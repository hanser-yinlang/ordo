/**
 * Ordo · 列表行模型 + 行级差量(04-UI规范 §3 布局骨架 / §4 待办行规格)
 *
 * 为什么要「行模型」这一层:
 *  改前 `ListPage` 把 `todaySections()/currentTodos()/…` 直接喂给 `ForEach`,外层是 `Scroll + Column`:
 *    · `ForEach` 不是懒加载——首帧就把 1000 行全部建成组件树,之后每次状态变化仍要**遍历全部 N 项求键值**
 *      才能判断哪些项需要重建(ArkUI 文档:ForEach 非首次渲染时逐项比较键值);
 *    · 行与分组标题是同一个 `@Component` 的 build 产物,没有"某一行变了"这一粒度,只能整棵子树重算。
 *  改后由本文件把「数据 → 行序列」算清楚,并给出**只有受影响区间才发的**差量指令(`RowEdit[]`),
 *  由 `RowDataSource` 翻译成 `notifyDataReload/notifyDataAdd/notifyDataDelete/notifyDataMove`,
 *  再交给 `List + LazyForEach`(只创建可见区 + cachedCount 内的组件)。
 *
 * 键值口径(依据 ArkUI 官方文档 *LazyForEach:数据懒加载* 的约束):
 *  · "LazyForEach depends on the generated key to determine whether to re-render the child component.
 *     If the key does not change, LazyForEach cannot trigger a re-render for the corresponding child component."
 *    → 行键必须把**内容指纹**算进去:`key = <身份 id>@<指纹 rev>`。
 *      内容变了 → 键变了 → `notifyDataReload()` 只重建这一行(同键的其它行复用缓存组件);
 *      内容没变 → 键没变 → 一行都不重建。
 *  · "If the first parameter dataSource is re-assigned a value, an exception occurs."
 *    → 数据源实例在整个生命周期内保持不变,切换清单由 `RowDataSource.sync()` 内部换行序列。
 *
 * 本文件不依赖 ArkUI,可被 Node(类型擦除)直接执行——`_qa/row-perf-harness.mjs` 就是这么量出
 * 「1000 条待办下每次变化重建多少行」的,数字不是估算。
 */

import { CalendarEvent, ListKind, Todo } from '../../core/model/Entities.ets';
import { DayGroup, HeadingGroup, LogbookGroup } from '../../core/query/ListQuery.ets';
import { millisToHM, fmtDayLabel } from '../../core/util/DateUtil.ets';
import { containerKeyOf, listSupportsReorder, sectionCanReorder } from '../../viewmodel/ReorderMath.ets';

/* ------------------------------------------------------------ 行类型 */

/**
 * 行种类:
 *  - agendaTitle / agendaEvent:今天清单顶部的「日程」区块(设备本地日历,只读)
 *  - group:分组标题(今天 / 今晚 / 日期 / 「更晚」/ 日志簿日期)
 *  - heading:项目视图的标题分组行(可折叠 + 归档)
 *  - todo:待办行(可滑、可拖)
 *  - empty:空状态
 */
export type RowKind = 'agendaTitle' | 'agendaEvent' | 'group' | 'heading' | 'todo' | 'empty';

/** 一行在列表里的全部渲染输入(不放 UI 对象,只放纯数据,便于比对与测试) */
export interface ListRow {
  kind: RowKind;
  /** 行的稳定身份(与内容无关;拖拽/插入/删除都靠它配对) */
  id: string;
  /** 行内容版本号:该行渲染依赖字段的 32 位折叠 */
  rev: number;
  /** LazyForEach 的键值 = `id@rev`:内容变则键变,ArkUI 才会重建这一行 */
  key: string;
  todoId: string;
  /** 拖拽容器(order 的作用域) */
  container: string;
  /** 该行当前是否允许拖拽排序 */
  dragEnabled: boolean;
  /** 正被拖动(04 §5.4:scale 1.02 + 12dp 投影 + 背景 surface + alpha 0.55) */
  lifted: boolean;
  /** 拖拽期这一行的纵向让位量(vp;正数向下)。0 = 不动 */
  shift: number;
  /** 插入指示线的位置:'none' | 'top' | 'bottom'(2dp accent + 左端 4dp 圆点) */
  dropLine: string;
  /** 分组标题文案 / 标题分组的名字 */
  label: string;
  /** 分组计数 */
  count: number;
  /** 分组标题色调:'secondary' | 'tonight' */
  tone: string;
  headingId: string;
  collapsed: boolean;
  /** 空状态 */
  emptyTitle: string;
  emptySubtitle: string;
  emptyAction: string;
  /** 空状态主按钮去向:'inbox' | 'anytime' | 'quickadd' | '' */
  emptyTarget: string;
  /** 日程行 */
  timeText: string;
  calendarText: string;
}

