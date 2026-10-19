# 聊天后端生产部署记录

2026-10-19，用户明确要求使用 Wrangler 修改现有 Worker，并把部署工程放到 `/root/nu-chat`。**核心后端已部署；R2 未开通，备份/设备迁移未上线；未做真实账号收发或安卓/iOS/Bark真机联调。**

## 部署目标与本机目录

| 项目 | 实际值 |
| --- | --- |
| 域名 | `https://nu-pe-chat.cc.cd`，保留既有 Custom Domain |
| Worker | `nu-chat`，更新原实例，没有创建同名替代服务 |
| 当前版本 | `34d2826d-f7af-4c52-bf84-3b670183d511` |
| 版本标签 | `v2-20261019` |
| D1 | 原 `nu-chat-db`，ID `fbda1269-6747-46f9-93f0-828bb15dc14a` |
| schema | 四项migration已应用，v2_schema=4 |
| Cron | `* * * * *`，每分钟维护outbox/过期事件；无R2绑定则跳过对象清理 |
| Wrangler工程 | `/root/nu-chat/backend/nu-chat-worker` |
| 生产配置 | `wrangler.production.jsonc`（不是未填ID的通用模板） |
| 原代码/配置/回退点元数据 | `/root/nu-chat/deploy-backups/20261019-before-v2/` |
| 本机私密部署密钥文件 | `/root/nu-chat/.secrets/nu-chat.production.json`，目录0700、文件0600；不提交或输出内容 |

`/root/nu-chat` 原有的 `server.js`、`server.js.bak`、`data` 和日志未覆盖或删除；没有把 `type:module` 的package.json直接放在旧Node脚本旁，避免改变旧CommonJS服务行为。本次没有重启/停用旧Node服务。

## 数据保护与发布步骤

1. 用当前Wrangler登录身份确认域名、原Worker和D1所有权，未修改其他Worker。
2. 保存旧Worker代码、配置、版本记录和schema；旧版本为 `b9f6252c-13e4-44f3-b874-b4bc3967907f`。完整SQL本地导出被安全审批拒绝后，用户明确选择**仅Cloudflare原地恢复点**；没有绕过限制或导出聊天数据。
3. 通过 `wrangler d1 time-travel info` 记录原地恢复书签于本机 `recovery-point.json`；它不是永久SQL备份，受Cloudflare账户的Time Travel保留窗口约束。
4. 按线上实际旧schema在内存SQLite演练四项migration，通过后用 `wrangler d1 migrations apply nu-chat-db --remote --config wrangler.production.jsonc` 应用。旧表不清空，旧记录保持原位。
5. 生成两项独立32字节秘密，使用Wrangler `--secrets-file` 随同新版上传；秘密作为Cloudflare secret_text绑定，不写入仓库或日志。生产BARK_ENABLED=true，但没有替任何用户绑定Bark key或发送通知。
6. 生产配置dry-run成功后，执行现有Worker的Wrangler deploy并更新Custom Domain/Cron；部署代码119.87KiB，gzip27.01KiB，启动时间2ms。

本次运行命令（维护时在上述工程目录执行，必须先审阅代码/配置）：

```sh
wrangler d1 migrations list nu-chat-db --remote --config wrangler.production.jsonc
wrangler deploy --dry-run --config wrangler.production.jsonc
wrangler deploy --config wrangler.production.jsonc
```

首次部署已通过私密文件上传秘密；后续deploy保留已有云端secret。不要重新运行随机密钥生成以“修复”配置，否则旧游标/Bark加密绑定可能失效。Wrangler账号、网络代理和日志路径按实际终端环境配置；上述命令不是自动发布授权。

## 线上无凭据验证

验证时间：2026-10-19 22:52:54 UTC。

| 检查 | 结果 |
| --- | --- |
| GET `/chat/ping` | HTTP200，protocol=legacy-d1 |
| GET `/chat/v2/capabilities` | HTTP200，protocol=nu-chat-v2，包含legacy_android_interop及bark |
| 无Bearer GET `/chat/pull`、`/chat/v2/sync` | HTTP401，未绕过认证 |
| 不存在的V2路径 | HTTP404 |
| OPTIONS偏好接口 | HTTP204，允许PATCH |
| 云端部署版本/DB/secrets/Cron绑定 | 与本机生产配置一致 |
| 迁移前后聚合计数 | 均为旧users=1、messages=0、reads=0；验证后v2_accounts=0；没有创建测试用户或消息 |

线上只做无凭据读取/预检与管理元数据核对，不声称认证后实际收发已联调。此前本地41项测试含真实workerd/D1/R2及双曲线向量；不替代生产真机验收。

## 当前明确缺口

- Cloudflare账号R2列表接口返回10042“Please enable R2 through the Cloudflare Dashboard”。**未开通账单、未创建bucket、没有R2绑定。** 因此能力列表正确不含encrypted_backups/device_history_transfer；对应存储功能不可用，不能假装已部署。后续需用户先开通R2并补齐Wrangler授权，再创建私有bucket、添加生产绑定后重新部署。
- iOS聊天页面/持钥存储/双协议接入尚未实施；仅后端上线不会自动给当前IPA增加互聊能力。
- 旧安卓兼容版本和单主设备限制见[安卓互通](api/ANDROID_INTEROP.md)。导入的无稳定身份链接历史不会按当前用户名猜归属；公钥所有者须认证登记。
- Bark API已开放但尚无用户绑定，没有真机推送验证。主站稳定ID、跨端收发、历史恢复和Bark锁屏/终止状态仍需后续验收。

## 回退注意

先检查生产是否已有新数据、当前版本、剩余Time Travel窗口及客户端使用情况，再由维护方决定回退。旧Worker版本和数据库原地恢复是两个独立操作；恢复旧书签会倒退其后所有写入，**不得自动恢复或把回退当作无损撤销**。回退代码可能移除新版功能，Cron和secret配置也须单独核对。此次没有执行任何回退/数据库恢复。
