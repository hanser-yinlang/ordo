/**
 * 认证服务 —— 契约 §7.4 / §9。
 *  - access token:JWT HS256,有效期 30 分钟(config.accessTtlSec)
 *  - refresh token:256-bit 随机串,服务端**仅存 SHA-256 哈希**,30 天,刷新即轮换失效
 *  - 邮箱验证码登录(§7.6.5,v1.3):验证码只存 HMAC-SHA256,一次性消费、同码最多 5 次
 */
import { createHmac, randomBytes, randomInt, randomUUID, timingSafeEqual } from 'node:crypto';
import jwt from 'jsonwebtoken';
import { z } from 'zod';
import { AppConfig } from '../config';
import { AppError, errors } from '../domain/errors';
import { DeviceRow, EmailCodeRow, RefreshTokenRow, Repository, UserRow } from '../repo/types';
import { createMailSender, MailSender } from './mail';
import { PasswordHasher, sha256Hex, validatePasswordStrength } from './password';

export const RegisterInputSchema = z.object({
  email: z.string().trim().min(3).max(200).email('邮箱格式不正确'),
  password: z.string().min(1, '口令不能为空'),
  deviceName: z.string().trim().max(100).optional(),
  platform: z.string().trim().max(50).optional(),
  deviceId: z.string().trim().max(100).optional()
});

export const LoginInputSchema = z.object({
  email: z.string().trim().min(3).max(200),
  password: z.string().min(1),
  deviceName: z.string().trim().max(100).optional(),
  platform: z.string().trim().max(50).optional(),
  deviceId: z.string().trim().max(100).optional()
});

export const RefreshInputSchema = z.object({ refreshToken: z.string().min(10).max(500) });
export const LogoutInputSchema = z.object({ refreshToken: z.string().min(10).max(500) });

/** 游客登录(契约 §7.6.2):只需设备信息,不要求邮箱口令 */
export const GuestInputSchema = z.object({
  deviceName: z.string().trim().max(100).optional(),
  platform: z.string().trim().max(50).optional(),
  deviceId: z.string().trim().max(100).optional()
});

/** 游客升级为正式账号(契约 §7.6.2):需带 Access Token,body 为 {email,password} */
export const UpgradeGuestInputSchema = z.object({
  email: z.string().trim().min(3).max(200).email('邮箱格式不正确'),
  password: z.string({ required_error: '口令不能为空' }).min(1, '口令不能为空')
});

export const DeviceRegisterInputSchema = z.object({
  deviceId: z.string().trim().min(1).max(100),
  name: z.string().trim().max(100).optional(),
  platform: z.string().trim().max(50).optional()
});

/* ---- 邮箱验证码登录(契约 §7.6.5,v1.3 新增)---- */

/** `POST /v1/auth/email/code` 的 body:`{email}` */
export const EmailCodeRequestSchema = z.object({
  email: z.string().trim().min(3).max(200).email('邮箱格式不正确')
});

/**
 * `POST /v1/auth/email/login` 的 body。
 *
 * 契约 §7.6.5 的表格把 `deviceId` / `deviceName` / `platform` 都写成**可选**,
 * 共享核心的 `EmailCodeLoginRequest` 里 `deviceName` / `platform` 是无默认值的必填字段。
 * 服务端取二者的**并集**:全部可选 —— 满足契约表格,也不会拒绝按共享核心 DTO 发来的请求
 * (它与 register/login 一样,缺省时由服务端补 '未命名设备' / 'unknown')。
 */
export const EmailCodeLoginSchema = z.object({
  email: z.string().trim().min(3).max(200).email('邮箱格式不正确'),
  // 契约 §7.6.5:验证码是 6 位数字;格式不对属于 400 VALIDATION_FAILED(不是 401)
  code: z.string().trim().regex(/^\d{6}$/, '验证码必须是 6 位数字'),
  deviceId: z.string().trim().max(100).optional(),
  deviceName: z.string().trim().max(100).optional(),
  platform: z.string().trim().max(50).optional()
});

