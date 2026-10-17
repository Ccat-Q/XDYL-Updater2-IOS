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
- 用户：`/user/profile`、`/user/avatar`、`/user/password`、`/user/change-username`、`/user/bind-qq`、`/user/unbind-qq`、`/user/items`、`/user/emojis`、`/user/game-bindings`、`/user/game-bindings/delete`、`/player/info/{player}`。
- 社区：`/forum/categories`、`/forum/posts`、`/forum/post`、帖子详情的 `/reply`、`/like`、`/tip`，以及 `/upload/image`。
- 游戏：`/seasons`、`/server/players`、`/rank/coins`、`/rank/playtime`、`/playtime/rewards`、`/tasks`、`/polls`、`/polls/{id}/vote`。
- 商城：`/shop/items`、`/shop/buy`、`/titles/catalog`、`/titles/mine`、`/titles/buy`、`/titles/wear`、`/redeem/rate`、`/redeem/game-coins`。
- 内容：`/announcements`、`/notifications`、`/notifications/unread`、`/notifications/read`、`/suggestions`、`/memorials`。
- 更新：`/update/latest`、`/update/pack-links`、`/update/pack-files`、`/mods/list`、`:5551/mods/mods.json`。
- 市场：`/market/preview`、`/market/history/{identifier}`。
- 支付：`/pay/create`、`/pay/status?order_no=`、`/afdian/status`、`/afdian/claim`。
- YSM：独立服务的 `/upload_v2`、`/confirm_duplicate`、`/history?player=`；默认地址来自 EXE 设置，可在 YSM 页选择官方服务主机。

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
- 决斗场使用认证的 `/pvp/me`、`/pvp/online`、`/pvp/incoming`、`/pvp/accounts`、`/pvp/match/status` 与 `/pvp/rank?limit=50`。写入端点分别为：`POST /pvp/challenge` `{target}`、`POST /pvp/challenge/respond` `{id, action}`、`POST /pvp/match/join` `{account, time_pref}`、`POST /pvp/match/confirm` `{action:"accept"}` 和空对象 `POST /pvp/match/leave`。匹配状态以 `idle/searching/found/starts/expired/declined` 为准，客户端不会伪造游戏内结算。
- 决斗场在页面前台可见且匹配处于 `searching`、`found` 或 `starts` 时每 2 秒读取状态，每 10 秒读取邀请；进入后台或离开页面立即停止，重新进入或返回前台会完整刷新。`starts` 按 Windows 行为允许再次匹配；无法识别的状态保留为未知，不当成 idle 开放入队。

## 2026-10-13 EXE 静态契约修正

这些契约来自 SHA-256 `59a7b5dc6e79b578ef40c1130b0a30c982ee901aecfeaa430fe915295fc6291e` 的 EXE 内嵌程序集；静态恢复不等于线上交易或对局已经联调成功。

- HTTP 与业务 envelope 的 `code` 均须成功，失败不得触发余额刷新、关闭表单或清除未读数。认证失效尝试一次共享令牌刷新；确定失效后清除会话，网络暂时失败保留会话。
- 图片上传使用 multipart `image`，头像为 `avatar`，表情为 `emoji`；按实际内容设置 MIME 和文件扩展名，5 MB 上限，不支持的照片格式转换为 JPEG。
- 通知批量已读为 `{all:true}`；列表 limit=50。前台每 30 秒刷新未读数，后台停止。
- 密码重置发码使用 `/forgot-password` `{email}`，提交 `{email,code,new_password}`。资料更新为 `{nickname,bio}`，QQ 状态读取 `qq_bound`。
- QQ 未绑定响应可为带 `temp_token` 的 HTTP 302，仅该专用流程接受；已登录账号绑定发送 `/user/bind-qq` `{temp_token}`，关联已有账号使用 `/qq/bind` `{temp_token,account,password}`。
- 投票发送 `/polls/{id}/vote` `{option_id}`，展示选项、票数、本人选票和结束状态；称号购买及免费佩戴发送 `{title}`。
- 游戏绑定添加 `{game_name,uuid}`，删除 `{id}`；游戏奖励按 milestones 的 `claimable/claimed` 控制按钮，领取 `{hours}`，所有影响余额的成功操作刷新个人资料。
- 决斗账号字段是 `game_name/online`，邀请使用扁平的 `from_name/from_rating/from_tier/from_wins/from_losses` 和 `to_name`，有效期为 `expires_at`；战绩使用布尔 `win` 和 `reported_at`。竞技场时间为 day/night/random，默认 day。
- YSM 表单为 `code/player_name/is_public/skin_file`。只有明确 duplicate 响应才进入二次授权确认，`/confirm_duplicate` 为 `{code,player_name,original_model_id}`。2026-10-13 匿名读取 Windows 默认 `:8080/history?player=__codex_contract_probe__` 返回 HTTP 200 和空 history；上传/授权未执行线上验证。客户端不对不同主机自动重发上传。
- 支付宝创建 `{item_id}`，前台轮询订单状态；爱发电状态及领取为 `{out_trade_no}`，喵币兑换为 `{coins}`。支付由用户在支付宝完成，客户端以服务器支付与兑换码状态为准。
- 社区分页、定向回复 `reply_to`、表情插入、正文 HTML/Markdown 图片均有业务页面；图片保持原文顺序。市场只读页面每分钟前台刷新并展示历史价格；2026-10-13 匿名 preview 返回 118 个物品，history/nether_star1 返回 time（Unix 秒）与 value 采样点，客户端显示格式化时间、现价、买卖价、百分比涨跌和成交数。
- 下载验证 HTTP 状态及哈希，取消与重试关联原记录，重启核对后台任务，文件校验和复制在独立队列执行。

