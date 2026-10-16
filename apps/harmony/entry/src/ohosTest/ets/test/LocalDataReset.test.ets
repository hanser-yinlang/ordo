/**
 * Ordo · 「清空本地数据 / 清除演示数据」与启动播种判据用例
 * (`core/store/OrdoEngine.ets` 的 clearAll / clearDemoData + `viewmodel/SeedPolicy.ets`;
 * 契约 §7.6.3 的本地化版本)
 *
 * 守的是**用户报过的一类 bug**:设置页三条入口的语义必须不同 ——
 *  1.「恢复默认示例数据」:立刻写回演示数据,并保证播种标记存在;
 *  2.「清空本地数据」:退回**全新安装态**(实体 + outbox + 墓碑 + 播种标记全清),界面立刻变空,
 *    **下次冷启动**才重新播种(不是只剩一个空界面);
 *  3.「清除演示数据」:内容一样清空,但**钉住播种标记** —— 重启后演示数据不会自己长回来
 *    (用户明确要求);想找回示例数据只能显式点「恢复默认示例数据」;
 *  4. 用户**自己逐条删空**待办(没点过清空)时标记还在,冷启动**不得**把演示数据塞回来。
 *
 * 全部基于 MemoryOrdoStore(不需要设备 RDB),因此宿主机 harness 跑的是同一份用例。
 */

import { describe, expect, it } from '@ohos/hypium';
import { Todo } from '../../../main/ets/core/model/Entities.ets';
import { OrdoEngine } from '../../../main/ets/core/store/OrdoEngine.ets';
import { KvKeys } from '../../../main/ets/core/storage/OrdoStore.ets';
import { MemoryOrdoStore } from '../../../main/ets/core/storage/MemoryStore.ets';
import { buildSeedState } from '../../../main/ets/core/SeedData.ets';
import { todayISO } from '../../../main/ets/core/util/DateUtil.ets';
import { SEEDED_MARK_VALUE, applyResetToSeedData, applySeedPolicy, shouldSeedDemoData } from '../../../main/ets/viewmodel/SeedPolicy.ets';

const DEVICE: string = 'dev_localdata';

/** 一个工作区 = 一份库 + 一个引擎 */
interface Workspace {
  store: MemoryOrdoStore;
  engine: OrdoEngine;
}

async function freshWorkspace(): Promise<Workspace> {
  const store: MemoryOrdoStore = new MemoryOrdoStore(undefined, 'local-test', false);
  await store.init();
  const engine: OrdoEngine = new OrdoEngine(store);
  await engine.init(DEVICE);
  return { store: store, engine: engine };
}

/** 已经完成首次播种的工作区 */
async function seededWorkspace(): Promise<Workspace> {
  const ws: Workspace = await freshWorkspace();
  const wrote: boolean = await applySeedPolicy(ws.store, ws.engine, buildSeedState(todayISO()));
  expect(wrote).assertTrue();
  return ws;
}

/** 冷启动:同一个库重新装载一个引擎(播种判据照旧走 applySeedPolicy) */
async function coldStart(store: MemoryOrdoStore): Promise<OrdoEngine> {
  const engine: OrdoEngine = new OrdoEngine(store);
  await engine.init(DEVICE);
  return engine;
}

/** 还"活着"的待办数:软删除的行(契约 §3,deleted = true)不算 */
function aliveTodos(engine: OrdoEngine): number {
  const all: Todo[] = engine.todos();
  let n: number = 0;
  for (let i = 0; i < all.length; i++) {
    if (!all[i].deleted) {
      n = n + 1;
    }
  }
  return n;
}

/** 把当前所有待办逐条删掉 = "用户自己删空" */
function deleteEveryTodo(engine: OrdoEngine): void {
  const ids: string[] = [];
  const all: Todo[] = engine.todos();
  for (let i = 0; i < all.length; i++) {
    ids.push(all[i].id);
  }
  for (let i = 0; i < ids.length; i++) {
    engine.deleteTodo(ids[i]);
  }
}

