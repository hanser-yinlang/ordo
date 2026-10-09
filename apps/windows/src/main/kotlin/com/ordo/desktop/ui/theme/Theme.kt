package com.ordo.desktop.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.remember

/** Ordo 主题:提供设计令牌 + 一个克制的 Material3 配色(组件仍以自绘为主) */
@Composable
fun OrdoTheme(
    dark: Boolean,
    reduceMotion: Boolean = false,
    content: @Composable () -> Unit
) {
    val tokens = remember(dark) {
        OrdoTokens(if (dark) OrdoDarkPalette else OrdoLightPalette, dark)
    }
    val palette = tokens.palette
    val scheme = remember(dark) {
        if (dark) {
            darkColorScheme(
                primary = OrdoDarkPalette.accent,
                onPrimary = OrdoDarkPalette.surface,
                background = OrdoDarkPalette.canvas,
                onBackground = OrdoDarkPalette.textPrimary,
                surface = OrdoDarkPalette.surface,
                onSurface = OrdoDarkPalette.textPrimary,
                error = OrdoDarkPalette.danger
            )
        } else {
            lightColorScheme(
                primary = OrdoLightPalette.accent,
                onPrimary = OrdoLightPalette.surface,
                background = OrdoLightPalette.canvas,
                onBackground = OrdoLightPalette.textPrimary,
                surface = OrdoLightPalette.surface,
                onSurface = OrdoLightPalette.textPrimary,
                error = OrdoLightPalette.danger
            )
        }
    }
    CompositionLocalProvider(
        LocalOrdoTokens provides tokens,
        LocalOrdoReduceMotion provides reduceMotion
    ) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

/** 当前配色(便捷访问器) */
val ordoColors: OrdoPalette
    @Composable @ReadOnlyComposable get() = LocalOrdoTokens.current.palette

val ordoDark: Boolean
    @Composable @ReadOnlyComposable get() = LocalOrdoTokens.current.dark

/** 动效时长:系统要求"减弱动态效果"时统一降为 0(04-UI规范 §5) */
@Composable
fun motionMillis(millis: Int): Int = if (LocalOrdoReduceMotion.current) 0 else millis
