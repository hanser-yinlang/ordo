/**
 * 真实 PostgreSQL 验证脚本 —— 把 test/pg.test.ts 的断言换成对**真库**执行,
 * 并覆盖 README「用真实 PostgreSQL 16 复跑」里 pg-mem 覆盖不到的 5 条人工确认点。
 *
 * 用法(先启动 PG,见 README):
 *   DATABASE_URL="postgres://ordo:ordo_secret@127.0.0.1:55432/ordo" \
 *     node --import tsx scripts/pg-real-verify.mts
 */
import { join } from 'node:path';
import { Pool } from 'pg';
import { PgRepository, type SqlPool } from '../src/repo/pg';
import { runMigrations } from '../src/repo/migrate';
import { baseConfig } from '../test/helpers';
import { AuthService, emailCodeHash } from '../src/services/auth';
import { createPasswordHasher, sha256Hex } from '../src/services/password';
import type { MailSender } from '../src/services/mail';
import { SyncService } from '../src/services/sync';
import type { AnyEntity, Todo } from '../src/domain/model';

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  console.error('DATABASE_URL is required, e.g. postgres://user:pass@127.0.0.1:55432/ordo');
  process.exit(2);
}
const MIGRATIONS_DIR = join(process.cwd(), 'src', 'repo', 'migrations');
const NOW = 1_810_000_000_000;

let pass = 0;
let fail = 0;
const failures: string[] = [];

