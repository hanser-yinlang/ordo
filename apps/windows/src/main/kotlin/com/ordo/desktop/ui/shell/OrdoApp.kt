package com.ordo.desktop.ui.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.ui.common.OrdoConfirmDialog
import com.ordo.desktop.ui.common.OrdoToastHost
import com.ordo.desktop.ui.list.ListPane
import com.ordo.desktop.ui.quickadd.QuickAdd
import com.ordo.desktop.ui.schedule.ScheduleSheet
import com.ordo.desktop.ui.search.FastFindOverlay
import com.ordo.desktop.ui.settings.SettingsView
import com.ordo.desktop.ui.theme.OrdoTheme
import com.ordo.desktop.ui.theme.ordoColors

/**
 * 应用根组件(04-UI规范 §3 三栏骨架):
 *
 *   ┌──────────┬───────────────────────────────┐
 *   │ 侧栏 248  │ 清单区(大标题 + 分组 + 待办行)   │
 *   │          ├───────────────────────────────┤
 *   │          │ 状态栏:共 N 项 · 已完成 M 项 · 同步 │
 *   └──────────┴───────────────────────────────┘
 *   浮层:快加号 / 排期面板 / 快找 / 设置 / 提示条(按需叠加)
 */
@Composable
fun OrdoApp(vm: OrdoViewModel) {
    val state by vm.state.collectAsState()

    OrdoTheme(dark = state.dark) {
        Box(
            Modifier
                .fillMaxSize()
                .background(ordoColors.canvas)
        ) {
            Row(Modifier.fillMaxSize()) {
                Sidebar(state = state, vm = vm)
                Column(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .background(ordoColors.canvas)
                ) {
                    ListPane(state = state, vm = vm, modifier = Modifier.weight(1f))
                    StatusBar(state = state)
                }
            }

            // 快加号(右下悬浮)
            QuickAdd(state = state, vm = vm, modifier = Modifier.align(Alignment.BottomEnd))

            // 排期面板(契约 §4 / UI 规范 §4)
            if (state.scheduleTargetId != null) {
                ScheduleSheet(state = state, vm = vm)
            }

            // 快找浮层
            if (state.fastFindOpen) {
                FastFindOverlay(state = state, vm = vm)
            }

            // 设置
            if (state.settingsOpen) {
                SettingsView(state = state, vm = vm)
            }

            // 破坏性操作的二次确认(项目 / 区域 / 标题)
            state.confirm?.let { request ->
                OrdoConfirmDialog(
                    title = request.title,
                    message = request.message,
                    onConfirm = { vm.confirmDelete() },
                    onCancel = { vm.cancelConfirm() }
                )
            }

            // 提示条
            OrdoToastHost(message = state.toast, onDismiss = vm::dismissToast)
        }
    }
}

/** 供 Main.kt 记录窗口标题(跟随当前清单,04-UI规范 §3) */
@Composable
fun windowTitleOf(vm: OrdoViewModel): String {
    val state by vm.state.collectAsState()
    return "Ordo · " + state.route.title
}
