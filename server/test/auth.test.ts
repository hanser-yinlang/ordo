/**
 * 认证测试 —— 契约 §7.4 / §9
 * 覆盖:注册 / 重复邮箱 / 登录失败 / 刷新轮换 / 受保护路由 401 / schema 版本 / 登出
 */
import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import jwt from 'jsonwebtoken';
import {
  authHeaders,
  makeApp,
  registerUser,
  TestContext,
  uniqueEmail
} from './helpers';

describe('认证 §7.4 / §9', () => {
  let ctx: TestContext;

  before(async () => {
    ctx = await makeApp();
  });

  after(async () => {
    await ctx.close();
  });

  it('健康检查无需鉴权且返回契约字段', async () => {
    const res = await ctx.app.inject({ method: 'GET', url: '/v1/health' });
    assert.equal(res.statusCode, 200);
    const body = res.json();
    assert.equal(body.status, 'ok');
    assert.equal(typeof body.version, 'string');
    assert.equal(typeof body.serverTime, 'number');
    assert.equal(body.schemaVersion, 1);
  });

  it('注册成功返回 user/device/accessToken/refreshToken/expiresIn', async () => {
    const email = uniqueEmail('reg');
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: { email, password: 'password123', deviceName: 'Pixel 9', platform: 'android' }
    });
    assert.equal(res.statusCode, 201);
    const body = res.json();
    assert.equal(body.user.email, email.toLowerCase());
    assert.equal(body.user.isGuest, false, '契约 §7.6.2:register 响应必须带 user.isGuest(正式账号为 false)');
    assert.ok(body.device.id);
    assert.ok(body.accessToken.split('.').length === 3, 'accessToken 应为 JWT');
    assert.ok(body.refreshToken.length >= 40, 'refreshToken 应为 256-bit 随机串');
    assert.equal(body.expiresIn, ctx.config.accessTtlSec);
    // 绝不返回口令哈希
    assert.equal(body.user.passwordHash, undefined);
    assert.equal(JSON.stringify(body).includes('passwordHash'), false);
  });

  it('重复邮箱注册返回 409 AUTH_EMAIL_TAKEN', async () => {
    const user = await registerUser(ctx.app);
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: { email: user.email, password: 'password123' }
    });
    assert.equal(res.statusCode, 409);
    assert.equal(res.json().error.code, 'AUTH_EMAIL_TAKEN');
  });

  it('口令过短返回 400 VALIDATION_FAILED(§9 最小长度 8)', async () => {
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: { email: uniqueEmail('weak'), password: 'short' }
    });
    assert.equal(res.statusCode, 400);
    assert.equal(res.json().error.code, 'VALIDATION_FAILED');
  });

  it('登录成功,口令错误/邮箱不存在均返回 401 AUTH_INVALID_CREDENTIALS', async () => {
    const user = await registerUser(ctx.app);

    const ok = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { email: user.email, password: user.password }
    });
    assert.equal(ok.statusCode, 200);
    assert.equal(ok.json().user.isGuest, false, '契约 §7.6.2:login 响应也必须带 user.isGuest');

    const wrongPassword = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { email: user.email, password: 'wrong-password' }
    });
    assert.equal(wrongPassword.statusCode, 401);
    assert.equal(wrongPassword.json().error.code, 'AUTH_INVALID_CREDENTIALS');

    const noSuchUser = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { email: uniqueEmail('ghost'), password: 'password123' }
    });
    assert.equal(noSuchUser.statusCode, 401);
    assert.equal(noSuchUser.json().error.code, 'AUTH_INVALID_CREDENTIALS');
  });

  it('刷新令牌轮换:旧 refresh 失效,重放会被拒绝', async () => {
    const user = await registerUser(ctx.app);

    const first = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/refresh',
      payload: { refreshToken: user.refreshToken }
    });
    assert.equal(first.statusCode, 200);
    const rotated = first.json();
    assert.ok(rotated.accessToken && rotated.refreshToken);
    assert.notEqual(rotated.refreshToken, user.refreshToken, 'refreshToken 必须轮换');

    const replay = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/refresh',
      payload: { refreshToken: user.refreshToken }
    });
    assert.equal(replay.statusCode, 401);
    assert.equal(replay.json().error.code, 'AUTH_TOKEN_EXPIRED');

    // 重放会撤销该用户全部会话:新 refresh 也失效
    const afterReplay = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/refresh',
      payload: { refreshToken: rotated.refreshToken }
    });
    assert.equal(afterReplay.statusCode, 401);
  });

  it('受保护路由缺少令牌返回 401 AUTH_REQUIRED,令牌无效同样 401', async () => {
    const missing = await ctx.app.inject({ method: 'GET', url: '/v1/sync/snapshot' });
    assert.equal(missing.statusCode, 401);
    assert.equal(missing.json().error.code, 'AUTH_REQUIRED');

    const garbage = await ctx.app.inject({
      method: 'GET',
      url: '/v1/sync/snapshot',
      headers: { authorization: 'Bearer not-a-jwt' }
    });
    assert.equal(garbage.statusCode, 401);
    assert.equal(garbage.json().error.code, 'AUTH_REQUIRED');

    const wrongScheme = await ctx.app.inject({
      method: 'GET',
      url: '/v1/sync/snapshot',
      headers: { authorization: 'Token abc' }
    });
    assert.equal(wrongScheme.statusCode, 401);
  });

  it('过期令牌返回 401 AUTH_TOKEN_EXPIRED(客户端据此触发 refresh)', async () => {
    const user = await registerUser(ctx.app);
    const expired = jwt.sign({ sub: user.userId, dev: user.deviceId, typ: 'access' }, ctx.config.jwtSecret, {
      algorithm: 'HS256',
      expiresIn: -60
    });
    const res = await ctx.app.inject({
      method: 'GET',
      url: '/v1/sync/snapshot',
      headers: authHeaders(expired)
    });
    assert.equal(res.statusCode, 401);
    assert.equal(res.json().error.code, 'AUTH_TOKEN_EXPIRED');
  });

  it('不支持的 X-Ordo-Schema 返回 400 VALIDATION_FAILED(§8)', async () => {
    const user = await registerUser(ctx.app);
    const res = await ctx.app.inject({
      method: 'GET',
      url: '/v1/sync/snapshot',
      headers: { authorization: `Bearer ${user.accessToken}`, 'x-ordo-schema': '99' }
    });
    assert.equal(res.statusCode, 400);
    assert.equal(res.json().error.code, 'VALIDATION_FAILED');
    assert.deepEqual(res.json().error.details.supported, 1);
  });

  it('登出后 refresh 失效且返回 204', async () => {
    const user = await registerUser(ctx.app);
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/logout',
      payload: { refreshToken: user.refreshToken }
    });
    assert.equal(res.statusCode, 204);

    const afterLogout = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/refresh',
      payload: { refreshToken: user.refreshToken }
    });
    assert.equal(afterLogout.statusCode, 401);
  });

  it('设备注册更新最后在线(需登录)', async () => {
    const user = await registerUser(ctx.app);
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/v1/devices/register',
      headers: authHeaders(user.accessToken),
      payload: { deviceId: user.deviceId, name: '重命名后的设备', platform: 'windows' }
    });
    assert.equal(res.statusCode, 200);
    assert.equal(res.json().device.name, '重命名后的设备');

    const unauth = await ctx.app.inject({
      method: 'POST',
      url: '/v1/devices/register',
      payload: { deviceId: 'x' }
    });
    assert.equal(unauth.statusCode, 401);
  });

  it('删除账号会级联删除数据(§9)', async () => {
    const user = await registerUser(ctx.app);
    const res = await ctx.app.inject({
      method: 'DELETE',
      url: '/v1/account',
      headers: authHeaders(user.accessToken)
    });
    assert.equal(res.statusCode, 204);
    assert.equal(await ctx.repo.findUserById(user.userId), null);
    assert.equal((await ctx.repo.listEntities(user.userId)).length, 0);
  });
});
