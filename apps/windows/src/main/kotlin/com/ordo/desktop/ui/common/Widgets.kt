package com.ordo.desktop.ui.common

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import com.ordo.desktop.ui.theme.OrdoMotion
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSize
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.motionMillis
import com.ordo.desktop.ui.theme.ordoColors

/**
 * 全局"正在输入"标记。
 *
 * 用于让 `1–6`、`Space`、单字母等全局快捷键在文本框获得焦点时让路(04-UI规范 §6)。
 */
object OrdoInputFocus {
    private var count = 0

    val isTyping: Boolean get() = count > 0

    fun gain() {
        count += 1
    }

    fun lose() {
        if (count > 0) count -= 1
    }
}

/** 基础文本输入:统一焦点环、占位符与 Enter 行为 */
@Composable
fun OrdoTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    textStyle: TextStyle = OrdoType.body,
    singleLine: Boolean = true,
    onEnter: (() -> Unit)? = null,
    onEscape: (() -> Unit)? = null,
    enabled: Boolean = true,
    cursorColor: Color? = null
) {
    val colors = ordoColors
    val focused = remember { mutableStateOf(false) }
    val interaction = remember { MutableInteractionSource() }

    DisposableEffect(Unit) {
        onDispose { if (focused.value) OrdoInputFocus.lose() }
    }

    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        enabled = enabled,
        singleLine = singleLine,
        textStyle = textStyle.copy(color = colors.textPrimary),
        cursorBrush = SolidColor(cursorColor ?: colors.accent),
        interactionSource = interaction,
        modifier = modifier
            .onFocusChanged { state ->
                if (state.isFocused != focused.value) {
                    focused.value = state.isFocused
                    if (state.isFocused) OrdoInputFocus.gain() else OrdoInputFocus.lose()
                }
            }
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                when (event.key) {
                    Key.Enter -> {
                        if (onEnter != null) {
                            onEnter()
                            true
                        } else false
                    }
                    Key.Escape -> {
                        if (onEscape != null) {
                            onEscape()
                            true
                        } else false
                    }
                    else -> false
                }
            },
        decorationBox = { inner ->
            Box(contentAlignment = Alignment.CenterStart) {
                if (value.isEmpty() && placeholder.isNotEmpty()) {
                    Text(placeholder, style = textStyle, color = colors.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                inner()
            }
        }
    )
}

/** 图标按钮:桌面端最小点击区 32×32(04-UI规范 §8) */
@Composable
fun OrdoIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = OrdoSize.touchTarget,
    iconSize: Dp = OrdoSize.icon,
    tint: Color? = null,
    enabled: Boolean = true,
    background: Color? = null
) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val base = tint ?: colors.textSecondary
    Box(
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .then(if (background != null) Modifier.background(background, RoundedCornerShape(OrdoRadius.row)) else Modifier)
            .then(if (hovered && enabled) Modifier.background(colors.hover, RoundedCornerShape(OrdoRadius.row)) else Modifier)
            .clickable(interactionSource = interaction, indication = null, enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = if (enabled) base else colors.textTertiary,
            modifier = Modifier.size(iconSize)
        )
    }
}

/** 文字按钮(胶囊) */
@Composable
fun OrdoTextButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    emphasized: Boolean = false,
    danger: Boolean = false,
    enabled: Boolean = true
) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val shape = RoundedCornerShape(OrdoRadius.pill)
    val bg = when {
        !enabled -> colors.chipBg
        emphasized -> colors.accent
        hovered -> colors.hover
        else -> Color.Transparent
    }
    val fg = when {
        !enabled -> colors.textTertiary
        danger -> colors.danger
        emphasized -> Color.White
        else -> colors.textPrimary
    }
    Box(
        modifier = modifier
            .clip(shape)
            .background(bg, shape)
            .border(1.dp, if (emphasized) Color.Transparent else colors.hairline, shape)
            .clickable(interactionSource = interaction, indication = null, enabled = enabled, onClick = onClick)
            .padding(horizontal = OrdoSpace.m, vertical = 6.dp)
            .defaultMinSize(minHeight = 24.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, style = OrdoType.caption, color = fg, maxLines = 1)
    }
}

/** 标签 chip(高 20,圆角 pill) */
@Composable
fun OrdoChip(text: String, modifier: Modifier = Modifier, onClick: (() -> Unit)? = null) {
    val colors = ordoColors
    val shape = RoundedCornerShape(OrdoRadius.pill)
    Box(
        modifier = modifier
            .height(OrdoSize.chip)
            .clip(shape)
            .background(if (onClick != null) colors.accentSoft else colors.chipBg, shape)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 6.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = text,
            style = OrdoType.micro,
            color = if (onClick != null) colors.accent else colors.chipText,
            maxLines = 1
        )
    }
}

/** 元信息 pill:图标 14 + 文字 13 */
@Composable
fun MetaPill(
    icon: ImageVector,
    text: String? = null,
    tint: Color? = null,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null
) {
    val colors = ordoColors
    val color = tint ?: colors.textSecondary
    Row(
        modifier = modifier
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp)
    ) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(OrdoSize.iconSm))
        if (text != null) {
            Text(text, style = OrdoType.caption, color = color, maxLines = 1)
        }
    }
}

