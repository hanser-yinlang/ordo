/**
 * 可插拔发信通道 —— 契约 §7.6.5 / §9(v1.3 邮箱验证码登录)。
 *
 * 两个通道,同一接口:
 *   · `console`(默认):把邮件写进服务端日志,适合本地开发与自动化测试。
 *     **代码只在非生产环境打印**(契约 §9:服务端日志不得打印验证码,开发模式除外);
 *     生产环境用 console 通道会打印一条"未投递"警告且**不含验证码**。
 *   · `http`:POST `{to,subject,text}` 到通用邮件网关(带 `Authorization: Bearer <token>`),
 *     任何非 2xx / 网络错误都视为发信失败 → 上层返回 500 `INTERNAL` + `details.reason='mail_failed'`。
 *
 * 只用 Node 内建 `fetch`,不引新依赖(与仓库「无额外依赖」的取舍一致)。
 */
import { AppConfig, MailTransport } from '../config';

export interface MailMessage {
  to: string;
  subject: string;
  text: string;
}

export interface MailSender {
  readonly kind: MailTransport;
  /**
   * 结构化日志出口。`app.ts` 在 Fastify 实例建好后把它接到 `app.log`
   * (与 TombstonePurger.logger 同一手法),保证 console 通道的开发回显、
   * http 通道的投递结果都走同一份结构化日志。
   */
  logger?: MailLogger;
  send(message: MailMessage): Promise<void>;
}

/** 结构化日志接口(Fastify 的 app.log 满足它);测试可注入内存实现 */
export interface MailLogger {
  info(obj: Record<string, unknown>, msg: string): void;
  warn(obj: Record<string, unknown>, msg: string): void;
}

/** 默认写 stdout,保证脱离 Fastify 单独使用 MailSender 时也有输出 */
const defaultLogger: MailLogger = {
  info: (obj, msg) => console.log(JSON.stringify({ level: 'info', ...obj, msg })),
  warn: (obj, msg) => console.warn(JSON.stringify({ level: 'warn', ...obj, msg }))
};

export class ConsoleMailSender implements MailSender {
  readonly kind = 'console' as const;

  /**
   * @param printCode 是否在日志里打印验证码正文(仅**非生产**环境允许,契约 §9)
   */
  constructor(private printCode: boolean, public logger: MailLogger = defaultLogger) {}

  async send(message: MailMessage): Promise<void> {
    if (this.printCode) {
      this.logger.info(
        { transport: 'console', to: message.to, subject: message.subject },
        `[mail] 验证码邮件(开发模式,仅日志投递):${message.text}`
      );
      return;
    }
    // 生产环境:绝不把验证码写进日志(契约 §9)。这条警告用来提示"邮件其实没发出去"。
    this.logger.warn(
      { transport: 'console', to: message.to },
      '[mail] ORDO_MAIL_TRANSPORT=console 不会真的投递邮件;生产环境请配置 ORDO_MAIL_TRANSPORT=http'
    );
  }
}

export class HttpMailSender implements MailSender {
  readonly kind = 'http' as const;

  constructor(
    private url: string,
    private token: string | null,
    private timeoutMs: number,
    public logger: MailLogger = defaultLogger
  ) {}

  async send(message: MailMessage): Promise<void> {
    const res = await fetch(this.url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(this.token ? { authorization: `Bearer ${this.token}` } : {})
      },
      body: JSON.stringify({ to: message.to, subject: message.subject, text: message.text }),
      signal: AbortSignal.timeout(this.timeoutMs)
    });
    if (!res.ok) {
      // 只记状态码,不记正文 —— 正文里有验证码(契约 §9)
      throw new Error(`mail gateway responded ${res.status}`);
    }
    this.logger.info({ transport: 'http', to: message.to, status: res.status }, '[mail] 验证码邮件已投递');
  }
}

/**
 * 按配置构造通道。
 *
 * 生产环境**不会**用 console 通道打印验证码(即使 ORDO_DEV_ECHO_CODE 被绕过,
 * loadConfig 也已经在启动时拒绝了生产 + 回显的组合)。
 */
export function createMailSender(config: AppConfig, logger: MailLogger = defaultLogger): MailSender {
  if (config.mail.transport === 'http') {
    // loadConfig 已保证 http 通道一定有 URL;这里再兜一层,避免绕过 loadConfig 直接构造 config
    if (!config.mail.httpUrl) throw new Error('ORDO_MAIL_TRANSPORT=http 时必须设置 ORDO_MAIL_HTTP_URL');
    return new HttpMailSender(config.mail.httpUrl, config.mail.httpToken, config.mail.httpTimeoutMs, logger);
  }
  return new ConsoleMailSender(config.env !== 'production', logger);
}
