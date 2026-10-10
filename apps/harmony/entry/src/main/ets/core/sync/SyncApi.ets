/**
 * Ordo · HTTP 同步接口封装
 * 契约来源:docs/03-数据模型与同步协议.md §7.4(HTTP 接口)、§7.4 错误模型与 401 处理、§9(安全)
 *
 * 统一请求头:X-Ordo-Schema / X-Ordo-Device / X-Ordo-Client,鉴权用 Authorization: Bearer
 * 401 处理:遇 AUTH_TOKEN_EXPIRED 自动 refresh 并重放原请求一次;refresh 也失败 → 抛 AUTH_REQUIRED
 * 日志纪律:绝不打印 accessToken / refreshToken / 口令 / 备注正文。
 */

import { http } from '@kit.NetworkKit';
import { MAX_PAYLOAD_BYTES, MAX_PULL_LIMIT, Op, SCHEMA_VERSION, Snapshot } from '../model/Entities.ets';
import {
  AuthTokens,
  AuthUser,
  ERR_AUTH_REQUIRED,
  ERR_AUTH_TOKEN_EXPIRED,
  ERR_NETWORK,
  ERR_RATE_LIMITED,
  ERR_VALIDATION_FAILED,
  OrdoApiError,
  OrdoErrorDetails,
  apiError,
  apiErrorWithReason,
  errorText,
  errorTextWithReason,
  parseErrorDetails
} from './SyncTypes.ets';

/** POST /v1/auth/* 的返回 */
export interface AuthResult {
  user: AuthUser;
  tokens: AuthTokens;
}

/** 验证码有效期兜底(秒,契约 §7.6.5:300) */
export const EMAIL_CODE_DEFAULT_TTL: number = 300;
/** 再次请求的最小间隔兜底(秒,契约 §7.6.5:60) */
export const EMAIL_CODE_DEFAULT_RETRY_AFTER: number = 60;

/**
 * POST /v1/auth/email/code 的返回(契约 §7.6.5)。
 *
 * `devCode` **只在开发模式**(`ORDO_MAIL_TRANSPORT=console` 且 `ORDO_DEV_ECHO_CODE=1`)回显,
 * 生产环境恒为空串 —— 客户端只能把它当联调便利,**不得依赖**(为空时界面照常让用户手输)。
 */
export interface EmailCodeSent {
  sent: boolean;
  expiresIn: number;
  retryAfter: number;
  devCode: string;
}

/** 被服务端拒绝的 op(兼容两种下发形态:纯 opId 字符串 或 对象) */
export interface RejectedOp {
  opId: string;
  code: string;
  message: string;
}

/** POST /v1/sync/push 的返回 */
export interface PushResult {
  serverSeq: number;
  accepted: string[];
  rejected: RejectedOp[];
  ops: Op[];
  droppedOversize: string[];
}

/** GET /v1/sync/pull 的返回 */
export interface PullResult {
  serverSeq: number;
  ops: Op[];
  hasMore: boolean;
}

interface HealthBody {
  status: string;
  version: string;
  serverTime: number;
}

interface AuthBody {
  user: AuthUser;
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

/** POST /v1/auth/upgrade 的返回(契约 §7.6.2:userId 与数据都不变,只补邮箱口令) */
interface UpgradeBody {
  user: AuthUser;
}

interface PushBody {
  serverSeq: number;
  accepted: string[];
  rejected: Object[];
  ops: Op[];
}

interface PullBody {
  serverSeq: number;
  ops: Op[];
  hasMore: boolean;
}

interface RefreshBody {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

interface ErrorBody {
  error: ErrorDetail;
}

interface ErrorDetail {
  code: string;
  message: string;
  details: Object;
}

/** 归一化后的验证码受理响应(缺字段一律回落到契约默认值) */
interface EmailCodeSentBody {
  sent: boolean;
  expiresIn: number;
  retryAfter: number;
  devCode: string;
}

export class SyncApi {
  private baseUrl: string;
  private deviceId: string;
  private tokens: AuthTokens | null;

