package com.ordo.desktop.app

import com.ordo.core.sync.AuthApi
import com.ordo.core.sync.AuthRequest
import com.ordo.core.sync.EmailCodeLoginRequest
import com.ordo.core.sync.EmailCodeRequest
import com.ordo.core.sync.EmailCodeSent
import com.ordo.core.sync.GuestAuthRequest
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.OrdoSessionStore
import com.ordo.desktop.net.TokenStore
import com.ordo.desktop.net.errorCodeOf
import com.ordo.desktop.net.errorReasonOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 登录页的两种模式(04-UI规范 §5.1:同一张卡片切换「登录 / 注册」文案) */
enum class LoginMode { LOGIN, REGISTER }

/**
 * 登录方式(契约 §7.6.5):口令登录与**邮箱验证码登录同级** ——
 * 它们是同一张卡片上的两个平级入口,不是"藏进二级页面"的附属功能。
 */
enum class LoginMethod { PASSWORD, EMAIL_CODE }

/** 焦点所在的输入框(浮动标签上移 + 转 accent 只跟这个值走) */
enum class LoginField { EMAIL, PASSWORD, CODE }

/**
 * 验证码登录的纯状态机(契约 §7.6.5 / 04-UI规范 §5.1)。
 *
 * 这里只有数据与纯函数:倒计时剩余秒数、按钮可用性、6 位码格式、busy、自动提交判定**全部可单测**,
 * 界面只负责画,控制器只负责发请求与驱动时钟([tick])。
 *
 * 倒计时用**截止时刻**而不是"减一"计数:窗口被挂起/掉帧都不会让倒计时变慢,
 * 掐点重算 `remainingSeconds`,失帧只会少刷几帧而不会算错剩余时间。
 */
