# 游戏、排行、任务与投票

共 10 项，服务 MAIN，iOS 使用 Bearer，GET 无请求体。Query 未列出即为无。示例是已知字段的合成示意，阅读 [证据与通用协议](README.md)。

## 接口目录

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/seasons` | 周目与个人时长 |
| GET | `/server/players` | 服务器在线名单 |
| GET | `/rank/coins` | 累计获得喵币原始榜 |
| GET | `/rank/playtime` | 原始在线时长榜 |
| GET | `/playtime/rewards` | 时长奖励档位 |
| POST | `/playtime/rewards/claim` | 领取时长奖励 |
| GET | `/tasks` | 每日任务、成就等 |
| POST | `/tasks/{id}/claim` | 领取任务奖励 |
| GET | `/polls` | 投票列表与选项 |
| POST | `/polls/{id}/vote` | 投票或改投 |

### GET /seasons

用途：周目列表、起止时间、人数和本人本周目游玩时长（C/S）。返回体：

```json
{"code":200,"data":{"seasons":[{"id":1,"name":"示例周目","is_active":true,"start_time":"2026-10-01 00:00:00","end_time":null,"players_count":20,"my_playtime":7200,"description":"周目介绍"}]}}
```

容器兼容 `items`/直接数组；`id/season_id`、名称 `name/season_name/title`、内容 `description/content`。`is_active` bool，`players_count/my_playtime` integer；`my_playtime` 为秒，不能直接显示为小时。日期使用客户端通用时间解析，缺失状态保留未知。

### GET /server/players

用途：首页在线状态和玩家入口（C/S）。返回示例：

```json
{"code":200,"data":{"server_name":"示例服务器","count":1,"players":[{"name":"DemoPlayer"}]}}
```

客户端同时兼容根级 `count/server_name`、名称 `server`、玩家 `player_name/username` 或字符串名单。`count` integer、`players` 数组；保留服务端计数，不要求等于可读名单长度。成功空名单、计数存在却没有名单、网络失败分开处理；“无人在线”不能当作“服务器离线”。

### GET /rank/coins

用途：原始累计获得喵币排名，也是主页模式候选名单来源之一（C，2026-10-18 既有匿名读取 R）。返回：

```json
{"code":200,"data":[{"rank":1,"username":"demo","nickname":"示例","avatar":"avatar_demo.png","coins":1000}]}
```

`rank/coins` integer，头像与名字为 string。按服务端 rank 升序，支持并列名次。`coins` 为该榜统计值，**不等于本人或公开主页当前余额**。当前代码不发送 `limit/page/source`，不假设存在完整用户枚举能力。

### GET /rank/playtime

用途：原始在线时长榜及主页模式的另一份候选名单（C，2026-10-18 既有匿名读取 R）。返回：

```json
{"code":200,"data":[{"rank":1,"player_name":"DemoPlayer","avatar":"avatar_demo.png","seconds":7200}]}
```

`seconds` integer，单位秒；`player_name` 为 lookup 标识。服务端曾返回同名多行，原始模式保持服务器名次，不把同名当不存在的另一用户名。当前不请求 `limit/page/source`。

### GET /playtime/rewards

用途：时长累计与可领取奖励（C/S）。返回：

```json
{"code":200,"data":{"total_seconds":7200,"milestones":[{"hours":2,"coins":10,"exp":20,"claimed":false,"claimable":true}]}}
```

容器兼容 `rewards`/payload 数组。`total_seconds` 是秒，档位 `hours` 为可大于 0 的 number/数字字符串，`coins/exp` integer，`claimed/claimable` bool。资格由服务端为准；已领不可再领，未明确可领不开放按钮。

### POST /playtime/rewards/claim

用途：领取指定**小时档位**，不是通用奖励行 ID。JSON（C/S）：

```json
{"hours":2}
```

`hours` number，来自 milestone，允许正数。兼容帮助逻辑还可从 `hour/required_hours/requiredHours/tier` 读取小时，或将 `required_seconds/seconds` 除 3600；这是客户端兼容，不是要求后端同时返回这些别名。返回体：Ack，成功刷新本人资料和奖励列表。不要发送 `{id:...}`，会导致档位不存在。

### GET /tasks

用途：每日任务、成就、游玩时长及其他任务（C/S）。返回结构示例：

```json
{"code":200,"data":{"daily":[{"id":1,"title":"示例每日任务","description":"完成一次操作","progress":"1/1","completed":true,"claimed":false,"reward_coins":5,"reward_exp":10}],"achievements":[{"id":2,"title":"示例成就","current":2,"target":3,"status":"in_progress","reward_points":3}],"playtime":[]}}
```

容器别名：`daily/daily_tasks/dailies`；`achievements/achievement_tasks/achievement`；`playtime/playtime_tasks/other/other_tasks`。扁平列表按 `type/task_type` 的 daily/achievement 文本分组；其余保留，不丢弃。

奖励读取 `reward/reward_name/reward_text`，或 `reward_coins/coins`、`points/reward_points`、`exp/reward_exp`；并非这些字段都必定出现。状态归一化顺序是已领取 > 已完成 > 进行中：

| 语义 | 客户端兼容字段/表达 |
| --- | --- |
| 已领取 | `claimed/is_claimed/received/is_received/collected/is_collected` 为真；状态文本 `claimed/received/collected/已领取/领取成功` |
| 完成 | `completed/is_completed/complete/is_complete/done/is_done/finished/is_finished/achieved/is_achieved/can_claim/canClaim` 为真；状态文本 `complete/completed/done/finished/achieved/已完成/完成` |
| 状态字段 | `status/task_status/completion_status/state/claim_status` |
| 进度字符串 | `progress/task_progress/completion_progress` 的 `100%` 或 `1/1` |
| 数值进度 | 当前 `current_progress/current/completed_count/count/value/progress`；目标 `target/target_count/required/required_count/goal/total/max_progress`，目标 > 0 且当前达到目标 |

这些是适配集合，不是服务端 schema 保证；最终领取资格仍由服务端判断。不能仅根据用户主观完成就伪造领取成功。

### POST /tasks/{id}/claim

用途：领取真实 task ID 对应奖励。JSON：

```json
{}
```

返回体：Ack；成功后刷新本人资料与 `/tasks`。缺真实任务 ID 不得把“项目 1”行号拼为接口 ID。

### GET /polls

用途：投票、选项、票数和本人选票（C/S）。返回：

```json
{"code":200,"data":{"polls":[{"id":1,"title":"示例投票","description":"选择一项","end_time":"2026-10-20 12:00:00","is_active":true,"total_votes":2,"my_vote":10,"options":[{"id":10,"name":"选项 A","votes":2},{"id":11,"name":"选项 B","votes":0}]}]}}
```

列表兼容 `items`/数组；`id/my_vote/options[*].id` number/string；票数 integer；`is_active` bool，缺失时兼容 `status` 不在 ended/closed/finished；这是 UI 容错而非服务器保证。缺选项不能自动发送默认 option_id。

### POST /polls/{id}/vote

用途：提交选票或改投。JSON：

```json
{"option_id":10}
```

`id` 是 poll ID，`option_id` 是该 poll 的真实选项 ID（number/string）。返回体：Ack；成功后重新 GET `/polls`，显示选中项与票数。后端是否允许改投以结果为准，客户端按 Windows 兼容流程提供入口。

## 个人主页排行不是新服务端接口

用户切换“原始榜单 / 个人主页”时，主页模式合并两榜当前名单，按真实 username/player_name 请求 [GET /player/info/{player}](ACCOUNT.md#get-playerinfoplayer)，去重后以主页余额或秒数本地降序排序。未新增 `/rank/profile` 或 `source=profile` 等未证实路由/参数。榜单明确当前名单、非全服；失败/缺失不补 0，不混用累计喵币，真实零值可排名，并列采用 1/1/3。详见 [流程与验证](LEADERBOARD_SOURCES_2026-10-18.md)。
