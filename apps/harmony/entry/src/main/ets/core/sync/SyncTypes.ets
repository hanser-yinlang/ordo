/**
 * Ordo · 同步层对外类型(接口边界)
 * 契约来源:docs/03-数据模型与同步协议.md §7(同步协议 v1)
 *
 * 本文件只放**类型与常量**,不含实现:
 *  - OrdoEngine 依赖 OpSink(把远端 op 交给引擎落地)
 *  - SyncEngine 依赖 OpSource(从引擎取快照与本地状态)
 * 这样引擎与同步引擎之间不产生循环依赖。
 */

import { EntityKind, Op, OpType, Tombstone } from '../model/Entities.ets';

/* ------------------------------------------------------------- 合并结果 */

/** 契约 §7.3 合并判定结果 */
export type ApplyOutcome = 'applied' | 'stale' | 'ignored' | 'tombstoned' | 'invalid';

export interface ApplyResult {
  outcome: ApplyOutcome;
  entity: EntityKind;
  entityId: string;
  /** 人类可读原因,便于日志与测试断言(不打印备注正文与令牌,契约 §9) */
  reason: string;
}

export function applyResult(outcome: ApplyOutcome, entity: EntityKind, entityId: string, reason: string): ApplyResult {
  const r: ApplyResult = { outcome: outcome, entity: entity, entityId: entityId, reason: reason };
  return r;
}

/* ------------------------------------------------------------- 引擎边界 */

/** 同步引擎把远端 Op 落地的入口(由 OrdoEngine 实现) */
export interface OpSink {
  applyRemoteOp(op: Op): ApplyResult;
  /** 全量快照覆盖(SEQ_GAP 重拉时使用) */
  applySnapshot(json: string): Promise<boolean>;
}

/** 同步引擎读取本地状态与 outbox 的入口(由 OrdoEngine 实现) */
export interface OpSource {
  /** 取本地全量快照(契约 §7.4 snapshot 结构) */
  exportSnapshot(): string;
  /** 取待推送的 ops(契约 §7.4 单次 ≤ 500) */
  takePendingOps(limit: number): Op[];
  /** 推送成功后从 outbox 移除 */
  confirmPushed(opIds: string[]): void;
  /** 当前 lastServerSeq */
  getLastServerSeq(): number;
  /** 记录服务端返回的 serverSeq */
  setLastServerSeq(seq: number): void;
  /** 本地墓碑集合(契约 §7.3.5) */
  listTombstones(): Tombstone[];
  /** 生成一条 upsert op(用于"把本地未同步实体补推") */
  buildOp(entity: EntityKind, entityId: string, type: OpType): Op | null;
}

/* ------------------------------------------------------------- 同步状态 */

export type SyncPhase = 'idle' | 'syncing' | 'offline' | 'error' | 'authRequired';

export interface SyncStatus {
  phase: SyncPhase;
  lastServerSeq: number;
  pendingCount: number;
  lastErrorCode: string | null;
  lastErrorText: string | null;
  lastSyncAt: number;
  realtimeConnected: boolean;
}

export function idleStatus(): SyncStatus {
  const s: SyncStatus = {
    phase: 'idle',
    lastServerSeq: 0,
    pendingCount: 0,
    lastErrorCode: null,
    lastErrorText: null,
    lastSyncAt: 0,
    realtimeConnected: false
  };
  return s;
}

/** 同步状态的中文展示(状态栏用,契约 §3 布局) */
export function phaseLabel(p: SyncPhase): string {
  if (p === 'syncing') {
    return '同步中';
  }
  if (p === 'offline') {
    return '离线';
  }
  if (p === 'error') {
    return '同步失败';
  }
  if (p === 'authRequired') {
    return '需要登录';
  }
  return '已同步';
}

/* ------------------------------------------------------------- 账号与令牌 */

export interface AuthUser {
  id: string;
  email: string;
  /** 契约 §7.6.1:游客账号 email 为空且 isGuest = true;正式账号为 false */
  isGuest: boolean;
}

