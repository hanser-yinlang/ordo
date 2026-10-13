package com.ordo.desktop.ui.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ordo.desktop.app.UiState
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.ordoColors

/**
 * 状态栏(04-UI规范 §3):`共 N 项 · 已完成 M 项`。
 *
 * 纯本地版本:**没有**刷新控件、没有同步指示、没有任何"同步中/已同步/离线"文案 ——
 * 数据就在本机,不存在需要"刷一下"的东西(§5.3 的刷新控件随云同步一起移除)。
 */
@Composable
fun StatusBar(state: UiState) {
    val colors = ordoColors
    val total = state.totalCount
    val done = state.counts.logbook

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
        Text("本地", style = OrdoType.micro, color = colors.textTertiary)
    }
}
