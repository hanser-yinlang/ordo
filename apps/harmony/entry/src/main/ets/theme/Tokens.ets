/**
 * Ordo · 设计令牌(Ordo Design System v1)
 * 契约来源:docs/04-UI设计规范.md §2(色彩 / 排版 / 间距圆角阴影动效)、§3(布局)、§4(组件)、§5(动效)
 *
 * 本文件是四端令牌的鸿蒙实现:命名与取值必须与文档一致,深浅两套同时提供。
 * 用法:组件内 `const c: OrdoColorTokens = OrdoColors.of(this.dark);`
 */

/* ------------------------------------------------------------------ 图标 */

/**
 * 图标字形表(04 §5.3 提到 `OrdoIcons.Refresh`)。
 * 鸿蒙端的图标一律走**系统字体里的几何字形**,不引入 svg 资源:
 * 既避免多一套资源打包链路,也保证深浅色下都能用当前文字色渲染(§8 对比度)。
 */
export class OrdoIcons {
  /** 刷新(§5.3 状态栏刷新控件) */
  static readonly refresh: string = '↻';
  /** 成功态对勾 */
  static readonly check: string = '✓';
  /** 失败态感叹号(与危险色同时出现,不单靠颜色表达,§8) */
  static readonly warn: string = '!';
  /** 快加号 */
  static readonly plus: string = '＋';
  /** 展开成 ×(快加号长按后旋转 45°,§5.2) */
  static readonly close: string = '＋';
}

/* ------------------------------------------------------------------ 色彩 */

export interface OrdoColorTokens {
  bgCanvas: string;
  bgSurface: string;
  bgSidebar: string;
  lineHairline: string;
  textPrimary: string;
  textSecondary: string;
  textTertiary: string;
  accentPrimary: string;
  /**
   * 快加号(FAB)专用填充色(§5.2 v1.5:亮蓝 `#0A84FF`)。
   * **独立于 accentPrimary**:品牌靛紫不动,只有这一个圆钮用亮蓝;
   * 光晕也用它(半透明,见 FabMenu.FAB_GLOW_*)。
   */
  fab: string;
  accentTonight: string;
  stateDanger: string;
  stateSuccess: string;
  chipBg: string;
  chipText: string;
  focusRing: string;
  /** 未完成复选框描边(§4:1.6vp #C6C3BA) */
  checkboxBorder: string;
  /** 选中行底色(accent 12% 叠加在 canvas 上的近似实色) */
  rowSelected: string;
  /** 侧栏选中项底色 */
  sideSelected: string;
}

export class OrdoColors {
  private static lightTokens: OrdoColorTokens = {
    bgCanvas: '#FBFAF7',
    bgSurface: '#FFFFFF',
    bgSidebar: '#F4F3EF',
    lineHairline: '#E7E5DF',
    textPrimary: '#1C1B19',
    textSecondary: '#7A776F',
    textTertiary: '#A8A49B',
    accentPrimary: '#5B5BD6',
    // §5.2 v1.5:快加号专用亮蓝(浅色与深色同值);菜单项图标仍走 textSecondary
    fab: '#0A84FF',
    accentTonight: '#D98324',
    stateDanger: '#E5533D',
    stateSuccess: '#2FA36B',
    chipBg: '#EFEDE8',
    chipText: '#6B6860',
    focusRing: 'rgba(91,91,214,0.45)',
    checkboxBorder: '#C6C3BA',
    rowSelected: '#EFEFF9',
    sideSelected: '#E7E6F5'
  };

  private static darkTokens: OrdoColorTokens = {
    bgCanvas: '#141416',
    bgSurface: '#1D1D21',
    bgSidebar: '#191919',
    lineHairline: '#2E2E33',
    textPrimary: '#F2F1EE',
    textSecondary: '#9A968E',
    textTertiary: '#6E6B65',
    accentPrimary: '#7C7CF0',
    fab: '#0A84FF',
    accentTonight: '#E8A13F',
    stateDanger: '#F2705C',
    stateSuccess: '#3FBF83',
    chipBg: '#2A2A2F',
    chipText: '#B9B5AC',
    focusRing: 'rgba(124,124,240,0.5)',
    checkboxBorder: '#5A574F',
    rowSelected: '#25253A',
    sideSelected: '#26263C'
  };

  static of(dark: boolean): OrdoColorTokens {
    return dark ? OrdoColors.darkTokens : OrdoColors.lightTokens;
  }
}

/* ------------------------------------------------------------------ 排版 */

export interface OrdoTextStyle {
  size: number;
  lineHeight: number;
  weight: number;
}

