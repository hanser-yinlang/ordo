/**
 * Ordo · 待办行组件(04-UI规范 §4「待办行」/ §5 完成动效)
 *
 * 从 `ListPage.row()` 原样抽出,变成**独立 @Component**:这样"某一行变了"才是一个可寻址的渲染单元,
 * 配合 `LazyForEach` + `RowDataSource.notifyDataChange(index)` 只重建这一行。
 *
 * 刷新契约(重要):
 *  行的数据来自引擎(普通对象,不受 @Observed 观察),所以行内渲染**不能**依赖"父组件重渲染"顺带刷新。
 *  父组件通过 `rowRev`(见 `RowModel.todoRowRev`,覆盖本行渲染依赖的全部字段)驱动本组件重渲染:
 *  指纹不变 = 这一行渲染结果不可能变,不重建;指纹变了 = 只重建这一行。
 */

import { Todo } from '../../core/model/Entities.ets';
import { checklistProgress } from '../../core/query/ListQuery.ets';
import { repeatLabel } from '../../core/repeat/RepeatEngine.ets';
import { fmtReminder, fmtShortDate, millisToHM, nowLocalDateTime, todayISO } from '../../core/util/DateUtil.ets';
import { AppStore } from '../../viewmodel/AppStore.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoMotion, OrdoRadius, OrdoSize, OrdoSpace } from '../../theme/Tokens.ets';
import { DetailCard } from '../DetailCard.ets';

@Component
export struct TodoRow {
  @ObjectLink store: AppStore;
  @Prop todoId: string = '';
  /** 行内容指纹:唯一的重渲染触发条件(见 RowModel.todoRowRev) */
  @Prop rowRev: number = 0;
  /** 完成动效:本行是否正在播放动画 */
  @Prop animating: boolean = false;

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
  }

  build() {
    Column() {
      Row({ space: OrdoSpace.m }) {
        // 复选框 20×20 圆形(04 §4)
        Stack() {
          if (this.isChecked()) {
            Circle()
              .width(OrdoSize.checkbox)
              .height(OrdoSize.checkbox)
              .fill(this.isCanceled() ? this.c().stateDanger : this.c().accentPrimary)
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
          this.store.toggleDone(this.todoId);
        })

        Column({ space: 2 }) {
          Text(this.titleOf())
            .fontSize(OrdoFont.body.size)
            .fontColor(this.isChecked() ? this.c().textTertiary : this.c().textPrimary)
            .decoration({
              type: this.isChecked() ? TextDecorationType.LineThrough : TextDecorationType.None,
              color: this.c().textTertiary
            })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.notePreview().length > 0) {
            Text(this.notePreview())
              .fontSize(OrdoFont.caption.size)
              .fontColor(this.c().textTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (this.hasMeta()) {
            this.metaRow()
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
            this.store.openSchedule(this.todoId, false);
          })
      }
      .width('100%')
      .constraintSize({ minHeight: OrdoSize.rowHeight })
      .padding({ top: OrdoSpace.xs, bottom: OrdoSpace.xs })
      .backgroundColor(this.store.selectedTodoId === this.todoId ? this.c().rowSelected : Color.Transparent)
      .borderRadius(OrdoRadius.row)
      .opacity(this.animating ? 0.72 : 1)
      .animation({ duration: OrdoMotion.base, curve: Curve.FastOutSlowIn })
      .onClick(() => {
        this.store.setSelected(this.todoId);
      })

      if (this.store.selectedTodoId === this.todoId) {
        DetailCard({ store: this.store, todoId: this.todoId })
      }
    }
    .width('100%')
  }

  @Builder
  metaRow() {
    Row({ space: 6 }) {
      ForEach(this.tagsOf(), (name: string) => {
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
      }, (name: string) => this.todoId + '_' + name)

      if (this.reminderOf().length > 0) {
        Text('⏰ ' + fmtReminder(this.reminderOf()))
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.isReminderPast() ? this.c().stateDanger : this.c().textSecondary)
      }
      if (this.deadlineOf().length > 0) {
        Text('⚑ ' + fmtShortDate(this.deadlineOf()))
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.isOverdue() ? this.c().stateDanger : this.c().textSecondary)
      }
      if (this.checklistText().length > 0) {
        Text('☑ ' + this.checklistText())
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().textSecondary)
      }
      if (this.repeatText().length > 0) {
        Text('⟳ ' + this.repeatText())
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().textSecondary)
      }
      if (this.completedAtText().length > 0) {
        Text(this.completedAtText())
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().textTertiary)
      }
    }
    .width('100%')
  }

  /* ------------------------------------------------------------ 取值辅助 */

  private todo(): Todo | null {
    return this.store.findTodo(this.todoId);
  }

  private titleOf(): string {
    const t: Todo | null = this.todo();
    return t === null ? '' : t.title;
  }

  private isChecked(): boolean {
    const t: Todo | null = this.todo();
    return t !== null && (t.status === 'done' || t.status === 'canceled');
  }

  private isCanceled(): boolean {
    const t: Todo | null = this.todo();
    return t !== null && t.status === 'canceled';
  }

  private notePreview(): string {
    const t: Todo | null = this.todo();
    if (t === null || t.note.length === 0) {
      return '';
    }
    let plain: string = t.note.split('#').join('').split('**').join('').split('`').join('').split('- ').join('');
    plain = plain.split('\n').join(' ');
    return plain.length > 80 ? plain.substring(0, 80) : plain;
  }

  private hasMeta(): boolean {
    const t: Todo | null = this.todo();
    if (t === null) {
      return false;
    }
    return t.tags.length > 0 || t.reminder !== null || t.deadline !== null ||
      t.checklist.length > 0 || t.repeat !== null || t.completedAt !== null;
  }

  private tagsOf(): string[] {
    const t: Todo | null = this.todo();
    return t === null ? [] : t.tags;
  }

  private reminderOf(): string {
    const t: Todo | null = this.todo();
    return t === null || t.reminder === null ? '' : t.reminder;
  }

  private deadlineOf(): string {
    const t: Todo | null = this.todo();
    return t === null || t.deadline === null ? '' : t.deadline;
  }

  private isOverdue(): boolean {
    const d: string = this.deadlineOf();
    return d.length > 0 && d < todayISO() && !this.isChecked();
  }

  private isReminderPast(): boolean {
    const r: string = this.reminderOf();
    return r.length > 0 && r < nowLocalDateTime() && !this.isChecked();
  }

  private checklistText(): string {
    const t: Todo | null = this.todo();
    return t === null ? '' : checklistProgress(t.checklist);
  }

  private repeatText(): string {
    const t: Todo | null = this.todo();
    return t === null ? '' : repeatLabel(t.repeat);
  }

  private completedAtText(): string {
    const t: Todo | null = this.todo();
    if (t === null || t.completedAt === null) {
      return '';
    }
    return fmtShortDate(fmtDateOf(t.completedAt)) + ' ' + millisToHM(t.completedAt);
  }
}

/** epoch millis → "YYYY-MM-DD" */
function fmtDateOf(ms: number): string {
  const d: Date = new Date(ms);
  const mm: string = (d.getMonth() + 1) < 10 ? '0' + (d.getMonth() + 1).toString() : (d.getMonth() + 1).toString();
  const dd: string = d.getDate() < 10 ? '0' + d.getDate().toString() : d.getDate().toString();
  return d.getFullYear().toString() + '-' + mm + '-' + dd;
}
