import SwiftUI

@MainActor
struct DuelArenaView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var me: DuelPlayer?
    @State private var recentMatches: [DuelRecentMatch] = []
    @State private var ranks: [DuelPlayer] = []
    @State private var online: [DuelPlayer] = []
    @State private var invites: [DuelInvite] = []
    @State private var accounts: [GameBinding] = []
    @State private var selectedAccount = ""
    @State private var match = DuelMatch.idle
    @State private var isLoading = false
    @State private var pendingAction: PendingAction?
    @State private var isSubmitting = false
    @State private var timePreference = "day"
    @State private var isVisible = false
    @State private var responseGate = DuelResponseGate()
    @State private var actionTask: Task<Void, Never>?

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
            Section("决斗规则") {
                Text("双方须在游戏内在线。接受或双方确认后，服务器会倒计时传送进竞技场，潜行可以取消。败者装备与经验保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("决斗场")
        .overlay { if isLoading && me == nil { ProgressView("正在读取决斗场…") } }
        .refreshable { await loadAll() }
        .task(id: "\(scenePhase == .active)-\(isVisible)") {
            guard scenePhase == .active, isVisible else { return }
            await loadAll(); await pollWhileActive()
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; stopRequests() }
        .onChange(of: scenePhase) { phase in if phase != .active { stopRequests() } }
        .disabled(isSubmitting || isLoading)
        .confirmationDialog(pendingAction?.title ?? "确认操作", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            if let action = pendingAction {
                Button("确认") { pendingAction = nil; perform(action) }
                Button("取消", role: .cancel) { pendingAction = nil }
            }
        } message: { Text(pendingAction?.message ?? "") }
    }

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
            Text(player.totalPlayers.map { "共 \($0) 名排位玩家 · \(player.streakText)" } ?? player.streakText)
                .font(.caption).foregroundStyle(.secondary)
            if let tier = player.nextTier, let need = player.nextTierNeed { Text("距 \(tier) 还需 \(need) 分").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var challengeSection: some View {
        Section("发起挑战") {
            if online.isEmpty { Text("暂无可挑战的在线玩家").foregroundStyle(.secondary) }
            ForEach(online) { player in
                HStack {
                    avatar(for: player)
                    opponentSummary(player)
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
                    Image(systemName: record.won == nil ? "questionmark.circle" : (record.won == true ? "checkmark.shield.fill" : "shield.slash.fill"))
                        .foregroundStyle(record.won == nil ? Color.secondary : (record.won == true ? Color.green : Color.red))
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
            if accounts.isEmpty && !match.isActive { Text("未找到已绑定的游戏账号，请先在游戏内完成绑定。").foregroundStyle(.secondary) }
            else {
                Picker("游戏账号", selection: $selectedAccount) {
                    ForEach(accounts) { Text("\($0.name) · \($0.online ? "在线" : "离线")").tag($0.name) }
                    if match.isActive, !selectedAccount.isEmpty, !accounts.contains(where: { $0.name == selectedAccount }) {
                        Text("\(selectedAccount) · 当前匹配").tag(selectedAccount)
                    }
                }.disabled(match.isActive)
            }
            NavigationLink("管理游戏账号绑定") { GameBindingsView() }
            Picker("竞技场时间", selection: $timePreference) { Text("白天").tag("day"); Text("黑夜").tag("night"); Text("随机").tag("random") }.disabled(match.isActive)
            LabeledContent("状态", value: match.state.title)
            if match.state == .searching { LabeledContent("已等待", value: "\(match.waitingSeconds) 秒") }
            if let opponent = match.opponent {
                HStack { avatar(for: opponent); opponentSummary(opponent) }
                if match.state == .found { Text("确认：我 \(match.meConfirmed ? "已确认" : "未确认") · 对方 \(match.opponentConfirmed ? "已确认" : "未确认")").font(.caption).foregroundStyle(.secondary) }
            }
            if match.state == .starts {
                Text("请回到游戏内等待服务器倒计时并传送进竞技场。").foregroundStyle(.green)
            }
            if match.state.permitsJoin {
                Button(match.state == .starts ? "再次开始匹配" : "开始匹配") { pendingAction = .join }.disabled(selectedAccount.isEmpty || accounts.first(where: { $0.name == selectedAccount })?.online != true)
            } else if match.state == .found && !match.meConfirmed {
                Button("确认对局") { pendingAction = .confirm }.buttonStyle(.borderedProminent)
                Button("拒绝 / 取消", role: .destructive) { pendingAction = .leave }
            } else if match.state == .searching {
                Button("取消匹配", role: .destructive) { pendingAction = .leave }
            }
            if match.state == .found {
                Text("确认剩余：\(match.expiresIn) 秒").font(.caption).foregroundStyle(.secondary)
                if match.meConfirmed { Button("取消匹配", role: .destructive) { pendingAction = .leave } }
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
                    opponentSummary(invite.player)
                    if let deadline = invite.expiresAt { Text("有效期至 \(deadline.formatted())").font(.caption).foregroundStyle(.secondary) }
                    else if let seconds = invite.expiresIn { Text("剩余 \(seconds) 秒").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("接受") { pendingAction = .respond(invite, true) }.buttonStyle(.borderedProminent)
                        Button("拒绝", role: .destructive) { pendingAction = .respond(invite, false) }.buttonStyle(.bordered)
                    }
                    .disabled(invite.expiresAt.map { $0 <= Date() } ?? false)
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

    private func opponentSummary(_ player: DuelPlayer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(player.name).font(.headline)
            Text("游戏名：\(player.gameName)").font(.caption)
            if let username = player.username { Text("论坛：@\(username)").font(.caption) }
            Text("\(player.tier) · \(player.rating) 分").font(.caption)
            Text("\(player.wins) 胜 · \(player.losses) 负 · \(player.streakText)").font(.caption)
        }.foregroundStyle(.secondary)
    }

    private func loadAll(resetFlow: Bool = true) async {
        guard isVisible, scenePhase == .active, !Task.isCancelled, !isSubmitting || !resetFlow else { return }
        if resetFlow { responseGate.invalidate() }
        let ticket = responseGate.begin("all", session: model.sessionStore.generation)
        isLoading = true
        defer {
            // Cancellation blocks response application, not cleanup of this load.
            if responseGate.accepts(ticket, session: model.sessionStore.generation) { isLoading = false }
        }
        await loadMe(); guard isCurrent(ticket) else { return }
        await loadRanks(); guard isCurrent(ticket) else { return }
        await loadOnline(); guard isCurrent(ticket) else { return }
        await loadInvites(); guard isCurrent(ticket) else { return }
        await loadAccounts(); guard isCurrent(ticket) else { return }
        await refreshMatch()
    }

    private func loadMe() async {
        await load(channel: "me", request: { try await model.api.value(path: "/pvp/me") }) { value in
            me = DuelPlayer(json: value["data"] ?? value)
            recentMatches = DuelPayload.recentMatches(value)
        }
    }

    private func loadRanks() async {
        await load(channel: "ranks", request: {
            try await model.api.value(path: "/pvp/rank", query: [URLQueryItem(name: "limit", value: "50")])
        }) { value in
            ranks = DuelPayload.list(value, keys: ["rankings", "players"]).enumerated()
                .map { DuelPlayer(json: $0.element, fallbackID: "rank-\($0.offset)") }
                .sorted { ($0.rank ?? Int.max) < ($1.rank ?? Int.max) }
        }
    }

    private func loadOnline() async {
        await load(channel: "online", request: { try await model.api.value(path: "/pvp/online") }) { value in
            online = DuelPayload.list(value, keys: ["players", "online"]).enumerated()
                .map { DuelPlayer(json: $0.element, fallbackID: "online-\($0.offset)") }
        }
    }

    private func loadInvites() async {
        await load(channel: "invites", request: { try await model.api.value(path: "/pvp/incoming") }) {
            invites = DuelPayload.invites($0)
        }
    }

    private func loadAccounts() async {
        await load(channel: "accounts", request: { try await model.api.value(path: "/pvp/accounts") }) { value in
            let result = value.rows("accounts").map { GameBinding(json: $0) }.filter { !$0.name.isEmpty }
            accounts = result
            if !match.isActive && !result.contains(where: { $0.name == selectedAccount }) {
                selectedAccount = result.first(where: \.online)?.name ?? result.first?.name ?? ""
            }
        }
    }

    private func refreshMatch() async {
        await load(channel: "match", request: { try await model.api.value(path: "/pvp/match/status") }) { value in
            let updated = DuelMatch(json: value)
            let selection = updated.restoredSelection(account: selectedAccount, timePreference: timePreference)
            selectedAccount = selection.account
            timePreference = selection.timePreference
            match = updated
        }
    }

    private func load<Value>(channel: String, request: () async throws -> Value, apply: (Value) -> Void) async {
        guard isVisible, scenePhase == .active, !Task.isCancelled else { return }
        let ticket = responseGate.begin(channel, session: model.sessionStore.generation)
        do {
            let value = try await request()
            guard isCurrent(ticket) else { return }
            apply(value)
        } catch {
            guard isCurrent(ticket) else { return }
            model.errorMessage = error.localizedDescription
        }
    }

    private func isCurrent(_ ticket: DuelResponseGate.Ticket) -> Bool {
        isVisible && scenePhase == .active && responseGate.accepts(ticket, session: model.sessionStore.generation, cancelled: Task.isCancelled)
    }

    private func stopRequests() {
        responseGate.invalidate()
        actionTask?.cancel(); actionTask = nil
        isSubmitting = false; isLoading = false; pendingAction = nil
    }

    private func pollWhileActive() async {
        var tick = 0
        while !Task.isCancelled && isVisible && scenePhase == .active {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            if !isSubmitting && !isLoading {
                let flow = responseGate.flow
                if match.state.shouldPoll { await refreshMatch() }
                guard !Task.isCancelled, isVisible, scenePhase == .active else { return }
                if !isSubmitting && !isLoading && flow == responseGate.flow && tick % 5 == 0 { await loadInvites() }
            }
            tick += 1
        }
    }

    private func perform(_ action: PendingAction) {
        guard isVisible, scenePhase == .active, !isSubmitting, !isLoading else { return }
        // A confirmation dialog may remain open while a poll changes the match.
        switch action {
        case .join:
            guard match.state.permitsJoin, accounts.contains(where: { $0.name == selectedAccount && $0.online }) else { return }
        case .confirm:
            guard match.state == .found, !match.meConfirmed else { return }
        case .leave:
            guard match.isActive else { return }
        case let .respond(invite, _):
            guard invites.contains(where: { $0.id == invite.id }), !(invite.expiresAt.map { $0 <= Date() } ?? false) else { return }
        case .challenge: break
        }
        responseGate.invalidate()
        let ticket = responseGate.begin("action", session: model.sessionStore.generation)
        let account = selectedAccount, preference = timePreference
        isSubmitting = true
        actionTask = Task {
            defer {
                if responseGate.accepts(ticket, session: model.sessionStore.generation) {
                    isSubmitting = false; actionTask = nil
                }
            }
            do {
                guard isCurrent(ticket) else { return }
                switch action {
                case let .challenge(player): _ = try await model.api.post(path: "/pvp/challenge", fields: player.challengeFields)
                case let .respond(invite, accept): _ = try await model.api.post(path: "/pvp/challenge/respond", fields: ["id": .identifier(invite.id), "action": .string(accept ? "accept" : "decline")])
                case .join: _ = try await model.api.post(path: "/pvp/match/join", fields: ["account": .string(account), "time_pref": .string(preference)])
                case .confirm: _ = try await model.api.post(path: "/pvp/match/confirm", fields: ["action": .string("accept")])
                case .leave: _ = try await model.api.post(path: "/pvp/match/leave", fields: [:])
                }
                guard isCurrent(ticket) else { return }
                await loadAll(resetFlow: false)
            } catch {
                guard isCurrent(ticket) else { return }
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
