/**
 * Ordo · 侧栏(04 §3:宽 248;§4:侧栏项高 34、图标 18、文字 15/22、计数 13/18)
 * 结构:固定清单(6)→ 区域(可折叠,内含项目 + 进度环)→ 标签 → 底部工具与同步状态
 */

import { Area, ListKind, Project, Tag, Todo } from '../core/model/Entities.ets';
import { SidebarCounts } from '../core/query/ListQuery.ets';
import { AppStore } from '../viewmodel/AppStore.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoRadius, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';

/** 固定清单项定义 */
interface FixedList {
  kind: ListKind;
  label: string;
  glyph: string;
}

@Component
export struct Sidebar {
  @ObjectLink store: AppStore;

  private fixedLists: FixedList[] = [
    { kind: 'inbox', label: '收件箱', glyph: '▤' },
    { kind: 'today', label: '今天', glyph: '★' },
    { kind: 'upcoming', label: '计划', glyph: '▦' },
    { kind: 'anytime', label: '随时', glyph: '≡' },
    { kind: 'someday', label: '某天', glyph: '◇' },
    { kind: 'logbook', label: '日志簿', glyph: '▣' }
  ];

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
  }

  private countOf(kind: ListKind): number {
    const counts: SidebarCounts = this.store.counts();
    if (kind === 'inbox') {
      return counts.inbox;
    }
    if (kind === 'today') {
      return counts.today;
    }
    if (kind === 'upcoming') {
      return counts.upcoming;
    }
    if (kind === 'anytime') {
      return counts.anytime;
    }
    if (kind === 'someday') {
      return counts.someday;
    }
    return counts.logbook;
  }

  private isActive(kind: ListKind): boolean {
    return this.store.list === kind;
  }

  @Builder
  fixedRow(item: FixedList) {
    Row({ space: OrdoSpace.s }) {
      Text(item.glyph)
        .fontSize(OrdoSize.sideIcon)
        .fontColor(this.isActive(item.kind) ? this.c().accentPrimary : this.c().textSecondary)
        .width(OrdoSize.sideIcon + 4)
        .textAlign(TextAlign.Center)
      Text(item.label)
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textPrimary)
        .layoutWeight(1)
      Text(this.countOf(item.kind).toString())
        .fontSize(OrdoFont.caption.size)
        .fontColor(this.c().textSecondary)
    }
    .width('100%')
    .height(OrdoSize.sideItem)
    .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
    .borderRadius(OrdoRadius.row)
    .backgroundColor(this.isActive(item.kind) ? this.c().sideSelected : Color.Transparent)
    .onClick(() => {
      this.store.goList(item.kind);
    })
  }

  @Builder
  projectRow(p: Project) {
    Row({ space: OrdoSpace.s }) {
      // 进度环 18×18(线宽 2)
      Progress({ value: this.store.progressOf(p.id) * 100, total: 100, type: ProgressType.Ring })
        .width(OrdoSize.progressRing)
        .height(OrdoSize.progressRing)
        .color(this.c().accentPrimary)
        .backgroundColor(this.c().lineHairline)
        .style({ strokeWidth: OrdoSize.progressRingStroke })
      Text(p.name)
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textPrimary)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.openCountOfProject(p.id).toString())
        .fontSize(OrdoFont.caption.size)
        .fontColor(this.c().textSecondary)
    }
    .width('100%')
    .height(OrdoSize.sideItem)
    .padding({ left: OrdoSpace.xl + OrdoSpace.s, right: OrdoSpace.m })
    .borderRadius(OrdoRadius.row)
    .backgroundColor(this.store.list === 'project' && this.store.projectId === p.id ? this.c().sideSelected : Color.Transparent)
    .onClick(() => {
      this.store.goProject(p.id);
    })
  }

  @Builder
  areaBlock(a: Area) {
    Column() {
      Row({ space: OrdoSpace.s }) {
        Text(a.archived ? '▸' : '▾')
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().textTertiary)
          .width(12)
          .textAlign(TextAlign.Center)
        Text(a.name)
          .fontSize(OrdoFont.caption.size)
          .fontWeight(500)
          .fontColor(this.c().textSecondary)
          .layoutWeight(1)
        Text(this.areaOpenCount(a.id).toString())
          .fontSize(OrdoFont.caption.size)
          .fontColor(this.c().textTertiary)
      }
      .width('100%')
      .height(OrdoSize.sideItem)
      .padding({ left: OrdoSpace.s, right: OrdoSpace.m })
      .onClick(() => {
        this.store.goArea(a.id);
      })

      if (!a.archived) {
        ForEach(this.projectsOfArea(a.id), (p: Project) => {
          this.projectRow(p);
        }, (p: Project) => p.id)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  tagRow(tag: Tag) {
    Row({ space: OrdoSpace.s }) {
      Circle()
        .width(8)
        .height(8)
        .fill(tag.color)
      Text(tag.name)
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textPrimary)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.tagCountOf(tag.name).toString())
        .fontSize(OrdoFont.caption.size)
        .fontColor(this.c().textSecondary)
    }
    .width('100%')
    .height(OrdoSize.sideItem)
    .padding({ left: OrdoSpace.m, right: OrdoSpace.m })
    .borderRadius(OrdoRadius.row)
    .backgroundColor(this.store.list === 'tag' && this.store.tagName === tag.name ? this.c().sideSelected : Color.Transparent)
    .onClick(() => {
      this.store.goTag(tag.name);
    })
  }

  private projectsOfArea(areaId: string): Project[] {
    const out: Project[] = [];
    const list: Project[] = this.store.projects();
    for (let i = 0; i < list.length; i++) {
      const p: Project = list[i];
      if (p.areaId === areaId && !p.deleted && p.status === 'open') {
        out.push(p);
      }
    }
    return out;
  }

  private openCountOfProject(projectId: string): number {
    let n: number = 0;
    const list: Todo[] = this.store.todos();
    for (let i = 0; i < list.length; i++) {
      const t: Todo = list[i];
      if (t.projectId === projectId && !t.deleted && t.status === 'open') {
        n++;
      }
    }
    return n;
  }

  private areaOpenCount(areaId: string): number {
    let n: number = 0;
    const list: Todo[] = this.store.todos();
    for (let i = 0; i < list.length; i++) {
      const t: Todo = list[i];
      if (t.areaId === areaId && !t.deleted && t.status === 'open') {
        n++;
      }
    }
    return n;
  }

  private tagCountOf(name: string): number {
    const map: Map<string, number> = this.store.tagCountMap();
    return map.has(name) ? (map.get(name) as number) : 0;
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: OrdoSpace.xs }) {
          ForEach(this.fixedLists, (item: FixedList) => {
            this.fixedRow(item);
          }, (item: FixedList) => item.kind)

          Divider()
            .color(this.c().lineHairline)
            .margin({ top: OrdoSpace.m, bottom: OrdoSpace.s })

          Row() {
            Text('区域')
              .fontSize(OrdoFont.micro.size)
              .fontWeight(500)
              .fontColor(this.c().textTertiary)
              .letterSpacing(0.4)
              .layoutWeight(1)
            Text('＋')
              .fontSize(OrdoFont.body.size)
              .fontColor(this.c().textSecondary)
              .width(OrdoSize.minTouchTarget)
              .height(OrdoSize.minTouchTarget)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.store.createArea('新区域');
              })
          }
          .width('100%')
          .padding({ left: OrdoSpace.s, right: OrdoSpace.xs })

          ForEach(this.store.areas(), (a: Area) => {
            this.areaBlock(a);
          }, (a: Area) => a.id)

          Divider()
            .color(this.c().lineHairline)
            .margin({ top: OrdoSpace.m, bottom: OrdoSpace.s })

          Text('标签')
            .fontSize(OrdoFont.micro.size)
            .fontWeight(500)
            .fontColor(this.c().textTertiary)
            .letterSpacing(0.4)
            .width('100%')
            .padding({ left: OrdoSpace.m, bottom: OrdoSpace.xs })

          ForEach(this.store.tags(), (tag: Tag) => {
            this.tagRow(tag);
          }, (tag: Tag) => tag.id)
        }
        .width('100%')
        .padding({ left: OrdoSpace.s, right: OrdoSpace.s, top: OrdoSpace.m, bottom: OrdoSpace.xl })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      Divider().color(this.c().lineHairline)

      Row({ space: OrdoSpace.s }) {
        Text(this.store.themeGlyph())
          .fontSize(OrdoFont.body.size)
          .fontColor(this.c().textSecondary)
          .width(OrdoSize.minTouchTarget)
          .height(OrdoSize.minTouchTarget)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.store.cycleTheme();
          })
        Text('⚙')
          .fontSize(OrdoFont.body.size)
          .fontColor(this.c().textSecondary)
          .width(OrdoSize.minTouchTarget)
          .height(OrdoSize.minTouchTarget)
          .textAlign(TextAlign.Center)
          .id('ordo_sidebar_settings')
          .onClick(() => {
            this.store.settingsOpen = true;
            this.store.bump();
          })
        Column({ space: 2 }) {
          Text('序 · Ordo')
            .fontSize(OrdoFont.micro.size)
            .fontColor(this.c().textTertiary)
          Text('本地')
            .fontSize(OrdoFont.micro.size)
            .fontColor(this.c().textTertiary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: OrdoSpace.s, right: OrdoSpace.m, top: OrdoSpace.xs, bottom: OrdoSpace.xs })
    }
    .width(OrdoSize.sidebarWidth)
    .height('100%')
    .backgroundColor(this.c().bgSidebar)
  }
}