  constructor(baseUrl: string, deviceId: string) {
    this.baseUrl = baseUrl;
    this.deviceId = deviceId;
    this.tokens = null;
  }

  setTokens(tokens: AuthTokens | null): void {
    this.tokens = tokens;
  }

  getTokens(): AuthTokens | null {
    return this.tokens;
  }

  hasToken(): boolean {
    return this.tokens !== null && (this.tokens as AuthTokens).accessToken.length > 0;
  }

  getDeviceId(): string {
    return this.deviceId;
  }

  setBaseUrl(url: string): void {
    this.baseUrl = url;
  }

  /* ------------------------------------------------------------ 通用请求 */

  private headers(withAuth: boolean): Record<string, string> {
    const h: Record<string, string> = {
      'Content-Type': 'application/json',
      'X-Ordo-Schema': SCHEMA_VERSION.toString(),
      'X-Ordo-Device': this.deviceId,
      'X-Ordo-Client': 'harmony/1.0.0'
    };
    if (withAuth && this.tokens !== null) {
      h['Authorization'] = 'Bearer ' + (this.tokens as AuthTokens).accessToken;
    }
    return h;
  }

  /** 发一次请求;网络异常统一转 NETWORK_UNREACHABLE */
  private async send(method: http.RequestMethod, path: string, body: string | null, withAuth: boolean): Promise<string> {
    const request = http.createHttp();
    const options: http.HttpRequestOptions = {
      method: method,
      header: this.headers(withAuth),
      connectTimeout: 10000,
      readTimeout: 20000,
      expectDataType: http.HttpDataType.STRING
    };
    if (body !== null) {
      options.extraData = body;
    }
    let response: http.HttpResponse | null = null;
    try {
      response = await request.request(this.baseUrl + path, options);
    } catch (e) {
      request.destroy();
      const err: Error = e as Error;
      throw apiError(ERR_NETWORK, errorText(ERR_NETWORK), err === null ? '' : err.message);
    }
    request.destroy();
    const code: number = response.responseCode;
    const text: string = typeof response.result === 'string' ? response.result as string : '';
    if (code >= 200 && code < 300) {
      return text;
    }
    throw this.toApiError(code, text);
  }

  private toApiError(code: number, text: string): OrdoApiError {
    let parsedCode: string = '';
    let parsedMessage: string = '';
    let parsedReason: string = '';
    let parsedRetryAfterSec: number = 0;
    try {
      const body: ErrorBody = JSON.parse(text) as ErrorBody;
      if (body !== null && body.error !== null && body.error !== undefined) {
        parsedCode = body.error.code;
        parsedMessage = body.error.message;
        // §7.6.5:验证码类错误靠 details.reason 区分(code 仍是冻结的错误码枚举);
        // 限流秒数在错误体里叫 details.retryAfterSec(成功响应顶层才是 retryAfter)
        const details: OrdoErrorDetails = parseErrorDetails(body.error.details);
        parsedReason = details.reason;
        parsedRetryAfterSec = details.retryAfterSec;
      }
    } catch (e) {
      parsedMessage = '';
    }
    if (parsedCode.length === 0) {
      parsedCode = code === 401 ? ERR_AUTH_REQUIRED : (code === 429 ? ERR_RATE_LIMITED : ERR_VALIDATION_FAILED);
    }
    const fallback: string = errorTextWithReason(parsedCode, parsedReason);
    const shown: string = parsedMessage.length > 0 ? parsedMessage : fallback;
    return apiErrorWithReason(parsedCode, shown, 'HTTP ' + code.toString(), parsedReason, parsedRetryAfterSec);
  }

