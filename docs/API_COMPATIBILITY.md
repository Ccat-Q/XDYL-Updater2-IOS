# API compatibility

本清单来自拥有授权的 `ModUpdater2.exe` 内嵌 .NET 程序集，仅记录兼容重写所需的公开字符串、类型和路由，不提交反编译源码。

## 服务地址

| 用途 | 地址 | iOS 策略 |
| --- | --- | --- |
| 主 API | `https://login.lanternwaves.fun` | 已于 2026-09-05 以匿名只读请求核验；旧 `api.lanternwaves.fun:8080` 对所有应用路由返回 404 |
| 模组清单 | `http://api.lanternwaves.fun:5551/mods` | 匿名读取与后台下载 |
| 登录网页/资源 | `https://login.lanternwaves.fun` | 强制 HTTPS |
| IPA 更新 | GitHub Releases | 强制 HTTPS |

## 已映射功能

- 身份：`/login`、`/refresh`、`/register`、`/forgot-password`、`/reset-password`、`/send-verify-code`、`/check-qq-login`、`/notify-login`。登录使用字段 `account`（邮箱或用户名）和 `password`；QQ 登录先请求 `/qq-login`，读取 `data.login_url`，再打开 QQ 授权页。
- 用户：`/user/profile`、`/user/avatar`、`/user/password`、`/user/change-username`、`/user/bind-qq`、`/user/unbind-qq`、`/user/items`、`/user/emojis`。
- 社区：`/forum/categories`、`/forum/posts`、`/forum/post`、帖子详情的 `/reply`、`/like`、`/tip`，以及 `/upload/image`。
- 游戏：`/seasons`、`/server/players`、`/rank/coins`、`/rank/playtime`、`/playtime/rewards`、`/tasks`、`/polls`、`/vote`。
- 商城：`/shop/items`、`/shop/buy`、`/titles/catalog`、`/titles/mine`、`/titles/buy`、`/titles/wear`、`/redeem/rate`、`/redeem/game-coins`。
- 内容：`/announcements`、`/notifications`、`/notifications/unread`、`/notifications/read`、`/suggestions`、`/memorials`。
- 更新：`/update/latest`、`/update/pack-links`、`/mods/list`、`:5551/mods/mods.json`。

## 验证约束

旧程序经过裁剪，字段模型不能仅靠字符串完整恢复。客户端因此先用容错 JSON envelope 解码；获得低权限测试账号后，必须逐接口记录方法、请求字段、响应样例和错误码，再把已验证的关键响应收紧为具体模型。任何会修改服务器状态的验证只能使用测试数据。App 内的“网络日志”只记录时间、方法、地址与状态码，绝不记录请求正文、密码或令牌。
