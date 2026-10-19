# 私聊 V2 基础契约（本地实现）

日期：2026-10-19。**状态：LOCAL IMPLEMENTED / 本地实现；部署状态见[生产记录](../CHAT_DEPLOYMENT_2026-10-19.md)；未真机联调。** 用户批准后已在 [backend/nu-chat-worker](../../backend/nu-chat-worker/README.md) 实现并本地验证，核心后端现已上线，R2功能未启用。文件名保留历史链接；这不是主站官方API，也不是当前iOS功能。完整新增功能见 [V2扩展](CHAT_V2_EXTENSIONS.md)，旧安卓互通见 [ANDROID_INTEROP.md](ANDROID_INTEROP.md)。

前置事实见 [V1 源码契约](CHAT_V1.md)，实施门槛见[整改方案](../CHAT_SERVER_REMEDIATION.md)。JSON 示例为合成数据；`<...>`、示例游标及密码学材料均不可直接用于联调。

## 1. 版本、身份与安全边界

- 新协议统一前缀 `/chat/v2`；V1 路径不变，不把 V1 公钥或单收件箱伪装为 V2 设备。互通必须显式启用兼容主设备并选择旧编解码，不能向原生 V2 消息接口混入 V1 密文；能力不足时停止启用，不静默降级。
- HTTPS only，拒绝跨源重定向、userinfo URL、query/body token。只在 `Authorization: Bearer ...` 传凭证；正文 JSON UTF-8，响应禁止缓存。仅能力发现匿名，其余均认证。
- 社区账号由主站验证结果中的稳定 `id/user_id` 绑定为不可变 `subject`；`username` 是当前寻址名，昵称仅供显示。无稳定账号 ID 则 `IDENTITY_UNSUPPORTED`，不得回退昵称。主站用户名更改后更新映射，旧名称不得绑定到其他账号的历史数据。
- 首次以主站 access token 创建短期、单设备的聊天会话；之后只发中继签发的聊天令牌。中继仍会接触首次凭证，必须明确征得用户同意；不保存或记录主站令牌。这不是主站签发的最小权限授权，风险仍存在。
- 每个设备独立 `device_id`，由客户端随机生成 UUID；不得作为秘密凭证使用。会话令牌是随机 256-bit 不透明秘密，服务端仅存哈希，固定 1 小时到期、可撤销；到期重新向主站验证，不新增虚构的主站 OAuth 接口。
- API 授权始终由会话绑定的 subject/device 决定，不信任请求中的 from/owner；所有字符串身份大小写以主站规范值为准。

## 2. 通用类型与错误

| 类型 | 目标约定 |
| --- | --- |
| ID | 随机 UUID 字符串；subject 为服务端返回的不透明字符串，不由客户端猜测 |
| seq / revision | 非负十进制字符串，比较按整数，避免 JS 53-bit 精度丢失 |
| 时间 | `*_at_ms` 为 Unix 毫秒整数，服务端时间决定排序/过期；client 时间仅展示 |
| 公钥 | 算法 `X25519` 或 `P256`，DER SPKI 标准 Base64，严格校验曲线与编码 |
| 分页游标 | 服务端签名/认证的不透明字符串，绑定 subject、device、位置及版本；不接受任意 seq 替代 |
| 内容 | 仅 UTF-8 纯文字；正文最多 16 KiB，单请求最多 512 KiB，目标设备最多 16 个/消息 |

所有成功 HTTP 200，`ok:true`；含业务数据时使用 `data` 对象。错误用准确的 HTTP 状态及稳定 error.code，不返回堆栈。未知字段拒绝（400），不同 endpoint 的请求对象分别定义，不套用主业务 envelope。

```json
{"ok":false,"error":{"code":"KEYSET_CHANGED","message":"接收方设备密钥已变化","retryable":false},"request_id":"<UUID>"}
```

