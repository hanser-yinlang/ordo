/**
 * Ordo · 快找浮层(04 §4:顶部输入 44 高,结果行 36,高亮匹配片段;支持 ↑↓ / Enter / Esc)
 * 搜索范围:待办(标题/备注,契约 §4)、项目、标签、内置清单。
 */

import { ListKind, Project, Tag, Todo } from '../core/model/Entities.ets';
import { AppStore } from '../viewmodel/AppStore.ets';
import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoRadius, OrdoSize, OrdoSpace } from '../theme/Tokens.ets';

/** 快找结果项 */
interface FindItem {
  kind: string;
  id: string;
  title: string;
  subtitle: string;
}

@Component
export struct FastFindSheet {
  @ObjectLink store: AppStore;
  @State private query: string = '';
  @State private cursor: number = 0;

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.store.isDark());
  }

  /** 汇总结果:清单 → 项目 → 标签 → 待办 */
  private results(): FindItem[] {
    const q: string = this.query.trim().toLowerCase();
    const out: FindItem[] = [];
    if (q.length === 0) {
      // 无输入时给出内置清单入口
      const lists: string[] = ['今天', '收件箱', '计划', '随时', '某天', '日志簿'];
      const kinds: ListKind[] = ['today', 'inbox', 'upcoming', 'anytime', 'someday', 'logbook'];
      for (let i = 0; i < lists.length; i++) {
        out.push({ kind: 'list', id: kinds[i], title: lists[i], subtitle: '内置清单' });
      }
      return out;
    }
    const projects: Project[] = this.store.projects();
    for (let i = 0; i < projects.length; i++) {
      const p: Project = projects[i];
      if (!p.deleted && p.name.toLowerCase().indexOf(q) >= 0) {
        out.push({ kind: 'project', id: p.id, title: p.name, subtitle: '项目' });
      }
    }
    const tags: Tag[] = this.store.tags();
    for (let i = 0; i < tags.length; i++) {
      const t: Tag = tags[i];
      if (t.name.toLowerCase().indexOf(q) >= 0 || ('#' + t.name).toLowerCase().indexOf(q) >= 0) {
        out.push({ kind: 'tag', id: t.name, title: '#' + t.name, subtitle: '标签' });
      }
    }
    const todos: Todo[] = this.store.fastFind(q);
    for (let i = 0; i < todos.length && out.length < 40; i++) {
      const t: Todo = todos[i];
      out.push({
        kind: 'todo',
        id: t.id,
        title: t.title,
        subtitle: t.status === 'open' ? '待办' : (t.status === 'done' ? '已完成' : '已取消')
      });
    }
    return out;
  }

  private open(item: FindItem): void {
    if (item.kind === 'list') {
      this.store.goList(item.id as ListKind);
    } else if (item.kind === 'project') {
      this.store.goProject(item.id);
    } else if (item.kind === 'tag') {
      this.store.goTag(item.id);
    } else {
      const t: Todo | null = this.store.findTodo(item.id);
      if (t !== null) {
        if (t.projectId !== null) {
          this.store.goProject(t.projectId);
        } else {
          this.store.goList(t.when === 'inbox' ? 'inbox' : 'today');
        }
        this.store.selectedTodoId = t.id;
      }
    }
    this.store.fastFindOpen = false;
    this.store.bump();
  }

  @Builder
  resultRow(item: FindItem, index: number) {
    Row({ space: OrdoSpace.s }) {
      Text(this.glyphOf(item.kind))
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textSecondary)
        .width(20)
        .textAlign(TextAlign.Center)
      Text(item.title)
        .fontSize(OrdoFont.body.size)
        .fontColor(this.c().textPrimary)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(item.subtitle)
        .fontSize(OrdoFont.micro.size)
        .fontColor(this.c().textTertiary)
    }
    .width('100%')
    .height(OrdoSize.findRowHeight)
    .padding({ left: OrdoSpace.s, right: OrdoSpace.s })
    .borderRadius(OrdoRadius.row)
    .backgroundColor(this.cursor === index ? this.c().rowSelected : Color.Transparent)
    .onClick(() => {
      this.open(item);
    })
  }

  private glyphOf(kind: string): string {
    if (kind === 'list') {
      return '▤';
    }
    if (kind === 'project') {
      return '◎';
    }
    if (kind === 'tag') {
      return '#';
    }
    return '✓';
  }

  build() {
    Column({ space: OrdoSpace.s }) {
      Row({ space: OrdoSpace.s }) {
        Text('⌕')
          .fontSize(18)
          .fontColor(this.c().textSecondary)
        TextInput({ placeholder: '搜索待办、项目、标签…', text: this.query })
          .layoutWeight(1)
          .height(OrdoSize.findInputHeight)
          .fontSize(OrdoFont.body.size)
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => {
            this.query = value;
            this.cursor = 0;
          })
          .onSubmit(() => {
            const list: FindItem[] = this.results();
            if (list.length > this.cursor) {
              this.open(list[this.cursor]);
            }
          })
        Text('Esc')
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().textTertiary)
          .borderRadius(4)
          .border({ width: 1, color: this.c().lineHairline })
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .onClick(() => {
            this.store.fastFindOpen = false;
            this.store.bump();
          })
      }
      .width('100%')

      Divider().color(this.c().lineHairline)

      List() {
        ForEach(this.results(), (item: FindItem, index: number) => {
          ListItem() {
            this.resultRow(item, index)
          }
        }, (item: FindItem) => item.kind + '_' + item.id)
      }
      .width('100%')
      .height(360)
      .scrollBar(BarState.Off)

      Row() {
        Text('↑↓ 选择 · Enter 打开 · Esc 关闭 · 输入 #标签 过滤')
          .fontSize(OrdoFont.micro.size)
          .fontColor(this.c().textTertiary)
      }
      .width('100%')
    }
    .width('100%')
    .constraintSize({ maxWidth: 560 })
    .padding(OrdoSpace.l)
    .backgroundColor(this.c().bgSurface)
    .borderRadius(OrdoRadius.sheet)
    .border({ width: 1, color: this.c().lineHairline })
    .shadow({ radius: 40, color: 'rgba(0,0,0,0.18)', offsetY: 12 })
  }
}
