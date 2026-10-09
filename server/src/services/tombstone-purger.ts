/**
 * 墓碑清理定时任务 —— 契约 §3「删除墓碑保留 30 天后可回收」。
 *
 * 历史实现是在 push 路径上做节流触发(`SyncService.maybePurgeTombstones`),
 * 问题是:**没有推送的实例永远不会清理**,且清理耗时被算进 push 的响应时间。
 * 现在改为独立定时任务:
 *  - 周期由 `TOMBSTONE_PURGE_INTERVAL_MS` 配置(默认 5 分钟,`0` 表示关闭);
 *  - 每轮输出结构化日志与指标(删除行数、轮次结果);
 *  - 单轮失败只记录、不抛出(下一次周期继续),并用 `running` 防止重入。
 */
import { AppConfig } from '../config';
import { Repository } from '../repo/types';
import { METRIC, Metrics } from '../observability/metrics';

export interface PurgeLogger {
  info(obj: Record<string, unknown>, msg?: string): void;
  warn(obj: Record<string, unknown>, msg?: string): void;
}

const silentLogger: PurgeLogger = { info: () => undefined, warn: () => undefined };

export interface PurgeResult {
  /** 删除的墓碑行数 */
  purged: number;
  /** 本轮使用的过期阈值(epoch millis) */
  olderThanMs: number;
}

export class TombstonePurger {
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private runs = 0;

  constructor(
    private repo: Repository,
    private config: AppConfig,
    /** 可在构造后替换为 Fastify 的结构化 logger(app.ts 里接线) */
    public logger: PurgeLogger = silentLogger,
    private metrics: Metrics | null = null,
    private now: () => number = Date.now
  ) {}

  get intervalMs(): number {
    return this.config.tombstonePurgeIntervalMs;
  }

  /** 启动周期任务;intervalMs <= 0 时不启动(便于测试/单次部署手动触发) */
  start(): void {
    this.stop();
    if (this.intervalMs <= 0) {
      this.logger.warn({ event: 'tombstone_purge_disabled' }, '墓碑清理定时任务已关闭(interval<=0)');
      return;
    }
    this.timer = setInterval(() => {
      void this.runOnce();
    }, this.intervalMs);
    // 不阻止进程退出(测试与优雅停机都依赖这一点)
    this.timer.unref?.();
    this.logger.info(
      { event: 'tombstone_purge_started', intervalMs: this.intervalMs, ttlMs: this.config.tombstoneTtlMs },
      '墓碑清理定时任务已启动'
    );
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  get started(): boolean {
    return this.timer !== null;
  }

  get runCount(): number {
    return this.runs;
  }

  /** 执行一轮清理(定时器与手动触发共用);永不抛出 */
  async runOnce(): Promise<PurgeResult> {
    const now = this.now();
    const olderThanMs = now - this.config.tombstoneTtlMs;
    if (this.running) {
      this.logger.warn({ event: 'tombstone_purge_skipped', reason: 'previous_run_still_running' }, '上一轮墓碑清理尚未结束,跳过本轮');
      return { purged: 0, olderThanMs };
    }

    this.running = true;
    this.runs += 1;
    const startedAt = this.now();
    try {
      const purged = await this.repo.purgeTombstones(olderThanMs);
      this.metrics?.inc(METRIC.TOMBSTONES_PURGED, {}, purged);
      this.metrics?.inc(METRIC.TOMBSTONE_PURGE_RUNS, { result: 'ok' });
      this.logger.info(
        {
          event: 'tombstone_purge',
          purged,
          olderThanMs,
          ttlMs: this.config.tombstoneTtlMs,
          durationMs: this.now() - startedAt
        },
        purged > 0 ? `已清理 ${purged} 条过期墓碑` : '本轮无过期墓碑'
      );
      return { purged, olderThanMs };
    } catch (err) {
      this.metrics?.inc(METRIC.TOMBSTONE_PURGE_RUNS, { result: 'error' });
      this.metrics?.inc(METRIC.TOMBSTONE_PURGE_ERRORS);
      this.logger.warn(
        {
          event: 'tombstone_purge_failed',
          error: err instanceof Error ? err.message : String(err),
          durationMs: this.now() - startedAt
        },
        '墓碑清理失败,将在下一周期重试'
      );
      return { purged: 0, olderThanMs };
    } finally {
      this.running = false;
    }
  }
}
