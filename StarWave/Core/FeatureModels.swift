import Foundation

extension JSONValue {
    var payload: JSONValue { self["data"] ?? self }
    var integer: Int? { stringValue.flatMap(Int.init) }
    var double: Double? { stringValue.flatMap(Double.init) }
    static func identifier(_ value: String) -> JSONValue {
        if let number = Double(value), number.isFinite { return .number(number) }
        return .string(value)
    }
    func rows(_ keys: String...) -> [JSONValue] {
        let source = payload
        if case let .array(rows) = source { return rows }
        for key in keys { if case let .array(rows)? = source[key] { return rows } }
        return []
    }
}

enum APIResponse {
    static func validate(status: Int, json: JSONValue?, allowQQBinding: Bool = false) throws {
        let source = json?.payload
        if allowQQBinding, (status == 302 || 200..<300 ~= status), (source?["temp_token"]?.stringValue ?? json?["temp_token"]?.stringValue) != nil { return }
        let message = json?["message"]?.stringValue ?? json?["detail"]?.stringValue ?? json?["error"]?.stringValue ?? ""
        guard 200..<300 ~= status else { throw AppError.server(status: status, message: message) }
        if let code = json?["code"]?.integer, !(200..<300 ~= code) {
            throw AppError.server(status: code, message: message)
        }
    }
}

enum QQLoginState: Equatable {
    case waiting
    case authenticated(AuthTokens)
    case needsBinding(token: String, nickname: String)

    init(json: JSONValue) {
        let source = json.payload
        if let token = source["temp_token"]?.stringValue ?? json["temp_token"]?.stringValue, !token.isEmpty {
            self = .needsBinding(token: token, nickname: source["qq_nickname"]?.stringValue ?? json["qq_nickname"]?.stringValue ?? "QQ 用户")
        } else if let tokens = AuthTokens(json: json) { self = .authenticated(tokens) }
        else { self = .waiting }
    }
}

struct GameBinding: Identifiable {
    let id: String
    let name: String
    let uuid: String
    let online: Bool
    init(json: JSONValue) {
        name = json["game_name"]?.stringValue ?? json["name"]?.stringValue ?? json.stringValue ?? ""
        id = json["id"]?.stringValue ?? name
        uuid = json["uuid"]?.stringValue ?? ""
        online = json["online"]?.boolValue ?? false
    }
}

struct PollOption: Identifiable {
    let id: String
    let name: String
    let votes: Int
    init(json: JSONValue) { id = json["id"]?.stringValue ?? ""; name = json["name"]?.stringValue ?? ""; votes = json["votes"]?.integer ?? 0 }
}

struct Poll: Identifiable {
    let id: String
    let title: String
    let description: String
    let endTime: String
    let myVote: String?
    let totalVotes: Int
    let isActive: Bool
    let options: [PollOption]
    init(json: JSONValue) {
        id = json["id"]?.stringValue ?? ""
        title = json["title"]?.stringValue ?? "投票"
        description = json["description"]?.stringValue ?? ""
        endTime = json["end_time"]?.stringValue ?? ""
        myVote = json["my_vote"]?.stringValue
        totalVotes = json["total_votes"]?.integer ?? 0
        isActive = json["is_active"]?.boolValue ?? !["ended", "closed", "finished"].contains(json["status"]?.stringValue ?? "")
        options = (json["options"]?.arrayValue ?? []).map { PollOption(json: $0) }.filter { !$0.id.isEmpty }
    }
}

struct PlaytimeMilestone: Identifiable {
    let hours: Double
    let coins: Int
    let experience: Int
    let claimed: Bool
    let claimable: Bool
    var id: Double { hours }
    init?(json: JSONValue) {
        guard let hours = json["hours"]?.double, hours > 0 else { return nil }
        self.hours = hours
        coins = json["coins"]?.integer ?? 0
        experience = json["exp"]?.integer ?? 0
        claimed = json["claimed"]?.boolValue ?? false
        claimable = !claimed && (json["claimable"]?.boolValue ?? false)
    }
}

struct MarketItem: Identifiable {
    let id: String
    let name: String
    let englishName: String
    let buy: Double?
    let sell: Double?
    let price: Double?
    let operations: Int?
    let change: String
    let iconData: Data?
    let iconURL: URL?
    init(json: JSONValue) {
        id = json["identifier"]?.stringValue ?? json["id"]?.stringValue ?? ""
        name = json["name"]?.stringValue ?? json["title"]?.stringValue ?? id
        englishName = json["name_en"]?.stringValue ?? json["en"]?.stringValue ?? ""
        buy = json["buy"]?.double ?? json["price"]?.double
        sell = json["sell"]?.double
        price = json["price"]?.double
        operations = json["ops"]?.integer
        change = json["change"]?.stringValue ?? ""
        let raw = json["icon_b64"]?.stringValue ?? ""
        iconData = Data(base64Encoded: raw.components(separatedBy: ",").last ?? raw, options: .ignoreUnknownCharacters)
        iconURL = ContentURLs.resolve(json["icon"]?.stringValue)
    }
}

struct MarketPoint: Identifiable {
    let id: Int
    let value: Double
    let label: String
    init?(json: JSONValue, index: Int) {
        guard let value = json["value"]?.double ?? json["price"]?.double ?? json.double else { return nil }
        id = index; self.value = value
        if let seconds = json["time"]?.double ?? json["timestamp"]?.double {
            label = Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
        } else { label = json["time"]?.stringValue ?? json["timestamp"]?.stringValue ?? json["created_at"]?.stringValue ?? "\(index + 1)" }
    }
}

struct RedeemCode: Identifiable {
    let id: String
    let code: String
    let name: String
    let used: Bool
    let created: String
    init(json: JSONValue, index: Int) {
        code = json["code"]?.stringValue ?? json["redeem_code"]?.stringValue ?? json["code_text"]?.stringValue ?? ""
        id = json["id"]?.stringValue ?? (code.isEmpty ? "code-\(index)" : code)
        name = json["item_name"]?.stringValue ?? json["name"]?.stringValue ?? json["title"]?.stringValue ?? "兑换码"
        used = json["used"]?.boolValue ?? ["used", "claimed", "redeemed"].contains(json["status"]?.stringValue ?? json["state"]?.stringValue ?? "")
        created = json["created_at"]?.stringValue ?? json["created_time"]?.stringValue ?? json["time"]?.stringValue ?? ""
    }
}

enum TitleValidation {
    static func error(for title: String, maxVisible: Int?) -> String? {
        let visible = TitleColor.removingTokens(from: title)
        if visible.isEmpty { return "称号不能为空" }
        if title.utf16.count > 64 { return "含颜色代码最多 64 个字符" }
        if let limit = maxVisible, visible.utf16.count > limit { return "称号最多 \(limit) 个可见字符" }
        if visible.range(of: #"^[\u4e00-\u9fa5A-Za-z0-9_·×]+$"#, options: .regularExpression) == nil { return "仅支持中文、字母、数字、_、·、× 和有效颜色代码" }
        return nil
    }
}
