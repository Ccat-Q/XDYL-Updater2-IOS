import SwiftUI
import PhotosUI

struct ProfileView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var showingEdit = false
    @State private var showingPassword = false
    @State private var showingQQBinding = false
    @State private var avatarItem: PhotosPickerItem?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AsyncImage(url: model.profile?.avatarURL) { image in image.resizable().scaledToFill() } placeholder: {
                        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                    }
                    .frame(width: 64, height: 64).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.profile?.nickname ?? "用户").font(.title3.bold())
                        Text("@\(model.profile?.username ?? model.sessionStore.username ?? "-")").foregroundStyle(.secondary)
                        Text("喵喵币：\(model.profile?.balance ?? "0")").font(.caption)
                    }
                }
                .padding(.vertical, 8)
            }
            Section("账户") {
                PhotosPicker(selection: $avatarItem, matching: .images) {
                    Label("更换头像", systemImage: "photo")
                }
                Button { showingEdit = true } label: { Label("编辑资料", systemImage: "person.text.rectangle") }
                Button { showingPassword = true } label: { Label("修改密码", systemImage: "key") }
                if model.profile?.qqNickname == nil {
                    Button { showingQQBinding = true } label: { Label("绑定 QQ", systemImage: "link") }
                } else {
                    Button(role: .destructive) { unbindQQ() } label: {
                        HStack { Label("解绑 QQ", systemImage: "link.badge.minus"); Spacer(); Text(model.profile?.qqNickname ?? "").foregroundStyle(.secondary) }
                    }
                }
            }
            Section("应用") {
                NavigationLink { NotificationsView() } label: {
                    Label("通知", systemImage: "bell")
                    if model.unreadCount > 0 { Spacer(); Text("\(model.unreadCount)").foregroundStyle(.secondary) }
                }
                Link(destination: AppEnvironment.repositoryReleasesURL) { Label("检查 IPA 更新", systemImage: "arrow.triangle.2.circlepath") }
                NavigationLink { SettingsView() } label: { Label("设置", systemImage: "gear") }
                if model.profile?.isAdministrator == true {
                    Button { openURL(AppEnvironment.webBaseURL.appendingPathComponent("webadmin")) } label: { Label("管理后台", systemImage: "lock.shield") }
                }
                HStack { Text("版本"); Spacer(); Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-").foregroundStyle(.secondary) }
            }
            Section {
                Button("退出登录", role: .destructive) { model.logout() }
            }
        }
        .navigationTitle("我的")
        .refreshable { await model.refreshProfile() }
        .sheet(isPresented: $showingEdit) { EditProfileView() }
        .sheet(isPresented: $showingPassword) { ChangePasswordView() }
        .sheet(isPresented: $showingQQBinding) { QQBindingView() }
        .onChange(of: avatarItem) { item in uploadAvatar(item) }
    }

    private func uploadAvatar(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw AppError.invalidDownload }
                _ = try await model.api.upload(path: "/user/avatar", data: data, filename: "avatar.jpg", fieldName: "avatar")
                await model.refreshProfile()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func unbindQQ() {
        Task {
            do { _ = try await model.api.post(path: "/user/unbind-qq", fields: [:]); await model.refreshProfile() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}

private struct SettingsView: View {
    @AppStorage("allowCellularDownloads") private var allowCellularDownloads = true
    @AppStorage("updateChecksEnabled") private var updateChecksEnabled = true

    var body: some View {
        Form {
            Section("下载") {
                Toggle("允许蜂窝网络下载", isOn: $allowCellularDownloads)
                Text("后台下载会在系统允许的时间内继续；蜂窝网络设置在下次启动后生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("更新") {
                Toggle("检查 IPA 更新", isOn: $updateChecksEnabled)
                Link("打开 GitHub Releases", destination: AppEnvironment.repositoryReleasesURL)
            }
            Section("诊断") {
                NavigationLink { DiagnosticsView() } label: { Label("网络日志", systemImage: "doc.text.magnifyingglass") }
                Text("日志只保存在本机，记录请求地址、时间和状态码；不会记录密码、令牌或请求内容。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("网络安全") {
                Label("账户和社区服务使用 HTTPS", systemImage: "lock.shield")
                    .foregroundStyle(.green)
                Text("模组清单服务仍使用旧 HTTP 地址；不要在公共 Wi-Fi 下载或提交敏感信息。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
    }
}

private struct DiagnosticsView: View {
    @ObservedObject private var diagnostics = DiagnosticsStore.shared

    var body: some View {
        List {
            Section {
                if diagnostics.entries.isEmpty {
                    Text("尚无网络请求记录。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(diagnostics.entries.reversed()), id: \.self) { entry in
                        Text(entry)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } footer: {
                Text("最多保留 300 条。日志不含密码、令牌和请求正文。")
            }
        }
        .navigationTitle("网络日志")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !diagnostics.entries.isEmpty {
                    ShareLink(item: diagnostics.logURL) { Image(systemName: "square.and.arrow.up") }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("清除", role: .destructive) { diagnostics.clear() }
                    .disabled(diagnostics.entries.isEmpty)
            }
        }
    }
}

private struct QQBindingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var sessionID = UUID().uuidString
    @State private var polling = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "qrcode").font(.system(size: 64)).foregroundStyle(Color.accentColor)
                Text("在浏览器完成 QQ 授权后返回本 App，绑定状态会自动刷新。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("打开 QQ 授权页面") { start() }.buttonStyle(.borderedProminent).disabled(polling)
                if polling { ProgressView("等待授权…") }
            }
            .padding()
            .navigationTitle("绑定 QQ")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func start() {
        polling = true
        Task {
            defer { polling = false }
            do {
                openURL(try await model.api.startQQLogin(sessionID: sessionID, mode: "bind"))
            } catch {
                model.errorMessage = error.localizedDescription
                return
            }
            for _ in 0..<45 {
                do {
                    if try await model.api.bindQQ(sessionID: sessionID) {
                        await model.refreshProfile()
                        dismiss()
                        return
                    }
                } catch { model.errorMessage = error.localizedDescription; return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            model.errorMessage = "QQ 绑定已超时，请重试"
        }
    }
}

private struct EditProfileView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var email = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("昵称", text: $nickname)
                TextField("邮箱", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress)
            }
            .navigationTitle("编辑资料")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear { nickname = model.profile?.nickname ?? ""; email = model.profile?.email ?? "" }
        }
    }

    private func save() {
        Task {
            do {
                _ = try await model.api.post(path: "/user/profile", fields: ["nickname": .string(nickname), "email": .string(email)])
                await model.refreshProfile()
                dismiss()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

private struct ChangePasswordView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var oldPassword = ""
    @State private var newPassword = ""

    var body: some View {
        NavigationStack {
            Form {
                SecureField("当前密码", text: $oldPassword)
                SecureField("新密码", text: $newPassword)
            }
            .navigationTitle("修改密码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("修改") { save() }.disabled(oldPassword.isEmpty || newPassword.count < 6) }
            }
        }
    }

    private func save() {
        Task {
            do {
                _ = try await model.api.post(path: "/user/password", fields: ["old_password": .string(oldPassword), "new_password": .string(newPassword)])
                dismiss()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

private struct NotificationsView: View {
    var body: some View { RemoteStandaloneList(title: "通知", icon: "bell", path: "/notifications") }
}

struct RemoteStandaloneList: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let icon: String
    let path: String
    @State private var items: [RemoteItem] = []
    @State private var loading = false

    var body: some View {
        Group {
            if loading && items.isEmpty { ProgressView() }
            else if items.isEmpty { EmptyStateView(icon: icon, title: "暂无\(title)", message: "下拉刷新") }
            else { List(items) { RemoteItemRow(item: $0) }.refreshable { await load() } }
        }
        .navigationTitle(title)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { items = try await model.api.values(path: path) }
        catch { model.errorMessage = error.localizedDescription }
    }
}
