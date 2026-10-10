package com.ordo.desktop

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.unit.Density
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.sync.AuthApi
import com.ordo.core.sync.AuthRequest
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.DeviceDto
import com.ordo.core.sync.EmailCodeLoginRequest
import com.ordo.core.sync.EmailCodeRequest
import com.ordo.core.sync.EmailCodeSent
import com.ordo.core.sync.GuestAuthRequest
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.OrdoSessionStore
import com.ordo.core.sync.UpgradeRequest
import com.ordo.core.sync.UpgradeResponse
import com.ordo.core.sync.UserDto
import com.ordo.desktop.app.AccountInfo
import com.ordo.desktop.app.GateStage
import com.ordo.desktop.app.LoginController
import com.ordo.desktop.app.LoginMode
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.SessionGate
import com.ordo.desktop.app.SyncStatus
import com.ordo.desktop.net.TokenStore
import com.ordo.desktop.ui.auth.LoginView
import com.ordo.desktop.ui.shell.OrdoApp
import com.ordo.desktop.ui.shell.OrdoGateHost
import com.ordo.desktop.ui.shell.StatusBar
import com.ordo.desktop.ui.theme.OrdoTheme
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 登录门禁的界面落点 + 三张交付截图(离屏渲染,不创建窗口、不抢鼠标)。
 *
 * 截图产物(`<buildDir>/reports/`):
 *  - `ordo-login.png`            登录页(§5.1:400 宽卡片、三个入口)
 *  - `ordo-quickadd-menu.png`    重构后的快加号 + 展开的菜单(§5.2:只有一个 56dp 蓝按钮,旋转 45°)
 *  - `ordo-refresh-syncing.png`  刷新按钮旋转中(§5.3:图标 + 文字)
 */
@OptIn(ExperimentalComposeUiApi::class, InternalComposeUiApi::class)
class GateAndRefreshRenderTest {

    private class NoopAuthApi : AuthApi {
        override suspend fun register(request: AuthRequest): AuthResponse = error("渲染测试不发请求")
        override suspend fun login(request: AuthRequest): AuthResponse = error("渲染测试不发请求")
        override suspend fun refresh(refreshToken: String): AuthResponse = error("渲染测试不发请求")
        override suspend fun guest(request: GuestAuthRequest): AuthResponse = error("渲染测试不发请求")
        override suspend fun upgrade(accessToken: String, request: UpgradeRequest): UpgradeResponse =
            error("渲染测试不发请求")

        override suspend fun requestEmailCode(request: EmailCodeRequest): EmailCodeSent =
            error("渲染测试不发请求")

        override suspend fun emailLogin(request: EmailCodeLoginRequest): AuthResponse =
            error("渲染测试不发请求")
    }

    private fun loginController(): LoginController = LoginController(
        api = NoopAuthApi(),
        tokens = TokenStore(InMemoryStorage()),
        scope = CoroutineScope(Dispatchers.Unconfined)
    )

    private fun viewModel(): OrdoViewModel {
        val storage = InMemoryStorage()
        val engine = OrdoEngine(storage)
        engine.seedDemoData(force = true)
        return OrdoViewModel(engine = engine, storage = storage, scope = CoroutineScope(Dispatchers.Unconfined))
    }

    private fun reportDir(): File {
        val dir = File(System.getProperty("ordo.reportDir") ?: "build/reports")
        dir.mkdirs()
        return dir
    }

    private fun saveBytes(bytes: ByteArray, name: String): File {
        val out = File(reportDir(), name)
        out.writeBytes(bytes)
        assertTrue("截图应落盘且不是空白:${out.absolutePath} (${bytes.size} 字节)", bytes.size > 5_000)
        println("[GateAndRefreshRenderTest] 已输出截图:${out.absolutePath} (${bytes.size} 字节)")
        return out
    }

    /** 场景语义树里的全部文字(用来断言"现在到底显示的是哪一页") */
    private fun texts(scene: ImageComposeScene): List<String> {
        val out = mutableListOf<String>()
        scene.semanticsOwners.forEach { owner -> collectText(owner.rootSemanticsNode, out) }
        return out
    }

    private fun collectText(node: SemanticsNode, out: MutableList<String>) {
        node.config.getOrNull(SemanticsProperties.Text)?.forEach { out.add(it.text) }
        node.children.forEach { collectText(it, out) }
    }

    // ------------------------------------------------------------ 门禁:无会话 → 登录页

