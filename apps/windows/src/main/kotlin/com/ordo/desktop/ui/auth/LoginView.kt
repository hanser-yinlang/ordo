package com.ordo.desktop.ui.auth

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
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
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ordo.desktop.app.LoginController
import com.ordo.desktop.app.LoginField
import com.ordo.desktop.app.LoginUiState
import com.ordo.desktop.ui.common.OrdoIcons
import com.ordo.desktop.ui.theme.OrdoMotion
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.ordoColors
import com.ordo.desktop.ui.theme.ordoDark
import javax.imageio.ImageIO

/**
 * 登录页(04-UI规范 §5.1)。
 *
 * 结构:整屏居中卡片(宽 400,高自适应),画布 + 一层极淡的品牌光晕;
 * 卡片内自上而下 = 品牌区 → 输入区(邮箱 / 口令,浮动标签 + 显示隐藏)→ 主按钮 →
 * 「以游客身份继续」→ 底部文本链接;主按钮下方固定预留 20 高给错误文案。
 *
 * 三个入口(登录 / 注册 / 游客登录)都在这里,且**游客与正式登录共用同一条提交链路**(§5.1 硬约束)。
 */
@Composable
fun LoginView(state: LoginUiState, controller: LoginController, modifier: Modifier = Modifier) {
    val colors = ordoColors
    val dark = ordoDark

    // 进入登录页:fade + 上移 12px,220ms(§5.1 动效表)
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }
    val enterAlpha by animateFloatAsState(
        targetValue = if (appeared) 1f else 0f,
        animationSpec = tween(OrdoMotion.BASE),
        label = "loginEnterAlpha"
    )
    val enterOffset by animateDpAsState(
        targetValue = if (appeared) 0.dp else 12.dp,
        animationSpec = tween(OrdoMotion.BASE),
        label = "loginEnterOffset"
    )

    Box(
        modifier
            .fillMaxSize()
            .background(colors.canvas),
        contentAlignment = Alignment.Center
    ) {
        // 品牌光晕:透明度 ≤6%,只负责让整屏不至于"一张白纸"
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0f to colors.accent.copy(alpha = if (dark) 0.10f else 0.06f),
                        0.45f to Color.Transparent
                    )
                )
        )
        Column(
            Modifier
                .offset(y = enterOffset)
                .alpha(enterAlpha)
                .width(400.dp)
                .shadow(12.dp, RoundedCornerShape(16.dp))
                .clip(RoundedCornerShape(16.dp))
                .background(colors.surface)
                .padding(horizontal = OrdoSpace.xxl, vertical = OrdoSpace.xxl),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            BrandHeader()

            Spacer(Modifier.height(OrdoSpace.xl))

            FloatingLabelField(
                value = state.email,
                onValueChange = controller::setEmail,
                label = "邮箱",
                enabled = state.enabled,
                focused = state.focused == LoginField.EMAIL,
                onFocusChange = { focused ->
                    controller.setFocused(if (focused) LoginField.EMAIL else null)
                }
            )

            Spacer(Modifier.height(OrdoSpace.m))

            FloatingLabelField(
                value = state.password,
                onValueChange = controller::setPassword,
                label = "口令",
                enabled = state.enabled,
                focused = state.focused == LoginField.PASSWORD,
                onFocusChange = { focused ->
                    controller.setFocused(if (focused) LoginField.PASSWORD else null)
                },
                secret = true,
                secretVisible = state.passwordVisible,
                onToggleSecret = controller::togglePasswordVisible
            )

            Spacer(Modifier.height(OrdoSpace.l))

            PrimaryButton(
                label = state.primaryLabel,
                busy = state.busy,
                enabled = state.canSubmit,
                onClick = controller::submit
            )

            // 错误区:固定预留 20 高,失败时 danger 文案 + 左右抖动(振幅 6px / 320ms / 衰减两次)
            ErrorSlot(message = state.error, shakeToken = state.errorShake)

            SecondaryButton(
                label = "以游客身份继续",
                enabled = state.enabled,
                onClick = controller::continueAsGuest
            )

            state.notice?.let { notice ->
                Spacer(Modifier.height(OrdoSpace.m))
                Text(notice, style = OrdoType.micro, color = colors.textTertiary)
            }

            Spacer(Modifier.height(OrdoSpace.l))

            // 底部一行的文本链接(登录态 ⇄ 注册态)
            Text(
                text = state.switchHint,
                style = OrdoType.caption,
                color = if (state.enabled) colors.accent else colors.textTertiary,
                modifier = Modifier
                    .clip(RoundedCornerShape(OrdoRadius.pill))
                    .clickable(enabled = state.enabled) { controller.switchMode() }
                    .padding(horizontal = OrdoSpace.s, vertical = OrdoSpace.xs)
            )
        }
    }
}

