/**
 * 路由汇总
 */
import type { FastifyInstance } from 'fastify';
import { registerAuthRoutes } from './auth';
import { RouteDeps } from './deps';
import { ORDO_SCHEMA_VERSION, SERVER_VERSION } from '../config';
import { registerHealthRoutes } from './health';
import { registerMetricsRoutes } from './metrics';
import { registerSyncRoutes } from './sync';

export function registerRoutes(app: FastifyInstance, deps: RouteDeps): void {
  registerHealthRoutes(app, deps);
  registerAuthRoutes(app, deps);
  registerSyncRoutes(app, deps);
  // 运维端点:GET /metrics(Prometheus 文本)、GET /v1/ops/status
  registerMetricsRoutes(app, deps);

  // 便于客户端探活与版本协商(非契约必需,附加只读端点)
  app.get('/v1/version', async () => ({
    version: SERVER_VERSION,
    schemaVersion: ORDO_SCHEMA_VERSION,
    storage: deps.storage
  }));
}

export { RouteDeps };
