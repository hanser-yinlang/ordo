package com.ordo.android.vm

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.ordo.android.R
import com.ordo.android.auth.AuthFieldError
import com.ordo.android.auth.AuthMethod
import com.ordo.android.auth.AuthMode
import com.ordo.android.auth.AuthStage
import com.ordo.android.auth.EmailCodeAction
import com.ordo.android.auth.EmailCodeError
import com.ordo.android.auth.EmailCodeErrorMapper
import com.ordo.android.auth.EmailCodeRules
import com.ordo.android.auth.SessionGate
import com.ordo.android.auth.SessionVerdict
import com.ordo.android.data.SeedData
import com.ordo.android.data.whenValue
import com.ordo.android.di.ServiceLocator
import com.ordo.android.net.OrdoAuthApi
import com.ordo.android.net.OrdoAuthError
import com.ordo.android.sync.RefreshController
import com.ordo.android.sync.RefreshPhase
import com.ordo.android.sync.SyncState
import com.ordo.android.ui.common.OrdoFormatter
import com.ordo.android.ui.theme.ThemeMode
import com.ordo.core.model.CalendarEvent
import com.ordo.core.model.ChecklistItem
import com.ordo.core.model.OrdoSnapshot
import com.ordo.core.model.RepeatFreq
import com.ordo.core.model.RepeatMode
import com.ordo.core.model.RepeatRule
import com.ordo.core.model.Status
import com.ordo.core.model.Todo
import com.ordo.core.store.TodoOptions
import com.ordo.core.model.When
import com.ordo.core.nlp.NaturalDateParser
import com.ordo.core.query.ListQuery
import com.ordo.core.query.ListSection
import com.ordo.core.query.SectionKind
import com.ordo.core.query.SidebarCounts
import com.ordo.core.store.OrdoEngine
import com.ordo.core.sync.AuthRequest
import com.ordo.core.sync.EmailCodeLoginRequest
import com.ordo.core.sync.EmailCodeRequest
import com.ordo.core.sync.GuestAuthRequest
import com.ordo.core.sync.OrdoApiException
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.UpgradeRequest
import com.ordo.core.util.OrdoDate
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * 唯一的 UI 状态持有者。
 *
 * 单向数据流：UI → ViewModel → OrdoEngine（shared:core）→ subscribe 回调 → StateFlow → UI。
 * 所有写操作都必须经过 [OrdoEngine]，ViewModel 不直接改数据（契约 §7.1 本地优先）。
 */
class OrdoViewModel : ViewModel() {

    /**
     * 当前账号的引擎。**不能**在字段初始化时读成 val：
     * 数据目录按账号隔离（契约 §7.6.3），登录/退出都会重新绑定，必须每次取当前账号的那一份。
     */
    private val engine: OrdoEngine get() = ServiceLocator.engine
    private val settings = ServiceLocator.settings
    private val tokens = ServiceLocator.tokens
    private val sessions = ServiceLocator.sessions
    private val scheduler = ServiceLocator.scheduler
    private val authApi: OrdoAuthApi = ServiceLocator.authApi
    private val context: Context = ServiceLocator.appContext
    private val formatter = OrdoFormatter(context)

    /** 刷新控件状态机（UI §5.3）：状态栏刷新键与下拉刷新共用同一份状态 */
    private val refreshController = RefreshController()

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    private var unsubscribe: (() -> Unit)? = null
    private var toastJob: Job? = null
    private var settleJob: Job? = null

    /** 「获取验证码」倒计时协程（每次重新请求都重启） */
    private var codeCooldownJob: Job? = null

    /** 退出登录中：避免"会话被清 → NOT_LOGGED_IN"被误判为令牌失效而重复跳登录页 */
    private var loggingOut = false

    /** 区域折叠是设备本地 UI 偏好（契约 §2.3 的同类本地状态），由界面层持有 */
    private val collapsedAreas = mutableSetOf<String>()

    init {
        viewModelScope.launch {
            settings.themeMode.collect { mode -> _state.update { it.copy(themeMode = mode) } }
        }
        viewModelScope.launch {
            scheduler.state.collect { value ->
                _state.update { it.copy(syncState = value) }
                applySyncState(value)
            }
        }
        viewModelScope.launch {
            refreshController.state.collect { value -> _state.update { it.copy(refresh = value) } }
        }
        viewModelScope.launch {
            _state.update {
                it.copy(
                    eventList = runCatching { SeedData.events() }.getOrDefault(emptyList()),
                    loading = false,
                )
            }
            startGate()
        }
    }

    override fun onCleared() {
        unsubscribe?.invoke()
        super.onCleared()
    }

    /* ============================ 登录门禁 ============================ */

    /**
     * 启动流程（契约 §7.6.4）：
     * ```
     * 读 session
     *   ├─ 有且未过期            → 直接进主界面（后台静默 refresh）
     *   ├─ 有但 accessToken 过期 → 先 refresh；失败 → 登录页（保留 userId 目录）
     *   └─ 无                    → 登录页（登录 / 注册 / 游客登录）
     * ```
     */
    private suspend fun startGate() {
        val session = runCatching { sessions.load() }.getOrNull()
        when (val verdict = SessionGate.decide(session, System.currentTimeMillis())) {
            SessionVerdict.NoSession -> showLogin()

            is SessionVerdict.Ready -> enterMain(verdict.session, silentRefresh = true)

            is SessionVerdict.RefreshFirst -> {
                val refreshed = runCatching { authApi.refresh(verdict.session.refreshToken) }.getOrNull()
                val stored = runCatching { sessions.load() }.getOrNull()
                when (val after = SessionGate.afterRefresh(refreshed != null, stored, verdict.session)) {
                    is SessionVerdict.Ready -> enterMain(after.session, silentRefresh = false)
                    // refresh 失败：回登录页，但只清会话、不清目录（契约 §7.6.3）
                    else -> showLogin()
                }
            }
        }
    }

    /** 进入主界面：绑定该账号的数据目录 → 订阅引擎 → 起实时通道 → 静默同步 */
    private fun enterMain(session: OrdoSession, silentRefresh: Boolean) {
        runCatching { ServiceLocator.bindUser(session.userId, seedIfEmpty = false) }
            .onFailure { showLogin(); return }

        unsubscribe?.invoke()
        unsubscribe = runCatching { engine.subscribe { snapshot -> rebuild(snapshot) } }.getOrNull()

        _state.update {
            it.copy(
                auth = AuthUi(
                    stage = AuthStage.MAIN,
                    displayName = session.displayName(),
                    isGuest = session.isGuest,
                    userId = session.userId,
                    email = session.email.orEmpty(),
                ),
                loading = false,
            )
        }
        rebuild(runCatching { engine.snapshot }.getOrNull())

        ServiceLocator.startRealtime()
        if (silentRefresh) {
            // 后台静默 refresh：失败也不打断使用（accessToken 仍有效，401 时由网络层兜底）
            viewModelScope.launch { runCatching { authApi.refreshSaved() } }
        }
        viewModelScope.launch { runCatching { scheduler.syncOnce() } }
    }

