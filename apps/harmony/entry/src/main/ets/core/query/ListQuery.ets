/**
 * Ordo · 派生清单查询
 * 契约来源:docs/03-数据模型与同步协议.md §4(派生清单查询规范,四端必须逐条一致)
 *
 * 原则:所有清单都是**查询**,不落库。E = deleted != true 的实体全集;open(t) = t.status == 'open'。
 * 每个契约条目对应本文件一个函数,函数名与清单一一对应,便于逐条核对与测试。
 */

import { ChecklistItem, Heading, Project, Status, Todo } from '../model/Entities.ets';
import { datePartOf, daysBetween, todayISO } from '../util/DateUtil.ets';
import { firstOccurrenceOnOrAfter, repeatBaseDate } from '../repeat/RepeatEngine.ets';

/** 契约 §4:可见实体(deleted != true) */
export function isVisible(t: Todo): boolean {
  return !t.deleted;
}

/** 契约 §4:open(t) */
export function isOpen(t: Todo): boolean {
  return t.status === 'open' && !t.deleted;
}

/** 契约 §4:已完成/已取消(日志簿) */
export function isLogbook(t: Todo): boolean {
  return (t.status === 'done' || t.status === 'canceled') && !t.deleted;
}

/* ------------------------------------------------------------ 收件箱 Inbox */

/** 契约 §4:收件箱 = open(t) && when == "inbox" */
export function inbox(todos: Todo[]): Todo[] {
  const out: Todo[] = [];
  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (isOpen(t) && t.when === 'inbox') {
      out.push(t);
    }
  }
  return sortByOrder(out);
}

/* -------------------------------------------------------------- 今天 Today */

/**
 * 契约 §4:今天 = open(t) && (when ∈ {today, evening}
 *   || (when == "date" && date <= today)
 *   || (deadline != null && deadline <= today))
 */
export function isInToday(t: Todo, today: string): boolean {
  if (!isOpen(t)) {
    return false;
  }
  if (t.when === 'today' || t.when === 'evening') {
    return true;
  }
  if (t.when === 'date' && t.date !== null && t.date <= today) {
    return true;
  }
  if (t.deadline !== null && t.deadline <= today) {
    return true;
  }
  return false;
}

export function today(todos: Todo[], todayISOValue: string): Todo[] {
  const out: Todo[] = [];
  for (let i = 0; i < todos.length; i++) {
    if (isInToday(todos[i], todayISOValue)) {
      out.push(todos[i]);
    }
  }
  return sortForToday(out);
}

/**
 * 契约 §4:今晚分区 = 今天结果中 when == "evening" 的单独一组,置于底部。
 */
export function tonight(todos: Todo[], todayISOValue: string): Todo[] {
  const out: Todo[] = [];
  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (isOpen(t) && t.when === 'evening' && isInToday(t, todayISOValue)) {
      out.push(t);
    }
  }
  return sortByOrder(out);
}

/** 今天列表中「今晚」以外的部分 */
export function todayMain(todos: Todo[], todayISOValue: string): Todo[] {
  const all: Todo[] = today(todos, todayISOValue);
  const out: Todo[] = [];
  for (let i = 0; i < all.length; i++) {
    if (all[i].when !== 'evening') {
      out.push(all[i]);
    }
  }
  return out;
}

/** 契约 §4:逾期标记 = deadline != null && deadline < today */
export function isOverdue(t: Todo, todayISOValue: string): boolean {
  return t.deadline !== null && t.deadline < todayISOValue && isOpen(t);
}

/** 过期提醒(UI 用珊瑚红展示) */
export function isReminderPast(t: Todo, nowLocal: string): boolean {
  return t.reminder !== null && t.reminder < nowLocal && isOpen(t);
}

/* ---------------------------------------------------------- 计划 Upcoming */

/** 契约 §4:窗口 = 明天起 14 天 */
export const UPCOMING_WINDOW_DAYS: number = 14;

