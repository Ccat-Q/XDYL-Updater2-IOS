import Foundation
import CoreGraphics

enum ChatFailure: LocalizedError, Equatable {
    case invalid(String)
    case service(Int, String, Int?)
    case keyChanged(String)
    case storage

    var errorDescription: String? {
        switch self {
        case .invalid(let value): return value
        case .storage: return "聊天记录保存失败，未推进同步位置，请重试。"
        case .keyChanged: return "对方的设备或密钥已变化，请核对指纹后重新信任。"
        case .service(_, let code, _):
            switch code {
            case "SESSION_EXPIRED", "UNAUTHORIZED": return "聊天授权已过期，请重新连接。"
            case "DEVICE_REVOKED": return "此聊天设备已撤销，请在设置中明确创建新设备。"
            case "CURSOR_EXPIRED": return "同步位置已过期；保留本地历史后，可确认重新同步。"
            case "KEYSET_CHANGED": return "设备密钥已变化，本次发送未接受。请核对密钥后重新发送。"
            case "DELIVERY_NOT_ALLOWED", "DELIVERY_OR_KEY_CONFLICT": return "暂时无法发送：对方可能限制了接收，或设备密钥已变化。"
            case "LEGACY_ACCOUNT_ALREADY_IN_USE", "LEGACY_IDENTITY_ALREADY_BOUND": return "此账号已使用其他旧协议密钥或主设备，不能直接覆盖。"
            case "LEGACY_PRIMARY_DEVICE_REQUIRED": return "请先在聊天设置中明确启用本机为旧安卓兼容主设备。"
            case "HISTORY_NOT_CONFIGURED": return "服务器尚未启用加密历史存储。"
            case "RATE_LIMITED": return "请求过于频繁，请按服务器要求稍后重试。"
            case "USER_NOT_FOUND": return "尚未找到聊天账号，请确认用户名，并让对方先启用聊天。"
            case "NO_ACTIVE_DEVICE": return "对方尚未登记可接收消息的设备。"
            case "RECALL_WINDOW_EXPIRED": return "已超过十分钟撤回期限。"
            case "FILTER_CHANGED": return "删除记录已变化，请重新读取过滤规则后恢复。"
            case "PACK_EXPIRED": return "加密恢复包已过期或已取消。"
            case "REVISION_CONFLICT": return "设置已在其他设备变化，请刷新后重新保存。"
            default: return "聊天请求失败（\(code)），请重试或检查设置。"
            }
        }
    }
    var code: String? { if case .service(_, let code, _) = self { return code }; return nil }
}

enum ChatProtocolMode: String, Codable, CaseIterable, Identifiable {
    case automatic, native, legacy
    var id: String { rawValue }
    var title: String { switch self { case .automatic: return "自动（优先 V2）"; case .native: return "新版 V2"; case .legacy: return "旧安卓兼容" } }
}

struct ChatPeer: Codable, Hashable, Identifiable {
    var subject: String
    var username: String
    var note = ""
    var mode: ChatProtocolMode = .automatic
    var fingerprint = ""
    var trustedKeys: [String: String] = [:]
    // Older clients also pinned unverified keys extracted from message bodies.
    // Those pins must be explicitly reverified before they can decrypt again.
    var trustVersion: Int? = nil
    var id: String { subject }
    var title: String { note.isEmpty ? username : note }
}

struct ChatConversation: Codable, Identifiable, Hashable {
    var id: String
    var peerSubject: String
    var peerUsername: String
    var pinned: Bool
    var archived: Bool
    var lastSequence: String
    var unread: Int
    var availableUnread: Int
    var historyGap: Bool
    var revision: String

