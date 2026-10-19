import SwiftUI

struct CommunityView: View {
    @State private var selection = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("社区内容", selection: $selection) { Text("论坛").tag(0); Text("私聊").tag(1) }
                .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            if selection == 0 { ForumFeedView() } else { ChatInboxView() }
        }
        .navigationTitle("社区")
    }
}

struct ChatInboxView: View {
    @EnvironmentObject private var chat: ChatController
    @State private var showingNew = false
    @State private var selected: ChatPeer?
    @State private var archived = false
    @State private var search = ""

    var body: some View {
        Group {
            if !chat.enabled { ChatConsentView() }
            else {
                List {
                    ChatStatusSection()
                    if chat.needsReset {
                        Section {
                            Text("服务端同步位置已过期。本地历史保留，重新同步也不能补回已过期或缺少密钥的消息。")
                            Button("保留本地历史并重新同步") { Task { await chat.perform { try await chat.resetCursor() } } }
                        }
                    }
                    Section {
                        Toggle("查看归档会话", isOn: $archived)
                        if visiblePeers.isEmpty { Text("暂无私聊。使用右上角按钮，按用户名添加联系人。 ").foregroundStyle(.secondary) }
                        ForEach(visiblePeers) { peer in
                            NavigationLink { ChatThreadView(peer: peer) } label: { conversationRow(peer) }
                        }
                    }
                }
                .searchable(text: $search, prompt: "联系人备注、用户名或本地消息")
                .refreshable { await chat.refresh() }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                NavigationLink { ChatSettingsView() } label: { Image(systemName: "gearshape") }.accessibilityLabel("私聊设置")
                if chat.enabled { Button { showingNew = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("新建私聊") }
            }
        }
        .sheet(isPresented: $showingNew) {
            NavigationStack { ChatNewContactView { peer in selected = peer; showingNew = false } }
        }
        .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected { ChatThreadView(peer: selected) }
        }
    }
    private var visiblePeers: [ChatPeer] {
        chat.peers.filter { peer in
            let conv = chat.conversations.first { $0.peerSubject == peer.subject }
            guard (conv?.archived ?? false) == archived else { return false }
            return search.isEmpty || peer.title.localizedCaseInsensitiveContains(search) || peer.username.localizedCaseInsensitiveContains(search)
                || chat.messages.contains { $0.peerSubject == peer.subject && ($0.text?.localizedCaseInsensitiveContains(search) ?? false) }
        }.sorted { a, b in
            let x = chat.conversations.first { $0.peerSubject == a.subject }, y = chat.conversations.first { $0.peerSubject == b.subject }
            if x?.pinned != y?.pinned { return x?.pinned == true }
            return (Int64(x?.lastSequence ?? "0") ?? 0) > (Int64(y?.lastSequence ?? "0") ?? 0)
        }
    }
    private func conversationRow(_ peer: ChatPeer) -> some View {
        let conv = chat.conversations.first { $0.peerSubject == peer.subject }
        let last = chat.messages.filter { $0.peerSubject == peer.subject && $0.status != "hidden" }.max { $0.acceptedAt < $1.acceptedAt }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                if conv?.pinned == true { Image(systemName: "pin.fill").font(.caption) }
                Text(peer.title).font(.headline)
                Spacer()
                if let count = conv?.unread, count > 0 { Text("\(count)").font(.caption).foregroundStyle(.tint).accessibilityLabel("\(count) 条未读") }
            }
            Text(last?.text ?? last?.problem ?? (conv?.historyGap == true ? "本设备存在历史缺口" : "尚无本地消息"))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            if conv?.historyGap == true { Text("当前设备未拥有全部历史密文").font(.caption).foregroundStyle(.orange) }
        }.padding(.vertical, 4)
    }
}

