# API 接口手册

整理日期：2026-10-18。源码基线：`9bcc1cd`。本手册覆盖当前开发者目录的 **83 项方法 + 路由组合**，另补充客户端调用的 GitHub Release、头像、下载和管理网页 4 项入口，共 87 项。所有 API 文档集中在本目录；UI、Bug 和 Windows 迁移记录保留在上级 `docs/`。

## 阅读入口

| 模块 | 目录内接口数 | 详细说明 |
| --- | ---: | --- |
| 登录、注册、QQ 与令牌 | 10 | [AUTH.md](AUTH.md) |
| 账户、公开资料、表情与游戏绑定 | 14 | [ACCOUNT.md](ACCOUNT.md) |
| 社区、回复、点赞、打赏与图片 | 8 | [COMMUNITY.md](COMMUNITY.md) |
| 周目、玩家、排行、任务、奖励与投票 | 10 | [GAME.md](GAME.md) |
| 决斗场 | 11 | [DUEL.md](DUEL.md) |
| 商城、称号、兑换、行情与支付 | 14 | [COMMERCE.md](COMMERCE.md) |
| 公告、通知、意见箱与纪念堂 | 8 | [CONTENT.md](CONTENT.md) |
| 更新、资源、YSM 与外部资源 | 8，另含外部入口 | [RESOURCES.md](RESOURCES.md) |

接口逐项记录 HTTP 方法、服务、鉴权、参数、请求体、已知返回字段、用途和风险。`GET` 没有请求体，空 JSON `{}` 与无请求体不是同一回事；各条目分别说明。

### 外部聊天参考与本地后端契约

2026-10-19 补充以下独立文档；**iOS 2.3.0 已加入独立文字私聊客户端**，实现和验收边界见[IOS_CHAT.md](../IOS_CHAT.md)。聊天使用独立凭据和安全传输，不更改上面 83 + 4 = 87 项主业务统计，也不加入可记录完整响应的 App 开发者请求目录。

| 文档 | 状态与范围 |
| --- | --- |
| [外部聊天 V1](CHAT_V1.md) | 固定版本 Android/Worker 静态证据，六项现有外部操作，不代表线上已联调 |
| [聊天 V2 基础契约](CHAT_V2_PROPOSAL.md) | 16 项基础操作及Bark上游；核心已部署，未真机联调 |
| [聊天 V2 扩展](CHAT_V2_EXTENSIONS.md) | 会话、隐私、提醒、加密备份/迁移、分块与恢复；完整请求/响应 |
| [固定安卓互通](ANDROID_INTEROP.md) | 36d3a8c 的 Bearer/seq 与客户端双编解码；不等于所有旧APK可用 |
| [服务端整改与验收](../CHAT_SERVER_REMEDIATION.md) | 本地验证记录、上线/真机待测矩阵和后续 iOS 边界 |
| [生产部署记录](../CHAT_DEPLOYMENT_2026-10-19.md) | nu-pe-chat.cc.cd现有Worker已更新，R2未开通，原地恢复点与无凭据检查 |

聊天中继与 MAIN 分属不同信任边界，不能套用主业务 envelope 或把主站令牌自动发给它。文档必须准确注明本地实现、实际部署及资源缺口，不把单测或无凭据检查称作真机验收或当前iOS能力；离线检查校验分类、JSON和链接，后端真实运行时测试另行执行。

## 范围与证据等级

“完整”指当前仓库已知接口的完整覆盖，**不是未经授权取得的后端完整实现或全字段保证**。未掌握的服务端必填约束、完整错误码、权限细分及返回字段明确写为待核实，不虚构成功结果。

- **C（客户端）**：从实际请求构造和响应解析得出，说明 iOS 当前发送/消费的契约，不保证后端只返回这些字段。
- **S（静态证据）**：来自已有 Windows EXE 审查报告，未重新执行或反编译程序。静态字段不能代替线上联调。
- **R（既有只读核实）**：先前已记录的线上 GET/匿名验证；标注日期，不保证服务在任何时候都保持相同。

各模块默认等级 C；补充 S/R 的条目另注。本手册中的 JSON 均为**脱敏、合成的结构示例**，不是原始抓包、当前账户数据或可直接使用的凭证。示例只选取已知字段，不把示例中的字段全部声明为服务端必填。`message:"成功"` 等文案也不是固定字符串约定。

本次整理仅读取本地源码、测试和已有证据，没有发送登录、验证码、交易、发帖、上传、对局或任何写请求，也没有读取/导出用户 Keychain 或原文调试会话。

## 服务与 URL

