package com.ordo.desktop.app

import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.sync.AuthApi
import com.ordo.core.sync.AuthRequest
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.DeviceDto
import com.ordo.core.sync.EmailCodeLoginRequest
import com.ordo.core.sync.EmailCodeRequest
import com.ordo.core.sync.EmailCodeSent
import com.ordo.core.sync.GuestAuthRequest
import com.ordo.core.sync.OrdoApiException
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.UpgradeRequest
import com.ordo.core.sync.UpgradeResponse
import com.ordo.core.sync.UserDto
import com.ordo.desktop.net.OrdoHttpException
import com.ordo.desktop.net.TokenStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 一份成功的登录响应(顶层函数:嵌套的假 API 与用例共用) */
private fun authResponse(userId: String, email: String, guest: Boolean) = AuthResponse(
    user = UserDto(id = userId, email = email, isGuest = guest),
    device = DeviceDto("dev_1", "Ordo Windows", "windows"),
    accessToken = "access-token",
    refreshToken = "refresh-token",
    expiresIn = 1_800L
)

/**
 * 登录页控制器(契约 §7.6.2 / 04-UI规范 §5.1)。
 *
 * 三个入口(登录 / 注册 / 游客登录)共用同一条落地链路:成功后把 [OrdoSession] 写进 kv,
 * 再放行到主界面;失败则给出人话文案 + 抖动令牌,并且**不留下半个会话**。
 */
class LoginControllerTest {

    /** 可编排的假 AuthApi:记录调用、可挂起、可失败 */
    private class FakeAuthApi(
        var loginResult: (() -> AuthResponse)? = null,
        var registerResult: (() -> AuthResponse)? = null,
        var guestResult: (() -> AuthResponse)? = null,
        var codeResult: (() -> EmailCodeSent)? = null,
        var emailLoginResult: (() -> AuthResponse)? = null,
        var failure: Throwable? = null,
        var codeFailure: Throwable? = null,
        var emailLoginFailure: Throwable? = null,
        var gate: CompletableDeferred<Unit>? = null
    ) : AuthApi {

        var loginCalls = 0
        var registerCalls = 0
        var guestCalls = 0
        var codeCalls = 0
        var emailLoginCalls = 0
        var lastGuestRequest: GuestAuthRequest? = null
        var lastAuthRequest: AuthRequest? = null
        var lastEmailCodeRequest: EmailCodeRequest? = null
        var lastEmailLoginRequest: EmailCodeLoginRequest? = null

        private suspend fun <T> answer(value: () -> T): T {
            gate?.await()
            failure?.let { throw it }
            return value()
        }

        override suspend fun register(request: AuthRequest): AuthResponse {
            registerCalls += 1
            lastAuthRequest = request
            return answer { registerResult?.invoke() ?: authResponse("u-new", request.email, guest = false) }
        }

        override suspend fun login(request: AuthRequest): AuthResponse {
            loginCalls += 1
            lastAuthRequest = request
            return answer { loginResult?.invoke() ?: authResponse("u-1", request.email, guest = false) }
        }

        override suspend fun refresh(refreshToken: String): AuthResponse =
            answer { authResponse("u-1", "a@b.c", guest = false) }

        override suspend fun guest(request: GuestAuthRequest): AuthResponse {
            guestCalls += 1
            lastGuestRequest = request
            return answer { guestResult?.invoke() ?: authResponse("u-guest", "", guest = true) }
        }

        override suspend fun upgrade(accessToken: String, request: UpgradeRequest): UpgradeResponse =
            UpgradeResponse(UserDto("u-guest", request.email, isGuest = false))

        override suspend fun requestEmailCode(request: EmailCodeRequest): EmailCodeSent {
            codeCalls += 1
            lastEmailCodeRequest = request
            gate?.await()
            codeFailure?.let { throw it }
            return codeResult?.invoke() ?: EmailCodeSent(sent = true, expiresIn = 300, retryAfter = 60)
        }

        override suspend fun emailLogin(request: EmailCodeLoginRequest): AuthResponse {
            emailLoginCalls += 1
            lastEmailLoginRequest = request
            gate?.await()
            emailLoginFailure?.let { throw it }
            return emailLoginResult?.invoke() ?: authResponse("u-1", request.email, guest = false)
        }
    }

