# iOS 聊天源码来源与许可审计

日期：2026-10-21。范围已按用户要求收窄为**iOS软件**，不审计或调整Worker。本文不改变根目录MIT许可证，也不是对整个仓库、Windows逆向成果、图标素材或其他第三方资产的法律保证。

## 结论先行

1. **上游确为GPLv3，而且实现聊天时参考的`36d3a8c`版本就已包含GPLv3，不是本次询问后才改变。** 早期`fe877678`根目录未见LICENSE，不能因此当作MIT或可任意改编。
2. 当前Swift聊天模块有明确的上游源码参考关系，但本轮未找到直接复制Kotlin代码块或机械逐句翻译的证据。可观察到的共同部分主要是旧协议的接口/字段和密码学格式，iOS的网络、存储、生命周期及UI实现有明显结构差异。
3. **仅“上游改GPL”或“App与GPL程序通信”，不足以推定整个iOS必须同步转GPL；但“换成Swift”也不足以排除GPL衍生关系。** 本轮是技术来源审计，不是独立创作证明或司法认定；不出具“可放心MIT-only发布”的免责结论。
4. 本轮保持许可证不变，不发布正式Release。若后续证实包含GPL代码的改编/翻译，应为相应作品遵守GPL或取得有效其他授权；若希望减少争议，可在核对权属及依赖后选择GPLv3发布，而不是仅凭当前扫描结果自动转换。

## 证据与历史时间线

本地审计基线：`1f219ae`，聊天首次入库为`20e6f30`（2026-10-19 23:16 UTC）；本轮还核对了2.3.1修订。根目录[LICENSE](../LICENSE)为MIT，版权行`Copyright (c) 2026 Ccat_Q`，此次没有替换。