/** 品牌区:56 应用图标 + 「Ordo」(24/32,600)+ 副标题「把今天理清楚」 */
@Composable
private fun BrandHeader() {
    val colors = ordoColors
    val icon = rememberOrdoIcon()
    Box(Modifier.size(56.dp), contentAlignment = Alignment.Center) {
        if (icon != null) {
            Image(painter = icon, contentDescription = "Ordo", modifier = Modifier.size(56.dp))
        } else {
            Box(
                Modifier
                    .size(56.dp)
                    .clip(CircleShape)
                    .background(colors.accent),
                contentAlignment = Alignment.Center
            ) {
                Text("序", style = OrdoType.title, color = Color.White, fontWeight = FontWeight.SemiBold)
            }
        }
    }
    Spacer(Modifier.height(OrdoSpace.m))
    Text(
        text = "Ordo",
        style = OrdoType.display.copy(fontSize = 24.sp, lineHeight = 32.sp),
        color = colors.textPrimary,
        fontWeight = FontWeight.SemiBold
    )
    Text("把今天理清楚", style = OrdoType.caption, color = colors.textSecondary)
}

/**
 * 浮动标签输入框(§5.1 输入区):聚焦时标签上移 12px 并转 accent,边框同时转 accent(120ms)。
 */
@Composable
private fun FloatingLabelField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    enabled: Boolean,
    focused: Boolean,
    onFocusChange: (Boolean) -> Unit,
    secret: Boolean = false,
    secretVisible: Boolean = false,
    onToggleSecret: (() -> Unit)? = null
) {
    val colors = ordoColors
    val floated = focused || value.isNotEmpty()
    val labelOffset by animateDpAsState(
        targetValue = if (floated) (-12).dp else 0.dp,
        animationSpec = tween(OrdoMotion.FAST),
        label = "loginLabelOffset"
    )
    val labelColor = when {
        focused -> colors.accent
        floated -> colors.textSecondary
        else -> colors.textTertiary
    }

    Box(
        Modifier
            .fillMaxWidth()
            .height(52.dp)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(colors.canvas)
            .border(
                width = 1.dp,
                color = if (focused) colors.accent else colors.hairline,
                shape = RoundedCornerShape(OrdoRadius.row)
            )
            .padding(horizontal = OrdoSpace.m),
        contentAlignment = Alignment.CenterStart
    ) {
        // 标签:未浮动时充当占位符,浮动后缩小并上移 12px
        Text(
            text = label,
            style = if (floated) OrdoType.micro else OrdoType.body.copy(fontSize = 14.sp),
            color = labelColor,
            modifier = Modifier.offset(y = labelOffset)
        )
        Row(
            Modifier
                .fillMaxWidth()
                .padding(top = if (floated) 14.dp else 0.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                enabled = enabled,
                singleLine = true,
                textStyle = OrdoType.body.copy(color = colors.textPrimary, fontSize = 15.sp),
                cursorBrush = SolidColor(colors.accent),
                visualTransformation = if (secret && !secretVisible) {
                    PasswordVisualTransformation()
                } else {
                    VisualTransformation.None
                },
                modifier = Modifier
                    .weight(1f)
                    .onFocusChanged { onFocusChange(it.isFocused) }
            )
            if (secret && onToggleSecret != null) {
                Icon(
                    imageVector = if (secretVisible) OrdoIcons.Hidden else OrdoIcons.Visible,
                    contentDescription = if (secretVisible) "隐藏口令" else "显示口令",
                    tint = colors.textSecondary,
                    modifier = Modifier
                        .size(28.dp)
                        .clickable(enabled = enabled) { onToggleSecret() }
                        .padding(4.dp)
                )
            }
        }
    }
}

