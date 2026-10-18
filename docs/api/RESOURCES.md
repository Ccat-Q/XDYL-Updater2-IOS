# 资源、更新、YSM 与外部入口

目录内 8 项，加 4 项客户端额外的 Release/头像/下载/网页入口。服务和鉴权逐条注明。GET 均无请求体；未列出的 Query 为无。响应示例为合成结构，未知响应不编造，见 [总说明](README.md)。

## 接口目录

| 方法 | 路径 | 服务 / iOS 鉴权 | 用途 |
| --- | --- | --- | --- |
| GET | `/update/latest` | MAIN / Bearer | 旧更新目录路由 |
| GET | `/update/pack-links` | MAIN / Bearer | 整合包版本、网盘入口 |
| GET | `/update/pack-files` | MAIN / Bearer | 整合包直链文件 |
| GET | `/mods/list` | MAIN / Bearer | 模组分组数据 |
| GET | `/mods.json` | MODS / 无 Bearer | 真实文件清单 |
| POST | `/upload_v2` | YSM / 无 Bearer，正文含兑换码 | 上传皮肤 |
| POST | `/confirm_duplicate` | YSM / 无 Bearer，正文含兑换码 | 重复内容授权 |
| GET | `/history` | YSM / 无 Bearer | 玩家上传历史 |
| GET | `/repos/Ccat-Q/XDYL-Updater2-IOS/releases/latest` | GH / 无社区 Bearer | IPA Release 元数据 |
| GET | `/user/avatar/{filename}` | WEB / 无显式 Bearer | 头像二进制 |
| GET | `{download_url}` | 响应提供的 URL / 无显式 Bearer | 下载文件/内容图片 |
| GET | `/webadmin` | WEB / 浏览器处理网页身份 | 管理后台入口 |

### GET /update/latest

服务 MAIN，iOS 开发者目录使用 Bearer。用途：保留已知旧更新路由，当前 IPA 更新业务**不使用此路由**，改读 GitHub Release。无 Query。

返回体：目录只登记路由，没有专用业务解析器或可用的完整响应样本；应为供控制台查看的响应，但字段、envelope、版本/下载参数都**待核实**。不虚构 `{version,url}` 固定格式，也不以本路由返回内容自动安装 EXE。证据 C（目录级）。

### GET /update/pack-links

服务 MAIN、Bearer。用途：整合包版本与更新说明、网盘/网页下载入口（C/S）。返回示例：

```json
{"code":200,"data":{"pack_version":"demo-1","pack_changelog":"示例更新说明","links":[{"label":"示例网盘","url":"https://example.invalid/pack","code":"<EXTRACTION_CODE>"}]}}
```

`pack_version/pack_changelog` string、links 数组；元素 url string，label（兼容通用 title/name）与 code 为可选 string。链接可包含提取码，不将其当商品兑换码。

客户端按资源种类保存用户明确确认的版本；版本变化或首次发现展示提醒。“我已了解此版本”只记录本地阅读，不表示下载/安装完成。iOS 不照搬 Windows 安装器行为。

### GET /update/pack-files

服务 MAIN、Bearer。用途：整合包直链文件（C/S）。返回示例：

```json
{"code":200,"data":{"files":[{"name":"demo-pack.zip","url":"/downloads/demo-pack.zip","sha256":"0000000000000000000000000000000000000000000000000000000000000000","size":1024,"mtime":"2026-10-18 12:00:00"}]}}
```

容器兼容 payload 直接数组。name/url/sha256 string，size 为 Int64 字节数（兼容数字字符串），mtime 为可格式化日期或时间值。示例 SHA256 仅占位，不是文件真实哈希。缺 URL 不提供可下载按钮；URL 可相对 MAIN。资源种类由当前页面标为 pack_zip，不要求响应一定含 kind。

### GET /mods/list

服务 MAIN、Bearer。用途：已知旧模组列表/分组路由；开发者目录保留（C，历史兼容记录说明为分组数据）。当前资源页不消费它。

