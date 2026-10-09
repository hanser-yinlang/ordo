/**
 * 迁移 CLI:`pnpm migrate`(容器启动前或裸机部署时单独执行)。
 */
import { Pool } from 'pg';
import { loadConfig } from '../config';
import { migrationsDirCandidates } from '../repo';
import { resolveMigrationsDir, runMigrations } from '../repo/migrate';

async function main(): Promise<void> {
  const config = loadConfig();
  if (!config.databaseUrl) {
    console.error('[migrate] 未配置 DATABASE_URL,无需迁移(应用将使用内存仓储)');
    process.exit(0);
  }
  const dir = resolveMigrationsDir(migrationsDirCandidates());
  const pool = new Pool({ connectionString: config.databaseUrl, max: 2 });
  try {
    const applied = await runMigrations(pool, dir, (msg) => console.log(msg));
    console.log(
      applied.length > 0 ? `[migrate] 完成,应用了 ${applied.length} 个迁移:${applied.join(', ')}` : '[migrate] 无待应用迁移'
    );
  } finally {
    await pool.end();
  }
}

main().catch((err) => {
  console.error('[migrate] 失败:', err instanceof Error ? err.message : err);
  process.exit(1);
});
