/**
 * 同步核心 —— 契约 §7。
 *
 * 负责:
 *  - push:幂等(opId)、实体级 LWW(clientTs vs updatedAt)、完成不可回滚、标签并集、
 *          checklist 按 id 合并、删除墓碑、项目完成硬约束,并**捎带返回** sinceSeq 之后的远端 ops
 *  - pull:按 serverSeq 分页拉取
 *  - snapshot:全量快照(areas/projects/headings/todos/tags)
 *
 * serverSeq 由存储层分配,保证每个用户单调递增。
 */
import { ZodError } from 'zod';
import { AppConfig } from '../config';
import { OpRejection } from '../domain/errors';
import { errors } from '../domain/errors';
import {
  AnyEntity,
  Area,
  ChecklistItem,
  EntityKind,
  ENTITY_SCHEMAS,
  Heading,
  OpType,
  Project,
  Tag,
  Todo,
  isCompletedStatus,
  parseEntity
} from '../domain/model';
import { canCompleteProject, isEffectivelyDeleted, normalizeEntity } from '../domain/normalize';
import { EntityRow, NewOpRow, OpRow, Repository } from '../repo/types';
import { METRIC, Metrics } from '../observability/metrics';
import { RealtimeService } from './realtime';

/** 由 ReminderService 实现:todo 落库后同步 Fastlane 提醒索引 */
export interface ReminderIndexer {
  syncTodo(userId: string, todoId: string, todo: Todo | null): Promise<void>;
}

export interface IncomingOp {
  opId: string;
  deviceId: string | null;
  entity: EntityKind;
  entityId: string;
  type: OpType;
  payload: AnyEntity | null;
  clientTs: number;
}

export interface OpOut {
  opId: string;
  deviceId: string | null;
  entity: EntityKind;
  entityId: string;
  type: OpType;
  payload: AnyEntity | null;
  clientTs: number;
  seq: number;
}

export interface PushAccepted {
  opId: string;
  serverSeq: number | null;
  duplicate?: boolean;
  applied?: boolean;
  /** 命中了 stale/completion_immutable,但仍按 §7.3 规则 3 合并了标签 */
  tagsMerged?: boolean;
}

export interface PushRejected extends OpRejection {
  tagsMerged?: boolean;
}

export interface PushResult {
  serverSeq: number;
  accepted: PushAccepted[];
  rejected: PushRejected[];
  ops: OpOut[];
}

export interface PullResult {
  serverSeq: number;
  ops: OpOut[];
  hasMore: boolean;
}

export interface SnapshotResult {
  serverSeq: number;
  areas: Area[];
  projects: Project[];
  headings: Heading[];
  todos: Todo[];
  tags: Tag[];
}

export class SyncService {
  constructor(
    private repo: Repository,
    private config: AppConfig,
    private realtime: RealtimeService | null = null,
    private reminderIndexer: ReminderIndexer | null = null,
    private now: () => number = Date.now,
    private metrics: Metrics | null = null
  ) {}

  /* ============================ snapshot ============================ */

  async snapshot(userId: string): Promise<SnapshotResult> {
    const rows = await this.repo.listEntities(userId);
    const live = rows.filter((r) => !r.deleted);

    const areas = live.filter((r) => r.entity === 'area').map((r) => r.payload as Area);
    const projects = live.filter((r) => r.entity === 'project').map((r) => r.payload as Project);
    const todos = live.filter((r) => r.entity === 'todo').map((r) => r.payload as Todo);
    const tags = live.filter((r) => r.entity === 'tag').map((r) => r.payload as Tag);
    // §2.2:Heading 是顶层实体,单独同步;项目里的「标题列表」是派生视图
    const headings = live
      .filter((r) => r.entity === 'heading')
      .map((r) => r.payload as Heading)
      .sort((a, b) => a.order - b.order);

    return { serverSeq: await this.repo.latestSeq(userId), areas, projects, headings, todos, tags };
  }

  /* ============================ pull ============================ */

