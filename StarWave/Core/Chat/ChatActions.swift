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
        try await localWrite(c) {
        var peer = peers.first(where: { $0.subject == inspection.subject }) ?? ChatPeer(subject: inspection.subject, username: inspection.username)
        peer.fingerprint = inspection.fingerprint; peer.username = inspection.username; peer.mode = mode
        if let note { peer.note = String(note.prefix(64)) }
        if peer.trustVersion != 1 { peer.trustedKeys = [:] }
        inspection.publicKeys.forEach { peer.trustedKeys[$0.key] = $0.value }
        peer.trustVersion = 1
        // Trust only the displayed fingerprint's keyset. Previously verified
        // keys survive rotation; raw messages cannot introduce a trusted key.
        try await c.store.put(peer, kind: "peer", id: peer.subject); try current(c)
        peers.removeAll { $0.subject == peer.subject }; peers.append(peer)
        changedPeers.remove(inspection.subject)
        var restored: [ChatMessage] = []
        for message in try await c.store.all(ChatMessage.self, kind: "message") where message.peerSubject == peer.subject {
            if let raw = message.raw { restored.append(try decodeMessage(raw, c: c, storedRecord: message)) }
        }
        try current(c)
        let changes = try await c.store.commit(events: [], messages: restored, cursor: nil, owner: c.subject, deviceID: c.ring.deviceID)
        try await mergeCommitted(changes, c: c)
        }
    }
    func saveContact(_ peer: ChatPeer) async throws {
        let c = try await connect()
        try await localWrite(c) {
            try await c.store.put(peer, kind: "peer", id: peer.subject); try current(c)
            peers.removeAll { $0.subject == peer.subject }; peers.append(peer)
        }
    }
    func send(_ text: String, to peer: ChatPeer, onQueued: (() -> Void)? = nil) async throws {
        guard !busy else { throw ChatFailure.invalid("正在准备发送，请稍候。") }
        try ChatValidation.plaintext(text); busy = true; defer { busy = false }
        let c = try await connect(), inspection = try await inspectPeer(peer.username)
        guard peer.trustVersion == 1, !changedPeers.contains(peer.subject), inspection.subject == peer.subject, !peer.fingerprint.isEmpty, inspection.fingerprint == peer.fingerprint else { throw ChatFailure.keyChanged(peer.subject) }
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
        try await localWrite(c) {
            try await c.store.savePending(pending); try current(c)
            self.pending.append(pending); messages.append(message)
        }
        // Ownership moves from the composer to the durable outbox before any
        // request. Uncertain HTTP results must retry this UUID, not mint another.
        onQueued?()
        try await submit(pending, c: c)
    }
    func retry(_ pending: ChatPendingSend) async throws { let c = try await connect(); try await submit(pending, c: c) }
    private func submit(_ pending: ChatPendingSend, c: ChatConnection) async throws {
        // Never rebuild a request after a timeout: UUID, nonce, ciphertext and
        // keyset snapshot remain byte-for-byte the same on every retry.
        let result = try await c.transport.json(pending.path, token: c.token, method: "POST", body: pending.body)
        try current(c)
        if pending.path == "/chat/v2/messages" {
            try await localWrite(c) {
            let accepted = result["data"] ?? .null
            var message = pending.message
            message.id = try accepted.chatString("message_id"); message.conversationID = try accepted.chatString("conversation_id")
            message.sequence = try accepted.chatSequence("conversation_seq"); message.acceptedAt = try accepted.chatInt64("accepted_at_ms"); message.status = "accepted"
            if let synced = messages.first(where: { $0.id == message.id }) {
                message.raw = synced.raw
                if ["received", "read", "hidden", "recalled"].contains(synced.status) { message.status = synced.status; message.text = synced.text }
            }
            let cursor = try await c.store.get(String.self, kind: "state", id: "cursor")
            let changes = try await c.store.commit(events: [], messages: [message], cursor: cursor, owner: c.subject, deviceID: c.ring.deviceID)
            try await mergeCommitted(changes, c: c)
            }
        } else {
            try await localWrite(c) {
                // Legacy acceptance contains only numeric seq, not the unified
                // message identity. Retain the exact outbox until sync proves it.
                if self.pending.contains(where: { $0.id == pending.id }) {
                    var accepted = pending; accepted.message.status = "accepted_waiting_sync"
                    try await c.store.savePending(accepted); try current(c)
                    self.pending.removeAll { $0.id == pending.id }; self.pending.append(accepted)
                    messages.removeAll { $0.id == pending.message.id }; messages.append(accepted.message)
                }
            }
        }
        do { try await sync(c) }
        catch is CancellationError { throw CancellationError() }
        catch { try current(c); self.error = "服务端已接受发送，后续同步暂未完成。请刷新或原样重试，不要重新发送同一内容。" }
        self.pending = try await c.store.all(ChatPendingSend.self, kind: "pending"); try current(c)
    }
    func draft(for peer: String) async -> String {
        let stamp = ticket
        do {
            let store = try localStorage(), value = try await store.get(String.self, kind: "draft", id: peer) ?? ""
            guard stamp == ticket else { return "" }; return value
        } catch is CancellationError { return "" }
        catch { self.error = error.localizedDescription; return "" }
    }
    func saveDraft(_ text: String, peer: String, namespace expected: String? = nil) async {
        guard expected == nil || expected == namespace else { return }
        let stamp = ticket
        do { let store = try localStorage(); try await store.put(text, kind: "draft", id: peer) }
        catch is CancellationError {} catch { if stamp == ticket { self.error = error.localizedDescription } }
    }
    @discardableResult
    func markRead(_ message: ChatMessage) async throws -> Bool {
        guard message.recipient == subject, message.text != nil, message.problem == nil, message.status == "incoming" else { return false }
        if let conv = conversations.first(where: { $0.id == message.conversationID }), conv.historyGap && conv.unread > conv.availableUnread { return false }
        guard !messages.contains(where: { $0.conversationID == message.conversationID && $0.recipient == subject && $0.status == "incoming" && $0.text == nil && (Int64($0.sequence) ?? Int64.max) <= (Int64(message.sequence) ?? 0) }) else { return false }
        let c = try await connect()
        // read only after visible, decrypted message and page ACK has completed.
        if let task = syncTask { try await task.value }
        _ = try await json("/chat/v2/conversations/\(message.conversationID)/read", method: "POST", body: .chatObject(["up_to_conversation_seq": message.sequence]))
        try await refreshConversations(c)
        return true
    }
    func hide(_ message: ChatMessage) async throws {
        _ = try await json("/chat/v2/messages/\(message.id)", method: "DELETE")
        let c = try await connect(); var hidden = message; hidden.status = "hidden"; hidden.text = nil; hidden.raw = nil
        try await localWrite(c) {
            try await c.store.put(hidden, kind: "message", id: hidden.id); try current(c)
            messages.removeAll { $0.id == hidden.id }; messages.append(hidden)
        }
        try await refreshConversations(c)
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
        try await localWrite(c) {
            let decoded = try result["messages"].chatArray().map { try decodeMessage($0, c: c) }
            let changes = try await c.store.commit(events: [], messages: decoded, cursor: nil, owner: c.subject, deviceID: c.ring.deviceID, preserveExisting: true)
            try await mergeCommitted(changes, c: c)
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
        let stamp = ticket
        let vault = keyVaultFactory(ns); var ring = try vault.load() ?? ChatKeyRing.create()
        ring.archiveKeys += ring.keys; ring.keys = try ChatCrypto.newKeys(); ring.deviceID = UUID().uuidString.lowercased(); ring.revision = "0"
        let store = try ChatLocalStore(namespace: ns, key: ring.storeKey)
        try await store.remove(kind: "state", id: "cursor")
        guard ticket == stamp, namespace == ns else { throw CancellationError() }
        try vault.save(ring); suspend(); currentDeviceID = ring.deviceID; lifecycleRevision = UUID()
    }
    func clearLocal() async throws {
        _ = try localStorage() // Resolve the exact account before invalidating IO.
        let resumeForeground = foreground, flight = syncTask
        suspend() // Reject delayed sync, paging, send and restore callbacks.
        foreground = resumeForeground
        defer { lifecycleRevision = UUID() }
        try await localOnlyWrite { store, valid in
            if let flight { _ = try? await flight.value }
            try valid(); try await store.clearLocalHistory(); try valid()
            messages = []; pending = []; status = "本机聊天历史已清除"
        }
    }
    func discardPending(_ item: ChatPendingSend) async throws {
        try await localOnlyWrite { store, valid in
        try await store.remove(kind: "pending", id: item.id); try await store.remove(kind: "message", id: item.message.id)
        try valid(); pending.removeAll { $0.id == item.id }; messages.removeAll { $0.id == item.message.id }
        }
    }
}