export interface AuthTokens {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

/* ------------------------------------------------------------- 实时通道 */

/** 契约 §7.5 服务端 → 客户端消息类型 */
export type WsInboundType = 'hello' | 'ops' | 'reminder' | 'ping';
/** 契约 §7.5 客户端 → 服务端消息类型 */
export type WsOutboundType = 'subscribe' | 'ack' | 'pong';

export interface WsHello {
  type: 'hello';
  serverSeq: number;
  serverTime: number;
}

export interface WsOps {
  type: 'ops';
  serverSeq: number;
  ops: Op[];
}

/** Fastlane 提醒推送(契约 §7.5) */
export interface WsReminder {
  type: 'reminder';
  todoId: string;
  title: string;
  at: string;
}

export interface WsPing {
  type: 'ping';
  t: number;
}

/** WS 心跳与退避参数(契约 §7.5:ping/pong 心跳;指数退避重连) */
export class RealtimePolicy {
  /** 心跳间隔:25 秒(小于常见 30 秒空闲断开阈值) */
  static readonly HEARTBEAT_MS: number = 25000;
  /** 心跳超时:10 秒无 pong 视为断线 */
  static readonly HEARTBEAT_TIMEOUT_MS: number = 10000;
  /** 指数退避基数 1s,上限 30s */
  static readonly BACKOFF_BASE_MS: number = 1000;
  static readonly BACKOFF_MAX_MS: number = 30000;
  /** 退避抖动 ±20% */
  static readonly BACKOFF_JITTER: number = 0.2;

  static backoffDelay(attempt: number): number {
    const raw: number = RealtimePolicy.BACKOFF_BASE_MS * Math.pow(2, attempt);
    const capped: number = raw > RealtimePolicy.BACKOFF_MAX_MS ? RealtimePolicy.BACKOFF_MAX_MS : raw;
    const jitter: number = capped * RealtimePolicy.BACKOFF_JITTER * (Math.random() * 2 - 1);
    const out: number = capped + jitter;
    return out < 0 ? 0 : Math.round(out);
  }
}

/* ------------------------------------------------------------- 错误模型 */

/** 契约 §7.4 错误码 */
export const ERR_VALIDATION_FAILED: string = 'VALIDATION_FAILED';
export const ERR_AUTH_REQUIRED: string = 'AUTH_REQUIRED';
export const ERR_AUTH_INVALID_CREDENTIALS: string = 'AUTH_INVALID_CREDENTIALS';
export const ERR_AUTH_TOKEN_EXPIRED: string = 'AUTH_TOKEN_EXPIRED';
export const ERR_AUTH_EMAIL_TAKEN: string = 'AUTH_EMAIL_TAKEN';
/** 本地补充:游客账号调用 login(无口令可校验)—— 契约 §7.6.2 的错误说明 */
export const ERR_AUTH_GUEST_NEEDS_RESTORE: string = 'AUTH_GUEST_NEEDS_RESTORE';
export const ERR_SYNC_SEQ_GAP: string = 'SYNC_SEQ_GAP';
export const ERR_SYNC_OP_TOO_LARGE: string = 'SYNC_OP_TOO_LARGE';
export const ERR_NOT_FOUND: string = 'NOT_FOUND';
export const ERR_RATE_LIMITED: string = 'RATE_LIMITED';
export const ERR_INTERNAL: string = 'INTERNAL';
export const ERR_NETWORK: string = 'NETWORK_UNREACHABLE';

/**
 * 同步错误(契约 §7.4)。
 *
 * 必须是 Error 的子类:ArkTS 的 arkts-limited-throw 规则只允许 throw Error 及其派生类型,
 * 抛普通对象会在编译期报错。
 */
export class OrdoApiError extends Error {
  code: string;
  details: string;
  /**
   * 服务端 `error.details.reason`(契约 §7.6.5)。
   * 错误码表(§7.4)是**冻结枚举**,不再新增 `code`;更精确的场景靠 reason 区分,
   * 例如 `AUTH_INVALID_CREDENTIALS` + `code_invalid` / `code_expired` / `code_attempts_exceeded`。
   * 没有 reason 的错误一律为空串,由调用方回落到 `errorText(code)`。
   */
  reason: string;
  /**
   * 服务端 `error.details.retryAfterSec`(整数秒,契约 §7.6.5)。
   *
   * **注意字段名**:成功响应体顶层是 `retryAfter`,而**错误体里**统一是 `retryAfterSec`
   * (`{"error":{"code":"RATE_LIMITED","details":{"reason":"code_throttled","retryAfterSec":42}}}`),
   * 两者不要混用。缺失或非正数一律为 0,由调用方回落到契约的 60s 兜底。
   */
  retryAfterSec: number;

