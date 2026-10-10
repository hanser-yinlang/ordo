# Ordo 后端 API(v1)

> 契约依据:`docs/03-数据模型与同步协议.md`(FROZEN v1)· schemaVersion = `1`
> 基础路径 `/v1`;除 `/v1/health`、`/v1/auth/*` 外均需 `Authorization: Bearer <accessToken>`。

## 0. 通用约定

### 请求头

| 头 | 必需 | 说明 |
|---|---|---|
| `Authorization` | 受保护接口必需 | `Bearer <accessToken>` |
| `Content-Type` | POST 必需 | `application/json` |
| `X-Ordo-Schema` | 可选 | 必须为 `1`;传其它值返回 `VALIDATION_FAILED`(提示升级客户端) |
| `X-Ordo-Device` | 可选 | 设备 id;`push` 未在 body 里带 `deviceId` 时用它 |
| `X-Ordo-Client` | 可选 | 客户端标识,如 `android/1.0.0`(仅用于日志,不参与逻辑) |

### 错误模型(契约 §7.4)

所有错误响应统一为:

```json
{ "error": { "code": "AUTH_REQUIRED", "message": "需要登录", "details": {} } }
```

| code | HTTP | 触发场景 |
|---|---|---|
| `VALIDATION_FAILED` | 400 | 参数/schema 校验失败、`ops.length > 500`、`pull limit > 1000`、`X-Ordo-Schema` 不兼容;**非游客账号调用 `POST /v1/auth/upgrade`**(`details.reason = "not_guest"`) |
| `AUTH_REQUIRED` | 401 | 缺少/伪造 Authorization 头;`upgrade` 的令牌对应账号已不存在 |
| `AUTH_INVALID_CREDENTIALS` | 401 | 登录时邮箱或口令错误;**游客账号调用 `login`**(无口令可校验,契约 §7.6.2) |
| `AUTH_TOKEN_EXPIRED` | 401 | access/refresh 过期;refresh 被重放(同时撤销全部会话) |
| `AUTH_EMAIL_TAKEN` | 409 | 注册邮箱已存在;**`upgrade` 的目标邮箱已被其它账号占用** |
| `SYNC_SEQ_GAP` | 409 | 客户端 `sinceSeq` 超前于服务端(`push` 与 `pull` 都会返回),客户端应重新拉快照 |
| `SYNC_OP_TOO_LARGE` | 413 | 单个 op 的 payload > 256 KB,或请求体超过服务端上限 |
| `NOT_FOUND` | 404 | 路由不存在 |
| `RATE_LIMITED` | 429 | 写接口超过 10 req/s(带 `Retry-After` 头) |
| `INTERNAL` | 500 | 未预期异常(细节只进日志,不外泄) |

### 限制(契约 §7.4)

| 项 | 限制 | 超限表现 |
|---|---|---|
| 单次 `push` 的 op 数 | ≤ 500 | 400 `VALIDATION_FAILED`,`details.limit = 500` |
| 单个 op 的 payload | ≤ 256 KB | 413 `SYNC_OP_TOO_LARGE` |
| `pull` 的 `limit` | ≤ 1000(默认 200) | 400 `VALIDATION_FAILED` |
| 写接口速率 | 10 req/s(令牌桶,按 userId 或 IP) | 429 `RATE_LIMITED` |

---

## 1. 健康检查

### `GET /v1/health`(无需鉴权)

```json
{ "status": "ok", "version": "1.0.0", "serverTime": 1759900000000, "schemaVersion": 1, "storage": "postgres" }
```

`storage` 为 `postgres` / `memory`;`memory` 表示未配置或连不上 `DATABASE_URL`,数据不持久化。

### `GET /v1/version`(附加只读端点)

```json
{ "version": "1.0.0", "schemaVersion": 1, "storage": "memory" }
```

### `GET /metrics`(附加运维端点,与 `GET /v1/metrics` 内容相同)

Prometheus 文本展示格式(`Content-Type: text/plain; version=0.0.4; charset=utf-8`),无需鉴权。
指标清单见 README「可观测性与运维」。片段示例:

```
# HELP ordo_ws_connections 当前 WS 连接数
# TYPE ordo_ws_connections gauge
ordo_ws_connections 3
# HELP ordo_storage_degraded 仓储降级状态:1=已降级为内存仓储,0=正常
# TYPE ordo_storage_degraded gauge
ordo_storage_degraded 0
# HELP ordo_rate_limited_total 被限流拒绝的请求数
# TYPE ordo_rate_limited_total counter
ordo_rate_limited_total 2
```