export type RegisterInput = z.infer<typeof RegisterInputSchema>;
export type LoginInput = z.infer<typeof LoginInputSchema>;
export type GuestInput = z.infer<typeof GuestInputSchema>;
export type UpgradeGuestInput = z.infer<typeof UpgradeGuestInputSchema>;
export type EmailCodeRequestInput = z.infer<typeof EmailCodeRequestSchema>;
export type EmailCodeLoginInput = z.infer<typeof EmailCodeLoginSchema>;

/** `POST /v1/auth/email/code` 的响应(契约 §7.6.5,对应共享核心 `EmailCodeSent`) */
export interface EmailCodeSentResult {
  sent: true;
  /** 验证码有效期(秒),默认 300 */
  expiresIn: number;
  /** 同一邮箱再次请求的最小间隔(秒),默认 60 */
  retryAfter: number;
  /** **仅开发模式**回显(console 通道 + ORDO_DEV_ECHO_CODE=1 + 非生产);生产恒不出现 */
  devCode?: string;
}

/**
 * 验证码哈希:契约 §7.6.5 / §9 硬约束 —— `HMAC-SHA256(pepper, email + ':' + code)`。
 *
 * 为什么必须是 HMAC 而不是裸 SHA-256:6 位数字只有 1e6 种可能,拿到裸哈希就能离线爆破;
 * 加上只有服务端知道的 pepper,库被拖走也无法反推验证码。
 * email 参与哈希,保证同一个 6 位码对不同邮箱得到不同哈希(与限流按邮箱一一对应)。
 */
export function emailCodeHash(pepper: string, email: string, code: string): string {
  return createHmac('sha256', pepper).update(`${email.toLowerCase()}:${code}`, 'utf8').digest('hex');
}

/** 契约 §7.6.2 的 `user` 投影:register / login / guest / refresh **同构** */
export interface PublicUser {
  id: string;
  /** 游客为 null(契约 §7.6.1) */
  email: string | null;
  /** 游客为 true;正式账号(含由游客升级而来)为 false */
  isGuest: boolean;
  createdAt: number;
}

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

export interface AuthResult extends TokenPair {
  user: PublicUser;
  device: DeviceRow;
}

export interface AccessIdentity {
  userId: string;
  deviceId: string | null;
}

export class AuthService {
  private dummyHash: string | null = null;

  constructor(
    private repo: Repository,
    private config: AppConfig,
    private hasher: PasswordHasher,
    private now: () => number = Date.now,
    private mail: MailSender = createMailSender(config)
  ) {}

  get passwordAlgo(): string {
    return this.hasher.algo;
  }

  async register(input: RegisterInput): Promise<AuthResult> {
    const email = input.email.toLowerCase();
    const pwError = validatePasswordStrength(input.password);
    if (pwError) throw errors.validation(pwError, { field: 'password' });

    const existing = await this.repo.findUserByEmail(email);
    if (existing) throw errors.emailTaken();

    const user: UserRow = {
      id: randomUUID(),
      email,
      passwordHash: await this.hasher.hash(input.password),
      passwordAlgo: this.hasher.algo,
      isGuest: false,
      createdAt: this.now()
    };

    try {
      await this.repo.createUser(user);
    } catch (err) {
      if (isUniqueViolation(err)) throw errors.emailTaken();
      throw err;
    }

    const device = await this.upsertDevice(user.id, input);
    const tokens = await this.issueTokens(user.id, device.id);
    return { user: publicUser(user), device, ...tokens };
  }

  async login(input: LoginInput): Promise<AuthResult> {
    const email = input.email.toLowerCase();
    const user = await this.repo.findUserByEmail(email);
    if (!user) {
      // 抹平「邮箱不存在」与「口令错误」的耗时差异,降低账号枚举风险
      await this.burnPasswordCheck(input.password);
      throw errors.invalidCredentials();
    }
    if (user.isGuest === true || user.passwordAlgo === 'none') {
      // 契约 §7.6.2 / §7.6.5:
      //  · 游客账号没有口令可校验;
      //  · 由**邮箱验证码**自动创建的账号同样没有口令(`password_algo = 'none'`,
      //    占位哈希 `otp$<random>`)。
      // 两者都一律按"凭据不正确"处理,不单独返回"这是游客/无口令账号"的错误码 ——
      // 邮箱是调用方自己提供的,回 AUTH_INVALID_CREDENTIALS 与"邮箱不存在/口令错误"
      // 不可区分,不泄漏账号是否存在、是否无口令。
      // 同时照常做一次哈希校验,保持与其它失败分支相同的耗时特征。
      await this.burnPasswordCheck(input.password);
      throw errors.invalidCredentials();
    }
    const ok = await this.hasher.verify(user.passwordHash, input.password);
    if (!ok) throw errors.invalidCredentials();

    const device = await this.upsertDevice(user.id, input);
    const tokens = await this.issueTokens(user.id, device.id);
    return { user: publicUser(user), device, ...tokens };
  }

