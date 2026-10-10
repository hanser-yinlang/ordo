package com.ordo.android.ui.quickadd

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.ordo.android.R
import com.ordo.android.ui.common.OrdoIcon
import com.ordo.android.ui.common.OrdoIconKind
import com.ordo.android.ui.common.OrdoScrim
import com.ordo.android.ui.common.OrdoTextField
import com.ordo.android.ui.gesture.FabGesture
import com.ordo.android.ui.gesture.OrdoGesture
import com.ordo.android.ui.gesture.QuickAddGesture
import com.ordo.android.ui.theme.OrdoElevation
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoMotion
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.OrdoViewModel
import com.ordo.android.vm.UiState
import kotlinx.coroutines.withTimeoutOrNull

/**
 * 快加号（UI §5.2 重构）。
 *
 * **只保留一个圆形按钮**（直径 56，accent 底 + 白色「+」，8dp 投影）：
 *   单击            → 打开行内输入行（聚焦 + 弹软键盘）
 *   **长按 400ms** → 从按钮左上方弹出快捷菜单，按钮旋转 45°（「+」变「×」）
 *   菜单展开中单击  → 收起菜单，按钮转回 0°
 *
 * 长按时长由 [OrdoGesture.LONG_PRESS_MILLIS] 定义：Compose 默认的 `detectTapGestures`
 * 用系统长按超时（≈500ms），**不符合**规范，因此这里自己跑指针循环。
 */
@Composable
fun QuickAddFab(
    menuOpen: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OrdoTheme.colors
    var pressed by remember { mutableStateOf(false) }
    var longPressReached by remember { mutableStateOf(false) }

    // 按压 scale → 0.96（90ms）；长按到 400ms 轻微放大到 1.06 并保持
    val scale by animateFloatAsState(
        targetValue = QuickAddGesture.scale(pressed, longPressReached),
        animationSpec = tween(OrdoTheme.fast, easing = OrdoMotion.easing),
        label = "fab-scale",
    )
    // 菜单展开时按钮旋转 45°；收起反向 140ms
    val rotation by animateFloatAsState(
        targetValue = QuickAddGesture.rotationDegrees(menuOpen),
        animationSpec = tween(
            if (menuOpen) OrdoMotion.MENU_POP_IN else OrdoMotion.MENU_COLLAPSE,
            easing = OrdoMotion.easing,
        ),
        label = "fab-rotation",
    )

    Box(
        modifier = modifier
            .size(OrdoLayout.fabSize)
            .scale(scale)
            .shadow(OrdoElevation.fab, CircleShape)
            .clip(CircleShape)
            .background(colors.accent)
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    pressed = true
                    longPressReached = false
                    var moved = 0f

                    // 400ms 内等到抬起 → "单击"分支；超时（null）→ "长按"分支
                    val released: Boolean? = withTimeoutOrNull(OrdoGesture.LONG_PRESS_MILLIS) {
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: continue
                            moved += (change.position - change.previousPosition).getDistance()
                            if (!change.pressed) break
                        }
                        true
                    }

                    if (released == null) {
                        // 长按到点：放大保持 + 展开菜单，等抬手再复位
                        longPressReached = true
                        onLongClick()
                        waitForUpOrCancellation()
                    } else {
                        // 位移 <6px 才算单击（长按阈值判定与纯函数同源）
                        if (QuickAddGesture.classify(holdMillis = 0L, movedPx = moved) == FabGesture.CLICK) {
                            onClick()
                        }
                    }
                    pressed = false
                    longPressReached = false
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        OrdoIcon(
            kind = OrdoIconKind.Plus,
            size = 22.dp,
            tint = colors.onAccent,
            strokeWidth = 2.1f,
            modifier = Modifier.rotate(rotation),
        )
    }
}

/**
 * 快加号长按菜单（UI §5.2）：新建待办 / 项目 / 区域 / 标题。
 *
 * 表现：
 *  - 从按钮**左上方**弹出（面板底边压在按钮上方、右缘对齐按钮右侧）；
 *  - 面板 scale 0.9→1 + alpha 0→1（180ms）；菜单项**逐个错位 40ms** 淡入并上移 6dp；
 *  - 收起反向 140ms；
 *  - 遮罩点击 / 返回键收起菜单；**按钮自身在更上层**，因此"菜单展开中单击按钮"
 *    命中的是按钮（收起菜单 + 转回 0°），不会被遮罩吞掉。
 */
