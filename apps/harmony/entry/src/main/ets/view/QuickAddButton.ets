/**
 * Ordo · 快加号 QuickAdd(04 §5.2 快加号集群 / §4 组件表)
 *
 * §5.2(v1.1 重构「去掉多余元素」)原文要点:
 *  - **只保留一个圆形按钮**:直径 56,accent 填充,白色「+」,投影 8dp;
 *  - **删除**独立的折叠箭头按钮(旧版右下角同时有 56 蓝「+」和 28 白折叠箭头,视觉互相叠压);
 *  - 交互分工:单击 → 打开行内输入行;**长按 400ms** → 从按钮**左上方**展开快捷菜单;
 *    菜单展开中单击 → 收起菜单,按钮转回 0°;
 *  - 菜单展开时按钮**旋转 45°**(「+」变「×」)作为状态反馈。
 *
 * 动效(§5.2 表):
 *  按压 scale → 0.96(90ms);长按到 400ms 放大到 1.06 并保持;
 *  菜单展开:面板 scale 0.9→1 + alpha 0→1(180ms),菜单项逐个错位 40ms 淡入并上移 6px;
 *  菜单收起:反向 140ms。
 *
 * 以及行内新建面板 QuickAddPanel(自然语言实时预览,契约 §5)。
 */

import { ParsedInput, parseNaturalNow } from '../core/nlp/NaturalDateParser.ets';
import { fmtMonthDay } from '../core/util/DateUtil.ets';
import { nowMillis } from '../core/util/Ids.ets';
import { AppStore } from '../viewmodel/AppStore.ets';
import { LONG_PRESS_MS, PressTracker } from '../viewmodel/PressGesture.ets';
import { touchOf } from './Common/GestureUtil.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoIcons, OrdoMotion, OrdoRadius, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';

/**
 * 快加输入框的组件 id。
 * 供 `UIContext.getFocusController().requestFocus(id)` 定位 —— 输入框出现后必须**真正获焦**,
 * 否则软键盘不弹、看不到光标,用户会觉得"点了加号没反应"。
 */
const QUICK_ADD_INPUT_ID: string = 'ordo_quick_add_input';

/** 快捷菜单项(§5.2:新建待办 / 项目 / 区域 / 标题) */
interface FabMenuItem {
  glyph: string;
  label: string;
}

@Component
export struct QuickAddFab {
  @ObjectLink store: AppStore;
  @State private menuOpen: boolean = false;
  /** 菜单展开动效的目标态(展开后下一帧置位,才能从 scale 0.9/alpha 0 动到 1) */
  @State private menuIn: boolean = false;
  @State private pressed: boolean = false;

