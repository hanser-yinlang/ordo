/**
 * Ordo · 登录门禁(04-UI设计规范 §5.1 登录页 / 契约 §7.6 账号、会话与游客)
 *
 * 产品要求(§5.1 硬约束):
 *  - 必须同时存在**三个入口**:登录 / 注册 / 游客登录;
 *  - 游客登录与正式登录**体验对等**(都能同步,不得做成"功能受限"的灰色入口);
 *  - 触控目标 ≥44;口令框有可读标签;错误不靠颜色单独表达(同时给文字)。
 *
 * 布局(§5.1):
 *  - 整屏居中卡片,宽 400,高自适应(约 430~480);卡片 radius 16 + 12dp 投影;
 *    画布 = canvas + 一层极淡的品牌渐变光晕(透明度 ≤6%,见 pages/Index.ets 与本文件 LoginPage)
 *  - 自上而下:品牌区(56 图标 + 「Ordo」24/32 600 + 副标题)→ 输入区(邮箱、口令带显示/隐藏)
 *    → 主按钮(高 44,radius 10,accent,登录/注册)→ 错误区(固定预留 20 高)
 *    → 次要入口「以游客身份继续」(surface 底 + hairline 描边,**与主按钮同级**)
 *    → 底部居中文本链接(还没有账号?注册 / 已有账号?登录)
 *
 * 动效(§5.1):
 *  - 进入登录页:fade + 上移 12px,220ms;输入框聚焦边框转 accent 120ms;
 *    主按钮按压 scale 0.98(90ms);提交中按钮内转圈 + 输入框禁用 + 游客按钮禁用;
 *    登录成功:卡片 fade out 160ms → 主界面 fade in 220ms(后者见 pages/Index.ets)
 *  - 错误:振幅 6px、320ms、衰减两次的左右抖动
 *
 * 本轮的视觉打磨(对照真机截图后逐条改):
 *  1. **浮动标签真正浮起来**:标签改挂 `Alignment.TopStart` 并对齐到固定基线,
 *     空态停在中线、聚焦/有内容时上移并缩到 11 号 —— 之前用 `Alignment.Start` 居中再位移,
 *     实际渲染时标签被压在输入文字后面,看着像"没有标签的光板输入框"。
 *  2. **口令显隐换成眼睛图标**(椭圆 + 瞳孔 + 斜杠,全部用 ArkUI 形状组件画,不引资源),
 *     替掉原来那个灰字「显示/隐藏」;点击区仍是 44×44(§8)。
 *  3. **输入框底色改为画布色 + 1 发丝描边**,聚焦转 accent —— 原来的 chipBg 在浅色下是一块
 *     偏重的暖灰,和白色卡片叠在一起显脏。
 *  4. **游客入口去掉那个孤立箭头字形**(「→」在鸿蒙上会走字体回退、渲染成一个蓝色圆圈箭头),
 *     只留同级次要按钮的形态,和主按钮等宽等高。
 *  5. **服务器设置移到卡片外**,做成一行极轻的脚注(右侧只显示 host,不显示完整 URL),
 *     展开后才出现输入框与「保存 / 恢复默认」。登录卡片只保留 §5.1 规定的三段结构。
 *  6. 主按钮在可提交时带一层很淡的 accent 投影;卡片投影放宽到 32/16,减少"贴纸感"。
 *
 * 本轮新增「验证码登录」(契约 §7.6.5,免密登录):
 *  - 与口令登录**同级切换**:卡片里品牌区下方是两个并列页签(口令登录 / 验证码登录),
 *    不是藏在角落的小字入口;§5.1 的三个入口(登录 / 注册 / 游客)在两种模式下都够得着。
 *  - 验证码模式 = 邮箱 + 6 位验证码 + 「获取验证码」(按响应 `retryAfter` 跑 60s 倒计时置灰),
 *    **满 6 位自动提交**;错误沿用同一个错误区与抖动。
 *  - 倒计时与"同一验证码只提交一次"全部在 `viewmodel/EmailCodeState.ets`(纯逻辑,本机宿主可测),
 *    组件只负责画与转发。
 *  - `devCode`(仅开发模式回显)返回就自动填入;**生产恒为空,界面不依赖它**。
 */

