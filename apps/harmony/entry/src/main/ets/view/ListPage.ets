/**
 * Ordo · 主列表页(04 §3 布局骨架;§4 待办行规格;§5 完成动效;§5.3 刷新控件;§5.4 长按拖拽;§6 手势)
 *
 * 组成:大标题(28/34)+ 计数 + 工具按钮 → 列表(日程区块 → 分组 → 待办行 38vp)→ 状态栏(含刷新控件)
 *
 * 本轮改造:
 *  · 状态栏右侧换成 §5.3 的**刷新控件**(28dp 圆形图标 + 文字):同步中连续旋转、
 *    成功转 success 并显示「已同步」、失败转 danger 并常驻「同步失败,点击重试」;
 *  · 拖拽从"系统 universal drag(onDragStart/onDrop)"改为 §5.4 的**长按 400ms 后拖拽**:
 *    位移 <6px 视为点击,行抬起 scale 1.02 + 投影,拖回原位/按返回键取消且不写库。
 *    (去掉 onDragStart/onDrop 的原因:系统拖拽的阈值与取消语义由系统决定,
 *     端上无法保证 400ms/6px,也没有"拖回原位不写库"的精确语义。)
 *
 * 渲染粒度(沿用):`List + LazyForEach + RowDataSource`,行内容变化只对该下标发一次通知。 */

import { todayISO } from '../core/util/DateUtil.ets';
import { nowMillis } from '../core/util/Ids.ets';
import { AppStore, TodaySections } from '../viewmodel/AppStore.ets';
import { LONG_PRESS_MS, PressTracker, dragTargetIndex, moveIdToIndex } from '../viewmodel/PressGesture.ets';
import { DragHint, ListRow, RowInput, buildRows } from './list/RowModel.ets';
import { RowDataSource } from './list/RowDataSource.ets';
import { SwipeActionBar } from './list/SwipeActionBar.ets';
import { TodoRow } from './list/TodoRow.ets';
import { touchOf } from './Common/GestureUtil.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoMotion, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';
import { EmptyState } from './Common/EmptyState.ets';
import { MotionScale } from '../viewmodel/MotionScale.ets';

/** 拖拽让位的步长:行高 + 上下内边距(§4 待办行高 38) */
const ROW_EXTENT: number = OrdoSize.rowHeight + OrdoSpace.s;
/** 拖完之后的这段窗口内忽略点击,避免"松手顺手打开详情" */
const TAP_SUPPRESS_MS: number = 350;

@Component
export struct ListPage {
  @ObjectLink store: AppStore;
  /** 完成动效:正在播放动画的待办 id */
  @Prop animatingId: string = '';
  /**
   * `AppStore.changeSeq`:任何写操作 / 导航 / 浮层开关都会 +1。
   * 它一变就算一次行模型并对数据源做**最小通知**(见 syncRows)。
   */
  @Prop @Watch('onStoreChanged') storeRev: number = 0;
  /** `AppStore.dragCancelSeq`:返回键请求取消拖拽(§5.4 取消路径) */
  @Prop @Watch('onDragCancelRequested') dragCancelSeq: number = 0;
  /**
   * `AppStore.listKey()`:清单身份(类型 + 项目/区域/标签/搜索词 + 是否显示已完成)。
   * 它的变化就是「换了一个页面」,据此播 §5.5 的页面切换淡入。
   */
  @Prop @Watch('onListChanged') listKey: string = '';
  /** 页面入场进度:1 = 终态(首次组合不动),切清单时归零再 160ms 淡回 */
  @State private pageIn: number = 1;

  /**
   * 行数据源:**整个组件生命周期内只创建一次**。
   * ArkUI 文档明确"LazyForEach 的第一个参数被重新赋值会抛异常",所以换清单不能换数据源实例,
   * 而是由 `RowDataSource.sync(清单键, 行序列)` 在内部换行序列(见 view/list/RowDataSource.ets)。
   */
  private data: RowDataSource = new RowDataSource();
  /** 最近一次同步发出的通知条数(自检与 README §7.4 的计数口径) */
  lastEdits: number = 0;