@Composable
fun QuickAddMenuLayer(
    state: UiState,
    vm: OrdoViewModel,
    panelModifier: Modifier = Modifier,
) {
    val visible = state.quickAddMenuOpen
    var projectDraft by remember { mutableStateOf("") }
    var areaDraft by remember { mutableStateOf("") }
    var headingDraft by remember { mutableStateOf("") }
    var mode by remember { mutableStateOf(Mode.MENU) }

    LaunchedEffect(visible) {
        if (!visible) mode = Mode.MENU
    }

    if (visible) {
        OrdoScrim(onClick = { vm.openQuickAddMenu(false) })
    }
    BackHandler(enabled = visible) { vm.openQuickAddMenu(false) }

    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomEnd) {
        AnimatedVisibility(
            visible = visible,
            modifier = panelModifier,
            enter = fadeIn(tween(OrdoTheme.base)) +
                scaleIn(
                    initialScale = 0.9f,
                    animationSpec = tween(OrdoMotion.MENU_POP_IN, easing = OrdoMotion.easing),
                    transformOrigin = TransformOrigin(1f, 1f),
                ),
            exit = fadeOut(tween(OrdoMotion.MENU_COLLAPSE)) +
                scaleOut(
                    targetScale = 0.9f,
                    animationSpec = tween(OrdoMotion.MENU_COLLAPSE, easing = OrdoMotion.easing),
                    transformOrigin = TransformOrigin(1f, 1f),
                ),
        ) {
            Column(
                Modifier
                    .width(OrdoLayout.quickAddMenuWidth)
                    .shadow(OrdoElevation.popover, RoundedCornerShape(OrdoRadius.card))
                    .clip(RoundedCornerShape(OrdoRadius.card))
                    .background(OrdoTheme.colors.surface)
                    .padding(OrdoSpace.s),
            ) {
                when (mode) {
                    Mode.MENU -> {
                        StaggeredItem(0) {
                            MenuItem(OrdoIconKind.Anytime, stringResource(R.string.quickadd_todo)) {
                                vm.openQuickAddMenu(false)
                                vm.openComposer(vm.composerTarget())
                            }
                        }
                        StaggeredItem(1) {
                            MenuItem(OrdoIconKind.Project, stringResource(R.string.quickadd_project)) {
                                mode = Mode.PROJECT
                            }
                        }
                        StaggeredItem(2) {
                            MenuItem(OrdoIconKind.Area, stringResource(R.string.quickadd_area)) {
                                mode = Mode.AREA
                            }
                        }
                        StaggeredItem(3) {
                            MenuItem(OrdoIconKind.Heading, stringResource(R.string.quickadd_heading)) {
                                mode = Mode.HEADING
                            }
                        }
                    }

                    Mode.PROJECT -> QuickAddInput(
                        hint = stringResource(R.string.quickadd_project_hint),
                        value = projectDraft,
                        onValueChange = { projectDraft = it },
                        onSubmit = {
                            vm.createProject(projectDraft, currentAreaId(state))
                            projectDraft = ""
                            vm.openQuickAddMenu(false)
                        },
                    )

                    Mode.AREA -> QuickAddInput(
                        hint = stringResource(R.string.quickadd_area_hint),
                        value = areaDraft,
                        onValueChange = { areaDraft = it },
                        onSubmit = {
                            vm.createArea(areaDraft)
                            areaDraft = ""
                            vm.openQuickAddMenu(false)
                        },
                    )

                    Mode.HEADING -> QuickAddInput(
                        hint = stringResource(R.string.composer_heading_hint),
                        value = headingDraft,
                        onValueChange = { headingDraft = it },
                        onSubmit = {
                            vm.createHeadingFromQuickAdd(headingDraft)
                            headingDraft = ""
                        },
                    )
                }
            }
        }
    }
}

private enum class Mode { MENU, PROJECT, AREA, HEADING }

/** 菜单项逐个错位 40ms 淡入并上移 6dp（UI §5.2 动效表） */
@Composable
private fun StaggeredItem(index: Int, content: @Composable () -> Unit) {
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { shown = true }
    val progress by animateFloatAsState(
        targetValue = if (shown) 1f else 0f,
        animationSpec = tween(
            durationMillis = OrdoMotion.MENU_POP_IN,
            delayMillis = index * OrdoMotion.MENU_ITEM_STAGGER,
            easing = OrdoMotion.easing,
        ),
        label = "menu-item-$index",
    )
    Box(
        Modifier
            .fillMaxWidth()
            .offset { IntOffset(0, ((1f - progress) * 6f * density).toInt()) }
            .alpha(progress),
    ) {
        content()
    }
}

