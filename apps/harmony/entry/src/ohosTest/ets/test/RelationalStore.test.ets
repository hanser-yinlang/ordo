/**
 * Ordo · 真机 RDB 写盘回归用例(契约 §8:表字段名与 §2 完全一致)
 *
 * 为什么单独有这一组:`_qa` 宿主跑的是 `MemoryOrdoStore`(纯 JS),**永远走不到真 SQLite**;
 * 而 `order` / `when` 是 SQL 保留字,一旦拼 SQL 时漏掉双引号,真机上写入会直接
 * `errno 25: near "order": syntax error`。第六轮(task-7)就是用模拟器真机抓到的这条缺陷:
 * 症状是"验证码登录看着失败(报网络错误)、重启卡在启动页",根因是 `persistAll(seed)` 抛错。
 *
 * 因此本组用例**必须连真库**:用与 App 相同的 `RdbOrdoStore` 打开一个独立探针目录
 * (`<databaseDir>/rdb/qa_rdb_probe/ordo.db`,不碰任何账号数据),写入含保留字列名的行再读回。
 * 修复前这组会红,修复后应全绿 —— 它就是这条缺陷的回归闸门。
 *
 * 运行:`hdc shell aa test -b com.ordo.app -m entry_test -s unittest OpenHarmonyTestRunner`
 */

import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { RdbOrdoStore } from '../../../main/ets/core/storage/RelationalStore.ets';
import { Area, Heading, Op, Project, Tag, Todo, Tombstone } from '../../../main/ets/core/model/Entities.ets';
import { makeTodo } from './Fixtures.ets';
import { TestContext } from '../testability/TestAbility.ets';

/** 独立探针目录:与任何真实账号目录都不重名 */
const PROBE_DIR: string = 'qa_rdb_probe';

/**
 * 打开探针库。
 * 注意用 **UIAbility 上下文**(由 TestAbility 在 onCreate 里放进 `TestContext`):
 * `getAppContext()` 返回的是应用上下文,RDB 会报 `Illegal context`。
 */
function probeStore(): RdbOrdoStore {
  const context: common.UIAbilityContext | null = TestContext.ability;
  if (context === null) {
    throw new Error('TestContext.ability 为空:测试上下文未就绪');
  }
  return new RdbOrdoStore(context, PROBE_DIR, false);
}

