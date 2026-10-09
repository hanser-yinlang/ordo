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
    val fabSize: Dp = 52.dp
    val touchTarget: Dp = 44.dp
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
