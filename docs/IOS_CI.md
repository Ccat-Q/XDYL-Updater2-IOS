# iOS GitHub Actions：并行验证与 Xcode 缓存

2026-11-15。所有本次 iOS 编译、模拟器 XCTest 和归档都在 GitHub Actions 执行，不在 Linux 上尝试编译 iOS。工作流为 [ios.yml](../.github/workflows/ios.yml)，公共准备逻辑为 [prepare-ios](../.github/actions/prepare-ios/action.yml)。

## 并行拓扑

三个独立 Job 没有相互 `needs` 依赖：

- `simulator-tests`：macOS 26 / Xcode 26.6，构建模拟器 App 与测试，再执行 XCTest。
- `build`：macOS 26 / Xcode 26.6，独立执行真机 Release archive、IPA 打包与 SHA-256。
- `legacy-compatibility`：macOS 15 / Xcode 16.4，验证 iOS 16 回退代码与测试的编译兼容性。

测试不能早于其自身的模拟器产物生成；这里并行的是“模拟器构建/测试”和“独立真机归档编译”，不是让 XCTest 读取尚未编好的产物。模拟器在编译前开始启动，启动等待与编译重叠。

XCTest 用例内部仍保持串行，避免既有全局 URLProtocol 测试桩与截图窗口状态被多用例并发污染。没有可用 iPhone 模拟器时直接失败，不再以“跳过测试”产生绿色验收结果。

新提交会取消同一分支或 PR 的旧运行；版本标签运行不自动取消。并行任务增加瞬时 runner 用量，以减少串行等待时间；不承诺首次冷缓存构建的固定耗时。

## Xcode 缓存

准备 Action 分层处理工具下载缓存与构建缓存：

1. 工具层保留 Homebrew/SwiftPM 下载缓存，已安装 XcodeGen 时不重复安装，也不执行 Homebrew 自动更新。
2. 构建层按 runner OS、CPU 架构、完整 Xcode/Swift/系统版本指纹和 SDK/任务 profile 分区，真机、模拟器和旧 Xcode 不交叉回退。
3. 精确键包含该任务实际依赖的源码及工作流 hash。真机归档不因仅修改测试文件而单独失效；模拟器任务包含测试源码。
4. 没有精确匹配时，只回退到相同工具链和相同 profile 的最近缓存。不同 Xcode 或 SDK 的缓存不互相恢复。
5. Xcode 26 显式启用 `COMPILATION_CACHE_ENABLE_CACHING=YES`，通过 `COMPILATION_CACHE_CAS_PATH` 保存独立的内容寻址编译缓存；同时保留独立 DerivedData。Xcode 16 只复用其自己的 DerivedData，不强行启用新工具链功能。
6. 关闭 CI 不需要的编译索引存储，减少索引生成与缓存体积；缓存根目录不包含模拟器用户数据、Keychain、归档或 XCTest 结果包。
7. 构建层只在 main 上、成功编译后且精确缓存未命中时保存；工具层在安装成功后即可保存。模拟器编译缓存在运行测试前保存，测试失败也不丢掉已经完成的编译成果。PR 和版本标签只读已有缓存。

Actions Step Summary 记录精确命中状态与实际恢复键。编译与归档输出 `-showBuildTimingSummary`，可以区分安装/缓存传输、编译、模拟器启动和测试的耗时；不能仅凭总耗时声称缓存加速。

### 与 Gradle Enhanced Caching 的关系

用户提供的 [Gradle Enhanced Caching 官方文档](https://github.com/gradle/actions/blob/main/docs/setup-gradle.md#enhanced-caching)描述的是 `gradle/actions/setup-gradle` 对 **Gradle User Home** 的缓存，包括 Gradle 分发、JAR、编译脚本与 Gradle 本地构建缓存；其中 enhanced provider 还带有专有的跨条目去重和清理机制。

本仓库只有 Swift/Xcode/XcodeGen，没有 Gradle Wrapper 或 Gradle 工程，因此不加入一个空跑的 setup-gradle 步骤，不把它标为“已启用 Enhanced provider”。这里采用的是 **Xcode 原生编译缓存 + 官方 actions/cache**，借鉴其分层、严格匹配和成功后回填思路；不声称获得了 Gradle 专有 provider 的跨快照去重功能，也不引入 Gradle 商业服务、账户或密钥。

## 发布门禁

IPA artifact 可由独立归档 Job 先完成上传，但不代表测试验收通过。只有 `v*` 标签，且三个编译/测试 Job 全部成功后，`release` Job 才下载本次运行的 IPA、复核 SHA-256 并创建或更新 GitHub Release。

默认 Job 只有 `contents: read`；只有受门禁保护的发布 Job 获得 `contents: write`。测试结果与截图保留独立 artifact，便于确认真正执行的测试数量及失败原因。

## 验证

- 本地仅运行 YAML 解析、工作流依赖/缓存分区断言、`bash -n`、`git diff --check` 和文档检查，不运行 iOS 编译。
- 远端确认三个 Job 的运行时间区间有重叠，XCTest 结果包与摘要存在，IPA 和校验文件已上传。
- 首次运行可能是冷缓存；验证缓存成功保存后，重跑同一提交的真机归档 Job，核对精确命中及编译时间。不要为了“显示命中”取消版本、跳过测试或使用错误 SDK 的缓存。
