/**
 * Ordo · 设计令牌(Ordo Design System v1)
 * 契约来源:docs/04-UI设计规范.md §2(色彩 / 排版 / 间距圆角阴影动效)、§3(布局)、§4(组件)、§5(动效)
 *
 * 本文件是四端令牌的鸿蒙实现:命名与取值必须与文档一致,深浅两套同时提供。
 * 用法:组件内 `const c: OrdoColorTokens = OrdoColors.of(this.dark);`
 */

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
  /** 快加号直径 52 */
  static readonly quickAdd: number = 52;
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
