# 决斗场

共 11 项。MAIN、Bearer；GET 无请求体，Query 未列出则无。证据 C/S；没有宣称真实游戏传送/结算已完成线上联调。[通用协议](README.md)。

## 接口目录

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/pvp/me` | 本人排位及近期对局 |
| GET | `/pvp/online` | 可挑战在线玩家 |
| GET | `/pvp/incoming` | 收到和发出的挑战 |
| GET | `/pvp/accounts` | 可用于匹配的游戏账号 |
| GET | `/pvp/match/status` | 当前匹配状态 |
| GET | `/pvp/rank` | 决斗排名 |
| POST | `/pvp/challenge` | 发起挑战 |
| POST | `/pvp/challenge/respond` | 接受/拒绝邀请 |
| POST | `/pvp/match/join` | 加入匹配 |
| POST | `/pvp/match/confirm` | 确认找到的对手 |
| POST | `/pvp/match/leave` | 离开/取消匹配 |

## 共享模型

玩家字段（当前客户端兼容集合，不等于每个接口全量返回）：

| 字段 | 类型/语义 |
| --- | --- |
| `id` | number/string，兼容模型 ID 还可取 username/player/name |
| `name` | 展示名，兼容 nickname/username/player |
| `game_name` | Minecraft 游戏账号，挑战目标优先使用，空时才回退 name |
| `username` | 社区用户名，与 game_name 和昵称区分 |
| `rating/tier/tier_index` | 排位分 integer、段位 string、段位序号 integer |
| `wins/losses/matches` | 胜、负、场次 integer |
| `rank` | integer，兼容 rank_position |
| `peak_rating` | 历史最高排位分 integer |
| `avatar` | string，兼容 avatar_url |
| `streak` | integer，正为连胜、负为连败、0 无连胜败 |
| `total_players` | integer |
| `next_tier` | 对象 `{tier:string,need:integer}` |

### GET /pvp/me

用途：我的竞技资料及最近战绩。返回示意：

```json
{"code":200,"data":{"name":"示例","game_name":"DemoPlayer","username":"demo","rating":1010,"tier":"示例段位","tier_index":1,"wins":3,"losses":2,"matches":5,"rank":4,"peak_rating":1050,"streak":-1,"total_players":20,"next_tier":{"tier":"下一段位","need":90},"recent":[{"id":1,"opponent_name":"OtherPlayer","win":true,"rating_change":10,"rating_after":1010,"reported_at":"2026-10-18 12:00:00"}]}}
```

主资料位于 payload 本身，不是另行假设的 `/pvp/profile`。战绩容器兼容 `recent/recent_matches/matches/history` 的数组；战绩 `id/match_id`、对手 `opponent.name/opponent_name/opponent`、结果 `win` 或 result/status 文本 win/won/loss/lost/胜/负、变化 `rating_change/delta`、结算后分 `rating_after/my_rating_after`、时间 `reported_at/created_at/time`。顶层 `matches` 可是场次数字，只有数组才用于战绩。

### GET /pvp/online

用途：在线挑战对象。返回：

```json
{"code":200,"data":{"players":[{"name":"示例显示名","game_name":"DemoPlayer","username":"demo","rating":1010,"tier":"示例段位","wins":3,"losses":2,"streak":1}]}}
```

列表兼容 `online`/payload 数组；玩家字段同共享模型。页面显示用户名和游戏名，但发送挑战必须取 game_name，不能仅发送显示昵称。

### GET /pvp/incoming

用途：待处理来邀和已发送邀请。返回扁平示例：

```json
{"code":200,"data":{"incoming":[{"id":1,"from_name":"OtherPlayer","from_username":"other","from_rating":1000,"from_tier":"示例段位","from_wins":2,"from_losses":1,"from_streak":1,"status":"pending","expires_at":"2026-10-18T12:01:00Z"}],"outgoing":[{"id":2,"to_name":"DemoPlayer","status":"pending","expires_in":30}]}}
```

容器兼容 incoming/invites、outgoing/sent，也可直接数组。ID 兼容 `invite_id/id`。对手可来自 `player/from/opponent` 嵌套对象，或 `from_* / to_*` 前缀字段（name/game_name/username/rating/tier/wins/losses/matches/avatar/streak）；过期兼容 `expires_in/remaining_seconds` integer、`expires_at` 时间。状态默认 pending 是客户端兜底，不声明完整后端枚举。

### GET /pvp/accounts

用途：选择用于匹配的绑定游戏账号。返回：

```json
{"code":200,"data":{"accounts":[{"id":1,"game_name":"DemoPlayer","uuid":"<GAME_UUID>","online":true}]}}
```

消费 `accounts` 或数组，结构按 GameBinding 解码，名字兼容 name。账号必须符合游戏服务端在线约束；仅本地选择不会加入匹配。

### GET /pvp/match/status

用途：恢复并观察当前匹配。返回：

```json
{"code":200,"data":{"state":"found","account":"DemoPlayer","time_pref":"day","waiting_seconds":8,"expires_in":20,"me_confirmed":false,"opponent_confirmed":true,"opponent":{"name":"OtherPlayer","rating":1000,"tier":"示例段位","wins":2,"losses":1}}}
```

`account/time_pref/state` string，等待/剩余 integer 秒，确认 bool，对手可缺失。已知状态：

| state | 含义与客户端行为 |
| --- | --- |
| idle | 未匹配，允许加入 |
| searching | 等待对手，持续观察 |
| found | 双方确认阶段，持续观察 |
| starts | 即将开始/上一轮队列已完成，按 Windows 行为允许重新加入 |
| expired | 已超时，可重新加入 |
| declined | 已取消/拒绝，可重新加入 |
| 未知 | 保留未知，不当作 idle 开放操作 |

活跃 searching/found 恢复服务端 `account/time_pref`，避免本地选择与真实匹配不一致。time_pref 支持 day/night/random，未知值的 UI 回退 day 不意味着后端也是 day。

### GET /pvp/rank

用途：决斗榜，不受普通喵币/时长榜来源切换影响。Query `limit=50`（客户端固定 URL 文本）。返回：

```json
{"code":200,"data":{"rankings":[{"rank":1,"name":"示例","username":"demo","rating":1200,"tier":"示例段位","wins":10,"losses":2}]}}
```

容器兼容 players/payload 数组；按已知 rank 排序，未提供的名次靠后。其他玩家字段同共享模型，不假设额外分页 API。

### POST /pvp/challenge

用途：对指定在线游戏账号发起挑战。JSON：

```json
{"target":"DemoPlayer"}
```

target 为 game_name string；无 Query。返回体：Ack，成功后重读排位、邀请、匹配等状态。不是向社区 username 或 UI 行号挑战。

### POST /pvp/challenge/respond

用途：接受或拒绝收到的邀请。JSON：

```json
{"id":1,"action":"accept"}
```

id 来自邀请响应（number/string），action 只使用 `accept` 或 `decline`；不是 `reject`。返回体：Ack，操作后重新加载相关状态；邀请可能已经过期或被另一端处理，以服务端结果为准。

### POST /pvp/match/join

用途：选择游戏账号和竞技场时间后入队。JSON：

```json
{"account":"DemoPlayer","time_pref":"day"}
```

account string，time_pref 枚举 `day/night/random`，默认 day；不是用户本地时区参数。返回体：Ack，随后 GET 状态；不靠本地状态直接宣告找到对手。

### POST /pvp/match/confirm

用途：确认匹配对手。JSON：

```json
{"action":"accept"}
```

当前客户端只发送 accept，不猜测额外 match_id 或 refuse 参数。返回体：Ack，随后重读状态；只有游戏服务端负责传送和结算。

### POST /pvp/match/leave

用途：离开/取消当前匹配。JSON：

```json
{}
```

返回体：Ack；不是 HTTP DELETE。请求取消或页面退出不能撤销已经由服务器执行的对局动作。

## 状态观察约束

前台可见且 state 为 searching/found/starts 时每 2 秒查匹配、每 10 秒查邀请；离页/后台停止，重回前台完整刷新。操作需要用户确认且防重复提交；状态、邀请和操作按会话/流程/端点版本隔离，迟到结果不能覆盖新请求。这些是客户端策略，不是接口强制轮询频率或后端承诺。