### `GET /v1/ops/status`(附加运维端点)

```json
{
  "version": "1.0.0",
  "schemaVersion": 1,
  "storage": "memory",
  "degraded": false,
  "wsConnections": 1,
  "tombstonePurge": { "started": true, "intervalMs": 300000, "runs": 12, "purgedTotal": 4 },
  "uptimeSec": 3600
}
```

---

## 2. 认证

> **`user` 投影(契约 §7.6.2)**:`register` / `login` / `guest` / `refresh` 的响应结构**完全同构**,
> `user` 恒为 `{ "id", "email", "isGuest", "createdAt" }`。
> 正式账号 `isGuest = false`;游客 `isGuest = true` 且 `email = null`。

### `POST /v1/auth/register` → `201`

```json
// 请求
{ "email": "a@b.com", "password": "password123", "deviceName": "Pixel 9", "platform": "android", "deviceId": "dev_7f3a" }
// 响应
{
  "user":   { "id": "uuid", "email": "a@b.com", "isGuest": false, "createdAt": 1759900000000 },
  "device": { "id": "dev_7f3a", "userId": "uuid", "name": "Pixel 9", "platform": "android",
              "createdAt": 1759900000000, "lastSeenAt": 1759900000000 },
  "accessToken": "<JWT HS256,30min>",
  "refreshToken": "<256-bit 随机串,30 天>",
  "expiresIn": 1800
}
```

口令最小长度 8;邮箱大小写不敏感;`deviceId` 省略时服务端生成。邮箱已存在 → `409 AUTH_EMAIL_TAKEN`。

### `POST /v1/auth/login` → `200`

请求同 `register`(可省略 `deviceName`/`platform`),响应结构相同(`isGuest = false`)。
邮箱不存在或口令错误统一返回 `401 AUTH_INVALID_CREDENTIALS`。

> **游客账号不能用 login 登录**:游客没有邮箱口令,`login` 一律返回 `401 AUTH_INVALID_CREDENTIALS`
> (与"邮箱不存在/口令错误"不可区分,不泄漏账号类型)。客户端应引导游客用原 `refreshToken`
> 恢复会话,或重新走 `POST /v1/auth/guest`(契约 §7.6.2)。

### `POST /v1/auth/guest` → `201`(契约 §7.6.2)

```json
// 请求(全部可选)
{ "deviceId": "dev_7f3a", "deviceName": "Pixel 9", "platform": "android" }
// 响应:与 register/login **完全同构**
{
  "user":   { "id": "uuid", "email": null, "isGuest": true, "createdAt": 1759900000000 },
  "device": { "id": "dev_7f3a", "userId": "uuid", "name": "Pixel 9", "platform": "android",
              "createdAt": 1759900000000, "lastSeenAt": 1759900000000 },
  "accessToken": "<JWT HS256,30min>",
  "refreshToken": "<256-bit 随机串,30 天>",
  "expiresIn": 1800
}
```

创建一个**匿名账号**:`email = null`、`is_guest = true`,并签发与注册登录一样的令牌。

⚠️ **游客不是离线模式**:这一步就真的把用户写进 `users` 表(带一个随机占位口令哈希,
永不匹配任何口令),之后 `push` / `pull` / `snapshot` / WS / Fastlane 全部按正常用户走 ——
数据同样入库、同样多端同步。区别只有两点:没有邮箱口令、`isGuest = true`。

- 每次调用都会创建**新的** userId(游客之间数据互相隔离,不共享)。
  恢复既有游客会话请用 `POST /v1/auth/refresh`。
- 游客的 `email` 是 SQL `NULL`(不是空串),因此 `users.email` 的唯一索引可以容纳任意多个游客
  —— PostgreSQL 的 `unique` **默认允许多个 NULL**(见迁移 `003_guest_accounts.sql` 的注释)。

### `POST /v1/auth/upgrade` → `200`(需鉴权,契约 §7.6.2)

```json
// 请求(需 Authorization: Bearer <accessToken>)
{ "email": "a@b.com", "password": "password123" }
// 响应:只返回 user(不重发令牌)
{ "user": { "id": "uuid", "email": "a@b.com", "isGuest": false, "createdAt": 1759900000000 } }
```