| HTTP | code | 行为 |
| --- | --- | --- |
| 400 | INVALID_REQUEST / UNSUPPORTED_ALGORITHM | 修正请求，不重试原错误 |
| 401 | UNAUTHORIZED / SESSION_EXPIRED | 重新认证一次，不无限循环 |
| 403 | FORBIDDEN / DEVICE_REVOKED / DEVICE_NOT_ACTIVE | 停止越权请求；撤销则清会话，未激活则先登记密钥 |
| 404 | USER_NOT_FOUND / DEVICE_NOT_FOUND / MESSAGE_NOT_FOUND | 区分对象，不当作网络成功空数据 |
| 409 | IDEMPOTENCY_CONFLICT / KEYSET_CHANGED / REVISION_CONFLICT / DEVICE_LIMIT / DEVICE_LIMIT_OR_IDENTITY_CONFLICT / NO_ACTIVE_DEVICE / BARK_NOT_CONFIGURED / IDENTITY_UNSUPPORTED / DELIVERY_NOT_ALLOWED | 保留草稿/消息；按具体原因刷新、配置或等待身份服务补齐；不绕过拒收 |
| 410 | CURSOR_EXPIRED | 显式缺口提示并走重同步，不静默置零 |
| 413 | PAYLOAD_TOO_LARGE | 本地限制并保留草稿 |
| 429 | RATE_LIMITED | 遵守 Retry-After 秒数，不无限重试 |
| 503 | TEMPORARILY_UNAVAILABLE | 带退避重试，沿用幂等身份 |

初始限流建议：每 subject 写消息 30 次/分钟、每 IP 创建会话 10 次/分钟；Bark 测试每设备 3 次/分钟。实际部署调整须同步 capabilities 与文档，不通过关闭认证解决限流或身份故障。

## 3. 能力、会话和设备

### GET /chat/v2/capabilities

匿名，无请求体/query。成功：

```json
{"ok":true,"data":{"protocol":"nu-chat-v2","version":2,"algorithms":["X25519","P256"],"features":["cursor_sync","idempotent_send","device_keys","receipts","conversations","blocks","private_reads","history_controls","notification_preferences","legacy_android_interop","encrypted_backups","device_history_transfer","bark"],"retention_days":30,"max_page_size":200,"max_devices_per_account":8,"max_plaintext_bytes":16384,"max_request_bytes":524288,"max_envelopes":16}}
```

上例假设所有资源已配置；当前生产R2未开通，不返回encrypted_backups/device_history_transfer。只有服务真实启用的 feature 才可返回；feature 缺失不等于权限可绕过。健康可达不代表真机验收通过。

### POST /chat/v2/session

唯一接受**主站 Bearer**的操作，验证 `/user/profile` 的 HTTP 和业务状态；检查主站账号状态，无有效稳定身份拒绝。无 query，请求：

```json
{"device_id":"<DEVICE_UUID>","device_name":"我的 iPhone"}
```

成功（令牌仅此时返回，不记录到日志）：

```json
{"ok":true,"data":{"subject":"account:example-42","username":"alice","device_id":"<DEVICE_UUID>","chat_token":"<SECRET>","expires_at_ms":1792389600000}}
```

相同 device_id 不允许跨 subject 绑定；被撤销的 device_id 不能重新激活，返回 DEVICE_REVOKED，新设备须生成新 ID 并重新获得用户同意。设备不存在时建立未激活设备，尚不能收发；达到 8 个未撤销设备时 409 `DEVICE_LIMIT`，用户先撤销旧设备。设备命名最长 64 字符，无权限意义。失效主站令牌 401，主站故障 503，不伪装成账号不存在。

### DELETE /chat/v2/session

聊天 Bearer；无请求体/query，撤销当前令牌，幂等成功：

```json
{"ok":true}
```

退出当前会话不删除历史、不撤销设备公钥；已过期令牌返回 401，本地退出不依赖网络成功。账户安全事件需撤销全部相关聊天会话。

### GET /chat/v2/devices

聊天 Bearer；仅自己的设备，无请求体/query：

```json
{"ok":true,"data":{"devices":[{"device_id":"<DEVICE_UUID>","device_name":"我的 iPhone","active":true,"revoked":false,"key_revision":"1","created_at_ms":1792386000000}]}}
```

只返回设备元信息，不返回令牌、私钥或 Bark key。

### POST /chat/v2/devices/{device_id}/keys

聊天 Bearer；只能登记本会话设备。首次 revision 为 `"0"`；两个算法各一把新公钥，key_id 均全局唯一且不可复用：

```json
{"expected_revision":"0","keys":[{"key_id":"<X_KEY_UUID>","algorithm":"X25519","public_key":"<BASE64_DER_SPKI>"},{"key_id":"<P_KEY_UUID>","algorithm":"P256","public_key":"<BASE64_DER_SPKI>"}]}
```

