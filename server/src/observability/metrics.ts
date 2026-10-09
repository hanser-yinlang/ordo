/**
 * 轻量 Prometheus 指标注册表 —— 无第三方依赖,纯计数器/仪表盘 + 文本格式输出。
 *
 * 指标命名遵循 Prometheus 约定:`ordo_<子系统>_<度量>_<单位>`。
 * 说明:这里**不使用** Histogram,避免在无依赖前提下引入分桶复杂度;
 * 延迟类观测走结构化日志(见 logging.ts),指标只保留可告警的计数与瞬时值。
 */

/** 计数器快照:[labels, value] 列表 */
export type CounterSnapshot = Array<[Record<string, string>, number]>;

export interface MetricSample {
  name: string;
  help: string;
  type: 'counter' | 'gauge';
  samples: CounterSnapshot;
}

const LABEL_ESCAPE = /\\|"|\n/g;

/** 按 Prometheus 文本格式转义 label 值 */
function escapeLabel(value: string): string {
  return value.replace(LABEL_ESCAPE, (ch) => (ch === '\\' ? '\\\\' : ch === '"' ? '\\"' : '\\n'));
}

/** 按 Prometheus 文本格式转义 HELP 文本 */
function escapeHelp(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/\n/g, '\\n');
}

/** labels 的稳定序列化键(与书写顺序无关) */
function labelKey(labels: Record<string, string>): string {
  return Object.keys(labels)
    .sort()
    .map((k) => `${k}=${labels[k]}`)
    .join('\u0001');
}

function renderLabels(labels: Record<string, string>): string {
  const keys = Object.keys(labels).sort();
  if (keys.length === 0) return '';
  return `{${keys.map((k) => `${k}="${escapeLabel(labels[k])}"`).join(',')}}`;
}

/**
 * 一个可暴露为 Prometheus 文本的指标集合。
 * 线程模型:Node 单线程,方法内部无 await,天然原子。
 */
export class Metrics {
  /** 上次导出后是否需要重新渲染文本的可选缓存(未使用,保留语义清晰) */
  private counters = new Map<string, { help: string; values: Map<string, [Record<string, string>, number]> }>();
  private gauges = new Map<string, { help: string; values: Map<string, [Record<string, string>, number]> }>();
  /** 由回调实时求值的仪表盘(如 WS 连接数、降级状态) */
  private collectors = new Map<string, { help: string; collect: () => CounterSnapshot }>();

  constructor(private startedAtMs: number = Date.now()) {}

  /* ------------------------------ 注册 ------------------------------ */

  registerCounter(name: string, help: string): void {
    if (!this.counters.has(name)) this.counters.set(name, { help, values: new Map() });
  }

  registerGauge(name: string, help: string): void {
    if (!this.gauges.has(name)) this.gauges.set(name, { help, values: new Map() });
  }

  /**
   * 注册一个"实时求值"的仪表盘。
   * 用于 WS 连接数、仓储降级状态这类**不从事件累计**、只能按需读取的值。
   */
  registerCollector(name: string, help: string, collect: () => CounterSnapshot): void {
    this.collectors.set(name, { help, collect });
    this.registerGauge(name, help);
  }

  /* ------------------------------ 写入 ------------------------------ */

  inc(name: string, labels: Record<string, string> = {}, delta = 1): void {
    const metric = this.counters.get(name);
    if (!metric) throw new Error(`未注册的计数器:${name}`);
    const key = labelKey(labels);
    const current = metric.values.get(key);
    if (current) current[1] += delta;
    else metric.values.set(key, [{ ...labels }, delta]);
  }

  set(name: string, value: number, labels: Record<string, string> = {}): void {
    const metric = this.gauges.get(name);
    if (!metric) throw new Error(`未注册的仪表盘:${name}`);
    metric.values.set(labelKey(labels), [{ ...labels }, value]);
  }

  /* ------------------------------ 读取 ------------------------------ */

  value(name: string, labels: Record<string, string> = {}): number {
    const metric = this.counters.get(name) ?? this.gauges.get(name);
    if (!metric) return 0;
    return metric.values.get(labelKey(labels))?.[1] ?? 0;
  }

