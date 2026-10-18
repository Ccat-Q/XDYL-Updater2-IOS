# 商城、称号、兑换、市场与支付

共 14 项，服务 MAIN；iOS Bearer，GET 无请求体，Query 未列出即无。证据 C，部分 S/历史 R 单独说明。JSON 是合成结构示例；完整错误码与扣费约束仍以服务端为准。[通用协议](README.md)。

## 接口目录

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/shop/items` | 商品列表 |
| POST | `/shop/buy` | 喵币购买 |
| GET | `/titles/catalog` | 预设称号及自定义规则 |
| GET | `/titles/mine` | 称号仓库 |
| POST | `/titles/buy` | 购买预设或自定义称号 |
| POST | `/titles/wear` | 佩戴称号 |
| GET | `/redeem/rate` | 喵币兑换游戏币比例 |
| POST | `/redeem/game-coins` | 扣喵币换游戏币 |
| GET | `/market/preview` | 市场行情 |
| GET | `/market/history/{identifier}` | 市场物品历史 |
| POST | `/pay/create` | 创建支付宝订单 |
| GET | `/pay/status` | 支付订单状态 |
| POST | `/afdian/status` | 爱发电订单查询 |
| POST | `/afdian/claim` | 爱发电订单领取 |

### GET /shop/items

用途：显示可购买商品和选择支付入口（C/S）。返回：

```json
{"code":200,"data":{"items":[{"id":1,"name":"示例商品","description":"商品说明","price":10}]}}
```

列表兼容 payload 数组；条目按 RemoteItem 解码。UI 消费真实 `id`、名称/描述与 `price`。价格单位在喵币购买入口为喵币；支付宝金额由创建订单响应给出，不能将商品 price 自动当成人民币。后端库存、商品类型、购买次数限制完整字段待核实。

### POST /shop/buy

用途：使用当前账户喵币购买商品（C/S）。JSON：

```json
{"item_id":1}
```

item_id 是商品真实 ID，number/string。返回已知：

```json
{"code":200,"message":"购买成功","data":{"redeem_code":"<REDEEM_CODE>"}}
```

凭证兼容 `data.code_text/data.code`，或根级明确凭证字段；根级数字/数字字符串 code 不作兑换码。UI 立即展示并允许复制，另可 GET `/user/items`。成功但未返回凭证时不能伪造一条，显示购买结果和“我的物品”入口。返回 message 可在根或 payload。影响余额，二次确认、不自动重发。

### GET /titles/catalog

用途：预设称号与自定义称号计费/长度规则（C/S）。返回示例：

```json
{"code":200,"data":{"presets":[{"id":1,"title":"&#33CCFF示例称号","price":100}],"custom":{"price_per_char":10,"max_len":8}}}
```

列表兼容 `titles`/payload 数组。名称读取 title/name，预设 price 为喵币。自定义规则取 `data.custom` 或 payload，单字价格 `price_per_char/pricePerChar`，可见上限 `max_len/max_length/maxLen`，整数/数字字符串。缺规则不能编造固定价格。客户端预估为单价 × 去格式码后的 UTF-16 可见长度，最终由服务端扣费与校验。

### GET /titles/mine

用途：拥有的称号、数量、最早获得与佩戴状态（C/S）。返回：

```json
{"code":200,"data":{"items":[{"title":"&b示例称号","count":2,"first_at":"2026-10-01 12:00:00","wearing":true}]}}
```

容器兼容 titles/数组；title/name string、count integer、first_at（兼容 created_at）时间、wearing bool。当前称号另由 `/user/profile.title` 显示；不能以当前称号缺失证明仓库为空。

### POST /titles/buy

用途：购买预设或用户编辑的自定义称号（C/S）。两者使用同一请求体，不发送目录 ID：

```json
{"title":"&b&l示例&#FF88CC称号"}
```

title string 保留颜色/格式码。已知返回：

```json
{"code":200,"message":"购买成功","data":{"granted_in_game":false,"new_coins":50}}
```

消费 `granted_in_game:bool`、`new_coins:number/string` 与 message，兼容根级字段。HTTP/业务成功只表示账户结果；false 明确提示游戏内未送达、联系管理员补发且不要重复购买；缺字段提示送达未知，不能补 true。成功后刷新本人和称号数据。

格式/本地校验：十六进制 `&#RRGGBB`、短色 `&0`–`&f`、格式 `&k`–`&o`、重置 `&r`（大小写兼容）；`&l` 粗体，`&r` 重置，k/m/n/o 按 Windows 显示行为隐藏而不实现特效。可见字符接受中文、字母、数字、`_·×`；总 UTF-16 长度最多 64，可见长度遵目录规则。颜色生成器、预览和计费共用解析，不是额外 API。服务端校验仍最终决定。

### POST /titles/wear

用途：佩戴已经拥有的称号（C/S）。JSON：

```json
{"title":"&b示例称号"}
```

已知返回：

```json
{"code":200,"message":"佩戴成功","data":{"granted":false}}
```

字段为 `granted`，**不是购买的 granted_in_game**。false 提示游戏内同步未送达、稍后自动补发；缺失保留未知。客户端流程标记佩戴不扣喵币，不据此替后端杜撰其他费用规则。

### GET /redeem/rate

