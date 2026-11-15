import Foundation
import Combine
import CryptoKit

// No arbitrary message/error strings enter the diagnostic store. All text is
// fixed vocabulary; identifiers and public keys are reduced to short hashes.
enum ChatDiagnosticCategory: String, CaseIterable, Sendable { case connection = "连接", crypto = "加解密", keys = "密钥", lifecycle = "生命周期" }
enum ChatDiagnosticOutcome: String, Sendable { case started = "开始", succeeded = "成功", failed = "失败", info = "信息" }
enum ChatDiagnosticProtocol: String, Sendable { case v1 = "nu-chat-v1", v2 = "nu-chat-v2", unknown = "未知协议" }
enum ChatDiagnosticAlgorithm: String, Sendable {
    case x25519 = "X25519", p256 = "P256", unknown = "未知算法"
    init(_ wire: String) { self = wire == "X25519" ? .x25519 : wire == "P256" ? .p256 : .unknown }
}
enum ChatDiagnosticDirection: String, Sendable { case incoming = "接收", outgoing = "发送" }
enum ChatDiagnosticState: String, Sendable { case disabled = "未启用", disconnected = "未连接", connected = "已连接" }
enum ChatDiagnosticStage: String, Sendable {
    case connection = "建立连接", capabilities = "中继能力", mainProfile = "主站资料", session = "会话交换", deviceBundle = "设备公钥集合", syncFetch = "同步读取", syncCommit = "同步提交", syncAck = "同步确认"
    case envelope = "信封检查", deviceTarget = "目标设备", localKey = "本机密钥查找", peerTrust = "联系人信任校验", ownSender = "本人发送钥校验"
    case cipherFormat = "密文格式", keyAgreement = "ECDH 密钥协商", keyDerivation = "HKDF 密钥派生", authenticatedCipher = "AES-GCM 认证加解密", plaintextValidation = "明文格式校验"
}
enum ChatDiagnosticReason: String, CaseIterable, Sendable {
    case schemaUnsupported = "SCHEMA_UNSUPPORTED", ownKeyMissing = "OWN_KEY_MISSING", ownKeyInvalid = "OWN_KEY_INVALID"
    case ownKeyPairMismatch = "OWN_KEY_PAIR_MISMATCH", peerUntrusted = "PEER_UNTRUSTED", peerKeyInvalid = "PEER_KEY_INVALID"
    case targetMismatch = "TARGET_MISMATCH", ownSenderUnverified = "OWN_SENDER_UNVERIFIED"
    case algorithmMismatch = "ALGORITHM_MISMATCH"
    case cipherFormatInvalid = "CIPHER_FORMAT_INVALID", keyAgreementFailed = "KEY_AGREEMENT_FAILED", aeadAuthenticationFailed = "AEAD_AUTH_FAILED"
    case plaintextInvalid = "PLAINTEXT_INVALID", cryptoFailed = "CRYPTO_FAILED", identityMismatch = "IDENTITY_MISMATCH"
    case cancelled = "CANCELLED", unauthorized = "UNAUTHORIZED", rateLimited = "RATE_LIMITED", remoteRejected = "REMOTE_REJECTED"
    case transportFailure = "TRANSPORT_FAILED", invalidResponse = "INVALID_RESPONSE", storageFailure = "STORAGE_FAILED", unknown = "UNKNOWN_FAILURE"
}
enum ChatDiagnosticEvent: String {
    case snapshot = "SNAPSHOT", suspended = "SUSPENDED"
    case connectStarted = "CONNECT_STARTED", capabilitiesVerified = "CAPABILITIES_VERIFIED", identityVerified = "IDENTITY_VERIFIED"
    case sessionExchanged = "SESSION_EXCHANGED", deviceKeysVerified = "DEVICE_KEYS_VERIFIED", connected = "CONNECTED", connectFailed = "CONNECT_FAILED"
    case requestStarted = "REQUEST_STARTED", requestCompleted = "REQUEST_COMPLETED", requestFailed = "REQUEST_FAILED"
    case syncStarted = "SYNC_STARTED", syncCommitted = "SYNC_COMMITTED", syncAcknowledged = "SYNC_ACKNOWLEDGED", syncCompleted = "SYNC_COMPLETED", syncFailed = "SYNC_FAILED"
    case decryptStarted = "DECRYPT_STARTED", decryptStage = "DECRYPT_STAGE", decryptSucceeded = "DECRYPT_SUCCEEDED", decryptFailed = "DECRYPT_FAILED"
    case encryptStarted = "ENCRYPT_STARTED", encryptStage = "ENCRYPT_STAGE", encryptSucceeded = "ENCRYPT_SUCCEEDED", encryptFailed = "ENCRYPT_FAILED"
    case keyPairChecked = "KEY_PAIR_CHECKED"
    var category: ChatDiagnosticCategory {
        switch self {
        case .snapshot, .suspended: return .lifecycle
        case .decryptStarted, .decryptStage, .decryptSucceeded, .decryptFailed, .encryptStarted, .encryptStage, .encryptSucceeded, .encryptFailed: return .crypto
        case .deviceKeysVerified, .keyPairChecked: return .keys
        default: return .connection
        }
    }
    var title: String {
        switch self {
        case .snapshot: return "当前诊断快照"
        case .suspended: return "连接已暂停"
        case .connectStarted: return "建立聊天连接"
        case .capabilitiesVerified: return "V2 中继能力核验"
        case .identityVerified: return "主站身份核验"
        case .sessionExchanged: return "聊天会话交换"
        case .deviceKeysVerified: return "云端设备公钥核对"
        case .connected: return "聊天连接就绪"
        case .connectFailed: return "连接失败"
        case .requestStarted: return "中继请求开始"
        case .requestCompleted: return "中继请求完成"
        case .requestFailed: return "中继请求失败"
        case .syncStarted: return "读取同步页"
        case .syncCommitted: return "同步页已保存"
        case .syncAcknowledged: return "同步页已确认"
        case .syncCompleted: return "同步页已提交并确认"
        case .syncFailed: return "同步未完成"
        case .decryptStarted: return "消息解密开始"
        case .decryptStage: return "消息解密阶段"
        case .decryptSucceeded: return "消息解密成功"
        case .decryptFailed: return "消息解密失败"
        case .encryptStarted: return "消息加密开始"
        case .encryptStage: return "消息加密阶段"
        case .encryptSucceeded: return "消息加密成功"
        case .encryptFailed: return "消息加密失败"
        case .keyPairChecked: return "本机公私钥配对检查"
        }
    }
}
enum ChatDiagnosticRoute: String, Sendable {
    case capabilities = "能力", session = "会话", sync = "同步", syncAck = "同步确认", keys = "设备公钥", legacy = "旧协议兼容", messages = "消息", conversations = "会话列表", history = "加密历史", settings = "设置", other = "其他 V2 请求"
    init(path: String) {
        if path == "/chat/v2/capabilities" { self = .capabilities }
        else if path == "/chat/v2/session" { self = .session }
        else if path == "/chat/v2/sync" { self = .sync }
        else if path == "/chat/v2/sync/ack" { self = .syncAck }
        else if path.contains("/legacy") { self = .legacy }
        else if path.hasSuffix("/keys") { self = .keys }
        else if path.hasPrefix("/chat/v2/history/") { self = .history }
        else if path.hasPrefix("/chat/v2/messages") { self = .messages }
        else if path.hasPrefix("/chat/v2/conversations") { self = .conversations }
        else { self = .other }
    }
}
struct ChatDiagnosticField: Equatable, Identifiable {
    let label: String
    let value: String
    var id: String { label + ":" + value }
    fileprivate init(_ label: String, _ value: String) { self.label = label; self.value = value }
}
enum ChatDiagnosticDetail {
    case localAlgorithm(ChatDiagnosticAlgorithm), wireAlgorithm(ChatDiagnosticAlgorithm)
    case wireProtocol(ChatDiagnosticProtocol), algorithm(ChatDiagnosticAlgorithm), direction(ChatDiagnosticDirection), stage(ChatDiagnosticStage), route(ChatDiagnosticRoute), state(ChatDiagnosticState)
    case httpStatus(Int), elapsedMilliseconds(Int), count(Int), activeKeyCount(Int), archivedKeyCount(Int), revision(String)
    case pairMatches(Bool?), trusted(Bool), targetMatches(Bool), pendingRotation(Bool), hasSession(Bool)
    case messageID(String), ownKeyID(String), peerKeyID(String), deviceID(String), ownPublicKey(String), peerPublicKey(String), relay(URL)
    private static func reference(_ value: String) -> String { String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)) }
    private static func publicFingerprint(_ value: String) -> String {
        guard value.utf8.count <= 512, let data = Data(base64Encoded: value), [44, 91].contains(data.count), data.first == 0x30 else { return "格式无效" }
        return referenceBytes(data)
    }
    private static func referenceBytes(_ value: Data) -> String { String(SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined().prefix(16)) }
    fileprivate var field: ChatDiagnosticField {
        func number(_ value: Int) -> String { String(min(1_000_000_000, max(0, value))) }
        func flag(_ value: Bool) -> String { value ? "是" : "否" }
        switch self {
        case .wireProtocol(let v): return .init("协议", v.rawValue)
        case .algorithm(let v): return .init("曲线", v.rawValue)
        case .localAlgorithm(let v): return .init("本机算法", v.rawValue)
        case .wireAlgorithm(let v): return .init("信封算法", v.rawValue)
        case .direction(let v): return .init("方向", v.rawValue)
        case .stage(let v): return .init("阶段", v.rawValue)
        case .route(let v): return .init("请求类别", v.rawValue)
        case .state(let v): return .init("连接状态", v.rawValue)
        case .httpStatus(let v): return .init("HTTP", (100...599).contains(v) ? String(v) : "无有效状态")
        case .elapsedMilliseconds(let v): return .init("耗时 ms", number(v))
        case .count(let v): return .init("数量", number(v))
        case .activeKeyCount(let v): return .init("活动密钥数", number(v))
        case .archivedKeyCount(let v): return .init("历史密钥数", number(v))
        case .revision(let v): return .init("密钥版本", Int64(v).flatMap { $0 >= 0 ? String($0) : nil } ?? "无效")
        case .pairMatches(let v): return .init("本机公私钥配对", v.map(flag) ?? "无法验证")
        case .trusted(let v): return .init("对端公钥已信任", flag(v))
        case .targetMatches(let v): return .init("目标设备匹配", flag(v))
        case .pendingRotation(let v): return .init("待核对轮换", flag(v))
        case .hasSession(let v): return .init("存在聊天会话", flag(v))
        case .messageID(let v): return .init("消息引用 SHA256/16", Self.reference(v))
        case .ownKeyID(let v): return .init("本机钥引用 SHA256/16", Self.reference(v))
        case .peerKeyID(let v): return .init("对端钥引用 SHA256/16", Self.reference(v))
        case .deviceID(let v): return .init("设备引用 SHA256/16", Self.reference(v))
        case .ownPublicKey(let v): return .init("本机 SPKI SHA256/16", Self.publicFingerprint(v))
        case .peerPublicKey(let v): return .init("对端 SPKI SHA256/16", Self.publicFingerprint(v))
        case .relay(let v): return .init("中继引用 SHA256/16", Self.reference(v.absoluteString))
        }
    }
}
struct ChatDiagnosticEntry: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let event: ChatDiagnosticEvent
    let outcome: ChatDiagnosticOutcome
    let reason: ChatDiagnosticReason?
    let fields: [ChatDiagnosticField]
    var repetitions: Int
    var category: ChatDiagnosticCategory { event.category }
    var code: String { reason?.rawValue ?? event.rawValue }
    var title: String { event.title }
}
@MainActor
final class ChatDiagnostics: ObservableObject {
    @Published private(set) var entries: [ChatDiagnosticEntry] = []
    @Published private(set) var snapshot: [ChatDiagnosticField] = []
    @Published var isRecording = true
    @Published private(set) var discardedCount = 0
    private(set) var generation = UUID()
    let limit: Int
    private let now: () -> Date
    private var scope: String?
    private var snapshotCapturedAt: Date?
    private let retention: TimeInterval = 24 * 60 * 60
    init(limit: Int = 400, now: @escaping () -> Date = Date.init) { self.limit = min(2000, max(1, limit)); self.now = now }
    func resetScope(_ namespace: String?) {
        guard scope != namespace else { return }
        scope = namespace; generation = UUID(); clear(); snapshot = []; snapshotCapturedAt = nil
    }
    func invalidateCallbacks() { generation = UUID() }
    func resetSession() { generation = UUID(); clear(); snapshot = []; snapshotCapturedAt = nil }
    func clear() { entries = []; discardedCount = 0 }
    func updateSnapshot(_ details: [ChatDiagnosticDetail]) { snapshot = details.map(\.field); snapshotCapturedAt = now() }
    func prune() {
        let cutoff = now().addingTimeInterval(-retention)
        if let captured = snapshotCapturedAt, captured < cutoff { snapshot = []; snapshotCapturedAt = nil }
        let removed = entries.filter { $0.date < cutoff }.count
        if removed > 0 { entries.removeAll { $0.date < cutoff }; discardedCount += removed }
    }
    func record(_ event: ChatDiagnosticEvent, outcome: ChatDiagnosticOutcome = .info, reason: ChatDiagnosticReason? = nil, details: [ChatDiagnosticDetail] = [], generation expected: UUID? = nil) {
        guard isRecording, expected == nil || expected == generation else { return }
        prune()
        let fields = details.map(\.field)
        let time = now()
        if let last = entries.last, last.event == event, last.outcome == outcome, last.reason == reason, last.fields == fields, time.timeIntervalSince(last.date) < 2 {
            entries[entries.count - 1].repetitions += 1; return
        }
        entries.append(.init(id: UUID(), date: time, event: event, outcome: outcome, reason: reason, fields: fields, repetitions: 1))
        if entries.count > limit { let excess = entries.count - limit; entries.removeFirst(excess); discardedCount += excess }
    }
    static var buildSummary: String {
        func version(_ key: String) -> String {
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
            return value.range(of: #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$"#, options: .regularExpression) != nil ? value : "未知"
        }
        let raw = Bundle.main.object(forInfoDictionaryKey: "ChatSourceRevision") as? String ?? ""
        let commit = raw.range(of: #"^[a-fA-F0-9]{7,40}$"#, options: .regularExpression) != nil ? String(raw.prefix(12)) : "未知"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "App \(version("CFBundleShortVersionString")) (\(version("CFBundleVersion"))) · 源码 \(commit) · iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
    func exportText() -> String {
        prune()
        let formatter = ISO8601DateFormatter()
        var lines = ["StarWave Chat Diagnostics / 1", Self.buildSummary, "仅本次运行内存记录；不含正文、密文、密钥或凭据。引用和公钥均为截断 SHA256，不是会话密钥指纹。", "已丢弃最早记录：\(discardedCount)", "[当前快照]"]
        lines += snapshot.map { "\($0.label): \($0.value)" }
        lines.append("[事件]")
        for item in entries {
            lines.append("\(formatter.string(from: item.date)) [\(item.category.rawValue)] \(item.outcome.rawValue) \(item.event.rawValue) \(item.reason?.rawValue ?? "") x\(item.repetitions)")
            lines += item.fields.map { "  \($0.label): \($0.value)" }
        }
        return lines.joined(separator: "\n")
    }
}