    private fun controller(
        api: AuthApi,
        storage: InMemoryStorage = InMemoryStorage(),
        now: Long = 5_000L,
        onAuthenticated: (OrdoSession) -> Unit = {}
    ): Pair<LoginController, TokenStore> {
        val tokens = TokenStore(storage)
        val controller = LoginController(
            api = api,
            tokens = tokens,
            scope = CoroutineScope(Dispatchers.Unconfined),
            now = { now },
            onAuthenticated = onAuthenticated
        )
        return controller to tokens
    }

    // ------------------------------------------------------------ 三个入口

    @Test
    fun `登录成功写入会话并回调进入主界面`() {
        var entered: OrdoSession? = null
        val (controller, tokens) = controller(FakeAuthApi(), onAuthenticated = { entered = it })

        controller.setEmail("me@ordo.app")
        controller.setPassword("pw-12345678")
        controller.submit()

        val session = tokens.currentSession()
        assertNotNull("会话必须落库", session)
        assertEquals("u-1", session!!.userId)
        assertEquals("me@ordo.app", session.email)
        assertFalse(session.isGuest)
        assertEquals("过期时刻 = now + 1800s", 5_000L + 1_800_000L, session.expiresAt)
        assertEquals("主界面回调带上会话", "u-1", entered?.userId)
        assertFalse("成功后不再忙", controller.state.value.busy)
        assertNull(controller.state.value.error)
        assertEquals("口令不该留在内存状态里", "", controller.state.value.password)
    }

    @Test
    fun `注册模式调用 register 并落库`() {
        val api = FakeAuthApi()
        val (controller, tokens) = controller(api)

        controller.switchMode()
        assertEquals(LoginMode.REGISTER, controller.state.value.mode)
        controller.setEmail("new@ordo.app")
        controller.setPassword("pw-12345678")
        controller.submit()

        assertEquals(1, api.registerCalls)
        assertEquals(0, api.loginCalls)
        assertEquals("new@ordo.app", tokens.currentSession()!!.email)
    }

    @Test
    fun `游客登录与正式登录链路对等,会话标记为游客`() {
        val api = FakeAuthApi()
        val (controller, tokens) = controller(api)

        controller.continueAsGuest()

        assertEquals(1, api.guestCalls)
        assertEquals(0, api.loginCalls)
        assertEquals("游客也要带设备信息", "windows", api.lastGuestRequest!!.platform)
        val session = tokens.currentSession()!!
        assertTrue(session.isGuest)
        assertNull(session.email)
        assertEquals("游客", session.displayName())
        assertFalse(controller.state.value.busy)
    }

    @Test
    fun `游客登录失败给出可读文案,不写会话`() {
        val api = FakeAuthApi(failure = OrdoApiException("INTERNAL", "boom"))
        val (controller, tokens) = controller(api)

        controller.continueAsGuest()

        assertNull("失败绝不能留下会话", tokens.currentSession())
        val error = controller.state.value.error!!
        assertTrue("要说清是游客登录失败:$error", error.startsWith("游客登录失败"))
        assertEquals("抖动令牌要自增", 1L, controller.state.value.errorShake)
    }

    // ------------------------------------------------------------ 校验与错误

    @Test
    fun `本地校验先挡住明显不合法的输入,不发请求`() {
        val api = FakeAuthApi()
        val (controller, _) = controller(api)

        controller.setEmail("not-an-email")
        controller.setPassword("pw")
        controller.submit()
        assertEquals("邮箱格式不对不该发请求", 0, api.loginCalls)
        assertEquals("邮箱格式不正确", controller.state.value.error)

        controller.switchMode()
        controller.setEmail("new@ordo.app")
        controller.setPassword("short")
        controller.submit()
        assertEquals("注册口令不足 8 位不该发请求", 0, api.registerCalls)
        assertEquals("口令至少 8 位", controller.state.value.error)
    }

