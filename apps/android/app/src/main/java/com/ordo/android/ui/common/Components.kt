package com.ordo.android.ui.common

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.Canvas
import com.ordo.android.R
import com.ordo.android.ui.theme.OrdoElevation
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoMotion
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme

/* ============================== 基础容器 ============================== */

@Composable
fun OrdoDivider(modifier: Modifier = Modifier) {
    Box(
        modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(OrdoTheme.colors.hairline),
    )
}

@Composable
fun OrdoScrim(onClick: () -> Unit) {
    Box(
        Modifier
            .fillMaxSize()
            .background(OrdoTheme.colors.scrim)
            .clickable(
                indication = null,
                interactionSource = remember { MutableInteractionSource() },
                onClick = onClick,
            ),
    )
}

/* ============================== 按钮 ============================== */

@Composable
fun OrdoIconButton(
    kind: OrdoIconKind,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = OrdoTheme.colors.textSecondary,
    size: Dp = OrdoLayout.touchTarget,
    iconSize: Dp = 18.dp,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.92f else 1f,
        animationSpec = tween(OrdoMotion.PRESS, easing = OrdoMotion.easing),
        label = "icon-button-press",
    )
    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .scale(scale),
        contentAlignment = Alignment.Center,
    ) {
        OrdoIcon(kind = kind, size = iconSize, tint = tint)
    }
}

@Composable
fun OrdoButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    primary: Boolean = false,
    danger: Boolean = false,
) {
    val colors = OrdoTheme.colors
    val background = when {
        danger -> colors.danger
        primary -> colors.accent
        else -> Color.Transparent
    }
    val content = when {
        danger || primary -> colors.onAccent
        else -> colors.textPrimary
    }
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(OrdoRadius.pill))
            .background(background)
            .then(
                if (primary || danger) Modifier else Modifier.border(1.dp, colors.hairline, RoundedCornerShape(OrdoRadius.pill)),
            )
            .clickable(onClick = onClick)
            .padding(horizontal = OrdoSpace.l, vertical = OrdoSpace.s),
    ) {
        Text(text = label, style = OrdoTheme.type.caption, color = content)
    }
}

/* ============================== 输入框 ============================== */