  /**
   * 游客登录(契约 §7.6.2)—— 创建一个**匿名账号**:
   * `email = null`、`isGuest = true`,并签发与 register/login 完全一样的令牌。
   *
   * **游客不是离线模式**:这一步就把用户写进 `users` 表(带一个随机占位哈希,
   * 永不匹配任何口令),之后 push/pull/WS/Fastlane 全部按正常用户走,
   * 数据同样入库、同样多端同步(同一 userId 换 deviceId 再调一次 guest 是不同的账号,
   * 恢复会话请用 refreshToken,见契约 §7.6.2)。
   */
  async guest(input: GuestInput): Promise<AuthResult> {
    const user: UserRow = {
      id: randomUUID(),
      email: null,
      // 无口令可校验 —— 存一个 256-bit 随机串当占位哈希(绝不留空、绝不存明文)。
      // login 对游客直接短路成 AUTH_INVALID_CREDENTIALS,这个哈希永远不会被用到。
      passwordHash: `guest$${randomBytes(32).toString('hex')}`,
      passwordAlgo: 'none',
      isGuest: true,
      createdAt: this.now()
    };
    await this.repo.createUser(user);

    const device = await this.upsertDevice(user.id, input);
    const tokens = await this.issueTokens(user.id, device.id);
    return { user: publicUser(user), device, ...tokens };
  }

  /**
   * 把当前游客账号升级为正式账号(契约 §7.6.2):
   * **userId 不变、全部数据不变**,只补上邮箱口令并把 `is_guest` 置回 false。
   *
   * 幂等性:升级后同一个 userId 再调一次会走 `not_guest` 分支(400);
   * 用同一个邮箱再调一次会走 `AUTH_EMAIL_TAKEN`(409),两者都不改动任何数据。
   */
  async upgrade(userId: string, input: UpgradeGuestInput): Promise<{ user: PublicUser }> {
    const pwError = validatePasswordStrength(input.password);
    if (pwError) throw errors.validation(pwError, { field: 'password' });

    const user = await this.repo.findUserById(userId);
    if (!user) throw errors.authRequired('访问令牌对应的账号不存在');

    if (user.isGuest !== true) {
      throw errors.notGuestAccount(user.email);
    }

    const email = input.email.toLowerCase();
    const owner = await this.repo.findUserByEmail(email);
    // 邮箱被别人占用 → AUTH_EMAIL_TAKEN(自己占用自己是不可能的:升级前 email 为 null)
    if (owner && owner.id !== user.id) throw errors.emailTaken();

    const passwordHash = await this.hasher.hash(input.password);
    // 一条 UPDATE 完成 email + 口令 + is_guest 翻转:users.id 与其它表里的 user_id
    // (devices / entities / ops / reminders / refresh_tokens)一律不动 —— 数据零迁移。
    let upgraded: UserRow | null;
    try {
      upgraded = await this.repo.upgradeGuestAccount(user.id, email, passwordHash, this.hasher.algo);
    } catch (err) {
      // 并发升级到同一邮箱时由数据库唯一索引兜底
      if (isUniqueViolation(err)) throw errors.emailTaken();
      throw err;
    }
    if (!upgraded) throw errors.authRequired('访问令牌对应的账号不存在');

    return { user: publicUser(upgraded) };
  }

  /* ==================== 邮箱验证码登录(契约 §7.6.5,v1.3)==================== */

