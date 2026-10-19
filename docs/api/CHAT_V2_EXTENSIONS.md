# 私聊 V2：会话、隐私、提醒与加密历史

2026-10-19，**LOCAL IMPLEMENTED / 本地实现；部署状态见[生产记录](../CHAT_DEPLOYMENT_2026-10-19.md)；未真机联调**。核心已部署，但R2未开通，本文备份/迁移存储功能暂不可用。源码在 [backend/nu-chat-worker](../../backend/nu-chat-worker/README.md)，基础会话、密钥、消息和同步见 [V2 基础](CHAT_V2_PROPOSAL.md)，安卓双协议另见 [互通契约](ANDROID_INTEROP.md)。这些接口不计入现有 iOS 87 项入口。

## 通用规则

全部使用**聊天 Bearer**；无特别说明则无 query。JSON UTF-8；GET/DELETE 无 body；成功 HTTP200 `{"ok":true,"data":...}`，无数据时 `{"ok":true}`。失败为基础契约的 `error:{code,message,retryable}`，不含上游原文。未知字段、重复/未知 query 拒绝400；不支持方法405。ID 为 UUID，subject 原样使用服务端返回值，seq/revision 为十进制字符串，时间为毫秒整数。CAS 首次 `expected_revision:"0"`；冲突409后重新读取，不盲目覆盖。

`conversations / blocks / private_reads / history_controls / notification_preferences / legacy_android_interop` 为本地实现能力；只有配置私有 R2 才返回 `encrypted_backups / device_history_transfer`，只有 Bark 硬开关和加密密钥均有效才返回 `bark`。未配置 R2 为503 `HISTORY_NOT_CONFIGURED`，Bark 为503 `BARK_NOT_CONFIGURED`。配置错误不是成功空结果。

## 账号与屏蔽

### GET /chat/v2/me/preferences

用途：读取账号范围偏好；无 body。未设置返回默认：

```json
{"ok":true,"data":{"revision":"0","receive_policy":"everyone","read_receipts":true,"retention_days":30}}
```

### PATCH /chat/v2/me/preferences

请求必须 `expected_revision`，其余可选、保留未指定值：

```json
{"expected_revision":"0","receive_policy":"existing","read_receipts":false,"retention_days":7}
```

返回与 GET 相同形状、revision 递增。receive_policy 为 `everyone/existing/none`；existing 只允许“**我曾向对方发送过消息**”的人，不把对方单向发来当作建立关系。默认 everyone。read_receipts=false 只隐藏自己的未来已读，仍可看对方公开已读，仍清除自己的未读；不回收已披露的历史。retention_days 仅1/7/30；缩短会裁剪**自己的副本**，延长不复活旧副本，不改变对方保留期。非法值400，旧版本409 `REVISION_CONFLICT`。

### GET /chat/v2/blocks

自己的单向屏蔽列表，无 body：`data:{blocked:[{subject,blocked_at_ms}]}`。不返回他人的屏蔽关系。

### PUT /chat/v2/blocks/{subject}

请求 `{}`，目标 subject URL 编码。幂等成功 `{"ok":true}`；阻止该人向我发新消息并取消待发提醒，**不阻止我主动向他发**，不清空已存在历史。自己400，目标不存在404，发送遇到拒收/屏蔽409 `DELIVERY_NOT_ALLOWED`（旧协议为 `DELIVERY_OR_KEY_CONFLICT`），不揭示具体隐私原因。

### DELETE /chat/v2/blocks/{subject}

无 body，幂等成功 `{"ok":true}`。解除后仍受 receive_policy 限制。

## 会话列表、状态与历史

### GET /chat/v2/conversations

query 可选 `limit`（1–100，默认50）、`cursor`（签名游标）、`archived`（false/true/all，默认false）。按置顶优先、最后服务端消息 seq 降序、会话ID稳定排序；游标绑定账号、设备与筛选条件。不是跨多次请求的冻结快照，实时新消息/置顶变化后应刷新首屏，按 ID 合并。

```json
{"ok":true,"data":{"conversations":[{"conversation_id":"<UUID>","peer_subject":"account:2","pinned":false,"archived":false,"last_seq":"12","last_visible_message_id":"<UUID>","unread_total":3,"unread_available":2,"history_gap":true,"revision":"0"}],"unread_total":3,"has_more":false,"next_cursor":"<SIGNED_CURSOR>"}}
```

