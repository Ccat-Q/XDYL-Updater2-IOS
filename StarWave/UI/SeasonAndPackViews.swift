import SwiftUI

struct SeasonsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var seasons: [Season] = []
    @State private var loading = false

    var body: some View {
        List {
            if loading && seasons.isEmpty { ProgressView("读取周目…") }
            else if seasons.isEmpty { Text("暂无周目记录").foregroundStyle(.secondary) }
            ForEach(seasons) { season in
                NavigationLink { SeasonDetailView(season: season) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(season.name).font(.headline)
                        Text(season.stateText).foregroundStyle(season.active == true ? Color.green : Color.secondary)
                        SeasonFactsView(season: season)
                    }.font(.caption)
                }
            }
        }
        .navigationTitle("周目")
        .task { await load() }.refreshable { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            let value = try await model.api.value(path: "/seasons")
            try Task.checkCancellation()
            seasons = value.rows("seasons", "items").enumerated().map { Season(json: $0.element, index: $0.offset) }
        } catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
}

private struct SeasonFactsView: View {
    let season: Season
    var body: some View {
        Group {
            if let start = season.start { LabeledContent("开始时间", value: start) }
            if let end = season.end { LabeledContent("结束时间", value: end) }
            if let players = season.players { LabeledContent("玩家人数", value: "\(players)") }
            if let seconds = season.mySeconds { LabeledContent("我的时长", value: DisplayFormat.duration(seconds)) }
        }.foregroundStyle(.secondary)
    }
}

private struct SeasonDetailView: View {
    let season: Season
    var body: some View {
        List {
            Section(season.name) { LabeledContent("状态", value: season.stateText); SeasonFactsView(season: season) }
            if !season.description.isEmpty { Section("周目介绍") { RichContentView(season.description) } }
        }.navigationTitle("周目详情").navigationBarTitleDisplayMode(.inline)
    }
}

struct PackVersionNoticeView: View {
    let version: String
    let changelog: String
    var showDownloadLink = false
    @ObservedObject private var versions = PackVersionStore.shared

    var body: some View {
        if versions.needsAcknowledgement(version: version) {
            SectionCard(title: "整合包版本更新", icon: "shippingbox") {
                Text("当前版本：\(version)").font(.headline)
                if !changelog.isEmpty { RichContentView(changelog) }
                Text("确认仅表示已阅读提醒，不代表已下载或安装资源。").font(.caption).foregroundStyle(.secondary)
                if showDownloadLink { NavigationLink("查看整合包下载") { PackDownloadsView() } }
                Button("我已了解此版本") { versions.acknowledge(version: version) }.buttonStyle(.bordered)
            }
        }
    }
}
