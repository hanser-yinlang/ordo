package com.ordo.android.ui.shell

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
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
import com.ordo.android.auth.AuthStage
import com.ordo.android.nav.OrdoNavHost
import com.ordo.android.nav.Routes
import com.ordo.android.sync.RefreshController
import com.ordo.android.sync.RefreshLabel
import com.ordo.android.sync.RefreshTone
import com.ordo.android.sync.RefreshUiState
import com.ordo.android.ui.auth.LoginScreen
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
 * 应用根：**登录门禁**（契约 §7.6.4）。
 *
 * ```
 * LOADING → 空白画布（正在读会话，不闪一下登录页）
 * LOGIN   → 登录页（登录 / 注册 / 游客登录 三个入口）
 * MAIN    → 三栏骨架
 * ```
 * 登录成功：卡片 fade out 160ms → 主界面 fade in 220ms（UI §5.1）。
 */
@Composable
fun OrdoRoot(
    state: UiState,
    vm: OrdoViewModel,
    deepLink: String?,
    onDeepLinkConsumed: () -> Unit,
) {
    AnimatedContent(
        targetState = state.auth.stage,
        transitionSpec = {
            fadeIn(tween(OrdoMotionPageFadeIn)) togetherWith fadeOut(tween(OrdoMotionPageFadeOut))
        },
        label = "auth-gate",
    ) { stage ->
        when (stage) {
            AuthStage.LOADING -> Box(
                Modifier
                    .fillMaxSize()
                    .background(OrdoTheme.colors.canvas),
            )

            AuthStage.LOGIN -> LoginScreen(state = state.auth, vm = vm)

            AuthStage.MAIN -> MainShell(
                state = state,
                vm = vm,
                deepLink = deepLink,
                onDeepLinkConsumed = onDeepLinkConsumed,
            )
        }
    }
}

private const val OrdoMotionPageFadeIn = 220
private const val OrdoMotionPageFadeOut = 160

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
                                .padding(OrdoSpace.xl),
                        )
                    }
                }
                StatusBar(state = state, onRefresh = vm::refresh)
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
 * 状态栏（UI §5.3）：左侧计数 + 右侧**刷新控件**（28dp 圆形图标按钮 + 状态文字）。
 *
 * 看到的行为：
 *  - 同步中：图标**连续旋转**（每圈 900ms，linear，持续到同步结束）+「同步中…」；
 *  - 成功：停转 + 图标转 success 色（320ms 过渡）+「已同步」，1.4s 后回常态；
 *  - 失败：图标 danger 色 +「同步失败，点击重试」（常驻，直到重试）；
 *  - 同步进行中与结束后 1.4s 内按钮禁用（防抖）。
 */
@Composable
private fun StatusBar(state: UiState, onRefresh: () -> Unit) {
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
        RefreshControl(state = state.refresh, onRefresh = onRefresh)
    }
}

@Composable
private fun RefreshControl(state: RefreshUiState, onRefresh: () -> Unit) {
    val colors = OrdoTheme.colors

    val tint by animateColorAsState(
        targetValue = when (state.tone) {
            RefreshTone.NEUTRAL -> colors.textTertiary
            RefreshTone.ACCENT -> colors.accent
            RefreshTone.SUCCESS -> colors.success
            RefreshTone.DANGER -> colors.danger
        },
        animationSpec = tween(RefreshController.SUCCESS_FLASH_MILLIS),
        label = "refresh-tint",
    )

    // 连续旋转：每圈 900ms、linear，直到同步结束（spinning=false 时停转并归零）
    val rotation = remember { Animatable(0f) }
    val stopMillis = OrdoTheme.fast
    LaunchedEffect(state.spinning) {
        if (!state.spinning) {
            rotation.animateTo(0f, tween(stopMillis))
            return@LaunchedEffect
        }
        while (true) {
            rotation.snapTo(0f)
            rotation.animateTo(
                targetValue = 360f,
                animationSpec = tween(RefreshController.ROTATION_PERIOD_MILLIS, easing = LinearEasing),
            )
        }
    }

    val label = stringResource(
        when (state.label) {
            RefreshLabel.SYNCING -> R.string.sync_syncing_ellipsis
            RefreshLabel.SYNCED -> R.string.sync_idle
            RefreshLabel.IDLE -> R.string.sync_idle
            RefreshLabel.FAILED -> R.string.sync_failed_retry
            RefreshLabel.OFFLINE -> R.string.sync_offline_retry
            RefreshLabel.NEVER -> R.string.sync_never
            RefreshLabel.UNSYNCED -> R.string.sync_unsynced
        },
    )
    val labelColor = when (state.tone) {
        RefreshTone.DANGER -> colors.danger
        RefreshTone.SUCCESS -> colors.success
        else -> colors.textSecondary
    }

    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(OrdoRadius.pill))
            .clickable(enabled = state.enabled, onClick = onRefresh)
            .padding(horizontal = OrdoSpace.xs)
            .height(OrdoLayout.touchTarget),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(28.dp)
                .clip(CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            OrdoIcon(
                kind = OrdoIconKind.Refresh,
                size = 16.dp,
                tint = tint,
                strokeWidth = 1.6f,
                modifier = Modifier.rotate(rotation.value),
            )
        }
        Spacer(Modifier.width(OrdoSpace.xs))
        Text(text = label, style = OrdoTheme.type.caption, color = labelColor)
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
