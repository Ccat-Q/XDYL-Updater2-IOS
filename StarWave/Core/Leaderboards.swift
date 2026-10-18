import Foundation
import Combine

enum LeaderboardMetric: String {
    case coins, playtime
    var path: String { "/rank/\(rawValue)" }
    var title: String { self == .coins ? "喵币排行" : "在线排行" }
}

enum LeaderboardSource: String, CaseIterable, Identifiable {
    case server, profile
    var id: String { rawValue }
    var title: String { self == .server ? "原始榜单" : "个人主页" }
}

struct LeaderboardEntry: Identifiable {
    let rank: Int
    let name: String
    let username: String?
    let avatarURL: URL?
    let coins: Int?
    let seconds: Int?
    let playerName: String?

    var id: String { "\(rank)-\(username ?? playerName ?? name)" }
    // Nicknames are display text, not a safe identifier for profile lookups.
    var profileLookup: String? { username ?? playerName }

    static func list(from value: JSONValue) -> [LeaderboardEntry] {
        value.rows("rankings", "players", "items").enumerated().compactMap { index, entry in
            guard let name = entry.firstNonemptyString("nickname", "player_name", "username") else { return nil }
            return LeaderboardEntry(
                rank: entry["rank"]?.integer ?? index + 1, name: name,
                username: entry.firstNonemptyString("username"),
                avatarURL: AppEnvironment.avatarURL(from: entry.firstNonemptyString("avatar")),
                coins: entry["coins"]?.integer, seconds: entry["seconds"]?.integer,
                playerName: entry.firstNonemptyString("player_name")
            )
        }.sorted { $0.rank < $1.rank }
    }
}

struct ProfileRankRecord {
    let candidate: LeaderboardEntry
    let profile: PublicPlayerProfile?
    let error: String?

    var identity: String {
        if let username = profile?.username ?? candidate.username { return "user:\(username)" }
        return "player:\(candidate.playerName ?? candidate.id)"
    }

    func value(for metric: LeaderboardMetric) -> Decimal? {
        guard let profile else { return nil }
        switch metric {
        case .coins:
            guard profile.registered != false, let raw = profile.coins else { return nil }
            // Decimal avoids lexicographical ordering or rounding currency to Int.
            guard raw.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
                  !value.isNaN else { return nil }
            return value
        case .playtime:
            guard let seconds = profile.seconds, seconds >= 0 else { return nil }
            return Decimal(seconds)
        }
    }

    func unavailableReason(for metric: LeaderboardMetric) -> String {
        if let error { return error }
        if metric == .coins, profile?.registered == false { return "未注册，未提供账户余额" }
        return metric == .coins ? "主页未提供有效余额" : "主页未提供有效游玩时长"
    }
}

struct ProfileRankEntry: Identifiable {
    let record: ProfileRankRecord
    let rank: Int?
    let value: Decimal?
    var id: String { record.identity }

    static func sorted(_ records: [ProfileRankRecord], metric: LeaderboardMetric) -> [ProfileRankEntry] {
        // Prefer a successful response over a failed alias. Otherwise keep the
        // first lookup (community username candidates precede game aliases).
        var unique: [ProfileRankRecord] = []
        for record in records {
            if let index = unique.firstIndex(where: { $0.identity == record.identity }) {
                if unique[index].value(for: metric) == nil, record.value(for: metric) != nil { unique[index] = record }
            } else { unique.append(record) }
        }
        let ordered = unique.enumerated().sorted { lhs, rhs in
            switch (lhs.element.value(for: metric), rhs.element.value(for: metric)) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }
        var previous: Decimal?
        var rank = 0
        return ordered.enumerated().map { index, pair in
            let value = pair.element.value(for: metric)
            if let value, previous != value { rank = index + 1 }
            previous = value
            return ProfileRankEntry(record: pair.element, rank: value == nil ? nil : rank, value: value)
        }
    }
}

@MainActor
final class LeaderboardStore: ObservableObject {
    @Published private(set) var serverEntries: [LeaderboardEntry] = []
    @Published private(set) var profileEntries: [ProfileRankEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var error: String?
    @Published private(set) var warning: String?
    private var revision = UUID()

    func invalidate() {
        revision = UUID()
        serverEntries = []; profileEntries = []
        isLoading = false; completed = 0; total = 0; error = nil; warning = nil
    }

    func load(metric: LeaderboardMetric, source: LeaderboardSource, api: APIClient, sessionStore: SessionStore) async {
        guard !Task.isCancelled else { return }
        invalidate()
        let ticket = revision, generation = sessionStore.generation
        @MainActor func check() throws {
            try Task.checkCancellation()
            guard ticket == revision, generation == sessionStore.generation else { throw CancellationError() }
        }
        isLoading = true
        defer { if ticket == revision { isLoading = false } }
        do {
            try check()
            if source == .server {
                let value = try await api.value(path: metric.path)
                try check()
                serverEntries = LeaderboardEntry.list(from: value)
                return
            }

            // These endpoints define a bounded candidate set, not a full server
            // directory. No guessed pagination, enumeration or private API.
            var candidates: [LeaderboardEntry] = []
            var failedLists = 0
            for candidateMetric in [LeaderboardMetric.coins, .playtime] {
                try check()
                do {
                    let value = try await api.value(path: candidateMetric.path)
                    try check()
                    candidates += LeaderboardEntry.list(from: value)
                } catch {
                    try check()
                    if error as? AppError == .notAuthenticated { throw error }
                    failedLists += 1
                }
            }
            guard failedLists < 2 else { throw AppError.transport("两份榜单均读取失败，无法建立主页排行名单") }
            if failedLists > 0 { warning = "部分原始榜单读取失败，当前名单不完整。下拉刷新可重试。" }
            var seen = Set<String>()
            candidates = candidates.filter { seen.insert($0.profileLookup ?? $0.id).inserted }
            total = candidates.count
            var records: [ProfileRankRecord] = []
            // Deliberately one profile request at a time: bounded server load,
            // cancellation checked before every request, no background polling.
            for candidate in candidates {
                try check()
                guard let lookup = candidate.profileLookup else {
                    records.append(.init(candidate: candidate, profile: nil, error: "缺少玩家标识，无法读取主页"))
                    completed += 1
                    continue
                }
                do {
                    let value = try await api.publicPlayerInfo(player: lookup)
                    try check()
                    records.append(.init(candidate: candidate, profile: PublicPlayerProfile(json: value, player: lookup), error: nil))
                } catch {
                    try check()
                    if error as? AppError == .notAuthenticated { throw error }
                    records.append(.init(candidate: candidate, profile: nil, error: "主页读取失败，下拉刷新可重试"))
                }
                completed += 1
            }
            try check()
            profileEntries = ProfileRankEntry.sorted(records, metric: metric)
        } catch is CancellationError {} catch {
            guard ticket == revision, generation == sessionStore.generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
