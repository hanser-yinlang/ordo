/**
 * 仓储工厂 —— 契约 §8「无 Postgres 时自动降级为内存仓储(同一接口)」。
 */
import { join } from 'node:path';
import { AppConfig } from '../config';
import { MemoryRepository } from './memory';
import { PgRepository } from './pg';
import { Repository } from './types';

export * from './types';
export { MemoryRepository } from './memory';
export { PgRepository } from './pg';
export { runMigrations, loadMigrations, resolveMigrationsDir } from './migrate';

export interface RepositoryBundle {
  repo: Repository;
  storage: 'postgres' | 'memory';
  /** true 表示配置了 DATABASE_URL 但连接失败,已降级 */
  degraded: boolean;
  reason?: string;
}

export function migrationsDirCandidates(): string[] {
  return [
    join(__dirname, 'migrations'),
    join(__dirname, '..', '..', 'src', 'repo', 'migrations'),
    join(process.cwd(), 'src', 'repo', 'migrations'),
    join(process.cwd(), 'migrations'),
    join(process.cwd(), 'dist', 'repo', 'migrations')
  ];
}

export async function createRepository(
  config: AppConfig,
  log: (msg: string) => void = () => undefined
): Promise<RepositoryBundle> {
  if (!config.databaseUrl) {
    const repo = new MemoryRepository();
    await repo.init();
    log('[storage] 未配置 DATABASE_URL,使用内存仓储(数据不持久化,仅用于开发/测试)');
    return { repo, storage: 'memory', degraded: false, reason: 'DATABASE_URL 未配置' };
  }

  const pg = new PgRepository(config.databaseUrl, config.dbPoolMax, migrationsDirCandidates());
  try {
    await pg.init();
    await pg.ping();
    log('[storage] 已连接 PostgreSQL 并完成迁移');
    return { repo: pg, storage: 'postgres', degraded: false };
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    log(`[storage] PostgreSQL 不可用(${reason}),降级为内存仓储`);
    await pg.close().catch(() => undefined);
    const repo = new MemoryRepository();
    await repo.init();
    return { repo, storage: 'memory', degraded: true, reason };
  }
}
