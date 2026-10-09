/**
 * Ordo · 主页面(路由入口)
 * 组装:侧栏(窄屏为抽屉)+ 主列表 + 快加号 + 行内新建 + 排期面板 + 快找浮层 + 设置 + Toast
 * 负责:初始化 AppStore、消费 ordo:// 深链、响应窗口宽度变化(04 §3 断点)
 */

import { common } from '@kit.AbilityKit';
import { AppStore } from '../viewmodel/AppStore.ets';
import { ListPage } from '../view/ListPage.ets';
import { Sidebar } from '../view/Sidebar.ets';
import { QuickAddFab, QuickAddPanel } from '../view/QuickAddButton.ets';
import { ScheduleSheet } from '../view/ScheduleSheet.ets';
import { FastFindSheet } from '../view/FastFindSheet.ets';
import { SettingsSheet } from './SettingsPage.ets';
import { LoginSheet } from '../view/LoginPage.ets';
import { OrdoToast } from '../view/Common/OrdoToast.ets';
import { OrdoColors, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';

@Entry
@Component
struct Index {
  @State store: AppStore = AppStore.instance();
  @State viewWidth: number = 1280;
  /** EntryAbility 写入的深链序号,变化即消费一次 */
  @StorageLink('ordo.deepLinkSeq') @Watch('onDeepLink') deepLinkSeq: number = 0;
  @StorageLink('ordo.deepLink') deepLink: string = '';

  aboutToAppear(): void {
    // getContext() 自 API 18 起废弃,改用 UIContext.getHostContext()
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store.applySystemColorMode(context);
    this.store.init(context);
    if (this.deepLink.length > 0) {
      this.store.applyDeepLink(this.deepLink);
    }
  }

  onDeepLink(): void {
    if (this.deepLink.length > 0) {
      this.store.applyDeepLink(this.deepLink);
    }
  }

  private c() {
    return OrdoColors.of(this.store.isDark());
  }

  @Builder
  drawer() {
    Row() {
      Sidebar({ store: this.store })
      Column()
        .layoutWeight(1)
        .height('100%')
        .backgroundColor('#00000066')
        .onClick(() => {
          this.store.drawerOpen = false;
          this.store.bump();
        })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Row() {
        if (this.viewWidth >= OrdoSize.breakpointMedium) {
          Sidebar({ store: this.store })
        }
        Column() {
          ListPage({ store: this.store, animatingId: this.store.animatingTodoId, storeRev: this.store.changeSeq })
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.c().bgCanvas)

      // 窄屏抽屉
      if (this.viewWidth < OrdoSize.breakpointMedium && this.store.drawerOpen) {
        this.drawer()
      }

      // 行内新建面板(顶部居中)
      if (this.store.quickAddOpen) {
        Column() {
          QuickAddPanel({ store: this.store })
        }
        .width('100%')
        .padding({ top: 72, left: OrdoSpace.xl, right: OrdoSpace.xl })
        // Column 没有 alignContent,顶部对齐用 justifyContent
        .justifyContent(FlexAlign.Start)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 排期面板(右侧浮层)
      if (this.store.scheduleTodoId.length > 0) {
        Column() {
          ScheduleSheet({ store: this.store })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#00000033')
        .onClick(() => {
          this.store.closeSchedule();
        })
      }

      // 快找浮层
      if (this.store.fastFindOpen) {
        Column() {
          FastFindSheet({ store: this.store })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 64 })
        .backgroundColor('#00000033')
      }

      // 设置
      if (this.store.settingsOpen) {
        Column() {
          SettingsSheet({ store: this.store })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#00000033')
      }

      // 登录 / 注册(未登录时首次同步也会自动打开)
      if (this.store.loginOpen) {
        Column() {
          LoginSheet({ store: this.store })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding(OrdoSpace.l)
        .backgroundColor('#00000033')
      }

      // 快加号
      Column() {
        QuickAddFab({ store: this.store })
      }
      .margin({ right: OrdoSpace.xl, bottom: 64 })

      // Toast(左滑删除后带「撤销」动作,04 §4 / §6)
      OrdoToast({
        toastSeq: this.store.toast.seq,
        toastText: this.store.toast.text,
        sticky: this.store.syncStatus.phase === 'error',
        actionText: this.store.toast.action,
        onAction: (): void => {
          this.store.undoDelete();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.c().bgCanvas)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const w: number = Number(newValue.width);
      if (!isNaN(w)) {
        this.viewWidth = w;
        this.store.narrow = w < OrdoSize.breakpointMedium;
      }
    })
  }
}
