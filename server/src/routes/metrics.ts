/**
 * 运维端点 —— `GET /metrics`(Prometheus 文本展示格式)。
 *
 * 暴露内容:
 *  - ops 速率:`ordo_sync_ops_pushed_total` / `ordo_sync_ops_rejected_total{reason}`
 *  - WS 连接数:`ordo_ws_connections`(实时求值)
 *  - 提醒投递数:`ordo_reminders_delivered_total`
 *  - 仓储降级状态:`ordo_storage_degraded`(1=已降级为内存仓储)
 *  - 限流命中数:`ordo_rate_limited_total`
 *
 * 安全:只输出聚合数值,不含任何用户标识/正文;因此无需鉴权即可抓取
 * (与 Prometheus 常规做法一致)。若部署环境要求鉴权,前置网关限制即可。
 */
import type { FastifyInstance, FastifyReply } from 'fastify';
import { ORDO_SCHEMA_VERSION, SERVER_VERSION } from '../config';
import { METRIC } from '../observability/metrics';
import { RouteDeps } from './deps';

const PROMETHEUS_CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8';

export function registerMetricsRoutes(app: FastifyInstance, deps: RouteDeps): void {
  const metricsHandler = async (_req: unknown, reply: FastifyReply): Promise<void> => {
    await reply.header('content-type', PROMETHEUS_CONTENT_TYPE).send(deps.metrics.render());
  };

  // 契约之外的运维端点:主路径 /metrics(与 Prometheus 默认抓取路径一致),
  // 同时挂 /v1/metrics 以免与业务 API 的 /v1 前缀割裂。
  app.get('/metrics', metricsHandler);
  app.get('/v1/metrics', metricsHandler);

  /** 运维自检:便于 curl 快速判断降级状态与版本 */
  app.get('/v1/ops/status', async () => ({
    version: SERVER_VERSION,
    schemaVersion: ORDO_SCHEMA_VERSION,
    storage: deps.storage,
    degraded: deps.metrics.value(METRIC.STORAGE_DEGRADED) === 1,
    wsConnections: deps.realtime.totalConnections(),
    tombstonePurge: {
      started: deps.purger.started,
      intervalMs: deps.purger.intervalMs,
      runs: deps.purger.runCount,
      purgedTotal: deps.metrics.value(METRIC.TOMBSTONES_PURGED)
    },
    uptimeSec: Math.round(process.uptime())
  }));
}
