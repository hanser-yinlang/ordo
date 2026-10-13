package com.ordo.android.ui.shell

import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
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
import com.ordo.android.ui.quickadd.QuickAddMenuLayer
import com.ordo.android.ui.schedule.ScheduleSheet
import com.ordo.android.ui.search.FastFind
import com.ordo.android.ui.settings.SettingsScreen
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.UiState
import com.ordo.android.vm.OrdoViewModel

/**
 * 应用根（v1.3：**不再有登录门禁**）。
 *
 * 产品决策「不再需要登录」：启动即进主界面，云同步走后台静默匿名会话
 * （时序见 `auth/SilentSession.kt` 与 `di/ServiceLocator.ensureAnonymousSession`）。
 * 因此这里没有任何 LOADING/LOGIN 分支——任何路径（首启、会话过期、401、离线）都是主界面。
 */
@Composable
fun OrdoRoot(
    state: UiState,
    vm: OrdoViewModel,
    deepLink: String?,
    onDeepLinkConsumed: () -> Unit,
) {
    MainShell(
        state = state,
        vm = vm,
        deepLink = deepLink,
        onDeepLinkConsumed = onDeepLinkConsumed,
    )
}

/**
 * 三栏骨架（04 文档 §3）：
 *   ≥1100dp 侧栏 + 列表 + 详情(内联第三栏)
 *   768–1099dp 侧栏 + 列表，详情浮层
 *   <768dp 侧栏抽屉 + 列表，详情全屏
 */
@Composable
private fun MainShell(
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
                         *      ViewModel 只递增 focusRequest，界面重新聚焦输入框、不丢草稿（任务 2）；
                         *   ③ 长按菜单展开时再点加号 → 同样命中加号 → 收起菜单并转回 0°（UI §5.2）。
                         * 卡片底部为加号留出 [OrdoLayout.fabSize] + 一点间距的空档，两者不重叠。
                         */
                        if (state.composer.open) {
                            ComposerSheet(
                                state = state,
                                vm = vm,
                                modifier = Modifier.padding(bottom = OrdoLayout.fabSize + OrdoSpace.l),
                            )
                        }
                        // 长按菜单从按钮**左上方**弹出：面板右缘对齐按钮右缘、底边压在按钮上方，
                        // 且 transformOrigin 取右下角 —— 视觉上就是"从按钮里向左上展开"（UI §5.2）
                        QuickAddMenuLayer(
                            state = state,
                            vm = vm,
                            panelModifier = Modifier.padding(
                                end = OrdoSpace.xl,
                                bottom = OrdoSpace.xl + OrdoLayout.fabSize + OrdoSpace.s,
                            ),
                        )
                        QuickAddFab(
                            menuOpen = state.quickAddMenuOpen,
                            onClick = vm::onQuickAddTap,
                            onLongClick = vm::onQuickAddLongPress,
                            modifier = Modifier
                                .align(Alignment.BottomEnd)
                                /*
                                 * UI §5.2 v1.5：底边距保证按钮**连同柔光**整体浮在状态栏之上。
                                 * 窗口坐标下的规则是 `statusBar + fabGlow`；而本 FAB 挂在内容区里，
                                 * 内容区底边正好是状态栏顶边，因此这里用减去状态栏后的局部值
                                 * （= `OrdoLayout.fabGlow`，见 Tokens 的 fabContentInset 推导）。
                                 * 柔光本身用 requiredSize 溢出边界，不参与布局，所以不会把按钮往里推。
                                 */
                                .padding(end = OrdoSpace.xl, bottom = OrdoLayout.fabContentInset),
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

        /* 新建待办浮层与长按菜单不在这里：它们与快加号同处列表区（见上），
           保证"再点一次加号"能重新聚焦、菜单展开时点加号能收起菜单 */

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

/**
 * 状态栏：左侧计数 + 右侧**本机存储标识**。
 *
 * v1.4（彻底删除云同步）起这里不再有同步指示与刷新控件：应用是纯本地的，
 * 「同步中 / 已同步 / 同步失败」这些状态与文案都已删除。
 */
@Composable
private fun StatusBar(state: UiState) {
    val colors = OrdoTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .height(OrdoLayout.touchTarget)
            .padding(horizontal = OrdoSpace.l),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = stringResource(R.string.status_counts, state.totalCount, state.doneCount),
            style = OrdoTheme.type.caption,
            color = colors.textSecondary,
        )
        Spacer(Modifier.weight(1f))
        Text(
            text = stringResource(R.string.status_local_only),
            style = OrdoTheme.type.caption,
            color = colors.textTertiary,
        )
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
