/**
 * 路由层共享依赖(避免 routes ↔ app 之间的循环引用)
 */
import { AppConfig } from '../config';
import { Metrics } from '../observability/metrics';
import { Repository } from '../repo/types';
import { AuthService } from '../services/auth';
import { RealtimeService } from '../services/realtime';
import { ReminderService } from '../services/reminders';
import { SyncService } from '../services/sync';
import { TombstonePurger } from '../services/tombstone-purger';

export interface RouteDeps {
  config: AppConfig;
  repo: Repository;
  auth: AuthService;
  sync: SyncService;
  realtime: RealtimeService;
  reminders: ReminderService;
  /** 独立的墓碑清理定时任务(可手动触发 / 观测) */
  purger: TombstonePurger;
  /** Prometheus 指标注册表 */
  metrics: Metrics;
  storage: 'postgres' | 'memory';
}
