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
                    ForEach(serverStatus) { item in
                        NavigationLink { RemoteItemDetailView(title: "服务器状态", item: item) } label: { RemoteItemRow(item: item) }
                    }
                }
                SectionCard(title: "公告", icon: "megaphone") {
                    if announcements.isEmpty { Text("暂无公告").foregroundStyle(.secondary) }
                    ForEach(announcements) { item in
                        NavigationLink { RemoteItemDetailView(title: "公告", item: item) } label: { RemoteItemRow(item: item) }
                    }
                }
                if let release { releaseCard(release) }
            }
            .padding()
        }
        .appContentBackground()
        .navigationTitle("星灯云浪")
        .refreshable { await load() }
        .task { if announcements.isEmpty { await load() } }
        .loading(isLoading)
    }

    private var welcomeCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("你好，\(model.profile?.nickname ?? model.sessionStore.username ?? "玩家")").font(.title3.bold())
                Text("在手机上浏览社区、管理资源与下载包").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .appSurfaceCard(cornerRadius: 20)
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
        .appSurfaceCard()
    }
}

struct RemoteItemRow: View {
    let item: RemoteItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StyledTitleText(item.title, colorHint: item.raw["color"]?.stringValue)
                .font(.subheadline.weight(.semibold))
            if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            if !item.detail.isEmpty, item.detail != item.title, item.detail != item.subtitle {
                RichContentView(item.detail, lineLimit: 4)
            }
            ItemImagesView(item: item, height: 150)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RemoteItemDetailView: View {
    let title: String
    let item: RemoteItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                StyledTitleText(item.title, colorHint: item.raw["color"]?.stringValue).font(.title3.bold())
                if !item.subtitle.isEmpty { Text(item.subtitle).foregroundStyle(.secondary) }
                if !item.detail.isEmpty, item.detail != item.subtitle { RichContentView(item.detail) }
                ItemImagesView(item: item, height: 240)
                if let userTitle = item.raw["user_title"]?.stringValue, !userTitle.isEmpty {
                    LabeledContent("称号") { StyledTitleText(userTitle) }
                }
                ForEach(item.raw.objectValue.keys.sorted(), id: \.self) { key in
                    if let value = item.raw[key]?.stringValue, !["title", "name", "content", "description", "summary"].contains(key) {
                        LabeledContent(key, value: value).font(.footnote)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StyledTitleText: View {
    let value: String
    let colorHint: String?

    init(_ value: String, colorHint: String? = nil) {
        self.value = value
        self.colorHint = colorHint
    }

    var body: some View {
        TitleColor.segments(in: value, fallback: TitleColor.color(from: colorHint))
            .reduce(Text("")) { partial, segment in
                partial + Text(segment.text).foregroundColor(segment.color)
            }
    }
}

enum TitleColor {
    struct Segment {
        let text: String
        let color: Color
    }

    static func segments(in value: String, fallback: Color?) -> [Segment] {
        let defaultColor = fallback ?? .primary
        guard let expression = try? NSRegularExpression(pattern: #"&#([0-9A-Fa-f]{6})"#) else {
            return [Segment(text: value, color: defaultColor)]
        }
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
        guard !matches.isEmpty else { return [Segment(text: value, color: defaultColor)] }

        var result: [Segment] = []
        var cursor = value.startIndex
        var activeColor = defaultColor
        for match in matches {
            guard let tokenRange = Range(match.range, in: value), let hexRange = Range(match.range(at: 1), in: value) else { continue }
            let text = String(value[cursor..<tokenRange.lowerBound])
            if !text.isEmpty { result.append(Segment(text: text, color: activeColor)) }
            activeColor = color(from: String(value[hexRange])) ?? activeColor
            cursor = tokenRange.upperBound
        }
        let trailing = String(value[cursor...])
        if !trailing.isEmpty { result.append(Segment(text: trailing, color: activeColor)) }
        return result.isEmpty ? [Segment(text: value, color: defaultColor)] : result
    }

    static func removingTokens(from value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"&#[0-9A-Fa-f]{6}"#) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: "")
    }

    static func visibleCharacterCount(in value: String) -> Int {
        removingTokens(from: value).count
    }

    static func color(from value: String?) -> Color? {
        guard let value else { return nil }
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#&")).prefix(6)
        guard hex.count == 6, let number = Int(hex, radix: 16) else { return nil }
        return Color(red: Double((number >> 16) & 0xFF) / 255, green: Double((number >> 8) & 0xFF) / 255, blue: Double(number & 0xFF) / 255)
    }
}

struct RichContentView: View {
    let value: String
    let lineLimit: Int?

    init(_ value: String, lineLimit: Int? = nil) {
        self.value = value
        self.lineLimit = lineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(cleanText).font(.subheadline).foregroundStyle(.primary).lineLimit(lineLimit)
            ForEach(markdownImageURLs, id: \.absoluteString) { url in
                RemoteImageView(url: url, height: 220)
            }
        }
    }

    private var markdownImageURLs: [URL] { ContentURLs.markdownImages(in: value) }
    private var cleanText: String { ContentURLs.removingMarkdownImages(from: value) }
}

struct ItemImagesView: View {
    let item: RemoteItem
    let height: CGFloat

    var body: some View {
        ForEach(ContentURLs.images(in: item.raw), id: \.absoluteString) { url in
            RemoteImageView(url: url, height: height)
        }
    }
}

struct RemoteImageView: View {
    let url: URL
    let height: CGFloat

    var body: some View {
        AsyncImage(url: url, transaction: .init(animation: .easeInOut)) { phase in
            switch phase {
            case let .success(image): image.resizable().scaledToFit()
            case .failure: Label("图片加载失败", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            default: ProgressView().frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private enum ContentURLs {
    static func images(in value: JSONValue) -> [URL] {
        let explicit = ["image", "image_url", "cover", "cover_url", "icon"]
            .compactMap { resolve(value[$0]?.stringValue) }
        let markdown = markdownImages(in: value["content"]?.stringValue ?? "")
        return Array(Set(explicit + markdown)).sorted { $0.absoluteString < $1.absoluteString }
    }

    static func markdownImages(in value: String) -> [URL] {
        guard let expression = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)\s]+)\)"#) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: value) else { return nil }
            return resolve(String(value[range]))
        }
    }

    static func removingMarkdownImages(from value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]+\)"#) else { return value }
        return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolve(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let url = URL(string: value), url.scheme != nil { return url }
        return URL(string: value, relativeTo: AppEnvironment.webBaseURL)?.absoluteURL
    }
}