    /** 回到登录页：清空界面数据（**不动**任何用户目录） */
    private fun showLogin(notice: String? = null) {
        unsubscribe?.invoke()
        unsubscribe = null
        ServiceLocator.stopRealtime()
        codeCooldownJob?.cancel()
        codeCooldownJob = null
        _state.update {
            it.copy(
                auth = it.auth.copy(
                    stage = AuthStage.LOGIN,
                    submitting = false,
                    password = "",
                    // 回登录页时旧验证码已失效：清空验证码与倒计时（令牌失效不需要用户等 60s）
                    code = "",
                    codeRequesting = false,
                    codeCooldownSeconds = 0,
                    devCodeFilled = false,
                    error = notice,
                    errorNonce = if (notice == null) it.auth.errorNonce else it.auth.errorNonce + 1,
                ),
                sections = emptyList(),
                agenda = emptyList(),
                areas = emptyList(),
                tags = emptyList(),
                projectHeader = null,
                detail = null,
                selectedTodoId = null,
                totalCount = 0,
                doneCount = 0,
                loading = false,
            )
        }
    }

    fun onAuthEmailChange(value: String) = _state.update {
        it.copy(auth = it.auth.copy(email = value, error = null))
    }

    fun onAuthPasswordChange(value: String) = _state.update {
        it.copy(auth = it.auth.copy(password = value, error = null))
    }

    /** 验证码输入：即时过滤成 6 位数字（粘贴/输入法带杂字符也不会把校验卡死） */
    fun onAuthCodeChange(value: String) = _state.update {
        it.copy(auth = it.auth.copy(code = EmailCodeRules.sanitizeCode(value), error = null))
    }

    fun togglePasswordVisible() = _state.update {
        it.copy(auth = it.auth.copy(passwordVisible = !it.auth.passwordVisible))
    }

    /**
     * 切换登录方式：口令 ⇄ 邮箱验证码（契约 §7.6.5，两者同级）。
     *
     * 切到验证码时强制回到「登录」语义（未注册邮箱自动建号，注册由服务端隐式完成）；
     * 同时清空上一种方式残留的验证码与错误，避免切换后立即触发自动提交。
     */
    fun switchAuthMethod(method: AuthMethod) = _state.update {
        it.copy(
            auth = it.auth.copy(
                loginMethod = method,
                mode = if (method == AuthMethod.EMAIL_CODE) AuthMode.LOGIN else it.auth.mode,
                code = "",
                devCodeFilled = false,
                error = null,
            ),
        )
    }

    /** 底部文本链接：登录态「还没有账号？注册」/ 注册态「已有账号？登录」（口令模式内切换） */
    fun switchAuthMode() = _state.update {
        it.copy(auth = it.auth.copy(mode = it.auth.mode.toggled(), error = null))
    }

    /**
     * 底部文本链接（UI §5.1 三入口硬约束）：
     * 口令模式下切换登录/注册；验证码模式下回到「口令 + 注册」——注册入口任何时候都点得到。
     */
    fun switchAuthLink() {
        val target = EmailCodeRules.linkTarget(_state.value.auth.loginMethod, _state.value.auth.mode)
        _state.update {
            it.copy(
                auth = it.auth.copy(
                    loginMethod = target.method,
                    mode = target.mode,
                    code = "",
                    devCodeFilled = false,
                    error = null,
                ),
            )
        }
    }

    /** 主按钮：按当前登录方式走口令（登录/注册）或验证码登录（UI §5.1 / §7.6.5） */
    fun submitAuth() {
        val auth = _state.value.auth
        if (auth.loginMethod == AuthMethod.EMAIL_CODE) {
            submitEmailCode()
            return
        }
        when (auth.mode) {
            AuthMode.LOGIN -> login(auth.email, auth.password)
            AuthMode.REGISTER -> register(auth.email, auth.password)
        }
    }

    /** 次要按钮「以游客身份继续」：与正式登录**体验对等**（同样写会话、同样同步） */
    fun continueAsGuest() {
        if (_state.value.auth.submitting) return
        setSubmitting(true)
        viewModelScope.launch {
            runCatching { authApi.guest(GuestAuthRequest(deviceId = ServiceLocator.deviceId, deviceName = deviceName(), platform = PLATFORM)) }
                .onSuccess { response -> onAuthSuccess(response.user.id, seedIfEmpty = true) }
                .onFailure { error -> onAuthFailure(error) }
        }
    }

    /* -------------------- 邮箱验证码登录（契约 §7.6.5） -------------------- */

    /**
     * 「获取验证码」：请求 6 位数字码，成功后按响应 `retryAfter` 跑倒计时并置灰按钮。
     *
     * 开发模式服务端可能回显 `devCode`，此处仅**自动填入**（方便联调），
     * 生产恒为 null，界面与流程都不得依赖它。
     */
    fun requestEmailCode() {
        val auth = _state.value.auth
        if (auth.loginMethod != AuthMethod.EMAIL_CODE) return
        if (auth.codeRequesting || auth.submitting) return
        EmailCodeRules.requestBlocker(auth.email)?.let { blocker ->
            failWith(emailCodeErrorText(blocker, null))
            return
        }
        if (auth.codeCooldownSeconds > 0) return // 倒计时中按钮已置灰，这里只是兜底（契约 §7.6.5：60s 内重复请求会被 429）
        setCodeRequesting(true)
        viewModelScope.launch {
            runCatching { authApi.requestEmailCode(EmailCodeRequest(auth.email.trim())) }
                .onSuccess { sent ->
                    val seconds = EmailCodeRules.normalizedRetryAfter(sent.retryAfter)
                    val devCode = sent.devCode
                        ?.let { EmailCodeRules.sanitizeCode(it) }
                        ?.takeIf { it.isNotEmpty() }
                    _state.update {
                        it.copy(
                            auth = it.auth.copy(
                                codeRequesting = false,
                                codeCooldownSeconds = seconds,
                                code = devCode ?: it.auth.code,
                                devCodeFilled = devCode != null,
                                error = null,
                            ),
                        )
                    }
                    startCodeCooldown()
                }
                .onFailure { error -> onEmailCodeFailure(error, EmailCodeAction.REQUEST_CODE) }
        }
    }

