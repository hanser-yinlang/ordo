/**
 * 错误映射 —— 契约 §7.4 错误模型:
 *   { "error": { "code":"AUTH_REQUIRED", "message":"需要登录", "details":{} } }
 */
import type { FastifyInstance } from 'fastify';
import { ZodError } from 'zod';
import { AppError, errors } from '../domain/errors';

interface FastifyLikeError {
  statusCode?: number;
  code?: string;
  message?: string;
  validation?: unknown;
}

export function registerErrorHandling(app: FastifyInstance): void {
  app.setNotFoundHandler((req, reply) => {
    reply.code(404).send(errors.notFound(`找不到路由 ${req.method} ${req.url}`).toBody());
  });

  app.setErrorHandler((err, req, reply) => {
    // 1) 业务错误
    if (err instanceof AppError) {
      if (err.status >= 500) req.log.error({ code: err.code }, err.message);
      return reply.code(err.status).send(err.toBody());
    }

    // 2) zod 校验失败
    if (err instanceof ZodError) {
      return reply.code(400).send(
        errors
          .validation('请求参数不合法', {
            issues: err.issues.map((i) => ({ path: i.path.join('.'), message: i.message }))
          })
          .toBody()
      );
    }

    const e = err as FastifyLikeError;

    // 3) body 超限(Fastify 内建)→ 契约里的 SYNC_OP_TOO_LARGE
    if (e.code === 'FST_ERR_CTP_BODY_TOO_LARGE' || e.statusCode === 413) {
      return reply.code(413).send(errors.opTooLarge('请求体超过服务端上限').toBody());
    }

    // 4) Fastify schema 校验 / 其它 4xx
    if (e.validation || (e.statusCode && e.statusCode >= 400 && e.statusCode < 500)) {
      return reply
        .code(e.statusCode && e.statusCode >= 400 && e.statusCode < 500 ? e.statusCode : 400)
        .send(errors.validation(e.message ?? '请求不合法').toBody());
    }

    // 5) 未预期错误:记录日志但不外泄细节(契约 §9:日志不打印 token/口令/备注正文)
    req.log.error({ err: { message: e.message, code: e.code } }, 'unhandled error');
    return reply.code(500).send(errors.internal().toBody());
  });
}
