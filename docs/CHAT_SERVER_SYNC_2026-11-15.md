# 实际生产 Worker 源码同步与曲线回归

**后续状态：用户明确授权后，修复已于 2026-11-15 11:26:53 UTC（19:26:53 UTC+8）部署。** 当前记录版本为 `7fbc42eb-f859-4ee7-a01b-d402ee9b062e`、100% 流量；见[部署验收凭据](../backend/nu-chat-worker/production-snapshots/current-deployment.json)。以下原始捕获与“未部署”描述属于同步阶段，不代表后续部署状态。

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

**工作源码有一项明确的兼容修复**：恢复按发送者的共同曲线选取收件人公钥。同步时该修复尚未部署，之后经用户明确授权已完成部署。原样快照保持不变，继续用于对照复现旧生产错误，不把修复偷偷混入历史快照。

[生产同步测试](../backend/nu-chat-worker/test/production-sync.test.js)在同一合成夹具上分别导入原样快照与工作源码，确认原样版本错误、修复版本成功，并验证原始模块哈希、路由别名、设备登记及备份账号隔离。既有双曲线真实加解密测试继续保留。

## 与先前历史故障的时间关系

此前只读抽查的最近失败消息于 **2026-11-15 08:46:29 UTC（16:46:29 UTC+8）**被接受，早于该新部署。这批历史的信封、目标 key ID、公钥和密文保留均正常；不能拿 09:44 的新回归倒推解释 08:46 的旧失败。

旧故障的具体端侧阶段仍需诊断记录确认。iOS 新诊断页可明确报告 `ALGORITHM_MISMATCH`、缺钥、未信任及真正 `AEAD_AUTH_FAILED`，不再仅靠“无法解密”猜测。不要清空数据或自动覆盖既有 P256 身份。

## 验证和部署要求

- 本机只执行不打包的 Node 单元测试与静态检查，不做 iOS 编译或 Worker 打包编译。
- 完整后端测试含 esbuild/Miniflare/workerd，由 GitHub Actions 的独立 Linux Job 执行；iOS 三项构建/测试保持并行，发布增加后端测试门禁。
- 同步阶段没有 D1 数据写入、消息修改、key-backup 内容导出或 Worker 部署。后续用户明确授权部署后，先重新核对线上仍为捕获版本，再上传 Actions 产物为未激活版本，核对全部绑定/运行时后切换 100% 流量；保留旧版本作回滚。
- 部署后，实际 bundle 与 Actions SHA-256 一致，线上 Source Map 的 11 个原始模块均匹配测试产物；变量和秘密引用、D1 绑定及非代码设置保持不变。`/iOS/chat/v2/capabilities` 与 `/Android/chat/ping` 均 200。未执行数据库写操作或迁移，也未改写已有消息。
- 该验收不等于真实双方设备已成功解密；尤其不能自动恢复早于修复的历史。未来再次部署仍须重新核对实际生产状态，避免覆盖其他人的更新。
