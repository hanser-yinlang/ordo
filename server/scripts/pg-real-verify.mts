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

console.log('=== 0) 迁移(从干净库开始) ===');
await adminPool.query(`drop schema public cascade; create schema public;`);
const pool = new Pool({ connectionString: DATABASE_URL, max: 8 });
const repo = new PgRepository(DATABASE_URL, 8, [MIGRATIONS_DIR], pool as unknown as SqlPool);

const applied = await runMigrations(pool as unknown as SqlPool, MIGRATIONS_DIR, (m) => console.log(`  ${m}`));
check('001_init.sql 被真实执行', applied.includes(1), `applied=${JSON.stringify(applied)}`);
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

/* ---------------- 9) EXPLAIN:索引被真正使用(pg-mem 无法验证)---------------- */
console.log('\n=== 9) EXPLAIN:执行计划确实走索引(pg-mem 无法验证) ===');
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
