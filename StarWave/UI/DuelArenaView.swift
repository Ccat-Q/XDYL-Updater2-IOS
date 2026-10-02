import SwiftUI

struct DuelArenaView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var me: DuelPlayer?
    @State private var recentMatches: [DuelRecentMatch] = []
    @State private var ranks: [DuelPlayer] = []
    @State private var online: [DuelPlayer] = []
    @State private var invites: [DuelInvite] = []
    @State private var accounts: [String] = []
    @State private var selectedAccount = ""
    @State private var match = DuelMatch.idle
    @State private var isLoading = false
    @State private var pendingAction: PendingAction?

    private enum PendingAction: Identifiable {
        case challenge(DuelPlayer), respond(DuelInvite, Bool), join, confirm, leave
        var id: String {
            switch self {
            case let .challenge(player): return "challenge-\(player.id)"
            case let .respond(invite, accept): return "respond-\(invite.id)-\(accept)"
            case .join: return "join"
            case .confirm: return "confirm"
            case .leave: return "leave"
            }
        }
        var title: String {
            switch self {
            case let .challenge(player): return "向 \(player.name) 发起挑战？"
            case let .respond(invite, accept): return accept ? "接受 \(invite.player.name) 的挑战？" : "拒绝 \(invite.player.name) 的挑战？"
            case .join: return "开始排位匹配？"
            case .confirm: return "确认本场对局？"
            case .leave: return "取消当前匹配？"
            }
        }
        var message: String {
            switch self {
            case .join: return "服务器会开始为所选账号寻找对手。"
            case .confirm: return "双方确认后，游戏服务器会安排竞技场对局。"
            case .leave: return "这会取消当前排队或拒绝已找到的对局。"
            default: return "该操作会发送到游戏服务器。"
            }
        }
    }

    var body: some View {
        List {
            if let me { myRankSection(me) }
            if !recentMatches.isEmpty { recentSection }
            challengeSection
            outgoingSection
            matchSection
            incomingSection
            leaderboardSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("决斗场")
        .overlay { if isLoading && me == nil { ProgressView("正在读取决斗场…") } }
        .refreshable { await loadAll() }
        .task { await loadAll() }
        .task(id: pollingKey) { await pollWhileActive() }
        .onChange(of: scenePhase) { _ in /* changing the key cancels polling immediately */ }
        .confirmationDialog(pendingAction?.title ?? "确认操作", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            if let action = pendingAction {
                Button("确认") { pendingAction = nil; perform(action) }
                Button("取消", role: .cancel) { pendingAction = nil }
            }
        } message: { Text(pendingAction?.message ?? "") }
    }

    private var pollingKey: String { "\(match.isActive)-\(scenePhase == .active)" }

    private func myRankSection(_ player: DuelPlayer) -> some View {
        Section("我的排位") {
            HStack {
                avatar(for: player)
                VStack(alignment: .leading) {
                    Text(player.name).font(.headline)
                    Text("\(player.tier) · \(player.rating) 分").foregroundStyle(.secondary)
                }
                Spacer()
                if let rank = player.rank { Text("#\(rank)").font(.title3.weight(.bold)) }
            }
            HStack {
                Label("\(player.wins) 胜", systemImage: "checkmark.circle")
                Label("\(player.losses) 负", systemImage: "xmark.circle")
                Label("\(player.matches) 场", systemImage: "flag")
                if let peak = player.peakRating { Text("最高 \(peak)").foregroundStyle(.secondary) }
            }.font(.caption)
        }
    }

    private var challengeSection: some View {
        Section("发起挑战") {
            if online.isEmpty { Text("暂无可挑战的在线玩家").foregroundStyle(.secondary) }
            ForEach(online) { player in
                HStack {
                    avatar(for: player)
                    VStack(alignment: .leading) { Text(player.name); Text("\(player.tier) · \(player.rating) 分").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("挑战") { pendingAction = .challenge(player) }.buttonStyle(.bordered)
                }
            }
        }
    }

    private var recentSection: some View {
        Section("近期对局") {
            ForEach(recentMatches) { record in
                HStack {
                    Image(systemName: record.won == true ? "checkmark.shield.fill" : "shield.slash.fill")
                        .foregroundStyle(record.won == true ? .green : .red)
                    VStack(alignment: .leading) {
                        Text("对手：\(record.opponent)")
                        if !record.time.isEmpty { Text(record.time).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        if let change = record.ratingChange { Text("\(change >= 0 ? "+" : "")\(change) 分") }
                        if let after = record.ratingAfter { Text("赛后 \(after) 分").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private var matchSection: some View {
        Section("排位匹配") {
            if accounts.isEmpty { Text("未找到已绑定的游戏账号，请先在游戏内完成绑定。").foregroundStyle(.secondary) }
            else { Picker("游戏账号", selection: $selectedAccount) { ForEach(accounts, id: \.self) { Text($0).tag($0) } } }
            LabeledContent("时间偏好", value: "白天")
            LabeledContent("状态", value: match.state.title)
            if match.state == .searching { LabeledContent("已等待", value: "\(match.waitingSeconds) 秒") }
            if let opponent = match.opponent {
                HStack { avatar(for: opponent); Text("对手：\(opponent.name)（\(opponent.tier) · \(opponent.rating) 分）") }
                if match.state == .found { Text("确认：我 \(match.meConfirmed ? "已确认" : "未确认") · 对方 \(match.opponentConfirmed ? "已确认" : "未确认")").font(.caption).foregroundStyle(.secondary) }
            }
            if match.state == .idle || match.state == .expired || match.state == .declined {
                Button("开始匹配") { pendingAction = .join }.disabled(selectedAccount.isEmpty)
            } else if match.state == .found && !match.meConfirmed {
                Button("确认对局") { pendingAction = .confirm }.buttonStyle(.borderedProminent)
                Button("拒绝 / 取消", role: .destructive) { pendingAction = .leave }
            } else if match.state == .searching {
                Button("取消匹配", role: .destructive) { pendingAction = .leave }
            } else if match.state == .starts {
                Text("请回到游戏内等待服务器倒计时并传送进竞技场。").foregroundStyle(.green)
            }
        }
    }

    private var outgoingSection: some View {
        Section("已发出的挑战") {
            let outgoing = invites.filter { !$0.isIncoming }
            if outgoing.isEmpty { Text("暂无待回应的挑战").foregroundStyle(.secondary) }
            ForEach(outgoing) { invite in
                HStack {
                    Text(invite.player.name)
                    Spacer()
                    Text(invite.status == "pending" ? "等待回应" : invite.status).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var incomingSection: some View {
        Section("收到的挑战") {
            let incoming = invites.filter(\.isIncoming)
            if incoming.isEmpty { Text("暂无待处理挑战").foregroundStyle(.secondary) }
            ForEach(incoming) { invite in
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(invite.player.name) 向你发起挑战")
                    if let seconds = invite.expiresIn { Text("剩余 \(seconds) 秒").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("接受") { pendingAction = .respond(invite, true) }.buttonStyle(.borderedProminent)
                        Button("拒绝", role: .destructive) { pendingAction = .respond(invite, false) }.buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var leaderboardSection: some View {
        Section("决斗场排行榜") {
            if ranks.isEmpty { Text("暂无排行数据").foregroundStyle(.secondary) }
            ForEach(Array(ranks.enumerated()), id: \.offset) { index, player in
                HStack {
                    Text("#\(player.rank ?? index + 1)").font(.headline).foregroundStyle(.secondary).frame(width: 42, alignment: .leading)
                    avatar(for: player)
                    VStack(alignment: .leading) { Text(player.name); Text("\(player.tier) · \(player.wins) 胜 \(player.losses) 负").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Text("\(player.rating) 分").fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder private func avatar(for player: DuelPlayer) -> some View {
        AsyncImage(url: player.avatarURL) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary) }
            .frame(width: 36, height: 36).clipShape(Circle())
    }

    private func loadAll() async {
        isLoading = true; defer { isLoading = false }
        // Keep UI state updates on the main actor.  These independent requests are
        // short and a sequential refresh avoids races with user-triggered actions.
        await loadMe(); await loadRanks(); await loadOnline()
        await loadInvites(); await loadAccounts(); await refreshMatch()
    }
    private func loadMe() async { await load { let value = try await model.api.value(path: "/pvp/me"); me = DuelPlayer(json: value["data"] ?? value); recentMatches = DuelPayload.recentMatches(value) } }
    private func loadRanks() async { await load { ranks = DuelPayload.list(try await model.api.value(path: "/pvp/rank", query: [URLQueryItem(name: "limit", value: "50")]), keys: ["rankings", "players"]).enumerated().map { DuelPlayer(json: $0.element, fallbackID: "rank-\($0.offset)") }.sorted { ($0.rank ?? Int.max) < ($1.rank ?? Int.max) } } }
    private func loadOnline() async { await load { online = DuelPayload.list(try await model.api.value(path: "/pvp/online"), keys: ["players", "online"]).enumerated().map { DuelPlayer(json: $0.element, fallbackID: "online-\($0.offset)") } } }
    private func loadInvites() async { await load { invites = DuelPayload.invites(try await model.api.value(path: "/pvp/incoming")) } }
    private func loadAccounts() async { await load { let result = DuelPayload.accounts(try await model.api.value(path: "/pvp/accounts")); accounts = result; if selectedAccount.isEmpty { selectedAccount = result.first ?? "" } } }
    private func refreshMatch() async { await load { match = DuelMatch(json: try await model.api.value(path: "/pvp/match/status")) } }
    private func load(_ work: @escaping () async throws -> Void) async { do { try await work() } catch is CancellationError {} catch { model.errorMessage = error.localizedDescription } }

    private func pollWhileActive() async {
        guard match.isActive, scenePhase == .active else { return }
        while !Task.isCancelled && match.isActive && scenePhase == .active {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await refreshMatch(); await loadInvites()
        }
    }

    private func perform(_ action: PendingAction) {
        Task {
            do {
                switch action {
                case let .challenge(player): _ = try await model.api.post(path: "/pvp/challenge", fields: ["target": .string(player.name)])
                case let .respond(invite, accept): _ = try await model.api.post(path: "/pvp/challenge/respond", fields: ["id": .string(invite.id), "action": .string(accept ? "accept" : "decline")])
                case .join: _ = try await model.api.post(path: "/pvp/match/join", fields: ["account": .string(selectedAccount), "time_pref": .string("day")])
                case .confirm: _ = try await model.api.post(path: "/pvp/match/confirm", fields: ["action": .string("accept")])
                case .leave: _ = try await model.api.post(path: "/pvp/match/leave", fields: [:])
                }
                await loadAll()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}
