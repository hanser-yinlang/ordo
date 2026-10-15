package com.ordo.android.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import com.ordo.android.R
import com.ordo.android.ui.common.OrdoButton
import com.ordo.android.ui.common.OrdoDivider
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.ui.theme.ThemeMode
import com.ordo.android.vm.OrdoViewModel
import com.ordo.android.vm.UiState

/**
 * 设置（04 文档 §6）。
 *
 * v1.4（彻底删除云同步）：应用是**纯本地**的 —— 没有账号、没有服务器地址、没有同步操作，
 * 设置页只保留外观 / 数据（重置为示例数据）/ 关于。
 */
@Composable
fun SettingsScreen(state: UiState, vm: OrdoViewModel) {
    val colors = OrdoTheme.colors
    var confirmReset by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(OrdoSpace.l),
        verticalArrangement = Arrangement.spacedBy(OrdoSpace.m),
    ) {
        /* 外观 */
        SectionCard(stringResource(R.string.settings_appearance), stringResource(R.string.settings_appearance_desc)) {
            Row(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)) {
                ThemeMode.entries.forEach { mode ->
                    val label = when (mode) {
                        ThemeMode.AUTO -> stringResource(R.string.settings_theme_auto)
                        ThemeMode.LIGHT -> stringResource(R.string.settings_theme_light)
                        ThemeMode.DARK -> stringResource(R.string.settings_theme_dark)
                    }
                    SegmentButton(
                        label = label,
                        selected = state.themeMode == mode,
                        onClick = { vm.setThemeMode(mode) },
                    )
                }
            }
        }

        /* 数据（纯本地：v1.4 起没有「立即同步」这类同步操作） */
        SectionCard(
            stringResource(R.string.settings_data),
            stringResource(R.string.settings_data_desc, state.totalCount),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)) {
                OrdoButton(
                    label = stringResource(R.string.settings_reset),
                    onClick = { confirmReset = true },
                    danger = true,
                )
                OrdoButton(
                    label = stringResource(R.string.settings_clear),
                    onClick = { confirmClear = true },
                    danger = true,
                )
            }
            if (confirmReset) {
                ConfirmStrip(
                    text = stringResource(R.string.settings_reset_confirm),
                    onConfirm = {
                        vm.resetToSeed()
                        confirmReset = false
                    },
                    onCancel = { confirmReset = false },
                )
            }
            if (confirmClear) {
                ConfirmStrip(
                    text = stringResource(R.string.settings_clear_confirm),
                    onConfirm = {
                        vm.clearAllData()
                        confirmClear = false
                    },
                    onCancel = { confirmClear = false },
                )
            }
        }

        /* 关于 */
        SectionCard(stringResource(R.string.settings_about), stringResource(R.string.settings_about_desc)) {
            Text(
                text = stringResource(R.string.app_slogan),
                style = OrdoTheme.type.caption,
                color = colors.textSecondary,
            )
        }
    }
}

/**
 * 破坏性操作的两步确认（数据区用）：一段红色说明 + 确定 / 取消。
 *
 * 「重置为示例数据」与「清空本地数据」都不可撤销，因此都先亮出后果再执行，
 * 不用系统对话框：浮层实现只在 Compose 内部，竖屏矮屏也不会挡住按钮。
 */
@Composable
private fun ConfirmStrip(text: String, onConfirm: () -> Unit, onCancel: () -> Unit) {
    val colors = OrdoTheme.colors
    Spacer(Modifier.height(OrdoSpace.s))
    Text(text = text, style = OrdoTheme.type.caption, color = colors.danger)
    Spacer(Modifier.height(OrdoSpace.s))
    Row(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)) {
        OrdoButton(
            label = stringResource(R.string.common_confirm),
            onClick = onConfirm,
            danger = true,
        )
        OrdoButton(
            label = stringResource(R.string.common_cancel),
            onClick = onCancel,
        )
    }
}

@Composable
private fun SectionCard(
    title: String,
    desc: String,
    content: @Composable () -> Unit,
) {
    val colors = OrdoTheme.colors
    Column(
        Modifier
            .fillMaxWidth(1f)
            .clip(RoundedCornerShape(OrdoRadius.card))
            .background(colors.surface)
            .padding(OrdoSpace.l),
    ) {
        Text(text = title, style = OrdoTheme.type.title, color = colors.textPrimary)
        Spacer(Modifier.height(OrdoSpace.xs))
        Text(text = desc, style = OrdoTheme.type.caption, color = colors.textSecondary)
        Spacer(Modifier.height(OrdoSpace.m))
        OrdoDivider()
        Spacer(Modifier.height(OrdoSpace.m))
        content()
    }
}

@Composable
private fun SegmentButton(label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = OrdoTheme.colors
    Box(
        Modifier
            .clip(RoundedCornerShape(OrdoRadius.pill))
            .background(if (selected) colors.accent else colors.chipBg)
            .clickable(onClick = onClick)
            .padding(horizontal = OrdoSpace.l, vertical = OrdoSpace.s),
    ) {
        Text(
            text = label,
            style = OrdoTheme.type.caption,
            color = if (selected) colors.onAccent else colors.chipText,
        )
    }
}