struct ChatStatusSection: View {
    @EnvironmentObject private var chat: ChatController
    var body: some View {
        Section {
            Label(chat.status, systemImage: chat.connected ? "lock.shield" : "network.slash").font(.footnote)
            if let error = chat.error {
                Text(error).font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
                Button("重试连接与同步") { Task { await chat.refresh() } }
            }
            if chat.unknownEvents { Text("存在尚未识别的事件，原始事件已加密保存，请更新应用。").font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct ChatConsentView: View {
    @EnvironmentObject private var chat: ChatController
    @EnvironmentObject private var model: AppModel
    @State private var relay = ""
    @State private var confirming = false
    var body: some View {
        Form {
            if let error = chat.error { Section { Text(error).font(.footnote).foregroundStyle(.orange) } }
            Section("文字私聊") {
                Text("私聊由独立中继提供，不属于主站身份服务。默认不联网，也不发送主站令牌。")
                TextField("HTTPS 中继", text: $relay).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("首次建立聊天会话时，中继会接触主站 access token 以验证账号；之后使用独立的短期聊天令牌。请只信任你确认的中继。")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Section("加密与设备") {
                Text("正文在设备加密。私钥保存在 Keychain，历史按账号和中继分别加密。服务端仍能看到通信双方和时间等元数据，不提供前向保密或完整身份透明性。")
                Text("前台同步，后台立即停止。后台提醒需另装 Bark 并主动绑定；本 App 不通过后台轮询收信。")
                Text("旧安卓互聊需在设置中另行启用兼容主设备；已有其他旧密钥不会被覆盖。")
            }
            if model.profile?.stableID == nil {
                Section { Text("主站尚未提供有效的稳定账号 ID，暂不能启用。").foregroundStyle(.orange); Button("重新读取账号资料") { Task { await model.refreshProfile() } } }
            }
            Section { Button("我了解上述用途，启用私聊") { confirming = true }.disabled(model.profile?.stableID == nil) }
        }
        .onAppear { relay = chat.relayText }
        .alert("向此中继授权？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("同意并启用") {
                do { try chat.changeRelay(relay, profile: model.profile); chat.setEnabled(true) }
                catch { chat.error = error.localizedDescription }
            }
        } message: { Text("主站凭据将只用于向 \(relay) 交换聊天会话。更换地址需要重新同意。") }
    }
}

struct ChatNewContactView: View {
    @EnvironmentObject private var chat: ChatController
    @Environment(\.dismiss) private var dismiss
    var initialUsername = ""
    let onComplete: (ChatPeer) -> Void
    @State private var username = ""
    @State private var note = ""
    @State private var mode: ChatProtocolMode = .automatic
    @State private var inspection: ChatPeerInspection?
    @State private var loading = false
    @State private var problem: String?
    var body: some View {
        Form {
            Section("联系人") {
                TextField("账号用户名（非昵称）", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("本地备注（可选）", text: $note)
                Picker("发送协议", selection: $mode) { ForEach(ChatProtocolMode.allCases) { Text($0.title).tag($0) } }
                Button("查询账号与公钥") { lookup() }.disabled(loading || username.isEmpty)
            }
            if let inspection {
                Section("核对指纹") {
                    Text(inspection.username).font(.headline)
                    Text(inspection.fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    Text("通过带外方式核对指纹。首次信任无法防止中继替换首次公钥；设备或密钥变化后必须重新确认。")
                        .font(.footnote).foregroundStyle(.orange)
                    Text("支持：" + inspection.protocols.joined(separator: "、")).font(.caption)
                    Button("核对并信任，进入私聊") { trust(inspection) }.disabled(loading)
                }
            }
            if let problem { Section { Text(problem).foregroundStyle(.orange) } }
        }
        .navigationTitle("联系人密钥")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .onAppear {
            username = initialUsername
            if let existing = chat.peers.first(where: { $0.username == initialUsername }) { note = existing.note; mode = existing.mode }
        }
        .onChange(of: username) { _ in inspection = nil }
    }
    private func lookup() {
        loading = true; problem = nil; let searched = username
        Task {
            defer { loading = false }
            do { let result = try await chat.inspectPeer(searched); if username == searched { inspection = result } }
            catch { problem = error.localizedDescription }
        }
    }
    private func trust(_ inspection: ChatPeerInspection) {
        loading = true
        Task {
            defer { loading = false }
            do {
                try await chat.trust(inspection, mode: mode, note: note)
                if let peer = chat.peers.first(where: { $0.subject == inspection.subject }) { onComplete(peer); dismiss() }
            } catch { problem = error.localizedDescription }
        }
    }
}

private struct ChatVisibleRows: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct ChatThreadView: View {
    @EnvironmentObject private var chat: ChatController
    @Environment(\.scenePhase) private var phase
    let peer: ChatPeer
    @State private var draft = ""
    @State private var search = ""
    @State private var sending = false
    @State private var showTrust = false
    @State private var confirmingClear = false
    @State private var confirmingBlock = false
    @State private var recallTarget: ChatMessage?
    @State private var lastRead: Int64 = 0
    @State private var readTask: Task<Void, Never>?
    @State private var viewport: CGSize = .zero
    @State private var visibleFrames: [String: CGRect] = [:]
    @State private var olderBefore: String?
    @State private var loadingOlder = false
    @State private var showSettings = false

    private var contact: ChatPeer { chat.peers.first(where: { $0.subject == peer.subject }) ?? peer }
    private var conversation: ChatConversation? { chat.conversations.first { $0.peerSubject == peer.subject } }
    private var rows: [ChatMessage] {
        chat.messages.filter { $0.peerSubject == peer.subject && $0.status != "hidden" && (search.isEmpty || $0.text?.localizedCaseInsensitiveContains(search) == true) }
            .sorted { a, b in a.acceptedAt == b.acceptedAt ? (Int64(a.sequence) ?? 0) < (Int64(b.sequence) ?? 0) : a.acceptedAt < b.acceptedAt }
    }
    var body: some View {
        VStack(spacing: 0) {
            if let problem = chat.error { Text(problem).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
            if conversation?.historyGap == true { Text("本设备存在历史缺口，可在私聊设置中查看恢复方式。").font(.caption).foregroundStyle(.orange).padding(.horizontal) }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if let conv = conversation {
                            Button(loadingOlder ? "正在读取历史…" : "读取当前设备较早历史") { loadOlder(conv) }.disabled(loadingOlder)
                        }
                        if rows.isEmpty { Text("暂无本地消息").foregroundStyle(.secondary).padding() }
                        ForEach(rows) { message in
                            messageRow(message).id(message.id)
                                .background(GeometryReader { geometry in Color.clear.preference(key: ChatVisibleRows.self, value: [message.id: geometry.frame(in: .named("chatViewport"))]) })
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding()
                }
                .coordinateSpace(name: "chatViewport")
                .background(GeometryReader { geometry in Color.clear.onAppear { viewport = geometry.size }.onChange(of: geometry.size) { viewport = $0 } })
                .onPreferenceChange(ChatVisibleRows.self) { visibleFrames = $0; markVisible($0) }
                .onChange(of: viewport) { _ in markVisible(visibleFrames) }
                .onChange(of: rows.last?.id) { _ in if !loadingOlder { withAnimation { reader.scrollTo("bottom", anchor: .bottom) } } }
                .onAppear { reader.scrollTo("bottom", anchor: .bottom) }
                .refreshable { await chat.refresh() }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(contact.title).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "在本地解密历史中查找")
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { menu } }
        .sheet(isPresented: $showTrust) { NavigationStack { ChatNewContactView(initialUsername: contact.username) { _ in } } }
        .sheet(isPresented: $showSettings) { NavigationStack { ChatNotificationSettingsView(conversationID: conversation?.id) } }
        .task { let value = await chat.draft(for: peer.subject); if draft.isEmpty { draft = value } }
        .onChange(of: draft) { value in Task { await chat.saveDraft(value, peer: peer.subject) } }
        .onDisappear { readTask?.cancel() }
        .onChange(of: phase) { if $0 != .active { readTask?.cancel() } }
        .alert("清空自己的会话历史？", isPresented: $confirmingClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { if let conv = conversation { Task { await chat.perform { try await chat.clearConversation(conv) } } } }
        } message: { Text("影响自己的所有聊天设备和恢复过滤，不删除对方的副本。") }
        .alert("屏蔽此人？", isPresented: $confirmingBlock) {
            Button("取消", role: .cancel) {}; Button("屏蔽", role: .destructive) { Task { await chat.perform { try await chat.block(contact, enabled: true) } } }
        } message: { Text("对方不能再向你发送，但你仍可主动发给对方。已有历史不清空。") }
        .alert("撤回消息？", isPresented: Binding(get: { recallTarget != nil }, set: { if !$0 { recallTarget = nil } })) {
            Button("取消", role: .cancel) { recallTarget = nil }
            Button("撤回", role: .destructive) { if let target = recallTarget { Task { await chat.perform { try await chat.recall(target) } } }; recallTarget = nil }
        } message: { Text("十分钟内可要求双方不再显示。截图、导出及旧安卓已保存的记录无法远程抹除。") }
    }
    private var composer: some View {
        HStack(alignment: .bottom) {
            TextField("文字消息", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
            Button { send() } label: { if sending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) } }
                .accessibilityLabel("发送文字").disabled(sending || !chat.connected || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.utf8.count > 16384)
        }.padding().background(.bar)
    }
    private var menu: some View {
        Menu {
            Button("备注、协议与核对密钥") { showTrust = true }
            if let conv = conversation {
                Button(conv.pinned ? "取消置顶" : "置顶") { Task { await chat.perform { try await chat.changeConversation(conv, pinned: !conv.pinned) } } }
                Button(conv.archived ? "取消归档" : "归档") { Task { await chat.perform { try await chat.changeConversation(conv, archived: !conv.archived) } } }
                Button("会话提醒设置") { showSettings = true }
                Button("清空自己的历史", role: .destructive) { confirmingClear = true }
            }
            Button("屏蔽此人", role: .destructive) { confirmingBlock = true }
        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("会话操作")
    }
    private func messageRow(_ message: ChatMessage) -> some View {
        let mine = message.sender == chat.subject
        return HStack {
            if mine { Spacer(minLength: 28) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 5) {
                Text(message.text ?? (message.status == "recalled" ? "消息已撤回" : message.problem ?? "消息不可用"))
                    .textSelection(.enabled).padding(12)
                    .background(mine ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 6) {
                    Text(message.date, style: .time)
                    if mine { Text(message.stateTitle) }
                }.font(.caption2).foregroundStyle(.secondary)
                if let item = chat.pending.first(where: { $0.id == message.clientID && message.status == "pending" }) {
                    Button("原样重试发送") { Task { await chat.perform { try await chat.retry(item) } } }.font(.caption)
                }
                if message.problem != nil { Button("核对密钥") { showTrust = true }.font(.caption) }
            }
            .contextMenu {
                if let text = message.text { Button("复制文字") { UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]) } }
                if !message.id.hasPrefix("pending:") {
                    Button("仅对自己隐藏", role: .destructive) { Task { await chat.perform { try await chat.hide(message) } } }
                    if mine, message.status != "recalled", ChatController.now - message.acceptedAt <= 600000 { Button("撤回", role: .destructive) { recallTarget = message } }
                }
            }
            if !mine { Spacer(minLength: 28) }
        }
    }
    private func send() {
        let text = draft; sending = true
        Task {
            defer { sending = false }
            do { try await chat.send(text, to: contact); if draft == text { draft = "" } }
            catch { chat.error = error.localizedDescription }
        }
    }
    private func loadOlder(_ conv: ChatConversation) {
        loadingOlder = true
        Task { defer { loadingOlder = false }; do { olderBefore = try await chat.loadOlder(conv, before: olderBefore) } catch { chat.error = error.localizedDescription } }
    }
    private func markVisible(_ frames: [String: CGRect]) {
        readTask?.cancel()
        guard phase == .active, chat.connected, search.isEmpty else { return }
        let area = CGRect(origin: .zero, size: viewport)
        guard let latest = rows.filter({ $0.recipient == chat.subject && $0.text != nil && $0.problem == nil && $0.status == "incoming" && (frames[$0.id]?.intersection(area).height ?? 0) > 16 })
            .max(by: { (Int64($0.sequence) ?? 0) < (Int64($1.sequence) ?? 0) }), let seq = Int64(latest.sequence), seq > lastRead else { return }
        readTask = Task {
            do { try await Task.sleep(nanoseconds: 400_000_000); try Task.checkCancellation(); try await chat.markRead(latest); lastRead = seq }
            catch is CancellationError {} catch { chat.error = error.localizedDescription }
        }
    }
}
