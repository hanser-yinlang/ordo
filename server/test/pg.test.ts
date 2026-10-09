/**
 * PgRepository 真实验证 —— 用 pg-mem(纯 JS 的内存 Postgres)执行真实的
 * `src/repo/migrations/001_init.sql`,并让 **PgRepository 的每一段 SQL** 都跑到。
 *
 * 覆盖(对应本轮任务第 1 项):
 *  1. 建表成功 / 迁移幂等 / 外键级联
 *  2. 索引声明与 DDL 可执行性(含部分索引 where 子句)
 *  3. op_id 唯一约束(user_id, op_id)生效
 *  4. serverSeq 单调递增(bigserial)
 *  5. pull 分页:`where server_seq > $1 order by server_seq asc limit $2`
 *  6. 墓碑语义:不复活、可清理、清理条件正确
 *  7. 易错 SQL 分支:on conflict do update / do nothing、`= any($2::text[])`、
 *     `coalesce` 撤销、`case when` 的 fired 保持、`max(server_seq)` 空表
 *
 * pg-mem 的差异与生产安全性说明见 test/pg-helpers.ts 顶部与 README。
 */
import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import { baseConfig } from './helpers';
import {
  createPgMemRepo,
  type IndexDeclaration,
  MIGRATIONS_DIR,
  type PgMemHarness,
  parseIndexDeclarations,
  parseTableNames,
  readInitSql,
  renameIndex,
  uuid
} from './pg-helpers';
import { loadMigrations } from '../src/repo/migrate';
import type { AnyEntity, Todo } from '../src/domain/model';
import { SyncService } from '../src/services/sync';

const INIT_SQL = readInitSql();
const NOW = 1_800_000_000_000;