    @Test
    fun `错误码翻译成人话`() {
        val (invalid, _) = controller(FakeAuthApi(failure = OrdoApiException("AUTH_INVALID_CREDENTIALS", "x")))
        invalid.setEmail("a@b.c")
        invalid.setPassword("pw-12345678")
        invalid.submit()
        assertEquals("邮箱或口令不正确", invalid.state.value.error)

        val (taken, _) = controller(FakeAuthApi(failure = OrdoApiException("AUTH_EMAIL_TAKEN", "x")))
        taken.switchMode()
        taken.setEmail("a@b.c")
        taken.setPassword("pw-12345678")
        taken.submit()
        assertTrue(taken.state.value.error!!.contains("已被注册"))

        val (offline, _) = controller(FakeAuthApi(failure = RuntimeException("connection refused")))
        offline.setEmail("a@b.c")
        offline.setPassword("pw-12345678")
        offline.submit()
        assertTrue("连不上服务器要说人话", offline.state.value.error!!.contains("无法连接服务器"))
    }

    @Test
    fun `提交中按钮禁用且不会重复发请求`() {
        val gate = CompletableDeferred<Unit>()
        val api = FakeAuthApi(gate = gate)
        val (controller, _) = controller(api)

        controller.setEmail("a@b.c")
        controller.setPassword("pw-12345678")
        controller.submit()

        assertTrue("提交中处于 busy", controller.state.value.busy)
        assertFalse("提交中禁用输入与按钮", controller.state.value.enabled)
        assertFalse("提交中主按钮不可点", controller.state.value.canSubmit)

        controller.submit()
        controller.continueAsGuest()
        assertEquals("重复点击只算一次", 1, api.loginCalls)
        assertEquals("提交中游客入口也要禁用", 0, api.guestCalls)

        gate.complete(Unit)
        assertFalse(controller.state.value.busy)
    }

    // ------------------------------------------------------------ 界面状态

    @Test
    fun `模式切换改主按钮与底部链接文案`() {
        val (controller, _) = controller(FakeAuthApi())
        assertEquals("登录", controller.state.value.primaryLabel)
        assertEquals("还没有账号？注册", controller.state.value.switchHint)

        controller.switchMode()
        assertEquals("注册", controller.state.value.primaryLabel)
        assertEquals("已有账号？登录", controller.state.value.switchHint)
    }

    @Test
    fun `口令可见性可切换,聚焦字段可跟踪`() {
        val (controller, _) = controller(FakeAuthApi())
        assertFalse(controller.state.value.passwordVisible)

        controller.togglePasswordVisible()
        assertTrue(controller.state.value.passwordVisible)

        controller.setFocused(LoginField.PASSWORD)
        assertEquals(LoginField.PASSWORD, controller.state.value.focused)
        controller.setFocused(null)
        assertNull(controller.state.value.focused)
    }

    @Test
    fun `服务器地址改动落到会话存储所在的 kv`() {
        val storage = InMemoryStorage()
        val (controller, tokens) = controller(FakeAuthApi(), storage)

        controller.setServerUrl("http://10.0.0.5:8080/")

        assertEquals("http://10.0.0.5:8080", tokens.serverUrl)
        assertEquals("http://10.0.0.5:8080", controller.state.value.serverUrl)
    }

    @Test
    fun `门禁带过来的过期说明会显示在登录页`() {
        val (controller, _) = controller(FakeAuthApi())
        controller.applyNotice("登录状态已过期")

        assertEquals("登录状态已过期", controller.state.value.notice)
    }

    @Test
    fun `回到登录页时表单被清空,只剩说明文案`() {
        val (controller, _) = controller(FakeAuthApi())
        controller.setEmail("me@ordo.app")
        controller.setPassword("pw-12345678")
        controller.togglePasswordVisible()

        controller.reset("登录状态已过期")

        val state = controller.state.value
        assertEquals("退出登录后不该留着上一个人的邮箱", "", state.email)
        assertEquals("口令必须清掉", "", state.password)
        assertFalse("口令可见性复位", state.passwordVisible)
        assertFalse(state.busy)
        assertNull(state.focused)
        assertNull(state.error)
        assertEquals("登录状态已过期", state.notice)
    }

