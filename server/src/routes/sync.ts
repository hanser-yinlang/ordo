/**
 * 同步路由 —— 契约 §7.4
 *   GET  /v1/sync/snapshot → { serverSeq, areas, projects, headings, todos, tags }
 *   POST /v1/sync/push     → { serverSeq, accepted[], rejected[], ops[] }(捎带拉取)
 *   GET  /v1/sync/pull     → { serverSeq, ops[], hasMore }
 */
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { errors } from '../domain/errors';
import { AnyEntity, EntityKindSchema, OpTypeSchema } from '../domain/model';
import { IncomingOp } from '../services/sync';
import { RouteDeps } from './deps';
import { requireAuth } from './health';

export const OpInputSchema = z.object({
  opId: z.string().min(1).max(120),
  deviceId: z.string().max(120).nullish(),
  entity: EntityKindSchema,
  entityId: z.string().min(1).max(200),
  type: OpTypeSchema,
  payload: z.unknown().nullish(),
  clientTs: z.number().int().nonnegative()
});

export const PushBodySchema = z.object({
  deviceId: z.string().max(120).nullish(),
  sinceSeq: z.number().int().nonnegative().nullish(),
  ops: z.array(OpInputSchema)
});

export const PullQuerySchema = z.object({
  sinceSeq: z.coerce.number().int().nonnegative().default(0),
  limit: z.coerce.number().int().positive().optional()
});

export function registerSyncRoutes(app: FastifyInstance, deps: RouteDeps): void {
  const auth = requireAuth(deps);

  app.get('/v1/sync/snapshot', { preHandler: auth }, async (req) => {
    return deps.sync.snapshot(req.auth!.userId);
  });

  app.post('/v1/sync/push', { preHandler: auth }, async (req) => {
    const parsed = PushBodySchema.safeParse(req.body);
    if (!parsed.success) {
      throw errors.validation('请求参数不合法', {
        issues: parsed.error.issues.map((i) => ({ path: i.path.join('.'), message: i.message }))
      });
    }
    const body = parsed.data;

    // 契约 §7.4:单次 push ≤ 500 ops
    if (body.ops.length > deps.config.maxOpsPerPush) {
      throw errors.validation(`单次 push 最多 ${deps.config.maxOpsPerPush} 个 op`, {
        limit: deps.config.maxOpsPerPush,
        received: body.ops.length
      });
    }

    const headerDevice = req.headers['x-ordo-device'];
    const deviceId =
      body.deviceId ?? (typeof headerDevice === 'string' && headerDevice !== '' ? headerDevice : null) ?? req.auth!.deviceId;

    const ops: IncomingOp[] = body.ops.map((op) => ({
      opId: op.opId,
      deviceId: op.deviceId ?? deviceId ?? null,
      entity: op.entity,
      entityId: op.entityId,
      type: op.type,
      payload: (op.payload ?? null) as AnyEntity | null,
      clientTs: op.clientTs
    }));

    return deps.sync.push(req.auth!.userId, deviceId ?? null, body.sinceSeq ?? null, ops);
  });

  app.get('/v1/sync/pull', { preHandler: auth }, async (req) => {
    const parsed = PullQuerySchema.safeParse(req.query);
    if (!parsed.success) {
      throw errors.validation('查询参数不合法', {
        issues: parsed.error.issues.map((i) => ({ path: i.path.join('.'), message: i.message }))
      });
    }
    const limit = parsed.data.limit ?? deps.config.defaultPullLimit;
    // 契约 §7.4:pull limit ≤ 1000
    if (limit > deps.config.maxPullLimit) {
      throw errors.validation(`limit 不能超过 ${deps.config.maxPullLimit}`, {
        limit: deps.config.maxPullLimit,
        received: limit
      });
    }
    return deps.sync.pull(req.auth!.userId, parsed.data.sinceSeq, limit);
  });
}