@Composable
private fun QuickAddInput(
    hint: String,
    value: String,
    onValueChange: (String) -> Unit,
    onSubmit: () -> Unit,
) {
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        withFrameNanos { }
        runCatching { focusRequester.requestFocus() }
    }
    Text(
        text = hint,
        style = OrdoTheme.type.micro,
        color = OrdoTheme.colors.textTertiary,
    )
    Spacer(Modifier.height(OrdoSpace.s))
    OrdoTextField(
        value = value,
        onValueChange = onValueChange,
        placeholder = hint,
        modifier = Modifier.fillMaxWidth(),
        focusRequester = focusRequester,
        onSubmit = onSubmit,
    )
}

private fun currentAreaId(state: UiState): String? = when {
    state.routeKey.startsWith("area/") -> state.routeKey.removePrefix("area/")
    state.projectHeader != null -> state.projectHeader.areaName?.let { name ->
        state.areas.firstOrNull { it.name == name }?.id
    }
    else -> null
}

@Composable
private fun MenuItem(icon: OrdoIconKind, label: String, onClick: () -> Unit) {
    val colors = OrdoTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OrdoRadius.row))
            .clickable(onClick = onClick)
            .padding(vertical = OrdoSpace.m, horizontal = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OrdoIcon(icon, size = 16.dp, tint = colors.textSecondary)
        Spacer(Modifier.width(OrdoSpace.s))
        Text(text = label, style = OrdoTheme.type.body, color = colors.textPrimary)
    }
}

/**
 * 新建待办输入浮层：标题里的日期与 #标签 由 shared:core 的 NLP 解析（契约 §5）。
 *
 * 可见反馈三件套（实测缺陷「点加号没反应」的修复点）：
 *   1. 打开后**自动聚焦 + 弹软键盘**（`focusRequest` 每点一次加号递增，重复点击也重新聚焦）；
 *   2. 软键盘弹起时不遮挡输入卡片（根骨架已 `imePadding()`，这里再声明一次，insets 会被消费掉不会叠加）；
 *   3. 返回键 / Esc 关闭浮层且不产生空待办（空标题只关闭，草稿直接丢弃）。
 *
 * @param modifier 加在输入卡片上，供调用方为右下角快加号留出空档（见 `ui/shell/OrdoShell.kt`）
 */
@Composable
fun ComposerSheet(state: UiState, vm: OrdoViewModel, modifier: Modifier = Modifier) {
    val composer = state.composer
    val focusRequester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current

    // key = focusRequest：第一次打开、以及"已打开时再点加号"都会重新执行，
    // 每次都把焦点交给输入框并弹起软键盘 —— 重复点击不再是无操作。
    LaunchedEffect(composer.focusRequest) {
        withFrameNanos { } // 等第一帧布局完成，FocusRequester 已绑定到节点
        runCatching { focusRequester.requestFocus() }
        keyboard?.show()
    }

    // 返回键 = 关闭浮层（而不是退出应用 / 回退清单），不产生空待办
    BackHandler { vm.closeComposer() }

    Box(
        Modifier
            .fillMaxSize()
            .onPreviewKeyEvent { event ->
                // 硬件键盘的 Esc：key 事件沿焦点路径冒泡到浮层根节点
                if (event.type == KeyEventType.KeyUp && event.key == Key.Escape) {
                    vm.closeComposer()
                    true
                } else {
                    false
                }
            },
    ) {
        OrdoScrim(onClick = vm::closeComposer)
        Column(
            Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter)
                .padding(OrdoSpace.l)
                .imePadding()
                .then(modifier),
        ) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(OrdoRadius.sheet))
                    .background(OrdoTheme.colors.surface)
                    .padding(OrdoSpace.m),
            ) {
                Text(
                    text = state.title,
                    style = OrdoTheme.type.micro,
                    color = OrdoTheme.colors.textTertiary,
                )
                Spacer(Modifier.height(OrdoSpace.s))
                OrdoTextField(
                    value = composer.draft,
                    onValueChange = vm::updateComposerDraft,
                    placeholder = stringResource(R.string.composer_hint),
                    modifier = Modifier.fillMaxWidth(),
                    focusRequester = focusRequester,
                    onSubmit = vm::submitComposer,
                )
            }
        }
    }
}
