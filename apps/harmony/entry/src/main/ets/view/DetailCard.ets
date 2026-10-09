/**
 * Ordo · 详情卡片(04 §4:白纸感、圆角 14、内边距 16、标题输入 20/26、字段区为可点胶囊按钮)
 * 字段:何时 / 截止 / 提醒 / 重复 / 移动到 / 标签 / 清单;底部:完成、取消、复制、删除、关闭
 */

import { ChecklistItem, Project, Todo } from '../core/model/Entities.ets';
import { checklistProgress } from '../core/query/ListQuery.ets';
import { repeatLabel } from '../core/repeat/RepeatEngine.ets';
import { fmtReminder, fmtShortDate, todayISO } from '../core/util/DateUtil.ets';
import { AppStore } from '../viewmodel/AppStore.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoRadius, OrdoSpace } from '../theme/Tokens.ets';

@Component
export struct DetailCard {
  @ObjectLink store: AppStore;
  @Prop todoId: string = '';
  @State private tagDraft: string = '';
  @State private checklistDraft: string = '';

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
  }

  private todo(): Todo | null {
    return this.store.findTodo(this.todoId);
  }

  private title(): string {
    const t: Todo | null = this.todo();
    return t === null ? '' : t.title;
  }

  private note(): string {
    const t: Todo | null = this.todo();
    return t === null ? '' : t.note;
  }

  private whenText(): string {
    const t: Todo | null = this.todo();
    if (t === null) {
      return '';
    }
    if (t.when === 'inbox') {
      return '收件箱';
    }
    if (t.when === 'today') {
      return '今天';
    }
    if (t.when === 'evening') {
      return '今晚';
    }
    if (t.when === 'anytime') {
      return '随时';
    }
    if (t.when === 'someday') {
      return '某天';
    }
    return t.date === null ? '日期' : fmtShortDate(t.date);
  }

  private whereText(): string {
    const t: Todo | null = this.todo();
    if (t === null) {
      return '移动到…';
    }
    if (t.projectId !== null) {
      const p: Project | null = this.store.findProject(t.projectId);
      return p === null ? '移动到…' : p.name;
    }
    if (t.areaId !== null) {
      const e = this.store.areas();
      for (let i = 0; i < e.length; i++) {
        if (e[i].id === t.areaId) {
          return e[i].name;
        }
      }
    }
    return '移动到…';
  }

  @Builder
  fieldPill(glyph: string, label: string, danger: boolean, action: () => void) {
    Row({ space: 4 }) {
      Text(glyph)
        .fontSize(OrdoFont.caption.size)
        .fontColor(danger ? this.c().stateDanger : this.c().textSecondary)
      Text(label)
        .fontSize(OrdoFont.caption.size)
        .fontColor(danger ? this.c().stateDanger : this.c().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .height(28)
    .padding({ left: OrdoSpace.s, right: OrdoSpace.s })
    .backgroundColor(this.c().chipBg)
    .borderRadius(OrdoRadius.pill)
    .onClick(() => {
      action();
    })
  }

  @Builder
  checklistSection() {
    Column({ space: OrdoSpace.xs }) {
      Row() {
        Text('清单')
          .fontSize(OrdoFont.micro.size)
          .fontWeight(500)
          .fontColor(this.c().textTertiary)
          .letterSpacing(0.4)
          .layoutWeight(1)
        Text(checklistProgress(this.checklist()))
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().textTertiary)
      }
      .width('100%')

      ForEach(this.checklist(), (item: ChecklistItem) => {
        Row({ space: OrdoSpace.s }) {
          Stack() {
            if (item.done) {
              Circle().width(16).height(16).fill(this.c().accentPrimary)
              Text('✓').fontSize(10).fontColor('#FFFFFF')
            } else {
              Circle().width(16).height(16).fillOpacity(0).stroke(this.c().checkboxBorder).strokeWidth(1.4)
            }
          }
          .width(16)
          .height(16)
          .onClick(() => {
            this.store.toggleChecklistItem(this.todoId, item.id);
          })
          Text(item.title)
            .fontSize(OrdoFont.body.size)
            .fontColor(item.done ? this.c().textTertiary : this.c().textPrimary)
            .decoration({ type: item.done ? TextDecorationType.LineThrough : TextDecorationType.None, color: this.c().textTertiary })
            .layoutWeight(1)
          Text('✕')
            .fontSize(OrdoFont.caption.size)
            .fontColor(this.c().textTertiary)
            .onClick(() => {
              this.store.removeChecklistItem(this.todoId, item.id);
            })
        }
        .width('100%')
        .height(32)
      }, (item: ChecklistItem) => item.id)

      Row({ space: OrdoSpace.s }) {
        TextInput({ placeholder: '新清单项', text: this.checklistDraft })
          .layoutWeight(1)
          .height(36)
          .fontSize(OrdoFont.body.size)
          .backgroundColor(Color.Transparent)
          .padding({ left: 0 })
          .onChange((value: string) => {
            this.checklistDraft = value;
          })
          .onSubmit(() => {
            if (this.checklistDraft.trim().length > 0) {
              this.store.addChecklistItem(this.todoId, this.checklistDraft.trim());
              this.checklistDraft = '';
            }
          })
        Text('添加')
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().accentPrimary)
          .onClick(() => {
            if (this.checklistDraft.trim().length > 0) {
              this.store.addChecklistItem(this.todoId, this.checklistDraft.trim());
              this.checklistDraft = '';
            }
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  build() {
    Column({ space: OrdoSpace.m }) {
      // 标题(可编辑,清空即删除 —— 契约 §3)
      TextInput({ text: this.title(), placeholder: '标题' })
        .fontSize(OrdoFont.title.size)
        .fontWeight(OrdoFont.title.weight)
        .fontColor(this.c().textPrimary)
        .backgroundColor(Color.Transparent)
        .padding({ left: 0, right: 0 })
        .onSubmit(() => {
          // 提交时不做处理,由 onChange 实时同步
        })
        .onChange((value: string) => {
          this.store.setTodoTitle(this.todoId, value);
        })

      // 备注(Markdown 原文;预览由列表页的单行摘要呈现)
      TextArea({ text: this.note(), placeholder: '备注(支持 # 标题、- 列表、**加粗**、`代码`)' })
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textPrimary)
        .backgroundColor(Color.Transparent)
        .padding({ left: 0, right: 0 })
        .height(64)
        .onChange((value: string) => {
          this.store.setTodoNote(this.todoId, value);
        })

      // 字段胶囊
      Flex({ wrap: FlexWrap.Wrap }) {
        this.fieldPill('▦', '何时:' + this.whenText(), false, (): void => {
          this.store.openSchedule(this.todoId, false);
        })
        this.fieldPill('⚑', this.deadlineText(), this.isOverdue(), (): void => {
          this.store.openSchedule(this.todoId, true);
        })
        this.fieldPill('⏰', this.reminderText(), false, (): void => {
          this.store.openSchedule(this.todoId, false);
        })
        this.fieldPill('⟳', this.repeatText(), false, (): void => {
          this.store.cycleRepeat(this.todoId);
        })
        this.fieldPill('◎', this.whereText(), false, (): void => {
          this.store.moveToNextProject(this.todoId);
        })
      }
      .width('100%')

      // 标签
      Row({ space: OrdoSpace.s }) {
        ForEach(this.tags(), (name: string) => {
          Row({ space: 4 }) {
            Text(name)
              .fontSize(OrdoFont.micro.size)
              .fontColor(this.c().chipText)
            Text('✕')
              .fontSize(OrdoFont.micro.size)
              .fontColor(this.c().textTertiary)
              .onClick(() => {
                this.store.removeTag(this.todoId, name);
              })
          }
          .height(24)
          .padding({ left: OrdoSpace.s, right: OrdoSpace.s })
          .backgroundColor(this.c().chipBg)
          .borderRadius(OrdoRadius.pill)
        }, (name: string) => this.todoId + '_t_' + name)

        TextInput({ placeholder: '加标签', text: this.tagDraft })
          .layoutWeight(1)
          .height(32)
          .fontSize(OrdoFont.caption.size)
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => {
            this.tagDraft = value;
          })
          .onSubmit(() => {
            if (this.tagDraft.trim().length > 0) {
              this.store.addTag(this.todoId, this.tagDraft.trim());
              this.tagDraft = '';
            }
          })
      }
      .width('100%')

      Divider().color(this.c().lineHairline)

      this.checklistSection()

      Divider().color(this.c().lineHairline)

      Row({ space: OrdoSpace.s }) {
        if (this.isDone()) {
          this.actionButton('恢复', false, (): void => {
            this.store.restoreTodo(this.todoId);
          })
        } else {
          this.actionButton('完成', true, (): void => {
            this.store.toggleDone(this.todoId);
          })
          this.actionButton('取消', false, (): void => {
            this.store.cancelTodo(this.todoId);
          })
        }
        this.actionButton('复制', false, (): void => {
          this.store.duplicateTodo(this.todoId);
        })
        this.actionButton('删除', false, (): void => {
          this.store.deleteTodo(this.todoId);
        })
        Blank()
        this.actionButton('关闭', false, (): void => {
          this.store.setSelected(this.todoId);
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding(OrdoSpace.l)
    .backgroundColor(this.c().bgSurface)
    .borderRadius(OrdoRadius.card)
    .border({ width: 1, color: this.c().lineHairline })
    .margin({ top: OrdoSpace.s, bottom: OrdoSpace.s })
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.08)', offsetY: 8 })
  }

  @Builder
  actionButton(label: string, primary: boolean, action: () => void) {
    Text(label)
      .fontSize(OrdoFont.caption.size)
      .fontColor(primary ? '#FFFFFF' : this.c().textPrimary)
      .backgroundColor(primary ? this.c().accentPrimary : this.c().chipBg)
      .height(32)
      .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
      .borderRadius(OrdoRadius.pill)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        action();
      })
  }

  /* ------------------------------------------------------------ 取值辅助 */

  private tags(): string[] {
    const t: Todo | null = this.todo();
    return t === null ? [] : t.tags;
  }

  private checklist(): ChecklistItem[] {
    const t: Todo | null = this.todo();
    return t === null ? [] : t.checklist;
  }

  private isDone(): boolean {
    const t: Todo | null = this.todo();
    return t !== null && (t.status === 'done' || t.status === 'canceled');
  }

  private deadlineText(): string {
    const t: Todo | null = this.todo();
    if (t === null || t.deadline === null) {
      return '截止日期';
    }
    return '截止:' + fmtShortDate(t.deadline);
  }

  private isOverdue(): boolean {
    const t: Todo | null = this.todo();
    return t !== null && t.deadline !== null && t.deadline < todayISO() && t.status === 'open';
  }

  private reminderText(): string {
    const t: Todo | null = this.todo();
    if (t === null || t.reminder === null) {
      return '提醒';
    }
    return '提醒:' + fmtReminder(t.reminder);
  }

  private repeatText(): string {
    const t: Todo | null = this.todo();
    if (t === null || t.repeat === null) {
      return '重复';
    }
    return repeatLabel(t.repeat);
  }
}
