package com.ordo.android.ui.auth

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ordo.android.R
import com.ordo.android.auth.AuthMode
import com.ordo.android.ui.common.OrdoIcon
import com.ordo.android.ui.common.OrdoIconKind
import com.ordo.android.ui.common.OrdoPrimaryButton
import com.ordo.android.ui.common.OrdoSecondaryButton
import com.ordo.android.ui.common.OrdoTextField
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoMotion
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.AuthUi
import com.ordo.android.vm.OrdoViewModel
import kotlin.math.roundToInt

/**
 * 登录页（UI §5.1 · 契约 §7.6.4）。
 *
 * 硬约束：
 *  - **三个入口同时存在**：登录 / 注册 / 「以游客身份继续」；游客入口是**同级次要按钮**，
 *    不是灰色小字（游客与正式账号体验对等，都能同步）；
 *  - 卡片宽 400 上限、radius 16、12dp 投影；画布加一层极淡品牌光晕（≤6%）；
 *  - 浮动标签在聚焦时上移 12dp 并转 accent；口令框有可读标签 + 显示/隐藏切换；
 *  - 主按钮高 44：提交中禁用 + 16dp 转圈；输入框与游客按钮一并禁用；
 *  - 错误区在主按钮下方固定预留 20dp；失败时 danger 文案 + 左右抖动（振幅 6dp、320ms、衰减两次）；
 *  - 软键盘：整屏 `imePadding()` + 可滚动，聚焦交给**真正的输入节点**（OrdoTextField 内部）。
 */