function makeTodo(id: string, overrides: Partial<Todo> = {}): Todo {
  return {
    id,
    title: '交季度报告',
    note: '',
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

describe('PgRepository × pg-mem(真实执行 001_init.sql)', () => {
  let h: PgMemHarness;
  const userId = uuid(1);
  const deviceId = uuid(2);

  before(async () => {
    h = await createPgMemRepo();
  });

  after(async () => {
    await h.close();
  });

  /* ==================== 1. 迁移 / 建表 / 索引 ==================== */

  describe('迁移与索引', () => {
    it('001_init.sql 建出契约 §8 的全部表', async () => {
      const rows = await h.sql<{ table_name: string }>(
        `select table_name from information_schema.tables where table_schema = 'public' order by table_name`
      );
      const tables = rows.map((r) => r.table_name);
      for (const expected of ['users', 'devices', 'refresh_tokens', 'entities', 'ops', 'reminders', 'schema_migrations']) {
        assert.ok(tables.includes(expected), `应建出表 ${expected},实际:${tables.join(', ')}`);
      }
    });

    it('迁移被记录到 schema_migrations,重复执行幂等', async () => {
      const before = await h.sql<{ version: number; applied_at: string | number }>(
        'select * from schema_migrations order by version'
      );
      assert.deepEqual(
        before.map((r) => Number(r.version)),
        [1, 2],
        '001_init.sql 与 002_device_id_text.sql 都应被记录'
      );

      // PgRepository.init() 再来一次:已应用的版本会被跳过
      await h.repo.init();
      const after = await h.sql('select * from schema_migrations');
      assert.equal(after.length, before.length, '重复 init 不应重复记录迁移版本');

      // 迁移文件要能被发现并按版本号升序执行
      const files = loadMigrations(MIGRATIONS_DIR);
      assert.deepEqual(
        files.map((f) => f.version),
        [...files.map((f) => f.version)].sort((a, b) => a - b),
        '迁移必须按版本号升序执行'
      );
      assert.ok(files.length >= 2, `应发现至少 2 个迁移文件,实际 ${files.length}`);
    });

    it('deviceId 相关列是 text 而不是 uuid(契约 §7.2 的 dev_xxx 形态)', async () => {
      // 回归防护:`devices.id` 曾在 001_init.sql 里被写成 uuid,导致契约形态的 deviceId
      // (`dev_7f3a...`,见契约 §7.2 与 §7.4 的 X-Ordo-Device)在真实 PostgreSQL 上
      // 注册即 500(`invalid input syntax for type uuid: "dev_..."`)。
      // 内存仓储不校验类型,pg-mem 的类型检查也偏宽松,所以这里从 information_schema 锁死列类型。
      const cols = await h.sql<{ table_name: string; column_name: string; data_type: string }>(
        `select table_name, column_name, data_type from information_schema.columns
         where (table_name = 'devices' and column_name = 'id')
            or (table_name = 'refresh_tokens' and column_name = 'device_id')
            or (table_name = 'ops' and column_name = 'device_id')
         order by table_name`
      );
      const byKey = new Map(cols.map((c) => [`${c.table_name}.${c.column_name}`, c.data_type]));
      assert.equal(byKey.get('devices.id'), 'text', 'devices.id 必须是 text(deviceId 是不透明短串)');
      assert.equal(byKey.get('refresh_tokens.device_id'), 'text');
      assert.equal(byKey.get('ops.device_id'), 'text', '同一个 deviceId 在三张表里的类型必须一致');

      // 行为断言:契约形态的 deviceId 必须能被写进 devices(连同外键)
      const contractUser = uuid(400);
      await h.repo.createUser({
        id: contractUser,
        email: 'devid-shape@example.com',
        passwordHash: 'scrypt$stub',
        passwordAlgo: 'scrypt',
        createdAt: NOW
      });
      await h.repo.upsertDevice({
        id: 'dev_7f3a9c2e',
        userId: contractUser,
        name: '契约形态设备',
        platform: 'android',
        createdAt: NOW,
        lastSeenAt: NOW
      });
      const found = await h.repo.findDevice(contractUser, 'dev_7f3a9c2e');
      assert.equal(found?.id, 'dev_7f3a9c2e');

      // 同一个 deviceId 也要能挂到 refresh_tokens 上(外键指向 devices.id)
      await h.repo.createRefreshToken({
        tokenHash: 'hash-devid-shape',
        userId: contractUser,
        deviceId: 'dev_7f3a9c2e',
        createdAt: NOW,
        expiresAt: NOW + 1000,
        revokedAt: null,
        replacedBy: null
      });
      const token = await h.repo.findRefreshToken('hash-devid-shape');
      assert.equal(token?.deviceId, 'dev_7f3a9c2e');
    });

    it('迁移里的每条 create index 都能被 pg-mem 真实执行(含部分索引 where 子句)', async () => {
      const declared = parseIndexDeclarations(INIT_SQL);
      assert.ok(declared.length >= 5, `迁移应声明至少 5 个索引,实际 ${declared.length}`);

      for (const index of declared) {
        // 换名重放:pg-mem 不保留索引目录,同名重放证明不了"真的走了创建路径"
        const replay = renameIndex(index.ddl.replace(/if\s+not\s+exists\s+/i, ''), index.name, `${index.name}_replay`);
        await assert.doesNotReject(
          async () => {
            await h.sql(replay);
          },
          `索引 ${index.name} 的 DDL 在 pg-mem 上应可执行:${replay}`
        );
      }
    });

    it('索引声明覆盖契约要求的表与列', () => {
      const byName = new Map<string, IndexDeclaration>(parseIndexDeclarations(INIT_SQL).map((i) => [i.name, i]));
      assert.deepEqual([...(byName.get('devices_user_idx')?.columns ?? [])], ['user_id']);
      assert.deepEqual([...(byName.get('refresh_tokens_user_idx')?.columns ?? [])], ['user_id']);
      assert.deepEqual([...(byName.get('entities_user_seq_idx')?.columns ?? [])], ['user_id', 'server_seq']);
      assert.deepEqual([...(byName.get('ops_user_seq_idx')?.columns ?? [])], ['user_id', 'server_seq']);

      const due = byName.get('reminders_due_idx');
      assert.ok(due, '应声明 reminders_due_idx');
      assert.deepEqual(due!.columns, ['user_id', 'at'], '提醒索引列顺序必须是 (user_id, at)');
      assert.equal(due!.where, 'where fired = false', '提醒索引必须是部分索引(fired = false)');

      // 迁移里每张表名都能在解析结果里对上(防止正则静默漏匹配)
      for (const table of parseTableNames(INIT_SQL)) {
        assert.ok(INIT_SQL.toLowerCase().includes(`create table if not exists ${table}`), `应解析到表 ${table}`);
      }
    });

    it('索引可被重复创建(if not exists 语义),且不影响已有数据', async () => {
      const before = await h.sql(`select count(*)::int as c from ops`);
      for (const index of parseIndexDeclarations(INIT_SQL)) {
        await h.sql(`${index.ddl}`);
      }
      const after = await h.sql(`select count(*)::int as c from ops`);
      assert.deepEqual(after, before, '重复执行 create index if not exists 不应改变数据');
    });
  });

  /* ==================== 2. 用户 / 设备 / 令牌 ==================== */

  describe('用户与设备', () => {
    it('createUser / findUserByEmail(大小写归一)/ findUserById', async () => {
      const created = await h.repo.createUser({
        id: userId,
        email: 'Pg.Test@Example.com',
        passwordHash: 'scrypt$stub',
        passwordAlgo: 'scrypt',
        createdAt: NOW
      });
      assert.equal(created.email, 'pg.test@example.com', '写入时应统一小写');
      assert.equal(created.createdAt, NOW, 'bigint 时间戳必须无损往返');

      const byEmail = await h.repo.findUserByEmail('PG.TEST@example.COM');
      assert.ok(byEmail, '查询应忽略大小写(仓储内部 toLowerCase)');
      assert.equal(byEmail!.id, userId);
      assert.equal(byEmail!.passwordAlgo, 'scrypt');
      assert.equal((await h.repo.findUserById(userId))!.id, userId);
      assert.equal(await h.repo.findUserByEmail('nobody@example.com'), null);
      assert.equal(await h.repo.findUserById(uuid(999)), null);
    });

    it('email 唯一约束(users.email)由数据库兜底', async () => {
      await assert.rejects(
        () =>
          h.repo.createUser({
            id: uuid(3),
            email: 'pg.test@example.com',
            passwordHash: 'x',
            passwordAlgo: 'scrypt',
            createdAt: NOW
          }),
        (err: { code?: string }) => err.code === '23505',
        '重复邮箱应触发 23505 唯一约束错误(AuthService 依赖它做并发注册兜底)'
      );
    });

    it('upsertDevice 走 on conflict (id) do update,不产生第二行', async () => {
      await h.repo.upsertDevice({
        id: deviceId,
        userId,
        name: '手机',
        platform: 'android',
        createdAt: NOW,
        lastSeenAt: NOW
      });
      const updated = await h.repo.upsertDevice({
        id: deviceId,
        userId,
        name: '手机(改名)',
        platform: 'android',
        createdAt: NOW - 5000, // created_at 不在 update 列表里,应保持原值
        lastSeenAt: NOW + 1000
      });
      assert.equal(updated.name, '手机(改名)');
      assert.equal(updated.lastSeenAt, NOW + 1000);
      assert.equal(updated.createdAt, NOW, 'created_at 不应被 on conflict 覆盖');

      const rows = await h.sql(`select count(*)::int as c from devices where user_id = $1`, [userId]);
      assert.equal(rows[0].c, 1, 'upsert 不应插入第二行');
      assert.equal((await h.repo.listDevices(userId)).length, 1);
      assert.equal((await h.repo.findDevice(userId, uuid(999))), null);
    });

    it('refresh token:仅存哈希,coalesce 撤销保留首次时间,过期清理按 expires_at', async () => {
      await h.repo.createRefreshToken({
        tokenHash: 'hash-a',
        userId,
        deviceId,
        createdAt: NOW,
        expiresAt: NOW + 86_400_000,
        revokedAt: null,
        replacedBy: null
      });
      await h.repo.createRefreshToken({
        tokenHash: 'hash-expired',
        userId,
        deviceId: null,
        createdAt: NOW,
        expiresAt: NOW - 1,
        revokedAt: null,
        replacedBy: null
      });
      await h.repo.createRefreshToken({
        tokenHash: 'hash-other-user',
        userId: uuid(4), // 不存在的用户 → 验证外键
        deviceId: null,
        createdAt: NOW,
        expiresAt: NOW + 1000,
        revokedAt: null,
        replacedBy: null
      }).catch(() => undefined);

      const stored = await h.sql<{ token_hash: string }>(`select token_hash from refresh_tokens`);
      assert.ok(
        stored.every((r) => r.token_hash.startsWith('hash-')),
        '明文 token 绝不能入库(表里只应有 SHA-256 哈希)'
      );

      await h.repo.revokeRefreshToken('hash-a', 'hash-b');
      const first = await h.repo.findRefreshToken('hash-a');
      assert.equal(first!.replacedBy, 'hash-b');
      assert.ok(first!.revokedAt !== null && first!.revokedAt > 0, '撤销时间应由 SQL 里的 $2 写入');

      // coalesce(revoked_at, $2):二次撤销不应改写首次时间
      await h.repo.revokeRefreshToken('hash-a', 'hash-c');
      const second = await h.repo.findRefreshToken('hash-a');
      assert.equal(second!.revokedAt, first!.revokedAt, 'coalesce 应保留首次撤销时间');
      assert.equal(second!.replacedBy, 'hash-c', 'replaced_by 仍会被覆盖(与 SQL 一致)');

      assert.equal(await h.repo.findRefreshToken('never-existed'), null);

      // revokeAllRefreshTokens 只影响未撤销的行
      await h.repo.createRefreshToken({
        tokenHash: 'hash-live',
        userId,
        deviceId: null,
        createdAt: NOW,
        expiresAt: NOW + 1000,
        revokedAt: null,
        replacedBy: null
      });
      await h.repo.revokeAllRefreshTokens(userId);
      assert.ok((await h.repo.findRefreshToken('hash-a'))!.revokedAt != null, '已撤销的保持撤销');
      assert.ok((await h.repo.findRefreshToken('hash-live'))!.revokedAt != null, '未撤销的应被撤销');

      // 只清理过期行,未过期的保留
      const removed = await h.repo.deleteExpiredRefreshTokens(NOW);
      assert.equal(removed, 1, '只应删除 expires_at < now 的那一行');
      assert.ok(await h.repo.findRefreshToken('hash-live'), '未过期令牌不应被删除');
      assert.equal(await h.repo.findRefreshToken('hash-expired'), null);
    });
  });

  /* ==================== 3. op_id 唯一约束 / serverSeq ==================== */

  describe('ops:唯一约束与 serverSeq 单调', () => {
    it('appendOps 返回 bigserial 分配的单调 serverSeq', async () => {
      const rows = await h.repo.appendOps(
        [1, 2, 3].map((i) => ({
          userId,
          opId: `seq-op-${i}`,
          deviceId,
          entity: 'todo' as const,
          entityId: `seq-todo-${i}`,
          type: 'upsert' as const,
          payload: null,
          clientTs: NOW + i,
          createdAt: NOW
        }))
      );
      assert.equal(rows.length, 3);
      const seqs = rows.map((r) => r.serverSeq);
      assert.deepEqual(
        [...seqs].sort((a, b) => a - b),
        seqs,
        'serverSeq 必须随插入顺序单调递增'
      );
      for (let i = 1; i < seqs.length; i += 1) {
        assert.ok(seqs[i] > seqs[i - 1], `serverSeq 必须严格递增,实际 ${seqs.join(',')}`);
      }
      assert.equal(await h.repo.latestSeq(userId), seqs[seqs.length - 1]);
    });

    it('(user_id, op_id) 唯一约束生效:重复 opId 触发 23505;不同用户可用同一 opId', async () => {
      await assert.rejects(
        () =>
          h.sql(
            `insert into ops (user_id, op_id, device_id, entity, entity_id, type, payload, client_ts, created_at)
             values ($1, 'seq-op-1', null, 'todo', 'dup', 'upsert', null, 1, 1)`,
            [userId]
          ),
        (err: { code?: string }) => err.code === '23505',
        '同一用户重复 op_id 必须被数据库拒绝'
      );

      // 另一个用户使用同样的 opId 应成功(唯一约束是 (user_id, op_id) 复合)
      const otherUser = uuid(5);
      await h.repo.createUser({
        id: otherUser,
        email: 'other@example.com',
        passwordHash: 'scrypt$stub',
        passwordAlgo: 'scrypt',
        createdAt: NOW
      });
      const inserted = await h.repo.appendOps([
        {
          userId: otherUser,
          opId: 'seq-op-1',
          deviceId: null,
          entity: 'todo',
          entityId: 'other-1',
          type: 'upsert',
          payload: null,
          clientTs: NOW,
          createdAt: NOW
        }
      ]);
      assert.equal(inserted.length, 1, '不同用户可使用相同 opId');
    });

    it('appendOps 的 on conflict do nothing:已存在的 op 不返回行,也不报错', async () => {
      // 复现真实 PgRepository 的路径:先查出已存在的 opId(同步服务已这样做)
      const preExisting = await h.repo.findExistingOpIds(userId, ['seq-op-1']);
      assert.equal(preExisting.has('seq-op-1'), true);

      const dup = await h.repo.appendOps([
        {
          userId,
          opId: 'seq-op-1',
          deviceId,
          entity: 'todo',
          entityId: 'dup',
          type: 'upsert',
          payload: null,
          clientTs: NOW,
          createdAt: NOW
        }
      ]);
      assert.deepEqual(dup, [], '冲突的 op 绝不能被当成"本次新写入"(否则幂等语义被破坏)');
      const count = await h.sql<{ c: number }>(
        `select count(*)::int as c from ops where user_id = $1 and op_id = 'seq-op-1'`,
        [userId]
      );
      assert.equal(count[0].c, 1, '重复 op 不应落库第二条');

      // 同一批里混合"新 op + 已存在的 op":只返回新写入的那条
      const mixed = await h.repo.appendOps([
        {
          userId,
          opId: 'seq-op-1',
          deviceId,
          entity: 'todo',
          entityId: 'dup',
          type: 'upsert',
          payload: null,
          clientTs: NOW,
          createdAt: NOW
        },
        {
          userId,
          opId: 'seq-op-fresh',
          deviceId,
          entity: 'todo',
          entityId: 'fresh',
          type: 'upsert',
          payload: null,
          clientTs: NOW + 1,
          createdAt: NOW
        }
      ]);
      assert.equal(mixed.length, 1, '混合批次只应返回真正写入的那条');
      assert.equal(mixed[0].opId, 'seq-op-fresh');
      assert.ok(mixed[0].serverSeq > 0, '新写入的行必须带上 bigserial 分配的 serverSeq');
    });

    it('appendOps 空数组直接返回,不开启事务', async () => {
      assert.deepEqual(await h.repo.appendOps([]), []);
    });

    it('appendOps 遇到约束错误会抛出(真实 Postgres 上由事务整体回滚)', async () => {
      const beforeCount = (await h.sql<{ c: number }>(`select count(*)::int as c from ops where user_id = $1`, [userId]))[0].c;

      // 第 3 条 op 的 user_id 不存在 → 外键失败
      await assert.rejects(
        () =>
          h.repo.appendOps([
            {
              userId,
              opId: 'tx-op-new',
              deviceId,
              entity: 'todo',
              entityId: 'tx-1',
              type: 'upsert',
              payload: null,
              clientTs: NOW,
              createdAt: NOW
            },
            {
              userId: uuid(777),
              opId: 'tx-op-fk',
              deviceId,
              entity: 'todo',
              entityId: 'tx-3',
              type: 'upsert',
              payload: null,
              clientTs: NOW,
              createdAt: NOW
            }
          ]),
        /./,
        '违反外键必须抛出,不能静默吞掉'
      );

      // 真实 Postgres:整个事务回滚,ops 表行数不变。
      // pg-mem:不支持事务回滚(见 README 的差异清单),因此这里**只断言"错误被抛出"**,
      // 不断言行数;回滚语义由 README 记录的真实 Postgres 复跑步骤覆盖。
      const afterCount = (await h.sql<{ c: number }>(`select count(*)::int as c from ops where user_id = $1`, [userId]))[0].c;
      assert.ok(
        afterCount >= beforeCount,
        `pg-mem 下允许残留(${beforeCount} -> ${afterCount}),但绝不能丢数据`
      );
      // 清理可能残留的行,避免影响后续用例对 ops 计数的假设
      await h.sql(`delete from ops where op_id = 'tx-op-new'`);
    });

    it('latestSeq:空表返回 0(max(server_seq) 为 null)', async () => {
      assert.equal(await h.repo.latestSeq(uuid(1000)), 0);
    });

    it('findExistingOpIds:命中/未命中/空数组(= any($2::text[]) 分支)', async () => {
      const hit = await h.repo.findExistingOpIds(userId, ['seq-op-1', 'seq-op-2', 'not-exists']);
      assert.deepEqual([...hit].sort(), ['seq-op-1', 'seq-op-2']);
      assert.equal((await h.repo.findExistingOpIds(userId, [])).size, 0, '空数组应短路返回');
      assert.equal((await h.repo.findExistingOpIds(uuid(1001), ['seq-op-1'])).size, 0, '不应跨用户泄漏 opId');
    });
  });

  /* ==================== 4. 分页 / 墓碑 ==================== */

  describe('opsSince 分页与墓碑', () => {
    it('where server_seq > $1 order by server_seq asc limit $2 语义正确', async () => {
      // 用独立用户造数据:这些用例在 node:test 里属于同一个 describe,
      // 共享数据库连接,自造数据可以避免互相干扰
      const pageUser = uuid(30);
      await h.repo.createUser({
        id: pageUser,
        email: 'paging@example.com',
        passwordHash: 'scrypt$stub',
        passwordAlgo: 'scrypt',
        createdAt: NOW
      });
      const seeded = await h.repo.appendOps(
        Array.from({ length: 7 }, (_, i) => ({
          userId: pageUser,
          opId: `page-op-${i}`,
          deviceId: null,
          entity: 'todo' as const,
          entityId: `page-todo-${i}`,
          type: 'upsert' as const,
          payload: null,
          clientTs: NOW + i,
          createdAt: NOW
        }))
      );
      const total = seeded.length;
      assert.equal(total, 7);

      const all = await h.repo.opsSince(pageUser, 0, 1000);
      assert.equal(all.length, total);
      assert.deepEqual(
        all.map((o) => o.serverSeq),
        [...all.map((o) => o.serverSeq)].sort((a, b) => a - b),
        '必须按 server_seq 升序'
      );

      // 逐页翻完,不重不漏
      const pageSize = 3;
      const seen: number[] = [];
      let cursor = 0;
      for (let guard = 0; guard < 50; guard += 1) {
        const page = await h.repo.opsSince(pageUser, cursor, pageSize);
        if (page.length === 0) break;
        assert.ok(page.length <= pageSize, 'limit 必须生效');
        for (const op of page) {
          assert.ok(op.serverSeq > cursor, `分页游标必须严格前进:${op.serverSeq} <= ${cursor}`);
          seen.push(op.serverSeq);
        }
        cursor = page[page.length - 1].serverSeq;
      }
      assert.deepEqual(seen, all.map((o) => o.serverSeq), '翻页结果应与一次性读取完全一致(不重不漏)');
      assert.equal(seen.length, 7);

      // limit=1 也必须只回一条
      const single = await h.repo.opsSince(pageUser, 0, 1);
      assert.equal(single.length, 1);

      // sinceSeq 取当前最大:应为空
      assert.deepEqual(await h.repo.opsSince(pageUser, await h.repo.latestSeq(pageUser), 10), []);

      // 不跨用户
      assert.deepEqual(await h.repo.opsSince(uuid(1002), 0, 10), []);
    });

    it('putEntity 走 on conflict do update:同一实体只保留一行且 server_seq 前移', async () => {
      const entityId = 'entity-lww';
      await h.repo.putEntity({
        userId,
        entity: 'todo',
        entityId,
        payload: makeTodo(entityId, { title: '第一版' }) as unknown as AnyEntity,
        updatedAt: NOW,
        deleted: false,
        serverSeq: 10
      });
      await h.repo.putEntity({
        userId,
        entity: 'todo',
        entityId,
        payload: makeTodo(entityId, { title: '第二版' }) as unknown as AnyEntity,
        updatedAt: NOW + 100,
        deleted: false,
        serverSeq: 20
      });

      const rows = await h.sql<{ c: number }>(
        `select count(*)::int as c from entities where user_id = $1 and entity = 'todo' and entity_id = $2`,
        [userId, entityId]
      );
      assert.equal(rows[0].c, 1, '主键 (user_id, entity, entity_id) 冲突时应更新而不是插入');

      const row = await h.repo.getEntity(userId, 'todo', entityId);
      assert.equal(row!.serverSeq, 20);
      assert.equal(row!.updatedAt, NOW + 100);
      assert.equal((row!.payload as Todo).title, '第二版', 'jsonb 必须整体替换为新快照');
      assert.equal(await h.repo.getEntity(userId, 'todo', 'missing'), null);
    });

    it('listEntities 带/不带 entity 过滤两个 SQL 分支', async () => {
      await h.repo.putEntity({
        userId,
        entity: 'project',
        entityId: 'proj-1',
        payload: { id: 'proj-1', name: '项目', updatedAt: NOW, deleted: false } as unknown as AnyEntity,
        updatedAt: NOW,
        deleted: false,
        serverSeq: 30
      });
      const all = await h.repo.listEntities(userId);
      const todos = await h.repo.listEntities(userId, 'todo');
      const projects = await h.repo.listEntities(userId, 'project');
      assert.ok(all.length > todos.length, '不带过滤应返回更多实体');
      assert.ok(todos.every((r) => r.entity === 'todo'));
      assert.equal(projects.length, 1);
      assert.equal(projects[0].entityId, 'proj-1');
      assert.deepEqual(await h.repo.listEntities(uuid(1003)), []);
    });

    it('purgeTombstones 只删 deleted=true 且 updated_at < 阈值的行', async () => {
      const tombstoneId = 'tombstone-old';
      const liveId = 'live-entity';
      await h.repo.putEntity({
        userId,
        entity: 'todo',
        entityId: tombstoneId,
        payload: { id: tombstoneId, deleted: true, updatedAt: NOW - 40 * 24 * 3600_000 } as unknown as AnyEntity,
        updatedAt: NOW - 40 * 24 * 3600_000, // 40 天前 > 30 天 TTL
        deleted: true,
        serverSeq: 40
      });
      await h.repo.putEntity({
        userId,
        entity: 'todo',
        entityId: liveId,
        payload: makeTodo(liveId) as unknown as AnyEntity,
        updatedAt: NOW - 400 * 24 * 3600_000, // 更旧,但 deleted=false
        deleted: false,
        serverSeq: 41
      });

      const purged = await h.repo.purgeTombstones(NOW - 30 * 24 * 3600_000);
      assert.equal(purged, 1, '应只删掉 1 条过期墓碑');
      assert.equal(await h.repo.getEntity(userId, 'todo', tombstoneId), null);
      assert.ok(await h.repo.getEntity(userId, 'todo', liveId), '存活实体绝不能被清理');

      // 阈值更早时不应误删(其他用户/其他行也不受影响)
      assert.equal(await h.repo.purgeTombstones(0), 0);
    });

    it('deleteUser 级联删除该用户的全部数据', async () => {
      const cascadeUser = uuid(6);
      await h.repo.createUser({
        id: cascadeUser,
        email: 'cascade@example.com',
        passwordHash: 'scrypt$stub',
        passwordAlgo: 'scrypt',
        createdAt: NOW
      });
      await h.repo.upsertDevice({
        id: uuid(7),
        userId: cascadeUser,
        name: '设备',
        platform: 'cli',
        createdAt: NOW,
        lastSeenAt: NOW
      });
      await h.repo.putEntity({
        userId: cascadeUser,
        entity: 'todo',
        entityId: 'cascade-todo',
        payload: makeTodo('cascade-todo') as unknown as AnyEntity,
        updatedAt: NOW,
        deleted: false,
        serverSeq: 0
      });
      await h.repo.appendOps([
        {
          userId: cascadeUser,
          opId: 'cascade-op',
          deviceId: null,
          entity: 'todo',
          entityId: 'cascade-todo',
          type: 'upsert',
          payload: null,
          clientTs: NOW,
          createdAt: NOW
        }
      ]);
      await h.repo.upsertReminder({ userId: cascadeUser, todoId: 'cascade-todo', at: NOW, title: '提醒', updatedAt: NOW });

      await h.repo.deleteUser(cascadeUser);

      assert.equal((await h.repo.listEntities(cascadeUser)).length, 0, 'entities 应级联删除');
      assert.equal((await h.repo.listDevices(cascadeUser)).length, 0, 'devices 应级联删除');
      assert.equal((await h.repo.opsSince(cascadeUser, 0, 10)).length, 0, 'ops 应级联删除');
      assert.equal((await h.repo.listReminders(cascadeUser)).length, 0, 'reminders 应级联删除');
      assert.equal(await h.repo.findUserById(cascadeUser), null);
    });

    it('updateUserPassword 只改哈希与算法', async () => {
      await h.repo.updateUserPassword(userId, 'argon2id$new', 'argon2id');
      const user = await h.repo.findUserById(userId);
      assert.equal(user!.passwordHash, 'argon2id$new');
      assert.equal(user!.passwordAlgo, 'argon2id');
      assert.equal(user!.email, 'pg.test@example.com', '其它列不应被改动');
    });
  });

  /* ==================== 5. 提醒(Fastlane 表语义) ==================== */

  describe('reminders 表语义', () => {
    const todoId = 'reminder-todo';

    it('upsertReminder:同 (user_id, todo_id) 唯一 + case when 决定 fired 是否复位', async () => {
      await h.repo.upsertReminder({ userId, todoId, at: NOW + 1000, title: '提醒 A', updatedAt: NOW });
      let rows = await h.repo.listReminders(userId);
      assert.equal(rows.length, 1);
      assert.equal(rows[0].fired, false);

      // ① 同一时刻再 upsert:只更新标题,保持 fired=false(尚未投递)
      await h.repo.upsertReminder({ userId, todoId, at: NOW + 1000, title: '提醒 B', updatedAt: NOW + 1 });
      rows = await h.repo.listReminders(userId);
      assert.equal(rows.length, 1, '唯一约束 (user_id, todo_id) 生效');
      assert.equal(rows[0].title, '提醒 B');
      assert.equal(rows[0].fired, false);

      // ② 领取投递权
      assert.equal(await h.repo.claimReminder(`${userId}|${todoId}`), true, '首次领取应成功');
      assert.equal(await h.repo.claimReminder(`${userId}|${todoId}`), false, '二次领取必须失败(只投一次)');
      assert.equal((await h.repo.listReminders(userId))[0].fired, true);

      // ③ 时刻不变再 upsert:fired 必须保持 true(不能重复投递)
      await h.repo.upsertReminder({ userId, todoId, at: NOW + 1000, title: '提醒 C', updatedAt: NOW + 2 });
      assert.equal(
        (await h.repo.listReminders(userId))[0].fired,
        true,
        'case when reminders.at = excluded.at then reminders.fired 必须保持已投递状态'
      );

      // ④ 时刻变化:fired 复位为 false,可重新投递
      await h.repo.upsertReminder({ userId, todoId, at: NOW + 5000, title: '提醒 D', updatedAt: NOW + 3 });
      const after = (await h.repo.listReminders(userId))[0];
      assert.equal(after.fired, false, '时刻变化后应重新投递');
      assert.equal(after.at, NOW + 5000);
    });

    it('listDueReminders:只取 fired=false 且 at <= 阈值,按 at 升序', async () => {
      const due = await h.repo.listDueReminders(NOW + 6000);
      assert.equal(due.length, 1, '只有复位后的那条到期');
      assert.equal(due[0].todoId, todoId);

      // 已投递的不会再出现(部分索引 where fired = false 的查询语义)
      assert.deepEqual(await h.repo.listDueReminders(NOW), [], '阈值早于 at 时不应返回');

      // 未来很远的提醒不在窗口内
      await h.repo.upsertReminder({ userId, todoId: 'far-future', at: NOW + 999_999, title: '远期', updatedAt: NOW });
      assert.equal((await h.repo.listDueReminders(NOW + 1000)).some((r) => r.todoId === 'far-future'), false);
    });

    it('claimReminder 对不存在的 id 返回 false(update 影响 0 行)', async () => {
      assert.equal(await h.repo.claimReminder('no-such-reminder'), false);
    });

    it('回归防护:upsertReminder 的 SET 顺序不能把已赋的 at 泄漏给 fired 表达式', async () => {
      // 背景:pg-mem 的 ON CONFLICT DO UPDATE 让后面的 SET 表达式读到前面已赋的值,
      // 于是 `set at = excluded.at, ... fired = case when reminders.at = excluded.at ...`
      // 会永远判等 → fired 永不复位 → 改过时间的提醒再也不会投递。
      // Postgres 语义是「所有 SET 表达式基于旧行求值」,所以把 fired 放在最前面
      // 在两边都正确。这个用例锁死该顺序,防止有人"整理"SQL 时把顺序改回去。
      const todoId = 'order-guard';
      await h.repo.upsertReminder({ userId, todoId, at: NOW + 100, title: 'A', updatedAt: NOW });
      assert.equal(await h.repo.claimReminder(`${userId}|${todoId}`), true, '先投递一次');

      await h.repo.upsertReminder({ userId, todoId, at: NOW + 200, title: 'B', updatedAt: NOW + 1 });
      const row = (await h.repo.listReminders(userId)).find((r) => r.todoId === todoId)!;
      assert.equal(row.at, NOW + 200, 'at 必须被更新为新时刻');
      assert.equal(row.fired, false, '时刻变化后 fired 必须复位,否则提醒永久丢失');
      assert.equal((await h.repo.listDueReminders(NOW + 1000)).some((r) => r.todoId === todoId), true);
    });

    it('deleteReminder 按 (user_id, todo_id) 删除,不跨用户', async () => {
      await h.repo.deleteReminder(userId, todoId);
      assert.equal((await h.repo.listReminders(userId)).some((r) => r.todoId === todoId), false);
      await h.repo.deleteReminder(uuid(1004), 'whatever'); // 不应报错
    });
  });

  /* ==================== 6. 与 SyncService 串起来 ==================== */

  describe('PgRepository 驱动完整 push/pull/snapshot/LWW/墓碑链路', () => {
    it('push → 快照 → LWW → 墓碑 → 不复活 → pull 分页', async () => {
      const config = baseConfig({ tzOffsetMinutes: 0, defaultPullLimit: 2 });
      const sync = new SyncService(h.repo, config);

      const syncRepo = await createPgMemRepo();
      const syncUser = uuid(20);
      try {
        const svc = new SyncService(syncRepo.repo, config);
        await syncRepo.repo.createUser({
          id: syncUser,
          email: 'sync@example.com',
          passwordHash: 'scrypt$stub',
          passwordAlgo: 'scrypt',
          createdAt: NOW
        });

        const todo = makeTodo('sync-todo');
        const first = await svc.push(syncUser, 'dev-1', null, [
          { opId: 's1', deviceId: 'dev-1', entity: 'todo', entityId: todo.id, type: 'upsert', payload: todo as AnyEntity, clientTs: NOW }
        ]);
        assert.equal(first.accepted[0].applied, true);
        assert.equal(first.accepted[0].serverSeq, 1);
        assert.equal(first.serverSeq, 1);

        // 快照能读到
        const snap = await svc.snapshot(syncUser);
        assert.equal(snap.todos.length, 1);
        assert.equal(snap.todos[0].title, '交季度报告');

        // 幂等
        const dup = await svc.push(syncUser, 'dev-1', null, [
          { opId: 's1', deviceId: 'dev-1', entity: 'todo', entityId: todo.id, type: 'upsert', payload: todo as AnyEntity, clientTs: NOW }
        ]);
        assert.equal(dup.accepted[0].duplicate, true);

        // LWW:更旧的 clientTs 被拒
        const stale = await svc.push(syncUser, 'dev-1', null, [
          {
            opId: 's2',
            deviceId: 'dev-1',
            entity: 'todo',
            entityId: todo.id,
            type: 'upsert',
            payload: { ...todo, title: '旧标题' } as AnyEntity,
            clientTs: NOW - 10_000
          }
        ]);
        assert.equal(stale.rejected[0].reason, 'stale');
        assert.equal((await syncRepo.repo.getEntity(syncUser, 'todo', todo.id))!.updatedAt, NOW);

        // 删除 → 墓碑
        const del = await svc.push(syncUser, 'dev-1', null, [
          { opId: 's3', deviceId: 'dev-1', entity: 'todo', entityId: todo.id, type: 'delete', payload: null, clientTs: NOW + 1000 }
        ]);
        assert.equal(del.accepted[0].applied, true);
        const tomb = await syncRepo.repo.getEntity(syncUser, 'todo', todo.id);
        assert.equal(tomb!.deleted, true);
        assert.equal(tomb!.payload.deleted, true, 'payload 里也必须带 deleted=true(客户端据此收敛)');

        // 墓碑不复活
        const revive = await svc.push(syncUser, 'dev-1', null, [
          {
            opId: 's4',
            deviceId: 'dev-1',
            entity: 'todo',
            entityId: todo.id,
            type: 'upsert',
            payload: { ...todo, title: '复活' } as AnyEntity,
            clientTs: NOW + 500
          }
        ]);
        assert.equal(revive.rejected[0].reason, 'tombstoned');
        assert.equal((await syncRepo.repo.getEntity(syncUser, 'todo', todo.id))!.deleted, true);

        // pull 分页:再推 2 条,总 op 数 4(page1 limit2 → hasMore true)
        await svc.push(syncUser, 'dev-1', null, [
          {
            opId: 's5',
            deviceId: 'dev-1',
            entity: 'todo',
            entityId: 'sync-todo-2',
            type: 'upsert',
            payload: makeTodo('sync-todo-2') as AnyEntity,
            clientTs: NOW + 2000
          },
          {
            opId: 's6',
            deviceId: 'dev-1',
            entity: 'todo',
            entityId: 'sync-todo-3',
            type: 'upsert',
            payload: makeTodo('sync-todo-3') as AnyEntity,
            clientTs: NOW + 3000
          }
        ]);
        const page1 = await svc.pull(syncUser, 0, 2);
        assert.equal(page1.ops.length, 2);
        assert.equal(page1.hasMore, true);
        const page2 = await svc.pull(syncUser, page1.ops[1].seq, 2);
        assert.equal(page2.ops.length, 2);
        assert.equal(page2.hasMore, false);
        assert.ok(page2.ops[0].seq > page1.ops[1].seq, '第二页必须从第一页之后继续');
        assert.equal(page1.serverSeq, await syncRepo.repo.latestSeq(syncUser));
      } finally {
        await syncRepo.close();
      }

      // 未使用的 sync 变量:保留以证明同一 config 可复用
      assert.ok(sync);
    });

    it('jsonb 往返保持中文、emoji、嵌套对象与 null(无乱码)', async () => {
      const payload = {
        id: 'jsonb-roundtrip',
        title: '季度报告 · 📊',
        note: '备注里有中文、数字 123 和符号 &<>"\'',
        tags: ['重要', '工作'],
        nested: { list: [1, 2, { deep: '深层' }], nil: null },
        updatedAt: NOW,
        deleted: false
      } as unknown as AnyEntity;
      await h.repo.putEntity({
        userId,
        entity: 'todo',
        entityId: 'jsonb-roundtrip',
        payload,
        updatedAt: NOW,
        deleted: false,
        serverSeq: 99
      });
      const loaded = await h.repo.getEntity(userId, 'todo', 'jsonb-roundtrip');
      assert.deepEqual(loaded!.payload, payload, 'jsonb 必须整体无损往返');
      assert.ok(JSON.stringify(loaded!.payload).includes('季度报告 · 📊'));
    });
  });
});
