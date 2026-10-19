# 外部私聊 V1：现有源码契约与缺陷

整理日期：2026-10-19。状态：**外部参考实现，当前 iOS 未接入**。本文六项操作不计入本 App 的 87 项已知入口，不代表线上部署与仓库完全一致。

本文保留最初 `fe877678` 的历史证据，不代表新后端行为。后续按用户要求实现的兼容目标已固定为 `36d3a8c`（Bearer + seq cursor）；当前加固契约、变化与互通限制见 [ANDROID_INTEROP.md](ANDROID_INTEROP.md)。不要把下文旧版无认证/时间游标缺陷误认为仍适用于新版源代码。

## 证据与信任边界

固定参考提交：[`UNSA-studio/xdyl@fe87767894edfcbc818101bf87a11c1b0501dc49`](https://github.com/UNSA-studio/xdyl/tree/fe87767894edfcbc818101bf87a11c1b0501dc49)。证据来源：

- [ChatApi.kt](https://github.com/UNSA-studio/xdyl/blob/fe87767894edfcbc818101bf87a11c1b0501dc49/app/src/main/java/www/xdyl/hygge/com/ChatApi.kt)：请求构造及 HTTPS → HTTP 降级。
- [ChatCrypto.kt](https://github.com/UNSA-studio/xdyl/blob/fe87767894edfcbc818101bf87a11c1b0501dc49/app/src/main/java/www/xdyl/hygge/com/ChatCrypto.kt)：密钥及密文格式。
- [ChatPage.kt](https://github.com/UNSA-studio/xdyl/blob/fe87767894edfcbc818101bf87a11c1b0501dc49/app/src/main/java/www/xdyl/hygge/com/ChatPage.kt)、[ChatStore.kt](https://github.com/UNSA-studio/xdyl/blob/fe87767894edfcbc818101bf87a11c1b0501dc49/app/src/main/java/www/xdyl/hygge/com/ChatStore.kt)：界面、同步及本地存储。
- [Worker](https://github.com/UNSA-studio/xdyl/blob/fe87767894edfcbc818101bf87a11c1b0501dc49/cloudflare/nu-chat-worker/src/index.js)、[API.md](https://github.com/UNSA-studio/xdyl/blob/fe87767894edfcbc818101bf87a11c1b0501dc49/API.md)：服务端处理及独立中继说明。

下文称“Worker”均指此提交的代码，不是对线上版本的推断。原文记录 HTTP 域名及 VPS 备用地址；未来客户端仅允许经用户同意的 HTTPS 中继，不继承明文回退。

此前调查于 2026-10-19 05:01:59 UTC 匿名 GET `https://nu-pe-chat.cc.cd/chat/ping` 得到 HTTP 200、`ok:true`、`mode:"username"`。只证明当时健康接口可达；未向中继发送主站令牌，未验证真实账号收发、公钥登记或部署版本。本轮文档实施没有再次探测聊天服务。

这是第三方自建中继，不是官方主站接口。Worker 携收到的主站 access token 请求 `https://login.lanternwaves.fun/user/profile` 核实身份，因此它能接触主站令牌。TLS 和消息加密不能消除此信任风险。

## 通用约定

- 基地址由 Android 设置 `chat_server` 提供，实际读取默认空；未配置即不调用。不要把注释中的默认常量当成真实配置。
- JSON UTF-8，字段大小写按下文；时间 `ts/since/upto` 均为 Unix 毫秒。
- Worker 受保护接口从 `Authorization: Bearer <ACCESS_TOKEN>` 读取令牌，也兼容 query `token`；后者有日志泄露风险，不作为新客户端方案。
- Android 的通用 GET/POST **没有设置 Authorization**。仅登记公钥在 JSON 放 `token`，Worker 却不读取它；发送、拉取、已读无令牌。这是源码直接不兼容，不应通过去掉服务端认证“修复”。
- Worker 验证身份优先读取 `username`，却还回退 `nickname` 或数字 ID；不能把这项宽松行为当成安全账号定义。
- HTTP 非 2xx 为失败。Worker 成功使用 `ok:true`，不是主业务的 `code:200`。Android 写操作还兼容 `code:200`，不说明 Worker 会返回该字段。
- 无 API 版本、算法协商、设备标识、速率限制或严格请求 schema。下文示例为合成结构；`<...>` 是不可用于加密/登录的占位符。

## 六项接口

### GET /chat/ping

用途：健康检查。无需认证，无 query 或请求体。Worker 未限制此路由的方法；这里只记录实际使用的 GET。

HTTP 200：

```json
{"ok":true,"ts":1792386000000,"mode":"username"}
```

`ts` 为服务端当前毫秒。不是版本协商或完整依赖健康检查。

### POST /chat/key

用途：登记自己的公钥。Worker 要求 Bearer；Android 实际请求：

```json
{"userId":"alice","token":"<ACCESS_TOKEN>","publicKey":"<BASE64_DER_SPKI>"}
```

Worker 不读 JSON `token`；Bearer 必须另带。`userId` 也接受 `username`，两者缺失使用鉴权用户名；显式值须与其相同。`publicKey` 仅检查真值，没有 DER、算法或长度验证。HTTP 200：

```json
{"ok":true,"userId":"alice"}
```

HTTP 401 为 `invalid token`；403 为 `username mismatch`；400 为 `missing publicKey`。相同用户直接覆盖 `key:<username>`，无版本比较、接管保护或历史密钥。

### GET /chat/key/{username}

用途：取对方公钥；**无需认证**。用户名为 URL 路径段，无请求体。HTTP 200：

```json
{"ok":true,"data":{"userId":"bob","publicKey":"<BASE64_DER_SPKI>"}}
```

没有登记：HTTP 404：

```json
{"ok":false,"error":"user not found"}
```

空用户名返回 HTTP 400 `bad user`。404 只代表没有该公钥记录，不能证明社区账号不存在；也不能把网络错误都显示成“对方不存在”。

### POST /chat/send

用途：向接收人保存密文。要求 Bearer，Android 实际未携带。请求：

```json
{"from":"alice","to":"bob","msgId":"1792386000000-1234","cipher":"<BASE64_NONCE>:<BASE64_CIPHERTEXT_AND_TAG>","ts":1792386000000}
```

`from` 可缺省为鉴权用户名，显式值须一致。`to/msgId/cipher` 必须非空，接收人必须已登记公钥。`ts` 被 `parseInt` 解析，假值改用服务端时间，非严格数值校验。首次 HTTP 200：

```json
{"ok":true}
```

重复键 HTTP 200：

```json
{"ok":true,"duplicate":true}
```

存储键为 `msg:<to>:<补齐15位ts>:<msgId>`；相同组合存在便返回 duplicate，不核对密文、不覆盖或续期。先 GET 再 PUT 非原子；改 `ts` 即新键，不能声称提供强幂等。消息 TTL 为 2,592,000 秒（30 天），仅收件箱副本，无发件箱同步。

失败：401 `invalid token`；403 `from mismatch`；400 `bad to` 或 `missing fields`；404 `recipient not found`。这些错误只解释 Worker 源码，不保证线上采用同样字符串。

### GET /chat/pull

用途：拉取自己的收件箱。要求 Bearer，query `since` 为毫秒，缺失为 0，无请求体。Android 发 `?since=<ms>`，没有用户参数或 Bearer。HTTP 200：

```json
{"ok":true,"data":[{"from":"alice","to":"bob","msgId":"1792386000000-1234","cipher":"<BASE64_NONCE>:<BASE64_CIPHERTEXT_AND_TAG>","ts":1792386000000}]}
```

Worker 先按 `msg:<鉴权username>:` 列出**最早的最多 200 个键**，再在该批结果内过滤严格 `ts > since`，读取消息并按 `ts` 升序排序。无 `cursor/has_more/next_since`，不遍历 KV 后续分页。前 200 个旧键仍存在时，后面的新消息可能一直不可见；把 since 改大或缩小轮询间隔不能修复。

仅时间游标无法区分同毫秒消息，也无法正确处理发送端时钟偏差、迟到写入和存储可见性延迟。空数组不等于可靠的“全部同步完毕”。认证失败为 401；过期消息直接消失，没有游标过期提示。

### POST /chat/read

用途：Android 尝试提交已读。要求 Bearer，客户端构造：

```json
{"peerId":"alice","upto":1792386000000}
```

Worker **不读取请求体**，只鉴权后 HTTP 200：

```json
{"ok":true}
```

没有存储、转发或返回已读位置。不能据此显示“对方已读”或“已送达”。

## 错误 envelope

上述失败的根结构示例：

```json
{"ok":false,"error":"invalid token"}
```

未知路径为 HTTP 404 `not found`。未处理异常为 HTTP 500，Worker 会返回错误文本及 `stack`，存在内部信息泄露；新协议必须移除。Android 将大部分 GET 错误压成 null/空列表，容易把失败误认为空历史。

## 加密格式：兼容事实而非安全背书

| 项目 | Android 实际实现 |
| --- | --- |
| 密钥协商 | Android API 33+ X25519；旧版 EC secp256r1/P-256 ECDH |
| 公钥/私钥存储编码 | Base64(DER SPKI) / Base64(DER PKCS#8) |
| 派生 | HKDF-SHA256，salt 为 32 个零字节，info UTF-8 `nu-chat-v1`，输出 32 字节 |
| 加密 | AES-256-GCM，随机 12 字节 nonce，16 字节 tag，无 AAD，明文 UTF-8 |
| 线上 cipher | 标准无换行 Base64(nonce) + `:` + Base64(ciphertext 与 tag 拼接) |

派生只按本机 OS 选择解析算法，没有对端能力协商；两种算法不能互相做 ECDH。每账号只有一把服务端公钥，即使 iOS 支持两种算法也不能保证同时与两类 Android 互通。无 key ID、历史密钥、多设备、可信身份签名或前向保密；中继可替换公钥，不能宣称能抵御主动中间人。密文不应写入普通支持日志，私钥永不上传。

## 客户端行为与迁移风险

- 一对一纯文字；手输社区 username 创建联系人，可填备注，查询公开资料后可能覆盖备注。不是数字 ID、游戏名或昵称寻址。
- 本地气泡、日期分隔、未读、`pending/sent/failed`；模型中的 delivered/read 未形成真实回执功能。无群聊、图片、文件、语音、撤回、失败消息专用重试或推送。
- 对话 8 秒网络轮询；列表 4 秒只读本地。用新 Handler 移除旧 Handler 回调不能可靠停止原轮询。
- 全局 `chat_last_pull` 与“仅存当前会话来信”组合可跳过其他联系人；必须先保存全部消息再推进游标。
- 发送每次生成“当前毫秒-四位随机数” ID 并重新取时间。手动重发为新消息；V1 若重试必须复用原 `msgId/ts/cipher`，但仍无强幂等保证。
- 本地明文 JSON、密钥 SharedPreferences、内存密钥缓存和游标未按账号隔离；每次追加整份读写，错误可能被吞。默认 App 私有目录，可通过调试开关改成公共目录；不应照搬至 iOS。
- HTTPS 异常自动回退 HTTP，可能将凭证外发到明文链路，必须禁止。

服务端源码与客户端源码不一致；健康检查不能消除上述问题。后续见 [V2 建议契约](CHAT_V2_PROPOSAL.md)与[整改及验收方案](../CHAT_SERVER_REMEDIATION.md)。源仓库未发现 LICENSE，不据此复制其代码或资源；本文为独立的协议与行为说明。
