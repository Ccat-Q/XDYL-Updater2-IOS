# 星灯云浪 iOS

“星灯云浪”是 `ModUpdater2.exe` 的原生 iOS 16+ 伴侣应用重写版。项目使用 SwiftUI，保留账号、社区、商城、任务、通知、投票、意见箱、周目、皮肤/物品和资源浏览等手机端可行能力。

Windows Minecraft 的 `.minecraft` 目录同步、运行 EXE 和桌面自更新不可能在 iOS 沙箱内执行。iOS 版会下载并校验资源，将文件保存到“文件”App →“我的 iPhone”→“星灯云浪”，由用户分享或传输到电脑。

## 开发

需要 macOS、Xcode 16 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
xcodegen generate
open StarWave.xcodeproj
```

运行测试：

```bash
xcodebuild build-for-testing \
  -project StarWave.xcodeproj \
  -scheme StarWave \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator'
```

## IPA

推送 `v*` 标签后，GitHub Actions 会在 macOS runner 上测试、构建并发布：

- `StarWave-resignable.ipa`
- `StarWave-resignable.ipa.sha256`

该 IPA 不绑定设备或开发者团队，必须由最终用户使用 SideStore/AltStore 和自己的 Apple ID 重签。普通未越狱 iPhone 不能安装完全未签名的 IPA。

## 安全说明

旧服务的 `api.lanternwaves.fun:8080` 和 `:5551` 仅支持 HTTP。为保持接口不变，应用对 `api.lanternwaves.fun` 配置了 ATS 例外，并在代码中把明文请求限制到上述端口。访问令牌只存放在 Keychain；但服务端明文传输风险无法由客户端消除。

逆向确认的接口和实现状态见 [API compatibility](docs/API_COMPATIBILITY.md)。
