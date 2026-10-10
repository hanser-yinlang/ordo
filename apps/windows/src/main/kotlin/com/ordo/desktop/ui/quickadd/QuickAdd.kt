package com.ordo.desktop.ui.quickadd

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import com.ordo.desktop.app.OrdoRoute
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.UiState
import com.ordo.desktop.ui.common.OrdoIcons
import com.ordo.desktop.ui.common.OrdoMenuIcons
import com.ordo.desktop.ui.common.OrdoTextField
import com.ordo.desktop.ui.common.detectPressGesture
import com.ordo.desktop.ui.theme.LocalOrdoReduceMotion
import com.ordo.desktop.ui.theme.OrdoMotion
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSize
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.motionMillis
import com.ordo.desktop.ui.theme.ordoColors
import kotlinx.coroutines.delay

private enum class NamePrompt { PROJECT, AREA, HEADING }

/**
 * 快加号按钮的视觉状态(可测:旋转角与缩放都由状态算出,不藏在动画里)。
 *
 * 04-UI规范 §5.2:菜单展开时按钮**旋转 45°**;按压 scale → 0.96(90ms);
 * 长按到 400ms 轻微放大到 1.06 并保持。
 */
object QuickAddVisual {

    /** 菜单展开时的旋转角(「+」变「×」) */
    const val OPEN_ROTATION = 45f

    fun rotation(menuOpen: Boolean): Float = if (menuOpen) OPEN_ROTATION else 0f

    fun scale(pressed: Boolean, armed: Boolean): Float = when {
        armed -> ARMED_SCALE
        pressed -> PRESS_SCALE
        else -> 1f
    }

    const val PRESS_SCALE = 0.96f
    const val ARMED_SCALE = 1.06f
}

/**
 * 快加号集群(04-UI规范 §5.2「重构:去掉多余元素」)。
 *
 * **只有一个** 56dp 圆形按钮,accent 填充 + 白色「+」+ 8dp 投影;
 * 过去与它叠压的那个 28dp 白色折叠箭头按钮已经**删除**(客户实测反馈:多余元素)。
 *
 * | 手势 | 行为 |
 * |---|---|
 * | 单击 | 打开行内输入行(聚焦 + 列表滚到输入行) |
 * | 长按 400ms | 展开快捷菜单(新建待办 / 项目 / 区域 / 标题),从按钮左上方弹出 |
 * | 菜单展开中单击 | 收起菜单,按钮转回 0° |
 */
@Composable
fun QuickAdd(state: UiState, vm: OrdoViewModel, modifier: Modifier = Modifier) {
    var prompt by remember { mutableStateOf<NamePrompt?>(null) }
    var pressed by remember { mutableStateOf(false) }
    var armed by remember { mutableStateOf(false) }

    Box(modifier.fillMaxSize(), contentAlignment = Alignment.BottomEnd) {
        Column(
            Modifier.padding(end = OrdoSpace.xl, bottom = OrdoSpace.xl),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(OrdoSpace.s)
        ) {
            // 菜单从按钮左上方弹出(面板结束边与按钮右缘对齐,向上生长)
            AnimatedVisibility(
                visible = state.quickAddMenuOpen,
                enter = fadeIn(tween(motionMillis(180))) + scaleIn(
                    initialScale = 0.9f,
                    animationSpec = tween(motionMillis(180))
                ),
                exit = fadeOut(tween(motionMillis(140))) + scaleOut(
                    targetScale = 0.9f,
                    animationSpec = tween(motionMillis(140))
                )
            ) {
                QuickAddMenu(state = state) { action ->
                    vm.setQuickAddMenu(false)
                    when (action) {
                        MenuAction.TODO -> vm.openComposer()
                        MenuAction.PROJECT -> prompt = NamePrompt.PROJECT
                        MenuAction.AREA -> prompt = NamePrompt.AREA
                        MenuAction.HEADING -> prompt = NamePrompt.HEADING
                    }
                }
            }
            OrdoFab(
                menuOpen = state.quickAddMenuOpen,
                pressed = pressed,
                armed = armed,
                onPressedChange = { pressed = it },
                onArmedChange = { armed = it },
                onClick = {
                    when (QuickAddGesture.clickAction(state.quickAddMenuOpen)) {
                        // 菜单展开中单击 → 收起(按钮转回 0°)
                        QuickAddAction.CLOSE_MENU -> vm.setQuickAddMenu(false)
                        // 常态单击 → 打开行内输入行
                        else -> vm.openComposer()
                    }
                },
                onLongPress = {
                    if (QuickAddGesture.longPressAction(state.quickAddMenuOpen) == QuickAddAction.EXPAND_MENU) {
                        vm.setQuickAddMenu(true)
                    }
                }            )
        }

        prompt?.let { kind ->
            NameInputDialog(
                title = when (kind) {
                    NamePrompt.PROJECT -> "新建项目"
                    NamePrompt.AREA -> "新建区域"
                    NamePrompt.HEADING -> "新建标题"
                },
                placeholder = "名称,回车确认",
                onConfirm = { name ->
                    when (kind) {
                        NamePrompt.PROJECT -> vm.createProject(name, (state.route as? OrdoRoute.Area)?.id)
                        NamePrompt.AREA -> vm.createArea(name)
                        NamePrompt.HEADING -> (state.route as? OrdoRoute.Project)?.let { vm.createHeading(it.id, name) }
                    }
                    prompt = null
                },
                onDismiss = { prompt = null }
            )
        }
    }
}

