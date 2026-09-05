import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var manager = DownloadManager.shared
    @State private var selection = 0
    @State private var resources: [RemoteItem] = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("资源", selection: $selection) {
                Text("资源中心").tag(0)
                Text("我的下载").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            if selection == 0 { catalog }
            else { downloads }
        }
        .navigationTitle("资源")
        .task { if resources.isEmpty { await load() } }
    }

    private var catalog: some View {
        Group {
            if isLoading && resources.isEmpty { ProgressView() }
            else if resources.isEmpty {
                EmptyStateView(icon: "shippingbox", title: "没有找到资源", message: "请检查旧模组接口，或下拉重新加载。")
            } else {
                List(resources) { item in resourceRow(item) }
                    .listStyle(.plain)
                    .refreshable { await load() }
            }
        }
    }

    private var downloads: some View {
        Group {
            if manager.records.isEmpty {
                EmptyStateView(icon: "arrow.down.doc", title: "暂无下载", message: "资源将保存到“文件”App → 我的 iPhone → 星灯云浪。")
            } else {
                List {
                    Section {
                        Label(manager.documentsDirectory.path, systemImage: "folder")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    ForEach(manager.records) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.filename).font(.headline).lineLimit(2)
                            ProgressView(value: record.progress)
                            HStack {
                                Text(label(for: record.state)).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if record.state == .failed { Button("重试") { manager.retry(record) } }
                                if record.state == .completed, let url = record.localURL {
                                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                                }
                                Button(role: .destructive) { manager.delete(record) } label: { Image(systemName: "trash") }
                            }
                            if let message = record.message { Text(message).font(.caption2).foregroundStyle(.secondary) }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func resourceRow(_ item: RemoteItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RemoteItemRow(item: item)
            if let url = firstURL(in: item.raw) {
                Button {
                    let hash = item.raw["sha256"]?.stringValue ?? item.raw["hash"]?.stringValue
                    manager.enqueue(url: url, filename: item.raw["filename"]?.stringValue ?? url.lastPathComponent, expectedSHA256: hash)
                    selection = 1
                } label: {
                    Label("下载到“文件”App", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("服务器未提供可用下载地址").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func firstURL(in value: JSONValue) -> URL? {
        if let string = value.stringValue, let url = URL(string: string), ["http", "https"].contains(url.scheme) { return url }
        if case let .object(object) = value {
            for key in ["url", "download_url", "link", "pack_zip", "direct_url"] {
                if let candidate = object[key], let url = firstURL(in: candidate) { return url }
            }
            for candidate in object.values { if let url = firstURL(in: candidate) { return url } }
        }
        if case let .array(array) = value {
            for candidate in array { if let url = firstURL(in: candidate) { return url } }
        }
        return nil
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let packLinks = try await model.api.values(path: "/update/pack-links")
            let mods = (try? await model.api.values(path: "/mods/list")) ?? []
            resources = packLinks + mods
            if resources.isEmpty {
                let fallback = try await model.api.value(path: "/mods.json", requiresAuthentication: false, baseURL: AppEnvironment.modsBaseURL)
                resources = RemoteItem.list(from: fallback)
            }
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func label(for state: DownloadState) -> String {
        switch state {
        case .queued: return "等待下载"
        case .downloading: return "下载中"
        case .verifying: return "正在校验 SHA-256"
        case .completed: return "下载完成"
        case .failed: return "下载失败"
        }
    }
}