    // ------------------------------------------------------------ 邮箱验证码登录(契约 §7.6.5)

    @Test
    fun `口令登录与验证码登录同级切换,共用同一个邮箱输入`() {
        val (controller, _) = controller(FakeAuthApi())
        assertEquals(LoginMethod.PASSWORD, controller.state.value.method)

        controller.setEmail("me@ordo.app")
        controller.setMethod(LoginMethod.EMAIL_CODE)

        assertEquals(LoginMethod.EMAIL_CODE, controller.state.value.method)
        assertEquals("邮箱是两种方式共用的", "me@ordo.app", controller.state.value.email)
        assertEquals("邮箱是两种方式共用的", "me@ordo.app", controller.state.value.emailCode.email)
        assertFalse("验证码方式下没有「注册」链接", controller.state.value.showsModeSwitchLink)

        controller.setMethod(LoginMethod.PASSWORD)
        assertTrue(controller.state.value.showsModeSwitchLink)
    }

    @Test
    fun `获取验证码按响应 retryAfter 进倒计时,期间按钮置灰`() {
        // 故意用一个非默认值:证明倒计时读的是响应里的 retryAfter,而不是写死的 60
        val api = FakeAuthApi(codeResult = { EmailCodeSent(sent = true, expiresIn = 300, retryAfter = 45) })
        val (controller, _) = controller(api)
        controller.setMethod(LoginMethod.EMAIL_CODE)
        controller.setEmail("me@ordo.app")

        controller.requestCode()

        assertEquals(1, api.codeCalls)
        assertEquals("me@ordo.app", api.lastEmailCodeRequest!!.email)
        val code = controller.state.value.emailCode
        assertEquals("按响应 retryAfter 跑倒计时", 45L, code.remainingSeconds)
        assertEquals("有效期也来自响应", 300L, code.expiresIn)
        assertTrue("倒计时中按钮置灰", code.coolingDown)
        assertFalse("倒计时中不能再请求", code.canRequestCode)
        assertEquals("45s 后重试", code.requestButtonLabel)
        assertFalse("请求完成后不再忙", controller.state.value.busy)
        assertTrue("要有「已发送」提示", controller.state.value.hint!!.contains("me@ordo.app"))
    }

    @Test
    fun `倒计时结束按钮自动恢复可用`() {
        val (controller, _) = controller(FakeAuthApi(codeResult = { EmailCodeSent(retryAfter = 60) }))
        controller.setMethod(LoginMethod.EMAIL_CODE)
        controller.setEmail("me@ordo.app")
        controller.requestCode()
        val running = controller.state.value.emailCode
        assertTrue("倒计时中按钮置灰", running.coolingDown)
        assertEquals(60L, running.remainingSeconds)

        // 时钟推进:控制器只在 tick 里按截止时刻重算剩余秒数(用相对偏移,和 now() 的具体取值无关)
        val start = running.cooldownUntil!! - running.remainingSeconds * 1000L
        val midway = running.tick(start + 30_000L)
        assertEquals("过半还剩 30s", 30L, midway.remainingSeconds)
        assertTrue(midway.coolingDown)

        val finished = midway.tick(start + 60_000L)
        assertEquals(0L, finished.remainingSeconds)
        assertFalse("倒计时结束不再置灰", finished.coolingDown)
        assertEquals("重新获取", finished.requestButtonLabel)
        assertTrue("倒计时结束后恢复可用", finished.canRequestCode)
        assertNull("倒计时结束后截止时刻清空", finished.cooldownUntil)
    }

    @Test
    fun `满 6 位自动提交验证码登录,响应落库为同一个会话体系`() {
        val api = FakeAuthApi()
        val (controller, tokens) = controller(api)
        controller.setMethod(LoginMethod.EMAIL_CODE)
        controller.setEmail("fresh@ordo.app")

        controller.setCode("12")
        assertEquals("没满 6 位不提交", 0, api.emailLoginCalls)
        controller.setCode("123456")

        assertEquals("满 6 位自动提交", 1, api.emailLoginCalls)
        val request = api.lastEmailLoginRequest!!
        assertEquals("fresh@ordo.app", request.email)
        assertEquals("123456", request.code)
        assertEquals("windows", request.platform)
        val session = tokens.currentSession()!!
        assertEquals("fresh@ordo.app", session.email)
        assertFalse(session.isGuest)
        assertEquals("成功后清掉验证码,不留明文", "", controller.state.value.emailCode.code)
    }

