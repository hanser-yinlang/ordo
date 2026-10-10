/**
 * 认证路由 —— 契约 §7.4 / §7.6
 *   POST /v1/auth/register   → 201 {user, device, accessToken, refreshToken, expiresIn}
 *   POST /v1/auth/guest      → 201 同构(user.email = null, user.isGuest = true,契约 §7.6.2)
 *   POST /v1/auth/login      → 200 同上(游客/无口令账号一律 AUTH_INVALID_CREDENTIALS)
 *   POST /v1/auth/upgrade    → 200 {user}(需 Access Token;游客 → 正式账号,userId 不变)
 *   POST /v1/auth/email/code → 202 {sent, expiresIn, retryAfter[, devCode]}(契约 §7.6.5)
 *   POST /v1/auth/email/login→ 200 与 register **完全同构**(未注册邮箱自动建号)
 *   POST /v1/auth/refresh    → 200 {user, device, accessToken, refreshToken, expiresIn}
 *   POST /v1/auth/logout     → 204
 */
import type { FastifyInstance } from 'fastify';
import { ZodError } from 'zod';
import { AppError, errors } from '../domain/errors';
import {
  DeviceRegisterInputSchema,
  EmailCodeLoginSchema,
  EmailCodeRequestSchema,
  GuestInputSchema,
  LoginInputSchema,
  LogoutInputSchema,
  RefreshInputSchema,
  RegisterInputSchema,
  UpgradeGuestInputSchema
} from '../services/auth';
import { RouteDeps } from './deps';
import { requireAuth } from './health';

function toValidationError(err: unknown): never {
  if (err instanceof ZodError) throw errors.validation('请求参数不合法', { issues: err.issues });
  throw err;
}

export function registerAuthRoutes(app: FastifyInstance, deps: RouteDeps): void {
  app.post('/v1/auth/register', async (req, reply) => {
    const parsed = RegisterInputSchema.safeParse(req.body);
    if (!parsed.success) toValidationError(parsed.error);
    const result = await deps.auth.register(parsed.data);
    return reply.code(201).send(result);
  });

  app.post('/v1/auth/login', async (req) => {
    const parsed = LoginInputSchema.safeParse(req.body);
    if (!parsed.success) toValidationError(parsed.error);
    return deps.auth.login(parsed.data);
  });

  /**
   * 游客登录(契约 §7.6.2)—— 创建匿名账号,响应与 register/login 同构。
   * **不是离线模式**:数据正常入库、正常多端同步,`user.isGuest = true`、`user.email = null`。
   */
  app.post('/v1/auth/guest', async (req, reply) => {
    const parsed = GuestInputSchema.safeParse(req.body ?? {});
    if (!parsed.success) toValidationError(parsed.error);
    const result = await deps.auth.guest(parsed.data);
    return reply.code(201).send(result);
  });

  /**
   * 游客升级为正式账号(契约 §7.6.2)—— 需 Access Token。
   * userId 与全部数据不变;邮箱已占用返回 409 AUTH_EMAIL_TAKEN;
   * 非游客账号调用返回 400 VALIDATION_FAILED(details.reason = 'not_guest')。
   */
  app.post('/v1/auth/upgrade', { preHandler: requireAuth(deps) }, async (req) => {
    const parsed = UpgradeGuestInputSchema.safeParse(req.body);
    if (!parsed.success) toValidationError(parsed.error);
    return deps.auth.upgrade(req.auth!.userId, parsed.data);
  });

  /**
   * 请求邮箱登录验证码(契约 §7.6.5,v1.3)—— 202。
   *
   * 限流命中时除了 429 的 `details.retryAfterSec`,还回一个标准的 `Retry-After` 头
   * (与 app.ts 里全局令牌桶的处理一致,便于通用 HTTP 客户端直接读)。
   */
  app.post('/v1/auth/email/code', async (req, reply) => {
    const parsed = EmailCodeRequestSchema.safeParse(req.body);
    if (!parsed.success) toValidationError(parsed.error);
    try {
      const result = await deps.auth.requestEmailCode(parsed.data);
      return await reply.code(202).send(result);
    } catch (err) {
      if (
        err instanceof AppError &&
        err.code === 'RATE_LIMITED' &&
        err.details.reason === 'code_throttled'
      ) {
        reply.header('Retry-After', String(err.details.retryAfterSec));
      }
      throw err;
    }
  });

  /**
   * 邮箱验证码登录(契约 §7.6.5)—— 200,响应与 register/login **完全同构**。
   * 邮箱未注册时自动建号(`is_guest=false`、无口令);已注册时直接登录、不改其口令。
   */
  app.post('/v1/auth/email/login', async (req) => {
    const parsed = EmailCodeLoginSchema.safeParse(req.body);
    if (!parsed.success) toValidationError(parsed.error);
    return deps.auth.emailCodeLogin(parsed.data);
  });

  app.post('/v1/auth/refresh', async (req) => {
    const parsed = RefreshInputSchema.safeParse(req.body);
    if (!parsed.success) toValidationError(parsed.error);
    return deps.auth.refresh(parsed.data.refreshToken);
  });

  app.post('/v1/auth/logout', async (req, reply) => {
    const parsed = LogoutInputSchema.safeParse(req.body);
    if (!parsed.success) toValidationError(parsed.error);
    await deps.auth.logout(parsed.data.refreshToken);
    return reply.code(204).send();
  });

  /** 设备注册 / 更新最后在线(契约 §7.4);需登录 */
  app.post('/v1/devices/register', { preHandler: requireAuth(deps) }, async (req) => {
    const parsed = DeviceRegisterInputSchema.safeParse(req.body);
    if (!parsed.success) toValidationError(parsed.error);
    const device = await deps.auth.registerDevice(req.auth!.userId, parsed.data);
    return { device };
  });

  /** 删除账号与全部数据(契约 §9,级联删除);需登录 */
  app.delete('/v1/account', { preHandler: requireAuth(deps) }, async (req, reply) => {
    const userId = req.auth!.userId;
    await deps.repo.revokeAllRefreshTokens(userId);
    await deps.repo.deleteUser(userId);
    return reply.code(204).send();
  });
}
