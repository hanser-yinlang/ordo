package com.ordo.desktop.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.SyncStatus
import com.ordo.desktop.app.ThemeMode
import com.ordo.desktop.app.UiState
import com.ordo.desktop.sync.SyncDiagnostics
import com.ordo.desktop.ui.common.OrdoDivider
import com.ordo.desktop.ui.common.OrdoTextButton
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.ordoColors
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * 设置浮层(04-UI规范 §4 组件规范 + §6 快捷键表)。
 * 四段:外观与启动 / 同步 / 同步诊断 / 数据 / 快捷键。
 *
 * 产品决策「不再需要登录」后,这里**没有**账号、退出登录与服务器地址:
 * 会话在后台静默维护,服务器地址是隐藏覆盖(改 `%APPDATA%\Ordo\kv.json` 的 `ordo.serverUrl`)。
 */
@Composable
fun SettingsView(state: UiState, vm: OrdoViewModel) {
    val colors = ordoColors
    val scrim = remember { MutableInteractionSource() }
    val inner = remember { MutableInteractionSource() }

    var message by remember { mutableStateOf<String?>(null) }

    var autoStartOn by remember { mutableStateOf(vm.isAutoStartEnabled()) }
    var autoStartMessage by remember { mutableStateOf<String?>(null) }
    var closeToTray by remember { mutableStateOf(vm.closeToTray()) }
    var followSelection by remember { mutableStateOf(vm.followSelection()) }
    var protocolRegistered by remember { mutableStateOf(vm.isProtocolRegistered()) }
    var protocolMessage by remember { mutableStateOf<String?>(null) }
    var diagnosticsTick by remember { mutableStateOf(0) }
    val diagnostics = remember(diagnosticsTick, state.syncDetail, state.syncStatus, vm.pendingOpCount()) {
        vm.syncDiagnostics()
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0x66000000))
            .clickable(interactionSource = scrim, indication = null) { vm.closeSettings() },
        contentAlignment = Alignment.Center
    ) {
        Column(
            Modifier
                .width(540.dp)
                .clip(RoundedCornerShape(OrdoRadius.card))
                .background(colors.surface)
                .clickable(interactionSource = inner, indication = null) { /* 吞掉点击,避免冒泡关闭 */ }
                .padding(OrdoSpace.xl)
                .verticalScroll(rememberScrollState())
        ) {
            Text("设置", style = OrdoType.title, color = colors.textPrimary, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(OrdoSpace.l))

            /* ---------------- 外观与启动 ---------------- */
            SectionTitle("外观与启动")
            Row(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)) {
                ThemeMode.entries.forEach { mode ->
                    val label = when (mode) {
                        ThemeMode.AUTO -> "跟随系统"
                        ThemeMode.LIGHT -> "浅色"
                        ThemeMode.DARK -> "深色"
                    }
                    val active = state.themeMode == mode
                    Text(
                        text = label,
                        style = OrdoType.caption,
                        color = if (active) colors.accent else colors.textSecondary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(OrdoRadius.pill))
                            .background(if (active) colors.accentSoft else Color.Transparent)
                            .clickable { vm.setTheme(mode) }
                            .padding(horizontal = OrdoSpace.m, vertical = 6.dp)
                    )
                }
            }
            Spacer(Modifier.height(OrdoSpace.s))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("开机自启", style = OrdoType.caption, color = colors.textSecondary, modifier = Modifier.width(90.dp))
                OrdoTextButton(
                    text = if (autoStartOn) "已开启(点击关闭)" else "已关闭(点击开启)",
                    onClick = {
                        val target = !autoStartOn
                        val ok = vm.setAutoStart(target)
                        autoStartOn = if (ok) target else vm.isAutoStartEnabled()
                        autoStartMessage = if (ok) {
                            if (target) "已写入注册表 Run 键,下次登录自动启动" else "已从注册表 Run 键移除"
                        } else {
                            "写入注册表失败(权限或策略限制),已保持原状"
                        }
                    }
                )
            }
            (autoStartMessage ?: vm.autoStartHint())?.let {
                Spacer(Modifier.height(OrdoSpace.xs))
                Text(text = it, style = OrdoType.micro, color = colors.textTertiary)
            }

            Spacer(Modifier.height(OrdoSpace.s))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("关闭窗口", style = OrdoType.caption, color = colors.textSecondary, modifier = Modifier.width(90.dp))
                OrdoTextButton(
                    text = if (closeToTray) "最小化到托盘" else "直接退出",
                    onClick = {
                        closeToTray = !closeToTray
                        vm.setCloseToTray(closeToTray)
                    }
                )
            }
            Spacer(Modifier.height(OrdoSpace.xs))
            Text(
                text = "最小化到托盘后应用继续跑(提醒 / 同步不断);托盘右键「退出」才真正结束。",
                style = OrdoType.micro,
                color = colors.textTertiary
            )

            Spacer(Modifier.height(OrdoSpace.s))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("窗口", style = OrdoType.caption, color = colors.textSecondary, modifier = Modifier.width(90.dp))
                OrdoTextButton(text = "新建窗口 (Ctrl+Shift+N)", onClick = { vm.openNewWindow() })
                Spacer(Modifier.width(OrdoSpace.s))
                OrdoTextButton(
                    text = if (followSelection) "跟随选中:开" else "跟随选中:关",
                    onClick = {
                        followSelection = !followSelection
                        vm.setFollowSelection(followSelection)
                    }
                )
            }
            Spacer(Modifier.height(OrdoSpace.xs))
            Text(
                text = "每个窗口有独立清单与选中;开启「跟随选中」后,在任一窗口打开某条待办,其它窗口会把它高亮出来。",
                style = OrdoType.micro,
                color = colors.textTertiary
            )

            SectionDivider()

            /* ---------------- 深链协议 ---------------- */
            SectionTitle("ordo:// 深链")
            Row(verticalAlignment = Alignment.CenterVertically) {
                OrdoTextButton(
                    text = if (protocolRegistered) "已注册(点击重新注册)" else "注册协议",
                    onClick = {
                        val ok = vm.registerProtocol()
                        protocolRegistered = vm.isProtocolRegistered()
                        protocolMessage = if (ok) "已写入 HKCU\\Software\\Classes\\ordo" else "注册失败(权限或策略限制)"
                    }
                )
                Spacer(Modifier.width(OrdoSpace.s))
                Text(
                    text = if (protocolRegistered) "浏览器点击 ordo://today 可直接打开" else "命令行深链仍可用",
                    style = OrdoType.micro,
                    color = colors.textTertiary
                )
            }
            (protocolMessage ?: vm.protocolHint()).let {
                Spacer(Modifier.height(OrdoSpace.xs))
                Text(text = it, style = OrdoType.micro, color = colors.textTertiary)
            }

            SectionDivider()

            /* ---------------- 同步 ---------------- */
            // 产品决策:不再需要登录 —— 这里没有账号 / 退出登录 / 服务器地址。
            // 会话在后台静默维护(见 SilentSessionKeeper);服务器地址是隐藏覆盖,改 %APPDATA%\Ordo\kv.json。
            SectionTitle("同步")
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(OrdoSpace.m)
            ) {
                OrdoTextButton(text = "立即同步", onClick = { vm.syncNow() })
            }

            message?.let {
                Spacer(Modifier.height(OrdoSpace.s))
                Text(it, style = OrdoType.caption, color = if (it.contains("成功")) colors.success else colors.danger)
            }

            Spacer(Modifier.height(OrdoSpace.s))
            Text(
                text = syncSummary(state, vm),
                style = OrdoType.caption,
                color = colors.textTertiary
            )

            SectionDivider()

            /* ---------------- 同步诊断 ---------------- */
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionTitle("同步诊断")
                Spacer(Modifier.width(OrdoSpace.s))
                OrdoTextButton(text = "刷新", onClick = { diagnosticsTick += 1 })
            }
            Text(
                text = "待推送 ${diagnostics.pendingCount} 条 · 服务端序号 ${diagnostics.lastServerSeq} · " +
                    "上次错误:${diagnostics.lastError ?: "无"}",
                style = OrdoType.caption,
                color = colors.textSecondary
            )
            Spacer(Modifier.height(OrdoSpace.s))
            if (diagnostics.recent.isEmpty()) {
                Text("outbox 为空,本地改动都已推送。", style = OrdoType.micro, color = colors.textTertiary)
            } else {
                Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                    Text("实体", style = OrdoType.micro, color = colors.textTertiary, modifier = Modifier.width(96.dp))
                    Text("opId", style = OrdoType.micro, color = colors.textTertiary, modifier = Modifier.weight(1f))
                    Text("clientTs", style = OrdoType.micro, color = colors.textTertiary, modifier = Modifier.width(96.dp))
                }
                diagnostics.recent.forEach { row ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                        Text(row.label, style = OrdoType.micro, color = colors.textSecondary, modifier = Modifier.width(96.dp))
                        Text(
                            text = row.opId,
                            style = OrdoType.micro,
                            color = colors.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f)
                        )
                        Text(
                            text = diagnosticsTime(row.clientTs),
                            style = OrdoType.micro,
                            color = colors.textTertiary,
                            modifier = Modifier.width(96.dp)
                        )
                    }
                }
                if (diagnostics.truncated) {
                    Text(
                        text = "仅显示前 ${SyncDiagnostics.DEFAULT_LIMIT} 条(共 ${diagnostics.pendingCount} 条)",
                        style = OrdoType.micro,
                        color = colors.textTertiary
                    )
                }
            }

            SectionDivider()

            /* ---------------- 数据 ---------------- */
            SectionTitle("数据")
            Row(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.m)) {
                OrdoTextButton(text = "重置为示例数据", onClick = { vm.resetDemoData(); diagnosticsTick += 1 })
                OrdoTextButton(text = "清空本地数据", onClick = { vm.clearAllData(); diagnosticsTick += 1 }, danger = true)
            }
            Spacer(Modifier.height(OrdoSpace.xs))
            Text(
                text = "本地数据位于 %APPDATA%\\Ordo\\<数据目录 id>\\;" +
                    "清空只影响本机这份数据，云端数据需重新同步。",
                style = OrdoType.micro,
                color = colors.textTertiary
            )

            SectionDivider()

            /* ---------------- 快捷键(04-UI规范 §6) ---------------- */
            SectionTitle("快捷键")
            SHORTCUTS.forEach { (key, desc) ->
                Row(Modifier.padding(vertical = 2.dp)) {
                    Text(key, style = OrdoType.micro, color = colors.textPrimary, modifier = Modifier.width(150.dp))
                    Text(desc, style = OrdoType.micro, color = colors.textSecondary)
                }
            }

            Spacer(Modifier.height(OrdoSpace.l))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                OrdoTextButton(text = "完成", onClick = { vm.closeSettings() })
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = OrdoType.caption, color = ordoColors.textSecondary, fontWeight = FontWeight.SemiBold)
    Spacer(Modifier.height(OrdoSpace.s))
}