/**
 * 拖拽期给行序列的提示(04 §5.4)。由 ListPage 的手势状态机产出,
 * 在 buildRows 末端折进行指纹 —— 因为 `LazyForEach` 只在**键变化**时才重建子组件,
 * 光靠父组件重渲染传 @Prop 是刷不动已有行的(见本文件开头的键值口径说明)。
 */
export interface DragHint {
  /** 正在被拖的待办 id(空串 = 没有拖拽) */
  draggedId: string;
  /** 被拖行相对按下点的纵向位移(vp) */
  dy: number;
  /** 同一容器内的落点下标 */
  toIndex: number;
  /** 行的纵向跨度(vp):让位量的步长 */
  extent: number;
}

/** 组装行序列所需的输入(全部来自 AppStore 的派生缓存,不额外遍历实体) */
export interface RowInput {
  /** 清单键(`list|projectId|areaId|tagName|keyword|showCompleted`) */
  key: string;
  list: ListKind;
  today: string;
  selectedTodoId: string;
  animatingTodoId: string;
  events: CalendarEvent[];
  /** 今天清单的两段 */
  main: Todo[];
  tonight: Todo[];
  upcoming: DayGroup[];
  headings: HeadingGroup[];
  logbook: LogbookGroup[];
  /** 其余清单(收件箱/随时/某天/区域/标签/搜索)的扁平序列 */
  todos: Todo[];
  /** 拖拽期提示(04 §5.4);不拖拽时省略,行指纹不受影响 */
  drag?: DragHint;
}

/* ------------------------------------------------------------ 行指纹 */

/** 32 位字符串折叠(FNV 变体),用于把"这一行渲染依赖的字段"压成一次整数比较 */
export function fold(h: number, s: string): number {
  let x: number = h;
  for (let i = 0; i < s.length; i++) {
    x = (x * 31 + s.charCodeAt(i)) | 0;
  }
  return x;
}

export function foldNum(h: number, n: number): number {
  return (h * 31 + (n | 0)) | 0;
}

/**
 * 待办行的内容指纹:覆盖该行**渲染出来的全部字段**(标题/备注/状态/标签/提醒/截止/清单进度/
 * 重复/完成时间/选中态/完成动效态/是否逾期)。
 *
 * 刻意折叠"渲染依赖"而不是 `updatedAt`:后者会在拖拽排序这类**不影响显示**的写入里变化,
 * 用它当指纹会把无谓的行重建也放进来。未纳入的只有"提醒过期"这种随时间流动的配色(依赖 now),
 * 它会在下一次任何变化时同步——与改前"每次重渲染都重算"的观感一致,但不制造每秒一次的整表刷新。
 */
export function todoRowRev(t: Todo, selected: boolean, animating: boolean, today: string): number {
  let h: number = 17;
  h = fold(h, t.title);
  h = fold(h, t.note);
  h = foldNum(h, t.status === 'done' ? 1 : (t.status === 'canceled' ? 2 : 0));
  h = foldNum(h, t.tags.length);
  for (let i = 0; i < t.tags.length; i++) {
    h = fold(h, t.tags[i]);
  }
  h = fold(h, t.reminder === null ? '' : t.reminder);
  h = fold(h, t.deadline === null ? '' : t.deadline);
  h = foldNum(h, t.checklist.length);
  let done: number = 0;
  for (let i = 0; i < t.checklist.length; i++) {
    if (t.checklist[i].done) {
      done = done + 1;
    }
  }
  h = foldNum(h, done);
  h = foldNum(h, t.repeat === null ? 0 : 1);
  if (t.repeat !== null) {
    h = fold(h, t.repeat.freq);
    h = foldNum(h, t.repeat.interval);
    h = fold(h, t.repeat.mode);
  }
  h = foldNum(h, t.completedAt === null ? 0 : 1);
  h = foldNum(h, t.completedAt === null ? 0 : t.completedAt);
  h = foldNum(h, selected ? 1 : 0);
  h = foldNum(h, animating ? 1 : 0);
  h = fold(h, today);
  return h;
}

