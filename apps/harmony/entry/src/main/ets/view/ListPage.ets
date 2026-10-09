/**
 * Ordo · 主列表页(04 §3 布局骨架;§4 待办行规格;§5 完成动效)
 *
 * 组成:大标题(28/34)+ 计数 + 工具按钮 → 日程区块(今天)→ 分组 → 待办行(38vp)
 * 行内展开详情卡片;行右侧显示排期按钮;元信息 pill 显示标签/提醒/截止/清单进度/重复。
 */

import { CalendarEvent, Todo } from '../core/model/Entities.ets';
import { DayGroup, HeadingGroup, LogbookGroup, checklistProgress } from '../core/query/ListQuery.ets';
import { fmtDayLabel, fmtReminder, fmtShortDate, millisToHM, nowLocalDateTime, todayISO } from '../core/util/DateUtil.ets';
import { repeatLabel } from '../core/repeat/RepeatEngine.ets';
import { AppStore } from '../viewmodel/AppStore.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoMotion, OrdoRadius, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';
import { DetailCard } from './DetailCard.ets';
import { EmptyState } from './Common/EmptyState.ets';

@Component
export struct ListPage {
  @ObjectLink store: AppStore;
  /** 完成动效:正在播放动画的待办 id */
  @Prop animatingId: string = '';

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
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

  /* ------------------------------------------------------------ 日程区块 */

