# 公告、通知、意见与纪念内容

共 8 项，MAIN、iOS Bearer。GET 无请求体，未列出的 Query 均无。均为已知客户端契约 C，示例是结构示意，不代表每个字段必填。通用列表采用 RemoteItem 的容错规则；未知完整 envelope/业务负载明确保留待核实。[总说明](README.md)。

## 接口目录

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/announcements` | 公告 |
| GET | `/notifications` | 当前账号通知 |
| GET | `/notifications/unread` | 未读数 |
| POST | `/notifications/read` | 批量已读 |
| GET | `/suggestions` | 意见列表 |
| POST | `/suggestions` | 提交意见 |
| DELETE | `/suggestions/{id}` | 删除意见 |
| GET | `/memorials` | 纪念内容 |

### GET /announcements

用途：首页和公告图文内容。示例：

```json
{"code":200,"data":[{"id":1,"title":"示例公告","content":"公告正文","image":"https://login.lanternwaves.fun/uploads/demo.jpg","created_at":"2026-10-18 12:00:00"}]}
```

消费通用条目 id/title/name、description/summary、content、时间及图片；RemoteItem 也会遍历 data/result/items/list 等列表容器。历史兼容记录确认公告可能有完整 image URL，但不保证每条必有图片。Markdown/HTML 正文图片与独立 image 分开兼容，见社区模块。

### GET /notifications

用途：读取本人通知列表。Query `limit=50`，客户端固定；没有已恢复的分页/单条删除参数。示例：

```json
{"code":200,"data":{"notifications":[{"id":1,"title":"示例通知","message":"通知摘要","content":"通知正文","created_at":"2026-10-18 12:00:00"}]}}
```

通过通用列表读取 id/title/message/content 等；`read/is_read` 等状态字段没有专用消费契约，不编造为固定返回字段。读取列表后客户端另行 POST 批量已读，不假设 GET 本身清除未读数。

### GET /notifications/unread

用途：当前会话通知徽标。返回示例：

```json
{"code":200,"data":{"count":2}}
```

计数兼容 payload.unread 或 payload 纯数字/数字字符串；完整格式以样本为准。前台每 30 秒尽力刷新，后台停止。旧会话响应不得覆盖新账号；批量已读期间发起的旧查询也要失效，后续新通知可以再增加徽标。

### POST /notifications/read

用途：全部通知已读（C/S）。请求体 JSON：

```json
{"all":true}
```

all 为 bool，不能改成空对象。返回体：Ack；HTTP 与业务均成功后本地未读立即归零，并使此前及请求期间发起的计数查询失效。后续新查询仍按服务器更新。不声明存在 `/notifications/{id}/read` 等未恢复的单条接口。

### GET /suggestions

用途：意见列表。示例：

```json
{"code":200,"data":[{"id":1,"content":"示例意见","status":"new","created_at":"2026-10-18 12:00:00"}]}
```

消费 id/content，status string、created_at（兼容 created/time）时间；new/read/done 显示待查看/已查看/已处理。读取成功不意味该意见已由管理员处理，其他状态原样保留。列表是本人意见还是权限相关集合须由服务端确认，不向普通账号保证可查看他人记录。

### POST /suggestions

用途：提交意见。JSON：

```json
{"content":"示例意见内容"}
```

返回体：Ack，成功清空输入并刷新列表，失败保留内容。没有已恢复的标题、图片、工单等级参数，不在文档新增。

### DELETE /suggestions/{id}

用途：删除具有真实 id 的意见。**请求体无**，不是 `{}`；Query 无。返回体：Ack。业务调用以 APIRequest 的 delete 且 body=nil 发出；开发者控制台是独立通用执行器，若用户填 `{}` 可能与业务请求不同。服务端所有权/管理员权限和删除返回负载待核实。

### GET /memorials

用途：纪念堂图文列表与详情。已知消费形式示例：

```json
{"code":200,"data":[{"id":1,"title":"示例纪念内容","description":"摘要","content":"正文","image":"https://login.lanternwaves.fun/uploads/memorial.jpg"}]}
```

当前仅用通用条目/图片模型，没有专用后端 schema；上例是 UI 可消费的字段集合，不是已捕获的完整响应。容器、其他字段、是否有时间/作者以及数据权限须补脱敏样本后确定，不把未知字段补成默认的真实数据。
