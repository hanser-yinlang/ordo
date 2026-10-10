/**
 * 内存仓储 —— 契约 §8「无 Postgres 时自动降级为内存仓储(同一接口),用于本地开发与自动化测试」。
 * 行为语义与 PgRepository 保持一致(serverSeq 单调递增、op 幂等唯一、提醒原子领取)。
 */
import { AnyEntity, EntityKind } from '../domain/model';
import {
  DeviceRow,
  EmailCodeRow,
  EntityRow,
  NewOpRow,
  OpRow,
  RefreshTokenRow,
  ReminderRow,
  ReminderUpsert,
  Repository,
  UserRow
} from './types';

const entityKey = (userId: string, entity: EntityKind, entityId: string): string => `${userId}|${entity}|${entityId}`;
const deviceKey = (userId: string, deviceId: string): string => `${userId}|${deviceId}`;
const opKey = (userId: string, opId: string): string => `${userId}|${opId}`;

export class MemoryRepository implements Repository {
  readonly kind = 'memory' as const;

  private users = new Map<string, UserRow>();
  /** 只索引**有邮箱**的账号;游客(email = null)不入索引(契约 §7.6) */
  private usersByEmail = new Map<string, UserRow>();
  private devices = new Map<string, DeviceRow>();
  private refreshTokens = new Map<string, RefreshTokenRow>();
  private entities = new Map<string, EntityRow>();
  private ops = new Map<string, OpRow[]>();
  private opsByKey = new Map<string, OpRow>();
  private reminders = new Map<string, ReminderRow>();
  /** 邮箱验证码(契约 §7.6.5);按 id 存,查询时按 email 过滤 */
  private emailCodes = new Map<string, EmailCodeRow>();
  private seq = 0;

  async init(): Promise<void> {
    /* 内存仓储无需初始化 */
  }

  async close(): Promise<void> {
    this.users.clear();
    this.usersByEmail.clear();
    this.devices.clear();
    this.refreshTokens.clear();
    this.entities.clear();
    this.ops.clear();
    this.opsByKey.clear();
    this.reminders.clear();
    this.emailCodes.clear();
  }

  async ping(): Promise<boolean> {
    return true;
  }

  /* ---------------- users ---------------- */

  async createUser(user: UserRow): Promise<UserRow> {
    const email = user.email?.toLowerCase() ?? null;
    if (email !== null && this.usersByEmail.has(email)) {
      const err = new Error('duplicate email') as Error & { code?: string };
      err.code = '23505';
      throw err;
    }
    const row: UserRow = { ...user, email, isGuest: user.isGuest === true };
    this.users.set(row.id, row);
    // 游客(email=null)没有可索引的邮箱 —— 与 PostgreSQL 的 unique 索引一致:
    // 多个 NULL 互不冲突,因此游客可以无限创建。这也是"游客不能用 login 登录"的根因:
    // findUserByEmail 永远查不到游客。
    if (row.email !== null) this.usersByEmail.set(row.email, row);
    return { ...row };
  }

  async findUserByEmail(email: string): Promise<UserRow | null> {
    const row = this.usersByEmail.get(email.toLowerCase());
    return row ? { ...row } : null;
  }

  async findUserById(id: string): Promise<UserRow | null> {
    const row = this.users.get(id);
    return row ? { ...row } : null;
  }

  async updateUserPassword(userId: string, passwordHash: string, passwordAlgo: string): Promise<void> {
    const row = this.users.get(userId);
    if (!row) return;
    row.passwordHash = passwordHash;
    row.passwordAlgo = passwordAlgo;
    // 注意:这里**不能**再写 `this.usersByEmail.set(row.email, row)` ——
    // 游客的 email 是 null,索引里也没有它,硬写会把 null 变成索引键。
    // 索引存的就是同一个对象引用,原地改字段即可。
  }

  /** 游客升级为正式账号(契约 §7.6.2):同一行上补 email 口令并把 isGuest 置回 false */
  async upgradeGuestAccount(
    userId: string,
    email: string,
    passwordHash: string,
    passwordAlgo: string
  ): Promise<UserRow | null> {
    const row = this.users.get(userId);
    if (!row) return null;
    const normalized = email.toLowerCase();
    const owner = this.usersByEmail.get(normalized);
    if (owner && owner.id !== userId) {
      // 与 PostgreSQL 的唯一索引行为对齐:重复邮箱抛 23505
      const err = new Error('duplicate email') as Error & { code?: string };
      err.code = '23505';
      throw err;
    }
    if (row.email !== null) this.usersByEmail.delete(row.email);
    row.email = normalized;
    row.passwordHash = passwordHash;
    row.passwordAlgo = passwordAlgo;
    row.isGuest = false;
    this.usersByEmail.set(normalized, row);
    return { ...row };
  }

