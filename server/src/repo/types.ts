/**
 * Repository 抽象 —— 契约 §8。
 * PostgreSQL 与内存实现必须满足同一接口;没有 DATABASE_URL 时自动降级为内存仓储
 * (本地开发与自动化测试均使用内存仓储,不依赖真实 Postgres)。
 */
import { AnyEntity, EntityKind, OpType } from '../domain/model';

export interface UserRow {
  id: string;
  /**
   * **游客账号为 `null`**(契约 §7.6.1:游客没有邮箱口令)。
   *
   * 为什么用 `null` 而不是空串:PostgreSQL 的 `unique` 索引**默认允许多个 NULL**
   * (SQL 标准里 `NULL` 互不相等),因此 `email` 上的唯一约束天然容忍任意多个游客;
   * 而空串会被当成同一个值,第二个游客就再也建不出来。见迁移 003 的注释。
   */
  email: string | null;
  passwordHash: string;
  /** 'argon2id' | 'scrypt'(见 services/password.ts) */
  passwordAlgo: string;
  /**
   * 是否游客账号(契约 §7.6)。同一个 `user` 从游客升级为正式账号时**此值翻转、`id` 不变**。
   *
   * 可选:`false` 是默认值,旧调用点(测试夹具、既有代码)可以省略。
   * 两个仓储都会在读出时补齐为布尔值,因此 `repo.findUser*()` 的返回值一定是布尔。
   */
  isGuest?: boolean;
  createdAt: number;
}

export interface DeviceRow {
  id: string;
  userId: string;
  name: string;
  platform: string;
  createdAt: number;
  lastSeenAt: number;
}

export interface RefreshTokenRow {
  /** 仅存 SHA-256 哈希(契约 §9) */
  tokenHash: string;
  userId: string;
  deviceId: string | null;
  createdAt: number;
  expiresAt: number;
  revokedAt: number | null;
  replacedBy: string | null;
}

export interface EntityRow {
  userId: string;
  entity: EntityKind;
  entityId: string;
  payload: AnyEntity;
  /** = 产生该版本的 op.clientTs(LWW 依据) */
  updatedAt: number;
  deleted: boolean;
  serverSeq: number;
}

export interface OpRow {
  userId: string;
  /** 每个用户单调递增(由存储层分配) */
  serverSeq: number;
  opId: string;
  deviceId: string | null;
  entity: EntityKind;
  entityId: string;
  type: OpType;
  payload: AnyEntity | null;
  clientTs: number;
  createdAt: number;
}

export type NewOpRow = Omit<OpRow, 'serverSeq'>;

export interface ReminderRow {
  id: string;
  userId: string;
  todoId: string;
  /** 到期时刻 epoch millis */
  at: number;
  title: string;
  fired: boolean;
  updatedAt: number;
}

export interface ReminderUpsert {
  userId: string;
  todoId: string;
  at: number;
  title: string;
  updatedAt: number;
}

export interface Repository {
  readonly kind: 'postgres' | 'memory';

  init(): Promise<void>;
  close(): Promise<void>;
  ping(): Promise<boolean>;

  /* ---- users ---- */
  createUser(user: UserRow): Promise<UserRow>;
  findUserByEmail(email: string): Promise<UserRow | null>;
  findUserById(id: string): Promise<UserRow | null>;
  updateUserPassword(userId: string, passwordHash: string, passwordAlgo: string): Promise<void>;
  /**
   * 游客 → 正式账号(契约 §7.6.2):在**同一行**上补邮箱口令并把 `is_guest` 置回 false。
   * `id` 与其它表的 `user_id` 一律不动 —— 数据零迁移。
   */
  upgradeGuestAccount(userId: string, email: string, passwordHash: string, passwordAlgo: string): Promise<UserRow | null>;
  /** 删除账号与全部数据(级联) */
  deleteUser(userId: string): Promise<void>;

  /* ---- devices ---- */
  upsertDevice(device: DeviceRow): Promise<DeviceRow>;
  findDevice(userId: string, deviceId: string): Promise<DeviceRow | null>;
  listDevices(userId: string): Promise<DeviceRow[]>;

  /* ---- refresh tokens ---- */
  createRefreshToken(token: RefreshTokenRow): Promise<void>;
  findRefreshToken(tokenHash: string): Promise<RefreshTokenRow | null>;
  revokeRefreshToken(tokenHash: string, replacedBy?: string | null): Promise<void>;
  revokeAllRefreshTokens(userId: string): Promise<void>;
  deleteExpiredRefreshTokens(nowMs: number): Promise<number>;

  /* ---- entities ---- */
  getEntity(userId: string, entity: EntityKind, entityId: string): Promise<EntityRow | null>;
  listEntities(userId: string, entity?: EntityKind): Promise<EntityRow[]>;
  putEntity(row: EntityRow): Promise<void>;
  /** 清理 30 天前的墓碑(契约 §3 / §7.3) */
  purgeTombstones(olderThanMs: number): Promise<number>;

  /* ---- ops ---- */
  appendOps(ops: NewOpRow[]): Promise<OpRow[]>;
  opsSince(userId: string, sinceSeq: number, limit: number): Promise<OpRow[]>;
  findExistingOpIds(userId: string, opIds: string[]): Promise<Set<string>>;
  latestSeq(userId: string): Promise<number>;

  /* ---- reminders(Fastlane) ---- */
  upsertReminder(reminder: ReminderUpsert): Promise<void>;
  deleteReminder(userId: string, todoId: string): Promise<void>;
  listDueReminders(upToMs: number): Promise<ReminderRow[]>;
  /** 原子地把 fired 由 false 置为 true;返回 true 表示本次调用抢到了投递权(只投一次) */
  claimReminder(id: string): Promise<boolean>;
  listReminders(userId: string): Promise<ReminderRow[]>;
}