import { AppStore, DEFAULT_BASE_URL } from '../viewmodel/AppStore.ets';
import { EmailCodeMachine, EMAIL_CODE_LENGTH } from '../viewmodel/EmailCodeState.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoIcons, OrdoMotion, OrdoRadius, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';

/** 登录卡片圆角:§5.1 明确写 16(令牌 OrdoRadius.sheet 是 14,登录卡片按 §5.1 取 16) */
const LOGIN_CARD_RADIUS: number = 16;
/** 输入框高 56;浮动标签的左右基线 */
const FIELD_HEIGHT: number = 56;
const LABEL_INSET: number = 14;
/** 标签"浮起"后的顶距 与 空态停靠的顶距(相对输入框顶部) */
const LABEL_FLOAT_Y: number = 9;
const LABEL_REST_Y: number = 19;
/** 口令显隐按钮的点击区(§8 触控目标 ≥44) */
const EYE_HIT: number = 44;
/** 验证码输入框右侧「获取验证码」按钮的点击区(§8 触控目标 ≥44) */
const CODE_ACTION_HIT: number = 44;
/** 登录方式页签的高度(§8:触控目标 ≥44) */
const MODE_TAB_HEIGHT: number = 44;

@Component
export struct LoginGate {
  @ObjectLink store: AppStore;
  /** 登录成功、正在播放 160ms 淡出(由 Index 在 authPhase = 'entering' 时置位) */
  @Prop leaving: boolean = false;

