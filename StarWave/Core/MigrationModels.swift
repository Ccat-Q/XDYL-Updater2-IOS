import Foundation
import Combine

extension JSONValue {
    func firstNonemptyString(_ keys: String...) -> String? {
        keys.compactMap { self[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}

/// /player/info is not /user/profile: registration and Minecraft playtime have
/// different meanings. Missing states stay unknown rather than becoming false.
struct PublicPlayerProfile {
    let name: String
    let username: String?
    let nickname: String
    let registered: Bool?
    let online: Bool?
    let banned: Bool?
    let seconds: Int?
    let coins: String?
    let lastLogin: String?
    let avatarURL: URL?
    let bio: String?
    let title: String?
    let level: Int?
    let experience: Int?
    let points: Int?

    init(json: JSONValue, player: String) {
        let source = json.payload
        name = player
        username = source.firstNonemptyString("username")
        nickname = source.firstNonemptyString("nickname", "name") ?? player
        registered = source["registered"]?.boolValue
        online = source["online"]?.boolValue
        banned = source["banned"]?.boolValue
        seconds = source["seconds"]?.integer ?? source["playtime"]?.integer
        coins = source.firstNonemptyString("coins", "balance")
        lastLogin = DisplayFormat.timestamp(source["last_login"])
        avatarURL = AppEnvironment.avatarURL(from: source.firstNonemptyString("avatar", "avatar_url"))
        bio = source.firstNonemptyString("bio")
        title = source.firstNonemptyString("title")
        level = source["level"]?.integer
        experience = source["exp"]?.integer
        points = source["points"]?.integer
    }
}

enum DisplayFormat {
    static func duration(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分钟"
    }

    static func timestamp(_ value: JSONValue?) -> String? {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let seconds = Double(raw), seconds.isFinite {
            guard seconds > 0, seconds < 253_402_300_800_000 else { return nil }
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds).formatted(date: .abbreviated, time: .shortened)
        }
        return DateParsing.parse(raw)?.formatted(date: .abbreviated, time: .shortened) ?? raw
    }

    static func suggestionStatus(_ raw: String) -> String {
        switch raw.lowercased() {
        case "new": return "待查看"
        case "read": return "已查看"
        case "done": return "已处理"
        default: return raw
        }
    }
}

struct ServerSnapshot {
    struct Player: Identifiable {
        let name: String
        var id: String { name }
    }
    let name: String
    let count: Int
    let players: [Player]

    init(json: JSONValue) {
        let source = json.payload
        name = source.firstNonemptyString("server_name", "server") ?? json.firstNonemptyString("server_name", "server") ?? "游戏服务器"
        var seen = Set<String>()
        players = source.rows("players").compactMap {
            let name = $0.firstNonemptyString("name", "player_name", "username") ?? $0.stringValue
            guard let name, !name.isEmpty, seen.insert(name).inserted else { return nil }
            return Player(name: name)
        }
        count = max(0, source["count"]?.integer ?? json["count"]?.integer ?? players.count)
    }
}

struct Season: Identifiable {
    let id: String
    let name: String
    let active: Bool?
    let start: String?
    let end: String?
    let players: Int?
    let mySeconds: Int?
    let description: String

    init(json: JSONValue, index: Int) {
        id = json.firstNonemptyString("id", "season_id") ?? "season-\(index)"
        name = json.firstNonemptyString("name", "season_name", "title") ?? "周目 \(index + 1)"
        active = json["is_active"]?.boolValue
        start = DisplayFormat.timestamp(json["start_time"])
        end = DisplayFormat.timestamp(json["end_time"])
        players = json["players_count"]?.integer
        mySeconds = json["my_playtime"]?.integer
        description = json.firstNonemptyString("description", "content") ?? ""
    }

    var stateText: String { active.map { $0 ? "进行中" : "已结束" } ?? "状态未知" }
}

struct TitleDeliveryResult {
    enum Operation { case purchase, wear }
    let message: String
    let delivered: Bool?

    init(json: JSONValue, operation: Operation) {
        let field = operation == .purchase ? "granted_in_game" : "granted"
        delivered = json.payload[field]?.boolValue ?? json[field]?.boolValue
        var lines = [operation == .purchase ? "称号购买成功" : "称号佩戴成功"]
        if let server = json.firstNonemptyString("message") ?? json.payload.firstNonemptyString("message") { lines.append(server) }
        if let coins = json.payload.firstNonemptyString("new_coins") ?? json.firstNonemptyString("new_coins") { lines.append("剩余喵币：\(coins)") }
        if delivered == true { lines.append("已同步发放到游戏内。") }
        else if delivered == false {
            lines.append(operation == .purchase ? "游戏内发放暂未送达，请联系管理员补发；不要重复购买。" : "游戏内同步暂未送达，稍后自动补发；无需重复付费。")
        } else { lines.append("服务端未返回游戏内送达状态，可进入游戏核对。") }
        message = lines.joined(separator: "\n")
    }
}

struct ShopPurchaseResult: Identifiable {
    let id = UUID()
    let item: String
    let code: String?
    let message: String

    init(json: JSONValue, item: String) {
        self.item = item
        // Envelope `code:200` is a business status, never a redeem credential.
        let source = json["data"] ?? json
        code = PaymentText.redeemCode(in: json)
        message = json.firstNonemptyString("message") ?? source.firstNonemptyString("message") ?? "购买成功"
    }
}

@MainActor
final class PackVersionStore: ObservableObject {
    static let shared = PackVersionStore()
    @Published private(set) var acknowledged: [String: String]
    private let defaults: UserDefaults
    private let key = "resources.acknowledgedVersions.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        acknowledged = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func needsAcknowledgement(version: String, kind: String = "pack_zip") -> Bool {
        !version.isEmpty && acknowledged[kind] != version
    }

    func acknowledge(version: String, kind: String = "pack_zip") {
        guard !version.isEmpty else { return }
        acknowledged[kind] = version
        defaults.set(acknowledged, forKey: key)
    }
}