unread_total 为账号范围可见、未过期、个人已读位置之后的入站消息数；unread_available 为当前设备实际有 envelope 的数量。history_gap 表示可见历史中存在当前设备没有 envelope 的消息；不可把0条历史当作完整。最后可见消息可能 null；不提供服务端明文预览，客户端本地解密。顶层未读计数不随 archived 筛选清零。

新增peer_username（当前账号规范用户名）供陌生会话寻址；peer_subject仍为所有权依据，用户名变更不迁移历史归属。消息详情/同步返回对应版本发送者公钥和双方用户名，见基础契约只读元数据说明。

### GET /chat/v2/conversations/{conversation_id}/state

自己参与的会话，无 body：

```json
{"ok":true,"data":{"revision":"0","pinned":false,"archived":false,"archived_seq":"0","clear_seq":"0"}}
```

### PATCH /chat/v2/conversations/{conversation_id}/state

```json
{"expected_revision":"0","pinned":true,"archived":true}
```

后两字段可选；返回 GET 形状。设置跨自己所有设备同步；归档记录当时最新 seq，后续新消息自动使有效 archived=false，恢复/查看备份不算新消息。旧版本409，非参与人403。

### GET /chat/v2/conversations/{conversation_id}/messages

query 可选 `before`（十进制字符串、默认 signed64最大值，排他）、`limit`（1–200，默认100）。无 body。返回 `data:{messages:[<与sync相同的消息payload，无event_seq>],has_more,next_before,history_scope:"current_device_envelopes"}`，消息 seq 降序；next_before 为最后 seq 或 null。不返回他人设备密文；隐藏、清空、撤回和自己保留期过滤；缺失 envelope 通过会话 history_gap 提示，不在此假造内容。

### POST /chat/v2/conversations/{conversation_id}/clear

```json
{"expected_revision":"1","through_seq":"12"}
```

返回状态形状；through_seq 必填、不大于会话最新 seq，只能前进不能回退。只影响自己的设备与未读；对方副本不删，之后新消息正常出现。未来 seq400，CAS409。产生恢复过滤标记，旧备份不能让清空内容重新显示。

### DELETE /chat/v2/messages/{message_id}

无 body，幂等 `{"ok":true}`。仅自己的所有设备隐藏该消息；不修改对方，更新恢复过滤版本。非参与人403，不存在404。

### POST /chat/v2/messages/{message_id}/recall

请求 `{}`；仅原发送者、服务端接收后 **10分钟内**。成功 `data:{recalled_at_ms}`，重复返回原时间。双方同步撤回事件，移除同步 envelope、取消待发提醒，并更新双方恢复过滤。超过409 `RECALL_WINDOW_EXPIRED`，接收者403。无法远程删除截图、导出和离线副本；旧安卓没有撤回事件 UI，已下载的旧本地内容无法强删。

## 分层提醒

四层优先级：账号默认 → 设备默认 → 账号会话 → 设备会话。按**字段**覆盖，未写字段继承，`quiet_hours:null` 显式关闭静默时段。Bark 绑定自身 enabled=false/删除以及后端硬开关具有最终否决权。

四类 PATCH 请求完全相同：

```json
{"expected_revision":"0","overrides":{"enabled":true,"muted":false,"mute_until_ms":0,"quiet_hours":{"timezone":"Asia/Shanghai","start":"23:00","end":"07:00","weekdays":[1,2,3,4,5,6,7]}}}
```

overrides 是本层**完整替换**，空 `{}` 恢复全部继承。enabled/muted 为bool，mute_until_ms 非负整数；quiet_hours 为 null 或完整对象。IANA 时区（非法400 `INVALID_TIMEZONE`）；start/end 为24小时 HH:mm、不可相等、跨度≤23小时；weekdays 不重复的1–7（周一至周日），跨午夜归属于**开始那一天**，DST 按时区墙钟时间。无显式配置默认 enabled=true、muted=false、mute_until=0、quiet_hours=null。

四类 GET/PATCH 返回相同形状：

```json
{"ok":true,"data":{"revision":"1","overrides":{"muted":true},"effective":{"enabled":true,"muted":true,"mute_until_ms":0,"quiet_hours":null}}}
```

### GET /chat/v2/me/notifications

读取账号默认，无 query/body。

### PATCH /chat/v2/me/notifications

替换账号默认；使用上述请求与响应。

### GET /chat/v2/devices/{device_id}/notifications

读取设备默认，device_id 必须为当前会话设备，否则403。