  async pull(userId: string, sinceSeq: number, limit: number): Promise<PullResult> {
    const serverSeq = await this.repo.latestSeq(userId);
    if (sinceSeq > serverSeq) {
      this.metrics?.inc(METRIC.SEQ_GAP, { endpoint: 'pull' });
      throw errors.seqGap('sinceSeq 超前于服务端,请重新拉取快照', { sinceSeq, serverSeq });
    }
    // 多取一条用于判断 hasMore
    const rows = await this.repo.opsSince(userId, sinceSeq, limit + 1);
    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;
    this.metrics?.inc(METRIC.PULL_REQUESTS, { hasMore: String(hasMore) });
    this.metrics?.inc(METRIC.PULL_OPS, {}, page.length);
    return { serverSeq, ops: page.map(toOpOut), hasMore };
  }

  /* ============================ push ============================ */

  async push(
    userId: string,
    deviceId: string | null,
    sinceSeq: number | null,
    ops: IncomingOp[]
  ): Promise<PushResult> {
    const currentSeq = await this.repo.latestSeq(userId);
    if (sinceSeq != null && sinceSeq > currentSeq) {
      this.metrics?.inc(METRIC.SEQ_GAP, { endpoint: 'push' });
      throw errors.seqGap('sinceSeq 超前于服务端,请重新拉取快照', { sinceSeq, serverSeq: currentSeq });
    }

    const existingOpIds = await this.repo.findExistingOpIds(
      userId,
      ops.map((o) => o.opId)
    );

    const accepted: PushAccepted[] = [];
    const rejected: PushRejected[] = [];
    const pendingOps: NewOpRow[] = [];
    /** 记录本次被写入的实体,等 serverSeq 分配后回填 */
    const touched: { entity: EntityKind; entityId: string; serverSeq: number | null }[] = [];

    for (const op of ops) {
      // ---- 幂等:同一 opId 只生效一次 ----
      if (existingOpIds.has(op.opId)) {
        accepted.push({ opId: op.opId, serverSeq: null, duplicate: true, applied: false });
        continue;
      }

      // ---- 单 op payload 上限(契约 §7.4:256 KB) ----
      const payloadBytes = byteLength(op.payload);
      if (payloadBytes > this.config.maxOpPayloadBytes) {
        this.metrics?.inc(METRIC.OP_TOO_LARGE);
        throw errors.opTooLarge('单个 op 的 payload 超过上限', {
          opId: op.opId,
          bytes: payloadBytes,
          limit: this.config.maxOpPayloadBytes
        });
      }

      const decision = await this.applyOp(userId, op);
      if (decision.kind === 'rejected') {
        rejected.push({ opId: op.opId, reason: decision.reason, message: decision.message, tagsMerged: decision.tagsMerged });
        if (decision.synthesizedOp) pendingOps.push(decision.synthesizedOp);
        continue;
      }

      pendingOps.push(decision.op);
      accepted.push({ opId: op.opId, serverSeq: null, applied: true, tagsMerged: decision.tagsMerged });
      if (decision.touchedEntity) touched.push({ ...decision.touchedEntity, serverSeq: null });
    }

    // ---- 追加 op 日志(分配 serverSeq) ----
    const appended = await this.repo.appendOps(pendingOps);

    // ---- 回填 accepted 的 serverSeq 与实体的 serverSeq ----
    const seqByOpId = new Map(appended.map((row) => [row.opId, row.serverSeq]));
    for (const item of accepted) {
      if (item.duplicate) continue;
      const seq = seqByOpId.get(item.opId);
      if (seq !== undefined) item.serverSeq = seq;
    }
    const seqByEntity = new Map<string, number>();
    for (const row of appended) seqByEntity.set(`${row.entity}|${row.entityId}`, row.serverSeq);
    for (const item of touched) {
      const seq = seqByEntity.get(`${item.entity}|${item.entityId}`);
      if (seq === undefined) continue;
      const row = await this.repo.getEntity(userId, item.entity, item.entityId);
      if (row) await this.repo.putEntity({ ...row, serverSeq: seq });
    }

    // ---- 捎带拉取:sinceSeq 之后的远端 ops(排除本次自己推的) ----
    const pushedIds = new Set(ops.map((o) => o.opId));
    const piggyback = (await this.repo.opsSince(userId, sinceSeq ?? 0, this.config.defaultPullLimit)).filter(
      (row) => !pushedIds.has(row.opId)
    );

    const serverSeq = await this.repo.latestSeq(userId);

    // ---- 实时广播给同用户的其它设备 ----
    if (this.realtime && appended.length > 0) {
      this.realtime.sendOps(userId, serverSeq, appended.map(toOpOut), deviceId);
    }

    // ---- 指标 ----
    if (pendingOps.length > 0 || rejected.length > 0) {
      this.metrics?.inc(METRIC.PUSH_REQUESTS, {
        result: rejected.length > 0 ? 'partial' : 'ok'
      });
    } else {
      this.metrics?.inc(METRIC.PUSH_REQUESTS, { result: 'noop' });
    }
    this.metrics?.inc(METRIC.OPS_PUSHED, {}, appended.length);
    for (const item of accepted) {
      if (item.duplicate) this.metrics?.inc(METRIC.OPS_REJECTED, { reason: 'duplicate' });
    }
    for (const item of rejected) this.metrics?.inc(METRIC.OPS_REJECTED, { reason: item.reason });

    // 墓碑清理已改为独立定时任务(services/tombstone-purger.ts),
    // 不再挂在 push 路径上:避免无推送实例永不清理,也避免清理耗时进入 push 延迟。
    return { serverSeq, accepted, rejected, ops: piggyback.map(toOpOut) };
  }

