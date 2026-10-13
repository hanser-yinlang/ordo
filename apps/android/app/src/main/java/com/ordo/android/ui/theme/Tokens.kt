package com.ordo.android.ui.theme

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/* ============================================================================
 * Ordo Design System v1 —— 设计令牌
 * 来源：ordo/docs/04-UI设计规范.md §2（FROZEN v1 · ordo-ds@1.0.0）
 * 命名与值必须四端一致；此处为 Android 端实现。
 * ========================================================================== */

/**
 * UI §5.2 v1.5 快加号（FAB）专属令牌：**亮蓝填充 + 同色柔光**。
 *
 * 柔光用**径向渐变**画（不是彩色阴影）：Windows(Compose Desktop/Skia) 实测彩色阴影不渲染，
 * 两端统一用渐变，视觉才一致。
 */
object OrdoFabTokens {
    /** FAB 填充色（浅/深色主题同一色值） */
    val fill = Color(0xFF0A84FF)

    /** 柔光透明度：浅色 35% / 深色 45% */
    const val GLOW_ALPHA_LIGHT = 0.35f
    const val GLOW_ALPHA_DARK = 0.45f

    /** 柔光颜色（填充色 + 主题对应透明度） */
    val glowLight = fill.copy(alpha = GLOW_ALPHA_LIGHT)
    val glowDark = fill.copy(alpha = GLOW_ALPHA_DARK)

    /** 柔光厚度（向外扩散的宽度，dp） */
    const val GLOW_THICKNESS_DP = 24

    /** App 自己状态栏（StatusBar composable）的实测高度（dp）：它用 touchTarget = 44 */
    const val STATUS_BAR_DP = 44

    /** 窗口坐标下的 FAB 底边距 = 状态栏高度 + 柔光厚度（按钮连同柔光整体浮在状态栏之上） */
    const val BOTTOM_INSET_DP = STATUS_BAR_DP + GLOW_THICKNESS_DP
}

/** §2.1 色彩 */
@Immutable
data class OrdoColors(
    val canvas: Color,
    val surface: Color,
    val sidebar: Color,
    val hairline: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val accent: Color,
    val accentSoft: Color,
    val onAccent: Color,
    val tonight: Color,
    val danger: Color,
    val success: Color,
    val chipBg: Color,
    val chipText: Color,
    val focusRing: Color,
    val checkboxStroke: Color,
    val hover: Color,
    val selected: Color,
    val scrim: Color,
    /** UI §5.2 v1.5：快加号填充（亮蓝，浅/深色同一色值） */
    val fab: Color,
    /** UI §5.2 v1.5：快加号柔光（同色半透明，浅色 35% / 深色 45%） */
    val fabGlow: Color,
    val isDark: Boolean,
)

val OrdoLightColors = OrdoColors(
    canvas = Color(0xFFFBFAF7),
    surface = Color(0xFFFFFFFF),
    sidebar = Color(0xFFF4F3EF),
    hairline = Color(0xFFE7E5DF),
    textPrimary = Color(0xFF1C1B19),
    textSecondary = Color(0xFF7A776F),
    textTertiary = Color(0xFFA8A49B),
    accent = Color(0xFF5B5BD6),
    accentSoft = Color(0x1F5B5BD6), // 12% 底（侧栏选中态）
    onAccent = Color(0xFFFFFFFF),
    tonight = Color(0xFFD98324),
    danger = Color(0xFFE5533D),
    success = Color(0xFF2FA36B),
    chipBg = Color(0xFFEFEDE8),
    chipText = Color(0xFF6B6860),
    focusRing = Color(0x735B5BD6), // rgba(91,91,214,.45)
    checkboxStroke = Color(0xFFC6C3BA),
    hover = Color(0x0A000000),
    selected = Color(0x1F5B5BD6),
    scrim = Color(0x52000000),
    fab = OrdoFabTokens.fill,
    fabGlow = OrdoFabTokens.glowLight,
    isDark = false,
)

val OrdoDarkColors = OrdoColors(
    canvas = Color(0xFF141416),
    surface = Color(0xFF1D1D21),
    sidebar = Color(0xFF191919),
    hairline = Color(0xFF2E2E33),
    textPrimary = Color(0xFFF2F1EE),
    textSecondary = Color(0xFF9A968E),
    textTertiary = Color(0xFF6E6B65),
    accent = Color(0xFF7C7CF0),
    accentSoft = Color(0x2E7C7CF0),
    onAccent = Color(0xFF101014),
    tonight = Color(0xFFE8A13F),
    danger = Color(0xFFF2705C),
    success = Color(0xFF3FBF83),
    chipBg = Color(0xFF2A2A2F),
    chipText = Color(0xFFB9B5AC),
    focusRing = Color(0x807C7CF0), // rgba(124,124,240,.5)
    checkboxStroke = Color(0xFF5A5751),
    hover = Color(0x14FFFFFF),
    selected = Color(0x2E7C7CF0),
    scrim = Color(0x8C000000),
    fab = OrdoFabTokens.fill,
    fabGlow = OrdoFabTokens.glowDark,
    isDark = true,
)

/** §2.2 排版（系统字体，不内嵌字体文件） */
@Immutable
data class OrdoTypography(
    val display: TextStyle = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 28.sp,
        lineHeight = 34.sp,
    ),
    val title: TextStyle = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 20.sp,
        lineHeight = 26.sp,
    ),
    val body: TextStyle = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 15.sp,
        lineHeight = 22.sp,
    ),
    val caption: TextStyle = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 13.sp,
        lineHeight = 18.sp,
    ),
    val micro: TextStyle = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 14.sp,
        letterSpacing = 0.4.sp,
    ),
)