  /**
   * 请求邮箱验证码:`POST /v1/auth/email/code` → 202 `{sent,expiresIn,retryAfter[,devCode]}`。
   *
   * 三步硬约束:
   *   ① **限流**(按邮箱):60s 内重复请求、每小时 > 5、每天 > 10 → 429 `RATE_LIMITED`
   *      + `details.reason='code_throttled'` + `retryAfterSec`;
   *   ② **发信**:走可插拔 `MailSender`;失败 → 500 `INTERNAL` + `details.reason='mail_failed'`;
   *   ③ **只存哈希**:库里落 `HMAC-SHA256(pepper, email:code)`,明文只存在于这封邮件里。
   *
   * 顺序上"先发信、后落库":发信失败时既不占用限流额度(用户可立刻重试),
   * 也不会在库里留下一条永远发不出去的验证码。
   * 邮件正文与"该邮箱是否已注册"**无关**(契约 §7.6.5),避免账号枚举。
   */
  async requestEmailCode(input: EmailCodeRequestInput): Promise<EmailCodeSentResult> {
    const email = input.email.toLowerCase();
    const cfg = this.config.emailCode;
    const now = this.now();

    // ①-a 60s 间隔:按最近一条验证码的 created_at 计算,并回一个精确的 retryAfter
    const latest = await this.repo.latestEmailCode(email);
    if (latest) {
      const windowMs = cfg.retryAfterSec * 1000;
      const elapsedMs = now - latest.createdAt;
      if (elapsedMs < windowMs) {
        throw errors.codeThrottled(Math.max(1, Math.ceil((windowMs - elapsedMs) / 1000)));
      }
    }
    // ①-b 每小时 / 每天上限。retryAfterSec 返回**整个窗口长度**(保守上界:
    // 等这么久之后,窗口内一定不再有历史请求,必然放行;契约只要求带 retryAfter 秒)。
    const hourly = await this.repo.countEmailCodesSince(email, now - 3_600_000);
    if (hourly >= cfg.maxPerHour) {
      throw errors.codeThrottled(3600, `同一邮箱每小时最多请求 ${cfg.maxPerHour} 次验证码`);
    }
    const daily = await this.repo.countEmailCodesSince(email, now - 86_400_000);
    if (daily >= cfg.maxPerDay) {
      throw errors.codeThrottled(86_400, `同一邮箱每天最多请求 ${cfg.maxPerDay} 次验证码`);
    }

    const code = generateEmailCode();
    try {
      // ② 发信。注意:失败时**不要**把通道错误原样抛给客户端(可能带网关细节),
      // 统一收敛成 INTERNAL + mail_failed;细节留给日志(不含验证码)。
      await this.mail.send({
        to: email,
        subject: 'Ordo 登录验证码',
        text: buildEmailCodeText(code, cfg.ttlSec)
      });
    } catch {
      throw errors.mailFailed();
    }

    // ③ 只存哈希:绝不明文、绝不裸 SHA-256(契约 §9)
    const row: EmailCodeRow = {
      id: randomUUID(),
      email,
      codeHash: emailCodeHash(cfg.pepper, email, code),
      attempts: 0,
      consumedAt: null,
      createdAt: now,
      expiresAt: now + cfg.ttlSec * 1000
    };
    await this.repo.createEmailCode(row);

    const result: EmailCodeSentResult = {
      sent: true,
      expiresIn: cfg.ttlSec,
      retryAfter: cfg.retryAfterSec
    };
    if (this.shouldEchoDevCode()) result.devCode = code;
    return result;
  }

