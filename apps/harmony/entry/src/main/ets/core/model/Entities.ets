/**
 * Ordo · 鸿蒙端核心数据模型
 * 契约来源:docs/03-数据模型与同步协议.md §2(规范数据模型)、§3(默认值与不变量)、§7.2(Op 结构)
 *
 * 本文件是鸿蒙端唯一的实体定义处:字段名、类型、可空性必须与契约 §2 逐字一致。
 * 约束:纯 ArkTS,不依赖任何 UI 与系统能力,可被 ohosTest 直接引入。
 */

/** 契约 §2 · When 取值 */
export type When = 'inbox' | 'today' | 'evening' | 'anytime' | 'someday' | 'date';
/** 契约 §2 · Status 取值 */
export type Status = 'open' | 'done' | 'canceled';
/** 契约 §2 · 重复频率 */
export type RepeatFreq = 'daily' | 'weekly' | 'monthly' | 'yearly';
/** 契约 §2 · 重复模式 */
export type RepeatMode = 'fixed' | 'afterCompletion';
/** 契约 §7.2 · 可同步实体种类 */
export type EntityKind = 'todo' | 'project' | 'area' | 'heading' | 'tag';
/** 契约 §7.2 · 操作类型 */
export type OpType = 'upsert' | 'delete';
/** 派生清单种类(契约 §4) */
export type ListKind =
  | 'inbox' | 'today' | 'upcoming' | 'anytime' | 'someday' | 'logbook'
  | 'project' | 'area' | 'tag' | 'search';

/** 契约版本号,写入 kv.schemaVersion 与请求头 X-Ordo-Schema(契约 §7.4、§8) */
export const SCHEMA_VERSION: number = 1;

/** 全部合法 When 值(用于校验与迁移) */
export const WHEN_VALUES: When[] = ['inbox', 'today', 'evening', 'anytime', 'someday', 'date'];
/** 全部合法 Status 值 */
export const STATUS_VALUES: Status[] = ['open', 'done', 'canceled'];
/** 契约 §7.4:单次 push ≤ 500 ops、单 op payload ≤ 256 KB、pull limit ≤ 1000 */
export const MAX_PUSH_OPS: number = 500;
export const MAX_PAYLOAD_BYTES: number = 262144;
export const MAX_PULL_LIMIT: number = 1000;
/** 契约 §7.3.5:墓碑保留 30 天 */
export const TOMBSTONE_TTL_MS: number = 30 * 24 * 60 * 60 * 1000;

/* ------------------------------------------------------------------ §2.5 */

/** 契约 §2.5 ChecklistItem(内嵌,不单独同步) */
export interface ChecklistItem {
  id: string;
  title: string;
  done: boolean;
}

/* ------------------------------------------------------------------ §2.7 */

/** 契约 §2.7 RepeatRule */
export interface RepeatRule {
  freq: RepeatFreq;
  interval: number;
  mode: RepeatMode;
}

/* ------------------------------------------------------------------ §2.1 */

/** 契约 §2.1 Area */
export interface Area {
  id: string;
  name: string;
  color: string;
  order: number;
  archived: boolean;
  updatedAt: number;
  deleted: boolean;
}

/* ------------------------------------------------------------------ §2.3 */

/**
 * 契约 §2.3 Heading。
 * 注意:契约 §2.3 未定义 `deleted` 字段,而 §3 要求"删除一律软删除"。
 * 处理方式(见 README「契约歧义处理」):Heading 的删除 = 从宿主项目 headings 数组移除,
 * 并在本地 tombstones 表登记墓碑;同步时仍按 §7.2 发送 entity="heading" 且 type="delete" 的 Op。
 * `collapsed` 是设备本地 UI 状态,不参与同步(推送前置 null,服务端忽略)。
 */
export interface Heading {
  id: string;
  projectId: string;
  name: string;
  order: number;
  archived: boolean;
  collapsed: boolean;
  updatedAt: number;
}

/* ------------------------------------------------------------------ §2.2 */

