/**
 * Ordo · 同步合并用例(契约 §7.3 六条规则 + §7.2 Op 结构 + §3 不变量)
 * 通过 MemoryOrdoStore + OrdoEngine 端到端验证:写入产出 Op、远端合并、墓碑拦截、LWW、标签并集、清单项合并。
 */

import { describe, expect, it } from '@ohos/hypium';
import { Heading, Op, Project, Todo } from '../../../main/ets/core/model/Entities.ets';
import { OrdoEngine } from '../../../main/ets/core/store/OrdoEngine.ets';
import { MemoryOrdoStore } from '../../../main/ets/core/storage/MemoryStore.ets';
import { ApplyResult } from '../../../main/ets/core/sync/SyncTypes.ets';
import { makeTodo, TodoOverrides } from './Fixtures.ets';

const DEVICE: string = 'dev_test';

/** 造一条远端 upsert op */
function opFor(todo: Todo, clientTs: number, type: string): Op {
  const op: Op = {
    opId: 'op_' + clientTs.toString() + '_' + todo.id,
    deviceId: 'dev_remote',
    entity: 'todo',
    entityId: todo.id,
    type: type === 'delete' ? 'delete' : 'upsert',
    payload: type === 'delete' ? null : JSON.stringify(todo),
    clientTs: clientTs,
    seq: 1
  };
  return op;
}

function remoteTodo(id: string, title: string, ts: number, opts?: TodoOverrides): Todo {
  if (opts === undefined) {
    return makeTodo(id, title, 'anytime', { createdAt: ts, updatedAt: ts });
  }
  const merged: TodoOverrides = opts;
  if (merged.createdAt === undefined) {
    merged.createdAt = ts;
  }
  if (merged.updatedAt === undefined) {
    merged.updatedAt = ts;
  }
  return makeTodo(id, title, 'anytime', merged);
}

async function newEngine(): Promise<OrdoEngine> {
  const store: MemoryOrdoStore = new MemoryOrdoStore();
  await store.init();
  const engine: OrdoEngine = new OrdoEngine(store);
  await engine.init(DEVICE);
  return engine;
}

