-- 迁移 004:邮箱验证码 —— 契约 §7.6.5 / §8 / §9(v1.3 新增「邮箱验证码登录」)
-- 迁移版本:004 · schemaVersion = 1(表结构增量,不改变 §1 的 schemaVersion)
--
-- 契约 §8 的表清单里给出的是:`email_codes(email, code_hash, attempts, consumed_at, created_at, expires_at)`,
-- 索引:`email_codes(email, created_at desc)`。本迁移逐字落地这张表。
--
-- ⚠️ 三个必须写清楚的约束(违反任何一条都会让功能或安全失效):
--   ① **只存哈希,不存明文**:`code_hash` = HMAC-SHA256(pepper, email + ':' + code)。
--      6 位数字只有 1e6 种可能,裸 SHA-256 可被离线爆破,所以 pepper 必须来自
--      `ORDO_CODE_PEPPER`(生产必填,开发回退 JWT_SECRET)。见 services/auth.ts。
--   ② **一次性消费**:`consumed_at` 由 `update ... where consumed_at is null` 原子置位,
--      同一验证码不可复用(仓储方法 consumeEmailCode)。
--   ③ **同码最多试 5 次**:`attempts` 由 `attempts = attempts + 1` 原子自增,超限即作废。
--
-- 幂等性:可执行语句全部幂等(`create table if not exists` / `create index if not exists`),
-- 重复执行不报错。迁移器 `runMigrations` 用 begin/commit 包住整个文件,失败则整体回滚。
--
-- ── 写法说明:本迁移**不含任何 DO 块**,全部是纯标准 DDL ─────────────────────
-- `test/pg-helpers.ts` 给 pg-mem 注册的是 **no-op plpgsql 编译器**:DO 块在 pg-mem 上
-- "能通过但什么都不做"。因此凡是"pg-mem 与真库都必须真的存在"的东西(建表、建索引),
-- 一律写在顶层**纯标准 DDL** 里 —— 两种实现都会真的执行它。
-- 002 / 003 里的 DO 块只用于 pg-mem 跑不了的**条件 DDL**(alter column drop not null 等),
-- 那类语句在真库上的语义由 scripts/pg-real-verify.mts 断言。
-- 本迁移建表 + 建索引都是无条件 DDL,不需要条件判断,也就不需要 DO 块、不依赖 plpgsql:
-- 保持"纯标准 DDL"能让 pg-mem 侧真的拥有 email_codes 表与索引(003 的写法说明同一结论)。
-- 建表/建索引失败时数据库本身就会报错并让 runMigrations 回滚,不需要额外的自检块。

-- ① 验证码表。
--    `id uuid primary key`:与 users/devices 等表一致(服务端生成 uuid,便于日志追踪与按行消费)。
--    `consumed_at bigint null`:null = 未消费;非 null = 消费时刻(epoch millis)。
--    `attempts int not null default 0`:同码尝试次数,自增原子。
--    时间列一律 bigint(与契约 §8 的其它表保持一致:epoch millis)。
create table if not exists email_codes (
  id uuid primary key,
  email text not null,
  code_hash text not null,
  attempts int not null default 0,
  consumed_at bigint,
  created_at bigint not null,
  expires_at bigint not null
);

-- ② 契约 §8 指定的索引:`(email, created_at desc)`。
--    查询模式有三种,都由它服务:
--      · 取某邮箱最近一条验证码(`order by created_at desc limit 1`)—— 校验与 60s 限流;
--      · 统计某邮箱在时间窗口内的发码条数(`created_at >= $2`)—— 每小时 5 / 每天 10 限流;
--      · 清理过期行。
--    写 `desc` 是为了与契约文字逐字一致(btree 可双向扫描,asc 也能满足上述查询,
--    但契约既然写明了列序与方向,就照写)。
create index if not exists email_codes_email_created_idx on email_codes (email, created_at desc);