  /* ------------------------------------------------------------ 长按拖拽状态(§5.4) */
  /** 手势判定:400ms 阈值 + 6px 位移阈值(与快加号共用同一套纯状态机) */
  private tracker: PressTracker = new PressTracker();
  private pressTimer: number = -1;
  private pressRowId: string = '';
  private suppressTimer: number = -1;
  /** 正在被拖的待办 id(空串 = 没有拖拽) */
  @State private dragId: string = '';
  /** 拖拽所在的容器(同一容器内才允许换序) */
  private dragContainer: string = '';
  /** 拖拽开始时该容器的可见序列 */
  private dragIds: string[] = [];
  @State private dragFrom: number = 0;
  @State private dragTo: number = 0;
  @State private dragDy: number = 0;
  /** 刚拖完的行:短暂忽略点击 */
  @State private suppressId: string = '';

  aboutToAppear(): void {
    this.syncRows();
  }

  aboutToDisappear(): void {
    this.clearPressTimer();
    if (this.suppressTimer >= 0) {
      clearTimeout(this.suppressTimer);
      this.suppressTimer = -1;
    }
  }

  /** store.changeSeq 变化:重算行模型 → 差量 → 最小通知 */
  /**
   * 清单切换(§5.5 v1.7「页面切换淡入 240ms」):淡入 + 上浮 10px。
   *
   * 首帧不播:pageIn 初值就是 1(终态),所以冷启动与离屏取图拿到的都是完整页面;
   * 只有真的换了清单(侧栏点收件箱/今天/项目/标签、或改搜索词)才归零重放。
   */
  onListChanged(): void {
    this.pageIn = 0;
    this.getUIContext().animateTo({ duration: MotionScale.ms(OrdoMotion.pageFade), curve: OrdoMotion.easingEnter }, () => {
      this.pageIn = 1;
    });
  }