  /* ============================ 内部:单 op 应用 ============================ */

  private async applyOp(
    userId: string,
    op: IncomingOp
  ): Promise<
    | {
        kind: 'applied';
        op: NewOpRow;
        tagsMerged: boolean;
        touchedEntity: { entity: EntityKind; entityId: string } | null;
      }
    | {
        kind: 'rejected';
        reason: OpRejection['reason'];
        message?: string;
        tagsMerged?: boolean;
        synthesizedOp?: NewOpRow | null;
      }
  > {
    const now = this.now();
    const existing = await this.repo.getEntity(userId, op.entity, op.entityId);

    /* ---------- 1. 删除 op ---------- */
    if (op.type === 'delete') {
      if (existing && existing.deleted) {
        // 幂等:已经是墓碑,仍记一条 op 供其它设备收敛(不产生新版本)
        return {
          kind: 'applied',
          op: this.buildOpRow(userId, op, null, now),
          tagsMerged: false,
          touchedEntity: null
        };
      }
      if (existing && op.clientTs < existing.updatedAt) {
        return { kind: 'rejected', reason: 'stale', message: '删除 op 的 clientTs 早于服务端版本' };
      }
      const payload = existing
        ? ({ ...existing.payload, deleted: true, updatedAt: op.clientTs } as AnyEntity)
        : tombstonePayload(op.entity, op.entityId, op.clientTs);
      await this.repo.putEntity({
        userId,
        entity: op.entity,
        entityId: op.entityId,
        payload,
        updatedAt: op.clientTs,
        deleted: true,
        serverSeq: 0
      });
      if (op.entity === 'todo') await this.reminderIndexer?.syncTodo(userId, op.entityId, null);
      return {
        kind: 'applied',
        op: this.buildOpRow(userId, op, null, now),
        tagsMerged: false,
        touchedEntity: { entity: op.entity, entityId: op.entityId }
      };
    }

    /* ---------- 2. upsert:payload 校验 ---------- */
    let parsed: AnyEntity;
    try {
      parsed = parseEntity(op.entity, op.payload);
    } catch (err) {
      const message =
        err instanceof ZodError ? err.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; ') : 'payload 校验失败';
      return { kind: 'rejected', reason: 'invalid', message };
    }

    const normalized = this.normalize(userId, op, parsed, existing, now);

    /* ---------- 3. §3 标题为空视为删除 ---------- */
    if (isEffectivelyDeleted(op.entity, normalized) || (normalized as { deleted?: boolean }).deleted === true) {
      const payload = { ...normalized, deleted: true, updatedAt: op.clientTs } as AnyEntity;
      await this.repo.putEntity({
        userId,
        entity: op.entity,
        entityId: op.entityId,
        payload,
        updatedAt: op.clientTs,
        deleted: true,
        serverSeq: 0
      });
      if (op.entity === 'todo') await this.reminderIndexer?.syncTodo(userId, op.entityId, null);
      return {
        kind: 'applied',
        op: this.buildOpRow(userId, { ...op, type: 'delete' }, null, now),
        tagsMerged: false,
        touchedEntity: { entity: op.entity, entityId: op.entityId }
      };
    }

    /* ---------- 4. 墓碑:旧 op 不能让实体复活 ---------- */
    if (existing && existing.deleted && op.clientTs < existing.updatedAt) {
      return {
        kind: 'rejected',
        reason: 'tombstoned',
        message: '实体已被删除(墓碑更新),该 op 版本更旧,拒绝复活'
      };
    }

    /* ---------- 5. 实体级 LWW ---------- */
    const incomingStatus = (normalized as { status?: string }).status;
    const existingStatus = existing ? (existing.payload as { status?: string }).status : undefined;

    if (existing && !existing.deleted && op.clientTs < existing.updatedAt) {
      const merged = await this.mergeTagsOnly(userId, existing, normalized, op, now);
      return {
        kind: 'rejected',
        reason: 'stale',
        message: `clientTs(${op.clientTs}) 早于服务端 updatedAt(${existing.updatedAt})`,
        tagsMerged: merged.merged,
        synthesizedOp: merged.op
      };
    }

    /* ---------- 6. 完成不可回滚 ---------- */
    if (
      existing &&
      !existing.deleted &&
      incomingStatus === 'open' &&
      (existingStatus === 'done' || existingStatus === 'canceled')
    ) {
      const merged = await this.mergeTagsOnly(userId, existing, normalized, op, now);
      return {
        kind: 'rejected',
        reason: 'completion_immutable',
        message: '本地已完成/已取消,拒绝被 open 状态覆盖',
        tagsMerged: merged.merged,
        synthesizedOp: merged.op
      };
    }

    /* ---------- 7. 项目完成硬约束(§2.2) ---------- */
    if (op.entity === 'project' && (normalized as Project).status === 'done') {
      const project = normalized as Project;
      const children = await this.collectProjectTodos(userId, project.id);
      const headings = await this.collectProjectHeadings(userId, project.id);
      if (!canCompleteProject('done', children, headings)) {
        return {
          kind: 'rejected',
          reason: 'project_incomplete',
          message: '项目下仍有未完成的待办或未归档的标题,不允许标记完成(契约 §2.2)'
        };
      }
    }

    /* ---------- 8. §3:headingId 必须属于 projectId 指向的项目,否则置 null ---------- */
    let finalIncoming = normalized;
    if (op.entity === 'todo') {
      finalIncoming = (await this.ensureHeadingValid(userId, normalized as Todo)) as AnyEntity;
    }

    /* ---------- 9. 应用:标签并集 + checklist 合并 ---------- */
    const tagsMerged = unionTags(
      existing && !existing.deleted ? ((existing.payload as { tags?: string[] }).tags ?? []) : [],
      (finalIncoming as { tags?: string[] }).tags ?? []
    );
    const finalPayload = this.mergeForStore(op.entity, existing, finalIncoming, tagsMerged, op.clientTs);

    await this.repo.putEntity({
      userId,
      entity: op.entity,
      entityId: op.entityId,
      payload: finalPayload,
      updatedAt: op.clientTs,
      deleted: false,
      serverSeq: 0
    });

    if (op.entity === 'todo') {
      const todo = finalPayload as Todo;
      await this.reminderIndexer?.syncTodo(userId, todo.id, todo.status === 'open' && todo.reminder ? todo : null);
    }

    return {
      kind: 'applied',
      op: this.buildOpRow(userId, op, finalPayload, now),
      tagsMerged: tagsMerged.length > ((finalIncoming as { tags?: string[] }).tags?.length ?? 0),
      touchedEntity: { entity: op.entity, entityId: op.entityId }
    };
  }

