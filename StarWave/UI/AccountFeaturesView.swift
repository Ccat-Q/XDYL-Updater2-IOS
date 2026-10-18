import SwiftUI
import PhotosUI

struct GameBindingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var bindings: [GameBinding] = []
    @State private var name = ""
    @State private var uuid = ""
    @State private var busy = false
    @State private var deleting: GameBinding?

    var body: some View {
        Form {
            Section("已绑定游戏账号") {
                if bindings.isEmpty { Text("暂无绑定账号").foregroundStyle(.secondary) }
                ForEach(bindings) { binding in
                    HStack {
                        VStack(alignment: .leading) { Text(binding.name); if !binding.uuid.isEmpty { Text(binding.uuid).font(.caption).foregroundStyle(.secondary) } }
                        Spacer()
                        Button(role: .destructive) { deleting = binding } label: { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(busy)
                    }
                }
            }
            Section("添加绑定") {
                TextField("游戏内玩家名", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("UUID（可选）", text: $uuid).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(busy ? "处理中…" : "绑定游戏账号") { add() }.disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("决斗场匹配使用这里绑定的游戏账号。请确认游戏内使用的玩家名。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("游戏账号绑定")
        .task { await load() }.refreshable { await load() }
        .confirmationDialog("删除这个游戏绑定？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let binding = deleting { Button("删除 \(binding.name)", role: .destructive) { deleting = nil; remove(binding) } }
        }
    }
    private func load() async {
        do { bindings = try await model.api.value(path: "/user/game-bindings").rows("items", "bindings").map { GameBinding(json: $0) }.filter { !$0.name.isEmpty } }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
    private func add() {
        busy = true
        Task {
            defer { busy = false }
            do { _ = try await model.api.post(path: "/user/game-bindings", fields: ["game_name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "uuid": .string(uuid)]); name = ""; uuid = ""; await load() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
    private func remove(_ binding: GameBinding) {
        busy = true
        Task {
            defer { busy = false }
            do { _ = try await model.api.post(path: "/user/game-bindings/delete", fields: ["id": .identifier(binding.id)]); await load() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}

struct PlayerInfoView: View {
    @EnvironmentObject private var model: AppModel
    let player: String
    @State private var profile: PublicPlayerProfile?
    @State private var loading = false

    var body: some View {
        List {
            if let profile {
                Section {
                    HStack {
                        AsyncImage(url: profile.avatarURL) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle") }.frame(width: 60, height: 60).clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(profile.nickname).font(.title3.bold())
                            Text(profile.name).foregroundStyle(.secondary)
                            if let username = profile.username { Text("@\(username)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    LabeledContent("游戏状态", value: profile.online.map { $0 ? "在线" : "离线" } ?? "未知")
                    LabeledContent("注册状态", value: profile.registered.map { $0 ? "已注册" : "未注册" } ?? "未知")
                    if let banned = profile.banned { LabeledContent("账号状态", value: banned ? "已封禁" : "正常") }
                    if let last = profile.lastLogin { LabeledContent("最后登录", value: last) }
                    if let seconds = profile.seconds { LabeledContent("累计游玩", value: DisplayFormat.duration(seconds)) }
                }
                if profile.registered != false {
                    Section("公开资料") {
                        if let bio = profile.bio { Text(bio) }
                        if let coins = profile.coins { LabeledContent("喵币", value: coins) }
                        if let level = profile.level { LabeledContent("等级", value: "Lv.\(level)") }
                        if let exp = profile.experience { LabeledContent("经验", value: "\(exp)") }
                        if let points = profile.points { LabeledContent("积分", value: "\(points)") }
                        if let title = profile.title { LabeledContent("称号") { StyledTitleText(title) } }
                    }
                } else { Text("该玩家尚未注册账户；这里只展示服务器提供的游玩状态。更完整的账户资料暂不可用。").font(.caption).foregroundStyle(.secondary) }
            } else if loading { ProgressView("读取玩家资料…") }
            else { Text("暂时无法读取玩家资料").foregroundStyle(.secondary); Button("重新加载") { Task { await load() } } }
        }
        .navigationTitle(player).task { await load() }.refreshable { await load() }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do { profile = PublicPlayerProfile(json: try await model.api.publicPlayerInfo(player: player), player: player) }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
}

struct ProfileStatisticsView: View {
    let profile: UserProfile
    var body: some View {
        Section("游戏资料") {
            LabeledContent("等级", value: "Lv.\(profile.level)")
            LabeledContent("经验", value: "\(profile.experience) / \(profile.nextLevelExperience)")
            LabeledContent("积分", value: "\(profile.points)")
            LabeledContent("累计游玩", value: "\(profile.playtime / 3600) 小时 \(profile.playtime % 3600 / 60) 分钟")
            if !profile.title.isEmpty { LabeledContent("称号") { StyledTitleText(profile.title) } }
        }
    }
}

struct ChangeUsernameView: View {
    @EnvironmentObject private var model: AppModel
    @State private var username = ""
    @State private var busy = false
    @State private var confirming = false
    var body: some View {
        Form {
            TextField("新用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("修改用户名") { confirming = true }.disabled(username.isEmpty || busy)
        }
        .navigationTitle("修改用户名")
        .confirmationDialog("确认修改用户名？", isPresented: $confirming, titleVisibility: .visible) {
            Button("确认") {
                busy = true
                Task {
                    defer { busy = false }
                    do { _ = try await model.api.post(path: "/user/change-username", fields: ["new_username": .string(username)]); await model.refreshProfile() }
                    catch { model.errorMessage = error.localizedDescription }
                }
            }
        }
    }
}

struct EmojiPickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onSelect: (URL) -> Void
    @State private var emojis: [RemoteItem] = []
    @State private var attachment: PhotosPickerItem?
    @StateObject private var imageUpload = AccountImageUpload()
    private var busy: Bool { imageUpload.isUploading }

    var body: some View {
        NavigationStack {
            List {
                PhotosPicker(selection: $attachment, matching: .images) { Label(busy ? "上传中…" : "上传表情", systemImage: "photo.badge.plus") }.disabled(busy)
                ForEach(emojis) { emoji in
                    if let url = ContentURLs.resolve(emoji.raw["url"]?.stringValue) {
                        Button { onSelect(url); dismiss() } label: {
                            HStack { AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }.frame(width: 64, height: 64); Text(emoji.raw["name"]?.stringValue ?? "表情") }
                        }.buttonStyle(.plain)
                    }
                }
                if emojis.isEmpty { Text("暂无表情，可以先上传图片").foregroundStyle(.secondary) }
            }
            .navigationTitle("我的表情").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await load() }.refreshable { await load() }
            .onChange(of: attachment) { item in upload(item) }
            .onChange(of: model.sessionStore.generation) { imageUpload.sessionChanged(to: $0); attachment = nil; emojis = [] }
            .onDisappear { imageUpload.cancel(); attachment = nil }
        }
    }
    private func load() async {
        do { emojis = try await model.api.value(path: "/user/emojis").rows("emojis", "items").enumerated().map { RemoteItem(json: $0.element, index: $0.offset) } }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
    private func upload(_ item: PhotosPickerItem?) {
        guard let item else { return }
        imageUpload.start(model: model, path: "/user/emojis", filename: "emoji.jpg", fieldName: "emoji", load: {
            try await item.loadTransferable(type: Data.self)
        }) { _ in
            attachment = nil
            await load()
        }
    }
}

struct PollsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var polls: [Poll] = []
    @State private var busy = false
    var body: some View {
        List {
            ForEach(polls) { poll in
                Section(poll.title) {
                    Text(poll.description)
                    if !poll.endTime.isEmpty { Text("截止：\(poll.endTime)").font(.caption).foregroundStyle(.secondary) }
                    Text("\(poll.isActive ? "进行中" : "已结束") · 共 \(poll.totalVotes) 票").font(.caption)
                    ForEach(poll.options) { option in
                        Button { vote(poll, option) } label: {
                            VStack(alignment: .leading) {
                                HStack { Text(option.name); Spacer(); Text("\(option.votes) 票"); if option.id == poll.myVote { Image(systemName: "checkmark.circle.fill") } }
                                ProgressView(value: Double(option.votes), total: Double(max(poll.totalVotes, 1)))
                            }
                        }.buttonStyle(.borderless).disabled(!poll.isActive || busy)
                    }
                    Text("选择选项即可投票，已投票后可以改投。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if polls.isEmpty { Text("暂无投票") }
        }
        .navigationTitle("投票").task { await load() }.refreshable { await load() }
    }
    private func load() async {
        do { polls = try await model.api.value(path: "/polls").rows("polls", "items").map { Poll(json: $0) }.filter { !$0.id.isEmpty } }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
    private func vote(_ poll: Poll, _ option: PollOption) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { _ = try await model.api.post(path: "/polls/\(poll.id)/vote", fields: ["option_id": .identifier(option.id)]); await load() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}

struct PlaytimeRewardsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var rewards: [PlaytimeMilestone] = []
    @State private var totalSeconds = 0
    @State private var busy = false
    var body: some View {
        List {
            Section { LabeledContent("累计游玩", value: "\(totalSeconds / 3600) 小时 \(totalSeconds % 3600 / 60) 分钟") }
            ForEach(rewards) { reward in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(reward.hours.formatted()) 小时奖励").font(.headline)
                    Text("\(reward.coins) 喵币 · \(reward.experience) 经验")
                    Button(reward.claimed ? "已领取" : (reward.claimable ? "领取" : "未达标")) { claim(reward) }.disabled(!reward.claimable || busy)
                }
            }
            if rewards.isEmpty { Text("暂无时长奖励") }
        }
        .navigationTitle("游戏奖励").task { await load() }.refreshable { await load() }
    }
    private func load() async {
        do { let value = try await model.api.value(path: "/playtime/rewards"); rewards = value.rows("milestones", "rewards").compactMap { PlaytimeMilestone(json: $0) }; totalSeconds = value.payload["total_seconds"]?.integer ?? 0 }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
    private func claim(_ reward: PlaytimeMilestone) {
        guard !busy && reward.claimable else { return }; busy = true
        Task {
            defer { busy = false }
            do { _ = try await model.api.post(path: "/playtime/rewards/claim", fields: ["hours": .number(reward.hours)]); await model.refreshProfile(); await load() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}
