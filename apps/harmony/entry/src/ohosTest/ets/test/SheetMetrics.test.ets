/**
 * Ordo · 浮层尺寸用例(04 §4 浮层规范)
 *
 * 背景:真机上设置面板最后两行「切换完成 / 删除」画到了列表底部状态栏上(用户截图反馈
 * 「设置界面底部有严重问题」)。根因是面板写死 `maxHeight: 640`,而内容约 900+vp、
 * ArkUI 默认又不裁剪 —— 溢出的部分就画到面板外面去了。
 *
 * 这组用例钉住 `viewmodel/SheetMetrics.ets` 的算术:
 *  1. **任何窗口高度下面板都不碰底部状态栏**(面板垂直居中 → 下留白 ≥ 状态栏 + 边距);
 *  2. 设计上限在窗口够高时生效,窗口未知时退回设计上限;
 *  3. 内容滚动区 = 面板上限 − 头部/内边距,且永远留得下能滚的区域;
 *  4. 面板底栏高度与列表底部状态栏**同源**(FabMenu.FAB_STATUS_BAR_HEIGHT),防止两处漂移。
 */

import { describe, expect, it } from '@ohos/hypium';
import { FAB_STATUS_BAR_HEIGHT } from '../../../main/ets/viewmodel/FabMenu.ets';
import {
  SCHEDULE_SHEET_CHROME,
  SCHEDULE_SHEET_DESIGN_MAX,
  SETTINGS_SHEET_CHROME,
  SETTINGS_SHEET_DESIGN_MAX,
  SHEET_BOTTOM_BAR,
  SHEET_EDGE_MARGIN,
  SHEET_MIN_HEIGHT,
  SHEET_SCROLL_MIN,
  sheetBottomGap,
  sheetMaxHeight,
  sheetScrollMaxHeight
} from '../../../main/ets/viewmodel/SheetMetrics.ets';

/** 常见窗口高度:含矮屏 / 分屏 / 平板,以及最紧的 336(刚好等于 240 面板 + 2×48 留白) */
const WINDOW_HEIGHTS: number[] = [336, 400, 500, 600, 745, 800, 900, 1280];

/** 面板下沿到窗口底边的留白是否让开了底部状态栏 */
function gapCoversBottomBar(windowHeight: number, designMax: number): boolean {
  const sheet: number = sheetMaxHeight(windowHeight, designMax);
  return sheetBottomGap(windowHeight, sheet) >= SHEET_BOTTOM_BAR + SHEET_EDGE_MARGIN;
}