成功：

```json
{"ok":true,"data":{"device_id":"<DEVICE_UUID>","key_revision":"1","keyset_revision":"7","active":true}}
```

服务端原子 CAS 校验 revision、完整验证两种公钥后激活；同 revision+相同完整请求重试返回首次结果；不同内容冲突 409。轮换必须带最新 expected_revision，不能凭“接管”静默覆盖；旧 key 元数据只读保留至引用密文过期，私钥留客户端。旧设备新建会话不能跳过用户的指纹变化确认。公钥注册属于账号授权，不代表公钥得到独立身份认证。

### DELETE /chat/v2/devices/{device_id}

聊天 Bearer；同 subject 可撤销自己的任一设备，无请求体/query，幂等成功 `{"ok":true}`。原子禁用设备、其会话与 Bark 绑定，递增账号 keyset_revision；新消息不再加密到它。不能撤销已泄露的明文或已取得的旧私钥。

### GET /chat/v2/users/{username}/keys

聊天 Bearer；URL 单段编码，无 query/body。查询主站规范账号映射；不使用昵称。返回所有活跃设备及两种公钥的快照：

```json
{"ok":true,"data":{"subject":"account:example-43","username":"bob","keyset_revision":"8","devices":[{"device_id":"<BOB_DEVICE_UUID>","key_revision":"1","keys":[{"key_id":"<BOB_X_KEY_UUID>","algorithm":"X25519","public_key":"<BASE64_DER_SPKI>"},{"key_id":"<BOB_P_KEY_UUID>","algorithm":"P256","public_key":"<BASE64_DER_SPKI>"}]}]}}
```

无账号 404；有账号无活跃设备返回 devices 空数组，不能误称“用户不存在”。首次信任（TOFU）后固定指纹，变化需暂停并确认；服务端可替换首次公钥的主动中间人风险仍在，应提供双方带外核对方式，不宣称已解决完整身份认证。

消息同步/历史响应增加只读sender_username、recipient_username，以及envelope.sender_public_key；原始sender_key_id解析对应版本公钥，避免换钥前未拉取消息无法解密。字段不加入发送请求或AAD，隐藏/撤回消息不会因此重新包含envelope。

## 4. 加密与发送

V2 客户端同时具备两种算法，每个目标设备只选一种：优先 X25519，否则 P256。原生消息只有显式登记到 V2 的设备参与。旧 Android 不使用此加密套件，通过[兼容主设备](ANDROID_INTEROP.md)与新前端互聊；这不让旧 APK 自动获得 V2 多设备能力。

V2 定义新的加密套件，**不得当成 V1 密文直接发送**：

- ECDH 按 envelope.algorithm 使用发送设备对应私钥和接收设备对应公钥。
- HKDF-SHA256，salt=SHA256(下述 AAD)，info=UTF-8 `nu-chat-v2`，输出 32 字节。
- AES-256-GCM，12 字节安全随机 nonce，16 字节 tag，标准 Base64 分别编码 nonce 和 ciphertext+tag。
- AAD 是 UTF-8 编码的无空白 JSON 字符串数组，元素顺序固定：`["nu-chat-v2",sender_subject,sender_device_id,recipient_subject,client_msg_id,target_subject,target_device_id,algorithm,sender_key_id,recipient_key_id]`；按 RFC 8259 字符串转义，非 ASCII 不额外转义。正文不在 AAD 中。
- 每个 envelope 单独生成 nonce；重试整条请求复用已持久化的原 envelope，禁止相同 key/nonce 加密不同明文。解密失败保留密文和错误，不推进“已读”。

本地参考编解码和篡改测试见 `backend/nu-chat-worker/src/protocol.js` 与测试目录；旧套件还与独立 OpenSSL 实现比对。不提供前向保密或已验证的密钥透明性，也不把单测通过当作第三方密码学审计或 Swift/Android 真机互操作验收。私钥备份/历史恢复是独立、用户主动的客户端流程，见扩展契约。

### POST /chat/v2/messages

聊天 Bearer，必须为活跃设备。客户端一次生成并保存 client_msg_id（UUID）及完整请求，再发送。to_subject 来自公钥查询，不接收 from 作为身份依据：

