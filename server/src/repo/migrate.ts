/**
 * SQL 迁移执行器 —— 契约 §8「迁移:按版本号顺序执行迁移脚本」。
 * 迁移文件位于 repo/migrations/*.sql,以文件名前缀数字作为版本号,记录在 schema_migrations。
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import type { SqlPool } from './pg';

export interface MigrationFile {
  version: number;
  name: string;
  sql: string;
}

/** 从若干候选目录里找到第一个存在的 migrations 目录(src 运行 / dist 运行 / 容器工作目录) */
export function resolveMigrationsDir(candidates: string[]): string {
  for (const dir of candidates) {
    try {
      const files = readdirSync(dir);
      if (files.some((f) => f.endsWith('.sql'))) return dir;
    } catch {
      /* 继续尝试下一个候选 */
    }
  }
  throw new Error(`找不到迁移目录,已尝试:${candidates.join(', ')}`);
}

export function loadMigrations(dir: string): MigrationFile[] {
  return readdirSync(dir)
    .filter((f) => /^\d+_.+\.sql$/.test(f))
    .map((f) => {
      const version = Number(f.split('_')[0]);
      return { version, name: f, sql: readFileSync(join(dir, f), 'utf8') };
    })
    .sort((a, b) => a.version - b.version);
}

export async function runMigrations(pool: SqlPool, dir: string, log: (msg: string) => void = () => {}): Promise<number[]> {
  const migrations = loadMigrations(dir);
  await pool.query(
    `create table if not exists schema_migrations (version int primary key, applied_at bigint not null)`
  );
  const { rows } = await pool.query<{ version: number }>(`select version from schema_migrations`);
  const applied = new Set(rows.map((r) => r.version));

  const executed: number[] = [];
  for (const migration of migrations) {
    if (applied.has(migration.version)) continue;
    const client = await pool.connect();
    try {
      await client.query('begin');
      await client.query(migration.sql);
      await client.query(`insert into schema_migrations (version, applied_at) values ($1, $2)`, [
        migration.version,
        Date.now()
      ]);
      await client.query('commit');
      executed.push(migration.version);
      log(`[migrate] applied ${migration.name}`);
    } catch (err) {
      await client.query('rollback').catch(() => undefined);
      throw err;
    } finally {
      client.release();
    }
  }
  return executed;
}