export default function localDataResetTest() {
  describe('LocalDataReset', () => {

    it('clear_all_returns_to_fresh_install_state', 0, async (done: Function) => {
      const ws: Workspace = await seededWorkspace();
      // 先制造 outbox 与墓碑:删一条待办(软删除会登记墓碑,并产出一条待推送 op)
      const victim: Todo = ws.engine.todos()[0];
      ws.engine.deleteTodo(victim.id);
      expect(ws.engine.pendingCount() > 0).assertTrue();
      expect(ws.engine.listTombstones().length > 0).assertTrue();

      await ws.engine.clearAll();

      // 内存状态必须立刻就空(UI 读的是它,不清就会出现"库空了界面还满着")
      expect(ws.engine.todos().length).assertEqual(0);
      expect(ws.engine.projects().length).assertEqual(0);
      expect(ws.engine.areas().length).assertEqual(0);
      expect(ws.engine.tags().length).assertEqual(0);
      expect(ws.engine.allHeadings().length).assertEqual(0);
      expect(ws.engine.pendingCount()).assertEqual(0);
      expect(ws.engine.listTombstones().length).assertEqual(0);

      // 库里也真的空了(重新装载 = 冷启动读库)
      const cold: OrdoEngine = await coldStart(ws.store);
      expect(cold.todos().length).assertEqual(0);
      expect(cold.projects().length).assertEqual(0);
      expect(cold.areas().length).assertEqual(0);
      expect(cold.tags().length).assertEqual(0);
      expect(cold.allHeadings().length).assertEqual(0);
      expect(cold.pendingCount()).assertEqual(0);
      expect(cold.listTombstones().length).assertEqual(0);
      done();
    });

    it('clear_all_drops_the_seed_mark_only', 0, async (done: Function) => {
      const ws: Workspace = await seededWorkspace();
      await ws.store.setKv(KvKeys.LOCAL_ACCOUNT_ID, 'local-805e05692b26ba14');
      expect(await ws.store.getKv(KvKeys.SEEDED)).assertEqual(SEEDED_MARK_VALUE);

      await ws.engine.clearAll();

      // 标记没了 = 全新安装态(下次冷启动才会重新播种)
      expect(await ws.store.getKv(KvKeys.SEEDED)).assertEqual(null);
      // 设备级 kv(工作区标识)必须留着:一变用户就以为自己的库被换掉了
      expect(await ws.store.getKv(KvKeys.LOCAL_ACCOUNT_ID)).assertEqual('local-805e05692b26ba14');
      done();
    });

    it('cold_start_after_clear_seeds_demo_data_again', 0, async (done: Function) => {
      const ws: Workspace = await seededWorkspace();
      await ws.engine.clearAll();
      expect(await ws.store.getKv(KvKeys.SEEDED)).assertEqual(null);

      const cold: OrdoEngine = await coldStart(ws.store);
      const wrote: boolean = await applySeedPolicy(ws.store, cold, buildSeedState(todayISO()));

      expect(wrote).assertTrue();
      expect(cold.projects().length > 0).assertTrue();
      expect(aliveTodos(cold) > 0).assertTrue();
      expect(await ws.store.getKv(KvKeys.SEEDED)).assertEqual(SEEDED_MARK_VALUE);
      done();
    });

    it('user_emptying_the_list_never_resurrects_demo_data', 0, async (done: Function) => {
      const ws: Workspace = await seededWorkspace();
      const rowsBefore: number = ws.engine.todos().length;
      deleteEveryTodo(ws.engine);
      expect(aliveTodos(ws.engine)).assertEqual(0);

      const cold: OrdoEngine = await coldStart(ws.store);
      const wrote: boolean = await applySeedPolicy(ws.store, cold, buildSeedState(todayISO()));

      // 标记还在 → 不播种;行数不变(没有"复活"出任何新待办)
      expect(wrote).assertFalse();
      expect(aliveTodos(cold)).assertEqual(0);
      expect(cold.todos().length).assertEqual(rowsBefore);
      expect(await ws.store.getKv(KvKeys.SEEDED)).assertEqual(SEEDED_MARK_VALUE);
      done();
    });

    it('seed_mark_alone_blocks_reseeding_on_an_empty_db', 0, async (done: Function) => {
      const ws: Workspace = await freshWorkspace();
      await ws.store.setKv(KvKeys.SEEDED, SEEDED_MARK_VALUE);

      const wrote: boolean = await applySeedPolicy(ws.store, ws.engine, buildSeedState(todayISO()));

      // 判据是**标记**,不是"库空不空"
      expect(wrote).assertFalse();
      expect(ws.engine.todos().length).assertEqual(0);
      expect(ws.engine.projects().length).assertEqual(0);
      done();
    });

    it('existing_data_without_mark_is_only_marked_never_overwritten', 0, async (done: Function) => {
      const ws: Workspace = await freshWorkspace();
      ws.engine.createTodo({
        raw: '自己写的一条',
        projectId: null,
        areaId: null,
        headingId: null,
        when: null
      });

      const wrote: boolean = await applySeedPolicy(ws.store, ws.engine, buildSeedState(todayISO()));

      // 有数据但没标记(老版本升级):只补标记,绝不拿演示数据覆盖用户的东西
      expect(wrote).assertFalse();
      expect(ws.engine.todos().length).assertEqual(1);
      expect(await ws.store.getKv(KvKeys.SEEDED)).assertEqual(SEEDED_MARK_VALUE);
      done();
    });

    it('reset_to_seed_data_restores_data_and_mark', 0, async (done: Function) => {
      const ws: Workspace = await seededWorkspace();
      await ws.engine.clearAll();

      // 「恢复默认示例数据」的核心(见 AppStore.resetToSeedData → SeedPolicy.applyResetToSeedData)
      await applyResetToSeedData(ws.store, ws.engine, buildSeedState(todayISO()));

      expect(aliveTodos(ws.engine) > 0).assertTrue();
      expect(await ws.store.getKv(KvKeys.SEEDED)).assertEqual(SEEDED_MARK_VALUE);

      // 重置之后再逐条删空,冷启动依旧不得复活(这条路径上曾经缺标记)
      deleteEveryTodo(ws.engine);
      const cold: OrdoEngine = await coldStart(ws.store);
      const wrote: boolean = await applySeedPolicy(ws.store, cold, buildSeedState(todayISO()));
      expect(wrote).assertFalse();
      expect(aliveTodos(cold)).assertEqual(0);
      done();
    });

    it('clear_demo_data_empties_content_but_pins_the_seed_mark', 0, async (done: Function) => {
      const ws: Workspace = await seededWorkspace();
      // 先制造 outbox 与墓碑,证明清除演示数据也把这两样收拾干净
      ws.engine.deleteTodo(ws.engine.todos()[0].id);
      expect(ws.engine.pendingCount() > 0).assertTrue();

      await ws.engine.clearDemoData();

      expect(ws.engine.todos().length).assertEqual(0);
      expect(ws.engine.projects().length).assertEqual(0);
      expect(ws.engine.areas().length).assertEqual(0);
      expect(ws.engine.tags().length).assertEqual(0);
      expect(ws.engine.pendingCount()).assertEqual(0);
      expect(ws.engine.listTombstones().length).assertEqual(0);
      // 与 clearAll 的**唯一**区别:标记钉住 —— 这是「重启不再出现演示数据」的全部依据
      expect(await ws.store.getKv(KvKeys.SEEDED)).assertEqual(SEEDED_MARK_VALUE);
      done();
    });

    it('cold_start_after_clear_demo_data_never_reseeds', 0, async (done: Function) => {
      const ws: Workspace = await seededWorkspace();
      await ws.engine.clearDemoData();

      const cold: OrdoEngine = await coldStart(ws.store);
      const wrote: boolean = await applySeedPolicy(ws.store, cold, buildSeedState(todayISO()));

      expect(wrote).assertFalse();
      expect(aliveTodos(cold)).assertEqual(0);
      expect(cold.projects().length).assertEqual(0);
      expect(cold.todos().length).assertEqual(0);
      expect(await ws.store.getKv(KvKeys.SEEDED)).assertEqual(SEEDED_MARK_VALUE);
      done();
    });

    it('clear_all_and_clear_demo_data_differ_only_by_the_seed_mark', 0, async (done: Function) => {
      const wsAll: Workspace = await seededWorkspace();
      await wsAll.engine.clearAll();
      const wsDemo: Workspace = await seededWorkspace();
      await wsDemo.engine.clearDemoData();

      // 内容侧:两条路径清出来的是同一个空库
      expect(wsAll.engine.todos().length).assertEqual(wsDemo.engine.todos().length);
      expect(wsAll.engine.projects().length).assertEqual(wsDemo.engine.projects().length);
      expect(wsAll.engine.areas().length).assertEqual(wsDemo.engine.areas().length);
      expect(wsAll.engine.tags().length).assertEqual(wsDemo.engine.tags().length);
      // 标记侧:清空本地数据 = 全新安装态(没标记);清除演示数据 = 有标记(不再播种)
      expect(await wsAll.store.getKv(KvKeys.SEEDED)).assertEqual(null);
      expect(await wsDemo.store.getKv(KvKeys.SEEDED)).assertEqual(SEEDED_MARK_VALUE);
      done();
    });

    it('clear_demo_data_can_still_be_restored_explicitly', 0, async (done: Function) => {
      const ws: Workspace = await seededWorkspace();
      await ws.engine.clearDemoData();

      // 自动播种这条路已经关上…
      expect(await applySeedPolicy(ws.store, ws.engine, buildSeedState(todayISO()))).assertFalse();
      expect(aliveTodos(ws.engine)).assertEqual(0);

      // …但设置页「恢复默认示例数据」这条**显式**路径必须还有效,否则用户再也找不回示例数据
      await applyResetToSeedData(ws.store, ws.engine, buildSeedState(todayISO()));
      expect(aliveTodos(ws.engine) > 0).assertTrue();
      expect(await ws.store.getKv(KvKeys.SEEDED)).assertEqual(SEEDED_MARK_VALUE);
      done();
    });

    it('should_seed_judgement_table', 0, () => {
      // 没标记 + 库空 → 播种
      expect(shouldSeedDemoData(null, 0, 0)).assertTrue();
      // 没标记 + 库里有东西 → 不播种(只补标记)
      expect(shouldSeedDemoData(null, 1, 0)).assertFalse();
      expect(shouldSeedDemoData(null, 0, 1)).assertFalse();
      expect(shouldSeedDemoData(null, 3, 2)).assertFalse();
      // 标记在 → 一律不播种,哪怕库是空的
      expect(shouldSeedDemoData(SEEDED_MARK_VALUE, 0, 0)).assertFalse();
      expect(shouldSeedDemoData(SEEDED_MARK_VALUE, 5, 2)).assertFalse();
      // 标记值不是 '1'(被外部清掉/老版本写入)→ 视为没有标记
      expect(shouldSeedDemoData('', 0, 0)).assertTrue();
    });
  });
}
