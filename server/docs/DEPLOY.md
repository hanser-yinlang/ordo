# Ordo 后端部署手册

## 1. 运行形态

| 形态 | 存储 | 适用 |
|---|---|---|
| 配 `DATABASE_URL` 且连得上 | PostgreSQL(`PgRepository`) | 生产 / 预发 |
| 未配 `DATABASE_URL`,或连接失败 | 内存仓储(`MemoryRepository`),启动日志会打印 `[storage] …降级` | 本地开发 / 自动化测试 / 演示 |

两种实现满足同一 `Repository` 接口,业务代码无分支。内存模式下**重启即丢数据**。

---

## 2. 环境变量

见 `.env.example`。要点:

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` / `HOST` | `8080` / `0.0.0.0` | 监听地址 |
| `DATABASE_URL` | 空 | 例:`postgres://ordo:secret@db:5432/ordo`;空则内存仓储 |
| `DB_POOL_MAX` | `10` | PG 连接池上限 |
| `JWT_SECRET` | 开发环境随机 | **生产必须显式设置**(否则启动即报错);access token 用 HS256 签名 |
| `ACCESS_TTL_SEC` | `1800` | access token 有效期(30 分钟) |
| `REFRESH_TTL_DAYS` | `30` | refresh token 有效期 |
| `TZ_OFFSET_MINUTES` | `480` | 本地时区偏移;用于把 `reminder`(`YYYY-MM-DDTHH:mm`)换算成 epoch millis |
| `REMINDER_SCAN_MS` | `1000` | Fastlane 扫描间隔(契约 §7.5) |
| `REMINDER_HORIZON_MS` | `60000` | 提前量:扫描「未来 60 秒内到期」 |
| `BODY_LIMIT_BYTES` | `524288` | HTTP body 上限;单 op 256 KB 由业务层另行校验 |
| `MAX_OPS_PER_PUSH` / `MAX_OP_PAYLOAD_BYTES` / `MAX_PULL_LIMIT` | `500` / `262144` / `1000` | 契约 §7.4 限制 |
| `RATE_LIMIT_ENABLED` / `RATE_LIMIT_CAPACITY` / `RATE_LIMIT_REFILL_PER_SEC` | `true` / `10` / `10` | 写接口令牌桶 |
| `TOMBSTONE_PURGE_INTERVAL_MS` | `300000` | 墓碑清理定时任务周期;`<=0` 关闭 |
| `TOMBSTONE_TTL_MS` | `2592000000` | 墓碑保留时长(30 天) |
| `SERVER_SIDE_REPEAT` | `false` | 是否由服务端代生成重复待办(默认关闭,避免与客户端双写) |
| `ORDO_CODE_PEPPER` | 空(开发回退 `JWT_SECRET`) | 邮箱验证码的 HMAC pepper;**生产必须显式设置**(否则启动即报错,契约 §7.6.5 / §9) |
| `ORDO_EMAIL_CODE_TTL_SEC` / `ORDO_EMAIL_CODE_RETRY_AFTER_SEC` | `300` / `60` | 验证码有效期 / 同邮箱最小请求间隔(秒) |
| `ORDO_EMAIL_CODE_MAX_PER_HOUR` / `ORDO_EMAIL_CODE_MAX_PER_DAY` / `ORDO_EMAIL_CODE_MAX_ATTEMPTS` | `5` / `10` / `5` | 同邮箱每小时 / 每天发码上限;同码最多尝试次数 |
| `ORDO_MAIL_TRANSPORT` | `console` | 发信通道:`console`(写日志,仅适合本地)/ `http`(POST 到通用邮件网关) |
| `ORDO_MAIL_HTTP_URL` / `ORDO_MAIL_HTTP_TOKEN` / `ORDO_MAIL_HTTP_TIMEOUT_MS` | 空 / 空 / `5000` | `transport=http` 时 URL **必填**(否则启动即报错);token 作为 `Authorization: Bearer`;超时按发信失败(500 `mail_failed`) |
| `ORDO_DEV_ECHO_CODE` | `0` | 开发回显验证码(仅非生产 + console);`NODE_ENV=production` 时设为 `1` **拒绝启动** |
| `LOG_LEVEL` | `info`(生产) | 日志级别;日志**不打印** token / 口令 / 备注正文(验证码也只在非生产 console 通道打印) |

> **上线邮箱验证码登录前必做**:把 `ORDO_MAIL_TRANSPORT` 设为 `http` 并配置 `ORDO_MAIL_HTTP_URL`
> (`console` 通道在生产**不会真的投递邮件**),同时设置 `ORDO_CODE_PEPPER`(独立于 `JWT_SECRET` 的随机串,
> 轮换 pepper 会让**在途验证码全部失效**)。

