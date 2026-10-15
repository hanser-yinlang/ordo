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
import com.ordo.desktop.ui.common.OrdoPageEnter
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
                    // 切清单 / 进项目 / 进区域 / 进标签:内容淡入 160ms + 上浮 6dp(§5.5)。
                    // 首次组合停在终态 —— 冷启动没有过场,离屏渲染第 0 帧也拿得到完整内容。
                    OrdoPageEnter(key = state.route, modifier = Modifier.weight(1f)) {
                        ListPane(state = state, vm = vm, modifier = Modifier.fillMaxSize())
                    }
                    StatusBar(state = state)
                }
            }

            // 快加号(右下悬浮)
            QuickAdd(state = state, vm = vm, modifier = Modifier.align(Alignment.BottomEnd))

            // 浮层宿主一律无条件组合:关闭时要靠 visible 走完 140ms 退场(§5.5);
            // 被 if 包住的话整棵子树当场消失,退场与遮罩淡出都播不出来。
            ScheduleSheet(state = state, vm = vm)

            // 快找浮层
            FastFindOverlay(state = state, vm = vm)

            // 设置
            SettingsView(state = state, vm = vm)

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
