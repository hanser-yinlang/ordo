/**
 * pg-mem 测试夹具:用纯 JS 的内存 Postgres 实现**真实执行** `migrations/001_init.sql`,
 * 让 `PgRepository` 在 CI / 本机无 Postgres 的环境下也能跑完整 SQL 流程。
 *
 * ── pg-mem 已知差异(详见 README「PgRepository 验证」)──────────────────
 * 1. **事务内 DDL 的 AST 覆盖检查**
 *    pg-mem 在事务中执行 `create table ... (version int primary key, ...)` 时,
 *    静态检查会把这些**内联列约束**报成 "planner 未读取的 AST 部分" 并抛
 *    NotSupported。约束本身在运行时是生效的(本文件 registerConstraintProbe
 *    用重复主键插入验证),因此夹具用 `noAstCoverageCheck: true` 关闭这项
 *    静态检查,而不是改写契约冻结的迁移 SQL。
 * 2. **bigint / bigserial 在 information_schema 里报告为 `integer`**
 *    但读写往返保持 JS number 精度(Date.now() 级别数值无损,见 pg.test.ts)。
 * 3. **没有索引目录**:`pg_indexes` / `pg_index` 不存在,`pg_class` 恒为空,
 *    `table.indexHandlers` 也是空的 —— pg-mem 不物化索引,只保证 DDL 可解析
 *    且查询语义正确。因此"索引存在"用**逐条重放迁移里的 create index 语句**
 *    来验证,真正的索引目录核对留给真实 Postgres(见 README 的复跑步骤)。
 * 4. `EXPLAIN` / `pg_typeof` 未实现,无法在这里断言执行计划是否走索引。
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { newDb, type IMemoryDb } from 'pg-mem';
import { PgRepository, SqlPool } from '../src/repo/pg';

/** 迁移目录(src 运行) */
export const MIGRATIONS_DIR = join(__dirname, '..', 'src', 'repo', 'migrations');
/** 初始迁移脚本路径 */
export const INIT_SQL_PATH = join(MIGRATIONS_DIR, '001_init.sql');

export interface PgMemHarness {
  /** pg-mem 数据库实例(用于直连 SQL 断言) */
  db: IMemoryDb;
  /** pg-mem 提供的 pg 兼容连接池 */
  pool: SqlPool;
  /** 待测仓储(真实执行 SQL) */
  repo: PgRepository;
  /** 直连 SQL 查询(pg-mem,不走 PgRepository) */
  sql<R = Record<string, unknown>>(text: string, params?: unknown[]): Promise<R[]>;
  close(): Promise<void>;
}

/** 建一个全新的、已执行 001_init.sql 的内存 Postgres */
export async function createPgMemRepo(): Promise<PgMemHarness> {
  const db = newDb({ autoCreateForeignKeyIndices: true, noAstCoverageCheck: true });
  const adapter = db.adapters.createPg();
  const pool = new adapter.Pool() as unknown as SqlPool;

  const repo = new PgRepository('postgres://pg-mem.local/ordo', 2, [MIGRATIONS_DIR], pool);
  await repo.init();

  return {
    db,
    pool,
    repo,
    async sql<R = Record<string, unknown>>(text: string, params?: unknown[]): Promise<R[]> {
      const res = await pool.query<R>(text, params);
      return res.rows;
    },
    async close() {
      await repo.close();
    }
  };
}

/** 读取 001_init.sql 原文(用于索引/约束声明的静态核对) */
export function readInitSql(): string {
  return readFileSync(INIT_SQL_PATH, 'utf8');
}

export interface IndexDeclaration {
  name: string;
  table: string;
  columns: string[];
  /** 部分索引的 where 子句(无则为 null) */
  where: string | null;
  /** 原始 DDL(不含结尾分号) */
  ddl: string;
}

/**
 * 解析迁移脚本里的 `create index [if not exists] <name> on <table> (cols) [where ...]`。
 * pg-mem 不保留索引目录,静态声明 + DDL 可执行性是这里能拿到的最强证据。
 */
export function parseIndexDeclarations(sql: string): IndexDeclaration[] {
  const out: IndexDeclaration[] = [];
  const re = /create\s+index\s+(?:if\s+not\s+exists\s+)?([a-z0-9_]+)\s+on\s+([a-z0-9_]+)\s*\(([^)]*)\)\s*(where[^;]*)?;/gi;
  let match: RegExpExecArray | null;
  while ((match = re.exec(sql)) !== null) {
    out.push({
      name: match[1],
      table: match[2],
      columns: match[3].split(',').map((c) => c.trim()),
      // 去掉行尾注释,否则 `where fired = false -- xxx` 会把注释带进解析结果
      where: match[4] ? match[4].replace(/--[^\n]*/g, '').trim().replace(/\s+/g, ' ') : null,
      ddl: match[0].replace(/--[^\n]*/g, '').replace(/;$/, '').trim()
    });
  }
  return out;
}

/**
 * 把索引 DDL 的索引名换掉,用于"逐条重放"验证 —— pg-mem 不保留索引目录,
 * 重复创建同名索引也无法证明真的执行过,换成新名字才能真正走到创建路径。
 */
export function renameIndex(ddl: string, oldName: string, newName: string): string {
  return ddl.replace(new RegExp(`\\b${oldName}\\b`), newName);
}

/** 从迁移脚本里抽取表名清单 */
export function parseTableNames(sql: string): string[] {
  const out: string[] = [];
  const re = /create\s+table\s+(?:if\s+not\s+exists\s+)?([a-z0-9_]+)/gi;
  let match: RegExpExecArray | null;
  while ((match = re.exec(sql)) !== null) out.push(match[1]);
  return out;
}

/** 生成确定性 uuid(测试可读性优于随机值) */
export function uuid(seed: number): string {
  const hex = seed.toString(16).padStart(12, '0');
  return `00000000-0000-4000-8000-${hex}`;
}