@Composable
fun OrdoTextField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    singleLine: Boolean = true,
    textStyle: TextStyle = OrdoTheme.type.body,
    onSubmit: (() -> Unit)? = null,
    /**
     * 需要自动聚焦时由调用方传入。
     *
     * 必须落在**真正的可聚焦节点**（`BasicTextField`）上：把 `focusRequester` 挂在外层
     * `Box` 上时 `requestFocus()` 找不到焦点目标，输入框不会获得焦点、软键盘也不会弹
     * —— 这正是实测「点加号没有反应」的根因之一。
     */
    focusRequester: FocusRequester? = null,
    /** 浮动标签（UI §5.1）：聚焦或有内容时上移 12dp 并转 accent；口令框必须给标签 */
    label: String? = null,
    /** 口令框：内容掩码 + 显示/隐藏切换 */
    isPassword: Boolean = false,
    /**
     * 键盘类型；默认按 [isPassword] 推断。
     * 验证码框传 `KeyboardType.NumberPassword`（纯数字键盘，契约 §7.6.5 的 6 位数字码）。
     */
    keyboardType: KeyboardType? = null,
    /** 尾部插槽（如验证码框右侧的「获取验证码」）：不参与聚焦，点它不会丢焦点 */
    trailing: (@Composable () -> Unit)? = null,
    enabled: Boolean = true,
    isError: Boolean = false,
    /** 提交中禁用时的遮罩透明度 */
    contentAlpha: Float = 1f,
) {
    val colors = OrdoTheme.colors
    var focused by remember { mutableStateOf(false) }
    var passwordVisible by remember { mutableStateOf(false) }

    val active = focused || value.isNotEmpty()
    val borderColor by animateColorAsState(
        targetValue = when {
            isError -> colors.danger
            focused -> colors.accent
            else -> colors.hairline
        },
        animationSpec = tween(OrdoTheme.fast, easing = OrdoMotion.easing),
        label = "field-border",
    )
    val labelShift by animateDpAsState(
        targetValue = if (active) 0.dp else FieldLabelShift,
        animationSpec = tween(OrdoTheme.fast, easing = OrdoMotion.easing),
        label = "field-label-shift",
    )
    val labelColor by animateColorAsState(
        targetValue = when {
            isError -> colors.danger
            focused -> colors.accent
            else -> colors.textTertiary
        },
        animationSpec = tween(OrdoTheme.fast, easing = OrdoMotion.easing),
        label = "field-label-color",
    )

    Row(
        modifier = modifier
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(colors.surface)
            .border(1.dp, borderColor, RoundedCornerShape(OrdoRadius.row))
            .height(if (label != null) OrdoLayout.fieldHeight else OrdoLayout.fieldHeightCompact)
            .padding(horizontal = OrdoSpace.m),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f)) {
            if (label != null) {
                Text(
                    text = label,
                    style = OrdoTheme.type.micro,
                    color = labelColor,
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .padding(top = 6.dp)
                        .offset(y = labelShift),
                )
            }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                enabled = enabled,
                singleLine = singleLine,
                textStyle = textStyle.copy(
                    color = colors.textPrimary.copy(alpha = contentAlpha),
                ),
                visualTransformation = if (isPassword && !passwordVisible) {
                    PasswordVisualTransformation()
                } else {
                    VisualTransformation.None
                },
                cursorBrush = SolidColor(colors.accent),
                keyboardOptions = KeyboardOptions(
                    keyboardType = keyboardType
                        ?: if (isPassword) KeyboardType.Password else KeyboardType.Text,
                    imeAction = if (singleLine) ImeAction.Done else ImeAction.Default,
                ),
                keyboardActions = KeyboardActions(
                    onDone = { onSubmit?.invoke() },
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .align(if (label != null) Alignment.BottomStart else Alignment.CenterStart)
                    .padding(bottom = if (label != null) 9.dp else 0.dp)
                    .onFocusChanged { focused = it.isFocused }
                    .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier),
            )
            if (value.isEmpty() && !active && label == null) {
                Text(
                    text = placeholder,
                    style = textStyle,
                    color = colors.textTertiary.copy(alpha = contentAlpha),
                    modifier = Modifier.align(Alignment.CenterStart),
                )
            }
        }
        if (isPassword) {
            // 可读标签 + 44dp 触控：显示/隐藏切换
            Box(
                Modifier
                    .size(OrdoLayout.touchTarget)
                    .clip(CircleShape)
                    .clickable(enabled = enabled, onClick = { passwordVisible = !passwordVisible }),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = stringResource(
                        if (passwordVisible) R.string.field_password_hide else R.string.field_password_show,
                    ),
                    style = OrdoTheme.type.micro,
                    color = colors.accent.copy(alpha = contentAlpha),
                )
            }
        }
        trailing?.invoke()
    }
}

/** 表单浮动标签的位移量（UI §5.1：聚焦时标签上移 12px） */
private val FieldLabelShift = 12.dp

/* ============================== 加载指示 ============================== */

/** 小转圈（UI §5.1：提交中主按钮内 16dp 转圈） */
@Composable
fun OrdoSpinner(
    modifier: Modifier = Modifier,
    size: Dp = 16.dp,
    color: Color = OrdoTheme.colors.onAccent,
    strokeWidth: Dp = 2.dp,
) {
    val transition = rememberInfiniteTransition(label = "spinner")
    val angle by transition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(
            animation = tween(OrdoMotion.SPINNER_PERIOD, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "spinner-angle",
    )
    Canvas(modifier.size(size).rotate(angle)) {
        drawArc(
            color = color,
            startAngle = 0f,
            sweepAngle = 280f,
            useCenter = false,
            topLeft = Offset(strokeWidth.toPx() / 2f, strokeWidth.toPx() / 2f),
            size = Size(this.size.width - strokeWidth.toPx(), this.size.height - strokeWidth.toPx()),
            style = Stroke(width = strokeWidth.toPx(), cap = StrokeCap.Round),
        )
    }
}

/* ============================== 登录页按钮 ============================== */

/**
 * 主按钮（UI §5.1）：高 44、radius 10、accent 填充；提交中禁用 + 内嵌 16dp 转圈。
 * 按压 scale → 0.98（90ms）。
 */
@Composable
fun OrdoPrimaryButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
) {
    val colors = OrdoTheme.colors
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed && enabled && !loading) 0.98f else 1f,
        animationSpec = tween(OrdoMotion.PRESS, easing = OrdoMotion.easing),
        label = "primary-press",
    )
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(OrdoLayout.buttonHeight)
            .scale(scale)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(colors.accent.copy(alpha = if (enabled && !loading) 1f else 0.5f))
            .clickable(
                enabled = enabled && !loading,
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            if (loading) {
                OrdoSpinner(size = 16.dp, color = colors.onAccent)
                Spacer(Modifier.width(OrdoSpace.s))
            }
            Text(text = label, style = OrdoTheme.type.body, color = colors.onAccent)
        }
    }
}

