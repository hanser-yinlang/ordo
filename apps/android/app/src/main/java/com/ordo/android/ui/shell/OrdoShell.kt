package com.ordo.android.ui.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.navigation.compose.rememberNavController
import com.ordo.android.R
import com.ordo.android.nav.OrdoNavHost
import com.ordo.android.nav.Routes
import com.ordo.android.ui.common.OrdoIcon
import com.ordo.android.ui.common.OrdoIconButton
import com.ordo.android.ui.common.OrdoIconKind
import com.ordo.android.ui.common.OrdoScrim
import com.ordo.android.ui.common.OrdoToastHost
import com.ordo.android.ui.detail.DetailCard
import com.ordo.android.ui.quickadd.ComposerSheet
import com.ordo.android.ui.quickadd.QuickAddFab
import com.ordo.android.ui.quickadd.QuickAddMenu
import com.ordo.android.ui.schedule.ScheduleSheet
import com.ordo.android.ui.search.FastFind
import com.ordo.android.ui.settings.SettingsScreen
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoMotion
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.UiState
import com.ordo.android.vm.OrdoViewModel
import com.ordo.android.sync.SyncState

/**
 * 三栏骨架（04 文档 §3）：
 *   ≥1100dp 侧栏 + 列表 + 详情(内联第三栏)
 *   768–1099dp 侧栏 + 列表，详情浮层
 *   <768dp 侧栏抽屉 + 列表，详情全屏
 */
@Composable
fun OrdoRoot(
    state: UiState,
    vm: OrdoViewModel,
    deepLink: String?,
    onDeepLinkConsumed: () -> Unit,
) {
    val colors = OrdoTheme.colors
    val navController = rememberNavController()

    LaunchedEffect(deepLink) {
        val route = deepLink ?: return@LaunchedEffect
        if (route.startsWith("detail/")) {
            navController.navigate(Routes.TODAY) { launchSingleTop = true }
            vm.openDetail(route.removePrefix("detail/"))
        } else {
            navController.navigate(route) { launchSingleTop = true }
        }
        onDeepLinkConsumed()
    }

    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(colors.canvas)
            .windowInsetsPadding(WindowInsets.systemBars)
            .imePadding(),
    ) {
        val wide = maxWidth >= OrdoLayout.BREAKPOINT_WIDE.dp
        val medium = maxWidth >= OrdoLayout.BREAKPOINT_MEDIUM.dp

        Row(Modifier.fillMaxSize()) {
            if (medium) {
                OrdoSidebar(
                    state = state,
                    onNavigate = { route -> navigateTo(navController, route, vm) },
                    onToggleArea = vm::toggleAreaCollapsed,
                    onOpenSettings = { navigateTo(navController, Routes.SETTINGS, vm) },
                )
            }

            Column(Modifier.weight(1f)) {
                MainHeader(
                    state = state,
                    showMenuButton = !medium,
                    onMenu = { vm.toggleSidebar(true) },
                    onSearch = vm::openFastFind,
                )
                Box(Modifier.weight(1f)) {
                    if (state.routeKey == UiState.ROUTE_SETTINGS) {
                        SettingsScreen(state = state, vm = vm)
                    } else {
                        OrdoNavHost(
                            navController = navController,
                            state = state,
                            vm = vm,
                            onNavigate = { route -> navigateTo(navController, route, vm) },
                        )
                        /*
                         * 浮层先画、快加号后画：加号永远在浮层之上，因此
                         *   ① 点加号 → 浮层出现（scrim + 输入卡片，明确可见）；
                         *   ② 浮层已打开时再点加号 → 命中的是加号而不是遮罩，
                         *      ViewModel 只递增 focusRequest，界面重新聚焦输入框、不丢草稿（任务 2）。
                         * 卡片底部为加号留出 [OrdoLayout.fabSize] + 一点间距的空档，两者不重叠。
                         */
                        if (state.composer.open) {
                            ComposerSheet(
                                state = state,
                                vm = vm,
                                modifier = Modifier.padding(bottom = OrdoLayout.fabSize + OrdoSpace.l),
                            )
                        }
                        QuickAddFab(
                            state = state,
                            onClick = { vm.openComposer(currentComposerTarget(state)) },
                            onLongClick = { vm.openQuickAddMenu(true) },
                            modifier = Modifier
                                .align(Alignment.BottomEnd)
                                .padding(OrdoSpace.xl),
                        )
                    }
                }
                StatusBar(state = state)
            }

            if (wide && state.detail != null) {
                DetailColumn(state = state, vm = vm)
            }
        }

        /* ------------------------------ 浮层 ------------------------------ */

        if (!medium && state.sidebarOpen) {
            Box(Modifier.fillMaxSize()) {
                OrdoScrim(onClick = { vm.toggleSidebar(false) })
                OrdoSidebar(
                    state = state,
                    onNavigate = { route -> navigateTo(navController, route, vm) },
                    onToggleArea = vm::toggleAreaCollapsed,
                    onOpenSettings = { navigateTo(navController, Routes.SETTINGS, vm) },
                    modifier = Modifier.fillMaxHeight(),
                )
            }
        }

        if (state.fastFindOpen) {
            FastFind(
                state = state,
                vm = vm,
                onNavigate = { route -> navigateTo(navController, route, vm) },
            )
        }

        if (state.scheduleTarget != null) {
            ScheduleSheet(state = state, vm = vm)
        }

        if (state.quickAddMenuOpen) {
            QuickAddMenu(state = state, vm = vm)
        }

        /* 新建待办浮层不在这里：它与快加号同处列表区（见上），保证"再点一次加号"能重新聚焦 */

        if (!wide && state.detail != null) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(colors.canvas)
                    .padding(top = OrdoSpace.m),
            ) {
                DetailCard(
                    state = state,
                    vm = vm,
                    expanded = true,
                    onClose = vm::closeDetail,
                )
            }
        }

        OrdoToastHost(message = state.toast)
    }
}