  /**
   * 归一化:注入 now / 时区 / 原始 payload。
   * headingId 的归属校验需要读库,由 `ensureHeadingValid()` 在落库前异步完成
   * (Heading 是顶层实体,项目 payload 里没有 headings 字段)。
   */
  private normalize(_userId: string, op: IncomingOp, parsed: AnyEntity, _existing: EntityRow | null, now: number): AnyEntity {
    const raw = (op.payload ?? {}) as Record<string, unknown>;
    return normalizeEntity(op.entity, parsed, {
      nowMs: now,
      tzOffsetMinutes: this.config.tzOffsetMinutes,
      raw
    });
  }

  /** §3:headingId 必须属于 projectId 指向的项目(Heading 是顶层实体),否则置 null */
  private async ensureHeadingValid(userId: string, todo: Todo): Promise<Todo> {
    if (!todo.headingId) return todo;
    if (!todo.projectId) return { ...todo, headingId: null };

    const headingRows = await this.repo.listEntities(userId, 'heading');
    const ok = headingRows.some(
      (r) =>
        !r.deleted &&
        (r.payload as Heading).id === todo.headingId &&
        (r.payload as Heading).projectId === todo.projectId
    );
    return ok ? todo : { ...todo, headingId: null };
  }

  /** 合并:updatedAt 强制为 clientTs;checklist 按 id 合并;tags 取并集 */
  private mergeForStore(
    kind: EntityKind,
    existing: EntityRow | null,
    incoming: AnyEntity,
    tags: string[],
    clientTs: number
  ): AnyEntity {
    const base = { ...(incoming as Record<string, unknown>) };
    base.updatedAt = clientTs;
    if (base.createdAt === undefined || base.createdAt === null) {
      base.createdAt = existing ? (existing.payload as { createdAt?: number }).createdAt ?? clientTs : clientTs;
    }
    base.deleted = false;

    if (kind === 'todo' || kind === 'project') {
      base.tags = tags;
      const incomingChecklist = (base.checklist as ChecklistItem[] | undefined) ?? [];
      const existingChecklist =
        existing && !existing.deleted ? (((existing.payload as { checklist?: ChecklistItem[] }).checklist) ?? []) : [];
      base.checklist = mergeChecklist(incomingChecklist, existingChecklist);
    }
    return base as unknown as AnyEntity;
  }