  @Builder
  agenda() {
    Column({ space: OrdoSpace.xs }) {
      Row() {
        Text('日程')
          .fontSize(OrdoFont.micro.size)
          .fontWeight(500)
          .fontColor(this.c().textTertiary)
          .letterSpacing(0.4)
          .layoutWeight(1)
        Text(this.store.todaySections().events.length.toString())
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().textTertiary)
      }
      .width('100%')

      ForEach(this.store.todaySections().events, (ev: CalendarEvent) => {
        Row({ space: OrdoSpace.s }) {
          Text(millisToHM(ev.start))
            .fontSize(OrdoFont.caption.size)
            .fontColor(this.c().textSecondary)
            .width(52)
          Rect()
            .width(3)
            .height(16)
            .fill(this.c().accentPrimary)
            .borderRadius(2)
          Text(ev.title)
            .fontSize(OrdoFont.body.size)
            .fontColor(this.c().textPrimary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(ev.calendar)
            .fontSize(OrdoFont.micro.size)
            .fontColor(this.c().textTertiary)
        }
        .width('100%')
        .height(28)
      }, (ev: CalendarEvent) => ev.id)
    }
    .width('100%')
    .padding({ bottom: OrdoSpace.m })
    .alignItems(HorizontalAlign.Start)
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

  /* ------------------------------------------------------------ 待办行 */

  @Builder
  row(todoId: string) {
    Column() {
      Row({ space: OrdoSpace.m }) {
        // 复选框 20×20 圆形
        Stack() {
          if (this.isChecked(todoId)) {
            Circle()
              .width(OrdoSize.checkbox)
              .height(OrdoSize.checkbox)
              .fill(this.isCanceled(todoId) ? this.c().stateDanger : this.c().accentPrimary)
            Text('✓')
              .fontSize(12)
              .fontColor('#FFFFFF')
          } else {
            Circle()
              .width(OrdoSize.checkbox)
              .height(OrdoSize.checkbox)
              .fillOpacity(0)
              .stroke(this.c().checkboxBorder)
              .strokeWidth(OrdoSize.checkboxStroke)
          }
        }
        .width(OrdoSize.checkbox)
        .height(OrdoSize.checkbox)
        .onClick(() => {
          this.store.toggleDone(todoId);
        })

        Column({ space: 2 }) {
          Text(this.titleOf(todoId))
            .fontSize(OrdoFont.body.size)
            .fontColor(this.isChecked(todoId) ? this.c().textTertiary : this.c().textPrimary)
            .decoration({ type: this.isChecked(todoId) ? TextDecorationType.LineThrough : TextDecorationType.None, color: this.c().textTertiary })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.notePreview(todoId).length > 0) {
            Text(this.notePreview(todoId))
              .fontSize(OrdoFont.caption.size)
              .fontColor(this.c().textTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (this.hasMeta(todoId)) {
            this.metaRow(todoId)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('▦')
          .fontSize(OrdoFont.body.size)
          .fontColor(this.c().textTertiary)
          .width(OrdoSize.minTouchTarget)
          .height(OrdoSize.minTouchTarget)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.store.openSchedule(todoId, false);
          })
      }
      .width('100%')
      .constraintSize({ minHeight: OrdoSize.rowHeight })
      .padding({ top: OrdoSpace.xs, bottom: OrdoSpace.xs })
      .backgroundColor(this.store.selectedTodoId === todoId ? this.c().rowSelected : Color.Transparent)
      .borderRadius(OrdoRadius.row)
      .opacity(this.animatingId === todoId ? 0.72 : 1)
      .animation({ duration: OrdoMotion.base, curve: Curve.FastOutSlowIn })
      .onClick(() => {
        this.store.setSelected(todoId);
      })

      if (this.store.selectedTodoId === todoId) {
        DetailCard({ store: this.store, todoId: todoId })
      }
    }
    .width('100%')
  }

  @Builder
  metaRow(todoId: string) {
    Row({ space: 6 }) {
      ForEach(this.tagsOf(todoId), (name: string) => {
        Text(name)
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().chipText)
          .backgroundColor(this.c().chipBg)
          .borderRadius(OrdoRadius.pill)
          .height(OrdoSize.chipHeight)
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            this.store.goTag(name);
          })
      }, (name: string) => todoId + '_' + name)

      if (this.reminderOf(todoId).length > 0) {
        Text('⏰ ' + fmtReminder(this.reminderOf(todoId)))
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.isReminderPast(todoId) ? this.c().stateDanger : this.c().textSecondary)
      }
      if (this.deadlineOf(todoId).length > 0) {
        Text('⚑ ' + fmtShortDate(this.deadlineOf(todoId)))
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.isOverdue(todoId) ? this.c().stateDanger : this.c().textSecondary)
      }
      if (this.checklistText(todoId).length > 0) {
        Text('☑ ' + this.checklistText(todoId))
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().textSecondary)
      }
      if (this.repeatText(todoId).length > 0) {
        Text('⟳ ' + this.repeatText(todoId))
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().textSecondary)
      }
      if (this.completedAtText(todoId).length > 0) {
        Text(this.completedAtText(todoId))
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().textTertiary)
      }
    }
    .width('100%')
  }

  /* ------------------------------------------------------------ 内容区 */

  @Builder
  todayContent() {
    if (this.store.todaySections().events.length > 0) {
      this.agenda()
    }
    this.groupTitle('今天', this.store.todaySections().main.length, this.c().textSecondary)
    if (this.store.todaySections().main.length === 0) {
      EmptyState({
        title: '今天还没有安排',
        subtitle: '从收件箱挑几件今天想做的事,或直接按右下角的快加号',
        actionText: '去收件箱看看',
        colors: this.c(),
        onAction: (): void => {
          this.store.goList('inbox');
        }
      })
    } else {
      ForEach(this.store.todaySections().main, (t: Todo) => {
        this.row(t.id);
      }, (t: Todo) => t.id)
    }
    if (this.store.todaySections().tonight.length > 0) {
      // 今晚分区:琥珀色分组标题(04 §2.1 accent.tonight)
      this.groupTitle('今晚', this.store.todaySections().tonight.length, this.c().accentTonight)
      ForEach(this.store.todaySections().tonight, (t: Todo) => {
        this.row(t.id);
      }, (t: Todo) => t.id)
    }
  }

  @Builder
  upcomingContent() {
    if (this.store.upcomingGroups().length === 0) {
      EmptyState({
        title: '未来两周没有安排',
        subtitle: '给待办设一个开始日期,它就会出现在这里',
        actionText: '查看随时',
        colors: this.c(),
        onAction: (): void => {
          this.store.goList('anytime');
        }
      })
    } else {
      ForEach(this.store.upcomingGroups(), (g: DayGroup) => {
        this.groupTitle(g.label.length > 0 ? g.label : '更晚', g.todos.length, this.c().textSecondary)
        ForEach(g.todos, (t: Todo) => {
          this.row(t.id);
        }, (t: Todo) => t.id)
      }, (g: DayGroup) => g.date.length > 0 ? g.date : 'overflow')
    }
  }

  @Builder
  projectContent() {
    if (this.store.currentProjectGroups().length === 0) {
      EmptyState({
        title: '这个项目还没有待办',
        subtitle: '按右下角的快加号开始记录第一步',
        actionText: '新建待办',
        colors: this.c(),
        onAction: (): void => {
          this.store.openQuickAdd('', '', '');
        }
      })
    } else {
      ForEach(this.store.currentProjectGroups(), (g: HeadingGroup) => {
        if (g.headingId !== null) {
          Row({ space: OrdoSpace.s }) {
            Text(g.collapsed ? '▸' : '▾')
              .fontSize(OrdoFont.micro.size)
              .fontColor(this.c().textTertiary)
              .onClick(() => {
                this.store.toggleHeading(g.headingId as string);
              })
            Text(g.name)
              .fontSize(OrdoFont.caption.size)
              .fontWeight(600)
              .fontColor(this.c().textSecondary)
              .layoutWeight(1)
            Text('归档')
              .fontSize(OrdoFont.micro.size)
              .fontColor(this.c().textTertiary)
              .onClick(() => {
                this.store.completeHeading(g.headingId as string);
              })
          }
          .width('100%')
          .padding({ top: OrdoSpace.m, bottom: OrdoSpace.xs })
        }
        if (!g.collapsed) {
          ForEach(g.todos, (t: Todo) => {
            this.row(t.id);
          }, (t: Todo) => t.id)
        }
      }, (g: HeadingGroup) => g.headingId === null ? 'loose' : g.headingId)
    }
  }

  @Builder
  logbookContent() {
    if (this.store.logbookGroups().length === 0) {
      EmptyState({
        title: '日志簿还是空的',
        subtitle: '完成的待办会按日期归档到这里',
        actionText: '',
        colors: this.c(),
        onAction: (): void => {
        }
      })
    } else {
      ForEach(this.store.logbookGroups(), (g: LogbookGroup) => {
        this.groupTitle(fmtDayLabel(g.date), g.todos.length, this.c().textSecondary)
        ForEach(g.todos, (t: Todo) => {
          this.row(t.id);
        }, (t: Todo) => t.id)
      }, (g: LogbookGroup) => 'lb_' + g.date)
    }
  }

  @Builder
  plainContent() {
    if (this.store.currentTodos().length === 0) {
      EmptyState({
        title: this.emptyTitle(),
        subtitle: this.emptySubtitle(),
        actionText: '新建待办',
        colors: this.c(),
        onAction: (): void => {
          this.store.openQuickAdd('', '', '');
        }
      })
    } else {
      ForEach(this.store.currentTodos(), (t: Todo) => {
        this.row(t.id);
      }, (t: Todo) => t.id)
    }
  }

  @Builder
  content() {
    Column() {
      if (this.store.list === 'today') {
        this.todayContent()
      } else if (this.store.list === 'upcoming') {
        this.upcomingContent()
      } else if (this.store.list === 'project') {
        this.projectContent()
      } else if (this.store.list === 'logbook') {
        this.logbookContent()
      } else {
        this.plainContent()
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: OrdoSize.contentMaxWidth })
    .alignItems(HorizontalAlign.Start)
  }

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
      Scroll() {
        Column() {
          this.content()
        }
        .width('100%')
        .padding({ left: OrdoSpace.xl, right: OrdoSpace.xl, bottom: 96 })
        .alignItems(HorizontalAlign.Center)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      this.statusBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.c().bgCanvas)
  }

  /* ------------------------------------------------------------ 取值辅助 */

  private titleOf(id: string): string {
    const t: Todo | null = this.store.findTodo(id);
    return t === null ? '' : t.title;
  }

  private isChecked(id: string): boolean {
    const t: Todo | null = this.store.findTodo(id);
    return t !== null && (t.status === 'done' || t.status === 'canceled');
  }

  private isCanceled(id: string): boolean {
    const t: Todo | null = this.store.findTodo(id);
    return t !== null && t.status === 'canceled';
  }

  private notePreview(id: string): string {
    const t: Todo | null = this.store.findTodo(id);
    if (t === null || t.note.length === 0) {
      return '';
    }
    let plain: string = t.note.split('#').join('').split('**').join('').split('`').join('').split('- ').join('');
    plain = plain.split('\n').join(' ');
    return plain.length > 80 ? plain.substring(0, 80) : plain;
  }

  private hasMeta(id: string): boolean {
    const t: Todo | null = this.store.findTodo(id);
    if (t === null) {
      return false;
    }
    return t.tags.length > 0 || t.reminder !== null || t.deadline !== null ||
      t.checklist.length > 0 || t.repeat !== null || t.completedAt !== null;
  }

  private tagsOf(id: string): string[] {
    const t: Todo | null = this.store.findTodo(id);
    return t === null ? [] : t.tags;
  }

  private reminderOf(id: string): string {
    const t: Todo | null = this.store.findTodo(id);
    return t === null || t.reminder === null ? '' : t.reminder;
  }

  private deadlineOf(id: string): string {
    const t: Todo | null = this.store.findTodo(id);
    return t === null || t.deadline === null ? '' : t.deadline;
  }

  private isOverdue(id: string): boolean {
    const d: string = this.deadlineOf(id);
    return d.length > 0 && d < todayISO() && !this.isChecked(id);
  }

  private isReminderPast(id: string): boolean {
    const r: string = this.reminderOf(id);
    return r.length > 0 && r < nowLocalDateTime() && !this.isChecked(id);
  }

  private checklistText(id: string): string {
    const t: Todo | null = this.store.findTodo(id);
    return t === null ? '' : checklistProgress(t.checklist);
  }

  private repeatText(id: string): string {
    const t: Todo | null = this.store.findTodo(id);
    return t === null ? '' : repeatLabel(t.repeat);
  }

  private completedAtText(id: string): string {
    const t: Todo | null = this.store.findTodo(id);
    if (t === null || t.completedAt === null) {
      return '';
    }
    return fmtShortDate(fmtDateOf(t.completedAt)) + ' ' + millisToHM(t.completedAt);
  }

  private emptyTitle(): string {
    if (this.store.list === 'inbox') {
      return '收件箱是空的';
    }
    if (this.store.list === 'someday') {
      return '某天里还没有事';
    }
    if (this.store.list === 'tag') {
      return '这个标签下没有待办';
    }
    if (this.store.list === 'search') {
      return '没有匹配的待办';
    }
    return '这里还没有待办';
  }

  private emptySubtitle(): string {
    if (this.store.list === 'inbox') {
      return '想到什么就先记下来,之后再决定什么时候做';
    }
    if (this.store.list === 'someday') {
      return '把"以后再说"的事放这里,定期回来看看';
    }
    return '按右下角的快加号新建一条';
  }
}

/** epoch millis → "YYYY-MM-DD" */
function fmtDateOf(ms: number): string {
  const d: Date = new Date(ms);
  const mm: string = (d.getMonth() + 1) < 10 ? '0' + (d.getMonth() + 1).toString() : (d.getMonth() + 1).toString();
  const dd: string = d.getDate() < 10 ? '0' + d.getDate().toString() : d.getDate().toString();
  return d.getFullYear().toString() + '-' + mm + '-' + dd;
}
