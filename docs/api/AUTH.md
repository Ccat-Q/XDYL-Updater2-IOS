# 身份、令牌与 QQ

共 10 项。先阅读 [通用协议与证据等级](README.md)。本页服务统一为 WEB/MAIN（当前同源），均不附加 Bearer；这不代表无需密码、验证码或临时凭证。未单独标注的响应是客户端契约 C 的合成示例。

## 接口目录

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| POST | `/login` | 邮箱/用户名密码登录 |
| POST | `/refresh` | 刷新访问令牌 |
| POST | `/register` | 邮箱验证码注册 |
| POST | `/send-verify-code` | 发送注册验证码 |
| POST | `/forgot-password` | 发送重置密码验证码 |
| POST | `/reset-password` | 提交新密码 |
| GET | `/qq-login` | 获取 QQ 授权 URL |
| GET | `/check-qq-login` | 查询 QQ 登录/绑定状态 |
| POST | `/qq/bind` | QQ 未绑定时关联已有社区账号 |
| POST | `/notify-login` | 登录成功后的尽力通知 |

### POST /login

用途：创建社区登录会话。Query：无。JSON 请求体：

```json
{"account":"demo@example.invalid","password":"<PASSWORD>"}
```

`account` 是邮箱或用户名，**不是字段 `username`**；两项都是客户端实际发送的 string。返回体读取令牌：

```json
{"code":200,"data":{"access_token":"<ACCESS_TOKEN>","refresh_token":"<REFRESH_TOKEN>","username":"demo"}}
```

令牌兼容 `token`、根节点，见通用约定。缺访问令牌即使 HTTP 成功也不能完成登录；错误不清空用户正在使用的新会话。

### POST /refresh

用途：同一账号刷新令牌，不新建账号代际。Query：无。JSON：

```json
{"refresh_token":"<REFRESH_TOKEN>"}
```

返回体与 `/login` 相同的令牌字段/兼容方式。请求本身不再递归触发刷新；客户端合并同会话并发刷新。旧账号刷新结果不得覆盖新账号。

### POST /register

用途：新用户注册。Query：无。JSON：

```json
{"email":"demo@example.invalid","username":"DemoPlayer","password":"<PASSWORD>","code":"<EMAIL_CODE>"}
```

全部为客户端发送的 string；验证码来自 `/send-verify-code`。`username` 在 UI 提醒使用玩家名，但不能与游戏绑定列表等同。后端长度/格式/重复限制的完整规范待核实。

返回体分支：有令牌时按 `/login` 解码并自动登录；无令牌时只确认注册成功，要求正常登录。成功 Ack 示例：

```json
{"code":200,"message":"注册成功"}
```

客户端显示注册须知同意项，但**请求中没有 `accepted_terms` 字段**，未恢复的完整法律条款不编造。

### POST /send-verify-code

用途：注册验证码。Query：无。JSON：

```json
{"email":"demo@example.invalid","purpose":"register"}
```

两项 string，客户端仅使用 `purpose:"register"`；不推断其他 purpose。返回体：Ack，额外限流/有效期字段未消费、待核实。会发送邮件，不因测试文档而调用。

### POST /forgot-password

用途：发送重置密码验证码（C/S）。Query：无。JSON：

```json
{"email":"demo@example.invalid"}
```

返回体：Ack；不是 `/send-verify-code` 的任意 purpose 替代品。

### POST /reset-password

用途：凭邮件验证码重置密码（C/S）。Query：无。JSON：

```json
{"email":"demo@example.invalid","code":"<EMAIL_CODE>","new_password":"<NEW_PASSWORD>"}
```

返回体：Ack，当前调用不消费令牌。成功后引导正常登录；不根据 HTTP 200 自动认为修改成功，仍校验业务 code。

### GET /qq-login

用途：创建 QQ 授权流程，返回第三方授权地址。请求体：无。Query：

| 参数 | 类型 | iOS 用法 |
| --- | --- | --- |
| `session_id` | string | 每次新流程生成的 UUID 字符串，客户端始终发送 |
| `mode` | string | 可选；绑定已登录账号时发送 `bind`，普通登录省略 |

返回体：

```json
{"code":200,"data":{"login_url":"https://graph.qq.com/oauth2.0/authorize?response_type=code&client_id=<CLIENT_ID>&state=<STATE>"}}
```

客户端也兼容根级 `login_url`，只接受 HTTPS 且主机为 `graph.qq.com`。应打开返回 URL，而不是将 `/qq-login` 这个 JSON 页面当授权网页。授权 URL 中 redirect/state/client_id 由服务端生成，不在客户端写死；QQ callback 属于网页流程，当前没有客户端直接请求其服务端 API 的契约。开发者目录的默认查询没有填 `session_id/mode`，实际调用以此处为准。

### GET /check-qq-login

用途：轮询与 `session_id` 关联的 QQ 状态。Query：`session_id:string`，必须与 `/qq-login` 同次流程一致。请求体：无。返回体为下列之一：

```json
{"code":200,"data":{"access_token":"<ACCESS_TOKEN>","refresh_token":"<REFRESH_TOKEN>","username":"demo"}}
```

```json
{"code":302,"data":{"temp_token":"<QQ_TEMP_TOKEN>","qq_nickname":"示例昵称"}}
```

客户端优先读取非空 `temp_token`（根级或 data），其次令牌；二者皆无为等待状态，不依赖某个固定 `waiting` 字段。带有效临时凭证的 HTTP 302，或 HTTP 2xx 且业务 code 302/2xx，可进入关联分支（C/S）。专用 Session 不跟随 302，以免丢掉 JSON。

同路由用于普通登录和已登录绑定；已登录绑定成功后还需调用 `/user/bind-qq`，不能把临时凭证当访问令牌。关闭页面/重试停止旧观察，迟到结果不能改写新流程。

### POST /qq/bind

用途：未注册绑定的 QQ 身份关联一个**已有**社区账号。Query：无。JSON：

```json
{"temp_token":"<QQ_TEMP_TOKEN>","account":"demo@example.invalid","password":"<PASSWORD>"}
```

返回体：与 `/login` 一致的令牌字段；当前代码要求成功响应包含有效访问令牌，否则报解码错误。与已登录的 `/user/bind-qq` 不同，不附带 Bearer。

### POST /notify-login

用途：成功登录后向服务端尽力发送通知（C/S）；不是认证、轮询或保活。Query：无。JSON：

```json
{"player_name":"demo","token":"<ACCESS_TOKEN>"}
```

虽不附加 Authorization，**正文内 `token` 是真实凭证**，必须脱敏。客户端优先用当前个人资料用户名，回退会话用户名，不能发送空值/占位“用户”。返回体：Ack，不消费业务负载；失败不影响已建立的登录。每个新会话最多尽力一次，恢复既有会话不重复通知。服务端通知副作用仍待测试账号核实。
