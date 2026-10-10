/**
 * 运行配置(全部来自环境变量,便于容器化部署)。
 * 契约依据:03-数据模型与同步协议.md §7.4(限制)、§7.5(Fastlane)、§8(存储)、§9(安全)
 */
import { randomBytes } from 'node:crypto';

export const SERVER_VERSION = '1.0.0';
/** 契约 §1:schemaVersion = 1 */
export const ORDO_SCHEMA_VERSION = 1;

export interface RateLimitConfig {
  enabled: boolean;
  /** 桶容量 = 允许的瞬时突发请求数 */
  capacity: number;
  /** 每秒补充的令牌数 */
  refillPerSec: number;
}

/** 发信通道(契约 §7.6.5):console = 写日志(开发),http = POST 到通用邮件网关 */
export type MailTransport = 'console' | 'http';

export interface MailConfig {
  transport: MailTransport;
  /** http 通道的网关地址(transport=http 时必填,否则拒绝启动) */
  httpUrl: string | null;
  /** http 通道的 Bearer token(可选) */
  httpToken: string | null;
  httpTimeoutMs: number;
}

/** 邮箱验证码参数(契约 §7.6.5:5 分钟有效、60s 间隔、每小时 5 / 每天 10、同码最多 5 次) */
export interface EmailCodeConfig {
  ttlSec: number;
  retryAfterSec: number;
  maxPerHour: number;
  maxPerDay: number;
  maxAttempts: number;
  /**
   * `HMAC-SHA256(pepper, email:code)` 的 pepper(契约 §9)。
   * 生产必填(`ORDO_CODE_PEPPER`),开发/测试回退到 `JWT_SECRET`。
   */
  pepper: string;
  /**
   * 是否在响应里额外返回 `devCode`(仅在 `transport=console` 且**非生产**环境生效)。
   * `NODE_ENV=production` 时若开启,`loadConfig` 直接抛错(拒绝启动)。
   */
  devEchoCode: boolean;
}

export interface AppConfig {
  env: string;
  host: string;
  port: number;
  /** 为 null 时降级为内存仓储(本地开发 / 自动化测试) */
  databaseUrl: string | null;
  dbPoolMax: number;
  jwtSecret: string;
  /** access token 有效期(秒),契约 §9:30min */
  accessTtlSec: number;
  /** refresh token 有效期(天),契约 §9:30 天 */
  refreshTtlDays: number;
  /** 本地时区偏移(分钟),用于把 "YYYY-MM-DDTHH:mm" 本地时间换算成 epoch millis */
  tzOffsetMinutes: number;
  /** Fastlane 扫描间隔(毫秒),契约 §7.5:每 1 秒 */
  reminderScanMs: number;
  /** 提前量(毫秒),契约 §7.5:未来 60 秒内到期 */
  reminderHorizonMs: number;
  /** HTTP body 上限(字节);单 op 上限由 maxOpPayloadBytes 单独约束 */
  bodyLimitBytes: number;
  /** 单次 push 最多 op 数,契约 §7.4:500 */
  maxOpsPerPush: number;
  /** 单 op payload 上限(字节),契约 §7.4:256 KB */
  maxOpPayloadBytes: number;
  /** pull limit 上限,契约 §7.4:1000 */
  maxPullLimit: number;
  /** pull 默认 limit */
  defaultPullLimit: number;
  /** 墓碑清理定时任务周期(毫秒);<=0 表示关闭定时任务(契约 §3:墓碑保留 30 天) */
  tombstonePurgeIntervalMs: number;
  /** 墓碑保留时长(毫秒),默认 30 天 */
  tombstoneTtlMs: number;
  rateLimit: RateLimitConfig;
  /** 邮箱验证码登录(契约 §7.6.5) */
  emailCode: EmailCodeConfig;
  /** 发信通道(契约 §7.6.5) */
  mail: MailConfig;
  logLevel: string;
  /**
   * 是否由服务端代生成重复待办的下一次实例(契约 §6)。
   * 默认 **关闭**:本地优先架构下由客户端生成,服务端再生成会造成双写。
   */
  serverSideRepeat: boolean;
}

type EnvLike = Record<string, string | undefined>;

function num(env: EnvLike, key: string, fallback: number): number {
  const raw = env[key];
  if (raw === undefined || raw === '') return fallback;
  const v = Number(raw);
  if (!Number.isFinite(v)) throw new Error(`环境变量 ${key} 必须是数字,当前为 "${raw}"`);
  return v;
}

