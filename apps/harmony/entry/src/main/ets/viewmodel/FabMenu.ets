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

/* ------------------------------------------------------------ 快加号外观与位置(§5.2 v1.5) */

/**
 * FAB 填充色:**亮蓝**(§5.2 v1.5)。
 * 与 `OrdoColorTokens.fab` 同值(那边是给组件用的令牌,这里是给用例钉住的常量);
 * `accentPrimary`(靛紫)保持不变,只有这个圆钮用亮蓝。
 */
export const FAB_FILL_HEX: string = '#0A84FF';

/** 圆钮直径(vp;与 `OrdoSize.quickAdd` 一致) */
export const FAB_SIZE: number = 56;

/*
 * 2026-10-13 用户要求:三端的蓝色圆按钮都**不要柔光**。
 * 原先的柔光常量(FAB_GLOW_THICKNESS / _ALPHA_LIGHT / _ALPHA_DARK / _RENDER_MODE /
 * _INNER_STOP / _OUTER_STOP、fabGlowDiameter / fabGlowInnerColor / fabGlowOuterColor)已全部删除。
 *
 * ⚠ 历史坑(留着,别再踩):ArkUI 的颜色字符串是 `#AARRGGBB`(alpha 在前),
 * 写成 CSS 的 `#RRGGBBAA` 会被解析成完全不同的颜色(当年真机上一圈光晕只剩灰绿)。
 */

/* ------------------------------------------------------------ 悬浮按钮里那枚白色「＋」(2026-10-13 按参照图量测) */

/**
 * 悬浮按钮里的「＋」画布尺寸(vp)。
 *
 * 参照图量测:**跨度 ≈21% 按钮直径、笔画 ≈5%**;56 的按钮 → 跨度 ≈11.8vp、笔画 ≈2.8vp。
 * 画布 26、内缩 7 → 跨度 = 26 − 2×7 = 12vp(21.4%);笔画 2.8(5.0%)。
 * (菜单里那枚「＋」仍是长而细的 12/20 跨度,两者刻意不同 —— 按钮上的要"短而粗"。)
 */
export const FAB_MARK_SIZE: number = 26;
export const FAB_MARK_INSET: number = 7;
export const FAB_MARK_STROKE: number = 2.8;

/** 悬浮按钮里「＋」的跨度(vp)= 画布 − 2×内缩 */
export function fabMarkSpan(): number {
  return FAB_MARK_SIZE - FAB_MARK_INSET * 2;
}

/* ------------------------------------------------------------ 可见性(模态浮层之上不得出现按钮) */

/**
 * 悬浮按钮是否该显示。
 *
 * **硬规则**:设置 / 快找 / 排期 这三个模态浮层打开时,悬浮按钮一律**隐藏**。
 *
 * 真机踩坑(用户截图):ArkUI 的 `Stack` 里**后声明的画在上面**,而按钮原先声明在面板之后 →
 * 打开设置面板时,那颗亮蓝按钮**画在面板之上**,压在「打开详情」等文字上,整个设置页像坏掉了。
 * 只挪顺序也能解决,但"模态之上不该有悬浮按钮"本身就该由状态决定 —— 所以两条一起做:
 * 视图里把按钮挪到浮层**之前**声明,同时用这个函数在浮层打开时**不渲染**它。
 */
export function fabVisible(settingsOpen: boolean, fastFindOpen: boolean, hasScheduleSheet: boolean): boolean {
  return !settingsOpen && !fastFindOpen && !hasScheduleSheet;
}

/* ------------------------------------------------------------ 位置避让(§5.2 v1.5 硬约束) */

/** 状态栏/底栏高度(vp):列表底部那行统计文案的高度上限(与 `ListPage.statusBar()` 的 padding + micro 字号一致) */
export const FAB_STATUS_BAR_HEIGHT: number = 32;
/** 按钮与底栏之间的留白(vp):去掉柔光后由它给间距(与 Windows 的 OrdoSpace.l 一致) */
export const FAB_BOTTOM_GAP: number = 16;
/**
 * FAB 底边距 = **底栏高度 + 留白**(vp)。
 *
 * 规则来自 §5.2 v1.5:按钮不许压住任何文字。去掉柔光后由"留白"代替原先的"光晕厚度 + 空隙":
 * 32(底栏)+ 16(留白)= 48。`pages/Index.ets` 用这个常量摆放,别写死数字。
 */
export const FAB_MARGIN_BOTTOM: number = FAB_STATUS_BAR_HEIGHT + FAB_BOTTOM_GAP;

/** FAB 右边距(vp;= `OrdoSpace.xl`,与页面其它右侧留白一致) */
export const FAB_MARGIN_RIGHT: number = 24;
