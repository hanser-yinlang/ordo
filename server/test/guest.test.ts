/**
 * 游客账号测试 —— 契约 §7.6(v1.2 新增「账号、会话与游客」)
 *
 * 覆盖:
 *  - `POST /v1/auth/guest`:匿名账号(email=null、isGuest=true)、响应与 register/login **同构**
 *  - 游客 **不是离线模式**:push/pull/snapshot 正常入库,且**按 user 隔离**
 *    (两个游客互相看不到对方的数据,连 ops 游标与 Fastlane 提醒索引都不串)
 *  - `POST /v1/auth/upgrade`:userId 不变、数据仍在、isGuest 翻转为 false
 *  - 升级后**旧 refreshToken 依然有效**(令牌绑定 userId,升级不改 userId)
 *  - 重复升级:换邮箱 → 409 AUTH_EMAIL_TAKEN;同一个 userId 再升级 → 400 not_guest
 *  - 游客调 `login` 被拒 → 401 AUTH_INVALID_CREDENTIALS(无口令可校验)
 *  - 正式账号(register/login/refresh)的 `user.isGuest` 恒为 false
 */
import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import type { FastifyInstance } from 'fastify';
import { authHeaders, makeApp, makeTodo, uniqueEmail, type TestContext } from './helpers';

type FastifyApp = FastifyInstance;

interface GuestSession {
  userId: string;
  deviceId: string;
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  email: string | null;
  isGuest: boolean;
}

/** 注册一个游客并返回令牌(断言 201 + 契约字段) */
async function registerGuest(
  app: FastifyApp,
  options: { deviceId?: string; deviceName?: string; platform?: string } = {}
): Promise<GuestSession> {
  const res = await app.inject({
    method: 'POST',
    url: '/v1/auth/guest',
    payload: {
      deviceId: options.deviceId,
      deviceName: options.deviceName ?? '游客设备',
      platform: options.platform ?? 'windows'
    }
  });
  assert.equal(res.statusCode, 201, `游客登录应返回 201,实际 ${res.statusCode}:${res.body}`);
  const body = res.json() as {
    user: { id: string; email: string | null; isGuest: boolean };
    device: { id: string };
    accessToken: string;
    refreshToken: string;
    expiresIn: number;
  };
  return {
    userId: body.user.id,
    email: body.user.email,
    isGuest: body.user.isGuest,
    deviceId: body.device.id,
    accessToken: body.accessToken,
    refreshToken: body.refreshToken,
    expiresIn: body.expiresIn
  };
}

type FastifyApp = FastifyInstance;

/** 游客升级;返回原始响应,便于断言错误分支 */
async function upgrade(
  app: FastifyApp,
  token: string,
  payload: { email: string; password: string }
): Promise<{ statusCode: number; body: any }> {
  const res = await app.inject({ method: 'POST', url: '/v1/auth/upgrade', headers: authHeaders(token), payload });
  return { statusCode: res.statusCode, body: res.json() };
}

/** 推一条待办,返回 serverSeq */
async function pushTodo(app: FastifyApp, session: GuestSession, title: string): Promise<number> {
  const todo = makeTodo({ title, updatedAt: Date.now(), createdAt: Date.now() });
  const res = await app.inject({
    method: 'POST',
    url: '/v1/sync/push',
    headers: authHeaders(session.accessToken, session.deviceId),
    payload: {
      deviceId: session.deviceId,
      sinceSeq: null,
      ops: [
        {
          opId: `op_${session.userId.slice(0, 8)}_${Math.random().toString(36).slice(2, 10)}`,
          deviceId: session.deviceId,
          entity: 'todo',
          entityId: todo.id,
          type: 'upsert',
          payload: todo,
          clientTs: Date.now()
        }
      ]
    }
  });
  assert.equal(res.statusCode, 200, `游客 push 必须成功(不是离线模式):${res.body}`);
  const body = res.json() as { accepted: Array<{ applied?: boolean; serverSeq: number | null }> };
  assert.equal(body.accepted[0]?.applied, true, `游客 push 应被接受:${res.body}`);
  return body.accepted[0]!.serverSeq!;
}