返回体：已知不是可直接用作下载按钮的逐文件清单，**完整分组键与字段未恢复**。不提供虚构的分组样例，也不把分组名当文件名。可下载文件应从下一项公开 manifest 读取。

### GET /mods.json

服务 MODS、无 Bearer。完整 URL：`http://api.lanternwaves.fun:5551/mods/mods.json`，不是 MAIN 的 `/mods.json`。用途：资源中心权威文件清单。返回：

```json
{"code":200,"data":{"files":[{"name":"example.jar","url":"http://api.lanternwaves.fun:5551/mods/example.jar","sha256":"0000000000000000000000000000000000000000000000000000000000000000","size":1024,"kind":"mods","mtime":1792324800}]}}
```

消费 `data.files`（兼容根级 files），每项 name/url/sha256/kind string、size 字节数 number/string、mtime 时间值。name 必须非空；下载 URL 按响应使用，不自行将名称拼成地址。HTTP 不提供传输机密性；哈希可以做文件一致性校验，不是独立的签名真实性证明。

### POST /upload_v2

服务 YSM，默认 `http://api.lanternwaves.fun:8080`；**不发送社区 Bearer**，但表单 code 是敏感兑换/授权凭证。用途：上传 YSM 皮肤（C/S）。无 Query，multipart：

```http
Content-Disposition: form-data; name="code"

<REDEEM_CODE>
Content-Disposition: form-data; name="player_name"

DemoPlayer
Content-Disposition: form-data; name="is_public"

false
Content-Disposition: form-data; name="skin_file"; filename="demo.ysm"
Content-Type: application/octet-stream

<文件二进制>
```

以上仅展示各 part 内容；真实请求必须含正确 boundary/CRLF。code/player_name 为文本、is_public 是 multipart 文本 `true/false`（不是 JSON bool part），skin_file 为 .ysm/.zip 文件。支持通过我的物品选择兑换码。

普通结果已消费：

```json
{"code":200,"message":"上传成功","data":{"model_id":"demo-model","skin_path":"demo/path"}}
```

重复内容分支：

```json
{"duplicate":true,"original_model_id":"demo-model","message":"文件已存在"}
```

duplicate/original_model_id 可位于根级或 data；普通结果 model_id/skin_path 也兼容两层。只有 **HTTP 409 或 2xx 且明确 duplicate:true** 才按客户端专门分支进入二次授权确认，不把任意失败当重复成功。原始模型 ID 保留响应的 number/string 类型。

大文件后台分块构建临时 multipart，再从文件上传，120 秒客户端超时；结束/取消清理暂存，离页可取消本地任务。准备、返回与授权检查原玩家/主机/兑换码/会话快照，不向其他主机自动重传。取消本地上传不保证服务端撤销已收到文件。开发者目录只提供表单示意，JSON 不能替代文件。

### POST /confirm_duplicate

服务 YSM，不附 Bearer；JSON 正文含敏感 code。用途：用户确认将已存在模型授权给指定玩家（C/S）。JSON：

```json
{"code":"<REDEEM_CODE>","player_name":"DemoPlayer","original_model_id":"demo-model"}
```

三项实际提交；original_model_id 从 duplicate 响应原样传递，可能 number/string。缺该 ID 不提交。返回体：按普通 YSM 结果读取 message/model_id/skin_path，完整服务端负载待联调；不能用 Ack 伪造授权模型 ID。与上传共享同一主机及原操作快照，用户必须二次确认。

### GET /history

服务 YSM，不附 Bearer。用途：输入玩家名的皮肤上传/授权历史。Query：`player:string`（注意不是 player_name）。无请求体。

```json
{"code":200,"history":[{"model_id":"demo-model","upload_time":"2026-10-18 12:00:00","is_duplicate":false,"file_md5":"<MD5_HEX>"}]}
```

