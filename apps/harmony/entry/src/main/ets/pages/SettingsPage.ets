/**
 * Ordo · 设置
 *  - SettingsPage:@Entry 页面(可在 main_pages 中作为独立页打开)
 *  - SettingsSheet:主页面内以浮层形式打开的设置面板(04 §4 浮层规范)
 * 内容:外观(自动/浅色/深色)、数据与存储、同步状态、账号、示例数据重置、快捷键与手势说明
 */

import { AppStore } from '../viewmodel/AppStore.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoMotion, OrdoRadius, OrdoSize, OrdoSpace, OrdoTheme, ThemeMode } from '../theme/Tokens.ets';

@Component
export struct SettingsSheet {
  @ObjectLink store: AppStore;
  /** 游客升级表单(契约 §7.6.2) */
  @State private upgradeOpen: boolean = false;
  @State private upgradeEmail: string = '';
  @State private upgradePassword: string = '';

  private submitUpgrade(): void {
    this.store.upgradeGuest(this.upgradeEmail, this.upgradePassword).then((ok: boolean): void => {
      if (ok) {
        this.upgradeOpen = false;
        this.upgradePassword = '';
      }
    });
  }

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(OrdoFont.micro.size)
      .fontWeight(500)
      .fontColor(this.c().textTertiary)
      .letterSpacing(0.4)
      .width('100%')
      .padding({ top: OrdoSpace.m, bottom: OrdoSpace.xs })
  }

  @Builder
  row(label: string, value: string) {
    Row({ space: OrdoSpace.s }) {
      Text(label)
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textPrimary)
        .layoutWeight(1)
      Text(value)
        .fontSize(OrdoFont.caption.size)
        .fontColor(this.c().textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(40)
  }

  /**
   * 与 `row()` 相同,额外给**值文本**挂一个测试 id。
   * 只为端到端取证(uitest dumpLayout 读取文本),不影响任何生产行为。
   */
  @Builder
  rowId(label: string, value: string, valueId: string) {
    Row({ space: OrdoSpace.s }) {
      Text(label)
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textPrimary)
        .layoutWeight(1)
      Text(value)
        .fontSize(OrdoFont.caption.size)
        .fontColor(this.c().textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .id(valueId)
    }
    .width('100%')
    .height(40)
  }

  @Builder
  themeChip(mode: ThemeMode) {
    Text(OrdoTheme.label(mode))
      .fontSize(OrdoFont.caption.size)
      .fontColor(this.store.themeMode === mode ? '#FFFFFF' : this.c().textPrimary)
      .backgroundColor(this.store.themeMode === mode ? this.c().accentPrimary : this.c().chipBg)
      .height(30)
      .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
      .borderRadius(OrdoRadius.pill)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.store.setTheme(mode);
      })
  }

  build() {
    Column({ space: OrdoSpace.xs }) {
      Row() {
        Text('设置')
          .fontSize(OrdoFont.title.size)
          .fontWeight(OrdoFont.title.weight)
          .fontColor(this.c().textPrimary)
          .layoutWeight(1)
        Text('✕')
          .fontSize(OrdoFont.body.size)
          .fontColor(this.c().textTertiary)
          .width(OrdoSize.minTouchTarget)
          .height(OrdoSize.minTouchTarget)
          .textAlign(TextAlign.Center)
          .id('ordo_settings_close')
          .onClick(() => {
            this.store.settingsOpen = false;
            this.store.bump();
          })
      }
      .width('100%')

      this.sectionTitle('外观')
      Row({ space: OrdoSpace.s }) {
        this.themeChip('auto')
        this.themeChip('light')
        this.themeChip('dark')
      }
      .width('100%')

      this.sectionTitle('数据与存储')
      this.row('存储方式', this.store.storageText())
      this.row('设备 ID', this.store.deviceText())
      this.row('统计', this.store.statsText())

      this.sectionTitle('同步')
      this.row('状态', this.store.refreshLabel() + this.store.pendingText())
      this.row('实时通道', this.store.syncStatus.realtimeConnected ? '已连接' : '未连接')
      this.row('服务端游标', this.store.syncStatus.lastServerSeq.toString())
      this.rowId('服务器地址', this.store.serverText(), 'ordo_settings_server')
      if (this.store.syncStatus.lastErrorText !== null) {
        this.row('最近错误', this.store.syncStatus.lastErrorText)
      }

      Row({ space: OrdoSpace.s }) {
        Text('立即同步')
          .fontSize(OrdoFont.caption.size)
          .fontColor('#FFFFFF')
          .backgroundColor(this.c().accentPrimary)
          .height(32)
          .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
          .borderRadius(OrdoRadius.pill)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.store.tapRefresh();
          })
        Blank()
      }
      .width('100%')

      this.sectionTitle('账号')
      Row({ space: OrdoSpace.s }) {
        Text(this.store.accountText())
          .fontSize(OrdoFont.body.size)
          .fontWeight(500)
          .fontColor(this.c().textPrimary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .id('ordo_settings_account')
        if (this.store.isGuest()) {
          Text('游客')
            .fontSize(OrdoFont.micro.size)
            .fontColor(this.c().accentPrimary)
            .backgroundColor(this.c().chipBg)
            .height(OrdoSize.chipHeight)
            .padding({ left: 6, right: 6 })
            .borderRadius(OrdoRadius.pill)
        }
      }
      .width('100%')
      .height(28)

      // 契约 §7.6.3:每个账号一份本地目录;这里把它显示出来,便于核对"没有串号"
      this.rowId('账号标识', this.store.accountDetailText(), 'ordo_settings_userid')
      this.rowId('数据目录', this.store.userDirText(), 'ordo_settings_userdir')
      this.row('库文件', this.store.dataPathText())

      // 契约 §7.6.2:游客可升级为正式账号(userId 与数据都不变)
      if (this.store.isGuest()) {
        if (this.upgradeOpen) {
          Column({ space: OrdoSpace.xs }) {
            TextInput({ placeholder: '邮箱', text: this.upgradeEmail })
              .type(InputType.Email)
              .height(40)
              .fontSize(OrdoFont.caption.size)
              .backgroundColor(this.c().chipBg)
              .borderRadius(OrdoRadius.row)
              .onChange((v: string): void => {
                this.upgradeEmail = v;
                this.store.loginError = '';
              })
            TextInput({ placeholder: '口令(至少 6 位)', text: this.upgradePassword })
              .type(InputType.Password)
              .height(40)
              .fontSize(OrdoFont.caption.size)
              .backgroundColor(this.c().chipBg)
              .borderRadius(OrdoRadius.row)
              .onChange((v: string): void => {
                this.upgradePassword = v;
                this.store.loginError = '';
              })
            if (this.store.loginError.length > 0) {
              Text(this.store.loginError)
                .fontSize(OrdoFont.micro.size)
                .fontColor(this.c().stateDanger)
                .width('100%')
            }
            Row({ space: OrdoSpace.s }) {
              Text('确认升级')
                .fontSize(OrdoFont.caption.size)
                .fontColor('#FFFFFF')
                .backgroundColor(this.c().accentPrimary)
                .height(32)
                .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
                .borderRadius(OrdoRadius.pill)
                .textAlign(TextAlign.Center)
                .onClick((): void => {
                  this.submitUpgrade();
                })
              Text('取消')
                .fontSize(OrdoFont.caption.size)
                .fontColor(this.c().textSecondary)
                .backgroundColor(this.c().chipBg)
                .height(32)
                .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
                .borderRadius(OrdoRadius.pill)
                .textAlign(TextAlign.Center)
                .onClick((): void => {
                  this.upgradeOpen = false;
                  this.store.loginError = '';
                })
              Blank()
            }
            .width('100%')
          }
          .width('100%')
        } else {
          Row() {
            Text('升级为正式账号')
              .fontSize(OrdoFont.caption.size)
              .fontColor(this.c().accentPrimary)
              .height(32)
              .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
              .borderRadius(OrdoRadius.pill)
              .backgroundColor(this.c().chipBg)
              .textAlign(TextAlign.Center)
              .onClick((): void => {
                this.upgradeOpen = true;
              })
            Blank()
          }
          .width('100%')
        }
      }

      Row({ space: OrdoSpace.s }) {
        Text('退出登录')
          .fontSize(OrdoFont.caption.size)
          .fontColor('#FFFFFF')
          .backgroundColor(this.c().stateDanger)
          .height(OrdoMotion.loginButtonHeight)
          .padding({ left: OrdoSpace.l, right: OrdoSpace.l })
          .borderRadius(OrdoRadius.row)
          .textAlign(TextAlign.Center)
          .id('ordo_settings_logout')
          .onClick(() => {
            this.store.logout();
          })
        Blank()
      }
      .width('100%')

      Text('退出登录只清除会话,本账号的本地数据目录会保留;下次用同一账号登录时数据仍在,联网后增量同步。')
        .fontSize(OrdoFont.micro.size)
        .fontColor(this.c().textTertiary)
        .width('100%')

      this.sectionTitle('键盘与手势(鸿蒙)')
      this.row('新建待办', '快加号 / 长按')
      this.row('快找', '顶部搜索图标')
      this.row('打开详情', '点击待办行')
      this.row('切换完成', '点击复选框 / 右滑')
      this.row('删除', '左滑删除')
      this.row('排期', '行右滑 / 行内日历按钮')
      this.row('切换深色', '设置项 / 侧栏主题按钮')
      this.row('关闭浮层', '返回键')

      this.sectionTitle('示例数据')
      Row({ space: OrdoSpace.s }) {
        Text('恢复默认示例数据')
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().stateDanger)
          .height(32)
          .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
          .borderRadius(OrdoRadius.pill)
          .backgroundColor(this.c().chipBg)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.store.resetToSeedData();
          })
        Blank()
      }
      .width('100%')
    }
    .width('100%')
    .constraintSize({ maxWidth: 520, maxHeight: 640 })
    .padding(OrdoSpace.xl)
    .backgroundColor(this.c().bgSurface)
    .borderRadius(OrdoRadius.sheet)
    .border({ width: 1, color: this.c().lineHairline })
    .shadow({ radius: 40, color: 'rgba(0,0,0,0.18)', offsetY: 12 })
  }
}

@Entry
@Component
struct SettingsPage {
  @State store: AppStore = AppStore.instance();

  build() {
    Column() {
      SettingsSheet({ store: this.store })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(OrdoColors.of(this.store.isDark()).bgCanvas)
  }
}
