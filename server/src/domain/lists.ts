/**
 * 派生清单查询规范 —— 契约 §4(四端必须逐条一致;清单全部是查询,不落库)。
 * 服务端实现用于一致性校验、快照调试与四端参考。
 */
import { Area, Heading, Project, Tag, Todo } from './model';
import { nextOccurrenceDate } from './repeat';
import { addDaysISO, compareDate } from './time';

export interface EntitySet {
  areas: Area[];
  projects: Project[];
  headings: Heading[];
  todos: Todo[];
  tags: Tag[];
}

export const notDeleted = <T>(e: T): boolean => (e as { deleted?: boolean }).deleted !== true;
export const isOpen = (t: Todo): boolean => t.status === 'open';
export const byOrder = (a: { order: number }, b: { order: number }): number => a.order - b.order;

export function visibleTodos(s: EntitySet): Todo[] {
  return s.todos.filter(notDeleted);
}

/** 收件箱:`open(t) && t.when == "inbox"` */
export function listInbox(s: EntitySet): Todo[] {
  return visibleTodos(s)
    .filter((t) => isOpen(t) && t.when === 'inbox')
    .sort(byOrder);
}

/** 今天:`open(t) && (when ∈ {today,evening} || (when=="date" && date <= today) || (deadline <= today))` */
export function listToday(s: EntitySet, today: string): { items: Todo[]; evening: Todo[]; overdue: Todo[] } {
  const items = visibleTodos(s)
    .filter((t) => {
      if (!isOpen(t)) return false;
      if (t.when === 'today' || t.when === 'evening') return true;
      if (t.when === 'date' && t.date !== null && t.date <= today) return true;
      if (t.deadline !== null && t.deadline <= today) return true;
      return false;
    })
    .sort(byOrder);

  const evening = items.filter((t) => t.when === 'evening');
  const overdue = items.filter((t) => t.deadline !== null && t.deadline < today);
  const main = items.filter((t) => t.when !== 'evening');
  return { items: main, evening, overdue };
}

export interface UpcomingGroup {
  date: string;
  todos: Todo[];
}

/**
 * 计划:窗口 = 明天起 14 天。
 * 含 when=="date" 且 date ∈ 窗口、deadline ∈ 窗口、repeat 的下一次发生日 ∈ 窗口;超出窗口归入「更晚」。
 */
export function listUpcoming(
  s: EntitySet,
  today: string,
  windowDays = 14
): { start: string; end: string; groups: UpcomingGroup[]; later: Todo[] } {
  const start = addDaysISO(today, 1);
  const end = addDaysISO(today, windowDays);
  const buckets = new Map<string, Todo[]>();
  for (let i = 1; i <= windowDays; i += 1) buckets.set(addDaysISO(today, i), []);
  const later: Todo[] = [];

  for (const t of visibleTodos(s)) {
    if (!isOpen(t)) continue;
    const dates = new Set<string>();
    if (t.when === 'date' && t.date) dates.add(t.date);
    if (t.deadline) dates.add(t.deadline);
    if (t.repeat) {
      const next = nextOccurrenceDate(t, today);
      if (next) dates.add(next);
    }
    if (dates.size === 0) continue;

    const sorted = [...dates].sort(compareDate);
    const inWindow = sorted.filter((d) => d >= start && d <= end);
    if (inWindow.length > 0) {
      for (const d of inWindow) buckets.get(d)?.push(t);
    } else if (sorted[0] > end) {
      later.push(t);
    }
  }

  const groups: UpcomingGroup[] = [];
  for (const [date, todos] of buckets.entries()) {
    if (todos.length > 0) groups.push({ date, todos: todos.sort(byOrder) });
  }
  return { start, end, groups, later: later.sort(byOrder) };
}

/** 随时:`open(t) && when == "anytime"` */
export function listAnytime(s: EntitySet): Todo[] {
  return visibleTodos(s)
    .filter((t) => isOpen(t) && t.when === 'anytime')
    .sort(byOrder);
}

