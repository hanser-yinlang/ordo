/**
 * Ordo · 设置
 *  - SettingsPage:@Entry 页面(可在 main_pages 中作为独立页打开)
 *  - SettingsSheet:主页面内以浮层形式打开的设置面板(04 §4 浮层规范)
 * 内容:外观(自动/浅色/深色)、数据与存储、本地数据、同步状态、示例数据重置、快捷键与手势说明
 *
 * v1.4:登录被移除 —— 设置页不再有「账号 / 账号标识 / 升级为正式账号 / 退出登录 / 服务器地址」区块;
 * 服务器地址改成**隐藏覆盖**(只读应用级 kv,无输入框,见 README §6.6)。
 */

import { AppStore } from '../viewmodel/AppStore.ets';
import {
  SETTINGS_SHEET_CHROME,
  SETTINGS_SHEET_DESIGN_MAX,
  sheetMaxHeight,
  sheetScrollMaxHeight
} from '../viewmodel/SheetMetrics.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoRadius, OrdoSize, OrdoSpace, OrdoTheme, ThemeMode } from '../theme/Tokens.ets';

@Component
export struct SettingsSheet {
  @ObjectLink store: AppStore;
  /**
   * 面板允许的最大高度(vp),由**当前窗口高度**算出(见 `viewmodel/SheetMetrics.ets`)。
   * 不要再写死数字:矮屏/分屏上写死会让内容溢出面板、画到底部状态栏上。
   */
  @Prop maxHeight: number = SETTINGS_SHEET_DESIGN_MAX;

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

      /*
       * 内容区:比面板高时**在面板内部滚动**。
       * 真机踩坑:原先这一段直接摊在 Column 里,面板 `maxHeight: 640` 而内容约 900+,
       * ArkUI 又默认不裁剪 —— 多出来的行就画到了面板外面,压住列表底部状态栏
       * (用户截图反馈「设置界面底部有严重问题」)。现在:滚动容器 + 明确 clip。
       */
      Scroll() {
        Column({ space: OrdoSpace.xs }) {
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

          this.sectionTitle('本地数据')
          // 契约 §7.6.6:工作区标识 = 本机稳定 id,数据落在 <databaseDir>/rdb/<标识>/ordo.db
          this.rowId('工作区标识', this.store.accountDirText(), 'ordo_settings_session')
          this.rowId('数据目录', this.store.userDirText(), 'ordo_settings_userdir')
          this.row('库文件', this.store.dataPathText())

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
      }
      .width('100%')
      .constraintSize({ maxHeight: sheetScrollMaxHeight(this.maxHeight, SETTINGS_SHEET_CHROME) })
      .scrollBar(BarState.Auto)
      .clip(true)
    }
    .width('100%')
    .constraintSize({ maxWidth: 520, maxHeight: this.maxHeight })
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
  /** 窗口高度(vp):独立打开这一页时也要用真实高度收敛面板,别写死 */
  @State private viewHeight: number = 0;

  build() {
    Column() {
      SettingsSheet({
        store: this.store,
        maxHeight: sheetMaxHeight(this.viewHeight, SETTINGS_SHEET_DESIGN_MAX)
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(OrdoColors.of(this.store.isDark()).bgCanvas)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const h: number = Number(newValue.height);
      if (!isNaN(h)) {
        this.viewHeight = h;
      }
    })
  }
}
