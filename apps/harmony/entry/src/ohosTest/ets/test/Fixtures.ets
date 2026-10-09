/**
 * Ordo · 测试夹具
 * 用**显式字段合并**代替 Object.assign / 对象展开,规避 ArkTS 的强类型限制,
 * 同时保证构造出的实体满足契约 §2 的全部字段。
 */

import {
  ChecklistItem,
  Heading,
  RepeatFreq,
  RepeatMode,
  RepeatRule,
  Status,
  Todo,
  When
} from '../../../main/ets/core/model/Entities.ets';

/** 待办的可选覆盖字段(与契约 §2.4 一一对应) */
export interface TodoOverrides {
  title?: string;
  note?: string;
  date?: string;
  reminder?: string;
  deadline?: string;
  tags?: string[];
  checklist?: ChecklistItem[];
  projectId?: string;
  areaId?: string;
  headingId?: string;
  repeat?: RepeatRule;
  order?: number;
  status?: Status;
  createdAt?: number;
  updatedAt?: number;
  completedAt?: number;
  deleted?: boolean;
}

/** 构造契约 §2.4 的完整待办 */
export function makeTodo(id: string, title: string, when: When, o?: TodoOverrides): Todo {
  const t: Todo = {
    id: id,
    title: title,
    note: '',
    when: when,
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
    createdAt: 1000,
    updatedAt: 1000,
    completedAt: null,
    deleted: false
  };
  if (o === undefined) {
    return t;
  }
  if (o.title !== undefined) {
    t.title = o.title;
  }
  if (o.note !== undefined) {
    t.note = o.note;
  }
  if (o.date !== undefined) {
    t.date = o.date;
  }
  if (o.reminder !== undefined) {
    t.reminder = o.reminder;
  }
  if (o.deadline !== undefined) {
    t.deadline = o.deadline;
  }
  if (o.tags !== undefined) {
    t.tags = o.tags;
  }
  if (o.checklist !== undefined) {
    t.checklist = o.checklist;
  }
  if (o.projectId !== undefined) {
    t.projectId = o.projectId;
  }
  if (o.areaId !== undefined) {
    t.areaId = o.areaId;
  }
  if (o.headingId !== undefined) {
    t.headingId = o.headingId;
  }
  if (o.repeat !== undefined) {
    t.repeat = o.repeat;
  }
  if (o.order !== undefined) {
    t.order = o.order;
  }
  if (o.status !== undefined) {
    t.status = o.status;
  }
  if (o.createdAt !== undefined) {
    t.createdAt = o.createdAt;
  }
  if (o.updatedAt !== undefined) {
    t.updatedAt = o.updatedAt;
  }
  if (o.completedAt !== undefined) {
    t.completedAt = o.completedAt;
  }
  if (o.deleted !== undefined) {
    t.deleted = o.deleted;
  }
  return t;
}

/** 构造契约 §2.3 的标题 */
export function makeHeading(id: string, projectId: string, name: string, order: number): Heading {
  const h: Heading = {
    id: id,
    projectId: projectId,
    name: name,
    order: order,
    archived: false,
    collapsed: false,
    updatedAt: 1000
  };
  return h;
}

/** 构造契约 §2.7 的重复规则 */
export function makeRule(freq: RepeatFreq, interval: number, mode: RepeatMode): RepeatRule {
  const r: RepeatRule = { freq: freq, interval: interval, mode: mode };
  return r;
}