  constructor(code: string, message: string, details: string, reason: string, retryAfterSec: number) {
    super(message);
    this.name = 'OrdoApiError';
    this.code = code;
    this.details = details;
    this.reason = reason;
    this.retryAfterSec = retryAfterSec;
  }
}

export function apiError(code: string, message: string, details: string): OrdoApiError {
  return new OrdoApiError(code, message, details, '', 0);
}

/** 带 details.reason / details.retryAfterSec 的错误(§7.6.5:验证码类错误) */
export function apiErrorWithReason(
  code: string,
  message: string,
  details: string,
  reason: string,
  retryAfterSec: number
): OrdoApiError {
  return new OrdoApiError(code, message, details, reason, retryAfterSec);
}

/* ------------------------------------------------------------- 错误原因(§7.6.5) */

/** 验证码错误 / 过期 / 尝试超限(均为 401 AUTH_INVALID_CREDENTIALS + reason) */
/**
 * `error.details` 里我们关心的字段:`reason` + `retryAfterSec`。
 * 两者都可能缺(不同错误只带其中一个),解析结果一律归一化:没有 → 空串 / 0。
 *
 * v1.4:登录/验证码界面移除后,客户端不再按 reason 生成界面文案
 * (那套 `code_invalid / code_expired / code_attempts_exceeded / code_throttled` → 中文提示
 * 的映射已随 §7.6.5 的验证码登录一起删除);这里保留的是**解析能力**,
 * 供日志/排障与后续状态机使用。
 */
export interface OrdoErrorDetails {
  reason: string;
  retryAfterSec: number;
}

/**
 * details 的"原始形状":字段在运行期可能是 undefined / null / 别的类型,
 * 因此按 `Object` 收下再用 `typeof` 判型 —— 不做 `=== undefined` 这种与静态类型冲突的比较。
 */
interface RawErrorDetails {
  reason: Object;
  retryAfterSec: Object;
}

/**
 * 解析 `error.details`(契约 §7.6.5)。
 *
 * 字段名务必区分:**成功响应顶层**是 `retryAfter`,**错误体里**是 `retryAfterSec`。
 * 传进来的若不是对象 / 字段名不对 / 类型不对,一律返回 `{reason:'', retryAfterSec:0}`,
 * 由调用方回落到契约的 60s 兜底与通用错误文案。
 */
export function parseErrorDetails(details: Object): OrdoErrorDetails {
  const out: OrdoErrorDetails = { reason: '', retryAfterSec: 0 };
  if (details === null || details === undefined) {
    return out;
  }
  const raw: RawErrorDetails = details as RawErrorDetails;
  const reason: Object = raw.reason;
  if (typeof reason === 'string') {
    out.reason = reason as string;
  }
  const seconds: Object = raw.retryAfterSec;
  if (typeof seconds === 'number') {
    const value: number = seconds as number;
    const whole: number = Math.floor(value);
    out.retryAfterSec = whole > 0 ? whole : 0;
  }
  return out;
}

/** 错误码 → 中文提示 */
export function errorText(code: string): string {
  if (code === ERR_AUTH_REQUIRED) {
    return '需要登录';
  }
  if (code === ERR_AUTH_GUEST_NEEDS_RESTORE) {
    // 契约 §7.6.2:游客账号没有口令可校验,不能引导去登录页
    return '游客账号没有口令,请用「以游客身份继续」恢复会话';
  }
  if (code === ERR_AUTH_INVALID_CREDENTIALS) {
    return '邮箱或密码不正确';
  }
  if (code === ERR_AUTH_TOKEN_EXPIRED) {
    return '登录已过期';
  }
  if (code === ERR_AUTH_EMAIL_TAKEN) {
    return '该邮箱已注册';
  }
  if (code === ERR_SYNC_SEQ_GAP) {
    return '同步序号不连续,正在重新拉取';
  }
  if (code === ERR_RATE_LIMITED) {
    return '操作过于频繁,请稍后再试';
  }
  if (code === ERR_NETWORK) {
    return '网络不可用,已离线保存';
  }
  if (code === ERR_VALIDATION_FAILED) {
    return '数据校验失败,请升级客户端';
  }
  return '服务异常,请稍后重试';
}
