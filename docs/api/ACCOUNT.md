# 账户、公开玩家资料、表情与绑定

共 14 项。服务 MAIN，iOS 均使用 Bearer；GET 无请求体、未列出的 Query 均为无。阅读 [通用约定](README.md)。

## 接口目录

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/user/profile` | 本人私有账户资料 |
| POST | `/user/profile` | 更新昵称/简介 |
| POST | `/user/avatar` | 上传头像 |
| POST | `/user/password` | 修改密码 |
| POST | `/user/change-username` | 修改社区用户名 |
| POST | `/user/bind-qq` | 已登录账户绑定 QQ |
| POST | `/user/unbind-qq` | 解绑 QQ |
| GET | `/user/items` | 我的物品/兑换码 |
| GET | `/user/emojis` | 我的表情 |
| POST | `/user/emojis` | 上传表情 |
| GET | `/user/game-bindings` | 游戏账号绑定列表 |
| POST | `/user/game-bindings` | 添加绑定 |
| POST | `/user/game-bindings/delete` | 删除绑定 |
| GET | `/player/info/{player}` | 指定玩家公开主页 |

### GET /user/profile

用途：本人资料、余额、账户权限及游戏统计。响应示例（C）：

```json
{"code":200,"data":{"username":"demo","nickname":"示例","email":"demo@example.invalid","role":"user","balance":50,"qq_bound":true,"qq_nickname":"示例 QQ","avatar":"avatar_demo.png","bio":"简介","level":3,"exp":120,"next_level_exp":200,"points":10,"playtime":7200,"title":"&b示例称号"}}
```

字段：`username/nickname/email/role/bio/title` string；`balance` number/string（兼容 `coins`）；`qq_bound` bool，兼容根据 `qq_nickname` 是否存在推断；`avatar` 兼容 `avatar_url`；`level/exp/next_level_exp/points/playtime` integer 或数字字符串。`playtime` 单位秒。payload 兼容 `data/profile/root`。角色 `admin/super_admin` 控制管理网页入口，不代表获得其他接口的管理权限。

缺失字段的模型默认值是 UI 容错，不是服务端保证。本人私有资料包含邮箱，不与公开主页模型混用；只应用当前会话最新一次刷新。

### POST /user/profile

用途：编辑昵称、简介。请求体 JSON：

```json
{"nickname":"新的昵称","bio":"新的简介"}
```

两项 string。返回体：Ack；成功后重新 GET `/user/profile`。不推断可以用本路由修改 role、余额或用户名。

### POST /user/avatar

用途：更换头像。Query：无。请求体是 multipart，**不是 JSON**：

```http
Content-Disposition: form-data; name="avatar"; filename="avatar.jpg"
Content-Type: image/jpeg

