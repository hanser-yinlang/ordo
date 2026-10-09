/**
 * Ordo · 登录 / 注册
 * 契约来源:docs/03-数据模型与同步协议.md §7.4(POST /v1/auth/login|register、401 与 AUTH_* 错误码)、§9(安全);
 *          docs/04-UI设计规范.md §2(令牌)、§4(浮层)
 *
 * 两种形态:
 *  - LoginSheet:主页面内以浮层形式打开(store.loginOpen),未登录时首次同步也会自动弹出;
 *  - LoginPage:@Entry 页面(可在 main_pages 中作为独立页打开,便于深链直接进入)。
 *
 * 交互:
 *  - 顶部「登录 / 注册」分段切换;
 *  - 邮箱 + 口令(口令掩码,提交时校验非空与长度);
 *  - 服务器地址输入(自建服务端场景),保存即换 SyncApi 地址并探活一次;
 *  - 错误提示一律走 sync 错误码 → errorText()(契约 §7.4),不在 UI 里硬编码错误文案。
 */

import { AppStore, DEFAULT_BASE_URL } from '../viewmodel/AppStore.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoRadius, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';

@Component
export struct LoginSheet {
  @ObjectLink store: AppStore;
  @State private registerMode: boolean = false;
  @State private email: string = '';
  @State private password: string = '';
  @State private serverDraft: string = '';
  @State private advancedOpen: boolean = false;

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
  }

  aboutToAppear(): void {
    this.registerMode = this.store.loginPrefersRegister;
    this.email = this.store.accountEmail;
    this.serverDraft = this.store.serverText();
  }

  private busy(): boolean {
    return this.store.loginBusy;
  }

  private canSubmit(): boolean {
    return !this.busy() && this.email.trim().length > 0 && this.password.length > 0;
  }

  private async submit(): Promise<void> {
    if (!this.canSubmit()) {
      this.store.showToast('请先填写邮箱与口令');
      return;
    }
    const mail: string = this.email;
    const secret: string = this.password;
    const ok: boolean = this.registerMode
      ? await this.store.register(mail, secret)
      : await this.store.login(mail, secret);
    if (ok) {
      this.password = '';
    }
  }

  @Builder
  modeChip(register: boolean) {
    Text(register ? '注册' : '登录')
      .fontSize(OrdoFont.body.size)
      .fontColor(this.registerMode === register ? '#FFFFFF' : this.c().textSecondary)
      .backgroundColor(this.registerMode === register ? this.c().accentPrimary : Color.Transparent)
      .height(32)
      .layoutWeight(1)
      .borderRadius(OrdoRadius.pill)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.registerMode = register;
        this.store.loginError = '';
        this.store.bump();
      })
  }

  @Builder
  field(label: string, placeholder: string, isSecret: boolean) {
    Column({ space: OrdoSpace.xs }) {
      Text(label)
        .fontSize(OrdoFont.micro.size)
        .fontColor(this.c().textTertiary)
        .width('100%')
      TextInput({
        placeholder: placeholder,
        text: isSecret ? this.password : this.email
      })
        .type(isSecret ? InputType.Password : InputType.Email)
        .height(OrdoSize.findInputHeight)
        .fontSize(OrdoFont.body.size)
        .backgroundColor(this.c().chipBg)
        .borderRadius(OrdoRadius.row)
        .enabled(!this.busy())
        .onChange((value: string) => {
          if (isSecret) {
            this.password = value;
          } else {
            this.email = value;
          }
          this.store.loginError = '';
        })
        .onSubmit(() => {
          this.submit();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: OrdoSpace.m }) {
      // 标题行
      Row({ space: OrdoSpace.s }) {
        Text('序')
          .fontSize(OrdoFont.title.size)
          .fontWeight(600)
          .fontColor(this.c().accentPrimary)
        Column({ space: 2 }) {
          Text(this.registerMode ? '创建账号' : '登录')
            .fontSize(OrdoFont.body.size)
            .fontWeight(500)
            .fontColor(this.c().textPrimary)
          Text('登录后待办会在这台设备与其它端之间同步')
            .fontSize(OrdoFont.micro.size)
            .fontColor(this.c().textTertiary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('✕')
          .fontSize(OrdoFont.body.size)
          .fontColor(this.c().textTertiary)
          .width(OrdoSize.minTouchTarget)
          .height(OrdoSize.minTouchTarget)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.store.closeLogin();
          })
      }
      .width('100%')

      // 登录 / 注册 分段
      Row({ space: OrdoSpace.xs }) {
        this.modeChip(false)
        this.modeChip(true)
      }
      .width('100%')
      .padding(OrdoSpace.xs)
      .backgroundColor(this.c().chipBg)
      .borderRadius(OrdoRadius.pill)

      this.field('邮箱', 'you@example.com', false)
      this.field('口令', this.registerMode ? '至少 6 位' : '你的口令', true)

      // 错误提示(错误码 → errorText())
      if (this.store.loginError.length > 0) {
        Row({ space: OrdoSpace.xs }) {
          Text('!')
            .fontSize(OrdoFont.caption.size)
            .fontColor(this.c().stateDanger)
          Text(this.store.loginError)
            .fontSize(OrdoFont.caption.size)
            .fontColor(this.c().stateDanger)
            .layoutWeight(1)
        }
        .width('100%')
      }

      // 提交
      Text(this.busy() ? '请稍候…' : (this.registerMode ? '注册并同步' : '登录'))
        .fontSize(OrdoFont.body.size)
        .fontWeight(500)
        .fontColor('#FFFFFF')
        .backgroundColor(this.canSubmit() ? this.c().accentPrimary : this.c().textTertiary)
        .height(OrdoSize.minTouchTarget)
        .width('100%')
        .borderRadius(OrdoRadius.pill)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.submit();
        })

      // 服务器地址(自建服务端)
      Row({ space: OrdoSpace.xs }) {
        Text(this.advancedOpen ? '▾' : '▸')
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().textTertiary)
        Text('服务器地址')
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().textSecondary)
          .layoutWeight(1)
        Text(this.store.serverText())
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(32)
      .onClick(() => {
        this.advancedOpen = !this.advancedOpen;
      })

      if (this.advancedOpen) {
        Column({ space: OrdoSpace.xs }) {
          TextInput({ placeholder: DEFAULT_BASE_URL, text: this.serverDraft })
            .type(InputType.Normal)
            .height(40)
            .fontSize(OrdoFont.caption.size)
            .backgroundColor(this.c().chipBg)
            .borderRadius(OrdoRadius.row)
            .onChange((value: string) => {
              this.serverDraft = value;
            })
          Row({ space: OrdoSpace.s }) {
            Text('保存')
              .fontSize(OrdoFont.caption.size)
              .fontColor('#FFFFFF')
              .backgroundColor(this.c().accentPrimary)
              .height(30)
              .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
              .borderRadius(OrdoRadius.pill)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.store.setBaseUrl(this.serverDraft);
              })
            Text('恢复默认')
              .fontSize(OrdoFont.caption.size)
              .fontColor(this.c().textSecondary)
              .height(30)
              .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
              .borderRadius(OrdoRadius.pill)
              .backgroundColor(this.c().chipBg)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.serverDraft = DEFAULT_BASE_URL;
                this.store.setBaseUrl(this.serverDraft);
              })
            Blank()
          }
          .width('100%')
        }
        .width('100%')
      }

      Text('口令只用于换取同步令牌,不会写入日志与本地明文存储')
        .fontSize(OrdoFont.micro.size)
        .fontColor(this.c().textTertiary)
        .width('100%')
    }
    .width('100%')
    .constraintSize({ maxWidth: 420 })
    .padding(OrdoSpace.xl)
    .backgroundColor(this.c().bgSurface)
    .borderRadius(OrdoRadius.sheet)
    .border({ width: 1, color: this.c().lineHairline })
    .shadow({ radius: 40, color: 'rgba(0,0,0,0.18)', offsetY: 12 })
  }
}

@Entry
@Component
struct LoginPage {
  @State store: AppStore = AppStore.instance();

  build() {
    Column() {
      LoginSheet({ store: this.store })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(OrdoColors.of(this.store.isDark()).bgCanvas)
  }
}
