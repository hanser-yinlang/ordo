/**
 * Ordo · 内存存储实现
 * 契约来源:docs/03-数据模型与同步协议.md §8(客户端存储)
 *
 * 用途:
 *  1. ohosTest 单元测试(不需要设备数据库)
 *  2. RDB 初始化失败时的降级(数据仅存活于本次运行)
 * 语义与 RelationalStore.ets 完全一致,方便两端互换。
 */

import {
  Area,
  Heading,
  Op,
  OrdoState,
  Project,
  Tag,
  Tombstone,
  Todo,
  cloneArea,
  cloneHeading,
  cloneProject,
  cloneTag,
  cloneTodo
} from '../model/Entities.ets';
import { OrdoStore, StorageSnapshot } from './OrdoStore.ets';

export class MemoryOrdoStore implements OrdoStore {
  private areas: Area[];
  private projects: Project[];
  private headings: Heading[];
  private todos: Todo[];
  private tags: Tag[];
  private outbox: Op[];
  private tombstones: Tombstone[];
  private kv: Map<string, string>;

  constructor(seed?: OrdoState) {
    this.areas = [];
    this.projects = [];
    this.headings = [];
    this.todos = [];
    this.tags = [];
    this.outbox = [];
    this.tombstones = [];
    this.kv = new Map<string, string>();
    if (seed !== undefined) {
      for (let i = 0; i < seed.areas.length; i++) {
        this.areas.push(cloneArea(seed.areas[i]));
      }
      for (let i = 0; i < seed.projects.length; i++) {
        const p: Project = cloneProject(seed.projects[i]);
        this.projects.push(p);
        for (let h = 0; h < p.headings.length; h++) {
          this.headings.push(cloneHeading(p.headings[h]));
        }
      }
      for (let i = 0; i < seed.todos.length; i++) {
        this.todos.push(cloneTodo(seed.todos[i]));
      }
      for (let i = 0; i < seed.tags.length; i++) {
        this.tags.push(cloneTag(seed.tags[i]));
      }
    }
  }

  async init(): Promise<void> {
    // 内存实现无需初始化
  }

  /* ---------------------------------------------------------------- 读取 */

  async loadAreas(): Promise<Area[]> {
    const out: Area[] = [];
    for (let i = 0; i < this.areas.length; i++) {
      out.push(cloneArea(this.areas[i]));
    }
    return out;
  }

  async loadProjects(): Promise<Project[]> {
    const out: Project[] = [];
    for (let i = 0; i < this.projects.length; i++) {
      const p: Project = cloneProject(this.projects[i]);
      p.headings = []; // 规范来源是 headings 表,由引擎装配
      out.push(p);
    }
    return out;
  }

  async loadHeadings(): Promise<Heading[]> {
    const out: Heading[] = [];
    for (let i = 0; i < this.headings.length; i++) {
      out.push(cloneHeading(this.headings[i]));
    }
    return out;
  }

  async loadTodos(): Promise<Todo[]> {
    const out: Todo[] = [];
    for (let i = 0; i < this.todos.length; i++) {
      out.push(cloneTodo(this.todos[i]));
    }
    return out;
  }

  async loadTags(): Promise<Tag[]> {
    const out: Tag[] = [];
    for (let i = 0; i < this.tags.length; i++) {
      out.push(cloneTag(this.tags[i]));
    }
    return out;
  }

  /* ---------------------------------------------------------------- 写入 */

  async saveArea(a: Area): Promise<void> {
    for (let i = 0; i < this.areas.length; i++) {
      if (this.areas[i].id === a.id) {
        this.areas[i] = cloneArea(a);
        return;
      }
    }
    this.areas.push(cloneArea(a));
  }

  async saveProject(p: Project): Promise<void> {
    for (let i = 0; i < this.projects.length; i++) {
      if (this.projects[i].id === p.id) {
        const stored: Project = cloneProject(p);
        stored.headings = []; // 标题单独存表
        this.projects[i] = stored;
        return;
      }
    }
    const stored: Project = cloneProject(p);
    stored.headings = [];
    this.projects.push(stored);
  }

  async saveHeading(h: Heading): Promise<void> {
    for (let i = 0; i < this.headings.length; i++) {
      if (this.headings[i].id === h.id) {
        this.headings[i] = cloneHeading(h);
        return;
      }
    }
    this.headings.push(cloneHeading(h));
  }

  async saveTodo(t: Todo): Promise<void> {
    for (let i = 0; i < this.todos.length; i++) {
      if (this.todos[i].id === t.id) {
        this.todos[i] = cloneTodo(t);
        return;
      }
    }
    this.todos.push(cloneTodo(t));
  }