private fun navigateTo(
    navController: androidx.navigation.NavHostController,
    route: String,
    vm: OrdoViewModel,
) {
    vm.navigate(route)
    runCatching {
        navController.navigate(route) { launchSingleTop = true }
    }
}

private fun currentComposerTarget(state: UiState): String? = when {
    state.routeKey.startsWith("project/") -> state.routeKey
    state.routeKey.startsWith("area/") -> state.routeKey
    else -> null
}

@Composable
private fun MainHeader(
    state: UiState,
    showMenuButton: Boolean,
    onMenu: () -> Unit,
    onSearch: () -> Unit,
) {
    val colors = OrdoTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = OrdoSpace.l, vertical = OrdoSpace.m),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (showMenuButton) {
            OrdoIconButton(
                kind = OrdoIconKind.Menu,
                contentDescription = stringResource(R.string.nav_open_sidebar),
                onClick = onMenu,
            )
            Spacer(Modifier.width(OrdoSpace.xs))
        }
        Column(Modifier.weight(1f)) {
            Text(text = state.title, style = OrdoTheme.type.display, color = colors.textPrimary)
            if (state.subtitle.isNotBlank()) {
                Text(text = state.subtitle, style = OrdoTheme.type.caption, color = colors.textSecondary)
            }
        }
        OrdoIconButton(
            kind = OrdoIconKind.Search,
            contentDescription = stringResource(R.string.common_search),
            onClick = onSearch,
        )
    }
}

@Composable
private fun StatusBar(state: UiState) {
    val colors = OrdoTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .height(34.dp)
            .padding(horizontal = OrdoSpace.l),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = stringResource(R.string.status_counts, state.totalCount, state.doneCount),
            style = OrdoTheme.type.caption,
            color = colors.textSecondary,
        )
        Spacer(Modifier.weight(1f))
        val (icon, tint, label) = when (state.syncState) {
            SyncState.IDLE -> Triple(OrdoIconKind.Check, colors.success, stringResource(R.string.sync_idle))
            SyncState.SYNCING -> Triple(OrdoIconKind.Repeat, colors.accent, stringResource(R.string.sync_syncing))
            SyncState.OFFLINE -> Triple(OrdoIconKind.Close, colors.textTertiary, stringResource(R.string.sync_offline))
            SyncState.FAILED -> Triple(OrdoIconKind.Close, colors.danger, stringResource(R.string.sync_failed))
            SyncState.NOT_LOGGED_IN -> Triple(OrdoIconKind.Close, colors.textTertiary, stringResource(R.string.sync_never))
        }
        OrdoIcon(kind = icon, size = 12.dp, tint = tint, strokeWidth = 1.4f)
        Spacer(Modifier.width(OrdoSpace.xs))
        Text(text = label, style = OrdoTheme.type.caption, color = colors.textSecondary)
    }
}

@Composable
private fun DetailColumn(state: UiState, vm: OrdoViewModel) {
    val colors = OrdoTheme.colors
    Box(
        Modifier
            .width(DetailColumnWidth)
            .fillMaxHeight()
            .background(colors.surface)
            .padding(OrdoSpace.l),
    ) {
        DetailCard(state = state, vm = vm, expanded = false, onClose = vm::closeDetail)
    }
}

private val DetailColumnWidth = 360.dp
