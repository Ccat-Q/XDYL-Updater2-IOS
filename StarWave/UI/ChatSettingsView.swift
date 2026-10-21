import SwiftUI

struct ChatSettingsView: View {
    @EnvironmentObject private var chat: ChatController
    @State private var confirmDisable = false
    @State private var confirmClear = false
    @State private var pendingDelete: ChatPendingSend?
    var body: some View {
        Group {
            if !chat.enabled { ChatConsentView() }
            else {
                Form {
                    ChatStatusSection()
                    Section("账号与安全") {
                        Text(chat.relayText).font(.footnote).textSelection(.enabled)
                        NavigationLink("接收权限、已读与保留期") { ChatPrivacyView() }
                        NavigationLink("聊天设备与公钥") { ChatDevicesView() }
                        NavigationLink("屏蔽列表") { ChatBlocksView() }
                    }
                    Section("提醒") {
                        NavigationLink("默认与设备提醒") { ChatNotificationSettingsView() }
                        NavigationLink("Bark 绑定与状态") { ChatBarkView() }
                        Text("仅应用前台同步。Bark 提醒不会传递聊天正文，也不代表已读。通知后请手动打开应用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("历史与本机数据") {
                        NavigationLink("加密备份与设备迁移") { ChatHistoryView() }
                        Button("清除本机聊天历史", role: .destructive) { confirmClear = true }
                        Text("清历史不删除 Keychain 私钥、不重置同步游标，也不删除对方记录。账号退出后停止请求并隐藏本地历史。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !chat.pending.isEmpty {
                        Section("待重试的原始发送") {
                            ForEach(chat.pending) { item in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.message.text ?? "文字消息").lineLimit(2)
                                    HStack {
                                        Button("原样重试") { Task { await chat.perform { try await chat.retry(item) } } }
                                        Spacer()
                                        Button("移除本地待发", role: .destructive) { pendingDelete = item }
                                    }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    Section { Button("停用聊天或更换中继", role: .destructive) { confirmDisable = true } }
                }
            }
        }
        .navigationTitle("私聊设置")
        .alert("停用私聊？", isPresented: $confirmDisable) {
            Button("取消", role: .cancel) {}; Button("停用", role: .destructive) { chat.setEnabled(false) }
        } message: { Text("立即停止聊天请求并隐藏历史。不会删除私钥或服务器设备；Bark 绑定需另行停用或解绑。更换中继后必须重新同意。") }
        .alert("清除本机历史？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}; Button("清除", role: .destructive) { Task { await chat.perform { try await chat.clearLocal() } } }
        } message: { Text("本机消息、草稿和待发队列将删除，密钥和游标保留。不能撤销可能已被服务器接受的发送。") }
        .alert("移除本地待发？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("移除", role: .destructive) { if let item = pendingDelete { Task { await chat.perform { try await chat.discardPending(item) } } }; pendingDelete = nil }
        } message: { Text("这不是服务端撤回。若此前已被接受，消息仍可能送达并在后续同步出现。") }
    }
}

private struct ChatPrivacyView: View {
    @EnvironmentObject private var chat: ChatController
    @State private var revision = "0"
    @State private var policy = "everyone"
    @State private var receipts = true
    @State private var retention = 30
    @State private var ready = false
    @State private var saving = false
    @State private var loadRevision = UUID()
    var body: some View {
        Form {
            ChatStatusSection()
            Section("谁可以发给我") {
                Picker("接收权限", selection: $policy) {
                    Text("所有人").tag("everyone"); Text("我曾主动联系的人").tag("existing"); Text("不接收新消息").tag("none")
                }
                Toggle("公开我的未来已读", isOn: $receipts)
                Text("关闭仍记录自己的阅读进度并清除未读，也仍可看到对方公开已读；不会收回已经披露的回执。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(saving || !ready)
            Section("自己的中继副本") {
                Picker("保留期限", selection: $retention) { Text("1 天").tag(1); Text("7 天").tag(7); Text("30 天").tag(30) }
                Text("缩短立即裁剪自己的中继副本，不影响对方；延长不会恢复已过期内容。已在本机保存的历史需另行清理。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(saving || !ready)
            Button(saving ? "正在保存…" : "保存") { save() }.disabled(!ready || saving)
            Button("重新读取") { Task { await load() } }.disabled(saving)
        }
        .navigationTitle("隐私与保留")
        .task { await load() }
    }
    private func load() async {
        ready = false; let stamp = UUID(); loadRevision = stamp
        await chat.perform {
            let p = try await chat.json("/chat/v2/me/preferences")
            guard loadRevision == stamp else { return }
            revision = try p.chatSequence("revision")
            policy = p["receive_policy"]?.stringValue ?? "everyone"; receipts = p["read_receipts"]?.boolValue ?? true
            retention = p["retention_days"]?.integer ?? 30; ready = true
        }
    }
    private func save() {
        saving = true
        Task { defer { saving = false }; await chat.perform {
            _ = try await chat.json("/chat/v2/me/preferences", method: "PATCH", body: .object(["expected_revision": .string(revision), "receive_policy": .string(policy), "read_receipts": .bool(receipts), "retention_days": .number(Double(retention))])); await load()
        } }
    }
}

private struct ChatDevicesView: View {
    @EnvironmentObject private var chat: ChatController
    @State private var devices: [JSONValue] = []
    @State private var keys: [JSONValue] = []
    @State private var accountFingerprint = ""
    @State private var compatibility = "尚未读取"
    @State private var revokeID: String?
    @State private var confirmNew = false
    @State private var confirmLegacy = false
    var body: some View {
        List {
            ChatStatusSection()
            Section("设备") {
                ForEach(Array(devices.enumerated()), id: \.offset) { _, d in deviceRow(d) }
                Button("刷新设备") { Task { await load() } }
            }
            Section("本机公钥指纹") {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key["algorithm"]?.stringValue ?? "算法")
                        Text(ChatCrypto.digest(Data((key["public_key"]?.stringValue ?? "").utf8)))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Text("只展示公钥指纹，不展示或复制私钥。请通过带外方式核对联系人的设备集合指纹。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("本账号设备集合指纹") {
                Text(accountFingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("让联系人与其查询页面展示的集合指纹核对；设备增减或公钥变化会改变此值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("旧安卓互通") {
                Text(compatibility).font(.footnote)
                Button("将本机明确设为兼容主设备") { confirmLegacy = true }
                Text("旧协议消息只提供给此持钥主设备。已有另一旧安卓私钥或主设备时，服务端会拒绝覆盖。不同曲线的两个旧安卓仍不能直接互聊。")
                    .font(.caption).foregroundStyle(.orange)
            }
            Section {
                Button("创建新的聊天设备身份", role: .destructive) { confirmNew = true }
                Text("用于本机身份已被撤销或需要明确重建的情况。保留旧私钥和本地历史，但新设备没有完整云历史；上限为8个未撤销设备。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("聊天设备")
        .task { await load() }
        .alert("撤销此聊天设备？", isPresented: Binding(get: { revokeID != nil }, set: { if !$0 { revokeID = nil } })) {
            Button("取消", role: .cancel) { revokeID = nil }
            Button("撤销", role: .destructive) { if let id = revokeID { Task { await chat.perform { try await chat.revokeDevice(id); await load() } } }; revokeID = nil }
        } message: { Text("立即注销其聊天会话并取消Bark待发任务。不能远程删除它已保存的内容。") }
        .alert("创建新设备身份？", isPresented: $confirmNew) {
            Button("取消", role: .cancel) {}; Button("创建新身份", role: .destructive) { Task { await chat.perform { try await chat.createNewDevice() } } }
        } message: { Text("不会接管另一台旧协议主设备；新身份将重新同步并明确保留历史缺口。") }
        .alert("启用旧安卓兼容主设备？", isPresented: $confirmLegacy) {
            Button("取消", role: .cancel) {}; Button("我了解限制，启用") { Task { await chat.perform { try await chat.enableLegacy(); await load() } } }
        } message: { Text("需新前端使用旧套件发给安卓；不会在中继解密，也不会覆盖原有旧公钥。") }
    }
    private func deviceRow(_ d: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text((d["device_name"]?.stringValue ?? "设备") + (d["device_id"]?.stringValue == chat.currentDeviceID ? "（本机）" : ""))
            Text(d["device_id"]?.stringValue ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if d["revoked"]?.boolValue == true { Text("已撤销").font(.caption).foregroundStyle(.secondary) }
            else { Button("撤销", role: .destructive) { revokeID = d["device_id"]?.stringValue }.buttonStyle(.borderless) }
        }
    }
    private func load() async {
        await chat.perform {
            devices = try await chat.json("/chat/v2/devices")["devices"].chatArray()
            let own = try await chat.json("/chat/v2/users/\(ChatValidation.segment(chat.username))/keys")
            keys = own["devices"]?.arrayValue.first(where: { $0["device_id"]?.stringValue == chat.currentDeviceID })?["keys"]?.arrayValue ?? []
            var publicKeys: [String: JSONValue] = [:]
            for device in own["devices"]?.arrayValue ?? [] {
                for key in device["keys"]?.arrayValue ?? [] { publicKeys[try key.chatString("key_id")] = key["public_key"] }
            }
            let protocols = try await chat.json("/chat/v2/users/\(ChatValidation.segment(chat.username))/protocols")
            for key in protocols["legacy_public_keys"]?.arrayValue ?? [] {
                let alg = try key.chatString("algorithm"), pub = try key.chatString("public_key")
                publicKeys[ChatCrypto.legacyID(alg, pub)] = .string(pub)
            }
            accountFingerprint = ChatCrypto.digest(try ChatCrypto.canonical(.object(publicKeys)))
            let legacy = try await chat.json("/chat/v2/devices/\(chat.currentDeviceID)/legacy")
            compatibility = legacy["enabled"]?.boolValue == true ? "兼容主设备：\(legacy["device_id"]?.stringValue ?? "")" : "未启用旧协议兼容"
        }
    }
}

private struct ChatBlocksView: View {
    @EnvironmentObject private var chat: ChatController
    @State private var blocked: [JSONValue] = []
    var body: some View {
        List {
            ChatStatusSection()
            if blocked.isEmpty { Text("暂无屏蔽账号").foregroundStyle(.secondary) }
            ForEach(Array(blocked.enumerated()), id: \.offset) { _, b in
                let subject = b["subject"]?.stringValue ?? ""
                HStack {
                    Text(chat.peers.first(where: { $0.subject == subject })?.title ?? subject)
                    Spacer()
                    Button("解除屏蔽") { Task { await chat.perform {
                        _ = try await chat.json("/chat/v2/blocks/\(ChatValidation.segment(subject))", method: "DELETE"); await load()
                    } } }.buttonStyle(.borderless)
                }
            }
        }.navigationTitle("屏蔽列表").task { await load() }.refreshable { await load() }
    }
    private func load() async { await chat.perform { blocked = try await chat.json("/chat/v2/blocks")["blocked"].chatArray() } }
}

struct ChatNotificationSettingsView: View {
    @EnvironmentObject private var chat: ChatController
    @Environment(\.dismiss) private var dismiss
    var conversationID: String?
    @State private var scope = "account"
    @State private var revision = "0"
    @State private var enabled = "inherit"
    @State private var muted = "inherit"
    @State private var quiet = "inherit"
    @State private var zone = TimeZone.current.identifier
    @State private var start = "23:00"
    @State private var end = "07:00"
    @State private var weekdays: Set<Int> = Set(1...7)
    @State private var until = ""
    @State private var effective = "尚未读取"
    @State private var ready = false
    @State private var saving = false
    @State private var loadRevision = UUID()
    private var base: String {
        let owner = scope == "account" ? "me" : "devices/\(chat.currentDeviceID)"
        return "/chat/v2/" + owner + (conversationID.map { "/conversations/" + $0 } ?? "") + "/notifications"
    }
    var body: some View {
        Form {
            ChatStatusSection()
            Section {
                Picker("配置范围", selection: $scope) { Text("账号").tag("account"); Text("当前设备").tag("device") }
                inheritancePicker("提醒", value: $enabled).disabled(!ready); inheritancePicker("静音", value: $muted).disabled(!ready)
                TextField("静音至 Unix 毫秒（留空继承，0清除）", text: $until).keyboardType(.numberPad).disabled(!ready)
            }.disabled(saving)
            Section("静默时间") {
                Picker("时段", selection: $quiet) { Text("继承上层").tag("inherit"); Text("明确关闭").tag("off"); Text("自定义").tag("on") }
                if quiet == "on" {
                    TextField("IANA 时区", text: $zone).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("开始 HH:mm", text: $start); TextField("结束 HH:mm", text: $end)
                    ForEach(1...7, id: \.self) { day in Toggle("周" + ["一","二","三","四","五","六","日"][day - 1], isOn: Binding(get: { weekdays.contains(day) }, set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } })) }
                }
                Text("账号默认 → 设备默认 → 账号会话 → 设备会话逐字段覆盖。静默结束只汇总仍未读的消息；仅接收不算已读。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(saving || !ready)
            Section("当前设备最终效果") { Text(effective).font(.footnote) }
            Button(saving ? "正在保存…" : "保存本层设置") { save() }.disabled(!ready || saving)
            Button("重新读取") { Task { await load() } }.disabled(saving)
        }
        .navigationTitle(conversationID == nil ? "私聊提醒" : "会话提醒")
        .task(id: base) { await load() }
    }
    private func inheritancePicker(_ title: String, value: Binding<String>) -> some View {
        Picker(title, selection: value) { Text("继承").tag("inherit"); Text("开启").tag("on"); Text("关闭").tag("off") }
    }
    private func load() async {
        ready = false; let target = base, stamp = UUID(); loadRevision = stamp
        await chat.perform {
            let result = try await chat.json(target); try Task.checkCancellation(); guard target == base, stamp == loadRevision else { return }
            revision = try result.chatSequence("revision"); let o = result["overrides"] ?? .object([:])
            enabled = o["enabled"]?.boolValue.map { $0 ? "on" : "off" } ?? "inherit"
            muted = o["muted"]?.boolValue.map { $0 ? "on" : "off" } ?? "inherit"
            until = o["mute_until_ms"]?.stringValue ?? ""
            if o["quiet_hours"] == .null { quiet = "off" }
            else if let h = o["quiet_hours"] {
                quiet = "on"; zone = h["timezone"]?.stringValue ?? "UTC"; start = h["start"]?.stringValue ?? "23:00"; end = h["end"]?.stringValue ?? "07:00"
                weekdays = Set(h["weekdays"]?.arrayValue.compactMap(\.integer) ?? [])
            } else { quiet = "inherit" }
            let e = result["effective"] ?? .null
            effective = "提醒：\(e["enabled"]?.boolValue == true ? "开" : "关")，静音：\(e["muted"]?.boolValue == true ? "开" : "关")\n静默时区：\(e["quiet_hours"]?["timezone"]?.stringValue ?? "无")"
            ready = true
        }
    }
    private func save() {
        saving = true
        Task {
            defer { saving = false }
            await chat.perform {
                var o: [String: JSONValue] = [:]
                if enabled != "inherit" { o["enabled"] = .bool(enabled == "on") }; if muted != "inherit" { o["muted"] = .bool(muted == "on") }
                if !until.isEmpty { guard let value = Double(until), value >= 0, value <= 9007199254740991, value.rounded() == value else { throw ChatFailure.invalid("静音时间必须为非负毫秒整数。") }; o["mute_until_ms"] = .number(value) }
                if quiet == "off" { o["quiet_hours"] = .null }
                if quiet == "on" {
                    guard TimeZone(identifier: zone) != nil, !weekdays.isEmpty,
                          start.range(of: #"^(?:[01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil,
                          end.range(of: #"^(?:[01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil, start != end else { throw ChatFailure.invalid("请检查静默时区、时刻和星期。") }
                    o["quiet_hours"] = .object(["timezone": .string(zone), "start": .string(start), "end": .string(end), "weekdays": .array(weekdays.sorted().map { .number(Double($0)) })])
                }
                _ = try await chat.json(base, method: "PATCH", body: .object(["expected_revision": .string(revision), "overrides": .object(o)])); await load()
            }
        }
    }
}

private struct ChatBarkView: View {
    @EnvironmentObject private var chat: ChatController
    @State private var state = JSONValue.null
    @State private var status = "尚未测试"
    @State private var key = ""
    @State private var enabled = true
    @State private var saving = false
    @State private var ready = false
    @State private var loadRevision = UUID()
    @State private var confirmDelete = false
    private var base: String { "/chat/v2/devices/\(chat.currentDeviceID)/bark" }
    var body: some View {
        Form {
            ChatStatusSection()
            Section("官方 Bark") {
                Text("https://api.day.app")
                Text("请先安装 Bark 并取得设备 Key。只支持官方服务器；通知内容不包含正文、发送人或账号。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("已配置：\(state["device_key_masked"]?.stringValue ?? "无")")
                SecureField("设备 Key（留空保留现有值）", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("允许本设备 Bark 提醒", isOn: $enabled)
                Button("保存绑定或开关") { save() }.disabled(saving || !chat.features.contains("bark"))
                Button("发送通用测试提醒") { run {
                    _ = try await chat.json(base + "/test", method: "POST", body: .object([:])); status = "已排队，不代表手机已经显示。请稍后刷新状态。"
                } }.disabled(saving || state["enabled"]?.boolValue != true)
                Button("读取云端状态") { run { let s = try await chat.json(base + "/status"); status = s["last_result"]?.stringValue ?? "none" } }
                Text(status).font(.footnote)
                Button("删除本设备 Bark 绑定", role: .destructive) { confirmDelete = true }.disabled(saving || state["key_configured"]?.boolValue != true)
            }.disabled(saving || !ready)
            Button("重新读取绑定") { Task { await load() } }.disabled(saving)
        }
        .navigationTitle("Bark 提醒")
        .task { await load() }
        .alert("删除 Bark 绑定？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}; Button("删除", role: .destructive) { run {
                _ = try await chat.json(base, method: "DELETE", query: [URLQueryItem(name: "expected_revision", value: state["revision"]?.stringValue ?? "0")]); await load()
            } }
        } message: { Text("取消未发送任务，不能撤回已在途通知。") }
    }
    private func run(_ operation: @escaping () async throws -> Void) { saving = true; Task { defer { saving = false }; await chat.perform(operation) } }
    private func load() async {
        ready = false; let stamp = UUID(); loadRevision = stamp
        await chat.perform {
            _ = try await chat.connect(); let value = try await chat.json(base)
            guard loadRevision == stamp else { return }
            state = value; enabled = state["enabled"]?.boolValue ?? false; ready = true
        }
    }
    private func save() {
        let submittedKey = key
        var fields: [String: JSONValue] = ["enabled": .bool(enabled), "expected_revision": state["revision"] ?? .string("0")]
        if !submittedKey.isEmpty { fields["device_key"] = .string(submittedKey) }
        let request = JSONValue.object(fields)
        run {
            _ = try await chat.json(base, method: "PUT", body: request); if key == submittedKey { key = "" }; await load()
        }
    }
}