<图片二进制>
```

返回体：上传结果的完整负载未消费，成功后重读 `/user/profile` 获取头像；按 Ack 校验。客户端 5 MB、MIME/转换规则见总说明。相册异步读取前固定账号，准备后与返回后核验代际；离页取消，禁止将旧账号选图发给新账号。

### POST /user/password

用途：已登录修改密码。JSON：

```json
{"old_password":"<OLD_PASSWORD>","new_password":"<NEW_PASSWORD>"}
```

返回体：Ack。与忘记密码的 `/reset-password` 区别在于 Bearer 和旧密码，不发送邮件 code。是否撤销其他会话由服务端决定，尚未核实。

### POST /user/change-username

用途：更改社区用户名。JSON：

```json
{"new_username":"NewDemo"}
```

返回体：Ack；客户端成功后刷新本人资料。不可将此写操作理解为更改 Minecraft 游戏名/游戏绑定，费用、冷却与服务端限制待核实。

### POST /user/bind-qq

用途：已登录社区账号绑定刚授权的 QQ。JSON：

```json
{"temp_token":"<QQ_TEMP_TOKEN>"}
```

临时凭证来自同次绑定流程的 `/check-qq-login`，绑定授权使用 `/qq-login?session_id=...&mode=bind`。返回体：Ack，当前客户端成功后刷新资料。不提交 QQ 密码，也不同于匿名 `/qq/bind`。

### POST /user/unbind-qq

用途：解绑当前账号 QQ。请求体 JSON：

```json
{}
```

返回体：Ack；成功后刷新资料。需用户确认，不存在已恢复的任意用户解绑参数。

### GET /user/items

用途：本人兑换码、商城购买结果入口，以及选择可用于 YSM 的兑换码。已知返回（C/S）：

```json
{"code":200,"data":{"items":[{"id":1,"code":"<REDEEM_CODE>","item_name":"示例物品","used":false,"created_at":"2026-10-18 12:00:00"}]}}
```

兼容 payload 直接数组。字段：`id` number/string；兑换码 `code/redeem_code/code_text`；名称 `item_name/item/name/title`；已使用 `used` 或 `status/state` 为 `used/claimed/redeemed`；时间 `created_at/created_time/created/buy_time/time`。均按非空字段回退。兑换码是凭证，文档不能附真实值；消费/授权的最终状态以服务端为准。

### GET /user/emojis

用途：表情选择器列表。已知返回（C）：

```json
{"code":200,"data":{"emojis":[{"id":1,"name":"示例表情","url":"/uploads/demo.png"}]}}
```

列表容器兼容 `items`/直接数组；消费 `url/name`，图片 URL 插入帖子/回复正文。其他表情元数据待样本核实。

### POST /user/emojis

用途：上传自己的表情。multipart 文件字段 `emoji`，示例：

```http
Content-Disposition: form-data; name="emoji"; filename="emoji.png"
Content-Type: image/png

<图片二进制>
```

没有额外业务表单字段。返回体：Ack；上传回调不依赖 URL 字段，成功后重读表情列表。5 MB 与账号代际约束同头像。

### GET /user/game-bindings

用途：查看社区账号绑定的游戏账号。已知返回（C/S）：

```json
{"code":200,"data":{"bindings":[{"id":1,"game_name":"DemoPlayer","uuid":"<GAME_UUID>","online":true}]}}
```

容器兼容 `items`/直接数组；账号名 `game_name/name`，模型亦接受字符串条目；`id` number/string、`uuid` string、`online` bool。与决斗的 `/pvp/accounts` 有相关字段，但不是同一个端点。

### POST /user/game-bindings

用途：添加游戏绑定。JSON：

```json
{"game_name":"DemoPlayer","uuid":""}
```

`game_name` 是已去首尾空白的非空 string；客户端允许 `uuid` 为空字符串，但仍发送字段，服务端完整校验待核实。返回体：Ack，之后重新读取绑定列表。

### POST /user/game-bindings/delete

用途：删除指定绑定。JSON：

```json
{"id":1}
```

ID 来自绑定列表，通过 `.identifier` 发送 number/string。返回体：Ack。不能改用 DELETE `/user/game-bindings/{id}`，没有该契约证据。

### GET /player/info/{player}

用途：玩家公开主页；现有榜单的个人主页数据来源也读取此接口。路径 `player:string` 是可定位的用户名/游戏名，不是显示昵称。无 Query。iOS 带 Bearer；2026-10-18 既有匿名 GET 成功（R），不等于其他用户接口允许匿名。

```json
{"code":200,"data":{"username":"demo","nickname":"示例","registered":true,"online":false,"banned":false,"seconds":7200,"coins":50,"last_login":"2026-10-18 12:00","avatar":"avatar_demo.png","bio":"公开简介","title":"&b称号","level":3,"exp":120,"points":10}}
```

已知字段（C/S，部分 R）：`registered/online/banned` bool；`seconds` integer（兼容 `playtime`）；`coins` number/string（兼容 `balance`）；`last_login` 日期/时间值；`username/nickname/avatar/bio/title` string；`level/exp/points` integer。名字兼容 `name`，头像兼容 `avatar_url`。公开资料不假设有本人邮箱或 `next_level_exp`。

明确 `registered:false` 时不展示账户余额等明细；未知状态不伪造为 false。主页 coins 是当前余额，不是原始喵币榜累计获得量。按主页模式排序的范围与规则见 [排行来源说明](LEADERBOARD_SOURCES_2026-10-18.md)。
