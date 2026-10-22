import Foundation
import Combine

struct ChatPeerInspection {
    let subject: String
    let username: String
    let protocols: [String]
    let native: ChatKeyBundle?
    let legacy: [String: String]
    let fingerprint: String
    let publicKeys: [String: String]
}

@MainActor
final class ChatController: ObservableObject {
    @Published var enabled = false
    @Published var relayText: String
    @Published var subject: String?
    @Published var username = ""
    @Published var conversations: [ChatConversation] = []
    @Published var messages: [ChatMessage] = []
    @Published var peers: [ChatPeer] = []
    @Published var features = Set<String>()
    @Published var unreadCount = 0
    @Published var connected = false
    @Published var status = "未启用私聊"
    @Published var error: String?
    @Published var needsReset = false
    @Published var busy = false
    @Published var currentDeviceID = ""
    @Published var pending: [ChatPendingSend] = []
    @Published var lifecycleRevision = UUID()
    @Published var unknownEvents = false

    let sessionStore: SessionStore
    let mainAPI: APIClient
    var connection: ChatConnection?
    var localStore: ChatLocalStore?
    var foreground = false
    var ticket = UUID()
    var namespace: String?
    var connectionTask: Task<ChatConnection, Error>?
    var syncTask: Task<Void, Error>?
    private var localWriteInProgress = false
    private var monitorID = UUID()
    private var mainGeneration: UUID
    private let defaults: UserDefaults
    let keyVaultFactory: (String) -> any ChatKeyStoring
    private let transportFactory: (URL) -> ChatTransport
    var changedPeers = Set<String>()

