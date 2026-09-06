import SwiftUI
import UniformTypeIdentifiers

struct DeveloperToolsView: View {
    @ObservedObject private var store = DeveloperToolsStore.shared
    @AppStorage("developer.continuousSampling") private var continuousSampling = false

    var body: some View {
        List {
            Section("接口调试") {
                NavigationLink { DeveloperRequestConsoleView() } label: { Label("请求控制台", systemImage: "terminal") }
                NavigationLink { DeveloperRouteCatalogView() } label: { Label("接口目录", systemImage: "list.bullet.rectangle") }
                NavigationLink { DeveloperSessionsView() } label: {
                    Label("最近请求与响应", systemImage: "clock.arrow.circlepath")
                    Spacer(); Text("\(store.sessions.count)").foregroundStyle(.secondary)
                }
            }
            Section("运行状态") {
                NavigationLink { DeveloperPerformanceView() } label: { Label("性能与网络追踪", systemImage: "waveform.path.ecg") }
                NavigationLink { DeveloperEnvironmentView() } label: { Label("环境收藏夹", systemImage: "server.rack") }
                Toggle("持续采样", isOn: $continuousSampling)
                Text("关闭时仅在性能页打开期间每 2 秒采样；开启后 App 运行期间持续采样。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("本地数据") {
                NavigationLink { DeveloperStorageView() } label: { Label("数据与缓存管理", systemImage: "externaldrive") }
                NavigationLink { DiagnosticsView() } label: { Label("普通网络日志", systemImage: "doc.text.magnifyingglass") }
            }
        }
        .navigationTitle("开发者功能")
        .onAppear { if continuousSampling { PerformanceMonitor.shared.start(continuous: true) } }
        .onChange(of: continuousSampling) { enabled in
            if enabled { PerformanceMonitor.shared.start(continuous: true) }
            else { PerformanceMonitor.shared.stop() }
        }
    }
}

private struct DeveloperRequestConsoleView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store = DeveloperToolsStore.shared
    @State private var draft = DeveloperRequestDraft()
    @State private var uploadURL: URL?
    @State private var showingImporter = false
    @State private var showingMutationConfirmation = false
    @State private var deletionPhrase = ""
    @State private var result: DeveloperSession?
    @State private var isSending = false
    @State private var saveName = ""
    @State private var showingSaveEnvironment = false

    var body: some View {
        Form {
            Section("目标") {
                TextField("基础地址", text: $draft.customBaseURL).textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("路径", text: $draft.path).textInputAutocapitalization(.never)
                Picker("方法", selection: $draft.method) {
                    ForEach(DeveloperHTTPMethod.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("携带当前登录令牌", isOn: $draft.useAuthentication)
                if draft.useAuthentication && !isOfficialHost {
                    Label("令牌将发送到自定义域名：\(hostDescription)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("保存为环境收藏") { saveName = ""; showingSaveEnvironment = true }
                if !store.environments.isEmpty {
                    Menu("选择收藏环境") {
                        ForEach(store.environments) { environment in
                            Button(environment.name) { draft.customBaseURL = environment.baseURL }
                        }
                    }
                }
            }
            Section("查询参数") {
                TextEditor(text: $draft.query).frame(minHeight: 60)
                Text("每行一个 key=value。") .font(.caption).foregroundStyle(.secondary)
            }
            if draft.method != .get {
                Section("JSON 请求体") {
                    TextEditor(text: $draft.jsonBody).font(.system(.body, design: .monospaced)).frame(minHeight: 140)
                }
                Section("文件上传（可选）") {
                    Button(uploadURL == nil ? "选择文件" : "已选择：\(uploadURL!.lastPathComponent)") { showingImporter = true }
                    TextField("multipart 字段名", text: $draft.uploadField).textInputAutocapitalization(.never)
                }
            }
            Section {
                Button(isSending ? "正在发送…" : "发送请求") { requestSend() }
                    .frame(maxWidth: .infinity).buttonStyle(.borderedProminent).disabled(isSending)
            } footer: {
                Text("写请求每次均需确认；DELETE 还需要输入 DELETE。自定义 HTTP 与令牌外发有风险。")
            }
            if let result { DeveloperResponseView(session: result) }
        }
        .navigationTitle("请求控制台")
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data]) { outcome in
            if case let .success(url) = outcome { uploadURL = url }
        }
        .sheet(isPresented: $showingMutationConfirmation) { mutationConfirmation }
        .alert("保存环境", isPresented: $showingSaveEnvironment) {
            TextField("环境名称", text: $saveName)
            Button("保存") { store.saveEnvironment(name: saveName, baseURL: draft.customBaseURL) }
            Button("取消", role: .cancel) { }
        } message: { Text("保存的自定义环境不会记住“携带登录令牌”开关。") }
    }

    private var isOfficialHost: Bool {
        URL(string: draft.customBaseURL)?.host?.lowercased() == AppEnvironment.apiBaseURL.host?.lowercased()
    }
    private var hostDescription: String { URL(string: draft.customBaseURL)?.host ?? draft.customBaseURL }

    private var mutationConfirmation: some View {
        NavigationStack {
            Form {
                Section("即将发送") {
                    Text("\(draft.method.rawValue) \(draft.customBaseURL)\(draft.path)").font(.system(.footnote, design: .monospaced))
                    Text(draft.useAuthentication ? "会携带当前登录令牌" : "匿名请求")
                }
                if draft.method == .delete {
                    TextField("输入 DELETE 以确认", text: $deletionPhrase).textInputAutocapitalization(.characters)
                }
            }
            .navigationTitle("确认写请求")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showingMutationConfirmation = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") { showingMutationConfirmation = false; send() }
                        .disabled(draft.method == .delete && deletionPhrase != "DELETE")
                }
            }
        }
    }