    init(_ json: JSONValue) throws {
        id = try json.chatString("conversation_id")
        peerSubject = try json.chatString("peer_subject")
        peerUsername = json["peer_username"]?.stringValue ?? peerSubject
        pinned = json["pinned"]?.boolValue ?? false
        archived = json["archived"]?.boolValue ?? false
        lastSequence = try json.chatSequence("last_seq")
        unread = json["unread_total"]?.integer ?? 0
        availableUnread = json["unread_available"]?.integer ?? 0
        historyGap = json["history_gap"]?.boolValue ?? false
        revision = try json.chatSequence("revision")
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: String
    var clientID: String
    var conversationID: String
    var sequence: String
    var sender: String
    var recipient: String
    var text: String?
    var problem: String?
    var acceptedAt: Int64
    var status: String
    var raw: JSONValue?
    var peerSubject: String
    var hasServerSequence: Bool { !id.hasPrefix("pending:") && UUID(uuidString: id) != nil && (Int64(sequence) ?? 0) > 0 && status != "pending" }
    mutating func associateLegacySend(owner: String, deviceID: String) {
        guard sender == owner, hasServerSequence, raw?["sender_device_id"]?.stringValue == deviceID,
              raw?["envelope"]?["protocol"]?.stringValue == "nu-chat-v1" else { return }
        let prefix = "v2:" + deviceID + ":"
        guard clientID.hasPrefix(prefix) else { return }
        let suffix = String(clientID.dropFirst(prefix.count))
        guard UUID(uuidString: suffix) != nil else { return }
        clientID = suffix // raw retains the wire identity; V2 AAD is never changed.
    }
    var date: Date { Date(timeIntervalSince1970: Double(acceptedAt) / 1000) }
    var stateTitle: String {
        switch status { case "pending": return "待重试"; case "accepted_waiting_sync": return "服务端已接受 · 待同步"; case "accepted": return "服务端已接受"; case "received": return "对方设备已接收"; case "read": return "对方已读"; case "recalled": return "消息已撤回"; case "hidden": return "消息不可用"; case "incoming": return ""; default: return "待同步" }
    }
}

struct ChatPendingSend: Codable, Identifiable {
    let id: String
    let peerSubject: String
    let path: String
    let body: JSONValue
    var message: ChatMessage
    func isAccepted(by accepted: ChatMessage) -> Bool {
        guard accepted.hasServerSequence, accepted.clientID == id, accepted.sender == message.sender,
              accepted.recipient == message.recipient, accepted.peerSubject == peerSubject else { return false }
        if path == "/chat/v2/legacy/messages" {
            return accepted.raw?["envelope"]?["protocol"]?.stringValue == "nu-chat-v1"
                && accepted.raw?["envelope"]?["cipher"] == body["cipher"]
                && accepted.raw?["envelope"]?["own_key_id"] == body["sender_key_id"]
        }
        return path == "/chat/v2/messages"
    }
}

enum ChatVisibleRead {
    static func latest(_ messages: [ChatMessage], frames: [String: CGRect], viewport: CGSize, owner: String?, after: Int64, enabled: Bool) -> ChatMessage? {
        guard enabled else { return nil }
        let area = CGRect(origin: .zero, size: viewport)
        return messages.filter {
            $0.recipient == owner && $0.hasServerSequence && $0.text != nil && $0.problem == nil && $0.status == "incoming"
                && (Int64($0.sequence) ?? 0) > after && (frames[$0.id]?.intersection(area).height ?? 0) > 16
        }.max { (Int64($0.sequence) ?? 0) < (Int64($1.sequence) ?? 0) }
    }
}

struct ChatCapabilities {
    let features: Set<String>
    init(_ json: JSONValue) throws {
        guard json["protocol"]?.stringValue == "nu-chat-v2", json["version"]?.integer == 2 else { throw ChatFailure.invalid("中继不支持本客户端所需的 V2 协议，未降级发送。") }
        features = Set(json["features"]?.arrayValue.compactMap(\.stringValue) ?? [])
        guard Set(["cursor_sync", "idempotent_send", "device_keys", "conversations"]).isSubset(of: features) else { throw ChatFailure.invalid("中继缺少可靠同步或设备能力，已停止连接。") }
    }
}

struct ChatDeviceKeys {
    let id: String
    let revision: String
    let keys: [ChatPublicKey]
}
struct ChatPublicKey: Codable, Hashable {
    var keyID: String
    var algorithm: String
    var publicKey: String
    var json: JSONValue { .object(["key_id": .string(keyID), "algorithm": .string(algorithm), "public_key": .string(publicKey)]) }
    init(keyID: String, algorithm: String, publicKey: String) { self.keyID = keyID; self.algorithm = algorithm; self.publicKey = publicKey }
    init(_ value: JSONValue) throws { keyID = try value.chatString("key_id"); algorithm = try value.chatString("algorithm"); publicKey = try value.chatString("public_key") }
}
struct ChatKeyBundle {
    let subject: String
    let revision: String
    let devices: [ChatDeviceKeys]
    init(_ value: JSONValue) throws {
        subject = try value.chatString("subject"); revision = try value.chatSequence("keyset_revision")
        devices = try value["devices"].chatArray().map { d in
            ChatDeviceKeys(id: try d.chatString("device_id"), revision: try d.chatSequence("key_revision"), keys: try d["keys"].chatArray().map(ChatPublicKey.init))
        }
    }
}

extension JSONValue {
    func chatString(_ key: String) throws -> String {
        guard case .string(let result)? = self[key], !result.isEmpty else { throw ChatFailure.invalid("聊天响应缺少有效的 \(key)。") }; return result
    }
    func chatSequence(_ key: String) throws -> String {
        let result = try chatString(key)
        guard !result.isEmpty, result.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int64(result), value >= 0 else { throw ChatFailure.invalid("聊天顺序号无效。") }
        return result
    }
    func chatInt64(_ key: String) throws -> Int64 {
        guard let value = self[key]?.stringValue, let number = Int64(value), number >= 0 else { throw ChatFailure.invalid("聊天时间无效。") }; return number
    }
    static func chatObject(_ fields: [String: String]) -> JSONValue { .object(fields.mapValues(JSONValue.string)) }
}
extension Optional where Wrapped == JSONValue {
    func chatArray() throws -> [JSONValue] {
        guard case .array(let result)? = self else { throw ChatFailure.invalid("聊天响应列表无效。") }; return result
    }
}

enum ChatValidation {
    static let defaultRelay = "https://nu-pe-chat.cc.cd"
    static func relay(_ value: String) throws -> URL {
        guard let c = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.port == nil || c.port == 443,
              c.path.isEmpty || c.path == "/", let result = URL(string: "https://\(host.lowercased())\(c.port == 443 ? ":443" : "")") else { throw ChatFailure.invalid("聊天中继必须是无路径、无账号参数的 HTTPS 地址。") }
        return result
    }
    static func username(_ value: String) throws -> String {
        guard value.range(of: #"^[A-Za-z0-9_.-]{1,64}$"#, options: .regularExpression) != nil, value != ".", value != ".." else { throw ChatFailure.invalid("请输入账号用户名，不能使用昵称。") }; return value
    }
    static func segment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? "" }
    static func plaintext(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 16384 else { throw ChatFailure.invalid("请输入文字，最多 16 KiB（按 UTF-8 字节计）。") }
    }
}
