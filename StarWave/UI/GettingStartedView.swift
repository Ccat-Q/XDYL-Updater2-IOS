import SwiftUI

/// Mobile guidance deliberately does not promise desktop launcher installation.
struct GettingStartedView: View {
    var onComplete: (() -> Void)?
    private let gameAddress = "mc.lanternwaves.fun:25565"
    var body: some View {
        List {
            Section("欢迎使用星灯云浪") {
                Text("在手机上查看社区、游戏资料并管理资源。")
            }
            Section("1 · 下载与保存") {
                Text("资源标签提供模组下载；服务 → 整合包下载提供整合包及网盘入口。下载保存到“文件”App，可通过分享导出。")
                Text("本 App 不会在 iPhone 安装桌面 Minecraft、同步游戏目录或操作 PCL2/HMCL。IPA 更新需自行完成签名安装。")
            }
            Section("2 · 游戏资料与奖励") {
                Text("在“我的”绑定游戏账号；在“服务”查看周目、任务、游玩奖励和决斗场。任务资格、余额与对局结果以服务器为准。")
                Text(gameAddress).font(.body.monospaced()).textSelection(.enabled)
                Button("复制游戏地址") { UIPasteboard.general.string = gameAddress }
                Text("地址来自 Windows 客户端配置，不代表已验证当前可达。").font(.caption).foregroundStyle(.secondary)
            }
            Section("3 · 社区与反馈") {
                Text("在社区发布图文、回复和参与讨论；在服务内参与投票或向意见箱提交建议。重要写入和扣费操作请核对确认内容。")
            }
            if let onComplete {
                Button("开始体验", action: onComplete)
                Button("跳过，不再自动显示", action: onComplete)
            }
        }.navigationTitle("新手引导")
    }
}