  /** 长按判定:阈值 400ms、位移 <6px 视为点击(与行拖拽共用同一套纯状态机,§5.2 / §5.4) */
  private tracker: PressTracker = new PressTracker();
  private longPressTimer: number = -1;
  private closeTimer: number = -1;

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
  }

  aboutToDisappear(): void {
    this.clearLongPress();
    if (this.closeTimer >= 0) {
      clearTimeout(this.closeTimer);
      this.closeTimer = -1;
    }
  }

  /* ------------------------------------------------------------ 手势 */

  private clearLongPress(): void {
    if (this.longPressTimer >= 0) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
  }

  /**
   * 排定长按判定。等待时长按"按下时刻 + 400ms"精确定，不靠 setTimeout 的近似:
   * 定时器早触发哪怕 1ms,`hold()` 也会如实返回"还没到 400ms",菜单就会打不开。
   */
  private armLongPress(): void {
    this.clearLongPress();
    const wait: number = LONG_PRESS_MS - (nowMillis() - this.tracker.downTime());
    this.longPressTimer = setTimeout((): void => {
      this.longPressTimer = -1;
      if (this.tracker.hold(this.tracker.downTime() + LONG_PRESS_MS)) {
        this.openMenu();
      }
    }, wait > 0 ? wait : 0);
  }

  private handleTouchEvent(event: TouchEvent): void {
    const touch: TouchObject = touchOf(event);
    if (event.type === TouchType.Down) {
      this.tracker.begin(touch.x, touch.y, nowMillis());
      this.pressed = true;
      this.armLongPress();
      return;
    }
    if (event.type === TouchType.Move) {
      const phase: string = this.tracker.move(touch.x, touch.y);
      if (phase === 'cancelled') {
        // 位移 ≥6px:交给列表滚动,不再算长按
        this.clearLongPress();
      }
      return;
    }
    // Up / Cancel
    this.clearLongPress();
    this.pressed = false;
    if (event.type === TouchType.Cancel) {
      this.tracker.cancel();
      this.closeMenu();
      return;
    }
    this.tracker.end();
  }

  /** 单击:菜单展开中 → 收起(按钮转回 0°);否则打开行内输入行 */
  private handleTap(): void {
    if (this.tracker.consumeLongPress()) {
      // 本次是长按,长按已经开过菜单了,不要再当点击处理
      return;
    }
    if (this.menuOpen) {
      this.closeMenu();
      return;
    }
    this.store.openQuickAdd('', '', '');
  }

  /* ------------------------------------------------------------ 菜单开合 */

  private openMenu(): void {
    if (this.closeTimer >= 0) {
      clearTimeout(this.closeTimer);
      this.closeTimer = -1;
    }
    this.menuOpen = true;
    // 下一帧再进入终态,否则首帧就是终态、180ms 的展开动效不播
    setTimeout((): void => {
      this.menuIn = true;
    }, 0);
  }

  /** 收起:反向 140ms,动效播完再卸载面板 */
  private closeMenu(): void {
    if (!this.menuOpen) {
      return;
    }
    this.menuIn = false;
    this.closeTimer = setTimeout((): void => {
      this.closeTimer = -1;
      this.menuOpen = false;
    }, OrdoMotion.menuCollapse);
  }

  private act(action: () => void): void {
    this.menuIn = false;
    this.menuOpen = false;
    action();
  }

  private menuItems(): FabMenuItem[] {
    const items: FabMenuItem[] = [
      { glyph: OrdoIcons.plus, label: '新建待办' },
      { glyph: '◎', label: '新建项目' },
      { glyph: '▣', label: '新建区域' }
    ];
    if (this.store.list === 'project') {
      items.push({ glyph: '▤', label: '新建标题' });
    }
    return items;
  }

  private runItem(label: string): void {
    if (label === '新建待办') {
      this.act((): void => {
        this.store.openQuickAdd('', '', '');
      });
      return;
    }
    if (label === '新建项目') {
      this.act((): void => {
        this.store.createProject('新项目', this.store.list === 'area' ? this.store.areaId : '');
      });
      return;
    }
    if (label === '新建区域') {
      this.act((): void => {
        this.store.createArea('新区域');
      });
      return;
    }
    this.act((): void => {
      this.store.addHeading(this.store.projectId, '新标题');
    });
  }

  @Builder
  menuItem(item: FabMenuItem, index: number) {
    Row({ space: OrdoSpace.s }) {
      Text(item.glyph)
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textSecondary)
        .width(20)
        .textAlign(TextAlign.Center)
      Text(item.label)
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textPrimary)
    }
    .width(168)
    .height(OrdoSize.minTouchTarget)
    .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
    .backgroundColor(this.c().bgSurface)
    .onClick((): void => {
      this.runItem(item.label);
    })
    // 逐个错位 40ms 淡入并上移 6px(§5.2)
    .opacity(this.menuIn ? 1 : 0)
    .translate({ y: this.menuIn ? 0 : OrdoMotion.menuItemRise })
    .animation({
      duration: this.menuOpen ? OrdoMotion.menuExpand : OrdoMotion.menuCollapse,
      delay: this.menuIn ? index * OrdoMotion.menuItemStagger : 0,
      curve: Curve.FastOutSlowIn
    })
  }

  @Builder
  menuPanel() {
    Column() {
      ForEach(this.menuItems(), (item: FabMenuItem, index: number) => {
        this.menuItem(item, index)
      }, (item: FabMenuItem) => item.label)
    }
    .backgroundColor(this.c().bgSurface)
    .borderRadius(OrdoRadius.card)
    .border({ width: 1, color: this.c().lineHairline })
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.14)', offsetY: 8 })
    .clip(true)
    // 面板 scale 0.9→1 + alpha 0→1(180ms)
    .scale({ x: this.menuIn ? 1 : OrdoMotion.menuFromScale, y: this.menuIn ? 1 : OrdoMotion.menuFromScale })
    .opacity(this.menuIn ? 1 : 0)
    .animation({
      duration: this.menuOpen ? OrdoMotion.menuExpand : OrdoMotion.menuCollapse,
      curve: Curve.FastOutSlowIn
    })
    // 从按钮**左上方**弹出:面板右缘比按钮右缘再往左让出半个按钮宽
    .margin({ right: OrdoSize.quickAdd / 2 })
  }

  build() {
    Column({ space: OrdoSpace.s }) {
      if (this.menuOpen) {
        this.menuPanel()
      }

      // 快加号本体:整个集群**只有这一个圆形按钮**(§5.2「删除独立的折叠箭头按钮」)
      Stack() {
        Circle()
          .width(OrdoSize.quickAdd)
          .height(OrdoSize.quickAdd)
          .fill(this.c().accentPrimary)
        Text(OrdoIcons.plus)
          .fontSize(26)
          .fontColor('#FFFFFF')
      }
      .width(OrdoSize.quickAdd)
      .height(OrdoSize.quickAdd)
      .shadow({ radius: 8, color: 'rgba(0,0,0,0.20)', offsetY: 4 })
      // 长按到 400ms:放大到 1.06 并保持;按压 0.96(90ms)
      .scale({
        x: this.menuOpen ? OrdoMotion.fabHoldScale : (this.pressed ? OrdoMotion.fabPressScale : 1),
        y: this.menuOpen ? OrdoMotion.fabHoldScale : (this.pressed ? OrdoMotion.fabPressScale : 1)
      })
      // 菜单展开时旋转 45°(「+」变「×」)
      .rotate({ angle: this.menuOpen ? OrdoMotion.fabRotate : 0 })
      .animation({ duration: OrdoMotion.fabPress, curve: Curve.FastOutSlowIn })
      .onTouch((event: TouchEvent): void => {
        this.handleTouchEvent(event);
      })
      .onClick((): void => {
        this.handleTap();
      })
    }
    .alignItems(HorizontalAlign.End)
  }
}