/* ------------------------------------------------------------ 行构造 */

function blankRow(kind: RowKind, id: string, rev: number): ListRow {
  const row: ListRow = {
    kind: kind,
    id: id,
    rev: rev,
    key: id + '@' + rev.toString(),
    todoId: '',
    container: '',
    dragEnabled: false,
    lifted: false,
    shift: 0,
    dropLine: 'none',
    label: '',
    count: 0,
    tone: 'secondary',
    headingId: '',
    collapsed: false,
    emptyTitle: '',
    emptySubtitle: '',
    emptyAction: '',
    emptyTarget: '',
    timeText: '',
    calendarText: ''
  };
  return row;
}

function todoRow(input: RowInput, t: Todo): ListRow {
  const row: ListRow = blankRow('todo', 't:' + t.id, 0);
  row.todoId = t.id;
  row.container = containerKeyOf(t);
  row.rev = todoRowRev(t, input.selectedTodoId === t.id, input.animatingTodoId === t.id, input.today);
  row.key = row.id + '@' + row.rev.toString();
  return row;
}

function groupRow(id: string, label: string, count: number, tone: string): ListRow {
  let rev: number = 7;
  rev = fold(rev, label);
  rev = foldNum(rev, count);
  rev = fold(rev, tone);
  const row: ListRow = blankRow('group', id, rev);
  row.label = label;
  row.count = count;
  row.tone = tone;
  return row;
}

function headingRow(g: HeadingGroup): ListRow {
  let rev: number = 11;
  rev = fold(rev, g.name);
  rev = foldNum(rev, g.collapsed ? 1 : 0);
  rev = foldNum(rev, g.todos.length);
  const id: string = g.headingId === null ? 'h:loose' : ('h:' + (g.headingId as string));
  const row: ListRow = blankRow('heading', id, rev);
  row.headingId = g.headingId === null ? '' : (g.headingId as string);
  row.label = g.name;
  row.collapsed = g.collapsed;
  row.count = g.todos.length;
  return row;
}

function emptyRow(title: string, subtitle: string, action: string, target: string): ListRow {
  let rev: number = 13;
  rev = fold(rev, title);
  rev = fold(rev, subtitle);
  rev = fold(rev, action);
  const row: ListRow = blankRow('empty', 'empty', rev);
  row.emptyTitle = title;
  row.emptySubtitle = subtitle;
  row.emptyAction = action;
  row.emptyTarget = target;
  return row;
}

function agendaTitleRow(count: number): ListRow {
  return blankRow('agendaTitle', 'agendaTitle', foldNum(19, count));
}

function agendaEventRow(ev: CalendarEvent): ListRow {
  let rev: number = 23;
  rev = foldNum(rev, ev.start);
  rev = fold(rev, ev.title);
  rev = fold(rev, ev.calendar);
  const row: ListRow = blankRow('agendaEvent', 'e:' + ev.id, rev);
  row.label = ev.title;
  row.calendarText = ev.calendar;
  row.timeText = millisToHM(ev.start);
  return row;
}

/* ------------------------------------------------------------ 行序列 */

