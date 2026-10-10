package com.ordo.desktop.app

import com.ordo.core.sync.AuthApi
import com.ordo.core.sync.AuthRequest
import com.ordo.core.sync.GuestAuthRequest
import com.ordo.core.sync.OrdoApiException
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.OrdoSessionStore
import com.ordo.desktop.net.TokenStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 登录页的两种模式(04-UI规范 §5.1:同一张卡片切换「登录 / 注册」文案) */
enum class LoginMode { LOGIN, REGISTER }

/** 焦点所在的输入框(浮动标签上移 + 转 accent 只跟这个值走) */
enum class LoginField { EMAIL, PASSWORD }

/**
 * 登录页状态(04-UI规范 §5.1)。
 *
 * 纯数据 + 纯计算:文案、可用性、校验、抖动用例都在这里,界面只负责画与转发事件。
 */
data class LoginUiState(
    val mode: LoginMode = LoginMode.LOGIN,
    val email: String = "",
    val password: String = "",
    val passwordVisible: Boolean = false,
    val busy: Boolean = false,
    val focused: LoginField? = null,
    val error: String? = null,
    /** 错误抖动令牌:每次失败自增一次,界面据此播放一次「左右抖动 6px / 320ms」 */
    val errorShake: Long = 0L,
    val serverUrl: String = TokenStore.DEFAULT_SERVER,
    /** 会话过期等一次性说明(来自门禁),不是错误 */
    val notice: String? = null
) {
    /** 主按钮文案(§5.1:「登录」/「注册」) */
    val primaryLabel: String get() = if (mode == LoginMode.LOGIN) "登录" else "注册"

    /** 底部文本链接(§5.1:「还没有账号?注册」/「已有账号?登录」) */
    val switchHint: String get() = if (mode == LoginMode.LOGIN) "还没有账号？注册" else "已有账号？登录"

    /** 提交中禁用 + 转圈(§5.1);游客按钮同样禁用 */
    val enabled: Boolean get() = !busy

    /** 邮箱、口令都填了才允许提交(格式问题交给服务端与下面的本地校验) */
    val canSubmit: Boolean get() = !busy && email.isNotBlank() && password.isNotEmpty()

    /** 本地能提前发现的问题(注册要求口令 ≥8,契约 §9) */
    fun validationMessage(): String? = when {
        email.isBlank() -> "请输入邮箱"
        !email.contains('@') -> "邮箱格式不正确"
        password.isEmpty() -> "请输入口令"
        mode == LoginMode.REGISTER && password.length < MIN_PASSWORD -> "口令至少 8 位"
        else -> null
    }

    companion object {
        /** 契约 §9:口令最小长度 8 */
        const val MIN_PASSWORD = 8
    }
}

/**
 * 登录页控制器(契约 §7.6.2 / 04-UI规范 §5.1)。
 *
 * 三个入口共用同一条落地链路:成功后把 [OrdoSession] 写进 [TokenStore](= kv[ordo.session]),
 * 再回调 [onAuthenticated] 让入口切到主界面。**没有任何"游客简化版"分支** ——
 * 游客拿到的也是正常令牌,数据同样入库、同样多端同步(契约 §7.6.1)。
 */