    @Test
    fun `同一个码不会重复自动提交,改一位后会重新提交`() {
        val api = FakeAuthApi(emailLoginFailure = OrdoHttpException("AUTH_INVALID_CREDENTIALS", "x", reason = "code_invalid"))
        val (controller, _) = controller(api)
        controller.setMethod(LoginMethod.EMAIL_CODE)
        controller.setEmail("fresh@ordo.app")

        controller.setCode("123456")
        val afterFirst = api.emailLoginCalls
        controller.setCode("123456")
        assertEquals("同一个码不重复自动提交(错码时用户只需改数字)", afterFirst, api.emailLoginCalls)

        controller.setCode("123457")
        assertEquals("改一位再满 6 位要重新提交", afterFirst + 1, api.emailLoginCalls)
    }

    @Test
    fun `开发模式的 devCode 自动填入并联调提交,生产不依赖它`() {
        // 开发模式:服务端回显 devCode(契约 §7.6.5)。这里让登录**失败**,好让状态留在"已自动填入"上
        val api = FakeAuthApi(
            codeResult = { EmailCodeSent(sent = true, retryAfter = 60, devCode = "654321") },
            emailLoginFailure = OrdoHttpException("AUTH_INVALID_CREDENTIALS", "x", reason = "code_invalid")
        )
        val (controller, _) = controller(api)
        controller.setMethod(LoginMethod.EMAIL_CODE)
        controller.setEmail("dev@ordo.app")

        controller.requestCode()

        assertEquals("devCode 是联调便利:自动填入", "654321", controller.state.value.emailCode.code)
        assertEquals("654321", controller.state.value.emailCode.devCode)
        assertEquals("填满即自动提交一次", 1, api.emailLoginCalls)
        assertEquals("自动提交用的就是这个 devCode", "654321", api.lastEmailLoginRequest!!.code)

        // 生产环境不带 devCode:不填、不提交,必须等用户自己输入
        val prodApi = FakeAuthApi(codeResult = { EmailCodeSent(sent = true, retryAfter = 60, devCode = null) })
        val (prod, _) = controller(prodApi)
        prod.setMethod(LoginMethod.EMAIL_CODE)
        prod.setEmail("prod@ordo.app")
        prod.requestCode()
        assertEquals("", prod.state.value.emailCode.code)
        assertEquals("绝不因为缺 devCode 就自动登录", 0, prodApi.emailLoginCalls)
        assertEquals("也只能靠用户手输", 0, prodApi.emailLoginCalls)
    }

