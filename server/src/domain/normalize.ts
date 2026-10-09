/**
 * 字段默认值与不变量 —— 契约 §3。
 * 服务端在落库前对每个实体做一次规范化,保证四端看到的数据形态一致。
 */
import {
  Area,
  AnyEntity,
  EntityKind,
  Heading,
  Project,
  Tag,
  Todo,
  entityTitle
} from './model';
import { isLocalDateTimeString, todayISO } from './time';

export interface NormalizeContext {
  nowMs: number;
  tzOffsetMinutes: number;
  /** 原始 payload:用于区分「客户端未指定 when」与「显式传 when」 */
  raw?: Record<string, unknown>;
  /** 校验 headingId 是否属于 projectId 指定的项目(§3) */
  headingBelongsToProject?: (headingId: string, projectId: string | null) => boolean;
}

function hasWhenField(raw?: Record<string, unknown>): boolean {
  return !!raw && Object.prototype.hasOwnProperty.call(raw, 'when') && raw.when !== undefined && raw.when !== null;
}

function hasProjectField(raw?: Record<string, unknown>): boolean {
  if (!raw) return false;
  const v = raw.projectId;
  return Object.prototype.hasOwnProperty.call(raw, 'projectId') && v !== undefined && v !== null && v !== '';
}

/** reminder 的日期部分,例如 "2026-10-09T18:00" → "2026-10-09" */
export function reminderDatePart(reminder: string | null): string | null {
  return reminder && isLocalDateTimeString(reminder) ? reminder.slice(0, 10) : null;
}

/** §3:标题为空字符串的实体视为删除 */
export function isEffectivelyDeleted(kind: EntityKind, entity: AnyEntity): boolean {
  return entityTitle(kind, entity).trim() === '';
}

export function normalizeTodo(input: Todo, ctx: NormalizeContext): Todo {
  const t: Todo = { ...input, tags: [...input.tags], checklist: input.checklist.map((c) => ({ ...c })) };
  const today = todayISO(ctx.nowMs, ctx.tzOffsetMinutes);

  // 1) when 缺省推导:未指定 when 且未指定项目 → inbox;未指定 when 但指定了项目 → anytime
  if (!hasWhenField(ctx.raw)) {
    t.when = hasProjectField(ctx.raw) || t.projectId ? 'anytime' : 'inbox';
  }

  // 2) 移入项目时 when=="inbox" → "anytime"(否则会同时留在收件箱)
  if (t.projectId && t.when === 'inbox') t.when = 'anytime';

  // 3) 设置 reminder 且 when ∈ {inbox, anytime, someday} → 自动改为 today
  if (t.reminder && (t.when === 'inbox' || t.when === 'anytime' || t.when === 'someday')) {
    t.when = 'today';
  }

  // 4) date 与 when 的一致性
  if (t.when === 'date') {
    if (!t.date) t.date = today;
  } else {
    t.date = null;
  }

  // 5) reminder 的日期部分必须等于 (when == "date" ? date : 今天),不满足则自动对齐
  if (t.reminder) {
    const expected = t.when === 'date' && t.date ? t.date : today;
    const actual = reminderDatePart(t.reminder);
    if (actual !== expected) t.reminder = `${expected}T${t.reminder.slice(11, 16)}`;
  }

  // 6) headingId 必须属于 projectId 指向的项目,否则置 null
  if (t.headingId) {
    if (!t.projectId || (ctx.headingBelongsToProject && !ctx.headingBelongsToProject(t.headingId, t.projectId))) {
      t.headingId = null;
    }
  }

  // 7) 完成态与 completedAt 保持一致
  if (t.status === 'open') {
    t.completedAt = null;
  } else if (t.completedAt == null) {
    t.completedAt = ctx.nowMs;
  }

  // 8) 去重标签(保持首次出现顺序)
  t.tags = [...new Set(t.tags.map((x) => x.trim()).filter((x) => x !== ''))];
  return t;
}

export function normalizeProject(input: Project, ctx: NormalizeContext): Project {
  const today = todayISO(ctx.nowMs, ctx.tzOffsetMinutes);
  const p: Project = { ...input, tags: [...input.tags] };

  if (p.when === 'date') {
    if (!p.date) p.date = today;
  } else {
    p.date = null;
  }

  if (p.status === 'open') {
    p.completedAt = null;
  } else if (p.completedAt == null) {
    p.completedAt = ctx.nowMs;
  }

  p.tags = [...new Set(p.tags.map((x) => x.trim()).filter((x) => x !== ''))];
  return p;
}

/** §2.3:collapsed 是设备本地 UI 状态,不参与同步 —— 服务端一律存 false */
export function normalizeHeading(input: Heading): Heading {
  return { ...input, collapsed: false };
}

export function normalizeArea(input: Area): Area {
  return { ...input };
}

export function normalizeTag(input: Tag): Tag {
  return { ...input };
}

export function normalizeEntity<K extends EntityKind>(kind: K, entity: AnyEntity, ctx: NormalizeContext): AnyEntity {
  switch (kind) {
    case 'todo':
      return normalizeTodo(entity as Todo, ctx);
    case 'project':
      return normalizeProject(entity as Project, ctx);
    case 'heading':
      return normalizeHeading(entity as Heading);
    case 'area':
      return normalizeArea(entity as Area);
    case 'tag':
      return normalizeTag(entity as Tag);
    default:
      return entity;
  }
}

/**
 * §2.2 硬约束(v1.1,2026-10-09 修订):项目仅当所有 todo 已完成/取消才能标记完成。
 *
 * **heading 不再参与判定** —— 它是组织容器不是工作项。客户端完成项目时会在同一批里
 * 先发出 heading 归档 op、再发 project done op,由客户端保证"已完成项目不含未归档标题"这一不变量;
 * 服务端只守住"没有未完成待办"这条唯一硬约束。
 *
 * `headings` 形参保留以兼容既有调用点与测试,不再参与判定。
 */
export function canCompleteProject(
  projectStatus: string,
  childTodos: Pick<Todo, 'status'>[],
  headings: Pick<Heading, 'archived'>[]
): boolean {
  void headings;
  if (projectStatus !== 'done') return true;
  return childTodos.every((t) => t.status === 'done' || t.status === 'canceled');
}
