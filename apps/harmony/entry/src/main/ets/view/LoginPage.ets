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
 *    画布 = canvas + 一层极淡的品牌渐变光晕(透明度 ≤6%)
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
 */

import { AppStore, DEFAULT_BASE_URL } from '../viewmodel/AppStore.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoIcons, OrdoMotion, OrdoRadius, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';

@Component
export struct LoginGate {
  @ObjectLink store: AppStore;
  /** 登录成功、正在播放 160ms 淡出(由 Index 在 authPhase = 'entering' 时置位) */
  @Prop leaving: boolean = false;

  /** 主按钮语义:false = 登录,true = 注册(两模式切换,§5.1) */
  @State private registerMode: boolean = false;
  @State private email: string = '';
  @State private password: string = '';
  @State private showPassword: boolean = false;
  @State private emailFocus: boolean = false;
  @State private passwordFocus: boolean = false;
  /** 进入动效的终态(aboutToAppear 后一帧置位,产生 fade + 上移 12px) */
  @State private entered: boolean = false;
  /** 错误抖动位移 */
  @State private shakeX: number = 0;
  @State private serverOpen: boolean = false;
  @State private serverDraft: string = '';

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
  }

  private busy(): boolean {
    return this.store.loginBusy;
  }

  private errorTextOf(): string {
    return this.store.loginError;
  }

  private canSubmit(): boolean {
    return !this.busy() && this.email.trim().length > 0 && this.password.length > 0;
  }

  private emailFloating(): boolean {
    return this.emailFocus || this.email.length > 0;
  }

  private passwordFloating(): boolean {
    return this.passwordFocus || this.password.length > 0;
  }

  /** 主按钮色调:可提交 accent,否则 tertiary(禁用态) */
  private submitBg(): string {
    return this.canSubmit() ? this.c().accentPrimary : this.c().chipBg;
  }

  private submitFg(): string {
    return this.canSubmit() ? '#FFFFFF' : this.c().textTertiary;
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

  private toggleMode(): void {
    this.registerMode = !this.registerMode;
    this.store.setLoginPrefersRegister(this.registerMode);
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

  @Builder
  emailField() {
    Stack({ alignContent: Alignment.Start }) {
      TextInput({ text: this.email })
        .type(InputType.Email)
        .id('ordo_login_email')
        .width('100%')
        .height(56)
        .padding({ left: OrdoSpace.m, right: OrdoSpace.m, top: 18 })
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textPrimary)
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
          this.submit();
        })
      // 浮动标签:未聚焦且为空时充当占位符(18),聚焦或有内容时上移 12px 并缩为 11 号(§5.1)
      Text('邮箱')
        .fontSize(this.emailFloating() ? OrdoFont.micro.size : OrdoFont.body.size)
        .fontColor(this.emailFocus ? this.c().accentPrimary : this.c().textTertiary)
        .margin({ left: OrdoSpace.m })
        .translate({ y: this.emailFloating() ? OrdoSpace.s : 18 })
        .animation({ duration: OrdoMotion.loginFieldFocus, curve: Curve.FastOutSlowIn })
        // 标签只是视觉层,触摸必须穿透到下面的输入框
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height(56)
    .backgroundColor(this.c().chipBg)
    .borderRadius(OrdoRadius.row)
    .border({
      width: this.emailFocus ? 1.5 : 1,
      color: this.emailFocus ? this.c().accentPrimary : this.c().lineHairline
    })
    .animation({ duration: OrdoMotion.loginFieldFocus, curve: Curve.FastOutSlowIn })
  }

  @Builder
  passwordField() {
    Stack({ alignContent: Alignment.Start }) {
      Row() {
        TextInput({ text: this.password })
          .type(this.showPassword ? InputType.Normal : InputType.Password)
          // 自带的"眼睛"关掉:显示/隐藏由右侧 44×44 的显式按钮负责(§5.1、§8 触控目标 ≥44)
          .showPasswordIcon(false)
          .id('ordo_login_password')
          .layoutWeight(1)
          .height(56)
          .padding({ left: OrdoSpace.m, right: OrdoSpace.xs, top: 18 })
          .fontSize(OrdoFont.body.size)
          .fontColor(this.c().textPrimary)
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
        Text(this.showPassword ? '隐藏' : '显示')
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().textSecondary)
          .width(OrdoSize.minTouchTarget)
          .height(OrdoSize.minTouchTarget)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            this.showPassword = !this.showPassword;
          })
      }
      .width('100%')

      // 浮动标签(同邮箱:聚焦或有内容时上移并缩号)
      Text('口令')
        .fontSize(this.passwordFloating() ? OrdoFont.micro.size : OrdoFont.body.size)
        .fontColor(this.passwordFocus ? this.c().accentPrimary : this.c().textTertiary)
        .margin({ left: OrdoSpace.m })
        .translate({ y: this.passwordFloating() ? OrdoSpace.s : 18 })
        .animation({ duration: OrdoMotion.loginFieldFocus, curve: Curve.FastOutSlowIn })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height(56)
    .backgroundColor(this.c().chipBg)
    .borderRadius(OrdoRadius.row)
    .border({
      width: this.passwordFocus ? 1.5 : 1,
      color: this.passwordFocus ? this.c().accentPrimary : this.c().lineHairline
    })
    .animation({ duration: OrdoMotion.loginFieldFocus, curve: Curve.FastOutSlowIn })
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
      Text(this.registerMode ? '注册' : '登录')
        .fontSize(OrdoFont.body.size)
        .fontWeight(500)
        .fontColor(this.submitFg())
    }
    .width('100%')
    .height(OrdoMotion.loginButtonHeight)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.submitBg())
    .borderRadius(OrdoRadius.row)
    .stateStyles({
      pressed: { .scale({ x: OrdoMotion.loginPressScale, y: OrdoMotion.loginPressScale }) },
      normal: { .scale({ x: 1, y: 1 }) }
    })
    .animation({ duration: OrdoMotion.loginPress, curve: Curve.FastOutSlowIn })
    .enabled(!this.busy())
    .onClick((): void => {
      this.submit();
    })
  }

  /**
   * 次要入口「以游客身份继续」。
   * §5.1 硬约束:它必须**与主按钮同级**(surface 底 + hairline 描边,同高 44),
   * 而不是灰色小字 —— 因为游客同样入库、同样多端同步,只是没有邮箱口令。
   */
  @Builder
  guestButton() {
    Row({ space: OrdoSpace.s }) {
      Text('→')
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().accentPrimary)
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
      }
    }
    .width('100%')
    .height(20)
    .justifyContent(FlexAlign.Center)
    .translate({ x: this.shakeX })
  }

  build() {
    Column({ space: OrdoSpace.m }) {
      this.brand()

      Column({ space: OrdoSpace.s }) {
        this.emailField()
        this.passwordField()
      }
      .width('100%')
      .margin({ top: OrdoSpace.s })

      this.primaryButton()
      this.errorArea()
      this.guestButton()

      // 底部一行居中文本链接:登录态 → 还没有账号?注册;注册态 → 已有账号?登录
      Text(this.registerMode ? '已有账号?登录' : '还没有账号?注册')
        .fontSize(OrdoFont.caption.size)
        .fontColor(this.c().accentPrimary)
        .height(OrdoSize.minTouchTarget)
        .width('100%')
        .textAlign(TextAlign.Center)
        .onClick((): void => {
          this.toggleMode();
        })

      // 自建服务端:默认收起,保持登录页只有规定的三段结构
      Row({ space: OrdoSpace.xs }) {
        Text(this.serverOpen ? '▾' : '▸')
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().textTertiary)
        Text('服务器地址')
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().textTertiary)
          .layoutWeight(1)
        Text(this.store.serverText())
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(28)
      .onClick((): void => {
        this.serverOpen = !this.serverOpen;
      })

      if (this.serverOpen) {
        Column({ space: OrdoSpace.xs }) {
          TextInput({ placeholder: DEFAULT_BASE_URL, text: this.serverDraft })
            .type(InputType.Normal)
            .height(40)
            .fontSize(OrdoFont.caption.size)
            .backgroundColor(this.c().chipBg)
            .borderRadius(OrdoRadius.row)
            .onChange((value: string): void => {
              this.serverDraft = value;
            })
          Row({ space: OrdoSpace.s }) {
            Text('保存')
              .fontSize(OrdoFont.caption.size)
              .fontColor('#FFFFFF')
              .backgroundColor(this.c().accentPrimary)
              .height(32)
              .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
              .borderRadius(OrdoRadius.pill)
              .textAlign(TextAlign.Center)
              .onClick((): void => {
                this.store.setBaseUrl(this.serverDraft);
              })
            Text('恢复默认')
              .fontSize(OrdoFont.caption.size)
              .fontColor(this.c().textSecondary)
              .height(32)
              .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
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
      }
    }
    .width(OrdoMotion.loginCardWidth)
    .constraintSize({ minHeight: OrdoMotion.loginCardMinHeight, maxWidth: OrdoMotion.loginCardWidth })
    .padding(OrdoSpace.xl)
    .backgroundColor(this.c().bgSurface)
    .borderRadius(OrdoRadius.sheet)
    .border({ width: 1, color: this.c().lineHairline })
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.12)', offsetY: 12 })
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
      Column() {
        LoginGate({ store: this.store })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .padding(OrdoSpace.l)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(OrdoColors.of(this.store.isDark()).bgCanvas)
  }
}
