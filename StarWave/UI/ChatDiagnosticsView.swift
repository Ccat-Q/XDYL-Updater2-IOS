import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Presentation uses only the diagnostic store's already-sanitized fields.
/// Export and clipboard writes are performed only by explicit button actions.
@MainActor
struct ChatDiagnosticsView: View {
    @ObservedObject var diagnostics: ChatDiagnostics
    private let refreshSnapshot: () -> Void
    @State private var categoryFilter = ""
    @State private var failuresOnly = false
    @State private var confirmClear = false
    @State private var copied = false

    init(diagnostics: ChatDiagnostics, refreshSnapshot: @escaping () -> Void = {}) {
        self.diagnostics = diagnostics
        self.refreshSnapshot = refreshSnapshot
    }

    private var visibleEntries: [ChatDiagnosticEntry] {
        ChatDiagnosticsPresentation.entries(diagnostics.entries,
            category: ChatDiagnosticCategory(rawValue: categoryFilter), failuresOnly: failuresOnly)
    }

    var body: some View {
        Form {
            privacySection
            buildSection
            snapshotSection
            controlsSection
            eventsSection
        }
        .navigationTitle("本机脱敏诊断")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("复制全部") { copyAll() }
                    .accessibilityHint("主动复制安全报告到本机剪贴板，约五分钟后过期")
            }
        }
        .onAppear {
            diagnostics.prune()
            refreshSnapshot()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            diagnostics.prune()
        }
        .alert("清空本次事件日志？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空事件", role: .destructive) { diagnostics.clear() }
        } message: {
            Text("仅清空当前进程内存中的诊断事件及裁剪计数，安全快照和记录开关保持不变。不删除聊天或密钥，也不能撤回已主动复制的报告。")
        }
        .alert("安全报告已复制", isPresented: $copied) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(ChatDiagnosticsPresentation.clipboardNotice)
        }
    }

    private var privacySection: some View {
        Section("隐私与边界") {
            Text("诊断记录仅保存在本次进程内存，不写日志文件、不触发网络，也不自动上报。快照会读取本机既有钥环并在本地校验公私钥配对，不生成、修改或导出私钥。退出进程后记录不保留。")
            Text("切换账号、更换中继或停用聊天时清空。不记录正文、密文、私钥、会话密钥、令牌或恢复码。")
            Text("标识符引用和公钥摘要是截断 SHA256 参考值，不是会话密钥指纹，也不能代替带外身份核验。")
                .font(.caption).foregroundStyle(.secondary)
            Text("只有你点按复制时才写入本机剪贴板，不通过通用剪贴板同步；约五分钟后过期。主动粘贴到其他应用后的副本不受本页控制。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var buildSection: some View {
        Section("应用构建") {
            Text(ChatDiagnostics.buildSummary)
                .font(.system(.footnote, design: .monospaced))
        }
    }

    private var snapshotSection: some View {
        Section("当前安全快照") {
            if diagnostics.snapshot.isEmpty {
                Text("尚无安全快照。离线或未启用聊天时也可刷新当前本机状态。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ChatDiagnosticFieldsView(fields: diagnostics.snapshot)
            }
            Button("刷新当前快照", action: refreshSnapshot)
            Text("刷新仅读取既有本机钥环并本地核验配对；不生成或导出私钥、不连接中继、不重试收发。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var controlsSection: some View {
        Section {
            Toggle("记录新的脱敏事件", isOn: $diagnostics.isRecording)
            Picker("事件类别", selection: $categoryFilter) {
                Text("全部").tag("")
                ForEach(ChatDiagnosticCategory.allCases, id: \.rawValue) { category in
                    Text(category.rawValue).tag(category.rawValue)
                }
            }
            Toggle("仅显示失败", isOn: $failuresOnly)
            Button("清空本次事件日志", role: .destructive) { confirmClear = true }
                .disabled(diagnostics.entries.isEmpty && diagnostics.discardedCount == 0)
        } header: {
            Text("记录与筛选")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("最多保留 \(diagnostics.limit) 条、最近 24 小时的记录；每分钟检查过期记录，记录和复制前也会裁剪。短时间相同事件可能合并。")
                Text("自动裁剪已丢弃最早记录：\(diagnostics.discardedCount) 条。关闭记录不会删除已有事件，也不会停止原有聊天操作。")
                Text("复制全部包含所有保留事件，不受筛选影响；单条事件可在详情内复制。")
            }
        }
    }

    private var eventsSection: some View {
        Section("事件（\(visibleEntries.count)/\(diagnostics.entries.count)，最新优先）") {
            if visibleEntries.isEmpty {
                emptyEvents
            } else {
                ForEach(visibleEntries) { entry in
                    eventRow(entry)
                }
            }
        }
    }

    private var emptyEvents: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(diagnostics.entries.isEmpty ? "暂无诊断事件" : "没有符合筛选条件的事件")
            Text(diagnostics.isRecording
                 ? "本页不会自动连接或解密；执行原有聊天操作后，可在这里查看脱敏阶段记录。"
                 : "事件记录已暂停。开启记录后，才会采集新的脱敏事件。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }

    private func eventRow(_ entry: ChatDiagnosticEntry) -> some View {
        // The destination retains only an ID. A scope reset or pruning must
        // remove old details, rather than leaving a captured entry on screen.
        let entryID = entry.id
        return NavigationLink {
            ChatDiagnosticEntryView(diagnostics: diagnostics, entryID: entryID)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title)
                    Spacer(minLength: 8)
                    Text(entry.outcome.rawValue)
                        .font(.caption)
                        .foregroundStyle(entry.outcome == .failed ? Color.red : Color.secondary)
                }
                Text(entry.code).font(.system(.caption, design: .monospaced))
                Text("\(ChatDiagnosticsPresentation.timestamp(entry.date)) · \(entry.category.rawValue) · 重复 \(entry.repetitions) 次")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.vertical, 2)
        }
    }

    private func copyAll() {
        // exportText() may prune. Never call it while evaluating View.body.
        ChatDiagnosticsPresentation.copyToLocalClipboard(diagnostics.exportText())
        copied = true
    }
}

@MainActor
private struct ChatDiagnosticEntryView: View {
    @ObservedObject var diagnostics: ChatDiagnostics
    let entryID: UUID
    @State private var copied = false

    private var entry: ChatDiagnosticEntry? {
        diagnostics.entries.first { $0.id == entryID }
    }

    var body: some View {
        Form {
            if let entry {
                eventSection(entry)
                Section("安全字段") {
                    if entry.fields.isEmpty {
                        Text("此事件没有附加字段。")
                            .foregroundStyle(.secondary)
                    } else {
                        ChatDiagnosticFieldsView(fields: entry.fields)
                    }
                }
                Section {
                    Button("复制此事件安全报告") { copyCurrentEvent() }
                    Text("只复制当前仍在内存中的事件及构建信息，不包含其他事件、正文、密文或密钥。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("该事件已清除或过期")
                    Text("切换账号、中继、停用聊天、主动清空或自动裁剪后，不再保留原事件详情。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("诊断事件")
        .onAppear { diagnostics.prune() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            diagnostics.prune()
        }
        .alert("事件报告已复制", isPresented: $copied) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(ChatDiagnosticsPresentation.clipboardNotice)
        }
    }

    private func eventSection(_ entry: ChatDiagnosticEntry) -> some View {
        Section("事件详情") {
            Text(entry.title).font(.headline)
            detailRow("时间", ChatDiagnosticsPresentation.timestamp(entry.date))
            detailRow("类别", entry.category.rawValue)
            detailRow("结果", entry.outcome.rawValue)
            detailRow("事件代码", entry.event.rawValue)
            detailRow("原因代码", entry.reason?.rawValue ?? "无")
            detailRow("重复次数", String(entry.repetitions))
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.footnote, design: .monospaced))
        }
    }

    private func copyCurrentEvent() {
        diagnostics.prune()
        guard let current = entry else { return }
        ChatDiagnosticsPresentation.copyToLocalClipboard(ChatDiagnosticsPresentation.report(for: current))
        copied = true
    }
}

private struct ChatDiagnosticFieldsView: View {
    let fields: [ChatDiagnosticField]
    var body: some View {
        ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label).font(.caption).foregroundStyle(.secondary)
                Text(field.value).font(.system(.footnote, design: .monospaced))
            }
        }
    }
}