把**当前游客账号**升级为正式账号:**userId 不变、全部数据不变**
(devices / entities / ops / reminders / refresh_tokens 一行都不动),只补上邮箱口令并把
`is_guest` 置回 `false`。

| 情况 | 结果 |
|---|---|
| 成功 | `200 {user:{id,email,isGuest:false}}` |
| 邮箱已被**其它**账号占用 | `409 AUTH_EMAIL_TAKEN`(账号仍是游客,无副作用) |
| 调用者**不是**游客(已是正式账号) | `400 VALIDATION_FAILED`,`details.reason = "not_guest"` |
| 缺/无效 Access Token | `401 AUTH_REQUIRED` / `AUTH_TOKEN_EXPIRED` |
| 口令 < 8 字符或邮箱格式错误 | `400 VALIDATION_FAILED` |

**升级后旧 `refreshToken` 依然有效**:令牌与 `userId` 绑定,升级不改变 `userId`,
因此升级不会打断四端现有会话(`refresh` 的响应会带上最新的 `isGuest`/`email`)。
升级后即可用新邮箱走 `login`。

### `POST /v1/auth/refresh` → `200`

```json
// 请求
{ "refreshToken": "<旧 refresh>" }
// 响应:与 register/login 同构(带 user/device)
{
  "user":   { "id": "uuid", "email": "a@b.com", "isGuest": false, "createdAt": 1759900000000 },
  "device": { "id": "dev_7f3a", "userId": "uuid", "name": "未命名设备", "platform": "unknown",
              "createdAt": 1759900000000, "lastSeenAt": 1759900000000 },
  "accessToken": "<新 JWT>",
  "refreshToken": "<新 refresh>",
  "expiresIn": 1800
}
```

**轮换语义**:旧 refresh 立即失效。若旧 refresh 被重放,服务端撤销该用户**全部**会话并返回 `AUTH_TOKEN_EXPIRED`。

### `POST /v1/auth/logout` → `204`

```json
{ "refreshToken": "<要吊销的 refresh>" }
```

### `POST /v1/devices/register` → `200`(需鉴权)

```json
{ "deviceId": "dev_7f3a", "name": "新名字", "platform": "windows" }
// → { "device": { ... } }
```

### `DELETE /v1/account` → `204`(需鉴权)

删除账号与全部数据(契约 §9 级联删除:devices / refresh_tokens / entities / ops / reminders)。

---

## 3. 同步

### 3.1 Op 结构(契约 §7.2)

```jsonc
{
  "opId": "01JABCDEF...",   // ULID/uuid,客户端生成,幂等键
  "deviceId": "dev_7f3a",
  "entity": "todo",         // todo | project | area | heading | tag
  "entityId": "uuid",
  "type": "upsert",         // upsert | delete
  "payload": { /* 实体完整快照;delete 时为 null */ },
  "clientTs": 1759900000123 // LWW 依据
}
```

### 3.2 `GET /v1/sync/snapshot` → `200`

```json
{ "serverSeq": 128, "areas": [], "projects": [], "headings": [], "todos": [], "tags": [] }
```

只返回 `deleted != true` 的实体。**Heading 是顶层实体**(契约 §2.2 实现说明):项目 payload 里**不内嵌** `headings`,
快照的 `headings` 数组来自独立的 heading 实体,按 `order` 排序;客户端按 `heading.projectId == project.id` 自行派生「项目的标题列表」。

### 3.3 `POST /v1/sync/push` → `200`

```jsonc
// 请求
{ "deviceId": "dev_7f3a", "sinceSeq": 128, "ops": [ /* Op[] */ ] }

// 响应
{
  "serverSeq": 130,
  "accepted": [ { "opId": "op_1", "serverSeq": 129, "applied": true,  "tagsMerged": false },
                { "opId": "op_2", "serverSeq": null, "duplicate": true, "applied": false } ],
  "rejected": [ { "opId": "op_3", "reason": "stale", "message": "…" } ],
  "ops": [ /* sinceSeq 之后的**远端** op(不含本次自己推的),用于捎带拉取 */ ]
}
```

`rejected[].reason` 取值与含义:

