# 社区、图文与互动

共 8 项。服务 MAIN，全部为 iOS Bearer 调用，GET 无请求体。JSON 为合成结构示例，证据默认为 C；兼容与错误规则见 [README.md](README.md)。

## 接口目录

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/forum/categories` | 分类列表 |
| GET | `/forum/posts` | 分类/分页帖子列表 |
| GET | `/forum/post/{id}` | 正文与回复 |
| POST | `/forum/post` | 发布帖子 |
| POST | `/forum/post/{id}/reply` | 回复帖子或指定楼层 |
| POST | `/forum/post/{id}/like` | 切换点赞状态 |
| POST | `/forum/post/{id}/tip` | 输入金额打赏 |
| POST | `/upload/image` | 上传正文图片 |

### GET /forum/categories

用途：显示分类选择器与发帖分类。Query：无。返回示例：

```json
{"code":200,"data":[{"id":1,"name":"交流","description":"分类说明"}]}
```

`id` number/string、`name` 或通用条目 `title`、`description` string；由 `RemoteItem.list` 容错读取，特定服务端容器完整规范待样本核实。分类读取失败单独显示重试，分类可用前禁止提交发帖，不把失败分类套在旧帖子上。

### GET /forum/posts

用途：帖子列表和分页。Query：

| 参数 | 类型 | 当前请求 |
| --- | --- | --- |
| `page` | integer 的 URL 文本 | 从 1 开始，每次发送 |
| `category_id` | number/string ID 的 URL 文本 | 筛选时发送，不筛选省略 |

返回体（C；历史 R 见兼容记录）：

```json
{"code":200,"data":{"posts":[{"id":1,"title":"示例帖子","content":"正文 ![图片](/uploads/demo.png)","nickname":"示例作者","username":"demo","avatar":"avatar_demo.png","reply_count":2,"likes":3,"created_at":"2026-10-18 12:00:00"}],"total_pages":3,"has_next":true}}
```

消费列表 `data.posts`，兼容 `items`/payload 数组；分页优先 `total_pages/pages`，再 `has_next`，无分页元数据时以是否有内容判断可继续。`page_size/total_count` 未被调用方消费，不能作为已知契约。正文 `content`、作者 `nickname/author/username`；文章可另带图片/附件字段，见图片约定。

只在成功后同时更新分类、页码和帖子；失败保留上一份一致结果，旧分页请求不得覆盖新选择。

### GET /forum/post/{id}

用途：单帖详情。路径 `id` 为帖子 ID，无 Query。返回体（C，历史 R）：

```json
{"code":200,"data":{"post":{"id":1,"title":"示例帖子","content":"图文正文","nickname":"示例作者","likes":3},"replies":[{"id":10,"nickname":"示例回复者","username":"reply_demo","avatar":"reply.png","user_title":"&b称号","content":"回复内容","reply_to_name":"示例作者","created_at":"2026-10-18 12:10:00"}]}}
```

必须区分 `post` 对象和 `replies` 数组，不能把外层 envelope 渲染成普通条目。回复已消费 `content/nickname/avatar/user_title/reply_to_name/id`；其他字段由通用详情展示，不代表完整结构已经恢复。

### POST /forum/post

用途：在选定分类发帖。无 Query。JSON：

```json
{"category_id":1,"title":"示例标题","content":"文字\n![图片](https://login.lanternwaves.fun/uploads/demo.png)\n"}
```

`category_id` 用列表真实 ID（number/string），标题与正文为 string。图片先上传，再将 URL 写入 `content`；没有已恢复的 `images` 发布字段。返回体：Ack，发帖成功刷新列表；返回的新帖 ID/对象目前未消费，待样本补全。提交期间锁定表单，失败保留草稿。

### POST /forum/post/{id}/reply

用途：回复帖子，可针对特定楼层（C/S）。无 Query。JSON：

```json
{"content":"回复文字\n![图片](/uploads/demo.png)","reply_to":10}
```

`id` 是帖子 ID；`reply_to` 是回复楼层 ID（number/string），普通回复明确发送 `null`，不是省略正文中的字段。返回体：Ack，成功后重新读取详情。开发者目录默认示例只有 `content`，实际业务还发送 `reply_to`。发送中禁止改变正文/附件/目标，失败保留草稿。

### POST /forum/post/{id}/like

用途：点赞/取消点赞切换，而不是每次都新增点赞。请求体：

```json
{}
```

已知返回字段（C；匿名 401 历史核实 R）：

```json
{"code":200,"data":{"liked":false,"likes":2}}
```

`liked` bool，兼容 `is_liked`；`likes` integer。调用方在成功后重新 GET 帖子详情，优先明确状态，必要时比较计数，不把取消点赞提示为点赞成功。字段并非均保证存在；Ack 仍可能成功但需重读确认。无需发送 `liked:true/false`，未恢复此请求约定。

### POST /forum/post/{id}/tip

用途：向帖子作者打赏。JSON：

```json
{"amount":10}
```

`amount` 是用户输入的正整数喵币数，number；不是字符串、不是 `coins`。返回体：Ack；成功后刷新本人余额。服务端余额、上限、收款与防重规则待核实，不自动重发。

### POST /upload/image

用途：发布/回复正文中的图片上传（C/S）。multipart 文件字段为 `image`：

```http
Content-Disposition: form-data; name="image"; filename="post-image.jpg"
Content-Type: image/jpeg

<图片二进制>
```

返回体已知读取方式：

```json
{"code":200,"data":{"url":"https://login.lanternwaves.fun/uploads/demo.jpg"}}
```

兼容 `image_url/path` 以及根级字段；相对路径以 MAIN 解析。上传成功但没有可解析 URL 不可当作已插入图片。限制见通用图片说明。本文与表情使用 Markdown URL 插入，不单独发送附件 ID。

## 内容图片的兼容读取

内容可按顺序嵌入 Markdown `![说明](URL)`、HTML `<img src="...">`。通用条目还尝试标量 `image/image_url/cover/cover_url/icon` 与集合 `images/image_urls/photos/attachments/files`；集合内对象兼容 `url/image/image_url/path/src/file_url`。这是**客户端容错集合**，不代表每个帖子 API 都返回所有字段。实际图片 GET 见 [资源入口](RESOURCES.md)。
