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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ordo.android.R
import com.ordo.android.di.ServiceLocator
import com.ordo.android.ui.common.OrdoButton
import com.ordo.android.ui.common.OrdoDivider
import com.ordo.android.ui.common.OrdoTextField
import com.ordo.android.ui.common.TagChip
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.ui.theme.ThemeMode
import com.ordo.android.vm.OrdoViewModel
import com.ordo.android.vm.UiState

/**
 * 设置（04 文档 §6：Android 的深色切换与账号入口在设置项里）。
 *
 * 账号区（契约 §7.6.3）：
 *  - 显示**当前账号**（邮箱 / 游客标记 / userId / 本地数据目录）；
 *  - 提供**退出登录**：只清除会话，**保留**该 userId 的本地数据目录；
 *  - 游客可在此升级为正式账号（userId 与数据不变，契约 §7.6.2）。
 */
@Composable
fun SettingsScreen(state: UiState, vm: OrdoViewModel) {
    val colors = OrdoTheme.colors
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var serverUrl by remember { mutableStateOf("") }
    var confirmReset by remember { mutableStateOf(false) }
    var confirmLogout by remember { mutableStateOf(false) }
    var upgradeOpen by remember { mutableStateOf(false) }

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

        /* 账号（契约 §7.6.3） */
        SectionCard(
            title = stringResource(R.string.settings_account),
            desc = if (state.auth.loggedIn) {
                state.auth.displayName
            } else {
                stringResource(R.string.settings_account_none)
            },
        ) {
            if (state.auth.loggedIn) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = stringResource(R.string.settings_account_current),
                        style = OrdoTheme.type.caption,
                        color = colors.textSecondary,
                    )
                    Spacer(Modifier.padding(horizontal = OrdoSpace.xs))
                    Text(
                        text = state.auth.displayName,
                        style = OrdoTheme.type.body,
                        color = colors.textPrimary,
                    )
                    if (state.auth.isGuest) {
                        Spacer(Modifier.padding(horizontal = OrdoSpace.xs))
                        TagChip(name = stringResource(R.string.settings_account_guest))
                    }
                }
                Spacer(Modifier.height(OrdoSpace.xs))
                Text(
                    text = stringResource(R.string.settings_account_id, state.auth.userId.orEmpty()),
                    style = OrdoTheme.type.micro,
                    color = colors.textTertiary,
                )
                ServiceLocator.userDir(state.auth.userId)?.absolutePath?.let { path ->
                    Text(
                        text = stringResource(R.string.settings_account_dir, path),
                        style = OrdoTheme.type.micro,
                        color = colors.textTertiary,
                    )
                }
                Spacer(Modifier.height(OrdoSpace.m))

                Row(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)) {
                    OrdoButton(
                        label = stringResource(R.string.settings_logout),
                        onClick = { confirmLogout = true },
                        danger = true,
                    )
                    if (state.auth.isGuest) {
                        OrdoButton(
                            label = stringResource(R.string.settings_upgrade),
                            onClick = { upgradeOpen = !upgradeOpen },
                        )
                    }
                }

                if (confirmLogout) {
                    Spacer(Modifier.height(OrdoSpace.s))
                    Text(
                        text = stringResource(R.string.settings_account_hint),
                        style = OrdoTheme.type.caption,
                        color = colors.textSecondary,
                    )
                    Spacer(Modifier.height(OrdoSpace.s))
                    Row(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)) {
                        OrdoButton(
                            label = stringResource(R.string.common_confirm),
                            onClick = {
                                confirmLogout = false
                                vm.logout()
                            },
                            danger = true,
                        )
                        OrdoButton(
                            label = stringResource(R.string.common_cancel),
                            onClick = { confirmLogout = false },
                        )
                    }
                }

                if (upgradeOpen && state.auth.isGuest) {
                    Spacer(Modifier.height(OrdoSpace.m))
                    OrdoTextField(
                        value = email,
                        onValueChange = { email = it },
                        placeholder = stringResource(R.string.settings_email),
                        label = stringResource(R.string.settings_email),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(OrdoSpace.s))
                    OrdoTextField(
                        value = password,
                        onValueChange = { password = it },
                        placeholder = stringResource(R.string.settings_password),
                        label = stringResource(R.string.settings_password),
                        modifier = Modifier.fillMaxWidth(),
                        isPassword = true,
                    )
                    Spacer(Modifier.height(OrdoSpace.s))
                    OrdoButton(
                        label = stringResource(R.string.settings_upgrade),
                        onClick = {
                            vm.upgradeGuest(email, password)
                            upgradeOpen = false
                        },
                        primary = true,
                    )
                }
            }

            Spacer(Modifier.height(OrdoSpace.m))
            OrdoTextField(
                value = serverUrl,
                onValueChange = { serverUrl = it },
                placeholder = ServiceLocator.tokens.serverUrl(),
                label = stringResource(R.string.settings_server),
                modifier = Modifier.fillMaxWidth(),
                onSubmit = { vm.setServerUrl(serverUrl) },
            )
            Spacer(Modifier.height(OrdoSpace.s))
            OrdoButton(
                label = stringResource(R.string.settings_server_save),
                onClick = { vm.setServerUrl(serverUrl) },
            )
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