## 2.2.1 后续流程修正

- 新登录、注册自动登录与 QQ 关联建立新的会话代际；同账号令牌刷新保留代际。响应成功、失败清理与刷新重试均检查代际，旧会话不得保存令牌、清掉新会话或覆盖资料/徽标。刷新按当前代际合并；登录流程取消或被替代后忽略迟到响应。
- QQ 临时绑定凭证统一从根节点或 `data.temp_token` 读取，忽略空字符串。绑定页关闭取消轮询，每次重试建立新的 session_id；取消本地请求不能撤销服务器已经完成的绑定。
- 注册请求仍为 `{email,password,code,username}`。界面保留 EXE 的玩家名/邮箱验证码提示和注册须知同意项；内嵌 `views/loginwindow.baml` 未恢复到完整条款正文，不凭空编造法律条款。响应返回有效令牌则自动登录，否则明确提示注册成功并要求正常登录。
- 成功登录后一次性尽力发送 `/notify-login` `{player_name,token}`，按 Windows 契约不使用此接口作认证或持续心跳；凭证由当前会话取得，失败不影响登录。真实服务端效果仍需测试账号验证；恢复已有会话不重复通知。
- `/pvp/online` 的展示名为 `name`，挑战目标为 `game_name`，仅游戏名为空时回退展示名。恢复活跃匹配选择器使用服务器 `account/time_pref`。每端点请求版本和流程代际共同屏蔽旧轮询/刷新，退出页面与进入后台停止应用响应。
- 支付状态查询按订单号和流程代际隔离，页面前台每 5 秒查询，手动与自动查询互斥；重建、离页、后台取消旧请求。已支付/关闭/过期/失败、401/404 或本地创建后 15 分钟截止停止，临时网络错误可继续重试；后台停留时间也计入本地截止。二维码和兑换码空字符串不阻止后续非空字段回退。爱发电改号后忽略旧响应，已领取但没有兑换码时显示服务器消息或“已发给其他用户”。
- YSM 大文件通过 1 MB 分块构建临时 multipart，再使用文件上传，结束或取消清理暂存文件。页面提供取消按钮，离页取消本地请求；发布/重复授权保存提交玩家、兑换码、主机和会话快照。历史查询对玩家、主机和请求版本校验，不能把旧玩家结果显示给新玩家。
- 下载删除文件失败时保留记录和路径，并显示错误；不把未删除的文件伪装为删除成功。
- IPA 首页只提示数值版本严格高于已安装版本的正式标签，旧版、同版和无法识别的标签不提供更新推荐。构建产物不是 GitHub Release，是否发布独立于编译成功。

## 2.2.2 审查修复与迁移补齐（2026-10-17）