data class EmailCodeState(
    val email: String = "",
    val code: String = "",
    /** 验证码有效期(秒,来自响应 `expiresIn`,契约 §7.6.5 = 300) */
    val expiresIn: Long = DEFAULT_EXPIRES_IN,
    /** 倒计时截止时刻(epoch ms);null = 不在倒计时中 */
    val cooldownUntil: Long? = null,
    /** 最近一次算出的剩余秒数(纯计算缓存,由 [tick] / [startCooldown] 写入) */
    val remainingSeconds: Long = 0L,
    val requested: Boolean = false,
    /** 服务端在开发模式回显的验证码(契约 §7.6.5);生产恒为 null,界面不得依赖 */
    val devCode: String? = null,
    /** 服务端要求重新获取验证码(错码超次 / 已过期 / 被限流) */
    val mustRequestAgain: Boolean = false,
    /** 正在发请求(请求验证码 / 提交登录);与 [LoginUiState.busy] 同步,便于单独测这一支 */
    val busy: Boolean = false,
    /**
     * 已经自动提交过的那个码值(契约:满 6 位自动提交)。
     * 记住**码值**而不是布尔位:同一个码只自动提交一次,用户改了一位再满 6 位就会再提交。
     */
    val autoSubmittedCode: String? = null
) {

    /** 倒计时中 →「获取验证码」按钮置灰 */
    val coolingDown: Boolean get() = remainingSeconds > 0L

    /** 按钮文案:倒计时中显示剩余秒数 */
    val requestButtonLabel: String
        get() = if (coolingDown) "${remainingSeconds}s 后重试" else if (requested) "重新获取" else "获取验证码"

    /** 已填够 6 位(自动提交的前提) */
    val codeComplete: Boolean get() = isCompleteCode(code)

    /** 可以请求验证码:邮箱像样 + 不在倒计时 + 没在忙 */
    val canRequestCode: Boolean get() = isValidEmail(email) && !coolingDown && !busy

    /** 可以提交验证码登录 */
    val canSubmitCode: Boolean get() = isValidEmail(email) && codeComplete && !busy

    /**
     * 验证码输入框下方的提示:服务端已判定这个码作废(过期 / 超次 / 被限流)时,
     * 直接告诉用户"再获取一次",而不是让他对着错码反复试。
     */
    val mustRequestAgainHint: String? get() = "请重新获取验证码".takeIf { mustRequestAgain }

    /** 这个码值是否已经自动提交过 */
    fun alreadyAutoSubmitted(): Boolean = autoSubmittedCode != null && autoSubmittedCode == code

    /** 进入倒计时(秒数来自响应 `retryAfter`,契约 §7.6.5 默认 60) */
    fun startCooldown(nowMillis: Long, retryAfterSeconds: Long): EmailCodeState {
        val seconds = retryAfterSeconds.coerceIn(0L, MAX_COOLDOWN_SECONDS)
        if (seconds <= 0L) return copy(cooldownUntil = null, remainingSeconds = 0L)
        return copy(cooldownUntil = nowMillis + seconds * 1000L, remainingSeconds = seconds)
    }

    /** 时钟推进:重算剩余秒数;归零即恢复按钮 */
    fun tick(nowMillis: Long): EmailCodeState {
        val until = cooldownUntil
            ?: return if (remainingSeconds == 0L) this else copy(remainingSeconds = 0L)
        val remaining = ((until - nowMillis) + 999L) / 1000L
        return if (remaining <= 0L) {
            copy(cooldownUntil = null, remainingSeconds = 0L)
        } else {
            copy(remainingSeconds = remaining)
        }
    }

    /** 输入验证码:只留数字并截断到 6 位(粘贴带空格 / 连字符也能用);改码即复位自动提交记录 */
    fun withCodeInput(raw: String): EmailCodeState {
        val digits = raw.filter(Char::isDigit).take(CODE_LENGTH)
        if (digits == code) return this
        return copy(code = digits, autoSubmittedCode = null)
    }

    /** 输入邮箱:换邮箱后旧验证码与"需重新获取"提示都不再适用 */
    fun withEmailInput(raw: String): EmailCodeState =
        if (raw == email) this else copy(email = raw, mustRequestAgain = false)

    companion object {
        /** 契约 §7.6.5:验证码固定 6 位数字 */
        const val CODE_LENGTH = 6

        /** 契约 §7.6.5:`expiresIn = 300` 秒 */
        const val DEFAULT_EXPIRES_IN = 300L

        /** 契约 §7.6.5:`retryAfter = 60` 秒 */
        const val DEFAULT_RETRY_AFTER = 60L

        /** 上限只是防御服务端给出离谱值把按钮永久锁死 */
        const val MAX_COOLDOWN_SECONDS = 3600L

        private val CODE_PATTERN = Regex("^\\d{$CODE_LENGTH}$")

        /** 纯格式判定:验证码必须是 6 位数字(契约 §7.6.5) */
        fun isCompleteCode(code: String): Boolean = CODE_PATTERN.matches(code)

        /** 界面在 requestCode 之后每 1s 调一次 [EmailCodeState.tick] */
        const val TICK_MILLIS = 1_000L

        /** 本地能提前发现的问题(与服务端 VALIDATION_FAILED 对齐,少一次无谓往返) */
        fun isValidEmail(email: String): Boolean {
            val at = email.indexOf('@')
            val dot = email.lastIndexOf('.')
            return email.isNotBlank() && at > 0 && dot > at + 1 && dot < email.length - 1
        }
    }
}


/**
 * 登录页状态(04-UI规范 §5.1 / 契约 §7.6.5)。
 *
 * 纯数据 + 纯计算:文案、可用性、校验、抖动用例都在这里,界面只负责画与转发事件。
 */