  /** 主按钮语义:false = 登录,true = 注册(两模式切换,§5.1) */
  @State private registerMode: boolean = false;
  /**
   * 登录方式:false = 邮箱 + 口令(含注册),true = 邮箱验证码(免密,契约 §7.6.5)。
   * 两者**同级**,由卡片顶部页签切换。
   */
  @State private codeMode: boolean = false;
  @State private email: string = '';
  @State private password: string = '';
  @State private code: string = '';
  @State private showPassword: boolean = false;
  @State private emailFocus: boolean = false;
  @State private passwordFocus: boolean = false;
  @State private codeFocus: boolean = false;
  /** 进入动效的终态(aboutToAppear 后一帧置位,产生 fade + 上移 12px) */
  @State private entered: boolean = false;
  /** 错误抖动位移 */
  @State private shakeX: number = 0;
  @State private serverOpen: boolean = false;
  @State private serverDraft: string = '';
  /** 验证码倒计时的秒表(每秒 tick 一次,由状态机决定要不要重绘) */
  private tickTimer: number = -1;

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
  }

  aboutToAppear(): void {
    this.registerMode = this.store.loginPrefersRegister;
    this.email = this.store.accountEmail;
    this.serverDraft = this.store.serverText();
    // 下一帧再进入终态,否则首帧就是终态、动效不播
    setTimeout((): void => {
      this.entered = true;
    }, 0);
    // 验证码倒计时:每秒推一次(状态机只在"秒数真的变了"时要求重绘)
    this.tickTimer = setInterval((): void => {
      this.store.tickEmailCode();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  private busy(): boolean {
    return this.store.loginBusy;
  }

  private errorTextOf(): string {
    return this.store.loginError;
  }

  private canSubmit(): boolean {
    if (this.busy()) {
      return false;
    }
    if (this.email.trim().length === 0) {
      return false;
    }
    if (this.codeMode) {
      return this.code.length === EMAIL_CODE_LENGTH;
    }
    return this.password.length > 0;
  }

  private emailFloating(): boolean {
    return this.emailFocus || this.email.length > 0;
  }

  private passwordFloating(): boolean {
    return this.passwordFocus || this.password.length > 0;
  }

  private codeFloating(): boolean {
    return this.codeFocus || this.code.length > 0;
  }

  /** 主按钮色调:可提交 accent,否则 chipBg(禁用态) */
  private submitBg(): string {
    return this.canSubmit() ? this.c().accentPrimary : this.c().chipBg;
  }

  private submitFg(): string {
    return this.canSubmit() ? '#FFFFFF' : this.c().textTertiary;
  }

  /** 可提交时给主按钮一层很淡的 accent 投影,让主操作"浮"起来;禁用态不带投影 */
  private submitShadow(): ShadowOptions {
    if (!this.canSubmit()) {
      return { radius: 0, color: 'rgba(0,0,0,0)', offsetX: 0, offsetY: 0 };
    }
    return { radius: 14, color: 'rgba(91,91,214,0.28)', offsetX: 0, offsetY: 6 };
  }

  /** 脚注只显示 host(去掉 https://),少一点视觉噪音 */
  private shortHost(): string {
    const url: string = this.store.serverText();
    const at: number = url.indexOf('://');
    return at >= 0 ? url.substring(at + 3) : url;
  }

  /**
   * 错误抖动:振幅 6px、320ms、衰减两次(§5.1)。
   * 用关键帧一次编排完 5 段(6 / -6 / 3 / -3 / 0,每段 64ms),而不是靠定时器多次改状态 ——
   * 定时器版本在快速重试时会互相打断,关键帧是原子的。
   */
  private shake(): void {
    this.getUIContext().keyframeAnimateTo({ delay: 0, iterations: 1 }, [
      { duration: 64, curve: Curve.Linear, event: (): void => { this.shakeX = OrdoMotion.errorShakeAmp; } },
      { duration: 64, curve: Curve.Linear, event: (): void => { this.shakeX = -OrdoMotion.errorShakeAmp; } },
      { duration: 64, curve: Curve.Linear, event: (): void => { this.shakeX = OrdoMotion.errorShakeAmp / 2; } },
      { duration: 64, curve: Curve.Linear, event: (): void => { this.shakeX = -OrdoMotion.errorShakeAmp / 2; } },
      { duration: 64, curve: Curve.Linear, event: (): void => { this.shakeX = 0; } }
    ]);
  }

  private async submit(): Promise<void> {
    if (this.busy()) {
      return;
    }
    if (this.email.trim().length === 0 || this.password.length === 0) {
      this.store.loginError = '请先填写邮箱与口令';
      this.store.bump();
      this.shake();
      return;
    }
    const mail: string = this.email;
    const secret: string = this.password;
    const ok: boolean = this.registerMode
      ? await this.store.register(mail, secret)
      : await this.store.login(mail, secret);
    if (ok) {
      this.password = '';
      return;
    }
    this.shake();
  }

  /** 游客登录:与正式登录同级、同流程(契约 §7.6.2「游客不是离线模式」) */
  private async guest(): Promise<void> {
    if (this.busy()) {
      return;
    }
    const ok: boolean = await this.store.continueAsGuest();
    if (!ok) {
      this.shake();
    }
  }

  /**
   * 验证码模式提交(§7.6.5)。
   * 满 6 位时由 onChange 自动调用;**同一验证码只自动提交一次**(状态机去重),
   * 因此主按钮也走同一条路径:自动提交被去重挡住时,用户可以手动再点。
   */
  private async submitCode(): Promise<void> {
    if (this.busy()) {
      return;
    }
    if (this.email.trim().length === 0 || this.code.length !== EMAIL_CODE_LENGTH) {
      this.store.loginError = '请先填写邮箱与 6 位验证码';
      this.store.bump();
      this.shake();
      return;
    }
    const mail: string = this.email;
    const digits: string = this.code;
    const ok: boolean = await this.store.emailCodeLogin(mail, digits, this.store.deviceId);
    if (ok) {
      this.code = '';
      return;
    }
    this.shake();
  }

  /** 满 6 位自动提交(§5.1 的免密体验;判定与去重都在 EmailCodeMachine 里) */
  private maybeAutoSubmitCode(): void {
    if (this.store.shouldAutoSubmitCode(this.code)) {
      this.submitCode();
    }
  }

  /**
   * 「获取验证码」(§7.6.5)。
   * 成功后按响应 `retryAfter` 起倒计时(按钮置灰);开发模式回显 `devCode` 时自动填入并尝试自动提交
   * —— 生产环境没有回显,照常由用户手输。
   */
  private async requestCode(): Promise<void> {
    if (!this.store.codeCanRequest()) {
      return;
    }
    const ok: boolean = await this.store.requestEmailCode(this.email);
    if (!ok) {
      this.shake();
      return;
    }
    const dev: string = this.store.devEchoCode();
    if (dev.length === EMAIL_CODE_LENGTH) {
      this.code = dev;
      this.maybeAutoSubmitCode();
    }
  }

  /** 登录方式页签切换(两个页签同级;§5.1 的三个入口在两种模式下都还在) */
  private switchMode(codeMode: boolean): void {
    if (this.codeMode === codeMode) {
      return;
    }
    this.codeMode = codeMode;
    this.codeFocus = false;
    this.store.loginError = '';
    this.store.bump();
  }

  private toggleMode(): void {
    if (this.codeMode) {
      // 验证码模式下底部链接是「还没有账号?注册」:切回口令模式并停在注册页签
      this.registerMode = true;
      this.store.setLoginPrefersRegister(true);
      this.switchMode(false);
      return;
    }
    this.registerMode = !this.registerMode;
    this.store.setLoginPrefersRegister(this.registerMode);
  }

  /* ------------------------------------------------------------ 方式页签 */

  /**
   * 登录方式页签。与口令登录**同级**:等宽、等高的两段,选中项 accent 文字 + 2px 指示条,
   * 未选中项 textTertiary(文字本身就区分了状态,不靠颜色单独表达)。
   * `tabId` 供 `uitest dumpLayout` / 自动化点击定位(与 `ordo_login_email` 同一约定)。
   */
  @Builder
  modeTab(label: string, forCode: boolean, tabId: string) {
    Column() {
      Text(label)
        .fontSize(OrdoFont.body.size)
        .fontWeight(this.codeMode === forCode ? 600 : 400)
        .fontColor(this.codeMode === forCode ? this.c().accentPrimary : this.c().textTertiary)
        .animation({ duration: OrdoMotion.loginFieldFocus, curve: Curve.FastOutSlowIn })
      Row()
        .width(this.codeMode === forCode ? 28 : 0)
        .height(2)
        .borderRadius(1)
        .backgroundColor(this.c().accentPrimary)
        .margin({ top: 6 })
    }
    .layoutWeight(1)
    .height(MODE_TAB_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .id(tabId)
    .onClick((): void => {
      this.switchMode(forCode);
    })
  }

  @Builder
  modeTabs() {
    Column() {
      Row() {
        this.modeTab('口令登录', false, 'ordo_login_tab_password')
        this.modeTab('验证码登录', true, 'ordo_login_tab_code')
      }
      .width('100%')
      .height(MODE_TAB_HEIGHT)

      Row()
        .width('100%')
        .height(1)
        .backgroundColor(this.c().lineHairline)
    }
    .width('100%')
  }

  /* ------------------------------------------------------------ 品牌区 */

  @Builder
  brand() {
    Column({ space: OrdoSpace.s }) {
      Image($r('app.media.app_icon'))
        .width(56)
        .height(56)
        .borderRadius(OrdoRadius.card)
        .draggable(false)
      Text('Ordo')
        .fontSize(24)
        .lineHeight(32)
        .fontWeight(600)
        .fontColor(this.c().textPrimary)
      Text('把今天理清楚')
        .fontSize(OrdoFont.caption.size)
        .fontColor(this.c().textSecondary)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /* ------------------------------------------------------------ 输入区(浮动标签) */

  /**
   * 浮动标签。
   * 关键点:父层 Stack 用 `Alignment.TopStart`,标签的 y 直接就是"距输入框顶部的距离",
   * 空态 19(与 15 号正文视觉中线齐平)、浮起 9(11 号小标签),两者之间 120ms 过渡。
   */
  @Builder
  floatLabel(text: string, floating: boolean, focused: boolean) {
    Text(text)
      .fontSize(floating ? OrdoFont.micro.size : OrdoFont.body.size)
      .fontColor(focused ? this.c().accentPrimary : this.c().textTertiary)
      .margin({ left: LABEL_INSET })
      .translate({ y: floating ? LABEL_FLOAT_Y : LABEL_REST_Y })
      .animation({ duration: OrdoMotion.loginFieldFocus, curve: Curve.FastOutSlowIn })
      // 标签只是视觉层,触摸必须穿透到下面的输入框
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  emailField() {
    Stack({ alignContent: Alignment.TopStart }) {
      TextInput({ text: this.email })
        .type(InputType.Email)
        .id('ordo_login_email')
        .width('100%')
        .height(FIELD_HEIGHT)
        .padding({ left: LABEL_INSET, right: LABEL_INSET, top: 20, bottom: 2 })
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textPrimary)
        .caretColor(this.c().accentPrimary)
        .backgroundColor(Color.Transparent)
        .enabled(!this.busy())
        .onFocus((): void => {
          this.emailFocus = true;
        })
        .onBlur((): void => {
          this.emailFocus = false;
        })
        .onChange((value: string): void => {
          this.email = value;
          this.store.loginError = '';
          this.store.bump();
        })
        .onSubmit((): void => {
          // 邮箱框回车:口令模式提交口令,验证码模式交给"满 6 位自动提交"的同一判据
          if (this.codeMode) {
            this.maybeAutoSubmitCode();
          } else {
            this.submit();
          }
        })
      this.floatLabel('邮箱', this.emailFloating(), this.emailFocus)
    }
    .width('100%')
    .height(FIELD_HEIGHT)
    .backgroundColor(this.c().bgCanvas)
    .borderRadius(OrdoRadius.row)
    .border({
      width: this.emailFocus ? 1.5 : 1,
      color: this.emailFocus ? this.c().accentPrimary : this.c().lineHairline
    })
    .animation({ duration: OrdoMotion.loginFieldFocus, curve: Curve.FastOutSlowIn })
  }

  /**
   * 口令显隐。用形状画一只眼睛:椭圆眼形 + 瞳孔,隐藏态再叠一条斜杠。
   * 全部走 ArkUI 形状组件(不引 svg、不依赖系统符号字体),深浅色都吃当前描边色。
   */
  @Builder
  passwordEye() {
    Stack() {
      Ellipse()
        .width(20)
        .height(12)
        .fill(Color.Transparent)
        .stroke(this.c().textSecondary)
        .strokeWidth(1.4)
      Circle()
        .width(4.5)
        .height(4.5)
        .fill(this.c().textSecondary)
      if (!this.showPassword) {
        Line()
          .width(20)
          .height(12)
          .startPoint([0, 0])
          .endPoint([20, 12])
          .stroke(this.c().textSecondary)
          .strokeWidth(1.4)
          .strokeLineCap(LineCapStyle.Round)
      }
    }
    .width(EYE_HIT)
    .height(EYE_HIT)
    .onClick((): void => {
      this.showPassword = !this.showPassword;
    })
  }

  @Builder
  passwordField() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        TextInput({ text: this.password })
          .type(this.showPassword ? InputType.Normal : InputType.Password)
          // 自带的"眼睛"关掉:显示/隐藏由右侧自绘按钮负责(§5.1、§8 触控目标 ≥44)
          .showPasswordIcon(false)
          .id('ordo_login_password')
          .layoutWeight(1)
          .height(FIELD_HEIGHT)
          .padding({ left: LABEL_INSET, right: OrdoSpace.xs, top: 20, bottom: 2 })
          .fontSize(OrdoFont.body.size)
          .fontColor(this.c().textPrimary)
          .caretColor(this.c().accentPrimary)
          .backgroundColor(Color.Transparent)
          .enabled(!this.busy())
          .onFocus((): void => {
            this.passwordFocus = true;
          })
          .onBlur((): void => {
            this.passwordFocus = false;
          })
          .onChange((value: string): void => {
            this.password = value;
            this.store.loginError = '';
            this.store.bump();
          })
          .onSubmit((): void => {
            this.submit();
          })
        this.passwordEye()
      }
      .width('100%')
      .height(FIELD_HEIGHT)
      .alignItems(VerticalAlign.Center)

      this.floatLabel('口令', this.passwordFloating(), this.passwordFocus)
    }
    .width('100%')
    .height(FIELD_HEIGHT)
    .backgroundColor(this.c().bgCanvas)
    .borderRadius(OrdoRadius.row)
    .border({
      width: this.passwordFocus ? 1.5 : 1,
      color: this.passwordFocus ? this.c().accentPrimary : this.c().lineHairline
    })
    .animation({ duration: OrdoMotion.loginFieldFocus, curve: Curve.FastOutSlowIn })
  }

  /**
   * 验证码输入(§7.6.5):6 位数字 + 右侧「获取验证码」。
   * 沿用口令框的基线:Stack(`Alignment.TopStart`)+ 固定基线浮动标签 + 画布底 + 发丝描边;
   * 只把右侧的眼睛换成文本按钮(点击区同样 ≥44,§8)。
   */
  @Builder
  codeField() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        TextInput({ text: this.code })
          .type(InputType.Number)
          .maxLength(EMAIL_CODE_LENGTH)
          .id('ordo_login_code')
          .layoutWeight(1)
          .height(FIELD_HEIGHT)
          .padding({ left: LABEL_INSET, right: OrdoSpace.xs, top: 20, bottom: 2 })
          .fontSize(OrdoFont.body.size)
          .fontColor(this.c().textPrimary)
          .caretColor(this.c().accentPrimary)
          .backgroundColor(Color.Transparent)
          .enabled(!this.busy())
          .onFocus((): void => {
            this.codeFocus = true;
          })
          .onBlur((): void => {
            this.codeFocus = false;
          })
          .onChange((value: string): void => {
            // 只留数字并截到 6 位(粘贴带空格/连字符的验证码也能用);满 6 位立刻自动提交
            this.code = EmailCodeMachine.normalizeCode(value);
            this.store.loginError = '';
            this.store.bump();
            this.maybeAutoSubmitCode();
          })
          .onSubmit((): void => {
            this.submitCode();
          })
        this.codeRequestButton()
      }
      .width('100%')
      .height(FIELD_HEIGHT)
      .alignItems(VerticalAlign.Center)

      this.floatLabel('验证码', this.codeFloating(), this.codeFocus)
    }
    .width('100%')
    .height(FIELD_HEIGHT)
    .backgroundColor(this.c().bgCanvas)
    .borderRadius(OrdoRadius.row)
    .border({
      width: this.codeFocus ? 1.5 : 1,
      color: this.codeFocus ? this.c().accentPrimary : this.c().lineHairline
    })
    .animation({ duration: OrdoMotion.loginFieldFocus, curve: Curve.FastOutSlowIn })
  }

  /**
   * 「获取验证码」。倒计时期间文字转 `textTertiary` 且不可点(§7.6.5:按 retryAfter 置灰),
   * 请求中显示 14 转圈。点击区高 44 满足 §8。
   */
  @Builder
  codeRequestButton() {
    Row() {
      if (this.store.codeRequesting()) {
        LoadingProgress()
          .width(14)
          .height(14)
          .color(this.c().textTertiary)
      } else {
        Text(this.store.codeButtonLabel())
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.store.codeCanRequest() ? this.c().accentPrimary : this.c().textTertiary)
          .maxLines(1)
      }
    }
    .height(CODE_ACTION_HIT)
    .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
    .margin({ right: OrdoSpace.xs })
    .id('ordo_login_get_code')
    .enabled(this.store.codeCanRequest())
    .onClick((): void => {
      this.requestCode();
    })
  }

  /* ------------------------------------------------------------ 按钮 */

  @Builder
  primaryButton() {
    Row({ space: OrdoSpace.s }) {
      if (this.busy()) {
        LoadingProgress()
          .width(OrdoMotion.loginSpinner)
          .height(OrdoMotion.loginSpinner)
          .color(this.submitFg())
      }
      Text(this.codeMode ? '登录' : (this.registerMode ? '注册' : '登录'))
        .fontSize(OrdoFont.body.size)
        .fontWeight(500)
        .fontColor(this.submitFg())
    }
    .width('100%')
    .height(OrdoMotion.loginButtonHeight)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.submitBg())
    .borderRadius(OrdoRadius.row)
    .shadow(this.submitShadow())
    .stateStyles({
      pressed: { .scale({ x: OrdoMotion.loginPressScale, y: OrdoMotion.loginPressScale }) },
      normal: { .scale({ x: 1, y: 1 }) }
    })
    .animation({ duration: OrdoMotion.loginPress, curve: Curve.FastOutSlowIn })
    .enabled(!this.busy())
    .id('ordo_login_submit')
    .onClick((): void => {
      if (this.codeMode) {
        // 验证码模式:满 6 位本该已经自动提交,这里是"去重挡住后用户手动再点"的入口
        this.submitCode();
      } else {
        this.submit();
      }
    })
  }

  /**
   * 次要入口「以游客身份继续」。
   * §5.1 硬约束:它必须**与主按钮同级**(surface 底 + hairline 描边,同高 44),
   * 而不是灰色小字 —— 因为游客同样入库、同样多端同步,只是没有邮箱口令。
   */
  @Builder
  guestButton() {
    Row() {
      Text(this.busy() ? '请稍候…' : '以游客身份继续')
        .fontSize(OrdoFont.body.size)
        .fontWeight(500)
        .fontColor(this.busy() ? this.c().textTertiary : this.c().textPrimary)
    }
    .width('100%')
    .height(OrdoMotion.loginButtonHeight)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.c().bgSurface)
    .borderRadius(OrdoRadius.row)
    .border({ width: 1, color: this.c().lineHairline })
    .stateStyles({
      pressed: { .scale({ x: OrdoMotion.loginPressScale, y: OrdoMotion.loginPressScale }) },
      normal: { .scale({ x: 1, y: 1 }) }
    })
    .animation({ duration: OrdoMotion.loginPress, curve: Curve.FastOutSlowIn })
    .enabled(!this.busy())
    .id('ordo_login_guest')
    .onClick((): void => {
      this.guest();
    })
  }

  /* ------------------------------------------------------------ 错误区(固定预留 20 高) */

  @Builder
  errorArea() {
    Row({ space: OrdoSpace.xs }) {
      if (this.errorTextOf().length > 0) {
        // 不靠颜色单独表达:同时给「!」图标与文字(§8)
        Text(OrdoIcons.warn)
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().stateDanger)
          .fontWeight(600)
        Text(this.errorTextOf())
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().stateDanger)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .id('ordo_login_error')
      }
    }
    .width('100%')
    .height(20)
    .justifyContent(FlexAlign.Center)
    .translate({ x: this.shakeX })
  }

  /* ------------------------------------------------------------ 服务器设置(卡片外的轻脚注) */

  @Builder
  serverFooter() {
    Column({ space: OrdoSpace.s }) {
      Row({ space: OrdoSpace.xs }) {
        Text(this.serverOpen ? '▾' : '▸')
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().textTertiary)
        Text('服务器设置')
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().textTertiary)
        Blank()
        Text(this.shortHost())
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 190 })
          .id('ordo_login_server_host')
      }
      .width('100%')
      .height(32)
      .padding({ left: OrdoSpace.s, right: OrdoSpace.s })
      .id('ordo_login_server_toggle')
      .onClick((): void => {
        this.serverOpen = !this.serverOpen;
      })

      if (this.serverOpen) {
        Column({ space: OrdoSpace.s }) {
          TextInput({ placeholder: DEFAULT_BASE_URL, text: this.serverDraft })
            .type(InputType.Normal)
            .height(OrdoMotion.loginButtonHeight)
            .fontSize(OrdoFont.caption.size)
            .fontColor(this.c().textPrimary)
            .caretColor(this.c().accentPrimary)
            .backgroundColor(this.c().bgCanvas)
            .borderRadius(OrdoRadius.row)
            .border({ width: 1, color: this.c().lineHairline })
            .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
            .id('ordo_login_server_input')
            .onChange((value: string): void => {
              this.serverDraft = value;
            })
          Row({ space: OrdoSpace.s }) {
            Text('保存')
              .fontSize(OrdoFont.caption.size)
              .fontWeight(500)
              .fontColor('#FFFFFF')
              .backgroundColor(this.c().accentPrimary)
              .height(32)
              .padding({ left: OrdoSpace.l, right: OrdoSpace.l })
              .borderRadius(OrdoRadius.pill)
              .textAlign(TextAlign.Center)
              .id('ordo_login_server_save')
              .onClick((): void => {
                this.store.setBaseUrl(this.serverDraft);
              })
            Text('恢复默认')
              .fontSize(OrdoFont.caption.size)
              .fontColor(this.c().textSecondary)
              .height(32)
              .padding({ left: OrdoSpace.l, right: OrdoSpace.l })
              .borderRadius(OrdoRadius.pill)
              .backgroundColor(this.c().chipBg)
              .textAlign(TextAlign.Center)
              .onClick((): void => {
                this.serverDraft = DEFAULT_BASE_URL;
                this.store.setBaseUrl(this.serverDraft);
              })
            Blank()
          }
          .width('100%')
        }
        .width('100%')
        .padding(OrdoSpace.m)
        .backgroundColor(this.c().bgSurface)
        .borderRadius(OrdoRadius.card)
        .border({ width: 1, color: this.c().lineHairline })
        .shadow({ radius: 16, color: 'rgba(28,27,25,0.08)', offsetX: 0, offsetY: 8 })
      }
    }
    .width('100%')
    .margin({ top: OrdoSpace.m })
  }

  /* ------------------------------------------------------------ 卡片 */

  @Builder
  card() {
    Column({ space: OrdoSpace.l }) {
      this.brand()

      // 登录方式与口令登录同级(§7.6.5 的免密入口,不做成角落小字)
      this.modeTabs()

      Column({ space: OrdoSpace.m }) {
        this.emailField()
        if (this.codeMode) {
          Column({ space: OrdoSpace.s }) {
            this.codeField()
            Text('验证码 ' + this.store.codeTtlText() + ',未注册的邮箱将自动创建账号')
              .fontSize(OrdoFont.micro.size)
              .fontColor(this.c().textTertiary)
              .width('100%')
              .padding({ left: LABEL_INSET, right: LABEL_INSET })
          }
          .width('100%')
        } else {
          this.passwordField()
        }
      }
      .width('100%')

      Column({ space: OrdoSpace.s }) {
        this.primaryButton()
        this.errorArea()
        this.guestButton()
      }
      .width('100%')

      // 底部一行居中文本链接:验证码模式 → 还没有账号?注册(切回口令注册);
      // 口令模式:登录态 → 还没有账号?注册,注册态 → 已有账号?登录
      Text(this.codeMode ? '还没有账号?注册' : (this.registerMode ? '已有账号?登录' : '还没有账号?注册'))
        .fontSize(OrdoFont.caption.size)
        .fontColor(this.c().accentPrimary)
        .height(OrdoSize.minTouchTarget)
        .width('100%')
        .textAlign(TextAlign.Center)
        .onClick((): void => {
          this.toggleMode();
        })
    }
    .width('100%')
    .constraintSize({ minHeight: OrdoMotion.loginCardMinHeight })
    .padding(OrdoSpace.xl)
    .backgroundColor(this.c().bgSurface)
    .borderRadius(LOGIN_CARD_RADIUS)
    .border({ width: 1, color: this.c().lineHairline })
    .shadow({ radius: 32, color: 'rgba(28,27,25,0.10)', offsetX: 0, offsetY: 16 })
  }

  build() {
    Column() {
      this.card()
      this.serverFooter()
    }
    .width('100%')
    .constraintSize({ maxWidth: OrdoMotion.loginCardWidth })
    .opacity(this.leaving ? 0 : (this.entered ? 1 : 0))
    .translate({ y: this.entered ? 0 : OrdoMotion.loginEnterRise })
    .animation({
      duration: this.leaving ? OrdoMotion.loginCardFadeOut : OrdoMotion.loginEnter,
      curve: Curve.FastOutSlowIn
    })
  }
}

/**
 * 登录页独立入口。
 * 主流程并不跳转到这里:Index 在 `authPhase !== 'ready'` 时直接内联渲染 LoginGate,
 * 这样"卡片淡出 → 主界面淡入"能连成一镜。保留 @Entry 是为了深链直接进登录页(见 main_pages.json)。
 *
 * 外层用 Scroll 兜底:小屏(或大字体)下卡片可能高于可视区,滚动保证"以游客身份继续"
 * 和"服务器设置"永远够得着,而不是被裁掉。
 */
@Entry
@Component
struct LoginPage {
  @State store: AppStore = AppStore.instance();

  build() {
    Stack() {
      // 画布 + 极淡的品牌渐变光晕(透明度 ≤6%,不喧宾夺主,§5.1)
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#0F5B5BD6', 0.0], ['#005B5BD6', 1.0]]
        })
      Scroll() {
        Column() {
          LoginGate({ store: this.store })
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding(OrdoSpace.l)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(OrdoColors.of(this.store.isDark()).bgCanvas)
  }
}