  async deleteUser(userId: string): Promise<void> {
    const user = this.users.get(userId);
    if (user && user.email !== null) this.usersByEmail.delete(user.email);
    // 账号删除要连验证码一起清掉(契约 §9「删除账号与全部数据」):
    // email_codes 按 email 关联,没有 user_id 外键,因此必须显式清 ——
    // 否则销号后旧验证码仍能登录,并自动把刚删掉的邮箱重新建成新账号。
    if (user && user.email !== null) {
      for (const [id, code] of [...this.emailCodes.entries()]) {
        if (code.email === user.email) this.emailCodes.delete(id);
      }
    }
    this.users.delete(userId);
    for (const key of [...this.devices.keys()]) if (key.startsWith(`${userId}|`)) this.devices.delete(key);
    for (const [hash, token] of [...this.refreshTokens.entries()]) if (token.userId === userId) this.refreshTokens.delete(hash);
    for (const key of [...this.entities.keys()]) if (key.startsWith(`${userId}|`)) this.entities.delete(key);
    for (const key of [...this.opsByKey.keys()]) if (key.startsWith(`${userId}|`)) this.opsByKey.delete(key);
    for (const [id, reminder] of [...this.reminders.entries()]) if (reminder.userId === userId) this.reminders.delete(id);
    this.ops.delete(userId);
  }

  /* ---------------- devices ---------------- */

  async upsertDevice(device: DeviceRow): Promise<DeviceRow> {
    this.devices.set(deviceKey(device.userId, device.id), { ...device });
    return { ...device };
  }

  async findDevice(userId: string, deviceId: string): Promise<DeviceRow | null> {
    const row = this.devices.get(deviceKey(userId, deviceId));
    return row ? { ...row } : null;
  }

  async listDevices(userId: string): Promise<DeviceRow[]> {
    return [...this.devices.values()].filter((d) => d.userId === userId).map((d) => ({ ...d }));
  }

  /* ---------------- refresh tokens ---------------- */

  async createRefreshToken(token: RefreshTokenRow): Promise<void> {
    this.refreshTokens.set(token.tokenHash, { ...token });
  }

  async findRefreshToken(tokenHash: string): Promise<RefreshTokenRow | null> {
    const row = this.refreshTokens.get(tokenHash);
    return row ? { ...row } : null;
  }

  async revokeRefreshToken(tokenHash: string, replacedBy: string | null = null): Promise<void> {
    const row = this.refreshTokens.get(tokenHash);
    if (!row) return;
    row.revokedAt = row.revokedAt ?? Date.now();
    row.replacedBy = replacedBy;
  }

  async revokeAllRefreshTokens(userId: string): Promise<void> {
    const now = Date.now();
    for (const row of this.refreshTokens.values()) {
      if (row.userId === userId && row.revokedAt == null) row.revokedAt = now;
    }
  }

  async deleteExpiredRefreshTokens(nowMs: number): Promise<number> {
    let removed = 0;
    for (const [hash, row] of [...this.refreshTokens.entries()]) {
      if (row.expiresAt < nowMs) {
        this.refreshTokens.delete(hash);
        removed += 1;
      }
    }
    return removed;
  }

  /* ---------------- entities ---------------- */

  async getEntity(userId: string, entity: EntityKind, entityId: string): Promise<EntityRow | null> {
    const row = this.entities.get(entityKey(userId, entity, entityId));
    return row ? { ...row, payload: clone(row.payload) } : null;
  }

  async listEntities(userId: string, entity?: EntityKind): Promise<EntityRow[]> {
    return [...this.entities.values()]
      .filter((r) => r.userId === userId && (!entity || r.entity === entity))
      .map((r) => ({ ...r, payload: clone(r.payload) }));
  }

  async putEntity(row: EntityRow): Promise<void> {
    this.entities.set(entityKey(row.userId, row.entity, row.entityId), { ...row, payload: clone(row.payload) });
  }

  async purgeTombstones(olderThanMs: number): Promise<number> {
    let removed = 0;
    for (const [key, row] of [...this.entities.entries()]) {
      if (row.deleted && row.updatedAt < olderThanMs) {
        this.entities.delete(key);
        removed += 1;
      }
    }
    return removed;
  }

  /* ---------------- ops ---------------- */