export interface DayGroup {
  /** "YYYY-MM-DD";溢出分组为空串 */
  date: string;
  /** 分组标题,如 "明天 · 周五" 或 "更晚" */
  label: string;
  todos: Todo[];
  /** true = 超出 14 天窗口的「更晚」分组 */
  overflow: boolean;
}

export interface UpcomingInput {
  todos: Todo[];
  today: string;
  /** 窗口内每一天的日期(由调用方传入,便于测试固定) */
  windowDays: string[];
}

/** 窗口起点(明天)与终点(含) */
export function upcomingWindow(todayISOValue: string): string[] {
  const days: string[] = [];
  for (let i = 1; i <= UPCOMING_WINDOW_DAYS; i++) {
    days.push(addDaysISO(todayISOValue, i));
  }
  return days;
}

function addDaysISO(iso: string, n: number): string {
  // 显式按本地时区解析,避免 Date.parse 的时区差异
  const y: number = parseInt(iso.substring(0, 4), 10);
  const m: number = parseInt(iso.substring(5, 7), 10);
  const day: number = parseInt(iso.substring(8, 10), 10);
  const local: Date = new Date(y, m - 1, day);
  local.setDate(local.getDate() + n);
  const mm: string = (local.getMonth() + 1) < 10 ? '0' + (local.getMonth() + 1).toString() : (local.getMonth() + 1).toString();
  const dd: string = local.getDate() < 10 ? '0' + local.getDate().toString() : local.getDate().toString();
  return local.getFullYear().toString() + '-' + mm + '-' + dd;
}

/**
 * 契约 §4:计划清单包含三类来源
 *   1. when == "date" && date ∈ 窗口
 *   2. deadline ∈ 窗口
 *   3. repeat != null 的下一次发生日 ∈ 窗口
 * 按天分组,超出窗口归入「更晚」。
 * 同一条待办可能命中多个来源,只归入**最早**的那一天。
 */
export function upcoming(todos: Todo[], todayISOValue: string, windowDays: string[]): DayGroup[] {
  const windowEnd: string = windowDays.length > 0 ? windowDays[windowDays.length - 1] : todayISOValue;
  const bucket: Map<string, Todo[]> = new Map<string, Todo[]>();
  for (let i = 0; i < windowDays.length; i++) {
    bucket.set(windowDays[i], []);
  }
  bucket.set('', []); // 「更晚」

  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (!isOpen(t)) {
      continue;
    }
    const candidates: string[] = [];
    if (t.repeat !== null) {
      // 契约 §4 来源 3:重复待办只认「下一次发生日」。不能再把 t.date 也当候选——
      // 重复待办的 date 是**首次**发生日,通常早已过期,一旦作为候选参与"取最早",
      // 就会被判为"今天及更早"而整条待办被丢弃,或错误地分到过期那天。
      const nextDate: string = firstOccurrenceOnOrAfter(t.repeat, repeatBaseDate(t, todayISOValue), todayISOValue);
      candidates.push(nextDate);
    } else if (t.when === 'date' && t.date !== null) {
      candidates.push(t.date);
    }
    if (t.deadline !== null) {
      candidates.push(t.deadline);
    }
    if (candidates.length === 0) {
      continue;
    }
    let earliest: string = candidates[0];
    for (let c = 1; c < candidates.length; c++) {
      if (candidates[c] < earliest) {
        earliest = candidates[c];
      }
    }
    if (earliest <= todayISOValue) {
      // 今天及更早的归「今天」清单,不进「计划」
      continue;
    }
    if (earliest <= windowEnd) {
      const list: Todo[] = bucket.get(earliest) as Todo[];
      list.push(t);
    } else {
      const late: Todo[] = bucket.get('') as Todo[];
      late.push(t);
    }
  }

  const groups: DayGroup[] = [];
  for (let i = 0; i < windowDays.length; i++) {
    const d: string = windowDays[i];
    const list: Todo[] = bucket.get(d) as Todo[];
    if (list.length > 0) {
      const g: DayGroup = { date: d, label: d, todos: sortByOrder(list), overflow: false };
      groups.push(g);
    }
  }
  const overflowList: Todo[] = bucket.get('') as Todo[];
  if (overflowList.length > 0) {
    const g: DayGroup = { date: '', label: '更晚', todos: sortByOrder(overflowList), overflow: true };
    groups.push(g);
  }
  return groups;
}

