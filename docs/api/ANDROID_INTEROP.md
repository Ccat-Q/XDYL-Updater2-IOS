# 旧安卓与 V2 新前端互通

2026-10-19，**本地实现并测试；部署状态见[生产记录](../CHAT_DEPLOYMENT_2026-10-19.md)；未APK真机联调**。兼容层已随核心后端上线；iOS 2.3.0 已实现双协议文字私聊，固定向量和构建验收见[IOS_CHAT.md](../IOS_CHAT.md)，不等同真实安卓与iOS已完成互聊验收。

兼容目标固定为 [`UNSA-studio/xdyl@36d3a8c61ee2ffce3c3fe184356cc4125a119fcd`](https://github.com/UNSA-studio/xdyl/tree/36d3a8c61ee2ffce3c3fe184356cc4125a119fcd)，不是泛指任何历史 APK。该版本 [ChatApi.kt](https://github.com/UNSA-studio/xdyl/blob/36d3a8c61ee2ffce3c3fe184356cc4125a119fcd/app/src/main/java/www/xdyl/hygge/com/ChatApi.kt) 已在 GET/POST 携 Bearer、使用数值 seq cursor；[ChatCrypto.kt](https://github.com/UNSA-studio/xdyl/blob/36d3a8c61ee2ffce3c3fe184356cc4125a119fcd/app/src/main/java/www/xdyl/hygge/com/ChatCrypto.kt) 仍为单公钥 `nu-chat-v1`。早期 fe877 的缺陷保留在[历史证据](CHAT_V1.md)，不篡改成当前行为。

## 技术选择和限制

仅在后端保留两组路径不能互聊，因为 V1/V2 的 HKDF、AAD、设备身份不同；中继没有私钥，不能解密升级。因此采用**新前端双编解码 + 显式兼容主设备**：新设备用已有两曲线密钥接受旧密文，服务器按安卓调用者曲线返回匹配公钥；新前端发给旧安卓时主动生成 V1 密文，经兼容发送接口写入旧收件流及统一会话元数据。服务器不读明文。

- Android33+ 使用 X25519，较早版 P256。两类旧安卓彼此曲线不同仍无法互聊；新前端支持两者，不等于后端能转换旧旧密文。
- 每个新版账号明确指定**一个**兼容主设备，其私钥才可解密旧协议消息；不为其他设备伪造可解密 envelope。其他设备会显示 history_gap，可另行可信设备迁移/备份恢复。原生 V2 消息仍正常覆盖所有活跃设备。
- 新版账号已有独立旧安卓公钥时，不允许新设备抢占；409 `LEGACY_ACCOUNT_ALREADY_IN_USE`。同账号安卓/iOS若持有不同私钥，不能冒用同一旧身份。需未来客户端显式导入并核验原私钥，或维护方与用户安排迁移；本轮没有静默覆盖或后台托管私钥。
- 主设备撤销/密钥轮换后停止旧兼容，不静默退回旧数据库公钥。主设备可在轮换后以当前 key_revision/expected_revision 显式重绑定；**不能改成另一台主设备**。目前没有自动主设备故障接管或重置接口，需上线前安排人工恢复方案。
- 旧安卓会缓存会话公钥、仍可能HTTPS失败后HTTP回退。服务端拒绝HTTP，但无法阻止客户端在网络上传出明文Bearer；需要安卓维护方移除回退。旧APK公钥缓存变化后可能需重启/重建会话，不能承诺无感换钥。
- 老版本APK没有Bearer或使用时间since不能安全兼容；不以取消认证修复。旧安卓也不会消费新版删除/撤回事件，已经下载的本地记录不能强制抹去。

## 安卓已有路径的当前加固契约

下列沿用旧字段和 `{ok:true}` envelope；错误 `{"ok":false,"error":"CODE","request_id":"UUID"}`，不是V2 error对象。保护操作使用**主站 Bearer**（不是聊天token），服务端每次核验稳定账号ID/用户名；用户名不可回退昵称。HTTPS only，无query/body token。

| 方法与路径 | 请求 | 成功返回与变化 |
| --- | --- | --- |
| GET /chat/ping | 无认证/body/query | `{ok,ts,mode:"d1",protocol:"legacy-d1",retention:"operator-managed",limits:{page:500},v2_path}`；不是完整V2就绪证明 |
| POST /chat/key | Bearer；`{userId?,username?,publicKey,expectedPublicKey?}` | `{ok:true,userId}`；DER SPKI严格校验；初次登记建立稳定subject映射，已有密钥不同须显式CAS，否则409 `KEY_CHANGE_REQUIRES_CONFIRMATION`。旧APK不会自动确认换钥 |
| GET /chat/key/{username} | 无body/query；当前安卓携Bearer | `{ok:true,data:{userId,publicKey}}`；有Bearer先鉴权并按调用者已登记曲线返回目标公钥，无匹配曲线409 `LEGACY_ALGORITHM_MISMATCH`，目标主设备失效409 `LEGACY_DEVICE_UNAVAILABLE`。匿名兼容查询只取默认公钥，不允许写入 |
| POST /chat/send | Bearer；`{from?,to,msgId,cipher,ts}` | `{ok:true,duplicate,seq}`；from须等于认证用户，cipher严格nonce/tag格式；相同发送人/msgId同内容幂等，改内容/ts409。新旧消息共用屏蔽/拒收/保留规则；身份未认证绑定409 `LEGACY_IDENTITY_UNBOUND` |
| GET /chat/pull | Bearer；query cursor数值默认0、limit1–500默认200 | `{ok:true,data:[{seq,msgId,from,to,cipher,ts}],next_cursor:<number>,has_more,server_time_ms}`；按服务端seq分页，隐藏/撤回/过期不返回正文，但next_cursor仍跨过过滤位置。非0 since409 `LEGACY_CURSOR_UNSUPPORTED`，不把旧时间冒充seq |
| POST /chat/read | Bearer；`{peerId,upto:<number seq>}` | `{ok:true}`；upto须为真实对方向自己发送的旧seq，单调保存并映射统一会话个人/公开已读。不根据pull伪造read或delivered |

### GET /chat/read

主站Bearer，query `peerId`，无body。补充读取自己的和对方**公开**已读位置，均为旧流数值seq：

```json
{"ok":true,"data":{"peerId":"bob","own_upto":12,"peer_upto":10}}
```

自己的进度为旧客户端read水位，对方从统一 disclosed_seq 映射；对方隐藏的未来已读不泄露。新前端private read不依赖旧水位。当前固定安卓的ChatPage未见实际调用markRead，不能因为API存在就显示其一定已读。

原用户提供的D1旧表由0001保留，0002–0004增量增加统一身份/会话/链接；已有历史没有凭空生成客户端envelope，不自动搬迁旧私钥。每个旧账号至少认证登记一次建立公钥所有者/稳定ID后才参与新发送，避免按用户名猜测归属。**导入库里无稳定身份链接的历史暂不向客户端返回**，游标仍跨过这些行；需要维护方有可靠旧身份依据后另行设计回填，不能用当前用户名猜测旧历史主人。用户名回收后也不把前账号的历史/已读归给新账号。原始旧密文最多保留30天并由cron清理，自己的更短保留限制在拉取时生效；删除过滤/最小幂等元数据另保留。

## 新前端兼容接口（聊天 Bearer）

均无query；GET无body；V2成功/错误形状见[V2基础](CHAT_V2_PROPOSAL.md)。需 feature=legacy_android_interop，并由用户明确同意兼容限制。新前端先查询双方协议，纯V2使用原生路径；旧对方才调用这里，**不双发同一消息**。

### GET /chat/v2/devices/{device_id}/legacy

仅当前活跃设备：`data:{enabled,device_id,revision,primary_device_only:true}`。未绑定 enabled=false/device_id=null/revision="0"；已绑定返回账号主设备ID，不代表当前设备自动拥有其私钥。

### POST /chat/v2/devices/{device_id}/legacy

当前活跃设备、已登记双曲线密钥：

```json
{"expected_revision":"0","key_revision":"1","default_algorithm":"X25519"}
```

default_algorithm可省略默认X25519；返回 `data:{enabled:true,device_id,revision:"1",primary_device_only:true}`。相同已提交配置且版本相邻的重试幂等；其他CAS冲突409 `REVISION_CONFLICT`，密钥快照不符409 `KEYSET_CHANGED`，已有不同旧身份409 `LEGACY_ACCOUNT_ALREADY_IN_USE`，已选另一主设备409 `LEGACY_IDENTITY_ALREADY_BOUND`。不能选择别人或另一聊天会话设备（403）。旧安卓不能使用 `/chat/send` 冒用新版主设备（409 `LEGACY_PRIMARY_DEVICE_REQUIRED`）。

### GET /chat/v2/users/{username}/protocols

返回可用协议与旧套件当前公钥，不保证历史密钥完整：

```json
{"ok":true,"data":{"username":"bob","subject":"account:2","protocols":["nu-chat-v1"],"legacy_public_keys":[{"algorithm":"P256","public_key":"<BASE64_SPKI>"}],"legacy_primary_device":null}}
```

纯原生V2没有legacy密钥时仅返回nu-chat-v2；兼容主设备有效时可返回两协议与两曲线；没有稳定账号404。主设备失效不回退旧raw公钥。新前端必须选择对方支持的曲线，并取得自己兼容主设备该曲线密钥。

### POST /chat/v2/legacy/messages

```json
{"client_msg_id":"<UUID>","to_username":"android","cipher":"<BASE64_NONCE>:<BASE64_CIPHER_AND_TAG>","ts":1792386000000,"sender_key_id":"<OWN_PRIMARY_KEY_UUID>","recipient_public_key":"<PEER_CURRENT_SPKI>"}
```

仅兼容主设备；ts安全整数，nonce12/tag16，正文≤16KiB；sender_key_id须为主设备当前版本的对应曲线key，recipient_public_key作为快照CAS校验。成功**保留旧响应** `{"ok":true,"duplicate":false,"seq":12}`，不是data对象；规范V2 message_id/conversation_id由sync获得。内部msgId为 `v2:<device_id>:<client_msg_id>`。重复同内容返回同旧seq，改内容409。并发原子落库：旧流消息、统一会话消息、双方副本、持钥主设备事件、提醒outbox；原生新消息接口仍拒绝此cipher格式。

旧套件消息在新版sync中：

```json
{"event_seq":"20","type":"message","message_id":"<UUID>","client_msg_id":"old-message-id","conversation_id":"<UUID>","conversation_seq":"8","sender_subject":"account:1","sender_device_id":"legacy:android","recipient_subject":"account:2","accepted_at_ms":1792386000000,"expires_at_ms":1794978000000,"envelope":{"protocol":"nu-chat-v1","algorithm":"P256","cipher":"<BASE64_NONCE>:<BASE64_CIPHER_AND_TAG>","sender_public_key":"<SPKI>","recipient_public_key":"<SPKI>","own_key_id":"<PRIMARY_KEY_UUID>"}}
```

envelope.protocol明确决定编解码；发送者是主设备时sender_device_id为真实UUID，否则legacy:username。不能按UUID格式强行解析旧发送设备。其他设备没有这份密文，显示缺口。隐藏/清空/撤回/保留/未读按统一会话规则生效；旧pull只返回该旧身份有权可见密文。

## 密码学与验证

V1：DER SPKI，ECDH X25519/P-256，HKDF-SHA256 salt=32个0字节、info=UTF8("nu-chat-v1")、32字节key；AES256GCM随机nonce12、tag16、**无AAD**，cipher=`base64(nonce):base64(ciphertext||tag)`。不得套用V2的AAD/hash salt。由于V1无身份AAD，不拥有V2的元数据绑定性质，不能把兼容安全级别宣传成完全相同。

参考客户端函数 [protocol.js](../../backend/nu-chat-worker/src/protocol.js)（服务端不使用私钥），[安卓双向测试](../../backend/nu-chat-worker/test/android.test.js) 对照独立 Node/OpenSSL ECDH/HKDF/AES 实现，覆盖X25519和P256；固定公开测试密钥与预期密文见 [crypto-vectors.json](../../backend/nu-chat-worker/test/crypto-vectors.json)、[向量测试](../../backend/nu-chat-worker/test/vectors.test.js)，仅供测试，禁止用于真实账号。另有真实workerd/D1测试确认按请求方曲线返回公钥及统一屏蔽规则。测试不代表APK真机、Swift或Bark真机验收；后续已部署核心并做无凭据线上检查，未进行真实账号收发。
