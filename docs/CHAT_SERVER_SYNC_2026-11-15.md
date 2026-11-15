# 实际生产 Worker 源码同步与曲线回归

## 来源与边界

2026-11-15，先通过 Cloudflare Custom Domains 与 service/environment/settings API 核对实际域名命中的 Worker 和 D1，再通过 production content API 取得脚本及其 Source Map。**没有把本机目录、Wrangler 配置或上游 Git HEAD 当成生产事实**。

本轮捕获的是 `nu-chat` / `production`，部署时间 **2026-11-15 09:44:36 UTC（17:44:36 UTC+8）**，版本 `991deea7-e80b-45fb-8d6b-be7d986c8d0c`，流量 100%。这次部署来自既有生产环境变化，本轮代理没有部署服务。

原样模块保存于[生产快照](../backend/nu-chat-worker/production-snapshots/2026-11-15T094436Z/manifest.json)，其中记录部署 ID、版本、bundle/Source Map 哈希和 11 个 `sourcesContent` 原始模块的 SHA-256。快照没有 OAuth、账户配置、秘密绑定值、用户消息或数据库导出。快照只供审计和合成回归，不作为开发入口。

## 同步内容

11 个生产模块中，8 个与仓库原有源码一致；差异集中在 `src/index.js`、`src/legacy.js`、`src/android.js`。工作目录继续保留可维护的模块化源码：

- `/Android/`、`/iOS/` 前缀归一化到统一 `/chat/...`。
- `POST ...?__alias=1` 回退为 GET，保留鉴权、移除 alias 参数和请求 body。
- 新增账号鉴权下的设备登记、平台节点返回、密码/恢复码两份不透明加密备份接口，契约见[Android 互通](api/ANDROID_INTEROP.md)。
- 从真实数据库**仅查询表定义**，补充本地迁移 `0005_android_registration_backup.sql`；没有读取备份内容，也没有把迁移应用到生产。

迁移与原始源码的本地同步不意味着任何生产修改。实际部署配置中的 account/database ID、秘密变量值未复制到模板。

## 确定复现的新生产回归

该生产版本将 `legacySend` 的收件人选钥从 `legacyPeer(db,to,selected.algorithm)` 改为默认选钥 `legacyPeer(db,to)`，但仍以发送者曲线构造旧协议信封。

合成测试重放证明：

1. P256 安卓通过带鉴权的 key lookup 取得 iOS 的 P256 公钥，并生成正确 P256 密文。
2. iOS 兼容主设备的默认曲线是 X25519，但同时持有 P256；这本身是合法配置。
3. 原样生产版本却把密文桥接到默认 X25519 key ID，信封的 algorithm 仍为 P256。
4. iOS 用被指定的 X25519 私钥无法解开该 P256 密文；不是调整 HKDF/AAD 或强制迁移身份就能正确处理的问题。

**工作源码有一项明确、未部署的修复**：恢复按发送者的共同曲线选取收件人公钥。快照保持原样，以便对照复现线上错误；修复不是偷偷修改快照，也没有执行生产部署。

[生产同步测试](../backend/nu-chat-worker/test/production-sync.test.js)在同一合成夹具上分别导入原样快照与工作源码，确认原样版本错误、修复版本成功，并验证原始模块哈希、路由别名、设备登记及备份账号隔离。既有双曲线真实加解密测试继续保留。

## 与先前历史故障的时间关系

此前只读抽查的最近失败消息于 **2026-11-15 08:46:29 UTC（16:46:29 UTC+8）**被接受，早于该新部署。这批历史的信封、目标 key ID、公钥和密文保留均正常；不能拿 09:44 的新回归倒推解释 08:46 的旧失败。

旧故障的具体端侧阶段仍需诊断记录确认。iOS 新诊断页可明确报告 `ALGORITHM_MISMATCH`、缺钥、未信任及真正 `AEAD_AUTH_FAILED`，不再仅靠“无法解密”猜测。不要清空数据或自动覆盖既有 P256 身份。

## 验证和部署要求

- 本机只执行不打包的 Node 单元测试与静态检查，不做 iOS 编译或 Worker 打包编译。
- 完整后端测试含 esbuild/Miniflare/workerd，由 GitHub Actions 的独立 Linux Job 执行；iOS 三项构建/测试保持并行，发布增加后端测试门禁。
- 本轮没有 D1 数据写入、消息修改、key-backup 内容导出或 Worker 部署。若要上线共同曲线修复，需要用户另行明确授权，并重新确认届时实际生产版本，避免覆盖他人的新部署。
