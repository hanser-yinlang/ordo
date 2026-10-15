/**
 * Ordo · 启动播种策略(v1.5:纯本地,不联网)
 *
 * 背景(用户报过的 bug):设置页有两条**语义不同**的入口,必须严格区分,否则用户"自己逐条删空
 * 待办"之后会被演示数据复活(数据凭空长回来,像丢过一次删除):
 *  - 「恢复默认示例数据」= 立刻写入一份演示数据,播种标记保持/补上 → 见 AppStore.resetToSeedData
 *  - 「清空本地数据」    = 退回**全新安装态**(实体 + outbox + 墓碑 + 播种标记全清)→ 下次冷启动
 *    才重新播种,见 OrdoEngine.clearAll / AppStore.clearAllData
 *
 * 判据因此只有一条:**播种标记** kv `ordo.seeded`。
 *  - 标记在 → 无论库是空是满都不播种(用户逐条删空 = 他的选择,不许复活)
 *  - 标记不在且库为空 → 播种
 *  - 标记不在但库有数据(老版本升级 / 标记被外部清掉)→ 只补标记,绝不覆盖用户数据
 *
 * 本文件不依赖 ArkUI / @kit,可被宿主机直接执行(见 LocalDataReset.test.ets)。
 */

import { OrdoState } from '../core/model/Entities.ets';
import { OrdoEngine } from '../core/store/OrdoEngine.ets';
import { KvKeys, OrdoStore } from '../core/storage/OrdoStore.ets';

/** 播种标记的取值(契约 §7.6.3 的本地化版本) */
export const SEEDED_MARK_VALUE: string = '1';

/**
 * 纯判据:现在该不该把演示数据写进库?
 *
 * @param seedMark kv `ordo.seeded` 的当前值(null = 没写过)
 * @param todoCount 库里(内存快照里)的待办数
 * @param projectCount 库里(内存快照里)的项目数
 */
export function shouldSeedDemoData(seedMark: string | null, todoCount: number, projectCount: number): boolean {
  if (seedMark === SEEDED_MARK_VALUE) {
    return false;
  }
  return todoCount === 0 && projectCount === 0;
}

/**
 * 首次进入该工作区时的演示数据(契约 §7.6.3 的本地化版本):
 * v1.5 没有服务端可比对,判据就是"本地为空且没写过种子标记"。
 *
 * @param seed 调用方准备好的演示数据(`buildSeedState(todayISO())`)
 * @returns 是否真的写入了演示数据(便于用例断言与调用方决定要不要接管 localEvents)
 */
export async function applySeedPolicy(store: OrdoStore, engine: OrdoEngine, seed: OrdoState): Promise<boolean> {
  const mark: string | null = await store.getKv(KvKeys.SEEDED);
  if (mark === SEEDED_MARK_VALUE) {
    return false;
  }
  if (!shouldSeedDemoData(mark, engine.todos().length, engine.projects().length)) {
    // 库里有用户数据却没有标记(升级/标记被清):只补标记,绝不覆盖
    await store.setKv(KvKeys.SEEDED, SEEDED_MARK_VALUE);
    return false;
  }
  await engine.persistAll(seed);
  await store.setKv(KvKeys.SEEDED, SEEDED_MARK_VALUE);
  return true;
}

/**
 * 「恢复默认示例数据」:立刻写入演示数据,**并补回播种标记**
 * (对齐 Windows 端 `seedDemoData(force = true)` —— 它在成功路径上无条件 kvSet 播种标记)。
 *
 * 为什么非补标记不可:清空本地数据会连标记一起删掉(全新安装态)。若重置不补回标记,就会出现
 * "清空 → 点恢复示例数据 → 用户自己逐条删空 → 冷启动"这条路径上**标记仍是缺的**,下次启动
 * 演示数据复活 —— 正是用户报过的那类"删掉的东西自己长回来"。
 */
export async function applyResetToSeedData(store: OrdoStore, engine: OrdoEngine, seed: OrdoState): Promise<void> {
  await engine.persistAll(seed);
  await store.setKv(KvKeys.SEEDED, SEEDED_MARK_VALUE);
}