export default function registerSheetMetricsTests(): void {
  describe('SheetMetrics', () => {
    it('settings_sheet_never_covers_the_bottom_status_bar', 0, () => {
      for (let i = 0; i < WINDOW_HEIGHTS.length; i++) {
        const h: number = WINDOW_HEIGHTS[i];
        expect(gapCoversBottomBar(h, SETTINGS_SHEET_DESIGN_MAX)).assertTrue();
        expect(sheetMaxHeight(h, SETTINGS_SHEET_DESIGN_MAX) <= SETTINGS_SHEET_DESIGN_MAX).assertTrue();
      }
    });

    it('schedule_sheet_never_covers_the_bottom_status_bar', 0, () => {
      for (let i = 0; i < WINDOW_HEIGHTS.length; i++) {
        const h: number = WINDOW_HEIGHTS[i];
        expect(gapCoversBottomBar(h, SCHEDULE_SHEET_DESIGN_MAX)).assertTrue();
        expect(sheetMaxHeight(h, SCHEDULE_SHEET_DESIGN_MAX) <= SCHEDULE_SHEET_DESIGN_MAX).assertTrue();
      }
    });

    it('design_cap_applies_when_the_window_is_tall_enough', 0, () => {
      // 1280 高的窗口:上限就是设计值,不会被放大
      expect(sheetMaxHeight(1280, SETTINGS_SHEET_DESIGN_MAX)).assertEqual(SETTINGS_SHEET_DESIGN_MAX);
      expect(sheetMaxHeight(10000, SETTINGS_SHEET_DESIGN_MAX)).assertEqual(SETTINGS_SHEET_DESIGN_MAX);
      expect(sheetMaxHeight(10000, SCHEDULE_SHEET_DESIGN_MAX)).assertEqual(SCHEDULE_SHEET_DESIGN_MAX);
      // 745(模拟器实测窗口高):设置面板仍取设计上限 640,且下留白 52.5 > 48
      expect(sheetMaxHeight(745, SETTINGS_SHEET_DESIGN_MAX)).assertEqual(SETTINGS_SHEET_DESIGN_MAX);
      expect(sheetMaxHeight(745, SCHEDULE_SHEET_DESIGN_MAX)).assertEqual(745 - (SHEET_BOTTOM_BAR + SHEET_EDGE_MARGIN) * 2);
    });

    it('unknown_window_height_falls_back_to_the_design_cap', 0, () => {
      expect(sheetMaxHeight(0, SETTINGS_SHEET_DESIGN_MAX)).assertEqual(SETTINGS_SHEET_DESIGN_MAX);
      expect(sheetMaxHeight(-1, SETTINGS_SHEET_DESIGN_MAX)).assertEqual(SETTINGS_SHEET_DESIGN_MAX);
      expect(sheetMaxHeight(Number.NaN, SETTINGS_SHEET_DESIGN_MAX)).assertEqual(SETTINGS_SHEET_DESIGN_MAX);
    });

    it('extremely_short_window_keeps_a_usable_minimum', 0, () => {
      // 退化情形:窗口比「最小面板 + 两侧留白」还矮(极小窗 / 分屏拖动中),
      // 此时以"还能滚"为先 —— 面板保持 240,承认盖住底栏,不做更矮的不可用面板。
      expect(sheetMaxHeight(200, SETTINGS_SHEET_DESIGN_MAX)).assertEqual(SHEET_MIN_HEIGHT);
      expect(sheetMaxHeight(SHEET_MIN_HEIGHT + 2 * (SHEET_BOTTOM_BAR + SHEET_EDGE_MARGIN) - 1, SETTINGS_SHEET_DESIGN_MAX))
        .assertEqual(SHEET_MIN_HEIGHT);
      // 恰好够的临界高度必须让开底栏(边界不多不少)
      const critical: number = SHEET_MIN_HEIGHT + 2 * (SHEET_BOTTOM_BAR + SHEET_EDGE_MARGIN);
      expect(gapCoversBottomBar(critical, SETTINGS_SHEET_DESIGN_MAX)).assertTrue();
      expect(sheetMaxHeight(critical, SETTINGS_SHEET_DESIGN_MAX)).assertEqual(SHEET_MIN_HEIGHT);
    });

    it('content_scroll_area_stays_inside_the_panel', 0, () => {
      expect(sheetScrollMaxHeight(SETTINGS_SHEET_DESIGN_MAX, SETTINGS_SHEET_CHROME))
        .assertEqual(SETTINGS_SHEET_DESIGN_MAX - SETTINGS_SHEET_CHROME);
      expect(sheetScrollMaxHeight(SCHEDULE_SHEET_DESIGN_MAX, SCHEDULE_SHEET_CHROME))
        .assertEqual(SCHEDULE_SHEET_DESIGN_MAX - SCHEDULE_SHEET_CHROME);
      // 面板再矮也留得下滚动区
      expect(sheetScrollMaxHeight(100, SETTINGS_SHEET_CHROME)).assertEqual(SHEET_SCROLL_MIN);
      expect(sheetScrollMaxHeight(SHEET_MIN_HEIGHT, SCHEDULE_SHEET_CHROME) >= SHEET_SCROLL_MIN).assertTrue();
      // 滚动区一定小于面板本身(否则"滚动"没意义)
      expect(sheetScrollMaxHeight(SETTINGS_SHEET_DESIGN_MAX, SETTINGS_SHEET_CHROME) < SETTINGS_SHEET_DESIGN_MAX)
        .assertTrue();
    });

    it('bottom_bar_height_is_shared_with_the_list_footer', 0, () => {
      expect(SHEET_BOTTOM_BAR).assertEqual(FAB_STATUS_BAR_HEIGHT);
      expect(SHEET_BOTTOM_BAR).assertEqual(32);
      expect(SHEET_EDGE_MARGIN > 0).assertTrue();
      expect(SHEET_SCROLL_MIN > 0 && SHEET_SCROLL_MIN < SHEET_MIN_HEIGHT).assertTrue();
    });

    it('bottom_gap_is_symmetric_for_a_centered_sheet', 0, () => {
      expect(sheetBottomGap(800, 400)).assertEqual(200);
      expect(sheetBottomGap(800, 640)).assertEqual(80);
    });
  });
}