| 标识 | Base URL | 用途与边界 |
| --- | --- | --- |
| MAIN | `https://login.lanternwaves.fun` | 当前主业务与身份服务；路径不额外添加 `/api` 前缀 |
| WEB | `https://login.lanternwaves.fun` | 身份流程、网页与头像；目前与 MAIN 同源 |
| MODS | `http://api.lanternwaves.fun:5551/mods` | `/mods.json` 的完整地址为 `/mods/mods.json`；明文 HTTP |
| YSM | 默认 `http://api.lanternwaves.fun:8080` | 独立皮肤上传服务；页面可选 MAIN 或 `https://api.lanternwaves.fun`，仅代表客户端允许选择，不证明每个地址均部署全部 YSM 路由 |
| GH | `https://api.github.com` | GitHub Releases 元数据，不发送社区 Bearer |

旧 `api.lanternwaves.fun:8080` 曾对主业务路由返回 404，不能因此把该主机上的独立 YSM `/history` 也断言为无效。不能自动向多个主机重发上传/扣费。

路径参数 `{id}`、`{player}`、`{identifier}` 必须替换为真实标识；ID 的数字或字符串形式由响应决定。iOS `.identifier` 对可解析的数字发送 JSON number，否则发送 string；不能把列表行号当服务端 ID。公开玩家标识仅接受单路径段字符，拒绝空值、`.`、`..` 及 `/ ? # %` 等路由注入字符。

## 鉴权、请求头和编码

条目中的“Bearer”表示**iOS 当前调用会附带登录令牌**，不等于已证明后端拒绝匿名调用。公开资料和原始排行榜曾匿名读取成功，但业务客户端仍默认带令牌；不擅自据此推断其他路由可匿名调用。

普通业务 JSON 请求：

```http
Accept: application/json
User-Agent: StarWave-iOS/<应用版本>
Accept-Language: zh-CN,zh;q=0.9
Authorization: Bearer <ACCESS_TOKEN>
Content-Type: application/json
```

`Authorization` 仅在条目标注 Bearer 时发送；`Content-Type` 仅在有 JSON 请求体时设置。QQ 状态专用请求、multipart 和 GitHub 请求不保证具有上述全部头。

- JSON 请求超时为客户端 30 秒；图片/文件上传 120 秒。这不是后端 SLA。
- multipart 使用 `multipart/form-data; boundary=...`，字段名严格区分 `image`、`avatar`、`emoji`、`skin_file`，不能用 JSON 字符串代替二进制文件。
- 头像/论坛/表情图片按内容设置 MIME 与扩展名；客户端原文件及转换后图片各有 5 MB 上限，不支持格式可转 JPEG。YSM 文件不是这项图片限额的对象。
- 默认业务重定向仅允许官方主机且与初始请求、当前响应同源；跨域、跨端口和 HTTPS 降级拒绝，包含 307/308。QQ 状态专用 Session 拒绝跟随重定向，以读取带 JSON 的 302。

## 通用响应与错误

常见成功 envelope：

```json
{"code":200,"message":"成功","data":{}}
```

`data` 可以是对象或数组，部分接口直接返回根对象/数组。多数模型读取 `data ?? root`；不能因为客户端容错，就认定所有接口支持所有 envelope。

通用确认响应（文中简称 **Ack**）：响应 JSON 的业务负载未被调用者消费；已知只检查 HTTP/业务成功。合成示例：

```json
{"code":200,"message":"操作成功"}
```

这不是声明后端一定返回该结构。客户端也能将空的 2xx 响应视为 `{}`；尚无证据证明任何具体写接口固定返回 204。凡条目标记 Ack 的接口，其完整成功负载须补充脱敏响应后才能确定。

错误结构示例：

```json
{"code":401,"message":"需要登录"}
```

- HTTP 必须为 2xx；若根级 `code` 可解析为整数，也必须在 200–299 内，数字字符串同样处理。不能只检查 HTTP 200。
- 错误文字依次读取 `message`、`detail`、`error`；业务错误不应被当成普通列表或“项目 1”。
- 已登录请求遇 HTTP 401 或业务 `code:401`，同会话共享一次 `/refresh`，成功后最多重新执行一次；确定失效清除会话，临时网络错误不直接登出。
- QQ 的带 `temp_token` 的 302、YSM 的明确 `duplicate:true` 响应是专门列出的例外，不推广到普通接口。
- 403/404/409/5xx 的业务细分含义除条目明确说明外待核实，不能杜撰固定错误码表。支付查单 404 会使客户端停止该订单轮询；不是所有 404 都代表登录失效。
- 普通业务不对支付、购买、打赏、领奖等进行无限自动重试；本地防重复提交不代表服务端幂等，也不能撤销服务端已完成的操作。

