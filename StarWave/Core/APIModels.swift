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
        avatarURL = AppEnvironment.avatarURL(from: source["avatar"]?.stringValue ?? source["avatar_url"]?.stringValue)
    }

    var isAdministrator: Bool { role == "admin" || role == "super_admin" }
}

/// Rules returned by `/titles/catalog` for a user-created title.
/// The service owns the final validation and debit; this type only exposes its
/// advertised price and length limit for a transparent client-side estimate.
struct CustomTitleRules: Equatable {
    let pricePerCharacter: Int?
    let maximumLength: Int?

    init(json: JSONValue) {
        let root = json["data"] ?? json
        let source = root["custom"] ?? root
        pricePerCharacter = Self.integer(in: source, keys: ["price_per_char", "pricePerChar"])
        maximumLength = Self.integer(in: source, keys: ["max_len", "max_length", "maxLen"])
    }

    func estimatedCost(visibleCharacters: Int) -> Int? {
        guard let pricePerCharacter else { return nil }
        return max(0, visibleCharacters) * pricePerCharacter
    }

    private static func integer(in value: JSONValue, keys: [String]) -> Int? {
        for key in keys {
            if let number = Int(value[key]?.stringValue ?? "") { return number }
        }
        return nil
    }
}

struct RemoteItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let detail: String
    let raw: JSONValue

    init(json: JSONValue, index: Int) {
        raw = json
        func first(_ keys: [String]) -> String? { keys.compactMap { json[$0]?.stringValue }.first }
        id = first(["id", "post_id", "task_id", "item_id", "reward_id", "title_id", "season_id", "user_id"]) ?? "row-\(index)"

        let hours = first(["hours", "required_hours"])
        let requiredSeconds = first(["required_seconds"])
        let derivedRewardTitle = hours.map { "\($0) 小时奖励" } ?? requiredSeconds.map { "累计 \($0) 秒奖励" }
        title = first(["title", "name", "task_name", "nickname", "player_name", "item_name", "reward_name"])
            ?? derivedRewardTitle
            ?? first(["season_name", "label", "type", "username", "content"])
            ?? "项目 \(index + 1)"

        let coins = first(["coins"])
        let rewardCoins = first(["reward_coins"])
        let derivedRewardSubtitle = coins.map { "\($0) 喵币" } ?? rewardCoins.map { "奖励 \($0) 喵币" }
        subtitle = first(["description", "summary", "nickname", "player_name", "message", "progress", "rank"])
            ?? derivedRewardSubtitle
            ?? first(["author", "created_at", "status"])
            ?? ""
        detail = first(["content", "note", "updated_at"]) ?? subtitle
    }

    static func list(from value: JSONValue) -> [RemoteItem] {
        items(in: value).enumerated().map { RemoteItem(json: $0.element, index: $0.offset) }
    }

    private static func items(in value: JSONValue) -> [JSONValue] {
        if case let .array(items) = value { return items }
        guard case let .object(object) = value else { return [] }
        for key in ["data", "result", "items", "list", "posts", "tasks", "notifications", "polls", "seasons", "records", "rows", "rewards", "players", "rankings", "titles"] {
            if let nested = object[key], !items(in: nested).isEmpty { return items(in: nested) }
        }
        // The service has several feature-specific container keys. Prefer any
        // populated array before falling back to a single object.
        for nested in object.values {
            if case .array = nested, !items(in: nested).isEmpty { return items(in: nested) }
        }
        for nested in object.values {
            if case .object = nested, !items(in: nested).isEmpty { return items(in: nested) }
        }
        // A single real item is still useful; error envelopes are intentionally not shown as “项目 1”.
        if object["id"] != nil || object["title"] != nil || object["name"] != nil || object["username"] != nil || object["player_name"] != nil || object["item_name"] != nil || object["reward_name"] != nil {
            return [value]
        }
        return []
    }
}

struct ForumPostDetail: Equatable {
    let post: RemoteItem
    let replies: [RemoteItem]

    init?(json: JSONValue) {
        let source = json["data"] ?? json
        guard let postValue = source["post"] else { return nil }
        post = RemoteItem(json: postValue, index: 0)
        let replyValues = source["replies"]?.arrayValue ?? []
        replies = replyValues.enumerated().map { RemoteItem(json: $0.element, index: $0.offset) }
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