/* ---------------------------------------------------------- 随时 / 某天 */

/** 契约 §4:随时 = open(t) && when == "anytime" */
export function anytime(todos: Todo[]): Todo[] {
  const out: Todo[] = [];
  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (isOpen(t) && t.when === 'anytime') {
      out.push(t);
    }
  }
  return sortByOrder(out);
}

/** 契约 §4:某天 = open(t) && when == "someday" */
export function someday(todos: Todo[]): Todo[] {
  const out: Todo[] = [];
  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (isOpen(t) && t.when === 'someday') {
      out.push(t);
    }
  }
  return sortByOrder(out);
}

/* -------------------------------------------------------------- 日志簿 */

export interface LogbookGroup {
  /** "YYYY-MM-DD" */
  date: string;
  label: string;
  todos: Todo[];
}

/**
 * 契约 §4:日志簿 = status ∈ {done, canceled},按 completedAt 的日期**倒序**分组。
 */
export function logbook(todos: Todo[]): LogbookGroup[] {
  const map: Map<string, Todo[]> = new Map<string, Todo[]>();
  const dates: string[] = [];
  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (!isLogbook(t)) {
      continue;
    }
    const ms: number = t.completedAt !== null ? t.completedAt : t.updatedAt;
    const d: Date = new Date(ms);
    const key: string = d.getFullYear().toString() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
    if (!map.has(key)) {
      map.set(key, []);
      dates.push(key);
    }
    (map.get(key) as Todo[]).push(t);
  }
  dates.sort((a: string, b: string): number  => {
    return a < b ? 1 : (a > b ? -1 : 0); // 倒序
  });
  const groups: LogbookGroup[] = [];
  for (let i = 0; i < dates.length; i++) {
    const key: string = dates[i];
    const list: Todo[] = map.get(key) as Todo[];
    list.sort((a: Todo, b: Todo): number  => {
      const am: number = a.completedAt !== null ? a.completedAt : a.updatedAt;
      const bm: number = b.completedAt !== null ? b.completedAt : b.updatedAt;
      return bm - am;
    });
    const g: LogbookGroup = { date: key, label: key, todos: list };
    groups.push(g);
  }
  return groups;
}

function pad2(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString();
}

/* ------------------------------------------------------------ 项目 / 区域 */

export interface HeadingGroup {
  /** null 表示"无标题"分组,契约 §4 要求排在最后 */
  headingId: string | null;
  name: string;
  collapsed: boolean;
  todos: Todo[];
}

/**
 * 契约 §4:项目视图 = t.projectId == P.id && open(t),
 * 先按 heading.order 分组(headingId == null 的排在最后),组内按 t.order。
 * 已归档标题(archived=true)不展示其分组,但其待办仍归入"无标题"分组不丢失。
 */
export function projectGroups(todos: Todo[], headings: Heading[], projectId: string): HeadingGroup[] {
  const sorted: Heading[] = [];
  for (let i = 0; i < headings.length; i++) {
    if (headings[i].projectId === projectId && !headings[i].archived) {
      sorted.push(headings[i]);
    }
  }
  sorted.sort((a: Heading, b: Heading): number  => {
    return a.order - b.order;
  });

  const groups: HeadingGroup[] = [];
  for (let i = 0; i < sorted.length; i++) {
    const h: Heading = sorted[i];
    const g: HeadingGroup = { headingId: h.id, name: h.name, collapsed: h.collapsed, todos: [] };
    groups.push(g);
  }
  const loose: HeadingGroup = { headingId: null, name: '', collapsed: false, todos: [] };

  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (t.projectId !== projectId || !isOpen(t)) {
      continue;
    }
    let placed: boolean = false;
    if (t.headingId !== null) {
      for (let g = 0; g < groups.length; g++) {
        if (groups[g].headingId === t.headingId) {
          groups[g].todos.push(t);
          placed = true;
          break;
        }
      }
    }
    if (!placed) {
      loose.todos.push(t);
    }
  }
  for (let g = 0; g < groups.length; g++) {
    groups[g].todos = sortByOrder(groups[g].todos);
  }
  if (loose.todos.length > 0) {
    loose.todos = sortByOrder(loose.todos);
    groups.push(loose); // 无标题分组永远排最后
  }
  return groups;
}