  /** §7.3 规则 3:即使 op 被判负,标签也要取并集(并合成一条 op 让其它设备收敛) */
  private async mergeTagsOnly(
    userId: string,
    existing: EntityRow,
    incoming: AnyEntity,
    op: IncomingOp,
    now: number
  ): Promise<{ merged: boolean; op: NewOpRow | null }> {
    if (op.entity !== 'todo' && op.entity !== 'project') return { merged: false, op: null };
    const current = ((existing.payload as { tags?: string[] }).tags ?? []) as string[];
    const incomingTags = ((incoming as { tags?: string[] }).tags ?? []) as string[];
    const union = unionTags(current, incomingTags);
    if (union.length === current.length) return { merged: false, op: null };

    const payload = { ...(existing.payload as Record<string, unknown>), tags: union } as unknown as AnyEntity;
    await this.repo.putEntity({ ...existing, payload });
    return {
      merged: true,
      op: {
        userId,
        opId: `srv:tags:${op.opId}`,
        deviceId: op.deviceId,
        entity: op.entity,
        entityId: op.entityId,
        type: 'upsert',
        payload,
        clientTs: existing.updatedAt,
        createdAt: now
      }
    };
  }

  private buildOpRow(userId: string, op: IncomingOp, payload: AnyEntity | null, now: number): NewOpRow {
    return {
      userId,
      opId: op.opId,
      deviceId: op.deviceId,
      entity: op.entity,
      entityId: op.entityId,
      type: op.type,
      payload,
      clientTs: op.clientTs,
      createdAt: now
    };
  }

