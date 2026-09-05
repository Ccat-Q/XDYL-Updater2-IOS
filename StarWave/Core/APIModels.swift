import Foundation

enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case let .object(value) = self else { return nil }
        return value[key]
    }

    var stringValue: String? {
        switch self {
        case let .string(value): return value
        case let .number(value): return value.rounded() == value ? String(Int(value)) : String(value)
        case let .bool(value): return value ? "true" : "false"
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case let .bool(value): return value
        case let .number(value): return value != 0
        case let .string(value): return ["true", "1", "yes"].contains(value.lowercased())
        default: return nil
        }
    }

    var arrayValue: [JSONValue] {
        if case let .array(value) = self { return value }
        return []
    }

    var objectValue: [String: JSONValue] {
        if case let .object(value) = self { return value }
        return [:]
    }

    var unwrappedPayload: JSONValue {
        for key in ["data", "result", "items", "list", "posts"] {
            if let value = self[key] { return value }
        }
        return self
    }
}

struct AuthTokens: Equatable {
    let accessToken: String
    let refreshToken: String?
    let username: String?

    init?(json: JSONValue) {
        let source = json["data"] ?? json
        guard let access = source["access_token"]?.stringValue ?? source["token"]?.stringValue else { return nil }
        accessToken = access
        refreshToken = source["refresh_token"]?.stringValue
        username = source["username"]?.stringValue ?? source["user"]?["username"]?.stringValue
    }
}

struct UserProfile: Equatable {
    var username: String
    var nickname: String
    var email: String
    var role: String
    var balance: String
    var qqNickname: String?
    var avatarURL: URL?

    init(json: JSONValue) {
        let source = json["data"] ?? json["profile"] ?? json
        username = source["username"]?.stringValue ?? "用户"
        nickname = source["nickname"]?.stringValue ?? username
        email = source["email"]?.stringValue ?? ""
        role = source["role"]?.stringValue ?? "user"
        balance = source["balance"]?.stringValue ?? source["coins"]?.stringValue ?? "0"
        qqNickname = source["qq_nickname"]?.stringValue
        avatarURL = (source["avatar"]?.stringValue ?? source["avatar_url"]?.stringValue).flatMap(URL.init(string:))
    }

    var isAdministrator: Bool { role == "admin" || role == "super_admin" }
}

struct RemoteItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let detail: String
    let raw: JSONValue

    init(json: JSONValue, index: Int) {
        raw = json
        id = json["id"]?.stringValue ?? json["post_id"]?.stringValue ?? json["task_id"]?.stringValue ?? "row-\(index)"
        title = json["title"]?.stringValue
            ?? json["name"]?.stringValue
            ?? json["username"]?.stringValue
            ?? json["content"]?.stringValue
            ?? "项目 \(index + 1)"
        subtitle = json["description"]?.stringValue
            ?? json["summary"]?.stringValue
            ?? json["author"]?.stringValue
            ?? json["status"]?.stringValue
            ?? ""
        detail = json["content"]?.stringValue
            ?? json["note"]?.stringValue
            ?? json["updated_at"]?.stringValue
            ?? subtitle
    }

    static func list(from value: JSONValue) -> [RemoteItem] {
        let payload = value.unwrappedPayload
        if case let .array(items) = payload {
            return items.enumerated().map { RemoteItem(json: $0.element, index: $0.offset) }
        }
        if case let .object(object) = payload {
            for key in ["items", "list", "posts", "tasks", "notifications", "polls", "seasons"] {
                if case let .array(items)? = object[key] {
                    return items.enumerated().map { RemoteItem(json: $0.element, index: $0.offset) }
                }
            }
            return [RemoteItem(json: payload, index: 0)]
        }
        return []
    }
}

struct GitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name; case browserDownloadURL = "browser_download_url" }
    }
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", name, body, assets
        case htmlURL = "html_url"
    }
}

