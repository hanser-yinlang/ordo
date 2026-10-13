/**
 * Ordo · 主页面(路由入口)
 * 组装:侧栏(窄屏为抽屉)+ 主列表 + 快加号 + 行内新建 + 排期面板 + 快找浮层 + 设置 + Toast
 * 负责:初始化 AppStore、消费 ordo:// 深链、响应窗口宽度变化(04 §3 断点)、
 *      启动过场(读会话/开库期间显示启动态,**没有登录门禁** —— v1.4 产品决策:启动即主界面)、
 *      返回键取消拖拽(04 §5.4 取消路径)
 */

import { common } from '@kit.AbilityKit';
import { AppStore } from '../viewmodel/AppStore.ets';
import { ListPage } from '../view/ListPage.ets';
import { Sidebar } from '../view/Sidebar.ets';
import { QuickAddFab, QuickAddPanel } from '../view/QuickAddButton.ets';
import { FAB_MARGIN_BOTTOM, FAB_MARGIN_RIGHT, fabVisible } from '../viewmodel/FabMenu.ets';
import { ScheduleSheet } from '../view/ScheduleSheet.ets';
import { FastFindSheet } from '../view/FastFindSheet.ets';
import { SettingsSheet } from './SettingsPage.ets';
import { OrdoToast } from '../view/Common/OrdoToast.ets';
import { OrdoColors, OrdoMotion, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';

@Entry
@Component
struct Index {
  @State store: AppStore = AppStore.instance();
  @State viewWidth: number = 1280;
  /** 主界面进入动效(登录成功:卡片淡出 160ms → 主界面淡入 220ms,§5.1) */
  @State private mainIn: boolean = false;
  /** EntryAbility 写入的深链序号,变化即消费一次 */
  @StorageLink('ordo.deepLinkSeq') @Watch('onDeepLink') deepLinkSeq: number = 0;
  @StorageLink('ordo.deepLink') deepLink: string = '';
  /** 启动阶段变化:驱动"登录页淡出 → 主界面淡入" */
  @StorageLink('ordo.authPhaseSeq') @Watch('onAuthPhase') authPhaseSeq: number = 0;

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

  /**
   * 启动阶段变化(v1.4 只有两态):
   *  - booting → 启动过场(读会话 / 开本地库,通常几十毫秒)
   *  - ready   → 主界面首帧透明,下一帧淡入 220ms
   */
  onAuthPhase(): void {
    const phase: string = this.store.authPhase;
    if (phase === 'ready') {
      setTimeout((): void => {
        this.mainIn = true;
      }, 0);
      return;
    }
    this.mainIn = false;
  }

  /**
   * 返回键(鸿蒙系统返回):拖拽中优先取消拖拽而不是退出页面(04 §5.4 的取消路径)。
   * 返回 true 表示本次按键已被消费。
   */
  onBackPress(): boolean {
    if (this.store.dragActive) {
      this.store.requestDragCancel();
      return true;
    }
    if (this.store.selectedTodoId.length > 0) {
      this.store.setSelected('');
      return true;
    }
    return false;
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

  /** 读会话/开库期间的过场(通常只有几十毫秒;v1.4 之后它是唯一的非主界面状态) */
  @Builder
  bootingScreen() {
    Column({ space: OrdoSpace.m }) {
      LoadingProgress()
        .width(32)
        .height(32)
        .color(this.c().accentPrimary)
      Text('序')
        .fontSize(20)
        .fontWeight(600)
        .fontColor(this.c().textSecondary)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.c().bgCanvas)
  }

  @Builder
  mainScreen() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Row() {
        if (this.viewWidth >= OrdoSize.breakpointMedium) {
          Sidebar({ store: this.store })
        }
        Column() {
          ListPage({
            store: this.store,
            animatingId: this.store.animatingTodoId,
            storeRev: this.store.changeSeq,
            dragCancelSeq: this.store.dragCancelSeq
          })
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
      // 外层 Column 必须占满高度:Stack 的对齐是 BottomEnd,若只包住面板就会贴着屏幕底部、
      // 被右下角的加号按钮压住,用户看到的是"点了没反应"。hitTestBehavior 为 Transparent,
      // 面板以外的区域不拦截列表触摸。
      if (this.store.quickAddOpen) {
        Column() {
          QuickAddPanel({ store: this.store, focusSeq: this.store.quickAddFocusSeq })
        }
        .width('100%')
        .height('100%')
        .padding({ top: 72, left: OrdoSpace.xl, right: OrdoSpace.xl })
        // Column 没有 alignContent,顶部对齐用 justifyContent
        .justifyContent(FlexAlign.Start)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 快加号(§5.2:只保留这一个圆形按钮,没有独立的折叠箭头)
      // 摆放规则(§5.2 v1.5):**底边距 = 底栏高度 + 光晕厚度 + 空隙**(= FAB_MARGIN_BOTTOM,见 FabMenu.ets),
      // 保证按钮**连同 24vp 光晕**都不压住列表底部状态文案;右下与页面留白一致(OrdoSpace.xl)。
      // ⚠ 必须声明在下面那些模态浮层**之前**:ArkUI 的 Stack 里后声明的画在上面,
      //   否则打开设置/快找/排期时按钮会压在面板内容上(真机踩过,用户截图反馈"设置界面严重错乱")。
      //   另外浮层打开时直接不渲染(fabVisible),双保险。
      if (fabVisible(this.store.settingsOpen, this.store.fastFindOpen, this.store.scheduleTodoId.length > 0)) {
        Column() {
          QuickAddFab({ store: this.store })
        }
        .margin({ right: FAB_MARGIN_RIGHT, bottom: FAB_MARGIN_BOTTOM })
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

      // Toast(左滑删除后带「撤销」动作,04 §4 / §6)
      OrdoToast({
        toastSeq: this.store.toast.seq,
        toastText: this.store.toast.text,
        sticky: false,
        actionText: this.store.toast.action,
        onAction: (): void => {
          this.store.undoDelete();
        }
      })
    }
    .width('100%')
    .height('100%')
    .opacity(this.mainIn ? 1 : 0)
    .animation({ duration: OrdoMotion.mainFadeIn, curve: Curve.FastOutSlowIn })
  }

  build() {
    Stack() {
      if (this.store.authPhase === 'ready') {
        this.mainScreen()
      } else {
        // v1.4:没有登录页了 —— 未就绪时只可能是"启动过场"
        this.bootingScreen()
      }
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
