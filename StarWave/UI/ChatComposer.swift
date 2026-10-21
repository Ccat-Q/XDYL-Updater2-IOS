import SwiftUI

/// A functional floating toolbar, not a material layer over the message body.
struct ChatComposer: View {
    @Binding var text: String
    let sending: Bool
    let connected: Bool
    let protocolTitle: String
    let send: () -> Void
    @ScaledMetric(relativeTo: .body) private var controlSize = 48.0

    private var overLimit: Bool { text.utf8.count > 16384 }
    private var canSend: Bool { !sending && connected && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !overLimit }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: connected ? "lock.fill" : "wifi.slash")
                Text(connected ? protocolTitle : "离线 · 草稿仍会加密保存在本机")
                Spacer(minLength: 0)
            }.font(.caption).foregroundStyle(.secondary)
            AppGlassControls {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("文字消息", text: $text, axis: .vertical)
                        .font(.body).lineLimit(1...5).textFieldStyle(.plain)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .frame(minHeight: controlSize)
                        .appChatControlSurface(cornerRadius: 26)
                        .accessibilityLabel("消息内容")
                    Button(action: send) {
                        Group {
                            if sending { ProgressView().tint(.primary) }
                            else { Image(systemName: "arrow.up").font(.body.weight(.bold)) }
                        }.frame(width: controlSize, height: controlSize).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .appChatControlSurface(cornerRadius: controlSize / 2, prominent: canSend)
                    .disabled(!canSend)
                    .accessibilityLabel(sending ? "正在发送" : "发送文字")
                    .accessibilityHint(connected ? "失败的发送会保留原始请求供重试" : "恢复连接后可以发送")
                }
            }
            if overLimit {
                Text("消息超过 16 KiB（当前 \(text.utf8.count) 字节），请缩短后发送。")
                    .font(.caption).foregroundStyle(.red).accessibilityIdentifier("chat.composer.limit")
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        .accessibilityIdentifier("chat.composer")
    }
}
