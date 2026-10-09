/**
 * Ordo · 主列表页(04 §3 布局骨架;§4 待办行规格;§5 完成动效;§6 手势)
 *
 * 组成:大标题(28/34)+ 计数 + 工具按钮 → 列表(日程区块 → 分组 → 待办行 38vp)→ 状态栏
 *
 * 本轮改造(渲染粒度):
 *  · `Scroll + Column + ForEach` → `List + LazyForEach + RowDataSource`
 *    —— 只创建可见区 + cachedCount 内的行,行内容变化只对该下标发一次通知(见 view/list/RowModel.ets);
 *  · 数据源按**清单键**缓存(`sources`),来回切清单不丢已建好的行,只补差量;
 *  · 待办行抽成独立组件 `TodoRow`,由行指纹 `rowRev` 驱动,粒度从"整页"降到"单行";
 *  · 手势:右滑 = 完成(`state.success`),左滑 = 删除(`state.danger`,可撤销)+ 排期入口;
 *  · 拖拽:`onDragStart/onDrop` 提交**同容器完整可见序列**给核心 `reorderTodos(ids)`,跨容器拒绝。
 *
 * 视觉与改前一致:分组标题、今晚分区(琥珀色)、行高、圆角、令牌取值全部沿用,只有承载容器换了。
 */

import { Todo } from '../core/model/Entities.ets';
import { todayISO } from '../core/util/DateUtil.ets';
import { AppStore, TodaySections } from '../viewmodel/AppStore.ets';
import { containerKeyOf, movedOrder } from '../viewmodel/ReorderMath.ets';
import { ListRow, RowInput, buildRows } from './list/RowModel.ets';
import { RowDataSource } from './list/RowDataSource.ets';
import { SwipeActionBar } from './list/SwipeActionBar.ets';
import { TodoRow } from './list/TodoRow.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';
import { EmptyState } from './Common/EmptyState.ets';

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

  /**
   * 行数据源:**整个组件生命周期内只创建一次**。
   * ArkUI 文档明确"LazyForEach 的第一个参数被重新赋值会抛异常",所以换清单不能换数据源实例,
   * 而是由 `RowDataSource.sync(清单键, 行序列)` 在内部换行序列(见 view/list/RowDataSource.ets)。
   */
  private data: RowDataSource = new RowDataSource();
  /** 正在被拖拽的待办 id(universal drag 的载荷;不参与渲染,故不用 @State) */
  private draggingId: string = '';
  /** 最近一次同步发出的通知条数(自检与 README §7.4 的计数口径) */
  lastEdits: number = 0;

  aboutToAppear(): void {
    this.syncRows();
  }

  /** store.changeSeq 变化:重算行模型 → 差量 → 最小通知 */
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
        animating: this.animatingId === row.todoId
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
    .draggable(row.dragEnabled)
    .onDragStart((event: DragEvent, extraParams?: string): DragItemInfo => {
      // 载荷放在 extraInfo;拖拽预览交给系统(组件快照)
      this.draggingId = row.todoId;
      const info: DragItemInfo = { extraInfo: row.todoId };
      return info;
    })
    .onDrop((event: DragEvent, extraParams?: string): void => {
      this.dropOnRow(row);
    })
    .onDragEnd((event: DragEvent, extraParams?: string): void => {
      this.draggingId = '';
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
            this.store.toggleHeading(row.headingId);
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

  /**
   * 把 `draggingId` 落到 `target` 行所在的位置。
   *
   * 提交给核心的是**当前清单里同容器的完整可见序列**(不是"被拖的那一条"):
   * 核心的语义是 `ids[i].order = i`,残缺序列会把没提交的条目挤到末尾。
   * 跨容器(不同 when / projectId / headingId)直接拒绝并提示,与 iOS `reorderTodos(ids:)` 一致。
   */
  private dropOnRow(target: ListRow): void {
    const sourceId: string = this.draggingId;
    this.draggingId = '';
    if (sourceId.length === 0 || sourceId === target.todoId) {
      return;
    }
    const src: Todo | null = this.store.findTodo(sourceId);
    if (src === null) {
      return;
    }
    if (containerKeyOf(src) !== target.container) {
      this.store.showToast('手动排序只在同一分区/项目内生效');
      return;
    }
    const ids: string[] = this.containerIds(target.container);
    const moved: string[] | null = movedOrder(ids, sourceId, target.todoId);
    if (moved === null) {
      return;
    }
    this.store.reorderTodos(moved);
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

  @Builder
  statusBar() {
    Row({ space: OrdoSpace.s }) {
      Text(this.store.statsText())
        .fontSize(OrdoFont.micro.size)
        .fontColor(this.c().textTertiary)
      Text('· ' + this.store.syncText() + this.store.pendingText())
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
    .backgroundColor(this.c().bgCanvas)
  }
}
