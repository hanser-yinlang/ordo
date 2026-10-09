/**
 * 规范数据模型 —— 契约 §2(字段名与四端逐字一致)。
 *
 * 约定:
 *  - 时间戳 = epoch millis(整数);日期 = "YYYY-MM-DD";日期时间 = "YYYY-MM-DDTHH:mm"。
 *  - 客户端上传的是**实体完整快照**;为容错,除 id/name/title 外的字段都给了契约默认值。
 *  - `updatedAt` 由服务端在落库时强制写成 op.clientTs(LWW 的唯一依据),见 services/sync.ts。
 */
import { z } from 'zod';

export const WhenSchema = z.enum(['inbox', 'today', 'evening', 'anytime', 'someday', 'date']);
export const StatusSchema = z.enum(['open', 'done', 'canceled']);
export const RepeatFreqSchema = z.enum(['daily', 'weekly', 'monthly', 'yearly']);
export const RepeatModeSchema = z.enum(['fixed', 'afterCompletion']);
export const EntityKindSchema = z.enum(['todo', 'project', 'area', 'heading', 'tag']);
export const OpTypeSchema = z.enum(['upsert', 'delete']);

export const IsoDateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, '必须是 YYYY-MM-DD');
export const LocalDateTimeSchema = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/, '必须是 YYYY-MM-DDTHH:mm');
export const EpochMillisSchema = z.number().int().nonnegative();

export const RepeatRuleSchema = z.object({
  freq: RepeatFreqSchema,
  interval: z.number().int().positive().default(1),
  mode: RepeatModeSchema.default('fixed')
});

export const ChecklistItemSchema = z.object({
  id: z.string().min(1),
  title: z.string().default(''),
  done: z.boolean().default(false)
});

/** §2.1 Area */
export const AreaSchema = z.object({
  id: z.string().min(1),
  name: z.string(),
  color: z.string().default('#5B5BD6'),
  order: z.number().int().default(0),
  archived: z.boolean().default(false),
  updatedAt: EpochMillisSchema.optional(),
  deleted: z.boolean().default(false)
});

/** §2.3 Heading(collapsed 为设备本地 UI 状态,不参与同步) */
export const HeadingSchema = z.object({
  id: z.string().min(1),
  projectId: z.string().min(1),
  name: z.string(),
  order: z.number().int().default(0),
  archived: z.boolean().default(false),
  collapsed: z.boolean().nullable().default(false),
  updatedAt: EpochMillisSchema.optional()
});

/**
 * §2.2 Project
 * 注意(契约 §2.2 实现说明):Heading 是**顶层实体**,不在 Project 里内嵌;
 * 项目的「标题列表」是按 `heading.projectId == project.id` 查询出的派生视图。
 */
export const ProjectSchema = z.object({
  id: z.string().min(1),
  areaId: z.string().nullable().default(null),
  name: z.string(),
  note: z.string().default(''),
  when: WhenSchema.default('anytime'),
  date: IsoDateSchema.nullable().default(null),
  deadline: IsoDateSchema.nullable().default(null),
  tags: z.array(z.string()).default([]),
  order: z.number().int().default(0),
  status: StatusSchema.default('open'),
  completedAt: EpochMillisSchema.nullable().default(null),
  repeat: RepeatRuleSchema.nullable().default(null),
  createdAt: EpochMillisSchema.optional(),
  updatedAt: EpochMillisSchema.optional(),
  deleted: z.boolean().default(false)
});

/** §2.4 Todo */
export const TodoSchema = z.object({
  id: z.string().min(1),
  title: z.string(),
  note: z.string().default(''),
  when: WhenSchema.default('inbox'),
  date: IsoDateSchema.nullable().default(null),
  reminder: LocalDateTimeSchema.nullable().default(null),
  deadline: IsoDateSchema.nullable().default(null),
  tags: z.array(z.string()).default([]),
  checklist: z.array(ChecklistItemSchema).default([]),
  projectId: z.string().nullable().default(null),
  areaId: z.string().nullable().default(null),
  headingId: z.string().nullable().default(null),
  repeat: RepeatRuleSchema.nullable().default(null),
  order: z.number().int().default(0),
  status: StatusSchema.default('open'),
  createdAt: EpochMillisSchema.optional(),
  updatedAt: EpochMillisSchema.optional(),
  completedAt: EpochMillisSchema.nullable().default(null),
  deleted: z.boolean().default(false)
});

/** §2.6 Tag */
export const TagSchema = z.object({
  id: z.string().min(1),
  name: z.string(),
  color: z.string().default('#8E8E93'),
  updatedAt: EpochMillisSchema.optional()
});

export interface EntityMap {
  todo: z.infer<typeof TodoSchema>;
  project: z.infer<typeof ProjectSchema>;
  area: z.infer<typeof AreaSchema>;
  heading: z.infer<typeof HeadingSchema>;
  tag: z.infer<typeof TagSchema>;
}

export type EntityKind = keyof EntityMap;
export type Todo = EntityMap['todo'];
export type Project = EntityMap['project'];
export type Area = EntityMap['area'];
export type Heading = EntityMap['heading'];
export type Tag = EntityMap['tag'];
export type AnyEntity = EntityMap[EntityKind];

export type When = z.infer<typeof WhenSchema>;
export type Status = z.infer<typeof StatusSchema>;
export type RepeatFreq = z.infer<typeof RepeatFreqSchema>;
export type RepeatMode = z.infer<typeof RepeatModeSchema>;
export type RepeatRule = z.infer<typeof RepeatRuleSchema>;
export type ChecklistItem = z.infer<typeof ChecklistItemSchema>;
export type OpType = z.infer<typeof OpTypeSchema>;

export const ENTITY_KINDS: EntityKind[] = ['todo', 'project', 'area', 'heading', 'tag'];

/**
 * 注意:因为 schema 里大量使用 .default(),zod 的 input 类型是「可选」而 output 类型是「必填」,
 * 所以这里用 ZodTypeAny 存放,再由 parseEntity 统一断言成契约类型。
 */
export const ENTITY_SCHEMAS: Record<EntityKind, z.ZodTypeAny> = {
  todo: TodoSchema,
  project: ProjectSchema,
  area: AreaSchema,
  heading: HeadingSchema,
  tag: TagSchema
};

export function isEntityKind(v: unknown): v is EntityKind {
  return typeof v === 'string' && (ENTITY_KINDS as string[]).includes(v);
}

/**
 * 解析并校验实体 payload。
 * 失败抛 zod 的 ZodError,由 routes 层统一映射为 VALIDATION_FAILED。
 */
export function parseEntity<K extends EntityKind>(kind: K, payload: unknown): EntityMap[K] {
  return ENTITY_SCHEMAS[kind].parse(payload) as EntityMap[K];
}

/** 实体的「标题」字段,用于 §3「标题为空字符串的实体视为删除」 */
export function entityTitle(kind: EntityKind, entity: AnyEntity): string {
  switch (kind) {
    case 'todo':
      return (entity as Todo).title ?? '';
    case 'project':
      return (entity as Project).name ?? '';
    case 'area':
      return (entity as Area).name ?? '';
    case 'heading':
      return (entity as Heading).name ?? '';
    case 'tag':
      return (entity as Tag).name ?? '';
    default:
      return '';
  }
}

/** §2.2 硬约束判定:项目能否被标记为完成 */
export function isCompletedStatus(status: Status): boolean {
  return status === 'done' || status === 'canceled';
}
