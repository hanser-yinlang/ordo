/**
 * PostgreSQL 仓储 —— 契约 §8 表结构(见 repo/migrations/001_init.sql)。
 * serverSeq 由 ops.server_seq(bigserial)分配,天然单调递增。
 */
import { Pool } from 'pg';
import { AnyEntity, EntityKind, OpType } from '../domain/model';
import { resolveMigrationsDir, runMigrations } from './migrate';
import {
  DeviceRow,
  EntityRow,
  NewOpRow,
  OpRow,
  RefreshTokenRow,
  ReminderRow,
  ReminderUpsert,
  Repository,
  UserRow
} from './types';

interface UserDbRow {
  id: string;
  /** 游客为 null(见迁移 003:email 可为 NULL,unique 索引默认容忍多个 NULL) */
  email: string | null;
  password_hash: string;
  password_algo: string;
  is_guest: boolean;
  created_at: string | number;
}

interface DeviceDbRow {
  id: string;
  user_id: string;
  name: string;
  platform: string;
  created_at: string | number;
  last_seen_at: string | number;
}

interface TokenDbRow {
  token_hash: string;
  user_id: string;
  device_id: string | null;
  created_at: string | number;
  expires_at: string | number;
  revoked_at: string | number | null;
  replaced_by: string | null;
}

interface EntityDbRow {
  user_id: string;
  entity: string;
  entity_id: string;
  payload: AnyEntity;
  updated_at: string | number;
  deleted: boolean;
  server_seq: string | number;
}

interface OpDbRow {
  user_id: string;
  server_seq: string | number;
  op_id: string;
  device_id: string | null;
  entity: string;
  entity_id: string;
  type: string;
  payload: AnyEntity | null;
  client_ts: string | number;
  created_at: string | number;
}

interface ReminderDbRow {
  id: string;
  user_id: string;
  todo_id: string;
  at: string | number;
  title: string;
  fired: boolean;
  updated_at: string | number;
}

const n = (v: string | number | null): number => (v == null ? 0 : typeof v === 'number' ? v : Number(v));

/**
 * 仓储实际用到的最小连接池契约。
 * `pg.Pool` 与 pg-mem 的 `adapters.createPg().Pool` 都满足它,
 * 因此同一份 PgRepository 代码可以在真实 Postgres 与内存 Postgres 上跑。
 */
export interface SqlSession {
  query<R = never>(sql: string, params?: unknown[]): Promise<SqlResult<R>>;
  release(): void;
}

export interface SqlPool {
  query<R = never>(sql: string, params?: unknown[]): Promise<SqlResult<R>>;
  connect(): Promise<SqlSession>;
  end(): Promise<void>;
}

/** query 结果里 PgRepository 真正读取的字段 */
export interface SqlResult<R> {
  rows: R[];
  rowCount?: number | null;
}

/** 把 pg.Pool / pg-mem Pool 统一收敛到 SqlPool(纯结构化,不做 instanceof 判断) */
export function asSqlPool(value: unknown): SqlPool {
  const candidate = value as Partial<SqlPool> | null;
  if (!candidate || typeof candidate.query !== 'function' || typeof candidate.connect !== 'function') {
    throw new TypeError('注入的 Pool 缺少 query()/connect(),无法作为 SQL 连接池使用');
  }
  return candidate as SqlPool;
}

export class PgRepository implements Repository {
  readonly kind = 'postgres' as const;
  private pool: SqlPool;

  /**
   * @param connectionString 连接串(构造真实 `pg.Pool`)。
   * @param poolOverride     可选:直接注入连接池,用于把仓储指向 pg-mem 的
   *                         `adapters.createPg().Pool`,从而在无 Postgres 的
   *                         环境里真实执行迁移 SQL 并验证 PgRepository。
   */
  constructor(
    private connectionString: string,
    private poolMax = 10,
    private migrationsDirCandidates: string[] = [],
    poolOverride?: SqlPool
  ) {
    this.pool = poolOverride ?? (new Pool({ connectionString, max: poolMax }) as unknown as SqlPool);
  }