    /**
     * 「验证码登录」：邮箱 + 6 位码提交（界面在满 6 位时**自动提交**，也支持手动点主按钮）。
     * 未注册邮箱由服务端自动建号，成功后与口令登录写同一份会话。
     */
    fun submitEmailCode() {
        val auth = _state.value.auth
        if (auth.loginMethod != AuthMethod.EMAIL_CODE) return
        if (auth.submitting || auth.codeRequesting) return
        EmailCodeRules.submitBlocker(auth.email, auth.code)?.let { blocker ->
            failWith(emailCodeErrorText(blocker, null))
            return
        }
        setSubmitting(true)
        viewModelScope.launch {
            val request = EmailCodeLoginRequest(
                email = auth.email.trim(),
                code = auth.code,
                deviceId = ServiceLocator.deviceId,
                deviceName = deviceName(),
                platform = PLATFORM,
            )
            runCatching { authApi.emailLogin(request) }
                .onSuccess { response -> onAuthSuccess(response.user.id, seedIfEmpty = true) }
                .onFailure { error -> onEmailCodeFailure(error, EmailCodeAction.SUBMIT_CODE) }
        }
    }

    /** 验证码流程失败：映射成中文文案 + 抖动；429 时按 retryAfter 直接开始倒计时 */
    private fun onEmailCodeFailure(error: Throwable, action: EmailCodeAction) {
        val kind = EmailCodeErrorMapper.fromThrowable(error, action)
        val retryAfter = EmailCodeErrorMapper.retryAfterOf(error)
        _state.update {
            it.copy(
                auth = it.auth.copy(
                    submitting = false,
                    codeRequesting = false,
                    code = if (EmailCodeRules.clearsCode(kind)) "" else it.auth.code,
                    devCodeFilled = if (EmailCodeRules.clearsCode(kind)) false else it.auth.devCodeFilled,
                ),
            )
        }
        if (kind == EmailCodeError.THROTTLED && retryAfter > 0) {
            _state.update { it.copy(auth = it.auth.copy(codeCooldownSeconds = retryAfter)) }
            startCodeCooldown()
        }
        failWith(emailCodeErrorText(kind, retryAfter))
    }

    /** 倒计时每秒 -1，到 0 自动结束（界面据 codeCooldownSeconds 置灰按钮） */
    private fun startCodeCooldown() {
        codeCooldownJob?.cancel()
        codeCooldownJob = viewModelScope.launch {
            while (true) {
                delay(1_000L)
                val next = EmailCodeRules.tick(_state.value.auth.codeCooldownSeconds)
                _state.update { it.copy(auth = it.auth.copy(codeCooldownSeconds = next)) }
                if (next <= 0) break
            }
        }
    }

    private fun setCodeRequesting(value: Boolean) = _state.update {
        it.copy(auth = it.auth.copy(codeRequesting = value, error = if (value) null else it.auth.error))
    }

    /** 验证码流程失败类型 → 中文文案（错误不靠颜色单独表达，UI §5.1） */
    private fun emailCodeErrorText(error: EmailCodeError, retryAfterSeconds: Int?): String = when (error) {
        EmailCodeError.EMAIL_REQUIRED -> context.getString(R.string.auth_error_email_empty)
        EmailCodeError.EMAIL_INVALID -> context.getString(R.string.auth_error_email_invalid)
        EmailCodeError.CODE_INCOMPLETE -> context.getString(R.string.auth_error_code_incomplete)
        EmailCodeError.CODE_INVALID -> context.getString(R.string.auth_error_code_invalid)
        EmailCodeError.CODE_EXPIRED -> context.getString(R.string.auth_error_code_expired)
        EmailCodeError.CODE_ATTEMPTS_EXCEEDED -> context.getString(R.string.auth_error_code_attempts)
        EmailCodeError.THROTTLED -> context.getString(
            R.string.auth_error_code_throttled,
            retryAfterSeconds ?: EmailCodeRules.DEFAULT_RETRY_AFTER_SECONDS,
        )
        EmailCodeError.MAIL_FAILED -> context.getString(R.string.auth_error_code_mail_failed)
        EmailCodeError.NETWORK -> context.getString(R.string.auth_error_code_network)
        EmailCodeError.UNKNOWN -> context.getString(R.string.auth_error_code_unknown)
    }

    private fun login(email: String, password: String) {
        if (_state.value.auth.submitting) return
        when (val invalid = SessionGate.validate(AuthMode.LOGIN, email, password)) {
            AuthFieldError.NONE -> Unit
            else -> {
                failWith(localErrorText(invalid))
                return
            }
        }
        setSubmitting(true)
        viewModelScope.launch {
            runCatching { authApi.login(AuthRequest(email.trim(), password, deviceName(), PLATFORM)) }
                .onSuccess { response -> onAuthSuccess(response.user.id, seedIfEmpty = true) }
                .onFailure { error -> onAuthFailure(error) }
        }
    }

    private fun register(email: String, password: String) {
        if (_state.value.auth.submitting) return
        when (val invalid = SessionGate.validate(AuthMode.REGISTER, email, password)) {
            AuthFieldError.NONE -> Unit
            else -> {
                failWith(localErrorText(invalid))
                return
            }
        }
        setSubmitting(true)
        viewModelScope.launch {
            runCatching { authApi.register(AuthRequest(email.trim(), password, deviceName(), PLATFORM)) }
                .onSuccess { response -> onAuthSuccess(response.user.id, seedIfEmpty = true) }
                .onFailure { error -> onAuthFailure(error) }
        }
    }

    /** 游客升级为正式账号（契约 §7.6.2）：userId 与数据都不变 */
    fun upgradeGuest(email: String, password: String) {
        val token = tokens.accessToken() ?: return
        when (val invalid = SessionGate.validate(AuthMode.REGISTER, email, password)) {
            AuthFieldError.NONE -> Unit
            else -> {
                failWith(localErrorText(invalid))
                return
            }
        }
        viewModelScope.launch {
            runCatching { authApi.upgrade(token, UpgradeRequest(email.trim(), password)) }
                .onSuccess { response ->
                    _state.update {
                        it.copy(
                            auth = it.auth.copy(
                                isGuest = response.user.isGuest,
                                // 游客没有邮箱 → 退回 userId 作为展示名(契约 §7.6.1)
                                displayName = response.user.email?.takeIf { it.isNotBlank() }
                                    ?: response.user.id,
                                error = null,
                            ),
                        )
                    }
                    showToast(context.getString(R.string.toast_upgrade_ok))
                }
                .onFailure { error -> failWith(loginErrorMessage(error)) }
        }
    }

    /** 登录/注册/游客成功后：绑定该账号的数据目录并进入主界面（契约 §7.6.3） */
    private fun onAuthSuccess(userId: String, seedIfEmpty: Boolean) {
        val session = runCatching { sessions.load() }.getOrNull()
        if (session == null) {
            onAuthFailure(IllegalStateException(context.getString(R.string.auth_error_no_session)))
            return
        }
        runCatching { ServiceLocator.bindUser(userId, seedIfEmpty = seedIfEmpty) }
            .onFailure { error -> onAuthFailure(error); return }
        enterMain(session, silentRefresh = false)
        showToast(context.getString(R.string.toast_login_ok))
    }