    @Test
    fun `验证码细分错误映射成中文_错码 过期 超次 限流`() {
        val (invalid, _) = controller(
            FakeAuthApi(emailLoginFailure = OrdoHttpException("AUTH_INVALID_CREDENTIALS", "x", reason = "code_invalid"))
        )
        invalid.setMethod(LoginMethod.EMAIL_CODE)
        invalid.setEmail("a@b.c")
        invalid.setCode("123456")
        assertEquals("验证码不正确，请检查后重试", invalid.state.value.error)
        assertEquals("抖动令牌要自增", 1L, invalid.state.value.errorShake)

        val (expired, _) = controller(
            FakeAuthApi(emailLoginFailure = OrdoHttpException("AUTH_INVALID_CREDENTIALS", "x", reason = "code_expired"))
        )
        expired.setMethod(LoginMethod.EMAIL_CODE)
        expired.setEmail("a@b.c")
        expired.setCode("123456")
        assertEquals("验证码已过期，请重新获取", expired.state.value.error)
        assertTrue("过期后必须重新获取", expired.state.value.emailCode.mustRequestAgain)

        val (exceeded, _) = controller(
            FakeAuthApi(
                emailLoginFailure = OrdoHttpException("AUTH_INVALID_CREDENTIALS", "x", reason = "code_attempts_exceeded")
            )
        )
        exceeded.setMethod(LoginMethod.EMAIL_CODE)
        exceeded.setEmail("a@b.c")
        exceeded.setCode("123456")
        assertEquals("该验证码尝试次数过多，请重新获取", exceeded.state.value.error)
        assertTrue(exceeded.state.value.emailCode.mustRequestAgain)

        val (throttled, _) = controller(
            FakeAuthApi(
                codeFailure = OrdoHttpException("RATE_LIMITED", "slow down", reason = "code_throttled", retryAfterSec = 42)
            )
        )
        throttled.setMethod(LoginMethod.EMAIL_CODE)
        throttled.setEmail("a@b.c")
        throttled.requestCode()
        assertEquals("请求过于频繁，请稍后再试", throttled.state.value.error)
        assertEquals("限流也要按服务端给的秒数跑倒计时", 42L, throttled.state.value.emailCode.remainingSeconds)
        assertFalse("限流期间不能再请求", throttled.state.value.emailCode.canRequestCode)
        assertEquals("要明确告诉用户重新获取", "请重新获取验证码", throttled.state.value.emailCode.mustRequestAgainHint)
    }

    @Test
    fun `验证码方式的本地校验与提交中禁用`() {
        val api = FakeAuthApi()
        val (controller, _) = controller(api)
        controller.setMethod(LoginMethod.EMAIL_CODE)

        controller.setEmail("not-an-email")
        controller.requestCode()
        assertEquals("邮箱格式不对不该发请求", 0, api.codeCalls)
        assertEquals("邮箱格式不正确", controller.state.value.error)

        controller.setEmail("a@b.c")
        controller.setCode("12")
        controller.submitEmailCode()
        assertEquals("没满 6 位不该发请求", 0, api.emailLoginCalls)
        assertEquals("请输入 6 位数字验证码", controller.state.value.error)

        val gate = CompletableDeferred<Unit>()
        val busyApi = FakeAuthApi(gate = gate)
        val (busy, _) = controller(busyApi)
        busy.setMethod(LoginMethod.EMAIL_CODE)
        busy.setEmail("a@b.c")
        busy.setCode("123456")
        assertTrue("提交中处于 busy", busy.state.value.busy)
        assertFalse("提交中主按钮不可点", busy.state.value.emailCode.canSubmitCode)
        busy.submitEmailCode()
        busy.setCode("123456")
        assertEquals("提交中不重复发请求", 1, busyApi.emailLoginCalls)
        gate.complete(Unit)
        assertFalse(busy.state.value.busy)
    }

    @Test
    fun `验证码输入只留数字并截断 6 位`() {
        // 登录故意失败,好让输入状态留在界面上(成功会把验证码清掉,见下一个用例)
        val (controller, _) = controller(
            FakeAuthApi(emailLoginFailure = OrdoHttpException("AUTH_INVALID_CREDENTIALS", "x", reason = "code_invalid"))
        )
        controller.setMethod(LoginMethod.EMAIL_CODE)
        controller.setEmail("a@b.c")

        controller.setCode("12 34-56")
        assertEquals("粘贴带空格 / 连字符也要能用", "123456", controller.state.value.emailCode.code)

        controller.setCode("1234567890")
        assertEquals("最多 6 位", "123456", controller.state.value.emailCode.code)

        controller.setCode("12a34")
        assertEquals("非数字直接丢弃", "1234", controller.state.value.emailCode.code)
    }

    @Test
    fun `验证码登录成功后清掉表单状态,倒计时与提示都复位`() {
        val (controller, _) = controller(FakeAuthApi())
        controller.setMethod(LoginMethod.EMAIL_CODE)
        controller.setEmail("a@b.c")
        controller.requestCode()
        assertNotNull("先有提示", controller.state.value.hint)

        controller.setCode("123456")

        assertNull("成功后提示要收起来", controller.state.value.hint)
        assertNull(controller.state.value.error)
        assertFalse(controller.state.value.emailCode.coolingDown)
    }
}