/** 契约 §2.2 Project(项目完成规则见 §2.2 硬约束,由 OrdoEngine.canCompleteProject 保证) */
export interface Project {
  id: string;
  areaId: string | null;
  name: string;
  note: string;
  when: When;
  date: string | null;
  deadline: string | null;
  tags: string[];
  headings: Heading[];
  order: number;
  status: Status;
  completedAt: number | null;
  repeat: RepeatRule | null;
  createdAt: number;
  updatedAt: number;
  deleted: boolean;
}

/* ------------------------------------------------------------------ §2.4 */

/** 契约 §2.4 Todo */
export interface Todo {
  id: string;
  title: string;
  note: string;
  when: When;
  date: string | null;
  reminder: string | null;
  deadline: string | null;
  tags: string[];
  checklist: ChecklistItem[];
  projectId: string | null;
  areaId: string | null;
  headingId: string | null;
  repeat: RepeatRule | null;
  order: number;
  status: Status;
  createdAt: number;
  updatedAt: number;
  completedAt: number | null;
  deleted: boolean;
}

/* ------------------------------------------------------------------ §2.6 */

/**
 * 契约 §2.6 Tag。与 Heading 同理:契约未给 `deleted`,删除 = 从 tags 数组移除 + 本地墓碑。
 */
export interface Tag {
  id: string;
  name: string;
  color: string;
  updatedAt: number;
}

/* ------------------------------------------------------------------ §2.8 */

/** 契约 §2.8 CalendarEvent(只读、设备本地、不同步) */
export interface CalendarEvent {
  id: string;
  title: string;
  start: number;
  end: number;
  calendar: string;
  allDay: boolean;
}

/* ------------------------------------------------------------- §7.2 / §7.3 */

/** 契约 §7.2 Op */
export interface Op {
  opId: string;
  deviceId: string;
  entity: EntityKind;
  entityId: string;
  type: OpType;
  payload: string | null; // 实体完整快照的 JSON 文本;delete 时为 null
  clientTs: number;
  seq: number | null; // 仅服务端下发时有;上传时省略
}

/** 契约 §7.3.5 墓碑 */
export interface Tombstone {
  entity: EntityKind;
  entityId: string;
  deletedAt: number;
  clientTs: number;
}

/* ------------------------------------------------------------- 汇总与传输 */

/** 契约 §7.4 GET /v1/sync/snapshot 响应体 */
export interface Snapshot {
  serverSeq: number;
  areas: Area[];
  projects: Project[];
  headings: Heading[];
  todos: Todo[];
  tags: Tag[];
}

/** 本地聚合状态:headings 规范存放于 Project.headings,由 allHeadings() 投影为顶层数组 */
export interface OrdoState {
  areas: Area[];
  projects: Project[];
  todos: Todo[];
  tags: Tag[];
  events: CalendarEvent[];
}

/* ------------------------------------------------------------------ 克隆 */

/**
 * ArkTS 不支持对象展开语法({...obj}),因此所有复制都走显式字段拷贝。
 * 这些函数是同步合并(§7.3)与重复引擎(§6)的基础。
 */
export function cloneRepeatRule(r: RepeatRule | null): RepeatRule | null {
  if (r === null) {
    return null;
  }
  const out: RepeatRule = { freq: r.freq, interval: r.interval, mode: r.mode };
  return out;
}

export function cloneChecklistItem(c: ChecklistItem): ChecklistItem {
  const out: ChecklistItem = { id: c.id, title: c.title, done: c.done };
  return out;
}

export function cloneChecklist(list: ChecklistItem[]): ChecklistItem[] {
  const out: ChecklistItem[] = [];
  for (let i = 0; i < list.length; i++) {
    out.push(cloneChecklistItem(list[i]));
  }
  return out;
}

export function cloneStringArray(list: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < list.length; i++) {
    out.push(list[i]);
  }
  return out;
}

export function cloneHeading(h: Heading): Heading {
  const out: Heading = {
    id: h.id,
    projectId: h.projectId,
    name: h.name,
    order: h.order,
    archived: h.archived,
    collapsed: h.collapsed,
    updatedAt: h.updatedAt
  };
  return out;
}

