/**
 * Ordo · 长按手势与拖拽用例(`viewmodel/PressGesture.ets`)
 *
 * 规范来源:docs/04-UI设计规范.md §5.2(快加号长按 400ms 展开菜单)、§5.4(长按拖拽)。
 * 校验点:
 *  1. 阈值就是 400ms:399ms 不算、400ms 算;
 *  2. 位移 <6px 视为点击,不进入拖拽;≥6px 且未到 400ms 直接取消长按资格;
 *  3. 长按后未移动就松手 → 仍按点击处理(§5.4 原文);
 *  4. 长按后移动 ≥6px → 进入拖拽,松手提交;
 *  5. 取消(返回键/拖回原位)→ 不提交;
 *  6. 落点下标换算与夹边;位置未变则不写库(返回 null)。
 */

import { describe, expect, it } from '@ohos/hypium';
import {
  LONG_PRESS_MS,
  MOVE_SLOP,
  PressTracker,
  dragTargetIndex,
  moveIdToIndex
} from '../../../main/ets/viewmodel/PressGesture.ets';

function joined(ids: string[] | null): string {
  return ids === null ? 'null' : ids.join(',');
}

export default function pressGestureTest() {
  describe('PressGesture', () => {

    it('thresholds_match_the_spec', 0, () => {
      // 规范写死的两个数字:400ms / 6px
      expect(LONG_PRESS_MS).assertEqual(400);
      expect(MOVE_SLOP).assertEqual(6);
    });

    it('long_press_fires_exactly_at_400ms', 0, () => {
      const t: PressTracker = new PressTracker();
      t.begin(10, 10, 1000);
      // 399ms:还没到
      expect(t.hold(1000 + 399)).assertFalse();
      expect(t.getPhase()).assertEqual('pressing');
      // 400ms:到点
      expect(t.hold(1000 + 400)).assertTrue();
      expect(t.getPhase()).assertEqual('armed');
      expect(t.longPressFired()).assertTrue();
    });

    it('movement_under_slop_still_allows_long_press', 0, () => {
      const t: PressTracker = new PressTracker();
      t.begin(0, 0, 0);
      t.move(5.9, 0);
      expect(t.getPhase()).assertEqual('pressing');
      expect(t.hold(400)).assertTrue();
    });

    it('movement_at_or_over_slop_cancels_before_long_press', 0, () => {
      const t: PressTracker = new PressTracker();
      t.begin(0, 0, 0);
      t.move(6, 0);
      // 位移到 6px 且还没到 400ms → 交还给点击/滚动,不再算长按
      expect(t.getPhase()).assertEqual('cancelled');
      expect(t.hold(400)).assertFalse();
      expect(t.longPressFired()).assertFalse();
    });

    it('release_before_400ms_is_a_plain_tap', 0, () => {
      const t: PressTracker = new PressTracker();
      t.begin(0, 0, 0);
      t.move(2, 3);
      expect(t.end()).assertEqual('tap');
      expect(t.getPhase()).assertEqual('idle');
    });

    it('long_press_without_movement_is_still_a_tap', 0, () => {
      // §5.4:移动 <6px 视为点击,不进入拖拽 —— 长按后没拖动,同样不该写库
      const t: PressTracker = new PressTracker();
      t.begin(0, 0, 0);
      t.hold(400);
      expect(t.end()).assertEqual('tap');
    });

    it('long_press_then_move_enters_drag_and_commits', 0, () => {
      const t: PressTracker = new PressTracker();
      t.begin(30, 100, 0);
      t.hold(400);
      expect(t.getPhase()).assertEqual('armed');
      t.move(30, 106);
      expect(t.getPhase()).assertEqual('dragging');
      expect(t.isDragging()).assertTrue();
      expect(t.dy()).assertEqual(6);
      expect(t.end()).assertEqual('dragCommit');
    });

    it('cancel_never_commits', 0, () => {
      const t: PressTracker = new PressTracker();
      t.begin(0, 0, 0);
      t.hold(400);
      t.move(0, 40);
      expect(t.isDragging()).assertTrue();
      // 返回键 / 拖出窗口:行回原位,不写库
      expect(t.cancel()).assertEqual('dragCancel');
      expect(t.getPhase()).assertEqual('idle');
    });

    it('long_press_flag_is_consumed_once', 0, () => {
      // 快加号用它抑制随后的 onClick:长按已开菜单,松手不该再打开输入行
      const t: PressTracker = new PressTracker();
      t.begin(0, 0, 0);
      t.hold(400);
      expect(t.consumeLongPress()).assertTrue();
      expect(t.consumeLongPress()).assertFalse();
    });

    it('drag_target_index_uses_row_extent_and_clamps', 0, () => {
      // 未过半行不换位
      expect(dragTargetIndex(2, 0, 40, 6)).assertEqual(2);
      expect(dragTargetIndex(2, 19, 40, 6)).assertEqual(2);
      // 过半行换一位(四舍五入)
      expect(dragTargetIndex(2, 20, 40, 6)).assertEqual(3);
      expect(dragTargetIndex(2, -20, 40, 6)).assertEqual(1);
      // 夹边
      expect(dragTargetIndex(0, -500, 40, 6)).assertEqual(0);
      expect(dragTargetIndex(5, 500, 40, 6)).assertEqual(5);
      // 行跨度为 0(异常输入)不能除零
      expect(dragTargetIndex(1, 100, 0, 3)).assertEqual(2);
      expect(dragTargetIndex(0, 0, 40, 0)).assertEqual(0);
    });

    it('move_id_to_index_reorders_the_full_sequence', 0, () => {
      expect(joined(moveIdToIndex(['a', 'b', 'c'], 'a', 2))).assertEqual('b,c,a');
      expect(joined(moveIdToIndex(['a', 'b', 'c'], 'c', 0))).assertEqual('c,a,b');
      expect(joined(moveIdToIndex(['a', 'b', 'c', 'd'], 'b', 2))).assertEqual('a,c,b,d');
      // 越界下标要夹住,而不是丢数据
      expect(joined(moveIdToIndex(['a', 'b', 'c'], 'a', 99))).assertEqual('b,c,a');
    });

    it('no_write_when_position_did_not_change', 0, () => {
      // §5.4「位置未变则不写库」
      expect(moveIdToIndex(['a', 'b', 'c'], 'a', 0) === null).assertTrue();
      expect(moveIdToIndex(['a', 'b', 'c'], 'b', 1) === null).assertTrue();
      // id 不在序列里(例如已经被删掉)→ 也不写库
      expect(moveIdToIndex(['a', 'b', 'c'], 'zz', 1) === null).assertTrue();
    });
  });
}
