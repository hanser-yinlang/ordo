/**
 * Ordo · 行模型与行级差量用例
 *
 * 覆盖本轮「列表行级增量刷新」的全部纯逻辑(`view/list/RowModel.ets`,不依赖 ArkUI):
 *  1. 行序列与改前 ListPage 的渲染顺序逐行等价;
 *  2. 行键 = 身份 + 内容指纹:内容不变键不变,内容变则只有该行键变;
 *  3. 差量分类:无变化 0 条 / 内容变 → reload / 纯增 → add / 纯删 → delete / 重排 → 交换序列;
 *  4. 拖拽开关只在 order 生效的清单 + 同容器分区开启。
 *
 * 数据源本身的时序(`DataChangeListener` 调用)由 `_qa/row-perf-harness.mjs` 用真实 `RowDataSource`
 * 在 Node 上跑,那里能记录每一次通知,比在 Hypium 里实现一个假的监听器更直接。
 */

import { describe, expect, it } from '@ohos/hypium';
import { ListKind, Todo, When } from '../../../main/ets/core/model/Entities.ets';
import { DayGroup, HeadingGroup, LogbookGroup } from '../../../main/ets/core/query/ListQuery.ets';
import { ListRow, RowEdit, RowInput, buildRows, diffRows } from '../../../main/ets/view/list/RowModel.ets';
import { makeTodo, TodoOverrides } from './Fixtures.ets';

const TODAY: string = '2026-10-09';

function rowInput(list: ListKind, todos: Todo[]): RowInput {
  return {
    key: list,
    list: list,
    today: TODAY,
    selectedTodoId: '',
    animatingTodoId: '',
    events: [],
    main: [],
    tonight: [],
    upcoming: [],
    headings: [],
    logbook: [],
    todos: list === 'today' ? [] : todos
  };
}

function todayInput(main: Todo[], tonight: Todo[]): RowInput {
  const input: RowInput = rowInput('today', []);
  input.main = main;
  input.tonight = tonight;
  return input;
}

function keys(rows: ListRow[]): string {
  const out: string[] = [];
  for (let i = 0; i < rows.length; i++) {
    out.push(rows[i].key);
  }
  return out.join(',');
}

function kinds(rows: ListRow[]): string {
  const out: string[] = [];
  for (let i = 0; i < rows.length; i++) {
    out.push(rows[i].kind);
  }
  return out.join(',');
}

function mk(id: string, title: string, when: When, o?: TodoOverrides): Todo {
  return makeTodo(id, title, when, o);
}

/** 把交换序列应用到旧序列(与 RowDataSource.apply 对 move 的处理完全一致) */
function applyEdits(cur: ListRow[], next: ListRow[], edits: RowEdit[]): string {
  const live: ListRow[] = cur.slice(0);
  for (let i = 0; i < edits.length; i++) {
    const e: RowEdit = edits[i];
    if (e.op === 'delete') {
      live.splice(e.index, 1);
    } else if (e.op === 'add') {
      live.splice(e.index, 0, next[e.index]);
    } else if (e.op === 'move') {
      const tmp: ListRow = live[e.index];
      live[e.index] = live[e.to];
      live[e.to] = tmp;
    } else if (e.op === 'reload') {
      return keys(next);
    }
  }
  return keys(live);
}