/**
 * 次要按钮（UI §5.1）：「以游客身份继续」与主按钮**同级**——
 * surface 底 + hairline 描边，不是灰色小字（游客登录与正式登录体验对等）。
 */
@Composable
fun OrdoSecondaryButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val colors = OrdoTheme.colors
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed && enabled) 0.98f else 1f,
        animationSpec = tween(OrdoMotion.PRESS, easing = OrdoMotion.easing),
        label = "secondary-press",
    )
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(OrdoLayout.buttonHeight)
            .scale(scale)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(colors.surface)
            .border(1.dp, colors.hairline, RoundedCornerShape(OrdoRadius.row))
            .clickable(
                enabled = enabled,
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = OrdoTheme.type.body,
            color = colors.textPrimary.copy(alpha = if (enabled) 1f else 0.4f),
        )
    }
}

/* ============================== 标签 / 元信息 ============================== */

@Composable
fun TagChip(
    name: String,
    onClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val colors = OrdoTheme.colors
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(OrdoRadius.pill))
            .background(colors.chipBg)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 6.dp, vertical = 2.dp),
    ) {
        Text(text = name, style = OrdoTheme.type.micro, color = colors.chipText)
    }
}

enum class MetaTone { NORMAL, DANGER, ACCENT, TONIGHT }

@Composable
fun MetaPill(
    text: String,
    icon: OrdoIconKind? = null,
    tone: MetaTone = MetaTone.NORMAL,
    modifier: Modifier = Modifier,
) {
    val colors = OrdoTheme.colors
    val tint = when (tone) {
        MetaTone.NORMAL -> colors.textSecondary
        MetaTone.DANGER -> colors.danger
        MetaTone.ACCENT -> colors.accent
        MetaTone.TONIGHT -> colors.tonight
    }
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        if (icon != null) {
            OrdoIcon(kind = icon, size = OrdoLayout.metaIconSize, tint = tint, strokeWidth = 1.5f)
        }
        Text(text = text, style = OrdoTheme.type.caption, color = tint)
    }
}

/* ============================== 进度环 ============================== */

@Composable
fun ProgressRing(
    progress: Float,
    modifier: Modifier = Modifier,
    size: Dp = OrdoLayout.projectRingSize,
    strokeWidth: Dp = 2.dp,
    tint: Color = OrdoTheme.colors.accent,
    trackTint: Color = OrdoTheme.colors.hairline,
    pulse: Boolean = false,
) {
    val animated by animateFloatAsState(
        targetValue = progress.coerceIn(0f, 1f),
        animationSpec = tween(OrdoMotion.BASE, easing = OrdoMotion.easing),
        label = "progress-ring",
    )
    val pulseScale by animateFloatAsState(
        targetValue = if (pulse && animated >= 1f) 1.15f else 1f,
        animationSpec = tween(OrdoMotion.BASE, easing = OrdoMotion.easing),
        label = "progress-pulse",
    )
    Canvas(modifier = modifier.size(size).scale(pulseScale)) {
        val stroke = Stroke(width = strokeWidth.toPx(), cap = StrokeCap.Round)
        val inset = stroke.width / 2f
        val arcSize = Size(this.size.width - stroke.width, this.size.height - stroke.width)
        drawArc(
            color = trackTint,
            startAngle = 0f,
            sweepAngle = 360f,
            useCenter = false,
            topLeft = Offset(inset, inset),
            size = arcSize,
            style = stroke,
        )
        if (animated > 0f) {
            drawArc(
                color = tint,
                startAngle = -90f,
                sweepAngle = 360f * animated,
                useCenter = false,
                topLeft = Offset(inset, inset),
                size = arcSize,
                style = stroke,
            )
        }
    }
}

