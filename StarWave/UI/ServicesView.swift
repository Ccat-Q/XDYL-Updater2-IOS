import SwiftUI
import UniformTypeIdentifiers

struct ServicesView: View {
    var body: some View {
        List(AppEnvironment.apiRoutes) { route in
            NavigationLink(value: route) {
                Label(route.title, systemImage: route.icon)
            }
        }
        .navigationTitle("服务")
        .navigationDestination(for: FeatureRoute.self) { route in RemoteFeatureView(route: route) }
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
                        NavigationLink { RemoteItemDetailView(title: route.title, item: item) } label: { RemoteItemRow(item: item) }
                        actionButtons(for: item)
                    }
                    .padding(.vertical, 4)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(route.title)
        .toolbar {
            if route.title == "意见箱" {
                Button { showingCompose = true } label: { Image(systemName: "square.and.pencil") }
            } else if route.title == "YSM 皮肤" {
                Button { showingFileImporter = true } label: { Image(systemName: "square.and.arrow.up") }
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