| 上游提交 | 已核验事实 |
| --- | --- |
| [`fe87767894edfcbc818101bf87a11c1b0501dc49`](https://github.com/UNSA-studio/xdyl/tree/fe87767894edfcbc818101bf87a11c1b0501dc49) | 最早协议调查参考；根文件清单未见LICENSE/README，许可证API返回404。没有找到此版本获MIT授权的证据 |
| [`100e358655282ec564977510c823c96645b9f41c`](https://github.com/UNSA-studio/xdyl/commit/100e358655282ec564977510c823c96645b9f41c) | 2026-10-19 05:15:56 UTC新增LICENSE和README；提交说明为恢复GPL-3.0；README明确整个上游项目以GPLv3发布 |
| [`36d3a8c61ee2ffce3c3fe184356cc4125a119fcd`](https://github.com/UNSA-studio/xdyl/tree/36d3a8c61ee2ffce3c3fe184356cc4125a119fcd) | 本项目固定兼容目标；根LICENSE为GPLv3，Git blob `f288702d2fa16d3cdf0035b15a9fcbc552cd88e7` |
| [`b99248b725fba4d2000de6a09d9a1d973357ea59`](https://github.com/UNSA-studio/xdyl/tree/b99248b725fba4d2000de6a09d9a1d973357ea59) | 本次故障审查参考；LICENSE与36d相同，不把其更新误说成刚新增GPL |

`ChatCrypto.kt`在三个固定提交的Git blob均为`fff163cf884fe0bfa52ba6f71b8650d814885e57`，`ChatStore.kt`均为`687758aee17b450c3e1940bb479ea1c8ea6f93d8`。因此“最早看过一个无根许可证版本”不能作为独立MIT授权的证据；未见这些聊天文件有额外的宽松许可头或例外授权。

可复核入口：GitHub的`/repos/UNSA-studio/xdyl/license?ref=<commit>`、`/git/trees/<commit>?recursive=1`及对应源码固定链接。核验只读取公开源码及许可，没有执行上游代码、读取其证书/密钥文件或修改上游仓库。

## 文件级比对

| 本项目iOS文件 | 参考与实际实现差异 | 本轮判断 |
| --- | --- | --- |
| [ChatCrypto.swift](../StarWave/Core/Chat/ChatCrypto.swift) | 参考[ChatCrypto.kt](https://github.com/UNSA-studio/xdyl/blob/36d3a8c61ee2ffce3c3fe184356cc4125a119fcd/app/src/main/java/www/xdyl/hygge/com/ChatCrypto.kt)。保留互通所需的X25519/P256、SPKI、零盐HKDF-SHA256、`nu-chat-v1`、12字节nonce及Base64冒号格式。Swift调用CryptoKit的ECDH/HKDF/AES-GCM；没有移植Kotlin的手写HMAC派生、SharedPreferences存钥或联系人会话密钥缓存。V2 AAD与设备版本不来自该V1文件 | 协议/算法兼容参考明确；未见逐句转译，但不能用这一点代替法律判断 |
| [ChatTransport.swift](../StarWave/Core/Chat/ChatTransport.swift) | 参考[ChatApi.kt](https://github.com/UNSA-studio/xdyl/blob/b99248b725fba4d2000de6a09d9a1d973357ea59/app/src/main/java/www/xdyl/hygge/com/ChatApi.kt)确认原接口。Swift为独立URLSession、短期V2令牌和严格origin/redirect检查；没有搬入OkHttp/Cronet/ECH、UA伪装、端口/HTTP回退、GET别名或Android前缀实现 | 未见引入安卓网络实现；相同HTTP字段不是代码复制证明 |
| [ChatLocalStore.swift](../StarWave/Core/Chat/ChatLocalStore.swift)、ChatModels.swift | 参考[ChatStore.kt](https://github.com/UNSA-studio/xdyl/blob/36d3a8c61ee2ffce3c3fe184356cc4125a119fcd/app/src/main/java/www/xdyl/hygge/com/ChatStore.kt)理解会话/消息职责。安卓按联系人JSON文件/索引保存明文，Swift是actor+SQLite事务、逐记录AEAD及账号/中继命名空间；没有复制JSON读写及全量索引更新函数 | 数据模型的通用概念相同，实现/持久化结构不同 |
| ChatController.swift、ChatActions.swift | 参考[ChatPage.kt](https://github.com/UNSA-studio/xdyl/blob/b99248b725fba4d2000de6a09d9a1d973357ea59/app/src/main/java/www/xdyl/hygge/com/ChatPage.kt)理解流程。Swift用MainActor任务、设备事件/ACK、持久outbox、稳定subject和ticket隔离；安卓为Handler/Thread、全局数值游标、联系人会话缓存。重试和双气泡等iOS缺陷是本项目实现问题 | 没有把安卓控制器整体翻译；亦不以“重写”宣称必然不存在衍生关系 |
| UI/ChatViews.swift、ChatComposer.swift、ChatSettingsView.swift | 原生SwiftUI NavigationStack/Form/安全区/环境与自建组件；没有复制Android LinearLayout/Dialog/Card构建函数、drawable或颜色常量。新输入栏依据Apple公开API和本项目设计规范实现 | 有功能参考，没有发现安卓布局或素材直接引入 |
| ChatHistory.swift、UI/ChatHistoryView.swift | 手动加密分块/恢复/可信设备迁移按本项目V2契约实现；所核对的四份上游V1聊天文件未提供对应流程 | 没有发现相应上游V1代码被移植的证据 |

工程[project.yml](../project.yml)未引入安卓的`fclcore`、OkHttp、Cronet或Gradle模块；iOS聊天使用Apple系统框架与系统SQLite。上游因为`fclcore`采用GPL，并不能单凭这一事实推出没有引入它的iOS必然受同样约束。这也不是对所有素材及开发工具依赖的完整许可清单。

## 文本检索的范围与局限

对11个Swift聊天源文件与上述四份Kotlin文件，做了空白归一化后的连续三条有效代码行检索（每组至少100字符，忽略空白、纯括号及独立注释行），未发现匹配块。共享长字符串包括标准HTTP头、JSON/分页字段、通用消息状态、`X25519`和`nu-chat-v1`；人工复核了密码学、存储、请求和发送关键路径。

**这只是排查直接文本复制的辅助结果。** 跨语言改写可能没有任何相同行，也可能仍涉及受保护表达；本次开发确实参考过上游源码，不是未接触上游的clean-room开发。不能把“0个相同代码块”解释成“GPL必定不适用”。临时源文件和比较脚本仅留在`/tmp/xdyl-license-audit-20261021.iUEuxf`，不将上游源码混入本项目。

## 许可判断规则与下一步

- [GNU FAQ：跨语言翻译](https://www.gnu.org/licenses/gpl-faq.en.html#TranslateCode)说明翻译可能属于修改，不因Kotlin变Swift自动免除原许可。
- [GPLv3第0、5、6节](https://www.gnu.org/licenses/gpl-3.0.en.html)围绕受版权保护的改编、作品整体及发布对应源码规定条件。只有确认相应作品落入许可范围后，才能具体确定发布义务；仅经HTTP通信或同仓保存不自动决定边界。
- [GitHub许可说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)说明没有许可证不是任意使用授权。

**当前建议：不自动替换iOS的MIT，但在继续作MIT-only发布保证前先解决来源解释。** 可向上游权利人明确确认此客户端兼容实现是否获额外宽松授权，或请熟悉相关法域的专业人士判断是否构成改编；若用户倾向主动按GPLv3整理iOS软件，应另行确认权属、第三方许可、版权声明和对应源码的交付方式。任何后续许可选择都不应删除原作者声明，也不能自动补救既往发布问题。

本轮未执行许可转换、权利人联络、生产Worker变更或正式Release发布。