export default function relationalStoreTest() {
  describe('RelationalStore', () => {

    it('reserved_word_columns_roundtrip_on_real_sqlite', 0, async (done: Function) => {
      const store: RdbOrdoStore = probeStore();
      await store.init();

      // ---- areas:含保留字列 order ----
      const area: Area = {
        id: 'qa_area_1',
        name: '探针区域',
        color: '#5B5BD6',
        order: 7,
        archived: false,
        updatedAt: 111,
        deleted: false
      };
      await store.saveArea(area);
      const areas: Area[] = await store.loadAreas();
      let gotArea: Area | null = null;
      for (let i = 0; i < areas.length; i++) {
        if (areas[i].id === 'qa_area_1') {
          gotArea = areas[i];
        }
      }
      expect(gotArea === null).assertFalse();
      const a: Area = gotArea as Area;
      expect(a.order).assertEqual(7);
      expect(a.name).assertEqual('探针区域');

      // ---- projects:含保留字列 when + order ----
      const project: Project = {
        id: 'qa_proj_1',
        areaId: 'qa_area_1',
        name: '探针项目',
        note: 'note',
        when: 'anytime',
        date: null,
        deadline: null,
        tags: ['qa'],
        headings: [],
        order: 5,
        status: 'open',
        completedAt: null,
        repeat: null,
        createdAt: 100,
        updatedAt: 111,
        deleted: false
      };
      await store.saveProject(project);
      const projects: Project[] = await store.loadProjects();
      let gotProject: Project | null = null;
      for (let i = 0; i < projects.length; i++) {
        if (projects[i].id === 'qa_proj_1') {
          gotProject = projects[i];
        }
      }
      expect(gotProject === null).assertFalse();
      const p: Project = gotProject as Project;
      expect(p.when).assertEqual('anytime');
      expect(p.order).assertEqual(5);
      expect(p.tags.length).assertEqual(1);

      // ---- headings:含保留字列 order ----
      const heading: Heading = {
        id: 'qa_head_1',
        projectId: 'qa_proj_1',
        name: '探针标题',
        order: 3,
        archived: false,
        collapsed: false,
        updatedAt: 111
      };
      await store.saveHeading(heading);
      const headings: Heading[] = await store.loadHeadings();
      let gotHeading: Heading | null = null;
      for (let i = 0; i < headings.length; i++) {
        if (headings[i].id === 'qa_head_1') {
          gotHeading = headings[i];
        }
      }
      expect(gotHeading === null).assertFalse();
      expect((gotHeading as Heading).order).assertEqual(3);

      // ---- todos:含保留字列 when + order(真实 SQLite 上最容易炸的一条) ----
      const todo = makeTodo('qa_todo_1', '探针待办', 'today', { order: 9, projectId: 'qa_proj_1' });
      await store.saveTodo(todo);
      const todos: Todo[] = await store.loadTodos();
      let gotTodo: Todo | null = null;
      for (let i = 0; i < todos.length; i++) {
        if (todos[i].id === 'qa_todo_1') {
          gotTodo = todos[i];
        }
      }
      expect(gotTodo === null).assertFalse();
      expect((gotTodo as Todo).order).assertEqual(9);
      expect((gotTodo as Todo).when).assertEqual('today');
      expect((gotTodo as Todo).title).assertEqual('探针待办');

      // ---- tags ----
      const tag: Tag = { id: 'qa_tag_1', name: 'qa', color: '#5B5BD6', updatedAt: 111 };
      await store.saveTag(tag);
      const tags: Tag[] = await store.loadTags();
      let gotTag: Tag | null = null;
      for (let i = 0; i < tags.length; i++) {
        if (tags[i].id === 'qa_tag_1') {
          gotTag = tags[i];
        }
      }
      expect(gotTag === null).assertFalse();
      expect((gotTag as Tag).name).assertEqual('qa');

      done();
    });

    it('kv_outbox_and_tombstone_roundtrip', 0, async (done: Function) => {
      const store: RdbOrdoStore = probeStore();
      await store.init();

      await store.setKv('qa.kv', 'qa-value');
      expect(await store.getKv('qa.kv')).assertEqual('qa-value');

      const op: Op = {
        opId: 'qa_op_1',
        deviceId: 'qa',
        entity: 'todo',
        entityId: 'qa_todo_1',
        type: 'upsert',
        payload: '{"id":"qa_todo_1"}',
        clientTs: 42,
        seq: null
      };
      await store.appendOutbox(op);
      const ops: Op[] = await store.loadOutbox();
      let gotOp: Op | null = null;
      for (let i = 0; i < ops.length; i++) {
        if (ops[i].opId === 'qa_op_1') {
          gotOp = ops[i];
        }
      }
      expect(gotOp === null).assertFalse();
      expect((gotOp as Op).entity).assertEqual('todo');
      expect((gotOp as Op).clientTs).assertEqual(42);

      const tomb: Tombstone = { entity: 'todo', entityId: 'qa_todo_1', deletedAt: 7, clientTs: 8 };
      await store.saveTombstone(tomb);
      const tombs: Tombstone[] = await store.loadTombstones();
      let gotTomb: Tombstone | null = null;
      for (let i = 0; i < tombs.length; i++) {
        if (tombs[i].entityId === 'qa_todo_1') {
          gotTomb = tombs[i];
        }
      }
      expect(gotTomb === null).assertFalse();
      expect((gotTomb as Tombstone).deletedAt).assertEqual(7);

      done();
    });
  });
}
