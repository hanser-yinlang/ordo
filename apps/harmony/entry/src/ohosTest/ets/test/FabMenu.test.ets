/**
 * Ordo · 快加号菜单用例(04-UI规范 §5.2「快加号集群」v1.3 对齐参照原型)
 *
 * 钉住四件事:
 *  1. 菜单项**顺序与文案**(新建待办 / 项目 / 区域 / 标题);
 *  2. **图标 → 形状**映射(＋ / H / 圆角方框+中心点 / ≡ —— 全是矢量形状,不是字体字符);
 *  3. **可用性规则**:「新建标题」只在项目视图出现,其余三项所有视图可用;
 *  4. 面板与条目尺寸(§5.2:面板最小宽 ≥208 / radius 12 / 条目高 ≥44 / 左内边距 9 /
 *     图标间距 8 / 条目 radius 7)与"只有新建待办有快捷键 Ctrl+N"。
 */

import { describe, expect, it } from '@ohos/hypium';
import {
  AREA_DOT_RADIUS,
  AREA_LEFT,
  AREA_RADIUS,
  AREA_SIZE,
  AREA_STROKE,
  AREA_TOP,
  FAB_FILL_HEX,
  FAB_BOTTOM_GAP,
  FAB_MARK_INSET,
  FAB_MARK_SIZE,
  FAB_MARK_STROKE,
  fabMarkSpan,
  FAB_MARGIN_BOTTOM,
  FAB_MARGIN_RIGHT,
  FAB_SIZE,
  FAB_STATUS_BAR_HEIGHT,
  FAB_ICON_SIZE,
  FAB_ITEM_HEIGHT,
  FAB_ITEM_ICON_GAP,
  FAB_ITEM_PADDING_LEFT,
  FAB_ITEM_RADIUS,
  FAB_PANEL_MIN_WIDTH,
  FAB_PANEL_RADIUS,
  FAB_SHORTCUT_NEW_TODO,
  FabActionKind,
  FabMenuItemModel,
  HEADING_LINE_FROM_X,
  HEADING_LINE_TO_X,
  HEADING_LINE_YS,
  HEADING_STROKE,
  PLUS_H_FROM,
  PLUS_H_TO,
  PLUS_STROKE,
  PLUS_V_FROM,
  PLUS_V_TO,
  PROJECT_BAR_FROM,
  PROJECT_BAR_TO,
  PROJECT_LEFT_FROM,
  PROJECT_LEFT_TO,
  PROJECT_RIGHT_FROM,
  PROJECT_RIGHT_TO,
  PROJECT_STROKE,
  fabItemAvailable,
  fabVisible,
  fabMenuItems
} from '../../../main/ets/viewmodel/FabMenu.ets';

/** 非项目视图(其余三项都该在) */
const NON_PROJECT_VIEWS: string[] = ['today', 'inbox', 'upcoming', 'anytime', 'someday', 'logbook', 'area', 'tag', 'search'];

function labelsOf(items: FabMenuItemModel[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < items.length; i++) {
    out.push(items[i].label);
  }
  return out;
}

function actionsOf(items: FabMenuItemModel[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < items.length; i++) {
    out.push(items[i].action);
  }
  return out;
}