  onStoreChanged(): void {
    this.syncRows();
  }

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
  }

  /* ------------------------------------------------------------ 数据源 */

  /**
   * 重算行模型并同步到数据源(按清单键缓存的那一份)。
   * 同一个清单 → `apply()` 只发改动过的下标;换清单 → 内部退化为整表 reload。
   */
  private syncRows(): void {
    const key: string = this.store.listKey();
    const rows: ListRow[] = buildRows(this.rowInput(key));
    this.lastEdits = this.data.sync(key, rows).length;
  }

  /** 把 AppStore 的派生缓存摊平成行模型的输入(不做任何额外遍历) */
  private rowInput(key: string): RowInput {
    const input: RowInput = {
      key: key,
      list: this.store.list,
      today: todayISO(),
      selectedTodoId: this.store.selectedTodoId,
      animatingTodoId: this.animatingId,
      events: this.store.events(),
      main: [],
      tonight: [],
      upcoming: [],
      headings: [],
      logbook: [],
      todos: []
    };
    // 拖拽期必须把拖拽状态折进行指纹:LazyForEach 只在键变化时重建行(见 RowModel 键值口径)
    if (this.dragId.length > 0) {
      const hint: DragHint = {
        draggedId: this.dragId,
        dy: this.dragDy,
        toIndex: this.dragTo,
        extent: ROW_EXTENT
      };
      input.drag = hint;
    }
    if (this.store.list === 'today') {
      const s: TodaySections = this.store.todaySections();
      input.main = s.main;
      input.tonight = s.tonight;
    } else if (this.store.list === 'upcoming') {
      input.upcoming = this.store.upcomingGroups();
    } else if (this.store.list === 'project') {
      input.headings = this.store.currentProjectGroups();
    } else if (this.store.list === 'logbook') {
      input.logbook = this.store.logbookGroups();
    } else {
      input.todos = this.store.currentTodos();
    }
    return input;
  }

  /* ------------------------------------------------------------ 头部 */

  @Builder
  header() {
    Row({ space: OrdoSpace.s }) {
      Text('☰')
        .fontSize(20)
        .fontColor(this.c().textSecondary)
        .width(OrdoSize.minTouchTarget)
        .height(OrdoSize.minTouchTarget)
        .textAlign(TextAlign.Center)
        .visibility(this.store.isNarrow() ? Visibility.Visible : Visibility.None)
        .onClick(() => {
          this.store.drawerOpen = true;
          this.store.bump();
        })
      Column({ space: 2 }) {
        Text(this.store.headerTitle())
          .fontSize(OrdoFont.display.size)
          .fontWeight(OrdoFont.display.weight)
          .fontColor(this.c().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.store.headerSubtitle())
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('⌕')
        .fontSize(20)
        .fontColor(this.c().textSecondary)
        .width(OrdoSize.minTouchTarget)
        .height(OrdoSize.minTouchTarget)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.store.fastFindOpen = true;
          this.store.bump();
        })
      Text('⋯')
        .fontSize(20)
        .fontColor(this.c().textSecondary)
        .width(OrdoSize.minTouchTarget)
        .height(OrdoSize.minTouchTarget)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.store.settingsOpen = true;
          this.store.bump();
        })
    }
    .width('100%')
    .padding({ left: OrdoSpace.xl, right: OrdoSpace.l, top: OrdoSpace.l, bottom: OrdoSpace.s })
    .alignItems(VerticalAlign.Center)
  }

  /* ------------------------------------------------------------ 行(按 kind 分发) */

  @Builder
  itemOf(row: ListRow) {
    if (row.kind === 'todo') {
      this.todoItem(row)
    } else if (row.kind === 'group') {
      ListItem() {
        this.groupTitle(row.label, row.count, row.tone === 'tonight' ? this.c().accentTonight : this.c().textSecondary)
      }
    } else if (row.kind === 'heading') {
      ListItem() {
        this.headingRow(row)
      }
    } else if (row.kind === 'agendaTitle') {
      ListItem() {
        this.agendaTitle(row.count)
      }
    } else if (row.kind === 'agendaEvent') {
      ListItem() {
        this.agendaEvent(row)
      }
    } else {
      ListItem() {
        EmptyState({
          title: row.emptyTitle,
          subtitle: row.emptySubtitle,
          actionText: row.emptyAction,
          colors: this.c(),
          onAction: (): void => {
            this.onEmptyAction(row.emptyTarget);
          }
        })
      }
    }
  }

  /* ------------------------------------------------------------ 待办行(手势挂在 ListItem 上) */

  @Builder
  todoItem(row: ListRow) {
    ListItem() {
      TodoRow({
        store: this.store,
        todoId: row.todoId,
        rowRev: row.rev,
        animating: this.animatingId === row.todoId,
        lifted: row.lifted,
        shift: row.shift,
        dropLine: row.dropLine,
        suppressTap: this.suppressId === row.todoId
      })
    }
    .swipeAction({
      // 右滑:完成(state.success)
      start: {
        builder: (): void => {
          this.swipeCompleteBar(row.todoId)
        },
        onAction: (): void => {
          this.store.toggleDone(row.todoId);
        }
      },
      // 左滑:删除(state.danger,可撤销)+ 排期入口
      end: {
        builder: (): void => {
          this.swipeDeleteBar(row.todoId)
        },
        onAction: (): void => {
          this.store.deleteTodoWithUndo(row.todoId);
        }
      },
      edgeEffect: SwipeEdgeEffect.None
    })
    // 04 §5.4:长按 400ms 后拖拽。这里**不再**用系统 universal drag(.draggable/onDragStart/onDrop):
    // 它的阈值与取消语义由系统决定,端上无法保证 400ms / 6px,也没有"拖回原位不写库"的精确语义。
    .onTouch((event: TouchEvent): void => {
      this.onRowTouch(row, event);
    })
  }

  /* ------------------------------------------------------------ 滑动手势动作区 */

  /**
   * 右滑动作区:完成(04 §6「切换完成 = 点击复选框 / 右滑」,底色 `state.success`)。
   *
   * 注意这两动作区必须是 `@Builder` 方法(ArkTS 只允许在 @Builder / build 里创建组件),
   * CustomBuilder 用 `() => { this.xxx(id) }` 传入——SDK 对 DragItemInfo.builder 明示的推荐写法同型。
   */
  @Builder
  swipeCompleteBar(todoId: string) {
    SwipeActionBar({
      glyph: '✓',
      label: '完成',
      bg: this.c().stateSuccess,
      onTap: (): void => {
        this.store.toggleDone(todoId);
      }
    })
  }

  /** 左滑动作区:排期入口 + 删除(04 §6「删除 = 左滑删除」「排期 = 行右滑」,底色 `state.danger`) */
  @Builder
  swipeDeleteBar(todoId: string) {
    Row() {
      SwipeActionBar({
        glyph: '▦',
        label: '排期',
        bg: this.c().bgSidebar,
        onTap: (): void => {
          this.store.openSchedule(todoId, false);
        }
      })
      SwipeActionBar({
        glyph: '⌫',
        label: '删除',
        bg: this.c().stateDanger,
        onTap: (): void => {
          this.store.deleteTodoWithUndo(todoId);
        }
      })
    }
  }

  /* ------------------------------------------------------------ 分组标题 */

  @Builder
  groupTitle(label: string, count: number, accent: string) {
    Row({ space: OrdoSpace.s }) {
      Text(label)
        .fontSize(OrdoFont.caption.size)
        .fontWeight(600)
        .fontColor(accent)
        .layoutWeight(1)
      Text(count.toString())
        .fontSize(OrdoFont.caption.size)
        .fontColor(this.c().textTertiary)
      Text('＋')
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textSecondary)
        .width(OrdoSize.minTouchTarget)
        .height(OrdoSize.minTouchTarget)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.store.openQuickAdd('', '', '');
        })
    }
    .width('100%')
    .padding({ top: OrdoSpace.m, bottom: OrdoSpace.xs })
  }

  /** 项目视图的标题分组行(▸/▾ 折叠 + 归档) */
  @Builder
  headingRow(row: ListRow) {
    Row({ space: OrdoSpace.s }) {
      Text(row.collapsed ? '▸' : '▾')
        .fontSize(OrdoFont.micro.size)
        .fontColor(this.c().textTertiary)
        .onClick(() => {
          if (row.headingId.length > 0) {
            // 清单展开 220ms ease-out(§5.5):用 animateTo 包住 store 变更,让行的增减跟着动效走。
            // 不给每行挂 .transition() —— 行由 LazyForEach 懒创建,挂了的话滚动时新进入视口的行也会淡入。
            this.getUIContext().animateTo({ duration: MotionScale.ms(OrdoMotion.checklistExpand), curve: OrdoMotion.easingEnter }, () => {
              this.store.toggleHeading(row.headingId);
            });
          }
        })
      Text(row.label)
        .fontSize(OrdoFont.caption.size)
        .fontWeight(600)
        .fontColor(this.c().textSecondary)
        .layoutWeight(1)
      Text('归档')
        .fontSize(OrdoFont.micro.size)
        .fontColor(this.c().textTertiary)
        .onClick(() => {
          if (row.headingId.length > 0) {
            this.store.completeHeading(row.headingId);
          }
        })
    }
    .width('100%')
    .padding({ top: OrdoSpace.m, bottom: OrdoSpace.xs })
  }

  /* ------------------------------------------------------------ 日程区块 */

  @Builder
  agendaTitle(count: number) {
    Row() {
      Text('日程')
        .fontSize(OrdoFont.micro.size)
        .fontWeight(500)
        .fontColor(this.c().textTertiary)
        .letterSpacing(0.4)
        .layoutWeight(1)
      Text(count.toString())
        .fontSize(OrdoFont.caption.size)
        .fontColor(this.c().textTertiary)
    }
    .width('100%')
    .padding({ bottom: OrdoSpace.xs })
  }

  @Builder
  agendaEvent(row: ListRow) {
    Row({ space: OrdoSpace.s }) {
      Text(row.timeText)
        .fontSize(OrdoFont.caption.size)
        .fontColor(this.c().textSecondary)
        .width(52)
      Rect()
        .width(3)
        .height(16)
        .fill(this.c().accentPrimary)
        .borderRadius(2)
      Text(row.label)
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textPrimary)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(row.calendarText)
        .fontSize(OrdoFont.micro.size)
        .fontColor(this.c().textTertiary)
    }
    .width('100%')
    .height(28)
  }

  /* ------------------------------------------------------------ 长按拖拽手势(04 §5.4) */

  private clearPressTimer(): void {
    if (this.pressTimer >= 0) {
      clearTimeout(this.pressTimer);
      this.pressTimer = -1;
    }
  }

  /**
   * 按下后计时 400ms。等待时长按"按下时刻 + 400ms"精确定——用 setTimeout 的近似值会早触发几毫秒,
   * 而 `PressTracker.hold()` 会如实回答"还没到 400ms",拖拽就永远进不去。
   */
  private armLongPress(): void {
    this.clearPressTimer();
    const wait: number = LONG_PRESS_MS - (nowMillis() - this.tracker.downTime());
    this.pressTimer = setTimeout((): void => {
      this.pressTimer = -1;
      if (this.tracker.hold(this.tracker.downTime() + LONG_PRESS_MS)) {
        // 长按达成:行抬起(scale 1.02 + 投影),真正开始移动要等位移 ≥6px
        this.store.dragActive = true;
        this.bumpRows();
      }
    }, wait > 0 ? wait : 0);
  }

  private onRowTouch(row: ListRow, event: TouchEvent): void {
    const touch: TouchObject = touchOf(event);
    if (event.type === TouchType.Down) {
      if (!row.dragEnabled || this.dragId.length > 0) {
        // 该分区不可拖(混合容器 / 只有一条),或已经在拖另一行
        return;
      }
      this.tracker.begin(touch.x, touch.y, nowMillis());
      this.pressRowId = row.todoId;
      this.armLongPress();
      return;
    }
    if (event.type === TouchType.Move) {
      if (this.pressRowId.length === 0) {
        return;
      }
      const phase: string = this.tracker.move(touch.x, touch.y);
      if (phase === 'cancelled') {
        // 位移 ≥6px 且还没到 400ms:这是滚动/滑动,不进入拖拽(§5.4「移动 <6px 视为点击」)
        this.clearPressTimer();
        this.cancelDrag(false);
        return;
      }
      if (phase === 'dragging') {
        this.applyDragMove(row);
      }
      return;
    }
    // Up / Cancel
    this.clearPressTimer();
    if (event.type === TouchType.Cancel) {
      this.tracker.cancel();
      this.cancelDrag(true);
      return;
    }
    const outcome: string = this.tracker.end();
    const wasDragging: boolean = this.dragId.length > 0;
    this.pressRowId = '';
    if (!wasDragging) {
      // 未进入拖拽:长按达成但没移动 → 仍算点击(由 TodoRow 的 onClick 打开详情)
      this.store.dragActive = false;
      this.bumpRows();
      return;
    }
    if (outcome === 'dragCommit') {
      this.commitDrag();
    }
    this.suppressClickAfterDrag();
    this.resetDrag();
  }

  private applyDragMove(row: ListRow): void {
    const dy: number = this.tracker.dy();
    if (this.dragId.length === 0) {
      // 刚跨过 6px:正式进入拖拽,锁定容器与可见序列
      this.dragId = row.todoId;
      this.dragContainer = row.container;
      this.dragIds = this.containerIds(row.container);
      this.dragFrom = this.dragIds.indexOf(row.todoId);
      if (this.dragFrom < 0) {
        this.dragFrom = 0;
      }
      this.dragTo = this.dragFrom;
      this.store.dragActive = true;
    }
    this.dragDy = dy;
    this.dragTo = dragTargetIndex(this.dragFrom, dy, ROW_EXTENT, this.dragIds.length);
    this.bumpRows();
  }

  /** 落库:提交同容器的**完整可见序列**;位置未变则不写库(§5.4) */
  private commitDrag(): void {
    const container: string = this.dragContainer;
    const id: string = this.dragId;
    const to: number = this.dragTo;
    const from: number = this.dragFrom;
    if (id.length === 0 || to === from) {
      return;
    }
    const ids: string[] = this.containerIds(container);
    const moved: string[] | null = moveIdToIndex(ids, id, to);
    if (moved === null) {
      return;
    }
    if (!this.store.reorderTodos(moved)) {
      this.store.showToast('手动排序只在同一分区/项目内生效');
    }
  }

  /** 取消(返回键 / 拖出窗口 / 位移超限):行回原位,不写库 */
  private cancelDrag(notify: boolean): void {
    if (this.dragId.length === 0 && this.pressRowId.length === 0) {
      return;
    }
    this.pressRowId = '';
    if (this.dragId.length > 0) {
      this.suppressClickAfterDrag();
      this.resetDrag();
      if (notify) {
        this.store.showToast('已取消排序');
      }
      return;
    }
    this.store.dragActive = false;
    this.bumpRows();
  }

  private resetDrag(): void {
    this.dragId = '';
    this.dragContainer = '';
    this.dragIds = [];
    this.dragFrom = 0;
    this.dragTo = 0;
    this.dragDy = 0;
    this.store.dragActive = false;
    this.bumpRows();
  }

  /** 松手后的一小段时间内忽略该行的点击:否则"拖完一松手"会顺带打开详情 */
  private suppressClickAfterDrag(): void {
    const id: string = this.dragId;
    if (id.length === 0) {
      return;
    }
    this.suppressId = id;
    if (this.suppressTimer >= 0) {
      clearTimeout(this.suppressTimer);
    }
    this.suppressTimer = setTimeout((): void => {
      this.suppressTimer = -1;
      this.suppressId = '';
      this.bumpRows();
    }, TAP_SUPPRESS_MS);
  }

  /** 返回键请求取消拖拽(Index 的 onBackPress → AppStore.requestDragCancel) */
  onDragCancelRequested(): void {
    if (this.dragId.length === 0 && !this.store.dragActive) {
      return;
    }
    this.tracker.cancel();
    this.clearPressTimer();
    this.cancelDrag(true);
  }

  /** 行模型有变(拖拽跟手、让位):重算行序列并做最小通知 */
  private bumpRows(): void {
    this.syncRows();
  }

  /* ------------------------------------------------------------ 手势与拖拽 */

  private onEmptyAction(target: string): void {
    if (target === 'inbox') {
      this.store.goList('inbox');
    } else if (target === 'anytime') {
      this.store.goList('anytime');
    } else if (target === 'quickadd') {
      this.store.openQuickAdd('', '', '');
    }
  }

  /** 当前清单里某个容器的完整可见序列(顺序即屏幕顺序) */
  private containerIds(container: string): string[] {
    const rows: ListRow[] = this.data.rowsRef();
    const ids: string[] = [];
    for (let i = 0; i < rows.length; i++) {
      const r: ListRow = rows[i];
      if (r.kind === 'todo' && r.container === container) {
        ids.push(r.todoId);
      }
    }
    return ids;
  }

  /* ------------------------------------------------------------ 状态栏 */

  /**
   * 状态栏(04 §3 布局骨架)。
   * v1.5 纯本地:不再有同步指示与刷新控件,只显示本地统计与存储方式。
   */
  @Builder
  statusBar() {
    Row({ space: OrdoSpace.s }) {
      Text(this.store.statsText())
        .fontSize(OrdoFont.micro.size)
        .fontColor(this.c().textTertiary)
      Blank()
      Text(this.store.storageText())
        .fontSize(OrdoFont.micro.size)
        .fontColor(this.c().textTertiary)
    }
    .width('100%')
    .padding({ left: OrdoSpace.xl, right: OrdoSpace.xl, top: OrdoSpace.xs, bottom: OrdoSpace.xs })
  }

  build() {
    Column() {
      this.header()
      Column() {
        List() {
          LazyForEach(this.data, (row: ListRow) => {
            this.itemOf(row)
          }, (row: ListRow) => row.key)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
        .cachedCount(6)
        .padding({ left: OrdoSpace.xl, right: OrdoSpace.xl, bottom: 96 })
        .constraintSize({ maxWidth: OrdoSize.contentMaxWidth })
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      this.statusBar()
    }
    .width('100%')
    .height('100%')
    // §5.5 页面切换:淡入 160ms + 上浮 6px(进度见 onListChanged;首帧停在终态)
    .opacity(this.pageIn)
    .translate({ y: (1 - this.pageIn) * 10 })
    .backgroundColor(this.c().bgCanvas)
  }
}
