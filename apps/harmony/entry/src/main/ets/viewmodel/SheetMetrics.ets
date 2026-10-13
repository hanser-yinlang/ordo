/**
 * Ordo · 浮层尺寸计算(纯逻辑,不依赖 ArkUI,可被宿主机直接执行)
 *
 * 为什么单独抽出来:浮层"允许长多高"取决于**当前窗口高度**,而窗口高度只有视图知道。
 * 一旦在组件里写死 `constraintSize({ maxHeight: 640 })`,在矮屏 / 分屏 / 小窗上内容就会
 * **溢出面板边界**;而 ArkUI 默认**不裁剪**超出父容器的子组件,多出来的行会直接画到面板外面
 * (真机踩坑:设置面板最后两行「切换完成 / 删除」画到了列表底部状态栏上,用户截图反馈
 * 「设置界面底部有严重问题」)。
 *
 * 规则固化成可断言的数字:
 *  1) 面板上限 = 设计上限(§4)与"窗口可用高度"取小;
 *  2) 可用高度必须扣掉**底部状态栏**(列表底部那一行统计文案)与上下留白 ——
 *     面板在窗口里垂直居中,下方留白 = (窗口高 − 面板高)/2,要它 ≥ 状态栏 + 留白,
 *     面板就必须 ≤ 窗口高 − 2×(状态栏 + 留白);
 *  3) 内容比面板高时**在面板内部滚动**(Scroll),绝不允许溢出绘制;
 *  4) 窗口高度还没量到(0/NaN)时退回设计上限,免得首帧画成一个很矮的滚动条。
 */

import { FAB_STATUS_BAR_HEIGHT } from './FabMenu.ets';

/** 浮层与屏幕上下边缘的最小留白(vp) */
export const SHEET_EDGE_MARGIN: number = 16;

/** 浮层最小可用高度(vp):再矮的窗口也给这么高,配合内部滚动 */
export const SHEET_MIN_HEIGHT: number = 240;

/** 内容滚动区的最小高度(vp):保证任何窗口下都还剩能滚的区域 */
export const SHEET_SCROLL_MIN: number = 120;

/** 设置面板的设计上限(vp;04 §4 浮层规范) */
export const SETTINGS_SHEET_DESIGN_MAX: number = 640;

/** 排期面板的设计上限(vp;内容含月历,给得比设置高一些) */
export const SCHEDULE_SHEET_DESIGN_MAX: number = 720;

/**
 * 设置面板「头部 + 上下内边距 + 与内容区的间距」占掉的高度(vp):
 * 头部 44(最小触控目标)+ 内边距 2×24 + 间距 4 = 96。
 */
export const SETTINGS_SHEET_CHROME: number = 96;

/** 排期面板同样的开销(vp):头部 32 + 内边距 2×16 + 间距 8 = 72 */
export const SCHEDULE_SHEET_CHROME: number = 72;

/** 底部状态栏高度(vp):与列表底部那一行统计文案同高(单一事实来源在 FabMenu.ets) */
export const SHEET_BOTTOM_BAR: number = FAB_STATUS_BAR_HEIGHT;

/**
 * 浮层允许的最大高度(vp)。
 * @param windowHeight 当前窗口高度(vp);非正数 / NaN 时退回设计上限
 * @param designMax 该浮层的设计上限
 */
export function sheetMaxHeight(windowHeight: number, designMax: number): number {
  if (!(windowHeight > 0)) {
    return designMax;
  }
  const available: number = windowHeight - (SHEET_BOTTOM_BAR + SHEET_EDGE_MARGIN) * 2;
  return Math.max(SHEET_MIN_HEIGHT, Math.min(designMax, available));
}

/** 内容滚动区上限 = 面板上限 − 面板自身头部/内边距 */
export function sheetScrollMaxHeight(sheetMax: number, chrome: number): number {
  return Math.max(SHEET_SCROLL_MIN, sheetMax - chrome);
}

/** 面板垂直居中时下方的实际留白(vp);用例用它断言"碰不到底部状态栏" */
export function sheetBottomGap(windowHeight: number, sheetHeight: number): number {
  return (windowHeight - sheetHeight) / 2;
}