export class OrdoFont {
  /** 清单大标题 28/34 600 */
  static readonly display: OrdoTextStyle = { size: 28, lineHeight: 34, weight: 600 };
  /** 卡片标题、项目名 20/26 600 */
  static readonly title: OrdoTextStyle = { size: 20, lineHeight: 26, weight: 600 };
  /** 待办标题、正文 15/22 400 */
  static readonly body: OrdoTextStyle = { size: 15, lineHeight: 22, weight: 400 };
  /** 元信息、日期、计数 13/18 400 */
  static readonly caption: OrdoTextStyle = { size: 13, lineHeight: 18, weight: 400 };
  /** 标签 chip、分组标题 11/14 500 */
  static readonly micro: OrdoTextStyle = { size: 11, lineHeight: 14, weight: 500 };
  /** 系统字体族(鸿蒙走 HarmonyOS Sans,不内嵌字体文件) */
  static readonly family: string = 'HarmonyOS Sans';
}

/* ------------------------------------------------------------------ 间距 */

export class OrdoSpace {
  static readonly xs: number = 4;
  static readonly s: number = 8;
  static readonly m: number = 12;
  static readonly l: number = 16;
  static readonly xl: number = 24;
  static readonly xxl: number = 32;
}

export class OrdoRadius {
  static readonly row: number = 10;
  static readonly card: number = 14;
  static readonly sheet: number = 14;
  static readonly pill: number = 999;
}

export interface OrdoElevation {
  /** 0 1 2 rgba(0,0,0,.06) + 0 8 24 rgba(0,0,0,.08) */
  cardRadius: number;
  cardColor: string;
  cardOffsetY: number;
  sheetRadius: number;
  sheetColor: string;
  sheetOffsetY: number;
}

export class OrdoShadow {
  static card(): OrdoElevation {
    const e: OrdoElevation = {
      cardRadius: 24,
      cardColor: 'rgba(0,0,0,0.08)',
      cardOffsetY: 8,
      sheetRadius: 40,
      sheetColor: 'rgba(0,0,0,0.18)',
      sheetOffsetY: 12
    };
    return e;
  }
}

/* ------------------------------------------------------------------ 动效 */

export class OrdoMotion {
  /** 120ms */
  static readonly fast: number = 120;
  /** 220ms */
  static readonly base: number = 220;
  /** 320ms */
  static readonly slow: number = 320;
  /** 标准缓动 cubic-bezier(.2,.8,.2,1) → ArkUI Curve.FastOutSlowIn 近似 */
  static readonly easingStandard: string = 'cubic-bezier(0.2, 0.8, 0.2, 1)';

  /** 完成动效时序(契约 04 §5,单位 ms) */
  static readonly pressScale: number = 90;
  static readonly fillAt: number = 80;
  static readonly checkAt: number = 160;
  static readonly checkDuration: number = 120;
  static readonly titleFadeAt: number = 240;
  static readonly rowCollapseAt: number = 700;
  static readonly rowCollapseDuration: number = 180;
  static readonly ringPulseAt: number = 900;

  /** 其它 */
  static readonly checklistExpand: number = 220;
  static readonly sidebarCollapse: number = 260;
  static readonly popIn: number = 180;
  static readonly pageFade: number = 160;

  /* ---------------- §5.1 登录页 ---------------- */
  /** 进入登录页:fade + 上移 12px,220ms */
  static readonly loginEnter: number = 220;
  static readonly loginEnterRise: number = 12;
  /** 输入框聚焦:边框转 accent,120ms */
  static readonly loginFieldFocus: number = 120;
  /** 主按钮按压 scale → 0.98(90ms) */
  static readonly loginPressScale: number = 0.98;
  static readonly loginPress: number = 90;
  /** 登录成功:卡片 fade out 160ms → 主界面 fade in 220ms */
  static readonly loginCardFadeOut: number = 160;
  static readonly mainFadeIn: number = 220;
  /** 错误抖动:振幅 6px,320ms,衰减两次 */
  static readonly errorShake: number = 320;
  static readonly errorShakeAmp: number = 6;
  /** 登录卡片宽 400 / 高 430~480 */
  static readonly loginCardWidth: number = 400;
  static readonly loginCardMinHeight: number = 430;
  /** 主按钮高 44、radius 10;提交中转圈 16 */
  static readonly loginButtonHeight: number = 44;
  static readonly loginSpinner: number = 16;

