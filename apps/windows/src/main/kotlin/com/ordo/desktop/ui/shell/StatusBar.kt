package com.ordo.desktop.ui.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.SyncStatus
import com.ordo.desktop.app.UiState
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.ordoColors

/** 状态栏(04-UI规范 §3):共 N 项 · 已完成 M 项 · 同步状态 */
@Composable
fun StatusBar(state: UiState, vm: OrdoViewModel) {
    val colors = ordoColors
    val total = state.totalCount
    val done = state.counts.logbook
    val (statusText, statusColor) = when (state.syncStatus) {
        SyncStatus.LOCAL -> "本地" to colors.textTertiary
        SyncStatus.SYNCING -> "同步中…" to colors.accent
        SyncStatus.SYNCED -> "已同步" to colors.success
        SyncStatus.OFFLINE -> "离线" to colors.danger
        SyncStatus.ERROR -> "同步失败" to colors.danger
    }

    Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
    Row(
        Modifier
            .fillMaxWidth()
            .background(colors.canvas)
            .padding(horizontal = OrdoSpace.xl, vertical = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)
    ) {
        Text("共 $total 项 · 已完成 $done 项", style = OrdoType.caption, color = colors.textSecondary)
        Spacer(Modifier.weight(1f))
        state.syncDetail?.let { detail ->
            Text(detail.take(60), style = OrdoType.micro, color = colors.textTertiary)
            Spacer(Modifier.width(OrdoSpace.s))
        }
        Box(
            Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(statusColor)
        )
        Spacer(Modifier.width(6.dp))
        Box(
            Modifier.clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null
            ) { vm.syncNow() }
        ) {
            Text(statusText, style = OrdoType.caption, color = statusColor)
        }
    }
}