/** 圆形复选框:未完成 1.6px 描边;完成填充主色并画出对勾(§4/§5) */
@Composable
fun OrdoCheckbox(
    checked: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    canceled: Boolean = false,
    size: Dp = OrdoSize.checkbox
) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val fill = animateFloatAsState(
        targetValue = if (checked) 1f else 0f,
        animationSpec = tween(motionMillis(OrdoMotion.BASE)),
        label = "checkboxFill"
    )
    val accent = if (canceled) colors.danger else colors.accent
    val strokeWidth = OrdoSize.checkboxStroke

    Canvas(
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(OrdoRadius.checkbox))
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
    ) {
        val radius = this.size.minDimension / 2f - strokeWidth.toPx() / 2f
        val center = Offset(this.size.width / 2f, this.size.height / 2f)
        val progress = fill.value

        if (progress < 1f) {
            drawCircle(
                color = if (hovered) accent else colors.checkboxStroke,
                radius = radius,
                center = center,
                style = Stroke(width = strokeWidth.toPx())
            )
        }
        if (progress > 0f) {
            drawCircle(color = accent, radius = radius * progress, center = center)
            if (progress > 0.35f) {
                val tickAlpha = ((progress - 0.35f) / 0.65f).coerceIn(0f, 1f)
                val w = this.size.width
                val h = this.size.height
                val path = Path().apply {
                    moveTo(w * 0.28f, h * 0.52f)
                    lineTo(w * 0.44f, h * 0.68f)
                    lineTo(w * 0.74f, h * 0.34f)
                }
                drawPath(
                    path = path,
                    color = Color.White.copy(alpha = tickAlpha),
                    style = Stroke(width = w * 0.11f, cap = StrokeCap.Round)
                )
            }
        }
    }
}

@Composable
fun OrdoDivider(modifier: Modifier = Modifier, color: Color? = null) {
    val colors = ordoColors
    Box(modifier.height(1.dp).background(color ?: colors.hairline))
}

/** 分组标题(§4:micro 字重 500,全大写字距 +0.4,右侧计数) */
@Composable
fun SectionHeader(
    title: String,
    subtitle: String?,
    modifier: Modifier = Modifier,
    accent: Color? = null,
    trailing: @Composable (() -> Unit)? = null
) {
    val colors = ordoColors
    Row(
        modifier = modifier.padding(horizontal = OrdoSpace.s, vertical = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = title,
            style = OrdoType.micro,
            color = accent ?: colors.textSecondary
        )
        if (subtitle != null) {
            Spacer(Modifier.width(6.dp))
            Text(subtitle, style = OrdoType.micro, color = colors.textTertiary)
        }
        Spacer(Modifier.weight(1f))
        if (trailing != null) trailing()
    }
}

/**
 * 给整行用的 hover 高亮容器。
 *
 * @param gestureModifier 追加在 `clickable` **之后**(也就是更靠内)的手势层。
 *   长按拖拽就挂在这里:内层先收到 Main 阶段的事件,长按成立后 consume,
 *   外层 `clickable` 会因为事件被消费而自动取消 —— 拖完一行不会顺手打开详情。
 */
@Composable
fun HoverRow(
    modifier: Modifier = Modifier,
    shape: RoundedCornerShape = RoundedCornerShape(OrdoRadius.row),
    selected: Boolean = false,
    onClick: (() -> Unit)? = null,
    gestureModifier: Modifier = Modifier,
    content: @Composable (hovered: Boolean) -> Unit
) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    Box(
        modifier = modifier
            .clip(shape)
            .background(
                when {
                    selected -> colors.selected
                    hovered -> colors.hover
                    else -> Color.Transparent
                },
                shape
            )
            .then(
                if (onClick != null) {
                    Modifier.clickable(interactionSource = interaction, indication = null, onClick = onClick)
                } else {
                    Modifier.clickable(
                        interactionSource = interaction,
                        indication = null,
                        enabled = false,
                        onClick = {}
                    )
                }
            )
            .then(gestureModifier)
    ) {
        content(hovered)
    }
}

/** 顶部工具条按钮(带内边距的文字按钮) */
@Composable
fun ToolbarPadding(): PaddingValues = PaddingValues(horizontal = OrdoSpace.s, vertical = OrdoSpace.xs)

/** 让长文本按需省略 */
@Composable
fun EllipsisText(text: String, style: TextStyle = OrdoType.body, color: Color? = null, modifier: Modifier = Modifier) {
    val colors = ordoColors
    Text(
        text = text,
        style = style,
        color = color ?: colors.textPrimary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier
    )
}

/** 透明度动画辅助:0 → 1 */
@Composable
fun animatedAlpha(target: Float): Float =
    animateFloatAsState(targetValue = target, animationSpec = tween(motionMillis(OrdoMotion.BASE)), label = "alpha").value

@Composable
fun Dimmed(content: @Composable () -> Unit) {
    Box(Modifier.alpha(0.72f)) { content() }
}
