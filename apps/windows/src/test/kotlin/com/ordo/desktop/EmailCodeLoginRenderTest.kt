package com.ordo.desktop

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.unit.Density
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.sync.AuthApi
import com.ordo.core.sync.AuthRequest
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.EmailCodeLoginRequest
import com.ordo.core.sync.EmailCodeRequest
import com.ordo.core.sync.EmailCodeSent
import com.ordo.core.sync.GuestAuthRequest
import com.ordo.core.sync.UpgradeRequest
import com.ordo.core.sync.UpgradeResponse
import com.ordo.desktop.app.LoginController
import com.ordo.desktop.app.LoginMethod
import com.ordo.desktop.net.TokenStore
import com.ordo.desktop.ui.auth.LoginView
import com.ordo.desktop.ui.theme.OrdoTheme
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 验证码登录态的离屏渲染截图(契约 §7.6.5 / 04-UI规范 §5.1)。
 *
 * 产物:`<buildDir>/reports/ordo-login-email-code.png` —— 卡片顶部两个平级入口(口令 / 验证码)、
 * 邮箱 + 6 位验证码 + 倒计时置灰的「获取验证码」、以及「已发送」提示,一眼可核对。
 *
 * 全程离屏(ImageComposeScene),不创建窗口、不抢鼠标、不碰真实网络。
 */
@OptIn(ExperimentalComposeUiApi::class, InternalComposeUiApi::class)
class EmailCodeLoginRenderTest {

    private open class FakeAuthApi : AuthApi {
        override suspend fun register(request: AuthRequest): AuthResponse = error("渲染测试不发请求")
        override suspend fun login(request: AuthRequest): AuthResponse = error("渲染测试不发请求")
        override suspend fun refresh(refreshToken: String): AuthResponse = error("渲染测试不发请求")
        override suspend fun guest(request: GuestAuthRequest): AuthResponse = error("渲染测试不发请求")
        override suspend fun upgrade(accessToken: String, request: UpgradeRequest): UpgradeResponse =
            error("渲染测试不发请求")

        override suspend fun requestEmailCode(request: EmailCodeRequest): EmailCodeSent =
            EmailCodeSent(sent = true, expiresIn = 300, retryAfter = 60, devCode = null)

        override suspend fun emailLogin(request: EmailCodeLoginRequest): AuthResponse =
            error("渲染测试不发请求")
    }

    private fun controller(): LoginController = LoginController(
        api = FakeAuthApi(),
        tokens = TokenStore(InMemoryStorage()),
        scope = CoroutineScope(Dispatchers.Unconfined),
        now = { 1_000_000L }
    )

    private fun reportDir(): File {
        val dir = File(System.getProperty("ordo.reportDir") ?: "build/reports")
        dir.mkdirs()
        return dir
    }

    private fun texts(scene: ImageComposeScene): List<String> {
        val out = mutableListOf<String>()
        scene.semanticsOwners.forEach { owner -> collectText(owner.rootSemanticsNode, out) }
        return out
    }

    private fun collectText(node: SemanticsNode, out: MutableList<String>) {
        node.config.getOrNull(SemanticsProperties.Text)?.forEach { out.add(it.text) }
        node.children.forEach { collectText(it, out) }
    }

