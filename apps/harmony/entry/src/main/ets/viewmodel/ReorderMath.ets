/**
 * Ordo · 拖拽排序的**纯计算**(04-UI规范 §6「拖拽排序 = 长按拖拽」)
 *
 * 与另外三端保持同一套语义:
 *  - 共享核心 `OrdoEngine.reorderTodos(ids)`(shared/core/.../OrdoEngine.kt:293):`ids[i]` 的 order = i;
 *  - iOS `AppEnvironment.reorderTodos(ids:)` + `ListScreenView.movedOrder`:先移除自身再插入;
 *  - 桌上端 `ReorderMath.kt`:`moveWithin(ids, draggedId, insertIndex)`。
 *
 * 本文件不依赖 ArkUI、不碰引擎,输入 id 序列与落点,输出"是否受理 / 新的 id 序列",
 * 因此可以直接被 `_qa/row-perf-harness.mjs`(Node 类型擦除)执行,而不只是"看起来对"。
 */

import { ListKind, Todo } from '../core/model/Entities.ets';

/**
 * `order` 的作用域容器键(与 `OrdoEngine.nextOrder` 的分组口径一致,也与 iOS
 * `AppEnvironment.containerKey(for:)` 对齐):同一容器的 order 才是连续可比的。
 */
export function containerKeyOf(t: Todo): string {
  return t.when + '|' +
    (t.projectId === null ? '-' : t.projectId) + '|' +
    (t.headingId === null ? '-' : t.headingId);
}

/**
 * 哪些清单开放拖拽:只有 **order 真正参与排序** 的清单才开放。
 *  - 今天(`sortForToday` 的末位比较键)、收件箱/随时/某天(`sortByOrder`)、
 *    项目(标题组内 `sortByOrder`)、区域(`sortByOrder`)→ 开放;
 *  - 计划(按日期分组)、日志簿(按 completedAt 倒序)、标签/搜索(跨容器聚合)→ 关闭,
 *    拖了也白拖,反而会写出与排序规则竞争的 order。
 */
export function listSupportsReorder(list: ListKind): boolean {
  return list === 'today' || list === 'inbox' || list === 'anytime' ||
    list === 'someday' || list === 'project' || list === 'area';
}

/** 一组同容器待办是否可以拖:至少 2 条,且容器唯一 */
export function sectionCanReorder(containers: string[]): boolean {
  if (containers.length < 2) {
    return false;
  }
  const first: string = containers[0];
  for (let i = 1; i < containers.length; i++) {
    if (containers[i] !== first) {
      return false;
    }
  }
  return true;
}

/**
 * 把 `sourceId` 放到 `targetId` 这一行的位置上,方向决定落点在目标行前还是后:
 *  - 向下拖(源在目标之上)→ 落在目标行**之后**(否则"往下拖一行"会变成空操作);
 *  - 向上拖(源在目标之下)→ 落在目标行**之前**。
 *
 * 落点公式与 iOS `ListScreenView.movedOrder` 同形(先移除自身,再以"移除后"的数组为基准插入)。
 *
 * 现状(04 §5.4 长按拖拽落地后):`ListPage` 的手势路径改为按**落点下标**提交
 * (`PressGesture.moveIdToIndex`,由位移换算半行取整),本函数保留为"按目标行提交"这一等价入口,
 * 供 `ReorderMath.test` 与后续需要"拖到某一行"语义的场景使用。
 *
 * @returns 新的完整序列;不需要变更(同一条、找不到、或结果与原序列相同)时返回 null
 */
export function movedOrder(ids: string[], sourceId: string, targetId: string): string[] | null {
  const from: number = ids.indexOf(sourceId);
  const target: number = ids.indexOf(targetId);
  if (from < 0 || target < 0 || from === target) {
    return null;
  }
  const next: string[] = ids.slice(0);
  next.splice(from, 1);
  const clamped: number = target < 0 ? 0 : (target > next.length ? next.length : target);
  next.splice(clamped, 0, sourceId);
  let same: boolean = next.length === ids.length;
  if (same) {
    for (let i = 0; i < next.length; i++) {
      if (next[i] !== ids[i]) {
        same = false;
        break;
      }
    }
  }
  return same ? null : next;
}

/**
 * 交叉检查:一次拖拽提交的序列必须是**同一容器内**的完整可见序列。
 * 视图层在提交给 `OrdoEngine.reorderTodos(ids)` 之前调用,跨容器直接拒绝(04 §6)。
 */
export function sameContainer(containerKeys: string[]): boolean {
  if (containerKeys.length === 0) {
    return false;
  }
  const first: string = containerKeys[0];
  for (let i = 1; i < containerKeys.length; i++) {
    if (containerKeys[i] !== first) {
      return false;
    }
  }
  return true;
}
