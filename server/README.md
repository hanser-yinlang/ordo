# Ordo 后端(ordo-server)

Ordo(序)的 TypeScript 后端:同步协议、认证、实时通道与 Fastlane 提醒。
**唯一事实来源**:`../docs/03-数据模型与同步协议.md`(FROZEN v1,schemaVersion = 1)。

## 技术栈

TypeScript 5 + Node 20+ · Fastify 5 · PostgreSQL(`pg`,无库时自动降级内存仓储)· WebSocket(`@fastify/websocket`)·
`zod` 校验 · `argon2`/`scrypt` 口令哈希 · `jsonwebtoken`(HS256)· 测试 `node:test` + `tsx` · 打包 `tsc`。

## 快速开始

```bash
pnpm install
pnpm test           # 129 个测试:内存仓储 + pg-mem 真实 SQL + 真实 HTTP/WS 端到端
pnpm run build      # tsc → dist/
pnpm start          # node dist/index.js(未配 DATABASE_URL 时用内存仓储)

# 开发模式(热重载)
pnpm dev
```

启动后:

```bash
curl -s http://127.0.0.1:8080/v1/health
# {"status":"ok","version":"1.0.0","serverTime":…,"schemaVersion":1,"storage":"memory"}

curl -s http://127.0.0.1:8080/metrics | head -20     # Prometheus 文本指标
```

带 PostgreSQL:

```bash
cp .env.example .env      # 填 DATABASE_URL / JWT_SECRET
pnpm migrate              # 建表(001_init.sql)+ 列类型升级(002_device_id_text.sql)
pnpm start
```

## 目录结构

```
src/
├── config/           环境变量与限制(契约 §7.4 / §8 / §9)
├── domain/           领域层(契约 §2–§6 的参考实现)
│   ├── model.ts      实体类型 + zod schema(字段与 §2 逐字一致;Heading 为顶层实体,Project 不含 headings)
│   ├── normalize.ts  §3 字段默认值与不变量
│   ├── lists.ts      §4 派生清单查询
│   ├── nlp.ts        §5 中文自然语言解析
│   ├── repeat.ts     §6 重复规则引擎
│   ├── time.ts       本地时间串 ↔ epoch millis
│   └── errors.ts     错误码 → HTTP 状态码
├── repo/             仓储层(同一接口,两种实现)
│   ├── types.ts      Repository 接口
│   ├── memory.ts     MemoryRepository
│   ├── pg.ts         PgRepository
│   ├── migrate.ts    SQL 迁移执行器
│   └── migrations/   001_init.sql(契约 §8 表结构)· 002_device_id_text.sql(deviceId 列 uuid → text)
│                     · 003_guest_accounts.sql(游客:users.is_guest + email 可空)
├── services/
│   ├── auth.ts       注册/登录/**游客**/**游客升级**/刷新轮换/登出/JWT 校验
│   ├── sync.ts       §7 同步核心(push/pull/snapshot + 6 条合并规则)
│   ├── realtime.ts   WS 连接管理与广播
│   ├── reminders.ts  Fastlane:每 1 秒扫描未来 60 秒到期
│   ├── tombstone-purger.ts  独立的墓碑清理定时任务(周期可配置)
│   ├── password.ts   argon2id(不可用时降级 scrypt)
│   └── rate-limit.ts 内存令牌桶(10 req/s)
├── observability/
│   ├── metrics.ts    无依赖的 Prometheus 指标注册表
│   └── logging.ts    结构化 JSON 日志 + 脱敏(绝不打印 token/口令/备注)
├── routes/           HTTP 路由 + 统一错误映射 + /metrics 运维端点
├── ws/index.ts       WS 协议(hello/ops/reminder/ping/ack/subscribe)
├── app.ts            应用装配(测试复用,不监听端口)
└── index.ts          启动入口(优雅停机,启动清理任务)
test/                 node:test 测试
├── helpers.ts        内存仓储夹具 + 真实 HTTP/WS 服务夹具 + Prometheus 解析
├── pg-helpers.ts     pg-mem 夹具(真实执行迁移)
├── auth/sync/reminders/limits/domain.test.ts   既有单元与接口测试
├── guest.test.ts     契约 §7.6 游客登录 / 数据隔离 / 升级(12 用例)
├── pg.test.ts        PgRepository × pg-mem(真实 SQL)
├── e2e.test.ts       协议级端到端(真实 HTTP + WS)
└── observability.test.ts  /metrics、日志脱敏、墓碑清理任务
docs/API.md           端点、示例、错误码表
docs/DEPLOY.md        部署、环境变量、迁移、健康检查、备份
```

## 端点一览

