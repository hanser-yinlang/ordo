/**
 * 健康检查 —— 契约 §7.4 `GET /v1/health` → { status:"ok", version, serverTime }
 * (额外返回 storage / schemaVersion,便于运维判断是否降级为内存仓储)
 */
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { ORDO_SCHEMA_VERSION, SERVER_VERSION } from '../config';
import { errors } from '../domain/errors';
import { RouteDeps } from './deps';

export function requireAuth(deps: RouteDeps) {
  return async (req: FastifyRequest): Promise<void> => {
    const header = req.headers.authorization;
    if (!header || !header.startsWith('Bearer ')) throw errors.authRequired();
    const token = header.slice('Bearer '.length).trim();
    if (!token) throw errors.authRequired();
    req.auth = deps.auth.verifyAccess(token);
  };
}

export function registerHealthRoutes(app: FastifyInstance, deps: RouteDeps): void {
  app.get('/v1/health', async () => ({
    status: 'ok',
    version: SERVER_VERSION,
    serverTime: Date.now(),
    schemaVersion: ORDO_SCHEMA_VERSION,
    storage: deps.storage
  }));
}