/** 主按钮:高 44、radius 10、accent 填充;提交中禁用 + 16dp 转圈;按压 scale → 0.98(90ms) */
@Composable
private fun PrimaryButton(label: String, busy: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed && enabled) 0.98f else 1f,
        animationSpec = tween(90),
        label = "loginPrimaryPress"
    )
    val shape = RoundedCornerShape(10.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .height(44.dp)
            .scale(scale)
            .clip(shape)
            .background(if (enabled) colors.accent else colors.accent.copy(alpha = 0.55f), shape)
            .clickable(
                interactionSource = interaction,
                indication = null,
                enabled = enabled,
                onClick = onClick
            ),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        if (busy) {
            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = Color.White)
            Spacer(Modifier.width(OrdoSpace.s))
        }
        Text(label, style = OrdoType.bodyStrong, color = Color.White)
    }
}

/**
 * 次要入口「以游客身份继续」(§5.1 硬约束):
 * `surface` 底 + hairline 描边,**与主按钮同级** —— 不是灰色小字,也不是"功能受限"的入口。
 */
@Composable
private fun SecondaryButton(label: String, enabled: Boolean, onClick: () -> Unit) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed && enabled) 0.98f else 1f,
        animationSpec = tween(90),
        label = "loginSecondaryPress"
    )
    val shape = RoundedCornerShape(10.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .height(44.dp)
            .scale(scale)
            .clip(shape)
            .background(colors.canvas, shape)
            .border(1.dp, colors.hairline, shape)
            .clickable(
                interactionSource = interaction,
                indication = null,
                enabled = enabled,
                onClick = onClick
            ),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = label,
            style = OrdoType.bodyStrong,
            color = if (enabled) colors.textPrimary else colors.textTertiary
        )
    }
}

/**
 * 错误区:固定预留 20 高(不因错误出现而让布局跳动),失败时文案转 danger 并左右抖动。
 *
 * 抖动参数照 §5.1:振幅 6px、320ms、衰减两次(6 → -6 → 3 → -3 → 0)。
 */
@Composable
private fun ErrorSlot(message: String?, shakeToken: Long) {
    val colors = ordoColors
    val shake = remember { Animatable(0f) }
    LaunchedEffect(shakeToken) {
        if (shakeToken <= 0L) return@LaunchedEffect
        shake.snapTo(0f)
        shake.animateTo(
            targetValue = 0f,
            animationSpec = keyframes {
                durationMillis = 320
                -6f at 40
                6f at 120
                -3f at 200
                3f at 260
                0f at 320
            }
        )
    }
    Box(
        Modifier
            .fillMaxWidth()
            .height(20.dp)
            .offset(x = shake.value.dp),
        contentAlignment = Alignment.Center
    ) {
        if (message != null) {
            Text(message, style = OrdoType.micro, color = colors.danger, maxLines = 1)
        }
    }
}

/** 应用图标(与窗口图标同源);资源缺失时返回 null,由调用方退化为字母标记 */
@Composable
private fun rememberOrdoIcon(): Painter? = remember {
    runCatching {
        val stream = Thread.currentThread().contextClassLoader
            ?.getResourceAsStream(BRAND_ICON_RESOURCE) ?: return@runCatching null
        stream.use { BitmapPainter(ImageIO.read(it).toComposeImageBitmap()) }
    }.getOrNull()
}

private const val BRAND_ICON_RESOURCE = "ordo-icon-ring.png"