  /* ---------------- §5.2 快加号集群 ---------------- */
  /** 长按阈值:展开菜单与进入拖拽共用(§5.2 / §5.4) */
  static readonly longPressMs: number = 400;
  /** 按压 scale → 0.96(90ms) */
  static readonly fabPressScale: number = 0.96;
  static readonly fabPress: number = 90;
  /** 长按到 400ms:轻微放大到 1.06 并保持 */
  static readonly fabHoldScale: number = 1.06;
  /** 展开时旋转 45°(「+」变「×」) */
  static readonly fabRotate: number = 45;
  /** 菜单展开:面板 scale 0.9→1 + alpha 0→1,180ms */
  static readonly menuExpand: number = 180;
  static readonly menuCollapse: number = 140;
  static readonly menuFromScale: number = 0.9;
  /** 菜单项逐个错位 40ms 淡入并上移 6px */
  static readonly menuItemStagger: number = 40;
  static readonly menuItemRise: number = 6;

  /* ---------------- §5.3 刷新控件 ---------------- */
  /** 同步中:每圈 900ms,linear,持续到结束 */
  static readonly spinPerTurn: number = 900;
  /** 成功:短暂转 success 色 320ms,1.4s 后回到常态 */
  static readonly refreshSuccessFlash: number = 320;
  static readonly refreshSuccessHold: number = 1400;

  /* ---------------- §5.4 长按拖拽 ---------------- */
  /** 移动 < 6px 视为点击,不进入拖拽 */
  static readonly dragSlop: number = 6;
  /** 进入拖拽:scale 1.02 + 12dp 投影 + 背景转 surface */
  static readonly dragLiftScale: number = 1.02;
  static readonly dragLiftShadow: number = 12;
  /** 拖拽中被拖行 alpha 0.55,其余行让位 120ms */
  static readonly dragAlpha: number = 0.55;
  static readonly dragYield: number = 120;
  /** 松手:行回落 160ms spring */
  static readonly dragDrop: number = 160;
  /** 插入指示线 2dp accent + 左端 4dp 圆点 */
  static readonly dropLine: number = 2;
  static readonly dropDot: number = 4;
}

/* ------------------------------------------------------------------ 尺寸 */

export class OrdoSize {
  /** 侧栏 248vp(04 §3) */
  static readonly sidebarWidth: number = 248;
  /** 待办行高 38(04 §4) */
  static readonly rowHeight: number = 38;
  /** 复选框 20×20 */
  static readonly checkbox: number = 20;
  /** 复选框描边宽 1.6 */
  static readonly checkboxStroke: number = 1.6;
  /** 侧栏项高 34,图标 18 */
  static readonly sideItem: number = 34;
  static readonly sideIcon: number = 18;
  /** 项目进度环 18×18,线宽 2 */
  static readonly progressRing: number = 18;
  static readonly progressRingStroke: number = 2;
  /**
   * 快加号直径。§4 组件表写 52,§5.2(v1.1 重构「去掉多余元素」)写 56。
   * 取**新的、更具体的**那一条:56(同一处还明确「只保留一个圆形按钮」)。
   */
  static readonly quickAdd: number = 56;
  /** 刷新控件:28 圆形图标按钮(04 §5.3) */
  static readonly refreshIcon: number = 28;
  /** 内容区最大宽度 720 */
  static readonly contentMaxWidth: number = 720;
  /** 排期面板宽 280 */
  static readonly sheetWidth: number = 280;
  /** 滑动手势动作区宽度(04 §6:右滑完成 / 左滑删除 + 排期);≥ 44 的最小触控目标 */
  static readonly swipeActionWidth: number = 72;
  /** 快找浮层:输入 44 高,结果行 36 */
  static readonly findInputHeight: number = 44;
  static readonly findRowHeight: number = 36;
  /** 标签 chip 高 20;元信息图标 14 */
  static readonly chipHeight: number = 20;
  static readonly metaIcon: number = 14;
  /** 无障碍最小触控目标 */
  static readonly minTouchTarget: number = 44;
  /** 断点(04 §3) */
  static readonly breakpointWide: number = 1100;
  static readonly breakpointMedium: number = 768;
}

/** 主题模式(设置页三选一) */
export type ThemeMode = 'auto' | 'light' | 'dark';

export class OrdoTheme {
  static readonly STORAGE_KEY: string = 'themeMode';

  static parse(value: string | null): ThemeMode {
    if (value === 'light' || value === 'dark' || value === 'auto') {
      return value;
    }
    return 'auto';
  }

  static next(mode: ThemeMode): ThemeMode {
    if (mode === 'auto') {
      return 'light';
    }
    if (mode === 'light') {
      return 'dark';
    }
    return 'auto';
  }

  static label(mode: ThemeMode): string {
    if (mode === 'light') {
      return '浅色';
    }
    if (mode === 'dark') {
      return '深色';
    }
    return '跟随系统';
  }
}