/** 契约 §4:区域视图 = t.areaId == A.id || project.areaId == A.id */
export function areaTodos(todos: Todo[], projects: Project[], areaId: string): Todo[] {
  const projectIds: string[] = [];
  for (let i = 0; i < projects.length; i++) {
    if (projects[i].areaId === areaId && !projects[i].deleted) {
      projectIds.push(projects[i].id);
    }
  }
  const out: Todo[] = [];
  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (!isOpen(t)) {
      continue;
    }
    if (t.areaId === areaId) {
      out.push(t);
      continue;
    }
    if (t.projectId !== null && projectIds.indexOf(t.projectId) >= 0) {
      out.push(t);
    }
  }
  return sortByOrder(out);
}

/* -------------------------------------------------------------- 标签 / 搜索 */

/** 契约 §4:标签视图 = t.tags.contains(name),可切换"只看未完成" */
export function tagTodos(todos: Todo[], tagName: string, onlyOpen: boolean): Todo[] {
  const out: Todo[] = [];
  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (t.deleted) {
      continue;
    }
    if (t.tags.indexOf(tagName) < 0) {
      continue;
    }
    if (onlyOpen && t.status !== 'open') {
      continue;
    }
    out.push(t);
  }
  return sortForSearch(out);
}

/**
 * 契约 §4:搜索 = 标题或备注包含关键词(大小写不敏感);
 * 排序:未完成优先 → updatedAt 倒序。
 */
export function search(todos: Todo[], keyword: string): Todo[] {
  const key: string = keyword.trim().toLowerCase();
  if (key.length === 0) {
    return [];
  }
  const out: Todo[] = [];
  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (t.deleted) {
      continue;
    }
    const inTitle: boolean = t.title.toLowerCase().indexOf(key) >= 0;
    const inNote: boolean = t.note.toLowerCase().indexOf(key) >= 0;
    if (inTitle || inNote) {
      out.push(t);
    }
  }
  return sortForSearch(out);
}

/* ---------------------------------------------------------------- 进度与统计 */

/** 契约 §4:项目进度 = done / (done + open);无子项时 0 */
export function projectProgress(todos: Todo[], projectId: string): number {
  let done: number = 0;
  let open: number = 0;
  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (t.projectId !== projectId || t.deleted) {
      continue;
    }
    if (t.status === 'done' || t.status === 'canceled') {
      done++;
    } else if (t.status === 'open') {
      open++;
    }
  }
  const total: number = done + open;
  if (total === 0) {
    return 0;
  }
  return done / total;
}

/** 项目未完成计数(侧栏项目行右侧数字) */
export function projectOpenCount(todos: Todo[], projectId: string): number {
  let open: number = 0;
  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (t.projectId === projectId && isOpen(t)) {
      open++;
    }
  }
  return open;
}

/**
 * 契约 §2.2 项目完成规则(v1.1 修订)的唯一硬约束:
 * 项目下所有 todo 的 status ∈ {done, canceled}。
 *
 * Heading 是**组织容器**而非工作项,`heading.archived == true` 不再是完成条件
 * (旧规则会导致"界面显示 0 项未完成却被拒绝完成");完成项目时由引擎自动归档
 * 未归档标题,见 `OrdoEngine.completeProject`。
 *
 * `headings` 参数保留只为兼容既有调用点,不参与判定。
 */
export function canCompleteProject(todos: Todo[], headings: Heading[], projectId: string): boolean {
  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (t.projectId !== projectId || t.deleted) {
      continue;
    }
    if (t.status === 'open') {
      return false;
    }
  }
  return true;
}