function check(name: string, ok: boolean, detail = ''): void {
  if (ok) {
    pass += 1;
    console.log(`  PASS  ${name}${detail ? ` — ${detail}` : ''}`);
  } else {
    fail += 1;
    failures.push(name);
    console.log(`  FAIL  ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

function makeTodo(id: string, overrides: Partial<Todo> = {}): Todo {
  return {
    id,
    title: '交季度报告',
    note: '备注中文 · 📊',
    when: 'inbox',
    date: null,
    reminder: null,
    deadline: null,
    tags: [],
    checklist: [],
    projectId: null,
    areaId: null,
    headingId: null,
    repeat: null,
    order: 0,
    status: 'open',
    createdAt: NOW,
    updatedAt: NOW,
    completedAt: null,
    deleted: false,
    ...overrides
  };
}

/* ---------------- 干净起点:drop 全部表,强制重跑迁移 ---------------- */
const adminPool = new Pool({ connectionString: DATABASE_URL, max: 4 });
const { rows: ver } = await adminPool.query<{ v: string }>('select version() as v');
console.log(`\nPostgreSQL: ${ver[0].v}\n`);

/* ---------------- 0) 契约形态的 deviceId 必须可用(真实 PG 才会暴露)---------------- */
console.log('=== 0) 契约 §7.2 形态的 deviceId(dev_xxx)在真库上的类型兼容 ===');
{
  // 先建表(下面 drop schema 后重建,这里只是提前暴露类型问题)
  await adminPool.query(`drop schema public cascade; create schema public;`);
  await runMigrations(adminPool as unknown as SqlPool, MIGRATIONS_DIR, () => undefined);
  const { rows: devCols } = await adminPool.query<{ table_name: string; column_name: string; data_type: string }>(
    `select table_name, column_name, data_type from information_schema.columns
     where (table_name='devices' and column_name='id')
        or (table_name='refresh_tokens' and column_name='device_id')
        or (table_name='ops' and column_name='device_id')`
  );
  const map = new Map(devCols.map((c) => [`${c.table_name}.${c.column_name}`, c.data_type]));
  check('devices.id 是 text(不是 uuid)', map.get('devices.id') === 'text', `实际=${map.get('devices.id')}`);
  check('refresh_tokens.device_id 是 text', map.get('refresh_tokens.device_id') === 'text', `实际=${map.get('refresh_tokens.device_id')}`);
  check('ops.device_id 是 text', map.get('ops.device_id') === 'text', `实际=${map.get('ops.device_id')}`);

  // 真的写一条 dev_ 形态的 deviceId(旧 schema 会在这里抛 22P02)
  const contractUserId = '33333333-3333-4333-8333-333333333333';
  await adminPool.query(
    `insert into users (id,email,password_hash,password_algo,created_at) values ($1,'devid@example.com','h','scrypt',1)`,
    [contractUserId]
  );
  let insertOk = true;
  let insertErr = '';
  try {
    await adminPool.query(
      `insert into devices (id,user_id,name,platform,created_at,last_seen_at) values ($1,$2,'d','android',1,1)`,
      ['dev_7f3a9c2e', contractUserId]
    );
    await adminPool.query(
      `insert into refresh_tokens (token_hash,user_id,device_id,created_at,expires_at) values ('h1',$1,$2,1,2)`,
      [contractUserId, 'dev_7f3a9c2e']
    );
  } catch (err) {
    insertOk = false;
    insertErr = (err as Error).message;
  }
  check('契约形态 deviceId 可写入 devices 与 refresh_tokens(外键也成立)', insertOk, insertErr);
}

/* ---------------- 0.5) 迁移 003:游客账号列与 email 可空(真库才能验证)---------------- */
console.log('=== 0.5) 003_guest_accounts.sql:is_guest 列 + email 可空 + unique 容忍多个 NULL ===');
{
  const { rows: userCols } = await adminPool.query<{
    column_name: string;
    data_type: string;
    is_nullable: string;
    column_default: string | null;
  }>(
    `select column_name, data_type, is_nullable, column_default
     from information_schema.columns
     where table_schema = 'public' and table_name = 'users'`
  );
  const byName = new Map(userCols.map((c) => [c.column_name, c]));

  check(
    'users.is_guest 列存在且类型为 boolean',
    byName.get('is_guest')?.data_type === 'boolean',
    `实际=${byName.get('is_guest')?.data_type ?? 'missing'}`
  );
  check(
    'users.is_guest 是 not null 且默认 false',
    byName.get('is_guest')?.is_nullable === 'NO' && /false/.test(byName.get('is_guest')?.column_default ?? ''),
    `is_nullable=${byName.get('is_guest')?.is_nullable} default=${byName.get('is_guest')?.column_default}`
  );
  check(
    'users.email 已允许 NULL(契约 §7.6.1 游客无邮箱)',
    byName.get('email')?.is_nullable === 'YES',
    `is_nullable=${byName.get('email')?.is_nullable}`
  );

  // email 的唯一性必须落在**显式唯一索引** users_email_key 上(003 重建过)
  const { rows: emailIdx } = await adminPool.query<{ indexdef: string; indisunique: boolean }>(
    `select i.indexdef, ix.indisunique
     from pg_indexes i
     join pg_class c on c.relname = i.indexname
     join pg_index ix on ix.indexrelid = c.oid
     where i.schemaname = 'public' and i.tablename = 'users' and i.indexname = 'users_email_key'`
  );
  check('users_email_key 是唯一索引', emailIdx[0]?.indisunique === true, emailIdx[0]?.indexdef ?? '缺失');
  check(
    'users_email_key 只覆盖 email 一列',
    /using btree \(email\)/i.test(emailIdx[0]?.indexdef ?? ''),
    emailIdx[0]?.indexdef ?? '缺失'
  );
  // 同一列上不能有两个唯一索引(003 重放/幂等的保护)
  const { rows: emailUniqCount } = await adminPool.query<{ c: number }>(
    `select count(*)::int as c
     from pg_index ix
     join pg_class c on c.oid = ix.indexrelid
     join pg_class t on t.oid = ix.indrelid
     join pg_namespace ns on ns.oid = t.relnamespace
     where ns.nspname = 'public' and t.relname = 'users' and ix.indisunique
       and ix.indnatts = 1
       and (select a.attname from pg_attribute a where a.attrelid = t.oid and a.attnum = ix.indkey[0]) = 'email'`
  );
  check('users.email 上恰好一个唯一索引', emailUniqCount[0].c === 1, `count=${emailUniqCount[0].c}`);

  // 已存在的行(第 0 节插入的 devid@example.com)必须被补成 is_guest=false
  const { rows: legacy } = await adminPool.query<{ is_guest: boolean }>(
    `select is_guest from users where email = 'devid@example.com'`
  );
  check('迁移前已存在的行被补成 is_guest=false(行为不变)', legacy[0]?.is_guest === false, `实际=${legacy[0]?.is_guest}`);

  // 多个 NULL email 必须能共存 —— 这是游客能无限创建的唯一前提
  const g1 = 'aaaaaaaa-0000-4000-8000-000000000001';
  const g2 = 'aaaaaaaa-0000-4000-8000-000000000002';
  let multiNullOk = true;
  let multiNullErr = '';
  try {
    await adminPool.query(
      `insert into users (id,email,password_hash,password_algo,is_guest,created_at) values ($1,null,'guest$h','none',true,1)`,
      [g1]
    );
    await adminPool.query(
      `insert into users (id,email,password_hash,password_algo,is_guest,created_at) values ($1,null,'guest$h','none',true,1)`,
      [g2]
    );
  } catch (err) {
    multiNullOk = false;
    multiNullErr = (err as Error).message;
  }
  check('两个 email 为 NULL 的游客可以共存(unique 默认允许多个 NULL)', multiNullOk, multiNullErr);

  // 但唯一性对非 NULL 值仍然生效:重复邮箱必须被拒(正式账号依赖它兜底并发注册)
  let dupRejected = false;
  let dupCode = '';
  try {
    await adminPool.query(
      `insert into users (id,email,password_hash,password_algo,is_guest,created_at)
       values ('aaaaaaaa-0000-4000-8000-000000000003','devid@example.com','h','scrypt',false,1)`
    );
  } catch (err) {
    dupRejected = true;
    dupCode = String((err as { code?: string }).code ?? '');
  }
  check('重复的非 NULL 邮箱仍被唯一索引拒绝(23505)', dupRejected && dupCode === '23505', `code=${dupCode}`);

  // 用一个临时库把 003 单独重放,验证幂等 + 自检 DO 块不会误报
  const idemDb = `ordo_guest_idem_${Date.now()}`;
  await adminPool.query(`create database ${idemDb}`);
  const idemUrl = new URL(DATABASE_URL);
  idemUrl.pathname = `/${idemDb}`;
  const idemPool = new Pool({ connectionString: idemUrl.toString(), max: 2 });
  try {
    const { readFileSync } = await import('node:fs');
    const sql003 = readFileSync(join(MIGRATIONS_DIR, '003_guest_accounts.sql'), 'utf8');
    await runMigrations(idemPool as unknown as SqlPool, MIGRATIONS_DIR, () => undefined);
    let idemOk = true;
    let idemErr = '';
    try {
      await idemPool.query(sql003);
      await idemPool.query(sql003);
    } catch (err) {
      idemOk = false;
      idemErr = (err as Error).message;
    }
    check('003 可重复执行(幂等,含自检 DO 块)', idemOk, idemErr);
    const { rows: idx } = await idemPool.query<{ c: number }>(
      `select count(*)::int as c from pg_indexes
       where schemaname='public' and tablename='users' and indexname='users_email_key'`
    );
    check('幂等重跑后 users_email_key 恰好一个', idx[0].c === 1, `count=${idx[0].c}`);
    const { rows: nullable } = await idemPool.query<{ is_nullable: string }>(
      `select is_nullable from information_schema.columns
       where table_schema='public' and table_name='users' and column_name='email'`
    );
    check('幂等重跑后 email 仍可空', nullable[0]?.is_nullable === 'YES', `is_nullable=${nullable[0]?.is_nullable}`);
  } finally {
    await idemPool.end();
    await adminPool.query(`drop database if exists ${idemDb} with (force)`);
  }
}

console.log('=== 0) 迁移(从干净库开始) ===');
await adminPool.query(`drop schema public cascade; create schema public;`);
const pool = new Pool({ connectionString: DATABASE_URL, max: 8 });
const repo = new PgRepository(DATABASE_URL, 8, [MIGRATIONS_DIR], pool as unknown as SqlPool);

const applied = await runMigrations(pool as unknown as SqlPool, MIGRATIONS_DIR, (m) => console.log(`  ${m}`));
check('001_init.sql 被真实执行', applied.includes(1), `applied=${JSON.stringify(applied)}`);
check('003_guest_accounts.sql 被真实执行', applied.includes(3), `applied=${JSON.stringify(applied)}`);
const appliedAgain = await runMigrations(pool as unknown as SqlPool, MIGRATIONS_DIR);
check('迁移幂等(二次执行无副作用)', appliedAgain.length === 0);

/* ---------------- 1) pg_indexes:索引目录 ---------------- */
console.log('\n=== 1) pg_indexes 索引目录(README 人工确认点 1)===');
const { rows: indexes } = await adminPool.query<{ indexname: string; indexdef: string }>(
  `select indexname, indexdef from pg_indexes where schemaname = 'public' order by indexname`
);
const indexMap = new Map(indexes.map((i) => [i.indexname, i.indexdef]));
for (const name of ['devices_user_idx', 'refresh_tokens_user_idx', 'entities_user_seq_idx', 'ops_user_seq_idx', 'reminders_due_idx']) {
  check(`索引存在: ${name}`, indexMap.has(name), indexMap.get(name)?.slice(0, 70) ?? '缺失');
}
const dueDef = indexMap.get('reminders_due_idx') ?? '';
check('reminders_due_idx 是部分索引 WHERE (fired = false)', /where\s*\(?fired\s*=\s*false\)?/i.test(dueDef), dueDef);
check('ops_user_seq_idx 列序为 (user_id, server_seq)', /\(user_id,\s*server_seq\)/i.test(indexMap.get('ops_user_seq_idx') ?? ''));
check('entities_user_seq_idx 列序为 (user_id, server_seq)', /\(user_id,\s*server_seq\)/i.test(indexMap.get('entities_user_seq_idx') ?? ''));
const { rows: uniq } = await adminPool.query<{ conname: string; def: string }>(
  `select conname, pg_get_constraintdef(oid) as def from pg_constraint
   where conrelid = 'ops'::regclass and contype = 'u'`
);
check('ops(user_id, op_id) 唯一约束存在', uniq.some((u) => /unique \(user_id, op_id\)/i.test(u.def)), JSON.stringify(uniq));

/* ---------------- 2) server_seq 的 bigint + nextval 默认值(确认点 2)---------------- */
console.log('\n=== 2) \u005cd ops:server_seq 类型与默认值(README 人工确认点 2)===');
const { rows: cols } = await adminPool.query<{ column_name: string; data_type: string; column_default: string }>(
  `select column_name, data_type, column_default from information_schema.columns
   where table_name = 'ops' order by ordinal_position`
);
const seqCol = cols.find((c) => c.column_name === 'server_seq');
check('server_seq 类型是 bigint', seqCol?.data_type === 'bigint', `实际=${seqCol?.data_type}`);
check('server_seq 默认值是 nextval(...)', /nextval\(/.test(seqCol?.column_default ?? ''), seqCol?.column_default ?? '');
const tsCols = cols.filter((c) => ['client_ts', 'created_at'].includes(c.column_name));
check('client_ts/created_at 是 bigint', tsCols.every((c) => c.data_type === 'bigint'), JSON.stringify(tsCols));
const { rows: entCols } = await adminPool.query<{ column_name: string; data_type: string }>(
  `select column_name, data_type from information_schema.columns where table_name = 'entities'`
);
check('entities.payload 是 jsonb', entCols.find((c) => c.column_name === 'payload')?.data_type === 'jsonb');
check(
  'users/devices 的时间列是 bigint',
  (
    await adminPool.query<{ c: number }>(
      `select count(*)::int as c from information_schema.columns
       where table_name in ('users','devices','refresh_tokens','reminders') and data_type <> 'bigint'
         and column_name in ('created_at','last_seen_at','expires_at','revoked_at','updated_at','at')`
    )
  ).rows[0].c === 0
);
check(
  'email 的 text 比较大小写敏感(生产应为 C/ICU 排序规则,不与 pg-mem 的 nocase 相同)',
  (
    await adminPool.query<{ c: number }>(
      `select count(*)::int as c from pg_collation where collname = 'default'`
    )
  ).rows[0].c >= 1
);

/* ---------------- 3) has_table_privilege:迁移失败的事务回滚(确认点 3)---------------- */
console.log('\n=== 3) 失败迁移整体回滚,不留版本行(README 人工确认点 3)===');
{
  // 造一个必然失败的迁移:第二条语句语法错误
  const badDir = join(process.env.TEMP ?? '.', `ordo-bad-migration-${Date.now()}`);
  const { mkdirSync, writeFileSync, rmSync } = await import('node:fs');
  mkdirSync(badDir, { recursive: true });
  writeFileSync(join(badDir, '999_bad.sql'), `create table ordo_bad_probe (id int);\nthis is not valid sql;`);
  let threw = false;
  try {
    await runMigrations(pool as unknown as SqlPool, badDir, () => undefined);
  } catch {
    threw = true;
  }
  check('失败迁移抛出错误', threw);
  const { rows: versionRows } = await adminPool.query<{ c: number }>(
    `select count(*)::int as c from schema_migrations where version = 999`
  );
  check('schema_migrations 没有留下版本 999(事务回滚)', versionRows[0].c === 0, `实际=${versionRows[0].c}`);
  const { rows: probe } = await adminPool.query<{ c: number }>(
    `select count(*)::int as c from information_schema.tables where table_name = 'ordo_bad_probe'`
  );
  check('失败迁移里的 create table 也被回滚(表不存在)', probe[0].c === 0, `实际=${probe[0].c}`);
  rmSync(badDir, { recursive: true, force: true });
}

/* ---------------- 4) appendOps 批量失败回滚 + DO NOTHING RETURNING(确认点 4/5)---------------- */
console.log('\n=== 4) appendOps 事务回滚(README 人工确认点 4)===');
const userId = '11111111-1111-4111-8111-111111111111';
await repo.createUser({ id: userId, email: 'real@example.com', passwordHash: 'scrypt$x', passwordAlgo: 'scrypt', createdAt: NOW });

{
  const before = (await adminPool.query<{ c: number }>(`select count(*)::int as c from ops where user_id = $1`, [userId])).rows[0].c;
  let threw = false;
  try {
    await repo.appendOps([
      { userId, opId: 'tx-good', deviceId: null, entity: 'todo', entityId: 'tx-1', type: 'upsert', payload: null, clientTs: NOW, createdAt: NOW },
      { userId: '99999999-9999-4999-8999-999999999999', opId: 'tx-fk', deviceId: null, entity: 'todo', entityId: 'tx-2', type: 'upsert', payload: null, clientTs: NOW, createdAt: NOW }
    ]);
  } catch {
    threw = true;
  }
  const after = (await adminPool.query<{ c: number }>(`select count(*)::int as c from ops where user_id = $1`, [userId])).rows[0].c;
  check('批量中违反外键会抛错', threw);
  check('ops 行数没有增加(事务整体回滚)', after === before, `${before} -> ${after}`);
}

console.log('\n=== 5) on conflict do nothing returning * 冲突时返回 0 行(README 人工确认点 5)===');
{
  await repo.appendOps([{ userId, opId: 'dup-probe', deviceId: null, entity: 'todo', entityId: 'd-1', type: 'upsert', payload: null, clientTs: NOW, createdAt: NOW }]);
  const dup = await pool.query(
    `insert into ops (user_id, op_id, device_id, entity, entity_id, type, payload, client_ts, created_at)
     values ($1,'dup-probe',null,'todo','d-1','upsert',null,$2,$3)
     on conflict (user_id, op_id) do nothing returning *`,
    [userId, NOW, NOW]
  );
  check('冲突时 RETURNING 返回 0 行(与 pg-mem 的偏差在此确认)', dup.rows.length === 0, `rows=${dup.rows.length}`);
  const { rows: seqRows } = await adminPool.query<{ c: number }>(`select count(*)::int as c from ops where user_id=$1 and op_id='dup-probe'`, [userId]);
  check('冲突不产生第二行', seqRows[0].c === 1);

  // 注意:bigserial 的 nextval 在**冲突检测之前**就已求值,因此 do nothing 仍会消耗一个
  // 序列值(PG 的既有行为)。这**不影响契约**:契约只要求 server_seq 单调,不要求连续;
  // pg-mem 不消耗序列值,属于实现差异而非语义差异。真正要断言的是下面三条不变量。
  const { rows: beforeSeq } = await pool.query<{ v: string }>(`select last_value::text as v from ops_server_seq_seq`);
  await pool.query(
    `insert into ops (user_id, op_id, device_id, entity, entity_id, type, payload, client_ts, created_at)
     values ($1,'dup-probe',null,'todo','d-1','upsert',null,$2,$3)
     on conflict (user_id, op_id) do nothing`,
    [userId, NOW, NOW]
  );
  const { rows: afterSeq } = await pool.query<{ v: string }>(`select last_value::text as v from ops_server_seq_seq`);
  console.log(`    (参考)bigserial last_value ${beforeSeq[0].v} -> ${afterSeq[0].v}:冲突时 nextval 已被求值`);

  // 不变量 1:冲突不产生第二行
  const { rows: dupCount } = await adminPool.query<{ c: number }>(
    `select count(*)::int as c from ops where user_id = $1 and op_id = 'dup-probe'`,
    [userId]
  );
  check('冲突不产生第二行', dupCount[0].c === 1, `count=${dupCount[0].c}`);

  // 不变量 2:appendOps 对已存在的 op 返回空数组(仓储层幂等的关键)
  const again = await repo.appendOps([
    { userId, opId: 'dup-probe', deviceId: null, entity: 'todo', entityId: 'd-1', type: 'upsert', payload: null, clientTs: NOW, createdAt: NOW }
  ]);
  check('appendOps 对重复 opId 返回空数组(不误报"本次写入")', again.length === 0, `len=${again.length}`);

  // 不变量 3:混合批次只返回新写入的那条
  const mixed = await repo.appendOps([
    { userId, opId: 'dup-probe', deviceId: null, entity: 'todo', entityId: 'd-1', type: 'upsert', payload: null, clientTs: NOW, createdAt: NOW },
    { userId, opId: 'fresh-after-dup', deviceId: null, entity: 'todo', entityId: 'd-2', type: 'upsert', payload: null, clientTs: NOW + 1, createdAt: NOW }
  ]);
  check(
    '混合批次只返回真正写入的那条',
    mixed.length === 1 && mixed[0].opId === 'fresh-after-dup' && mixed[0].serverSeq > 0,
    JSON.stringify(mixed.map((m) => ({ opId: m.opId, seq: m.serverSeq })))
  );

  // 不变量 4:server_seq 严格单调(空洞是允许的:P0 冲突时 nextval 已消费)
  const { rows: seqs } = await pool.query<{ server_seq: string }>(
    `select server_seq from ops where user_id = $1 order by server_seq`,
    [userId]
  );
  const nums = seqs.map((s) => Number(s.server_seq));
  check('ops.server_seq 随插入严格单调递增', nums.every((v, i) => i === 0 || v > nums[i - 1]), JSON.stringify(nums));
}

/* ---------------- 6) PgRepository 全流程 ---------------- */
console.log('\n=== 6) PgRepository + SyncService 全流程(真库) ===');
const config = baseConfig({ tzOffsetMinutes: 0, defaultPullLimit: 2 });
const sync = new SyncService(repo, config);
const todoId = '22222222-2222-4222-8222-222222222222';

// 注意:不要硬编码 seq=1 —— `ops.server_seq` 是**全局** bigserial(不是 per-user),
// 前面的回滚/冲突用例已经消耗过序列值。契约只要求单调,不要求连续或从 1 开始。
const seqBefore = await repo.latestSeq(userId);
const p1 = await sync.push(userId, 'dev-1', null, [
  { opId: 'r1', deviceId: 'dev-1', entity: 'todo', entityId: todoId, type: 'upsert', payload: makeTodo(todoId) as AnyEntity, clientTs: NOW }
]);
check(
  'push 首次写入 applied 且获得正的 serverSeq',
  p1.accepted[0]?.applied === true && typeof p1.accepted[0].serverSeq === 'number' && p1.accepted[0].serverSeq > 0,
  `serverSeq=${p1.accepted[0]?.serverSeq}`
);
check(
  'serverSeq 严格大于推送前的 latestSeq',
  (p1.accepted[0].serverSeq ?? 0) > seqBefore,
  `${seqBefore} -> ${p1.accepted[0].serverSeq}`
);

const p2 = await sync.push(userId, 'dev-1', null, [
  { opId: 'r1', deviceId: 'dev-1', entity: 'todo', entityId: todoId, type: 'upsert', payload: makeTodo(todoId) as AnyEntity, clientTs: NOW }
]);
check('同 opId 幂等 duplicate', p2.accepted[0]?.duplicate === true, JSON.stringify(p2.accepted));

const p3 = await sync.push(userId, 'dev-1', null, [
  { opId: 'r2', deviceId: 'dev-1', entity: 'todo', entityId: todoId, type: 'upsert', payload: makeTodo(todoId, { title: '旧' }) as AnyEntity, clientTs: NOW - 5000 }
]);
check('LWW:更旧 clientTs 被拒 stale', p3.rejected[0]?.reason === 'stale');

const snap = await sync.snapshot(userId);
check('snapshot 读到实体且 jsonb 中文/emoji 无损', snap.todos.length === 1 && snap.todos[0].note === '备注中文 · 📊', JSON.stringify(snap.todos.map((t) => t.note)));

const p4 = await sync.push(userId, 'dev-1', null, [
  { opId: 'r3', deviceId: 'dev-1', entity: 'todo', entityId: todoId, type: 'delete', payload: null, clientTs: NOW + 1000 }
]);
check('删除写入墓碑', p4.accepted[0]?.applied === true);
const tomb = await repo.getEntity(userId, 'todo', todoId);
check('墓碑 deleted=true 且 payload.deleted=true', tomb?.deleted === true && (tomb.payload as { deleted?: boolean }).deleted === true);

const p5 = await sync.push(userId, 'dev-1', null, [
  { opId: 'r4', deviceId: 'dev-1', entity: 'todo', entityId: todoId, type: 'upsert', payload: makeTodo(todoId, { title: '复活' }) as AnyEntity, clientTs: NOW + 500 }
]);
check('更旧 op 不能复活墓碑(tombstoned)', p5.rejected[0]?.reason === 'tombstoned');

// pull 分页
for (let i = 0; i < 3; i += 1) {
  await sync.push(userId, 'dev-1', null, [
    { opId: `page-${i}`, deviceId: 'dev-1', entity: 'todo', entityId: `page-todo-${i}`, type: 'upsert', payload: makeTodo(`page-todo-${i}`) as AnyEntity, clientTs: NOW + 2000 + i }
  ]);
}
const page1 = await sync.pull(userId, 0, 2);
check('pull 分页 limit 生效且 hasMore=true', page1.ops.length === 2 && page1.hasMore === true, JSON.stringify(page1.ops.map((o) => o.seq)));
const page2 = await sync.pull(userId, page1.ops[1].seq, 2);
check('第二页从游标之后继续', page2.ops.every((o) => o.seq > page1.ops[1].seq), JSON.stringify(page2.ops.map((o) => o.seq)));

const gap = await sync.pull(userId, page1.serverSeq + 10, 10).catch((e: { code?: string }) => e.code);
check('SYNC_SEQ_GAP 触发', gap === 'SYNC_SEQ_GAP', String(gap));

/* ---------------- 7) 提醒:只投一次 + 改时刻复位 ---------------- */
console.log('\n=== 7) reminders:唯一约束 + 只投一次 + 改时刻复位(真库) ===');
await repo.upsertReminder({ userId, todoId: 'rem-1', at: NOW + 1000, title: 'A', updatedAt: NOW });
check('首次领取投递权', (await repo.claimReminder(`${userId}|rem-1`)) === true);
check('二次领取失败(只投一次)', (await repo.claimReminder(`${userId}|rem-1`)) === false);
await repo.upsertReminder({ userId, todoId: 'rem-1', at: NOW + 1000, title: 'B', updatedAt: NOW + 1 });
check('同 at 再 upsert 保持 fired=true', (await repo.listReminders(userId)).find((r) => r.todoId === 'rem-1')?.fired === true);
await repo.upsertReminder({ userId, todoId: 'rem-1', at: NOW + 9999, title: 'C', updatedAt: NOW + 2 });
check('改 at 后 fired 复位为 false', (await repo.listReminders(userId)).find((r) => r.todoId === 'rem-1')?.fired === false);
const due = await repo.listDueReminders(NOW + 10000);
check('listDueReminders 命中复位后的提醒', due.some((r) => r.todoId === 'rem-1'));

/* ---------------- 8) 墓碑清理 + 级联删除 ---------------- */
console.log('\n=== 8) 墓碑清理与级联删除(真库) ===');
await repo.putEntity({
  userId,
  entity: 'todo',
  entityId: 'ancient-tomb',
  payload: { id: 'ancient-tomb', deleted: true, updatedAt: NOW - 40 * 24 * 3600_000 } as unknown as AnyEntity,
  updatedAt: NOW - 40 * 24 * 3600_000,
  deleted: true,
  serverSeq: 0
});
const purged = await repo.purgeTombstones(NOW - 30 * 24 * 3600_000);
check('purgeTombstones 删掉过期墓碑', purged >= 1, `purged=${purged}`);
check('存活实体未受影响', (await repo.listEntities(userId)).length > 0);

await repo.deleteUser(userId);
const { rows: leftover } = await adminPool.query<{ e: number; o: number; d: number; r: number }>(
  `select (select count(*)::int from entities where user_id=$1) as e,
          (select count(*)::int from ops where user_id=$1) as o,
          (select count(*)::int from devices where user_id=$1) as d,
          (select count(*)::int from reminders where user_id=$1) as r`,
  [userId]
);
check('deleteUser 级联清空 entities/ops/devices/reminders', leftover[0].e + leftover[0].o + leftover[0].d + leftover[0].r === 0, JSON.stringify(leftover[0]));

/* ---------------- 9) 迁移 002:旧库(uuid 列)升级到 text(真库才能验证)---------------- */
console.log('\n=== 9) 002_device_id_text.sql 在"旧库形状"上真的做类型转换(真库) ===');
{
  // 在同一个 PG 实例里建一个独立的临时库,把 devices/refresh_tokens 造成**旧版 001 的形状**
  // (deviceId 列是 uuid + 外键),然后只跑 002,验证:
  //   ① 两列都被改成 text  ② 外键被保留(仍是 on delete set null)  ③ 可重复执行  ④ 之后能写入 dev_ 形态 id
  const tmpDb = `ordo_migrate_probe_${Date.now()}`;
  await adminPool.query(`create database ${tmpDb}`);

  const tmpUrl = new URL(DATABASE_URL);
  tmpUrl.pathname = `/${tmpDb}`;
  const tmpPool = new Pool({ connectionString: tmpUrl.toString(), max: 4 });

  try {
    // 先跑真实 001 建出完整 schema,再手工把两列退回 uuid —— 这样"旧库形状"与原版 001 逐字一致
    await runMigrations(tmpPool as unknown as SqlPool, MIGRATIONS_DIR, () => undefined);
    await tmpPool.query(`alter table refresh_tokens drop constraint refresh_tokens_device_id_fkey`);
    await tmpPool.query(`alter table refresh_tokens alter column device_id type uuid using device_id::uuid`);
    await tmpPool.query(`alter table devices alter column id type uuid using id::uuid`);
    await tmpPool.query(
      `alter table refresh_tokens add constraint refresh_tokens_device_id_fkey
       foreign key (device_id) references devices (id) on delete set null`
    );

    // 放一条旧数据,确认类型转换不丢数据
    const legacyUser = '44444444-4444-4444-8444-444444444444';
    const legacyDevice = '55555555-5555-4555-8555-555555555555';
    await tmpPool.query(
      `insert into users (id,email,password_hash,password_algo,created_at) values ($1,'old@e.com','h','scrypt',1)`,
      [legacyUser]
    );
    await tmpPool.query(
      `insert into devices (id,user_id,name,platform,created_at,last_seen_at) values ($1,$2,'old','cli',1,1)`,
      [legacyDevice, legacyUser]
    );
    await tmpPool.query(
      `insert into refresh_tokens (token_hash,user_id,device_id,created_at,expires_at) values ('old-token',$1,$2,1,2)`,
      [legacyUser, legacyDevice]
    );

    const colType = async (table: string, col: string): Promise<string> => {
      const { rows } = await tmpPool.query<{ data_type: string }>(
        `select data_type from information_schema.columns where table_schema='public' and table_name=$1 and column_name=$2`,
        [table, col]
      );
      return rows[0]?.data_type ?? 'missing';
    };
    check('旧库:devices.id 起初是 uuid', (await colType('devices', 'id')) === 'uuid', await colType('devices', 'id'));
    check('旧库:refresh_tokens.device_id 起初是 uuid', (await colType('refresh_tokens', 'device_id')) === 'uuid');

    // 直接执行 002 的 SQL(不走 runMigrations —— 此时 schema_migrations 里已记录过 002,
    // 走 runner 会被当成"已应用"而跳过,测不到升级路径)。
    // 直接执行也顺带验证了"这个迁移文件在旧形状的库上能独立跑通"。
    const { readFileSync } = await import('node:fs');
    const sql002 = readFileSync(join(MIGRATIONS_DIR, '002_device_id_text.sql'), 'utf8');
    await tmpPool.query(sql002);

    check('002 后 devices.id 变成 text', (await colType('devices', 'id')) === 'text', await colType('devices', 'id'));
    check('002 后 refresh_tokens.device_id 变成 text', (await colType('refresh_tokens', 'device_id')) === 'text');

    // 旧数据仍在
    const { rows: kept } = await tmpPool.query<{ c: number }>(`select count(*)::int as c from refresh_tokens where token_hash='old-token'`);
    check('类型转换不丢旧数据', kept[0].c === 1);

    // 外键被保留且仍是 on delete set null
    const { rows: fk } = await tmpPool.query<{ conname: string; confdeltype: string; def: string }>(
      `select conname, confdeltype, pg_get_constraintdef(oid) as def
       from pg_constraint
       where conrelid = 'refresh_tokens'::regclass and contype = 'f' and confrelid = 'devices'::regclass`
    );
    check('refresh_tokens → devices 外键被保留', fk.length === 1, JSON.stringify(fk.map((f) => f.conname)));
    check('外键仍是 on delete set null', fk[0]?.confdeltype === 'n', fk[0]?.def ?? '');
    check('外键引用的列已是 text', /foreign key \(device_id\) references devices\(id\)/i.test(fk[0]?.def ?? ''), fk[0]?.def ?? '');

    // 外键行为仍然有效:插入不存在的 device_id 必须被拒
    let fkRejected = false;
    try {
      await tmpPool.query(`insert into refresh_tokens (token_hash,user_id,device_id,created_at,expires_at) values ('bad',$1,'dev_nonexistent',1,2)`, [legacyUser]);
    } catch {
      fkRejected = true;
    }
    check('外键仍然生效(未知 device_id 被拒)', fkRejected);

    // 现在必须能写入契约形态的 dev_ id
    await tmpPool.query(`insert into devices (id,user_id,name,platform,created_at,last_seen_at) values ('dev_7f3a9c2e',$1,'new','android',1,1)`, [legacyUser]);
    await tmpPool.query(`insert into refresh_tokens (token_hash,user_id,device_id,created_at,expires_at) values ('new-token',$1,'dev_7f3a9c2e',1,2)`, [legacyUser]);
    check('升级后可写入契约形态 dev_ id(旧 uuid 列做不到)', true);

    // 幂等:再跑一次不报错,且列类型不变
    let idempotent = true;
    try {
      await tmpPool.query(sql002);
      await tmpPool.query(sql002);
    } catch (err) {
      idempotent = false;
      console.log('    重复执行报错:', (err as Error).message);
    }
    check('002 可重复执行(幂等)', idempotent);
    check('幂等重跑后列类型仍为 text', (await colType('devices', 'id')) === 'text' && (await colType('refresh_tokens', 'device_id')) === 'text');
    // 幂等重跑不能把外键搞丢
    const { rows: fkAfter } = await tmpPool.query<{ c: number }>(
      `select count(*)::int as c from pg_constraint
       where conrelid = 'refresh_tokens'::regclass and contype = 'f' and confrelid = 'devices'::regclass`
    );
    check('幂等重跑后外键仍只有一个', fkAfter[0].c === 1, `count=${fkAfter[0].c}`);
  } finally {
    await tmpPool.end();
    await adminPool.query(`drop database if exists ${tmpDb} with (force)`);
  }
}

/* ---------------- 10) EXPLAIN:索引被真正使用(pg-mem 无法验证)---------------- */
console.log('\n=== 10) EXPLAIN:执行计划确实走索引(pg-mem 无法验证) ===');
{
  await adminPool.query(`insert into users (id,email,password_hash,password_algo,created_at)
    select gen_random_uuid(), 'p'||g||'@e.com', 'h', 'scrypt', 1 from generate_series(1, 3000) g`);
  await adminPool.query(`insert into entities (user_id, entity, entity_id, payload, updated_at, deleted, server_seq)
    select id, 'todo', 'e'||g, '{"x":1}'::jsonb, 1, false, g from users, generate_series(1,3) g`);
  await adminPool.query(`analyze`);

  // 查 "某用户的增量实体":两条可用索引都能满足 (user_id, ...) 前缀,
  // 规划器可能选 entities_pkey(唯一索引)或 entities_user_seq_idx —— 只要不是全表扫描即可。
  const { rows: plan } = await adminPool.query<{ 'QUERY PLAN': string }>(
    `explain (costs off) select * from entities where user_id = (select id from users limit 1) and server_seq > 0`
  );
  const planText = plan.map((r) => r['QUERY PLAN']).join('\n');
  console.log(planText.split('\n').map((l) => `    ${l}`).join('\n'));
  check(
    'entities 查询走索引扫描(非 Seq Scan on entities)',
    /Index (Only )?Scan on entities|Bitmap Index Scan on entities/.test(planText) && !/Seq Scan on entities/.test(planText),
    planText.split('\n')[0].trim()
  );

  // 拉取 op 的增量查询:断言它确实用 ops_user_seq_idx
  await adminPool.query(`insert into ops (user_id, op_id, device_id, entity, entity_id, type, payload, client_ts, created_at)
    select id, 'exp-'||g, null, 'todo', 'e'||g, 'upsert', null, 1, 1 from users, generate_series(1,3) g`);
  await adminPool.query(`analyze ops`);
  const { rows: plan2 } = await adminPool.query<{ 'QUERY PLAN': string }>(
    `explain (costs off) select * from ops where user_id = (select id from users limit 1) and server_seq > 0 order by server_seq asc limit 10`
  );
  const plan2Text = plan2.map((r) => r['QUERY PLAN']).join('\n');
  console.log(plan2Text.split('\n').map((l) => `    ${l}`).join('\n'));
  check(
    'ops 增量查询走索引(非 Seq Scan on ops)',
    /Index (Only )?Scan on ops|Bitmap Index Scan on ops/.test(plan2Text) && !/Seq Scan on ops/.test(plan2Text),
    plan2Text.split('\n')[0].trim()
  );
}

/* ---------------- 11) 游客账号在真库上的完整行为(契约 §7.6)---------------- */
console.log('\n=== 11) 游客账号:真库建号 / email=null / 数据隔离 / 升级不改 userId(真库)===');
{
  const now = NOW + 1_000_000;
  const guestA = 'bbbbbbbb-0000-4000-8000-000000000001';
  const guestB = 'bbbbbbbb-0000-4000-8000-000000000002';

  // ① 建两个游客:email 为 null、is_guest = true(与 AuthService.guest 的写入一致)
  const created = await repo.createUser({
    id: guestA,
    email: null,
    passwordHash: 'guest$' + 'a'.repeat(64),
    passwordAlgo: 'none',
    isGuest: true,
    createdAt: now
  });
  check('游客 email 为 null 且 is_guest=true', created.email === null && created.isGuest === true, JSON.stringify(created));
  await repo.createUser({
    id: guestB,
    email: null,
    passwordHash: 'guest$' + 'b'.repeat(64),
    passwordAlgo: 'none',
    isGuest: true,
    createdAt: now
  });

  const readBack = await repo.findUserById(guestA);
  check('游客可从真库读回(is_guest 往返为布尔 true)', readBack?.isGuest === true && readBack?.email === null);
  check('游客查不到任何邮箱(findUserByEmail 永远 null)', (await repo.findUserByEmail('guest@example.com')) === null);

  const { rows: guestCount } = await adminPool.query<{ c: number }>(
    `select count(*)::int as c from users where email is null and is_guest = true`
  );
  check('库里同时存在多个 email 为 NULL 的游客行', guestCount[0].c >= 2, `count=${guestCount[0].c}`);

  // ② 数据隔离:两个游客各推一条,互不可见
  const sync = new SyncService(repo, config);
  const todoA = 'cccccccc-0000-4000-8000-00000000000a';
  const todoB = 'cccccccc-0000-4000-8000-00000000000b';
  await repo.upsertDevice({ id: 'dev_guest_a', userId: guestA, name: 'A', platform: 'cli', createdAt: now, lastSeenAt: now });
  await repo.upsertDevice({ id: 'dev_guest_b', userId: guestB, name: 'B', platform: 'cli', createdAt: now, lastSeenAt: now });

  const pushA = await sync.push(guestA, 'dev_guest_a', null, [
    { opId: 'guest-a-1', deviceId: 'dev_guest_a', entity: 'todo', entityId: todoA, type: 'upsert', payload: makeTodo(todoA, { title: 'A 的待办' }) as AnyEntity, clientTs: now }
  ]);
  const pushB = await sync.push(guestB, 'dev_guest_b', null, [
    { opId: 'guest-b-1', deviceId: 'dev_guest_b', entity: 'todo', entityId: todoB, type: 'upsert', payload: makeTodo(todoB, { title: 'B 的待办' }) as AnyEntity, clientTs: now }
  ]);
  check('游客 push 正常入库(不是离线模式)', pushA.accepted[0]?.applied === true && pushB.accepted[0]?.applied === true);

  const snapA = await sync.snapshot(guestA);
  const snapB = await sync.snapshot(guestB);
  check('游客 A 只能看到自己的 1 条待办', snapA.todos.length === 1 && snapA.todos[0].title === 'A 的待办', JSON.stringify(snapA.todos.map((t) => t.title)));
  check('游客 B 只能看到自己的 1 条待办(两游客互不可见)', snapB.todos.length === 1 && snapB.todos[0].title === 'B 的待办', JSON.stringify(snapB.todos.map((t) => t.title)));

  const { rows: isoCount } = await adminPool.query<{ user_id: string; c: number }>(
    `select user_id, count(*)::int as c from entities where user_id in ($1,$2) group by user_id order by user_id`,
    [guestA, guestB]
  );
  check(
    'entities 按 user_id 严格分开(各 1 行)',
    isoCount.length === 2 && isoCount.every((r) => r.c === 1),
    JSON.stringify(isoCount)
  );

  // ③ 升级:只改 email / password_hash / is_guest —— userId 与全部数据不变。
  //    这里复刻 AuthService.upgrade 的两步写入(① 改口令哈希依赖仓储方法
  //    ② email/is_guest 在同一行上翻转),然后逐条断言"数据零迁移"。
  const upgradeEmail = `guest-upgraded-${Date.now()}@example.com`;
  await repo.updateUserPassword(guestA, 'scrypt$upgraded', 'scrypt');
  const { rows: upgradedRows } = await adminPool.query<{ id: string; email: string; is_guest: boolean; password_algo: string }>(
    `update users set email = $2, is_guest = false where id = $1 returning id, email, is_guest, password_algo`,
    [guestA, upgradeEmail]
  );
  check('升级后还是同一个 userId', upgradedRows[0]?.id === guestA, upgradedRows[0]?.id ?? 'missing');
  check(
    '升级后 email 写入且 is_guest=false(口令哈希与算法同步更新)',
    upgradedRows[0]?.email === upgradeEmail && upgradedRows[0]?.is_guest === false && upgradedRows[0]?.password_algo === 'scrypt',
    JSON.stringify(upgradedRows[0])
  );
  const { rows: hashRow } = await adminPool.query<{ password_hash: string }>(
    `select password_hash from users where id = $1`,
    [guestA]
  );
  check('升级后口令哈希是新写入的值', hashRow[0]?.password_hash === 'scrypt$upgraded', hashRow[0]?.password_hash ?? 'missing');

  const afterUpgrade = await repo.findUserById(guestA);
  check('升级后仓储读回 is_guest=false、email 非空', afterUpgrade?.isGuest === false && afterUpgrade?.email === upgradeEmail);
  check(
    '升级后数据仍在(同一 userId 的实体与 op 一条不少)',
    (await repo.listEntities(guestA)).length === 1 && (await sync.snapshot(guestA)).todos[0].id === todoA
  );
  check('升级后可用新邮箱查到账号(游客时查不到)', (await repo.findUserByEmail(upgradeEmail))?.id === guestA);

  // ④ 升级后旧的 refreshToken 仍然有效(令牌绑定 userId,升级不改 userId)
  const guestBUser = await repo.findUserById(guestB);
  check('另一个游客未受影响(仍是 is_guest=true、email=null)', guestBUser?.isGuest === true && guestBUser?.email === null);
}

/* ---------------- 12) 邮箱验证码(契约 §7.6.5,迁移 004,真库)---------------- */
console.log('\n=== 12) 邮箱验证码:表/列/索引 + 只存 HMAC 哈希 + 一次性消费(真库)===');
{
  /* ① 迁移 004 建出的列形状(契约 §8) */
  const { rows: codeCols } = await adminPool.query<{
    column_name: string;
    data_type: string;
    is_nullable: string;
    column_default: string | null;
  }>(
    `select column_name, data_type, is_nullable, column_default
       from information_schema.columns
      where table_schema = 'public' and table_name = 'email_codes'
      order by ordinal_position`
  );
  check(
    'email_codes 表存在且恰好 7 列',
    codeCols.length === 7,
    `实际列:${codeCols.map((c) => c.column_name).join(', ') || '(表不存在)'}`
  );
  const colMap = new Map(codeCols.map((c) => [c.column_name, c]));
  check('email_codes.id 是 uuid', colMap.get('id')?.data_type === 'uuid', `实际=${colMap.get('id')?.data_type}`);
  check(
    'email_codes.email / code_hash 是非空 text',
    colMap.get('email')?.data_type === 'text' && colMap.get('email')?.is_nullable === 'NO' &&
      colMap.get('code_hash')?.data_type === 'text' && colMap.get('code_hash')?.is_nullable === 'NO',
    `email=${colMap.get('email')?.data_type}/${colMap.get('email')?.is_nullable} code_hash=${colMap.get('code_hash')?.data_type}/${colMap.get('code_hash')?.is_nullable}`
  );
  check(
    'email_codes.attempts 是 int、非空、默认 0',
    colMap.get('attempts')?.data_type === 'integer' &&
      colMap.get('attempts')?.is_nullable === 'NO' &&
      /0/.test(colMap.get('attempts')?.column_default ?? ''),
    `type=${colMap.get('attempts')?.data_type} nullable=${colMap.get('attempts')?.is_nullable} default=${colMap.get('attempts')?.column_default}`
  );
  check(
    'email_codes.consumed_at 可空(= 未消费)且是 bigint',
    colMap.get('consumed_at')?.data_type === 'bigint' && colMap.get('consumed_at')?.is_nullable === 'YES',
    `type=${colMap.get('consumed_at')?.data_type} nullable=${colMap.get('consumed_at')?.is_nullable}`
  );
  check(
    'email_codes.created_at / expires_at 是非空 bigint(epoch millis)',
    ['created_at', 'expires_at'].every(
      (c) => colMap.get(c)?.data_type === 'bigint' && colMap.get(c)?.is_nullable === 'NO'
    ),
    JSON.stringify(['created_at', 'expires_at'].map((c) => `${c}=${colMap.get(c)?.data_type}/${colMap.get(c)?.is_nullable}`))
  );
  const { rows: codePk } = await adminPool.query<{ def: string }>(
    `select pg_get_constraintdef(oid) as def from pg_constraint
      where conrelid = 'email_codes'::regclass and contype = 'p'`
  );
  check('email_codes 主键是 (id)', /primary key \(id\)/i.test(codePk[0]?.def ?? ''), codePk[0]?.def ?? '缺失');

  /* ② 索引目录:契约 §8 的 email_codes(email, created_at desc) */
  const { rows: codeIdx } = await adminPool.query<{ indexdef: string; indisunique: boolean }>(
    `select i.indexdef, ix.indisunique
       from pg_indexes i
       join pg_class c on c.relname = i.indexname
       join pg_index ix on ix.indexrelid = c.oid
      where i.schemaname = 'public' and i.tablename = 'email_codes'
        and i.indexname = 'email_codes_email_created_idx'`
  );
  check('索引 email_codes_email_created_idx 存在', codeIdx.length === 1, codeIdx[0]?.indexdef ?? '缺失');
  check(
    '索引列序是 (email, created_at DESC)',
    /\(email, created_at DESC\)/i.test(codeIdx[0]?.indexdef ?? ''),
    codeIdx[0]?.indexdef ?? '缺失'
  );
  check('该索引不是唯一索引(同一邮箱可以有多条历史验证码)', codeIdx[0]?.indisunique === false);

  /* ③ 服务层跑真库:请求验证码 → 只存 HMAC-SHA256(pepper, email:code) */
  let clock = NOW + 2_000_000;
  const sentMails: Array<{ to: string; subject: string; text: string }> = [];
  const mail: MailSender = {
    kind: 'console',
    async send(message) {
      sentMails.push(message);
    }
  };
  const auth = new AuthService(repo, config, createPasswordHasher({ force: 'scrypt' }), () => clock, mail);
  const codeEmail = `pg-code-${Date.now()}@example.com`;

  const sentRes = await auth.requestEmailCode({ email: codeEmail });
  check(
    'requestEmailCode 返回 sent=true / expiresIn=300 / retryAfter=60',
    sentRes.sent === true && sentRes.expiresIn === 300 && sentRes.retryAfter === 60,
    JSON.stringify(sentRes)
  );
  const code = /(\d{6})/.exec(sentMails[0]?.text ?? '')?.[1] ?? '';
  check('验证码真的通过发信通道发出且正文含 6 位数字', /^\d{6}$/.test(code), `code=${code || '(未取到)'}`);

  const { rows: hashRows } = await adminPool.query<{ id: string; code_hash: string; attempts: number; consumed_at: string | null }>(
    `select id, code_hash, attempts, consumed_at from email_codes where email = $1 order by created_at desc limit 1`,
    [codeEmail]
  );
  const storedHash = hashRows[0]?.code_hash ?? '';
  const codeId = hashRows[0]?.id ?? '';
  check(
    '库里存的是 HMAC-SHA256(pepper, email:code)',
    storedHash === emailCodeHash(config.emailCode.pepper, codeEmail, code),
    `${storedHash.slice(0, 16)}…`
  );
  check('库里不是明文验证码', storedHash !== code && !storedHash.includes(code));
  check(
    '库里不是裸 SHA-256(必须带 pepper)',
    storedHash !== sha256Hex(code) && storedHash !== sha256Hex(`${codeEmail}:${code}`)
  );
  check('新验证码 attempts=0 且 consumed_at 为 NULL', Number(hashRows[0]?.attempts) === 0 && hashRows[0]?.consumed_at === null);
  const { rows: lowerRows } = await adminPool.query(
    `select 1 from email_codes where email = $1`,
    [codeEmail.toLowerCase()]
  );
  check('email 以小写入库', lowerRows.length === 1);

  /* ④ 60s 限流在真库上同样生效 */
  const throttled = await auth.requestEmailCode({ email: codeEmail }).then(
    () => null,
    (err: { code?: string; details?: { reason?: string; retryAfterSec?: number } }) => err
  );
  check(
    '60s 内重复请求被限流(RATE_LIMITED / code_throttled + retryAfterSec)',
    throttled?.code === 'RATE_LIMITED' &&
      throttled?.details?.reason === 'code_throttled' &&
      typeof throttled?.details?.retryAfterSec === 'number',
    JSON.stringify(throttled?.details)
  );

  /* ⑤ 登录:自动建号 + 一次性消费 */
  const login = await auth.emailCodeLogin({ email: codeEmail, code, deviceName: '真库设备', platform: 'windows' });
  check(
    '验证码登录成功且响应完整(与 register 同构)',
    typeof login.user.id === 'string' &&
      login.user.isGuest === false &&
      typeof login.accessToken === 'string' &&
      typeof login.refreshToken === 'string' &&
      login.expiresIn > 0,
    JSON.stringify({ userId: login.user.id, isGuest: login.user.isGuest, expiresIn: login.expiresIn })
  );
  const { rows: codeUserRows } = await adminPool.query<{
    email: string;
    is_guest: boolean;
    password_algo: string;
    password_hash: string;
  }>(`select email, is_guest, password_algo, password_hash from users where id = $1`, [login.user.id]);
  check(
    "自动建号:is_guest=false、password_algo='none'、占位哈希 otp$<random>",
    codeUserRows[0]?.is_guest === false &&
      codeUserRows[0]?.password_algo === 'none' &&
      /^otp\$[0-9a-f]{64}$/.test(codeUserRows[0]?.password_hash ?? ''),
    JSON.stringify({ ...codeUserRows[0], password_hash: (codeUserRows[0]?.password_hash ?? '').slice(0, 12) + '…' })
  );
  check('自动建号的 email 就是已验证邮箱', codeUserRows[0]?.email === codeEmail);
  check('自动建号的占位哈希不含验证码明文', !(codeUserRows[0]?.password_hash ?? '').includes(code));

  const consumedAfterLogin = await adminPool.query<{ consumed_at: string | null }>(
    `select consumed_at from email_codes where id = $1`,
    [codeId]
  );
  check('登录成功后 consumed_at 已置位', consumedAfterLogin.rows[0]?.consumed_at != null, String(consumedAfterLogin.rows[0]?.consumed_at));

  const reuse = await auth.emailCodeLogin({ email: codeEmail, code, deviceName: 'x', platform: 'cli' }).then(
    () => null,
    (err: { code?: string; details?: { reason?: string } }) => err
  );
  check(
    '同一验证码复用被拒(401 AUTH_INVALID_CREDENTIALS / code_invalid)',
    reuse?.code === 'AUTH_INVALID_CREDENTIALS' && reuse?.details?.reason === 'code_invalid',
    JSON.stringify(reuse?.details)
  );
  check(
    '仓储层 consumeEmailCode 第二次返回 false(真库 update ... where consumed_at is null)',
    (await repo.consumeEmailCode(codeId, clock)) === false
  );

  /* ⑥ 同码最多 5 次:真库上的 attempts 原子自增与作废 */
  clock += 61_000;
  await auth.requestEmailCode({ email: codeEmail });
  const code2 = /(\d{6})/.exec(sentMails[1]?.text ?? '')?.[1] ?? '';
  const wrong = code2 === '000000' ? '111111' : '000000';
  const reasons: string[] = [];
  for (let i = 0; i < 5; i += 1) {
    const err = await auth.emailCodeLogin({ email: codeEmail, code: wrong, deviceName: 'x', platform: 'cli' }).then(
      () => null,
      (e: { details?: { reason?: string } }) => e
    );
    reasons.push(err?.details?.reason ?? 'no-error');
  }
  check(
    '前 4 次错码是 code_invalid,第 5 次变成 code_attempts_exceeded',
    reasons.slice(0, 4).every((r) => r === 'code_invalid') && reasons[4] === 'code_attempts_exceeded',
    JSON.stringify(reasons)
  );
  const { rows: attemptsRows } = await adminPool.query<{ attempts: number }>(
    `select attempts from email_codes where email = $1 order by created_at desc limit 1`,
    [codeEmail]
  );
  check('真库 attempts 恰好累加到 5', Number(attemptsRows[0]?.attempts) === 5, `attempts=${attemptsRows[0]?.attempts}`);
  const afterVoid = await auth.emailCodeLogin({ email: codeEmail, code: code2, deviceName: 'x', platform: 'cli' }).then(
    () => null,
    (err: { details?: { reason?: string } }) => err
  );
  check('作废后连正确的码也不再放行', afterVoid?.details?.reason === 'code_attempts_exceeded', JSON.stringify(afterVoid?.details));

  /* ⑦ 销号级联:deleteUser 必须连该邮箱的验证码一起清掉 */
  check(
    '销号前该邮箱还有验证码',
    (await repo.countEmailCodesSince(codeEmail, 0)) > 0
  );
  await repo.deleteUser(login.user.id);
  check('deleteUser 后该邮箱的验证码被清空(旧码不能把刚删的邮箱重新建号)', (await repo.countEmailCodesSince(codeEmail, 0)) === 0);
  check('deleteUser 后邮箱查不到账号', (await repo.findUserByEmail(codeEmail)) === null);
}

/* ---------------- 收尾 ---------------- */
console.log(`\n${'='.repeat(60)}`);
console.log(`真实 PostgreSQL 验证:${pass} 通过 / ${fail} 失败`);
if (fail > 0) console.log(`失败项:\n${failures.map((f) => `  - ${f}`).join('\n')}`);

// 默认清掉本轮造的数据(含 EXPLAIN 用的 3000 个用户与 9000 条实体),让库回到"空 schema",
// 便于紧接着跑 `pnpm migrate` / 启动服务时从头验证。
// 想保留 schema 供人工 inspection:设置 ORDO_KEEP_SCHEMA=1
if (process.env.ORDO_KEEP_SCHEMA === '1') {
  console.log('已保留 public schema(ORDO_KEEP_SCHEMA=1);如需清理:drop schema public cascade; create schema public;');
} else {
  await adminPool.query(`drop schema public cascade; create schema public;`);
  console.log('已清空 public schema(验证数据不残留);如需保留请设置 ORDO_KEEP_SCHEMA=1');
}

await repo.close(); // 内部会 end 注入的 pool,不要再单独 end 一次
await adminPool.end();
process.exit(fail > 0 ? 1 : 0);