/** §2.3 间距 */
object OrdoSpace {
    val xs: Dp = 4.dp
    val s: Dp = 8.dp
    val m: Dp = 12.dp
    val l: Dp = 16.dp
    val xl: Dp = 24.dp
    val xxl: Dp = 32.dp
}

/** §2.3 圆角 */
object OrdoRadius {
    val row: Dp = 10.dp
    val card: Dp = 14.dp
    val sheet: Dp = 14.dp
    val pill: Dp = 999.dp
}

/** §3 布局尺寸与断点 */
object OrdoLayout {
    val sidebarWidth: Dp = 248.dp
    val sidebarRailWidth: Dp = 64.dp
    val rowHeight: Dp = 38.dp
    val rowMinHeight: Dp = 38.dp
    val checkboxSize: Dp = 20.dp
    val contentMaxWidth: Dp = 720.dp
    val sheetWidth: Dp = 280.dp
    /** 快加号（UI §5.2：只保留一个圆形按钮，直径 56） */
    val fabSize: Dp = 56.dp
    /** 长按弹出的快捷菜单宽度（UI §5.2 v1.3：面板**最小宽 ≥208**；与 ui/quickadd/QuickAddMenuRules.PANEL_MIN_WIDTH_DP 一致） */
    val quickAddMenuWidth: Dp = 208.dp
    /** 表单输入框（UI §5.1：浮动标签需要两行高度） */
    val fieldHeight: Dp = 52.dp
    val fieldHeightCompact: Dp = 44.dp
    /** 按钮高度（UI §5.1：高 44；v1.3 起登录页已移除，令牌保留供后续表单页复用） */
    val buttonHeight: Dp = 44.dp
    val touchTarget: Dp = 44.dp
    /**
     * UI §5.2 v1.5：快加号柔光厚度（向外扩散 24dp）。
     *
     * 柔光**不参与布局**（用 `requiredSize` 溢出按钮边界），因此这里是"视觉厚度"，
     * 只在计算 [fabBottomInset] 与 [fabContentInset] 时进入布局。
     */
    val fabGlow: Dp = OrdoFabTokens.GLOW_THICKNESS_DP.dp
    /** App 自己状态栏（`StatusBar` composable）的高度：它用 [touchTarget] = 44dp */
    val statusBar: Dp = OrdoFabTokens.STATUS_BAR_DP.dp
    /** 窗口坐标下的 FAB 底边距 = 状态栏高度 + 柔光厚度（按钮连同柔光整体浮在状态栏之上） */
    val fabBottomInset: Dp = OrdoFabTokens.BOTTOM_INSET_DP.dp
    /**
     * 内容区内的**局部**底边距。
     *
     * Android 的 FAB 落在内容区（`Column` 里 `Box(weight=1f)`）内，而 App 状态栏是它的**下一个**兄弟节点，
     * 因此"内容区底边"本身就是状态栏顶边 —— 窗口坐标下的 `statusBar + fabGlow` 落到这里只剩 `fabGlow`。
     * （若把 FAB 提到窗口层，宽屏详情栏会让它压到详情列上，因此保持挂在内容区。）
     */
    val fabContentInset: Dp = fabGlow
    val projectRingSize: Dp = 18.dp
    val sidebarIconSize: Dp = 18.dp
    val metaIconSize: Dp = 14.dp

    /** 断点（dp）：≥1100 三栏常驻；768–1099 侧栏可收起；<768 抽屉 + 全屏详情 */
    const val BREAKPOINT_WIDE = 1100
    const val BREAKPOINT_MEDIUM = 768
}

/** §2.3 / §5 动效 */
object OrdoMotion {
    const val FAST = 120
    const val BASE = 220
    const val SLOW = 320

    /** §5 完成动效时序（ms，±40ms 容差） */
    const val PRESS = 90
    const val FILL = 80
    const val CHECK = 160
    const val GRAY = 240
    const val COLLAPSE_START = 700
    const val COLLAPSE_DURATION = 180
    const val RING_PULSE = 900

    /** §5.3 刷新控件：同步中图标每圈 900ms（linear）；成功色闪现 320ms */
    const val SPINNER_PERIOD = 900
    const val SUCCESS_FLASH = 320

    /** §5.2 快加号菜单：面板 180ms、菜单项逐个错位 40ms、收起 140ms */
    const val MENU_POP_IN = 180
    const val MENU_ITEM_STAGGER = 40
    const val MENU_COLLAPSE = 140
    /** §5.2 长按到 400ms 时轻微放大并保持 */
    const val FAB_HOLD_SCALE = 1.06f

    /** §5.4 长按拖拽：进入拖拽 400ms、其余行让位 120ms、行回落 160ms */
    const val DRAG_LONG_PRESS = 400
    const val DRAG_SHIFT = 120
    const val DRAG_SETTLE = 160

    const val COLLAPSE_TOTAL = 900
    const val SHEET_COLLAPSE = 260
    const val POP_IN = 180
    const val PAGE_FADE = 160
    const val TOAST_DURATION = 2400

    val easing: Easing = CubicBezierEasing(0.2f, 0.8f, 0.2f, 1f)
}

/** §2.3 阴影（Compose 用 elevation 近似，视觉一致） */
object OrdoElevation {
    val card: Dp = 2.dp
    val sheet: Dp = 12.dp
    val fab: Dp = 12.dp
    val popover: Dp = 8.dp
}

/** 全大写分组标题的字距（§2.2 micro） */
val UpperCaseTracking: TextUnit = 0.4.sp