/** 侧栏固定清单计数(契约 §4 + 04 号文档 §3 布局) */
export interface SidebarCounts {
  inbox: number;
  today: number;
  upcoming: number;
  anytime: number;
  someday: number;
  logbook: number;
}

export function sidebarCounts(todos: Todo[], todayISOValue: string, windowDays: string[]): SidebarCounts {
  const counts: SidebarCounts = {
    inbox: inbox(todos).length,
    today: today(todos, todayISOValue).length,
    upcoming: 0,
    anytime: anytime(todos).length,
    someday: someday(todos).length,
    logbook: logbook(todos).length
  };
  const groups: DayGroup[] = upcoming(todos, todayISOValue, windowDays);
  let up: number = 0;
  for (let i = 0; i < groups.length; i++) {
    up += groups[i].todos.length;
  }
  counts.upcoming = up;
  return counts;
}

/** 标签计数(按未完成计) */
export function tagCounts(todos: Todo[]): Map<string, number> {
  const map: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < todos.length; i++) {
    const t: Todo = todos[i];
    if (!isOpen(t)) {
      continue;
    }
    for (let k = 0; k < t.tags.length; k++) {
      const name: string = t.tags[k];
      const cur: number = map.has(name) ? (map.get(name) as number) : 0;
      map.set(name, cur + 1);
    }
  }
  return map;
}

/* ---------------------------------------------------------------- 排序工具 */

/** 组内按 order 升序(相同则按创建时间) */
export function sortByOrder(list: Todo[]): Todo[] {
  const copy: Todo[] = list.slice(0);
  copy.sort((a: Todo, b: Todo): number  => {
    if (a.order !== b.order) {
      return a.order - b.order;
    }
    return a.createdAt - b.createdAt;
  });
  return copy;
}

/** 今天列表排序:逾期最前 → 有提醒的按时刻 → 其余按 order */
export function sortForToday(list: Todo[]): Todo[] {
  const copy: Todo[] = list.slice(0);
  copy.sort((a: Todo, b: Todo): number  => {
    const aOver: number = a.deadline !== null && a.deadline < todayISO() ? 0 : 1;
    const bOver: number = b.deadline !== null && b.deadline < todayISO() ? 0 : 1;
    if (aOver !== bOver) {
      return aOver - bOver;
    }
    if (a.reminder !== null && b.reminder !== null && a.reminder !== b.reminder) {
      return a.reminder < b.reminder ? -1 : 1;
    }
    return a.order - b.order;
  });
  return copy;
}

/** 搜索排序:未完成优先 → updatedAt 倒序 */
export function sortForSearch(list: Todo[]): Todo[] {
  const copy: Todo[] = list.slice(0);
  copy.sort((a: Todo, b: Todo): number  => {
    const aOpen: number = a.status === 'open' ? 0 : 1;
    const bOpen: number = b.status === 'open' ? 0 : 1;
    if (aOpen !== bOpen) {
      return aOpen - bOpen;
    }
    return b.updatedAt - a.updatedAt;
  });
  return copy;
}

/** 状态中文文案 */
export function statusText(s: Status): string {
  if (s === 'done') {
    return '已完成';
  }
  if (s === 'canceled') {
    return '已取消';
  }
  return '未完成';
}

/** 清单项进度文案 "2/5" */
export function checklistProgress(list: ChecklistItem[]): string {
  if (list.length === 0) {
    return '';
  }
  let done: number = 0;
  for (let i = 0; i < list.length; i++) {
    if (list[i].done) {
      done++;
    }
  }
  return done.toString() + '/' + list.length.toString();
}

/** 提醒日期与 when/date 是否一致(契约 §3 不变量校验,供引擎与测试使用) */
export function reminderAlignsWithWhen(t: Todo, todayISOValue: string): boolean {
  if (t.reminder === null) {
    return true;
  }
  const expect: string = t.when === 'date' && t.date !== null ? t.date : todayISOValue;
  return datePartOf(t.reminder) === expect;
}

/** 距离窗口起点的天数(调试/分组用) */
export function daysFromToday(iso: string, todayISOValue: string): number {
  return daysBetween(todayISOValue, iso);
}