  get raw(): SqlPool {
    return this.pool;
  }

  async init(): Promise<void> {
    const dir = resolveMigrationsDir(this.migrationsDirCandidates);
    await runMigrations(this.pool, dir, (msg) => console.log(msg));
  }

  async close(): Promise<void> {
    await this.pool.end();
  }

  async ping(): Promise<boolean> {
    const { rows } = await this.pool.query<{ ok: number }>('select 1 as ok');
    return rows.length === 1;
  }

  /* ---------------- users ---------------- */

  async createUser(user: UserRow): Promise<UserRow> {
    const { rows } = await this.pool.query<UserDbRow>(
      `insert into users (id, email, password_hash, password_algo, is_guest, created_at)
       values ($1,$2,$3,$4,$5,$6) returning *`,
      [
        user.id,
        user.email === null ? null : user.email.toLowerCase(),
        user.passwordHash,
        user.passwordAlgo,
        user.isGuest === true,
        user.createdAt
      ]
    );
    return mapUser(rows[0]);
  }

  async findUserByEmail(email: string): Promise<UserRow | null> {
    const { rows } = await this.pool.query<UserDbRow>(`select * from users where email = $1`, [email.toLowerCase()]);
    return rows[0] ? mapUser(rows[0]) : null;
  }

  async findUserById(id: string): Promise<UserRow | null> {
    const { rows } = await this.pool.query<UserDbRow>(`select * from users where id = $1`, [id]);
    return rows[0] ? mapUser(rows[0]) : null;
  }

  async updateUserPassword(userId: string, passwordHash: string, passwordAlgo: string): Promise<void> {
    await this.pool.query(`update users set password_hash = $2, password_algo = $3 where id = $1`, [
      userId,
      passwordHash,
      passwordAlgo
    ]);
  }

  /**
   * 游客升级为正式账号(契约 §7.6.2):`email` + `password_hash` + `is_guest = false`
   * 在**一条 UPDATE** 里完成(要么全成要么全不成,不会出现"有口令却没邮箱"的中间态)。
   * `users.id` 不变,其它表的 `user_id` 自然不变 → 数据零迁移。
   *
   * 邮箱唯一性由 `users_email_key` 兜底:并发升级到同一邮箱时,输的那一方拿到 23505
   * (AuthService.upgrade 会把它翻译成 AUTH_EMAIL_TAKEN)。
   */
  async upgradeGuestAccount(
    userId: string,
    email: string,
    passwordHash: string,
    passwordAlgo: string
  ): Promise<UserRow | null> {
    const { rows } = await this.pool.query<UserDbRow>(
      `update users
          set email = $2, password_hash = $3, password_algo = $4, is_guest = false
        where id = $1
        returning *`,
      [userId, email.toLowerCase(), passwordHash, passwordAlgo]
    );
    return rows[0] ? mapUser(rows[0]) : null;
  }

  async deleteUser(userId: string): Promise<void> {
    await this.pool.query(`delete from users where id = $1`, [userId]);
  }

  /* ---------------- devices ---------------- */

  async upsertDevice(device: DeviceRow): Promise<DeviceRow> {
    const { rows } = await this.pool.query<DeviceDbRow>(
      `insert into devices (id, user_id, name, platform, created_at, last_seen_at)
       values ($1,$2,$3,$4,$5,$6)
       on conflict (id) do update set name = excluded.name, platform = excluded.platform, last_seen_at = excluded.last_seen_at
       returning *`,
      [device.id, device.userId, device.name, device.platform, device.createdAt, device.lastSeenAt]
    );
    return mapDevice(rows[0]);
  }

  async findDevice(userId: string, deviceId: string): Promise<DeviceRow | null> {
    const { rows } = await this.pool.query<DeviceDbRow>(`select * from devices where user_id = $1 and id = $2`, [
      userId,
      deviceId
    ]);
    return rows[0] ? mapDevice(rows[0]) : null;
  }

