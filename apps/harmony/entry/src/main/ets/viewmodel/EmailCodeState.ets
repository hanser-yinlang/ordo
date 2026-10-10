/**
 * Ordo · 邮箱验证码登录状态机(契约 docs/03-数据模型与同步协议.md §7.6.5 / 04-UI设计规范 §5.1)
 *
 * 契约要点(§7.6.5):
 *  - 验证码为 **6 位数字**,有效期 `expiresIn = 300s`,一次性消费;
 *  - 同一邮箱再次请求的最小间隔 `retryAfter = 60s`,客户端据此**跑倒计时并置灰按钮**;
 *  - 邮箱未注册 → 自动建号,已注册 → 直接登录,客户端不需要区分"登录 / 注册";
 *  - `devCode` 只在开发模式回显,客户端**不得依赖**。
 *
 * 为什么抽成纯状态机:倒计时(60s 置灰)、满 6 位自动提交、同一验证码只提交一次,这些判定
 * 都含时间量与"上一次提交了什么"的记忆,塞进组件里既测不了也容易写成"每敲一个数字就发一次请求"。
 * 本文件不依赖 ArkUI / @kit,**可被本机宿主直接执行**(见 _qa/node-harness 的 EmailCodeState.test)。
 */

/** 验证码位数(§7.6.5:6 位数字) */
export const EMAIL_CODE_LENGTH: number = 6;
/** 再次请求的最小间隔兜底(秒,§7.6.5:60;服务端会回 retryAfter,不给我方也给默认值) */
export const EMAIL_CODE_RESEND_SECONDS: number = 60;
/** 验证码有效期兜底(秒,§7.6.5:300) */
export const EMAIL_CODE_TTL_SECONDS: number = 300;
/**
 * 倒计时上限(秒)。服务端给异常大的 retryAfter(或"超小时/日上限"的限流)时,
 * 界面绝不能把按钮永久置灰 —— 最多显示 1 小时,超出的部分到点后再由服务端判定。
 */
export const EMAIL_CODE_MAX_RESEND_SECONDS: number = 3600;
/** 「获取验证码」按钮的常态文案 */
export const EMAIL_CODE_REQUEST_LABEL: string = '获取验证码';
/** 请求进行中的文案 */
export const EMAIL_CODE_REQUESTING_LABEL: string = '发送中…';
/** 倒计时文案后缀 */
export const EMAIL_CODE_COUNTDOWN_SUFFIX: string = 's 后重取';

/**
 * 验证码登录的界面状态机。
 *
 * 只保存"与时间有关"的状态(倒计时截止时刻、上一次提交的验证码),不碰网络:
 * 请求本身由 `AppStore.requestEmailCode / emailCodeLogin` 负责,它们把结果喂回这里。
 */
export class EmailCodeMachine {
  /** 冷却截止时刻(ms,0 = 无冷却) */
  private cooldownUntil: number = 0;
  /** 当前展示的剩余秒数(只在整秒变化时才更新 UI) */
  private remaining: number = 0;
  /** 「获取验证码」请求进行中 */
  private requesting: boolean = false;
  /** 已经自动提交过的验证码(同一串验证码不重复提交;失败后清空以便重试) */
  private lastSubmitted: string = '';
  /** 最近一次受理响应的有效期(秒) */
  private expiresIn: number = EMAIL_CODE_TTL_SECONDS;

  /* ------------------------------------------------------------ 请求与冷却 */

  /**
   * 受理响应(`202 {sent, expiresIn, retryAfter, devCode}`)→ 起倒计时。
   * `retryAfter <= 0` 时回落到契约的 60s(宁可多等,也不要在服务端限流时狂发请求)。
   */
  applySent(expiresIn: number, retryAfter: number, now: number): void {
    this.expiresIn = expiresIn > 0 ? Math.floor(expiresIn) : EMAIL_CODE_TTL_SECONDS;
    const seconds: number = EmailCodeMachine.clampSeconds(retryAfter);
    this.remaining = seconds;
    this.cooldownUntil = now + seconds * 1000;
  }

  private static clampSeconds(retryAfter: number): number {
    if (retryAfter <= 0) {
      return EMAIL_CODE_RESEND_SECONDS;
    }
    const whole: number = Math.ceil(retryAfter);
    return whole > EMAIL_CODE_MAX_RESEND_SECONDS ? EMAIL_CODE_MAX_RESEND_SECONDS : whole;
  }

  /** 请求开始(按钮显示"发送中…"并禁用,避免连点) */
  beginRequest(): void {
    this.requesting = true;
  }

  /** 请求结束(成功或失败都要调用,否则按钮会永远停在"发送中…") */
  endRequest(): void {
    this.requesting = false;
  }

