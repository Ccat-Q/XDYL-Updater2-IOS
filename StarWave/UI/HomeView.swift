import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var announcements: [RemoteItem] = []
    @State private var serverStatus: [RemoteItem] = []
    @State private var release: GitHubRelease?
    @State private var isLoading = false
    @AppStorage("updateChecksEnabled") private var updateChecksEnabled = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                welcomeCard
                SectionCard(title: "服务器状态", icon: "dot.radiowaves.left.and.right") {
                    if serverStatus.isEmpty { Text("暂无状态数据").foregroundStyle(.secondary) }
                    ForEach(serverStatus) { item in RemoteItemRow(item: item) }
                }
                SectionCard(title: "公告", icon: "megaphone") {
                    if announcements.isEmpty { Text("暂无公告").foregroundStyle(.secondary) }
                    ForEach(announcements) { item in RemoteItemRow(item: item) }
                }
                if let release { releaseCard(release) }
            }
            .padding()
        }
        .navigationTitle("星灯云浪")
        .refreshable { await load() }
        .task { if announcements.isEmpty { await load() } }
        .loading(isLoading)
    }

    private var welcomeCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("你好，\(model.profile?.nickname ?? model.sessionStore.username ?? "玩家")").font(.title3.bold())
                Text("在手机上浏览社区、管理资源与下载包").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(LinearGradient(colors: [.blue.opacity(0.24), .purple.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private func releaseCard(_ release: GitHubRelease) -> some View {
        SectionCard(title: "iOS 更新", icon: "arrow.triangle.2.circlepath") {
            Text(release.name ?? release.tagName).font(.headline)
            if let body = release.body, !body.isEmpty { Text(body).font(.caption).lineLimit(5) }
            Link("查看并下载 IPA", destination: release.assets.first(where: { $0.name.hasSuffix(".ipa") })?.browserDownloadURL ?? release.htmlURL)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        async let announcementsRequest = model.api.values(path: "/announcements")
        async let statusRequest = model.api.values(path: "/server/players")
        announcements = (try? await announcementsRequest) ?? []
        serverStatus = (try? await statusRequest) ?? []
        release = updateChecksEnabled ? (try? await model.api.latestRelease()) : nil
        await model.refreshUnreadCount()
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct RemoteItemRow: View {
    let item: RemoteItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.subheadline.weight(.semibold))
            if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            if !item.detail.isEmpty, item.detail != item.title, item.detail != item.subtitle {
                Text(item.detail).font(.subheadline).foregroundStyle(.primary).lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