  async listDevices(userId: string): Promise<DeviceRow[]> {
    const { rows } = await this.pool.query<DeviceDbRow>(`select * from devices where user_id = $1 order by created_at`, [
      userId
    ]);
    return rows.map(mapDevice);
  }

  /* ---------------- refresh tokens ---------------- */

  async createRefreshToken(token: RefreshTokenRow): Promise<void> {
    await this.pool.query(
      `insert into refresh_tokens (token_hash, user_id, device_id, created_at, expires_at, revoked_at, replaced_by)
       values ($1,$2,$3,$4,$5,$6,$7)`,
      [
        token.tokenHash,
        token.userId,
        token.deviceId,
        token.createdAt,
        token.expiresAt,
        token.revokedAt,
        token.replacedBy
      ]
    );
  }

  async findRefreshToken(tokenHash: string): Promise<RefreshTokenRow | null> {
    const { rows } = await this.pool.query<TokenDbRow>(`select * from refresh_tokens where token_hash = $1`, [
      tokenHash
    ]);
    return rows[0] ? mapToken(rows[0]) : null;
  }

  async revokeRefreshToken(tokenHash: string, replacedBy: string | null = null): Promise<void> {
    await this.pool.query(
      `update refresh_tokens set revoked_at = coalesce(revoked_at, $2), replaced_by = $3 where token_hash = $1`,
      [tokenHash, Date.now(), replacedBy]
    );
  }

  async revokeAllRefreshTokens(userId: string): Promise<void> {
    await this.pool.query(`update refresh_tokens set revoked_at = $2 where user_id = $1 and revoked_at is null`, [
      userId,
      Date.now()
    ]);
  }

  async deleteExpiredRefreshTokens(nowMs: number): Promise<number> {
    const res = await this.pool.query(`delete from refresh_tokens where expires_at < $1`, [nowMs]);
    return res.rowCount ?? 0;
  }

  /* ---------------- entities ---------------- */

  async getEntity(userId: string, entity: EntityKind, entityId: string): Promise<EntityRow | null> {
    const { rows } = await this.pool.query<EntityDbRow>(
      `select * from entities where user_id = $1 and entity = $2 and entity_id = $3`,
      [userId, entity, entityId]
    );
    return rows[0] ? mapEntity(rows[0]) : null;
  }

  async listEntities(userId: string, entity?: EntityKind): Promise<EntityRow[]> {
    const { rows } = entity
      ? await this.pool.query<EntityDbRow>(`select * from entities where user_id = $1 and entity = $2`, [userId, entity])
      : await this.pool.query<EntityDbRow>(`select * from entities where user_id = $1`, [userId]);
    return rows.map(mapEntity);
  }

  async putEntity(row: EntityRow): Promise<void> {
    await this.pool.query(
      `insert into entities (user_id, entity, entity_id, payload, updated_at, deleted, server_seq)
       values ($1,$2,$3,$4,$5,$6,$7)
       on conflict (user_id, entity, entity_id) do update
         set payload = excluded.payload, updated_at = excluded.updated_at,
             deleted = excluded.deleted, server_seq = excluded.server_seq`,
      [row.userId, row.entity, row.entityId, JSON.stringify(row.payload), row.updatedAt, row.deleted, row.serverSeq]
    );
  }

  async purgeTombstones(olderThanMs: number): Promise<number> {
    const res = await this.pool.query(`delete from entities where deleted = true and updated_at < $1`, [olderThanMs]);
    return res.rowCount ?? 0;
  }

  /* ---------------- ops ---------------- */

