import SwiftUI
import UniformTypeIdentifiers

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
    @State private var isLoading = false
    @State private var showingCompose = false
    @State private var composeText = ""
    @State private var showingFileImporter = false
    @State private var showingCustomTitle = false

    var body: some View {
        Group {
            if isLoading && items.isEmpty { ProgressView() }
            else if items.isEmpty {
                ScrollView { EmptyStateView(icon: route.icon, title: "暂无\(route.title)", message: "下拉刷新以重试请求。") }
                    .refreshable { await load() }
            }
            else {
                List(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        if route.path == "/rank/coins" || route.path == "/rank/playtime" {
                            RankRow(item: item, metric: route.path == "/rank/coins" ? .coins : .playtime)
                        } else {
                            NavigationLink { RemoteItemDetailView(title: route.title, item: item) } label: { RemoteItemRow(item: item) }
                        }
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
            items = try await model.api.values(path: route.path)
            if route.title == "通知" { try? await model.api.markNotificationsRead(); await model.refreshUnreadCount() }
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

private struct RankRow: View {
    enum Metric { case coins, playtime }
    let item: RemoteItem
    let metric: Metric

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(item.raw["rank"]?.stringValue ?? "-")").font(.title3.bold()).foregroundStyle(.secondary).frame(width: 38)
            AsyncImage(url: AppEnvironment.avatarURL(from: item.raw["avatar"]?.stringValue)) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary) }
                .frame(width: 38, height: 38).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold))
                if let username = item.raw["username"]?.stringValue, username != item.title { Text("@\(username)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(metricValue).font(.subheadline.weight(.semibold)).multilineTextAlignment(.trailing)
        }
    }

    private var metricValue: String {
        switch metric {
        case .coins: return "\(item.raw["coins"]?.stringValue ?? "0") 喵币"
        case .playtime:
            let seconds = Int(item.raw["seconds"]?.stringValue ?? "0") ?? 0
            return "\(seconds / 3600) 小时 \((seconds % 3600) / 60) 分"
        }
    }
}

private struct CustomTitlePurchaseView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onComplete: () async -> Void
    @State private var title = ""
    @State private var showingConfirmation = false
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("输入新称号", text: $title)
                Text("价格和最大长度由服务器校验；提交前会再次确认。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("自定义称号")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("继续") { showingConfirmation = true }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting) }
            }
            .confirmationDialog("确认购买自定义称号？", isPresented: $showingConfirmation, titleVisibility: .visible) {
                Button("确认提交", role: .destructive) { submit() }
            } message: { Text("服务器会按实际规则扣除喵币。") }
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