/* ============================== 圆形复选框 ============================== */

@Composable
fun OrdoCheckbox(
    checked: Boolean,
    onToggle: () -> Unit,
    contentDescription: String,
    modifier: Modifier = Modifier,
    canceled: Boolean = false,
    size: Dp = OrdoLayout.checkboxSize,
) {
    val colors = OrdoTheme.colors
    val fill by animateColorAsState(
        targetValue = when {
            canceled -> Color.Transparent
            checked -> colors.accent
            else -> Color.Transparent
        },
        animationSpec = tween(OrdoMotion.FAST, easing = OrdoMotion.easing),
        label = "checkbox-fill",
    )
    val borderColor by animateColorAsState(
        targetValue = when {
            canceled -> colors.danger
            checked -> colors.accent
            else -> colors.checkboxStroke
        },
        animationSpec = tween(OrdoMotion.FAST, easing = OrdoMotion.easing),
        label = "checkbox-border",
    )
    val tickAlpha by animateFloatAsState(
        targetValue = if (checked && !canceled) 1f else 0f,
        animationSpec = tween(OrdoMotion.FAST, easing = OrdoMotion.easing),
        label = "checkbox-tick",
    )
    val scale by animateFloatAsState(
        targetValue = if (checked) 1.04f else 1f,
        animationSpec = tween(OrdoMotion.FILL, easing = OrdoMotion.easing),
        label = "checkbox-scale",
    )

    Box(
        modifier = modifier
            .size(OrdoLayout.touchTarget)
            .clip(CircleShape)
            .clickable(onClick = onToggle),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .size(size)
                .scale(scale)
                .clip(CircleShape)
                .background(fill)
                .border(1.6.dp, borderColor, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (tickAlpha > 0.01f) {
                OrdoIcon(
                    kind = OrdoIconKind.Check,
                    size = size * 0.7f,
                    tint = colors.onAccent.copy(alpha = tickAlpha),
                    strokeWidth = 2.2f,
                )
            }
            if (canceled) {
                Canvas(Modifier.size(size)) {
                    drawLine(
                        color = colors.danger,
                        start = Offset(this.size.width * 0.25f, this.size.height * 0.75f),
                        end = Offset(this.size.width * 0.75f, this.size.height * 0.25f),
                        strokeWidth = 1.6.dp.toPx(),
                        cap = StrokeCap.Round,
                    )
                }
            }
        }
    }
}

/* ============================== 空状态 ============================== */

@Composable
fun EmptyState(
    title: String,
    subtitle: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val colors = OrdoTheme.colors
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = OrdoSpace.xxl),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Canvas(Modifier.size(64.dp)) {
            val stroke = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round)
            drawArc(
                color = colors.textTertiary,
                startAngle = -60f,
                sweepAngle = 300f,
                useCenter = false,
                topLeft = Offset(size.width * 0.16f, size.height * 0.16f),
                size = Size(size.width * 0.68f, size.height * 0.68f),
                style = stroke,
            )
            drawLine(
                color = colors.textTertiary,
                start = Offset(size.width * 0.38f, size.height * 0.5f),
                end = Offset(size.width * 0.62f, size.height * 0.5f),
                strokeWidth = 2.dp.toPx(),
                cap = StrokeCap.Round,
            )
        }
        Spacer(Modifier.height(OrdoSpace.l))
        Text(text = title, style = OrdoTheme.type.title, color = colors.textPrimary)
        Spacer(Modifier.height(OrdoSpace.xs))
        Text(text = subtitle, style = OrdoTheme.type.caption, color = colors.textSecondary)
        if (actionLabel != null && onAction != null) {
            Spacer(Modifier.height(OrdoSpace.l))
            OrdoButton(label = actionLabel, onClick = onAction, primary = true)
        }
    }
}

/* ============================== Toast ============================== */

@Composable
fun OrdoToastHost(
    message: String?,
    modifier: Modifier = Modifier,
) {
    if (message == null) return
    val colors = OrdoTheme.colors
    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(bottom = OrdoSpace.xl),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Box(
            Modifier
                .clip(RoundedCornerShape(OrdoRadius.pill))
                .background(colors.surface, RoundedCornerShape(OrdoRadius.pill))
                .border(1.dp, colors.hairline, RoundedCornerShape(OrdoRadius.pill))
                .padding(horizontal = OrdoSpace.l, vertical = OrdoSpace.s),
        ) {
            Text(text = message, style = OrdoTheme.type.caption, color = colors.textPrimary)
        }
    }
}