### PATCH /chat/v2/devices/{device_id}/notifications

替换当前设备默认；上述请求/响应，不能修改另一设备。

### GET /chat/v2/me/conversations/{conversation_id}/notifications

读取账号会话层；仅会话参与人。

### PATCH /chat/v2/me/conversations/{conversation_id}/notifications

替换账号会话层；上述请求/响应。

### GET /chat/v2/devices/{device_id}/conversations/{conversation_id}/notifications

读取设备会话层；须同时满足当前设备与会话参与人。

### PATCH /chat/v2/devices/{device_id}/conversations/{conversation_id}/notifications

替换设备会话层；上述请求/响应。

静默内任务延期到结束，不消耗重试次数；结束时只对仍未读、未删除、未屏蔽、未过期的消息按设备/静默窗口发**一条通用摘要**，不逐条补发。mute/disabled 则直接丢弃当次提醒，不积压。消费前重验设置，已发或在途不能撤回。任务24小时硬期限仍有效，极长静默或平台故障可能使其过期，不承诺必达。更多 outbox 语义见基础契约。

### GET /chat/v2/devices/{device_id}/bark

当前设备、无 body/query。原文 key 不可读回：

```json
{"ok":true,"data":{"server_url":"https://api.day.app","enabled":true,"key_configured":true,"device_key_masked":"••••1234","revision":"2"}}
```

未配置时 enabled/key_configured=false、masked=null、revision="0"。更新/测试/解绑/状态见基础契约；切换 enabled 可省略 device_key 保留旧秘密。

## 历史过滤、配额与恢复包

恢复不是重新发送：客户端下载后本地校验、解密、按 message_id 去重并应用最新过滤，再合并自己的历史。不调用 messages 发送恢复记录，不生成未读/提醒/新回执。本地恢复密钥、配对秘密或私钥永不作为下面接口字段。

### GET /chat/v2/history/filters

不依赖 R2。query 可选 `cursor`、`limit`（1–500，默认200）。返回一份账号范围、带版本的分页删除过滤；必须取完整所有页，同次读取若版本变化409 `FILTER_CHANGED`，从头重取后再恢复。客户端同时处理实时删除事件，避免恢复提交期间展示旧删除内容。

```json
{"ok":true,"data":{"revision":"3","filters":[{"type":"hidden","target":"<MESSAGE_UUID>","through_seq":null},{"type":"clear","target":"<CONVERSATION_UUID>","through_seq":"12"},{"type":"recall","target":"<MESSAGE_UUID>","through_seq":null}],"has_more":false,"next_cursor":null}}
```

### GET /chat/v2/history/quota

无 body/query。额度计入上传中、待批准、已就绪及**尚未清理的取消/过期包**，删除 R2 成功后才释放：

```json
{"ok":true,"data":{"chunk_bytes":1048576,"max_pack_bytes":104857600,"account_bytes":524288000,"max_uploads":2,"backup_days":30,"transfer_hours":24,"reserved_bytes":92}}
```

### 恢复包通用响应与授权

以下 `Pack` 形状用于列表、创建、批准、complete；revision 每次状态切换递增。null 字段仍保留：

```json
{"pack_id":"<UUID>","kind":"backup","state":"uploading","revision":"1","source_device":"<UUID>","target_device":null,"expected_bytes":92,"chunk_count":1,"recovery_key_id":"<UUID>","target_public_key":null,"source_public_key":null,"approval_proof":null,"created_at_ms":1792386000000,"expires_at_ms":1794978000000,"approval_expires_at_ms":null}
```

状态：backup `uploading→ready`；transfer `awaiting_approval→uploading→ready→completed`；取消转 `deleting→cancelled`，过期转 `deleting→expired`。deleting 期间读取410且额度不释放；清理可能重试。跨账号403，未知包404 `PACK_NOT_FOUND`，过期/失效410 `PACK_EXPIRED`。备份同账号活跃设备可读取 ready 包；迁移仅 target 可下载/source 可上传；创建时已存在的同账号活跃设备作为批准候选，后来新增设备不能批准旧迁移请求。

### GET /chat/v2/history/backups

query 可选 `before`（整数位置，排他）、`limit`（1–100，默认50）。返回 `data:{packs:[Pack],has_more,next_before}`；按不可变创建 rowid 降序，不按客户端时间。包含过期/取消元数据，不代表对象仍可下载。

### POST /chat/v2/history/backups