@Component
export struct QuickAddPanel {
  @ObjectLink store: AppStore;
  /**
   * `AppStore.quickAddFocusSeq`:加号(或组标题＋/快找"新建")每被点一次就 +1。
   * 面板**已经打开**时再点,输入框本已存在、不会重建,靠这个 @Watch 重新聚焦;
   * 首次打开由输入框自己的 onAppear 抢焦点。
   */
  @Prop @Watch('onFocusRequested') focusSeq: number = 0;
  @State private draft: string = '';

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
  }

  /**
   * 把焦点交给输入框(软键盘随之弹出,见 enableKeyboardOnFocus)。
   * 节点尚未上树 / 不可聚焦时 requestFocus 会抛 150001/150002/150003,
   * 这里吞掉:自动聚焦失败也不该让面板崩掉,用户仍可手动点输入框。
   */
  private focusInput(): void {
    try {
      this.getUIContext().getFocusController().requestFocus(QUICK_ADD_INPUT_ID);
    } catch (e) {
      console.warn('[Ordo] 快加输入框自动聚焦失败');
    }
  }

  onFocusRequested(): void {
    this.focusInput();
  }

  private preview(): ParsedInput {
    return parseNaturalNow(this.draft);
  }

  private previewText(): string {
    const p: ParsedInput = this.preview();
    const bits: string[] = [];
    if (p.cleanTitle.length > 0) {
      bits.push('标题「' + p.cleanTitle + '」');
    }
    if (p.when !== null) {
      if (p.date !== null) {
        bits.push(fmtMonthDay(p.date));
      } else if (p.when === 'today') {
        bits.push('今天');
      } else if (p.when === 'evening') {
        bits.push('今晚');
      } else if (p.when === 'someday') {
        bits.push('某天');
      }
    }
    if (p.reminder !== null) {
      bits.push('提醒 ' + p.reminder.substring(11, 16));
    }
    if (p.tags.length > 0) {
      bits.push('#' + p.tags.join(' #'));
    }
    return bits.length === 0 ? '' : '识别到:' + bits.join(' · ');
  }

  private submit(): void {
    if (this.draft.trim().length === 0) {
      return;
    }
    const created = this.store.createTodoFromInput(this.draft);
    if (created !== null) {
      this.store.showToast('已添加:' + created.title);
    }
    this.draft = '';
    this.store.closeQuickAdd();
  }

  build() {
    Column({ space: OrdoSpace.s }) {
      Row({ space: OrdoSpace.s }) {
        Circle()
          .width(OrdoSize.checkbox)
          .height(OrdoSize.checkbox)
          .fillOpacity(0)
          .stroke(this.c().checkboxBorder)
          .strokeWidth(OrdoSize.checkboxStroke)
        TextInput({ placeholder: '要做什么?可写「明天 18:00 交报告 #重要」', text: this.draft })
          .id(QUICK_ADD_INPUT_ID)
          .layoutWeight(1)
          .height(OrdoSize.rowHeight)
          .fontSize(OrdoFont.body.size)
          .backgroundColor(Color.Transparent)
          .enableKeyboardOnFocus(true)
          .onAppear(() => {
            // 面板首次出现:立刻聚焦并拉起软键盘,给出明确的可见反馈
            this.focusInput();
          })
          .onChange((value: string) => {
            this.draft = value;
          })
          .onSubmit(() => {
            this.submit();
          })
        Text('添加')
          .fontSize(OrdoFont.caption.size)
          .fontColor('#FFFFFF')
          .backgroundColor(this.c().accentPrimary)
          .height(30)
          .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
          .borderRadius(OrdoRadius.pill)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.submit();
          })
        Text('✕')
          .fontSize(OrdoFont.body.size)
          .fontColor(this.c().textTertiary)
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.draft = '';
            this.store.closeQuickAdd();
          })
      }
      .width('100%')

      if (this.draft.trim().length > 0 && this.previewText().length > 0) {
        Text(this.previewText())
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().accentPrimary)
          .width('100%')
          .padding({ left: OrdoSize.checkbox + OrdoSpace.s })
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: OrdoSize.contentMaxWidth })
    .padding(OrdoSpace.m)
    .backgroundColor(this.c().bgSurface)
    .borderRadius(OrdoRadius.card)
    .border({ width: 1, color: this.c().lineHairline })
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.08)', offsetY: 8 })
  }
}