```json
{"client_msg_id":"<MESSAGE_UUID>","to_subject":"account:example-43","client_sent_at_ms":1792386000000,"sender_keyset_revision":"7","recipient_keyset_revision":"8","envelopes":[{"target_subject":"account:example-43","target_device_id":"<BOB_DEVICE_UUID>","algorithm":"X25519","sender_key_id":"<ALICE_X_KEY_UUID>","recipient_key_id":"<BOB_X_KEY_UUID>","nonce":"<BASE64_12_BYTES>","ciphertext":"<BASE64_CIPHERTEXT_AND_TAG>"},{"target_subject":"account:example-42","target_device_id":"<ALICE_DEVICE_UUID>","algorithm":"X25519","sender_key_id":"<ALICE_X_KEY_UUID>","recipient_key_id":"<ALICE_X_KEY_UUID>","nonce":"<ANOTHER_BASE64_12_BYTES>","ciphertext":"<SELF_COPY_BASE64_CIPHERTEXT_AND_TAG>"}]}
```

须覆盖接收账号和发送账号全部活跃设备，每设备恰一份；同设备支持两种算法也不发送两份。发送设备自身也有加密副本。示例假定双方各一台设备。同账号发送禁止（400），无活跃接收设备 409 `NO_ACTIVE_DEVICE`。

服务端在同一事务校验两方 keyset_revision、设备与 key ID 归属、大小限制，创建消息、每设备投递事件和 Bark outbox；部分失败全部回滚。公钥集合已变化返回 KEYSET_CHANGED，尚未接受该消息；客户端刷新并确认后可在相同 client_msg_id 下重建请求。**一旦接受，任何变更后的重试均冲突**。

幂等唯一键 `(sender_subject,sender_device_id,client_msg_id)`；以解析后的完整请求对象（忽略 JSON 对象键序）比较，无需靠客户端时间区分。先完成身份/设备权限校验，再查已接受的幂等记录，**已接受原请求的重试不重新校验当前 keyset**，否则密钥变化会掩盖首次已成功结果。相同请求成功重放原 message_id/seq、duplicate:true；同键不同内容 409 IDEMPOTENCY_CONFLICT。只有未接受的新请求才进入密钥快照校验。接受顺序、幂等记录、消息和 outbox 原子提交，不使用 KV get-then-put；幂等记录至少保留设备存续期，正文过期后仍保留最小去重 tombstone。

```json
{"ok":true,"data":{"message_id":"<SERVER_MESSAGE_UUID>","client_msg_id":"<MESSAGE_UUID>","conversation_id":"<CONVERSATION_UUID>","conversation_seq":"1001","accepted_at_ms":1792386000010,"duplicate":false}}
```

这里仅为**服务端接受**，不代表设备已收或对方已读。服务端无法验证密文的真实文字长度和各 envelope 明文一致性；它只限制密文字节数，客户端负责文字长度；恶意发件人的内容真实性不能靠字段验证解决。

## 5. 增量同步、设备接收与已读

### GET /chat/v2/sync

聊天 Bearer；query `cursor`（首次省略）、`limit`（默认 100，1–200）；无请求体。仅返回当前设备的 append-only 事件流，每设备 event_seq 严格递增。分配顺序须与可见提交顺序一致，禁止低 seq 在游标越过后才提交；不能直接假定自增 ID 就解决提交乱序。

```json
{"ok":true,"data":{"events":[{"event_seq":"21","type":"message","message_id":"<SERVER_MESSAGE_UUID>","client_msg_id":"<MESSAGE_UUID>","conversation_id":"<CONVERSATION_UUID>","conversation_seq":"1001","sender_subject":"account:example-42","sender_device_id":"<ALICE_DEVICE_UUID>","recipient_subject":"account:example-43","accepted_at_ms":1792386000010,"expires_at_ms":1794978000010,"envelope":{"target_subject":"account:example-43","target_device_id":"<BOB_DEVICE_UUID>","algorithm":"X25519","sender_key_id":"<ALICE_X_KEY_UUID>","recipient_key_id":"<BOB_X_KEY_UUID>","nonce":"<BASE64_12_BYTES>","ciphertext":"<BASE64_CIPHERTEXT_AND_TAG>"}}],"next_cursor":"<OPAQUE_CURSOR>","has_more":false,"server_time_ms":1792386000100}}
```