手动备份，创建并预留配额：

```json
{"pack_id":"<CLIENT_UUID>","expected_bytes":92,"chunk_count":1,"recovery_key_id":"<RANDOM_KEY_ID_UUID>"}
```

expected_bytes 为总**密文**字节，≥29且≤单包限制；chunk_count 必须 ceil(bytes/1048576)，最后一块大小严格匹配。recovery_key_id 是标识，不是恢复密钥。返回 `data:Pack`。相同设备/ID/完全相同请求幂等；改请求409 `IDEMPOTENCY_CONFLICT`。创建限10次/账号/分钟，并发上传/额度超409 `QUOTA_OR_UPLOAD_LIMIT`。无自动定时备份，30天从创建算起。

### GET /chat/v2/history/backups/{pack_id}

无 body/query；返回 `data:{...Pack,chunks:[{chunk_index,bytes,digest,state}],manifest,restore_filters:"/chat/v2/history/filters"}`。manifest 仅 ready 返回原始密封 JSON 字符串，其余 null；digest 为 SHA256密文字节标准Base64，state=writing/ready，用于断点续传。

### DELETE /chat/v2/history/backups/{pack_id}

query `expected_revision` 必填（已终止包重复删除可成功），无 body。返回 `data:{state:"deleting"}`；已终止时 `{"ok":true}`。不立刻释放额度，不让R2失败变成无配额孤儿对象。

### GET /chat/v2/history/transfers

分页参数/响应与备份列表相同，但仅显示自己是目标、来源或批准候选的迁移包。

### POST /chat/v2/history/transfers

由新目标设备发起，target 公钥为本次临时 X25519，max_bytes 可选、默认单包最大值，并按该值预留额度：

```json
{"pack_id":"<CLIENT_UUID>","target_public_key":"<BASE64_X25519_SPKI>","max_bytes":104857600}
```

返回 `data:Pack`、state=awaiting_approval、revision="1"，批准窗口10分钟，整体包自创建24小时到期。重复规则同备份。前端另外生成32字节配对秘密放入二维码，**不发给服务端**。

### GET /chat/v2/history/transfers/{pack_id}

返回形状同备份详情；待批准候选可查看目标公钥，用于扫码后核对；批准后仅 source/target 可查看。不能用任意新设备冒充旧可信设备。

### DELETE /chat/v2/history/transfers/{pack_id}

取消自己的参与包；query `expected_revision`，无 body；结果/GC/错误同备份删除。

### POST /chat/v2/history/transfers/{pack_id}/approve

只能由创建时存在且**密钥版本未变**的同账号旧候选设备批准：

```json
{"expected_revision":"1","expected_bytes":92,"chunk_count":1,"source_public_key":"<TEMP_X25519_SPKI>","approval_proof":"<BASE64_HMAC_SHA256>"}
```

大小不能超 max_bytes 原预留，批准后缩小预留并确定 chunk_count；返回 `data:Pack` state=uploading revision="2"。证明是对二维码秘密的 HMAC，服务端只验格式/身份，不可能验证秘密；必须由目标客户端验证，失败不恢复。目标不能自己批准；候选过期/状态不对409 `APPROVAL_UNAVAILABLE`、未知候选403、CAS409。

### PUT /chat/v2/history/backups/{pack_id}/chunks/{index}

上传当前包0基分块，**Content-Type: application/octet-stream**，body 原始密文字节，不是 JSON/Base64；header `X-Chunk-SHA256: <BASE64_SHA256>` 必填。除最后一块外精确1MiB；超过413，大小不匹配400 `CHUNK_SIZE_MISMATCH`，摘要不符400 `DIGEST_MISMATCH`。返回 `data:{chunk_index,digest}`。同index/内容重试幂等、不同内容409；只在 uploading 状态的来源设备允许上传，120次/账号/分钟。预留 D1 writing 行后写 R2，再标 ready；中断可重传，取消并发会补偿删除晚到对象。

### PUT /chat/v2/history/transfers/{pack_id}/chunks/{index}

格式、大小、摘要、幂等、返回同备份分块；必须批准后的 source_device 上传，target 不可上传。

### GET /chat/v2/history/backups/{pack_id}/chunks/{index}

无 body/query；仅 ready，成功为**二进制响应** `application/octet-stream`，`Cache-Control:no-store`，header X-Chunk-SHA256 可校验；不是 `{ok,data}`。非ready409 `PACK_NOT_READY`，不存在块404 `CHUNK_NOT_FOUND`，R2缺失503 `OBJECT_UNAVAILABLE`。前端先校验摘要，再AEAD解密。

