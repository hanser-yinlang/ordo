/**
 * Ordo · 快加号 QuickAdd(04 §4:直径 52、accent.primary 底 + 白色加号、阴影 elev.sheet;
 * 按住展开菜单:新建待办 / 项目 / 区域 / 标题)
 * 以及行内新建面板 QuickAddPanel(自然语言实时预览,契约 §5)。
 */

import { ParsedInput, parseNaturalNow } from '../core/nlp/NaturalDateParser.ets';
import { fmtMonthDay } from '../core/util/DateUtil.ets';
import { AppStore } from '../viewmodel/AppStore.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoRadius, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';

@Component
export struct QuickAddFab {
  @ObjectLink store: AppStore;
  @State private menuOpen: boolean = false;

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
  }

  @Builder
  menuItem(glyph: string, label: string, action: () => void) {
    Row({ space: OrdoSpace.s }) {
      Text(glyph)
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textSecondary)
        .width(20)
        .textAlign(TextAlign.Center)
      Text(label)
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textPrimary)
    }
    .width(160)
    .height(OrdoSize.minTouchTarget)
    .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
    .backgroundColor(this.c().bgSurface)
    .onClick(() => {
      this.menuOpen = false;
      action();
    })
  }

  build() {
    Column({ space: OrdoSpace.s }) {
      if (this.menuOpen) {
        Column() {
          this.menuItem('＋', '新建待办', (): void => {
            this.store.openQuickAdd('', '', '');
          })
          this.menuItem('◎', '新建项目', (): void => {
            this.store.createProject('新项目', this.store.list === 'area' ? this.store.areaId : '');
          })
          this.menuItem('▣', '新建区域', (): void => {
            this.store.createArea('新区域');
          })
          if (this.store.list === 'project') {
            this.menuItem('▤', '新建标题', (): void => {
              this.store.addHeading(this.store.projectId, '新标题');
            })
          }
        }
        .backgroundColor(this.c().bgSurface)
        .borderRadius(OrdoRadius.card)
        .border({ width: 1, color: this.c().lineHairline })
        .shadow({ radius: 40, color: 'rgba(0,0,0,0.18)', offsetY: 12 })
        .clip(true)
      }

      // 快加号本体
      Stack() {
        Circle()
          .width(OrdoSize.quickAdd)
          .height(OrdoSize.quickAdd)
          .fill(this.c().accentPrimary)
        Text('＋')
          .fontSize(26)
          .fontColor('#FFFFFF')
      }
      .width(OrdoSize.quickAdd)
      .height(OrdoSize.quickAdd)
      .shadow({ radius: 40, color: 'rgba(0,0,0,0.18)', offsetY: 12 })
      .rotate({ angle: this.menuOpen ? 45 : 0 })
      .animation({ duration: 180, curve: Curve.FastOutSlowIn })
      .onClick(() => {
        if (this.menuOpen) {
          this.menuOpen = false;
          this.store.openQuickAdd('', '', '');
        } else {
          this.store.openQuickAdd('', '', '');
        }
      })
      .gesture(
        LongPressGesture({ repeat: false })
          .onAction(() => {
            this.menuOpen = !this.menuOpen;
          })
      )
    }
    .alignItems(HorizontalAlign.End)
  }
}

@Component
export struct QuickAddPanel {
  @ObjectLink store: AppStore;
  @State private draft: string = '';

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
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
          .layoutWeight(1)
          .height(OrdoSize.rowHeight)
          .fontSize(OrdoFont.body.size)
          .backgroundColor(Color.Transparent)
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