    init(sessionStore: SessionStore, mainAPI: APIClient, defaults: UserDefaults = .standard,
         keyVaultFactory: @escaping (String) -> any ChatKeyStoring = { ChatKeyVault(namespace: $0) },
         transportFactory: @escaping (URL) -> ChatTransport = { ChatTransport(relay: $0) }) {
        self.sessionStore = sessionStore; self.mainAPI = mainAPI; self.defaults = defaults
        self.keyVaultFactory = keyVaultFactory
        self.transportFactory = transportFactory
        mainGeneration = sessionStore.generation
        relayText = defaults.string(forKey: "chat.relay") ?? ChatValidation.defaultRelay
    }
    var lifecycleID: String { "\(namespace ?? "none")-\(enabled)-\(mainGeneration)-\(lifecycleRevision)" }
    var canConnect: Bool { subject != nil && enabled && sessionStore.isAuthenticated }
    func identify(_ profile: UserProfile) {
        guard let id = profile.stableID, let relay = try? ChatValidation.relay(relayText) else { resetIdentity(); return }
        let owner = "account:" + id, ns = ChatCrypto.namespace(relay: relay, subject: owner)
        if namespace != ns || mainGeneration != sessionStore.generation { resetIdentity() }
        mainGeneration = sessionStore.generation; namespace = ns; subject = owner; username = profile.username
        enabled = defaults.bool(forKey: "chat.consent." + ns)
    }
    func resetIdentity() {
        suspend(); namespace = nil; subject = nil; username = ""; enabled = false
        localStore = nil
        messages = []; conversations = []; peers = []; pending = []; unreadCount = 0; features = []; changedPeers = []
        needsReset = false; error = nil; currentDeviceID = ""; status = "未启用私聊"
    }
    func suspend() {
        foreground = false; ticket = UUID(); monitorID = UUID()
        connectionTask?.cancel(); connectionTask = nil; syncTask?.cancel(); syncTask = nil
        connection?.transport.cancel(); connection = nil; connected = false
    }
    func setEnabled(_ value: Bool) {
        guard let ns = namespace else { error = "主站资料缺少稳定账号 ID，请刷新资料后重试。"; return }
        defaults.set(value, forKey: "chat.consent." + ns); enabled = value
        if !value { suspend(); localStore = nil; messages = []; conversations = []; peers = []; pending = []; unreadCount = 0; status = "私聊已停用，本地历史和密钥未删除" }
    }
    func changeRelay(_ raw: String, profile: UserProfile?) throws {
        let url = try ChatValidation.relay(raw)
        resetIdentity(); relayText = url.absoluteString; defaults.set(relayText, forKey: "chat.relay")
        if let profile { identify(profile) }
        // Consent to another origin is never copied, even when account is same.
    }
    func current(_ c: ChatConnection) throws {
        try Task.checkCancellation()
        guard c.ticket == ticket, c.namespace == namespace, mainGeneration == sessionStore.generation,
              connection?.transport === c.transport, sessionStore.isAuthenticated, enabled, foreground else { throw CancellationError() }
    }
    func localStorage() throws -> ChatLocalStore {
        guard let ns = namespace, enabled, mainGeneration == sessionStore.generation, sessionStore.isAuthenticated else { throw CancellationError() }
        if let localStore { return localStore }
        let vault = keyVaultFactory(ns)
        let ring = try vault.load() ?? ChatKeyRing.create()
        try vault.save(ring)
        let store = try ChatLocalStore(namespace: ns, key: ring.storeKey)
        localStore = store; return store
    }
    func monitor(pollIntervalNanoseconds: UInt64? = nil) async {
        guard canConnect else { return }
        foreground = true; let id = UUID(), stamp = ticket; monitorID = id
        defer { if monitorID == id { suspend() } }
        var delay = 8
        while !Task.isCancelled, monitorID == id, canConnect, foreground {
            do {
                let c = try await connect()
                try await sync(c)
                try current(c); error = nil; status = "已连接 · 前台每 8 秒同步"; delay = 8
            } catch is CancellationError {
                // Transport replacement during renewal is not cancellation of
                // this foreground lifecycle. Never suspend its new connection.
                if Task.isCancelled || ticket != stamp || monitorID != id || !foreground { return }
                continue
            }
            catch {
                connected = false; self.error = error.localizedDescription; status = "离线或需要处理"
                if let e = error as? ChatFailure, e.code == "CURSOR_EXPIRED" { needsReset = true }
                if let e = error as? ChatFailure, e.code == "DEVICE_REVOKED" { return }
                if let failure = error as? ChatFailure, case .service(401, _, _) = failure { connection?.transport.cancel(); connection = nil }
                if let failure = error as? ChatFailure, case .service(429, _, let retry) = failure { delay = min(3600, max(8, retry ?? delay)) }
                else { delay = min(60, max(8, delay * 2)) }
            }
            do { try await Task.sleep(nanoseconds: pollIntervalNanoseconds ?? UInt64(delay) * 1_000_000_000) } catch { return }
        }
    }
    func refresh() async { await perform { let c = try await self.connect(); try await self.sync(c) } }
    func perform(_ action: () async throws -> Void) async {
        let stamp = ticket
        do { try await action() } catch is CancellationError {} catch { if stamp == ticket { self.error = error.localizedDescription } }
    }
    func connect() async throws -> ChatConnection {
        guard foreground, canConnect, let ns = namespace, let owner = subject else { throw ChatFailure.invalid("请先同意并启用聊天，并保持应用在前台。") }
        if let c = connection, c.ticket == ticket, c.expiresAt > Self.now + 30000 { return c }
        if let task = connectionTask { return try await task.value }
        let stamp = ticket, generation = sessionStore.generation
        let task: Task<ChatConnection, Error> = Task { @MainActor in
            // Drain the old page before replacing its transport. Its cursor
            // commit/ACK cannot be split by a concurrent session renewal.
            if let flight = self.syncTask { _ = try? await flight.value }
            try Task.checkCancellation()
            let relay = try ChatValidation.relay(self.relayText)
            let vault = self.keyVaultFactory(ns)
            var ring = try vault.load() ?? ChatKeyRing.create()
            try vault.save(ring) // Save before issuing public-key registration.
            let store = try self.localStorage()
            let transport = self.transportFactory(relay)
            var succeeded = false; defer { if !succeeded { transport.cancel() } }
            @MainActor func valid() throws {
                try Task.checkCancellation()
                guard self.ticket == stamp, self.namespace == ns, self.sessionStore.generation == generation, self.enabled, self.foreground else { throw CancellationError() }
            }
            if self.connection == nil {
                var history = try await store.all(ChatMessage.self, kind: "message")
                let contacts = try await store.all(ChatPeer.self, kind: "peer")
                var repairs: [ChatMessage] = []
                for index in history.indices {
                    // Migrate local recipient provenance before quarantining
                    // old contact trust. This does not authenticate the remote
                    // sender: revalidation still requires explicitly pinned keys.
                    if history[index].validatedTargetDeviceID == nil, history[index].text != nil, history[index].problem == nil,
                       let envelope = history[index].raw?["envelope"], envelope["target_subject"]?.stringValue == owner,
                       let target = envelope["target_device_id"]?.stringValue, UUID(uuidString: target) != nil,
                       let keyID = envelope["recipient_key_id"]?.stringValue, (try? ring.key(keyID)) != nil {
                        history[index].validatedTargetDeviceID = target; repairs.append(history[index])
                    }
                    if history[index].sender != owner, history[index].raw != nil,
                       contacts.first(where: { $0.subject == history[index].peerSubject })?.trustVersion != 1 {
                        history[index].text = nil; history[index].problem = "请重新核对联系人指纹；旧版本记录的历史公钥没有完整的核验来源。"
                        repairs.append(history[index])
                    }
                    if history[index].sender == owner, let envelope = history[index].raw?["envelope"],
                       envelope["protocol"]?.stringValue != "nu-chat-v1", (try? ring.verifiedOwnSender(envelope)) == nil {
                        history[index].text = nil; history[index].problem = "无法验证本人发送设备的公钥，请从可信设备迁移或恢复密钥。"
                        repairs.append(history[index])
                    }
                    let oldID = history[index].clientID
                    history[index].associateLegacySend(owner: owner, deviceID: ring.deviceID)
                    if oldID != history[index].clientID { repairs.append(history[index]) }
                }
                // Reconcile historical duplicate bubbles only with matching
                // accepted ciphertext, sender, recipient and device evidence.
                let outbox = try await store.all(ChatPendingSend.self, kind: "pending")
                repairs += history.filter { message in outbox.contains { $0.isAccepted(by: message) } }
                if !repairs.isEmpty { try await store.commit(events: [], messages: repairs, cursor: nil, owner: owner, deviceID: ring.deviceID) }
                let pending = try await store.all(ChatPendingSend.self, kind: "pending")
                let cached = try await store.get([ChatConversation].self, kind: "state", id: "conversations") ?? []
                let retained = Set(pending.map { $0.message.id })
                try valid(); self.messages = history.filter { !$0.id.hasPrefix("pending:") || retained.contains($0.id) }
                self.peers = contacts; self.pending = pending; self.conversations = cached
            }
            self.currentDeviceID = ring.deviceID; self.status = "正在验证中继能力"
            let caps = try ChatCapabilities(try await transport.json("/chat/v2/capabilities")["data"] ?? .null)
            try valid(); self.features = caps.features
            // Refresh against MAIN only; this call never sends the main bearer
            // to the relay. A separate, consented session exchange does below.
            let profile = try await self.mainAPI.profile(); try valid()
            guard profile.stableID.map({ "account:" + $0 }) == owner, let mainToken = self.sessionStore.accessToken else { throw ChatFailure.invalid("主站身份已变化，已停止聊天认证。") }
            let session = try await transport.json("/chat/v2/session", token: mainToken, method: "POST", body: .chatObject(["device_id": ring.deviceID, "device_name": "StarWave iPhone"]), mainCredential: true)["data"] ?? .null
            try valid()
            guard try session.chatString("subject") == owner else { throw ChatFailure.invalid("中继账号与主站稳定身份不一致。") }
            let token = try session.chatString("chat_token"), name = try session.chatString("username")
            let own = try ChatKeyBundle(try await transport.json("/chat/v2/users/\(ChatValidation.segment(name))/keys", token: token)["data"] ?? .null)
            try valid()
            if let device = own.devices.first(where: { $0.id == ring.deviceID }) {
                guard Set(device.keys) == Set(ring.keys.map(\.published)) else { throw ChatFailure.invalid("云端设备密钥与本机不符，未覆盖密钥。请检查设备列表。") }
                ring.revision = device.revision
            } else {
                guard ring.revision == "0" else { throw ChatFailure.invalid("云端未找到本机已登记的密钥，请检查撤销或恢复状态。") }
                let registered = try await transport.json("/chat/v2/devices/\(ring.deviceID)/keys", token: token, method: "POST", body: .object(["expected_revision": .string("0"), "keys": .array(ring.keys.map { $0.published.json })]))["data"] ?? .null
                try valid(); ring.revision = try registered.chatSequence("key_revision")
            }
            try valid()
            if let latest = try vault.load() {
                guard latest.deviceID == ring.deviceID else { throw CancellationError() }
                ring.archiveKeys = latest.archiveKeys
            }
            try vault.save(ring); try valid()
            let c = ChatConnection(ticket: stamp, namespace: ns, subject: owner, username: name, token: token, expiresAt: try session.chatInt64("expires_at_ms"), transport: transport, store: store, ring: ring)
            self.connection?.transport.cancel(); self.connection = c; self.connected = true; self.username = name
            succeeded = true; return c
        }
        connectionTask = task
        defer { if ticket == stamp { connectionTask = nil } }
        return try await task.value
    }
    static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func json(_ path: String, method: String = "GET", body: JSONValue? = nil, query: [URLQueryItem] = []) async throws -> JSONValue {
        let c = try await connect()
        let value = try await c.transport.json(path, token: c.token, method: method, body: body, query: query)
        try current(c); return value["data"] ?? value
    }
    func sync(_ c: ChatConnection) async throws {
        if localWriteInProgress { return }
        if let task = syncTask { return try await task.value }
        let task = Task { @MainActor in try await self.syncPages(c) }; syncTask = task
        defer { if ticket == c.ticket { syncTask = nil } }
        try await task.value
        try current(c); connected = true
    }
    func localWrite<T>(_ c: ChatConnection, _ action: () async throws -> T) async throws -> T {
        // Sync can suspend during decryption/network IO. Serialize local edits
        // with the full page commit so an older snapshot cannot resurrect a
        // cleared message or discard a just-created pending row in memory.
        while localWriteInProgress { try await Task.sleep(nanoseconds: 10_000_000); try current(c) }
        localWriteInProgress = true; defer { localWriteInProgress = false }
        if let task = syncTask { try await task.value }
        try current(c); return try await action()
    }
    /// Account-scoped local operations must not establish a relay connection.
    /// Failed existing sync is drained, not required to succeed. The same lock
    /// prevents a local edit from racing page commit or history restore.
    func localOnlyWrite<T>(_ action: (ChatLocalStore, () throws -> Void) async throws -> T) async throws -> T {
        let store = try localStorage(), stamp = ticket, ns = namespace, generation = sessionStore.generation
        func valid() throws {
            try Task.checkCancellation()
            guard ticket == stamp, namespace == ns, mainGeneration == generation,
                  sessionStore.generation == generation, enabled, sessionStore.isAuthenticated else { throw CancellationError() }
        }
        while localWriteInProgress { try await Task.sleep(nanoseconds: 10_000_000); try valid() }
        localWriteInProgress = true; defer { localWriteInProgress = false }
        if let flight = syncTask { _ = try? await flight.value }
        try valid(); return try await action(store, valid)
    }
    func mergeCommitted(_ changes: [ChatMessage], c: ChatConnection) async throws {
        let outbox = try await c.store.all(ChatPendingSend.self, kind: "pending"); try current(c)
        pending = outbox
        let ids = Set(changes.map(\.id)), retained = Set(outbox.map { $0.message.id })
        messages.removeAll { ids.contains($0.id) || ($0.id.hasPrefix("pending:") && !retained.contains($0.id)) }
        messages += changes
    }
    private func syncPages(_ c: ChatConnection) async throws {
        try current(c)
        var cursor = try await c.store.get(String.self, kind: "state", id: "cursor")
        for _ in 0..<100 {
            try current(c)
            var query = [URLQueryItem(name: "limit", value: "200")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page = try await c.transport.json("/chat/v2/sync", token: c.token, query: query)["data"] ?? .null
            try current(c)
            let events = try page["events"].chatArray(), next = try page.chatString("next_cursor")
            var decoded: [ChatMessage] = []
            for event in events {
                let type = try event.chatString("type")
                switch type {
                case "message":
                    decoded.append(try decodeMessage(event, c: c))
                case "delivered", "read", "message_hidden", "message_recalled", "history_cleared": break
                case "keyset_changed": if let owner = event["subject"]?.stringValue, owner != c.subject { changedPeers.insert(owner) }
                case "preferences_changed", "blocks_changed", "notification_preferences_changed", "conversation_state_changed": break
                default: unknownEvents = true
                }
            }
            try current(c)
            let changes = try await c.store.commit(events: events, messages: decoded, cursor: next, owner: c.subject, deviceID: c.ring.deviceID)
            try await mergeCommitted(changes, c: c)
            try current(c)
            _ = try await c.transport.json("/chat/v2/sync/ack", token: c.token, method: "POST", body: .chatObject(["cursor": next]))
            try current(c); cursor = next
            if page["has_more"]?.boolValue != true { break }
        }
        try await refreshConversations(c)
    }
    func decodeMessage(_ event: JSONValue, c: ChatConnection, storedRecord: ChatMessage? = nil) throws -> ChatMessage {
        let sender = try event.chatString("sender_subject"), recipient = try event.chatString("recipient_subject")
        guard sender == c.subject || recipient == c.subject else { throw ChatFailure.invalid("拒绝保存不属于当前账号的消息。") }
        let peer = sender == c.subject ? recipient : sender
        var message = ChatMessage(id: try event.chatString("message_id"), clientID: try event.chatString("client_msg_id"), conversationID: try event.chatString("conversation_id"), sequence: try event.chatSequence("conversation_seq"), sender: sender, recipient: recipient, text: nil, problem: nil, acceptedAt: try event.chatInt64("accepted_at_ms"), status: sender == c.subject ? "accepted" : "incoming", raw: event, peerSubject: peer)
        message.associateLegacySend(owner: c.subject, deviceID: c.ring.deviceID)
        if let unavailable = event["unavailable"]?.stringValue {
            message.status = unavailable == "recalled" ? "recalled" : "hidden"
            // Keep only wire identity until the store reconciles the outbox;
            // the transaction removes raw before persisting the tombstone.
            var identity = event.objectValue; identity["envelope"] = nil; message.raw = .object(identity)
            return message
        }
        do {
            guard let e = event["envelope"] else { throw ChatFailure.invalid("此设备没有消息密文。") }
            let remote: String, key: ChatPrivateKey
            if e["protocol"]?.stringValue == "nu-chat-v1" {
                key = try c.ring.key(e.chatString("own_key_id"))
                remote = try e.chatString(sender == c.subject ? "recipient_public_key" : "sender_public_key")
                try verifyRemote(peer: peer, keyID: ChatCrypto.legacyID(key.algorithm, remote), publicKey: remote)
                message.text = try ChatCrypto.decryptLegacy(e.chatString("cipher"), key: key, remote: remote)
            } else {
                let targetDevice = try e.chatString("target_device_id"), recipientKey = try e.chatString("recipient_key_id")
                let localHistory = storedRecord.map {
                    $0.raw == event && $0.id == message.id && $0.clientID == message.clientID && $0.conversationID == message.conversationID
                        && $0.sender == sender && $0.recipient == recipient && $0.sequence == message.sequence && $0.peerSubject == peer
                        && $0.hasServerSequence && !["hidden", "recalled"].contains($0.status)
                        && ($0.validatedTargetDeviceID == targetDevice
                            || ($0.text != nil && $0.problem == nil && c.ring.archiveKeys.contains(where: { $0.keyID == recipientKey })))
                } ?? false
                guard e["target_subject"]?.stringValue == c.subject,
                      targetDevice == c.ring.deviceID || (localHistory && UUID(uuidString: targetDevice) != nil) else { throw ChatFailure.invalid("消息密文不属于本设备或可信本地历史。") }
                if localHistory { message.validatedTargetDeviceID = targetDevice }
                key = try c.ring.key(e.chatString("recipient_key_id"))
                let senderKeyID = try e.chatString("sender_key_id")
                if sender == c.subject {
                    let own = try c.ring.verifiedOwnSender(e)
                    guard own.algorithm == key.algorithm else { throw ChatFailure.invalid("本人发送钥与目标算法不符。") }
                    remote = own.publicKey
                }
                else {
                    remote = e["sender_public_key"]?.stringValue ?? peers.first(where: { $0.subject == peer })?.trustedKeys[senderKeyID] ?? ""
                    try verifyRemote(peer: peer, keyID: senderKeyID, publicKey: remote)
                }
                var metadata = e.objectValue
                for k in ["sender_subject", "sender_device_id", "recipient_subject", "client_msg_id"] { metadata[k] = event[k] }
                message.text = try ChatCrypto.decrypt(key: key, remote: remote, metadata: .object(metadata), nonce: e.chatString("nonce"), ciphertext: e.chatString("ciphertext"))
                message.validatedTargetDeviceID = targetDevice
            }
        } catch {
            message.problem = sender == c.subject
                ? "无法验证或解密本人设备的消息：请从可信设备迁移或恢复私钥；不会自动信任消息附带的公钥。"
                : "无法解密：请核对并信任联系人密钥，或从旧设备恢复所需私钥。"
        }
        return message
    }
    private func verifyRemote(peer: String, keyID: String, publicKey: String) throws {
        guard !publicKey.isEmpty, let trusted = peers.first(where: { $0.subject == peer }), trusted.trustVersion == 1, !trusted.fingerprint.isEmpty,
              trusted.trustedKeys[keyID] == publicKey else { throw ChatFailure.keyChanged(peer) }
    }
    func refreshConversations(_ c: ChatConnection) async throws {
        var list: [ChatConversation] = [], cursor: String?
        repeat {
            var q = [URLQueryItem(name: "archived", value: "all"), URLQueryItem(name: "limit", value: "100")]
            if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page = try await c.transport.json("/chat/v2/conversations", token: c.token, query: q)["data"] ?? .null
            try current(c); list += try page["conversations"].chatArray().map(ChatConversation.init)
            unreadCount = page["unread_total"]?.integer ?? 0
            cursor = page["has_more"]?.boolValue == true ? try page.chatString("next_cursor") : nil
        } while cursor != nil
        try current(c); conversations = list
        for conv in list {
            var peer = peers.first(where: { $0.subject == conv.peerSubject }) ?? ChatPeer(subject: conv.peerSubject, username: conv.peerUsername)
            peer.username = conv.peerUsername
            if peers.first(where: { $0.subject == peer.subject }) != peer { try await c.store.put(peer, kind: "peer", id: peer.subject) }
            try current(c)
            peers.removeAll { $0.subject == peer.subject }; peers.append(peer)
        }
        if try await c.store.get([ChatConversation].self, kind: "state", id: "conversations") != list { try await c.store.put(list, kind: "state", id: "conversations") }
    }
    func resetCursor() async throws {
        let c = try await connect()
        let result = try await c.transport.json("/chat/v2/sync/reset", token: c.token, method: "POST", body: .chatObject(["reason": "cursor_expired"]))["data"] ?? .null
        try current(c); try await c.store.put(try result.chatString("cursor"), kind: "state", id: "cursor")
        try current(c); needsReset = false; try await sync(c)
    }
}
