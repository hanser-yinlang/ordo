/**
 * Ordo · 本地存储抽象
 * 契约来源:docs/03-数据模型与同步协议.md §8(客户端存储)
 *
 * 表结构(RelationalStore 实现,表字段名与契约 §2 完全一致):
 *   areas(id, name, color, "order", archived, updatedAt, deleted)
 *   projects(id, areaId, name, note, "when", date, deadline, tags, "order", status,
 *            completedAt, repeat, createdAt, updatedAt, deleted)
 *   headings(id, projectId, name, "order", archived, collapsed, updatedAt)
 *   todos(id, title, note, "when", date, reminder, deadline, tags, checklist,
 *         projectId, areaId, headingId, repeat, "order", status,
 *         createdAt, updatedAt, completedAt, deleted)
 *   tags(id, name, color, updatedAt)
 *   outbox(opId PK, payload, createdAt)      -- 契约 §8
 *   tombstones(entity, entityId, deletedAt, clientTs)
 *   kv(key PK, value)                        -- lastServerSeq / tokens / deviceId / schemaVersion
 *
 * 复杂字段(tags / checklist / repeat)以 JSON 文本列存储,列名与 §2 一致。
 * `order` 与 `when` 是 SQL 关键字,建表与读写时统一加双引号。
 */

import { Area, Heading, Op, Project, Tag, Tombstone, Todo } from '../model/Entities.ets';

/**
 * 一份完整实体快照(不含 outbox / tombstones / kv)。
 * 用途:首次安装写种子数据、重置示例数据、契约 §7.4 全量快照落地。
 * 语义是「以本快照为准」,因此实现必须删除快照中已不存在的实体。
 */
export interface StorageSnapshot {
  areas: Area[];
  projects: Project[];
  /** 顶层标题数组(契约 §7.4 snapshot 结构),由 OrdoEngine.allHeadings() 展开 */
  headings: Heading[];
  todos: Todo[];
  tags: Tag[];
}

export interface OrdoStore {
  /** 打开数据库并建表(幂等);RDB 实现需要 UIAbilityContext */
  init(): Promise<void>;

  /**
   * 该实例实际使用的库文件路径(仅用于设置页展示与自检;内存实现返回 '(内存)')。
   * 契约 §7.6.3 硬约束要求每个账号一份独立目录,这个字符串就是"到底落在哪"的证据。
   */
  pathText(): string;

  /* ---- 读取 ---- */
  loadAreas(): Promise<Area[]>;
  loadProjects(): Promise<Project[]>;
  loadHeadings(): Promise<Heading[]>;
  loadTodos(): Promise<Todo[]>;
  loadTags(): Promise<Tag[]>;

  /* ---- 写入(单实体 upsert / 物理删除) ---- */
  saveArea(a: Area): Promise<void>;
  saveProject(p: Project): Promise<void>;
  saveHeading(h: Heading): Promise<void>;
  saveTodo(t: Todo): Promise<void>;
  saveTag(t: Tag): Promise<void>;
  removeHeading(id: string): Promise<void>;
  removeTag(id: string): Promise<void>;

  /* ---- 清空(重置示例数据 / 退出登录) ---- */
  clearEntities(): Promise<void>;

  /* ---- 快照对账(增量 upsert + 删除快照中已不存在的实体) ---- */
  /**
   * 以 snapshot 为准写盘。实现约定:
   *  - 只对新增或内容变化的实体发写操作,删除仅限快照中不存在的 id;
   *  - 整个过程在一个事务内完成,失败整体回滚。
   * 与「clearEntities() + 逐条 saveX()」相比,稳态下写放大从 O(全部实体) 降到 O(变化实体)。
   */
  saveSnapshot(snapshot: StorageSnapshot): Promise<void>;

  /* ---- outbox(契约 §7.1/§7.2) ---- */
  loadOutbox(): Promise<Op[]>;
  appendOutbox(op: Op): Promise<void>;
  removeOutbox(opIds: string[]): Promise<void>;
  outboxCount(): Promise<number>;

  /* ---- 墓碑(契约 §7.3.5,保留 30 天) ---- */
  loadTombstones(): Promise<Tombstone[]>;
  saveTombstone(t: Tombstone): Promise<void>;
  pruneTombstones(beforeMs: number): Promise<void>;

  /* ---- kv ---- */
  getKv(key: string): Promise<string | null>;
  setKv(key: string, value: string): Promise<void>;
  removeKv(key: string): Promise<void>;
}

/** kv 键名常量(契约 §8) */
export class KvKeys {
  static readonly SCHEMA_VERSION: string = 'schemaVersion';
  static readonly LAST_SERVER_SEQ: string = 'lastServerSeq';
  static readonly DEVICE_ID: string = 'deviceId';
  static readonly ACCESS_TOKEN: string = 'accessToken';
  static readonly REFRESH_TOKEN: string = 'refreshToken';
  static readonly USER_EMAIL: string = 'userEmail';
  static readonly BASE_URL: string = 'baseUrl';
  static readonly THEME_MODE: string = 'themeMode';
  /**
   * 该用户目录是否已经决定过"首次演示数据"(契约 §7.6.3:首次登录某账号且服务端无数据时才写)。
   * 写在**用户目录**里:换账号等于换目录,标记天然互不影响。
   */
  static readonly SEEDED: string = 'ordo.seeded';
  /** 上一次登录的邮箱(应用级;登录页回填用,不属于会话)。v1.4 登录被移除后仅保留兼容,不再写入 */
  static readonly LAST_EMAIL: string = 'ordo.lastEmail';
  /**
   * **本机稳定账号目录标识**(契约 §7.6.6,v1.4 引入)。
   *
   * 形态 `local-<16hex>`,首次运行生成并持久化,**此后永不因会话重建而改变**。
   * 为什么不能用服务端 `userId` 当目录名:没有登录界面之后,"离线首启 → 联网拿会话"与
   * "同步 401 → 静默重建匿名会话"都会拿到**新的** userId;目录跟着变,用户就会觉得数据丢了。
   * 升级前已在用的目录(老版本按 `userDataDirName(userId)` 建的那份)**继续沿用**,不做迁移。
   */
  static readonly LOCAL_ACCOUNT_ID: string = 'ordo.localAccountId';
}

/**
 * 播种标记 `KvKeys.SEEDED` 的取值:该工作区「演示数据已经播过」的记忆(契约 §7.6.3 的本地化版本)。
 *
 * 为什么放在存储层:这个字面量有**两个使用者** —— 引擎要写它
 * (`OrdoEngine.clearDemoData` 清空内容后把标记钉住)、播种策略要读它
 * (`viewmodel/SeedPolicy.ets` 从本文件再导出为 `SEEDED_MARK_VALUE`)。
 * 各自写一份字面量迟早会漂移,而漂移的后果正是用户报过的那类 bug("删掉的东西自己长回来")。
 */
export const SEEDED_MARK_VALUE: string = '1';