  /**
   * 验证码登录:`POST /v1/auth/email/login` → 200,响应与 register/login **完全同构**。
   *
   * 账号语义(契约 §7.6.5 硬约束):
   *   · 邮箱未注册 → **自动建号**:`is_guest=false`、`email=<已验证邮箱>`、
   *     `password_algo='none'`、占位哈希 `otp$<random>`;
   *   · 邮箱已注册 → 直接登录该账号,**绝不修改其口令**(原本是游客升级来的账号行为不变)。
   *
   * 失败原因(全部 401 `AUTH_INVALID_CREDENTIALS`,靠 `details.reason` 区分):
   *   · 没有验证码 / 已消费 / 已作废 → `code_invalid`
   *   · 过期                          → `code_expired`
   *   · 尝试次数达到上限(≥5)        → `code_attempts_exceeded`
   */
  async emailCodeLogin(input: EmailCodeLoginInput): Promise<AuthResult> {
    const email = input.email.toLowerCase();
    const cfg = this.config.emailCode;
    const now = this.now();

    const row = await this.repo.latestEmailCode(email);
    if (!row || row.consumedAt != null) {
      // 没有验证码,或这条验证码已经被成功用掉了(一次性消费,契约 §7.6.5)
      throw errors.invalidEmailCode('code_invalid', '验证码不正确或已失效,请重新获取');
    }
    if (row.attempts >= cfg.maxAttempts) {
      // 达到/超过上限即作废:即使这次填对了也不再放行,必须重新获取
      throw errors.invalidEmailCode('code_attempts_exceeded', '验证码尝试次数过多,请重新获取');
    }
    if (row.expiresAt <= now) {
      throw errors.invalidEmailCode('code_expired', '验证码已过期,请重新获取');
    }

    const expected = emailCodeHash(cfg.pepper, email, input.code);
    if (!timingSafeEqualHex(expected, row.codeHash)) {
      const attempts = await this.repo.incrementEmailCodeAttempts(row.id);
      if (attempts >= cfg.maxAttempts) {
        // 第 5 次错误直接回报"次数超限",客户端据此提示用户重新获取
        throw errors.invalidEmailCode('code_attempts_exceeded', '验证码尝试次数过多,请重新获取');
      }
      throw errors.invalidEmailCode('code_invalid', '验证码不正确');
    }

    // 一次性消费:只有抢到消费权的那个请求能继续拿令牌(并发下也只有一个)
    const consumed = await this.repo.consumeEmailCode(row.id, now);
    if (!consumed) {
      throw errors.invalidEmailCode('code_invalid', '验证码已被使用,请重新获取');
    }

    const user = await this.ensureEmailUser(email);
    const device = await this.upsertDevice(user.id, input);
    const tokens = await this.issueTokens(user.id, device.id);
    return { user: publicUser(user), device, ...tokens };
  }

  /**
   * 刷新:旧 refresh 立即失效(轮换),重放旧令牌会撤销该用户全部会话。
   *
   * 契约 §7.6.2 要求 refresh 的响应也带上 `user.isGuest`,因此这里除了令牌还返回
   * user/device —— 与 register/login 同构(令牌本身与 userId 绑定,
   * 游客升级不改 userId,所以**升级前签发的 refreshToken 升级后依然有效**)。
   */
  async refresh(rawToken: string): Promise<AuthResult> {
    const tokenHash = sha256Hex(rawToken);
    const row = await this.repo.findRefreshToken(tokenHash);
    if (!row) throw errors.tokenExpired('刷新令牌无效,请重新登录');
    if (row.revokedAt != null) {
      await this.repo.revokeAllRefreshTokens(row.userId);
      throw errors.tokenExpired('刷新令牌已被使用,已撤销全部会话,请重新登录');
    }
    if (row.expiresAt <= this.now()) throw errors.tokenExpired('刷新令牌已过期,请重新登录');

    const user = await this.repo.findUserById(row.userId);
    if (!user) throw errors.authRequired('刷新令牌对应的账号不存在');

    const next = this.buildRefreshToken(row.userId, row.deviceId);
    await this.repo.revokeRefreshToken(tokenHash, next.tokenHash);
    await this.repo.createRefreshToken(next.row);

    const access = this.signAccess(row.userId, row.deviceId);
    const tokens: TokenPair = {
      accessToken: access.token,
      refreshToken: next.token,
      expiresIn: access.expiresIn
    };
    // 设备可能已被删除(refresh_tokens.device_id 是 on delete set null):
    // 按 (userId, deviceId) 重新登记一次即可,契约 §7.4 的 device 只是回显。
    const device: DeviceRow = {
      id: row.deviceId ?? `dev_${randomBytes(5).toString('hex')}`,
      userId: row.userId,
      name: '未命名设备',
      platform: 'unknown',
      createdAt: user.createdAt,
      lastSeenAt: this.now()
    };
    return { user: publicUser(user), device, ...tokens };
  }

  async logout(rawToken: string): Promise<void> {
    const tokenHash = sha256Hex(rawToken);
    const row = await this.repo.findRefreshToken(tokenHash);
    if (row) await this.repo.revokeRefreshToken(tokenHash, null);
  }