列表容器兼容 payload.history/items/数组；消费 model_id/model，upload_time/uploaded_at/time，is_duplicate/duplicate，file_md5/md5。类型由当前模型按 string/bool 容错，不宣称 MD5 是下载哈希 SHA256。2026-10-13 既有匿名请求默认 :8080 服务返回 HTTP 200 空 history（R）；本次未重新请求，不保证历史永远可匿名读到全部玩家信息。修改玩家或主机后清空旧结果并拒绝迟到响应。

### GET /repos/Ccat-Q/XDYL-Updater2-IOS/releases/latest

服务 GH，完整 URL `https://api.github.com/repos/Ccat-Q/XDYL-Updater2-IOS/releases/latest`。无社区 Bearer；请求头 `Accept: application/vnd.github+json`、`User-Agent: StarWave-iOS/<版本>`。用途：正式 Release 更新提示，不是 Actions 产物列表。

客户端读取的 GitHub 响应子集：

```json
{"tag_name":"v2.2.2","name":"示例发布","body":"发布说明","html_url":"https://github.com/Ccat-Q/XDYL-Updater2-IOS/releases/tag/v2.2.2","assets":[{"name":"StarWave-resignable.ipa","browser_download_url":"https://github.com/Ccat-Q/XDYL-Updater2-IOS/releases/download/v2.2.2/StarWave-resignable.ipa"}]}
```

tag_name/html_url/assets 为当前解码所需，name/body 可选；每个资产 name/browser_download_url 为当前解码所需。示例链接不承诺该 Release 现在存在或当前最新。只在可识别的数字版本严格更高时推荐；GitHub 完整响应更多字段不在此仓库使用。本项依据本地 GitHubRelease 解码器 C，不是重新核实第三方 API 全规范。

### GET /user/avatar/{filename}

服务 WEB，图片组件没有显式社区 Bearer。用途：将头像短文件名解析为完整图片 URL。filename 来自服务端 avatar，不发送 JSON/Query。返回体是图片二进制，MIME/缓存/错误页形式由服务器决定，当前未有固定契约；不能当业务 JSON。

avatar 已是 HTTP(S) URL 时直接读取，`/` 相对路径以 WEB 解析，有目录的相对值直接追加至 WEB。头像字段不得任意替换成其他 API 请求体。

### GET {download_url}

用途：manifest/整合包文件的直链下载，以及公告、帖子、表情等内容图片读取。URL 来源包括 files[*].url、Release assets[*].browser_download_url、图片 URL；无 JSON 请求体，不自动发送社区 Bearer。不要给第三方图片、网盘或签名地址附带登录凭证。

返回体为二进制文件或图片，不是业务 envelope；HTTP 错误不当作下载成功。下载管理器对已知文件校验 SHA256（若提供），再保存到 Documents；失败保留记录、可重试。iOS 允许 HTTPS，旧 HTTP 下载仅允许 api.lanternwaves.fun 的 8080/5551；这是客户端初始下载地址规则，不宣称下载 Session 与 APIClient 具有完全相同的重定向机制。

网盘 links[*].url 由外部网页处理，提取码不是 HTTP Authorization。运行时生成的签名 URL 可能含凭证，日志/文档不能原样记录。Range/断点续传/Content-Disposition 的服务端完整支持尚未恢复，不杜撰请求头要求。

### GET /webadmin

服务 WEB，通过系统打开网页。用途：本人 role 为 admin/super_admin 时展示管理后台入口。当前客户端没有向网页显式转交 Bearer、没有恢复管理后台内部 JSON API，也不把 UI 隐藏入口当服务端鉴权。

请求体/Query 无；返回 HTML/网页跳转由站点处理，完整结构及登录流程待核实。不能因为有此链接就编造用户封禁、调账等管理写接口。

## 未纳入恢复接口的地址

QQ OAuth/callback、支付宝跳转、爱发电商品页、网盘与 EXE 下载地址可能在网页或既有程序中出现；它们并非都由 iOS 直接请求为 JSON API。本手册分别记录用途，不凭 URL 字符串推导未恢复的回调、管理端点或资源安装协议。