export default function fabMenuTest() {
  describe('FabMenu', () => {

    it('project_view_has_four_items_in_order', 0, () => {
      // §5.2:菜单保持 4 项,顺序固定
      const items: FabMenuItemModel[] = fabMenuItems('project');
      expect(items.length).assertEqual(4);
      expect(labelsOf(items).join('|')).assertEqual('新建待办|新建项目|新建区域|新建标题');
      expect(actionsOf(items).join('|')).assertEqual('quickAdd|createProject|createArea|createHeading');
    });

    it('other_views_have_three_items_and_no_heading', 0, () => {
      // §5.2:heading 必属 project → 其余视图只有 3 项
      for (let i = 0; i < NON_PROJECT_VIEWS.length; i++) {
        const items: FabMenuItemModel[] = fabMenuItems(NON_PROJECT_VIEWS[i]);
        expect(items.length).assertEqual(3);
        expect(labelsOf(items).join('|')).assertEqual('新建待办|新建项目|新建区域');
      }
    });

    it('icon_kinds_map_to_the_reference_shapes', 0, () => {
      // §5.2 v1.3:待办 = ＋、项目 = H、区域 = 圆角方框 + 中心点、标题 = ≡
      const items: FabMenuItemModel[] = fabMenuItems('project');
      expect(items[0].icon).assertEqual('plus');
      expect(items[1].icon).assertEqual('projectH');
      expect(items[2].icon).assertEqual('area');
      expect(items[3].icon).assertEqual('heading');
      // 图标是**枚举**,不是字体字符 —— 顺着断言一遍:不能是那三个旧字形
      const icons: string[] = [items[1].icon, items[2].icon, items[3].icon];
      expect(icons.indexOf('◎') < 0).assertTrue();
      expect(icons.indexOf('▣') < 0).assertTrue();
      expect(icons.indexOf('▤') < 0).assertTrue();
    });

    it('only_new_todo_carries_the_shortcut_hint', 0, () => {
      const items: FabMenuItemModel[] = fabMenuItems('project');
      expect(items[0].shortcut).assertEqual('Ctrl+N');
      expect(FAB_SHORTCUT_NEW_TODO).assertEqual('Ctrl+N');
      expect(items[1].shortcut).assertEqual('');
      expect(items[2].shortcut).assertEqual('');
      expect(items[3].shortcut).assertEqual('');
    });

    it('availability_rule_matches_the_view', 0, () => {
      expect(fabItemAvailable('createHeading', 'project')).assertTrue();
      for (let i = 0; i < NON_PROJECT_VIEWS.length; i++) {
        expect(fabItemAvailable('createHeading', NON_PROJECT_VIEWS[i])).assertFalse();
        // 其余三项任何视图都可用
        const actions: FabActionKind[] = ['quickAdd', 'createProject', 'createArea'];
        for (let k = 0; k < actions.length; k++) {
          expect(fabItemAvailable(actions[k], NON_PROJECT_VIEWS[i])).assertTrue();
        }
      }
    });

    it('panel_and_item_metrics_match_the_spec', 0, () => {
      // §5.2:面板最小宽 ≥208、radius 12;条目高 ≥44、左内边距 9、图标间距 8、条目 radius 7
      expect(FAB_PANEL_MIN_WIDTH >= 208).assertTrue();
      expect(FAB_PANEL_RADIUS).assertEqual(12);
      expect(FAB_ITEM_HEIGHT >= 44).assertTrue();
      expect(FAB_ITEM_PADDING_LEFT).assertEqual(9);
      expect(FAB_ITEM_ICON_GAP).assertEqual(8);
      expect(FAB_ITEM_RADIUS).assertEqual(7);
    });

    it('icon_geometry_matches_the_20x20_viewbox', 0, () => {
      // 20×20 viewBox;数值即绘制坐标,组件里直接喂给 Line/Rect/Circle
      expect(FAB_ICON_SIZE).assertEqual(20);

      // ＋:(4,10)-(16,10) + (10,4)-(10,16),stroke 2.1
      expect(PLUS_STROKE).assertEqual(2.1);
      expect(PLUS_H_FROM.join(',')).assertEqual('4,10');
      expect(PLUS_H_TO.join(',')).assertEqual('16,10');
      expect(PLUS_V_FROM.join(',')).assertEqual('10,4');
      expect(PLUS_V_TO.join(',')).assertEqual('10,16');

      // H:两竖 x=5/x=15(y 4→16)+ 一横 y=10(x 5→15),stroke 1.7
      expect(PROJECT_STROKE).assertEqual(1.7);
      expect(PROJECT_LEFT_FROM.join(',')).assertEqual('5,4');
      expect(PROJECT_LEFT_TO.join(',')).assertEqual('5,16');
      expect(PROJECT_RIGHT_FROM.join(',')).assertEqual('15,4');
      expect(PROJECT_RIGHT_TO.join(',')).assertEqual('15,16');
      expect(PROJECT_BAR_FROM.join(',')).assertEqual('5,10');
      expect(PROJECT_BAR_TO.join(',')).assertEqual('15,10');

      // 区域:rect(3,3,14,14) rx=4 stroke 1.5 + 中心圆 r=2.6
      expect(AREA_LEFT).assertEqual(3);
      expect(AREA_TOP).assertEqual(3);
      expect(AREA_SIZE).assertEqual(14);
      expect(AREA_RADIUS).assertEqual(4);
      expect(AREA_STROKE).assertEqual(1.5);
      expect(AREA_DOT_RADIUS).assertEqual(2.6);

      // 标题:三横线 y=5/10/15(x 4.5→15.5),stroke 1.7
      expect(HEADING_STROKE).assertEqual(1.7);
      expect(HEADING_LINE_FROM_X).assertEqual(4.5);
      expect(HEADING_LINE_TO_X).assertEqual(15.5);
      expect(HEADING_LINE_YS.join(',')).assertEqual('5,10,15');
    });

    it('menu_is_rebuilt_when_the_view_changes', 0, () => {
      // 同一个视图枚举反复取都应得到一致结果(纯函数,无隐藏状态)
      const a: FabMenuItemModel[] = fabMenuItems('project');
      const b: FabMenuItemModel[] = fabMenuItems('project');
      expect(labelsOf(a).join('|')).assertEqual(labelsOf(b).join('|'));
      const c: FabMenuItemModel[] = fabMenuItems('today');
      expect(c.length).assertEqual(3);
      expect(a.length).assertEqual(4);
    });

    it('fab_is_bright_blue_not_brand_indigo', 0, () => {
      // §5.2 v1.5:FAB 用专用亮蓝;品牌靛紫(accentPrimary)不动、菜单图标走 textSecondary
      expect(FAB_FILL_HEX).assertEqual('#0A84FF');
      expect(FAB_SIZE).assertEqual(56);
      expect(FAB_FILL_HEX.toUpperCase()).assertEqual(FAB_FILL_HEX);
    });

    it('fab_has_no_glow_at_all', 0, () => {
      // 2026-10-13 用户要求:三端的蓝色圆按钮都**不要柔光**。
      // 柔光常量/函数已从 FabMenu 删除(旧用例随之删除);这里钉住"底边距不再给柔光留位置"。
      // 源码级守卫(不许再出现 FAB_GLOW_* / radialGradient)在 `_qa/selfcheck.py` 里。
      expect(FAB_SIZE).assertEqual(56);
      expect(FAB_MARGIN_BOTTOM).assertEqual(FAB_STATUS_BAR_HEIGHT + FAB_BOTTOM_GAP);
      expect(FAB_MARGIN_BOTTOM).assertEqual(48);
    });

    it('fab_margin_keeps_the_button_off_the_bottom_bar', 0, () => {
      // 位置规则(§5.2 v1.5):底边距 = 底栏高度 + 留白,按钮不压住底部文案
      expect(FAB_STATUS_BAR_HEIGHT).assertEqual(32);
      expect(FAB_BOTTOM_GAP).assertEqual(16);
      expect(FAB_MARGIN_BOTTOM >= FAB_STATUS_BAR_HEIGHT + FAB_BOTTOM_GAP).assertTrue();
      expect(FAB_MARGIN_BOTTOM).assertEqual(FAB_STATUS_BAR_HEIGHT + FAB_BOTTOM_GAP);
      expect(FAB_MARGIN_BOTTOM).assertEqual(48);
      // 右侧留白与页面一致(OrdoSpace.xl = 24)
      expect(FAB_MARGIN_RIGHT).assertEqual(24);
    });

    it('fab_mark_is_short_and_thick_like_the_reference', 0, () => {
      // 2026-10-13 按用户参照图量测:按钮里的「＋」跨度 ≈21% 按钮直径、笔画 ≈5%(短而粗)
      expect(fabMarkSpan()).assertEqual(FAB_MARK_SIZE - FAB_MARK_INSET * 2);
      const spanRatio: number = fabMarkSpan() / FAB_SIZE;
      const strokeRatio: number = FAB_MARK_STROKE / FAB_SIZE;
      expect(spanRatio > 0.19 && spanRatio < 0.24).assertTrue();
      expect(strokeRatio > 0.04 && strokeRatio < 0.06).assertTrue();
      // 必须与菜单里那枚"长而细"的「＋」区分开(菜单跨度 12/20)
      expect(FAB_MARK_SIZE - FAB_MARK_INSET * 2).assertEqual(12);
      expect(FAB_MARK_STROKE > PLUS_STROKE).assertTrue();
    });

    it('fab_hidden_when_any_modal_sheet_is_open', 0, () => {
      // 真机踩坑(用户截图):按钮原先声明在模态浮层之后 → ArkUI 里后声明者在上,
      // 打开设置面板时按钮画在面板上、压住文字。规则:任一浮层打开就不渲染按钮。
      expect(fabVisible(false, false, false)).assertTrue();
      expect(fabVisible(true, false, false)).assertFalse();
      expect(fabVisible(false, true, false)).assertFalse();
      expect(fabVisible(false, false, true)).assertFalse();
      expect(fabVisible(true, true, true)).assertFalse();
    });
  });
}