    private func requestSend() {
        if draft.method.changesServerState { deletionPhrase = ""; showingMutationConfirmation = true }
        else { send() }
    }

    private func send() {
        isSending = true
        Task {
            defer { isSending = false }
            var data: Data?
            var filename: String?
            if let uploadURL {
                let scoped = uploadURL.startAccessingSecurityScopedResource()
                defer { if scoped { uploadURL.stopAccessingSecurityScopedResource() } }
                data = try? Data(contentsOf: uploadURL)
                filename = uploadURL.lastPathComponent
            }
            result = await DeveloperRequestExecutor(sessionStore: model.sessionStore).execute(draft: draft, baseURL: draft.customBaseURL, upload: data, uploadFilename: filename)
        }
    }
}

private struct DeveloperResponseView: View {
    let session: DeveloperSession
    var body: some View {
        Section("响应") {
            LabeledContent("状态", value: session.statusCode.map(String.init) ?? "请求失败")
            LabeledContent("耗时", value: "\(session.durationMilliseconds) ms")
            LabeledContent("传输", value: "↑ \(ByteCountFormatter.string(fromByteCount: Int64(session.requestBytes), countStyle: .file)) · ↓ \(ByteCountFormatter.string(fromByteCount: Int64(session.responseBytes), countStyle: .file))")
            if let error = session.errorMessage { Text(error).foregroundStyle(.red) }
            if !session.responseHeaders.isEmpty {
                DisclosureGroup("响应头") { Text(session.responseHeaders.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }
            DisclosureGroup("响应正文", isExpanded: .constant(true)) {
                Text(pretty(session.responseBody)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
    private func pretty(_ value: String) -> String {
        guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data), let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return value }
        return String(data: pretty, encoding: .utf8) ?? value
    }
}

private struct DeveloperRouteCatalogView: View {
    private struct Route: Identifiable {
        let path: String; let method: String; let authenticated: Bool
        var id: String { path + method }
    }
    private let routes: [Route] = [
        .init(path: "/user/profile", method: "GET", authenticated: true), .init(path: "/forum/posts?page=1", method: "GET", authenticated: true), .init(path: "/notifications", method: "GET", authenticated: true),
        .init(path: "/notifications/read", method: "POST", authenticated: true), .init(path: "/rank/coins", method: "GET", authenticated: true), .init(path: "/rank/playtime", method: "GET", authenticated: true),
        .init(path: "/mods.json", method: "GET", authenticated: false), .init(path: "/upload/image", method: "POST multipart", authenticated: true)
    ]
    var body: some View {
        List {
            Section("已知接口") {
                ForEach(routes) { route in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(route.path).font(.system(.body, design: .monospaced))
                        Text("\(route.method) · \(route.authenticated ? "需要认证" : "匿名")").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: { Text("目录是快速入口；请求控制台支持任意路径与手动 URL。") }
        }.navigationTitle("接口目录")
    }
}

private struct DeveloperSessionsView: View {
    @ObservedObject private var store = DeveloperToolsStore.shared
    @State private var exportRaw = false
    @State private var rawExportURL: URL?
    @State private var showingRawShare = false
    var body: some View {
        List {
            if store.sessions.isEmpty { Text("暂无开发者请求记录").foregroundStyle(.secondary) }
            ForEach(store.sessions.reversed()) { session in
                NavigationLink { DeveloperResponseView(session: session).navigationTitle("请求详情") } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(session.method) \(session.url)").lineLimit(1).font(.system(.subheadline, design: .monospaced))
                        Text("\(session.statusCode.map(String.init) ?? "错误") · \(session.durationMilliseconds) ms · \(session.responseBytes) B").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("最近请求")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let url = store.exportURL(redacted: true) { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("导出脱敏记录") }
            }
            ToolbarItem(placement: .topBarTrailing) { Button("原文导出") { exportRaw = true }.disabled(store.sessions.isEmpty) }
        }
        .alert("导出完整响应？", isPresented: $exportRaw) {
            Button("继续") {
                rawExportURL = store.exportURL(redacted: false)
                showingRawShare = rawExportURL != nil
            }
            Button("取消", role: .cancel) { }
        } message: { Text("完整导出可能包含令牌、个人资料或密码字段。") }
        .sheet(isPresented: $showingRawShare) {
            NavigationStack {
                VStack(spacing: 18) {
                    Image(systemName: "exclamationmark.shield.fill").font(.system(size: 42)).foregroundStyle(.orange)
                    Text("原文记录可能包含敏感信息。")
                    if let rawExportURL { ShareLink(item: rawExportURL) { Label("分享原文记录", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent) }
                }
                .padding().navigationTitle("原文导出")
            }
        }
    }
}

private struct DeveloperPerformanceView: View {
    @ObservedObject private var monitor = PerformanceMonitor.shared
    @AppStorage("developer.continuousSampling") private var continuousSampling = false
    var body: some View {
        List {
            if let value = monitor.current {
                Section("当前设备") {
                    LabeledContent("电量", value: value.batteryLevel < 0 ? "未知" : "\(Int(value.batteryLevel * 100))%")
                    LabeledContent("电池状态", value: value.batteryState)
                    LabeledContent("热状态", value: value.thermalState)
                    LabeledContent("低电量模式", value: value.lowPowerMode ? "开启" : "关闭")
                    LabeledContent("可用磁盘", value: ByteCountFormatter.string(fromByteCount: value.availableDiskBytes, countStyle: .file))
                    LabeledContent("物理内存", value: ByteCountFormatter.string(fromByteCount: Int64(value.physicalMemoryBytes), countStyle: .memory))
                    LabeledContent("活动处理器", value: "\(value.processorCount)")
                }
            }
            Section("采样") {
                Toggle("持续采样", isOn: $continuousSampling)
                Button("立即采样") { monitor.sample() }
                Text("默认只在本页每 2 秒采样；持续采样开启后，在 App 前台持续记录。") .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("性能追踪")
        .onAppear { monitor.start(continuous: true) }
        .onDisappear { if !continuousSampling { monitor.stop() } }
    }
}

private struct DeveloperEnvironmentView: View {
    @ObservedObject private var store = DeveloperToolsStore.shared
    var body: some View {
        List {
            Section("官方") { Text("\(DeveloperEnvironment.official.name)\n\(DeveloperEnvironment.official.baseURL)") }
            Section("收藏环境") {
                if store.environments.isEmpty { Text("暂无收藏环境").foregroundStyle(.secondary) }
                ForEach(store.environments) { environment in
                    VStack(alignment: .leading) { Text(environment.name); Text(environment.baseURL).font(.caption).foregroundStyle(.secondary) }
                }.onDelete { offsets in offsets.map { store.environments[$0] }.forEach(store.deleteEnvironment) }
            }
        }.navigationTitle("环境收藏夹")
    }
}

private struct DeveloperStorageView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store = DeveloperToolsStore.shared
    @State private var resetText = ""
    @State private var showReset = false
    var body: some View {
        List {
            Section("占用") {
                LabeledContent("开发者诊断", value: ByteCountFormatter.string(fromByteCount: store.diskUsage(), countStyle: .file))
                LabeledContent("完整会话", value: "\(store.sessions.count) / 20")
            }
            Section("分项清理") {
                Button("清除开发者会话", role: .destructive) { store.clearSessions() }
                Button("清除性能记录", role: .destructive) { store.clearPerformance() }
                Button("清除环境收藏夹", role: .destructive) { store.clearEnvironments() }
                Button("清除 URL 缓存", role: .destructive) { URLCache.shared.removeAllCachedResponses() }
                Button("清除下载记录和文件", role: .destructive) { DownloadManager.shared.records.forEach(DownloadManager.shared.delete) }
            }
            Section("恢复初始状态") {
                Button("恢复初始状态", role: .destructive) { resetText = ""; showReset = true }
            }
        }
        .navigationTitle("数据与缓存")
        .alert("恢复初始状态", isPresented: $showReset) {
            TextField("输入 RESET", text: $resetText)
            Button("清除", role: .destructive) { store.resetAll(); model.logout() }.disabled(resetText != "RESET")
            Button("取消", role: .cancel) { }
        } message: { Text("将清除登录状态、调试会话、日志、缓存、下载和环境收藏。") }
    }
}
