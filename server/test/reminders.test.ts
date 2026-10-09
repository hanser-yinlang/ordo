/**
 * Fastlane 提醒 + 实时通道测试 —— 契约 §7.5
 * 覆盖:提醒到点经 WS 下发且**只发一次**;push 后同用户其它连接收到 ops;未鉴权 WS 被拒。
 */
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { after, before, describe, it } from 'node:test';
import { WebSocket } from 'ws';
import { makeApp, makeOp, makeTodo, push, registerUser, sleep, TestContext, waitFor } from './helpers';

interface WsMessage {
  type: string;
  [key: string]: unknown;
}

describe('Fastlane 提醒与实时通道 §7.5', () => {
  let ctx: TestContext;
  let socket: WebSocket;
  let messages: WsMessage[];
  let wsUrl: string;

  before(async () => {
    // tzOffset=0 便于时间断言;扫描间隔 100ms 让测试快速收敛(生产默认 1000ms)
    ctx = await makeApp({ reminderScanMs: 100, tzOffsetMinutes: 0 });
    await ctx.app.listen({ host: '127.0.0.1', port: 0 });
    const address = ctx.app.server.address() as AddressInfo;
    wsUrl = `ws://127.0.0.1:${address.port}/v1/ws`;
  });

  after(async () => {
    try {
      socket?.close();
    } catch {
      /* 已关闭 */
    }
    await ctx.close();
  });

  it('未带 token 连接 WS 会被拒绝并关闭(4401)', async () => {
    const bad = new WebSocket(wsUrl);
    const errors: WsMessage[] = [];
    let closeCode = 0;
    bad.on('message', (raw) => errors.push(JSON.parse(raw.toString())));
    bad.on('close', (code) => {
      closeCode = code;
    });
    await waitFor(() => closeCode !== 0, 4000);
    assert.equal(closeCode, 4401);
    assert.equal(errors[0]?.type, 'error');
    assert.equal((errors[0].error as { code: string }).code, 'AUTH_REQUIRED');
  });

  it('连接后收到 hello(含 serverSeq)', async () => {
    const user = await registerUser(ctx.app, { deviceId: 'dev_ws' });
    messages = [];
    socket = new WebSocket(`${wsUrl}?token=${encodeURIComponent(user.accessToken)}`);
    socket.on('message', (raw) => messages.push(JSON.parse(raw.toString()) as WsMessage));

    const got = await waitFor(() => messages.some((m) => m.type === 'hello'), 5000);
    assert.equal(got, true, '应收到 hello');
    const hello = messages.find((m) => m.type === 'hello')!;
    assert.equal(typeof hello.serverSeq, 'number');
    assert.equal(typeof hello.serverTime, 'number');

    // subscribe 绑定 deviceId
    socket.send(JSON.stringify({ type: 'subscribe', deviceId: 'dev_ws' }));
    await sleep(100);
  });

  it('到点提醒经 WS 下发,且只投递一次', async () => {
    const user = await registerUser(ctx.app, { deviceId: 'dev_ws_reminder' });
    const remMessages: WsMessage[] = [];
    const remSocket = new WebSocket(`${wsUrl}?token=${encodeURIComponent(user.accessToken)}`);
    remSocket.on('message', (raw) => remMessages.push(JSON.parse(raw.toString()) as WsMessage));
    await waitFor(() => remMessages.some((m) => m.type === 'hello'), 5000);

    // reminder 取「当前本地时刻」(tzOffset=0),扫描窗口[now, now+60s]内立即命中
    const nowLocal = new Date().toISOString().slice(0, 16);
    const todo = makeTodo({ title: '交季度报告', when: 'today', reminder: nowLocal });
    const pushed = await push(ctx.app, user.accessToken, 'dev_other', [
      makeOp({ entity: 'todo', entityId: todo.id, payload: todo, clientTs: Date.now() })
    ]);
    assert.equal(pushed.statusCode, 200);
    assert.equal(pushed.body.accepted[0].applied, true);

    // 设备侧其它连接会收到 ops 广播
    await waitFor(() => remMessages.some((m) => m.type === 'ops'), 5000);

    ctx.built.deps.reminders.start();
    const fired = await waitFor(() => remMessages.some((m) => m.type === 'reminder'), 6000);
    assert.equal(fired, true, '应在扫描周期内收到 reminder');

    const reminder = remMessages.find((m) => m.type === 'reminder')!;
    assert.equal(reminder.todoId, todo.id);
    assert.equal(reminder.title, '交季度报告');
    assert.equal(reminder.at, nowLocal, 'at 应是本地时间串 YYYY-MM-DDTHH:mm');

    // 再等若干个扫描周期,确认只投递一次
    await sleep(1200);
    const reminders = remMessages.filter((m) => m.type === 'reminder');
    assert.equal(reminders.length, 1, '同一提醒只能投递一次(fired=true)');

    const rows = await ctx.repo.listReminders(user.userId);
    const row = rows.find((r) => r.todoId === todo.id);
    assert.ok(row, '提醒应已建立索引');
    assert.equal(row!.fired, true, '投递后 fired 必须为 true');

    remSocket.close();
    ctx.built.deps.reminders.stop();
  });

  it('提醒时间被修改后会重新投递;待办完成则移除索引', async () => {
    const user = await registerUser(ctx.app, { deviceId: 'dev_ws_reminder2' });
    const msgs: WsMessage[] = [];
    const ws = new WebSocket(`${wsUrl}?token=${encodeURIComponent(user.accessToken)}`);
    ws.on('message', (raw) => msgs.push(JSON.parse(raw.toString()) as WsMessage));
    await waitFor(() => msgs.some((m) => m.type === 'hello'), 5000);

    const todo = makeTodo({ title: '会被改时间', when: 'today', reminder: new Date().toISOString().slice(0, 16) });
    await push(ctx.app, user.accessToken, 'dev_other', [
      makeOp({ entity: 'todo', entityId: todo.id, payload: todo, clientTs: Date.now() })
    ]);

    ctx.built.deps.reminders.start();
    await waitFor(() => msgs.some((m) => m.type === 'reminder' && m.todoId === todo.id), 6000);

    // 完成待办 → 索引移除
    await push(ctx.app, user.accessToken, 'dev_other', [
      makeOp({
        entity: 'todo',
        entityId: todo.id,
        payload: { ...todo, status: 'done', completedAt: Date.now() },
        clientTs: Date.now() + 1000
      })
    ]);
    const rows = await ctx.repo.listReminders(user.userId);
    assert.equal(rows.some((r) => r.todoId === todo.id), false, '完成的待办应移除提醒索引');

    ws.close();
    ctx.built.deps.reminders.stop();
  });
});
