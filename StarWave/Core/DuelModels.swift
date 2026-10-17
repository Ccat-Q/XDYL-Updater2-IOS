import Foundation

/// Server-authoritative data for the Minecraft duel arena.  The app only
/// presents and requests this state; teleportation and match settlement stay
/// on the game server.
struct DuelPlayer: Identifiable, Equatable {
    let id: String
    let name: String
    /// Display names are not necessarily Minecraft account identifiers.
    let gameName: String
    let username: String?
    let rating: Int
    let tier: String
    let tierIndex: Int
    let wins: Int
    let losses: Int
    let matches: Int
    let rank: Int?
    let peakRating: Int?
    let avatarURL: URL?
    let streak: Int
    let totalPlayers: Int?
    let nextTier: String?
    let nextTierNeed: Int?

    init(json: JSONValue, fallbackID: String = UUID().uuidString) {
        id = json["id"]?.stringValue ?? json["username"]?.stringValue ?? json["player"]?.stringValue ?? json["name"]?.stringValue ?? fallbackID
        name = json["name"]?.stringValue ?? json["nickname"]?.stringValue ?? json["username"]?.stringValue ?? json["player"]?.stringValue ?? "未知玩家"
        let account = json["game_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        gameName = account.isEmpty ? name : account
        username = json.firstNonemptyString("username")
        rating = Self.integer(json, "rating")
        tier = json["tier"]?.stringValue ?? "未定级"
        tierIndex = Self.integer(json, "tier_index")
        wins = Self.integer(json, "wins")
        losses = Self.integer(json, "losses")
        matches = Self.integer(json, "matches")
        rank = Self.optionalInteger(json, "rank", "rank_position")
        peakRating = Self.optionalInteger(json, "peak_rating")
        avatarURL = AppEnvironment.avatarURL(from: json["avatar"]?.stringValue ?? json["avatar_url"]?.stringValue)
        streak = Self.integer(json, "streak")
        totalPlayers = Self.optionalInteger(json, "total_players")
        nextTier = json["next_tier"]?["tier"]?.stringValue
        nextTierNeed = json["next_tier"]?["need"]?.integer
    }

    var streakText: String {
        if streak > 0 { return "连胜 \(streak)" }
        if streak < 0 { return "连败 \(streak.magnitude)" }
        return "暂无连胜或连败"
    }

    var challengeFields: [String: JSONValue] { ["target": .string(gameName)] }

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
    let expiresAt: Date?

    init(json: JSONValue, isIncoming: Bool, index: Int) {
        id = json["invite_id"]?.stringValue ?? json["id"]?.stringValue ?? "invite-\(index)"
        let prefix = isIncoming ? "from" : "to"
        var fields = json.objectValue
        for key in ["name", "game_name", "username", "rating", "tier", "wins", "losses", "matches", "avatar", "streak"] {
            if let value = json["\(prefix)_\(key)"] { fields[key] = value }
        }
        player = DuelPlayer(json: json["player"] ?? json["from"] ?? json["opponent"] ?? .object(fields), fallbackID: id)
        status = json["status"]?.stringValue ?? "pending"
        expiresIn = Int(json["expires_in"]?.stringValue ?? json["remaining_seconds"]?.stringValue ?? "")
        self.isIncoming = isIncoming
        expiresAt = DateParsing.parse(json["expires_at"]?.stringValue)
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
        won = json["win"]?.boolValue ?? result.flatMap { ["win", "won", "胜"].contains($0) ? true : (["loss", "lost", "负"].contains($0) ? false : nil) }
        ratingChange = Int(json["rating_change"]?.stringValue ?? json["delta"]?.stringValue ?? "")
        ratingAfter = Int(json["rating_after"]?.stringValue ?? json["my_rating_after"]?.stringValue ?? "")
        time = json["reported_at"]?.stringValue ?? json["created_at"]?.stringValue ?? json["time"]?.stringValue ?? ""
    }
}

enum DuelMatchState: String, Equatable {
    case idle, searching, found, starts, expired, declined, unknown

    init(raw: String?) { self = DuelMatchState(rawValue: raw?.lowercased() ?? "") ?? .unknown }

    // Windows treats starts as a completed queue, not an active queue lock.
    var permitsJoin: Bool { [DuelMatchState.idle, .starts, .expired, .declined].contains(self) }
    var shouldPoll: Bool { [DuelMatchState.searching, .found, .starts].contains(self) }

    var title: String {
        switch self {
        case .idle: return "未在匹配"
        case .searching: return "正在寻找对手"
        case .found: return "已找到对手，等待确认"
        case .starts: return "即将开始"
        case .expired: return "匹配已超时"
        case .declined: return "匹配已取消"
        case .unknown: return "状态暂不可用，请刷新"
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
        let preference = source["time_pref"]?.stringValue ?? "day"
        timePreference = ["day", "night", "random"].contains(preference) ? preference : "day"
        waitingSeconds = Int(source["waiting_seconds"]?.stringValue ?? "") ?? 0
        expiresIn = Int(source["expires_in"]?.stringValue ?? "") ?? 0
        meConfirmed = source["me_confirmed"]?.boolValue ?? false
        opponentConfirmed = source["opponent_confirmed"]?.boolValue ?? false
        opponent = source["opponent"].map { DuelPlayer(json: $0) }
    }

    static let idle = DuelMatch(json: .object(["state": .string("idle")]))
    var isActive: Bool { state == .searching || state == .found }

    func restoredSelection(account: String, timePreference: String) -> (account: String, timePreference: String) {
        guard isActive else { return (account, timePreference) }
        return (self.account.isEmpty ? account : self.account, self.timePreference)
    }
}

/// A late response may update only its original page flow, login session and
/// endpoint revision. Kept independent of SwiftUI so response races are testable.
struct DuelResponseGate {
    struct Ticket: Equatable {
        fileprivate let flow: UUID
        fileprivate let session: UUID
        fileprivate let channel: String
        fileprivate let revision: Int
    }

    private(set) var flow = UUID()
    private var revisions: [String: Int] = [:]

    mutating func invalidate() {
        flow = UUID()
        revisions.removeAll()
    }

    mutating func begin(_ channel: String, session: UUID) -> Ticket {
        let revision = (revisions[channel] ?? 0) + 1
        revisions[channel] = revision
        return Ticket(flow: flow, session: session, channel: channel, revision: revision)
    }

    func accepts(_ ticket: Ticket, session: UUID, cancelled: Bool = false) -> Bool {
        !cancelled && ticket.flow == flow && ticket.session == session && revisions[ticket.channel] == ticket.revision
    }
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
            $0.stringValue ?? $0["game_name"]?.stringValue ?? $0["account"]?.stringValue ?? $0["name"]?.stringValue ?? $0["player_name"]?.stringValue
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

enum DateParsing {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: value) { return date }
        let sql = DateFormatter(); sql.locale = Locale(identifier: "en_US_POSIX"); sql.timeZone = TimeZone(secondsFromGMT: 0); sql.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sql.date(from: value)
    }
}