@Composable
private fun SectionDivider() {
    Spacer(Modifier.height(OrdoSpace.l))
    OrdoDivider()
    Spacer(Modifier.height(OrdoSpace.l))
}

private fun syncSummary(state: UiState, vm: OrdoViewModel): String {
    val status = when (state.syncStatus) {
        SyncStatus.LOCAL -> "本地模式"
        SyncStatus.SYNCING -> "同步中"
        SyncStatus.SYNCED -> "已同步"
        SyncStatus.OFFLINE -> "离线"
        SyncStatus.ERROR -> "同步失败"
    }
    return "同步状态:$status · 待推送 ${vm.pendingOpCount()} 条 · 服务端序号 ${vm.lastServerSeq()}"
}

/** outbox 明细的时间列:本地时区的 `MM-dd HH:mm:ss` */
private val DIAG_TIME: DateTimeFormatter = DateTimeFormatter.ofPattern("MM-dd HH:mm:ss")

private fun diagnosticsTime(clientTs: Long): String =
    runCatching {
        Instant.ofEpochMilli(clientTs).atZone(ZoneId.systemDefault()).format(DIAG_TIME)
    }.getOrDefault(clientTs.toString())

private val SHORTCUTS = listOf(
    "Ctrl + N" to "新建待办",
    "Ctrl + K" to "快速查找(FastFind)",
    "Ctrl + R" to "立即同步(等同于点状态栏右侧的刷新控件)",
    "Ctrl + D" to "切换外观(自动 / 浅色 / 深色)",
    "1 – 6" to "收件箱 / 今天 / 计划 / 随时 / 某天 / 日志簿",
    "↑ ↓" to "移动选中行",
    "Enter" to "打开详情卡片",
    "Space" to "切换完成状态",
    "Delete" to "删除选中待办",
    "Esc" to "关闭浮层 / 详情;取消长按拖拽",
    "长按 400ms 后拖动" to "待办行排序(按住行尾手柄可免长按直接拖)"
)
