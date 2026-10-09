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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ordo.android.R
import com.ordo.android.ui.common.OrdoButton
import com.ordo.android.ui.common.OrdoDivider
import com.ordo.android.ui.common.OrdoTextField
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.ui.theme.ThemeMode
import com.ordo.android.vm.OrdoViewModel
import com.ordo.android.vm.UiState

/** 设置（04 文档 §6：Android 的深色切换与账号入口在设置项里） */
@Composable
fun SettingsScreen(state: UiState, vm: OrdoViewModel) {
    val colors = OrdoTheme.colors
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var deviceName by remember { mutableStateOf("Android 设备") }
    var serverUrl by remember { mutableStateOf("") }
    var confirmReset by remember { mutableStateOf(false) }

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

        /* 数据 */
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
                    label = stringResource(R.string.settings_sync_now),
                    onClick = { vm.syncNow() },
                )
            }
            if (confirmReset) {
                Spacer(Modifier.height(OrdoSpace.s))
                Text(
                    text = stringResource(R.string.settings_reset_confirm),
                    style = OrdoTheme.type.caption,
                    color = colors.danger,
                )
                Spacer(Modifier.height(OrdoSpace.s))
                Row(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)) {
                    OrdoButton(
                        label = stringResource(R.string.common_confirm),
                        onClick = {
                            vm.resetToSeed()
                            confirmReset = false
                        },
                        danger = true,
                    )
                    OrdoButton(
                        label = stringResource(R.string.common_cancel),
                        onClick = { confirmReset = false },
                    )
                }
            }
        }

        /* 账号 */
        SectionCard(
            title = stringResource(R.string.settings_account),
            desc = if (state.loggedIn) stringResource(R.string.sync_idle) else stringResource(R.string.sync_never),
        ) {
            OrdoTextField(
                value = email,
                onValueChange = { email = it },
                placeholder = stringResource(R.string.settings_email),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(OrdoSpace.s))
            OrdoTextField(
                value = password,
                onValueChange = { password = it },
                placeholder = stringResource(R.string.settings_password),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(OrdoSpace.s))
            OrdoTextField(
                value = deviceName,
                onValueChange = { deviceName = it },
                placeholder = stringResource(R.string.settings_device_name),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(OrdoSpace.s))
            OrdoTextField(
                value = serverUrl,
                onValueChange = { serverUrl = it },
                placeholder = stringResource(R.string.settings_server),
                modifier = Modifier.fillMaxWidth(),
                onSubmit = { vm.setServerUrl(serverUrl) },
            )
            Spacer(Modifier.height(OrdoSpace.s))
            Row(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)) {
                OrdoButton(
                    label = stringResource(R.string.settings_login),
                    onClick = { vm.login(email, password, deviceName) },
                    primary = true,
                )
                OrdoButton(
                    label = stringResource(R.string.settings_register),
                    onClick = { vm.register(email, password, deviceName) },
                )
                if (state.loggedIn) {
                    OrdoButton(
                        label = stringResource(R.string.settings_logout),
                        onClick = { vm.logout() },
                        danger = true,
                    )
                }
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