  async appendOps(ops: NewOpRow[]): Promise<OpRow[]> {
    const out: OpRow[] = [];
    for (const op of ops) {
      this.seq += 1;
      const row: OpRow = { ...op, serverSeq: this.seq };
      const list = this.ops.get(op.userId) ?? [];
      list.push(row);
      this.ops.set(op.userId, list);
      this.opsByKey.set(opKey(op.userId, op.opId), row);
      out.push({ ...row });
    }
    return out;
  }

  async opsSince(userId: string, sinceSeq: number, limit: number): Promise<OpRow[]> {
    const list = this.ops.get(userId) ?? [];
    return list
      .filter((o) => o.serverSeq > sinceSeq)
      .sort((a, b) => a.serverSeq - b.serverSeq)
      .slice(0, limit)
      .map((o) => ({ ...o }));
  }

  async findExistingOpIds(userId: string, opIds: string[]): Promise<Set<string>> {
    const found = new Set<string>();
    for (const opId of opIds) if (this.opsByKey.has(opKey(userId, opId))) found.add(opId);
    return found;
  }

  async latestSeq(userId: string): Promise<number> {
    const list = this.ops.get(userId) ?? [];
    return list.reduce((max, o) => (o.serverSeq > max ? o.serverSeq : max), 0);
  }

  /* ---------------- reminders ---------------- */

  async upsertReminder(reminder: ReminderUpsert): Promise<void> {
    const id = `${reminder.userId}|${reminder.todoId}`;
    const existing = this.reminders.get(id);
    this.reminders.set(id, {
      id,
      userId: reminder.userId,
      todoId: reminder.todoId,
      at: reminder.at,
      title: reminder.title,
      // 时间变了要重新投递;同一时间重复 upsert 不重置已投递标记
      fired: existing ? existing.fired && existing.at === reminder.at : false,
      updatedAt: reminder.updatedAt
    });
  }

  async deleteReminder(userId: string, todoId: string): Promise<void> {
    this.reminders.delete(`${userId}|${todoId}`);
  }

  async listDueReminders(upToMs: number): Promise<ReminderRow[]> {
    return [...this.reminders.values()]
      .filter((r) => !r.fired && r.at <= upToMs)
      .sort((a, b) => a.at - b.at)
      .map((r) => ({ ...r }));
  }

  async claimReminder(id: string): Promise<boolean> {
    const row = this.reminders.get(id);
    if (!row || row.fired) return false;
    row.fired = true;
    return true;
  }

  async listReminders(userId: string): Promise<ReminderRow[]> {
    return [...this.reminders.values()].filter((r) => r.userId === userId).map((r) => ({ ...r }));
  }

  /* ---------------- email login codes(契约 §7.6.5) ---------------- */

  async createEmailCode(row: EmailCodeRow): Promise<EmailCodeRow> {
    const stored: EmailCodeRow = {
      ...row,
      email: row.email.toLowerCase(),
      attempts: row.attempts ?? 0,
      consumedAt: row.consumedAt ?? null
    };
    this.emailCodes.set(stored.id, stored);
    return { ...stored };
  }

  /**
   * 最近一条(created_at 最大)。`>=` 而不是 `>`:同一毫秒内插入的多条取**后插入**的那条
   * (Map 保持插入顺序),与 PgRepository 的 `order by created_at desc, id desc` 语义对齐 ——
   * 二者都保证"最新一条"是确定性的,不依赖随机 uuid 的大小。
   */
  async latestEmailCode(email: string): Promise<EmailCodeRow | null> {
    const target = email.toLowerCase();
    let latest: EmailCodeRow | null = null;
    for (const row of this.emailCodes.values()) {
      if (row.email !== target) continue;
      if (!latest || row.createdAt >= latest.createdAt) latest = row;
    }
    return latest ? { ...latest } : null;
  }

  async consumeEmailCode(id: string, nowMs: number): Promise<boolean> {
    const row = this.emailCodes.get(id);
    if (!row || row.consumedAt != null) return false;
    row.consumedAt = nowMs;
    return true;
  }

  async incrementEmailCodeAttempts(id: string): Promise<number> {
    const row = this.emailCodes.get(id);
    if (!row) return 0;
    row.attempts += 1;
    return row.attempts;
  }

  async countEmailCodesSince(email: string, sinceMs: number): Promise<number> {
    const target = email.toLowerCase();
    let count = 0;
    for (const row of this.emailCodes.values()) {
      if (row.email === target && row.createdAt >= sinceMs) count += 1;
    }
    return count;
  }
}

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

export type { AnyEntity };
