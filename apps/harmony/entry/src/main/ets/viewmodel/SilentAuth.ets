/**
 * Ordo · 静默匿名会话(产品决策:不再需要登录,v1.4)
 *
 * 背景:登录界面与门禁整体移除,但**云同步要保留** —— 于是会话改成"后台静默建立":
 * 启动读会话 → 有效直接用;过期先 refresh;失败或无会话 → 静默 `POST /v1/auth/guest` 建匿名账号;
 * **网络不可达也照常进主界面**(离线可用),失败就退避重试,不阻塞、不弹界面。
 * 遇 401 → 静默重建匿名会话后继续。
 *
 * 为什么抽成纯逻辑:退避节奏、"现在该不该重试"、离线首启时用本地占位目录还是切到匿名账号目录,
 * 这些判定都含时间量与状态迁移,塞进 AppStore 里既测不了也容易写错。
 * 本文件不依赖 ArkUI / @kit,可被宿主机直接执行(见 SilentAuth.test.ets)。
 */

import { OrdoSessionHelper } from '../core/session/OrdoSession.ets';

/** 静默会话的状态机阶段 */
export type SilentAuthPhase =
  /** 已有可用会话,不需要做任何事 */
  | 'ready'
  /** 正在建会话(guest / refresh),界面不受影响 */
  | 'creating'
  /** 上次失败,等退避到点再试(离线可用) */
  | 'waiting';

/** 启动时该走哪条路(纯判定,便于用例钉住"有效 / 过期 / 无会话"三分支) */
export type SessionStartupPlan =
  /** 会话有效:直接用它进主界面 */
  | 'use'
  /** 有会话但 accessToken 过期:先用 refreshToken 续期 */
  | 'refresh'
  /** 没有会话:静默建匿名账号 */
  | 'create';

/** 首次重试等待 2s,指数退避,上限 60s */
export const ANON_BACKOFF_BASE_MS: number = 2000;
export const ANON_BACKOFF_MAX_MS: number = 60000;

/** 本机稳定账号目录标识前缀(契约 §7.6.6:形态自定,这里用 `local-<16hex>`) */
export const LOCAL_ACCOUNT_ID_PREFIX: string = 'local-';

/**
 * 启动分支判定。
 * @param hasSession 应用级 kv 里有没有会话
 * @param expired    会话的 accessToken 是否已过期(`OrdoSessionHelper.isExpired`)
 */
export function planStartup(hasSession: boolean, expired: boolean): SessionStartupPlan {
  if (!hasSession) {
    return 'create';
  }
  return expired ? 'refresh' : 'use';
}

/**
 * 钉住本地数据目录标识(**契约 §7.6.6**)。
 *
 * 目录标识 = **本机稳定账号标识**,不是服务端 `userId`:首次运行生成并持久化,
 * 此后**永不因会话重建而改变**。理由:没有登录界面之后,
 * "离线首启 → 联网拿到会话"与"同步 401 → 静默重建匿名会话"都会拿到**新的**服务端 userId;
 * 目录若跟着 userId 走,用户就会觉得数据丢了。
 *
 * @param storedId     kv `ordo.localAccountId` 里已钉住的值('' = 还没有)
 * @param legacyUserId 老版本(拿服务端 userId 当目录名)留下的会话 userId('' = 没有)
 * @returns 该用的目录标识;返回 '' 表示需要新生成一个(`newLocalAccountId`)
 */
export function planAccountDirId(storedId: string, legacyUserId: string): string {
  if (storedId.length > 0) {
    return storedId;
  }
  if (legacyUserId.length > 0) {
    // 升级路径:老版本就是按 `userDataDirName(userId)` 建的目录 —— 继续沿用,不做迁移
    return OrdoSessionHelper.userDataDirName(legacyUserId);
  }
  return '';
}

/** 目录标识是否已经钉住 */
export function hasPinnedAccountDir(dirId: string): boolean {
  return dirId.length > 0;
}

