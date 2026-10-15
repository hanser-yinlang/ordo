package com.ordo.android.ui.theme

import android.app.Activity
import android.provider.Settings
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

/** 外观模式（04 文档 §6：Android 走设置项） */
enum class ThemeMode {
    AUTO,
    LIGHT,
    DARK;

    fun next(): ThemeMode = when (this) {
        AUTO -> LIGHT
        LIGHT -> DARK
        DARK -> AUTO
    }

    companion object {
        fun fromKey(key: String?): ThemeMode = when (key) {
            "light" -> LIGHT
            "dark" -> DARK
            else -> AUTO
        }
    }

    val storageKey: String
        get() = when (this) {
            AUTO -> "auto"
            LIGHT -> "light"
            DARK -> "dark"
        }
}

val LocalOrdoColors = staticCompositionLocalOf { OrdoLightColors }
val LocalOrdoTypography = staticCompositionLocalOf { OrdoTypography() }

/** 系统「减弱动态效果」开启时为 true（04 文档 §5 末条） */
val LocalReduceMotion = staticCompositionLocalOf { false }

object OrdoTheme {
    val colors: OrdoColors
        @Composable @ReadOnlyComposable get() = LocalOrdoColors.current

    val type: OrdoTypography
        @Composable @ReadOnlyComposable get() = LocalOrdoTypography.current

    val reduceMotion: Boolean
        @Composable @ReadOnlyComposable get() = LocalReduceMotion.current

    /** 动效时长：减弱动态效果开启时统一为 0ms */
    val fast: Int @Composable @ReadOnlyComposable get() = if (reduceMotion) 0 else OrdoMotion.FAST
    val base: Int @Composable @ReadOnlyComposable get() = if (reduceMotion) 0 else OrdoMotion.BASE
    val slow: Int @Composable @ReadOnlyComposable get() = if (reduceMotion) 0 else OrdoMotion.SLOW

    /** §5.5 过渡动效：浮层入场 280 / 退场 200、页面切换 240、抽屉 260、详情 220 */
    val popIn: Int @Composable @ReadOnlyComposable get() = if (reduceMotion) 0 else OrdoMotion.POP_IN
    val popOut: Int @Composable @ReadOnlyComposable get() = if (reduceMotion) 0 else OrdoMotion.POP_OUT
    val pageFade: Int @Composable @ReadOnlyComposable get() = if (reduceMotion) 0 else OrdoMotion.PAGE_FADE
    val drawer: Int @Composable @ReadOnlyComposable get() = if (reduceMotion) 0 else OrdoMotion.SHEET_COLLAPSE
    val detail: Int @Composable @ReadOnlyComposable get() = if (reduceMotion) 0 else OrdoMotion.BASE
}

/** 读取系统动画时长为 0（即「减弱动态效果」） */
@Composable
fun rememberReduceMotion(): Boolean {
    val context = LocalContext.current
    return remember(context) {
        runCatching {
            Settings.Global.getFloat(
                context.contentResolver,
                Settings.Global.ANIMATOR_DURATION_SCALE,
                1f,
            ) == 0f
        }.getOrDefault(false)
    }
}

@Composable
fun OrdoTheme(
    themeMode: ThemeMode = ThemeMode.AUTO,
    content: @Composable () -> Unit,
) {
    val systemDark = isSystemInDarkTheme()
    val dark = when (themeMode) {
        ThemeMode.AUTO -> systemDark
        ThemeMode.LIGHT -> false
        ThemeMode.DARK -> true
    }
    val colors = if (dark) OrdoDarkColors else OrdoLightColors
    val reduceMotion = rememberReduceMotion()

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as? Activity)?.window ?: return@SideEffect
            val controller = WindowCompat.getInsetsController(window, view)
            controller.isAppearanceLightStatusBars = !dark
            controller.isAppearanceLightNavigationBars = !dark
        }
    }

    CompositionLocalProvider(
        LocalOrdoColors provides colors,
        LocalOrdoTypography provides OrdoTypography(),
        LocalReduceMotion provides reduceMotion,
    ) {
        content()
    }
}
