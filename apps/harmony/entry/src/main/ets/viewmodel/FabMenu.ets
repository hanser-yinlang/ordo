/**
 * Ordo · 快加号菜单模型(04-UI设计规范 §5.2「快加号集群」v1.3 对齐参照原型)
 *
 * 规范要点(§5.2):
 *  - 菜单**保持 4 项**:新建待办 / 新建项目 / 新建区域 / 新建标题;
 *  - 图标语义四端一致:待办 = ＋、项目 = **H**(两竖 + 中间一横)、
 *    区域 = **圆角方框 + 中心点**、标题 = **三横线(≡)**;
 *  - **「新建标题」只在项目视图出现**(heading 必属 project),其余三项所有视图可用;
 *  - 快捷键提示只有「新建待办」显示 `Ctrl+N`;
 *  - 面板:最小宽 ≥208vp、radius 12、1px hairline、底色 surface;
 *    条目高 ≥44、左内边距 9、图标与文字间距 8、条目 radius 7、按下底 rowSelected。
 *
 * 为什么抽成纯逻辑:图标是**形状枚举**而不是字体字符(上一轮 '→' 因字体回退渲染成了别的形状),
 * 因此"哪个条目用哪个形状、顺序与文案、可用性规则、几何与面板尺寸"都应当是**可断言的数据**,
 * 而不是散在组件里的魔法值。本文件不依赖 ArkUI,可被宿主机直接执行(见 FabMenu.test.ets)。
 */

/** 菜单项图标(形状枚举;绘制在 `view/QuickAddButton.ets` 的 `fabIcon()` 里) */
export type FabIconKind = 'plus' | 'projectH' | 'area' | 'heading';

/** 菜单动作(与 AppStore 的动作一一对应,便于用例钉住"文案 ↔ 动作") */
export type FabActionKind = 'quickAdd' | 'createProject' | 'createArea' | 'createHeading';

/** 一个菜单项 */
export interface FabMenuItemModel {
  icon: FabIconKind;
  label: string;
  action: FabActionKind;
  /** 快捷键提示;空串 = 不显示(§5.2:只有「新建待办」显示 Ctrl+N) */
  shortcut: string;
}

/** 快捷键提示:只有「新建待办」有 */
export const FAB_SHORTCUT_NEW_TODO: string = 'Ctrl+N';

/* ------------------------------------------------------------ 面板与条目尺寸(§5.2) */

/** 面板最小宽 208vp */
export const FAB_PANEL_MIN_WIDTH: number = 208;
/** 面板圆角 12 */
export const FAB_PANEL_RADIUS: number = 12;
/** 条目高 ≥44(与全局最小触控目标一致) */
export const FAB_ITEM_HEIGHT: number = 44;
/** 条目左内边距 9 */
export const FAB_ITEM_PADDING_LEFT: number = 9;
/** 图标与文字间距 8 */
export const FAB_ITEM_ICON_GAP: number = 8;
/** 条目圆角 7 */
export const FAB_ITEM_RADIUS: number = 7;
/** 图标画布 20×20(vp,矢量坐标即按此 viewBox 给出) */
export const FAB_ICON_SIZE: number = 20;

/* ------------------------------------------------------------ 图标几何(20×20 viewBox) */

/**
 * ＋ :横 (4,10)-(16,10) + 竖 (10,4)-(10,16),线宽 2.1,圆头。
 * 比另外三个图标略粗,保证"主操作"在小尺寸下也够醒目。
 */
export const PLUS_STROKE: number = 2.1;
export const PLUS_H_FROM: number[] = [4, 10];
export const PLUS_H_TO: number[] = [16, 10];
export const PLUS_V_FROM: number[] = [10, 4];
export const PLUS_V_TO: number[] = [10, 16];

/** H:两竖 x=5 / x=15(y 4→16)+ 一横 y=10(x 5→15),线宽 1.7,圆头 */
export const PROJECT_STROKE: number = 1.7;
export const PROJECT_LEFT_FROM: number[] = [5, 4];
export const PROJECT_LEFT_TO: number[] = [5, 16];
export const PROJECT_RIGHT_FROM: number[] = [15, 4];
export const PROJECT_RIGHT_TO: number[] = [15, 16];
export const PROJECT_BAR_FROM: number[] = [5, 10];
export const PROJECT_BAR_TO: number[] = [15, 10];

/** 区域:圆角方框 rect(3,3,14,14) rx=4,线宽 1.5 + 中心实心圆 r=2.6 */
export const AREA_STROKE: number = 1.5;
export const AREA_LEFT: number = 3;
export const AREA_TOP: number = 3;
export const AREA_SIZE: number = 14;
export const AREA_RADIUS: number = 4;
export const AREA_DOT_RADIUS: number = 2.6;

/** 标题:三横线 y=5/10/15(x 4.5→15.5),线宽 1.7,圆头 */
export const HEADING_STROKE: number = 1.7;
export const HEADING_LINE_FROM_X: number = 4.5;
export const HEADING_LINE_TO_X: number = 15.5;
export const HEADING_LINE_YS: number[] = [5, 10, 15];

/**
 * 菜单项(§5.2)。
 * @param listKind 当前清单类型(`AppStore.list`);`'project'` 时才追加「新建标题」
 */
export function fabMenuItems(listKind: string): FabMenuItemModel[] {
  const items: FabMenuItemModel[] = [
    { icon: 'plus', label: '新建待办', action: 'quickAdd', shortcut: FAB_SHORTCUT_NEW_TODO },
    { icon: 'projectH', label: '新建项目', action: 'createProject', shortcut: '' },
    { icon: 'area', label: '新建区域', action: 'createArea', shortcut: '' }
  ];
  // §5.2:heading 必属 project —— 非项目视图下这一项不可用(直接不出现)
  if (listKind === 'project') {
    items.push({ icon: 'heading', label: '新建标题', action: 'createHeading', shortcut: '' });
  }
  return items;
}

/** 某一项在当前视图是否可用(供用例钉住规则;实现上等价于"是否出现在 fabMenuItems 里") */
export function fabItemAvailable(action: FabActionKind, listKind: string): boolean {
  if (action === 'createHeading') {
    return listKind === 'project';
  }
  return true;
}