data class LoginUiState(
    val mode: LoginMode = LoginMode.LOGIN,
    /** 登录方式(§7.6.5):口令登录 ⇄ 邮箱验证码登录,平级切换 */
    val method: LoginMethod = LoginMethod.PASSWORD,
    val email: String = "",
    val password: String = "",
    val passwordVisible: Boolean = false,
    /** 验证码登录的全部纯状态(倒计时 / 码格式 / canSubmit / busy) */
    val emailCode: EmailCodeState = EmailCodeState(),
    val busy: Boolean = false,
    val focused: LoginField? = null,
    val error: String? = null,
    /** 错误抖动令牌:每次失败自增一次,界面据此播放一次「左右抖动 6px / 320ms」 */
    val errorShake: Long = 0L,
    /** 非错误的提示(如「验证码已发送至 x@y.z」),成功后才出现 */
    val hint: String? = null,
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

    /** 注册模式在验证码方式下没有意义(验证码登录会自动建号),底部链接只在口令方式出现 */
    val showsModeSwitchLink: Boolean get() = method == LoginMethod.PASSWORD

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
 * 错误 → 中文文案(契约 §7.4 冻结错误码 + §7.6.5 的 `details.reason`)。
 *
 * **不新增错误码**:错码 / 过期 / 超次都是 401 `AUTH_INVALID_CREDENTIALS`,靠 `reason` 区分;
 * 限流是 429 `RATE_LIMITED`(`reason = code_throttled`,带 `retryAfterSec`)。
 * 抽成顶层纯函数,便于逐条用例覆盖(界面与控制器共用同一份文案)。
 */
object LoginMessages {

    /** 验证码登录相关的细分文案;reason 为空时回落到通用文案 */
    fun codeError(code: String?, reason: String?): String = when (reason) {
        "code_invalid" -> "验证码不正确，请检查后重试"
        "code_expired" -> "验证码已过期，请重新获取"
        "code_attempts_exceeded" -> "该验证码尝试次数过多，请重新获取"
        "code_throttled" -> "请求过于频繁，请稍后再试"
        else -> when (code) {
            "AUTH_INVALID_CREDENTIALS" -> "验证码不正确或已失效，请重新获取"
            "VALIDATION_FAILED" -> "邮箱或验证码格式不正确（验证码为 6 位数字）"
            "RATE_LIMITED" -> "请求过于频繁，请稍后再试"
            "INTERNAL" -> "服务端出错了，请稍后再试"
            null -> "无法连接服务器，请检查地址与网络"
            else -> "登录失败，请稍后再试"
        }
    }

    /** 提示:验证码已发出 */
    fun codeSent(email: String): String = "验证码已发送至 $email，5 分钟内有效"

    /** 取服务端返回的重试间隔(429 的 `details.retryAfterSec`),缺失时用契约默认 60s */
    fun retryAfterOf(error: Throwable): Long = com.ordo.desktop.net.retryAfterSecondsOf(error)
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

    /** 验证码倒计时的驱动协程;重置表单 / 重新请求时取消重开 */
    private var countdownJob: Job? = null

    fun setEmail(value: String) = _state.update {
        it.copy(email = value, error = null, emailCode = it.emailCode.withEmailInput(value))
    }

    fun setPassword(value: String) = _state.update { it.copy(password = value, error = null) }

    /** 口令显示 / 隐藏切换(§5.1 输入区) */
    fun togglePasswordVisible() = _state.update { it.copy(passwordVisible = !it.passwordVisible) }

    fun setFocused(field: LoginField?) =
        _state.update { if (it.focused == field) it else it.copy(focused = field) }

    fun setMode(mode: LoginMode) = _state.update { it.copy(mode = mode, error = null) }

    /** 底部链接:登录 ⇄ 注册 */
    fun switchMode() = setMode(if (_state.value.mode == LoginMode.LOGIN) LoginMode.REGISTER else LoginMode.LOGIN)

    /**
     * 登录方式切换(契约 §7.6.5):口令 ⇄ 验证码。两种方式平级,共用同一个邮箱输入。
     * 切过去时清掉上一次的错误/提示(两个方式的错误语义不同);倒计时**不重置** —— 服务端的
     * 60s 限流是按邮箱算的,切走再切回来不该白送一次请求。
     */
    fun setMethod(method: LoginMethod) = _state.update {
        if (it.method == method) {
            it
        } else {
            it.copy(method = method, error = null, hint = null, focused = null)
        }
    }

    // ------------------------------------------------------------ 邮箱验证码登录(契约 §7.6.5)

    /** 验证码输入:只收数字、截断 6 位;满 6 位自动提交 */
    fun setCode(value: String) {
        _state.update { it.copy(emailCode = it.emailCode.withCodeInput(value), error = null) }
        autoSubmitIfComplete()
    }

    /**
     * 「获取验证码」(契约 §7.6.5):成功后按响应 `retryAfter` 跑倒计时并置灰按钮。
     *
     * 服务端 429(`code_throttled`)也带 `retryAfterSec`:同样进倒计时,只是文案是限流提示 ——
     * 否则用户会在 60s 里反复点、每次都吃一个 429。
     */
    fun requestCode() {
        val snapshot = _state.value
        if (snapshot.busy) return
        val email = snapshot.email.trim()
        if (!EmailCodeState.isValidEmail(email)) {
            fail("邮箱格式不正确")
            return
        }
        setServerUrl(snapshot.serverUrl)
        setBusy(true)
        // 立刻用契约默认值兜底锁住按钮:服务端限流是"按邮箱 60s",提前锁住才不会连点出一串 429;
        // 成功响应回来后再按响应里的 retryAfter 校准(见 onCodeSent)
        startCooldown(EmailCodeState.DEFAULT_RETRY_AFTER)
        scope.launch {
            runCatching { api.requestEmailCode(EmailCodeRequest(email)) }
                .onSuccess { sent -> onCodeSent(email, sent) }
                .onFailure { error -> onCodeFailed(error) }
        }
    }

    /** 「验证码登录」提交(自动提交与手动点击共用) */
    fun submitEmailCode() {
        val snapshot = _state.value
        if (snapshot.busy) return
        val email = snapshot.email.trim()
        val code = snapshot.emailCode.code
        if (!EmailCodeState.isValidEmail(email)) {
            fail("邮箱格式不正确")
            return
        }
        if (!EmailCodeState.isCompleteCode(code)) {   // 纯格式判定:必须 6 位数字
            fail("请输入 6 位数字验证码")
            return
        }
        setServerUrl(snapshot.serverUrl)
        setBusy(true)
        // 记下这个码值:同一个码只自动提交一次(用户改一位再满 6 位会重新提交)
        _state.update { it.copy(emailCode = it.emailCode.copy(autoSubmittedCode = code)) }
        scope.launch {
            runCatching {
                api.emailLogin(
                    EmailCodeLoginRequest(
                        email = email,
                        code = code,
                        deviceName = deviceName,
                        platform = platform
                    )
                )
            }
                .onSuccess { response -> succeed(OrdoSessionStore.from(response, now())) }
                .onFailure { error -> onCodeLoginFailed(error) }
        }
    }

    /** 满 6 位自动提交(契约:输入满 6 位自动提交);同一个码不重复自动提交 */
    private fun autoSubmitIfComplete() {
        val snapshot = _state.value
        val code = snapshot.emailCode
        if (snapshot.method != LoginMethod.EMAIL_CODE) return
        if (snapshot.busy || !code.codeComplete || code.alreadyAutoSubmitted()) return
        submitEmailCode()
    }

    private fun onCodeSent(email: String, sent: EmailCodeSent) {
        val devCode = sent.devCode
        // 成功响应体顶层是 `retryAfter`(契约 §7.6.5):以它为准校准倒计时(对不上兜底值也不会错)
        val seconds = sent.retryAfter.takeIf { it > 0L } ?: EmailCodeState.DEFAULT_RETRY_AFTER
        _state.update {
            it.copy(
                busy = false,
                error = null,
                hint = LoginMessages.codeSent(email),
                emailCode = it.emailCode.copy(
                    busy = false,
                    requested = true,
                    expiresIn = sent.expiresIn,
                    mustRequestAgain = false,
                    devCode = devCode,
                    // 开发模式会回显 devCode(契约 §7.6.5):联调便利,自动填入;生产恒为 null
                    code = devCode?.filter(Char::isDigit)?.take(EmailCodeState.CODE_LENGTH)
                        ?.takeIf { it.length == EmailCodeState.CODE_LENGTH }
                        ?: it.emailCode.code
                ).startCooldown(now(), seconds)
            )
        }
        // 服务端已经把码替我们填好了 → 直接走一次自动提交判定
        if (devCode != null) autoSubmitIfComplete()
    }

    private fun onCodeFailed(error: Throwable) {
        val message = LoginMessages.codeError(errorCodeOf(error), errorReasonOf(error))
        val retryAfter = LoginMessages.retryAfterOf(error)
        _state.update {
            it.copy(
                busy = false,
                error = message,
                errorShake = it.errorShake + 1L,
                emailCode = it.emailCode.copy(busy = false, mustRequestAgain = true)
                    .startCooldown(now(), retryAfter)
            )
        }
    }

    private fun onCodeLoginFailed(error: Throwable) {
        val reason = errorReasonOf(error)
        val message = LoginMessages.codeError(errorCodeOf(error), reason)
        // 过期 / 超次:这个码已经废了,必须重新获取(错码还可以再试一次)
        val dead = reason == "code_expired" || reason == "code_attempts_exceeded"
        _state.update {
            it.copy(
                busy = false,
                error = message,
                errorShake = it.errorShake + 1L,
                emailCode = it.emailCode.copy(busy = false, mustRequestAgain = it.emailCode.mustRequestAgain || dead)
            )
        }
    }

    /** 进入倒计时并同步"按钮置灰"所需的剩余秒数 */
    private fun startCooldown(seconds: Long) {
        _state.update { it.copy(emailCode = it.emailCode.startCooldown(now(), seconds)) }
        runCountdown()
    }

    /**
     * 倒计时驱动:每秒按**截止时刻**重算剩余秒数(掉帧 / 窗口挂起都不会算错),
     * 归零即退出,按钮由 [EmailCodeState.canRequestCode] 自动恢复可用。
     */
    private fun runCountdown() {
        countdownJob?.cancel()
        countdownJob = scope.launch {
            while (_state.value.emailCode.coolingDown) {
                delay(EmailCodeState.TICK_MILLIS)
                _state.update { it.copy(emailCode = it.emailCode.tick(now())) }
            }
        }
    }

    /** 统一维护 busy:父状态与验证码子状态必须同步(否则按钮可用性会互相矛盾) */
    private fun setBusy(value: Boolean) = _state.update {
        it.copy(busy = value, emailCode = it.emailCode.copy(busy = value))
    }

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
    fun reset(notice: String? = null): Unit {
        countdownJob?.cancel()
        countdownJob = null
        _state.update {
            it.copy(
                email = "",
                password = "",
                passwordVisible = false,
                busy = false,
                focused = null,
                error = null,
                hint = null,
                emailCode = EmailCodeState(),
                notice = notice
            )
        }
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
        setBusy(true)
        _state.update { it.copy(error = null) }
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
        setBusy(true)
        _state.update { it.copy(error = null) }
        val request = GuestAuthRequest(deviceName = deviceName, platform = platform)
        scope.launch {
            runCatching { api.guest(request) }
                .onSuccess { response -> succeed(OrdoSessionStore.from(response, now())) }
                .onFailure { error -> fail(messageOf(error, guest = true)) }
        }
    }

    /** 成功后清掉口令与验证码(不留明文在内存状态里),会话落库,再放行到主界面 */
    private fun succeed(session: OrdoSession) {
        tokens.saveSession(session)
        countdownJob?.cancel()
        countdownJob = null
        _state.update {
            it.copy(
                busy = false,
                error = null,
                hint = null,
                password = "",
                notice = null,
                emailCode = it.emailCode.copy(
                    busy = false,
                    code = "",
                    autoSubmittedCode = null,
                    cooldownUntil = null,
                    remainingSeconds = 0L
                )
            )
        }
        onAuthenticated(session)
    }

    private fun fail(message: String) = _state.update {
        it.copy(
            busy = false,
            error = message,
            errorShake = it.errorShake + 1L,
            emailCode = it.emailCode.copy(busy = false)
        )
    }

    /** 错误码 → 人话(契约 §7.4 错误模型;口令/注册路径) */
    private fun messageOf(error: Throwable, guest: Boolean): String {
        val prefix = if (guest) "游客登录失败：" else ""
        return prefix + when (errorCodeOf(error)) {
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