  /** 带鉴权的请求:遇 AUTH_TOKEN_EXPIRED 自动 refresh 并重放一次(契约 §7.4) */
  private async sendWithAuth(method: http.RequestMethod, path: string, body: string | null): Promise<string> {
    try {
      return await this.send(method, path, body, true);
    } catch (e) {
      const err: OrdoApiError = e as OrdoApiError;
      const isExpired: boolean = err !== null && err.code === ERR_AUTH_TOKEN_EXPIRED;
      if (!isExpired) {
        // ArkTS 只允许 throw Error 派生类型:重新抛出已归一化的 OrdoApiError
        throw err;
      }
      await this.refresh();
      return await this.send(method, path, body, true);
    }
  }

  /* -------------------------------------------------------------- 健康检查 */

  async health(): Promise<string> {
    const text: string = await this.send(http.RequestMethod.GET, '/v1/health', null, false);
    const body: HealthBody = JSON.parse(text) as HealthBody;
    return body === null ? '' : body.status;
  }

  /* ------------------------------------------------------------------ 鉴权 */

  async register(email: string, password: string, deviceName: string): Promise<AuthResult> {
    const payload: string = JSON.stringify({
      email: email,
      password: password,
      deviceName: deviceName,
      platform: 'harmony'
    });
    const text: string = await this.send(http.RequestMethod.POST, '/v1/auth/register', payload, false);
    return this.parseAuth(text);
  }

  async login(email: string, password: string, deviceName: string): Promise<AuthResult> {
    const payload: string = JSON.stringify({
      email: email,
      password: password,
      deviceName: deviceName,
      platform: 'harmony'
    });
    const text: string = await this.send(http.RequestMethod.POST, '/v1/auth/login', payload, false);
    return this.parseAuth(text);
  }

  private parseAuth(text: string): AuthResult {
    const body: AuthBody = JSON.parse(text) as AuthBody;
    const tokens: AuthTokens = {
      accessToken: body.accessToken,
      refreshToken: body.refreshToken,
      expiresIn: body.expiresIn
    };
    this.tokens = tokens;
    const result: AuthResult = { user: normalizeUser(body.user), tokens: tokens };
    return result;
  }

  /**
   * 游客登录(契约 §7.6.2 POST /v1/auth/guest)。
   * 与 register/login 同构:同样拿到正常令牌,**不是离线模式**,游客数据照样入库、照样多端同步。
   */
  async guest(deviceId: string, deviceName: string, platform: string): Promise<AuthResult> {
    const payload: string = JSON.stringify({
      deviceId: deviceId,
      deviceName: deviceName,
      platform: platform
    });
    const text: string = await this.send(http.RequestMethod.POST, '/v1/auth/guest', payload, false);
    return this.parseAuth(text);
  }

  /**
   * 游客升级为正式账号(契约 §7.6.2 POST /v1/auth/upgrade,需带 Access Token)。
   * userId 不变、数据不变,只把 email/password 补上;邮箱被占用时服务端返回 AUTH_EMAIL_TAKEN。
   */
  async upgrade(email: string, password: string): Promise<AuthUser> {
    const payload: string = JSON.stringify({ email: email, password: password });
    const text: string = await this.sendWithAuth(http.RequestMethod.POST, '/v1/auth/upgrade', payload);
    const body: UpgradeBody = JSON.parse(text) as UpgradeBody;
    return normalizeUser(body.user);
  }

  /**
   * 请求邮箱登录验证码(契约 §7.6.5 POST /v1/auth/email/code)。
   *
   * 服务端对同一邮箱 60s 内重复请求返回 429 `RATE_LIMITED`(details.reason = `code_throttled`),
   * 由调用方按"请求过频"提示并跑倒计时 —— 那不是"发信失败",不应提示用户重试发信。
   */
  async requestEmailCode(email: string): Promise<EmailCodeSent> {
    const payload: string = JSON.stringify({ email: email });
    const text: string = await this.send(http.RequestMethod.POST, '/v1/auth/email/code', payload, false);
    const body: EmailCodeSentBody = JSON.parse(text) as EmailCodeSentBody;
    return normalizeEmailCodeSent(body);
  }