    @Test
    fun `验证码登录态可离屏渲染并产出截图`() {
        val controller = controller()
        controller.setMethod(LoginMethod.EMAIL_CODE)
        controller.setEmail("me@ordo.app")
        controller.requestCode()

        // 手动把时钟推到"已过 18s",让倒计时数字固定下来(不依赖真实延时)
        val code = controller.state.value.emailCode
        val start = code.cooldownUntil!! - code.remainingSeconds * 1000L
        val midway = code.tick(start + 18_000L)
        assertTrue("倒计时中按钮必须置灰", midway.coolingDown)
        assertFalse("倒计时中不能再次请求", midway.canRequestCode)

        val scene = ImageComposeScene(width = 900, height = 780, density = Density(1f)) {
            OrdoTheme(dark = false) {
                // 状态机是纯的,直接把推好的倒计时喂给界面
                LoginView(
                    state = controller.state.value.copy(emailCode = midway),
                    controller = controller
                )
            }
        }
        try {
            scene.render(0L)
            scene.render(16_000_000L)
            val bytes = scene.render(260_000_000L).encodeToData()!!.bytes
            val labels = texts(scene)

            assertTrue("必须有两个平级入口:$labels", labels.contains("口令登录") && labels.contains("验证码登录"))
            assertTrue("必须有邮箱输入:$labels", labels.any { it == "邮箱" })
            assertTrue("必须有验证码输入:$labels", labels.any { it == "验证码" })
            assertTrue("「获取验证码」要显示剩余秒数:$labels", labels.any { it == "42s 后重试" })
            assertTrue("验证码方式下要有自动建号说明:$labels", labels.any { it.contains("自动创建账号") })
            assertTrue("要有「已发送」提示:$labels", labels.any { it.contains("验证码已发送至") })
            assertFalse("验证码方式下不该出现口令输入:$labels", labels.any { it == "口令" })
            assertFalse("验证码方式下不该出现「注册」链接:$labels", labels.any { it.contains("还没有账号") })
            assertTrue("游客入口必须还在:$labels", labels.any { it.contains("以游客身份继续") })

            val out = File(reportDir(), "ordo-login-email-code.png")
            out.writeBytes(bytes)
            assertTrue("截图应落盘且不是空白:${out.absolutePath}", bytes.size > 5_000)
            println("[EmailCodeLoginRenderTest] 已输出截图:${out.absolutePath} (${bytes.size} 字节)")
        } finally {
            scene.close()
        }
    }

    @Test
    fun `验证码登录失败时的抖动错误区同样可以离屏渲染`() {
        val controller = controller()
        controller.setMethod(LoginMethod.EMAIL_CODE)
        controller.setEmail("me@ordo.app")
        // 没满 6 位就手动提交:本地校验直接给出中文错误(与自动提交共用同一条错误区)
        controller.submitEmailCode()
        assertTrue("错误文案必须是人话", controller.state.value.error!!.contains("6 位数字验证码"))
        assertTrue("抖动令牌要自增", controller.state.value.errorShake > 0L)

        val scene = ImageComposeScene(width = 900, height = 780, density = Density(1f)) {
            OrdoTheme(dark = false) {
                LoginView(state = controller.state.value, controller = controller)
            }
        }
        try {
            scene.render(0L)
            var bytes = scene.render(16_000_000L).encodeToData()!!.bytes
            // 抖动是 320ms 的关键帧动画:多喂几帧,确保错误态真的画出来
            var now = 16_000_000L
            repeat(12) {
                now += 16_000_000L
                bytes = scene.render(now).encodeToData()!!.bytes
            }
            assertTrue("错误态也要有内容", bytes.size > 5_000)
            assertTrue("错误文案应出现在语义树里", texts(scene).any { it.contains("6 位数字验证码") })
            assertTrue("错误不靠颜色单独表达", texts(scene).any { it.contains("获取验证码") })
        } finally {
            scene.close()
            controller.reset()
        }
    }

    @Test
    fun `验证码作废时界面提示重新获取`() {
        // 服务端判定该码已过期(契约 §7.6.5 的 details.reason):错的不是输入,而是这个码本身
        val controller = controller()
        controller.setMethod(LoginMethod.EMAIL_CODE)
        controller.setEmail("me@ordo.app")
        val expired = com.ordo.desktop.net.OrdoHttpException(
            "AUTH_INVALID_CREDENTIALS",
            "code expired",
            reason = "code_expired"
        )
        val failing = LoginController(
            api = object : FakeAuthApi() {
                override suspend fun emailLogin(request: EmailCodeLoginRequest): AuthResponse = throw expired
            },
            tokens = TokenStore(InMemoryStorage()),
            scope = CoroutineScope(Dispatchers.Unconfined)
        )
        failing.setMethod(LoginMethod.EMAIL_CODE)
        failing.setEmail("me@ordo.app")
        failing.setCode("123456")

        assertTrue("服务端已判定作废", failing.state.value.emailCode.mustRequestAgain)
        assertEquals("必须给中文文案", "验证码已过期，请重新获取", failing.state.value.error)

        val scene = ImageComposeScene(width = 900, height = 780, density = Density(1f)) {
            OrdoTheme(dark = false) {
                LoginView(state = failing.state.value, controller = failing)
            }
        }
        try {
            scene.render(0L)
            scene.render(16_000_000L)
            val labels = texts(scene)
            assertTrue("要写出错因:$labels", labels.any { it == "验证码已过期，请重新获取" })
            assertTrue("要给出下一步:$labels", labels.any { it == "请重新获取验证码" })
        } finally {
            scene.close()
            controller.reset()
            failing.reset()
        }
    }
}