has_more 针对此次读取快照的剩余记录，不承诺之后没有新事件；即使空页也返回有效 next_cursor。严格按 seq 分页，不按客户端时间；下一页从上次返回位置继续，不跳到请求时最新位置。

客户端将所有会话的事件与 next_cursor **同事务落盘**，以 event_seq/message_id 去重，完成后再确认设备接收；不能只存当前会话。读取重试不删除服务端记录。事件包括 message、delivered、read 和 keyset_changed；未知类型需保存原事件并显示升级要求，不丢弃后假装完整同步。

### POST /chat/v2/sync/ack

聊天 Bearer；设备保存该页所有事件后请求：

```json
{"cursor":"<OPAQUE_CURSOR>"}
```

成功 `{"ok":true}`。服务端校验游标归属与已发范围，单调推进设备接收位置并为新接收的**入站消息**生成 delivered 事件；重复 ack 不重复产生逻辑回执。ack 不删除消息。接收自己的发件副本不能成为“对方已收到”的依据；已保存密文也不证明能解密或已阅读。

### POST /chat/v2/conversations/{conversation_id}/read

聊天 Bearer；必须为该会话参与人。仅当用户在当前会话实际看过对应消息且消息已成功解密时提交：

```json
{"up_to_conversation_seq":"1001"}
```

成功返回该用户的单调水位：

```json
{"ok":true,"data":{"reader_subject":"account:example-43","up_to_conversation_seq":"1001","read_at_ms":1792386000200}}
```

只接受该设备已 ack 的会话消息范围；超过已接收或不存在位置 400 `INVALID_READ_POSITION`，其他账号的会话 403。已读以接收账号聚合为“任一设备明确阅读”，设备接收仍逐设备记录；不可用所有设备送达推导已读。read 事件发给自己的活跃设备；仅 `read_receipts=true` 时向对方披露。关闭只影响未来操作，不抹去对方已收到的公开回执。重复或倒退的提交返回已有水位，不重复创建逻辑事件。

回执事件（同样出现在 sync.events，seq/会话字段规则不变）：

```json
{"event_seq":"22","type":"read","conversation_id":"<CONVERSATION_UUID>","reader_subject":"account:example-43","up_to_conversation_seq":"1001","read_at_ms":1792386000200}
```

```json
{"event_seq":"23","type":"delivered","conversation_id":"<CONVERSATION_UUID>","message_id":"<SERVER_MESSAGE_UUID>","receiver_subject":"account:example-43","receiver_device_id":"<BOB_DEVICE_UUID>","received_at_ms":1792386000150}
```

```json
{"event_seq":"24","type":"keyset_changed","subject":"account:example-43","keyset_revision":"9","changed_at_ms":1792386000300}
```

keyset_changed 向该账号设备及有未过期会话的对方设备投递；发送前仍必须校验 keyset_revision，不能只靠提醒判断密钥未变。回执依赖客户端诚实报告，不宣称服务端能证明用户真的看过文字。

### POST /chat/v2/sync/reset

聊天 Bearer；游标过期时，客户端先保留本地历史并确认补拉。请求：

```json
{"reason":"cursor_expired"}
```

成功：

```json
{"ok":true,"data":{"cursor":"<OPAQUE_RESET_CURSOR>","available_from_ms":1792386000000,"history_complete":false}}
```

从当前设备最早仍保留的事件之前开始，再用 sync 正常分页。reset 不清除既有已读/ack 水位；重复事件由客户端去重。保留期默认 30 天，过期或新设备加入前没有其 envelope 的消息不能恢复；必须标明缺口，不能宣称完整云历史或自动搬迁 V1 私钥。游标过期返回410，伪造/其他设备游标返回400/403。

## 6. Bark 绑定与通知

用户另装 Bark；本 App 不直接获得 APNs 能力，也不在后台轮询。Bark device key 与聊天 device_id 是两种不同身份。接口仅在 feature=bark 时可用。

### PUT /chat/v2/devices/{device_id}/bark

聊天 Bearer；仅绑定本会话设备，请求：

```json
{"server_url":"https://api.day.app","device_key":"<BARK_DEVICE_KEY>","enabled":true,"expected_revision":"0"}
```

成功仅返回非敏感信息：

```json
{"ok":true,"data":{"enabled":true,"server_url":"https://api.day.app","preview":"generic","revision":"1"}}
```