  /**
   * 邮箱验证码登录(契约 §7.6.5 POST /v1/auth/email/login)。
   *
   * 响应与 register / login / guest **同构**(user + device + accessToken + refreshToken + expiresIn),
   * 因此后续流程与口令登录完全一致:同一 userId、同一份云端数据、同一套 refreshToken。
   * 邮箱未注册时由服务端自动建号(正式账号、无口令),客户端不需要区分"登录"与"注册"。
   */
  async emailLogin(email: string, code: string, deviceId: string, deviceName: string): Promise<AuthResult> {
    const payload: string = JSON.stringify({
      email: email,
      code: code,
      deviceId: deviceId,
      deviceName: deviceName,
      platform: 'harmony'
    });
    const text: string = await this.send(http.RequestMethod.POST, '/v1/auth/email/login', payload, false);
    return this.parseAuth(text);
  }

  /** 契约 §7.4:旧 refresh 轮换失效 */
  async refresh(): Promise<AuthTokens> {
    if (this.tokens === null) {
      throw apiError(ERR_AUTH_REQUIRED, errorText(ERR_AUTH_REQUIRED), '本地无 refreshToken');
    }
    const payload: string = JSON.stringify({ refreshToken: (this.tokens as AuthTokens).refreshToken });
    let text: string = '';
    try {
      text = await this.send(http.RequestMethod.POST, '/v1/auth/refresh', payload, false);
    } catch (e) {
      const err: OrdoApiError = e as OrdoApiError;
      const code: string = err !== null && err.code !== undefined ? err.code : ERR_NETWORK;
      // 网络不可用/被限流**不是**"登录失效":令牌保留,由调用方按离线处理。
      // 只有服务端明确拒绝(鉴权类错误)才清令牌转登录态,避免离线启动被踢回登录页。
      if (code === ERR_NETWORK || code === ERR_RATE_LIMITED) {
        throw apiError(code, errorText(code), 'refresh 未能送达服务端');
      }
      this.tokens = null;
      throw apiError(ERR_AUTH_REQUIRED, errorText(ERR_AUTH_REQUIRED), 'refresh 失败,需重新登录');
    }
    const body: RefreshBody = JSON.parse(text) as RefreshBody;
    const next: AuthTokens = {
      accessToken: body.accessToken,
      refreshToken: body.refreshToken,
      expiresIn: body.expiresIn
    };
    this.tokens = next;
    return next;
  }

  async logout(): Promise<void> {
    if (this.tokens === null) {
      return;
    }
    const payload: string = JSON.stringify({ refreshToken: (this.tokens as AuthTokens).refreshToken });
    try {
      await this.send(http.RequestMethod.POST, '/v1/auth/logout', payload, true);
    } catch (e) {
      // 退出登录以本地清理为准,服务端失败不阻塞
    }
    this.tokens = null;
  }

  /* ------------------------------------------------------------------ 同步 */

  async snapshot(): Promise<Snapshot> {
    const text: string = await this.sendWithAuth(http.RequestMethod.GET, '/v1/sync/snapshot', null);
    const snap: Snapshot = JSON.parse(text) as Snapshot;
    return snap;
  }

  /**
   * 推送本地 ops 并捎带拉取(契约 §7.4)。
   * 超过单条 payload 上限(256 KB)的 op 不上传,放进 droppedOversize 由调用方处理。
   */
  async push(ops: Op[], sinceSeq: number): Promise<PushResult> {
    const sendable: Op[] = [];
    const dropped: string[] = [];
    for (let i = 0; i < ops.length; i++) {
      const op: Op = ops[i];
      const size: number = op.payload === null ? 0 : (op.payload as string).length;
      if (size > MAX_PAYLOAD_BYTES) {
        dropped.push(op.opId);
      } else {
        sendable.push(op);
      }
    }
    const payload: string = JSON.stringify({ deviceId: this.deviceId, sinceSeq: sinceSeq, ops: sendable });
    const text: string = await this.sendWithAuth(http.RequestMethod.POST, '/v1/sync/push', payload);
    const body: PushBody = JSON.parse(text) as PushBody;
    const result: PushResult = {
      serverSeq: body.serverSeq,
      accepted: body.accepted === null || body.accepted === undefined ? [] : body.accepted,
      rejected: this.normalizeRejected(body.rejected),
      ops: body.ops === null || body.ops === undefined ? [] : body.ops,
      droppedOversize: dropped
    };
    return result;
  }