async function snapshot(app: FastifyApp, session: GuestSession): Promise<any> {
  const res = await app.inject({ method: 'GET', url: '/v1/sync/snapshot', headers: authHeaders(session.accessToken) });
  assert.equal(res.statusCode, 200, `快照失败:${res.body}`);
  return res.json();
}

describe('游客账号 §7.6', () => {
  let ctx: TestContext;

  before(async () => {
    ctx = await makeApp();
  });

  after(async () => {
    await ctx.close();
  });

  /* ==================== 1. 游客注册 ==================== */

  it('POST /v1/auth/guest 创建一个匿名账号,响应与 register/login 同构', async () => {
    const guest = await registerGuest(ctx.app);

    assert.equal(guest.isGuest, true, '游客账号必须 isGuest=true');
    assert.equal(guest.email, null, '游客没有邮箱(契约 §7.6.1)');
    assert.ok(guest.userId, '必须返回 user.id');
    assert.ok(guest.deviceId, '必须返回 device');
    assert.equal(guest.accessToken.split('.').length, 3, 'accessToken 应为 JWT');
    assert.ok(guest.refreshToken.length >= 40, 'refreshToken 应为 256-bit 随机串');
    assert.equal(guest.expiresIn, ctx.config.accessTtlSec);

    // 与 register 的响应做**同构**校验:两侧键集合必须一致(契约 §7.6.2 要求)
    const reg = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: { email: uniqueEmail('iso'), password: 'password123' }
    });
    assert.equal(reg.statusCode, 201);
    const guestKeys = Object.keys((await ctx.app.inject({ method: 'POST', url: '/v1/auth/guest', payload: {} })).json()).sort();
    assert.deepEqual(Object.keys(reg.json()).sort(), guestKeys, 'guest 与 register 的响应结构必须一致');
  });

  it('游客账号真的落库(email=null、isGuest=true、带不可用的占位口令哈希)', async () => {
    const guest = await registerGuest(ctx.app);
    const row = await ctx.repo.findUserById(guest.userId);
    assert.ok(row, '游客必须写进 users 表 —— 游客不是离线模式');
    assert.equal(row!.email, null);
    assert.equal(row!.isGuest, true);
    assert.ok(row!.passwordHash.length > 0, '口令哈希不能为空');
    assert.equal(/^guest\$[0-9a-f]{64}$/.test(row!.passwordHash), true, '应为随机占位哈希,绝不留空/明文');

    // email 为 null → 任何邮箱都查不到它,这正是"游客不能用 login 登录"的根因
    assert.equal(await ctx.repo.findUserByEmail('anything@example.com'), null);
    assert.equal(await ctx.repo.findUserByEmail(''), null);
  });

  it('游客数据正常入库并可按 userId 隔离(两个游客互不可见)', async () => {
    const a = await registerGuest(ctx.app, { deviceId: 'dev_guest_a', deviceName: 'A 的手机' });
    const b = await registerGuest(ctx.app, { deviceId: 'dev_guest_b', deviceName: 'B 的手机' });
    assert.notEqual(a.userId, b.userId, '两个游客是不同的账号');

    const seqA = await pushTodo(ctx.app, a, 'A 的待办');
    assert.ok(seqA > 0, 'A 的 op 必须拿到 serverSeq');
    await pushTodo(ctx.app, b, 'B 的待办');

    // push 响应里捎带拉取:各拉各的,不能串
    const pullA = await ctx.app.inject({
      method: 'GET',
      url: '/v1/sync/pull?sinceSeq=0&limit=100',
      headers: authHeaders(a.accessToken)
    });
    assert.equal(pullA.statusCode, 200);
    const opsA = pullA.json().ops as Array<{ opId: string }>;
    assert.equal(opsA.length, 1, 'A 只能看到自己的 1 条 op');

    const snapA = await snapshot(ctx.app, a);
    const snapB = await snapshot(ctx.app, b);
    assert.equal(snapA.todos.length, 1, 'A 的快照只有自己的 1 条待办');
    assert.equal(snapB.todos.length, 1, 'B 的快照只有自己的 1 条待办');
    assert.equal(snapA.todos[0].title, 'A 的待办');
    assert.equal(snapB.todos[0].title, 'B 的待办');

    // 仓储层直接核对:实体按 user_id 分开
    assert.equal((await ctx.repo.listEntities(a.userId)).length, 1);
    assert.equal((await ctx.repo.listEntities(b.userId)).length, 1);
    assert.equal((await ctx.repo.listEntities(a.userId))[0].userId, a.userId);
  });

  it('游客用 login 登录被拒:401 AUTH_INVALID_CREDENTIALS(无口令可校验)', async () => {
    const guest = await registerGuest(ctx.app);

    // ① 邮箱为 null 时根本查不到这个账号 → 与"邮箱不存在"不可区分
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { email: 'guest-should-not-login@example.com', password: 'password123' }
    });
    assert.equal(res.statusCode, 401);
    assert.equal(res.json().error.code, 'AUTH_INVALID_CREDENTIALS');

    // ② 即便贴一个"看起来像游客"的邮箱,也必须是同一个错误码(不泄漏账号类型)
    const res2 = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { email: `${guest.userId}@guest.invalid`, password: 'password123' }
    });
    assert.equal(res2.statusCode, 401);
    assert.equal(res2.json().error.code, 'AUTH_INVALID_CREDENTIALS');

    // ③ 游客自己也无法用 login 重新登录 —— 只能用 refreshToken 恢复会话
    const res3 = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { email: null, password: 'password123' }
    });
    assert.equal(res3.statusCode, 400, 'email 为 null 时连校验都过不了');
    assert.equal(res3.json().error.code, 'VALIDATION_FAILED');

    // refreshToken 才是游客恢复会话的正路(契约 §7.6.2)
    const refreshed = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/refresh',
      payload: { refreshToken: guest.refreshToken }
    });
    assert.equal(refreshed.statusCode, 200);
    assert.equal(refreshed.json().user.id, guest.userId, '刷新后仍是同一个 userId');
    assert.equal(refreshed.json().user.isGuest, true, 'refresh 响应也要带 user.isGuest');
  });

  it('正式账号的 isGuest 恒为 false(register / login / refresh 三个响应)', async () => {
    const email = uniqueEmail('member');
    const reg = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: { email, password: 'password123' }
    });
    assert.equal(reg.statusCode, 201);
    assert.equal(reg.json().user.isGuest, false, 'register 响应:isGuest=false');

    const login = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { email, password: 'password123' }
    });
    assert.equal(login.statusCode, 200);
    assert.equal(login.json().user.isGuest, false, 'login 响应:isGuest=false');

    const refresh = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/refresh',
      payload: { refreshToken: reg.json().refreshToken }
    });
    assert.equal(refresh.statusCode, 200);
    assert.equal(refresh.json().user.isGuest, false, 'refresh 响应:isGuest=false');
    assert.equal(refresh.json().user.email, email.toLowerCase());
  });

  /* ==================== 2. 升级 ==================== */

  it('升级:userId 与全部数据不变,isGuest 翻转为 false,旧 refreshToken 仍可用', async () => {
    const guest = await registerGuest(ctx.app);
    await pushTodo(ctx.app, guest, '升级前就存在的待办');
    const beforeSnap = await snapshot(ctx.app, guest);
    assert.equal(beforeSnap.todos.length, 1);

    const email = uniqueEmail('upgraded');
    const upgraded = await upgrade(ctx.app, guest.accessToken, { email, password: 'password123' });
    assert.equal(upgraded.statusCode, 200, `升级应成功:${JSON.stringify(upgraded.body)}`);
    // 契约 §7.6.2:upgrade 只返回 {user:{id,email,isGuest}}(不带令牌)
    assert.deepEqual(
      Object.keys(upgraded.body).sort(),
      ['user'],
      'upgrade 的响应体只应有 user(契约 §7.6.2)'
    );
    assert.deepEqual(
      Object.keys(upgraded.body.user).sort(),
      ['createdAt', 'email', 'id', 'isGuest'],
      'user 投影应为 {id,email,isGuest}(+createdAt)'
    );
    assert.equal(upgraded.body.user.id, guest.userId, '契约 §7.6.2:userId 不变');
    assert.equal(upgraded.body.user.isGuest, false);
    assert.equal(upgraded.body.user.email, email.toLowerCase());

    // 数据仍在:同一个 userId,同一个快照
    const afterSnap = await snapshot(ctx.app, guest);
    assert.equal(afterSnap.todos.length, 1, '升级后数据必须还在');
    assert.equal(afterSnap.todos[0].title, '升级前就存在的待办');
    assert.equal(afterSnap.todos[0].id, beforeSnap.todos[0].id);

    // 仓储层核对
    const row = await ctx.repo.findUserById(guest.userId);
    assert.equal(row!.isGuest, false);
    assert.equal(row!.email, email.toLowerCase());
    assert.equal((await ctx.repo.listEntities(guest.userId)).length, 1, 'entities 的 user_id 没有被改写');

    // 升级后可以用新邮箱正式登录,且 isGuest=false
    const login = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { email, password: 'password123' }
    });
    assert.equal(login.statusCode, 200, `升级后应能用邮箱登录:${login.body}`);
    assert.equal(login.json().user.id, guest.userId, '登录拿到的还是同一个 userId');
    assert.equal(login.json().user.isGuest, false);

    // **升级前签发的 refreshToken 依然有效** —— 令牌与 userId 绑定,升级不改 userId,
    // 因此四端"升级后不打断现有会话"(契约 §7.6.2 只要求 userId 与数据不变)。
    const refreshOld = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/refresh',
      payload: { refreshToken: guest.refreshToken }
    });
    assert.equal(refreshOld.statusCode, 200, '升级后旧 refreshToken 仍应可用');
    assert.equal(refreshOld.json().user.id, guest.userId);
    assert.equal(refreshOld.json().user.isGuest, false, '刷新后 isGuest 反映的是升级后的最新状态');

    // 升级后签发的 accessToken 也能继续写数据
    const newSeq = await pushTodo(ctx.app, guest, '升级后的新待办');
    assert.ok(newSeq > 0);
    assert.equal((await snapshot(ctx.app, guest)).todos.length, 2);
  });

  it('重复升级:邮箱已被占用 → 409 AUTH_EMAIL_TAKEN', async () => {
    const taken = uniqueEmail('taken');
    const member = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: { email: taken, password: 'password123' }
    });
    assert.equal(member.statusCode, 201);

    const guest = await registerGuest(ctx.app);
    const res = await upgrade(ctx.app, guest.accessToken, { email: taken, password: 'password123' });
    assert.equal(res.statusCode, 409);
    assert.equal(res.body.error.code, 'AUTH_EMAIL_TAKEN');

    // 失败不能有副作用:账号仍是游客、仍无邮箱
    const row = await ctx.repo.findUserById(guest.userId);
    assert.equal(row!.isGuest, true, '失败后必须仍是游客');
    assert.equal(row!.email, null, '失败后不得写入邮箱');
  });

  it('重复升级:同一个 userId 再升级一次 → 400 且 details.reason=not_guest', async () => {
    const guest = await registerGuest(ctx.app);
    const email = uniqueEmail('once');
    const first = await upgrade(ctx.app, guest.accessToken, { email, password: 'password123' });
    assert.equal(first.statusCode, 200);

    const second = await upgrade(ctx.app, guest.accessToken, { email: uniqueEmail('again'), password: 'password123' });
    assert.equal(second.statusCode, 400, '非游客账号升级必须 400');
    assert.equal(second.body.error.code, 'VALIDATION_FAILED');
    assert.equal(second.body.error.details.reason, 'not_guest', '必须给出可判定的明确原因');

    // 用同一个邮箱再调一次也仍是"已不是游客",不是 409 —— 账号状态优先
    const third = await upgrade(ctx.app, guest.accessToken, { email, password: 'password123' });
    assert.equal(third.statusCode, 400);
    assert.equal(third.body.error.details.reason, 'not_guest');

    // 邮箱没有被改动
    assert.equal((await ctx.repo.findUserById(guest.userId))!.email, email.toLowerCase());
  });

  it('正式账号调用 upgrade 也是 400 not_guest(register 出来的账号)', async () => {
    const reg = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: { email: uniqueEmail('member2'), password: 'password123' }
    });
    assert.equal(reg.statusCode, 201);
    const res = await upgrade(ctx.app, reg.json().accessToken, {
      email: uniqueEmail('nope'),
      password: 'password123'
    });
    assert.equal(res.statusCode, 400);
    assert.equal(res.body.error.details.reason, 'not_guest');
  });

  it('upgrade 的边界:无令牌 401、弱口令 400、邮箱格式错误 400', async () => {
    const guest = await registerGuest(ctx.app);

    const noToken = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/upgrade',
      payload: { email: uniqueEmail('x'), password: 'password123' }
    });
    assert.equal(noToken.statusCode, 401);
    assert.equal(noToken.json().error.code, 'AUTH_REQUIRED');

    const weak = await upgrade(ctx.app, guest.accessToken, { email: uniqueEmail('weak'), password: 'short' });
    assert.equal(weak.statusCode, 400, '口令仍需满足 §9 的最小长度 8');
    assert.equal(weak.body.error.code, 'VALIDATION_FAILED');

    const badEmail = await upgrade(ctx.app, guest.accessToken, { email: 'not-an-email', password: 'password123' });
    assert.equal(badEmail.statusCode, 400);
    assert.equal(badEmail.body.error.code, 'VALIDATION_FAILED');

    const missingPassword = await ctx.app.inject({
      method: 'POST',
      url: '/v1/auth/upgrade',
      headers: authHeaders(guest.accessToken),
      payload: { email: uniqueEmail('nopw') }
    });
    assert.equal(missingPassword.statusCode, 400);

    // 全程失败 → 账号仍是游客
    assert.equal((await ctx.repo.findUserById(guest.userId))!.isGuest, true);
  });

  /* ==================== 3. 游客的完整同步闭环 ==================== */

  it('游客走完整闭环:push 带提醒 → pull 分页 → 升级 → 删除账号级联', async () => {
    const guest = await registerGuest(ctx.app);

    const todo = makeTodo({ title: '游客的提醒待办', reminder: '2030-01-01T09:00', when: 'today' });
    const push = await ctx.app.inject({
      method: 'POST',
      url: '/v1/sync/push',
      headers: authHeaders(guest.accessToken, guest.deviceId),
      payload: {
        deviceId: guest.deviceId,
        sinceSeq: null,
        ops: [
          {
            opId: 'op_guest_reminder',
            deviceId: guest.deviceId,
            entity: 'todo',
            entityId: todo.id,
            type: 'upsert',
            payload: todo,
            clientTs: Date.now()
          }
        ]
      }
    });
    assert.equal(push.statusCode, 200, `游客 push 失败:${push.body}`);

    // Fastlane 索引同样按用户建立(§7.5)—— 游客的提醒不会被丢掉。
    // 这个内存仓储被本文件的多个用例共用,所以只断言"这个 todo 的提醒存在且唯一",
    // 不断言总数(其它用例也可能建过提醒)。
    const reminders = await ctx.repo.listReminders(guest.userId);
    const mine = reminders.filter((r) => r.todoId === todo.id);
    assert.equal(mine.length, 1, '游客的提醒必须进 Fastlane 索引');
    assert.equal(mine[0].userId, guest.userId, '提醒必须挂在游客自己的 userId 下');

    const pull = await ctx.app.inject({
      method: 'GET',
      url: '/v1/sync/pull?sinceSeq=0&limit=1',
      headers: authHeaders(guest.accessToken)
    });
    assert.equal(pull.statusCode, 200);
    assert.equal(pull.json().ops.length, 1);
    assert.equal(pull.json().hasMore, false);

    // 升级后删除账号:仍然级联清空(§9)
    const ok = await upgrade(ctx.app, guest.accessToken, { email: uniqueEmail('cascade'), password: 'password123' });
    assert.equal(ok.statusCode, 200);
    const del = await ctx.app.inject({
      method: 'DELETE',
      url: '/v1/account',
      headers: authHeaders(guest.accessToken)
    });
    assert.equal(del.statusCode, 204);
    assert.equal(await ctx.repo.findUserById(guest.userId), null);
    assert.equal((await ctx.repo.listEntities(guest.userId)).length, 0);
    assert.equal((await ctx.repo.listReminders(guest.userId)).length, 0);
  });

  it('不存在的 userId 持有有效 access token 时 upgrade 返回 401', async () => {
    const guest = await registerGuest(ctx.app);
    await ctx.repo.deleteUser(guest.userId);
    const res = await upgrade(ctx.app, guest.accessToken, { email: uniqueEmail('ghost'), password: 'password123' });
    assert.equal(res.statusCode, 401);
    assert.equal(res.body.error.code, 'AUTH_REQUIRED');
  });
});
