import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var username = ""
    @State private var password = ""
    @State private var qqSessionID: String?
    @State private var isPollingQQ = false
    @State private var accountFlow: AccountFlow?
    @State private var qqLink: QQLinkContext?
    @State private var loginTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 50, weight: .medium))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("星灯云浪").font(.largeTitle.bold())
                        Text("Minecraft 社区伴侣").foregroundStyle(.secondary)
                    }
                    .padding(.top, 56)

                    VStack(spacing: 14) {
                        TextField("用户名或邮箱", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .textFieldStyle(.roundedBorder)
                        SecureField("密码", text: $password)
                            .textContentType(.password)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            Task { _ = await model.login(account: username, password: password) }
                        } label: {
                            Label("登录", systemImage: "person.badge.key").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(username.isEmpty || password.isEmpty || model.isBusy)

                        Button {
                            beginQQLogin()
                        } label: {
                            Label(isPollingQQ ? "等待 QQ 授权…" : "使用 QQ 登录 / 绑定", systemImage: "qrcode")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isPollingQQ)

                        HStack {
                            Button("注册账号") { accountFlow = .register }
                            Spacer()
                            Button("忘记密码") { accountFlow = .resetPassword }
                        }
                        .font(.subheadline)
                    }
                    .padding(20)
                    .appSurfaceCard(cornerRadius: 22)

                    Text("旧服务的部分接口使用 HTTP。继续登录表示你已了解公共网络中的明文传输风险。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .appContentBackground()
            .navigationTitle("登录")
            .navigationBarTitleDisplayMode(.inline)
            .loading(model.isBusy)
            .sheet(item: $accountFlow) { flow in AccountFlowView(flow: flow) }
            .sheet(item: $qqLink) { context in QQLinkAccountView(context: context) }
            .onDisappear { loginTask?.cancel(); loginTask = nil }
        }
    }

    private func beginQQLogin() {
        let id = UUID().uuidString
        qqSessionID = id
        isPollingQQ = true
        loginTask = Task {
            defer { isPollingQQ = false }
            do {
                openURL(try await model.api.startQQLogin(sessionID: id))
            } catch {
                model.errorMessage = error.localizedDescription
                return
            }
            for _ in 0..<45 {
                guard !Task.isCancelled else { return }
                do {
                    switch try await model.api.qqLoginState(sessionID: id) {
                    case .authenticated: await model.refreshProfile(); return
                    case let .needsBinding(token, nickname): qqLink = QQLinkContext(token: token, nickname: nickname); return
                    case .waiting: break
                    }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch is CancellationError { return } catch { model.errorMessage = error.localizedDescription; return }
            }
            model.errorMessage = "QQ 授权已超时，请重试"
        }
    }
}

private enum AccountFlow: String, Identifiable {
    case register, resetPassword
    var id: String { rawValue }
    var title: String { self == .register ? "注册账号" : "重置密码" }
    var purpose: String { self == .register ? "register" : "reset" }
}

private struct AccountFlowView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let flow: AccountFlow
    @State private var username = ""
    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if flow == .register { TextField("用户名", text: $username).textInputAutocapitalization(.never) }
                TextField("邮箱", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                HStack {
                    TextField("验证码", text: $code).keyboardType(.numberPad)
                    Button("发送验证码") { sendCode() }.disabled(email.isEmpty || busy)
                }
                SecureField(flow == .register ? "密码" : "新密码", text: $password)
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle(flow.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交") { submit() }
                        .disabled(email.isEmpty || code.isEmpty || password.count < 6 || (flow == .register && username.isEmpty) || busy)
                }
            }
        }
    }

    private func sendCode() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let fields: [String: JSONValue] = flow == .register ? ["email": .string(email), "purpose": .string("register")] : ["email": .string(email)]
                _ = try await model.api.post(path: flow == .register ? "/send-verify-code" : "/forgot-password", fields: fields, requiresAuthentication: false, baseURL: AppEnvironment.webBaseURL)
                message = "验证码已发送"
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func submit() {
        busy = true
        Task {
            defer { busy = false }
            do {
                var fields: [String: JSONValue] = ["email": .string(email), flow == .register ? "password" : "new_password": .string(password), "code": .string(code)]
                if flow == .register { fields["username"] = .string(username) }
                _ = try await model.api.post(path: flow == .register ? "/register" : "/reset-password", fields: fields, requiresAuthentication: false, baseURL: AppEnvironment.webBaseURL)
                dismiss()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

private struct QQLinkContext: Identifiable {
    let token: String
    let nickname: String
    var id: String { token }
}

private struct QQLinkAccountView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let context: QQLinkContext
    @State private var account = ""
    @State private var password = ""
    @State private var busy = false
    @State private var register = false
    var body: some View {
        NavigationStack {
            Form {
                Text("\(context.nickname) 尚未绑定社区账号，请关联已有账号；也可以先注册，再回到这里关联。")
                TextField("用户名或邮箱", text: $account).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码", text: $password)
                Button(busy ? "关联中…" : "关联并登录") { link() }.disabled(account.isEmpty || password.isEmpty || busy)
                Button("注册社区账号") { register = true }
            }
            .navigationTitle("关联 QQ")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .sheet(isPresented: $register) { AccountFlowView(flow: .register) }
        }
    }
    private func link() {
        busy = true
        Task {
            defer { busy = false }
            do { try await model.api.linkQQ(token: context.token, account: account, password: password); await model.refreshProfile(); dismiss() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}