export default function syncMergeTest() {
  describe('SyncMerge', () => {

    it('local_write_produces_outbox_op', 0, async (done: Function) => {
      const engine: OrdoEngine = await newEngine();
      const t: Todo | null = engine.createTodo({
        raw: '明天 交季度报告 #重要',
        projectId: null,
        areaId: null,
        headingId: null,
        when: null
      });
      expect(t === null).assertFalse();
      const todo: Todo = t as Todo;
      expect(todo.when).assertEqual('date');
      expect(todo.tags.length).assertEqual(1);

      const ops: Op[] = engine.takePendingOps(10);
      // 契约 §7.1「每个写操作产出一条 Op」+ §3「标签必须已存在,否则自动创建」:
      // 带新标签的待办 = 自动建标签 + 建待办,共 2 条 op(先 tag 后 todo)。
      expect(ops.length).assertEqual(2);
      expect(ops[0].entity).assertEqual('tag');
      expect(ops[0].type).assertEqual('upsert');
      expect(ops[1].entity).assertEqual('todo');
      expect(ops[1].type).assertEqual('upsert');
      expect(ops[1].payload === null).assertFalse();
      expect(ops[1].seq === null).assertTrue();
      done();
    });

    it('invariants_inbox_to_anytime_when_moved_into_project', 0, async (done: Function) => {
      const engine: OrdoEngine = await newEngine();
      const p = engine.createProject('测试项目', null);
      const t: Todo | null = engine.createTodo({
        raw: '整理资料',
        projectId: null,
        areaId: null,
        headingId: null,
        when: null
      });
      const todo: Todo = t as Todo;
      expect(todo.when).assertEqual('inbox'); // 契约 §3:未指定 when 且未指定项目 → inbox

      engine.moveTodo(todo.id, p.id, null, null);
      const after: Todo = engine.findTodo(todo.id) as Todo;
      expect(after.when).assertEqual('anytime'); // 契约 §3:移入项目 → anytime
      done();
    });

    it('invariants_reminder_moves_inbox_to_today_and_aligns_date', 0, async (done: Function) => {
      const engine: OrdoEngine = await newEngine();
      const t: Todo | null = engine.createTodo({
        raw: '打电话',
        projectId: null,
        areaId: null,
        headingId: null,
        when: null
      });
      const todo: Todo = t as Todo;
      expect(todo.when).assertEqual('inbox');

      engine.setReminder(todo.id, '2026-10-08T18:00');
      const after: Todo = engine.findTodo(todo.id) as Todo;
      expect(after.when).assertEqual('today'); // 契约 §3:设置提醒且 when ∈ {inbox,…} → today
      expect(after.reminder).assertEqual('2026-10-08T18:00');
      done();
    });

    it('lww_older_remote_is_stale', 0, async (done: Function) => {
      const engine: OrdoEngine = await newEngine();
      const t: Todo | null = engine.createTodo({
        raw: '原始标题', projectId: null, areaId: null, headingId: null, when: null
      });
      const todo: Todo = t as Todo;
      engine.setTodoTitle(todo.id, '本地新标题');
      const local: Todo = engine.findTodo(todo.id) as Todo;

      const remote: Todo = remoteTodo(todo.id, '远端更早标题', local.updatedAt - 5000);
      const result: ApplyResult = engine.applyRemoteOp(opFor(remote, local.updatedAt - 5000, 'upsert'));
      expect(result.outcome).assertEqual('stale');
      expect((engine.findTodo(todo.id) as Todo).title).assertEqual('本地新标题');
      done();
    });

    it('lww_newer_remote_is_applied', 0, async (done: Function) => {
      const engine: OrdoEngine = await newEngine();
      const t: Todo | null = engine.createTodo({
        raw: '原始标题', projectId: null, areaId: null, headingId: null, when: null
      });
      const todo: Todo = t as Todo;
      const local: Todo = engine.findTodo(todo.id) as Todo;

      const remote: Todo = remoteTodo(todo.id, '远端更新标题', local.updatedAt + 5000);
      const result: ApplyResult = engine.applyRemoteOp(opFor(remote, local.updatedAt + 5000, 'upsert'));
      expect(result.outcome).assertEqual('applied');
      expect((engine.findTodo(todo.id) as Todo).title).assertEqual('远端更新标题');
      done();
    });

    it('completion_cannot_roll_back', 0, async (done: Function) => {
      const engine: OrdoEngine = await newEngine();
      const t: Todo | null = engine.createTodo({
        raw: '要完成的事', projectId: null, areaId: null, headingId: null, when: null
      });
      const todo: Todo = t as Todo;
      engine.toggleDone(todo.id);
      const doneTodo: Todo = engine.findTodo(todo.id) as Todo;
      expect(doneTodo.status).assertEqual('done');
      const completedAt: number = doneTodo.completedAt as number;

      // 更早的 open 不能把完成状态回滚(契约 §7.3.2)
      const remote: Todo = remoteTodo(todo.id, doneTodo.title, completedAt - 1000, { status: 'open' });
      const result: ApplyResult = engine.applyRemoteOp(opFor(remote, completedAt - 1000, 'upsert'));
      expect(result.outcome).assertEqual('ignored');
      expect((engine.findTodo(todo.id) as Todo).status).assertEqual('done');
      done();
    });

    it('tags_are_unioned_even_when_stale', 0, async (done: Function) => {
      const engine: OrdoEngine = await newEngine();
      const t: Todo | null = engine.createTodo({
        raw: '标签合并', projectId: null, areaId: null, headingId: null, when: null
      });
      const todo: Todo = t as Todo;
      engine.addTagToTodo(todo.id, '本地标签');
      const local: Todo = engine.findTodo(todo.id) as Todo;

      const remote: Todo = remoteTodo(todo.id, local.title, local.updatedAt - 5000, { tags: ['远端标签'] });
      const result: ApplyResult = engine.applyRemoteOp(opFor(remote, local.updatedAt - 5000, 'upsert'));
      expect(result.outcome).assertEqual('stale');
      const merged: Todo = engine.findTodo(todo.id) as Todo;
      expect(merged.tags.length).assertEqual(2); // 契约 §7.3.3:stale 也要取并集
      expect(merged.tags.indexOf('本地标签') >= 0).assertTrue();
      expect(merged.tags.indexOf('远端标签') >= 0).assertTrue();
      done();
    });

    it('checklist_merged_by_id', 0, async (done: Function) => {
      const engine: OrdoEngine = await newEngine();
      const t: Todo | null = engine.createTodo({
        raw: '清单合并', projectId: null, areaId: null, headingId: null, when: null
      });
      const todo: Todo = t as Todo;
      engine.addChecklistItem(todo.id, '本地项');
      const local: Todo = engine.findTodo(todo.id) as Todo;
      const localItemId: string = local.checklist[0].id;

      const remote: Todo = remoteTodo(todo.id, local.title, local.updatedAt + 5000, {
        checklist: [
          { id: localItemId, title: '远端改写的本地项', done: true },
          { id: 'remote_only', title: '远端独有项', done: false }
        ]
      });
      const result: ApplyResult = engine.applyRemoteOp(opFor(remote, local.updatedAt + 5000, 'upsert'));
      expect(result.outcome).assertEqual('applied');
      const merged: Todo = engine.findTodo(todo.id) as Todo;
      expect(merged.checklist.length).assertEqual(2);
      // 两端都有的项取 winner(远端,因为远端 LWW 胜出)
      expect(merged.checklist[0].title).assertEqual('远端改写的本地项');
      expect(merged.checklist[1].id).assertEqual('remote_only');
      done();
    });

    it('tombstone_blocks_older_op', 0, async (done: Function) => {
      const engine: OrdoEngine = await newEngine();
      const t: Todo | null = engine.createTodo({
        raw: '会被删除', projectId: null, areaId: null, headingId: null, when: null
      });
      const todo: Todo = t as Todo;
      engine.deleteTodo(todo.id); // 本地墓碑
      const deleted: Todo = engine.findTodo(todo.id) as Todo;
      expect(deleted.deleted).assertTrue();

      // 更早的 upsert 不能让实体复活(契约 §7.3.5)
      const remote: Todo = remoteTodo(todo.id, '复活尝试', deleted.updatedAt - 10000);
      const result: ApplyResult = engine.applyRemoteOp(opFor(remote, deleted.updatedAt - 10000, 'upsert'));
      expect(result.outcome).assertEqual('tombstoned');
      expect((engine.findTodo(todo.id) as Todo).deleted).assertTrue();
      done();
    });

    it('remote_delete_op_soft_deletes_newer_local', 0, async (done: Function) => {
      const engine: OrdoEngine = await newEngine();
      const t: Todo | null = engine.createTodo({
        raw: '远端删除我', projectId: null, areaId: null, headingId: null, when: null
      });
      const todo: Todo = t as Todo;
      const local: Todo = engine.findTodo(todo.id) as Todo;

      const op: Op = opFor(local, local.updatedAt + 8000, 'delete');
      const result: ApplyResult = engine.applyRemoteOp(op);
      expect(result.outcome).assertEqual('applied');
      expect((engine.findTodo(todo.id) as Todo).deleted).assertTrue();
      done();
    });

    it('empty_title_is_treated_as_delete', 0, async (done: Function) => {
      const engine: OrdoEngine = await newEngine();
      const t: Todo | null = engine.createTodo({
        raw: '空标题处理', projectId: null, areaId: null, headingId: null, when: null
      });
      const todo: Todo = t as Todo;
      const local: Todo = engine.findTodo(todo.id) as Todo;

      const remote: Todo = remoteTodo(todo.id, '   ', local.updatedAt + 3000);
      const result: ApplyResult = engine.applyRemoteOp(opFor(remote, local.updatedAt + 3000, 'upsert'));
      expect(result.outcome).assertEqual('applied');
      expect((engine.findTodo(todo.id) as Todo).deleted).assertTrue(); // 契约 §7.3.6
      done();
    });

    it('push_confirm_removes_only_accepted', 0, async (done: Function) => {
      const engine: OrdoEngine = await newEngine();
      engine.createTodo({ raw: 'a', projectId: null, areaId: null, headingId: null, when: null });
      engine.createTodo({ raw: 'b', projectId: null, areaId: null, headingId: null, when: null });
      const ops: Op[] = engine.takePendingOps(10);
      expect(ops.length).assertEqual(2);

      engine.confirmPushed([ops[0].opId]);
      expect(engine.pendingCount()).assertEqual(1);
      const remain: Op[] = engine.takePendingOps(10);
      expect(remain[0].opId).assertEqual(ops[1].opId);
      done();
    });

    it('snapshot_export_contains_all_entities', 0, async (done: Function) => {
      const engine: OrdoEngine = await newEngine();
      engine.createArea('测试区域', '#5B5BD6');
      engine.createProject('测试项目', null);
      engine.createTodo({ raw: '测试待办', projectId: null, areaId: null, headingId: null, when: null });
      const json: string = engine.exportSnapshot();
      expect(json.indexOf('"serverSeq"') >= 0).assertTrue();
      expect(json.indexOf('测试区域') >= 0).assertTrue();
      expect(json.indexOf('测试项目') >= 0).assertTrue();
      expect(json.indexOf('测试待办') >= 0).assertTrue();
      done();
    });

    /* --------- 契约 §2.2 项目完成规则 v1.1(与 Kotlin 参考实现逐条对齐)--------- */

    it('complete_project_rejected_while_open_todos_remain', 0, async (done: Function) => {
      // ① 唯一硬约束:项目下还有 status == open 的待办 → 拒绝,且不留半成品
      const engine: OrdoEngine = await newEngine();
      const p: Project = engine.createProject('未完成项目', null);
      const h: Heading = engine.addHeading(p.id, '阶段一') as Heading;
      engine.createTodo({ raw: '还没做', projectId: p.id, areaId: null, headingId: h.id, when: null });

      expect(engine.canCompleteProject(p.id)).assertFalse();
      expect(engine.completeProject(p.id)).assertFalse();
      const after: Project = engine.findProject(p.id) as Project;
      expect(after.status).assertEqual('open');
      expect(after.completedAt === null).assertTrue();
      expect(after.headings[0].archived).assertFalse(); // 被拒时不得先归档标题
      done();
    });

    it('complete_project_allowed_with_unarchived_headings_and_archives_them', 0, async (done: Function) => {
      // ② 待办都结束但标题未归档 → 允许完成,且完成后自动归档(§2.2 v1.1)
      const engine: OrdoEngine = await newEngine();
      const p: Project = engine.createProject('Q4 产品发布', null);
      const h1: Heading = engine.addHeading(p.id, '设计') as Heading;
      engine.addHeading(p.id, '开发');
      const t: Todo | null = engine.createTodo({
        raw: '写方案', projectId: p.id, areaId: null, headingId: h1.id, when: null
      });
      expect(t === null).assertFalse();
      engine.toggleDone((t as Todo).id);

      const before: Project = engine.findProject(p.id) as Project;
      expect(before.headings.length).assertEqual(2);
      expect(before.headings[0].archived).assertFalse();
      expect(engine.canCompleteProject(p.id)).assertTrue(); // 未归档标题不再阻塞

      expect(engine.completeProject(p.id)).assertTrue();
      const after: Project = engine.findProject(p.id) as Project;
      expect(after.status).assertEqual('done');
      expect(after.completedAt === null).assertFalse();
      // 不变量:已完成项目不含未归档标题
      let unarchived: number = 0;
      for (let i = 0; i < after.headings.length; i++) {
        if (!after.headings[i].archived) {
          unarchived++;
        }
      }
      expect(unarchived).assertEqual(0);
      // 幂等:已完成的项目重复调用不再产 Op
      const opsAfter: number = engine.pendingCount();
      expect(engine.completeProject(p.id)).assertFalse();
      expect(engine.pendingCount()).assertEqual(opsAfter);
      done();
    });

    it('complete_project_emits_heading_archive_ops_then_project_op', 0, async (done: Function) => {
      // ③ 自动归档的 Op 数量与实体类型正确:2 个标题 → 2 条 heading op + 1 条 project op
      const engine: OrdoEngine = await newEngine();
      const p: Project = engine.createProject('发布项目', null);
      engine.addHeading(p.id, '设计');
      engine.addHeading(p.id, '开发');
      const t: Todo | null = engine.createTodo({
        raw: '收尾', projectId: p.id, areaId: null, headingId: null, when: null
      });
      engine.toggleDone((t as Todo).id);

      const opsBefore: number = engine.pendingCount();
      expect(engine.completeProject(p.id)).assertTrue();
      expect(engine.pendingCount() - opsBefore).assertEqual(3);

      const all: Op[] = engine.takePendingOps(1000);
      const fresh: Op[] = all.slice(opsBefore);
      expect(fresh.length).assertEqual(3);
      expect(fresh[0].entity).assertEqual('heading');
      expect(fresh[0].type).assertEqual('upsert');
      expect(fresh[1].entity).assertEqual('heading');
      expect(fresh[1].type).assertEqual('upsert');
      expect(fresh[2].entity).assertEqual('project');
      expect(fresh[2].type).assertEqual('upsert');
      // 归档 Op 与手工归档同构:完整 heading payload + archived=true
      expect((fresh[0].payload as string).indexOf('"archived":true') >= 0).assertTrue();
      expect((fresh[1].payload as string).indexOf('"archived":true') >= 0).assertTrue();
      expect((fresh[2].payload as string).indexOf('"status":"done"') >= 0).assertTrue();
      done();
    });
  });
}
