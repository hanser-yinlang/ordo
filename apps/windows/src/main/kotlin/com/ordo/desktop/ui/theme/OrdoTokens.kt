package com.ordo.desktop.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Ordo 设计令牌(04-UI设计规范 §2 / §3 / §5)。
 *
 * 命名与取值与文档逐条对齐;四端同一套命名,Windows 端实现于此。
 * 字体栈:Windows 走系统字体 `Segoe UI Variable`,不内嵌字体文件。
 */

// ---------------------------------------------------------------- 色彩

/** 一套完整配色(浅色或深色)。字段名对应设计令牌名。 */
@Immutable
data class OrdoPalette(
    val canvas: Color,
    val surface: Color,
    val sidebar: Color,
    val hairline: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val accent: Color,
    val accentSoft: Color,
    /** 快加号悬浮按钮的填充色(用户指定对齐参照原型:亮蓝 #0A84FF;改回品牌靛紫只需改这一处) */
    val fab: Color,
    /** 悬浮按钮的光晕(参照原型那颗按钮四周的柔光) */
    val fabGlow: Color,
    val tonight: Color,
    val danger: Color,
    val success: Color,
    val chipBg: Color,
    val chipText: Color,
    val focusRing: Color,
    val hover: Color,
    val selected: Color,
    val checkboxStroke: Color
)

val OrdoLightPalette = OrdoPalette(
    canvas = Color(0xFFFBFAF7),
    surface = Color(0xFFFFFFFF),
    sidebar = Color(0xFFF4F3EF),
    hairline = Color(0xFFE7E5DF),
    textPrimary = Color(0xFF1C1B19),
    textSecondary = Color(0xFF7A776F),
    textTertiary = Color(0xFFA8A49B),
    accent = Color(0xFF5B5BD6),
    accentSoft = Color(0x1F5B5BD6),
    fab = Color(0xFF0A84FF),
    fabGlow = Color(0x590A84FF),
    tonight = Color(0xFFD98324),
    danger = Color(0xFFE5533D),
    success = Color(0xFF2FA36B),
    chipBg = Color(0xFFEFEDE8),
    chipText = Color(0xFF6B6860),
    focusRing = Color(0x735B5BD6),
    hover = Color(0x0A1C1B19),
    selected = Color(0x1F5B5BD6),
    checkboxStroke = Color(0xFFC6C3BA)
)

val OrdoDarkPalette = OrdoPalette(
    canvas = Color(0xFF141416),
    surface = Color(0xFF1D1D21),
    sidebar = Color(0xFF191919),
    hairline = Color(0xFF2E2E33),
    textPrimary = Color(0xFFF2F1EE),
    textSecondary = Color(0xFF9A968E),
    textTertiary = Color(0xFF6E6B65),
    accent = Color(0xFF7C7CF0),
    accentSoft = Color(0x3D7C7CF0),
    fab = Color(0xFF0A84FF),
    fabGlow = Color(0x730A84FF),
    tonight = Color(0xFFE8A13F),
    danger = Color(0xFFF2705C),
    success = Color(0xFF3FBF83),
    chipBg = Color(0xFF2A2A2F),
    chipText = Color(0xFFB9B5AC),
    focusRing = Color(0x807C7CF0),
    hover = Color(0x14FFFFFF),
    selected = Color(0x3D7C7CF0),
    checkboxStroke = Color(0xFF5A574F)
)

// ---------------------------------------------------------------- 间距 / 圆角 / 动效

object OrdoSpace {
    val xs: Dp = 4.dp
    val s: Dp = 8.dp
    val m: Dp = 12.dp
    val l: Dp = 16.dp
    val xl: Dp = 24.dp
    val xxl: Dp = 32.dp

    /** 侧栏宽度(§3:248px) */
    val sidebarWidth: Dp = 248.dp

    /** 内容区最大宽度(§3:720) */
    val contentMaxWidth: Dp = 720.dp

    /** 排期面板宽度(§4:280) */
    val scheduleWidth: Dp = 280.dp

    /** 快找浮层宽度(§4) */
    val fastFindWidth: Dp = 560.dp
}

object OrdoRadius {
    val row: Dp = 10.dp
    val card: Dp = 14.dp
    val sheet: Dp = 14.dp
    val pill: Dp = 999.dp
    val checkbox: Dp = 999.dp
}

object OrdoMotion {
    const val FAST = 120
    const val BASE = 220
    const val SLOW = 320

    /** §5:完成一行待办的完整时序 */
    const val COMPLETE_PRESS = 90
    const val COMPLETE_FILL = 80
    const val COMPLETE_TICK = 120
    const val COMPLETE_TEXT = 240
    const val COMPLETE_REMOVE = 700
}

/** 行高与组件尺寸(§4) */
object OrdoSize {
    val rowHeight: Dp = 38.dp
    val checkbox: Dp = 20.dp
    val checkboxStroke: Dp = 1.6.dp
    val sidebarItem: Dp = 34.dp

    /** 快加号直径(04-UI规范 §5.2:只保留一个 56dp 的蓝色「+」) */
    val fab: Dp = 56.dp

    /** 快加号光晕的**厚度**(从按钮边缘向外渐隐;参照原型的量测值 ≈ 按钮半径) */
    val fabGlow: Dp = 24.dp

    /**
     * 底部状态栏高度:1px 上边线 + 上下各 8dp 内边距 + 18sp 行高 ≈ 34dp(量自离屏渲染)。
     *
     * 悬浮按钮要**整体(含光晕)浮在它上面** —— 否则按钮和光晕会压住状态栏里的文案
     * (用户实测截图:光晕洗到右下角「本地」上)。
     */
    val statusBar: Dp = 34.dp
    val iconSm: Dp = 14.dp
    val icon: Dp = 18.dp
    val touchTarget: Dp = 32.dp
    val chip: Dp = 20.dp
    val scheduleWidth: Dp = 280.dp
}

// ---------------------------------------------------------------- 排版

object OrdoType {
    /** Windows 系统字体栈(§2.2) */
    val family: FontFamily = FontFamily.SansSerif

    val display = TextStyle(fontFamily = family, fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.SemiBold)
    val title = TextStyle(fontFamily = family, fontSize = 20.sp, lineHeight = 26.sp, fontWeight = FontWeight.SemiBold)
    val body = TextStyle(fontFamily = family, fontSize = 15.sp, lineHeight = 22.sp, fontWeight = FontWeight.Normal)
    val bodyStrong = TextStyle(fontFamily = family, fontSize = 15.sp, lineHeight = 22.sp, fontWeight = FontWeight.Medium)
    val caption = TextStyle(fontFamily = family, fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal)
    val micro = TextStyle(fontFamily = family, fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.Medium)

    /** 快捷菜单条目标签(§5.2:13.5,≈ caption 与 body 之间;对齐参照原型 `.pop-item` 的 13.5px) */
    val menuItem = TextStyle(fontFamily = family, fontSize = 13.5.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal)
}

// ---------------------------------------------------------------- 主题载体

@Immutable
data class OrdoTokens(val palette: OrdoPalette, val dark: Boolean)

val LocalOrdoTokens = staticCompositionLocalOf { OrdoTokens(OrdoLightPalette, false) }

/** 全局动效开关:跟随系统"减弱动态效果"(§5) */
val LocalOrdoReduceMotion = staticCompositionLocalOf { false }
