/**
 * 协议级端到端测试 —— 把 `scripts/smoke.mjs` 的覆盖面升级为**可回归的自动化测试**。
 *
 * 与 smoke.mjs 的区别:
 *  - 在**一个进程内**起真实 HTTP + WS 服务(随机端口),用真实 socket / fetch,
 *    不经过 app.inject,因此 Fastify 的 body 上限、序列化、WS 握手全部真实参与;
 *  - 断言的是失败路径(401 / 409 / 413 / 429 / 4401)与边界值,不只是 happy path;
 *  - 结束后必须释放端口(见 after 钩子)。
 *
 * 覆盖清单:
 *  注册 → 登录 → push(捎带拉取)→ pull 分页 → WS hello/ops → Fastlane reminder
 *  只投一次 → 401 刷新令牌重放 → 限流 429 → 单批 500 ops / 256 KB 上限 → SYNC_SEQ_GAP
 */
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, describe, it } from 'node:test';
import { WebSocket } from 'ws';
import { http, makeServer, makeTodo, nextOpId, sleep, type ServerContext } from './helpers';

interface WsMessage {
  type: string;
  [key: string]: unknown;
}

interface WsHandle {
  socket: WebSocket;
  messages: WsMessage[];
  waitFor(type: string, predicate?: (m: WsMessage) => boolean, timeoutMs?: number): Promise<WsMessage | null>;
  close(): void;
}

async function connectWs(url: string, token?: string): Promise<WsHandle> {
  const socket = new WebSocket(token ? `${url}?token=${encodeURIComponent(token)}` : url);
  const messages: WsMessage[] = [];
  socket.on('message', (raw) => {
    try {
      messages.push(JSON.parse(raw.toString()) as WsMessage);
    } catch {
      /* 忽略非 JSON */
    }
  });

  const waitFor = async (
    type: string,
    predicate: (m: WsMessage) => boolean = () => true,
    timeoutMs = 8000
  ): Promise<WsMessage | null> => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const hit = messages.find((m) => m.type === type && predicate(m));
      if (hit) return hit;
      await sleep(25);
    }
    return messages.find((m) => m.type === type && predicate(m)) ?? null;
  };

  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('WS 连接超时')), 5000);
    socket.once('open', () => {
      clearTimeout(timer);
      resolve();
    });
    socket.once('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    // 未鉴权时服务端会先发 error 再关闭,这里同样视为"已连接"(由用例断言 4401)
    socket.once('close', () => {
      clearTimeout(timer);
      resolve();
    });
  });

  return {
    socket,
    messages,
    waitFor,
    close() {
      try {
        socket.close();
      } catch {
        /* 已关闭 */
      }
    }
  };
}