| 方法 | 路径 | 说明 | 测试 |
|---|---|---|---|
| GET | `/v1/health` | 健康检查 | `auth.test.ts` / `e2e.test.ts` |
| GET | `/v1/version` | 版本(附加) | — |
| GET | `/metrics` | **Prometheus 文本指标**(附加) | `observability.test.ts` |
| GET | `/v1/metrics` | 同上(别名) | `observability.test.ts` |
| GET | `/v1/ops/status` | 运维自检:降级状态 / WS 连接数 / 清理任务(附加) | `e2e.test.ts` |
| POST | `/v1/auth/register` | 注册 | `auth.test.ts` / `e2e.test.ts` |
| POST | `/v1/auth/guest` | **游客登录**(建匿名账号,数据同样入库同步;契约 §7.6.2) | `guest.test.ts` / `e2e.test.ts` |
| POST | `/v1/auth/upgrade` | **游客升级为正式账号**(userId 与数据不变;契约 §7.6.2) | `guest.test.ts` / `e2e.test.ts` |
| POST | `/v1/auth/login` | 登录(游客调用一律 `AUTH_INVALID_CREDENTIALS`) | `auth.test.ts` / `e2e.test.ts` |
| POST | `/v1/auth/refresh` | 刷新(轮换,响应带 `user.isGuest`) | `auth.test.ts` / `e2e.test.ts` |
| POST | `/v1/auth/logout` | 登出 | `auth.test.ts` / `e2e.test.ts` |
| POST | `/v1/devices/register` | 设备注册/更新在线 | `auth.test.ts` / `e2e.test.ts` |
| DELETE | `/v1/account` | 删除账号与全部数据(附加) | `auth.test.ts` / `e2e.test.ts` |
| GET | `/v1/sync/snapshot` | 全量快照 | `sync.test.ts` / `e2e.test.ts` |
| POST | `/v1/sync/push` | 推送 + 捎带拉取 | `sync.test.ts` / `limits.test.ts` / `e2e.test.ts` |
| GET | `/v1/sync/pull` | 增量拉取(分页) | `sync.test.ts` / `limits.test.ts` / `e2e.test.ts` |
| WS | `/v1/ws?token=` | 实时通道 + Fastlane 提醒 | `reminders.test.ts` / `e2e.test.ts` |

## PgRepository 验证(pg-mem 真实执行 SQL)

本机(或 CI)不提供 PostgreSQL 时,`PgRepository` 也不能只靠 mock 验证,因此第一层验证是:
用 **`pg-mem`**(纯 JS 的内存 Postgres 实现,无原生扩展,`devDependencies`)**真实执行**
`src/repo/migrations/*.sql`(001 建表 + 002 列类型升级),再让真正的 `PgRepository` 代码跑完整
push/pull/snapshot/LWW/墓碑流程。

```bash
node --import tsx --test test/pg.test.ts    # 30 个用例
```

测试夹具(`test/pg-helpers.ts`)把 pg-mem 的 `adapters.createPg().Pool` 通过
`PgRepository` 的第 4 个构造参数注入,因此**被测代码是与生产完全相同的那一份**,
没有为测试改写任何仓储逻辑:

```ts
const repo = new PgRepository('postgres://pg-mem.local/ordo', 2, [MIGRATIONS_DIR], pool);
```

### 被真实执行的 SQL(逐条覆盖)

| 类别 | 语句 | 覆盖用例 |
|---|---|---|
| 迁移 | `001_init.sql` 全部 12 条 DDL(7 张表 + 5 个索引,含**部分索引** `where fired = false`)、`002_device_id_text.sql` | 建表、索引重放、幂等、迁移版本 `[1,2]` |
| 用户 | `insert ... returning *`、`select ... where email = $1`、`update ... set password_hash` | 注册/查找/改密 |
| 设备 | `insert ... on conflict (id) do update set ... excluded.*` | upsert 不产生第二行、`created_at` 不被覆盖、`dev_` 形态 id 可写 |
| 令牌 | `insert`、`update ... set revoked_at = coalesce(revoked_at, $2)`、`delete ... where expires_at < $1` | 轮换链、撤销幂等、过期清理 |
| 实体 | `insert ... on conflict (user_id, entity, entity_id) do update`、`select ... where user_id = $1 [and entity = $2]`、`delete ... where deleted = true and updated_at < $1` | putEntity/LWW、两种 list 分支、墓碑清理 |
| op 日志 | `insert ... on conflict (user_id, op_id) do nothing`、`select ... where server_seq > $1 order by server_seq asc limit $2`、`op_id = any($2::text[])`、`select max(server_seq)` | 幂等、**分页不重不漏**、seq 单调、空表返回 0 |
| 提醒 | `insert ... on conflict (user_id, todo_id) do update` + `case when`、`update ... where id = $1 and fired = false` | 唯一约束、**只投一次**、改时刻后重新投递 |

`serverSeq` 单调性、`op_id` 唯一约束(`23505`)、外键级联删除、jsonb 中文/emoji 往返
全部由**数据库行为**断言,而不是靠 mock。

### 与生产 PostgreSQL 的差异(逐条说明)

