/**
 * 统一错误模型:契约 §7.4
 *   { "error": { "code":"AUTH_REQUIRED", "message":"需要登录", "details":{} } }
 */

export type ErrorCode =
  | 'VALIDATION_FAILED'
  | 'AUTH_REQUIRED'
  | 'AUTH_INVALID_CREDENTIALS'
  | 'AUTH_TOKEN_EXPIRED'
  | 'AUTH_EMAIL_TAKEN'
  | 'SYNC_SEQ_GAP'
  | 'SYNC_OP_TOO_LARGE'
  | 'NOT_FOUND'
  | 'RATE_LIMITED'
  | 'INTERNAL';

/** 错误码 → HTTP 状态码(契约 §7.4 错误码表) */
export const ERROR_STATUS: Record<ErrorCode, number> = {
  VALIDATION_FAILED: 400,
  AUTH_REQUIRED: 401,
  AUTH_INVALID_CREDENTIALS: 401,
  AUTH_TOKEN_EXPIRED: 401,
  AUTH_EMAIL_TAKEN: 409,
  SYNC_SEQ_GAP: 409,
  SYNC_OP_TOO_LARGE: 413,
  NOT_FOUND: 404,
  RATE_LIMITED: 429,
  INTERNAL: 500
};

export interface ErrorBody {
  error: {
    code: ErrorCode;
    message: string;
    details: Record<string, unknown>;
  };
}

export class AppError extends Error {
  readonly code: ErrorCode;
  readonly status: number;
  readonly details: Record<string, unknown>;

  constructor(code: ErrorCode, message: string, details: Record<string, unknown> = {}) {
    super(message);
    this.name = 'AppError';
    this.code = code;
    this.status = ERROR_STATUS[code];
    this.details = details;
  }

  toBody(): ErrorBody {
    return { error: { code: this.code, message: this.message, details: this.details } };
  }
}

export const errors = {
  validation: (message = '请求参数不合法', details: Record<string, unknown> = {}) =>
    new AppError('VALIDATION_FAILED', message, details),
  authRequired: (message = '需要登录') => new AppError('AUTH_REQUIRED', message),
  invalidCredentials: (message = '邮箱或密码不正确') => new AppError('AUTH_INVALID_CREDENTIALS', message),
  tokenExpired: (message = '令牌已过期,请刷新或重新登录') => new AppError('AUTH_TOKEN_EXPIRED', message),
  emailTaken: (message = '该邮箱已注册') => new AppError('AUTH_EMAIL_TAKEN', message),
  /**
   * 契约 §7.6.2:`upgrade` 只对**游客**账号有意义。非游客账号调用时返回 400,
   * 并给客户端一个可判定的明确原因(error.details.reason = 'not_guest')。
   * 之所以不新增错误码:契约 §7.4 的错误码表是冻结的枚举,客户端按 code 分支;
   * 这里用 VALIDATION_FAILED(400)+ 稳定 details 既能被程序判定,又不改动契约枚举。
   */
  notGuestAccount: (email: string | null) =>
    new AppError('VALIDATION_FAILED', '该账号已是正式账号,无需升级', {
      reason: 'not_guest',
      email
    }),
  seqGap: (message = '本机 serverSeq 超前于服务端,请重新拉取快照', details: Record<string, unknown> = {}) =>
    new AppError('SYNC_SEQ_GAP', message, details),
  opTooLarge: (message = '单个 op 的 payload 超过 256 KB 上限', details: Record<string, unknown> = {}) =>
    new AppError('SYNC_OP_TOO_LARGE', message, details),
  notFound: (message = '资源不存在') => new AppError('NOT_FOUND', message),
  rateLimited: (message = '请求过于频繁,请稍后重试', details: Record<string, unknown> = {}) =>
    new AppError('RATE_LIMITED', message, details),
  /**
   * 契约 §7.6.5:邮箱验证码的三个失败原因共用 **401 AUTH_INVALID_CREDENTIALS**,
   * 用 `details.reason` 区分(code_invalid / code_expired / code_attempts_exceeded)。
   *
   * 为什么复用同一个 code:§7.4 的错误码表是**冻结枚举**,客户端按 `code` 分支;
   * 与 §7.6.2 的 `not_guest` 同一手法 —— 既不改契约枚举,又能给客户端可判定的精确原因。
   * 也不能为"验证码错误"单独造一个 400/422:那会把"验证码是否正确"从鉴权结果里泄漏出去。
   */
  invalidEmailCode: (
    reason: 'code_invalid' | 'code_expired' | 'code_attempts_exceeded',
    message: string
  ) => new AppError('AUTH_INVALID_CREDENTIALS', message, { reason }),
  /**
   * 契约 §7.6.5:同邮箱 60s / 每小时 5 / 每天 10 限流 —— 429 RATE_LIMITED + details.reason='code_throttled'。
   *
   * 秒数的字段名是 **`retryAfterSec`**(整数秒),与 §7.4 全局限流在 app.ts 里发出的
   * `details: { retryAfterSec }` 同名 —— 同一份错误模型里不出现两种叫法。
   * 注意与**成功响应体顶层**的 `retryAfter` 区分:那是"再请求的最小间隔"(固定 60),
   * 这里是"本次被拒后还要等多少秒"(按剩余时间计算,1..60)。
   */
  codeThrottled: (retryAfterSec: number, message = '发送过于频繁,请稍后再试') =>
    new AppError('RATE_LIMITED', message, { reason: 'code_throttled', retryAfterSec }),
  /** 契约 §7.6.5:发信通道失败 —— 500 INTERNAL + details.reason='mail_failed' */
  mailFailed: (message = '验证码发送失败,请稍后重试') =>
    new AppError('INTERNAL', message, { reason: 'mail_failed' }),
  internal: (message = '服务器内部错误') => new AppError('INTERNAL', message)
};

/** op 级别被拒的原因(契约 §7.3;记录在 push 响应的 rejected[] 里) */
export type OpRejectionReason =
  | 'stale' // clientTs 早于服务端 updatedAt,LWW 判负
  | 'completion_immutable' // 完成不可回滚
  | 'tombstoned' // 命中删除墓碑,旧 op 不能复活实体
  | 'project_incomplete' // 项目完成规则(§2.2 硬约束)不满足
  | 'invalid'; // payload 未通过 schema 校验

export interface OpRejection {
  opId: string;
  reason: OpRejectionReason;
  message?: string;
}