  /**
   * 追加 op 日志并分配 serverSeq(bigserial)。
   *
   * **两阶段写法**(插入 + 回查),而不是 `... returning *`:
   * pg-mem 在 `on conflict (user_id, op_id) do nothing returning *` 时会**把冲突行
   * 原样返回**(真实 Postgres 返回 0 行),那样"本次到底写入了哪些 op"就无法判断,
   * 幂等语义会被悄悄破坏。改为:
   *   ① 先记下插入前已存在的 opId 集合;
   *   ② 批量 insert ... on conflict do nothing(不带 returning,pg-mem 语义正确);
   *   ③ 回查这批 opId,排除①里已存在的,剩下的就是本次真正写入的行。
   * 语义与 `returning *` 完全等价(冲突目标就是 (user_id, op_id) 唯一索引),
   * 在真实 Postgres 上同样安全,只是多一次 SELECT。
   *
   * 注意 `ops.server_seq` 是**全局** bigserial(不是 per-user),契约只要求每个用户
   * 的 pull 顺序单调,因此天然满足。
   */
  async appendOps(ops: NewOpRow[]): Promise<OpRow[]> {
    if (ops.length === 0) return [];
    const opIds = ops.map((op) => op.opId);
    const userId = ops[0].userId;
    const client: SqlSession = await this.pool.connect();
    try {
      await client.query('begin');
      const preExisting = await this.existingOpIds(client, userId, opIds);
      for (const op of ops) {
        await client.query(
          `insert into ops (user_id, op_id, device_id, entity, entity_id, type, payload, client_ts, created_at)
           values ($1,$2,$3,$4,$5,$6,$7,$8,$9)
           on conflict (user_id, op_id) do nothing`,
          [
            op.userId,
            op.opId,
            op.deviceId,
            op.entity,
            op.entityId,
            op.type,
            op.payload === null ? null : JSON.stringify(op.payload),
            op.clientTs,
            op.createdAt
          ]
        );
      }
      const freshIds = [...(await this.existingOpIds(client, userId, opIds))].filter((opId) => !preExisting.has(opId));
      let inserted: OpDbRow[] = [];
      if (freshIds.length > 0) {
        const res = await client.query<OpDbRow>(
          `select * from ops where user_id = $1 and op_id = any($2::text[]) order by server_seq asc`,
          [userId, freshIds]
        );
        inserted = res.rows;
      }
      await client.query('commit');
      return inserted.map(mapOp);
    } catch (err) {
      await client.query('rollback').catch(() => undefined);
      throw err;
    } finally {
      client.release();
    }
  }

  private async existingOpIds(client: SqlSession, userId: string, opIds: string[]): Promise<Set<string>> {
    const { rows } = await client.query<{ op_id: string }>(
      `select op_id from ops where user_id = $1 and op_id = any($2::text[])`,
      [userId, opIds]
    );
    return new Set(rows.map((r) => r.op_id));
  }

  async opsSince(userId: string, sinceSeq: number, limit: number): Promise<OpRow[]> {
    const { rows } = await this.pool.query<OpDbRow>(
      `select * from ops where user_id = $1 and server_seq > $2 order by server_seq asc limit $3`,
      [userId, sinceSeq, limit]
    );
    return rows.map(mapOp);
  }

  async findExistingOpIds(userId: string, opIds: string[]): Promise<Set<string>> {
    if (opIds.length === 0) return new Set();
    const { rows } = await this.pool.query<{ op_id: string }>(
      `select op_id from ops where user_id = $1 and op_id = any($2::text[])`,
      [userId, opIds]
    );
    return new Set(rows.map((r) => r.op_id));
  }

  async latestSeq(userId: string): Promise<number> {
    const { rows } = await this.pool.query<{ seq: string | null }>(
      `select max(server_seq) as seq from ops where user_id = $1`,
      [userId]
    );
    return n(rows[0]?.seq ?? 0);
  }

  /* ---------------- reminders ---------------- */

