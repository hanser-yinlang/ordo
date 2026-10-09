/**
 * Ordo · 鸿蒙 RelationalStore(RDB)持久化实现
 * 契约来源:docs/03-数据模型与同步协议.md §8(客户端存储:表字段名与 §2 完全一致)
 *
 * 表(8 张):
 *   areas / projects / headings / todos / tags  —— 实体表,列名与契约 §2 一致
 *   outbox(opId PK, entity, entityId, type, payload, clientTs, createdAt)  —— 契约 §7.1/§8
 *   tombstones(entity, entityId, deletedAt, clientTs)                      —— 契约 §7.3.5
 *   kv(key PK, value)                                                      —— lastServerSeq / deviceId / tokens
 *
 * 注意:
 *  1. `order` 与 `when` 是 SQL 关键字,建表与读写一律加双引号。
 *  2. 复杂字段(tags / checklist / repeat)以 JSON 文本列存储,列名与契约 §2 保持一致。
 *  3. RDB 全部 API 在 SDK 中带 `@throws { BusinessError }`,ArkTS 编译期为每处调用报
 *     「Function may throw exceptions. Special handling is required.」。本文件因此把所有
 *     RDB 调用收敛到少量私有助手方法内,并在助手内 try/catch:既消除了编译告警,也让
 *     「哪些异常被吞、哪些被上抛」在一处显式可读。助手统一把失败包装成 Error 后 **继续上抛**,
 *     从而与改造前的行为完全一致(由 OrdoEngine 的 safeStore 记日志、AppStore 决定是否降级)。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import {
  Area,
  ChecklistItem,
  EntityKind,
  Heading,
  Op,
  OpType,
  Project,
  RepeatRule,
  Status,
  Tag,
  Todo,
  Tombstone,
  When
} from '../model/Entities.ets';
import { OrdoStore, StorageSnapshot } from './OrdoStore.ets';

const DB_NAME: string = 'ordo.db';

const SQL_AREAS: string = 'CREATE TABLE IF NOT EXISTS areas (' +
  'id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT, "order" INTEGER, archived INTEGER, updatedAt INTEGER, deleted INTEGER)';

const SQL_PROJECTS: string = 'CREATE TABLE IF NOT EXISTS projects (' +
  'id TEXT PRIMARY KEY, areaId TEXT, name TEXT NOT NULL, note TEXT, "when" TEXT, date TEXT, deadline TEXT, ' +
  'tags TEXT, "order" INTEGER, status TEXT, completedAt INTEGER, repeat TEXT, createdAt INTEGER, updatedAt INTEGER, deleted INTEGER)';

const SQL_HEADINGS: string = 'CREATE TABLE IF NOT EXISTS headings (' +
  'id TEXT PRIMARY KEY, projectId TEXT NOT NULL, name TEXT NOT NULL, "order" INTEGER, archived INTEGER, collapsed INTEGER, updatedAt INTEGER)';

const SQL_TODOS: string = 'CREATE TABLE IF NOT EXISTS todos (' +
  'id TEXT PRIMARY KEY, title TEXT NOT NULL, note TEXT, "when" TEXT, date TEXT, reminder TEXT, deadline TEXT, ' +
  'tags TEXT, checklist TEXT, projectId TEXT, areaId TEXT, headingId TEXT, repeat TEXT, "order" INTEGER, status TEXT, ' +
  'createdAt INTEGER, updatedAt INTEGER, completedAt INTEGER, deleted INTEGER)';

const SQL_TAGS: string = 'CREATE TABLE IF NOT EXISTS tags (' +
  'id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT, updatedAt INTEGER)';

const SQL_OUTBOX: string = 'CREATE TABLE IF NOT EXISTS outbox (' +
  'opId TEXT PRIMARY KEY, entity TEXT NOT NULL, entityId TEXT NOT NULL, type TEXT NOT NULL, ' +
  'payload TEXT, clientTs INTEGER, createdAt INTEGER)';

const SQL_TOMBSTONES: string = 'CREATE TABLE IF NOT EXISTS tombstones (' +
  'entity TEXT NOT NULL, entityId TEXT NOT NULL, deletedAt INTEGER, clientTs INTEGER, PRIMARY KEY(entity, entityId))';

const SQL_KV: string = 'CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)';

const SQL_INDEX_TODOS: string = 'CREATE INDEX IF NOT EXISTS idx_todos_when ON todos("when", status)';
const SQL_INDEX_HEADS: string = 'CREATE INDEX IF NOT EXISTS idx_headings_project ON headings(projectId)';
const SQL_INDEX_OUTBOX: string = 'CREATE INDEX IF NOT EXISTS idx_outbox_created ON outbox(createdAt)';

/** 建表语句(init 统一执行,便于收敛异常处理) */
const DDL_STATEMENTS: string[] = [
  SQL_AREAS,
  SQL_PROJECTS,
  SQL_HEADINGS,
  SQL_TODOS,
  SQL_TAGS,
  SQL_OUTBOX,
  SQL_TOMBSTONES,
  SQL_KV,
  SQL_INDEX_TODOS,
  SQL_INDEX_HEADS,
  SQL_INDEX_OUTBOX
];