describe('端到端协议(真实 HTTP + WS)', () => {
  let server: ServerContext;
  let accessToken = '';
  let refreshToken = '';
  let userId = '';
  let deviceId = '';
  const email = `e2e_${Date.now()}@example.com`;
  const password = 'password123';

  before(async () => {
    server = await makeServer({ app: { tzOffsetMinutes: 0, reminderScanMs: 50 } });
  });

  after(async () => {
    await server.close();
  });

  it('GET /v1/health 返回 ok 与存储类型', async () => {
    const res = await http(server.baseUrl, 'GET', '/v1/health');
    assert.equal(res.status, 200);
    assert.equal(res.body.status, 'ok');
    assert.equal(res.body.storage, 'memory');
    assert.equal(res.body.schemaVersion, 1);
    assert.equal(typeof res.body.serverTime, 'number');
  });

  it('POST /v1/auth/register → 201,返回 user/device/token 三件套', async () => {
    const res = await http(server.baseUrl, 'POST', '/v1/auth/register', {
      body: { email, password, deviceName: 'E2E', platform: 'cli', deviceId: 'e2e-device-1' }
    });
    assert.equal(res.status, 201, res.text);
    assert.equal(res.body.user.email, email);
    assert.equal(res.body.user.isGuest, false, '契约 §7.6.2:register 响应带 user.isGuest=false');
    assert.equal(typeof res.body.accessToken, 'string');
    assert.equal(typeof res.body.refreshToken, 'string');
    assert.equal(res.body.expiresIn, server.config.accessTtlSec);
    accessToken = res.body.accessToken;
    refreshToken = res.body.refreshToken;
    userId = res.body.user.id;
    deviceId = res.body.device.id;

    // 重复注册 → 409 AUTH_EMAIL_TAKEN
    const dup = await http(server.baseUrl, 'POST', '/v1/auth/register', {
      body: { email, password, deviceName: 'E2E', platform: 'cli' }
    });
    assert.equal(dup.status, 409);
    assert.equal(dup.body.error.code, 'AUTH_EMAIL_TAKEN');
  });

  it('POST /v1/auth/login → 200,口令错误 → 401', async () => {
    const ok = await http(server.baseUrl, 'POST', '/v1/auth/login', {
      body: { email, password, deviceName: 'E2E-2', platform: 'web', deviceId: 'e2e-device-2' }
    });
    assert.equal(ok.status, 200, ok.text);
    assert.equal(ok.body.user.id, userId);
    assert.equal(ok.body.user.isGuest, false);

    const bad = await http(server.baseUrl, 'POST', '/v1/auth/login', {
      body: { email, password: 'wrong-password' }
    });
    assert.equal(bad.status, 401);
    assert.equal(bad.body.error.code, 'AUTH_INVALID_CREDENTIALS');
  });

  it('未带 token 访问同步接口 → 401 AUTH_REQUIRED;错误的 X-Ordo-Schema → 400', async () => {
    const noAuth = await http(server.baseUrl, 'GET', '/v1/sync/snapshot');
    assert.equal(noAuth.status, 401);
    assert.equal(noAuth.body.error.code, 'AUTH_REQUIRED');

    const badSchema = await http(server.baseUrl, 'GET', '/v1/health', { headers: { 'x-ordo-schema': '99' } });
    assert.equal(badSchema.status, 400);
    assert.equal(badSchema.body.error.code, 'VALIDATION_FAILED');

    const badToken = await http(server.baseUrl, 'GET', '/v1/sync/snapshot', { token: 'not-a-jwt' });
    assert.equal(badToken.status, 401);
  });

  it('WS 未带 token → 4401 + error 帧', async () => {
    const ws = await connectWs(server.wsUrl);
    await sleep(250);
    const err = ws.messages.find((m) => m.type === 'error');
    assert.ok(err, '应收到 error 帧');
    assert.equal((err!.error as { code: string }).code, 'AUTH_REQUIRED');
    await new Promise<void>((resolve) => {
      if (ws.socket.readyState === 3) return resolve();
      ws.socket.once('close', () => resolve());
      setTimeout(resolve, 2000);
    });
    assert.equal(ws.socket.readyState, 3, '连接应被服务端关闭');
  });

  it('WS 连接 → hello(含 serverSeq/serverTime);subscribe 绑定 deviceId;ping → pong', async () => {
    const ws = await connectWs(server.wsUrl, accessToken);
    const hello = await ws.waitFor('hello');
    assert.ok(hello, '应收到 hello');
    assert.equal(typeof hello!.serverSeq, 'number');
    assert.equal(typeof hello!.serverTime, 'number');
    assert.equal(hello!.serverSeq, 0, '新用户还没有任何 op');

    ws.socket.send(JSON.stringify({ type: 'subscribe', deviceId }));
    ws.socket.send(JSON.stringify({ type: 'ping' }));
    const pong = await ws.waitFor('pong');
    assert.ok(pong, 'ping 应回 pong');

    // 非法 JSON 与未知类型 → error 帧
    ws.socket.send('this-is-not-json');
    const jsonErr = await ws.waitFor('error', (m) => (m.error as { message: string }).message.includes('JSON'));
    assert.ok(jsonErr, '非法 JSON 应回 error');

    ws.socket.send(JSON.stringify({ type: 'no-such-type' }));
    const typeErr = await ws.waitFor('error', (m) => (m.error as { message: string }).message.includes('未知消息类型'));
    assert.ok(typeErr, '未知消息类型应回 error');

    ws.close();
  });

  it('push:首次写入 applied,serverSeq 从 1 开始;重复 opId 幂等', async () => {
    const todo = makeTodo({ title: 'E2E 待办', tags: ['e2e'] });
    const opId = nextOpId('e2e');
    const first = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: {
        deviceId,
        sinceSeq: 0,
        ops: [{ opId, deviceId, entity: 'todo', entityId: todo.id, type: 'upsert', payload: todo, clientTs: Date.now() }]
      }
    });
    assert.equal(first.status, 200, first.text);
    assert.equal(first.body.accepted.length, 1);
    assert.equal(first.body.accepted[0].applied, true);
    assert.equal(first.body.accepted[0].serverSeq, 1);
    assert.equal(first.body.serverSeq, 1);
    assert.deepEqual(first.body.rejected, []);
    // 首次 push 时没有"别人"的 op,捎带拉取应为空
    assert.deepEqual(first.body.ops, []);

    // 重复 opId:duplicate,不再分配 serverSeq
    const again = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: {
        deviceId,
        sinceSeq: 1,
        ops: [{ opId, deviceId, entity: 'todo', entityId: todo.id, type: 'upsert', payload: todo, clientTs: Date.now() }]
      }
    });
    assert.equal(again.status, 200);
    assert.equal(again.body.accepted[0].duplicate, true);
    assert.equal(again.body.accepted[0].serverSeq, null);
    assert.equal(again.body.serverSeq, 1, '幂等复推不应推进 serverSeq');
  });

  it('push 捎带拉取:第二个设备的 push 能把远端 op 一起带回来', async () => {
    // 先由"另一个设备"写一条,拿到 seq
    const otherTodo = makeTodo({ title: '其它设备的待办' });
    const otherPush = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: {
        deviceId: 'e2e-device-2',
        sinceSeq: 1,
        ops: [
          {
            opId: nextOpId('e2e'),
            deviceId: 'e2e-device-2',
            entity: 'todo',
            entityId: otherTodo.id,
            type: 'upsert',
            payload: otherTodo,
            clientTs: Date.now() + 10
          }
        ]
      }
    });
    assert.equal(otherPush.status, 200);
    assert.equal(otherPush.body.serverSeq, 2);

    // 本设备 sinceSeq=1 再推一条,应捎带回 seq=2 的那条(且不含自己刚推的)
    const mine = makeTodo({ title: '本设备的新待办' });
    const myPush = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: {
        deviceId,
        sinceSeq: 1,
        ops: [
          {
            opId: nextOpId('e2e'),
            deviceId,
            entity: 'todo',
            entityId: mine.id,
            type: 'upsert',
            payload: mine,
            clientTs: Date.now() + 20
          }
        ]
      }
    });
    assert.equal(myPush.status, 200, myPush.text);
    assert.equal(myPush.body.serverSeq, 3);
    const piggybacked = myPush.body.ops as Array<{ entityId: string; seq: number }>;
    assert.equal(piggybacked.length, 1, `捎带应只含远端 op,实际:${JSON.stringify(piggybacked)}`);
    assert.equal(piggybacked[0].entityId, otherTodo.id);
    assert.equal(piggybacked[0].seq, 2);
  });

  it('pull 分页:limit 生效、hasMore 正确、翻页不重不漏', async () => {
    const all = await http(server.baseUrl, 'GET', '/v1/sync/pull?sinceSeq=0&limit=1000', { token: accessToken });
    assert.equal(all.status, 200);
    const totalOps = all.body.ops.length;
    assert.ok(totalOps >= 3, `应有至少 3 条 op,实际 ${totalOps}`);
    assert.equal(all.body.hasMore, false);
    assert.equal(all.body.serverSeq, totalOps);

    const page1 = await http(server.baseUrl, 'GET', '/v1/sync/pull?sinceSeq=0&limit=2', { token: accessToken });
    assert.equal(page1.body.ops.length, 2);
    assert.equal(page1.body.hasMore, true, '还有剩余时必须 hasMore=true');
    assert.deepEqual(
      page1.body.ops.map((o: { seq: number }) => o.seq),
      [1, 2]
    );

    const cursor = page1.body.ops[1].seq;
    const page2 = await http(server.baseUrl, 'GET', `/v1/sync/pull?sinceSeq=${cursor}&limit=2`, { token: accessToken });
    assert.ok(page2.body.ops.every((o: { seq: number }) => o.seq > cursor), '第二页必须从游标之后继续');
    assert.equal(page2.body.hasMore, false, '最后一页 hasMore 应为 false');

    // 默认 limit(不传 limit 参数)
    const def = await http(server.baseUrl, 'GET', '/v1/sync/pull?sinceSeq=0', { token: accessToken });
    assert.equal(def.status, 200);
    assert.equal(def.body.ops.length, totalOps);
  });

  it('snapshot 返回全部实体;删除后从快照消失但保留墓碑', async () => {
    const snap = await http(server.baseUrl, 'GET', '/v1/sync/snapshot', { token: accessToken });
    assert.equal(snap.status, 200);
    const before = snap.body.todos.length as number;
    assert.ok(before >= 2, `快照应有至少 2 条待办(前序用例累计),实际 ${before}`);
    assert.equal(typeof snap.body.serverSeq, 'number');

    const victim = snap.body.todos[0].id;
    const del = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: {
        deviceId,
        sinceSeq: snap.body.serverSeq,
        ops: [{ opId: nextOpId('e2e-del'), deviceId, entity: 'todo', entityId: victim, type: 'delete', payload: null, clientTs: Date.now() + 1000 }]
      }
    });
    assert.equal(del.status, 200, del.text);
    assert.equal(del.body.accepted[0].applied, true);

    const after = await http(server.baseUrl, 'GET', '/v1/sync/snapshot', { token: accessToken });
    assert.equal(after.body.todos.length, before - 1, '墓碑不应出现在快照里');
    assert.equal(
      after.body.todos.some((t: { id: string }) => t.id === victim),
      false,
      '被删除的待办必须从快照消失'
    );

    // 更旧的 upsert 不能复活
    const revive = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: {
        deviceId,
        sinceSeq: null,
        ops: [
          {
            opId: nextOpId('e2e-revive'),
            deviceId,
            entity: 'todo',
            entityId: victim,
            type: 'upsert',
            payload: makeTodo({ id: victim, title: '复活?' }),
            clientTs: Date.now() - 60_000
          }
        ]
      }
    });
    assert.equal(revive.status, 200);
    assert.equal(revive.body.rejected[0].reason, 'tombstoned');
    const stillGone = await http(server.baseUrl, 'GET', '/v1/sync/snapshot', { token: accessToken });
    assert.equal(stillGone.body.todos.length, before - 1, '墓碑必须拒绝复活');
  });

  it('WS ops:同用户其它连接收到新增 op 的广播(排除发起设备)', async () => {
    const ws = await connectWs(server.wsUrl, accessToken);
    await ws.waitFor('hello');
    // 订阅成"其它设备",以便接收本设备发起的变更
    ws.socket.send(JSON.stringify({ type: 'subscribe', deviceId: 'e2e-device-99' }));
    await sleep(100);

    const todo = makeTodo({ title: '广播测试' });
    const pushed = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: {
        deviceId,
        sinceSeq: null,
        ops: [{ opId: nextOpId('e2e-bc'), deviceId, entity: 'todo', entityId: todo.id, type: 'upsert', payload: todo, clientTs: Date.now() + 5000 }]
      }
    });
    assert.equal(pushed.status, 200, pushed.text);

    const ops = await ws.waitFor('ops');
    assert.ok(ops, '应收到 ops 广播');
    assert.equal(typeof ops!.serverSeq, 'number');
    const payload = ops!.ops as Array<{ entityId: string }>;
    assert.ok(
      payload.some((o) => o.entityId === todo.id),
      '广播里应包含本次新增的 op'
    );
    ws.close();
  });

  it('Fastlane:到点提醒经 WS 只投递一次', async () => {
    const ws = await connectWs(server.wsUrl, accessToken);
    await ws.waitFor('hello');

    // tzOffset=0 → 用 UTC 当前分钟作为提醒时刻,落在扫描窗口(now, now+60s] 内
    const reminderAt = new Date().toISOString().slice(0, 16);
    const todo = makeTodo({ title: 'E2E 提醒', when: 'today', reminder: reminderAt, date: new Date().toISOString().slice(0, 10) });
    const res = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: {
        deviceId: 'e2e-device-reminder',
        sinceSeq: null,
        ops: [
          {
            opId: nextOpId('e2e-rem'),
            deviceId: 'e2e-device-reminder',
            entity: 'todo',
            entityId: todo.id,
            type: 'upsert',
            payload: todo,
            clientTs: Date.now() + 9000
          }
        ]
      }
    });
    assert.equal(res.status, 200, res.text);

    server.built.deps.reminders.start();
    try {
      const reminder = await ws.waitFor('reminder', (m) => m.todoId === todo.id, 8000);
      assert.ok(reminder, '应在扫描周期内收到 reminder');
      assert.equal(reminder!.title, 'E2E 提醒');
      assert.equal(reminder!.at, reminderAt, 'at 应是本地时间串 YYYY-MM-DDTHH:mm');

      // 再等若干个扫描周期,确认只投一次
      await sleep(700);
      const count = ws.messages.filter((m) => m.type === 'reminder' && m.todoId === todo.id).length;
      assert.equal(count, 1, '同一提醒只能投递一次');
    } finally {
      server.built.deps.reminders.stop();
      ws.close();
    }
  });

  it('限流:写接口超过桶容量返回 429 RATE_LIMITED + Retry-After', async () => {
    // 独立实例:capacity=3, refill=0 让断言确定
    const limited = await makeServer({
      app: { rateLimit: { enabled: true, capacity: 3, refillPerSec: 0 } }
    });
    try {
      let okCount = 0;
      let limitedCount = 0;
      let retryAfter: string | null = null;
      for (let i = 0; i < 6; i += 1) {
        const res = await http(limited.baseUrl, 'POST', '/v1/auth/login', {
          body: { email: 'nobody@example.com', password: 'password123' }
        });
        if (res.status === 429) {
          limitedCount += 1;
          retryAfter = res.headers.get('retry-after');
          assert.equal(res.body.error.code, 'RATE_LIMITED');
        } else {
          okCount += 1;
          assert.equal(res.status, 401);
        }
      }
      assert.equal(okCount, 3, '桶容量 3,前 3 个请求应通过');
      assert.equal(limitedCount, 3, '其余请求应被限流');
      assert.ok(retryAfter, '限流响应必须带 Retry-After');

      // 读接口不受写限流影响
      const read = await http(limited.baseUrl, 'GET', '/v1/health');
      assert.equal(read.status, 200);

      // 限流命中数应被计入指标
      const metrics = await http(limited.baseUrl, 'GET', '/metrics');
      assert.match(metrics.text, /ordo_rate_limited_total 3/);
    } finally {
      await limited.close();
    }
  });

  it('单批上限:501 个 op → 400;恰好 500 个 op → 200', async () => {
    const tooMany = Array.from({ length: 501 }, (_, i) => ({
      opId: `e2e-bulk-${i}`,
      deviceId,
      entity: 'todo',
      entityId: `e2e-bulk-${i}`,
      type: 'upsert',
      payload: makeTodo({ id: `e2e-bulk-${i}` }),
      clientTs: Date.now() + i
    }));
    const bad = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: { deviceId, sinceSeq: null, ops: tooMany }
    });
    assert.equal(bad.status, 400, bad.text.slice(0, 200));
    assert.equal(bad.body.error.code, 'VALIDATION_FAILED');
    assert.equal(bad.body.error.details.limit, 500);
    assert.equal(bad.body.error.details.received, 501);

    const exactly = tooMany.slice(0, 500);
    const good = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: { deviceId, sinceSeq: null, ops: exactly }
    });
    assert.equal(good.status, 200, good.text.slice(0, 300));
    assert.equal(good.body.accepted.length, 500);
    assert.ok(good.body.accepted.every((a: { applied: boolean }) => a.applied === true));
  });

  it('单 op 256 KB 上限:301 KB 的 payload → 413 SYNC_OP_TOO_LARGE', async () => {
    const huge = makeTodo({ id: 'e2e-huge', title: '超大', note: 'x'.repeat(300 * 1024) });
    const res = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: {
        deviceId,
        sinceSeq: null,
        ops: [{ opId: nextOpId('e2e-huge'), deviceId, entity: 'todo', entityId: huge.id, type: 'upsert', payload: huge, clientTs: Date.now() }]
      }
    });
    assert.equal(res.status, 413, res.text.slice(0, 200));
    assert.equal(res.body.error.code, 'SYNC_OP_TOO_LARGE');
    assert.ok(res.body.error.details.bytes > 256 * 1024);
    assert.equal(res.body.error.details.limit, 256 * 1024);
  });

  it('请求体超过 body 上限(512 KB)→ 413', async () => {
    const res = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: { deviceId, sinceSeq: null, padding: 'y'.repeat(600 * 1024) }
    });
    assert.equal(res.status, 413, res.text.slice(0, 200));
    assert.equal(res.body.error.code, 'SYNC_OP_TOO_LARGE');
  });

  it('pull limit > 1000 → 400;SYNC_SEQ_GAP:sinceSeq 超前 → 409(HTTP 与详情)', async () => {
    const tooBig = await http(server.baseUrl, 'GET', '/v1/sync/pull?sinceSeq=0&limit=1001', { token: accessToken });
    assert.equal(tooBig.status, 400);
    assert.equal(tooBig.body.error.code, 'VALIDATION_FAILED');
    assert.equal(tooBig.body.error.details.limit, 1000);

    const snap = await http(server.baseUrl, 'GET', '/v1/sync/snapshot', { token: accessToken });
    const serverSeq = snap.body.serverSeq as number;

    const gapPull = await http(server.baseUrl, 'GET', `/v1/sync/pull?sinceSeq=${serverSeq + 10}&limit=10`, {
      token: accessToken
    });
    assert.equal(gapPull.status, 409, gapPull.text.slice(0, 200));
    assert.equal(gapPull.body.error.code, 'SYNC_SEQ_GAP');
    assert.equal(gapPull.body.error.details.sinceSeq, serverSeq + 10);
    assert.equal(gapPull.body.error.details.serverSeq, serverSeq);

    const gapPush = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: { deviceId, sinceSeq: serverSeq + 10, ops: [] }
    });
    assert.equal(gapPush.status, 409, gapPush.text.slice(0, 200));
    assert.equal(gapPush.body.error.code, 'SYNC_SEQ_GAP');

    // 不超前的 sinceSeq 正常
    const okPush = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token: accessToken,
      body: { deviceId, sinceSeq: serverSeq, ops: [] }
    });
    assert.equal(okPush.status, 200);
    assert.deepEqual(okPush.body.accepted, []);
  });

  it('刷新令牌:轮换后旧令牌重放 → 401 且撤销全部会话', async () => {
    const rotated = await http(server.baseUrl, 'POST', '/v1/auth/refresh', { body: { refreshToken } });
    assert.equal(rotated.status, 200, rotated.text);
    assert.equal(typeof rotated.body.accessToken, 'string');
    assert.equal(rotated.body.user.isGuest, false, '契约 §7.6.2:refresh 响应也带 user.isGuest');
    assert.equal(rotated.body.user.id, userId);
    assert.notEqual(rotated.body.refreshToken, refreshToken, 'refresh token 必须轮换');
    const freshAccessToken = rotated.body.accessToken as string;
    const freshRefreshToken = rotated.body.refreshToken as string;

    // 旧令牌重放 → 401,并撤销该用户全部 refresh token
    const replay = await http(server.baseUrl, 'POST', '/v1/auth/refresh', { body: { refreshToken } });
    assert.equal(replay.status, 401, replay.text);
    assert.equal(replay.body.error.code, 'AUTH_TOKEN_EXPIRED');
    assert.match(replay.body.error.message, /已被使用/);

    // 因为触发了"重放 → 撤销全部会话",刚轮换出来的新令牌也应失效
    const afterReplay = await http(server.baseUrl, 'POST', '/v1/auth/refresh', { body: { refreshToken: freshRefreshToken } });
    assert.equal(afterReplay.status, 401, '重放应导致全部会话被撤销');

    // 但 access token 在有效期内仍然可用(无状态 JWT)
    const stillWorks = await http(server.baseUrl, 'GET', '/v1/sync/snapshot', { token: freshAccessToken });
    assert.equal(stillWorks.status, 200);

    // 重新登录以便后续用例继续使用
    const relogin = await http(server.baseUrl, 'POST', '/v1/auth/login', {
      body: { email, password, deviceName: 'E2E', platform: 'cli', deviceId }
    });
    assert.equal(relogin.status, 200);
    accessToken = relogin.body.accessToken;
    refreshToken = relogin.body.refreshToken;

    // logout 幂等
    const logout = await http(server.baseUrl, 'POST', '/v1/auth/logout', { body: { refreshToken } });
    assert.equal(logout.status, 204);
    const afterLogout = await http(server.baseUrl, 'POST', '/v1/auth/refresh', { body: { refreshToken } });
    assert.equal(afterLogout.status, 401, '登出后 refresh 必须失效');
  });

  it('设备注册与账号删除(级联)', async () => {
    const relogin = await http(server.baseUrl, 'POST', '/v1/auth/login', {
      body: { email, password, deviceName: 'E2E', platform: 'cli', deviceId }
    });
    accessToken = relogin.body.accessToken;

    const device = await http(server.baseUrl, 'POST', '/v1/devices/register', {
      token: accessToken,
      body: { deviceId: 'e2e-device-3', name: '桌面端', platform: 'desktop' }
    });
    assert.equal(device.status, 200, device.text);
    assert.equal(device.body.device.id, 'e2e-device-3');
    assert.equal(device.body.device.name, '桌面端');

    const del = await http(server.baseUrl, 'DELETE', '/v1/account', { token: accessToken });
    assert.equal(del.status, 204);

    // 账号删除后,数据不可再访问(用户已不存在,但 JWT 仍在有效期内:
    // 仓储层查不到用户 → 同步接口返回空快照而不是报错)
    const snap = await http(server.baseUrl, 'GET', '/v1/sync/snapshot', { token: accessToken });
    assert.equal(snap.status, 200);
    assert.equal(snap.body.todos.length, 0, '账号删除应级联清空实体');
    assert.equal(snap.body.serverSeq, 0);
  });

  it('游客走真实 HTTP + WS:注册 → 同步 → 实时通道 → 升级(契约 §7.6)', async () => {
    // 1. 游客登录:与 register 同构,但 email=null、isGuest=true
    const guestRes = await http(server.baseUrl, 'POST', '/v1/auth/guest', {
      body: { deviceId: 'e2e-guest-1', deviceName: '游客设备', platform: 'cli' }
    });
    assert.equal(guestRes.status, 201, guestRes.text);
    assert.equal(guestRes.body.user.email, null, '游客没有邮箱');
    assert.equal(guestRes.body.user.isGuest, true);
    assert.deepEqual(
      Object.keys(guestRes.body).sort(),
      ['accessToken', 'device', 'expiresIn', 'refreshToken', 'user'],
      'guest 响应必须与 register/login 同构'
    );

    const guest = guestRes.body;
    const guestUserId = guest.user.id as string;
    assert.notEqual(guestUserId, userId, '游客是独立账号,不复用已有 userId');

    // 2. 真实 WS 握手:游客同样能拿到 hello(实时通道对游客一视同仁)
    const ws = await connectWs(server.wsUrl, guest.accessToken as string);
    try {
      const hello = await ws.waitFor('hello');
      assert.ok(hello, '游客 WS 应收到 hello');

      // 3. push 一条待办 → 该游客自己的连接收到 ops 广播
      const todoId = randomUUID();
      const guestTodo = makeTodo({ id: todoId, title: '游客的待办' });
      const pushed = await http(server.baseUrl, 'POST', '/v1/sync/push', {
        token: guest.accessToken as string,
        body: {
          deviceId: 'e2e-guest-1',
          sinceSeq: 0,
          ops: [
            {
              opId: nextOpId('guest'),
              deviceId: 'e2e-guest-1',
              entity: 'todo',
              entityId: todoId,
              type: 'upsert',
              payload: guestTodo,
              clientTs: Date.now()
            }
          ]
        }
      });
      assert.equal(pushed.status, 200, pushed.text);
      assert.equal(pushed.body.accepted[0].applied, true);
      const guestSeq = pushed.body.serverSeq as number;
      assert.ok(guestSeq > 0, '游客的 op 必须拿到 serverSeq');

      // 游客不是离线模式:数据真的入库了
      const guestSnap = await http(server.baseUrl, 'GET', '/v1/sync/snapshot', { token: guest.accessToken as string });
      assert.equal(guestSnap.status, 200);
      assert.equal(guestSnap.body.todos.length, 1);
      assert.equal(guestSnap.body.todos[0].title, '游客的待办');

      // 4. 按用户隔离:原账号(email 注册的那个)看不到游客的数据
      const memberSnap = await http(server.baseUrl, 'GET', '/v1/sync/snapshot', { token: accessToken });
      assert.equal(memberSnap.status, 200);
      assert.equal(
        memberSnap.body.todos.some((t: { title: string }) => t.title === '游客的待办'),
        false,
        '游客的数据绝不能出现在别的账号里'
      );

      const ops = await ws.waitFor('ops');
      if (ops) assert.ok(Array.isArray(ops.ops), 'ops 广播必须带 op 数组');
    } finally {
      ws.close();
    }

    // 5. 升级为正式账号:userId 与数据都不变
    const upgradeEmail = `e2e_guest_upgraded_${Date.now()}@example.com`;
    const upgraded = await http(server.baseUrl, 'POST', '/v1/auth/upgrade', {
      token: guest.accessToken as string,
      body: { email: upgradeEmail, password: 'password123' }
    });
    assert.equal(upgraded.status, 200, upgraded.text);
    assert.equal(upgraded.body.user.id, guestUserId, '升级必须保持 userId 不变');
    assert.equal(upgraded.body.user.isGuest, false);
    assert.equal(upgraded.body.user.email, upgradeEmail);

    const afterUpgrade = await http(server.baseUrl, 'GET', '/v1/sync/snapshot', { token: guest.accessToken as string });
    assert.equal(afterUpgrade.status, 200);
    assert.equal(afterUpgrade.body.todos.length, 1, '升级后数据必须还在');
    assert.equal(afterUpgrade.body.todos[0].title, '游客的待办');

    // 升级后能用邮箱登录
    const memberLogin = await http(server.baseUrl, 'POST', '/v1/auth/login', {
      body: { email: upgradeEmail, password: 'password123' }
    });
    assert.equal(memberLogin.status, 200, memberLogin.text);
    assert.equal(memberLogin.body.user.id, guestUserId);
    assert.equal(memberLogin.body.user.isGuest, false);

    // 6. 邮箱已被占用 → 409;非游客账号再升级 → 400 not_guest
    const secondGuest = await http(server.baseUrl, 'POST', '/v1/auth/guest', {
      body: { deviceId: 'e2e-guest-2' }
    });
    assert.equal(secondGuest.status, 201);
    const taken = await http(server.baseUrl, 'POST', '/v1/auth/upgrade', {
      token: secondGuest.body.accessToken as string,
      body: { email: upgradeEmail, password: 'password123' }
    });
    assert.equal(taken.status, 409, taken.text);
    assert.equal(taken.body.error.code, 'AUTH_EMAIL_TAKEN');

    const again = await http(server.baseUrl, 'POST', '/v1/auth/upgrade', {
      token: guest.accessToken as string,
      body: { email: `e2e_guest_again_${Date.now()}@example.com`, password: 'password123' }
    });
    assert.equal(again.status, 400, again.text);
    assert.equal(again.body.error.details.reason, 'not_guest');

    // 7. 游客不能登录:邮箱为 null 的账号在 login 里一律 401
    const guestLogin = await http(server.baseUrl, 'POST', '/v1/auth/login', {
      body: { email: `guest_${guestUserId}@example.com`, password: 'password123' }
    });
    assert.equal(guestLogin.status, 401);
    assert.equal(guestLogin.body.error.code, 'AUTH_INVALID_CREDENTIALS');
  });

  it('运维端点:/v1/ops/status 反映运行状态', async () => {
    const res = await http(server.baseUrl, 'GET', '/v1/ops/status');
    assert.equal(res.status, 200);
    assert.equal(res.body.storage, 'memory');
    assert.equal(res.body.degraded, false);
    assert.equal(typeof res.body.wsConnections, 'number');
    assert.equal(typeof res.body.tombstonePurge.intervalMs, 'number');
    assert.equal(res.body.version, '1.0.0');
  });
});