## 共享数据约定

| 领域 | 读取/表达规则 |
| --- | --- |
| 令牌 | `data.access_token` 或 `data.token`；`refresh_token`、`username` 可选；可兼容根级，用户名另兼容 `user.username` |
| 金额 | 响应可能是数值或数值字符串；当前余额、累计获得喵币、游戏币、支付人民币不能互换；支付金额以服务器为准 |
| 时间 | `seconds/playtime/my_playtime` 为秒；`hours` 为小时；`mtime` 与业务日期可有不同表达，不统一假设为毫秒；市场采样 `time` 按 Unix 秒读取 |
| 图片 | 头像文件名补为 WEB `/user/avatar/{filename}`；绝对 HTTP(S) URL 或相对路径另解析；正文含 Markdown/HTML 图片 |
| 称号 | 原始字符串可含 `&#RRGGBB`、`&0`–`&f`、`&k`–`&o`、`&r`；可见长度、格式码与送达状态见商城模块 |
| 兑换码 | `redeem_code/code_text` 优先；嵌套业务 `data.code` 可为凭证，根级数字或数字字符串 `code` 是状态码，不作兑换码 |
| 状态缺失 | 客户端模型有些默认值只是 UI 容错，不能反写为后端返回值，尤其不能伪造余额、在线/封禁、领取或游戏内送达 |

## 来源、维护与核对

主要来源：[开发者目录](../../StarWave/Core/DeveloperTools.swift)、[APIClient](../../StarWave/Core/APIClient.swift)、[业务模型](../../StarWave/Core/APIModels.swift)、[功能模型](../../StarWave/Core/FeatureModels.swift)、[决斗模型](../../StarWave/Core/DuelModels.swift)、[迁移模型](../../StarWave/Core/MigrationModels.swift)、[支付模型](../../StarWave/Core/PaymentModels.swift)、各 UI 请求点及 `StarWaveTests`。

历史依据见 [兼容性与历史验证](API_COMPATIBILITY.md)、[Windows 迁移记录](../WINDOWS_PARITY.md)、[排行来源说明](LEADERBOARD_SOURCES_2026-10-18.md)。本地 EXE 审查位于 `artifacts/rea-audit-20261017/REPORT.md`；它和二进制文件不作为 API 文档附件提交。

新增或改动接口时，同步修改对应模块；使用以下离线检查覆盖目录、业务路径和结构示例：

```bash
python3 scripts/check_api_docs.py
```

该检查只证明文档与本地已知请求目录的覆盖和示例 JSON 语法，不证明后端行为正确。真实样本后续应保留日期、HTTP 状态、脱敏响应及账号权限；不记录密码、Bearer、验证码、QQ 临时令牌、兑换码原文或签名下载 URL。

2026-10-18 整理时的离线结果：83 项目录接口及 4 项补充入口均有详细条目；92 处可静态提取的业务请求路径已覆盖，93 个 JSON 结构示例语法有效，43 个相对链接/锚点可解析，`git diff --check` 通过。当轮未改业务 Swift 源码，未触发 iOS 编译或线上接口验证。

2026-10-19 聊天后端实现后：原iOS覆盖不变，独立校验历史V1六项、V2基础十六项、扩展及安卓适配操作和Bark上游一项；数量以检查器实际输出为准。另有Node真实SQLite及Cloudflare workerd/D1/R2测试，不改业务Swift、不执行生产聊天/Bark请求或iOS编译。文档语法通过不等于服务已部署或真机验收完成。

## 尚需补充的服务端证据

| 项目 | 已记录范围 | 尚未确认 |
| --- | --- | --- |
| 完整响应 schema | 各接口客户端消费字段及兼容别名 | 未消费字段、服务端严格 required/nullable 与额外元数据 |
| 确认型写接口 | 精确请求体，成功判定为 Ack | 成功响应完整负载、是否返回新 ID/对象、字段必填性 |
| 旧更新和模组分组 | `/update/latest`、`/mods/list` 路由及当前用途边界 | 完整 JSON 返回结构，不能用猜测样例补齐 |
| 权限与错误 | 客户端带不带 Bearer、通用错误、已知 QQ/YSM 例外 | 各业务权限矩阵、全部错误码、限流/验证码时效 |
| 交易与游戏 | 支付/兑换/发放状态和客户端处理 | 真实扣费、订单归属、防重、跨端重试与游戏内最终送达 |

后续需经用户授权的低权限测试账号或服务端 OpenAPI/源码补证据；不能通过批量调用写接口“补全”生产数据。本文完整覆盖已知接口，但不将未掌握的服务端契约伪装为已经核实。
