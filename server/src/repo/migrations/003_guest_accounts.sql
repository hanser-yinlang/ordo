-- 迁移 003:游客账号 —— 契约 §7.6(v1.2 新增「账号、会话与游客」)
-- 迁移版本:003 · schemaVersion = 1(表结构增量,不改变 §1 的 schemaVersion)
--
-- 改动只有两件事:
--   ① users 增加 is_guest boolean not null default false —— 标记游客账号
--   ② users.email 必须允许为 NULL —— 游客没有邮箱
--
-- ⚠️ 为什么必须「允许 NULL」,以及为什么**不能**用空串代替:
--   契约 §7.6.1 明确 user.email 可为 null(游客)。PostgreSQL 的 unique 索引
--   **默认就允许多个 NULL**(SQL 标准:NULL 与 NULL 不相等,唯一性检查对 NULL 直接放行),
--   因此 `email text unique` 这一个约束天然容忍任意多个游客账号,**不需要**改成部分索引:
--       insert into users (email) values (null);   -- ok
--       insert into users (email) values (null);   -- ok,再来一个仍然 ok
--   反过来,若用**空串**当"没有邮箱",第二个游客就会撞上唯一约束(空串 = 空串),
--   `POST /v1/auth/guest` 从第二次调用起全部失败。所以服务端一律写 NULL,绝不写 ''。
--   该行为已在真实 PostgreSQL 上断言(scripts/pg-real-verify.mts 第 0.5 / 11 节)。
--
-- 幂等性:可执行语句全部幂等(if not exists / 条件 DDL),重复执行不报错。
-- 迁移器 `runMigrations` 用 begin/commit 包住整个文件,失败则整体回滚。
--
-- ── 写法说明:为什么拆成"可执行 DDL"+"条件 DO 块"两段 ──────────────────────
-- `test/pg-helpers.ts` 给 pg-mem 注册的是 **no-op plpgsql 编译器**:DO 块在 pg-mem 上
-- "能通过但什么都不做"(与 002 的既有情况一致)。而 PgRepository 现在都会写 `is_guest` 列,
-- 因此 **pg-mem 侧也必须真的拥有这一列**,否则仓储的所有用户相关 SQL 都会失败。
-- 所以:
--   · 能两边都跑的语句(create index / alter table add column ... default / drop index if exists)
--     放在顶层,**pg-mem 与真库都会真的执行**;
--   · pg-mem 跑不了的条件 DDL(alter ... drop not null、drop constraint)放在 DO 块里,
--     由 `scripts/pg-real-verify.mts` 在真实 PostgreSQL 上验证语义。

-- ① is_guest 列。加列时带 `not null default false`:PG 11+ 走"常量默认值不重写表"的快速路径,
--    旧行自动补成 false → 全部按正式账号对待,行为完全不变。
--    **必须放在顶层**(不能包在 DO 块里):pg-mem 的 plpgsql 是 no-op,
--    DO 块里的 ALTER 不会真的执行,而 PgRepository 现在都会写这一列 ——
--    放顶层才能让 pg-mem 与真库的列形状一致(见 test/pg-helpers.ts 差异 #5)。
--    `if not exists` 让语句本身幂等。
alter table users add column if not exists is_guest boolean not null default false;

-- ② 把 email 上的唯一性收敛成一个**显式唯一索引** users_email_key。
--    注意:这不是为了改变行为 —— `unique` 列约束生成的索引本来就允许多个 NULL。
--    之所以还要重建,是为了让"唯一索引 + 多个 NULL"这件事在迁移里显式可见,
--    避免后人误以为 email 的唯一性会挡住游客,顺手把它改成 not null 或非空部分索引。
--    先摘掉旧的列约束(默认名 users_email_key —— 同时会带走它背后的索引),
--    再建回同名唯一索引;`if not exists` 让整段幂等。
do $$
begin
  alter table users drop constraint if exists users_email_key;
end $$;

create unique index if not exists users_email_key on users (email);

-- ③ 摘掉 email 的 NOT NULL(游客无邮箱)。
--    pg-mem 不支持 `alter column ... drop not null`,所以这一步放在 DO 块里,
--    由真实 PostgreSQL 执行(见 pg-real-verify 第 0.5 / 11 节)。
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'users'
      and column_name = 'email' and is_nullable = 'NO'
  ) then
    alter table users alter column email drop not null;
  end if;
end $$;

-- ④ 自检:迁移结束时 is_guest 列必须存在。不满足就让整个迁移回滚
--    (schema_migrations 不会留下版本 3)。
--    注意:**不能**在自检里断言 "email 必须可空" —— pg-mem 的 DO 块是 no-op,
--    那样会让无 Postgres 的 CI 直接失败。email 可空性由真库脚本断言
--    (scripts/pg-real-verify.mts 第 0.5 / 11 节)。
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'users' and column_name = 'is_guest'
  ) then
    raise exception '迁移 003 失败:users.is_guest 列不存在';
  end if;
end $$;
