/**
 * 服务入口:`pnpm dev` / `pnpm start`
 *  - 无 DATABASE_URL 或连不上 PostgreSQL 时自动降级为内存仓储(契约 §8)
 *  - 启动 Fastlane 提醒扫描(每 1 秒)与 WS 心跳
 *  - 启动独立的墓碑清理定时任务(周期可配置)
 *  - 优雅停机:SIGINT/SIGTERM 时关闭 WS、停止扫描与清理、释放连接池
 */
import { buildApp } from './app';
import { loadConfig, SERVER_VERSION } from './config';
import { createRepository } from './repo';

async function main(): Promise<void> {
  const config = loadConfig();
  // 仓储创建阶段的提示:在 app 建好之前,先收进数组,等 logger 就绪后统一结构化输出。
  // 关键约束:**stdout 必须是纯 JSON 行**(日志采集器按行解析),
  // 因此这里不能直接 console.log,否则会混进非 JSON 行。
  const bootNotes: string[] = [];
  const { repo, storage, degraded, reason } = await createRepository(config, (msg) => bootNotes.push(msg));

  const { app, deps, hasher, limiter, metrics, purger } = await buildApp(config, repo, storage, { degraded });
  // 注意:字段名不能用 `note` —— 那是日志脱敏的保护路径(待办备注正文),
  // 会被替换成 [Redacted],把运维信息吃掉。这里用 `detail`。
  for (const note of bootNotes) app.log.info({ event: 'storage', detail: note }, note);
  deps.reminders.start();
  deps.realtime.startHeartbeat(30_000);
  purger.start();
  const sweepTimer = setInterval(() => limiter.sweep(), 5 * 60_000);
  sweepTimer.unref?.();

  const shutdown = async (signal: string): Promise<void> => {
    app.log.info({ event: 'shutdown', signal }, `收到 ${signal},开始优雅停机`);
    deps.reminders.stop();
    purger.stop();
    deps.realtime.closeAll();
    clearInterval(sweepTimer);
    try {
      await app.close();
      await repo.close();
    } finally {
      process.exit(0);
    }
  };
  process.on('SIGINT', () => void shutdown('SIGINT'));
  process.on('SIGTERM', () => void shutdown('SIGTERM'));

  await app.listen({ host: config.host, port: config.port });

  app.log.info(
    {
      event: 'started',
      version: SERVER_VERSION,
      host: config.host,
      port: config.port,
      storage,
      degraded,
      passwordAlgo: hasher.algo,
      rateLimitEnabled: config.rateLimit.enabled,
      reminderScanMs: config.reminderScanMs,
      tombstonePurgeIntervalMs: config.tombstonePurgeIntervalMs,
      tzOffsetMinutes: config.tzOffsetMinutes
    },
    'Ordo 后端已启动'
  );

  // 人类可读的启动横幅走 **stderr**:stdout 保持"纯 JSON 行",便于日志采集按行解析。
  // (结构化日志里已有等价的 `started` 事件,运维查日志不受影响。)
  const banner = [
    `Ordo 后端 v${SERVER_VERSION} 已启动`,
    `  监听        : http://${config.host}:${config.port}`,
    `  健康检查    : GET /v1/health`,
    `  指标        : GET /metrics(Prometheus 文本)`,
    `  实时通道    : WS  /v1/ws?token=<accessToken>`,
    `  存储        : ${storage}${degraded ? `(已降级:${reason ?? ''})` : ''}`,
    `  口令算法    : ${hasher.algo}`,
    `  限流        : ${config.rateLimit.enabled ? `${config.rateLimit.capacity} req/s(桶容量),每秒补充 ${config.rateLimit.refillPerSec}` : '已关闭'}`,
    `  Fastlane    : 每 ${config.reminderScanMs} ms 扫描未来 ${config.reminderHorizonMs} ms 到期的提醒`,
    `  墓碑清理    : ${config.tombstonePurgeIntervalMs > 0 ? `每 ${config.tombstonePurgeIntervalMs} ms 清理 ${config.tombstoneTtlMs} ms 前的墓碑` : '已关闭'}`,
    `  时区偏移    : UTC${config.tzOffsetMinutes >= 0 ? '+' : ''}${config.tzOffsetMinutes / 60}`
  ].join('\n');
  process.stderr.write(`${banner}\n`);
}

main().catch((err) => {
  console.error('启动失败:', err instanceof Error ? err.stack ?? err.message : err);
  process.exit(1);
});
