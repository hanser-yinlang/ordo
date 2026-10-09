/**
 * Fastlane 提醒服务 —— 契约 §7.5。
 *  - 为 `reminder` 建独立索引(reminders 表)
 *  - 后台**每 1 秒**扫描「未来 60 秒内到期」的提醒,命中即刻通过 WS 下发(不等待批量合并)
 *  - 同一提醒只投递一次(claimReminder 原子置 fired=true)
 */
import { AppConfig } from '../config';
import { Todo } from '../domain/model';
import { epochToLocalDateTime, localDateTimeToEpoch } from '../domain/time';
import { METRIC, Metrics } from '../observability/metrics';
import { ReminderRow, Repository } from '../repo/types';
import { RealtimeService } from './realtime';
import { ReminderIndexer } from './sync';

export class ReminderService implements ReminderIndexer {
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private repo: Repository,
    private realtime: RealtimeService,
    private config: AppConfig,
    private now: () => number = Date.now,
    private metrics: Metrics | null = null
  ) {}

  /** todo 落库后同步索引:完成/取消/无提醒 → 移除索引 */
  async syncTodo(userId: string, todoId: string, todo: Todo | null): Promise<void> {
    if (!todoId) return;
    if (!todo || todo.status !== 'open' || !todo.reminder) {
      await this.repo.deleteReminder(userId, todoId);
      return;
    }
    const at = localDateTimeToEpoch(todo.reminder, this.config.tzOffsetMinutes);
    if (at === null) {
      await this.repo.deleteReminder(userId, todoId);
      return;
    }
    await this.repo.upsertReminder({
      userId,
      todoId,
      at,
      title: todo.title,
      updatedAt: this.now()
    });
  }

  start(): void {
    this.stop();
    this.timer = setInterval(() => {
      void this.scanOnce().catch(() => undefined);
    }, this.config.reminderScanMs);
    this.timer.unref?.();
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

  /** 扫描一次;返回本次真正投递的提醒条数 */
  async scanOnce(): Promise<number> {
    try {
      return await this.scanInternal();
    } catch (err) {
      this.metrics?.inc(METRIC.REMINDER_SCANS, { result: 'error' });
      throw err;
    }
  }

  /** 供 /metrics 读取:当前尚未投递的提醒条数 */
  private async refreshPendingGauge(): Promise<void> {
    if (!this.metrics) return;
    // 只统计「已到期 + 未来 1 小时」窗口,避免把远期提醒也算成待投递
    const due = await this.repo.listDueReminders(this.now() + 3_600_000);
    this.metrics.set(METRIC.REMINDERS_PENDING, due.length);
  }

  private async scanInternal(): Promise<number> {
    const now = this.now();
    const due = await this.repo.listDueReminders(now + this.config.reminderHorizonMs);
    let fired = 0;
    for (const reminder of due) {
      // 原子领取:并发/重复扫描时只有一个调用能拿到投递权
      const claimed = await this.repo.claimReminder(reminder.id);
      if (!claimed) continue;
      fired += 1;
      this.realtime.sendReminder(reminder.userId, {
        todoId: reminder.todoId,
        title: reminder.title,
        at: epochToLocalDateTime(reminder.at, this.config.tzOffsetMinutes)
      });
    }
    this.metrics?.inc(METRIC.REMINDER_SCANS, { result: 'ok' });
    if (fired > 0) this.metrics?.inc(METRIC.REMINDERS_DELIVERED, {}, fired);
    await this.refreshPendingGauge().catch(() => undefined);
    return fired;
  }

  async listForUser(userId: string): Promise<ReminderRow[]> {
    return this.repo.listReminders(userId);
  }
}
