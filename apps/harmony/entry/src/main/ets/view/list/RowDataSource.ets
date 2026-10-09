/**
 * Ordo · LazyForEach 数据源(BasicDataSource 实现 IDataSource)
 *
 * 三条不可越过的框架约束(依据 ArkUI 官方文档 *LazyForEach:数据懒加载* 的 Constraints):
 *  1. "If the first parameter dataSource is re-assigned a value, an exception occurs."
 *     → 本实例在 `ListPage` 的整个生命周期内**只创建一次**,换清单由 `sync()` 在内部换行序列,
 *       绝不把新的 IDataSource 交给 LazyForEach。
 *  2. "LazyForEach depends on the generated key ... If the key does not change, LazyForEach cannot
 *     trigger a re-render for the corresponding child component."
 *     → 行键由 `RowModel` 算成 `id@rev`(内容变则键变),内容更新走 `onDataReloaded()`,
 *       ArkUI 只重建"键变了"的行,同键的行复用缓存组件。
 *  3. "Before onDataDelete is called, ensure that the corresponding data in dataSource has been deleted."
 *     → 每条通知都是**先改自己的数组、再通知**。
 *
 * 外加一个与框架无关的保险:`apply()` 结束前逐位比对键,任何记账偏差都退化为整表 reload,
 * 不允许出现"视图与行模型不一致"的状态。
 *
 * 清单键缓存:`snapshots` 保存每个清单最后一次的行序列(改前那种"整表重建"的替代物),
 * 因此 `sync()` 的返回值可以被自检脚本直接计数——"这次变化重建了多少行"是数出来的,不是估的。
 */

import { ListRow, RowEdit, diffRows } from './RowModel.ets';

export class RowDataSource implements IDataSource {
  /** 当前清单的行序列(视图读它) */
  private rows: ListRow[] = [];
  /** 按清单键缓存的行序列(`list|projectId|…`) */
  private snapshots: Map<string, ListRow[]> = new Map<string, ListRow[]>();
  /** 当前清单键 */
  private activeKey: string = '';
  private listeners: DataChangeListener[] = [];
  /** 累计通知条数(自检用;不改渲染行为) */
  private totalEdits: number = 0;

  /* ---------------------------------------------------------- IDataSource */

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): ListRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }

  /* ---------------------------------------------------------- 视图侧读取 */

  size(): number {
    return this.rows.length;
  }

  rowAt(index: number): ListRow {
    return this.rows[index];
  }

  /**
   * 当前行序列的引用(不复制)。视图侧用它算「同容器完整可见序列」再提交给核心排序——
   * 每次渲染复制一份 1000 行数组本身就是改前那种 O(n) 放大,这里刻意避免。
   */
  rowsRef(): ListRow[] {
    return this.rows;
  }

  /** 当前清单键 */
  key(): string {
    return this.activeKey;
  }

  /** 已缓存的清单键数量(自检用) */
  cachedKeyCount(): number {
    return this.snapshots.size;
  }

  /** 累计通知条数(自检用) */
  edits(): number {
    return this.totalEdits;
  }

  /** 某个清单缓存里的行数(自检用;没有缓存返回 -1) */
  cachedRowCount(key: string): number {
    return this.snapshots.has(key) ? (this.snapshots.get(key) as ListRow[]).length : -1;
  }

  /* ---------------------------------------------------------- 数据变更 */

  /**
   * 同步某个清单的行序列。换清单 = 整表 reload(键值不变的行仍会复用组件);
   * 同一个清单内的变化 = 逐条最小通知。
   *
   * @returns 实际发出的通知明细(空数组 = 数据没变,一行都不重建)
   */
  sync(key: string, next: ListRow[]): RowEdit[] {
    if (key !== this.activeKey) {
      this.snapshots.set(key, next);
      this.activeKey = key;
      this.rows = next;
      const switched: RowEdit[] = [{ op: 'reload', index: 0, to: 0 }];
      this.totalEdits = this.totalEdits + 1;
      this.notifyReload();
      return switched;
    }
    return this.apply(next);
  }

  /** 增量应用:按差量逐条通知(先改数组,再通知) */
  apply(next: ListRow[]): RowEdit[] {
    const edits: RowEdit[] = diffRows(this.rows, next);
    if (edits.length === 0) {
      return edits;
    }
    if (edits[0].op === 'reload') {
      this.rows = next;
      this.snapshots.set(this.activeKey, next);
      this.totalEdits = this.totalEdits + 1;
      this.notifyReload();
      return edits;
    }
    for (let i = 0; i < edits.length; i++) {
      const e: RowEdit = edits[i];
      if (e.op === 'delete') {
        this.rows.splice(e.index, 1);
        this.totalEdits = this.totalEdits + 1;
        this.notifyDelete(e.index);
      } else if (e.op === 'add') {
        this.rows.splice(e.index, 0, next[e.index]);
        this.totalEdits = this.totalEdits + 1;
        this.notifyAdd(e.index);
      } else if (e.op === 'move') {
        // ArkUI 的 onDataMove 是交换语义,本地数组必须跟着交换
        const tmp: ListRow = this.rows[e.index];
        this.rows[e.index] = this.rows[e.to];
        this.rows[e.to] = tmp;
        this.totalEdits = this.totalEdits + 1;
        this.notifyMove(e.index, e.to);
      }
    }
    this.snapshots.set(this.activeKey, next);
    if (!this.matches(next)) {
      // 兜底:任何下标记账偏差都不允许留下"视图与模型不一致"的状态,直接整表对齐
      this.rows = next;
      this.totalEdits = this.totalEdits + 1;
      this.notifyReload();
    }
    return edits;
  }

  /** 与目标序列逐位比对(键);兜底路径的判据 */
  private matches(next: ListRow[]): boolean {
    if (this.rows.length !== next.length) {
      return false;
    }
    for (let i = 0; i < next.length; i++) {
      const a: ListRow = this.rows[i];
      const b: ListRow = next[i];
      if (a === undefined || b === undefined || a.key !== b.key) {
        return false;
      }
    }
    return true;
  }

  /* ---------------------------------------------------------- 通知 */

  private notifyReload(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }

  private notifyAdd(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataAdd(index);
    }
  }

  private notifyDelete(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataDelete(index);
    }
  }

  private notifyMove(from: number, to: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataMove(from, to);
    }
  }
}