  /** 校验 access token;抛 AppError(AUTH_REQUIRED / AUTH_TOKEN_EXPIRED) */
  verifyAccess(token: string): AccessIdentity {
    try {
      const payload = jwt.verify(token, this.config.jwtSecret, { algorithms: ['HS256'] }) as jwt.JwtPayload;
      if (payload.typ !== 'access' || typeof payload.sub !== 'string' || payload.sub === '') {
        throw errors.authRequired('访问令牌无效');
      }
      const dev = typeof payload.dev === 'string' && payload.dev !== '' ? payload.dev : null;
      return { userId: payload.sub, deviceId: dev };
    } catch (err) {
      if (err instanceof AppError) throw err;
      if (err instanceof jwt.TokenExpiredError) throw errors.tokenExpired();
      throw errors.authRequired('访问令牌无效');
    }
  }

  async getUser(userId: string): Promise<PublicUser | null> {
    const user = await this.repo.findUserById(userId);
    return user ? publicUser(user) : null;
  }

  /** 仅供限流分桶使用:不校验签名,只读 sub(真正的校验在 verifyAccess) */
  peekUserId(token: string): string | null {
    try {
      const payload = jwt.decode(token);
      if (payload && typeof payload === 'object' && typeof (payload as jwt.JwtPayload).sub === 'string') {
        return (payload as jwt.JwtPayload).sub as string;
      }
      return null;
    } catch {
      return null;
    }
  }

  /** 设备注册 / 更新最后在线(契约 §7.4 `POST /v1/devices/register`) */
  async registerDevice(userId: string, input: z.infer<typeof DeviceRegisterInputSchema>): Promise<DeviceRow> {
    const now = this.now();
    const existing = await this.repo.findDevice(userId, input.deviceId);
    const device: DeviceRow = {
      id: input.deviceId,
      userId,
      name: input.name ?? existing?.name ?? '未命名设备',
      platform: input.platform ?? existing?.platform ?? 'unknown',
      createdAt: existing?.createdAt ?? now,
      lastSeenAt: now
    };
    return this.repo.upsertDevice(device);
  }

  /* ---------------- 内部 ---------------- */

  private async upsertDevice(
    userId: string,
    input: { deviceId?: string; deviceName?: string; platform?: string }
  ): Promise<DeviceRow> {
    // 契约 §7.2:deviceId 是客户端生成的不透明短串(`dev_` + 不透明后缀,示例 "dev_7f3a...")。
    // 客户端未带时,服务端兜底也必须产出同一形态 —— 早前用 randomUUID() 会产出 uuid 形态,
    // 与契约示例不符,也让"设备 id 格式"在不同客户端之间不一致。
    const deviceId = input.deviceId?.trim() || `dev_${randomBytes(5).toString('hex')}`;
    const now = this.now();
    const existing = await this.repo.findDevice(userId, deviceId);
    const device: DeviceRow = {
      id: deviceId,
      userId,
      name: input.deviceName?.trim() || existing?.name || '未命名设备',
      platform: input.platform?.trim() || existing?.platform || 'unknown',
      createdAt: existing?.createdAt ?? now,
      lastSeenAt: now
    };
    return this.repo.upsertDevice(device);
  }

  /**
   * 签发令牌。令牌本身与账号类型无关(契约 §7.6:游客与正式账号的令牌完全一致),
   * 因此这里不需要区分 isGuest —— 它只由 `user` 投影对外表达。
   */
  private async issueTokens(userId: string, deviceId: string | null): Promise<TokenPair> {
    const access = this.signAccess(userId, deviceId);
    const refresh = this.buildRefreshToken(userId, deviceId);
    await this.repo.createRefreshToken(refresh.row);
    return { accessToken: access.token, refreshToken: refresh.token, expiresIn: access.expiresIn };
  }

  private signAccess(userId: string, deviceId: string | null): { token: string; expiresIn: number } {
    const expiresIn = this.config.accessTtlSec;
    const token = jwt.sign({ sub: userId, dev: deviceId, typ: 'access' }, this.config.jwtSecret, {
      algorithm: 'HS256',
      expiresIn
    });
    return { token, expiresIn };
  }

