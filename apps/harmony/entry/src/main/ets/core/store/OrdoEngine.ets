/**
 * Ordo · 业务引擎
 * 契约来源:docs/03-数据模型与同步协议.md
 *   §2 数据模型 · §3 默认值与不变量 · §4 派生清单(委托 ListQuery)
 *   §6 重复引擎(委托 RepeatEngine)· §7.1/§7.2/§7.3 本地优先写入 + Op 产出 + 远端合并
 *
 * 职责边界:
 *  - 本文件是**唯一**的实体读写入口;所有写操作先改内存、立即通知 UI,再异步落库(本地优先)
 *  - 每次写操作产出一条 Op 进入 outbox(契约 §7.1)
 *  - 实现 OpSink(applyRemoteOp)与 OpSource(exportSnapshot / takePendingOps / …),
 *    使 SyncEngine 与本引擎之间不产生循环依赖
 *  - 派生清单查询本身在 core/query/ListQuery.ets,本文件只暴露数据与统计
 */

import {
  Area,
  ChecklistItem,
  EntityKind,
  Heading,
  MAX_PULL_LIMIT,
  Op,
  OpType,
  OrdoState,
  Project,
  RepeatRule,
  Snapshot,
  Status,
  Tag,
  TOMBSTONE_TTL_MS,
  Todo,
  Tombstone,
  When,
  cloneArea,
  cloneHeading,
  cloneProject,
  cloneTag,
  cloneTodo,
  newArea,
  newHeading,
  newProject,
  newTag,
  newTodo,
  newTombstone
} from '../model/Entities.ets';
import { OrdoStore, StorageSnapshot } from '../storage/OrdoStore.ets';
import { todayISO } from '../util/DateUtil.ets';
import { newChecklistItemId, newId, newOpId, nowMillis } from '../util/Ids.ets';
import { ParsedInput, parseNaturalNow } from '../nlp/NaturalDateParser.ets';
import { RepeatCompletion, completeWithRepeat, sanitizeRepeatRule } from '../repeat/RepeatEngine.ets';
import { ApplyResult, OpSink, OpSource, applyResult } from '../sync/SyncTypes.ets';

/** 引擎变更通知(UI 订阅后重新渲染) */
export type EngineListener = () => void;

/** 新建待办的参数(可空项由契约 §3 的默认值规则决定) */
export interface CreateTodoOptions {
  raw: string;
  projectId: string | null;
  areaId: string | null;
  headingId: string | null;
  when: When | null;
}

/** 完成/取消后的反馈(供 UI 播放动效与提示) */
export interface CompletionFeedback {
  todo: Todo | null;
  nextInstance: Todo | null;
  repeatCreated: boolean;
}

const DEFAULT_AREA_COLOR: string = '#5B5BD6';
const DEFAULT_TAG_COLOR: string = '#7A776F';

export class OrdoEngine implements OpSink, OpSource {
  private store: OrdoStore;
  private state: OrdoState;
  private outbox: Op[];
  private tombstones: Tombstone[];
  private lastServerSeq: number;
  private deviceId: string;
  private listeners: EngineListener[];
  private ready: boolean;

  constructor(store: OrdoStore) {
    this.store = store;
    this.state = { areas: [], projects: [], todos: [], tags: [], events: [] };
    this.outbox = [];
    this.tombstones = [];
    this.lastServerSeq = 0;
    this.deviceId = '';
    this.listeners = [];
    this.ready = false;
  }

  /* ============================================================ 生命周期 */

  /** 从本地库装载;库为空时由调用方写入种子数据(见 SeedData.ets) */
  async init(deviceId: string): Promise<void> {
    this.deviceId = deviceId;
    const areas: Area[] = await this.store.loadAreas();
    const projects: Project[] = await this.store.loadProjects();
    const headings: Heading[] = await this.store.loadHeadings();
    const todos: Todo[] = await this.store.loadTodos();
    const tags: Tag[] = await this.store.loadTags();
    const seq: string | null = await this.store.getKv('lastServerSeq');
    this.lastServerSeq = seq === null ? 0 : parseInt(seq, 10);
    if (isNaN(this.lastServerSeq)) {
      this.lastServerSeq = 0;
    }
    // headings 规范存放于 Project.headings(契约 §2.2),库里是独立表,装载时装配
    for (let i = 0; i < projects.length; i++) {
      projects[i].headings = [];
    }
    for (let i = 0; i < headings.length; i++) {
      const h: Heading = headings[i];
      for (let p = 0; p < projects.length; p++) {
        if (projects[p].id === h.projectId) {
          projects[p].headings.push(h);
          break;
        }
      }
    }
    this.state = { areas: areas, projects: projects, todos: todos, tags: tags, events: [] };
    this.outbox = await this.store.loadOutbox();
    this.tombstones = await this.store.loadTombstones();
    this.ready = true;
    this.emit();
  }

  isReady(): boolean {
    return this.ready;
  }

  addListener(l: EngineListener): void {
    this.listeners.push(l);
  }