/** 某天:`open(t) && when == "someday"` */
export function listSomeday(s: EntitySet): Todo[] {
  return visibleTodos(s)
    .filter((t) => isOpen(t) && t.when === 'someday')
    .sort(byOrder);
}

/** 日志簿:`status ∈ {done,canceled}`,按 completedAt 的日期倒序分组 */
export function listLogbook(s: EntitySet): { date: string; todos: Todo[] }[] {
  const map = new Map<string, Todo[]>();
  for (const t of visibleTodos(s)) {
    if (t.status !== 'done' && t.status !== 'canceled') continue;
    const key = t.completedAt != null ? new Date(t.completedAt).toISOString().slice(0, 10) : '未知';
    const arr = map.get(key) ?? [];
    arr.push(t);
    map.set(key, arr);
  }
  return [...map.entries()]
    .sort((a, b) => (a[0] < b[0] ? 1 : a[0] > b[0] ? -1 : 0))
    .map(([date, todos]) => ({ date, todos: todos.sort((a, b) => (b.completedAt ?? 0) - (a.completedAt ?? 0)) }));
}

/** 项目视图:先按 heading.order 分组(headingId == null 排最后),组内按 t.order */
export function projectView(s: EntitySet, projectId: string): { heading: Heading | null; todos: Todo[] }[] {
  const headings = s.headings.filter((h) => notDeleted(h) && h.projectId === projectId).sort(byOrder);
  const todos = visibleTodos(s).filter((t) => t.projectId === projectId && isOpen(t));
  const groups: { heading: Heading | null; todos: Todo[] }[] = headings.map((h) => ({
    heading: h,
    todos: todos.filter((t) => t.headingId === h.id).sort(byOrder)
  }));
  const known = new Set(headings.map((h) => h.id));
  groups.push({ heading: null, todos: todos.filter((t) => !t.headingId || !known.has(t.headingId)).sort(byOrder) });
  return groups;
}

/** 区域视图:`t.areaId == A.id || project.areaId == A.id` */
export function areaView(s: EntitySet, areaId: string): { projects: Project[]; todos: Todo[]; looseTodos: Todo[] } {
  const projects = s.projects.filter((p) => notDeleted(p) && p.areaId === areaId);
  const projectIds = new Set(projects.map((p) => p.id));
  const todos = visibleTodos(s).filter(
    (t) => isOpen(t) && (t.areaId === areaId || (t.projectId !== null && projectIds.has(t.projectId)))
  );
  return {
    projects,
    todos,
    looseTodos: todos.filter((t) => t.projectId === null).sort(byOrder)
  };
}

/** 标签视图:`t.tags.contains(name)`,可切换"只看未完成" */
export function tagView(s: EntitySet, name: string, onlyOpen = true): Todo[] {
  return visibleTodos(s)
    .filter((t) => t.tags.includes(name) && (onlyOpen ? isOpen(t) : true))
    .sort(byOrder);
}

/** 搜索:标题或备注包含关键词(大小写不敏感);未完成优先 → updatedAt 倒序 */
export function searchTodos(s: EntitySet, keyword: string): Todo[] {
  const q = keyword.trim().toLowerCase();
  if (!q) return [];
  return visibleTodos(s)
    .filter((t) => t.title.toLowerCase().includes(q) || t.note.toLowerCase().includes(q))
    .sort((a, b) => {
      const ao = isOpen(a) ? 0 : 1;
      const bo = isOpen(b) ? 0 : 1;
      if (ao !== bo) return ao - bo;
      return (b.updatedAt ?? 0) - (a.updatedAt ?? 0);
    });
}

/** 项目进度:done / (done + open);无子项时 0 */
export function projectProgress(s: EntitySet, projectId: string): number {
  const children = visibleTodos(s).filter((t) => t.projectId === projectId);
  const done = children.filter((t) => t.status === 'done').length;
  const open = children.filter((t) => t.status === 'open').length;
  if (done + open === 0) return 0;
  return done / (done + open);
}

export function buildEntitySet(
  areas: Area[],
  projects: Project[],
  headings: Heading[],
  todos: Todo[],
  tags: Tag[]
): EntitySet {
  return { areas, projects, headings, todos, tags };
}