  private buildRefreshToken(userId: string, deviceId: string | null): { token: string; tokenHash: string; row: RefreshTokenRow } {
    const token = randomBytes(32).toString('base64url'); // 256-bit
    const tokenHash = sha256Hex(token);
    const now = this.now();
    return {
      token,
      tokenHash,
      row: {
        tokenHash,
        userId,
        deviceId,
        createdAt: now,
        expiresAt: now + this.config.refreshTtlDays * 86_400_000,
        revokedAt: null,
        replacedBy: null
      }
    };
  }

  private async burnPasswordCheck(password: string): Promise<void> {
    if (!this.dummyHash) this.dummyHash = await this.hasher.hash('ordo-timing-equalizer');
    await this.hasher.verify(this.dummyHash, password);
  }

  /**
   * 是否回显验证码(契约 §7.6.5 的唯一例外)。
   * 三个条件**同时**成立才回显:显式开关 + console 通道 + 非生产。
   * 生产环境即使 ORDO_DEV_ECHO_CODE=1 也到不了这里 —— loadConfig 已经在启动时拒绝。
   */
  private shouldEchoDevCode(): boolean {
    return (
      this.config.emailCode.devEchoCode &&
      this.config.mail.transport === 'console' &&
      this.config.env !== 'production'
    );
  }

  /**
   * 邮箱验证码登录时的账号解析(契约 §7.6.5 硬约束 1 / 2):
   *   · 已注册 → 原样返回,**不动它的口令**(也可能是游客升级来的正式账号);
   *   · 未注册 → 自动建号:`is_guest=false`、无口令(`password_algo='none'` + 占位哈希)。
   *
   * 为什么占位哈希不是空串:与游客账号同一手法 —— 哈希列永不留空,
   * 且 `otp$<256-bit 随机>` 与任何口令都不可能匹配(login 还会按 algo='none' 直接短路)。
   * 并发下两个请求可能同时走到 createUser,由 `users_email_key` 唯一索引兜底:
   * 输的那个拿到 23505,再查一次即可拿到赢家建好的账号(不重复建号)。
   */
  private async ensureEmailUser(email: string): Promise<UserRow> {
    const existing = await this.repo.findUserByEmail(email);
    if (existing) return existing;

    const user: UserRow = {
      id: randomUUID(),
      email,
      passwordHash: `otp$${randomBytes(32).toString('hex')}`,
      passwordAlgo: 'none',
      isGuest: false,
      createdAt: this.now()
    };
    try {
      return await this.repo.createUser(user);
    } catch (err) {
      if (isUniqueViolation(err)) {
        const raced = await this.repo.findUserByEmail(email);
        if (raced) return raced;
      }
      throw err;
    }
  }
}

function publicUser(user: UserRow): PublicUser {
  return {
    id: user.id,
    email: user.email,
    // 契约 §7.6.2:register / login / refresh 的响应都要带 user.isGuest(正式账号为 false)
    isGuest: user.isGuest === true,
    createdAt: user.createdAt
  };
}

function isUniqueViolation(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: string }).code === '23505';
}

/** 6 位数字验证码。用 CSPRNG(`randomInt`)而不是 `Math.random` —— 后者可预测(契约 §9)。 */
function generateEmailCode(): string {
  return randomInt(0, 1_000_000)
    .toString()
    .padStart(6, '0');
}

/**
 * 邮件正文。**不含**任何"该邮箱是否已注册"的差异信息(契约 §7.6.5 / §9),
 * 注册与未注册收到的邮件逐字相同。
 */
function buildEmailCodeText(code: string, ttlSec: number): string {
  const minutes = Math.max(1, Math.round(ttlSec / 60));
  return `您的 Ordo 登录验证码是 ${code},${minutes} 分钟内有效。\n若非本人操作,请忽略本邮件。`;
}

/** 定长十六进制哈希的常量时间比较(避免用 === 泄漏前缀匹配长度) */
function timingSafeEqualHex(a: string, b: string): boolean {
  const bufA = Buffer.from(a, 'utf8');
  const bufB = Buffer.from(b, 'utf8');
  if (bufA.length !== bufB.length) return false;
  return timingSafeEqual(bufA, bufB);
}