  removeListener(l: EngineListener): void {
    const idx: number = this.listeners.indexOf(l);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  private emit(): void {
    const snapshot: EngineListener[] = this.listeners.slice(0);
    for (let i = 0; i < snapshot.length; i++) {
      snapshot[i]();
    }
  }

  /** 把种子数据/远端快照写入本地库(首次安装、重置示例数据、§7.4 全量快照落地) */
  async persistAll(next: OrdoState): Promise<void> {
    this.state = next;
    const snapshot: StorageSnapshot = {
      areas: next.areas,
      projects: next.projects,
      headings: this.allHeadings(),
      todos: next.todos,
      tags: next.tags
    };
    // 增量对账:只写变化实体、只删快照中消失的 id,且在一个事务内完成
    await this.store.saveSnapshot(snapshot);
    this.emit();
  }

  /* ============================================================ 读取视图 */

  todos(): Todo[] {
    return this.state.todos;
  }

  projects(): Project[] {
    return this.state.projects;
  }

  areas(): Area[] {
    return this.state.areas;
  }

  tags(): Tag[] {
    return this.state.tags;
  }

  /** 全部标题(契约 §7.4 snapshot 的顶层 headings 数组) */
  allHeadings(): Heading[] {
    const out: Heading[] = [];
    for (let i = 0; i < this.state.projects.length; i++) {
      const hs: Heading[] = this.state.projects[i].headings;
      for (let k = 0; k < hs.length; k++) {
        out.push(hs[k]);
      }
    }
    return out;
  }

  findTodo(id: string): Todo | null {
    for (let i = 0; i < this.state.todos.length; i++) {
      if (this.state.todos[i].id === id) {
        return this.state.todos[i];
      }
    }
    return null;
  }

  findProject(id: string): Project | null {
    for (let i = 0; i < this.state.projects.length; i++) {
      if (this.state.projects[i].id === id) {
        return this.state.projects[i];
      }
    }
    return null;
  }

  findArea(id: string): Area | null {
    for (let i = 0; i < this.state.areas.length; i++) {
      if (this.state.areas[i].id === id) {
        return this.state.areas[i];
      }
    }
    return null;
  }

  findTag(name: string): Tag | null {
    for (let i = 0; i < this.state.tags.length; i++) {
      if (this.state.tags[i].name === name) {
        return this.state.tags[i];
      }
    }
    return null;
  }

  findHeading(headingId: string): Heading | null {
    for (let i = 0; i < this.state.projects.length; i++) {
      const hs: Heading[] = this.state.projects[i].headings;
      for (let k = 0; k < hs.length; k++) {
        if (hs[k].id === headingId) {
          return hs[k];
        }
      }
    }
    return null;
  }

  /* ============================================================ 待办写入 */

  /**
   * 新建待办(契约 §3 默认值):
   *  - 未指定 when 且未指定 projectId → when="inbox"
   *  - 未指定 when 但指定了 projectId  → when="anytime"
   *  - 走 NLP 解析(标题清理 / 日期 / 提醒 / 标签;标签不存在则自动创建)
   */
  createTodo(options: CreateTodoOptions): Todo | null {
    const parsed: ParsedInput = parseNaturalNow(options.raw);
    const title: string = parsed.cleanTitle.length > 0 ? parsed.cleanTitle : options.raw.trim();
    if (title.length === 0 && parsed.tags.length === 0) {
      return null;
    }
    const now: number = nowMillis();
    const t: Todo = newTodo(newId(), title, now);

    // when:解析结果 > 显式参数 > 契约 §3 默认值
    if (parsed.when !== null) {
      t.when = parsed.when;
      t.date = parsed.date;
    } else if (options.when !== null) {
      t.when = options.when;
      t.date = options.when === 'date' ? todayISO() : null;
    } else {
      t.when = options.projectId === null ? 'inbox' : 'anytime';
    }
    t.projectId = options.projectId;
    t.areaId = options.areaId;
    t.headingId = options.headingId;
    t.order = this.nextOrder(t.when, options.projectId);

    for (let i = 0; i < parsed.tags.length; i++) {
      this.ensureTag(parsed.tags[i]);
      t.tags.push(parsed.tags[i]);
    }
    if (parsed.reminder !== null) {
      t.reminder = parsed.reminder;
    }
    this.normalizeTodo(t, now);

    this.state.todos.push(t);
    this.persistTodo(t);
    this.pushOp('todo', t.id, 'upsert');
    this.emit();
    return t;
  }

  setTodoTitle(id: string, title: string): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      return;
    }
    const trimmed: string = title.trim();
    if (trimmed.length === 0) {
      // 契约 §3:标题为空字符串的实体视为删除
      this.deleteTodo(id);
      return;
    }
    t.title = trimmed;
    this.touchTodo(t);
  }

  setTodoNote(id: string, note: string): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      return;
    }
    t.note = note;
    this.touchTodo(t);
  }

  /** 设置「何时」(契约 §3:when=date 时 date 必须非空;其它 when 时 date 必须为 null) */
  setWhen(id: string, when: When, date: string | null): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      return;
    }
    t.when = when;
    t.date = when === 'date' ? (date !== null && date.length === 10 ? date : todayISO()) : null;
    if (t.projectId !== null && t.when === 'inbox') {
      t.when = 'anytime';
    }
    this.normalizeTodo(t, nowMillis());
    this.touchTodo(t);
  }

  setDeadline(id: string, deadline: string | null): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      return;
    }
    t.deadline = deadline !== null && deadline.length === 10 ? deadline : null;
    this.touchTodo(t);
  }

  /**
   * 设置提醒(契约 §3):
   *  - reminder 的日期部分必须等于 (when=="date" ? date : 今天)
   *  - 原本 when ∈ {inbox, anytime, someday} 时自动改为 "today"
   */
  setReminder(id: string, reminder: string | null): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      return;
    }
    if (reminder === null) {
      t.reminder = null;
      this.touchTodo(t);
      return;
    }
    if (t.when === 'inbox' || t.when === 'anytime' || t.when === 'someday') {
      t.when = 'today';
      t.date = null;
    }
    const base: string = t.when === 'date' && t.date !== null ? t.date : todayISO();
    const hm: string = reminder.length >= 16 ? reminder.substring(11, 16) : '09:00';
    t.reminder = base + 'T' + hm;
    this.touchTodo(t);
  }

  addTagToTodo(id: string, name: string): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null || name.trim().length === 0) {
      return;
    }
    const clean: string = name.trim();
    this.ensureTag(clean);
    if (t.tags.indexOf(clean) < 0) {
      t.tags.push(clean);
      this.touchTodo(t);
    }
  }

  removeTagFromTodo(id: string, name: string): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      return;
    }
    const idx: number = t.tags.indexOf(name);
    if (idx >= 0) {
      t.tags.splice(idx, 1);
      this.touchTodo(t);
    }
  }

  setTodoRepeat(id: string, rule: RepeatRule | null): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      return;
    }
    t.repeat = sanitizeRepeatRule(rule);
    if (t.repeat !== null && t.when !== 'date') {
      // 重复必须有基准日期:收件箱 / 随时 / 某天 提升为 date=今天
      t.when = 'date';
      t.date = t.date !== null ? t.date : todayISO();
    }
    this.normalizeTodo(t, nowMillis());
    this.touchTodo(t);
  }

  /* ---------------------------------------------------------- 清单项 */

  addChecklistItem(todoId: string, title: string): ChecklistItem | null {
    const t: Todo | null = this.findTodo(todoId);
    if (t === null || t.checklist.length >= 100) {
      return null; // 契约 §2.5:清单项 ≤100
    }
    const item: ChecklistItem = { id: newChecklistItemId(), title: title, done: false };
    t.checklist.push(item);
    this.touchTodo(t);
    return item;
  }

  setChecklistItemTitle(todoId: string, itemId: string, title: string): void {
    const t: Todo | null = this.findTodo(todoId);
    if (t === null) {
      return;
    }
    for (let i = 0; i < t.checklist.length; i++) {
      if (t.checklist[i].id === itemId) {
        t.checklist[i].title = title;
        this.touchTodo(t);
        return;
      }
    }
  }

  toggleChecklistItem(todoId: string, itemId: string): void {
    const t: Todo | null = this.findTodo(todoId);
    if (t === null) {
      return;
    }
    for (let i = 0; i < t.checklist.length; i++) {
      if (t.checklist[i].id === itemId) {
        t.checklist[i].done = !t.checklist[i].done;
        this.touchTodo(t);
        return;
      }
    }
  }

  removeChecklistItem(todoId: string, itemId: string): void {
    const t: Todo | null = this.findTodo(todoId);
    if (t === null) {
      return;
    }
    for (let i = 0; i < t.checklist.length; i++) {
      if (t.checklist[i].id === itemId) {
        t.checklist.splice(i, 1);
        this.touchTodo(t);
        return;
      }
    }
  }

  /* ---------------------------------------------------------- 移动 / 排序 */

  /** 移动到项目/区域(契约 §3:移入项目时 inbox → anytime;headingId 必须属于该项目) */
  moveTodo(id: string, projectId: string | null, areaId: string | null, headingId: string | null): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      return;
    }
    t.projectId = projectId;
    t.areaId = projectId === null ? areaId : null;
    t.headingId = headingId;
    if (projectId !== null && t.when === 'inbox') {
      t.when = 'anytime';
    }
    if (projectId === null && t.when === 'anytime' && areaId === null) {
      t.when = 'inbox';
    }
    this.normalizeTodo(t, nowMillis());
    this.touchTodo(t);
  }

  /** 排序:把待办移动到同组内的目标序号 */
  reorderTodo(id: string, targetOrder: number): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      return;
    }
    t.order = targetOrder;
    this.touchTodo(t);
  }

  /**
   * 拖拽排序(契约 §2.4 的 `order`,04 §6「长按拖拽」):按传入顺序**整批**重写 `order = 下标`。
   *
   * 与共享核心 `OrdoEngine.reorderTodos(ids)`(shared/core/.../OrdoEngine.kt:293)语义逐字一致:
   * `ids[i]` 的 order = i。调用方必须提交**同一容器内的完整可见序列**——核心不知道该清单里
   * 被过滤掉了哪些条目,提交残缺序列会把未提交的条目挤到数组末尾。
   *
   * 容器 = `(when, projectId, headingId)` 三元组(见 `nextOrder` 的作用域);跨容器提交会写出
   * 互相竞争的 order,由视图层(`view/list/ReorderMath.ets`)在提交前拒绝。
   *
   * 与 `reorderTodo()` 的区别:后者只改一条的 order(会把其它条目挤到同序号),本方法按整段序列落库。
   *
   * @returns 真正被改写的条数(0 表示 ids 里没有本地存在的待办)
   */
  reorderTodos(ids: string[]): number {
    const now: number = nowMillis();
    const updated: Todo[] = [];
    for (let i = 0; i < ids.length; i++) {
      const t: Todo | null = this.findTodo(ids[i]);
      if (t === null) {
        continue;
      }
      t.order = i;
      t.updatedAt = now;
      updated.push(t);
    }
    for (let i = 0; i < updated.length; i++) {
      // 每一条都要落库 + 产出 Op(契约 §7.1 本地优先),合并成一次 emit 通知 UI
      this.persistTodo(updated[i]);
      this.pushOp('todo', updated[i].id, 'upsert');
    }
    if (updated.length > 0) {
      this.emit();
    }
    return updated.length;
  }

  /**
   * 撤销删除(左滑删除的可撤销兜底,04 §6):`deleted` 复位 + `updatedAt` 取当前时刻。
   *
   * 本地墓碑保留不动,理由:墓碑规则是「deletedAt >= op.clientTs 才忽略」(§7.3.5),
   * 恢复后 `updatedAt = now` 已经晚于墓碑时刻,任何早于删除时刻的远端 op 本就该被 LWW 拒绝;
   * 保留墓碑只是把"我们自己的删除 op 回声"一并挡掉,而不会挡住用户之后的新删除(那时会刷新墓碑)。
   */
  restoreDeletedTodo(id: string): boolean {
    const t: Todo | null = this.findTodo(id);
    if (t === null || !t.deleted) {
      return false;
    }
    t.deleted = false;
    this.touchTodo(t);
    return true;
  }

  /* ---------------------------------------------------------- 完成 / 取消 */

  /**
   * 勾选完成(契约 §6):重复待办会生成新实例。
   * 已完成的再点一次表示恢复。
   */
  toggleDone(id: string): CompletionFeedback {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      const empty: CompletionFeedback = { todo: null, nextInstance: null, repeatCreated: false };
      return empty;
    }
    if (t.status !== 'open') {
      t.status = 'open';
      t.completedAt = null;
      this.touchTodo(t);
      const restored: CompletionFeedback = { todo: t, nextInstance: null, repeatCreated: false };
      return restored;
    }

    const now: number = nowMillis();
    const today: string = todayISO();
    const result: RepeatCompletion = completeWithRepeat(t, now, today);
    this.replaceTodo(id, result.completed);
    if (result.next !== null) {
      this.state.todos.push(result.next);
      this.persistTodo(result.next);
      this.pushOp('todo', result.next.id, 'upsert');
    }
    const feedback: CompletionFeedback = {
      todo: result.completed,
      nextInstance: result.next,
      repeatCreated: result.next !== null
    };
    return feedback;
  }

  cancelTodo(id: string): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      return;
    }
    t.status = 'canceled';
    t.completedAt = nowMillis();
    this.touchTodo(t);
  }

  restoreTodo(id: string): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      return;
    }
    t.status = 'open';
    t.completedAt = null;
    this.touchTodo(t);
  }

  /** 软删除(契约 §3):deleted=true + updatedAt 更新,并登记本地墓碑 */
  deleteTodo(id: string): void {
    const t: Todo | null = this.findTodo(id);
    if (t === null) {
      return;
    }
    const now: number = nowMillis();
    t.deleted = true;
    t.updatedAt = now;
    this.recordTombstone('todo', id, now);
    this.persistTodo(t);
    // 软删除以 payload.deleted=true 表达,保留 LWW 时间戳(契约 §7.3.1)
    this.pushOp('todo', id, 'upsert');
    this.emit();
  }

  /* ============================================================ 项目 */

  createProject(name: string, areaId: string | null): Project {
    const now: number = nowMillis();
    const fallback: string = '未命名项目';
    const p: Project = newProject(newId(), name.trim().length > 0 ? name.trim() : fallback, areaId, now);
    p.order = this.state.projects.length;
    this.state.projects.push(p);
    this.persistProject(p);
    this.pushOp('project', p.id, 'upsert');
    this.emit();
    return p;
  }

  renameProject(id: string, name: string): void {
    const p: Project | null = this.findProject(id);
    if (p === null) {
      return;
    }
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return; // 项目不允许空名(与待办不同,避免误删整个项目)
    }
    p.name = trimmed;
    this.touchProject(p);
  }

  setProjectNote(id: string, note: string): void {
    const p: Project | null = this.findProject(id);
    if (p === null) {
      return;
    }
    p.note = note;
    this.touchProject(p);
  }

  setProjectArea(id: string, areaId: string | null): void {
    const p: Project | null = this.findProject(id);
    if (p === null) {
      return;
    }
    p.areaId = areaId;
    this.touchProject(p);
  }

  /**
   * 项目完成硬约束(契约 §2.2):
   * 仅当所有子待办 status ∈ {done, canceled} 且所有 heading.archived == true。
   */
  canCompleteProject(id: string): boolean {
    const p: Project | null = this.findProject(id);
    if (p === null) {
      return false;
    }
    for (let i = 0; i < this.state.todos.length; i++) {
      const t: Todo = this.state.todos[i];
      if (t.projectId === id && !t.deleted && t.status === 'open') {
        return false;
      }
    }
    for (let i = 0; i < p.headings.length; i++) {
      if (!p.headings[i].archived) {
        return false;
      }
    }
    return true;
  }

  completeProject(id: string): boolean {
    if (!this.canCompleteProject(id)) {
      return false;
    }
    const p: Project | null = this.findProject(id);
    if (p === null) {
      return false;
    }
    p.status = 'done';
    p.completedAt = nowMillis();
    this.touchProject(p);
    return true;
  }

  restoreProject(id: string): void {
    const p: Project | null = this.findProject(id);
    if (p === null) {
      return;
    }
    p.status = 'open';
    p.completedAt = null;
    this.touchProject(p);
  }

  deleteProject(id: string): void {
    const p: Project | null = this.findProject(id);
    if (p === null) {
      return;
    }
    const now: number = nowMillis();
    p.deleted = true;
    p.updatedAt = now;
    this.recordTombstone('project', id, now);
    this.persistProject(p);
    this.pushOp('project', id, 'upsert');
    this.emit();
  }

  /* ============================================================ 标题 */

  addHeading(projectId: string, name: string): Heading | null {
    const p: Project | null = this.findProject(projectId);
    if (p === null) {
      return null;
    }
    const now: number = nowMillis();
    const fallback: string = '新标题';
    const h: Heading = newHeading(newId(), projectId, name.trim().length > 0 ? name.trim() : fallback, p.headings.length, now);
    p.headings.push(h);
    this.persistHeading(h);
    this.pushOp('heading', h.id, 'upsert');
    this.emit();
    return h;
  }

  renameHeading(headingId: string, name: string): void {
    const h: Heading | null = this.findHeading(headingId);
    if (h === null) {
      return;
    }
    h.name = name.trim().length > 0 ? name.trim() : h.name;
    h.updatedAt = nowMillis();
    this.persistHeading(h);
    this.pushOp('heading', h.id, 'upsert');
    this.emit();
  }

  /** 折叠是设备本地 UI 状态,不参与同步(契约 §2.3) */
  toggleHeadingCollapsed(headingId: string): void {
    const h: Heading | null = this.findHeading(headingId);
    if (h === null) {
      return;
    }
    h.collapsed = !h.collapsed;
    this.persistHeading(h);
    this.emit();
  }

  /** 归档标题前必须先完成其下所有待办(项目完成硬约束的组成部分) */
  canArchiveHeading(headingId: string): boolean {
    for (let i = 0; i < this.state.todos.length; i++) {
      const t: Todo = this.state.todos[i];
      if (t.headingId === headingId && !t.deleted && t.status === 'open') {
        return false;
      }
    }
    return true;
  }

  archiveHeading(headingId: string): boolean {
    if (!this.canArchiveHeading(headingId)) {
      return false;
    }
    const h: Heading | null = this.findHeading(headingId);
    if (h === null) {
      return false;
    }
    h.archived = true;
    h.updatedAt = nowMillis();
    this.persistHeading(h);
    this.pushOp('heading', h.id, 'upsert');
    this.emit();
    return true;
  }

  deleteHeading(headingId: string): void {
    const h: Heading | null = this.findHeading(headingId);
    if (h === null) {
      return;
    }
    const p: Project | null = this.findProject(h.projectId);
    if (p !== null) {
      for (let i = 0; i < p.headings.length; i++) {
        if (p.headings[i].id === headingId) {
          p.headings.splice(i, 1);
          break;
        }
      }
    }
    // 标题下的待办不随之删除,回归"无标题"分组
    for (let i = 0; i < this.state.todos.length; i++) {
      const t: Todo = this.state.todos[i];
      if (t.headingId === headingId) {
        t.headingId = null;
        t.updatedAt = nowMillis();
        this.persistTodo(t);
        this.pushOp('todo', t.id, 'upsert');
      }
    }
    this.recordTombstone('heading', headingId, nowMillis());
    this.safeStore(this.store.removeHeading(headingId), '标题删除');
    this.pushOp('heading', headingId, 'delete');
    this.emit();
  }

  /** 批量完成某标题下的全部待办(归档前置操作) */
  completeHeadingTodos(headingId: string): number {
    let count: number = 0;
    for (let i = 0; i < this.state.todos.length; i++) {
      const t: Todo = this.state.todos[i];
      if (t.headingId === headingId && t.status === 'open' && !t.deleted) {
        this.toggleDone(t.id);
        count++;
      }
    }
    return count;
  }

  /* ============================================================ 区域 */

  createArea(name: string, color: string): Area {
    const now: number = nowMillis();
    const fallback: string = '新区域';
    const a: Area = newArea(newId(), name.trim().length > 0 ? name.trim() : fallback, color, this.state.areas.length, now);
    this.state.areas.push(a);
    this.persistArea(a);
    this.pushOp('area', a.id, 'upsert');
    this.emit();
    return a;
  }

  renameArea(id: string, name: string): void {
    const a: Area | null = this.findArea(id);
    if (a === null || name.trim().length === 0) {
      return;
    }
    a.name = name.trim();
    this.touchArea(a);
  }

  archiveArea(id: string): void {
    const a: Area | null = this.findArea(id);
    if (a === null) {
      return;
    }
    a.archived = !a.archived;
    this.touchArea(a);
  }

  deleteArea(id: string): void {
    const a: Area | null = this.findArea(id);
    if (a === null) {
      return;
    }
    const now: number = nowMillis();
    a.deleted = true;
    a.updatedAt = now;
    // 区域下的项目与待办脱离该区域,不随之删除
    for (let i = 0; i < this.state.projects.length; i++) {
      const p: Project = this.state.projects[i];
      if (p.areaId === id) {
        p.areaId = null;
        this.touchProject(p);
      }
    }
    for (let i = 0; i < this.state.todos.length; i++) {
      const t: Todo = this.state.todos[i];
      if (t.areaId === id) {
        t.areaId = null;
        if (t.projectId === null && t.when === 'anytime') {
          t.when = 'inbox';
        }
        this.touchTodo(t);
      }
    }
    this.recordTombstone('area', id, now);
    this.persistArea(a);
    this.pushOp('area', id, 'upsert');
    this.emit();
  }

  /* ============================================================ 标签 */

  /** 标签不存在则自动创建(契约 §5:标签必须已存在,否则自动创建) */
  ensureTag(name: string): Tag {
    const existing: Tag | null = this.findTag(name);
    if (existing !== null) {
      return existing;
    }
    const now: number = nowMillis();
    const t: Tag = newTag(newId(), name, DEFAULT_TAG_COLOR, now);
    this.state.tags.push(t);
    this.persistTag(t);
    this.pushOp('tag', t.id, 'upsert');
    return t;
  }

  setTagColor(name: string, color: string): void {
    const t: Tag | null = this.findTag(name);
    if (t === null) {
      return;
    }
    t.color = color;
    t.updatedAt = nowMillis();
    this.persistTag(t);
    this.pushOp('tag', t.id, 'upsert');
    this.emit();
  }

  deleteTag(id: string): void {
    let name: string = '';
    for (let i = 0; i < this.state.tags.length; i++) {
      if (this.state.tags[i].id === id) {
        name = this.state.tags[i].name;
        this.state.tags.splice(i, 1);
        break;
      }
    }
    if (name.length === 0) {
      return;
    }
    // 契约 §7.3.3:删除标签走实体 op,不靠数组差集;待办上的名字保留(再次使用会自动重建)
    this.recordTombstone('tag', id, nowMillis());
    this.safeStore(this.store.removeTag(id), '标签删除');
    this.pushOp('tag', id, 'delete');
    this.emit();
  }

  /* ============================================================ §3 不变量 */

  /** 规范化:所有写入路径最后都要过一遍(契约 §3 的六条不变量) */
  private normalizeTodo(t: Todo, now: number): void {
    if (t.when === 'date') {
      if (t.date === null || t.date.length !== 10) {
        t.date = todayISO();
      }
    } else {
      t.date = null;
    }
    if (t.headingId !== null) {
      const h: Heading | null = this.findHeading(t.headingId);
      if (h === null || t.projectId === null || h.projectId !== t.projectId) {
        t.headingId = null;
      }
    }
    if (t.reminder !== null) {
      if (t.when === 'inbox' || t.when === 'anytime' || t.when === 'someday') {
        t.when = 'today';
      }
      const base: string = t.when === 'date' && t.date !== null ? t.date : todayISO();
      const hm: string = t.reminder.length >= 16 ? t.reminder.substring(11, 16) : '09:00';
      t.reminder = base + 'T' + hm;
    }
    if (t.projectId !== null && t.when === 'inbox') {
      t.when = 'anytime';
    }
    if (t.updatedAt <= 0) {
      t.updatedAt = now;
    }
  }

  /* ============================================================ 内部写盘 */

  private touchTodo(t: Todo): void {
    t.updatedAt = nowMillis();
    this.normalizeTodo(t, t.updatedAt);
    this.persistTodo(t);
    this.pushOp('todo', t.id, 'upsert');
    this.emit();
  }

  private replaceTodo(id: string, next: Todo): void {
    for (let i = 0; i < this.state.todos.length; i++) {
      if (this.state.todos[i].id === id) {
        this.state.todos[i] = next;
        break;
      }
    }
    this.persistTodo(next);
    this.pushOp('todo', id, 'upsert');
    this.emit();
  }

  private touchProject(p: Project): void {
    p.updatedAt = nowMillis();
    this.persistProject(p);
    this.pushOp('project', p.id, 'upsert');
    this.emit();
  }

  private touchArea(a: Area): void {
    a.updatedAt = nowMillis();
    this.persistArea(a);
    this.pushOp('area', a.id, 'upsert');
    this.emit();
  }

  private nextOrder(when: When, projectId: string | null): number {
    let max: number = -1;
    for (let i = 0; i < this.state.todos.length; i++) {
      const t: Todo = this.state.todos[i];
      const sameList: boolean = projectId !== null ? t.projectId === projectId : t.when === when;
      if (sameList && t.order > max) {
        max = t.order;
      }
    }
    return max + 1;
  }

  /** 统一吞掉本地存储失败:不阻塞 UI,错误只落日志(不打印备注正文与令牌,契约 §9) */
  private safeStore(task: Promise<void>, what: string): void {
    task.catch((e: Error): void => {
      console.error('[OrdoEngine] ' + what + '失败: ' + e.message);
    });
  }

  /** 本地优先:落库失败只记日志(数据仍在内存,后续写操作会重试) */
  private persistTodo(t: Todo): Promise<void> {
    const task: Promise<void> = this.store.saveTodo(t);
    this.safeStore(task, '待办落库');
    return task;
  }

  private persistProject(p: Project): Promise<void> {
    const task: Promise<void> = this.store.saveProject(p);
    this.safeStore(task, '项目落库');
    return task;
  }

  private persistArea(a: Area): Promise<void> {
    const task: Promise<void> = this.store.saveArea(a);
    this.safeStore(task, '区域落库');
    return task;
  }

  private persistHeading(h: Heading): Promise<void> {
    const task: Promise<void> = this.store.saveHeading(h);
    this.safeStore(task, '标题落库');
    return task;
  }

  private persistTag(t: Tag): Promise<void> {
    const task: Promise<void> = this.store.saveTag(t);
    this.safeStore(task, '标签落库');
    return task;
  }

  /* ============================================================ Op 产出 */

  /** 生成一条 upsert/delete Op 并写入 outbox(契约 §7.2) */
  private pushOp(entity: EntityKind, entityId: string, type: OpType): void {
    const op: Op | null = this.buildOpInternal(entity, entityId, type);
    if (op === null) {
      return;
    }
    this.outbox.push(op);
    this.store.appendOutbox(op).catch((e: Error): void => {
      console.error('[OrdoEngine] outbox 写入失败: ' + e.message);
    });
  }

  private entityPayload(entity: EntityKind, entityId: string): string | null {
    if (entity === 'todo') {
      const t: Todo | null = this.findTodo(entityId);
      return t === null ? null : JSON.stringify(t);
    }
    if (entity === 'project') {
      const p: Project | null = this.findProject(entityId);
      return p === null ? null : JSON.stringify(p);
    }
    if (entity === 'area') {
      const a: Area | null = this.findArea(entityId);
      return a === null ? null : JSON.stringify(a);
    }
    if (entity === 'heading') {
      const h: Heading | null = this.findHeading(entityId);
      return h === null ? null : JSON.stringify(h);
    }
    if (entity === 'tag') {
      for (let i = 0; i < this.state.tags.length; i++) {
        if (this.state.tags[i].id === entityId) {
          return JSON.stringify(this.state.tags[i]);
        }
      }
      return null;
    }
    return null;
  }

  private buildOpInternal(entity: EntityKind, entityId: string, type: OpType): Op | null {
    const payload: string | null = type === 'delete' ? null : this.entityPayload(entity, entityId);
    if (type === 'upsert' && payload === null) {
      return null;
    }
    const op: Op = {
      opId: newOpId(),
      deviceId: this.deviceId,
      entity: entity,
      entityId: entityId,
      type: type,
      payload: payload,
      clientTs: nowMillis(),
      seq: null
    };
    return op;
  }

  /* ============================================================ OpSource */

  exportSnapshot(): string {
    const snap: Snapshot = {
      serverSeq: this.lastServerSeq,
      areas: this.state.areas,
      projects: this.state.projects,
      headings: this.allHeadings(),
      todos: this.state.todos,
      tags: this.state.tags
    };
    return JSON.stringify(snap);
  }

  takePendingOps(limit: number): Op[] {
    const max: number = limit > 0 ? limit : 1;
    const out: Op[] = [];
    for (let i = 0; i < this.outbox.length && out.length < max; i++) {
      out.push(this.outbox[i]);
    }
    return out;
  }

  /** 推送成功后确认(契约 §7.1:服务端以 op_id 去重,这里只移除已 accepted 的) */
  confirmPushed(opIds: string[]): void {
    const remain: Op[] = [];
    for (let i = 0; i < this.outbox.length; i++) {
      if (opIds.indexOf(this.outbox[i].opId) < 0) {
        remain.push(this.outbox[i]);
      }
    }
    this.outbox = remain;
    this.store.removeOutbox(opIds).catch((e: Error): void => {
      console.error('[OrdoEngine] outbox 清理失败: ' + e.message);
    });
    this.emit();
  }

  pendingCount(): number {
    return this.outbox.length;
  }

  getLastServerSeq(): number {
    return this.lastServerSeq;
  }

  setLastServerSeq(seq: number): void {
    if (seq <= this.lastServerSeq) {
      return;
    }
    this.lastServerSeq = seq;
    this.store.setKv('lastServerSeq', seq.toString()).catch((e: Error): void => {
      console.error('[OrdoEngine] lastServerSeq 落库失败: ' + e.message);
    });
  }

  listTombstones(): Tombstone[] {
    return this.tombstones;
  }

  buildOp(entity: EntityKind, entityId: string, type: OpType): Op | null {
    return this.buildOpInternal(entity, entityId, type);
  }

  private recordTombstone(entity: EntityKind, entityId: string, now: number): void {
    const ts: Tombstone = newTombstone(entity, entityId, now);
    for (let i = 0; i < this.tombstones.length; i++) {
      const tb: Tombstone = this.tombstones[i];
      if (tb.entity === entity && tb.entityId === entityId) {
        this.tombstones[i] = ts;
        this.safeStore(this.store.saveTombstone(ts), '墓碑落库');
        return;
      }
    }
    this.tombstones.push(ts);
    this.safeStore(this.store.saveTombstone(ts), '墓碑落库');
  }

  private findTombstone(entity: EntityKind, entityId: string): Tombstone | null {
    for (let i = 0; i < this.tombstones.length; i++) {
      const tb: Tombstone = this.tombstones[i];
      if (tb.entity === entity && tb.entityId === entityId) {
        return tb;
      }
    }
    return null;
  }

  /** 清理 30 天前的墓碑(契约 §7.3.5) */
  async pruneTombstones(): Promise<void> {
    const before: number = nowMillis() - TOMBSTONE_TTL_MS;
    const remain: Tombstone[] = [];
    for (let i = 0; i < this.tombstones.length; i++) {
      if (this.tombstones[i].deletedAt >= before) {
        remain.push(this.tombstones[i]);
      }
    }
    this.tombstones = remain;
    await this.store.pruneTombstones(before);
  }

  /* ============================================================ §7.3 合并 */

  /**
   * 应用远端 Op(契约 §7.3 六条规则):
   *  1. 实体级 LWW:clientTs >= 本地 updatedAt 才应用
   *  2. 完成不可回滚
   *  3. 标签取并集(即使 LWW 判 stale 也要并)
   *  4. 清单项按 id 合并
   *  5. 墓碑优先:deletedAt >= op.clientTs 时忽略
   *  6. 标题为空视为删除
   */
  applyRemoteOp(op: Op): ApplyResult {
    const tb: Tombstone | null = this.findTombstone(op.entity, op.entityId);
    if (tb !== null && tb.deletedAt >= op.clientTs) {
      return applyResult('tombstoned', op.entity, op.entityId, '本地墓碑更新,忽略旧 op');
    }
    if (op.type === 'delete') {
      return this.applyRemoteDelete(op);
    }
    if (op.payload === null) {
      return applyResult('invalid', op.entity, op.entityId, 'upsert 缺少 payload');
    }
    if (op.entity === 'todo') {
      return this.applyRemoteTodo(op);
    }
    if (op.entity === 'project') {
      return this.applyRemoteProject(op);
    }
    if (op.entity === 'area') {
      return this.applyRemoteArea(op);
    }
    if (op.entity === 'heading') {
      return this.applyRemoteHeading(op);
    }
    if (op.entity === 'tag') {
      return this.applyRemoteTag(op);
    }
    return applyResult('invalid', op.entity, op.entityId, '未知实体类型');
  }

  private applyRemoteDelete(op: Op): ApplyResult {
    this.recordTombstone(op.entity, op.entityId, op.clientTs);
    if (op.entity === 'todo') {
      const t: Todo | null = this.findTodo(op.entityId);
      if (t === null) {
        return applyResult('applied', op.entity, op.entityId, '本地无此待办,已记墓碑');
      }
      if (op.clientTs < t.updatedAt) {
        return applyResult('stale', op.entity, op.entityId, '本地更新更晚,拒绝远端删除');
      }
      t.deleted = true;
      t.updatedAt = op.clientTs;
      this.persistTodo(t);
      this.emit();
      return applyResult('applied', op.entity, op.entityId, '远端删除已应用');
    }
    if (op.entity === 'project') {
      const p: Project | null = this.findProject(op.entityId);
      if (p === null) {
        return applyResult('applied', op.entity, op.entityId, '本地无此项目,已记墓碑');
      }
      if (op.clientTs < p.updatedAt) {
        return applyResult('stale', op.entity, op.entityId, '本地更新更晚,拒绝远端删除');
      }
      p.deleted = true;
      p.updatedAt = op.clientTs;
      this.persistProject(p);
      this.emit();
      return applyResult('applied', op.entity, op.entityId, '远端删除已应用');
    }
    if (op.entity === 'area') {
      const a: Area | null = this.findArea(op.entityId);
      if (a === null) {
        return applyResult('applied', op.entity, op.entityId, '本地无此区域,已记墓碑');
      }
      if (op.clientTs < a.updatedAt) {
        return applyResult('stale', op.entity, op.entityId, '本地更新更晚,拒绝远端删除');
      }
      a.deleted = true;
      a.updatedAt = op.clientTs;
      this.persistArea(a);
      this.emit();
      return applyResult('applied', op.entity, op.entityId, '远端删除已应用');
    }
    if (op.entity === 'heading') {
      const h: Heading | null = this.findHeading(op.entityId);
      if (h === null) {
        return applyResult('applied', op.entity, op.entityId, '本地无此标题,已记墓碑');
      }
      const owner: Project | null = this.findProject(h.projectId);
      if (owner !== null) {
        for (let i = 0; i < owner.headings.length; i++) {
          if (owner.headings[i].id === h.id) {
            owner.headings.splice(i, 1);
            break;
          }
        }
      }
      this.safeStore(this.store.removeHeading(h.id), '标题删除');
      this.emit();
      return applyResult('applied', op.entity, op.entityId, '标题已删除');
    }
    for (let i = 0; i < this.state.tags.length; i++) {
      if (this.state.tags[i].id === op.entityId) {
        this.state.tags.splice(i, 1);
        this.safeStore(this.store.removeTag(op.entityId), '标签删除');
        this.emit();
        return applyResult('applied', op.entity, op.entityId, '标签已删除');
      }
    }
    return applyResult('applied', op.entity, op.entityId, '本地无此标签,已记墓碑');
  }

  private applyRemoteTodo(op: Op): ApplyResult {
    let remote: Todo | null = null;
    try {
      remote = JSON.parse(op.payload as string) as Todo;
    } catch (e) {
      return applyResult('invalid', op.entity, op.entityId, 'payload 解析失败');
    }
    if (remote === null) {
      return applyResult('invalid', op.entity, op.entityId, 'payload 为空');
    }
    const incoming: Todo = remote;
    const local: Todo | null = this.findTodo(op.entityId);
    if (local === null) {
      this.state.todos.push(incoming);
      this.persistTodo(incoming);
      this.emit();
      return applyResult('applied', op.entity, op.entityId, '新增远端待办');
    }

    // 规则 6:远端标题为空 = 删除
    if (incoming.title.trim().length === 0 && !incoming.deleted) {
      incoming.deleted = true;
    }

    const isStale: boolean = op.clientTs < local.updatedAt;
    const localDone: boolean = local.status === 'done' || local.status === 'canceled';
    const remoteOpen: boolean = incoming.status === 'open';
    const finishedAt: number = local.completedAt !== null ? local.completedAt : local.updatedAt;
    // 规则 2:完成不可回滚
    if (localDone && remoteOpen && op.clientTs < finishedAt) {
      return applyResult('ignored', op.entity, op.entityId, '本地已完成,忽略更早的 open');
    }
    if (isStale) {
      // 规则 3/4:即使 LWW 判 stale,标签仍取并集、清单项仍按 id 合并
      const merged: boolean = this.mergeTagsAndChecklist(local, incoming);
      if (merged) {
        this.persistTodo(local);
        this.emit();
      }
      return applyResult('stale', op.entity, op.entityId, '本地更新更晚,仅合并标签与清单项');
    }

    const applied: Todo = cloneTodo(incoming);
    applied.tags = this.unionTags(local.tags, incoming.tags);
    applied.checklist = this.mergeChecklist(local.checklist, incoming.checklist);
    this.replaceTodoSilently(op.entityId, applied);
    this.persistTodo(applied);
    this.emit();
    return applyResult('applied', op.entity, op.entityId, '远端待办已应用');
  }

  private replaceTodoSilently(id: string, next: Todo): void {
    for (let i = 0; i < this.state.todos.length; i++) {
      if (this.state.todos[i].id === id) {
        this.state.todos[i] = next;
        return;
      }
    }
  }

  /** 规则 3:标签取并集;并集中新出现的标签自动创建实体 */
  private unionTags(a: string[], b: string[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < a.length; i++) {
      if (out.indexOf(a[i]) < 0) {
        out.push(a[i]);
      }
    }
    for (let i = 0; i < b.length; i++) {
      if (out.indexOf(b[i]) < 0) {
        out.push(b[i]);
        this.ensureTag(b[i]);
      }
    }
    return out;
  }

  /** 规则 4:按 checklist[].id 合并;两端都有的取 winner(本实体 LWW 结果),仅一端有的保留 */
  private mergeChecklist(local: ChecklistItem[], remote: ChecklistItem[]): ChecklistItem[] {
    const out: ChecklistItem[] = [];
    for (let i = 0; i < remote.length; i++) {
      const c: ChecklistItem = { id: remote[i].id, title: remote[i].title, done: remote[i].done };
      out.push(c);
    }
    for (let i = 0; i < local.length; i++) {
      let found: boolean = false;
      for (let k = 0; k < out.length; k++) {
        if (out[k].id === local[i].id) {
          found = true;
          break;
        }
      }
      if (!found) {
        const c: ChecklistItem = { id: local[i].id, title: local[i].title, done: local[i].done };
        out.push(c);
      }
    }
    return out;
  }

  /** stale 分支:只并标签、补远端独有清单项,不动本地其它字段 */
  private mergeTagsAndChecklist(local: Todo, remote: Todo): boolean {
    let changed: boolean = false;
    const tags: string[] = this.unionTags(local.tags, remote.tags);
    if (tags.length !== local.tags.length) {
      local.tags = tags;
      changed = true;
    }
    for (let i = 0; i < remote.checklist.length; i++) {
      const item: ChecklistItem = remote.checklist[i];
      let found: boolean = false;
      for (let k = 0; k < local.checklist.length; k++) {
        if (local.checklist[k].id === item.id) {
          found = true;
          break;
        }
      }
      if (!found) {
        const c: ChecklistItem = { id: item.id, title: item.title, done: item.done };
        local.checklist.push(c);
        changed = true;
      }
    }
    return changed;
  }

  private applyRemoteProject(op: Op): ApplyResult {
    let remote: Project | null = null;
    try {
      remote = JSON.parse(op.payload as string) as Project;
    } catch (e) {
      return applyResult('invalid', op.entity, op.entityId, 'payload 解析失败');
    }
    if (remote === null) {
      return applyResult('invalid', op.entity, op.entityId, 'payload 为空');
    }
    const incoming: Project = remote;
    const local: Project | null = this.findProject(op.entityId);
    if (local === null) {
      this.state.projects.push(incoming);
      this.persistProject(incoming);
      const hs: Heading[] = incoming.headings !== null && incoming.headings !== undefined ? incoming.headings : [];
      for (let i = 0; i < hs.length; i++) {
        this.persistHeading(hs[i]);
      }
      this.emit();
      return applyResult('applied', op.entity, op.entityId, '新增远端项目');
    }
    if (op.clientTs < local.updatedAt) {
      return applyResult('stale', op.entity, op.entityId, '本地项目更新更晚');
    }
    const mergedTags: string[] = this.unionTags(local.tags, incoming.tags);
    const incomingHeadings: Heading[] = incoming.headings !== null && incoming.headings !== undefined ? incoming.headings : [];
    const headings: Heading[] = incomingHeadings.length > 0 ? incomingHeadings : local.headings;
    const next: Project = cloneProject(incoming);
    next.tags = mergedTags;
    next.headings = headings;
    for (let i = 0; i < this.state.projects.length; i++) {
      if (this.state.projects[i].id === op.entityId) {
        this.state.projects[i] = next;
        break;
      }
    }
    this.persistProject(next);
    for (let i = 0; i < headings.length; i++) {
      this.persistHeading(headings[i]);
    }
    this.emit();
    return applyResult('applied', op.entity, op.entityId, '远端项目已应用');
  }

  private applyRemoteArea(op: Op): ApplyResult {
    let remote: Area | null = null;
    try {
      remote = JSON.parse(op.payload as string) as Area;
    } catch (e) {
      return applyResult('invalid', op.entity, op.entityId, 'payload 解析失败');
    }
    if (remote === null) {
      return applyResult('invalid', op.entity, op.entityId, 'payload 为空');
    }
    const incoming: Area = remote;
    const local: Area | null = this.findArea(op.entityId);
    if (local === null) {
      this.state.areas.push(incoming);
      this.persistArea(incoming);
      this.emit();
      return applyResult('applied', op.entity, op.entityId, '新增远端区域');
    }
    if (op.clientTs < local.updatedAt) {
      return applyResult('stale', op.entity, op.entityId, '本地区域更新更晚');
    }
    const next: Area = cloneArea(incoming);
    for (let i = 0; i < this.state.areas.length; i++) {
      if (this.state.areas[i].id === op.entityId) {
        this.state.areas[i] = next;
        break;
      }
    }
    this.persistArea(next);
    this.emit();
    return applyResult('applied', op.entity, op.entityId, '远端区域已应用');
  }

  private applyRemoteHeading(op: Op): ApplyResult {
    let remote: Heading | null = null;
    try {
      remote = JSON.parse(op.payload as string) as Heading;
    } catch (e) {
      return applyResult('invalid', op.entity, op.entityId, 'payload 解析失败');
    }
    if (remote === null) {
      return applyResult('invalid', op.entity, op.entityId, 'payload 为空');
    }
    const incoming: Heading = remote;
    const local: Heading | null = this.findHeading(op.entityId);
    if (local !== null && op.clientTs < local.updatedAt) {
      return applyResult('stale', op.entity, op.entityId, '本地标题更新更晚');
    }
    const owner: Project | null = this.findProject(incoming.projectId);
    if (owner === null) {
      return applyResult('ignored', op.entity, op.entityId, '所属项目不存在');
    }
    for (let i = 0; i < this.state.projects.length; i++) {
      const list: Heading[] = this.state.projects[i].headings;
      for (let k = 0; k < list.length; k++) {
        if (list[k].id === incoming.id) {
          list.splice(k, 1);
          break;
        }
      }
    }
    const next: Heading = cloneHeading(incoming);
    if (local !== null) {
      // collapsed 是设备本地 UI 状态,保留本地值(契约 §2.3)
      next.collapsed = local.collapsed;
    }
    owner.headings.push(next);
    this.persistHeading(next);
    this.emit();
    return applyResult('applied', op.entity, op.entityId, '远端标题已应用');
  }

  private applyRemoteTag(op: Op): ApplyResult {
    let remote: Tag | null = null;
    try {
      remote = JSON.parse(op.payload as string) as Tag;
    } catch (e) {
      return applyResult('invalid', op.entity, op.entityId, 'payload 解析失败');
    }
    if (remote === null) {
      return applyResult('invalid', op.entity, op.entityId, 'payload 为空');
    }
    const incoming: Tag = remote;
    for (let i = 0; i < this.state.tags.length; i++) {
      const local: Tag = this.state.tags[i];
      if (local.id === incoming.id) {
        if (op.clientTs < local.updatedAt) {
          return applyResult('stale', op.entity, op.entityId, '本地标签更新更晚');
        }
        this.state.tags[i] = cloneTag(incoming);
        this.persistTag(this.state.tags[i]);
        this.emit();
        return applyResult('applied', op.entity, op.entityId, '远端标签已应用');
      }
    }
    this.state.tags.push(cloneTag(incoming));
    this.persistTag(incoming);
    this.emit();
    return applyResult('applied', op.entity, op.entityId, '新增远端标签');
  }

  /* ============================================================ 快照导入 */

  /** 全量快照覆盖(首次同步 / SEQ_GAP 重拉时使用,契约 §7.4) */
  async applySnapshot(json: string): Promise<boolean> {
    let snap: Snapshot | null = null;
    try {
      snap = JSON.parse(json) as Snapshot;
    } catch (e) {
      return false;
    }
    if (snap === null) {
      return false;
    }
    const s: Snapshot = snap;
    const projects: Project[] = s.projects !== null && s.projects !== undefined ? s.projects : [];
    for (let i = 0; i < projects.length; i++) {
      projects[i].headings = [];
    }
    const headings: Heading[] = s.headings !== null && s.headings !== undefined ? s.headings : [];
    for (let i = 0; i < headings.length; i++) {
      const h: Heading = headings[i];
      for (let p = 0; p < projects.length; p++) {
        if (projects[p].id === h.projectId) {
          projects[p].headings.push(h);
          break;
        }
      }
    }
    const next: OrdoState = {
      areas: s.areas !== null && s.areas !== undefined ? s.areas : [],
      projects: projects,
      todos: s.todos !== null && s.todos !== undefined ? s.todos : [],
      tags: s.tags !== null && s.tags !== undefined ? s.tags : [],
      events: []
    };
    await this.persistAll(next);
    this.setLastServerSeq(s.serverSeq);
    return true;
  }

  /** 导出为可读 JSON(设置页「导出数据」用) */
  exportJson(): string {
    return this.exportSnapshot();
  }

  /** 当前设备 id(展示用) */
  getDeviceId(): string {
    return this.deviceId;
  }

  /** 拉取上限(契约 §7.4) */
  static pullLimit(): number {
    return MAX_PULL_LIMIT;
  }

  /** 状态栏统计文案 */
  stats(): string {
    let done: number = 0;
    let open: number = 0;
    for (let i = 0; i < this.state.todos.length; i++) {
      const t: Todo = this.state.todos[i];
      if (t.deleted) {
        continue;
      }
      if (t.status === 'done') {
        done++;
      } else if (t.status === 'open') {
        open++;
      }
    }
    return '共 ' + (done + open).toString() + ' 项 · 已完成 ' + done.toString() + ' 项';
  }

  /** 取第一条指定状态的待办(测试与自动化用) */
  firstWithStatus(status: Status): Todo | null {
    for (let i = 0; i < this.state.todos.length; i++) {
      const t: Todo = this.state.todos[i];
      if (t.status === status && !t.deleted) {
        return t;
      }
    }
    return null;
  }
}