    @Test
    fun `无会话渲染登录页,并有三个入口`() {
        val decision = SessionGate.boot(null, 0L)
        assertEquals(GateStage.LOGIN, decision.stage)
        val controller = loginController()

        val scene = ImageComposeScene(width = 900, height = 720, density = Density(1f)) {
            OrdoTheme(dark = false) {
                OrdoGateHost(
                    decision = decision,
                    login = { LoginView(state = controller.state.value, controller = controller) },
                    main = { Box(Modifier.fillMaxSize()) { } }
                )
            }
        }
        try {
            scene.render()
            val labels = texts(scene)

            assertTrue("必须有『以游客身份继续』入口:$labels", labels.any { it.contains("以游客身份继续") })
            assertTrue("必须有邮箱输入:$labels", labels.any { it == "邮箱" })
            assertTrue("必须有口令输入:$labels", labels.any { it == "口令" })
            assertTrue("主按钮应是『登录』:$labels", labels.any { it == "登录" })
            assertTrue("底部应有『还没有账号？注册』:$labels", labels.any { it.contains("还没有账号") })
            assertTrue("品牌区:$labels", labels.any { it == "Ordo" } && labels.any { it == "把今天理清楚" })
        } finally {
            scene.close()
        }
    }

    @Test
    fun `有会话直接渲染主界面,不经过登录页`() {
        val session = OrdoSession(
            userId = "u-1",
            email = "me@ordo.app",
            isGuest = false,
            accessToken = "at",
            refreshToken = "rt",
            expiresAt = 0L
        )
        val decision = SessionGate.boot(session, 0L)
        assertEquals(GateStage.MAIN, decision.stage)

        val vm = viewModel()
        val controller = loginController()
        val scene = ImageComposeScene(width = 1280, height = 800, density = Density(1f)) {
            OrdoTheme(dark = false) {
                OrdoGateHost(
                    decision = decision,
                    login = { LoginView(state = controller.state.value, controller = controller) },
                    main = { OrdoApp(vm) }
                )
            }
        }
        try {
            scene.render()
            val labels = texts(scene)
            assertFalse("有会话就不该看到登录页:$labels", labels.any { it.contains("以游客身份继续") })
            assertTrue("应看到主界面(今天):$labels", labels.any { it == "今天" })
        } finally {
            scene.close()
        }
    }

    // ------------------------------------------------------------ 截图 1:登录页

    @Test
    fun `登录页可离屏渲染并产出截图`() {
        val controller = loginController()
        controller.setEmail("me@ordo.app")
        controller.setPassword("pw-12345678")

        val bytes = renderBytes(900, 720) {
            LoginView(state = controller.state.value, controller = controller)
        }

        saveBytes(bytes, "ordo-login.png")
    }

    @Test
    fun `登录页注册态与错误抖动同样可以离屏渲染`() {
        val controller = loginController()
        controller.switchMode()
        assertEquals(LoginMode.REGISTER, controller.state.value.mode)
        controller.setMode(LoginMode.LOGIN)

        val scene = ImageComposeScene(width = 900, height = 720, density = Density(1f)) {
            OrdoTheme(dark = false) {
                LoginView(state = controller.state.value, controller = controller)
            }
        }
        try {
            scene.render(0L)
            val before = scene.render(16_000_000L).encodeToData()!!.bytes

            // 制造一次失败:错误文案与抖动令牌(§5.1)
            controller.setEmail("bad")
            controller.setPassword("x")
            controller.submit()
            assertEquals(1L, controller.state.value.errorShake)

            var now = 32_000_000L
            var after = before
            repeat(12) {
                now += 16_000_000L
                after = scene.render(now).encodeToData()!!.bytes
            }

            assertFalse("错误态必须真的画出来", before.contentEquals(after))
            assertTrue(after.size > 5_000)
        } finally {
            scene.close()
        }
    }

    // ------------------------------------------------------------ 截图 2:快加号菜单展开

    @Test
    fun `快加号菜单展开可离屏渲染并产出截图`() {
        val vm = viewModel()
        // 菜单只有在"项目内"才多出「新建标题」(参照原型同样只在项目里给这一项),
        // 所以先进一个项目,好让四个新图标(＋ / H / 圆角方框+点 / ≡)都在同一张截图里可核对
        val project = vm.engine.createProject("Q4 产品发布")
        vm.navigate(com.ordo.desktop.app.OrdoRoute.Project(project.id))
        vm.setQuickAddMenu(true)

        val scene = ImageComposeScene(width = 1440, height = 900, density = Density(1f)) { OrdoApp(vm) }
        try {
            val bytes = renderStaggeredMenu(scene)
            val labels = texts(scene)
            assertTrue(
                "菜单必须仍是四项(§5.2 菜单项图标):$labels",
                labels.contains("新建待办") && labels.contains("新建项目") &&
                    labels.contains("新建区域") && labels.contains("新建标题")
            )
            assertFalse("折叠箭头那个多余按钮不该存在:$labels", labels.any { it.contains("更多新建") })
            assertEquals("快捷键提示只有「新建待办」一项", 1, labels.count { it == "Ctrl+N" })

            saveBytes(bytes, "ordo-quickadd-menu.png")
        } finally {
            scene.close()
        }
    }