device key 加密存储，不写访问日志、不读回原文。首次 expected_revision 可省略按0；已有绑定必须提供当前 revision，否则428 `PRECONDITION_REQUIRED`，旧版本409。省略 device_key 则保留旧秘密，可以只切换 enabled；首次必须提供。server_url 可省略，**仅允许官方 `https://api.day.app` origin**，拒绝路径/query/userinfo/非默认端口和自建地址，不跟随重定向；未实现任意主机 DNS/IP 白名单，不宣称支持自建。替换、停用均取消旧版本待发任务，不能撤销在途请求。

### DELETE /chat/v2/devices/{device_id}/bark

聊天 Bearer，仅本会话设备；无请求体，query `expected_revision=<当前版本>`，删除密钥和未发送任务；无绑定时幂等成功 `{"ok":true}`。有绑定缺版本400、旧版本409；撤销设备也执行此清理，正在发出的请求无法撤回。读取脱敏绑定见扩展契约。

### POST /chat/v2/devices/{device_id}/bark/test

聊天 Bearer，仅本会话设备；请求 `{}`。成功表示**排入通知任务**，不是保证手机已显示：

```json
{"ok":true,"data":{"queued":true,"notification_id":"<NOTIFICATION_UUID>"}}
```

未绑定 409 `BARK_NOT_CONFIGURED`；异步结果通过下述状态接口查询。

### GET /chat/v2/devices/{device_id}/bark/status

聊天 Bearer，仅本会话设备；无 query/body：

```json
{"ok":true,"data":{"enabled":true,"last_attempt_at_ms":1792386000400,"last_result":"accepted","last_error_code":null}}
```

last_result 为 none/queued/accepted/failed；accepted 仅 Bark 接受，不代表设备送达。错误仅枚举 NETWORK_ERROR、RATE_LIMITED、INVALID_KEY、UPSTREAM_REJECTED，不包含 URL 中的 key、响应原文或主站令牌。

### POST /push

这不是聊天客户端 API。在线中继从持久化 outbox 取任务，向绑定主机 `/push` 发送 JSON，不把 key 放 URL。目标格式依据 [Bark 官方说明](https://github.com/Finb/Bark#usage)及 [bark-server](https://github.com/Finb/bark-server)，实际使用版本需在联调记录固定。

```json
{"device_key":"<BARK_DEVICE_KEY>","title":"星灯云浪","body":"收到新私聊，请打开应用查看","group":"starwave-chat","isArchive":0}
```

禁止正文、发送者姓名、消息密文、主站 token 和私钥进入通知；首版不提供明文预览开关，不设置尚未实现的 App 深链。Bark HTTP 2xx 且业务 code=200 才记 accepted；结构示例：

```json
{"code":200,"message":"success","timestamp":1792386000}
```

消息提交与 outbox 原子落库；幂等键 `(message_id,target_device_id)`，测试任务用独立 ID。不因推送失败回滚消息，消费任务采用持久30秒租约；超时、429、5xx 最多重试 5 次（加上首发共 6 次，退避基准 1/2/4/8/16 秒，加入抖动并遵守 Retry-After）；其他4xx停止并记录脱敏错误。任务最长24小时，到期停止，即使 Retry-After 或静默窗口更晚也不续期。已解绑/撤销/私下已读/隐藏/清空/撤回/过期/屏蔽的消息跳过，**仅 ack 不消除未读提醒**；不向发送账号副本通知。静默后按设备/窗口合并一条通用摘要，正常突发按设备10秒窗口合并。Bark 超时重试可能重复提醒，不能宣称 exactly-once。

## 7. 启用门槛与非目标

新协议不直接恢复旧 Android 私钥。用户后续明确批准旧安卓互通，因此新增显式 V1 密文适配，不在服务器解密转换；边界与固定兼容版本见安卓互通文档。不能静默接管旧私钥或把两套密码学混用。用户迁移的是使用能力，不是未经授权复制源项目代码。

在[整改验收矩阵](../CHAT_SERVER_REMEDIATION.md)关键上线项目通过并记录证据前，不加入 iOS 请求目录、不宣称当前 App 聊天已可用。客户端加密备份和可信设备迁移后端已加入扩展；群聊、附件、语音、通话、自动备份、前向保密与身份透明日志仍不在范围内。
