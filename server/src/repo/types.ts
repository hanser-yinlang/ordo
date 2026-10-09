/**
 * Repository 抽象 —— 契约 §8。
 * PostgreSQL 与内存实现必须满足同一接口;没有 DATABASE_URL 时自动降级为内存仓储
 * (本地开发与自动化测试均使用内存仓储,不依赖真实 Postgres)。
 */
import { AnyEntity, EntityKind, OpType } from '../domain/model';

export interface UserRow {
  id: string;
  email: string;
  passwordHash: string;
  /** 'argon2id' | 'scrypt'(见 services/password.ts) */
  passwordAlgo: string;
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
