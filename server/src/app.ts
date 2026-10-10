/**
 * 应用装配:Fastify 实例 + 依赖注入(测试可直接复用,不监听端口)。
 */
import websocket from '@fastify/websocket';
import Fastify, { FastifyInstance, FastifyRequest } from 'fastify';
import { AppConfig, ORDO_SCHEMA_VERSION } from './config';
import { errors } from './domain/errors';
import { createLoggerOptions } from './observability/logging';
import { createMetrics, METRIC, Metrics } from './observability/metrics';
import { Repository } from './repo/types';
import { registerRoutes } from './routes';
import { RouteDeps } from './routes/deps';
import { registerErrorHandling } from './routes/errors';
import { AuthService } from './services/auth';
import { createMailSender, MailSender } from './services/mail';
import { createPasswordHasher, PasswordHasher } from './services/password';
import { TokenBucketLimiter } from './services/rate-limit';
import { RealtimeService } from './services/realtime';
import { ReminderService } from './services/reminders';
import { SyncService } from './services/sync';
import { TombstonePurger } from './services/tombstone-purger';
import { registerWsRoute } from './ws';

export interface BuildAppOptions {
  /** 关闭日志(测试环境);默认按 config.logLevel 开启 */
  logger?: boolean;
  /** 结构化日志写入目标(测试里注入内存流以断言脱敏);不传则写 stdout */
  logDestination?: NodeJS.WritableStream;
  /** 覆盖日志级别(测试里常显式设为 info) */
  logLevel?: string;
  hasher?: PasswordHasher;
  /**
   * 覆盖发信通道(测试可注入内存实现以断言邮件正文;不传则按 config.mail 构造)。
   * 契约 §7.6.5:console 通道写日志,http 通道 POST 到通用邮件网关。
   */
  mail?: MailSender;
  /** 复用外部构造的指标注册表(测试断言用);不传则内部创建 */
  metrics?: Metrics;
  /** 存储是否已降级(暴露到 /metrics 的 ordo_storage_degraded) */
  degraded?: boolean;
}

export interface BuiltApp {
  app: FastifyInstance;
  deps: RouteDeps;
  hasher: PasswordHasher;
  /** 实际使用的发信通道(测试断言 transport=http 时真的发了报文) */
  mail: MailSender;
  limiter: TokenBucketLimiter;
  metrics: Metrics;
  purger: TombstonePurger;
}

export async function buildApp(
  config: AppConfig,
  repo: Repository,
  storage: 'postgres' | 'memory',
  options: BuildAppOptions = {}
): Promise<BuiltApp> {
  const hasher = options.hasher ?? createPasswordHasher();
  const realtime = new RealtimeService();
  const metrics =
    options.metrics ??
    createMetrics({
      storage,
      degraded: options.degraded ?? false,
      wsConnections: () => realtime.totalConnections()
    });
  // 发信通道:console(默认,写日志)/ http(POST 到通用邮件网关)。契约 §7.6.5。
  const mail = options.mail ?? createMailSender(config);
  const auth = new AuthService(repo, config, hasher, Date.now, mail);
  const reminders = new ReminderService(repo, realtime, config, Date.now, metrics);
  const sync = new SyncService(repo, config, realtime, reminders, Date.now, metrics);
  const limiter = new TokenBucketLimiter(config.rateLimit.capacity, config.rateLimit.refillPerSec);
  const purger = new TombstonePurger(repo, config, undefined, metrics);

  const deps: RouteDeps = { config, repo, auth, sync, realtime, reminders, purger, metrics, storage };

  const app = Fastify({
    logger:
      options.logger === false
        ? false
        : createLoggerOptions(options.logLevel ?? config.logLevel, options.logDestination),
    bodyLimit: config.bodyLimitBytes,
    trustProxy: true
  });

  // 清理任务的日志接到 Fastify 的结构化 logger(与 HTTP 日志同一格式)
  purger.logger = {
    info: (obj, msg) => app.log.info(obj, msg),
    warn: (obj, msg) => app.log.warn(obj, msg)
  };
  // 发信通道的日志同样接到 Fastify logger:console 通道的开发回显、http 通道的投递结果
  // 都要走结构化日志(契约 §9:日志永不打印 token/口令;验证码只在非生产打印)。
  mail.logger = {
    info: (obj, msg) => app.log.info(obj, msg),
    warn: (obj, msg) => app.log.warn(obj, msg)
  };

  await app.register(websocket);

  registerErrorHandling(app);

  // 统一请求头校验 + 写接口限流(契约 §7.4 / §8)
  app.addHook('onRequest', async (req: FastifyRequest, reply) => {
    const schemaHeader = req.headers['x-ordo-schema'];
    if (schemaHeader !== undefined) {
      const value = Array.isArray(schemaHeader) ? schemaHeader[0] : schemaHeader;
      if (String(value) !== String(ORDO_SCHEMA_VERSION)) {
        throw errors.validation(`不支持的 X-Ordo-Schema:${value},请升级客户端`, {
          supported: ORDO_SCHEMA_VERSION
        });
      }
    }

    if (config.rateLimit.enabled && ['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) {
      const decision = limiter.tryConsume(bucketKey(req, auth));
      metrics.inc(METRIC.RATE_LIMIT_CHECKS, { result: decision.allowed ? 'allowed' : 'limited' });
      if (!decision.allowed) {
        metrics.inc(METRIC.RATE_LIMITED);
        reply.header('Retry-After', String(decision.retryAfterSec));
        throw errors.rateLimited('请求过于频繁,请稍后重试', { retryAfterSec: decision.retryAfterSec });
      }
    }
  });

  // HTTP 请求计数(按方法/状态码),用于观测错误率与限流比例
  app.addHook('onResponse', async (req, reply) => {
    metrics.inc(METRIC.HTTP_REQUESTS, {
      method: req.method,
      status: String(reply.statusCode),
      route: redactRoute(req.url)
    });
  });

  registerRoutes(app, deps);
  registerWsRoute(app, deps);

  return { app, deps, hasher, mail, limiter, metrics, purger };
}

/** 已登录请求按 userId 计数,匿名请求按 IP 计数 */
function bucketKey(req: FastifyRequest, auth: AuthService): string {
  const header = req.headers.authorization;
  if (header && header.startsWith('Bearer ')) {
    const userId = auth.peekUserId(header.slice('Bearer '.length).trim());
    if (userId) return `u:${userId}`;
  }
  return `ip:${req.ip}`;
}

/** 指标 label 用路由模板,避免把 uuid / 查询串写成高基数 label */
function redactRoute(url: string): string {
  const path = url.split('?')[0];
  return path.replace(/\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '/:id');
}