- 公开资料 `/player/info/{player}` 使用独立 `PublicPlayerProfile`，保留 `registered/online/banned/seconds/last_login/coins`。公开游玩时间优先 `seconds`，只在该模型中兼容 `playtime`；账户 `/user/profile` 继续使用原有字段。未注册玩家不展示账户明细，缺失状态显示未知，不伪造封禁/在线/余额。
- 称号显示、校验、计费长度共用 `TitleMarkup`。接受 `&#RRGGBB`、`&0`–`&f`、`&k`–`&o` 与 `&r`（大小写兼容）；`&l` 加粗，`&r` 重置颜色和粗体，短色码清除粗体，十六进制颜色保留粗体；`k/m/n/o` 按 Windows 行为隐藏而不实现特效。无效标记仍拒绝提交，保留总长 64 和 UTF-16 可见长度约束。
- `/titles/buy` 读取 `granted_in_game`、`new_coins`；`/titles/wear` 读取 `granted`。账户成功不等于游戏内送达：购买未送达提示联系管理员补发、不要重复购买；佩戴未送达提示稍后自动补发。字段缺失明确提示送达状态未知。
- `/titles/mine` 展示 `count/first_at/created_at/wearing`；`/shop/buy` 成功立即展示并允许复制返回的 `code/redeem_code/code_text`。根节点业务状态 `code:200`（包括字符串形式）不作为兑换码。兑换码列表兼容商品名 `item`、时间 `created/buy_time` 和空字符串回退。
- `/update/pack-links` 的 `pack_version/pack_changelog` 用于独立于 IPA 的资源版本提醒。按资源类型在本机保存明确确认的版本；首次发现或版本变化提示，不以浏览、下载或确认提醒伪装安装成功。`/update/pack-files` 和模组清单保留并格式化 `mtime`。
- `/server/players` 保留 `count/server_name`（兼容 `server`）和 `players[*].name`；成功无人在线、计数存在但无名单、请求失败分别展示，不能把无人在线当服务器离线。
- `/seasons` 专用模型展示 `is_active/start_time/end_time/players_count/my_playtime`，个人时长按秒格式化；决斗在线玩家、来邀、匹配对手展示已有段位/分数/胜负资料，在线列表另显示游戏名和论坛用户名。
- 市场本地排序支持涨跌幅度、涨幅、跌幅、价格降序和成交活跃度；按数值排序，缺失值靠后，相同值保留服务端顺序。意见状态 `new/read/done` 本地化并显示提交时间；YSM 历史展示 `file_md5/md5`。
- 相册读取、上传和页面生命周期统一管理。头像、发帖图片、回复图片及表情在读取前捕获账号代际；读取后、网络发送前及返回后核验；离页取消，切换账号使旧操作失效。YSM 构建 multipart 后同样核验会话，避免准备文件期间切换账号后发送旧表单。
- 默认业务 URLSession 在每次重定向时重新校验官方协议/主机/端口，并要求与最初请求和当前响应同源；拒绝跨域、跨端口、降级或带用户信息的目标。307/308 也不能绕过此策略转发上传体。QQ 保持专用拒绝重定向流程，开发者自定义请求执行器保持独立。HTTPS 官方服务仅允许 443，旧 HTTP 仅允许既有 8080/5551。
- 资料刷新仅应用当前账号最新请求；未读查询也有独立版本。全部已读成功会使此前和请求期间启动的未读查询失效，再归零；后续新查询仍可显示新通知。
- 统一脱敏覆盖业务兑换码别名 `code_text`（JSON、查询及自由文本）。明确清除会话/恢复初始状态时，删除原件、`sessions.json.recovery-*` 及原文/脱敏导出（兼容旧临时路径），失败必须提示。普通损坏恢复仍先保留原件；清理仅针对已知诊断文件，不删除无关文件。

本轮新增协议/排序/格式码/版本记忆/异步竞态与清理回归测试。Linux 本地无法运行 Xcode/XCTest；重定向测试调用策略和 delegate 验证，不声称已经用双服务或真机复现传输。游戏内送达与真实支付/授权仍需测试账号联调。

## 验证约束

旧程序经过裁剪，字段模型不能仅靠字符串完整恢复。客户端因此先用容错 JSON envelope 解码；获得低权限测试账号后，必须逐接口记录方法、请求字段、响应样例和错误码，再把已验证的关键响应收紧为具体模型。任何会修改服务器状态的验证只能使用测试数据。App 内的“网络日志”只记录时间、方法、地址与状态码，绝不记录请求正文、密码或令牌。

## 开发者调试

- 连续点按设置中的版本号 7 次可在本机启用开发者功能；该入口包含接口目录、任意路径请求控制台、环境收藏、完整会话、性能追踪与本地数据清理。
- 接口目录维护客户端当前已知的认证、用户、社区、游戏、商城、内容、更新和资源路由；GET 可直接一键请求，写路由仍必须确认，且可转入控制台补充 JSON、文件和 `{id}` 等动态字段。
- 业务 `APIClient` 继续严格限制官方服务；独立的开发者执行器才允许自定义 HTTP/HTTPS 地址。自定义地址的令牌开关默认关闭且不保存，打开时会明确显示目标域名。
- POST/PUT/DELETE 必须逐次确认，DELETE 还要求输入 `DELETE`。完整响应最多保留最近 20 条，使用 iOS 完整文件保护保存；导出默认脱敏令牌、密码和 Cookie，原文导出必须再次确认。
- 调试记录日期写入 ISO8601，读取兼容 ISO8601 与旧数值日期；单条损坏时恢复可读条目并先保存原文件，读取/备份失败不得覆盖原文件。脱敏覆盖 URL 查询与用户信息、凭证头、嵌套 JSON 和错误文本；普通网络日志也不保存 URL 内凭证。
- 性能采样只有一个计时器所有者：前台且（性能页可见或持续采样开启）才每 2 秒采样。默认离页停止；关闭持续开关但仍在性能页时继续默认采样；后台停止，返回前台恢复。不申请后台保活或承诺 iOS 持续执行定时器，“本次打开”计数独立重置。
