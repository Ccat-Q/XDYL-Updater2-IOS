# NU Chat Worker

2026-10-19 部署状态：[核心已部署到nu-pe-chat.cc.cd，R2待开通](../../docs/CHAT_DEPLOYMENT_2026-10-19.md)。工程位于 `/root/nu-chat/backend/nu-chat-worker`，旧Node服务文件保持不变；生产使用 `wrangler.production.jsonc`，下方 `wrangler.jsonc` 仍是通用模板。未做真实账号/跨端/Bark真机联调。

源于用户提供的 `nu-chat-worker.7z`，修正其 D1 代码与 KV 配置不一致的问题。保留经过加固的安卓 `/chat/*`，新增独立 `/chat/v2/*`。没有真实账号或 Bark 凭据进入测试，没有修改外部安卓仓库；本项目后续已加入[iOS 2.3.0客户端](../../docs/IOS_CHAT.md)。

契约：[V2 基础](../../docs/api/CHAT_V2_PROPOSAL.md)、[完整扩展接口](../../docs/api/CHAT_V2_EXTENSIONS.md)、[安卓互通](../../docs/api/ANDROID_INTEROP.md)。

## 本地验证

需要 Node 24+。依赖固定在 `package-lock.json`；测试生成合成账号和密钥。

```sh
npm ci
npm test
WRANGLER_LOG_PATH=/tmp/nu-chat-wrangler.log WRANGLER_SEND_METRICS=false npm run check
```

`npm test` 包含真实 SQLite 单测以及 Miniflare/workerd 的真实 D1/R2 集成测试；后者需要允许监听回环端口。主站身份查询和 Bark 出口均为测试桩，不发送真实网络请求。`check` 仅构建 dry-run，不部署。测试说明与生产缺口见[整改记录](../../docs/CHAT_SERVER_REMEDIATION.md)。

## 通用部署步骤

1. 单独创建 D1 和**私有** R2 bucket，替换 `wrangler.jsonc` 的 D1 ID；R2 不开公共域名，不把历史对象暴露为静态资源。评估请求量、存储和费用后再配置部署账号与域名。
2. 审阅已有 D1 schema，记录服务端恢复点；仅在明确获准时导出完整数据。先在隔离库依次运行 `0001` 至 `0004` migrations，确认旧消息自增 seq 保留，再手动迁移。此生产实例已迁移，勿重复直接执行ALTER SQL；使用Wrangler migration tracker。不要把模板ID当作可部署配置。
3. 用密码学随机源各生成独立 32 字节、标准 Base64 的 `CURSOR_SECRET`、`BARK_ENCRYPTION_KEY`，手动通过 `wrangler secret put` 设置，不写入 Git、文档或日志。游标签名密钥更换会使旧游标失效；Bark 加密密钥更换需要重新绑定，不直接覆盖后假装旧绑定有效。
4. Bark 默认硬关闭 `BARK_ENABLED=false`；只有显式设为字符串 `true` 且加密密钥有效才开放。只支持官方 `https://api.day.app/push`，不支持自建地址。每个聊天设备一个可替换、可停用/删除的 Bark key。
5. 可选 `HISTORY_MAX_PACK_BYTES`（默认 100 MiB，上限 1 GiB）、`HISTORY_ACCOUNT_BYTES`（默认 500 MiB，必须 ≥ 单包限制）、`HISTORY_MAX_UPLOADS`（默认 2，可配置 1–10）。分块固定 **1 MiB 密文**；最后一块可短。备份 30 天、迁移包 24 小时、批准窗口 10 分钟，均不因访问续期。
6. 主站 `/user/profile` 必须返回稳定 `id/user_id` 与规范 `username`。失效身份返回 401，故障返回 503，无稳定 ID 拒绝；禁止用昵称映射历史用户。新部署不能仅导入用户名后猜测账号归属；旧安卓需认证一次完成稳定绑定。
7. Cron 每分钟负责 outbox、过期事件及 R2 清理；部署后确认触发器、告警与配额。R2 删除成功前保留额度预留，孤儿扫描每轮最多 1000 对象并保存游标。D1 元数据 tombstone 不等于仍保存消息正文；最小幂等/删除过滤元数据会保留，须另制定账号注销/法定删除流程。
8. 部署前由维护方确认环境与验收门槛；通用 `npm run deploy` 使用模板，不用于此生产实例。当前实例用 `wrangler deploy --config wrangler.production.jsonc`，生产秘密已上传。没有自动生产部署，也未添加 GitHub Actions 的后端发布步骤。

## 安全与运行边界

- D1 每请求 `first-primary` session；原子 `batch` 同时提交消息、投递事件、所有权、密钥快照和 outbox。CHECK guard 失败整体回滚，不以 KV get/put 代替事务。
- V2 会话 1 小时，服务端仅存 token 哈希；主站 token 仅认证时校验、不存库。旧安卓每次仍携主站 Bearer，这是旧协议的信任成本。HTTPS only，重定向不转发凭据。
- 前端持有私钥、随机 32 字节恢复密钥和迁移二维码秘密；服务器只保存公钥、密文、加密 Bark key 与最少关联元数据。恢复密钥不是主站密码，也不是 API 请求字段。
- 原生新消息为每个活跃设备提供独立 envelope；旧协议消息只投递兼容主设备。新增设备必须明确显示历史缺口，用可信设备或手动备份补齐，不能显示“云历史完整”。
- iOS 2.3.0已实现双协议解密、协议选择与显式兼容主设备登记，需安装新IPA并完成真实账号跨端验收；仅更新后端不改变旧IPA。旧安卓自身 HTTP 回退、单密钥和本地缓存缺陷不能靠后端彻底修复。
- Bark 仅通用提醒，不承载正文/账号/密文；被 Bark 接受不证明手机已显示，更不证明已读。超时重试可能重复通知，解绑无法撤回在途请求。
- 观察性默认关闭；不要在平台访问日志、错误追踪或代理中记录 Authorization、请求体、完整响应、私钥或 Bark key。默认错误只含随机 request ID 与稳定错误码。
- 当前未实现：群聊、附件、举报、好友关系、自动云备份、主站签发的最小权限 OAuth、账号注销接口、任意自建 Bark。上线前需容量/成本评估、身份服务约定、恢复演练和安卓/iOS/Bark 真机联调。