    /**
     * 放大视图:窗口收到只比菜单宽一点(仍把菜单放在内容区,不压侧栏),让 16dp 的图标、
     * 44 高的条目、208 宽的面板在截图上真正看得清 —— 1440×900 的整窗截图里它们只占一角。
     */
    @Test
    fun `快加号菜单放大视图可离屏渲染`() {
        val vm = viewModel()
        val project = vm.engine.createProject("Q4 产品发布")
        vm.navigate(com.ordo.desktop.app.OrdoRoute.Project(project.id))
        vm.setQuickAddMenu(true)

        val scene = ImageComposeScene(width = 560, height = 460, density = Density(1f)) { OrdoApp(vm) }
        try {
            val bytes = renderStaggeredMenu(scene)
            val labels = texts(scene)
            for (item in listOf("新建待办", "新建项目", "新建区域", "新建标题")) {
                assertTrue("放大视图里也要有 $item:$labels", labels.contains(item))
            }

            val out = File(reportDir(), "ordo-quickadd-menu-closeup.png")
            out.writeBytes(bytes)
            assertTrue(out.length() > 5_000)
            println("[GateAndRefreshRenderTest] 已输出截图:${out.absolutePath} (${out.length()} 字节)")
        } finally {
            scene.close()
        }
    }

    /**
     * 喂帧到菜单完全展开并截图。
     *
     * 菜单项是**逐个错位 40ms 淡入**的,而错位用的是 `LaunchedEffect` + `delay`(真实时间),
     * 不是帧时钟;只喂帧不给真实时间的话,第 4 项(新建标题)会被截在半透明上。
     * 这里每喂一帧就睡 12ms:30 帧 ≈ 360ms > 3×40ms 错位 + 160ms 淡入。
     */
    private fun renderStaggeredMenu(scene: ImageComposeScene): ByteArray {
        var now = 0L
        var bytes = scene.render(now).encodeToData()!!.bytes
        repeat(30) {
            now += 16_000_000L
            bytes = scene.render(now).encodeToData()!!.bytes
            Thread.sleep(12L)
        }
        return bytes
    }

    /**
     * §5.2「新建标题」的可用性:heading 必属 project,所以**只在项目视图**出现这一项,
     * 其余三项所有视图可用(菜单在项目视图下才是完整的 4 项)。
     *
     * 这里断言的是语义树里有没有这一项,与淡入动画的 alpha 无关(节点在面板可见时就已经组合),
     * 因此不需要等动画。
     */
    @Test
    fun `非项目视图的菜单只有三项,新建标题只在项目视图出现`() {
        // 「新建待办」在主界面里还有别的落点(项目内联入口等),所以这里只看那件**唯一有分歧**的事:
        // 「新建标题」到底出不出现 —— 它出现 = 菜单是完整 4 项,不出现 = 只有 3 项。
        val menuItems = listOf("新建待办", "新建项目", "新建区域")

        val todayVm = viewModel()
        todayVm.setQuickAddMenu(true)
        val today = ImageComposeScene(width = 900, height = 700, density = Density(1f)) { OrdoApp(todayVm) }
        try {
            today.render(0L)
            today.render(16_000_000L)
            val labels = texts(today)
            assertTrue("前三项在所有视图都要有:$labels", labels.containsAll(menuItems))
            assertFalse("非项目视图不该有「新建标题」:$labels", labels.contains("新建标题"))
        } finally {
            today.close()
        }

        val projectVm = viewModel()
        val project = projectVm.engine.createProject("Q4 产品发布")
        projectVm.navigate(com.ordo.desktop.app.OrdoRoute.Project(project.id))
        projectVm.setQuickAddMenu(true)
        val inProject = ImageComposeScene(width = 900, height = 700, density = Density(1f)) { OrdoApp(projectVm) }
        try {
            inProject.render(0L)
            inProject.render(16_000_000L)
            val labels = texts(inProject)
            assertTrue("项目视图下菜单是完整 4 项:$labels", labels.containsAll(menuItems + "新建标题"))
            assertEquals("有且只有一项「新建标题」:$labels", 1, labels.count { it == "新建标题" })
            assertEquals("快捷键提示也只挂在新建待办上:$labels", 1, labels.count { it == "Ctrl+N" })
        } finally {
            inProject.close()
        }
    }

    // ------------------------------------------------------------ 截图 3:刷新按钮旋转中