  snapshot(): MetricSample[] {
    const out: MetricSample[] = [];
    for (const [name, metric] of this.counters) {
      out.push({ name, help: metric.help, type: 'counter', samples: [...metric.values.values()] });
    }
    for (const [name, metric] of this.gauges) {
      const samples = [...metric.values.values()];
      for (const [collectorName, collector] of this.collectors) {
        if (collectorName === name) samples.push(...collector.collect());
      }
      out.push({ name, help: metric.help, type: 'gauge', samples });
    }
    return out;
  }

  /** 渲染为 Prometheus 文本展示格式(version=0.0.4) */
  render(): string {
    const lines: string[] = [];
    for (const metric of this.snapshot()) {
      lines.push(`# HELP ${metric.name} ${escapeHelp(metric.help)}`);
      lines.push(`# TYPE ${metric.name} ${metric.type}`);
      if (metric.samples.length === 0) {
        // 计数器/仪表盘无样本时也要输出一行,便于 Prometheus 侧看到指标存在
        lines.push(`${metric.name} ${metric.type === 'counter' ? 0 : 0}`);
        continue;
      }
      for (const [labels, value] of metric.samples) {
        lines.push(`${metric.name}${renderLabels(labels)} ${formatNumber(value)}`);
      }
    }
    lines.push(...this.processLines());
    return `${lines.join('\n')}\n`;
  }

  private processLines(): string[] {
    return [
      '# HELP ordo_uptime_seconds 服务进程启动至今的秒数',
      '# TYPE ordo_uptime_seconds gauge',
      `ordo_uptime_seconds ${formatNumber((Date.now() - this.startedAtMs) / 1000)}`
    ];
  }
}

/** Prometheus 文本格式里数值必须是十进制或科学计数法,禁止 Infinity/NaN */
function formatNumber(value: number): string {
  if (!Number.isFinite(value)) return '0';
  if (Number.isInteger(value)) return String(value);
  return String(value);
}

/* ============================================================================
 * Ordo 指标定义
 * ==========================================================================*/

export const METRIC = {
  /** push 处理过的 op 数(按结果分桶) */
  OPS_PUSHED: 'ordo_sync_ops_pushed_total',
  /** push 被拒的 op 数(按原因分桶) */
  OPS_REJECTED: 'ordo_sync_ops_rejected_total',
  /** push 请求数 */
  PUSH_REQUESTS: 'ordo_sync_push_requests_total',
  /** pull 请求数与返回的 op 数 */
  PULL_REQUESTS: 'ordo_sync_pull_requests_total',
  PULL_OPS: 'ordo_sync_pull_ops_total',
  /** SYNC_SEQ_GAP 次数 */
  SEQ_GAP: 'ordo_sync_seq_gap_total',
  /** 单 op 超限次数 */
  OP_TOO_LARGE: 'ordo_sync_op_too_large_total',
  /** WS 当前连接数(按状态分桶:total / authenticated 失败另计) */
  WS_CONNECTIONS: 'ordo_ws_connections',
  /** WS 连接/断开/拒绝累计 */
  WS_OPENED: 'ordo_ws_connections_opened_total',
  WS_CLOSED: 'ordo_ws_connections_closed_total',
  WS_REJECTED: 'ordo_ws_connections_rejected_total',
  /** WS 下发消息数(按类型分桶) */
  WS_SENT: 'ordo_ws_messages_sent_total',
  /** Fastlane 提醒投递数 */
  REMINDERS_DELIVERED: 'ordo_reminders_delivered_total',
  /** Fastlane 扫描轮次 */
  REMINDER_SCANS: 'ordo_reminder_scans_total',
  /** 提醒索引中的待投递条数(实时求值) */
  REMINDERS_PENDING: 'ordo_reminders_pending',
  /** 墓碑清理累计删除行数与执行轮次 */
  TOMBSTONES_PURGED: 'ordo_tombstones_purged_total',
  TOMBSTONE_PURGE_RUNS: 'ordo_tombstone_purge_runs_total',
  TOMBSTONE_PURGE_ERRORS: 'ordo_tombstone_purge_errors_total',
  /** 限流命中数与累计限流请求 */
  RATE_LIMITED: 'ordo_rate_limited_total',
  RATE_LIMIT_CHECKS: 'ordo_rate_limit_checks_total',
  /** HTTP 请求与错误 */
  HTTP_REQUESTS: 'ordo_http_requests_total',
  /** 仓储降级状态:0=正常,1=已降级为内存仓储 */
  STORAGE_DEGRADED: 'ordo_storage_degraded',
  /** 存储类型信息标签恒为 1 */
  STORAGE_INFO: 'ordo_storage_info'
} as const;

