/**
 * 认证服务 —— 契约 §7.4 / §9。
 *  - access token:JWT HS256,有效期 30 分钟(config.accessTtlSec)
 *  - refresh token:256-bit 随机串,服务端**仅存 SHA-256 哈希**,30 天,刷新即轮换失效
 */
import { randomBytes, randomUUID } from 'node:crypto';
import jwt from 'jsonwebtoken';
import { z } from 'zod';
import { AppConfig } from '../config';
import { AppError, errors } from '../domain/errors';
import { DeviceRow, RefreshTokenRow, Repository, UserRow } from '../repo/types';
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
export const DeviceRegisterInputSchema = z.object({
  deviceId: z.string().trim().min(1).max(100),
  name: z.string().trim().max(100).optional(),
  platform: z.string().trim().max(50).optional()
});

export type RegisterInput = z.infer<typeof RegisterInputSchema>;
export type LoginInput = z.infer<typeof LoginInputSchema>;

export interface PublicUser {
  id: string;
  email: string;
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
    private now: () => number = Date.now
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
    const ok = await this.hasher.verify(user.passwordHash, input.password);
    if (!ok) throw errors.invalidCredentials();

    const device = await this.upsertDevice(user.id, input);
    const tokens = await this.issueTokens(user.id, device.id);
    return { user: publicUser(user), device, ...tokens };
  }

  /** 刷新:旧 refresh 立即失效(轮换),重放旧令牌会撤销该用户全部会话 */
  async refresh(rawToken: string): Promise<TokenPair> {
    const tokenHash = sha256Hex(rawToken);
    const row = await this.repo.findRefreshToken(tokenHash);
    if (!row) throw errors.tokenExpired('刷新令牌无效,请重新登录');
    if (row.revokedAt != null) {
      await this.repo.revokeAllRefreshTokens(row.userId);
      throw errors.tokenExpired('刷新令牌已被使用,已撤销全部会话,请重新登录');
    }
    if (row.expiresAt <= this.now()) throw errors.tokenExpired('刷新令牌已过期,请重新登录');

    const next = this.buildRefreshToken(row.userId, row.deviceId);
    await this.repo.revokeRefreshToken(tokenHash, next.tokenHash);
    await this.repo.createRefreshToken(next.row);

    const access = this.signAccess(row.userId, row.deviceId);
    return { accessToken: access.token, refreshToken: next.token, expiresIn: access.expiresIn };
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
}

function publicUser(user: UserRow): PublicUser {
  return { id: user.id, email: user.email, createdAt: user.createdAt };
}

function isUniqueViolation(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: string }).code === '23505';
}
