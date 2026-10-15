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
import {
  SCHEDULE_SHEET_DESIGN_MAX,
  SETTINGS_SHEET_DESIGN_MAX,
  sheetMaxHeight
} from '../viewmodel/SheetMetrics.ets';
import { OrdoColors, OrdoMotion, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';
import { ReduceMotion } from '../theme/ReduceMotion.ets';
import { MotionScale } from '../viewmodel/MotionScale.ets';

@Entry
@Component
struct Index {
  @State store: AppStore = AppStore.instance();
  @State viewWidth: number = 1280;
  /** 窗口高度(vp):浮层上限要用它算,别在组件里写死(见 viewmodel/SheetMetrics.ets) */
  @State viewHeight: number = 800;
  /** 主界面进入动效(登录成功:卡片淡出 160ms → 主界面淡入 220ms,§5.1) */
  @State private mainIn: boolean = false;
  /** EntryAbility 写入的深链序号,变化即消费一次 */
  @StorageLink('ordo.deepLinkSeq') @Watch('onDeepLink') deepLinkSeq: number = 0;
  @StorageLink('ordo.deepLink') deepLink: string = '';
  /** 启动阶段变化:驱动"登录页淡出 → 主界面淡入" */
  @StorageLink('ordo.authPhaseSeq') @Watch('onAuthPhase') authPhaseSeq: number = 0;

  aboutToAppear(): void {
    // 系统「减弱动态效果」(§5 硬要求):先读一次并订阅,下面所有时长都走 MotionScale.ms(...)
    ReduceMotion.bind();
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

  /**
   * 窄屏抽屉(§5.5「侧栏折叠 260ms」):侧栏自左侧滑入/滑出,遮罩同步淡入淡出。
   *
   * 遮罩必须单独成层:面板自带 shadow,而 ArkUI 的阴影在 alpha<1 的图层里不画(§5.2 踩过的
   * 「先方角后圆角」),所以透明度只给遮罩,侧栏本体只做位移。
   */
  @Builder
  drawer() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#00000066')
        .onClick(() => {
          this.store.drawerOpen = false;
          this.store.bump();
        })
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.OPACITY.animation({ duration: MotionScale.ms(OrdoMotion.popIn), curve: OrdoMotion.easingEnter }),
          TransitionEffect.OPACITY.animation({ duration: MotionScale.ms(OrdoMotion.popOut), curve: OrdoMotion.easingEnter })
        ))
      Column() {
        Sidebar({ store: this.store })
      }
      .height('100%')
      .transition(TransitionEffect.translate({ x: -OrdoSize.sidebarWidth })
        .animation({ duration: MotionScale.ms(OrdoMotion.sidebarCollapse), curve: OrdoMotion.easingEnter }))
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
            dragCancelSeq: this.store.dragCancelSeq,
            // 清单身份传给列表页:它一变就播 §5.5 的页面切换淡入
            listKey: this.store.listKey()
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
      // 摆放规则(§5.2 v1.5):**底边距 = 底栏高度 + 留白**(= FAB_MARGIN_BOTTOM,见 FabMenu.ets),
      // 保证按钮不压住列表底部状态文案;右下与页面留白一致(OrdoSpace.xl)。
      // (2026-10-13 用户要求去掉柔光后,底边距里的"光晕厚度"换成等价的"留白",数值同时下调。)
      // ⚠ 必须声明在下面那些模态浮层**之前**:ArkUI 的 Stack 里后声明的画在上面,
      //   否则打开设置/快找/排期时按钮会压在面板内容上(真机踩过,用户截图反馈"设置界面严重错乱")。
      //   另外浮层打开时直接不渲染(fabVisible),双保险。
      if (fabVisible(this.store.settingsOpen, this.store.fastFindOpen, this.store.scheduleTodoId.length > 0)) {
        Column() {
          QuickAddFab({ store: this.store })
        }
        .margin({ right: FAB_MARGIN_RIGHT, bottom: FAB_MARGIN_BOTTOM })
      }

      // 排期面板(居中浮层,§5.5 v1.7:入场 280ms / 退场 200ms,面板 scale .96→1 + 上浮 14)
      if (this.store.scheduleTodoId.length > 0) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#00000033')
            .onClick(() => {
              this.store.closeSchedule();
            })
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.animation({ duration: MotionScale.ms(OrdoMotion.popIn), curve: OrdoMotion.easingEnter }),
              TransitionEffect.OPACITY.animation({ duration: MotionScale.ms(OrdoMotion.popOut), curve: OrdoMotion.easingEnter })
            ))
          Column() {
            ScheduleSheet({
              store: this.store,
              maxHeight: sheetMaxHeight(this.viewHeight, SCHEDULE_SHEET_DESIGN_MAX)
            })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          // 面板以外不拦触摸(遮罩独立成层后,点空白处关面板要靠它放行)
          .hitTestBehavior(HitTestMode.Transparent)
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.scale({ x: 0.96, y: 0.96 })
              .animation({ duration: MotionScale.ms(OrdoMotion.popIn), curve: OrdoMotion.easingEnter })
              .combine(TransitionEffect.translate({ y: 14 })
                .animation({ duration: MotionScale.ms(OrdoMotion.popIn), curve: OrdoMotion.easingEnter })),
            TransitionEffect.scale({ x: 0.96, y: 0.96 })
              .animation({ duration: MotionScale.ms(OrdoMotion.popOut), curve: OrdoMotion.easingEnter })
              .combine(TransitionEffect.translate({ y: 14 })
                .animation({ duration: MotionScale.ms(OrdoMotion.popOut), curve: OrdoMotion.easingEnter }))
          ))
        }
        .width('100%')
        .height('100%')
      }

      // 快找浮层(顶部居中,§5.5 v1.7:入场 280ms / 退场 200ms,面板 scale .96→1 + 自上方落下 14)
      if (this.store.fastFindOpen) {
        Stack({ alignContent: Alignment.TopStart }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#00000033')
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.animation({ duration: MotionScale.ms(OrdoMotion.popIn), curve: OrdoMotion.easingEnter }),
              TransitionEffect.OPACITY.animation({ duration: MotionScale.ms(OrdoMotion.popOut), curve: OrdoMotion.easingEnter })
            ))
          Column() {
            FastFindSheet({ store: this.store })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Start)
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 64 })
          // 面板以外不拦触摸(原来靠整层 backgroundColor + 内边距实现,现在遮罩独立成层)
          .hitTestBehavior(HitTestMode.Transparent)
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.scale({ x: 0.96, y: 0.96 })
              .animation({ duration: MotionScale.ms(OrdoMotion.popIn), curve: OrdoMotion.easingEnter })
              .combine(TransitionEffect.translate({ y: -14 })
                .animation({ duration: MotionScale.ms(OrdoMotion.popIn), curve: OrdoMotion.easingEnter })),
            TransitionEffect.scale({ x: 0.96, y: 0.96 })
              .animation({ duration: MotionScale.ms(OrdoMotion.popOut), curve: OrdoMotion.easingEnter })
              .combine(TransitionEffect.translate({ y: -14 })
                .animation({ duration: MotionScale.ms(OrdoMotion.popOut), curve: OrdoMotion.easingEnter }))
          ))
        }
        .width('100%')
        .height('100%')
      }

      // 设置(居中浮层,§5.5 v1.7:入场 280ms / 退场 200ms,面板 scale .96→1 + 上浮 14)
      if (this.store.settingsOpen) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#00000033')
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.animation({ duration: MotionScale.ms(OrdoMotion.popIn), curve: OrdoMotion.easingEnter }),
              TransitionEffect.OPACITY.animation({ duration: MotionScale.ms(OrdoMotion.popOut), curve: OrdoMotion.easingEnter })
            ))
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
          .hitTestBehavior(HitTestMode.Transparent)
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.scale({ x: 0.96, y: 0.96 })
              .animation({ duration: MotionScale.ms(OrdoMotion.popIn), curve: OrdoMotion.easingEnter })
              .combine(TransitionEffect.translate({ y: 14 })
                .animation({ duration: MotionScale.ms(OrdoMotion.popIn), curve: OrdoMotion.easingEnter })),
            TransitionEffect.scale({ x: 0.96, y: 0.96 })
              .animation({ duration: MotionScale.ms(OrdoMotion.popOut), curve: OrdoMotion.easingEnter })
              .combine(TransitionEffect.translate({ y: 14 })
                .animation({ duration: MotionScale.ms(OrdoMotion.popOut), curve: OrdoMotion.easingEnter }))
          ))
        }
        .width('100%')
        .height('100%')
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
    .animation({ duration: MotionScale.ms(OrdoMotion.mainFadeIn), curve: OrdoMotion.easingEnter })
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
      const h: number = Number(newValue.height);
      if (!isNaN(h)) {
        this.viewHeight = h;
      }
    })
  }
}