用途：兑换页面读取比例（C/S）。返回：

```json
{"code":200,"data":{"rate":100}}
```

rate 为 number/数字字符串；UI 表达 1 喵币兑换 rate 游戏币。缺失比例不应伪造固定值；价格可能变化，提交时服务端最终结算。

### POST /redeem/game-coins

用途：花费输入的喵币数兑换游戏币。JSON：

```json
{"coins":10}
```

coins 是客户端校验的正整数，number。返回体：消费根级 message，其余按 Ack；成功清空输入并刷新本人余额。不自行计算/伪造游戏服务器最终到账结果。

### GET /market/preview

用途：行情列表，搜索及五种本地排序（C/S，2026-10-13 历史 R）。返回：

```json
{"code":200,"data":{"items":[{"identifier":"nether_star1","name":"示例物品","name_en":"Example Item","buy":100,"sell":90,"price":95,"ops":10,"change":"2.5%","icon":"/icons/demo.png","icon_b64":"<BASE64_IMAGE>"}]}}
```

列表兼容 payload 数组。标识 `identifier/id`，名称 name/title，英文 name_en/en；buy/sell/price 为 number/数字字符串、ops integer、change string，图标 icon URL 或 icon_b64（可含 data URL 前缀）。这些图标字段可择一，示例不要求同时存在。buy 是玩家买入价、sell 是玩家卖出价（静态文案 S），不是币种兑换比例。

前台页面每分钟刷新一次；排序“幅度/涨幅/跌幅/价格/成交活跃度”在本地进行，不发送未证实的 sort 参数。数值缺失靠后，不按字符串大小排序。

### GET /market/history/{identifier}

用途：指定市场物品历史图表。identifier 来自 preview，非显示名称。返回：

```json
{"code":200,"data":{"points":[{"time":1792324800,"value":95.5}]}}
```

容器兼容 history/数组；值 value/price，亦兼容纯数字采样；时间 time/timestamp 数值按 Unix 秒处理，字符串则展示（兼容 created_at）。当前请求不含区间、粒度或分页，不能假定支持。2026-10-13 既有读取证实 time/value 采样（R）。

### POST /pay/create

用途：为所选商品创建支付宝订单（C/S）。JSON：

```json
{"item_id":1}
```

返回已消费：

```json
{"code":200,"data":{"order_no":"<ORDER_NO>","qr_code":"https://example.invalid/pay/demo","amount_yuan":"1.00","status":"pending"}}
```

order_no string 必须非空，二维码/支付文本兼容非空 qr_code/qr_url/pay_url；金额 amount_yuan/amount 为 number/string；状态 status/state string。URL 形态仅为示意，实际由服务端生成；二维码可为编码文本或图片 URL，当前仅允许已知安全支付 scheme 打开。创建成功≠支付成功≠兑换码已发放，不能依赖本地打开支付宝确认结果。

### GET /pay/status

用途：查询特定支付宝订单。Query：`order_no:string`，来自 create；请求体无。返回：

```json
{"code":200,"data":{"order_no":"<ORDER_NO>","status":"paid","redeem_code":"<REDEEM_CODE>"}}
```

消费 status/state、可选 order_no、兑换码别名 redeem_code/code_text/code。响应订单号若存在必须匹配当前订单。已知客户端状态：paid 完成；closed/expired 关闭/过期；failed 失败；其余继续等待，不把未知状态自行改成 paid。已支付未有凭证提示生成中/查看物品。

前台可见每 5 秒查询，手动与自动互斥；离页/后台停止，回前台重读。创建后本地 15 分钟停止查单（后台时间计入）；401/404 也停止，临时网络失败可继续。15 分钟是本地策略，不是经确认的服务端订单有效期或撤单承诺。重建、改号、旧请求不能串单。

### POST /afdian/status

用途：查询用户输入的爱发电订单号（C/S）。注意是 POST，不是 GET。JSON：

```json
{"out_trade_no":"<AFDIAN_ORDER_NO>"}
```

已知返回：

```json
{"code":200,"data":{"paid":true,"claimed":false,"message":"订单可领取"}}
```

消费 paid/claimed bool、message string，以及可能已返回的兑换码别名。已领取但无可读兑换码时显示服务器消息/“已发给其他用户”，不能引导查看当前用户必然不存在的凭证。不向爱发电网站直接发送社区 Bearer。

### POST /afdian/claim

用途：将符合条件的爱发电订单领取到当前账户（C/S）。JSON：

```json
{"out_trade_no":"<AFDIAN_ORDER_NO>"}
```

返回已知：

```json
{"code":200,"data":{"claimed":true,"redeem_code":"<REDEEM_CODE>"}}
```

解码与 status 同样兼容 paid/message/兑换码别名；只有业务成功才刷新物品。订单实际归属/重复领取限制以服务端为准；不重放真实领取验证文档。

## 外部支付页面

客户端另打开两个静态爱发电商品页：`https://ifdian.net/item/b5c1ad0c9adc11f19a345254001e7c00`、`https://afdian.com/p/9c65d9cc617011ed81c352540025c377`。它们是网页入口，不是本项目恢复的 JSON API，不编写虚构请求/返回体。支付宝跳转由 create 返回的支付文本决定，同样不等同本项目后端回调接口。