export function cloneArea(a: Area): Area {
  const out: Area = {
    id: a.id,
    name: a.name,
    color: a.color,
    order: a.order,
    archived: a.archived,
    updatedAt: a.updatedAt,
    deleted: a.deleted
  };
  return out;
}

export function cloneTag(t: Tag): Tag {
  const out: Tag = { id: t.id, name: t.name, color: t.color, updatedAt: t.updatedAt };
  return out;
}

export function cloneTodo(t: Todo): Todo {
  const out: Todo = {
    id: t.id,
    title: t.title,
    note: t.note,
    when: t.when,
    date: t.date,
    reminder: t.reminder,
    deadline: t.deadline,
    tags: cloneStringArray(t.tags),
    checklist: cloneChecklist(t.checklist),
    projectId: t.projectId,
    areaId: t.areaId,
    headingId: t.headingId,
    repeat: cloneRepeatRule(t.repeat),
    order: t.order,
    status: t.status,
    createdAt: t.createdAt,
    updatedAt: t.updatedAt,
    completedAt: t.completedAt,
    deleted: t.deleted
  };
  return out;
}

export function cloneProject(p: Project): Project {
  const headings: Heading[] = [];
  for (let i = 0; i < p.headings.length; i++) {
    headings.push(cloneHeading(p.headings[i]));
  }
  const out: Project = {
    id: p.id,
    areaId: p.areaId,
    name: p.name,
    note: p.note,
    when: p.when,
    date: p.date,
    deadline: p.deadline,
    tags: cloneStringArray(p.tags),
    headings: headings,
    order: p.order,
    status: p.status,
    completedAt: p.completedAt,
    repeat: cloneRepeatRule(p.repeat),
    createdAt: p.createdAt,
    updatedAt: p.updatedAt,
    deleted: p.deleted
  };
  return out;
}

export function cloneEvent(e: CalendarEvent): CalendarEvent {
  const out: CalendarEvent = {
    id: e.id,
    title: e.title,
    start: e.start,
    end: e.end,
    calendar: e.calendar,
    allDay: e.allDay
  };
  return out;
}

/* ------------------------------------------------------------- 默认构造器 */

/** 契约 §3:新建待办未指定 when 且未指定 projectId → when="inbox" */
export function newTodo(id: string, title: string, now: number): Todo {
  const t: Todo = {
    id: id,
    title: title,
    note: '',
    when: 'inbox',
    date: null,
    reminder: null,
    deadline: null,
    tags: [],
    checklist: [],
    projectId: null,
    areaId: null,
    headingId: null,
    repeat: null,
    order: 0,
    status: 'open',
    createdAt: now,
    updatedAt: now,
    completedAt: null,
    deleted: false
  };
  return t;
}

export function newProject(id: string, name: string, areaId: string | null, now: number): Project {
  const p: Project = {
    id: id,
    areaId: areaId,
    name: name,
    note: '',
    when: 'anytime',
    date: null,
    deadline: null,
    tags: [],
    headings: [],
    order: 0,
    status: 'open',
    completedAt: null,
    repeat: null,
    createdAt: now,
    updatedAt: now,
    deleted: false
  };
  return p;
}

export function newArea(id: string, name: string, color: string, order: number, now: number): Area {
  const a: Area = {
    id: id,
    name: name,
    color: color,
    order: order,
    archived: false,
    updatedAt: now,
    deleted: false
  };
  return a;
}

export function newTag(id: string, name: string, color: string, now: number): Tag {
  const t: Tag = { id: id, name: name, color: color, updatedAt: now };
  return t;
}

export function newHeading(id: string, projectId: string, name: string, order: number, now: number): Heading {
  const h: Heading = {
    id: id,
    projectId: projectId,
    name: name,
    order: order,
    archived: false,
    collapsed: false,
    updatedAt: now
  };
  return h;
}

export function newTombstone(entity: EntityKind, entityId: string, now: number): Tombstone {
  const t: Tombstone = { entity: entity, entityId: entityId, deletedAt: now, clientTs: now };
  return t;
}