/**
 * 生成一个**本机稳定**目录标识:`local-<16hex>`。
 * 由 `seed` 决定(建议 `deviceId + ':' + 时间戳`),同 seed 同结果,便于用例断言。
 */
export function newLocalAccountId(seed: string): string {
  return LOCAL_ACCOUNT_ID_PREFIX + seedHex16(seed);
}

/** FNV-1a 32 位哈希(两次不同偏移拼成 16 个 hex 字符)—— 只为"稳定且够分散",不做安全用途 */
function fnv1a(text: string, offset: number): number {
  let h: number = offset;
  for (let i = 0; i < text.length; i++) {
    h = h ^ text.charCodeAt(i);
    // h * 16777619:用移位加法避免超出安全整数
    h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
  }
  return h >>> 0;
}

function toHex8(value: number): string {
  let s: string = (value >>> 0).toString(16);
  while (s.length < 8) {
    s = '0' + s;
  }
  return s;
}

/** seed → 16 个 hex 字符 */
export function seedHex16(seed: string): string {
  const a: number = fnv1a(seed, 0x811c9dc5);
  const b: number = fnv1a(seed + '#ordo', 0x01000193);
  return toHex8(a) + toHex8(b);
}

/** 指数退避(毫秒):2s、4s、8s…上限 60s。attempt 从 1 开始 */
export function anonBackoffMs(attempt: number): number {
  if (attempt < 1) {
    return ANON_BACKOFF_BASE_MS;
  }
  let ms: number = ANON_BACKOFF_BASE_MS;
  for (let i = 1; i < attempt && ms < ANON_BACKOFF_MAX_MS; i++) {
    ms = ms * 2;
  }
  return ms > ANON_BACKOFF_MAX_MS ? ANON_BACKOFF_MAX_MS : ms;
}

/**
 * 静默会话状态机:只记"在不在建、失败几次、下次什么时候能再试"。
 * 网络调用本身留在 AppStore(它才有 SyncApi),这里负责节奏。
 */
export class SilentAuthMachine {
  private phase: SilentAuthPhase = 'ready';
  private attempts: number = 0;
  private nextRetryAt: number = 0;

  getPhase(): SilentAuthPhase {
    return this.phase;
  }

  /** 已经失败的次数(诊断/状态栏用) */
  attemptsMade(): number {
    return this.attempts;
  }

  /** 开始一次建会话(界面不受影响) */
  begin(now: number): void {
    this.phase = 'creating';
    this.nextRetryAt = 0;
  }

  /** 成功:回到稳态并清空退避 */
  succeed(): void {
    this.phase = 'ready';
    this.attempts = 0;
    this.nextRetryAt = 0;
  }

  /**
   * 失败:累加次数并排下一次重试时刻。
   * @returns 下一次重试的等待毫秒数(调用方据此排定时器)
   */
  fail(now: number): number {
    this.attempts = this.attempts + 1;
    const wait: number = anonBackoffMs(this.attempts);
    this.phase = 'waiting';
    this.nextRetryAt = now + wait;
    return wait;
  }

  /** 现在能不能发起重试(建会话中不问、退避未到不问) */
  canRetry(now: number): boolean {
    if (this.phase === 'creating') {
      return false;
    }
    return now >= this.nextRetryAt;
  }

  /** 距下次可重试还剩多少毫秒(0 = 现在就可以) */
  remainingMs(now: number): number {
    if (this.phase === 'creating' || this.phase === 'ready') {
      return 0;
    }
    const left: number = this.nextRetryAt - now;
    return left > 0 ? left : 0;
  }

  /** 退出/重置(本端没有退出登录了,留给测试与容错路径) */
  reset(): void {
    this.phase = 'ready';
    this.attempts = 0;
    this.nextRetryAt = 0;
  }

  /** 状态栏一行文案(离线首启时告诉用户"还在后台重试",不弹窗) */
  label(): string {
    if (this.phase === 'creating') {
      return '正在建立同步会话…';
    }
    if (this.phase === 'waiting') {
      return '离线可用 · 稍后自动重连';
    }
    return '已就绪';
  }
}