/** 菜单项的动作(与 [NamePrompt] 对应,便于单测直接断言分支) */
private enum class MenuAction { TODO, PROJECT, AREA, HEADING }

/**
 * 快加号"单击 / 长按"的分支判定(§5.2 交互分工)。
 *
 * 单独抽成纯函数,是为了让"单击开输入行、长按开菜单、菜单展开中单击收起"这三条
 * 能被直接断言,而不是只能靠人手点。
 */
object QuickAddGesture {

    /** 单击的落点 */
    fun clickAction(menuOpen: Boolean): QuickAddAction =
        if (menuOpen) QuickAddAction.CLOSE_MENU else QuickAddAction.OPEN_COMPOSER

    /** 长按(400ms)的落点:展开菜单;已经展开时保持展开,不来回切换 */
    fun longPressAction(menuOpen: Boolean): QuickAddAction =
        if (menuOpen) QuickAddAction.KEEP_MENU else QuickAddAction.EXPAND_MENU
}

/** 一次快加号手势对应的界面动作 */
enum class QuickAddAction { OPEN_COMPOSER, CLOSE_MENU, EXPAND_MENU, KEEP_MENU }

/**
 * 快捷菜单的视觉规格(04-UI规范 §5.2「菜单项图标」),数值逐条对齐参照原型 `things-clone`
 * 的 `.pop` / `.pop-item`(最小宽 208 / radius 12 / 1px 描边 / 条目 padding 9 / gap 8 / radius 7 / 13.5px)。
 *
 * 抽成常量而不是写在 Modifier 里:既让四条菜单项的间距不会各自漂移,也让"最小宽 ≥208、条目高 ≥44"
 * 这类硬指标可以被单测直接断言。
 */
object QuickAddMenuSpec {

    /** 面板最小宽(§5.2 ≥208;原型 `.pop { min-width: 208px }`)。四项文案固定,所以它同时就是实际宽 */
    val MIN_WIDTH = 208.dp

    /** 面板圆角(原型 `border-radius: 12px`) */
    val PANEL_RADIUS = 12.dp

    /** 面板内边距(原型 `padding: 5px`) */
    val PANEL_PADDING = 5.dp

    /** 面板描边:1px hairline */
    val HAIRLINE = 1.dp

    /** 面板投影(与快加号按钮同一档 8dp) */
    val PANEL_ELEVATION = 8.dp

    /** 条目高(§5.2 ≥44:触控目标够大比照抄原型的 28 更重要) */
    val ITEM_HEIGHT = 44.dp

    /** 条目圆角(原型 `border-radius: 7px`) */
    val ITEM_RADIUS = 7.dp

    /** 条目左/右内边距(原型 `padding: 6px 9px`) */
    val ITEM_PADDING = 9.dp

    /** 图标与文字间距(原型 `gap: 8px`) */
    val ICON_TEXT_GAP = 8.dp

    /** 图标渲染尺寸(原型 `.pop-item .ico { 16px }`;20×20 viewBox 等比缩到 16dp) */
    val ICON_SIZE = 16.dp
}

