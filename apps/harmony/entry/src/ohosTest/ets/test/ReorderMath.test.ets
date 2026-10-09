/**
 * Ordo · 拖拽排序纯计算用例(`viewmodel/ReorderMath.ets`)
 *
 * 校验点:
 *  1. 容器键 = `(when, projectId, headingId)`,与 `OrdoEngine.nextOrder` 的作用域一致;
 *  2. 只有 order 真正生效的清单开放拖拽(今天/收件箱/随时/某天/项目/区域);
 *  3. `movedOrder` 的落点:向下拖落在目标行之后、向上拖落在目标行之前,且不改动其它行的相对顺序;
 *  4. 跨容器提交必须被 `sameContainer` 拒绝(与 iOS `reorderTodos(ids:)` 的两道闸门一致)。
 */

import { describe, expect, it } from '@ohos/hypium';
import { Todo, When } from '../../../main/ets/core/model/Entities.ets';
import { containerKeyOf, listSupportsReorder, movedOrder, sameContainer, sectionCanReorder } from '../../../main/ets/viewmodel/ReorderMath.ets';
import { makeTodo, TodoOverrides } from './Fixtures.ets';

function mk(id: string, when: When, o?: TodoOverrides): Todo {
  return makeTodo(id, id, when, o);
}

function ids(list: Todo[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < list.length; i++) {
    out.push(list[i].id);
  }
  return out;
}

function joined(list: string[]): string {
  return list.join(',');
}

export default function reorderMathTest() {
  describe('ReorderMath', () => {

    it('container_key_is_when_project_heading', 0, () => {
      const plain: Todo = mk('a', 'today');
      expect(containerKeyOf(plain)).assertEqual('today|-|-');
      const inProject: Todo = mk('b', 'anytime', { projectId: 'p1', headingId: 'h1' });
      expect(containerKeyOf(inProject)).assertEqual('anytime|p1|h1');
      const otherHeading: Todo = mk('c', 'anytime', { projectId: 'p1', headingId: 'h2' });
      expect(containerKeyOf(otherHeading) === containerKeyOf(inProject)).assertFalse();
    });

    it('reorder_supported_lists', 0, () => {
      expect(listSupportsReorder('today')).assertTrue();
      expect(listSupportsReorder('inbox')).assertTrue();
      expect(listSupportsReorder('anytime')).assertTrue();
      expect(listSupportsReorder('someday')).assertTrue();
      expect(listSupportsReorder('project')).assertTrue();
      expect(listSupportsReorder('area')).assertTrue();
      expect(listSupportsReorder('upcoming')).assertFalse();
      expect(listSupportsReorder('logbook')).assertFalse();
      expect(listSupportsReorder('tag')).assertFalse();
      expect(listSupportsReorder('search')).assertFalse();
    });

    it('section_needs_two_rows_in_one_container', 0, () => {
      expect(sectionCanReorder(['a|-|-'])).assertFalse();
      expect(sectionCanReorder(['a|-|-', 'a|-|-'])).assertTrue();
      expect(sectionCanReorder(['a|-|-', 'b|-|-'])).assertFalse();
    });

    it('move_down_lands_after_target', 0, () => {
      const moved: string[] | null = movedOrder(['a', 'b', 'c', 'd'], 'a', 'c');
      expect(moved === null).assertFalse();
      expect(joined(moved as string[])).assertEqual('b,c,a,d');
    });

    it('move_up_lands_before_target', 0, () => {
      const moved: string[] | null = movedOrder(['a', 'b', 'c', 'd'], 'd', 'b');
      expect(moved === null).assertFalse();
      expect(joined(moved as string[])).assertEqual('a,d,b,c');
    });

    it('move_adjacent_down_is_not_a_noop', 0, () => {
      const moved: string[] | null = movedOrder(['a', 'b', 'c'], 'a', 'b');
      expect(moved === null).assertFalse();
      expect(joined(moved as string[])).assertEqual('b,a,c');
    });

    it('move_onto_itself_returns_null', 0, () => {
      const moved: string[] | null = movedOrder(['a', 'b', 'c'], 'b', 'b');
      expect(moved === null).assertTrue();
    });

    it('move_keeps_other_rows_relative_order', 0, () => {
      const before: string[] = ['a', 'b', 'c', 'd', 'e', 'f'];
      const moved: string[] | null = movedOrder(before, 'e', 'b');
      const after: string[] = moved as string[];
      expect(after.length).assertEqual(6);
      const others: string[] = [];
      for (let i = 0; i < after.length; i++) {
        if (after[i] !== 'e') {
          others.push(after[i]);
        }
      }
      const expected: string[] = [];
      for (let i = 0; i < before.length; i++) {
        if (before[i] !== 'e') {
          expected.push(before[i]);
        }
      }
      expect(joined(others)).assertEqual(joined(expected));
    });

    it('same_container_rejects_cross_container_submission', 0, () => {
      const a: Todo = mk('a', 'anytime');
      const b: Todo = mk('b', 'someday');
      expect(sameContainer([containerKeyOf(a), containerKeyOf(b)])).assertFalse();
      const c: Todo = mk('c', 'anytime');
      expect(sameContainer([containerKeyOf(a), containerKeyOf(c)])).assertTrue();
      expect(sameContainer([])).assertFalse();
    });

    it('moved_order_reproduces_full_sequence', 0, () => {
      const list: Todo[] = [mk('a', 'inbox'), mk('b', 'inbox'), mk('c', 'inbox')];
      const moved: string[] | null = movedOrder(ids(list), 'c', 'a');
      expect(moved === null).assertFalse();
      // 提交给核心的是**完整序列**,数组下标即新的 order
      expect((moved as string[]).length).assertEqual(3);
      expect(joined(moved as string[])).assertEqual('c,a,b');
    });
  });
}