@MainActor
enum ChatDiagnosticsPresentation {
    static let clipboardNotice = "已主动复制到本机剪贴板，不通过通用剪贴板同步，约五分钟后过期。清空日志不会撤回已复制或已粘贴到其他应用的副本。"
    private static let utcFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func timestamp(_ date: Date) -> String {
        utcFormatter.string(from: date) + "（UTC）"
    }

    static func entries(_ entries: [ChatDiagnosticEntry], category: ChatDiagnosticCategory?, failuresOnly: Bool) -> [ChatDiagnosticEntry] {
        let filtered = entries.enumerated().filter { item in
            (category == nil || item.element.category == category) && (!failuresOnly || item.element.outcome == .failed)
        }
        return filtered.sorted { lhs, rhs in
            if lhs.element.date == rhs.element.date { return lhs.offset > rhs.offset }
            return lhs.element.date > rhs.element.date
        }.map(\.element)
    }

    static func report(for entry: ChatDiagnosticEntry) -> String {
        var lines = ["单条聊天脱敏诊断 / 1", ChatDiagnostics.buildSummary,
                     "不含正文、密文、私钥、会话密钥或凭据；引用不是会话密钥指纹。",
                     "时间：\(timestamp(entry.date))", "类别：\(entry.category.rawValue)",
                     "结果：\(entry.outcome.rawValue)", "事件代码：\(entry.event.rawValue)",
                     "原因代码：\(entry.reason?.rawValue ?? "无")", "重复次数：\(entry.repetitions)"]
        lines += entry.fields.map { "\($0.label)：\($0.value)" }
        return lines.joined(separator: "\n")
    }

    static func clipboardOptions(at date: Date) -> [UIPasteboard.OptionsKey: Any] {
        [.localOnly: true, .expirationDate: date.addingTimeInterval(5 * 60)]
    }

    static func copyToLocalClipboard(_ report: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: report]], options: clipboardOptions(at: Date()))
    }
}