export default function rowModelTest() {
  describe('RowModel', () => {

    it('today_rows_match_legacy_order', 0, () => {
      const main: Todo[] = [mk('a', 'A', 'today'), mk('b', 'B', 'today')];
      const tonight: Todo[] = [mk('c', 'C', 'evening')];
      const rows: ListRow[] = buildRows(todayInput(main, tonight));
      // 改前:分组标题「今天」→ 行 → 分组标题「今晚」→ 行
      expect(kinds(rows)).assertEqual('group,todo,todo,group,todo');
      expect(rows[0].label).assertEqual('今天');
      expect(rows[0].count).assertEqual(2);
      expect(rows[3].label).assertEqual('今晚');
      expect(rows[3].tone).assertEqual('tonight');
    });

    it('empty_today_renders_empty_state_row', 0, () => {
      const rows: ListRow[] = buildRows(todayInput([], []));
      expect(kinds(rows)).assertEqual('group,empty');
      expect(rows[1].emptyTarget).assertEqual('inbox');
    });

    it('plain_list_without_rows_renders_empty_state', 0, () => {
      const rows: ListRow[] = buildRows(rowInput('inbox', []));
      expect(kinds(rows)).assertEqual('empty');
      expect(rows[0].emptyTitle).assertEqual('收件箱是空的');
    });

    it('upcoming_groups_keep_day_keys', 0, () => {
      const input: RowInput = rowInput('upcoming', []);
      const g1: DayGroup = { date: '2026-10-10', label: '2026-10-10', todos: [mk('a', 'A', 'date')], overflow: false };
      const g2: DayGroup = { date: '', label: '更晚', todos: [mk('b', 'B', 'anytime')], overflow: true };
      input.upcoming = [g1, g2];
      const rows: ListRow[] = buildRows(input);
      expect(kinds(rows)).assertEqual('group,todo,group,todo');
      expect(rows[0].id).assertEqual('g:day:2026-10-10');
      expect(rows[2].id).assertEqual('g:day:later');
      expect(rows[2].label).assertEqual('更晚');
    });

    it('project_groups_use_heading_rows_and_skip_loose_title', 0, () => {
      const input: RowInput = rowInput('project', []);
      const h: HeadingGroup = {
        headingId: 'h1',
        name: '第一步',
        collapsed: false,
        todos: [mk('a', 'A', 'anytime')]
      };
      const loose: HeadingGroup = { headingId: null, name: '', collapsed: false, todos: [mk('b', 'B', 'anytime')] };
      input.headings = [h, loose];
      const rows: ListRow[] = buildRows(input);
      // 有标题的分组出标题行;「无标题」分组不出标题行(与改前一致)
      expect(kinds(rows)).assertEqual('heading,todo,todo');
      expect(rows[0].id).assertEqual('h:h1');
    });

    it('logbook_groups_use_day_label', 0, () => {
      const input: RowInput = rowInput('logbook', []);
      const g: LogbookGroup = { date: '2026-10-08', label: '2026-10-08', todos: [mk('a', 'A', 'today')] };
      input.logbook = [g];
      const rows: ListRow[] = buildRows(input);
      expect(rows[0].label.length > 0).assertTrue();
      expect(rows[0].id).assertEqual('g:lb:2026-10-08');
    });

    it('key_is_stable_when_nothing_changes', 0, () => {
      const todos: Todo[] = [mk('a', 'A', 'inbox'), mk('b', 'B', 'inbox')];
      const first: ListRow[] = buildRows(rowInput('inbox', todos));
      const second: ListRow[] = buildRows(rowInput('inbox', todos));
      expect(keys(first)).assertEqual(keys(second));
      expect(diffRows(first, second).length).assertEqual(0);
    });

    it('title_edit_changes_only_that_row_key', 0, () => {
      const before: ListRow[] = buildRows(rowInput('inbox', [mk('a', 'A', 'inbox'), mk('b', 'B', 'inbox')]));
      const after: ListRow[] = buildRows(rowInput('inbox', [mk('a', 'A2', 'inbox'), mk('b', 'B', 'inbox')]));
      expect(before[0].key === after[0].key).assertFalse();
      expect(before[1].key === after[1].key).assertTrue();
      const edits: RowEdit[] = diffRows(before, after);
      expect(edits.length).assertEqual(1);
      expect(edits[0].op).assertEqual('reload');
    });

    it('adding_a_row_emits_single_add', 0, () => {
      // 用标签清单:它不开放拖拽,所以「分区从 1 行变 2 行」不会翻转 dragEnabled 指纹,
      // 差量能干净地落到纯 add 分支(收件箱那种会翻转的清单见下一个用例)。
      const before: ListRow[] = buildRows(rowInput('tag', [mk('a', 'A', 'inbox')]));
      const after: ListRow[] = buildRows(rowInput('tag', [mk('a', 'A', 'inbox'), mk('b', 'B', 'inbox')]));
      const edits: RowEdit[] = diffRows(before, after);
      expect(edits.length).assertEqual(1);
      expect(edits[0].op).assertEqual('add');
      expect(edits[0].index).assertEqual(1);
    });

    it('removing_a_row_emits_single_delete', 0, () => {
      const before: ListRow[] = buildRows(rowInput('tag', [mk('a', 'A', 'inbox'), mk('b', 'B', 'inbox')]));
      const after: ListRow[] = buildRows(rowInput('tag', [mk('a', 'A', 'inbox')]));
      const edits: RowEdit[] = diffRows(before, after);
      expect(edits.length).assertEqual(1);
      expect(edits[0].op).assertEqual('delete');
      expect(edits[0].index).assertEqual(1);
    });

    it('drag_affordance_toggle_counts_as_content_change', 0, () => {
      // 收件箱:1 行时不可拖、2 行时可拖 → 原有那行的 dragEnabled 指纹翻转,
      // 属于**真实的内容变化**,差量必须走 reload(而不是假装只有一条被 add)。
      const before: ListRow[] = buildRows(rowInput('inbox', [mk('a', 'A', 'inbox')]));
      const after: ListRow[] = buildRows(rowInput('inbox', [mk('a', 'A', 'inbox'), mk('b', 'B', 'inbox')]));
      expect(before[0].dragEnabled).assertFalse();
      expect(after[0].dragEnabled).assertTrue();
      expect(before[0].key === after[0].key).assertFalse();
      const edits: RowEdit[] = diffRows(before, after);
      expect(edits.length).assertEqual(1);
      expect(edits[0].op).assertEqual('reload');
    });

    it('reorder_emits_swaps_and_reproduces_target_order', 0, () => {
      const a: Todo = mk('a', 'A', 'inbox');
      const b: Todo = mk('b', 'B', 'inbox');
      const c: Todo = mk('c', 'C', 'inbox');
      const d: Todo = mk('d', 'D', 'inbox');
      const before: ListRow[] = buildRows(rowInput('inbox', [a, b, c, d]));
      const after: ListRow[] = buildRows(rowInput('inbox', [a, d, b, c]));
      const edits: RowEdit[] = diffRows(before, after);
      let moves: number = 0;
      for (let i = 0; i < edits.length; i++) {
        expect(edits[i].op).assertEqual('move');
        moves = moves + 1;
      }
      expect(moves > 0).assertTrue();
      // 交换语义应用后必须与目标序列逐位同键
      expect(applyEdits(before, after, edits)).assertEqual(keys(after));
    });

    it('mixed_add_and_delete_falls_back_to_reload', 0, () => {
      const before: ListRow[] = buildRows(rowInput('inbox', [mk('a', 'A', 'inbox'), mk('b', 'B', 'inbox')]));
      const after: ListRow[] = buildRows(rowInput('inbox', [mk('b', 'B', 'inbox'), mk('c', 'C', 'inbox')]));
      const edits: RowEdit[] = diffRows(before, after);
      expect(edits.length).assertEqual(1);
      expect(edits[0].op).assertEqual('reload');
    });

    it('drag_enabled_only_for_order_driven_lists', 0, () => {
      const same: Todo[] = [mk('a', 'A', 'inbox'), mk('b', 'B', 'inbox')];
      const inboxRows: ListRow[] = buildRows(rowInput('inbox', same));
      expect(inboxRows[0].dragEnabled).assertTrue();
      const tagRows: ListRow[] = buildRows(rowInput('tag', same));
      expect(tagRows[0].dragEnabled).assertFalse();
      const logbookRows: ListRow[] = buildRows(rowInput('logbook', same));
      expect(logbookRows[0].dragEnabled).assertFalse();
    });

    it('drag_disabled_when_section_mixes_containers', 0, () => {
      const mixed: ListRow[] = buildRows(rowInput('area', [
        mk('a', 'A', 'anytime'),
        mk('b', 'B', 'someday'),
        mk('c', 'C', 'anytime')
      ]));
      expect(mixed[0].dragEnabled).assertFalse();
      expect(mixed[1].dragEnabled).assertFalse();
      expect(mixed[2].dragEnabled).assertFalse();
    });

    it('drag_disabled_for_single_row_section', 0, () => {
      const rows: ListRow[] = buildRows(rowInput('inbox', [mk('a', 'A', 'inbox')]));
      expect(rows[0].dragEnabled).assertFalse();
    });

    it('oversized_reorder_falls_back_to_reload', 0, () => {
      const all: Todo[] = [];
      for (let i = 0; i < 120; i++) {
        all.push(mk('t' + i.toString(), 'T' + i.toString(), 'inbox'));
      }
      const before: ListRow[] = buildRows(rowInput('inbox', all));
      const rotated: Todo[] = [];
      rotated.push(all[0]);
      for (let i = 2; i < all.length; i++) {
        rotated.push(all[i]);
      }
      rotated.push(all[1]);
      const after: ListRow[] = buildRows(rowInput('inbox', rotated));
      const edits: RowEdit[] = diffRows(before, after);
      // 位移 118 格 > MAX_SWAPS(64) → 一次 reload,而不是上百条交换
      expect(edits.length).assertEqual(1);
      expect(edits[0].op).assertEqual('reload');
    });
  });
}
