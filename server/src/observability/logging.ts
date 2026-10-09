/**
 * 结构化日志 + 脱敏 —— 契约 §9「日志不打印 token / 口令 / 备注正文」。
 *
 * 做法(三层防御):
 *  1. **不记录请求体**:Fastify 默认 serializer 会把 headers 打进日志,这里替换为
 *     只输出 `{ method, url }`,并额外剥掉 URL 的查询串(WS 握手把 access token
 *     放在 `?token=` 里,直接记录 URL 会泄漏凭据)。
 *  2. **pino redact**:对仍然可能出现的敏感字段按路径做 `[Redacted]` 替换
 *     (password / note / refreshToken / accessToken / authorization …)。
 *  3. **err serializer**:只序列化 message / code / stack,不序列化 err 上可能挂着的
 *     请求体副本。
 */
import type { FastifyServerOptions } from 'fastify';

/** 需要脱敏的字段路径(pino redact 语法) */
export const REDACT_PATHS: string[] = [
  'req.headers.authorization',
  'req.headers.cookie',
  'req.headers["x-ordo-token"]',
  'headers.authorization',
  'headers.cookie',
  'authorization',
  'accessToken',
  'refreshToken',
  'token',
  'tokenHash',
  'password',
  'passwordHash',
  'newPassword',
  'currentPassword',
  'note',
  'noteText',
  '*.accessToken',
  '*.refreshToken',
  '*.password',
  '*.note',
  '*.token',
  'body.accessToken',
  'body.refreshToken',
  'body.password',
  'body.ops[*].payload.note',
  'payload.note',
  'req.body.password',
  'req.body.refreshToken'
];

const REDACTED = '[Redacted]';

/** 只保留 pathname:避免 `?token=<accessToken>` 出现在日志里 */
export function redactUrl(url: string | undefined): string {
  if (!url) return '';
  const index = url.indexOf('?');
  return index === -1 ? url : url.slice(0, index);
}

/**
 * Fastify logger 配置:JSON 行输出 + 脱敏。
 * @param destination 可选的写入目标(测试里注入内存流以断言"日志里没有秘密")
 */
export function createLoggerOptions(
  level: string,
  destination?: NodeJS.WritableStream
): FastifyServerOptions['logger'] {
  return {
    level,
    ...(destination ? { stream: destination } : {}),
    // 结构化日志:每行一个 JSON 对象(pino 默认行为),messageKey 保持 msg
    messageKey: 'msg',
    timestamp: () => `,"time":${Date.now()}`,
    redact: { paths: REDACT_PATHS, censor: REDACTED },
    serializers: {
      // 绝不记录请求头/请求体 —— 只记录方法与去掉查询串的路径
      req: (req: { method: string; url: string; id?: string }) => ({
        method: req.method,
        url: redactUrl(req.url),
        ...(req.id ? { id: req.id } : {})
      }),
      res: (res: { statusCode: number }) => ({ statusCode: res.statusCode }),
      err: (err: Error & { code?: string }) => ({
        type: err.name,
        message: err.message,
        code: err.code,
        stack: err.stack ?? ''
      })
    }
  };
}
