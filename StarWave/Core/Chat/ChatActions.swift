import Foundation

extension ChatController {
    func inspectPeer(_ name: String) async throws -> ChatPeerInspection {
        let name = try ChatValidation.username(name.trimmingCharacters(in: .whitespacesAndNewlines))
        let c = try await connect()
        let p = try await json("/chat/v2/users/\(ChatValidation.segment(name))/protocols")
        let owner = try p.chatString("subject")
        guard owner != c.subject else { throw ChatFailure.invalid("私聊对象不能是自己。") }
        let protocols = try p["protocols"].chatArray().compactMap(\.stringValue)
        var native: ChatKeyBundle?, keys: [String: String] = [:], legacy: [String: String] = [:]
        if protocols.contains("nu-chat-v2") {
            let bundle = try ChatKeyBundle(try await json("/chat/v2/users/\(ChatValidation.segment(name))/keys"))
            guard bundle.subject == owner else { throw ChatFailure.invalid("联系人账号映射不一致。") }; native = bundle
            for device in bundle.devices { for key in device.keys { keys[key.keyID] = key.publicKey } }
        }
        for key in try p["legacy_public_keys"].chatArray() {
            let alg = try key.chatString("algorithm"), pub = try key.chatString("public_key")
            legacy[alg] = pub; keys[ChatCrypto.legacyID(alg, pub)] = pub
        }
        let snapshot = JSONValue.object(keys.mapValues(JSONValue.string))
        let fingerprint = ChatCrypto.digest(try ChatCrypto.canonical(snapshot))
        try current(c)
        return ChatPeerInspection(subject: owner, username: name, protocols: protocols, native: native, legacy: legacy, fingerprint: fingerprint, publicKeys: keys)
    }
    func trust(_ inspection: ChatPeerInspection, mode: ChatProtocolMode = .automatic, note: String? = nil) async throws {
        let c = try await connect(); try current(c)
        var peer = peers.first(where: { $0.subject == inspection.subject }) ?? ChatPeer(subject: inspection.subject, username: inspection.username)
        peer.fingerprint = inspection.fingerprint; peer.username = inspection.username; peer.mode = mode
        if let note { peer.note = String(note.prefix(64)) }
        inspection.publicKeys.forEach { peer.trustedKeys[$0.key] = $0.value }
        // Historical V2 public keys are delivered by the relay, not invented
        // from the current keyset. Remember them only after explicit trust.
        for message in messages where message.peerSubject == peer.subject && message.sender == peer.subject {
            if let e = message.raw?["envelope"], let id = e["sender_key_id"]?.stringValue, let pub = e["sender_public_key"]?.stringValue,
               peer.trustedKeys[id] == nil { peer.trustedKeys[id] = pub }
        }
        try await c.store.put(peer, kind: "peer", id: peer.subject); try current(c)
        peers.removeAll { $0.subject == peer.subject }; peers.append(peer)
        changedPeers.remove(inspection.subject)
        var restored = messages
        for i in restored.indices where restored[i].peerSubject == peer.subject && restored[i].text == nil {
            if let raw = restored[i].raw { restored[i] = try decodeMessage(raw, c: c) }
        }
        for message in restored { try await c.store.put(message, kind: "message", id: message.id) }
        try current(c); messages = restored
    }
    func saveContact(_ peer: ChatPeer) async throws {
        let c = try await connect(); try await c.store.put(peer, kind: "peer", id: peer.subject); try current(c)
        peers.removeAll { $0.subject == peer.subject }; peers.append(peer)
    }
    func send(_ text: String, to peer: ChatPeer) async throws {
        guard !busy else { throw ChatFailure.invalid("正在准备发送，请稍候。") }
        try ChatValidation.plaintext(text); busy = true; defer { busy = false }
        let c = try await connect(), inspection = try await inspectPeer(peer.username)
        guard !changedPeers.contains(peer.subject), inspection.subject == peer.subject, !peer.fingerprint.isEmpty, inspection.fingerprint == peer.fingerprint else { throw ChatFailure.keyChanged(peer.subject) }
        let id = UUID().uuidString.lowercased(), now = Self.now
        let useLegacy = peer.mode == .legacy || (peer.mode == .automatic && !inspection.protocols.contains("nu-chat-v2"))
        let path: String, request: JSONValue
        if useLegacy {
            guard features.contains("legacy_android_interop"), inspection.protocols.contains("nu-chat-v1") else { throw ChatFailure.invalid("对方或中继不支持旧协议。") }
            let binding = try await json("/chat/v2/devices/\(c.ring.deviceID)/legacy")
            guard binding["enabled"]?.boolValue == true, binding["device_id"]?.stringValue == c.ring.deviceID else { throw ChatFailure.service(403, "LEGACY_PRIMARY_DEVICE_REQUIRED", nil) }
            guard let algorithm = ["X25519", "P256"].first(where: { inspection.legacy[$0] != nil }), let remote = inspection.legacy[algorithm], let key = c.ring.keys.first(where: { $0.algorithm == algorithm }) else { throw ChatFailure.invalid("双方没有可互通的旧协议算法。") }
            let cipher = try ChatCrypto.encryptLegacy(text, key: key, remote: remote)
            path = "/chat/v2/legacy/messages"
            request = .object(["client_msg_id": .string(id), "to_username": .string(peer.username), "cipher": .string(cipher), "ts": .number(Double(now)), "sender_key_id": .string(key.keyID), "recipient_public_key": .string(remote)])
        } else {
            guard let receiver = inspection.native, !receiver.devices.isEmpty else { throw ChatFailure.service(409, "NO_ACTIVE_DEVICE", nil) }
            let own = try ChatKeyBundle(try await json("/chat/v2/users/\(ChatValidation.segment(c.username))/keys"))
            var envelopes: [JSONValue] = []
            for account in [own, receiver] { for device in account.devices {
                guard let target = device.keys.first(where: { $0.algorithm == "X25519" }) ?? device.keys.first(where: { $0.algorithm == "P256" }),
                      let local = c.ring.keys.first(where: { $0.algorithm == target.algorithm }) else { throw ChatFailure.invalid("某个目标设备没有受支持的密钥。") }
                var fields: [String: JSONValue] = ["target_subject": .string(account.subject), "target_device_id": .string(device.id), "algorithm": .string(target.algorithm), "sender_key_id": .string(local.keyID), "recipient_key_id": .string(target.keyID)]
                var metadata = fields
                metadata["sender_subject"] = .string(c.subject); metadata["sender_device_id"] = .string(c.ring.deviceID)
                metadata["recipient_subject"] = .string(peer.subject); metadata["client_msg_id"] = .string(id)
                let encrypted = try ChatCrypto.encrypt(text, key: local, remote: target.publicKey, metadata: .object(metadata))
                fields["nonce"] = .string(encrypted.0); fields["ciphertext"] = .string(encrypted.1); envelopes.append(.object(fields))
            } }
            path = "/chat/v2/messages"
            request = .object(["client_msg_id": .string(id), "to_subject": .string(peer.subject), "client_sent_at_ms": .number(Double(now)), "sender_keyset_revision": .string(own.revision), "recipient_keyset_revision": .string(receiver.revision), "envelopes": .array(envelopes)])
        }
        try current(c)
        let message = ChatMessage(id: "pending:" + id, clientID: id, conversationID: conversations.first(where: { $0.peerSubject == peer.subject })?.id ?? "", sequence: "0", sender: c.subject, recipient: peer.subject, text: text, problem: nil, acceptedAt: now, status: "pending", raw: nil, peerSubject: peer.subject)
        let pending = ChatPendingSend(id: id, peerSubject: peer.subject, path: path, body: request, message: message)
        try await c.store.savePending(pending); try current(c)
        self.pending.append(pending); messages.append(message)
        try await submit(pending, c: c)
    }
    func retry(_ pending: ChatPendingSend) async throws { let c = try await connect(); try await submit(pending, c: c) }
    private func submit(_ pending: ChatPendingSend, c: ChatConnection) async throws {
        // Never rebuild a request after a timeout: UUID, nonce, ciphertext and
        // keyset snapshot remain byte-for-byte the same on every retry.
        let result = try await c.transport.json(pending.path, token: c.token, method: "POST", body: pending.body)
        try current(c)
        if pending.path == "/chat/v2/messages" {
            let accepted = result["data"] ?? .null
            var message = pending.message
            message.id = try accepted.chatString("message_id"); message.conversationID = try accepted.chatString("conversation_id")
            message.sequence = try accepted.chatSequence("conversation_seq"); message.acceptedAt = try accepted.chatInt64("accepted_at_ms"); message.status = "accepted"
            let cursor = try await c.store.get(String.self, kind: "state", id: "cursor")
            try await c.store.commit(events: [], messages: [message], cursor: cursor)
            try current(c); messages.removeAll { $0.id == pending.message.id || $0.id == message.id }; messages.append(message)
        }
        // Legacy response only contains numeric seq. Its canonical ID arrives
        // in sync; keep outbox until that sync commit succeeds.
        try await sync(c)
        self.pending = try await c.store.all(ChatPendingSend.self, kind: "pending"); try current(c)
    }
    func draft(for peer: String) async -> String {
        guard let c = connection else { return "" }
        return (try? await c.store.get(String.self, kind: "draft", id: peer)) ?? ""
    }
    func saveDraft(_ text: String, peer: String) async {
        guard let c = connection, (try? current(c)) != nil else { return }
        do { try await c.store.put(String(text.prefix(16384)), kind: "draft", id: peer) } catch { self.error = error.localizedDescription }
    }
    func markRead(_ message: ChatMessage) async throws {
        guard message.recipient == subject, message.text != nil, message.problem == nil, message.status == "incoming" else { return }
        let c = try await connect()
        // read only after visible, decrypted message and page ACK has completed.
        if let task = syncTask { try await task.value }
        _ = try await json("/chat/v2/conversations/\(message.conversationID)/read", method: "POST", body: .chatObject(["up_to_conversation_seq": message.sequence]))
        try await refreshConversations(c)
    }
    func hide(_ message: ChatMessage) async throws {
        _ = try await json("/chat/v2/messages/\(message.id)", method: "DELETE")
        let c = try await connect(); var hidden = message; hidden.status = "hidden"; hidden.text = nil; hidden.raw = nil
        try await c.store.put(hidden, kind: "message", id: hidden.id); try current(c)
        messages.removeAll { $0.id == hidden.id }; messages.append(hidden); try await refreshConversations(c)
    }
    func recall(_ message: ChatMessage) async throws {
        _ = try await json("/chat/v2/messages/\(message.id)/recall", method: "POST", body: .object([:]))
        let c = try await connect(); try await sync(c)
    }
    func changeConversation(_ conv: ChatConversation, pinned: Bool? = nil, archived: Bool? = nil) async throws {
        var b: [String: JSONValue] = ["expected_revision": .string(conv.revision)]
        if let pinned { b["pinned"] = .bool(pinned) }; if let archived { b["archived"] = .bool(archived) }
        _ = try await json("/chat/v2/conversations/\(conv.id)/state", method: "PATCH", body: .object(b))
        let c = try await connect(); try await refreshConversations(c)
    }
    func clearConversation(_ conv: ChatConversation) async throws {
        _ = try await json("/chat/v2/conversations/\(conv.id)/clear", method: "POST", body: .chatObject(["expected_revision": conv.revision, "through_seq": conv.lastSequence]))
        let c = try await connect(); try await sync(c)
    }
    func block(_ peer: ChatPeer, enabled: Bool) async throws {
        _ = try await json("/chat/v2/blocks/\(ChatValidation.segment(peer.subject))", method: enabled ? "PUT" : "DELETE", body: enabled ? .object([:]) : nil)
    }
    func loadOlder(_ conv: ChatConversation, before: String?) async throws -> String? {
        let c = try await connect()
        var query = [URLQueryItem(name: "limit", value: "100")]; if let before { query.append(URLQueryItem(name: "before", value: before)) }
        let result = try await json("/chat/v2/conversations/\(conv.id)/messages", query: query)
        for event in try result["messages"].chatArray() {
            let message = try decodeMessage(event, c: c)
            // Do not turn a local/remote read back into accepted when paging.
            if !messages.contains(where: { $0.id == message.id }) { try await c.store.put(message, kind: "message", id: message.id); try current(c); messages.append(message) }
        }
        return result["has_more"]?.boolValue == true ? result["next_before"]?.stringValue : nil
    }
    func enableLegacy() async throws {
        let c = try await connect(), state = try await json("/chat/v2/devices/\(c.ring.deviceID)/legacy")
        _ = try await json("/chat/v2/devices/\(c.ring.deviceID)/legacy", method: "POST", body: .chatObject(["expected_revision": state["revision"]?.stringValue ?? "0", "key_revision": c.ring.revision]))
    }
    func revokeDevice(_ id: String) async throws {
        let c = try await connect(); _ = try await json("/chat/v2/devices/\(id)", method: "DELETE")
        if id == c.ring.deviceID { suspend(); status = "本机聊天设备已撤销" }
    }
    func createNewDevice() async throws {
        guard let ns = namespace else { return }
        let vault = ChatKeyVault(namespace: ns); var ring = try vault.load() ?? ChatKeyRing.create()
        ring.archiveKeys += ring.keys; ring.keys = try ChatCrypto.newKeys(); ring.deviceID = UUID().uuidString.lowercased(); ring.revision = "0"
        let store = try ChatLocalStore(namespace: ns, key: ring.storeKey)
        try await store.remove(kind: "state", id: "cursor")
        try vault.save(ring); suspend(); currentDeviceID = ring.deviceID; lifecycleRevision = UUID()
    }
    func clearLocal() async throws {
        let c = try await connect(); try await c.store.clearLocalHistory(); try current(c); messages = []; pending = []
    }
    func discardPending(_ item: ChatPendingSend) async throws {
        let c = try await connect()
        try await c.store.remove(kind: "pending", id: item.id); try await c.store.remove(kind: "message", id: item.message.id)
        try current(c); pending.removeAll { $0.id == item.id }; messages.removeAll { $0.id == item.message.id }
    }
}