export interface MetricsOptions {
  storage: 'postgres' | 'memory';
  degraded?: boolean;
  /** 实时求值:当前 WS 连接数 */
  wsConnections?: () => number;
}

/** 构造带 Ordo 全部指标定义的注册表,并挂上实时求值的 collector */
export function createMetrics(options: MetricsOptions): Metrics {
  const metrics = new Metrics();
  const counter = (name: string, help: string): void => metrics.registerCounter(name, help);

  counter(METRIC.OPS_PUSHED, 'push 中成功落库的 op 数');
  counter(METRIC.OPS_REJECTED, 'push 中被拒绝的 op 数(按 reason 分桶)');
  counter(METRIC.PUSH_REQUESTS, 'push 请求数(按结果分桶)');
  counter(METRIC.PULL_REQUESTS, 'pull 请求数(按是否还有更多分桶)');
  counter(METRIC.PULL_OPS, 'pull 返回的 op 总数');
  counter(METRIC.SEQ_GAP, 'SYNC_SEQ_GAP 命中次数(按接口分桶)');
  counter(METRIC.OP_TOO_LARGE, '单个 op payload 超过 256KB 被拒次数');
  counter(METRIC.WS_OPENED, 'WS 连接建立次数');
  counter(METRIC.WS_CLOSED, 'WS 连接关闭次数');
  counter(METRIC.WS_REJECTED, 'WS 连接因鉴权失败被拒次数');
  counter(METRIC.WS_SENT, 'WS 下发消息数(按 type 分桶)');
  counter(METRIC.REMINDERS_DELIVERED, 'Fastlane 提醒投递次数');
  counter(METRIC.REMINDER_SCANS, 'Fastlane 扫描轮次(按结果分桶)');
  counter(METRIC.TOMBSTONES_PURGED, '墓碑清理删除的实体行数');
  counter(METRIC.TOMBSTONE_PURGE_RUNS, '墓碑清理执行轮次(按结果分桶)');
  counter(METRIC.TOMBSTONE_PURGE_ERRORS, '墓碑清理失败次数');
  counter(METRIC.RATE_LIMITED, '被限流拒绝的请求数');
  counter(METRIC.RATE_LIMIT_CHECKS, '限流判断次数(按结果分桶)');
  counter(METRIC.HTTP_REQUESTS, 'HTTP 请求数(按方法/状态码分桶)');

  metrics.registerGauge(METRIC.WS_CONNECTIONS, '当前 WS 连接数');
  metrics.registerGauge(METRIC.REMINDERS_PENDING, '提醒索引中尚未投递的条数');
  metrics.set(METRIC.REMINDERS_PENDING, 0);

  metrics.registerCollector(METRIC.WS_CONNECTIONS, '当前 WS 连接数', () =>
    options.wsConnections ? [[{}, options.wsConnections()]] : []
  );

  metrics.registerGauge(METRIC.STORAGE_DEGRADED, '仓储降级状态:1=已降级为内存仓储,0=正常');
  metrics.set(METRIC.STORAGE_DEGRADED, options.degraded ? 1 : 0);

  metrics.registerGauge(METRIC.STORAGE_INFO, '存储后端信息(标签 storage,值恒为 1)');
  metrics.set(METRIC.STORAGE_INFO, 1, { storage: options.storage });

  return metrics;
}