| reason | 含义 |
|---|---|
| `stale` | `clientTs` 早于服务端 `updatedAt`,LWW 判负(但标签仍按 §7.3 规则 3 取并集) |
| `completion_immutable` | 服务端已是 `done`/`canceled`,拒绝被 `open` 覆盖 |
| `tombstoned` | 命中删除墓碑,旧 op 不能复活实体 |
| `project_incomplete` | 项目下仍有未完成待办/未归档标题,不允许 `status=done`(§2.2 硬约束) |
| `invalid` | payload 未通过实体 schema 校验 |

**合并规则实现位置**:`src/services/sync.ts`(`applyOp` / `mergeTagsOnly` / `mergeForStore`)。

### 3.4 `GET /v1/sync/pull?sinceSeq=&limit=` → `200`

```json
{ "serverSeq": 130, "ops": [ /* Op[] 带 seq 字段,按 serverSeq 升序 */ ], "hasMore": false }
```

`sinceSeq` 超前于服务端时返回 `409 SYNC_SEQ_GAP`。

---

## 4. 实时通道(WebSocket,契约 §7.5)

```
WS /v1/ws?token=<accessToken>
```

鉴权失败:先发 `{type:"error",error:{code:"AUTH_REQUIRED",...}}`,再以 **4401** 关闭。

### 服务端 → 客户端

```jsonc
{ "type": "hello",    "serverSeq": 128, "serverTime": 1759900000000 }
{ "type": "ops",      "serverSeq": 130, "ops": [ /* Op[] */ ] }
{ "type": "reminder", "todoId": "uuid", "title": "交季度报告", "at": "2026-10-09T18:00" }  // Fastlane
{ "type": "ping",     "t": 1759900000000 }
```

### 客户端 → 服务端

```jsonc
{ "type": "subscribe", "deviceId": "dev_7f3a" }  // 绑定设备,服务端据此跳过变更发起设备
{ "type": "ack",       "serverSeq": 130 }
{ "type": "pong" }
```

**Fastlane**:`reminder` 有独立索引(`reminders` 表),后台每 **1 秒**扫描「未来 60 秒内到期」的提醒,
命中即刻推送;`fired=true` 保证同一提醒只投递一次。提醒时间被改写会重新投递;待办完成/取消/删除会移除索引。

---

## 5. 与契约的差异与补充

| 项 | 说明 |
|---|---|
| `GET /v1/version`、`DELETE /v1/account` | 契约 §7.4 表格未列出 `version`,§9 提到「删除账号与全部数据」但未给路径。两者均为**附加**端点,不影响既有契约 |
| `GET /metrics`、`GET /v1/metrics`、`GET /v1/ops/status` | 附加**运维**端点(本轮新增),不属于客户端契约;只输出聚合数值与运行状态,不含任何用户标识或正文 |
| 日志脱敏 | 结构化 JSON 日志,永不打印 token / 口令 / 备注正文;WS 握手 URL 的 `?token=` 会被剥离(有断言用例锁定) |
| `completion_immutable` 的判定 | 契约 §7.3 规则 2 的表述是「远端 op 是**更早的** open」。实现采取**更严格**的解释:只要本地是 `done/canceled`,任何 `open` 版本都被拒绝(更贴合「完成不可回滚」的语义) |
| 标签并集的副作用 | 被判负(stale / completion_immutable)的 op 若带新标签,服务端合并后会写入一条 `opId = "srv:tags:<原 opId>"` 的合成 op,让其它设备也能收敛 |
| 实体 `serverSeq` | `entities.server_seq` 记录「最后一次改动该实体的 op 的 seq」,便于客户端做增量快照比对 |
| 服务端不代做重复实例 | 契约 §6 的重复规则由客户端执行(本地优先);服务端提供纯函数参考实现 `src/domain/repeat.ts`,并可用 `SERVER_SIDE_REPEAT=true` 打开(默认关闭,避免与客户端双写) |
| `headingId` 归属校验 | §3 要求 `headingId` 必须属于 `projectId`;服务端查 `heading` 实体(顶层实体,见 §2.2 实现说明),不合法则置 `null` |
| Heading 模型 | 契约 §2.2 在 2026-10-08 修订:Project **不再内嵌** `headings`,Heading 只作为顶层实体同步。服务端已按修订版实现(ProjectSchema 不含 `headings`,`snapshot.headings` 只来自 heading 实体) |
| 时区 | `reminder` 是「无时区的本地时间串」,服务端用 `TZ_OFFSET_MINUTES`(默认 `480` = UTC+8)换算 epoch |