/* ============================== 浮层容器 ============================== */

@Composable
fun OrdoPopover(
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    width: Dp = OrdoLayout.sheetWidth,
    content: @Composable () -> Unit,
) {
    val colors = OrdoTheme.colors
    OrdoScrim(onClick = onDismiss)
    Box(
        modifier = modifier
            .fillMaxSize()
            .padding(OrdoSpace.l),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .width(width)
                .clip(RoundedCornerShape(OrdoRadius.card))
                .background(colors.surface)
                .border(1.dp, colors.hairline, RoundedCornerShape(OrdoRadius.card))
                .padding(OrdoSpace.m),
        ) {
            content()
        }
    }
}

/* ============================== Markdown 预览 ============================== */

@Composable
fun MarkdownPreview(
    text: String,
    modifier: Modifier = Modifier,
) {
    val colors = OrdoTheme.colors
    Column(modifier) {
        text.split("\n").forEach { rawLine ->
            val line = rawLine.trimEnd()
            when {
                line.startsWith("### ") -> MarkdownLine(line.removePrefix("### "), OrdoTheme.type.caption, colors.textPrimary, FontWeight.SemiBold)
                line.startsWith("## ") -> MarkdownLine(line.removePrefix("## "), OrdoTheme.type.body, colors.textPrimary, FontWeight.SemiBold)
                line.startsWith("# ") -> MarkdownLine(line.removePrefix("# "), OrdoTheme.type.title, colors.textPrimary, FontWeight.SemiBold)
                line.startsWith("- ") || line.startsWith("* ") -> Row(
                    Modifier.padding(vertical = 1.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Text(text = "•", style = OrdoTheme.type.body, color = colors.textSecondary)
                    Spacer(Modifier.width(OrdoSpace.s))
                    MarkdownLine(line.substring(2), OrdoTheme.type.body, colors.textPrimary, FontWeight.Normal)
                }
                line.isBlank() -> Spacer(Modifier.height(OrdoSpace.xs))
                else -> MarkdownLine(line, OrdoTheme.type.body, colors.textPrimary, FontWeight.Normal)
            }
        }
    }
}

@Composable
private fun MarkdownLine(
    text: String,
    style: TextStyle,
    color: Color,
    weight: FontWeight,
) {
    val colors = OrdoTheme.colors
    val annotated = remember(text, color, weight) {
        buildInlineMarkdown(text, color, colors.accent, colors.chipBg)
    }
    Text(text = annotated, style = style.copy(fontWeight = weight))
}

private fun buildInlineMarkdown(
    text: String,
    textColor: Color,
    accent: Color,
    codeBackground: Color,
): AnnotatedString = buildAnnotatedString {
    var index = 0
    val pattern = Regex("\\*\\*(.+?)\\*\\*|`(.+?)`|\\[(.+?)]\\((.+?)\\)")
    pattern.findAll(text).forEach { match ->
        if (match.range.first > index) {
            append(text.substring(index, match.range.first))
        }
        val bold = match.groupValues[1]
        val code = match.groupValues[2]
        val linkLabel = match.groupValues[3]
        when {
            bold.isNotEmpty() -> withStyle(SpanStyle(fontWeight = FontWeight.SemiBold, color = textColor)) { append(bold) }
            code.isNotEmpty() -> withStyle(
                SpanStyle(fontFamily = FontFamily.Monospace, background = codeBackground, color = textColor),
            ) { append(code) }
            linkLabel.isNotEmpty() -> withStyle(
                SpanStyle(color = accent, textDecoration = TextDecoration.Underline),
            ) { append(linkLabel) }
        }
        index = match.range.last + 1
    }
    if (index < text.length) append(text.substring(index))
}

/* ============================== 阴影容器 ============================== */

@Composable
fun OrdoCard(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val colors = OrdoTheme.colors
    Box(
        modifier
            .clip(RoundedCornerShape(OrdoRadius.card))
            .background(colors.surface)
            .border(1.dp, colors.hairline, RoundedCornerShape(OrdoRadius.card)),
    ) {
        content()
    }
}
