package com.ordo.desktop.app

import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.sync.AuthApi
import com.ordo.core.sync.AuthRequest
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.DeviceDto
import com.ordo.core.sync.GuestAuthRequest
import com.ordo.core.sync.OrdoApiException
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.UpgradeRequest
import com.ordo.core.sync.UpgradeResponse
import com.ordo.core.sync.UserDto
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
        var failure: Throwable? = null,
        var gate: CompletableDeferred<Unit>? = null
    ) : AuthApi {

        var loginCalls = 0
        var registerCalls = 0
        var guestCalls = 0
        var lastGuestRequest: GuestAuthRequest? = null
        var lastAuthRequest: AuthRequest? = null

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
}