| # | 差异 | 影响 | 生产是否安全 |
|---|---|---|---|
| 1 | **事务内 DDL 的静态 AST 覆盖检查**:pg-mem 在事务里执行 `create table ... (version int primary key, ...)` 会把这些内联列约束报成 "planner 未读取的 AST 部分" 并抛 `NotSupported` | 迁移执行器 `runMigrations` 用 `begin/commit` 包住 DDL,所以 `PgRepository.init()` 在 pg-mem 上会失败 | **安全**。夹具用 `newDb({ noAstCoverageCheck: true })` 关闭这项**静态检查**;约束本身是运行时强制的,测试里用重复主键插入验证过 `23505`。迁移 SQL 不为测试改写。 |
| 2 | **不支持事务回滚**:`begin` → 写入 → `rollback` 后数据仍在(已用探针确认) | `runMigrations` / `appendOps` 的 `rollback` 分支无法在 pg-mem 上验证"失败后不留残留" | **安全**。真实 Postgres 回滚是标准行为;测试只断言"错误被抛出",回滚语义由真实 Postgres 复跑覆盖(见下节)。 |
| 3 | **`ON CONFLICT DO UPDATE` 的 SET 求值顺序**:pg-mem 让后面的 SET 表达式读到**前面刚赋的值**;Postgres 语义是所有 SET 表达式都基于**旧行**求值([INSERT 文档](https://www.postgresql.org/docs/16/sql-insert.html):"SET 和 WHERE 子句可以用表名访问已存在的行") | 若先写 `at = excluded.at` 再写 `fired = case when reminders.at = excluded.at ...`,pg-mem 下 `fired` 永不复位 → 改过时间的提醒再也不会投递 | **安全**。已把 `fired` 放到 SET 最前面(Postgres 下语义完全不变),并加了回归用例锁死顺序。这是测试**真实抓到的一个隐患**,不是绕过。 |
| 4 | **`insert ... on conflict do nothing returning *` 在冲突时把冲突行返回**(Postgres 返回 0 行) | `appendOps` 无法用 `returning` 判断"本次到底写入了哪些 op",幂等语义会被悄悄破坏 | **安全**。`appendOps` 改为两阶段(插入 → 回查 opId,排除插入前已存在的),与 `returning *` 等价,只是多一次 SELECT;并有"混合批次只返回新写入那条"的用例。 |
| 5 | **没有索引目录**:`pg_indexes` / `pg_index` 不存在或为空,`pg_class` 恒空,`table.indexHandlers` 也是空的;`EXPLAIN` / `pg_typeof` 未实现 | 无法在 pg-mem 里 `select * from pg_indexes` 或看执行计划 | **安全**。索引验证改为两步:① 解析迁移的 `create index` 声明,断言**索引名、列顺序、部分索引 where 子句**与契约一致;② 把每条 DDL **换个名字逐条真实重放**。索引目录与执行计划由真实 Postgres 复跑覆盖。 |
| 6 | **`bigint` 在 `information_schema` 里报告为 `integer`**;`unique` 的文本比较对大小写不敏感(pg-mem 默认 `nocase` 排序规则) | 元数据层面与生产不一致 | **安全**。读写往返保持 `Date.now()` 级别精度(已断言);仓储在 SQL 之前就做了 `email.toLowerCase()`。但要注意:**pg-mem 的类型检查偏宽松**,真实 Postgres 才会拦住类型错误 —— 见"真实 PostgreSQL 抓到的生产级 Bug"。 |
| 7 | **`bigserial` 在冲突时也会消耗序列值**(Postgres 的 `DO NOTHING` 同样会消耗:`nextval` 在冲突判定前已求值) | 序列号出现空洞 | **安全**。契约只要求 `server_seq` **单调**,不要求连续;测试断言的是严格递增与分页不重不漏。 |
| 8 | **不实现 plpgsql**:`002_device_id_text.sql` 用 `DO $$ ... $$` 做条件 DDL,pg-mem 的 `DO` 块需要注册"语言编译器" | 002 里的条件逻辑在 pg-mem 上不执行 | **安全**。夹具注册 **no-op plpgsql 编译器**让 `DO` 块通过;因为夹具的 001 已建出 `text` 列,"什么都不做"恰好等于真实 Postgres 上该迁移的正确行为(no-op 分支)。真正的 ALTER 语义由真实 Postgres 复跑覆盖(第 9 节)。 |

### 用真实 PostgreSQL 16 复跑(两选一)

两种方式都会跑同一份迁移与同一套断言,建议在合并前至少跑一次。

**方式 A:Docker(最快)**

```bash
cd ordo/server

# 1. 起一个一次性的 Postgres 16
docker run --rm -d --name ordo-pg -p 55432:5432 \
  -e POSTGRES_PASSWORD=secret -e POSTGRES_USER=ordo -e POSTGRES_DB=ordo \
  postgres:16-alpine

# 2. 等它就绪
until docker exec ordo-pg pg_isready -U ordo -d ordo; do sleep 1; done

# 3. 指向真实库:一条命令跑完全部真库断言
export DATABASE_URL="postgres://ordo:secret@127.0.0.1:55432/ordo"
pnpm install
node --import tsx scripts/pg-real-verify.mts

# 4. 人工核对索引目录(方式 B 也适用)
psql "$DATABASE_URL" -c "
  select indexname, indexdef from pg_indexes
  where schemaname = 'public' order by indexname;"
```

**方式 B:裸机 / Windows(已装 PostgreSQL 16)**

```bash
# macOS:  brew install postgresql@16 && brew services start postgresql@16
# Ubuntu: sudo apt install postgresql-16 && sudo systemctl start postgresql
# Windows: 安装 EDB 安装包后,用 services.msc 启动 postgresql-x64-16

createuser -s ordo || true
createdb -O ordo ordo
psql -d ordo -c "alter user ordo password 'secret';"

cd ordo/server
export DATABASE_URL="postgres://ordo:secret@127.0.0.1:5432/ordo"
pnpm install && pnpm migrate
node --import tsx scripts/pg-real-verify.mts
```

**两者都要人工确认的点**(pg-mem 覆盖不到的部分):

1. `pg_indexes` 里存在 `devices_user_idx`、`refresh_tokens_user_idx`、`entities_user_seq_idx`、
   `ops_user_seq_idx`、`reminders_due_idx`,其中 `reminders_due_idx` 的 `indexdef` 必须包含
   `WHERE (fired = false)`。
2. `\d ops` 里 `server_seq` 的类型是 `bigint` 且默认值为 `nextval('ops_server_seq_seq')`。
3. 手工制造一次失败迁移,确认 `schema_migrations` 没有留下版本行(`runMigrations` 的事务回滚)。
4. `appendOps` 批量中夹一条不存在的 `user_id`,确认 `ops` 行数**没有增加**(事务回滚)。
5. `insert ... on conflict (user_id, op_id) do nothing returning *` 在冲突时返回 **0 行**
   (pg-mem 会返回冲突行,这是差异 #4 的根源,`appendOps` 已改为不依赖该行为)。

> 以上 5 点已全部脚本化,由 `scripts/pg-real-verify.mts` 自动断言(见下节)。

### 无管理员权限装一个本地 PostgreSQL(Windows)

本机是**非管理员**账号,EDB 官方安装包(winget `PostgreSQL.PostgreSQL.16`)需要 UAC 并会注册
Windows 服务,因此改用**官方 PostgreSQL 二进制 + 本地数据目录**(不装服务、不改 PATH、
不写进 `package.json`,只落在 `%LOCALAPPDATA%\ordo-pg`):

```powershell
# 1) 取官方 16.14 二进制(npm 上的 @embedded-postgres/windows-x64 就是 EDB 二进制打包)
$v='16.14.0-beta.17'; $root="$env:LOCALAPPDATA\ordo-pg"; $dest="$root\pg-$v"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Invoke-WebRequest "https://registry.npmjs.org/@embedded-postgres/windows-x64/-/windows-x64-$v.tgz" -OutFile "$root\pg.tgz"
tar -xzf "$root\pg.tgz" -C $dest --strip-components=1     # 二进制在 $dest\native\bin

# 2) 初始化数据目录(数据目录必须只允许当前用户访问)
$bin="$dest\native\bin"; $data="$root\data16"
New-Item -ItemType Directory -Force -Path $data | Out-Null
icacls $data /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" /T /Q | Out-Null
Set-Content "$root\pw.txt" 'ordo_secret' -Encoding ascii -NoNewline
& "$bin\initdb.exe" -D $data -U ordo --pwfile="$root\pw.txt" -E UTF8 --locale=C -A scram-sha-256
Remove-Item "$root\pw.txt"

# 3) 启动(端口 55432,只监听回环)
& "$bin\pg_ctl.exe" -D $data -l "$root\server16.log" -o "-p 55432 -h 127.0.0.1" -w -t 60 start
& "$bin\pg_ctl.exe" -D $data status        # 查看状态
& "$bin\pg_ctl.exe" -D $data -m fast stop  # 停止
```

- 建库用项目自带的 `pg` 驱动即可(这个 bin-only 发行版**没有 `psql` / `createdb`**):
  `create database ordo with encoding 'UTF8' template template0`。
- ⚠️ **不要**对整个解压目录执行 `icacls /inheritance:r /grant:r <user>`:那会把继承来的
  执行权限一起剥掉,导致 `initdb.exe` 直接 "Access is denied"。要恢复用
  `icacls <dir> /reset /T`。只有**数据目录**需要独占 ACL。
- ⚠️ **`pg_ctl start` 的进程归属**:在 PowerShell 里直接 `pg_ctl start` 时,postgres 会成为
  该 shell 子进程(job object 成员);一旦这个 shell 结束/被中断,postgres 会**一起被终止**
  (实测:杀掉持有它的 shell,数据库立刻退出)。要让它长期存活,二选一:
  1. **单独开一个终端**跑 `pg_ctl start`,保持该窗口不关;或
  2. 用一次性计划任务把它"解绑"(本仓库就是这么做的,起来后即可删掉任务):

     ```powershell
     # start-pg.bat 内容:pg_ctl.exe -D <data> -l <log> -o "-p 55432 -h 127.0.0.1" start
     schtasks /create /tn "ordo-pg-start" /tr "<绝对路径>\start-pg.bat" /sc once /st 23:59 /f
     schtasks /run    /tn "ordo-pg-start"
     schtasks /delete /tn "ordo-pg-start" /f      # 起来后即可删除
     ```

### 对真实 PostgreSQL 16 复跑(本仓库已执行)

装好库之后一条命令即可把所有人工确认点变成自动断言:

```bash
cd ordo/server
export DATABASE_URL="postgres://ordo:ordo_secret@127.0.0.1:55432/ordo"
node --import tsx scripts/pg-real-verify.mts
# => 真实 PostgreSQL 验证:94 通过 / 0 失败
```

脚本会从干净 schema 开始重跑迁移,覆盖:索引目录与部分索引谓词、列类型
(`bigint` / `jsonb` / `text`)、失败迁移的事务回滚、`appendOps` 的批量回滚、
`on conflict do nothing returning *` 的 0 行语义、完整 push/pull/snapshot/LWW/墓碑/提醒流程、
级联删除、**迁移 003(游客:is_guest 列 + email 可空 + 多个 NULL 共存 + 幂等重放)**、
**游客在真库上的端到端行为(建号、按 user_id 隔离、升级不改 userId)**、
**迁移 002 在"旧库形状"上的升级路径**,以及 `EXPLAIN` 走索引。
结束时清空 `public` schema,不残留验证数据(设 `ORDO_KEEP_SCHEMA=1` 可保留)。

另外把整个服务指向真库跑一遍冒烟(这一步才会暴露类型级问题,见下节):

```powershell
powershell -File scripts/verify-smoke.ps1 -DatabaseUrl "postgres://ordo:ordo_secret@127.0.0.1:55432/ordo"
# => storage=postgres,冒烟 10/10 全部通过

# 游客全流程(契约 §7.6):建号 → push/pull → 隔离 → 升级 → 409/400 错误分支
powershell -NoProfile -File scripts/verify-guest-smoke.ps1 -DatabaseUrl "postgres://ordo:ordo_secret@127.0.0.1:55432/ordo"
# => guest flow: 24 passed / 0 failed
```

### 真实 PostgreSQL 抓到的生产级 Bug(已修 + 已补迁移)

`scripts/verify-smoke.ps1 -DatabaseUrl ...` 首次运行时,**注册直接 500**:

```
err: invalid input syntax for type uuid: "dev_smoke_f0307630"   code=22P02
```

根因:`001_init.sql` 里 `devices.id` 与 `refresh_tokens.device_id` 写成了 `uuid`,而契约
§7.2 的示例是 **`"deviceId":"dev_7f3a..."`** —— 客户端设备 id 是**不透明短串,不是 uuid**
(契约 §7.4 还规定用 `X-Ordo-Device: <deviceId>` 传它)。

**影响面是四端全部**:四端生成的 deviceId 都是 `dev_<opaque>` 形态 ——
iOS `newDeviceId()` → `dev_` + uuid 去连字符前 10 位;Harmony `newIdWithPrefix('dev')` →
`dev_` + 16 进制 20 位;Android/Windows 走共享核心 `OrdoEngine` → `dev_` + ULID 后 10 位小写。
所以**任何按契约实现的客户端都注册不上**,服务端也无法单方面兜底(要么改列类型,
要么让所有客户端改用 uuid,后者违反契约示例)。`ops.device_id` 本来就是 `text`,三张表还不一致。

修复:`001_init.sql` 里两列改为 `text`(全新库直接正确),并新增
**`002_device_id_text.sql`** 让已经建过表的库自动升级。

为什么之前没发现:**内存仓储不校验列类型;pg-mem 的类型检查也偏宽松**(差异 #6 已提示过)。
只有真实 PostgreSQL 会执行类型检查与 ALTER —— 这正是"必须对真库复跑一次"的价值。

回归防护已补三处:

- `test/pg.test.ts` → `deviceId 相关列是 text 而不是 uuid(契约 §7.2 的 dev_xxx 形态)`:
  从 `information_schema.columns` 断言三张表的列类型,并用 `dev_7f3a9c2e` 真写一条
  (含 `refresh_tokens` 外键)。
- `test/pg.test.ts` → 迁移用例断言 `schema_migrations` 同时记录 `[1, 2]`,且重复 `init()` 幂等。
- `scripts/pg-real-verify.mts` 第 0 节(真库列类型 + 真写 `dev_...`)与**第 9 节(002 的旧库升级路径)**。

### 迁移 002:`002_device_id_text.sql`(旧库升级)

对**全新库**是 no-op(001 已建出 `text`);对**跑过旧版 001 的库**执行真正的类型变更。整体幂等。

⚠️ 这里有一个容易踩的坑:`devices.id` 被 `refresh_tokens.device_id` 的外键引用,
而 **PostgreSQL 不允许直接改变被引用列的类型**(`foreign key constraint ... cannot be implemented`)。
所以顺序必须是:

1. 删掉 `refresh_tokens → devices` 的外键(并记下它的 `ON DELETE` 行为)
2. **先**改引用列 `refresh_tokens.device_id type text`
3. **再**改被引用列 `devices.id type text`
4. 按 `text` 重建外键,保留原 `on delete set null`

整个过程包在**一个 `DO` 块**里(失败则整体回滚);末尾再用一个 `DO` 块自检三列都必须是 `text`,
否则 `raise exception` 让迁移回滚。第一版就是因为在同一块里先改 `devices.id` 才失败的 ——
只有真实 PostgreSQL 上跑一次才暴露出来。

升级路径已在真实库上自动验证(`scripts/pg-real-verify.mts` 第 9 节会造一个"旧库形状"的
临时库:`uuid` 列 + 外键 + 一条旧数据,再跑 002):

```
PASS  旧库:devices.id 起初是 uuid
PASS  002 后 devices.id 变成 text / refresh_tokens.device_id 变成 text
PASS  类型转换不丢旧数据
PASS  外键仍是 on delete set null / 外键仍然生效(未知 device_id 被拒)
PASS  升级后可写入契约形态 dev_ id(旧 uuid 列做不到)
PASS  002 可重复执行(幂等) / 幂等重跑后列类型仍为 text / 外键仍只有一个
```

> 已有库直接 `pnpm migrate` 即可自动升级(迁移器按 `schema_migrations` 跳过已应用的版本)。
> 应急用的等价裸 SQL 顺序:
> ```sql
> alter table refresh_tokens drop constraint refresh_tokens_device_id_fkey;
> alter table refresh_tokens alter column device_id type text;
> alter table devices alter column id type text;
> alter table refresh_tokens add constraint refresh_tokens_device_id_fkey
>   foreign key (device_id) references devices (id) on delete set null;
> ```

### `scripts/smoke.mjs` 与 `test/e2e.test.ts` 的关系

- `scripts/smoke.mjs`:对**已在运行的服务**做冒烟(`node scripts/smoke.mjs [baseUrl]`),
  适合部署后手工验收,失败即 `exit code 1`。
- `test/e2e.test.ts`:同一套覆盖面,但**自己起真实 HTTP + WS 服务**(随机端口,进程内),
  断言的是成功路径 **+ 失败路径**(401/409/413/429/4401),可回归、可 CI。
  两者互补:前者验证"真实部署",后者验证"协议行为不回归"。

## 可观测性与运维

### `GET /metrics`(Prometheus 文本,version=0.0.4)

无第三方依赖的指标注册表(`src/observability/metrics.ts`),`GET /metrics` 与
`GET /v1/metrics` 内容相同。

| 指标 | 类型 | 含义 |
|---|---|---|
| `ordo_sync_ops_pushed_total` | counter | 成功落库的 op 数(**ops 速率**的分子) |
| `ordo_sync_ops_rejected_total{reason}` | counter | 被拒 op 数,`reason` ∈ `stale` / `tombstoned` / `completion_immutable` / `project_incomplete` / `invalid` / `duplicate` |
| `ordo_sync_push_requests_total{result}` | counter | push 请求数(`ok` / `partial` / `noop`) |
| `ordo_sync_pull_requests_total{hasMore}` / `ordo_sync_pull_ops_total` | counter | pull 分页情况与实际返回条数 |
| `ordo_sync_seq_gap_total{endpoint}` | counter | `SYNC_SEQ_GAP` 次数(客户端状态不对的信号) |
| `ordo_sync_op_too_large_total` | counter | 单 op 超 256 KB 次数 |
| `ordo_ws_connections` | gauge | **当前 WS 连接数**(实时求值,非累计) |
| `ordo_ws_connections_opened_total` / `_closed_total` / `_rejected_total{reason}` | counter | WS 连接建立 / 关闭 / 鉴权失败 |
| `ordo_ws_messages_sent_total{type}` | counter | 下发消息数(`hello` / `ops` / `reminder` / `pong`) |
| `ordo_reminders_delivered_total` | counter | **Fastlane 提醒投递数** |
| `ordo_reminder_scans_total{result}` | counter | 扫描轮次与失败次数 |
| `ordo_reminders_pending` | gauge | 1 小时内待投递的提醒条数 |
| `ordo_tombstones_purged_total` / `ordo_tombstone_purge_runs_total{result}` / `_errors_total` | counter | 墓碑清理删除行数 / 轮次 / 失败次数 |
| `ordo_rate_limited_total` / `ordo_rate_limit_checks_total{result}` | counter | **限流命中数** / 限流判断次数 |
| `ordo_http_requests_total{method,status,route}` | counter | HTTP 请求数(`route` 模板化,uuid 替换为 `:id`,防高基数) |
| `ordo_storage_degraded` | gauge | **仓储降级状态**:`1` = 已降级为内存仓储,`0` = 正常 |
| `ordo_storage_info{storage}` | gauge | 存储类型信息,值恒为 1 |
| `ordo_uptime_seconds` | gauge | 进程启动至今秒数 |

`GET /v1/ops/status` 是给人看的轻量自检(降级状态、WS 连接数、清理任务轮次与周期)。

### 结构化日志与脱敏

日志是**每行一个 JSON 对象**(pino),脱敏用三层防御(`src/observability/logging.ts`):

1. **不记录请求体**:`req` serializer 只输出 `{ method, url, id }`,完全不碰 headers 与 body。
2. **剥离 URL 查询串**:WS 握手把 access token 放在 `?token=` 里,直接记 URL 会泄漏凭据,
   因此 `redactUrl()` 只保留 pathname(`/v1/ws?token=…` → `/v1/ws`)。
3. **pino `redact`**:`authorization` / `cookie` / `accessToken` / `refreshToken` / `token` /
   `tokenHash` / `password` / `passwordHash` / `note` / `payload.note` / `body.ops[*].payload.note`
   等路径替换为 `[Redacted]`;`err` serializer 只序列化 `type/message/code/stack`。

`test/observability.test.ts` 里有**断言**把这些锁死:用内存流采集真实日志后,逐条检查
是合法 JSON 行,并断言日志全文**不包含**注册口令、错误口令、access token、
`refreshToken`、`authorization`、备注正文(`CONFIDENTIAL-NOTE-BODY-正文-DO-NOT-LOG`),
以及 `?token=` 查询串。

**stdout 是纯 JSON 行**:启动横幅与仓储降级提示走 **stderr**(结构化日志里有等价的
`event: "started"` / `event: "storage"` 事件),这样日志采集器可以直接按行解析 stdout。
`scripts/verify-json-logs.ps1` 会自动验证这一点(零非 JSON 行 + 端口释放)。

> ⚠️ 写日志时注意:`note` 是**受保护字段名**(待办备注正文),用它当普通字段会被整条替换成
> `[Redacted]`(本项目就踩过一次:仓储提示信息用了 `note`,结果被吃掉了)。要记描述性文本请用
> `detail` / `message` 之类的字段名。

```bash
# 手工看一眼脱敏效果
LOG_LEVEL=info pnpm dev
curl -s "http://127.0.0.1:8080/v1/health?token=SHOULD-NOT-APPEAR" >/dev/null
# 日志里应只有 "url":"/v1/health"
```

### 墓碑清理定时任务

契约 §3 要求删除墓碑保留 30 天后可回收。清理**不再挂在 push 路径上**(旧实现在 push 里节流触发,
导致"没有推送的实例永远不清理",且清理耗时进入 push 延迟),而是独立定时任务
`src/services/tombstone-purger.ts`:

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `TOMBSTONE_PURGE_INTERVAL_MS` | `300000`(5 分钟) | 清理周期;`<=0` 表示关闭定时任务 |
| `TOMBSTONE_TTL_MS` | `2592000000`(30 天) | 墓碑保留时长,清理 `deleted = true and updated_at < now - TTL` |

每轮输出结构化日志(`event: "tombstone_purge"`,带 `purged` / `olderThanMs` / `ttlMs` / `durationMs`)
与指标;单轮失败只记 `warn`(`event: "tombstone_purge_failed"`)并计
`ordo_tombstone_purge_errors_total`,不抛出,下一周期重试;重入时跳过本轮并记
`event: "tombstone_purge_skipped"`。优雅停机时 `purger.stop()`。

## 契约对齐要点

- **幂等**:`ops(user_id, op_id)` 唯一;重复推送返回 `accepted[].duplicate = true`,不产生新 op。
- **LWW**:服务端 `updatedAt` 恒等于 `op.clientTs`;`clientTs < updatedAt` → `rejected: stale`。
- **完成不可回滚**:本地 `done/canceled` 时拒绝任何 `open` 版本(比契约措辞更严格,见 `docs/API.md` §5)。
- **标签并集**:即使 op 判负,标签仍并入,并补一条 `srv:tags:<opId>` 合成 op 供其它设备收敛。
- **checklist 合并**:按 `id` 合并,两端都有的取胜者,仅一端有的保留。
- **墓碑**:删除写 `deleted=true` + `updatedAt`,保留 30 天;旧 op 无法复活实体。
- **项目完成硬约束**:子待办未全部结束或标题未全部归档时,`status=done` 被拒(`project_incomplete`)。
- **Heading 是顶层实体**(契约 §2.2 修订版):Project payload 不含 `headings`;快照的 `headings` 只来自 heading 实体,按 `order` 排序。
- **serverSeq**:`ops.server_seq`(bigserial)保证每用户单调递增;`entities.server_seq` 记录该实体最后一次变更的 seq。
- **deviceId**:客户端生成的不透明短串(契约 §7.2 示例 `dev_7f3a...`),服务端按 `text` 存储;`devices.id` / `refresh_tokens.device_id` / `ops.device_id` 三处类型必须一致。

## 测试

```bash
pnpm test        # node --import tsx --test test/*.test.ts
```

当前:**129 个用例 / 20 个套件,全部通过**(`pnpm test` 末尾会打印 `tests 129 / pass 129 / fail 0`)。

| 文件 | 用例数 | 覆盖 |
|---|---|---|
| `test/auth.test.ts` | 12 | 注册 / 重复邮箱 / 弱口令 / 登录失败 / 刷新轮换与重放 / 401 / 过期令牌 / schema 版本 / 登出 / 删号 |
| `test/guest.test.ts` | **12**(新增文件) | 契约 §7.6:游客注册与落库 / 响应同构 / push·pull·snapshot 入库 / **两游客互相看不到对方数据** / 升级后 userId 与数据不变 / 升级后旧 refreshToken 仍有效 / 重复升级 409 与 400 `not_guest` / 游客调 login 被拒 / 正式账号 `isGuest=false` / 边界(无令牌、弱口令、坏邮箱)/ 升级后删号级联 |
| `test/sync.test.ts` | 16 | 幂等 / LWW / stale / 完成不可回滚 / 标签并集 / checklist 合并 / 墓碑 / 捎带拉取 / 分页 / SEQ_GAP / §3 不变量 / 项目完成硬约束 / heading 顶层实体 |
| `test/reminders.test.ts` | 4 | WS 鉴权与 hello / 提醒到点下发且只发一次 / ops 广播 / 完成即移除索引 |
| `test/limits.test.ts` | 7 | 501 ops / 500 ops 边界 / 256 KB op / 请求体超限 / pull limit / 10 req/s 限流 |
| `test/domain.test.ts` | 22 | §3 不变量 / §4 派生清单 / §5 NLP / §6 重复规则 |
| `test/pg.test.ts` | **31**(30+1) | PgRepository × pg-mem:建表 / 索引重放 / **deviceId 列类型回归** / 迁移版本 `[1,2,3]` / **003 游客迁移的静态核对** / op_id 唯一约束 / serverSeq 单调 / pull 分页 / 墓碑不复活与清理 / 级联删除 / 提醒只投一次 / jsonb 中文往返 |
| `test/e2e.test.ts` | **21**(20+1) | 真实 HTTP + WS:注册→登录→push→捎带拉取→pull 分页→WS hello/ops→Fastlane 只投一次→401 刷新重放→限流 429→500 ops 与 256 KB 上限→SYNC_SEQ_GAP→**游客全流程(含真实 WS 与按用户隔离)**→运维端点 |
| `test/observability.test.ts` | 18 | /metrics 内容与取值 / Prometheus 文本格式与解析 / 日志 JSON 行与脱敏断言 / 墓碑清理任务(周期、日志、指标、错误处理) |
| `scripts/verify-*.ps1` | 5 个脚本 | 起真实服务跑冒烟 / 断言 stdout 纯 JSON / 断言清理任务按周期触发 / **游客全流程冒烟(新增)**(非 node:test) |
| `scripts/pg-real-verify.mts` | **94 项断言**(66+28) | **对真实 PostgreSQL 16 复跑**:索引目录 / 列类型 / 事务回滚 / RETURNING 语义 / 全流程 / **迁移 003(游客列 + email 可空 + 多个 NULL 共存 + 幂等重放)** / **真库游客端到端(建号、隔离、升级)** / 迁移 002 旧库升级 / EXPLAIN |

> 12 + 12 + 16 + 4 + 7 + 22 + 31 + 21 + 18 = **143 个 `it()`**,与 `pnpm test` 打印的 `tests 143` 完全一致
> (本机实测 `pass 143 / fail 0`)。本轮:新增 `test/guest.test.ts` **12** 个用例,`test/pg.test.ts`
> 与 `test/e2e.test.ts` 各 **+1**,基线 129 → **143**;`scripts/pg-real-verify.mts` 新增 **28** 项
> 真实 PostgreSQL 断言(66 → **94**)。

### 一键复现证据(三个 PowerShell 脚本)

这三个脚本会自动完成"起服务 → 断言 → 停服务 → 确认端口释放",可重复运行:

| 脚本 | 做什么 | 关键断言 |
|---|---|---|
| `scripts/verify-smoke.ps1` | 起服务 + `node scripts/smoke.mjs` + 抓 `/metrics` 与 `/v1/ops/status`;加 `-DatabaseUrl` 可指向真实 PostgreSQL | 冒烟 10 项全绿;退出码 0;端口释放 |
| `scripts/verify-json-logs.ps1` | 起服务、制造流量、停止 | **stdout 零非 JSON 行** + 日志行数 ≥5 + 启动横幅在 stderr + 端口释放 |
| `scripts/verify-purge.ps1` | 用 `TOMBSTONE_PURGE_INTERVAL_MS=200` 起服务,跑 1.5 秒 | 清理轮次 ≥3(实测 7),日志有 `event: "tombstone_purge"`,端口释放 |

```powershell
powershell -File scripts/verify-smoke.ps1
powershell -File scripts/verify-smoke.ps1 -DatabaseUrl "postgres://ordo:ordo_secret@127.0.0.1:55432/ordo"
powershell -File scripts/verify-json-logs.ps1
powershell -File scripts/verify-purge.ps1
```

> 三个脚本与 `tools/verify.ps1` 一样**刻意只用 ASCII**:Windows PowerShell 5.1 会把无 BOM 的
> UTF-8 `.ps1` 当 ANSI 解析,非 ASCII 字面量会在解析期被破坏。
> **同理:不要用 PowerShell 的 `Get-Content -Raw` + `Set-Content`(或 `[IO.File]::WriteAllText`
> 配合错误的编码推导)去改含中文的源文件** —— 会把 UTF-8 当 GBK 往返,造成**不可逆**损坏
> (本项目就踩过一次 `README.md`)。改中文文件请用编辑工具直接写 UTF-8。

## 已知取舍

- 限流为**单实例内存**令牌桶;多副本需换共享存储。
- `SERVER_SIDE_REPEAT` 默认关闭:重复实例由客户端生成(本地优先),服务端只提供 §6 参考实现与测试。
- 内存仓储用于开发/测试;生产必须配 `DATABASE_URL`,否则重启丢数据(启动横幅会提示)。
- 服务端不代做 NLP:`src/domain/nlp.ts` 是给四端对齐用的参考实现,并通过 `domain.test.ts` 与契约逐条校验。
- **PgRepository 的验证有两层**:① `pg-mem`(纯 JS、无原生扩展)真实执行迁移,让 `PgRepository`
  的每段 SQL 都跑到;② `scripts/pg-real-verify.mts` 对**真实 PostgreSQL 16** 复跑同一批断言 +
  `pg_indexes` / `EXPLAIN` / 事务回滚 / 迁移升级路径等 pg-mem 覆盖不到的部分。
  真实库这一层已经抓到过两个生产级问题(设备 id 列类型、迁移 002 的 ALTER 顺序),
  因此**合入前务必跑一次**。
- **`001_init.sql` 在开发期被修过一次**(`devices.id`、`refresh_tokens.device_id`:`uuid` → `text`),
  并用 `002_device_id_text.sql` 覆盖已建表的库。发版后应只新增迁移,不再改已发布的 `001`。
- 指标为**进程内累计值**,多副本各自暴露自己的一份;聚合交给 Prometheus。
- `/metrics` 未做鉴权(与 Prometheus 生态惯例一致,且不输出任何用户标识);若环境要求鉴权,
  在网关层限制即可。
- 本机 Node 为 v24,`engines` 仍声明 `>=20`:所有测试在 Node 20+ 均可运行(pg-mem 为纯 JS,
  不涉及原生扩展编译)。