  async saveTag(t: Tag): Promise<void> {
    for (let i = 0; i < this.tags.length; i++) {
      if (this.tags[i].id === t.id) {
        this.tags[i] = cloneTag(t);
        return;
      }
    }
    this.tags.push(cloneTag(t));
  }

  async removeHeading(id: string): Promise<void> {
    const remain: Heading[] = [];
    for (let i = 0; i < this.headings.length; i++) {
      if (this.headings[i].id !== id) {
        remain.push(this.headings[i]);
      }
    }
    this.headings = remain;
  }

  async removeTag(id: string): Promise<void> {
    const remain: Tag[] = [];
    for (let i = 0; i < this.tags.length; i++) {
      if (this.tags[i].id !== id) {
        remain.push(this.tags[i]);
      }
    }
    this.tags = remain;
  }

  async clearEntities(): Promise<void> {
    this.areas = [];
    this.projects = [];
    this.headings = [];
    this.todos = [];
    this.tags = [];
  }

  /** 快照对账(语义与 RelationalStore.saveSnapshot 一致) */
  async saveSnapshot(snapshot: StorageSnapshot): Promise<void> {
    this.areas = [];
    for (let i = 0; i < snapshot.areas.length; i++) {
      this.areas.push(cloneArea(snapshot.areas[i]));
    }
    this.projects = [];
    for (let i = 0; i < snapshot.projects.length; i++) {
      const p: Project = cloneProject(snapshot.projects[i]);
      p.headings = []; // 标题单独存表
      this.projects.push(p);
    }
    this.headings = [];
    for (let i = 0; i < snapshot.headings.length; i++) {
      this.headings.push(cloneHeading(snapshot.headings[i]));
    }
    this.todos = [];
    for (let i = 0; i < snapshot.todos.length; i++) {
      this.todos.push(cloneTodo(snapshot.todos[i]));
    }
    this.tags = [];
    for (let i = 0; i < snapshot.tags.length; i++) {
      this.tags.push(cloneTag(snapshot.tags[i]));
    }
  }

  /* -------------------------------------------------------------- outbox */

  async loadOutbox(): Promise<Op[]> {
    const out: Op[] = [];
    for (let i = 0; i < this.outbox.length; i++) {
      out.push(this.outbox[i]);
    }
    return out;
  }

  async appendOutbox(op: Op): Promise<void> {
    for (let i = 0; i < this.outbox.length; i++) {
      if (this.outbox[i].opId === op.opId) {
        return; // 幂等:同一 opId 只存一份
      }
    }
    this.outbox.push(op);
  }

  async removeOutbox(opIds: string[]): Promise<void> {
    const remain: Op[] = [];
    for (let i = 0; i < this.outbox.length; i++) {
      if (opIds.indexOf(this.outbox[i].opId) < 0) {
        remain.push(this.outbox[i]);
      }
    }
    this.outbox = remain;
  }

  async outboxCount(): Promise<number> {
    return this.outbox.length;
  }

  /* ------------------------------------------------------------ tombstones */

  async loadTombstones(): Promise<Tombstone[]> {
    const out: Tombstone[] = [];
    for (let i = 0; i < this.tombstones.length; i++) {
      out.push(this.tombstones[i]);
    }
    return out;
  }

  async saveTombstone(t: Tombstone): Promise<void> {
    for (let i = 0; i < this.tombstones.length; i++) {
      const cur: Tombstone = this.tombstones[i];
      if (cur.entity === t.entity && cur.entityId === t.entityId) {
        this.tombstones[i] = t;
        return;
      }
    }
    this.tombstones.push(t);
  }

  async pruneTombstones(beforeMs: number): Promise<void> {
    const remain: Tombstone[] = [];
    for (let i = 0; i < this.tombstones.length; i++) {
      if (this.tombstones[i].deletedAt >= beforeMs) {
        remain.push(this.tombstones[i]);
      }
    }
    this.tombstones = remain;
  }

  /* -------------------------------------------------------------------- kv */

  async getKv(key: string): Promise<string | null> {
    if (this.kv.has(key)) {
      return this.kv.get(key) as string;
    }
    return null;
  }

  async setKv(key: string, value: string): Promise<void> {
    this.kv.set(key, value);
  }

  async removeKv(key: string): Promise<void> {
    this.kv.delete(key);
  }

  /* --------------------------------------------------------------- 测试辅助 */

  /** 仅供测试:直接读取(不复制) */
  rawTodos(): Todo[] {
    return this.todos;
  }

  /** 仅供测试:kv 快照 */
  kvSnapshot(): Map<string, string> {
    return this.kv;
  }
}
