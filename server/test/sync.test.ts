/**
 * 同步协议测试 —— 契约 §7.2 / §7.3 / §7.4
 * 覆盖:幂等 / LWW / stale / 完成不可回滚 / 标签并集 / checklist 合并 / 墓碑 / 捎带拉取 / 分页 / 快照 / §3 不变量
 */
import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import {
  authHeaders,
  makeApp,
  makeOp,
  makeTodo,
  newId,
  push,
  registerUser,
  RegisteredUser,
  snapshot,
  TestContext,
  uniqueEmail
} from './helpers';

const DEV_A = 'dev_aaa';
const DEV_B = 'dev_bbb';

describe('同步协议 §7', () => {
  let ctx: TestContext;
  let user: RegisteredUser;

  before(async () => {
    ctx = await makeApp();
    user = await registerUser(ctx.app, { email: uniqueEmail('sync'), deviceId: DEV_A });
  });

  after(async () => {
    await ctx.close();
  });

  it('推送后可在快照中读到,且 serverSeq 单调递增', async () => {
    const todo = makeTodo({ title: '第一件事' });
    const r1 = await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: todo.id, payload: todo, clientTs: 1_000 })
    ]);
    assert.equal(r1.statusCode, 200);
    assert.equal(r1.body.rejected.length, 0);
    assert.equal(r1.body.accepted[0].applied, true);
    assert.ok(r1.body.accepted[0].serverSeq > 0);

    const snap = await snapshot(ctx.app, user.accessToken);
    assert.equal(snap.todos.length, 1);
    assert.equal(snap.todos[0].title, '第一件事');
    assert.equal(snap.serverSeq, r1.body.serverSeq);

    const todo2 = makeTodo({ title: '第二件事' });
    const r2 = await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: todo2.id, payload: todo2, clientTs: 2_000 })
    ]);
    assert.ok(r2.body.serverSeq > r1.body.serverSeq, 'serverSeq 必须单调递增');
  });

  it('幂等:同一 opId 推送两次只生效一次', async () => {
    const todo = makeTodo({ title: '幂等测试' });
    const op = makeOp({ entity: 'todo', entityId: todo.id, payload: todo, clientTs: 3_000 });

    const first = await push(ctx.app, user.accessToken, DEV_A, [op]);
    assert.equal(first.body.accepted[0].applied, true);

    const second = await push(ctx.app, user.accessToken, DEV_A, [op]);
    assert.equal(second.statusCode, 200);
    assert.equal(second.body.accepted.length, 1);
    assert.equal(second.body.accepted[0].duplicate, true);
    assert.equal(second.body.accepted[0].applied, false);

    const rows = await ctx.repo.listEntities(user.userId, 'todo');
    assert.equal(rows.filter((r) => r.entityId === todo.id).length, 1);
    assert.equal((rows.find((r) => r.entityId === todo.id)!.payload as { updatedAt: number }).updatedAt, 3_000);
    assert.equal(second.body.serverSeq, first.body.serverSeq, '重复推送不应产生新的 op');
  });

  it('LWW:clientTs 高者胜出,低者被标记 stale', async () => {
    const id = newId();
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: id, payload: makeTodo({ id, title: '旧标题' }), clientTs: 10_000 })
    ]);
    const win = await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: id, payload: makeTodo({ id, title: '新标题' }), clientTs: 20_000 })
    ]);
    assert.equal(win.body.accepted[0].applied, true);

    const stale = await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: id, payload: makeTodo({ id, title: '更旧的标题' }), clientTs: 15_000 })
    ]);
    assert.equal(stale.body.rejected.length, 1);
    assert.equal(stale.body.rejected[0].reason, 'stale');

    const snap = await snapshot(ctx.app, user.accessToken);
    assert.equal(snap.todos.find((t: { id: string }) => t.id === id).title, '新标题');
  });

  it('完成不可回滚:已完成实体拒绝被 open 覆盖', async () => {
    const id = newId();
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: id, payload: makeTodo({ id, title: '会被完成' }), clientTs: 30_000 })
    ]);
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({
        entity: 'todo',
        entityId: id,
        payload: makeTodo({ id, title: '会被完成', status: 'done', completedAt: 31_000 }),
        clientTs: 31_000
      })
    ]);

    // 即使 clientTs 更大,也不允许把 done 改回 open
    const reopen = await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: id, payload: makeTodo({ id, title: '想复活', status: 'open' }), clientTs: 32_000 })
    ]);
    assert.equal(reopen.body.rejected.length, 1);
    assert.equal(reopen.body.rejected[0].reason, 'completion_immutable');

    const snap = await snapshot(ctx.app, user.accessToken);
    const stored = snap.todos.find((t: { id: string }) => t.id === id);
    assert.equal(stored.status, 'done');
    assert.equal(stored.title, '会被完成');
  });

  it('标签取并集:低 clientTs 的 op 虽然被判负,标签仍然并入', async () => {
    const id = newId();
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: id, payload: makeTodo({ id, tags: ['重要'] }), clientTs: 40_000 })
    ]);

    const staleTags = await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: id, payload: makeTodo({ id, tags: ['外出'] }), clientTs: 39_000 })
    ]);
    assert.equal(staleTags.body.rejected[0].reason, 'stale');

    const snap = await snapshot(ctx.app, user.accessToken);
    const stored = snap.todos.find((t: { id: string }) => t.id === id);
    assert.deepEqual([...stored.tags].sort(), ['外出', '重要'].sort(), '§7.3 规则 3:标签取并集');

    // 正常路径(高 clientTs)同样是并集,而不是覆盖
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: id, payload: makeTodo({ id, tags: ['紧急'] }), clientTs: 41_000 })
    ]);
    const snap2 = await snapshot(ctx.app, user.accessToken);
    const stored2 = snap2.todos.find((t: { id: string }) => t.id === id);
    assert.deepEqual([...stored2.tags].sort(), ['外出', '紧急', '重要'].sort());
  });

  it('checklist 按 id 合并:两端都有的取胜者,仅一端有的保留', async () => {
    const id = newId();
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({
        entity: 'todo',
        entityId: id,
        payload: makeTodo({
          id,
          checklist: [
            { id: 'c1', title: '订机票', done: false },
            { id: 'c2', title: '订酒店', done: false }
          ]
        }),
        clientTs: 50_000
      })
    ]);

    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({
        entity: 'todo',
        entityId: id,
        payload: makeTodo({
          id,
          checklist: [
            { id: 'c2', title: '订酒店', done: true },
            { id: 'c3', title: '换外币', done: false }
          ]
        }),
        clientTs: 51_000
      })
    ]);

    const snap = await snapshot(ctx.app, user.accessToken);
    const stored = snap.todos.find((t: { id: string }) => t.id === id);
    const byId = Object.fromEntries(stored.checklist.map((c: { id: string; done: boolean }) => [c.id, c.done]));
    assert.deepEqual(Object.keys(byId).sort(), ['c1', 'c2', 'c3'], '并集:仅一端有的项都保留');
    assert.equal(byId.c2, true, '两端都有的项取 LWW 胜者(新 op)');
    assert.equal(byId.c1, false);
  });

  it('删除墓碑:软删除后,更旧的 upsert 不能复活实体', async () => {
    const id = newId();
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: id, payload: makeTodo({ id, title: '待删除' }), clientTs: 60_000 })
    ]);
    const del = await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: id, type: 'delete', payload: null, clientTs: 61_000 })
    ]);
    assert.equal(del.body.accepted[0].applied, true);

    const revive = await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: id, payload: makeTodo({ id, title: '试图复活' }), clientTs: 60_500 })
    ]);
    assert.equal(revive.body.rejected.length, 1);
    assert.equal(revive.body.rejected[0].reason, 'tombstoned');

    const snap = await snapshot(ctx.app, user.accessToken);
    assert.equal(snap.todos.some((t: { id: string }) => t.id === id), false, '墓碑必须阻止复活');

    const entity = await ctx.repo.getEntity(user.userId, 'todo', id);
    assert.equal(entity?.deleted, true);
    assert.equal((entity?.payload as { deleted: boolean }).deleted, true);
  });

  it('push 捎带返回 sinceSeq 之后的远端 ops', async () => {
    const remoteTodo = makeTodo({ title: '来自设备 A' });
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: remoteTodo.id, payload: remoteTodo, clientTs: 70_000 })
    ]);

    const mine = makeTodo({ title: '来自设备 B' });
    const res = await push(
      ctx.app,
      user.accessToken,
      DEV_B,
      [makeOp({ entity: 'todo', entityId: mine.id, payload: mine, clientTs: 70_100 })],
      0
    );
    assert.equal(res.statusCode, 200);
    assert.ok(res.body.ops.length > 0, '应捎带返回远端 ops');
    assert.ok(
      res.body.ops.some((op: { entityId: string }) => op.entityId === remoteTodo.id),
      '远端 op 必须出现在捎带结果里'
    );
    assert.equal(
      res.body.ops.some((op: { entityId: string }) => op.entityId === mine.id),
      false,
      '本次自己推的 op 不应回显'
    );
  });

  it('pull 分页:limit 生效且 hasMore 正确', async () => {
    const fresh = await registerUser(ctx.app, { email: uniqueEmail('pull') });
    for (let i = 0; i < 5; i += 1) {
      const t = makeTodo({ title: `分页 ${i}` });
      await push(ctx.app, fresh.accessToken, DEV_A, [
        makeOp({ entity: 'todo', entityId: t.id, payload: t, clientTs: 80_000 + i })
      ]);
    }

    const page1 = await ctx.app.inject({
      method: 'GET',
      url: '/v1/sync/pull?sinceSeq=0&limit=2',
      headers: authHeaders(fresh.accessToken)
    });
    assert.equal(page1.statusCode, 200);
    const body1 = page1.json();
    assert.equal(body1.ops.length, 2);
    assert.equal(body1.hasMore, true);

    const lastSeq = body1.ops[body1.ops.length - 1].seq;
    const page2 = await ctx.app.inject({
      method: 'GET',
      url: `/v1/sync/pull?sinceSeq=${lastSeq}&limit=2`,
      headers: authHeaders(fresh.accessToken)
    });
    const body2 = page2.json();
    assert.equal(body2.ops.length, 2);
    assert.ok(body2.ops[0].seq > lastSeq, 'ops 必须按 serverSeq 递增返回');

    const page3 = await ctx.app.inject({
      method: 'GET',
      url: `/v1/sync/pull?sinceSeq=${body2.ops[1].seq}&limit=2`,
      headers: authHeaders(fresh.accessToken)
    });
    const body3 = page3.json();
    assert.equal(body3.ops.length, 1);
    assert.equal(body3.hasMore, false);
  });

  it('sinceSeq 超前于服务端返回 409 SYNC_SEQ_GAP', async () => {
    const res = await ctx.app.inject({
      method: 'GET',
      url: '/v1/sync/pull?sinceSeq=999999',
      headers: authHeaders(user.accessToken)
    });
    assert.equal(res.statusCode, 409);
    assert.equal(res.json().error.code, 'SYNC_SEQ_GAP');

    const pushRes = await push(ctx.app, user.accessToken, DEV_A, [], 999999);
    assert.equal(pushRes.statusCode, 409);
    assert.equal(pushRes.body.error.code, 'SYNC_SEQ_GAP');
  });

  it('§3 不变量:移入项目后 inbox → anytime;提醒会把 when 拉进今天并对齐日期', async () => {
    const today = new Date().toISOString().slice(0, 10);

    const moved = makeTodo({ title: '进入项目', when: 'inbox', projectId: 'p-1' });
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: moved.id, payload: moved, clientTs: 90_000 })
    ]);

    const withReminder = makeTodo({ title: '带提醒', when: 'anytime', reminder: '2020-01-01T09:30' });
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: withReminder.id, payload: withReminder, clientTs: 90_100 })
    ]);

    const snap = await snapshot(ctx.app, user.accessToken);
    const t1 = snap.todos.find((t: { id: string }) => t.id === moved.id);
    assert.equal(t1.when, 'anytime', '移入项目的 inbox 待办应变为 anytime');
    assert.equal(t1.date, null);

    const t2 = snap.todos.find((t: { id: string }) => t.id === withReminder.id);
    assert.equal(t2.when, 'today', '设置提醒且 when ∈ {inbox,anytime,someday} → 自动改为 today');
    assert.equal(t2.reminder, `${today}T09:30`, '提醒日期部分必须对齐到「今天」');
  });

  it('§3:标题为空的实体视为删除', async () => {
    const id = newId();
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: id, payload: makeTodo({ id, title: '先创建' }), clientTs: 95_000 })
    ]);
    const res = await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: id, payload: makeTodo({ id, title: '   ' }), clientTs: 95_100 })
    ]);
    assert.equal(res.body.accepted[0].applied, true);

    const snap = await snapshot(ctx.app, user.accessToken);
    assert.equal(snap.todos.some((t: { id: string }) => t.id === id), false);
    const entity = await ctx.repo.getEntity(user.userId, 'todo', id);
    assert.equal(entity?.deleted, true);
  });

  it('§2.2 项目完成硬约束:子项未完成时不允许 done', async () => {
    const projectId = 'p-hard-rule';
    const project = {
      id: projectId,
      areaId: null,
      name: '硬约束项目',
      note: '',
      when: 'anytime',
      date: null,
      deadline: null,
      tags: [],
      order: 0,
      status: 'open',
      completedAt: null,
      repeat: null,
      createdAt: 100_000,
      updatedAt: 100_000,
      deleted: false
    };

    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'project', entityId: projectId, payload: project, clientTs: 100_000 })
    ]);
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({
        entity: 'todo',
        entityId: 't-child',
        payload: makeTodo({ id: 't-child', title: '未完成的子项', projectId, when: 'anytime' }),
        clientTs: 100_100
      })
    ]);

    const done = await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({
        entity: 'project',
        entityId: projectId,
        payload: { ...project, status: 'done', completedAt: 100_200 },
        clientTs: 100_200
      })
    ]);
    assert.equal(done.body.rejected.length, 1);
    assert.equal(done.body.rejected[0].reason, 'project_incomplete');

    // 子项完成后允许
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({
        entity: 'todo',
        entityId: 't-child',
        payload: makeTodo({
          id: 't-child',
          title: '未完成的子项',
          projectId,
          when: 'anytime',
          status: 'done',
          completedAt: 100_300
        }),
        clientTs: 100_300
      })
    ]);
    const done2 = await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({
        entity: 'project',
        entityId: projectId,
        payload: { ...project, status: 'done', completedAt: 100_400 },
        clientTs: 100_400
      })
    ]);
    assert.equal(done2.body.rejected.length, 0, '所有子项完成后应允许完成项目');
  });

  it('§2.2 Heading 是顶层实体:单独同步、快照单独返回;headingId 必须属于该项目', async () => {
    const projectId = 'p-heading';
    const headingId = 'h-design';
    const project = {
      id: projectId,
      areaId: null,
      name: '带标题的项目',
      note: '',
      when: 'anytime',
      date: null,
      deadline: null,
      tags: [],
      order: 0,
      status: 'open',
      completedAt: null,
      repeat: null,
      createdAt: 110_000,
      updatedAt: 110_000,
      deleted: false
    };
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'project', entityId: projectId, payload: project, clientTs: 110_000 })
    ]);
    // collapsed 是设备本地 UI 状态:推送 false/true 都不参与同步,服务端一律存 false
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({
        entity: 'heading',
        entityId: headingId,
        payload: { id: headingId, projectId, name: '设计', order: 0, archived: false, collapsed: true, updatedAt: 110_100 },
        clientTs: 110_100
      })
    ]);

    const snap = await snapshot(ctx.app, user.accessToken);
    const heading = snap.headings.find((h: { id: string }) => h.id === headingId);
    assert.ok(heading, 'heading 必须作为顶层实体出现在快照里');
    assert.equal(heading.projectId, projectId);
    assert.equal(heading.collapsed, false, 'collapsed 不参与同步,服务端忽略其值');
    const storedProject = snap.projects.find((p: { id: string }) => p.id === projectId);
    assert.equal('headings' in storedProject, false, 'Project 不应内嵌 headings(§2.2)');

    // headingId 合法 → 保留
    const good = makeTodo({ title: '属于标题的待办', projectId, headingId, when: 'anytime' });
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: good.id, payload: good, clientTs: 110_200 })
    ]);
    // headingId 不属于该项目 → 置 null
    const bad = makeTodo({ title: '标题不属于本项目', projectId, headingId: 'h-not-exist', when: 'anytime' });
    await push(ctx.app, user.accessToken, DEV_A, [
      makeOp({ entity: 'todo', entityId: bad.id, payload: bad, clientTs: 110_300 })
    ]);

    const snap2 = await snapshot(ctx.app, user.accessToken);
    assert.equal(snap2.todos.find((t: { id: string }) => t.id === good.id).headingId, headingId);
    assert.equal(snap2.todos.find((t: { id: string }) => t.id === bad.id).headingId, null, '非法 headingId 应被置 null');
  });

  it('空 ops 推送也能正常返回(客户端心跳式同步)', async () => {
    const res = await push(ctx.app, user.accessToken, DEV_A, []);
    assert.equal(res.statusCode, 200);
    assert.equal(Array.isArray(res.body.ops), true);
  });
});