  private async collectProjectTodos(userId: string, projectId: string): Promise<Todo[]> {
    const rows = await this.repo.listEntities(userId, 'todo');
    return rows
      .filter((r) => !r.deleted && (r.payload as Todo).projectId === projectId)
      .map((r) => r.payload as Todo);
  }

  private async collectProjectHeadings(userId: string, projectId: string): Promise<Heading[]> {
    const rows = await this.repo.listEntities(userId, 'heading');
    return rows
      .filter((r) => !r.deleted && (r.payload as Heading).projectId === projectId)
      .map((r) => r.payload as Heading);
  }

  /**
   * 墓碑清理已迁移到独立的定时任务(见 services/tombstone-purger.ts),
   * push 路径不再顺带清理:避免无推送的实例永不清理,也避免清理耗时进入 push 延迟。
   */

  /** headingId 归属的异步修正(落库前调用) */
  async fixTodoHeading(userId: string, op: IncomingOp): Promise<void> {
    if (op.entity !== 'todo' || op.type !== 'upsert' || !op.payload) return;
    const todo = op.payload as Todo;
    if (!todo.headingId) return;
    const fixed = await this.ensureHeadingValid(userId, todo);
    if (fixed.headingId !== todo.headingId) op.payload = fixed;
  }
}

/* ============================ 纯函数辅助 ============================ */

export function unionTags(a: string[], b: string[]): string[] {
  return [...new Set([...(a ?? []), ...(b ?? [])])];
}

export function mergeChecklist(winner: ChecklistItem[], loser: ChecklistItem[]): ChecklistItem[] {
  const ids = new Set(winner.map((c) => c.id));
  return [...winner, ...loser.filter((c) => !ids.has(c.id))];
}

export function byteLength(value: unknown): number {
  if (value === null || value === undefined) return 0;
  return Buffer.byteLength(JSON.stringify(value), 'utf8');
}

export function toOpOut(row: OpRow): OpOut {
  return {
    opId: row.opId,
    deviceId: row.deviceId,
    entity: row.entity,
    entityId: row.entityId,
    type: row.type,
    payload: row.payload,
    clientTs: row.clientTs,
    seq: row.serverSeq
  };
}

/** 为空实体删除生成墓碑 payload(字段与 §2 保持一致) */
export function tombstonePayload(kind: EntityKind, entityId: string, clientTs: number): AnyEntity {
  const base = { id: entityId, updatedAt: clientTs, deleted: true };
  switch (kind) {
    case 'todo':
      return {
        ...base,
        title: '',
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
        createdAt: clientTs,
        completedAt: null
      } as unknown as AnyEntity;
    case 'project':
      return {
        ...base,
        areaId: null,
        name: '',
        note: '',
        when: 'anytime',
        date: null,
        deadline: null,
        tags: [],
        order: 0,
        status: 'open',
        completedAt: null,
        repeat: null,
        createdAt: clientTs
      } as unknown as AnyEntity;
    case 'area':
      return { ...base, name: '', color: '#5B5BD6', order: 0, archived: false } as unknown as AnyEntity;
    case 'heading':
      return { ...base, projectId: '', name: '', order: 0, archived: false, collapsed: false } as unknown as AnyEntity;
    case 'tag':
      return { ...base, name: '', color: '#8E8E93' } as unknown as AnyEntity;
    default:
      return base as unknown as AnyEntity;
  }
}

export { ENTITY_SCHEMAS };