  isRequesting(): boolean {
    return this.requesting;
  }

  /** 当前剩余冷却秒数(0 = 可以请求) */
  remainingSeconds(now: number): number {
    if (this.cooldownUntil <= 0 || this.cooldownUntil <= now) {
      return 0;
    }
    const left: number = Math.ceil((this.cooldownUntil - now) / 1000);
    return left > EMAIL_CODE_MAX_RESEND_SECONDS ? EMAIL_CODE_MAX_RESEND_SECONDS : left;
  }

  isCountingDown(now: number): boolean {
    return this.remainingSeconds(now) > 0;
  }

  /** 是否可以请求验证码:不在请求中,且冷却已过 */
  canRequest(now: number): boolean {
    return !this.requesting && this.cooldownUntil <= now;
  }

  /**
   * 时间推进(登录页每秒调一次)。
   * @returns 展示文案是否发生变化 —— 只有变了才需要让界面重绘,避免每秒无谓刷新。
   */
  tick(now: number): boolean {
    if (this.cooldownUntil <= 0) {
      return false;
    }
    if (this.cooldownUntil <= now) {
      // 倒计时结束:清冷却,并返回一次"变化"让按钮从置灰恢复可点
      this.cooldownUntil = 0;
      const changed: boolean = this.remaining !== 0;
      this.remaining = 0;
      return changed;
    }
    const left: number = this.remainingSeconds(now);
    if (left === this.remaining) {
      return false;
    }
    this.remaining = left;
    return true;
  }

  /** 按钮文案:获取验证码 / 60s 后重取 / 发送中… */
  resendLabel(now: number): string {
    if (this.requesting) {
      return EMAIL_CODE_REQUESTING_LABEL;
    }
    const left: number = this.remainingSeconds(now);
    return left > 0 ? left.toString() + EMAIL_CODE_COUNTDOWN_SUFFIX : EMAIL_CODE_REQUEST_LABEL;
  }

  /** 最近一次受理响应的有效期(秒,默认 300) */
  expiresInSeconds(): number {
    return this.expiresIn;
  }

  /** 退出登录 / 会话失效 / 登录成功:清空倒计时与提交记忆 */
  reset(): void {
    this.cooldownUntil = 0;
    this.remaining = 0;
    this.requesting = false;
    this.lastSubmitted = '';
    this.expiresIn = EMAIL_CODE_TTL_SECONDS;
  }

  /* ------------------------------------------------------------ 验证码输入 */

  /** 只保留数字并截到 6 位(粘贴带空格/字母的串也能用) */
  static normalizeCode(raw: string): string {
    let out: string = '';
    for (let i = 0; i < raw.length && out.length < EMAIL_CODE_LENGTH; i++) {
      const ch: string = raw.charAt(i);
      if (ch >= '0' && ch <= '9') {
        out = out + ch;
      }
    }
    return out;
  }

  /** 是否满 6 位数字(§7.6.5:验证码格式不合法服务端会回 400,客户端先挡一道) */
  static isCompleteCode(code: string): boolean {
    if (code.length !== EMAIL_CODE_LENGTH) {
      return false;
    }
    for (let i = 0; i < code.length; i++) {
      const ch: string = code.charAt(i);
      if (ch < '0' || ch > '9') {
        return false;
      }
    }
    return true;
  }

  /**
   * 开发模式回显的 `devCode`:只有确实是 6 位数字才接受,否则返回空串。
   * 生产环境该字段恒为空,界面必须能在"没有回显"时正常工作(**不得依赖**)。
   */
  static validDevCode(raw: string): string {
    const digits: string = EmailCodeMachine.normalizeCode(raw);
    return EmailCodeMachine.isCompleteCode(digits) ? digits : '';
  }

  /**
   * 满 6 位是否应当**自动提交**(§5.1 的免密体验:填满即登录)。
   * 同一串验证码只提交一次:失败后 `markSubmitFailed()` 清空记忆,用户可以重试;
   * 用户不改验证码就重复触发 onChange 时不会被重复提交。
   */
  shouldAutoSubmit(code: string): boolean {
    if (this.requesting) {
      return false;
    }
    if (!EmailCodeMachine.isCompleteCode(code)) {
      return false;
    }
    return code !== this.lastSubmitted;
  }

  /** 记下已提交的验证码 */
  markSubmitted(code: string): void {
    this.lastSubmitted = EmailCodeMachine.normalizeCode(code);
  }

  /** 提交失败:允许同一串验证码再次自动提交(网络抖动时用户不必改一位再删掉) */
  markSubmitFailed(): void {
    this.lastSubmitted = '';
  }

  /** 测试/界面调试用:当前已提交的验证码 */
  lastSubmittedCode(): string {
    return this.lastSubmitted;
  }
}
