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

## 已核验的响应结构

- `GET /forum/posts?page=1`：返回对象中的 `posts` 数组；帖子的正文为 `content`，作者显示名为 `nickname`。
- `GET /forum/post/{id}`：返回 `data.post` 与 `data.replies`；回复正文为 `replies[*].content`，不能将外层对象直接作为普通列表项。
- 资料与排行榜中的 `avatar` 可以是文件名；客户端将其解析为 `https://login.lanternwaves.fun/user/avatar/{filename}`。
- 公告/纪念内容的 `image` 为完整图片地址；帖子与回复的 `content` 可以包含 Markdown 图片 `![说明](URL)`。客户端应同时渲染两者。
- 排行榜使用 `rank`、`coins` 或 `seconds`；客户端用专用榜单模型显示 `nickname`（喵币榜）或 `player_name`（在线榜），按服务端 `rank` 排序，并分别显示喵币数和格式化时长。账户余额与服务端排行榜统计值由后端分别维护，客户端不以其中一方覆盖另一方。
- 称号目录包含 `presets`、`custom`、`price_per_char`、`max_len`；自定义称号通过 `POST /titles/buy` 和字段 `title` 提交，必须在客户端二次确认后发出。Windows 版使用 `&#RRGGBB` 作为颜色标记；iOS 显示单价、可见长度、预估扣费和实时预览，但服务端仍是最终的校验与扣费来源。
- 论坛发帖/回复支持通过 `POST /upload/image` 上传图片。iOS 将返回的 `url`、`image_url` 或相对 `path` 插入正文为 Markdown 图片，随后随 `content` 一并提交。
- 点赞使用 `POST /forum/post/{id}/like`；无令牌时服务返回 401（已核验），说明该路由有效。客户端在成功后重新加载帖子并展示 `likes` 计数。
- 资源下载使用公开的 `:5551/mods/mods.json` 中的 `data.files`；不使用只含分组信息的 `/mods/list` 作为下载目标。每个文件的 `name`、`url`、`sha256`、`size` 和 `kind` 直接对应下载记录与资源展示。下载完成时使用 Documents 内的分块暂存与原子移动，避免后台传输临时文件触发 Cocoa “Cannot create file”。
- 打赏使用 `POST /forum/post/{id}/tip`；客户端要求输入正整数 `amount`，在服务端成功确认后刷新账户余额。
- `POST /notifications/read` 为批量已读端点；服务端成功响应后客户端立即清除本地未读徽标，再由后续刷新取得服务器的新计数。

## 验证约束

旧程序经过裁剪，字段模型不能仅靠字符串完整恢复。客户端因此先用容错 JSON envelope 解码；获得低权限测试账号后，必须逐接口记录方法、请求字段、响应样例和错误码，再把已验证的关键响应收紧为具体模型。任何会修改服务器状态的验证只能使用测试数据。App 内的“网络日志”只记录时间、方法、地址与状态码，绝不记录请求正文、密码或令牌。

## 开发者调试

- 连续点按设置中的版本号 7 次可在本机启用开发者功能；该入口包含接口目录、任意路径请求控制台、环境收藏、完整会话、性能追踪与本地数据清理。
- 业务 `APIClient` 继续严格限制官方服务；独立的开发者执行器才允许自定义 HTTP/HTTPS 地址。自定义地址的令牌开关默认关闭且不保存，打开时会明确显示目标域名。
- POST/PUT/DELETE 必须逐次确认，DELETE 还要求输入 `DELETE`。完整响应最多保留最近 20 条，使用 iOS 完整文件保护保存；导出默认脱敏令牌、密码和 Cookie，原文导出必须再次确认。
