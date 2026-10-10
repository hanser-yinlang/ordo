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
import androidx.compose.foundation.layout.width
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ordo.android.R
import com.ordo.android.auth.AuthMethod
import com.ordo.android.auth.AuthMode
import com.ordo.android.auth.CodeSendState
import com.ordo.android.auth.EmailCodeRules
import com.ordo.android.ui.common.OrdoIcon
import com.ordo.android.ui.common.OrdoIconKind
import com.ordo.android.ui.common.OrdoPrimaryButton
import com.ordo.android.ui.common.OrdoSecondaryButton
import com.ordo.android.ui.common.OrdoSpinner
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
 *  - v1.3 免密登录（契约 §7.6.5）：卡片顶部「口令登录 / 验证码登录」**同级**切换；
 *    验证码模式 = 邮箱 + 6 位数字码 + 「获取验证码」（按 retryAfter 跑倒计时置灰），
 *    满 6 位**自动提交**，错误仍走同一错误区（抖动 + 文案）。
 */
@Composable
fun LoginScreen(state: AuthUi, vm: OrdoViewModel) {
    val colors = OrdoTheme.colors
    val emailFocus = remember { FocusRequester() }
    val passwordFocus = remember { FocusRequester() }
    val codeFocus = remember { FocusRequester() }
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

    // 验证码满 6 位自动提交（§7.6.5 免密体验）：canSubmit 已包含邮箱/码格式/忙碌判定
    LaunchedEffect(state.loginMethod, state.code) {
        if (state.loginMethod == AuthMethod.EMAIL_CODE && state.canSubmit) vm.submitEmailCode()
    }

    // 验证码请求成功（无错误地结束请求中）→ 焦点落到验证码框，软键盘直接可输入
    var wasCodeRequesting by remember { mutableStateOf(false) }
    LaunchedEffect(state.codeRequesting, state.error) {
        if (wasCodeRequesting && !state.codeRequesting && state.error == null) {
            runCatching { codeFocus.requestFocus() }
        }
        wasCodeRequesting = state.codeRequesting
    }

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
                Spacer(Modifier.height(OrdoSpace.l))

                // 登录方式：口令 / 验证码，同级切换（契约 §7.6.5）
                AuthMethodTabs(
                    current = state.loginMethod,
                    enabled = !state.submitting && !state.codeRequesting,
                    onSelect = vm::switchAuthMethod,
                )
                Spacer(Modifier.height(OrdoSpace.l))

                OrdoTextField(
                    value = state.email,
                    onValueChange = vm::onAuthEmailChange,
                    placeholder = stringResource(R.string.auth_email),
                    label = stringResource(R.string.auth_email),
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !state.submitting && !state.codeRequesting,
                    isError = state.error != null,
                    contentAlpha = if (state.submitting) 0.5f else 1f,
                    onSubmit = {
                        when (state.loginMethod) {
                            AuthMethod.EMAIL_CODE -> runCatching { codeFocus.requestFocus() }
                            AuthMethod.PASSWORD -> runCatching { passwordFocus.requestFocus() }
                        }
                    },
                )
                Spacer(Modifier.height(OrdoSpace.m))

                if (state.loginMethod == AuthMethod.PASSWORD) {
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
                } else {
                    OrdoTextField(
                        value = state.code,
                        onValueChange = vm::onAuthCodeChange,
                        placeholder = stringResource(R.string.auth_code),
                        label = stringResource(R.string.auth_code),
                        modifier = Modifier.fillMaxWidth(),
                        focusRequester = codeFocus,
                        keyboardType = KeyboardType.NumberPassword,
                        enabled = !state.submitting && !state.codeRequesting,
                        isError = state.error != null,
                        contentAlpha = if (state.submitting || state.codeRequesting) 0.5f else 1f,
                        onSubmit = vm::submitEmailCode,
                        trailing = {
                            CodeSendAction(
                                sendState = state.codeSendState,
                                cooldownSeconds = state.codeCooldownSeconds,
                                enabled = !state.submitting && !state.codeRequesting,
                                onClick = vm::requestEmailCode,
                            )
                        },
                    )
                    Spacer(Modifier.height(OrdoSpace.xs))
                    Text(
                        text = stringResource(R.string.auth_code_hint),
                        style = OrdoTheme.type.micro,
                        color = colors.textTertiary,
                    )
                    if (state.devCodeFilled) {
                        // 仅开发模式会走到这里（服务端回显 devCode）；生产恒不显示，流程不依赖它
                        Spacer(Modifier.height(OrdoSpace.xs))
                        Text(
                            text = stringResource(R.string.auth_code_dev_hint),
                            style = OrdoTheme.type.micro,
                            color = colors.accent,
                        )
                    }
                }
                Spacer(Modifier.height(OrdoSpace.m))

                OrdoPrimaryButton(
                    label = stringResource(
                        if (state.loginMethod == AuthMethod.PASSWORD && state.mode == AuthMode.REGISTER) {
                            R.string.auth_register
                        } else {
                            R.string.auth_login
                        },
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
                    enabled = !state.submitting && !state.codeRequesting,
                )
                Spacer(Modifier.height(OrdoSpace.s))
                Text(
                    text = stringResource(R.string.auth_guest_hint),
                    style = OrdoTheme.type.micro,
                    color = colors.textTertiary,
                )

                Spacer(Modifier.height(OrdoSpace.l))

                /*
                 * 底部文本链接（UI §5.1 三入口硬约束）：
                 * 口令模式「还没有账号？注册」/「已有账号？登录」；验证码模式固定回到「口令 + 注册」，
                 * 保证注册入口在任何登录方式下都点得到（§7.6.5 的自动建号不替代显式注册）。
                 */
                Box(
                    Modifier
                        .height(OrdoLayout.touchTarget)
                        .clip(RoundedCornerShape(OrdoRadius.pill))
                        .clickable(
                            enabled = !state.submitting && !state.codeRequesting,
                            onClick = vm::switchAuthLink,
                        )
                        .padding(horizontal = OrdoSpace.l),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = stringResource(
                            if (state.loginMethod == AuthMethod.PASSWORD && state.mode == AuthMode.REGISTER) {
                                R.string.auth_to_login
                            } else {
                                R.string.auth_to_register
                            },
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
                        .clickable(enabled = !state.submitting && !state.codeRequesting) { serverOpen = !serverOpen }
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

/* ==================== 登录方式切换 / 获取验证码（v1.3 · §7.6.5） ==================== */

/**
 * 「口令登录 / 验证码登录」切换：两级**同级**的胶囊标签（选中 accent + accentSoft 底），
 * 触控高度 44（UI §5.1 硬约束），提交中或请求验证码中禁用。
 */
@Composable
private fun AuthMethodTabs(
    current: AuthMethod,
    enabled: Boolean,
    onSelect: (AuthMethod) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AuthMethodTab(
            label = stringResource(R.string.auth_method_password),
            selected = current == AuthMethod.PASSWORD,
            enabled = enabled,
            onClick = { onSelect(AuthMethod.PASSWORD) },
        )
        Spacer(Modifier.width(OrdoSpace.s))
        AuthMethodTab(
            label = stringResource(R.string.auth_method_code),
            selected = current == AuthMethod.EMAIL_CODE,
            enabled = enabled,
            onClick = { onSelect(AuthMethod.EMAIL_CODE) },
        )
    }
}

@Composable
private fun AuthMethodTab(
    label: String,
    selected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = OrdoTheme.colors
    Box(
        Modifier
            .height(OrdoLayout.touchTarget)
            .clip(RoundedCornerShape(OrdoRadius.pill))
            .background(if (selected) colors.accentSoft else Color.Transparent)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = OrdoSpace.l),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = OrdoTheme.type.caption,
            color = if (selected) colors.accent else colors.textSecondary,
        )
    }
}

/**
 * 验证码框尾部的「获取验证码」：
 *  - [CodeSendState.IDLE] 可点（accent）；
 *  - [CodeSendState.SENDING] 转圈（请求中）；
 *  - [CodeSendState.COOLDOWN] 显示剩余秒数并置灰（取服务端 retryAfter，§7.6.5）；
 *  - [CodeSendState.DISABLED] 邮箱不合法 / 正在提交，置灰。
 */
@Composable
private fun CodeSendAction(
    sendState: CodeSendState,
    cooldownSeconds: Int,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = OrdoTheme.colors
    val clickable = enabled && sendState == CodeSendState.IDLE
    Box(
        Modifier
            .height(OrdoLayout.touchTarget)
            .clip(RoundedCornerShape(OrdoRadius.pill))
            .clickable(enabled = clickable, onClick = onClick)
            .padding(horizontal = OrdoSpace.s),
        contentAlignment = Alignment.Center,
    ) {
        when (sendState) {
            CodeSendState.SENDING -> OrdoSpinner(size = 16.dp, color = colors.accent)
            CodeSendState.COOLDOWN -> Text(
                text = stringResource(R.string.auth_code_resend, cooldownSeconds),
                style = OrdoTheme.type.micro,
                color = colors.textTertiary,
            )
            else -> Text(
                text = stringResource(R.string.auth_code_send),
                style = OrdoTheme.type.micro,
                color = if (clickable) colors.accent else colors.textTertiary,
            )
        }
    }
}