  /**
   * 提醒 upsert —— 「同一提醒只投递一次」的关键 SQL。
   *
   * `fired` 的赋值**必须写在 `at` 之前**:`case when reminders.at = excluded.at ...`
   * 读的是**冲突行的原值**(PostgreSQL 文档:ON CONFLICT DO UPDATE 的 SET/WHERE
   * 通过表名访问已存在的行,通过 excluded 访问拟插入的行;UPDATE 语义下所有 SET
   * 表达式都基于旧行求值)。pg-mem 会把**前面已赋的值**泄漏给后面的表达式
   * (先写 `at = excluded.at` 会让后面的 `reminders.at` 读到新值),把 `fired`
   * 提到前面即可在两种实现下都得到"时刻变化才重新投递"的正确语义。
   */
  async upsertReminder(reminder: ReminderUpsert): Promise<void> {
    const id = `${reminder.userId}|${reminder.todoId}`;
    await this.pool.query(
      `insert into reminders (id, user_id, todo_id, at, title, fired, updated_at)
       values ($1,$2,$3,$4,$5,false,$6)
       on conflict (user_id, todo_id) do update
         set fired = case when reminders.at = excluded.at then reminders.fired else false end,
             at = excluded.at,
             title = excluded.title,
             updated_at = excluded.updated_at`,
      [id, reminder.userId, reminder.todoId, reminder.at, reminder.title, reminder.updatedAt]
    );
  }

  async deleteReminder(userId: string, todoId: string): Promise<void> {
    await this.pool.query(`delete from reminders where user_id = $1 and todo_id = $2`, [userId, todoId]);
  }

  async listDueReminders(upToMs: number): Promise<ReminderRow[]> {
    const { rows } = await this.pool.query<ReminderDbRow>(
      `select * from reminders where fired = false and at <= $1 order by at asc limit 500`,
      [upToMs]
    );
    return rows.map(mapReminder);
  }

  async claimReminder(id: string): Promise<boolean> {
    const res = await this.pool.query(`update reminders set fired = true where id = $1 and fired = false`, [id]);
    return (res.rowCount ?? 0) === 1;
  }

  async listReminders(userId: string): Promise<ReminderRow[]> {
    const { rows } = await this.pool.query<ReminderDbRow>(
      `select * from reminders where user_id = $1 order by at asc`,
      [userId]
    );
    return rows.map(mapReminder);
  }
}

function mapUser(row: UserDbRow): UserRow {
  return {
    id: row.id,
    // 迁移 003 之前建的行没有 email 概念上的 null;这里统一收敛为 null 或非空串
    email: row.email === null || row.email === '' ? null : row.email,
    passwordHash: row.password_hash,
    passwordAlgo: row.password_algo,
    // 迁移 003 之前插入的行 is_guest 由列默认值补成 false;这里再兜一层,保证返回布尔
    isGuest: row.is_guest === true,
    createdAt: n(row.created_at)
  };
}

function mapDevice(row: DeviceDbRow): DeviceRow {
  return {
    id: row.id,
    userId: row.user_id,
    name: row.name,
    platform: row.platform,
    createdAt: n(row.created_at),
    lastSeenAt: n(row.last_seen_at)
  };
}

function mapToken(row: TokenDbRow): RefreshTokenRow {
  return {
    tokenHash: row.token_hash,
    userId: row.user_id,
    deviceId: row.device_id,
    createdAt: n(row.created_at),
    expiresAt: n(row.expires_at),
    revokedAt: row.revoked_at == null ? null : n(row.revoked_at),
    replacedBy: row.replaced_by
  };
}

function mapEntity(row: EntityDbRow): EntityRow {
  return {
    userId: row.user_id,
    entity: row.entity as EntityKind,
    entityId: row.entity_id,
    payload: row.payload,
    updatedAt: n(row.updated_at),
    deleted: row.deleted,
    serverSeq: n(row.server_seq)
  };
}

function mapOp(row: OpDbRow): OpRow {
  return {
    userId: row.user_id,
    serverSeq: n(row.server_seq),
    opId: row.op_id,
    deviceId: row.device_id,
    entity: row.entity as EntityKind,
    entityId: row.entity_id,
    type: row.type as OpType,
    payload: row.payload,
    clientTs: n(row.client_ts),
    createdAt: n(row.created_at)
  };
}

function mapReminder(row: ReminderDbRow): ReminderRow {
  return {
    id: row.id,
    userId: row.user_id,
    todoId: row.todo_id,
    at: n(row.at),
    title: row.title,
    fired: row.fired,
    updatedAt: n(row.updated_at)
  };
}
