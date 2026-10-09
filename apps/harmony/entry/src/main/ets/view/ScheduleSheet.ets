/**
 * Ordo · 排期面板(04 §4:浮层宽 280;上部自然语言输入,中部快捷项,下部月历,底部危险色"清除")
 * 同时承担「何时」与「截止日期」两种用途(通过 store.scheduleIsDeadline 区分)。
 */

import { ParsedInput, parseNaturalNow } from '../core/nlp/NaturalDateParser.ets';
import { Todo } from '../core/model/Entities.ets';
import { addDays, fmtMonthDay, isValidISODate, lastDayOfMonth, pad2, todayISO, weekdayIndex } from '../core/util/DateUtil.ets';
import { AppStore } from '../viewmodel/AppStore.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoRadius, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';

@Component
export struct ScheduleSheet {
  @ObjectLink store: AppStore;
  @State private draft: string = '';
  @State private year: number = 0;
  @State private month: number = 0;

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
  }

  private todo(): Todo | null {
    return this.store.findTodo(this.store.scheduleTodoId);
  }

  private isDeadline(): boolean {
    return this.store.scheduleIsDeadline;
  }

  aboutToAppear(): void {
    const parts: string[] = todayISO().split('-');
    this.year = parseInt(parts[0], 10);
    this.month = parseInt(parts[1], 10);
  }

  private daysInMonth(): number {
    return lastDayOfMonth(this.year, this.month);
  }

  /** 当月 1 日是周几(0=周日) */
  private firstWeekday(): number {
    return weekdayIndex(this.year.toString() + '-' + pad2(this.month) + '-01');
  }

  private monthLabel(): string {
    return this.year.toString() + ' 年 ' + this.month.toString() + ' 月';
  }

  private applyDate(iso: string): void {
    const id: string = this.store.scheduleTodoId;
    if (this.isDeadline()) {
      this.store.setDeadline(id, iso);
    } else {
      this.store.setWhen(id, 'date', iso);
    }
    this.store.showToast('已安排:' + fmtMonthDay(iso));
    this.store.closeSchedule();
  }

  private applyWhen(when: string, date: string): void {
    const id: string = this.store.scheduleTodoId;
    if (this.isDeadline()) {
      if (when === 'today' || when === 'date') {
        this.store.setDeadline(id, date.length > 0 ? date : todayISO());
      } else {
        this.store.setDeadline(id, '');
      }
    } else {
      this.store.setWhen(id, when, date);
    }
    this.store.closeSchedule();
  }

  @Builder
  quickItem(glyph: string, label: string, action: () => void) {
    Row({ space: OrdoSpace.s }) {
      Text(glyph)
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textSecondary)
        .width(20)
        .textAlign(TextAlign.Center)
      Text(label)
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textPrimary)
        .layoutWeight(1)
    }
    .width('100%')
    .height(OrdoSize.minTouchTarget)
    .padding({ left: OrdoSpace.s, right: OrdoSpace.s })
    .borderRadius(OrdoRadius.row)
    .onClick(() => {
      action();
    })
  }

  @Builder
  calendar() {
    Column({ space: OrdoSpace.xs }) {
      Row({ space: OrdoSpace.s }) {
        Text('‹')
          .fontSize(20)
          .fontColor(this.c().textSecondary)
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            if (this.month === 1) {
              this.month = 12;
              this.year = this.year - 1;
            } else {
              this.month = this.month - 1;
            }
          })
        Text(this.monthLabel())
          .fontSize(OrdoFont.caption.size)
          .fontWeight(600)
          .fontColor(this.c().textPrimary)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('›')
          .fontSize(20)
          .fontColor(this.c().textSecondary)
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            if (this.month === 12) {
              this.month = 1;
              this.year = this.year + 1;
            } else {
              this.month = this.month + 1;
            }
          })
      }
      .width('100%')

      Row() {
        ForEach(['日', '一', '二', '三', '四', '五', '六'], (w: string) => {
          Text(w)
            .fontSize(OrdoFont.micro.size)
            .fontColor(this.c().textTertiary)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
        }, (w: string) => 'dow_' + w)
      }
      .width('100%')

      // 6 行 × 7 列
      ForEach([0, 1, 2, 3, 4, 5], (rowIdx: number) => {
        Row() {
          ForEach([0, 1, 2, 3, 4, 5, 6], (colIdx: number) => {
            Text(this.cellLabel(rowIdx * 7 + colIdx))
              .fontSize(OrdoFont.caption.size)
              .fontColor(this.cellColor(rowIdx * 7 + colIdx))
              .backgroundColor(this.cellBg(rowIdx * 7 + colIdx))
              .width(30)
              .height(30)
              .borderRadius(15)
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .onClick(() => {
                const iso: string = this.cellISO(rowIdx * 7 + colIdx);
                if (iso.length > 0) {
                  this.applyDate(iso);
                }
              })
          }, (colIdx: number) => 'col_' + rowIdx.toString() + '_' + colIdx.toString())
        }
        .width('100%')
      }, (rowIdx: number) => 'row_' + rowIdx.toString())
    }
    .width('100%')
  }

  /** 网格序号 → 该格日期(空串表示上/下月的占位) */
  private cellISO(index: number): string {
    const day: number = index - this.firstWeekday() + 1;
    if (day < 1 || day > this.daysInMonth()) {
      return '';
    }
    return this.year.toString() + '-' + pad2(this.month) + '-' + pad2(day);
  }

  private cellLabel(index: number): string {
    const iso: string = this.cellISO(index);
    if (iso.length === 0) {
      return '';
    }
    return parseInt(iso.substring(8, 10), 10).toString();
  }

  private cellColor(index: number): string {
    const iso: string = this.cellISO(index);
    if (iso.length === 0) {
      return this.c().textTertiary;
    }
    return iso === todayISO() ? this.c().accentPrimary : this.c().textPrimary;
  }

  private cellBg(index: number): string {
    const iso: string = this.cellISO(index);
    const t: Todo | null = this.todo();
    if (t === null || iso.length === 0) {
      return 'rgba(0,0,0,0)';
    }
    const selected: string | null = this.isDeadline() ? t.deadline : t.date;
    if (selected !== null && selected === iso) {
      return this.c().chipBg;
    }
    return 'rgba(0,0,0,0)';
  }

  build() {
    Column({ space: OrdoSpace.s }) {
      Row() {
        Text(this.isDeadline() ? '截止日期' : '安排时间')
          .fontSize(OrdoFont.caption.size)
          .fontWeight(600)
          .fontColor(this.c().textSecondary)
          .layoutWeight(1)
        Text('✕')
          .fontSize(OrdoFont.body.size)
          .fontColor(this.c().textTertiary)
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.store.closeSchedule();
          })
      }
      .width('100%')

      // 自然语言输入(契约 §5)
      TextInput({ placeholder: '试试「明天」「周五」「18:00」「3 天后」', text: this.draft })
        .height(40)
        .fontSize(OrdoFont.body.size)
        .backgroundColor(this.c().chipBg)
        .borderRadius(OrdoRadius.row)
        .onChange((value: string) => {
          this.draft = value;
        })
        .onSubmit(() => {
          this.applyParsed();
        })

      if (this.draft.trim().length > 0) {
        Text(this.previewText())
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().accentPrimary)
          .width('100%')
      }

      Row() {
        Text('应用')
          .fontSize(OrdoFont.caption.size)
          .fontColor('#FFFFFF')
          .backgroundColor(this.c().accentPrimary)
          .height(32)
          .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
          .borderRadius(OrdoRadius.pill)
          .onClick(() => {
            this.applyParsed();
          })
        Blank()
      }
      .width('100%')

      Divider().color(this.c().lineHairline)

      this.quickItem('★', '今天', (): void => {
        this.applyWhen('today', '');
      })
      this.quickItem('☾', '今晚', (): void => {
        this.applyWhen('evening', '');
      })
      this.quickItem('▦', '明天', (): void => {
        this.applyWhen('date', addDays(todayISO(), 1));
      })
      this.quickItem('▤', '本周末', (): void => {
        const cur: number = weekdayIndex(todayISO());
        let delta: number = (6 - cur + 7) % 7;
        if (delta === 0) {
          delta = 7;
        }
        this.applyWhen('date', addDays(todayISO(), delta));
      })
      this.quickItem('◇', '某天', (): void => {
        this.applyWhen('someday', '');
      })

      Divider().color(this.c().lineHairline)

      this.calendar()

      Divider().color(this.c().lineHairline)

      Row({ space: OrdoSpace.s }) {
        Text('✕')
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().stateDanger)
        Text(this.isDeadline() ? '清除截止日期' : '清除时间')
          .fontSize(OrdoFont.body.size)
          .fontColor(this.c().stateDanger)
          .layoutWeight(1)
      }
      .width('100%')
      .height(OrdoSize.minTouchTarget)
      .onClick(() => {
        this.applyWhen('anytime', '');
      })
    }
    .width(OrdoSize.sheetWidth)
    .padding(OrdoSpace.l)
    .backgroundColor(this.c().bgSurface)
    .borderRadius(OrdoRadius.sheet)
    .border({ width: 1, color: this.c().lineHairline })
    .shadow({ radius: 40, color: 'rgba(0,0,0,0.18)', offsetY: 12 })
  }

  /** 输入解析预览 */
  private previewText(): string {
    const p: ParsedInput = parseNaturalNow(this.draft);
    const bits: string[] = [];
    if (p.when !== null) {
      bits.push('何时=' + (p.date !== null ? fmtMonthDay(p.date) : p.when));
    }
    if (p.reminder !== null) {
      bits.push('提醒=' + p.reminder.substring(11, 16));
    }
    if (p.tags.length > 0) {
      bits.push('标签=' + p.tags.join('、'));
    }
    if (bits.length === 0) {
      return '未识别到日期';
    }
    return '将应用:' + bits.join(' · ');
  }

  private applyParsed(): void {
    const p: ParsedInput = parseNaturalNow(this.draft);
    const id: string = this.store.scheduleTodoId;
    if (this.isDeadline()) {
      if (p.date !== null) {
        this.store.setDeadline(id, p.date);
      } else if (p.when === 'today') {
        this.store.setDeadline(id, todayISO());
      }
      this.store.closeSchedule();
      return;
    }
    if (p.date !== null && isValidISODate(p.date)) {
      this.store.setWhen(id, 'date', p.date);
    } else if (p.when !== null) {
      this.store.setWhen(id, p.when, '');
    }
    if (p.reminder !== null) {
      this.store.setReminder(id, p.reminder);
    }
    for (let i = 0; i < p.tags.length; i++) {
      this.store.addTag(id, p.tags[i]);
    }
    this.store.closeSchedule();
  }
}