function bool(env: EnvLike, key: string, fallback: boolean): boolean {
  const raw = env[key];
  if (raw === undefined || raw === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(raw.toLowerCase());
}

export function loadConfig(env: EnvLike = process.env): AppConfig {
  const nodeEnv = env.NODE_ENV ?? 'development';
  const isProd = nodeEnv === 'production';
  const databaseUrl = env.DATABASE_URL && env.DATABASE_URL.trim() !== '' ? env.DATABASE_URL.trim() : null;

  let jwtSecret = env.JWT_SECRET && env.JWT_SECRET.trim() !== '' ? env.JWT_SECRET.trim() : '';
  if (!jwtSecret) {
    if (isProd) throw new Error('生产环境必须设置 JWT_SECRET(契约 §9)');
    // 开发/测试:生成一次性随机密钥,重启即失效(不会把默认密钥带进生产)
    jwtSecret = randomBytes(32).toString('hex');
  }

  /* ---- 发信通道(契约 §7.6.5) ---- */
  const mailTransportRaw = (env.ORDO_MAIL_TRANSPORT ?? '').trim().toLowerCase() || 'console';
  if (mailTransportRaw !== 'console' && mailTransportRaw !== 'http') {
    throw new Error(`ORDO_MAIL_TRANSPORT 只能是 console 或 http,当前为 "${mailTransportRaw}"`);
  }
  const mailTransport = mailTransportRaw as MailTransport;
  const mailHttpUrl = env.ORDO_MAIL_HTTP_URL && env.ORDO_MAIL_HTTP_URL.trim() !== '' ? env.ORDO_MAIL_HTTP_URL.trim() : null;
  if (mailTransport === 'http' && !mailHttpUrl) {
    // 没有任何可投递的地址 → 每次发码都必然失败,属于配置错误,直接拒绝启动
    throw new Error('ORDO_MAIL_TRANSPORT=http 时必须设置 ORDO_MAIL_HTTP_URL(通用邮件网关地址)');
  }

  /* ---- 邮箱验证码(契约 §7.6.5) ---- */
  const devEchoCode = bool(env, 'ORDO_DEV_ECHO_CODE', false);
  if (isProd && devEchoCode) {
    // 契约 §7.6.5 明文要求:生产环境开启回显直接拒绝启动
    throw new Error('生产环境禁止 ORDO_DEV_ECHO_CODE=1(契约 §7.6.5:响应绝不回显验证码)');
  }
  const pepperRaw = env.ORDO_CODE_PEPPER && env.ORDO_CODE_PEPPER.trim() !== '' ? env.ORDO_CODE_PEPPER.trim() : '';
  let codePepper = pepperRaw;
  if (!codePepper) {
    if (isProd) throw new Error('生产环境必须设置 ORDO_CODE_PEPPER(契约 §9:验证码只存 HMAC-SHA256 哈希)');
    // 开发/测试:回退到 JWT_SECRET(契约 §7.6.5 允许)
    codePepper = jwtSecret;
  }

  return {
    env: nodeEnv,
    host: env.HOST ?? '0.0.0.0',
    port: num(env, 'PORT', 8080),
    databaseUrl,
    dbPoolMax: num(env, 'DB_POOL_MAX', 10),
    jwtSecret,
    accessTtlSec: num(env, 'ACCESS_TTL_SEC', 30 * 60),
    refreshTtlDays: num(env, 'REFRESH_TTL_DAYS', 30),
    tzOffsetMinutes: num(env, 'TZ_OFFSET_MINUTES', 480),
    reminderScanMs: num(env, 'REMINDER_SCAN_MS', 1000),
    reminderHorizonMs: num(env, 'REMINDER_HORIZON_MS', 60_000),
    bodyLimitBytes: num(env, 'BODY_LIMIT_BYTES', 512 * 1024),
    maxOpsPerPush: num(env, 'MAX_OPS_PER_PUSH', 500),
    maxOpPayloadBytes: num(env, 'MAX_OP_PAYLOAD_BYTES', 256 * 1024),
    maxPullLimit: num(env, 'MAX_PULL_LIMIT', 1000),
    defaultPullLimit: num(env, 'DEFAULT_PULL_LIMIT', 200),
    tombstonePurgeIntervalMs: num(env, 'TOMBSTONE_PURGE_INTERVAL_MS', 5 * 60_000),
    tombstoneTtlMs: num(env, 'TOMBSTONE_TTL_MS', 30 * 24 * 60 * 60 * 1000),
    rateLimit: {
      enabled: bool(env, 'RATE_LIMIT_ENABLED', true),
      capacity: num(env, 'RATE_LIMIT_CAPACITY', 10),
      refillPerSec: num(env, 'RATE_LIMIT_REFILL_PER_SEC', 10)
    },
    emailCode: {
      ttlSec: num(env, 'ORDO_EMAIL_CODE_TTL_SEC', 300),
      retryAfterSec: num(env, 'ORDO_EMAIL_CODE_RETRY_AFTER_SEC', 60),
      maxPerHour: num(env, 'ORDO_EMAIL_CODE_MAX_PER_HOUR', 5),
      maxPerDay: num(env, 'ORDO_EMAIL_CODE_MAX_PER_DAY', 10),
      maxAttempts: num(env, 'ORDO_EMAIL_CODE_MAX_ATTEMPTS', 5),
      pepper: codePepper,
      devEchoCode
    },
    mail: {
      transport: mailTransport,
      httpUrl: mailHttpUrl,
      httpToken: env.ORDO_MAIL_HTTP_TOKEN && env.ORDO_MAIL_HTTP_TOKEN.trim() !== '' ? env.ORDO_MAIL_HTTP_TOKEN.trim() : null,
      httpTimeoutMs: num(env, 'ORDO_MAIL_HTTP_TIMEOUT_MS', 5000)
    },
    logLevel: env.LOG_LEVEL ?? (isProd ? 'info' : 'warn'),
    serverSideRepeat: bool(env, 'SERVER_SIDE_REPEAT', false)
  };
}