  /** 兼容 rejected 的两种下发形态(纯字符串 / 对象) */
  private normalizeRejected(raw: Object[]): RejectedOp[] {
    const out: RejectedOp[] = [];
    if (raw === null || raw === undefined) {
      return out;
    }
    for (let i = 0; i < raw.length; i++) {
      const item: Object = raw[i];
      if (typeof item === 'string') {
        const asId: string = item as string;
        out.push({ opId: asId, code: ERR_VALIDATION_FAILED, message: '被服务端拒绝' });
      } else {
        const obj: RejectedOp = item as RejectedOp;
        out.push({
          opId: obj.opId === undefined ? '' : obj.opId,
          code: obj.code === undefined ? ERR_VALIDATION_FAILED : obj.code,
          message: obj.message === undefined ? '被服务端拒绝' : obj.message
        });
      }
    }
    return out;
  }

  async pull(sinceSeq: number, limit: number): Promise<PullResult> {
    const safeLimit: number = limit > MAX_PULL_LIMIT ? MAX_PULL_LIMIT : (limit < 1 ? 1 : limit);
    const path: string = '/v1/sync/pull?sinceSeq=' + sinceSeq.toString() + '&limit=' + safeLimit.toString();
    const text: string = await this.sendWithAuth(http.RequestMethod.GET, path, null);
    const body: PullBody = JSON.parse(text) as PullBody;
    const result: PullResult = {
      serverSeq: body.serverSeq,
      ops: body.ops === null || body.ops === undefined ? [] : body.ops,
      hasMore: body.hasMore === true
    };
    return result;
  }
}

/**
 * 归一化 user 字段(契约 §7.6.1)。
 * 服务端可能省略 isGuest(旧版本),缺失一律按正式账号 false 处理 ——
 * 宁可把游客当成正式账号(只是展示名不同),也不能反过来把正式账号误标成游客。
 */
function normalizeUser(u: AuthUser): AuthUser {
  if (u === null || u === undefined) {
    return { id: '', email: '', isGuest: false };
  }
  const out: AuthUser = {
    id: u.id === undefined || u.id === null ? '' : u.id,
    email: u.email === undefined || u.email === null ? '' : u.email,
    isGuest: u.isGuest === true
  };
  return out;
}

/**
 * 归一化 `POST /v1/auth/email/code` 的响应。
 * 缺字段时回落到契约默认值(expiresIn 300 / retryAfter 60 / devCode 空),避免服务端少给字段
 * 就把倒计时跑成 0 秒或把 undefined 填进输入框。
 *
 * 注意:`retryAfter` 是**成功响应顶层**的字段名;错误体里是 `details.retryAfterSec`
 * (见 SyncTypes.parseErrorDetails)。
 */
function normalizeEmailCodeSent(body: EmailCodeSentBody): EmailCodeSent {
  if (body === null || body === undefined) {
    return {
      sent: false,
      expiresIn: EMAIL_CODE_DEFAULT_TTL,
      retryAfter: EMAIL_CODE_DEFAULT_RETRY_AFTER,
      devCode: ''
    };
  }
  const ttl: number = body.expiresIn === undefined || body.expiresIn === null ? 0 : body.expiresIn;
  const retry: number = body.retryAfter === undefined || body.retryAfter === null ? 0 : body.retryAfter;
  const dev: string = body.devCode === undefined || body.devCode === null ? '' : body.devCode;
  const out: EmailCodeSent = {
    sent: body.sent !== false,
    expiresIn: ttl > 0 ? ttl : EMAIL_CODE_DEFAULT_TTL,
    retryAfter: retry > 0 ? retry : EMAIL_CODE_DEFAULT_RETRY_AFTER,
    devCode: dev
  };
  return out;
}