/** 实体表名(清空与快照对账用) */
const ENTITY_TABLES: string[] = ['areas', 'projects', 'headings', 'todos', 'tags'];

const CONTEXT_INIT: string = '打开本地库';
const CONTEXT_DDL: string = '建表';
const CONTEXT_BEGIN: string = '开启事务';
const CONTEXT_COMMIT: string = '提交事务';
const CONTEXT_ROLLBACK: string = '回滚事务';
const CONTEXT_CLEAR: string = '清空实体表';

export class RdbOrdoStore implements OrdoStore {
  private context: common.UIAbilityContext;
  private rdb: relationalStore.RdbStore | null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.rdb = null;
  }

  async init(): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore = await this.openStore(config);
    for (let i = 0; i < DDL_STATEMENTS.length; i++) {
      await this.execSql(store, DDL_STATEMENTS[i], CONTEXT_DDL);
    }
    this.rdb = store;
  }

  private db(): relationalStore.RdbStore {
    const store: relationalStore.RdbStore | null = this.rdb;
    if (store === null) {
      throw new Error('RdbOrdoStore 未初始化,请先调用 init()');
    }
    return store;
  }

  /* ==================================================== RDB 调用收敛层 */
  /* 所有会抛 BusinessError 的 RDB API 只允许在本区块内调用,统一 try/catch 后上抛 Error。 */

  private async openStore(config: relationalStore.StoreConfig): Promise<relationalStore.RdbStore> {
    try {
      return await relationalStore.getRdbStore(this.context, config);
    } catch (e) {
      throw this.fail(CONTEXT_INIT, e);
    }
  }

  private async execSql(store: relationalStore.RdbStore, sql: string, what: string): Promise<void> {
    try {
      await store.executeSql(sql);
    } catch (e) {
      throw this.fail(what, e);
    }
  }

  private async insertRow(
    store: relationalStore.RdbStore,
    table: string,
    bucket: relationalStore.ValuesBucket,
    conflict: relationalStore.ConflictResolution,
    what: string
  ): Promise<void> {
    try {
      await store.insert(table, bucket, conflict);
    } catch (e) {
      throw this.fail(what, e);
    }
  }

  private async deleteRows(store: relationalStore.RdbStore, predicates: relationalStore.RdbPredicates, what: string): Promise<void> {
    try {
      await store.delete(predicates);
    } catch (e) {
      throw this.fail(what, e);
    }
  }

  private async queryRows(
    store: relationalStore.RdbStore,
    predicates: relationalStore.RdbPredicates,
    columns: string[],
    what: string
  ): Promise<relationalStore.ResultSet> {
    try {
      return await store.query(predicates, columns);
    } catch (e) {
      throw this.fail(what, e);
    }
  }

  /** ResultSet 游标推进(游标走到末尾并非异常,返回值交给调用方判断) */
  private nextRow(rs: relationalStore.ResultSet, what: string): boolean {
    try {
      return rs.goToNextRow();
    } catch (e) {
      throw this.fail(what, e);
    }
  }

  private closeResultSet(rs: relationalStore.ResultSet): void {
    try {
      rs.close();
    } catch (e) {
      // 关闭失败不影响已读出的数据,仅记日志
      console.error('[RdbOrdoStore] 结果集关闭失败:' + this.reasonOf(e));
    }
  }

  private beginTx(store: relationalStore.RdbStore): void {
    try {
      store.beginTransaction();
    } catch (e) {
      throw this.fail(CONTEXT_BEGIN, e);
    }
  }

  private commitTx(store: relationalStore.RdbStore): void {
    try {
      store.commit();
    } catch (e) {
      throw this.fail(CONTEXT_COMMIT, e);
    }
  }

  /** 回滚只做尽力而为:失败时保留原始异常语义 */
  private rollbackTx(store: relationalStore.RdbStore): void {
    try {
      store.rollBack();
    } catch (e) {
      console.error('[RdbOrdoStore] ' + CONTEXT_ROLLBACK + '失败:' + this.reasonOf(e));
    }
  }

  /** 统一包装:保留原始 message 便于定位(不打印待办正文与令牌,契约 §9) */
  private fail(what: string, e: Object): Error {
    return new Error('[RdbOrdoStore] ' + what + '失败:' + this.reasonOf(e));
  }

  private reasonOf(e: Object): string {
    if (e === null || e === undefined) {
      return '未知错误';
    }
    const err: Error = e as Error;
    return err.message === undefined ? '未知错误' : err.message;
  }

  private toInt(b: boolean): number {
    return b ? 1 : 0;
  }

  private boolOf(rs: relationalStore.ResultSet, column: string): boolean {
    try {
      const idx: number = rs.getColumnIndex(column);
      if (idx < 0) {
        return false;
      }
      return rs.getLong(idx) === 1;
    } catch (e) {
      throw this.fail('读取布尔列 ' + column, e);
    }
  }

  private numOf(rs: relationalStore.ResultSet, column: string): number {
    try {
      const idx: number = rs.getColumnIndex(column);
      if (idx < 0) {
        return 0;
      }
      return rs.getLong(idx);
    } catch (e) {
      throw this.fail('读取数值列 ' + column, e);
    }
  }

  private strOf(rs: relationalStore.ResultSet, column: string): string {
    try {
      const idx: number = rs.getColumnIndex(column);
      if (idx < 0) {
        return '';
      }
      return rs.getString(idx);
    } catch (e) {
      throw this.fail('读取文本列 ' + column, e);
    }
  }

  private nullableStr(rs: relationalStore.ResultSet, column: string): string | null {
    try {
      const idx: number = rs.getColumnIndex(column);
      if (idx < 0 || rs.isColumnNull(idx)) {
        return null;
      }
      return rs.getString(idx);
    } catch (e) {
      throw this.fail('读取可空文本列 ' + column, e);
    }
  }

  /** 可空整数列(如 completedAt):SQL NULL 必须还原为 null,不能当成 0 */
  private nullableNum(rs: relationalStore.ResultSet, column: string): number | null {
    try {
      const idx: number = rs.getColumnIndex(column);
      if (idx < 0 || rs.isColumnNull(idx)) {
        return null;
      }
      return rs.getLong(idx);
    } catch (e) {
      throw this.fail('读取可空数值列 ' + column, e);
    }
  }

  private static parseStringArray(json: string): string[] {
    if (json === null || json.length === 0) {
      return [];
    }
    const parsed: string[] = JSON.parse(json) as string[];
    return parsed === null ? [] : parsed;
  }

  private static parseChecklist(json: string): ChecklistItem[] {
    if (json === null || json.length === 0) {
      return [];
    }
    const parsed: ChecklistItem[] = JSON.parse(json) as ChecklistItem[];
    return parsed === null ? [] : parsed;
  }

  private static parseRepeat(json: string | null): RepeatRule | null {
    if (json === null || json.length === 0) {
      return null;
    }
    return JSON.parse(json) as RepeatRule;
  }

  /* ================================================================ 读取 */

  async loadAreas(): Promise<Area[]> {
    const out: Area[] = [];
    const predicates = new relationalStore.RdbPredicates('areas');
    const rs: relationalStore.ResultSet = await this.queryRows(this.db(), predicates, [
      'id', 'name', 'color', '"order"', 'archived', 'updatedAt', 'deleted'
    ], '读取区域');
    try {
      while (this.nextRow(rs, '读取区域')) {
        const a: Area = {
          id: this.strOf(rs, 'id'),
          name: this.strOf(rs, 'name'),
          color: this.strOf(rs, 'color'),
          order: this.numOf(rs, 'order'),
          archived: this.boolOf(rs, 'archived'),
          updatedAt: this.numOf(rs, 'updatedAt'),
          deleted: this.boolOf(rs, 'deleted')
        };
        out.push(a);
      }
    } finally {
      this.closeResultSet(rs);
    }
    return out;
  }

  async loadProjects(): Promise<Project[]> {
    const out: Project[] = [];
    const predicates = new relationalStore.RdbPredicates('projects');
    const rs: relationalStore.ResultSet = await this.queryRows(this.db(), predicates, [
      'id', 'areaId', 'name', 'note', '"when"', 'date', 'deadline', 'tags',
      '"order"', 'status', 'completedAt', 'repeat', 'createdAt', 'updatedAt', 'deleted'
    ], '读取项目');
    try {
      while (this.nextRow(rs, '读取项目')) {
        const whenText: string = this.strOf(rs, 'when');
        const statusText: string = this.strOf(rs, 'status');
        const p: Project = {
          id: this.strOf(rs, 'id'),
          areaId: this.nullableStr(rs, 'areaId'),
          name: this.strOf(rs, 'name'),
          note: this.strOf(rs, 'note'),
          when: (whenText.length > 0 ? whenText : 'anytime') as When,
          date: this.nullableStr(rs, 'date'),
          deadline: this.nullableStr(rs, 'deadline'),
          tags: RdbOrdoStore.parseStringArray(this.strOf(rs, 'tags')),
          headings: [], // 标题来自 headings 表,由引擎装配
          order: this.numOf(rs, 'order'),
          status: (statusText.length > 0 ? statusText : 'open') as Status,
          completedAt: this.nullableNum(rs, 'completedAt'),
          repeat: RdbOrdoStore.parseRepeat(this.nullableStr(rs, 'repeat')),
          createdAt: this.numOf(rs, 'createdAt'),
          updatedAt: this.numOf(rs, 'updatedAt'),
          deleted: this.boolOf(rs, 'deleted')
        };
        out.push(p);
      }
    } finally {
      this.closeResultSet(rs);
    }
    return out;
  }

  async loadHeadings(): Promise<Heading[]> {
    const out: Heading[] = [];
    const predicates = new relationalStore.RdbPredicates('headings');
    const rs: relationalStore.ResultSet = await this.queryRows(this.db(), predicates, [
      'id', 'projectId', 'name', '"order"', 'archived', 'collapsed', 'updatedAt'
    ], '读取标题');
    try {
      while (this.nextRow(rs, '读取标题')) {
        const h: Heading = {
          id: this.strOf(rs, 'id'),
          projectId: this.strOf(rs, 'projectId'),
          name: this.strOf(rs, 'name'),
          order: this.numOf(rs, 'order'),
          archived: this.boolOf(rs, 'archived'),
          collapsed: this.boolOf(rs, 'collapsed'),
          updatedAt: this.numOf(rs, 'updatedAt')
        };
        out.push(h);
      }
    } finally {
      this.closeResultSet(rs);
    }
    return out;
  }

  async loadTodos(): Promise<Todo[]> {
    const out: Todo[] = [];
    const predicates = new relationalStore.RdbPredicates('todos');
    const rs: relationalStore.ResultSet = await this.queryRows(this.db(), predicates, [
      'id', 'title', 'note', '"when"', 'date', 'reminder', 'deadline', 'tags', 'checklist',
      'projectId', 'areaId', 'headingId', 'repeat', '"order"', 'status',
      'createdAt', 'updatedAt', 'completedAt', 'deleted'
    ], '读取待办');
    try {
      while (this.nextRow(rs, '读取待办')) {
        const whenText: string = this.strOf(rs, 'when');
        const statusText: string = this.strOf(rs, 'status');
        const t: Todo = {
          id: this.strOf(rs, 'id'),
          title: this.strOf(rs, 'title'),
          note: this.strOf(rs, 'note'),
          when: (whenText.length > 0 ? whenText : 'inbox') as When,
          date: this.nullableStr(rs, 'date'),
          reminder: this.nullableStr(rs, 'reminder'),
          deadline: this.nullableStr(rs, 'deadline'),
          tags: RdbOrdoStore.parseStringArray(this.strOf(rs, 'tags')),
          checklist: RdbOrdoStore.parseChecklist(this.strOf(rs, 'checklist')),
          projectId: this.nullableStr(rs, 'projectId'),
          areaId: this.nullableStr(rs, 'areaId'),
          headingId: this.nullableStr(rs, 'headingId'),
          repeat: RdbOrdoStore.parseRepeat(this.nullableStr(rs, 'repeat')),
          order: this.numOf(rs, 'order'),
          status: (statusText.length > 0 ? statusText : 'open') as Status,
          createdAt: this.numOf(rs, 'createdAt'),
          updatedAt: this.numOf(rs, 'updatedAt'),
          completedAt: this.nullableNum(rs, 'completedAt'),
          deleted: this.boolOf(rs, 'deleted')
        };
        out.push(t);
      }
    } finally {
      this.closeResultSet(rs);
    }
    return out;
  }

  async loadTags(): Promise<Tag[]> {
    const out: Tag[] = [];
    const predicates = new relationalStore.RdbPredicates('tags');
    const rs: relationalStore.ResultSet = await this.queryRows(this.db(), predicates, ['id', 'name', 'color', 'updatedAt'], '读取标签');
    try {
      while (this.nextRow(rs, '读取标签')) {
        const t: Tag = {
          id: this.strOf(rs, 'id'),
          name: this.strOf(rs, 'name'),
          color: this.strOf(rs, 'color'),
          updatedAt: this.numOf(rs, 'updatedAt')
        };
        out.push(t);
      }
    } finally {
      this.closeResultSet(rs);
    }
    return out;
  }

  /* ================================================================ 写入 */

  async saveArea(a: Area): Promise<void> {
    await this.upsertArea(this.db(), a);
  }

  async saveProject(p: Project): Promise<void> {
    await this.upsertProject(this.db(), p);
  }

  async saveHeading(h: Heading): Promise<void> {
    await this.upsertHeading(this.db(), h);
  }

  async saveTodo(t: Todo): Promise<void> {
    await this.upsertTodo(this.db(), t);
  }

  async saveTag(t: Tag): Promise<void> {
    await this.upsertTag(this.db(), t);
  }

  /* ------------------------------------------- 单实体 upsert(事务内外共用) */

  private async upsertArea(store: relationalStore.RdbStore, a: Area): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'id': a.id,
      'name': a.name,
      'color': a.color,
      'order': a.order,
      'archived': this.toInt(a.archived),
      'updatedAt': a.updatedAt,
      'deleted': this.toInt(a.deleted)
    };
    await this.insertRow(store, 'areas', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE, '保存区域');
  }

  private async upsertProject(store: relationalStore.RdbStore, p: Project): Promise<void> {
    const repeatJson: string = p.repeat === null ? '' : JSON.stringify(p.repeat);
    const bucket: relationalStore.ValuesBucket = {
      'id': p.id,
      'areaId': p.areaId,
      'name': p.name,
      'note': p.note,
      'when': p.when,
      'date': p.date,
      'deadline': p.deadline,
      'tags': JSON.stringify(p.tags),
      'order': p.order,
      'status': p.status,
      'completedAt': p.completedAt,
      'repeat': repeatJson,
      'createdAt': p.createdAt,
      'updatedAt': p.updatedAt,
      'deleted': this.toInt(p.deleted)
    };
    await this.insertRow(store, 'projects', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE, '保存项目');
  }

  private async upsertHeading(store: relationalStore.RdbStore, h: Heading): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'id': h.id,
      'projectId': h.projectId,
      'name': h.name,
      'order': h.order,
      'archived': this.toInt(h.archived),
      'collapsed': this.toInt(h.collapsed),
      'updatedAt': h.updatedAt
    };
    await this.insertRow(store, 'headings', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE, '保存标题');
  }

  private async upsertTodo(store: relationalStore.RdbStore, t: Todo): Promise<void> {
    const repeatJson: string = t.repeat === null ? '' : JSON.stringify(t.repeat);
    const bucket: relationalStore.ValuesBucket = {
      'id': t.id,
      'title': t.title,
      'note': t.note,
      'when': t.when,
      'date': t.date,
      'reminder': t.reminder,
      'deadline': t.deadline,
      'tags': JSON.stringify(t.tags),
      'checklist': JSON.stringify(t.checklist),
      'projectId': t.projectId,
      'areaId': t.areaId,
      'headingId': t.headingId,
      'repeat': repeatJson,
      'order': t.order,
      'status': t.status,
      'createdAt': t.createdAt,
      'updatedAt': t.updatedAt,
      'completedAt': t.completedAt,
      'deleted': this.toInt(t.deleted)
    };
    await this.insertRow(store, 'todos', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE, '保存待办');
  }

  private async upsertTag(store: relationalStore.RdbStore, t: Tag): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'id': t.id,
      'name': t.name,
      'color': t.color,
      'updatedAt': t.updatedAt
    };
    await this.insertRow(store, 'tags', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE, '保存标签');
  }

  async removeHeading(id: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates('headings');
    predicates.equalTo('id', id);
    await this.deleteRows(this.db(), predicates, '删除标题');
  }

  async removeTag(id: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates('tags');
    predicates.equalTo('id', id);
    await this.deleteRows(this.db(), predicates, '删除标签');
  }

  async clearEntities(): Promise<void> {
    const store: relationalStore.RdbStore = this.db();
    await this.clearTables(store, ENTITY_TABLES, CONTEXT_CLEAR);
  }

  private async clearTables(store: relationalStore.RdbStore, tables: string[], what: string): Promise<void> {
    for (let i = 0; i < tables.length; i++) {
      await this.execSql(store, 'DELETE FROM ' + tables[i], what + ':' + tables[i]);
    }
  }

  /* ========================================================== 快照增量写盘 */

  /**
   * 用一份完整快照对账本库(契约 §7.4 全量快照落地 / 首次安装种子数据 / 重置示例数据)。
   *
   * 与「先 DELETE 全表、再逐条 INSERT」相比:
   *  - 只对**新增或内容有变化**的实体发 INSERT ... ON CONFLICT REPLACE;
   *  - 只对**快照中已不存在的 id**发 DELETE(按主键 IN 批量,每表一条语句);
   *  - 整个对账过程包在一个事务里,失败整体回滚,不会留下「清空了但没写回」的中间态。
   * 因此稳态(内容基本不变)下写放大从 O(全部实体) 降到 O(变化实体),且不再有「库被清空」的
   * 危险窗口。
   */
  async saveSnapshot(snapshot: StorageSnapshot): Promise<void> {
    const store: relationalStore.RdbStore = this.db();
    this.beginTx(store);
    try {
      await this.diffAndUpsert(store, 'areas', await this.loadAreas(), snapshot.areas, (a: Area): string => a.id,
        (a: Area): Promise<void> => this.upsertArea(store, a));
      await this.diffAndUpsert(store, 'projects', await this.loadProjects(), snapshot.projects, (p: Project): string => p.id,
        (p: Project): Promise<void> => this.upsertProject(store, p));
      await this.diffAndUpsert(store, 'headings', await this.loadHeadings(), snapshot.headings, (h: Heading): string => h.id,
        (h: Heading): Promise<void> => this.upsertHeading(store, h));
      await this.diffAndUpsert(store, 'todos', await this.loadTodos(), snapshot.todos, (t: Todo): string => t.id,
        (t: Todo): Promise<void> => this.upsertTodo(store, t));
      await this.diffAndUpsert(store, 'tags', await this.loadTags(), snapshot.tags, (t: Tag): string => t.id,
        (t: Tag): Promise<void> => this.upsertTag(store, t));
      this.commitTx(store);
    } catch (e) {
      // 整体回滚后再上抛:调用方看到的仍是一个失败,但库里不会留下半份数据
      this.rollbackTx(store);
      throw this.fail('快照写盘', e as Object);
    }
  }

  /**
   * 单表对账:先删快照中已不存在的 id,再只 upsert 新增或有变化的实体。
   * @param keyOf 取实体主键
   * @param put 单实体 upsert(不开启子事务,复用外层事务)
   */
  private async diffAndUpsert<T>(
    store: relationalStore.RdbStore,
    table: string,
    existing: T[],
    incoming: T[],
    keyOf: (item: T) => string,
    put: (item: T) => Promise<void>
  ): Promise<void> {
    const staleIds: string[] = [];
    for (let i = 0; i < existing.length; i++) {
      const id: string = keyOf(existing[i]);
      let kept: boolean = false;
      for (let k = 0; k < incoming.length; k++) {
        if (keyOf(incoming[k]) === id) {
          kept = true;
          break;
        }
      }
      if (!kept) {
        staleIds.push(id);
      }
    }
    if (staleIds.length > 0) {
      const predicates = new relationalStore.RdbPredicates(table);
      predicates.in('id', staleIds);
      await this.deleteRows(store, predicates, '对账删除 ' + table);
    }
    for (let i = 0; i < incoming.length; i++) {
      const item: T = incoming[i];
      let previous: T | null = null;
      for (let k = 0; k < existing.length; k++) {
        if (keyOf(existing[k]) === keyOf(item)) {
          previous = existing[k];
          break;
        }
      }
      if (previous === null || JSON.stringify(previous) !== JSON.stringify(item)) {
        await put(item);
      }
    }
  }

  /* ============================================================== outbox */

  async loadOutbox(): Promise<Op[]> {
    const out: Op[] = [];
    const predicates = new relationalStore.RdbPredicates('outbox');
    predicates.orderByAsc('createdAt');
    const rs: relationalStore.ResultSet = await this.queryRows(this.db(), predicates, [
      'opId', 'entity', 'entityId', 'type', 'payload', 'clientTs'
    ], '读取 outbox');
    try {
      while (this.nextRow(rs, '读取 outbox')) {
        const payload: string | null = this.nullableStr(rs, 'payload');
        const op: Op = {
          opId: this.strOf(rs, 'opId'),
          deviceId: '',
          // ArkTS 不支持索引访问类型(Op['entity']),直接标注具体枚举类型
          entity: this.strOf(rs, 'entity') as EntityKind,
          entityId: this.strOf(rs, 'entityId'),
          type: this.strOf(rs, 'type') as OpType,
          payload: payload !== null && payload.length > 0 ? payload : null,
          clientTs: this.numOf(rs, 'clientTs'),
          seq: null
        };
        out.push(op);
      }
    } finally {
      this.closeResultSet(rs);
    }
    return out;
  }

  async appendOutbox(op: Op): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'opId': op.opId,
      'entity': op.entity,
      'entityId': op.entityId,
      'type': op.type,
      'payload': op.payload,
      'clientTs': op.clientTs,
      'createdAt': op.clientTs
    };
    await this.insertRow(this.db(), 'outbox', bucket, relationalStore.ConflictResolution.ON_CONFLICT_IGNORE, '写入 outbox');
  }

  async removeOutbox(opIds: string[]): Promise<void> {
    if (opIds.length === 0) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates('outbox');
    predicates.in('opId', opIds);
    await this.deleteRows(this.db(), predicates, '清理 outbox');
  }

  async outboxCount(): Promise<number> {
    const predicates = new relationalStore.RdbPredicates('outbox');
    const rs: relationalStore.ResultSet = await this.queryRows(this.db(), predicates, ['opId'], '统计 outbox');
    let count: number = 0;
    try {
      const n: number = rs.rowCount;
      count = n < 0 ? 0 : n;
    } catch (e) {
      throw this.fail('统计 outbox', e);
    } finally {
      this.closeResultSet(rs);
    }
    return count;
  }

  /* ========================================================== tombstones */

  async loadTombstones(): Promise<Tombstone[]> {
    const out: Tombstone[] = [];
    const predicates = new relationalStore.RdbPredicates('tombstones');
    const rs: relationalStore.ResultSet = await this.queryRows(this.db(), predicates, [
      'entity', 'entityId', 'deletedAt', 'clientTs'
    ], '读取墓碑');
    try {
      while (this.nextRow(rs, '读取墓碑')) {
        const tb: Tombstone = {
          entity: this.strOf(rs, 'entity') as EntityKind,
          entityId: this.strOf(rs, 'entityId'),
          deletedAt: this.numOf(rs, 'deletedAt'),
          clientTs: this.numOf(rs, 'clientTs')
        };
        out.push(tb);
      }
    } finally {
      this.closeResultSet(rs);
    }
    return out;
  }

  async saveTombstone(t: Tombstone): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'entity': t.entity,
      'entityId': t.entityId,
      'deletedAt': t.deletedAt,
      'clientTs': t.clientTs
    };
    await this.insertRow(this.db(), 'tombstones', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE, '保存墓碑');
  }

  async pruneTombstones(beforeMs: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates('tombstones');
    predicates.lessThan('deletedAt', beforeMs);
    await this.deleteRows(this.db(), predicates, '清理过期墓碑');
  }

  /* ================================================================== kv */

  async getKv(key: string): Promise<string | null> {
    const predicates = new relationalStore.RdbPredicates('kv');
    predicates.equalTo('key', key);
    const rs: relationalStore.ResultSet = await this.queryRows(this.db(), predicates, ['key', 'value'], '读取 kv');
    let value: string | null = null;
    try {
      if (this.nextRow(rs, '读取 kv')) {
        value = this.strOf(rs, 'value');
      }
    } finally {
      this.closeResultSet(rs);
    }
    return value;
  }

  async setKv(key: string, value: string): Promise<void> {
    const bucket: relationalStore.ValuesBucket = { 'key': key, 'value': value };
    await this.insertRow(this.db(), 'kv', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE, '保存 kv');
  }

  async removeKv(key: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates('kv');
    predicates.equalTo('key', key);
    await this.deleteRows(this.db(), predicates, '删除 kv');
  }
}