/**
 * 快捷菜单面板:菜单项逐个错位 40ms 淡入并上移 6px(§5.2 动效表)。
 *
 * 从按钮**左上方**弹出:面板宽度按 [QuickAddMenuSpec.MIN_WIDTH] 起,在按钮所在 Column 里右对齐(End),
 * 因此它的右下角贴着按钮的左上角。四项前导图标见 [OrdoMenuIcons]。
 */
@Composable
private fun QuickAddMenu(
    state: UiState,
    onAction: (MenuAction) -> Unit
) {
    val colors = ordoColors
    val reduceMotion = LocalOrdoReduceMotion.current
    val hasHeading = state.route is OrdoRoute.Project
    val shape = RoundedCornerShape(QuickAddMenuSpec.PANEL_RADIUS)

    Column(
        Modifier
            // 宽度 = 最宽那一行的内容,但兜住 208 的下限(参照原型 `.pop{min-width:208px}` 的生效宽度)。
            // 不能只写 widthIn(min=208):条目里的 fillMaxWidth 会把它撑到整窗宽。
            .width(IntrinsicSize.Max)
            .widthIn(min = QuickAddMenuSpec.MIN_WIDTH)
            .shadow(QuickAddMenuSpec.PANEL_ELEVATION, shape)
            .clip(shape)
            .background(colors.surface)
            .border(QuickAddMenuSpec.HAIRLINE, colors.hairline, shape)
            .padding(QuickAddMenuSpec.PANEL_PADDING)
    ) {
        StaggeredItem(index = 0, reduceMotion = reduceMotion) {
            MenuItem(OrdoMenuIcons.Todo, "新建待办", "Ctrl+N") { onAction(MenuAction.TODO) }
        }
        StaggeredItem(index = 1, reduceMotion = reduceMotion) {
            // H(两竖 + 一横):以前这里错用了 OrdoIcons.Area(文件夹)
            MenuItem(OrdoMenuIcons.Project, "新建项目", null) { onAction(MenuAction.PROJECT) }
        }
        StaggeredItem(index = 2, reduceMotion = reduceMotion) {
            MenuItem(OrdoMenuIcons.Area, "新建区域", null) { onAction(MenuAction.AREA) }
        }
        if (hasHeading) {
            StaggeredItem(index = 3, reduceMotion = reduceMotion) {
                // ≡(三横线):与「H」区分,是 Ordo 自有项(参照原型没有)
                MenuItem(OrdoMenuIcons.Heading, "新建标题", null) { onAction(MenuAction.HEADING) }
            }
        }
    }
}

/** 错位淡入:第 i 项延迟 i×40ms,淡入并上移 6px */
@Composable
private fun StaggeredItem(index: Int, reduceMotion: Boolean, content: @Composable () -> Unit) {
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(index) {
        if (reduceMotion) {
            shown = true
        } else {
            delay(index * STAGGER_MILLIS)
            shown = true
        }
    }
    val alpha by animateFloatAsState(
        targetValue = if (shown) 1f else 0f,
        animationSpec = tween(motionMillis(160)),
        label = "quickAddItemAlpha$index"
    )
    Box(
        Modifier
            .alpha(alpha)
            .offset(y = ((1f - alpha) * 6f).dp)
    ) {
        content()
    }
}

/** 菜单项错位间隔(§5.2:逐个错位 40ms) */
private const val STAGGER_MILLIS = 40L

/**
 * 菜单条目(§5.2):高 [QuickAddMenuSpec.ITEM_HEIGHT]、radius 7、左内边距 9、图标↔文字 8、
 * 字号 13.5;悬停与按下**都**用 `rowSelected`(本端令牌名是 `colors.selected`);
 * 快捷键提示只有「新建待办」有(由调用方传 shortcut,其余项传 null)。
 */