> 多实例部署注意:限流是**单实例内存**令牌桶。多副本时请按 `userId` 做一致性哈希,或替换为 Redis 实现(`src/services/rate-limit.ts` 的 `TokenBucketLimiter` 已是可替换的单一入口)。

---

## 3. Docker

仓库内附 `Dockerfile`(多阶段构建,运行阶段只装生产依赖)。

```bash
# 1) 构建镜像(在 ordo/server 目录)
docker build -t ordo-server:1.0.0 .

# 2) 起 PostgreSQL(示例)
docker run -d --name ordo-db \
  -e POSTGRES_USER=ordo -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=ordo \
  -p 5432:5432 postgres:16-alpine

# 3) 跑迁移(独立步骤,失败即退出)
#    运行阶段镜像只装生产依赖,用编译后的脚本(不是 tsx 版)
docker run --rm --network host \
  -e DATABASE_URL=postgres://ordo:secret@127.0.0.1:5432/ordo \
  ordo-server:1.0.0 node dist/scripts/migrate.js

# 4) 启动服务
docker run -d --name ordo-api --network host \
  -e DATABASE_URL=postgres://ordo:secret@127.0.0.1:5432/ordo \
  -e JWT_SECRET="$(openssl rand -hex 32)" \
  -e NODE_ENV=production -e TZ_OFFSET_MINUTES=480 \
  -p 8080:8080 ordo-server:1.0.0
```

> 应用启动时也会自动执行迁移(`PgRepository.init()`),`pnpm migrate` 用于「迁移先于流量」的严格发布流程。

### docker compose(可选)

```yaml
services:
  db:
    image: postgres:16-alpine
    environment: { POSTGRES_USER: ordo, POSTGRES_PASSWORD: secret, POSTGRES_DB: ordo }
    volumes: [ "ordo-pg:/var/lib/postgresql/data" ]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ordo"]
      interval: 5s
      retries: 10
  api:
    build: .
    depends_on: { db: { condition: service_healthy } }
    environment:
      DATABASE_URL: postgres://ordo:secret@db:5432/ordo
      JWT_SECRET: change-me-in-production
      NODE_ENV: production
    ports: [ "8080:8080" ]
volumes: { ordo-pg: {} }
```

---

## 4. 裸机部署(Node 20+)

```bash
cd ordo/server
pnpm install --frozen-lockfile
pnpm run build                 # tsc → dist/
export $(grep -v '^#' .env | xargs)   # 或使用 systemd EnvironmentFile
pnpm migrate                   # 可选:DATABASE_URL 为空时会提示无需迁移
pnpm start                     # node dist/index.js
```

### 部署后自检(端到端)

```bash
node scripts/smoke.mjs http://127.0.0.1:8080
# 覆盖:健康检查 → 注册 → push → LWW 拒绝 → WS hello/ops/reminder → pull → snapshot → 未鉴权 401

curl -s http://127.0.0.1:8080/v1/ops/status          # 降级状态 / WS 连接数 / 清理任务
curl -s http://127.0.0.1:8080/metrics | head -40     # Prometheus 指标
```

> `scripts/smoke.mjs` 面向**已部署的服务**;协议行为的可回归覆盖在 `test/e2e.test.ts`
>(自起真实 HTTP + WS,含 401/409/413/429/4401 失败路径),两者互补。

systemd 单元示例:

```ini
[Unit]
Description=Ordo API
After=network.target postgresql.service

[Service]
WorkingDirectory=/opt/ordo/server
EnvironmentFile=/opt/ordo/server/.env
ExecStart=/usr/bin/node dist/index.js
Restart=always
RestartSec=3
User=ordo
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

---

## 5. 迁移

- 迁移文件:
  - `src/repo/migrations/001_init.sql` —— 契约 §8 表结构(users / devices / refresh_tokens / entities / ops / reminders / schema_migrations)。
  - `src/repo/migrations/002_device_id_text.sql` —— 把 `devices.id` / `refresh_tokens.device_id` 从 `uuid` 统一为 `text`(契约 §7.2 的 deviceId 是 `dev_xxx` 不透明短串,不是 uuid)。对全新库是 no-op,对跑过旧版 001 的库执行真正的类型变更。
- 版本记录:`schema_migrations(version, applied_at)`,按文件名前缀数字升序执行,已应用的跳过(幂等)。
- 执行方式:源码环境用 `pnpm migrate`(tsx);生产镜像用 `pnpm migrate:prod` / `node dist/scripts/migrate.js`;应用启动时也会自动执行(`PgRepository.init()`)。
- 迁移文件查找顺序:`dist/repo/migrations`(镜像内已拷贝)→ `../../src/repo/migrations` → `$PWD/src/repo/migrations` → `$PWD/migrations`。
- 新增迁移:添加 `00N_xxx.sql` 即可,**不要**修改已发布的迁移文件。
- **升级注意(002)**:`devices.id` 被 `refresh_tokens.device_id` 的外键引用,而 PostgreSQL
  不允许直接改变被引用列的类型。002 内部按「删外键 → 改引用列 → 改被引用列 → 重建外键」的顺序处理,
  整体包在一个 `DO` 块里(失败全部回滚),并在末尾自检三列都是 `text`。已有库直接
  `pnpm migrate` 即可;**若你的库已经跑过旧版 001 且注册接口报 500
  `invalid input syntax for type uuid`**,就是这个迁移没跑到,确认 `schema_migrations` 里有 `version = 2`。
- 客户端兼容:服务端对带 `X-Ordo-Schema` 的请求做版本校验,不匹配返回 `VALIDATION_FAILED`,提示升级客户端(契约 §8)。

---

## 6. 健康检查与可观测性

```bash
curl -s http://127.0.0.1:8080/v1/health
# {"status":"ok","version":"1.0.0","serverTime":...,"schemaVersion":1,"storage":"postgres"}

