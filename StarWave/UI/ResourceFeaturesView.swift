import SwiftUI
import UniformTypeIdentifiers

struct YSMPublishView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("ysm_api_base") private var base = "http://api.lanternwaves.fun:8080"
    @State private var code = ""
    @State private var player = ""
    @State private var isPublic = false
    @State private var file: URL?
    @State private var importFile = false
    @State private var busy = false
    @State private var result: JSONValue?
    @State private var duplicate: JSONValue?
    @State private var history: [RemoteItem] = []
    @State private var codes: [RedeemCode] = []
    @State private var submittedCode = ""
    @State private var submittedPlayer = ""
    @State private var submittedBase = AppEnvironment.ysmBaseURL

    var body: some View {
        Form {
            Section("YSM 服务") {
                Picker("服务地址", selection: $base) {
                    Text("Windows 默认服务").tag("http://api.lanternwaves.fun:8080")
                    Text("账户服务（HTTPS）").tag(AppEnvironment.apiBaseURL.absoluteString)
                    Text("API 服务（HTTPS）").tag("https://api.lanternwaves.fun")
                }.disabled(busy)
                Text(AppEnvironment.ysmBaseURL.absoluteString).font(.caption).foregroundStyle(.secondary)
            }
            Section("发布皮肤") {
                TextField("兑换码", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !codes.isEmpty {
                    Menu("从我的兑换码选择") { ForEach(codes.filter { !$0.used && !$0.code.isEmpty }) { item in Button(item.name + " · " + item.code) { code = item.code } } }
                }
                TextField("游戏内玩家名", text: $player).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("公开模型", isOn: $isPublic)
                Button(file?.lastPathComponent ?? "选择 .ysm / .zip 文件") { importFile = true }.disabled(busy)
                Button(busy ? "发布中…" : "上传并发布") { upload() }.disabled(busy || code.isEmpty || player.isEmpty || file == nil)
            }
            .disabled(busy)
            if let result {
                Section("发布结果") {
                    let source = result.payload
                    if let message = result["message"]?.stringValue { Text(message) }
                    if let id = source["model_id"]?.stringValue ?? result["model_id"]?.stringValue { Text("模型 ID：\(id)").textSelection(.enabled); Button("复制模型 ID") { UIPasteboard.general.string = id } }
                    if let path = source["skin_path"]?.stringValue ?? result["skin_path"]?.stringValue { Text(path).font(.caption).textSelection(.enabled) }
                }
            }
            Section("上传历史") {
                Button("查询此玩家的上传历史") { Task { await loadHistory() } }.disabled(player.isEmpty || busy)
                ForEach(history) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.raw["model_id"]?.stringValue ?? item.raw["model"]?.stringValue ?? item.title)
                        Text(item.raw["upload_time"]?.stringValue ?? item.raw["uploaded_at"]?.stringValue ?? item.raw["time"]?.stringValue ?? "").font(.caption).foregroundStyle(.secondary)
                        if item.raw["is_duplicate"]?.boolValue == true || item.raw["duplicate"]?.boolValue == true { Text("重复文件授权").font(.caption) }
                    }
                }
            }
        }
        .navigationTitle("YSM 皮肤")
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.data], allowsMultipleSelection: false) { response in
            switch response {
            case let .success(urls):
                if let url = urls.first, ["ysm", "zip"].contains(url.pathExtension.lowercased()) { file = url }
                else { model.errorMessage = "请选择 .ysm 或 .zip 文件" }
            case let .failure(error): model.errorMessage = error.localizedDescription
            }
        }
        .task { await loadCodes() }
        .confirmationDialog("文件已存在，继续授权给此玩家？", isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } }), titleVisibility: .visible) {
            if let duplicate { Button("确认授权") { self.duplicate = nil; authorize(duplicate) } }
            Button("取消", role: .cancel) { duplicate = nil }
        } message: { Text("玩家：\(submittedPlayer)。继续授权会使用本次提交的兑换码。") }
    }

    private func loadCodes() async {
        do { codes = try await model.api.value(path: "/user/items").rows("items").enumerated().map { RedeemCode(json: $0.element, index: $0.offset) } }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
    private func loadHistory() async {
        do { history = try await model.api.value(path: "/history", query: [.init(name: "player", value: player)], requiresAuthentication: false, baseURL: AppEnvironment.ysmBaseURL).rows("history", "items").enumerated().map { RemoteItem(json: $0.element, index: $0.offset) } }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
    private func upload() {
        guard let file, !busy else { return }
        busy = true; result = nil; submittedCode = code; submittedPlayer = player
        let baseURL = AppEnvironment.ysmBaseURL
        submittedBase = baseURL
        let fields = ["code": code, "player_name": player, "is_public": isPublic ? "true" : "false"]
        Task {
            defer { busy = false }
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            do {
                let data = try await Task.detached { try Data(contentsOf: file) }.value
                let value = try await model.api.upload(path: "/upload_v2", data: data, filename: file.lastPathComponent, fieldName: "skin_file", fields: fields, baseURL: baseURL, requiresAuthentication: false)
                if value["duplicate"]?.boolValue == true || value.payload["duplicate"]?.boolValue == true { duplicate = value }
                else { result = value; await loadHistory(); await loadCodes() }
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
    private func authorize(_ value: JSONValue) {
        guard let original = value.payload["original_model_id"] ?? value["original_model_id"] else { model.errorMessage = "重复文件响应缺少模型 ID"; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                result = try await model.api.post(path: "/confirm_duplicate", fields: ["code": .string(submittedCode), "player_name": .string(submittedPlayer), "original_model_id": original], requiresAuthentication: false, baseURL: submittedBase)
                await loadHistory(); await loadCodes()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

struct PackDownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var files: [ResourceFile] = []
    @State private var links: [RemoteItem] = []
    @State private var version = ""
    @State private var changelog = ""
    var body: some View {
        List {
            Section("整合包") {
                if !version.isEmpty { LabeledContent("版本", value: version) }
                if !changelog.isEmpty { RichContentView(changelog) }
                ForEach(files) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(file.name).font(.headline)
                        Text(file.description).font(.caption).foregroundStyle(.secondary)
                        if let url = file.url { Button("下载到“文件”App") { model.downloads.enqueue(url: url, filename: file.name, expectedSHA256: file.sha256) }.buttonStyle(.bordered) }
                    }
                }
                if files.isEmpty { Text("暂无直链文件，可查看网盘入口") }
            }
            Section("网盘入口") {
                ForEach(links) { link in
                    if let url = ContentURLs.resolve(link.raw["url"]?.stringValue) {
                        Link(link.raw["label"]?.stringValue ?? link.title, destination: url)
                        if let code = link.raw["code"]?.stringValue, !code.isEmpty { HStack { Text("提取码：\(code)"); Spacer(); Button("复制") { UIPasteboard.general.string = code } }.buttonStyle(.borderless) }
                    }
                }
            }
        }
        .navigationTitle("整合包下载").task { await load() }.refreshable { await load() }
    }
    private func load() async {
        do {
            let value = try await model.api.value(path: "/update/pack-files")
            files = value.rows("files").compactMap { row in
                guard let name = row["name"]?.stringValue else { return nil }
                return ResourceFile(name: name, url: ContentURLs.resolve(row["url"]?.stringValue), sha256: row["sha256"]?.stringValue, size: row["size"]?.stringValue.flatMap(Int64.init), kind: "pack_zip")
            }
            let packs = try await model.api.value(path: "/update/pack-links")
            version = packs.payload["pack_version"]?.stringValue ?? ""
            changelog = packs.payload["pack_changelog"]?.stringValue ?? ""
            let source = packs.payload["links"] ?? .array([])
            let rows: [JSONValue]
            if case .array = source { rows = source.arrayValue } else { rows = source.objectValue.keys.sorted().compactMap { source[$0] } }
            links = rows.enumerated().map { RemoteItem(json: $0.element, index: $0.offset) }
        } catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
}

struct SuggestionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var items: [RemoteItem] = []
    @State private var content = ""
    @State private var busy = false
    @State private var deleting: RemoteItem?
    var body: some View {
        List {
            Section("提交意见") {
                TextEditor(text: $content).frame(minHeight: 120)
                Button("提交") { submit() }.disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                Text("意见仅自己和管理组可见。").font(.caption).foregroundStyle(.secondary)
            }
            Section("已提交意见") {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        RichContentView(item.detail)
                        if let status = item.raw["status"]?.stringValue { Text("状态：\(status)").font(.caption).foregroundStyle(.secondary) }
                        Button("删除", role: .destructive) { deleting = item }.disabled(busy || item.raw["id"] == nil)
                    }
                }
            }
        }
        .navigationTitle("意见箱").task { await load() }.refreshable { await load() }
        .confirmationDialog("确认删除意见？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let item = deleting { Button("删除", role: .destructive) { deleting = nil; remove(item) } }
        }
    }
    private func load() async {
        do { items = try await model.api.values(path: "/suggestions") }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
    private func submit() {
        busy = true
        Task {
            defer { busy = false }
            do { _ = try await model.api.post(path: "/suggestions", fields: ["content": .string(content)]); content = ""; await load() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
    private func remove(_ item: RemoteItem) {
        busy = true
        Task {
            defer { busy = false }
            do { _ = try await model.api.request(APIRequest(path: "/suggestions/\(item.id)", method: .delete)); await load() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}