@Composable
private fun MenuItem(icon: ImageVector, label: String, shortcut: String?, onClick: () -> Unit) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val pressed by interaction.collectIsPressedAsState()
    val shape = RoundedCornerShape(QuickAddMenuSpec.ITEM_RADIUS)
    Row(
        Modifier
            .fillMaxWidth()
            .height(QuickAddMenuSpec.ITEM_HEIGHT)
            .clip(shape)
            .background(if (hovered || pressed) colors.selected else Color.Transparent, shape)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .padding(horizontal = QuickAddMenuSpec.ITEM_PADDING),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(QuickAddMenuSpec.ICON_SIZE)
        )
        Spacer(Modifier.width(QuickAddMenuSpec.ICON_TEXT_GAP))
        Text(label, style = OrdoType.menuItem, color = colors.textPrimary)
        Spacer(Modifier.weight(1f))
        if (shortcut != null) Text(shortcut, style = OrdoType.micro, color = colors.textTertiary)
    }
}

/**
 * 唯一的圆形快加号按钮:直径 56、accent 底 + 白色加号、8dp 投影。
 *
 * 手势由 [detectPressGesture] 统一判定(单击 / 长按 400ms 共用一套阈值):
 *  - 单击 → [onClick](开输入行,或菜单展开时收起菜单);
 *  - 按住满 400ms → [onLongPress](展开菜单),同时按钮放大到 1.06 并保持;
 *  - 菜单展开时按钮旋转 45°(「+」变「×」)。
 */
@Composable
private fun OrdoFab(
    menuOpen: Boolean,
    pressed: Boolean,
    armed: Boolean,
    onPressedChange: (Boolean) -> Unit,
    onArmedChange: (Boolean) -> Unit,
    onClick: () -> Unit,
    onLongPress: () -> Unit
) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()

    val rotation by animateFloatAsState(
        targetValue = QuickAddVisual.rotation(menuOpen),
        animationSpec = tween(motionMillis(OrdoMotion.BASE)),
        label = "quickAddRotation"
    )
    val scale by animateFloatAsState(
        targetValue = QuickAddVisual.scale(pressed, armed),
        animationSpec = tween(motionMillis(if (armed) 120 else 90)),
        label = "quickAddScale"
    )

    Box(
        Modifier
            .size(OrdoSize.fab)
            .scale(scale)
            // 8dp 投影(§5.2)
            .shadow(8.dp, CircleShape)
            .clip(CircleShape)
            .background(if (hovered) colors.accent.copy(alpha = 0.92f) else colors.accent, CircleShape)
            .pointerInput(Unit) {
                detectPressGesture(
                    onPressedChange = onPressedChange,
                    onArmedChange = onArmedChange,
                    // 位置参数用不上:按钮只有一个圆形热点,长按落点即按钮内部
                    onLongPress = { onLongPress() },
                    onClick = onClick
                )
            },
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = OrdoIcons.Add,
            contentDescription = if (menuOpen) "收起新建菜单" else "新建待办",
            tint = Color.White,
            modifier = Modifier
                .size(24.dp)
                .rotate(rotation)
        )
    }
}

/** 通用名称输入弹窗(新建项目 / 区域 / 标题) */
@Composable
fun NameInputDialog(
    title: String,
    placeholder: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit
) {
    val colors = ordoColors
    var value by remember { mutableStateOf("") }
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.28f))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { onDismiss() },
        contentAlignment = Alignment.Center
    ) {
        Column(
            Modifier
                .widthIn(min = 320.dp, max = 420.dp)
                .clip(RoundedCornerShape(OrdoRadius.card))
                .background(colors.surface)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                .padding(OrdoSpace.l)
        ) {
            Text(title, style = OrdoType.title, color = colors.textPrimary)
            Spacer(Modifier.height(OrdoSpace.m))
            OrdoTextField(
                value = value,
                onValueChange = { value = it },
                placeholder = placeholder,
                textStyle = OrdoType.body,
                modifier = Modifier
                    .focusRequester(focusRequester)
                    .clip(RoundedCornerShape(OrdoRadius.row))
                    .background(colors.canvas)
                    .padding(OrdoSpace.m),
                onEnter = { if (value.isNotBlank()) onConfirm(value.trim()) },
                onEscape = onDismiss
            )
            Spacer(Modifier.height(OrdoSpace.s))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                com.ordo.desktop.ui.common.OrdoTextButton("取消", onDismiss)
                Spacer(Modifier.width(OrdoSpace.s))
                com.ordo.desktop.ui.common.OrdoTextButton(
                    "确定",
                    { if (value.isNotBlank()) onConfirm(value.trim()) },
                    emphasized = true
                )
            }
        }
    }
}