curl -s http://127.0.0.1:8080/metrics           # Prometheus 文本指标
curl -s http://127.0.0.1:8080/v1/ops/status     # 人工自检:降级状态/WS 连接数/清理任务
```

- 容器 liveness/readiness 建议探测 `/v1/health`;`storage` 字段可判断是否意外降级为内存仓储(生产应为 `postgres`)。
  也可直接告警 `ordo_storage_degraded == 1`。
- `/v1/version` 便于灰度时确认版本与 schema。
- 日志:**JSON 行**格式,只记录 `method`/`url`/`statusCode` 与错误信息;`serializers` 已剔除请求头与请求体,
  并对 `authorization` / `token` / `password` / `note` 等路径做 `redact`。**WS 握手 URL 的 `?token=` 也会被剥离**
  (只保留 pathname),因此 access token 不会落日志 —— 这条有断言用例锁定(`test/observability.test.ts`)。
- Prometheus 抓取配置示例:

  ```yaml
  scrape_configs:
    - job_name: ordo
      static_configs:
        - targets: ['ordo:8080']
      metrics_path: /metrics
  ```

- 建议告警项:`ordo_storage_degraded == 1`、`rate(ordo_sync_seq_gap_total[5m]) > 0`、
  `rate(ordo_tombstone_purge_errors_total[15m]) > 0`、`ordo_ws_connections` 长期为 0(推送通道断了)。
- 指标多副本部署时各自暴露一份,聚合交给 Prometheus。

---

## 7. 备份与恢复

- **数据库**:`pg_dump -Fc ordo > ordo-$(date +%F).dump`;恢复 `pg_restore -d ordo --clean --if-exists ordo-YYYY-MM-DD.dump`。
- 备份内容覆盖全部用户数据(entities/ops/reminders 与账号表),`users → 其余表` 均为 `on delete cascade`。
- 建议:每日全量 + WAL 归档(PITR);`ops` 表增长最快,可按 `created_at` 归档历史 op(客户端只需 `sinceSeq` 之后的增量,归档前确认没有落后太多的设备)。
- **密钥**:`JWT_SECRET` 需与备份分开保管;轮换密钥会使所有 access token 立即失效(refresh 不受影响,用户无感)。
- 墓碑清理:软删除实体的墓碑保留 **30 天**(`TOMBSTONE_TTL_MS`),由**独立的定时任务**
  `TombstonePurger` 按 `TOMBSTONE_PURGE_INTERVAL_MS`(默认 5 分钟,`<=0` 关闭)清理;
  每轮打结构化日志(`event: "tombstone_purge"`)并计入 `ordo_tombstones_purged_total`
  与 `ordo_tombstone_purge_runs_total{result}`。失败只记 `warn` 并在下一周期重试,不影响请求路径。

---

## 8. 安全清单(契约 §9)

- [ ] 生产环境 `JWT_SECRET` 为 32 字节以上随机值,不写入镜像与仓库。
- [ ] 前置反向代理启用 TLS 1.2+(HTTP → HTTPS 跳转),WS 走 WSS。
- [ ] 数据库开启静态加密(磁盘/卷级),`entities.payload` 不含口令。
- [ ] 口令哈希:`argon2id` 优先;若目标平台无 argon2 预编译产物则自动降级 `scrypt`,启动横幅会打印实际算法。
- [ ] refresh token 仅存 SHA-256 哈希,轮换失效;重放会撤销全部会话。
- [ ] 不采集通讯录/位置;日历事件不上传(客户端本地读取)。
- [ ] 日志不打印 token、口令、备注正文。
