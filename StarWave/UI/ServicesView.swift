import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ServicesView: View {
    var body: some View {
        List(AppEnvironment.apiRoutes) { route in
            NavigationLink(value: route) {
                Label(route.title, systemImage: route.icon)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("服务")
        .navigationDestination(for: FeatureRoute.self) { route in
            if route.title == "任务" { TaskFeatureView() }
            else { RemoteFeatureView(route: route) }
        }
    }
}

private struct TaskFeatureView: View {
    @EnvironmentObject private var model: AppModel
    @State private var daily: [RemoteItem] = []
    @State private var achievements: [RemoteItem] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading && daily.isEmpty && achievements.isEmpty { ProgressView() }
            else if daily.isEmpty && achievements.isEmpty {
                ScrollView { EmptyStateView(icon: "checkmark.seal", title: "暂无任务", message: "下拉刷新以重试请求。") }
                    .refreshable { await load() }
            } else {
                List {
                    if !daily.isEmpty { Section("每日任务") { ForEach(daily) { taskRow($0) } } }
                    if !achievements.isEmpty { Section("成就") { ForEach(achievements) { taskRow($0) } } }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle("任务")
        .task { await load() }
    }

    private func taskRow(_ item: RemoteItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(.headline)
            if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary) }
            Text("奖励：\(rewardText(for: item))").font(.subheadline).foregroundStyle(.orange)
            Button("领取奖励") { claim(item) }.buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private func rewardText(for item: RemoteItem) -> String {
        let raw = item.raw
        let text = raw["reward"]?.stringValue ?? raw["reward_name"]?.stringValue ?? raw["reward_text"]?.stringValue
        if let text, !text.isEmpty { return text }
        var parts: [String] = []
        if let coins = raw["reward_coins"]?.stringValue ?? raw["coins"]?.stringValue { parts.append("\(coins) 喵币") }
        if let points = raw["points"]?.stringValue ?? raw["reward_points"]?.stringValue { parts.append("\(points) 点数") }
        if let experience = raw["exp"]?.stringValue ?? raw["reward_exp"]?.stringValue { parts.append("\(experience) 经验") }
        return parts.isEmpty ? "以服务器结算为准" : parts.joined(separator: " · ")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await model.api.value(path: "/tasks")
            let source = value["data"] ?? value
            daily = firstList(in: source, keys: ["daily", "daily_tasks", "dailies"])
            achievements = firstList(in: source, keys: ["achievements", "achievement_tasks", "achievement"])
            if daily.isEmpty && achievements.isEmpty {
                let all = RemoteItem.list(from: source)
                daily = all.filter { ($0.raw["type"]?.stringValue ?? $0.raw["task_type"]?.stringValue ?? "").lowercased().contains("daily") }
                achievements = all.filter { ($0.raw["type"]?.stringValue ?? $0.raw["task_type"]?.stringValue ?? "").lowercased().contains("achievement") }
                if daily.isEmpty && achievements.isEmpty { daily = all }
            }
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func firstList(in source: JSONValue, keys: [String]) -> [RemoteItem] {
        for key in keys where source[key] != nil {
            let items = RemoteItem.list(from: source[key]!)
            if !items.isEmpty { return items }
        }
        return []
    }

    private func claim(_ item: RemoteItem) {
        Task {
            do { _ = try await model.api.post(path: "/tasks/\(item.id)/claim", fields: [:]); await load() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}

private struct RemoteFeatureView: View {
    @EnvironmentObject private var model: AppModel
    let route: FeatureRoute
    @State private var items: [RemoteItem] = []
    @State private var rankings: [LeaderboardEntry] = []
    @State private var isLoading = false
    @State private var showingCompose = false
    @State private var composeText = ""
    @State private var showingFileImporter = false
    @State private var showingCustomTitle = false

    var body: some View {
        Group {
            if isLoading && items.isEmpty && rankings.isEmpty { ProgressView() }
            else if isRanking {
                rankingList
            } else if items.isEmpty {
                ScrollView { EmptyStateView(icon: route.icon, title: "暂无\(route.title)", message: "下拉刷新以重试请求。") }
                    .refreshable { await load() }
            }
            else {
                List(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink { RemoteItemDetailView(title: route.title, item: item) } label: { RemoteItemRow(item: item) }
                        actionButtons(for: item)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle(route.title)
        .toolbar {
            if route.title == "意见箱" {
                Button { showingCompose = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("提交意见")
            } else if route.title == "YSM 皮肤" {
                Button { showingFileImporter = true } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("上传 YSM 皮肤")
            } else if route.title == "称号目录" {
                Button { showingCustomTitle = true } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                    .accessibilityLabel("自定义称号")
            }
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.data]) { result in
            guard case let .success(url) = result else { return }
            uploadSkin(url)
        }
        .sheet(isPresented: $showingCompose) {
            NavigationStack {
                Form { TextEditor(text: $composeText).frame(minHeight: 220) }
                    .navigationTitle("提交意见")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { showingCompose = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("提交") { submitSuggestion() }.disabled(composeText.isEmpty) }
                    }
            }
        }
        .sheet(isPresented: $showingCustomTitle) { CustomTitlePurchaseView { await load() } }
        .task { await load() }
    }

    private var isRanking: Bool { route.path == "/rank/coins" || route.path == "/rank/playtime" }

    @ViewBuilder private var rankingList: some View {
        if rankings.isEmpty {
            ScrollView { EmptyStateView(icon: route.icon, title: "暂无\(route.title)", message: "下拉刷新以重试请求。") }
                .refreshable { await load() }
        } else {
            List(rankings) { entry in
                RankRow(entry: entry, metric: route.path == "/rank/coins" ? .coins : .playtime)
                    .padding(.vertical, 4)
            }
            .listStyle(.insetGrouped)
            .refreshable { await load() }
        }
    }

    @ViewBuilder private func actionButtons(for item: RemoteItem) -> some View {
        if route.title == "任务" {
            Button("领取奖励") { post("/tasks/\(item.id)/claim", fields: [:]) }.buttonStyle(.bordered)
        } else if route.title == "商城" {
            Button("购买") { post("/shop/buy", fields: ["item_id": .string(item.id)]) }.buttonStyle(.borderedProminent)
        } else if route.title == "投票" {
            Button("投票") { post("/vote", fields: ["poll_id": .string(item.id)]) }.buttonStyle(.bordered)
        } else if route.title == "游戏奖励" {
            Button("领取") { post("/playtime/rewards/claim", fields: ["reward_id": .string(item.id)]) }.buttonStyle(.bordered)
        } else if route.title == "称号目录" {
            Button("购买") { post("/titles/buy", fields: ["title_id": .string(item.id)]) }.buttonStyle(.bordered)
        } else if route.title == "我的称号" {
            Button("佩戴") { post("/titles/wear", fields: ["title_id": .string(item.id)]) }.buttonStyle(.bordered)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await model.api.value(path: route.path)
            if isRanking {
                rankings = LeaderboardEntry.list(from: value)
                items = []
            } else {
                items = RemoteItem.list(from: value)
            }
            if route.title == "通知" { try? await model.markAllNotificationsRead() }
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func post(_ path: String, fields: [String: JSONValue]) {
        Task {
            do { _ = try await model.api.post(path: path, fields: fields); await load() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func submitSuggestion() {
        let value = composeText
        Task {
            do {
                _ = try await model.api.post(path: "/suggestions", fields: ["content": .string(value)])
                composeText = ""
                showingCompose = false
                await load()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func uploadSkin(_ url: URL) {
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                _ = try await model.api.upload(path: "/upload_v2", data: data, filename: url.lastPathComponent, fieldName: "skin_file")
                await load()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

struct LeaderboardEntry: Identifiable {
    let rank: Int
    let name: String
    let username: String?
    let avatarURL: URL?
    let coins: Int?
    let seconds: Int?

    var id: String { "\(rank)-\(username ?? name)" }

    static func list(from value: JSONValue) -> [LeaderboardEntry] {
        let source = (value["data"] ?? value).arrayValue
        return source.enumerated().compactMap { index, entry in
            let name = entry["nickname"]?.stringValue ?? entry["player_name"]?.stringValue ?? entry["username"]?.stringValue
            guard let name, !name.isEmpty else { return nil }
            let rank = Int(entry["rank"]?.stringValue ?? "") ?? index + 1
            return LeaderboardEntry(
                rank: rank,
                name: name,
                username: entry["username"]?.stringValue,
                avatarURL: AppEnvironment.avatarURL(from: entry["avatar"]?.stringValue),
                coins: Int(entry["coins"]?.stringValue ?? ""),
                seconds: Int(entry["seconds"]?.stringValue ?? "")
            )
        }
        .sorted { $0.rank < $1.rank }
    }
}

private struct RankRow: View {
    enum Metric { case coins, playtime }
    let entry: LeaderboardEntry
    let metric: Metric

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(entry.rank)").font(.title3.bold()).foregroundStyle(.secondary).frame(width: 38)
            AsyncImage(url: entry.avatarURL) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary) }
                .frame(width: 38, height: 38).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.subheadline.weight(.semibold))
                if let username = entry.username, username != entry.name { Text("@\(username)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(metricValue).font(.subheadline.weight(.semibold)).multilineTextAlignment(.trailing)
        }
    }

    private var metricValue: String {
        switch metric {
        case .coins: return "\(entry.coins ?? 0) 喵币"
        case .playtime:
            let seconds = entry.seconds ?? 0
            return "\(seconds / 3600) 小时 \((seconds % 3600) / 60) 分"
        }
    }
}

private struct CustomTitlePurchaseView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onComplete: () async -> Void
    @State private var title = ""
    @State private var selectedColor = Color.accentColor
    @State private var rules: CustomTitleRules?
    @State private var isLoadingRules = false
    @State private var showingConfirmation = false
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("称号内容") {
                    TextField("输入新称号", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                    HStack {
                        Text("可见字符")
                        Spacer()
                        Text(lengthDescription).foregroundStyle(isOverLimit ? .red : .secondary)
                    }
                    Text("颜色代码会随称号提交，但不会显示在预览中。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("颜色代码") {
                    ColorPicker("选择颜色", selection: $selectedColor, supportsOpacity: false)
                    Button {
                        insertColorCode()
                    } label: {
                        Label("插入颜色代码", systemImage: "paintpalette")
                    }
                    Button("清除全部颜色代码", role: .destructive) {
                        title = TitleColor.removingTokens(from: title)
                    }
                    .disabled(!title.contains("&#"))
                    LabeledContent("当前代码", value: colorToken)
                        .font(.caption.monospaced())
                }

                Section("预览") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("游戏内显示效果").font(.caption).foregroundStyle(.secondary)
                        if visibleTitle.isEmpty {
                            Text("输入称号后将在这里预览")
                                .foregroundStyle(.secondary)
                        } else {
                            StyledTitleText(title)
                                .font(.title3.bold())
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .accessibilityLabel("称号预览：\(visibleTitle)")
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("扣费说明") {
                    if isLoadingRules {
                        HStack { ProgressView(); Text("正在读取服务器定价规则…") }
                    } else if let rules {
                        if let price = rules.pricePerCharacter {
                            LabeledContent("单价", value: "\(price) 喵币 / 字")
                        }
                        if let maximumLength = rules.maximumLength {
                            LabeledContent("最多长度", value: "\(maximumLength) 个可见字符")
                        }
                        if let estimate = rules.estimatedCost(visibleCharacters: visibleCharacterCount) {
                            LabeledContent("预计扣费", value: "\(estimate) 喵币")
                                .fontWeight(.semibold)
                        }
                        Text("按目录返回的每字价格和可见字符数预估；提交时颜色代码也会发送，服务端会按最终规则校验并从喵币余额扣除。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("未能读取定价规则。可以继续提交，价格、最大长度和扣费结果以服务端校验为准。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("自定义称号")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("继续") { showingConfirmation = true }
                        .disabled(!canSubmit || isSubmitting)
                }
            }
            .confirmationDialog("确认购买自定义称号？", isPresented: $showingConfirmation, titleVisibility: .visible) {
                Button("确认提交", role: .destructive) { submit() }
            } message: { Text(confirmationMessage) }
        }
        .task { await loadRules() }
    }

    private var colorToken: String {
        let color = UIColor(selectedColor)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "&#FFFFFF" }
        return String(format: "&#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    private var visibleTitle: String {
        TitleColor.removingTokens(from: title).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleCharacterCount: Int { TitleColor.visibleCharacterCount(in: title) }

    private var isOverLimit: Bool {
        guard let maximumLength = rules?.maximumLength else { return false }
        return visibleCharacterCount > maximumLength
    }

    private var canSubmit: Bool { !visibleTitle.isEmpty && !isOverLimit }

    private var lengthDescription: String {
        if let maximumLength = rules?.maximumLength { return "\(visibleCharacterCount) / \(maximumLength)" }
        return "\(visibleCharacterCount)"
    }

    private var confirmationMessage: String {
        var lines = ["称号：\(visibleTitle)"]
        if let estimate = rules?.estimatedCost(visibleCharacters: visibleCharacterCount) {
            lines.append("预计扣除：\(estimate) 喵币")
        }
        lines.append("服务端会校验长度、价格和余额后再扣费。")
        return lines.joined(separator: "\n")
    }

    private func insertColorCode() {
        title += colorToken
    }

    private func loadRules() async {
        isLoadingRules = true
        defer { isLoadingRules = false }
        do {
            rules = CustomTitleRules(json: try await model.api.value(path: "/titles/catalog"))
        } catch {
            // Keep purchase available for a temporarily unavailable catalog; the
            // server remains authoritative when the user confirms the request.
            rules = nil
        }
    }

    private func submit() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                _ = try await model.api.post(path: "/titles/buy", fields: ["title": .string(value)])
                await onComplete()
                dismiss()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}
