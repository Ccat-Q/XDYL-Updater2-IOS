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
    var foreground = false
    var ticket = UUID()
    var namespace: String?
    var connectionTask: Task<ChatConnection, Error>?
    var syncTask: Task<Void, Error>?
    private var localWriteInProgress = false
    private var monitorID = UUID()
    private var mainGeneration: UUID
    private let defaults: UserDefaults
    var changedPeers = Set<String>()

    init(sessionStore: SessionStore, mainAPI: APIClient, defaults: UserDefaults = .standard) {
        self.sessionStore = sessionStore; self.mainAPI = mainAPI; self.defaults = defaults
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
        if !value { suspend(); messages = []; conversations = []; peers = []; pending = []; unreadCount = 0; status = "私聊已停用，本地历史和密钥未删除" }
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
              sessionStore.isAuthenticated, enabled, foreground else { throw CancellationError() }
    }
    func monitor() async {
        guard canConnect else { return }
        foreground = true; let id = UUID(); monitorID = id
        defer { if monitorID == id { suspend() } }
        var delay = 8
        while !Task.isCancelled, monitorID == id, canConnect, foreground {
            do {
                let c = try await connect()
                try await sync(c)
                try current(c); error = nil; status = "已连接 · 前台每 8 秒同步"; delay = 8
            } catch is CancellationError { return }
            catch {
                connected = false; self.error = error.localizedDescription; status = "离线或需要处理"
                if let e = error as? ChatFailure, e.code == "CURSOR_EXPIRED" { needsReset = true }
                if let e = error as? ChatFailure, e.code == "DEVICE_REVOKED" { return }
                if let failure = error as? ChatFailure, case .service(401, _, _) = failure { connection?.transport.cancel(); connection = nil }
                if let failure = error as? ChatFailure, case .service(429, _, let retry) = failure { delay = min(3600, max(8, retry ?? delay)) }
                else { delay = min(60, max(8, delay * 2)) }
            }
            do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) } catch { return }
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
            let relay = try ChatValidation.relay(self.relayText)
            let vault = ChatKeyVault(namespace: ns)
            var ring = try vault.load() ?? ChatKeyRing.create()
            try vault.save(ring) // Save before issuing public-key registration.
            let store = try ChatLocalStore(namespace: ns, key: ring.storeKey)
            let transport = ChatTransport(relay: relay)
            var succeeded = false; defer { if !succeeded { transport.cancel() } }
            @MainActor func valid() throws {
                try Task.checkCancellation()
                guard self.ticket == stamp, self.namespace == ns, self.sessionStore.generation == generation, self.enabled, self.foreground else { throw CancellationError() }
            }
            let history = try await store.all(ChatMessage.self, kind: "message")
            let contacts = try await store.all(ChatPeer.self, kind: "peer")
            let outbox = try await store.all(ChatPendingSend.self, kind: "pending")
            let cached = try await store.get([ChatConversation].self, kind: "state", id: "conversations") ?? []
            try valid(); self.messages = history; self.peers = contacts; self.pending = outbox; self.conversations = cached
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
            var updated = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
            for event in events {
                let type = try event.chatString("type")
                switch type {
                case "message":
                    var message = try decodeMessage(event, c: c)
                    if let old = updated[message.id], ["read", "received"].contains(old.status), message.status == "accepted" { message.status = old.status }
                    updated[message.id] = message
                    updated.removeValue(forKey: "pending:" + message.clientID)
                case "delivered":
                    if let id = event["message_id"]?.stringValue, var m = updated[id], m.sender == c.subject,
                       event["receiver_subject"]?.stringValue == m.recipient, m.status == "accepted" { m.status = "received"; updated[id] = m }
                case "read":
                    if let reader = event["reader_subject"]?.stringValue, let conv = event["conversation_id"]?.stringValue, let upto = Int64(event["up_to_conversation_seq"]?.stringValue ?? "") {
                        for (id, var m) in updated where m.conversationID == conv && m.sender == c.subject && m.recipient == reader && (Int64(m.sequence) ?? Int64.max) <= upto { m.status = "read"; updated[id] = m }
                    }
                case "message_hidden", "message_recalled":
                    if let id = event["message_id"]?.stringValue, var m = updated[id] { m.text = nil; m.raw = nil; m.status = type == "message_recalled" ? "recalled" : "hidden"; updated[id] = m }
                case "history_cleared":
                    if let conv = event["conversation_id"]?.stringValue, let upto = Int64(event["through_seq"]?.stringValue ?? "") {
                        for (id, var m) in updated where m.conversationID == conv && (Int64(m.sequence) ?? Int64.max) <= upto { m.text = nil; m.raw = nil; m.status = "hidden"; updated[id] = m }
                    }
                case "keyset_changed": if let owner = event["subject"]?.stringValue, owner != c.subject { changedPeers.insert(owner) }
                case "preferences_changed", "blocks_changed", "notification_preferences_changed", "conversation_state_changed": break
                default: unknownEvents = true
                }
            }
            try current(c)
            try await c.store.commit(events: events, messages: Array(updated.values), cursor: next)
            try current(c)
            messages = Array(updated.values)
            pending = try await c.store.all(ChatPendingSend.self, kind: "pending")
            try current(c)
            _ = try await c.transport.json("/chat/v2/sync/ack", token: c.token, method: "POST", body: .chatObject(["cursor": next]))
            try current(c); cursor = next
            if page["has_more"]?.boolValue != true { break }
        }
        try await refreshConversations(c)
    }
    func decodeMessage(_ event: JSONValue, c: ChatConnection) throws -> ChatMessage {
        let sender = try event.chatString("sender_subject"), recipient = try event.chatString("recipient_subject")
        guard sender == c.subject || recipient == c.subject else { throw ChatFailure.invalid("拒绝保存不属于当前账号的消息。") }
        let peer = sender == c.subject ? recipient : sender
        var message = ChatMessage(id: try event.chatString("message_id"), clientID: try event.chatString("client_msg_id"), conversationID: try event.chatString("conversation_id"), sequence: try event.chatSequence("conversation_seq"), sender: sender, recipient: recipient, text: nil, problem: nil, acceptedAt: try event.chatInt64("accepted_at_ms"), status: sender == c.subject ? "accepted" : "incoming", raw: event, peerSubject: peer)
        if let unavailable = event["unavailable"]?.stringValue { message.status = unavailable == "recalled" ? "recalled" : "hidden"; message.raw = nil; return message }
        do {
            guard let e = event["envelope"] else { throw ChatFailure.invalid("此设备没有消息密文。") }
            let remote: String, key: ChatPrivateKey
            if e["protocol"]?.stringValue == "nu-chat-v1" {
                key = try c.ring.key(e.chatString("own_key_id"))
                remote = try e.chatString(sender == c.subject ? "recipient_public_key" : "sender_public_key")
                try verifyRemote(peer: peer, keyID: ChatCrypto.legacyID(key.algorithm, remote), publicKey: remote)
                message.text = try ChatCrypto.decryptLegacy(e.chatString("cipher"), key: key, remote: remote)
            } else {
                guard e["target_subject"]?.stringValue == c.subject, e["target_device_id"]?.stringValue == c.ring.deviceID else { throw ChatFailure.invalid("消息密文不属于本设备。") }
                key = try c.ring.key(e.chatString("recipient_key_id"))
                let senderKeyID = try e.chatString("sender_key_id")
                if sender == c.subject {
                    if let embedded = e["sender_public_key"]?.stringValue { remote = embedded }
                    else { remote = try c.ring.key(senderKeyID).publicKey }
                }
                else {
                    remote = e["sender_public_key"]?.stringValue ?? peers.first(where: { $0.subject == peer })?.trustedKeys[senderKeyID] ?? ""
                    try verifyRemote(peer: peer, keyID: senderKeyID, publicKey: remote)
                }
                var metadata = e.objectValue
                for k in ["sender_subject", "sender_device_id", "recipient_subject", "client_msg_id"] { metadata[k] = event[k] }
                message.text = try ChatCrypto.decrypt(key: key, remote: remote, metadata: .object(metadata), nonce: e.chatString("nonce"), ciphertext: e.chatString("ciphertext"))
            }
        } catch { message.problem = "无法解密：请核对并信任联系人密钥，或从旧设备恢复所需私钥。" }
        return message
    }
    private func verifyRemote(peer: String, keyID: String, publicKey: String) throws {
        guard !publicKey.isEmpty, let trusted = peers.first(where: { $0.subject == peer }), !trusted.fingerprint.isEmpty,
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
            try await c.store.put(peer, kind: "peer", id: peer.subject); try current(c)
            peers.removeAll { $0.subject == peer.subject }; peers.append(peer)
        }
        try await c.store.put(list, kind: "state", id: "conversations")
    }
    func resetCursor() async throws {
        let c = try await connect()
        let result = try await c.transport.json("/chat/v2/sync/reset", token: c.token, method: "POST", body: .chatObject(["reason": "cursor_expired"]))["data"] ?? .null
        try current(c); try await c.store.put(try result.chatString("cursor"), kind: "state", id: "cursor")
        try current(c); needsReset = false; try await sync(c)
    }
}
