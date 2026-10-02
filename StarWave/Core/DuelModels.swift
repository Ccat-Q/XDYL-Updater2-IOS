import Foundation

/// Server-authoritative data for the Minecraft duel arena.  The app only
/// presents and requests this state; teleportation and match settlement stay
/// on the game server.
struct DuelPlayer: Identifiable, Equatable {
    let id: String
    let name: String
    let rating: Int
    let tier: String
    let tierIndex: Int
    let wins: Int
    let losses: Int
    let matches: Int
    let rank: Int?
    let peakRating: Int?
    let avatarURL: URL?

    init(json: JSONValue, fallbackID: String = UUID().uuidString) {
        id = json["id"]?.stringValue ?? json["username"]?.stringValue ?? json["player"]?.stringValue ?? json["name"]?.stringValue ?? fallbackID
        name = json["name"]?.stringValue ?? json["nickname"]?.stringValue ?? json["username"]?.stringValue ?? json["player"]?.stringValue ?? "未知玩家"
        rating = Self.integer(json, "rating")
        tier = json["tier"]?.stringValue ?? "未定级"
        tierIndex = Self.integer(json, "tier_index")
        wins = Self.integer(json, "wins")
        losses = Self.integer(json, "losses")
        matches = Self.integer(json, "matches")
        rank = Self.optionalInteger(json, "rank", "rank_position")
        peakRating = Self.optionalInteger(json, "peak_rating")
        avatarURL = AppEnvironment.avatarURL(from: json["avatar"]?.stringValue ?? json["avatar_url"]?.stringValue)
    }

    private static func integer(_ json: JSONValue, _ key: String) -> Int { Int(json[key]?.stringValue ?? "") ?? 0 }
    private static func optionalInteger(_ json: JSONValue, _ keys: String...) -> Int? {
        keys.compactMap { Int(json[$0]?.stringValue ?? "") }.first
    }
}

struct DuelInvite: Identifiable, Equatable {
    let id: String
    let player: DuelPlayer
    let status: String
    let expiresIn: Int?
    let isIncoming: Bool

    init(json: JSONValue, isIncoming: Bool, index: Int) {
        id = json["invite_id"]?.stringValue ?? json["id"]?.stringValue ?? "invite-\(index)"
        player = DuelPlayer(json: json["player"] ?? json["from"] ?? json["opponent"] ?? json, fallbackID: id)
        status = json["status"]?.stringValue ?? "pending"
        expiresIn = Int(json["expires_in"]?.stringValue ?? json["remaining_seconds"]?.stringValue ?? "")
        self.isIncoming = isIncoming
    }
}

struct DuelRecentMatch: Identifiable, Equatable {
    let id: String
    let opponent: String
    let won: Bool?
    let ratingChange: Int?
    let ratingAfter: Int?
    let time: String

    init(json: JSONValue, index: Int) {
        id = json["id"]?.stringValue ?? json["match_id"]?.stringValue ?? "recent-\(index)"
        opponent = json["opponent"]?["name"]?.stringValue ?? json["opponent_name"]?.stringValue ?? json["opponent"]?.stringValue ?? "未知对手"
        let result = json["result"]?.stringValue?.lowercased() ?? json["status"]?.stringValue?.lowercased()
        won = result.map { ["win", "won", "胜"].contains($0) }
        ratingChange = Int(json["rating_change"]?.stringValue ?? json["delta"]?.stringValue ?? "")
        ratingAfter = Int(json["rating_after"]?.stringValue ?? json["my_rating_after"]?.stringValue ?? "")
        time = json["created_at"]?.stringValue ?? json["time"]?.stringValue ?? ""
    }
}

enum DuelMatchState: String, Equatable {
    case idle, searching, found, starts, expired, declined

    init(raw: String?) { self = DuelMatchState(rawValue: raw?.lowercased() ?? "") ?? .idle }

    var title: String {
        switch self {
        case .idle: return "未在匹配"
        case .searching: return "正在寻找对手"
        case .found: return "已找到对手，等待确认"
        case .starts: return "即将开始"
        case .expired: return "匹配已超时"
        case .declined: return "匹配已取消"
        }
    }
}

struct DuelMatch: Equatable {
    let state: DuelMatchState
    let account: String
    let timePreference: String
    let waitingSeconds: Int
    let expiresIn: Int
    let meConfirmed: Bool
    let opponentConfirmed: Bool
    let opponent: DuelPlayer?

    init(json: JSONValue) {
        let source = json["data"] ?? json
        state = DuelMatchState(raw: source["state"]?.stringValue)
        account = source["account"]?.stringValue ?? ""
        timePreference = source["time_pref"]?.stringValue ?? "day"
        waitingSeconds = Int(source["waiting_seconds"]?.stringValue ?? "") ?? 0
        expiresIn = Int(source["expires_in"]?.stringValue ?? "") ?? 0
        meConfirmed = source["me_confirmed"]?.boolValue ?? false
        opponentConfirmed = source["opponent_confirmed"]?.boolValue ?? false
        opponent = source["opponent"].map { DuelPlayer(json: $0) }
    }

    static let idle = DuelMatch(json: .object([:]))
    var isActive: Bool { state == .searching || state == .found }
}

enum DuelPayload {
    static func list(_ value: JSONValue, keys: [String]) -> [JSONValue] {
        let source = value["data"] ?? value
        for key in keys {
            if let candidate = source[key], !candidate.arrayValue.isEmpty { return candidate.arrayValue }
        }
        return source.arrayValue
    }

    static func accounts(_ value: JSONValue) -> [String] {
        list(value, keys: ["accounts", "players", "data"]).compactMap {
            $0.stringValue ?? $0["account"]?.stringValue ?? $0["name"]?.stringValue ?? $0["player_name"]?.stringValue
        }
    }

    static func recentMatches(_ value: JSONValue) -> [DuelRecentMatch] {
        let source = value["data"] ?? value
        let rows = ["recent", "recent_matches", "matches", "history"].compactMap { source[$0] }.first(where: { !$0.arrayValue.isEmpty })?.arrayValue ?? []
        return rows.enumerated().map { DuelRecentMatch(json: $0.element, index: $0.offset) }
    }

    static func invites(_ value: JSONValue) -> [DuelInvite] {
        let source = value["data"] ?? value
        var result: [DuelInvite] = []
        if let incoming = source["incoming"] ?? source["invites"] {
            result += incoming.arrayValue.enumerated().map { DuelInvite(json: $0.element, isIncoming: true, index: $0.offset) }
        }
        if let outgoing = source["outgoing"] ?? source["sent"] {
            result += outgoing.arrayValue.enumerated().map { DuelInvite(json: $0.element, isIncoming: false, index: $0.offset) }
        }
        if result.isEmpty {
            result = source.arrayValue.enumerated().map { DuelInvite(json: $0.element, isIncoming: true, index: $0.offset) }
        }
        return result
    }
}