class LoginController(
    private val api: AuthApi,
    private val tokens: TokenStore,
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
    private val onAuthenticated: (OrdoSession) -> Unit = {},
    private val deviceName: String = "Ordo Windows",
    private val platform: String = "windows"
) {

    private val _state = MutableStateFlow(LoginUiState(serverUrl = tokens.serverUrl))
    val state: StateFlow<LoginUiState> = _state.asStateFlow()

    fun setEmail(value: String) = _state.update { it.copy(email = value, error = null) }

    fun setPassword(value: String) = _state.update { it.copy(password = value, error = null) }

    /** 口令显示 / 隐藏切换(§5.1 输入区) */
    fun togglePasswordVisible() = _state.update { it.copy(passwordVisible = !it.passwordVisible) }

    fun setFocused(field: LoginField?) =
        _state.update { if (it.focused == field) it else it.copy(focused = field) }

    fun setMode(mode: LoginMode) = _state.update { it.copy(mode = mode, error = null) }

    /** 底部链接:登录 ⇄ 注册 */
    fun switchMode() = setMode(if (_state.value.mode == LoginMode.LOGIN) LoginMode.REGISTER else LoginMode.LOGIN)

    /** 服务器地址(自建服务 / 本地联调) */
    fun setServerUrl(url: String) {
        tokens.serverUrl = url
        _state.update { it.copy(serverUrl = tokens.serverUrl) }
    }

    /** 门禁带过来的一次性说明(例如"会话已过期") */
    fun applyNotice(notice: String?) = _state.update { it.copy(notice = notice) }

    /**
     * 回到登录页时把表单清干净(退出登录 / 会话过期都用它):
     * 上一次的邮箱与口令既不该留在界面上,也不该在内存状态里过夜。
     */
    fun reset(notice: String? = null) = _state.update {
        it.copy(
            email = "",
            password = "",
            passwordVisible = false,
            busy = false,
            focused = null,
            error = null,
            notice = notice
        )
    }

    /** 主按钮:登录 / 注册 */
    fun submit() {
        val snapshot = _state.value
        if (snapshot.busy) return
        snapshot.validationMessage()?.let { problem ->
            fail(problem)
            return
        }
        setServerUrl(snapshot.serverUrl)
        _state.update { it.copy(busy = true, error = null) }
        val request = AuthRequest(
            email = snapshot.email.trim(),
            password = snapshot.password,
            deviceName = deviceName,
            platform = platform
        )
        scope.launch {
            runCatching { if (snapshot.mode == LoginMode.REGISTER) api.register(request) else api.login(request) }
                .onSuccess { response -> succeed(OrdoSessionStore.from(response, now())) }
                .onFailure { error -> fail(messageOf(error, guest = false)) }
        }
    }

    /** 次要入口「以游客身份继续」(§5.1 硬约束:与正式登录体验对等) */
    fun continueAsGuest() {
        if (_state.value.busy) return
        setServerUrl(_state.value.serverUrl)
        _state.update { it.copy(busy = true, error = null) }
        val request = GuestAuthRequest(deviceName = deviceName, platform = platform)
        scope.launch {
            runCatching { api.guest(request) }
                .onSuccess { response -> succeed(OrdoSessionStore.from(response, now())) }
                .onFailure { error -> fail(messageOf(error, guest = true)) }
        }
    }

    /** 成功后清掉口令(不留明文在内存状态里),会话落库,再放行到主界面 */
    private fun succeed(session: OrdoSession) {
        tokens.saveSession(session)
        _state.update { it.copy(busy = false, error = null, password = "", notice = null) }
        onAuthenticated(session)
    }

    private fun fail(message: String) = _state.update {
        it.copy(busy = false, error = message, errorShake = it.errorShake + 1L)
    }

    /** 错误码 → 人话(契约 §7.4 错误模型) */
    private fun messageOf(error: Throwable, guest: Boolean): String {
        val prefix = if (guest) "游客登录失败：" else ""
        val code = (error as? OrdoApiException)?.code
        return prefix + when (code) {
            "AUTH_INVALID_CREDENTIALS" -> "邮箱或口令不正确"
            "AUTH_EMAIL_TAKEN" -> "该邮箱已被注册，请直接登录或换一个邮箱"
            "VALIDATION_FAILED" -> "邮箱或口令不符合要求（口令至少 ${LoginUiState.MIN_PASSWORD} 位）"
            "RATE_LIMITED" -> "尝试过于频繁，请稍后再试"
            "INTERNAL" -> "服务端出错了，请稍后再试"
            null -> "无法连接服务器，请检查地址与网络"
            else -> error.message.orEmpty().ifBlank { "请求失败" }
        }
    }
}
