/**
 * 限制与限流测试 —— 契约 §7.4
 * 覆盖:push ≤ 500 ops / 单 op payload ≤ 256 KB / pull limit ≤ 1000 / 写接口 10 req/s(RATE_LIMITED)
 */
import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import {
  authHeaders,
  makeApp,
  makeOp,
  makeTodo,
  registerUser,
  RegisteredUser,
  TestContext,
  uniqueEmail
} from './helpers';

describe('限制与限流 §7.4', () => {
  let ctx: TestContext;
  let user: RegisteredUser;

  before(async () => {
    ctx = await makeApp();
    user = await registerUser(ctx.app, { email: uniqueEmail('limits') });
  });

  after(async () => {
    await ctx.close();
  });

  it('单次 push 超过 500 个 op → 400 VALIDATION_FAILED', async () => {
    const ops = Array.from({ length: 501 }, (_, i) =>
      makeOp({ entity: 'todo', entityId: `bulk-${i}`, payload: makeTodo({ id: `bulk-${i}` }), clientTs: 1_000 + i })
    );
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/v1/sync/push',
      headers: authHeaders(user.accessToken),
      payload: { deviceId: 'dev_limits', sinceSeq: null, ops }
    });
    assert.equal(res.statusCode, 400);
    const body = res.json();
    assert.equal(body.error.code, 'VALIDATION_FAILED');
    assert.equal(body.error.details.limit, 500);
    assert.equal(body.error.details.received, 501);
  });

  it('恰好 500 个 op 可以通过', async () => {
    const ops = Array.from({ length: 500 }, (_, i) =>
      makeOp({ entity: 'todo', entityId: `ok-${i}`, payload: makeTodo({ id: `ok-${i}` }), clientTs: 2_000 + i })
    );
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/v1/sync/push',
      headers: authHeaders(user.accessToken),
      payload: { deviceId: 'dev_limits', sinceSeq: null, ops }
    });
    assert.equal(res.statusCode, 200);
    assert.equal(res.json().accepted.length, 500);
  });

  it('单个 op 的 payload 超过 256 KB → 413 SYNC_OP_TOO_LARGE', async () => {
    const huge = makeTodo({ title: '超大备注', note: 'x'.repeat(300 * 1024) });
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/v1/sync/push',
      headers: authHeaders(user.accessToken),
      payload: {
        deviceId: 'dev_limits',
        sinceSeq: null,
        ops: [makeOp({ entity: 'todo', entityId: huge.id, payload: huge, clientTs: 9_000 })]
      }
    });
    assert.equal(res.statusCode, 413);
    const body = res.json();
    assert.equal(body.error.code, 'SYNC_OP_TOO_LARGE');
    assert.ok(body.error.details.bytes > 256 * 1024);
    assert.equal(body.error.details.limit, 256 * 1024);
  });

  it('请求体超过服务端 body 上限 → 413 SYNC_OP_TOO_LARGE', async () => {
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/v1/sync/push',
      headers: authHeaders(user.accessToken),
      payload: { deviceId: 'dev_limits', sinceSeq: null, big: 'y'.repeat(600 * 1024) }
    });
    assert.equal(res.statusCode, 413);
    assert.equal(res.json().error.code, 'SYNC_OP_TOO_LARGE');
  });

  it('pull limit > 1000 → 400 VALIDATION_FAILED;limit=1000 可用', async () => {
    const tooBig = await ctx.app.inject({
      method: 'GET',
      url: '/v1/sync/pull?sinceSeq=0&limit=1001',
      headers: authHeaders(user.accessToken)
    });
    assert.equal(tooBig.statusCode, 400);
    assert.equal(tooBig.json().error.code, 'VALIDATION_FAILED');
    assert.equal(tooBig.json().error.details.limit, 1000);

    const ok = await ctx.app.inject({
      method: 'GET',
      url: '/v1/sync/pull?sinceSeq=0&limit=1000',
      headers: authHeaders(user.accessToken)
    });
    assert.equal(ok.statusCode, 200);
    assert.equal(Array.isArray(ok.json().ops), true);
  });

  it('写接口限流:超过 10 req/s 返回 429 RATE_LIMITED', async () => {
    // refillPerSec=0 让断言确定(不补充令牌);生产默认 10 req/s 补充
    const limited = await makeApp({
      rateLimit: { enabled: true, capacity: 10, refillPerSec: 0 }
    });
    try {
      let ok = 0;
      let limitedCount = 0;
      let retryAfter: string | undefined;
      for (let i = 0; i < 20; i += 1) {
        const res = await limited.app.inject({
          method: 'POST',
          url: '/v1/auth/login',
          payload: { email: uniqueEmail('rl'), password: 'password123' }
        });
        if (res.statusCode === 429) {
          limitedCount += 1;
          retryAfter = res.headers['retry-after'] as string | undefined;
          assert.equal(res.json().error.code, 'RATE_LIMITED');
        } else {
          ok += 1;
          assert.equal(res.statusCode, 401, '未注册邮箱应是 401');
        }
      }
      assert.equal(ok, 10, '桶容量 10,前 10 个请求应通过');
      assert.equal(limitedCount, 10, '其余请求应被限流');
      assert.ok(retryAfter, '限流响应应带 Retry-After');
    } finally {
      await limited.close();
    }
  });

  it('限流不影响读接口(GET /v1/sync/pull)', async () => {
    const limited = await makeApp({ rateLimit: { enabled: true, capacity: 2, refillPerSec: 1 } });
    try {
      const u = await registerUser(limited.app, { email: uniqueEmail('rl-read') });
      for (let i = 0; i < 6; i += 1) {
        const res = await limited.app.inject({
          method: 'GET',
          url: '/v1/sync/pull?sinceSeq=0&limit=10',
          headers: authHeaders(u.accessToken)
        });
        assert.equal(res.statusCode, 200, '读接口不应被写限流拦截');
      }
    } finally {
      await limited.close();
    }
  });
});
