import SwiftUI
import CoreImage.CIFilterBuiltins

struct ChatHistoryView: View {
    @EnvironmentObject private var chat: ChatController
    @State private var packs: [JSONValue] = []
    @State private var prepared: [ChatPreparedPack] = []
    @State private var backup: ChatPreparedPack?
    @State private var savedKey = false
    @State private var recoveryID = ""
    @State private var recoveryKey = ""
    @State private var transferCode = ""
    @State private var pairing: ChatPairing?
    @State private var transferID = ""
    @State private var message = ""
    @State private var working = false
    @State private var confirmBackup = false
    @State private var confirmApprove = false
    @State private var deletion: JSONValue?
    @State private var quota = ""
    private var available: Bool { chat.features.contains("encrypted_backups") && chat.features.contains("device_history_transfer") }

    var body: some View {
        Form {
            if !available {
                Section {
                    Label("当前中继尚未启用 R2", systemImage: "externaldrive.badge.exclamationmark")
                    Text("加密备份与设备迁移暂不可用。客户端不会发送无意义请求、伪造上传成功或把登录当作历史恢复。请联系中继维护方开通私有存储。")
                }
            }
            Section("恢复边界") {
                Text("所有加密在本机完成；备份含可读聊天历史及历史私钥。恢复密钥独立于登录密码，丢失后无法找回。服务端只保存密文。")
                Text("仅恢复到相同账号及中继，按消息 ID 去重，并应用最新个人隐藏、清空和双方撤回过滤。恢复不产生新消息、未读或提醒。")
                    .font(.caption).foregroundStyle(.secondary)
                if !quota.isEmpty { Text(quota).font(.caption) }
            }
            Section("手动加密备份") {
                Button("生成备份与独立恢复密钥") { confirmBackup = true }.disabled(!available || working)
                if let backup {
                    Text("备份 ID：\(backup.id)").font(.caption).textSelection(.enabled)
                    Text(backup.root).font(.system(.caption, design: .monospaced)).textSelection(.enabled).privacySensitive()
                    Button("复制恢复密钥（仅本机剪贴板 60 秒）") { copySecret(backup.root) }
                    Toggle("我已在安全位置保存恢复密钥", isOn: $savedKey)
                    Button("上传此加密备份") { run { try await chat.uploadBackup(backup); message = "备份已就绪。30天从创建算起，读取不会续期。"; await load() } }.disabled(!available || working || !savedKey)
                }
                Text("密文分块1MiB，单包100MiB；账号额度和并发限制以服务器为准。上传中断后使用原加密分块续传，不重新加密同一包。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("恢复手动备份") {
                TextField("备份 ID", text: $recoveryID).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("独立恢复密钥", text: $recoveryKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("校验、解密并恢复到本机") { run {
                    try await chat.restoreBackup(id: recoveryID.trimmingCharacters(in: .whitespacesAndNewlines), recoveryKey: recoveryKey)
                    recoveryKey = ""; message = "恢复完成，未重发消息或改变服务器未读。"
                } }.disabled(!available || working || recoveryID.isEmpty || recoveryKey.isEmpty)
            }
            Section("可信设备迁移 · 新设备") {
                Button("发起接收请求") { run {
                    let result = try await chat.beginTransfer(); pairing = result; transferID = result.packID
                    message = "请在10分钟内让旧可信设备批准；临时加密包24小时到期。"
                } }.disabled(!available || working)
                if let pairing, let code = try? String(data: JSONEncoder().encode(pairing), encoding: .utf8) {
                    if let image = qr(code) { Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 240).accessibilityLabel("包含本次迁移秘密的二维码").privacySensitive() }
                    Button("复制迁移码到旧设备") { copySecret(code) }
                    Text("此码含一次性配对秘密。只在自己的可信设备间传递，不要发到论坛或日志。")
                        .font(.caption).foregroundStyle(.orange)
                }
                TextField("本机发起的迁移包 ID", text: $transferID).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("接收已批准的加密历史") { run { try await chat.receiveTransfer(id: transferID); message = "迁移完成，已校验批准证明并提交恢复确认。" } }
                    .disabled(!available || working || UUID(uuidString: transferID) == nil)
            }
            Section("可信设备迁移 · 旧设备") {
                SecureField("从新设备粘贴迁移码", text: $transferCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("核对并批准上传历史") { confirmApprove = true }.disabled(!available || working || transferCode.isEmpty)
                Text("只批准你本人刚发起的请求；服务端确认账号/候选设备，接收方还会独立校验二维码秘密和批准证明。不新增相机权限，可用系统相机读取二维码后复制迁移码。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !prepared.isEmpty {
                Section("本机加密分块与续传") {
                    ForEach(prepared) { p in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(p.kind == "backup" ? "手动备份" : "设备迁移")
                            Text(p.id).font(.caption).textSelection(.enabled)
                            Button("使用原分块继续上传") { run { try await chat.resumePrepared(p); message = "该包已上传并完成。"; await load() } }.disabled(working || !available)
                            if p.kind == "backup" { Button("再次查看恢复密钥") { backup = p; savedKey = false } }
                        }
                    }
                }
            }
            Section("云端恢复包") {
                Button("刷新配额与恢复包") { Task { await load() } }.disabled(!available || working)
                ForEach(Array(packs.enumerated()), id: \.offset) { _, pack in packRow(pack) }
            }
            if !message.isEmpty { Section { Text(message).foregroundStyle(.secondary) } }
            if let problem = chat.error { Section { Text(problem).foregroundStyle(.orange) } }
        }
        .navigationTitle("加密历史恢复")
        .task { if available { await load() } }
        .onDisappear { recoveryKey = ""; transferCode = ""; backup = nil; pairing = nil }
        .alert("创建含历史私钥的加密备份？", isPresented: $confirmBackup) {
            Button("取消", role: .cancel) {}
            Button("在本机准备备份") { run { backup = try await chat.prepareBackup(); savedKey = false; await load() } }
        } message: { Text("只有独立恢复密钥可以解密。请将密钥单独安全保存，不能把它当作登录密码或发给中继。") }
        .alert("批准此设备接收历史？", isPresented: $confirmApprove) {
            Button("取消", role: .cancel) {}
            Button("批准并上传") { run { try await chat.approveTransfer(transferCode); transferCode = ""; message = "已加密上传，等待目标设备校验并导入。"; await load() } }
        } message: { Text("请输入你本人新设备刚展示的完整迁移码。包中会包含聊天历史与历史解密私钥。") }
        .alert("取消并删除此恢复包？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("取消", role: .cancel) { deletion = nil }
            Button("删除恢复包", role: .destructive) {
                if let p = deletion { run {
                    let kind = p["kind"]?.stringValue == "backup" ? "backups" : "transfers"
                    let id = try p.chatString("pack_id")
                    _ = try await chat.json("/chat/v2/history/\(kind)/\(id)", method: "DELETE", query: [URLQueryItem(name: "expected_revision", value: p["revision"]?.stringValue ?? "0")]); await load()
                } }; deletion = nil
            }
        } message: { Text("删除成功后由服务器清理密文，实际对象清理完成前不释放预留额度。不会撤销此前已恢复的本机历史。") }
    }
    private func packRow(_ pack: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(pack["kind"]?.stringValue == "backup" ? "手动备份" : "可信设备迁移")
            Text(pack["pack_id"]?.stringValue ?? "").font(.caption).textSelection(.enabled)
            Text("状态：\(pack["state"]?.stringValue ?? "未知")").font(.caption).foregroundStyle(.secondary)
            if let expiry = Int64(pack["expires_at_ms"]?.stringValue ?? "") { Text("到期：" + Date(timeIntervalSince1970: Double(expiry) / 1000).formatted()).font(.caption) }
            HStack {
                if pack["kind"]?.stringValue == "backup" { Button("选择恢复") { recoveryID = pack["pack_id"]?.stringValue ?? "" } }
                Spacer(); Button("删除", role: .destructive) { deletion = pack }
            }.buttonStyle(.borderless).disabled(working)
        }
    }
    private func run(_ action: @escaping () async throws -> Void) {
        working = true; message = "正在本机处理并传输加密分块…"
        Task { defer { working = false }; await chat.perform(action) }
    }
    private func load() async {
        guard available else { return }
        await chat.perform {
            let q = try await chat.json("/chat/v2/history/quota")
            quota = "已预留：\(q["reserved_bytes"]?.stringValue ?? "0") / \(q["account_bytes"]?.stringValue ?? "0") 字节"
            prepared = try await chat.preparedHistory()
            var result: [JSONValue] = []
            for kind in ["backups", "transfers"] {
                var before: String?
                repeat {
                    var query = [URLQueryItem(name: "limit", value: "100")]; if let before { query.append(URLQueryItem(name: "before", value: before)) }
                    let page = try await chat.json("/chat/v2/history/\(kind)", query: query); result += try page["packs"].chatArray()
                    before = page["has_more"]?.boolValue == true ? page["next_before"]?.stringValue : nil
                } while before != nil
            }
            packs = result
        }
    }
    private func copySecret(_ value: String) { UIPasteboard.general.setItems([["public.utf8-plain-text": value]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]) }
    private func qr(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8)
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
