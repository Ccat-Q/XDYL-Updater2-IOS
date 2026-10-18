import SwiftUI

struct LeaderboardView: View {
    @EnvironmentObject private var model: AppModel
    let metric: LeaderboardMetric
    @State private var source = LeaderboardSource.server
    @StateObject private var store = LeaderboardStore()

    private struct LoadKey: Equatable {
        let source: LeaderboardSource
        let generation: UUID
    }

    var body: some View {
        List {
            Section {
                Picker("数据来源", selection: Binding(get: { source }, set: { newValue in
                    guard newValue != source else { return }
                    store.invalidate()
                    source = newValue
                })) {
                    ForEach(LeaderboardSource.allCases) { source in Text(source.title).tag(source) }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("切换原始榜单统计或个人主页数据排行")
            } footer: {
                Text(sourceDescription)
            }

            if store.isLoading {
                Section {
                    if source == .profile, store.total > 0 {
                        ProgressView(value: Double(store.completed), total: Double(store.total))
                        Text("读取个人主页 \(store.completed) / \(store.total)").font(.caption).foregroundStyle(.secondary)
                    } else { ProgressView("读取榜单…") }
                }
            }
            if let error = store.error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }.disabled(store.isLoading)
                }
            }
            if let warning = store.warning { Section { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) } }

            if source == .server {
                Section(metric == .coins ? "累计获得喵币" : "原始在线时长") {
                    ForEach(store.serverEntries) { entry in
                        rowLink(player: entry.profileLookup) {
                            RankingRow(rank: String(entry.rank), name: entry.name, username: entry.username,
                                       avatarURL: entry.avatarURL, value: serverValue(entry))
                        }
                    }
                }
            } else {
                Section(metric == .coins ? "主页当前余额 · 当前名单" : "主页累计游玩 · 当前名单") {
                    ForEach(store.profileEntries) { entry in
                        let record = entry.record
                        rowLink(player: record.candidate.profileLookup) {
                            RankingRow(rank: entry.rank.map(String.init), name: record.profile?.nickname ?? record.candidate.name,
                                       username: record.profile?.username ?? record.candidate.username,
                                       avatarURL: record.profile?.avatarURL ?? record.candidate.avatarURL,
                                       value: profileValue(entry),
                                       note: entry.value == nil ? record.unavailableReason(for: metric) : nil)
                        }
                    }
                }
                if !store.profileEntries.isEmpty {
                    Section {
                        Text("已排名 \(store.profileEntries.filter { $0.rank != nil }.count) 人；\(store.profileEntries.filter { $0.rank == nil }.count) 人未参与排名。相同数值并列，未提供数据或读取失败的玩家不计名次。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !store.isLoading, store.error == nil, store.serverEntries.isEmpty, store.profileEntries.isEmpty {
                Section { Text("暂无排行数据，下拉刷新可重试。").foregroundStyle(.secondary) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(metric.title)
        .task(id: LoadKey(source: source, generation: model.sessionStore.generation)) { await load() }
        .refreshable { await load() }
        .onDisappear { store.invalidate() }
    }

    private var sourceDescription: String {
        if source == .server {
            return metric == .coins ? "按服务器原始名次展示累计获得喵币，不代表当前可用余额。" : "按服务器原始名次展示在线时长。"
        }
        return "合并现有喵币榜和在线榜的名单，逐一读取个人主页后重新排序；仅为当前名单排行，不是全服排名。\(metric == .coins ? "数值为主页当前余额，不是累计获得喵币。" : "时长使用主页 seconds（兼容 playtime），不叠加原始榜单。")"
    }

    @ViewBuilder private func rowLink<Content: View>(player: String?, @ViewBuilder content: () -> Content) -> some View {
        if let player { NavigationLink { PlayerInfoView(player: player) } label: { content() } }
        else { content() }
    }

    private func serverValue(_ entry: LeaderboardEntry) -> String {
        switch metric {
        case .coins: return entry.coins.map { "\($0) 喵币" } ?? "未提供"
        case .playtime: return entry.seconds.map(DisplayFormat.duration) ?? "未提供"
        }
    }

    private func profileValue(_ entry: ProfileRankEntry) -> String {
        guard let value = entry.value else { return "未参与排名" }
        if metric == .coins { return "\(NSDecimalNumber(decimal: value).stringValue) 喵币" }
        return DisplayFormat.duration(entry.record.profile?.seconds ?? 0)
    }

    private func load() async {
        await store.load(metric: metric, source: source, api: model.api, sessionStore: model.sessionStore)
    }
}

private struct RankingRow: View {
    let rank: String?
    let name: String
    let username: String?
    let avatarURL: URL?
    let value: String
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                Text(rank.map { "#\($0)" } ?? "—")
                    .font(.subheadline.bold()).foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .leading)
                    .accessibilityLabel(rank.map { "第 \($0) 名" } ?? "未参与排名")
                AsyncImage(url: avatarURL) { image in image.resizable().scaledToFill() } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                }
                .frame(width: 36, height: 36).clipShape(Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.subheadline.weight(.semibold))
                    if let username, username != name { Text("@\(username)").font(.caption).foregroundStyle(.secondary) }
                    Text(value).font(.subheadline.weight(.semibold))
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }
}