    private fun onAuthFailure(error: Throwable) {
        _state.update { it.copy(auth = it.auth.copy(submitting = false)) }
        failWith(loginErrorMessage(error))
    }

    private fun setSubmitting(value: Boolean) = _state.update {
        it.copy(auth = it.auth.copy(submitting = value, error = if (value) null else it.auth.error))
    }

    /** 失败：文案 + 抖动（errorNonce 递增，界面据此重放抖动动画） */
    private fun failWith(message: String) = _state.update {
        it.copy(
            auth = it.auth.copy(
                submitting = false,
                error = message,
                errorNonce = it.auth.errorNonce + 1,
            ),
        )
    }

    private fun localErrorText(error: AuthFieldError): String = context.getString(
        when (error) {
            AuthFieldError.EMAIL_EMPTY -> R.string.auth_error_email_empty
            AuthFieldError.EMAIL_INVALID -> R.string.auth_error_email_invalid
            AuthFieldError.PASSWORD_EMPTY -> R.string.auth_error_password_empty
            AuthFieldError.PASSWORD_TOO_SHORT -> R.string.auth_error_password_short
            AuthFieldError.NONE -> R.string.auth_error_email_empty
        },
    )

    private fun deviceName(): String =
        runCatching { "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim() }
            .getOrDefault("Android 设备")

    /* ============================== 导航 ============================== */

    fun navigate(routeKey: String) {
        _state.update {
            it.copy(
                routeKey = routeKey,
                selectedTodoId = null,
                detail = null,
                sidebarOpen = false,
                fastFindOpen = false,
                composer = it.composer.closed(),
                scheduleTarget = null,
                searchQuery = if (routeKey == UiState.ROUTE_SEARCH) it.searchQuery else "",
                searchResults = if (routeKey == UiState.ROUTE_SEARCH) it.searchResults else emptyList(),
            )
        }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun openDetail(todoId: String) {
        _state.update { it.copy(selectedTodoId = todoId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun closeDetail() = _state.update { it.copy(selectedTodoId = null, detail = null) }

    fun toggleSidebar(open: Boolean) = _state.update { it.copy(sidebarOpen = open) }

    fun openFastFind() = _state.update { it.copy(fastFindOpen = true) }

    fun closeFastFind() = _state.update { it.copy(fastFindOpen = false, searchQuery = "", searchResults = emptyList()) }

    fun openQuickAddMenu(open: Boolean) = _state.update { it.copy(quickAddMenuOpen = open) }

    /**
     * 快加号单击（UI §5.2）：只保留一个 FAB，按"菜单是否已展开"分两种语义。
     *   菜单未展开 → 打开行内输入行（聚焦 + 弹软键盘）
     *   菜单已展开 → 收起菜单（按钮转回 0°），**不**打开输入行
     */
    fun onQuickAddTap() {
        if (_state.value.quickAddMenuOpen) {
            openQuickAddMenu(false)
        } else {
            openComposer(composerTarget())
        }
    }

    /** 快加号长按 400ms（UI §5.2）：从按钮左上方弹出快捷菜单，按钮旋转 45° */
    fun onQuickAddLongPress() = openQuickAddMenu(true)

    /** 菜单落地目标：当前处于项目/区域视图时把新待办直接放进去 */
    fun composerTarget(): String? = when (val route = _state.value.routeKey) {
        UiState.ROUTE_TODAY -> null
        else -> route.takeIf { it.startsWith(ROUTE_PROJECT_PREFIX) || it.startsWith(ROUTE_AREA_PREFIX) }
    }

    /**
     * 快加号菜单「新建标题」：标题必须属于某个项目（契约 §2.3），
     * 因此只在项目视图里创建；其它视图给出明确提示，而不是偷偷建到别的项目里。
     */
    fun createHeadingFromQuickAdd(name: String) {
        val projectId = _state.value.routeKey
            .takeIf { it.startsWith(ROUTE_PROJECT_PREFIX) }
            ?.removePrefix(ROUTE_PROJECT_PREFIX)
        if (projectId.isNullOrBlank()) {
            openQuickAddMenu(false)
            showToast(context.getString(R.string.quickadd_heading_need_project))
            return
        }
        val value = name.trim().ifEmpty { context.getString(R.string.heading_default_name) }
        createHeading(projectId, value)
        openQuickAddMenu(false)
    }

    /**
     * 长按拖拽落库（UI §5.4）：只重排**同一分组内**的待办。
     * 位置未变时界面层不会调用本方法（契约要求"位置未变则不写库"）。
     */
    fun reorderSection(orderedIds: List<String>) {
        if (orderedIds.size < 2) return
        runCatching { engine.reorderTodos(orderedIds) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    /* ============================ 状态重建 ============================ */

    private fun rebuild(snapshot: OrdoSnapshot?) {
        if (snapshot == null) return
        val route = _state.value.routeKey
        val sections = runCatching { buildSections(route, snapshot) }.getOrDefault(emptyList())
        val visible = sections.flatMap { it.todos }

        _state.update { current ->
            current.copy(
                loading = false,
                title = titleFor(route, snapshot),
                subtitle = subtitleFor(route, sections, snapshot),
                sections = sections,
                agenda = if (route == UiState.ROUTE_TODAY) buildAgenda() else emptyList(),
                counts = runCatching { engine.counts().toUi() }.getOrDefault(current.counts),
                areas = buildAreaNodes(snapshot),
                tags = buildTagNodes(snapshot),
                projectHeader = buildProjectHeader(route, snapshot),
                detail = current.selectedTodoId?.let { id -> buildDetail(id, snapshot) },
                totalCount = visible.size,
                doneCount = visible.count { it.status != Status.OPEN },
            )
        }
    }

    private fun buildSections(route: String, snapshot: OrdoSnapshot): List<SectionUi> = when {
        route == UiState.ROUTE_SEARCH || route == UiState.ROUTE_SETTINGS -> emptyList()

        route.startsWith(ROUTE_PROJECT_PREFIX) -> {
            val projectId = route.removePrefix(ROUTE_PROJECT_PREFIX)
            val collapsed = engine.headingsOf(projectId).associate { it.id to it.collapsed }
            engine.sections(ListQuery.ProjectScope(projectId)).map { section ->
                section.toUi(snapshot, collapsed[section.headingId] ?: false)
            }
        }

        route.startsWith(ROUTE_AREA_PREFIX) -> {
            val areaId = route.removePrefix(ROUTE_AREA_PREFIX)
            groupByProject(engine.list(ListQuery.AreaScope(areaId)), snapshot)
        }

        route.startsWith(ROUTE_TAG_PREFIX) -> {
            val name = URLDecoder.decode(route.removePrefix(ROUTE_TAG_PREFIX), "UTF-8")
            val todos = engine.list(ListQuery.TagScope(name, includeCompleted = _state.value.showCompleted))
            listOf(
                SectionUi(
                    title = null,
                    kind = SectionKind.PLAIN,
                    todos = todos.map { it.toRow() },
                ),
            )
        }

        else -> engine.sections(queryFor(route)).map { section -> section.toUi(snapshot, false) }
    }

    private fun queryFor(route: String): ListQuery = when (route) {
        UiState.ROUTE_INBOX -> ListQuery.Inbox
        UiState.ROUTE_UPCOMING -> ListQuery.Upcoming
        UiState.ROUTE_ANYTIME -> ListQuery.Anytime
        UiState.ROUTE_SOMEDAY -> ListQuery.Someday
        UiState.ROUTE_LOGBOOK -> ListQuery.Logbook
        else -> ListQuery.Today
    }

    private fun groupByProject(todos: List<Todo>, snapshot: OrdoSnapshot): List<SectionUi> =
        todos.groupBy { it.projectId }
            .map { (projectId, list) ->
                SectionUi(
                    title = projectId?.let { id -> snapshot.projects.firstOrNull { it.id == id }?.name }
                        ?: context.getString(R.string.detail_no_project),
                    kind = SectionKind.PLAIN,
                    todos = list.map { it.toRow() },
                )
            }
            .sortedBy { it.title }

    private fun ListSection.toUi(snapshot: OrdoSnapshot, collapsed: Boolean): SectionUi = SectionUi(
        title = title,
        kind = kind,
        todos = todos.map { it.toRow() },
        headingId = headingId,
        collapsed = collapsed,
    )

    private fun Todo.toRow(): TodoRowUi = TodoRowUi(
        id = id,
        title = title,
        notePreview = formatter.plainPreview(note).take(90),
        status = status,
        whenValue = whenValue,
        whenLabel = when (whenValue) {
            When.DATE, When.TODAY, When.EVENING -> formatter.whenLabel(whenValue, date)
            else -> null
        },
        reminderLabel = formatter.reminderLabel(reminder),
        reminderPast = formatter.reminderPast(reminder) && status == Status.OPEN,
        deadlineLabel = formatter.shortDate(deadline),
        deadlineOverdue = formatter.deadlineOverdue(deadline) && status == Status.OPEN,
        tags = tags,
        checklistDone = checklistDone,
        checklistTotal = checklist.size,
        hasNote = note.isNotBlank(),
        repeat = repeat != null,
        completedAtLabel = if (status != Status.OPEN) formatter.completedLabel(completedAt) else null,
    )

    private fun buildAgenda(): List<AgendaItemUi> {
        val now = OrdoDate.nowHHmm()
        return _state.value.eventList
            .filter { OrdoDate.datePartOf(it.start) == OrdoDate.todayISO() }
            .sortedBy { it.start }
            .map { event ->
                AgendaItemUi(
                    id = event.id,
                    time = OrdoDate.timePartOf(event.start) ?: event.start,
                    title = event.title,
                    calendar = event.calendar,
                    past = (OrdoDate.timePartOf(event.start) ?: "") < now,
                )
            }
    }

    private fun buildAreaNodes(snapshot: OrdoSnapshot): List<AreaNodeUi> {
        val counts = runCatching { engine.counts() }.getOrNull()
        return snapshot.areas
            .filter { !it.deleted && !it.archived }
            .sortedBy { it.order }
            .map { area ->
                val projects = snapshot.projects
                    .filter { it.areaId == area.id && !it.deleted && it.status == Status.OPEN }
                    .sortedBy { it.order }
                    .map { project ->
                        ProjectNodeUi(
                            id = project.id,
                            name = project.name,
                            areaId = project.areaId,
                            progress = counts?.projectProgress?.get(project.id)
                                ?: engine.projectProgress(project.id),
                            openCount = counts?.projects?.get(project.id)
                                ?: snapshot.todos.count { it.projectId == project.id && it.isOpen && !it.deleted },
                        )
                    }
                AreaNodeUi(
                    id = area.id,
                    name = area.name,
                    color = area.color,
                    collapsed = collapsedAreas.contains(area.id),
                    projects = projects,
                )
            }
    }

    private fun buildTagNodes(snapshot: OrdoSnapshot): List<TagNodeUi> {
        val counts = runCatching { engine.counts() }.getOrNull()
        return engine.tags().map { tag ->
            TagNodeUi(
                name = tag.name,
                color = tag.color,
                count = counts?.tags?.get(tag.name)
                    ?: snapshot.todos.count { !it.deleted && it.isOpen && it.tags.contains(tag.name) },
            )
        }
    }

    private fun buildProjectHeader(route: String, snapshot: OrdoSnapshot): ProjectHeaderUi? {
        if (!route.startsWith(ROUTE_PROJECT_PREFIX)) return null
        val project = engine.project(route.removePrefix(ROUTE_PROJECT_PREFIX)) ?: return null
        val children = snapshot.todos.filter { it.projectId == project.id && !it.deleted }
        return ProjectHeaderUi(
            id = project.id,
            name = project.name,
            note = project.note,
            areaName = project.areaId?.let { id -> snapshot.areas.firstOrNull { it.id == id }?.name },
            progress = engine.projectProgress(project.id),
            doneCount = children.count { it.status != Status.OPEN },
            openCount = children.count { it.isOpen },
            headings = engine.headingsOf(project.id).map {
                HeadingUi(id = it.id, name = it.name, collapsed = it.collapsed, archived = it.archived)
            },
            status = project.status,
        )
    }

    private fun buildDetail(todoId: String, snapshot: OrdoSnapshot): DetailUi? {
        val todo = engine.todo(todoId) ?: return null
        return DetailUi(
            id = todo.id,
            title = todo.title,
            note = todo.note,
            whenValue = todo.whenValue,
            whenLabel = formatter.whenLabel(todo.whenValue, todo.date),
            deadlineLabel = formatter.shortDate(todo.deadline),
            deadlineOverdue = formatter.deadlineOverdue(todo.deadline) && todo.isOpen,
            reminderLabel = formatter.reminderLabel(todo.reminder),
            reminderRaw = todo.reminder,
            reminderPast = formatter.reminderPast(todo.reminder) && todo.isOpen,
            repeatLabel = formatter.repeatLabel(todo.repeat?.freq, todo.repeat?.mode),
            repeatFreq = todo.repeat?.freq,
            repeatMode = todo.repeat?.mode,
            projectId = todo.projectId,
            projectName = todo.projectId?.let { id -> snapshot.projects.firstOrNull { it.id == id }?.name },
            tags = todo.tags,
            checklist = todo.checklist.map { ChecklistItemUi(it.id, it.title, it.done) },
            status = todo.status,
        )
    }

    private fun titleFor(route: String, snapshot: OrdoSnapshot): String = when {
        route == UiState.ROUTE_INBOX -> context.getString(R.string.nav_inbox)
        route == UiState.ROUTE_TODAY -> context.getString(R.string.nav_today)
        route == UiState.ROUTE_UPCOMING -> context.getString(R.string.nav_upcoming)
        route == UiState.ROUTE_ANYTIME -> context.getString(R.string.nav_anytime)
        route == UiState.ROUTE_SOMEDAY -> context.getString(R.string.nav_someday)
        route == UiState.ROUTE_LOGBOOK -> context.getString(R.string.nav_logbook)
        route == UiState.ROUTE_SEARCH -> context.getString(R.string.common_search)
        route == UiState.ROUTE_SETTINGS -> context.getString(R.string.settings_title)
        route.startsWith(ROUTE_PROJECT_PREFIX) ->
            engine.project(route.removePrefix(ROUTE_PROJECT_PREFIX))?.name
                ?: context.getString(R.string.nav_anytime)
        route.startsWith(ROUTE_AREA_PREFIX) -> snapshot.areas
            .firstOrNull { it.id == route.removePrefix(ROUTE_AREA_PREFIX) }?.name
            ?: context.getString(R.string.nav_section_areas)
        route.startsWith(ROUTE_TAG_PREFIX) -> URLDecoder.decode(route.removePrefix(ROUTE_TAG_PREFIX), "UTF-8")
        else -> context.getString(R.string.app_name)
    }

    private fun subtitleFor(route: String, sections: List<SectionUi>, snapshot: OrdoSnapshot): String {
        val count = sections.sumOf { it.todos.size }
        return when {
            route == UiState.ROUTE_TODAY -> context.getString(R.string.subtitle_today, count)
            route == UiState.ROUTE_UPCOMING -> context.getString(R.string.subtitle_upcoming, count)
            route == UiState.ROUTE_LOGBOOK -> context.getString(R.string.subtitle_logbook, count)
            route.startsWith(ROUTE_PROJECT_PREFIX) -> {
                val projectId = route.removePrefix(ROUTE_PROJECT_PREFIX)
                val open = snapshot.todos.count { it.projectId == projectId && it.isOpen && !it.deleted }
                context.getString(
                    R.string.subtitle_project,
                    (engine.projectProgress(projectId) * 100).toInt(),
                    open,
                )
            }
            else -> context.getString(R.string.subtitle_count, count)
        }
    }

    /* ============================== 写操作 ============================== */

    fun toggleDone(todoId: String) {
        runCatching { engine.toggleDone(todoId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun updateTitle(todoId: String, title: String) {
        val trimmed = title.trim()
        if (trimmed.isEmpty()) {
            deleteTodo(todoId)
            return
        }
        runCatching { engine.setTitle(todoId, trimmed) }
    }

    fun updateNote(todoId: String, note: String) {
        runCatching { engine.setNote(todoId, note) }
    }

    fun setWhen(todoId: String, `when`: When, date: String? = null) {
        runCatching { engine.setWhen(todoId, `when`, date) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun setDeadline(todoId: String, date: String?) {
        runCatching { engine.setDeadline(todoId, date) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun setReminder(todoId: String, reminder: String?) {
        runCatching { engine.setReminder(todoId, reminder) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    /** 提醒：今天/明天 + HH:mm（写入后由引擎按契约 §3 自动对齐 `when`） */
    fun setReminderAt(todoId: String, hourMinute: String, tomorrow: Boolean = false) {
        val normalized = OrdoDate.normalizeTime(hourMinute) ?: hourMinute
        val day = if (tomorrow) OrdoDate.plusDays(OrdoDate.todayISO(), 1) else OrdoDate.todayISO()
        setReminder(todoId, OrdoDate.dateTime(day, normalized))
        showToast(context.getString(R.string.toast_reminder_set, normalized))
    }

    fun clearReminder(todoId: String) {
        setReminder(todoId, null)
        showToast(context.getString(R.string.schedule_reminder_clear))
    }

    fun setRepeat(todoId: String, freq: RepeatFreq?, mode: RepeatMode = RepeatMode.FIXED) {
        runCatching { engine.setRepeat(todoId, freq?.let { RepeatRule(freq = it, interval = 1, mode = mode) }) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun addTag(todoId: String, tag: String) {
        val value = tag.trim().removePrefix("#")
        if (value.isEmpty()) return
        runCatching { engine.ensureTag(value) }
        runCatching { engine.addTag(todoId, value) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun removeTag(todoId: String, tag: String) {
        runCatching { engine.removeTag(todoId, tag) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun toggleChecklistItem(todoId: String, itemId: String) {
        runCatching { engine.toggleChecklistItem(todoId, itemId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun addChecklistItem(todoId: String, title: String) {
        val value = title.trim()
        if (value.isEmpty()) return
        runCatching { engine.addChecklistItem(todoId, value) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun deleteTodo(todoId: String) {
        runCatching { engine.deleteTodo(todoId) }
        _state.update { it.copy(selectedTodoId = null, detail = null) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
        showToast(context.getString(R.string.toast_deleted))
    }

    fun duplicateTodo(todoId: String) {
        runCatching { engine.duplicateTodo(todoId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
        showToast(context.getString(R.string.toast_duplicated))
    }

    fun moveTodo(todoId: String, projectId: String?, areaId: String?, headingId: String?) {
        runCatching { engine.moveTodo(todoId, projectId, areaId, headingId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    /**
     * 完成项目（契约 §2.2 v1.1）。
     *
     * 唯一硬约束是「项目下没有未完成的待办」；标题未归档不再阻塞（引擎会自动归档）。
     * 提示文案与实际原因必须一致：拒绝时带上是多少项未完成，且不再提「标题」。
     */
    fun completeProject(projectId: String) {
        val statusBefore = runCatching { engine.project(projectId)?.status }.getOrNull()
        val openCount = runCatching { engine.counts().projects[projectId] ?: 0 }.getOrDefault(0)
        val completed = runCatching { engine.completeProject(projectId) }.getOrDefault(false)
        rebuild(runCatching { engine.snapshot }.getOrNull())
        val outcome = resolveProjectComplete(completed, statusBefore, openCount)
        showToast(context.getString(outcome.messageRes, *outcome.messageArgs()))
    }

    /** 重新打开已完成的项目（卡片在 DONE 时显示「重新打开」而不是「完成项目」） */
    fun reopenProject(projectId: String) {
        runCatching { engine.reopenProject(projectId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
        showToast(context.getString(R.string.toast_project_reopened))
    }

    fun renameProject(projectId: String, name: String) {
        val value = name.trim()
        if (value.isEmpty()) return
        runCatching { engine.renameProject(projectId, value) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun createProject(name: String, areaId: String?) {
        val value = name.trim()
        if (value.isEmpty()) return
        val project = runCatching { engine.createProject(value, areaId) }.getOrNull() ?: return
        showToast(context.getString(R.string.toast_project_created, project.name))
        navigate("$ROUTE_PROJECT_PREFIX${project.id}")
    }

    fun createArea(name: String) {
        val value = name.trim()
        if (value.isEmpty()) return
        runCatching { engine.createArea(value) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
        showToast(context.getString(R.string.toast_area_created, value))
    }

    fun createHeading(projectId: String, name: String) {
        val value = name.trim()
        if (value.isEmpty()) return
        runCatching { engine.createHeading(projectId, value) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun toggleHeadingCollapsed(headingId: String) {
        runCatching { engine.toggleHeadingCollapsed(headingId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun toggleAreaCollapsed(areaId: String) {
        if (!collapsedAreas.add(areaId)) collapsedAreas.remove(areaId)
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun toggleShowCompleted() {
        _state.update { it.copy(showCompleted = !it.showCompleted) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun restore(todoId: String) {
        runCatching { engine.reopen(todoId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
        showToast(context.getString(R.string.toast_restored))
    }

    /* ============================ 新建（快加） ============================ */

    /**
     * 打开「新建待办」浮层。
     *
     * 已经打开时**不是空操作**：保留已输入的草稿，只递增 `focusRequest`，
     * 界面据此重新聚焦输入框并弹起软键盘（实测缺陷「点加号没反应」的修复点之一）。
     */
    fun openComposer(target: String?) = _state.update {
        it.copy(composer = it.composer.opened(target), quickAddMenuOpen = false)
    }

    fun updateComposerDraft(text: String) = _state.update { it.copy(composer = it.composer.edited(text)) }

    /** 关闭浮层：草稿丢弃；空标题不会留下任何待办 */
    fun closeComposer() = _state.update { it.copy(composer = it.composer.closed()) }

    /** 提交新待办；标题里的日期/时间/标签由 core 的 NLP 解析（契约 §5） */
    fun submitComposer() {
        when (val verdict = _state.value.composer.submission()) {
            ComposerState.Submission.Empty -> closeComposer()

            is ComposerState.Submission.Create -> {
                val target = _state.value.composer.target
                val options = TodoOptions(
                    `when` = when (val route = _state.value.routeKey) {
                        UiState.ROUTE_TODAY -> When.TODAY
                        UiState.ROUTE_SOMEDAY -> When.SOMEDAY
                        UiState.ROUTE_ANYTIME -> When.ANYTIME
                        else -> if (route.startsWith(ROUTE_PROJECT_PREFIX)) When.ANYTIME else null
                    },
                    projectId = target?.takeIf { it.startsWith(ROUTE_PROJECT_PREFIX) }?.removePrefix(ROUTE_PROJECT_PREFIX),
                    areaId = target?.takeIf { it.startsWith(ROUTE_AREA_PREFIX) }?.removePrefix(ROUTE_AREA_PREFIX),
                    headingId = target?.takeIf { it.startsWith(HEADING_PREFIX) }?.removePrefix(HEADING_PREFIX),
                )
                val created = runCatching { engine.createTodo(verdict.title, options) }.getOrNull()
                closeComposer()
                rebuild(runCatching { engine.snapshot }.getOrNull())
                if (created != null) showToast(context.getString(R.string.toast_todo_created, created.title))
            }
        }
    }

    /* ============================ 排期面板 ============================ */

    fun openSchedule(todoId: String, forDeadline: Boolean = false) =
        _state.update { it.copy(scheduleTarget = ScheduleTargetUi(todoId, forDeadline)) }

    fun closeSchedule() = _state.update { it.copy(scheduleTarget = null) }

    fun applySchedule(`when`: When, date: String? = null) {
        val target = _state.value.scheduleTarget ?: return
        if (target.forDeadline) setDeadline(target.todoId, date) else setWhen(target.todoId, `when`, date)
        closeSchedule()
    }

    fun applyScheduleDate(date: String) {
        val target = _state.value.scheduleTarget ?: return
        if (target.forDeadline) setDeadline(target.todoId, date) else setWhen(target.todoId, When.DATE, date)
        closeSchedule()
    }

    fun applyScheduleTonight() {
        val target = _state.value.scheduleTarget ?: return
        setWhen(target.todoId, When.EVENING)
        closeSchedule()
    }

    fun applyScheduleTomorrow() = applyScheduleDate(OrdoDate.plusDays(OrdoDate.todayISO(), 1))

    fun applyScheduleWeekend() {
        val today = OrdoDate.todayISO()
        val offset = (6 - OrdoDate.dayOfWeek(today) + 7) % 7
        applyScheduleDate(OrdoDate.plusDays(today, if (offset == 0) 7 else offset))
    }

    fun applyScheduleSomeday() = applySchedule(When.SOMEDAY)

    fun clearScheduleTarget() {
        val target = _state.value.scheduleTarget ?: return
        if (target.forDeadline) setDeadline(target.todoId, null) else setWhen(target.todoId, When.ANYTIME)
        closeSchedule()
    }

    /** 排期面板里的自然语言输入：交给 core 的 NaturalDateParser（契约 §5） */
    fun applyNaturalLanguage(text: String) {
        val target = _state.value.scheduleTarget ?: return
        val parsed = runCatching { NaturalDateParser.parse(text) }.getOrNull()
        if (parsed == null) {
            closeSchedule()
            return
        }
        if (target.forDeadline) {
            setDeadline(target.todoId, parsed.date)
        } else {
            val `when` = parsed.`when` ?: if (parsed.date != null) When.DATE else When.ANYTIME
            setWhen(target.todoId, `when`, parsed.date)
            parsed.reminder?.let { setReminder(target.todoId, it) }
        }
        parsed.tags.forEach { addTag(target.todoId, it) }
        closeSchedule()
    }

    /* ============================== 快找 ============================== */

    fun onSearchQueryChange(query: String) {
        _state.update { it.copy(searchQuery = query) }
        val keyword = query.trim()
        if (keyword.isEmpty()) {
            _state.update { it.copy(searchResults = emptyList()) }
            return
        }
        val snapshot = runCatching { engine.snapshot }.getOrNull() ?: return
        val lower = keyword.lowercase().removePrefix("#")
        val results = mutableListOf<SearchResultUi>()

        runCatching { engine.list(ListQuery.Search(keyword)) }
            .getOrDefault(emptyList())
            .take(SEARCH_LIMIT)
            .forEach { todo ->
                results += SearchResultUi(
                    id = todo.id,
                    kind = SearchKind.TODO,
                    title = todo.title,
                    subtitle = formatter.plainPreview(todo.note).take(40).takeIf { it.isNotBlank() },
                    route = ROUTE_DETAIL_PREFIX + todo.id,
                )
            }

        snapshot.projects
            .filter { !it.deleted && it.name.lowercase().contains(lower) }
            .take(SEARCH_LIMIT)
            .forEach { project ->
                results += SearchResultUi(
                    id = project.id,
                    kind = SearchKind.PROJECT,
                    title = project.name,
                    subtitle = context.getString(R.string.fastfind_project),
                    route = "$ROUTE_PROJECT_PREFIX${project.id}",
                )
            }

        snapshot.areas
            .filter { !it.deleted && it.name.lowercase().contains(lower) }
            .take(SEARCH_LIMIT)
            .forEach { area ->
                results += SearchResultUi(
                    id = area.id,
                    kind = SearchKind.AREA,
                    title = area.name,
                    subtitle = context.getString(R.string.nav_section_areas),
                    route = "$ROUTE_AREA_PREFIX${area.id}",
                )
            }

        engine.tags()
            .filter { it.name.lowercase().contains(lower) }
            .take(SEARCH_LIMIT)
            .forEach { tag ->
                results += SearchResultUi(
                    id = tag.name,
                    kind = SearchKind.TAG,
                    title = "#${tag.name}",
                    subtitle = context.getString(R.string.nav_section_tags),
                    route = "$ROUTE_TAG_PREFIX${URLEncoder.encode(tag.name, "UTF-8")}",
                )
            }

        _state.update { it.copy(searchResults = results.take(SEARCH_LIMIT * 2)) }
    }

    /* ============================== 设置 ============================== */

    fun setThemeMode(mode: ThemeMode) {
        viewModelScope.launch { settings.setThemeMode(mode) }
    }

    fun cycleTheme() {
        viewModelScope.launch { settings.setThemeMode(_state.value.themeMode.next()) }
    }

    /** 重置为示例数据（core 负责内容） */
    fun resetToSeed() {
        runCatching { engine.seedDemoData(force = true) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
        showToast(context.getString(R.string.toast_reset))
    }

    /* ============================== 同步 · 刷新 ============================== */

    /**
     * 状态栏刷新键（UI §5.3）与下拉刷新共用这一条路径，因此两处表现必然一致。
     * 同步中、或成功后 1.4s 防抖窗口内的点按是空操作。
     */
    fun refresh() {
        if (!tokens.isLoggedIn()) {
            refreshController.onNotLoggedIn()
            return
        }
        if (!refreshController.onClick()) return
        viewModelScope.launch { runCatching { scheduler.syncOnce() } }
    }

    /** 设置页的「立即同步」：走同一条路径，用户同样能看到图标连续旋转 */
    fun syncNow() = refresh()

    /**
     * 同步状态 → 刷新控件（把控制器做成 [SyncScheduler] 状态的**投影**，
     * 于是轮询 / 回前台 / 网络恢复触发的同步同样有转圈反馈）。
     */
    private fun applySyncState(value: SyncState) {
        val control = refreshController.state.value
        when (value) {
            SyncState.SYNCING -> refreshController.requestSync()

            SyncState.IDLE -> when (control.phase) {
                RefreshPhase.SYNCING -> {
                    refreshController.onSyncFinished(true)
                    settleJob?.cancel()
                    settleJob = viewModelScope.launch {
                        delay(RefreshController.SETTLE_MILLIS)
                        refreshController.settle()
                    }
                }
                RefreshPhase.SUCCESS, RefreshPhase.FAILED -> Unit
                RefreshPhase.IDLE -> refreshController.onIdle()
            }

            SyncState.FAILED -> if (control.phase == RefreshPhase.SYNCING) refreshController.onSyncFinished(false)

            SyncState.OFFLINE -> refreshController.onOffline()

            SyncState.NOT_LOGGED_IN -> {
                refreshController.onNotLoggedIn()
                // 令牌失效（refresh 也失败）→ 转登录态，但**本地数据目录保留**（契约 §7.4 / §7.6.3）
                if (!loggingOut && _state.value.auth.stage == AuthStage.MAIN) {
                    ServiceLocator.unbindUser()
                    showLogin(context.getString(R.string.auth_error_session_expired))
                }
            }
        }
    }

    fun onAppForeground() {
        scheduler.onForeground()
        if (!tokens.isLoggedIn()) return
        ServiceLocator.applicationScope.launch { runCatching { scheduler.syncOnce() } }
    }

    fun onAppBackground() = scheduler.onBackground()

    /* ============================== 账号 ============================== */

    /**
     * 退出登录（契约 §7.6.3）：**只清会话，保留该 userId 的数据目录**。
     * 下次同一账号登录时数据仍在（离线可用，联网后增量同步）。
     */
    fun logout() {
        loggingOut = true
        codeCooldownJob?.cancel()
        codeCooldownJob = null
        viewModelScope.launch {
            runCatching { authApi.logout() }
            ServiceLocator.unbindUser()
            unsubscribe?.invoke()
            unsubscribe = null
            val themeMode = _state.value.themeMode
            _state.value = UiState(
                themeMode = themeMode,
                auth = AuthUi(stage = AuthStage.LOGIN),
                refresh = refreshController.state.value,
                eventList = _state.value.eventList,
            )
            loggingOut = false
            showToast(context.getString(R.string.toast_logout))
        }
    }

    fun setServerUrl(url: String) {
        tokens.saveServerUrl(url)
        showToast(context.getString(R.string.toast_server_saved))
    }

    /** 当前服务器地址（登录页与设置页共用同一份配置） */
    fun currentServerUrl(): String = tokens.serverUrl()

    private fun loginErrorMessage(error: Throwable): String {
        val message = (error as? OrdoApiException)?.message ?: error.message.orEmpty()
        return context.getString(R.string.toast_login_failed, message.ifBlank { error::class.java.simpleName })
    }

    /* ============================== Toast ============================== */

    fun showToast(message: String) {
        toastJob?.cancel()
        _state.update { it.copy(toast = message) }
        toastJob = viewModelScope.launch {
            delay(TOAST_MILLIS)
            _state.update { it.copy(toast = null) }
        }
    }

    fun dismissToast() {
        toastJob?.cancel()
        _state.update { it.copy(toast = null) }
    }

    companion object {
        const val ROUTE_PROJECT_PREFIX = "project/"
        const val ROUTE_AREA_PREFIX = "area/"
        const val ROUTE_TAG_PREFIX = "tag/"
        const val ROUTE_DETAIL_PREFIX = "detail/"
        const val HEADING_PREFIX = "heading/"
        const val PLATFORM = "android"
        const val TOAST_MILLIS = 2_400L
        const val SEARCH_LIMIT = 12
    }
}

/* -------------------- core SidebarCounts → UI 模型（单点接触） -------------------- */
private fun SidebarCounts.toUi() = SidebarCountsUi(
    inbox = inbox,
    today = today,
    upcoming = upcoming,
    anytime = anytime,
    someday = someday,
    logbook = logbook,
)