/** 数据 → 行序列。顺序与改前 `ListPage` 各 `content()` 的渲染顺序逐行等价。 */
export function buildRows(input: RowInput): ListRow[] {
  const rows: ListRow[] = [];
  if (input.list === 'today') {
    if (input.events.length > 0) {
      rows.push(agendaTitleRow(input.events.length));
      for (let i = 0; i < input.events.length; i++) {
        rows.push(agendaEventRow(input.events[i]));
      }
    }
    rows.push(groupRow('g:today', '今天', input.main.length, 'secondary'));
    if (input.main.length === 0) {
      rows.push(emptyRow('今天还没有安排', '从收件箱挑几件今天想做的事,或直接按右下角的快加号', '去收件箱看看', 'inbox'));
    } else {
      for (let i = 0; i < input.main.length; i++) {
        rows.push(todoRow(input, input.main[i]));
      }
    }
    if (input.tonight.length > 0) {
      // 今晚分区:琥珀色分组标题(04 §2.1 accent.tonight)
      rows.push(groupRow('g:tonight', '今晚', input.tonight.length, 'tonight'));
      for (let i = 0; i < input.tonight.length; i++) {
        rows.push(todoRow(input, input.tonight[i]));
      }
    }
  } else if (input.list === 'upcoming') {
    if (input.upcoming.length === 0) {
      rows.push(emptyRow('未来两周没有安排', '给待办设一个开始日期,它就会出现在这里', '查看随时', 'anytime'));
    } else {
      for (let g = 0; g < input.upcoming.length; g++) {
        const day: DayGroup = input.upcoming[g];
        const id: string = day.date.length > 0 ? ('g:day:' + day.date) : 'g:day:later';
        rows.push(groupRow(id, day.label.length > 0 ? day.label : '更晚', day.todos.length, 'secondary'));
        for (let i = 0; i < day.todos.length; i++) {
          rows.push(todoRow(input, day.todos[i]));
        }
      }
    }
  } else if (input.list === 'project') {
    if (input.headings.length === 0) {
      rows.push(emptyRow('这个项目还没有待办', '按右下角的快加号开始记录第一步', '新建待办', 'quickadd'));
    } else {
      for (let g = 0; g < input.headings.length; g++) {
        const hg: HeadingGroup = input.headings[g];
        if (hg.headingId !== null) {
          rows.push(headingRow(hg));
        }
        if (!hg.collapsed) {
          for (let i = 0; i < hg.todos.length; i++) {
            rows.push(todoRow(input, hg.todos[i]));
          }
        }
      }
    }
  } else if (input.list === 'logbook') {
    if (input.logbook.length === 0) {
      rows.push(emptyRow('日志簿还是空的', '完成的待办会按日期归档到这里', '', ''));
    } else {
      for (let g = 0; g < input.logbook.length; g++) {
        const lg: LogbookGroup = input.logbook[g];
        // 日志簿分组标题按改前的 `fmtDayLabel(g.date)` 渲染
        rows.push(groupRow('g:lb:' + lg.date, fmtDayLabel(lg.date), lg.todos.length, 'secondary'));
        for (let i = 0; i < lg.todos.length; i++) {
          rows.push(todoRow(input, lg.todos[i]));
        }
      }
    }
  } else {
    if (input.todos.length === 0) {
      rows.push(emptyRow(emptyTitleOf(input.list), emptySubtitleOf(input.list), '新建待办', 'quickadd'));
    } else {
      for (let i = 0; i < input.todos.length; i++) {
        rows.push(todoRow(input, input.todos[i]));
      }
    }
  }
  markDragEnabled(rows, listSupportsReorder(input.list));
  const hint: DragHint | undefined = input.drag;
  if (hint !== undefined && hint.draggedId.length > 0) {
    applyDragHint(rows, hint);
  }
  ensureUniqueIds(rows);
  return rows;
}

/**
 * 把拖拽提示折进受影响的行(04 §5.4):
 *  - 被拖行:lifted = true,shift = dy(跟手);
 *  - 起点与落点之间的行:整体让位一个行跨度(动画 120ms);
 *  - 落点行:显示插入指示线。
 *
 * `LazyForEach` 只在键变化时重建子组件,所以这些字段必须**折进行指纹**,
 * 否则拖拽过程中界面不会动(行不会跟手、其它行也不会让位)。
 */
function applyDragHint(rows: ListRow[], hint: DragHint): void {
  let draggedIndex: number = -1;
  let container: string = '';
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].kind === 'todo' && rows[i].todoId === hint.draggedId) {
      draggedIndex = i;
      container = rows[i].container;
      break;
    }
  }
  if (draggedIndex < 0) {
    return;
  }
  // 同一容器内的可见序列(与 ListPage.containerIds() 同一口径:顺序即屏幕顺序)
  const seq: number[] = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].kind === 'todo' && rows[i].container === container) {
      seq.push(i);
    }
  }
  let from: number = -1;
  for (let k = 0; k < seq.length; k++) {
    if (seq[k] === draggedIndex) {
      from = k;
      break;
    }
  }
  if (from < 0) {
    return;
  }
  let to: number = hint.toIndex;
  if (to < 0) {
    to = 0;
  }
  if (to > seq.length - 1) {
    to = seq.length - 1;
  }
  const extent: number = hint.extent <= 0 ? 1 : hint.extent;
  for (let k = 0; k < seq.length; k++) {
    const row: ListRow = rows[seq[k]];
    let shift: number = 0;
    if (k === from) {
      row.lifted = true;
      shift = hint.dy;
    } else if (from < to && k > from && k <= to) {
      shift = -extent;
    } else if (to < from && k >= to && k < from) {
      shift = extent;
    }
    row.shift = shift;
    if (k === to && to !== from) {
      row.dropLine = to > from ? 'bottom' : 'top';
    }
    row.rev = foldNum(row.rev, Math.round(shift));
    row.rev = foldNum(row.rev, row.lifted ? 1 : 0);
    row.rev = fold(row.rev, row.dropLine);
    row.key = row.id + '@' + row.rev.toString();
  }
}