### GET /chat/v2/history/transfers/{pack_id}/chunks/{index}

同二进制格式，仅 target_device 可下载 ready 包；source不可下载（409），不表示服务器能证明目标真实解密。

### POST /chat/v2/history/backups/{pack_id}/complete

```json
{"expected_revision":"1","manifest":"{\"format\":\"nu-chat-history/1\",\"salt\":\"<BASE64_32_BYTES>\",\"sealed_manifest\":\"<BASE64_NONCE_AND_GCM_CIPHER>\"}"}
```

manifest 是 UTF-8 ≤64KiB 的 JSON**字符串**，只能含 format/salt/sealed_manifest；sealed_manifest 解码28–49152字节。只校验密封外壳，不解密。所有块数/字节/ready校验在同一事务完成，返回 `data:Pack` state=ready revision递增；未完成或旧版本409，同ready且完全同manifest重试幂等。不能替换已完成清单。

### POST /chat/v2/history/transfers/{pack_id}/complete

相同请求/响应；只能 source 完成，批准后通常 expected_revision="2"。

### POST /chat/v2/history/transfers/{pack_id}/ack

目标校验/解密/去重并应用最新过滤后确认：

```json
{"expected_revision":"3","filter_revision":"0"}
```

返回 `data:{state:"completed"}`，同状态重试成功；非目标403，过滤版本已变409 `FILTER_CHANGED`，先重取/重应用后重试；包过期410。标完成后触发后续GC，不再下载。此 ack 不是消息 read/received，也不产生会话未读。备份不需要此确认，读取不延长30天期限。

## 客户端加密格式（参考实现，不是服务端解密）

实现与负向测试：[recovery-crypto.js](../../backend/nu-chat-worker/src/recovery-crypto.js)、[recovery.test.js](../../backend/nu-chat-worker/test/recovery.test.js)。

- 备份 root 为独立安全随机32字节恢复密钥（标准Base64），不是密码；用户自行保管，服务端不知，丢失不能重置解密。每包另取32字节 salt。
- `context=["nu-chat-history/1",owner,pack_id,kind]`，HKDF-SHA256(root,salt,info=UTF8(JSON.stringify(context)))→AES256GCM key。每块新随机12字节nonce、tag16；密封字节 `nonce||ciphertext||tag`，所以分块明文最多1048548字节。块 AAD 为 JSON.stringify([...context,"chunk",index])，manifest AAD 为 [...context,"manifest"]；不可互换index/包/账号。
- manifest 解密内容建议 `{format:"nu-chat-records/1",chunks:[{index,digest}],records:<count>}`；有序密文摘要和记录schema需客户端严格校验，恢复记录必须含 message_id/conversation_id/conversation_seq，且不能含未经用户同意的凭据。服务端不验证内部业务记录，不接受私钥字段。
- 迁移二维码秘密随机32字节，临时两端 X25519；pairingContext 为按键名排序 canonical JSON `{owner,pack_id,source_device,target_device,source_public_key,target_public_key}`；proof=HMAC-SHA256(QRsecret,UTF8(pairingContext))。root=HKDF-SHA256(ECDHshared,salt=SHA256(QRsecret),info=UTF8("nu-chat-transfer/1:"+pairingContext))32字节。双方核对同一上下文、验证proof后才导入。
- 恢复只合并用户可解密内容，先校验AEAD、ID去重，应用 hidden/clear/recall；不得把缺密钥、缺分块、错误证明当作成功。恢复包可含用户主动导出的历史/密钥材料，其安全存储、确认UI和导入由未来前端负责，本轮未做iOS页面。

## 同步事件与本地消费

新增账号范围事件：`preferences_changed`、`blocks_changed`、`notification_preferences_changed`（只有 type，需重新GET相应设置）；`conversation_state_changed`/`history_cleared` 包含 conversation_id/through_seq；`message_hidden`/`message_recalled` 包含 message_id。事件均有 event_seq，由正常同步游标消费，只发给有权设备。恢复包进度通过详情GET查询，不用伪造会话事件。

不可见旧消息在 sync 中保留事件位置，但**无 envelope**且 `unavailable:"hidden"|"recalled"`，前端删除/隐藏本地显示，不解密、不生成已读。API不会远程清除已经存到旧安卓的本地密文或明文。