@Composable
fun LoginScreen(state: AuthUi, vm: OrdoViewModel) {
    val colors = OrdoTheme.colors
    val emailFocus = remember { FocusRequester() }
    val passwordFocus = remember { FocusRequester() }
    var serverOpen by remember { mutableStateOf(false) }
    var serverUrl by remember { mutableStateOf("") }

    // 进入登录页：fade + 上移 12dp，220ms（§5.1 动效表）
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }
    val appear by animateFloatAsState(
        targetValue = if (appeared) 1f else 0f,
        animationSpec = tween(OrdoTheme.base, easing = OrdoMotion.easing),
        label = "login-enter",
    )

    // 错误抖动：振幅 6dp、320ms、衰减两次（§5.1）
    val shake = remember { Animatable(0f) }
    LaunchedEffect(state.errorNonce) {
        if (state.errorNonce == 0) return@LaunchedEffect
        shake.snapTo(0f)
        shake.animateTo(
            targetValue = 0f,
            animationSpec = keyframes {
                durationMillis = 320
                0f at 0
                6f at 40
                -6f at 120
                3f at 200
                -3f at 260
                0f at 320
            },
        )
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(colors.canvas)
            .windowInsetsPadding(WindowInsets.systemBars)
            // 软键盘：整屏收缩，卡片始终完整可见（输入区不会被 IME 顶出屏幕）
            .imePadding(),
        contentAlignment = Alignment.Center,
    ) {
        // 品牌光晕：透明度 ≤6%，不喧宾夺主
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.radialGradient(
                        colors = listOf(colors.accent.copy(alpha = 0.06f), Color.Transparent),
                        radius = 720f,
                    ),
                ),
        )

        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = OrdoSpace.l, vertical = OrdoSpace.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(
                Modifier
                    .widthIn(max = OrdoLayout.loginCardWidth)
                    .fillMaxWidth()
                    .offset { IntOffset(0, ((1f - appear) * 12f * density).roundToInt()) }
                    .alpha(appear)
                    .shadow(12.dp, RoundedCornerShape(16.dp))
                    .clip(RoundedCornerShape(16.dp))
                    .background(colors.surface)
                    .padding(OrdoSpace.xl),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                BrandHeader()
                Spacer(Modifier.height(OrdoSpace.xl))

                OrdoTextField(
                    value = state.email,
                    onValueChange = vm::onAuthEmailChange,
                    placeholder = stringResource(R.string.auth_email),
                    label = stringResource(R.string.auth_email),
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !state.submitting,
                    isError = state.error != null,
                    contentAlpha = if (state.submitting) 0.5f else 1f,
                    onSubmit = { runCatching { passwordFocus.requestFocus() } },
                )
                Spacer(Modifier.height(OrdoSpace.m))
                OrdoTextField(
                    value = state.password,
                    onValueChange = vm::onAuthPasswordChange,
                    placeholder = stringResource(R.string.auth_password),
                    label = stringResource(R.string.auth_password),
                    modifier = Modifier.fillMaxWidth(),
                    focusRequester = passwordFocus,
                    isPassword = true,
                    enabled = !state.submitting,
                    isError = state.error != null,
                    contentAlpha = if (state.submitting) 0.5f else 1f,
                    onSubmit = vm::submitAuth,
                )
                Spacer(Modifier.height(OrdoSpace.m))

                OrdoPrimaryButton(
                    label = stringResource(
                        if (state.mode == AuthMode.REGISTER) R.string.auth_register else R.string.auth_login,
                    ),
                    onClick = vm::submitAuth,
                    enabled = state.canSubmit,
                    loading = state.submitting,
                )

                // 错误区：固定预留 20dp，失败时显示 danger 文案并左右抖动
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(ErrorAreaHeight)
                        .offset { IntOffset((shake.value * density).roundToInt(), 0) },
                    contentAlignment = Alignment.Center,
                ) {
                    state.error?.let { message ->
                        Text(
                            text = message,
                            style = OrdoTheme.type.caption,
                            color = colors.danger,
                        )
                    }
                }

                OrdoSecondaryButton(
                    label = stringResource(R.string.auth_guest),
                    onClick = vm::continueAsGuest,
                    enabled = !state.submitting,
                )
                Spacer(Modifier.height(OrdoSpace.s))
                Text(
                    text = stringResource(R.string.auth_guest_hint),
                    style = OrdoTheme.type.micro,
                    color = colors.textTertiary,
                )

                Spacer(Modifier.height(OrdoSpace.l))

                // 底部文本链接：登录态「还没有账号？注册」/ 注册态「已有账号？登录」
                Box(
                    Modifier
                        .height(OrdoLayout.touchTarget)
                        .clip(RoundedCornerShape(OrdoRadius.pill))
                        .clickable(enabled = !state.submitting, onClick = vm::switchAuthMode)
                        .padding(horizontal = OrdoSpace.l),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = stringResource(
                            if (state.mode == AuthMode.REGISTER) R.string.auth_to_login else R.string.auth_to_register,
                        ),
                        style = OrdoTheme.type.caption,
                        color = colors.accent,
                    )
                }

                /*
                 * 服务器地址：登录前也必须可改。
                 * 否则默认地址不可达时用户会被卡死在登录页（设置页在登录之后才进得去）。
                 */
                Box(
                    Modifier
                        .height(OrdoLayout.touchTarget)
                        .clip(RoundedCornerShape(OrdoRadius.pill))
                        .clickable(enabled = !state.submitting) { serverOpen = !serverOpen }
                        .padding(horizontal = OrdoSpace.l),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = stringResource(R.string.auth_server_toggle),
                        style = OrdoTheme.type.micro,
                        color = colors.textTertiary,
                    )
                }
                if (serverOpen) {
                    OrdoTextField(
                        value = serverUrl,
                        onValueChange = { serverUrl = it },
                        placeholder = vm.currentServerUrl(),
                        label = stringResource(R.string.settings_server),
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !state.submitting,
                    )
                    Spacer(Modifier.height(OrdoSpace.s))
                    OrdoSecondaryButton(
                        label = stringResource(R.string.common_save),
                        onClick = { vm.setServerUrl(serverUrl) },
                        enabled = !state.submitting,
                    )
                }
            }
        }
    }
}

@Composable
private fun BrandHeader() {
    val colors = OrdoTheme.colors
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier
                .size(56.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(colors.accent),
            contentAlignment = Alignment.Center,
        ) {
            OrdoIcon(
                kind = OrdoIconKind.Today,
                size = 32.dp,
                tint = colors.onAccent,
                strokeWidth = 1.8f,
            )
        }
        Spacer(Modifier.height(OrdoSpace.m))
        Text(
            text = stringResource(R.string.auth_brand),
            // §5.1：font.display 24/32、字重 600（品牌名比清单大标题小一号）
            style = OrdoTheme.type.display.copy(fontSize = 24.sp, lineHeight = 32.sp),
            color = colors.textPrimary,
        )
        Text(
            text = stringResource(R.string.auth_brand_sub),
            style = OrdoTheme.type.caption,
            color = colors.textSecondary,
        )
    }
}

/** 错误区固定高度（UI §5.1：主按钮下方固定预留 20 高度，避免出错时卡片跳动） */
private val ErrorAreaHeight = 20.dp