function emptyTitleOf(list: ListKind): string {
  if (list === 'inbox') {
    return '收件箱是空的';
  }
  if (list === 'someday') {
    return '某天里还没有事';
  }
  if (list === 'tag') {
    return '这个标签下没有待办';
  }
  if (list === 'search') {
    return '没有匹配的待办';
  }
  return '这里还没有待办';
}

function emptySubtitleOf(list: ListKind): string {
  if (list === 'inbox') {
    return '想到什么就先记下来,之后再决定什么时候做';
  }
  if (list === 'someday') {
    return '把"以后再说"的事放这里,定期回来看看';
  }
  return '按右下角的快加号新建一条';
}

/**
 * 只有「连续的一段待办行」构成的分区**整体同容器**且 ≥2 条时,这些行才允许拖拽。
 * 与 iOS `ListScreenView.canReorder` 的判据一致:混合容器的分区拖了会写出互相竞争的 order。
 * `dragEnabled` 参与行指纹,因此开关状态变化本身也会让这些行的键变化(各重建一次)。
 */
function markDragEnabled(rows: ListRow[], allowed: boolean): void {
  let start: number = 0;
  while (start < rows.length) {
    if (rows[start].kind !== 'todo') {
      start = start + 1;
      continue;
    }
    const containers: string[] = [];
    let end: number = start;
    while (end < rows.length && rows[end].kind === 'todo') {
      containers.push(rows[end].container);
      end = end + 1;
    }
    const ok: boolean = allowed && sectionCanReorder(containers);
    for (let i = start; i < end; i++) {
      rows[i].dragEnabled = ok;
      rows[i].rev = foldNum(rows[i].rev, ok ? 1 : 0);
      rows[i].key = rows[i].id + '@' + rows[i].rev.toString();
    }
    start = end;
  }
}

/** LazyForEach 要求键值唯一;真出现重复身份(例如同一条待办被两个分区收纳)时按出现顺序加后缀 */
function ensureUniqueIds(rows: ListRow[]): void {
  const seen: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < rows.length; i++) {
    const id: string = rows[i].id;
    const n: number = seen.has(id) ? (seen.get(id) as number) : 0;
    if (n > 0) {
      rows[i].id = id + '#' + (n + 1).toString();
      rows[i].key = rows[i].id + '@' + rows[i].rev.toString();
    }
    seen.set(id, n + 1);
  }
}

/* ------------------------------------------------------------ 差量 */

export type RowOp = 'add' | 'delete' | 'move' | 'reload';

/** 一条给数据源的通知指令:index/to 都是**当前数组**下标(move 是交换语义,见下) */
export interface RowEdit {
  op: RowOp;
  index: number;
  to: number;
}

/** 超过这个交换次数就改用一次 reload(长距离拖拽兜底,避免一次拖拽发出成百上千条通知) */
export const MAX_SWAPS: number = 64;

function edit(op: RowOp, index: number, to: number): RowEdit {
  const e: RowEdit = { op: op, index: index, to: to };
  return e;
}

function reloadEdit(): RowEdit {
  return edit('reload', 0, 0);
}

function sameKeySequence(a: ListRow[], b: ListRow[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i].key !== b[i].key) {
      return false;
    }
  }
  return true;
}

function sameIdSequence(a: ListRow[], b: ListRow[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i].id !== b[i].id) {
      return false;
    }
  }
  return true;
}

function idMapOf(rows: ListRow[]): Map<string, number> {
  const map: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < rows.length; i++) {
    map.set(rows[i].id, i);
  }
  return map;
}