    @Test
    fun `刷新按钮旋转中可离屏渲染并产出截图`() {
        val vm = viewModel()
        vm.setSyncStatus(SyncStatus.SYNCING)

        val scene = ImageComposeScene(width = 1440, height = 900, density = Density(1f)) { OrdoApp(vm) }
        try {
            scene.render(0L)
            scene.render(16_000_000L)
            val labels = texts(scene)
            assertTrue("状态栏应显示『同步中…』:$labels", labels.any { it == "同步中…" })

            // 连续旋转:相隔 1/4 圈的两次渲染必须不同(图标真的在转,而不是静态)
            val quarterTurn = scene.render(241_000_000L).encodeToData()!!.bytes
            val halfTurn = scene.render(466_000_000L).encodeToData()!!.bytes
            assertFalse("图标必须连续旋转", quarterTurn.contentEquals(halfTurn))

            val out = File(reportDir(), "ordo-refresh-syncing.png")
            out.writeBytes(halfTurn)
            assertTrue(out.length() > 5_000)
            println("[GateAndRefreshRenderTest] 已输出截图:${out.absolutePath} (${out.length()} 字节)")
        } finally {
            scene.close()
        }
    }

    /** 放大版:只画状态栏,让 28dp 的刷新控件与"同步中…"看得清 */
    @Test
    fun `刷新控件放大视图可离屏渲染`() {
        val vm = viewModel()
        vm.setSyncStatus(SyncStatus.SYNCING)
        val state = vm.state.value

        val scene = ImageComposeScene(width = 760, height = 56, density = Density(1f)) {
            OrdoTheme(dark = false) { StatusBar(state = state, vm = vm) }
        }
        try {
            scene.render(0L)
            scene.render(16_000_000L)
            var now = 16_000_000L
            var bytes: ByteArray? = null
            repeat(14) {
                now += 16_000_000L
                bytes = scene.render(now).encodeToData()!!.bytes
            }
            val out = File(reportDir(), "ordo-refresh-control.png")
            out.writeBytes(bytes!!)
            assertTrue(out.length() > 1_000)
            println("[GateAndRefreshRenderTest] 已输出截图:${out.absolutePath} (${out.length()} 字节)")
        } finally {
            scene.close()
        }
    }

    // ------------------------------------------------------------ 设置页显示的账号

    @Test
    fun `设置页与视图模型显示当前账号(邮箱或游客)`() {
        val storage = InMemoryStorage()
        val tokens = TokenStore(storage)
        val engine = OrdoEngine(storage)
        val vm = OrdoViewModel(engine = engine, storage = storage, scope = CoroutineScope(Dispatchers.Unconfined))
        vm.tokens = tokens

        assertFalse("没有会话时不是登录态", vm.isLoggedIn)
        assertEquals("未登录", vm.accountLabel)

        tokens.saveSession(
            OrdoSession("u-1", "me@ordo.app", isGuest = false, accessToken = "at", refreshToken = "rt", expiresAt = 0L)
        )
        vm.refreshAccount()
        assertEquals("me@ordo.app", vm.accountLabel)
        assertEquals(AccountInfo(userId = "u-1", email = "me@ordo.app", isGuest = false), vm.account)
        assertEquals("u-1", vm.dataDirName)

        tokens.saveSession(OrdoSession("u-g", null, isGuest = true, accessToken = "at", refreshToken = "rt", expiresAt = 0L))
        vm.refreshAccount()
        assertEquals("游客", vm.accountLabel)
        assertTrue(vm.isGuest)
        assertEquals("u-g", vm.dataDirName)
    }

    @Test
    fun `退出登录只清会话并通知入口回登录页`() {
        val storage = InMemoryStorage()
        val tokens = TokenStore(storage)
        val engine = OrdoEngine(storage)
        val vm = OrdoViewModel(engine = engine, storage = storage, scope = CoroutineScope(Dispatchers.Unconfined))
        vm.tokens = tokens
        tokens.saveSession(
            OrdoSession("u-1", "me@ordo.app", isGuest = false, accessToken = "at", refreshToken = "rt", expiresAt = 0L)
        )
        var signedOut = 0
        vm.onSignedOut = { signedOut += 1 }

        vm.signOut()

        assertEquals(1, signedOut)
        assertFalse(vm.isLoggedIn)
        assertEquals(null, OrdoSessionStore(storage).load())
        assertEquals("退出后展示为未登录", "未登录", vm.accountLabel)
    }

    private fun renderBytes(width: Int, height: Int, content: @Composable () -> Unit): ByteArray {
        val scene = ImageComposeScene(width = width, height = height, density = Density(1f)) {
            OrdoTheme(dark = false) { content() }
        }
        return try {
            scene.render(0L)
            scene.render(16_000_000L)
            // 入场动效(220ms)跑完再取图,否则截到的是"还在淡入"的半透明画面
            scene.render(260_000_000L).encodeToData()!!.bytes
        } finally {
            scene.close()
        }
    }
}
