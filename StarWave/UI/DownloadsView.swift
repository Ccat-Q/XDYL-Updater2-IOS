import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var manager = DownloadManager.shared
    @State private var selection = 0
    @State private var resources: [ResourceFile] = []
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
        .background(Color(uiColor: .systemGroupedBackground))
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
                    .listStyle(.insetGrouped)
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
                                if record.state == .failed {
                                    Button("重试") { manager.retry(record) }
                                        .buttonStyle(.borderless)
                                }
                                if record.state == .completed, let url = record.localURL {
                                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                                }
                                Button(role: .destructive) { manager.delete(record) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                            if let message = record.message { Text(message).font(.caption2).foregroundStyle(.secondary) }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func resourceRow(_ item: ResourceFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.name).font(.headline).lineLimit(3)
            Text(item.description).font(.caption).foregroundStyle(.secondary)
            if let url = item.url {
                Button {
                    manager.enqueue(url: url, filename: item.name, expectedSHA256: item.sha256)
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

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // The public manifest is authoritative: it contains individual files,
            // names, SHA-256 values and direct download URLs. `/mods/list` returns
            // grouping data and must not be treated as downloadable files.
            let manifest = try await model.api.value(path: "/mods.json", requiresAuthentication: false, baseURL: AppEnvironment.modsBaseURL)
            resources = ResourceFile.list(from: manifest)
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

struct ResourceFile: Identifiable {
    let name: String
    let url: URL?
    let sha256: String?
    let size: Int64?
    let kind: String?

    var id: String { url?.absoluteString ?? name }
    var description: String {
        var values: [String] = []
        if let kind, !kind.isEmpty { values.append(kind == "pack_zip" ? "整合包" : "模组") }
        if let size { values.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return values.isEmpty ? "服务器资源" : values.joined(separator: " · ")
    }

    static func list(from value: JSONValue) -> [ResourceFile] {
        let root = value["data"] ?? value
        let files = root["files"]?.arrayValue ?? []
        return files.compactMap { file in
            guard let name = file["name"]?.stringValue, !name.isEmpty else { return nil }
            let rawURL = file["url"]?.stringValue
            let url = rawURL.flatMap(URL.init(string:))
            return ResourceFile(
                name: name,
                url: url,
                sha256: file["sha256"]?.stringValue,
                size: Int64(file["size"]?.stringValue ?? ""),
                kind: file["kind"]?.stringValue
            )
        }
    }
}