/**
 * 交换序列:把 `cur` 的身份顺序变成 `next` 的身份顺序。
 *
 * ArkUI 的 `onDataMove(from,to)` 是**交换**语义(官方文档 *Swapping Data* 示例里数组做的是
 * `a[from] ↔ a[to]`),所以这里用"逐位选择排序 + 相邻/远距交换"给出等价的交换序列:
 * 单行向下拖 1 格 = 1 次交换,拖 k 格 = k 次交换(k 超过 `MAX_SWAPS` 时调用方改用 reload)。
 */
export function swapPlan(cur: ListRow[], next: ListRow[]): RowEdit[] {
  const edits: RowEdit[] = [];
  const live: string[] = [];
  for (let i = 0; i < cur.length; i++) {
    live.push(cur[i].id);
  }
  for (let target = 0; target < next.length; target++) {
    const want: string = next[target].id;
    while (live[target] !== want) {
      const from: number = live.indexOf(want);
      if (from < 0) {
        break;
      }
      const tmp: string = live[target];
      live[target] = live[from];
      live[from] = tmp;
      edits.push(edit('move', target, from));
    }
  }
  return edits;
}

/**
 * 行级差量。分支口径(全部以 `id` 配身份、以 `rev` 判内容、以 `key = id@rev` 交给 ArkUI):
 *  1. 键序列完全相同 → 空:一行都不重建(典型:浮层开关、选中态之外的无关键作);
 *  2. 身份序列相同、只有指纹变 → `reload`:键变的那几行重建,同键的行复用缓存组件
 *     (典型:改标题、勾清单项、展开详情、分组计数变化);
 *  3. 纯增 / 纯删且存活行指纹未变 → `add`/`delete`:只创建/销毁受影响的那一行
 *     (典型:收件箱新建一条;含分组标题的清单会因计数变化落到第 2 支);
 *  4. 纯重排 → 交换序列(≤ `MAX_SWAPS`),否则 `reload`(典型:拖拽排序);
 *  5. 其余(增删混合、换清单)→ `reload`。
 */
export function diffRows(cur: ListRow[], next: ListRow[]): RowEdit[] {
  const edits: RowEdit[] = [];
  if (cur.length === 0 && next.length === 0) {
    return edits;
  }
  if (cur.length === 0) {
    edits.push(reloadEdit());
    return edits;
  }
  if (sameKeySequence(cur, next)) {
    return edits;
  }

  const oldIndex: Map<string, number> = idMapOf(cur);
  const newIndex: Map<string, number> = idMapOf(next);
  const oldRev: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < cur.length; i++) {
    oldRev.set(cur[i].id, cur[i].rev);
  }

  if (sameIdSequence(cur, next)) {
    // 第 2 支:身份全对得上,只有内容变了
    edits.push(reloadEdit());
    return edits;
  }

  let sameSet: boolean = oldIndex.size === newIndex.size;
  if (sameSet) {
    for (let i = 0; i < next.length; i++) {
      if (!oldIndex.has(next[i].id)) {
        sameSet = false;
        break;
      }
    }
  }

  let revChanged: boolean = false;
  for (let i = 0; i < next.length; i++) {
    if (oldRev.has(next[i].id) && (oldRev.get(next[i].id) as number) !== next[i].rev) {
      revChanged = true;
      break;
    }
  }

  if (sameSet) {
    if (revChanged) {
      edits.push(reloadEdit());
      return edits;
    }
    const swaps: RowEdit[] = swapPlan(cur, next);
    if (swaps.length <= MAX_SWAPS) {
      return swaps;
    }
    edits.push(reloadEdit());
    return edits;
  }

  const removed: number[] = [];
  const added: number[] = [];
  for (let i = 0; i < cur.length; i++) {
    if (!newIndex.has(cur[i].id)) {
      removed.push(i);
    }
  }
  for (let i = 0; i < next.length; i++) {
    if (!oldIndex.has(next[i].id)) {
      added.push(i);
    }
  }

  if (revChanged) {
    edits.push(reloadEdit());
    return edits;
  }
  if (removed.length > 0 && added.length > 0) {
    edits.push(reloadEdit());
    return edits;
  }
  if (removed.length > 0) {
    // 从大到小删,下标才不会互相顶掉
    for (let i = removed.length - 1; i >= 0; i--) {
      edits.push(edit('delete', removed[i], removed[i]));
    }
    return edits;
  }
  for (let i = 0; i < added.length; i++) {
    edits.push(edit('add', added[i], added[i]));
  }
  return edits;
}
