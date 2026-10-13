package com.ordo.desktop

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
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
import com.ordo.core.sync.OrdoSession
import com.ordo.desktop.app.OrdoRoute
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.SyncStatus
import com.ordo.desktop.net.TokenStore
import com.ordo.desktop.ui.shell.OrdoApp
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
 * 启动落点 + 外壳的离屏渲染(不创建窗口、不抢鼠标)。
 *
 * 产品决策「不再需要登录」后,这里的头等大事变成**反向断言**:
 * 应用启动后直接是主界面,任何视图(含全新安装、无会话、设置页)都**不得**再出现登录相关入口。
 *
 * 截图产物(`<buildDir>/reports/`):
 *  - `ordo-startup-main.png`          启动即主界面(本次交付)
 *  - `ordo-quickadd-menu.png`         快加号 + 展开的菜单(§5.2)
 *  - `ordo-quickadd-menu-closeup.png` 菜单放大视图(核对四个图标)
 *  - `ordo-refresh-syncing.png`       刷新按钮旋转中(§5.3)
 *  - `ordo-refresh-control.png`       刷新控件放大视图
 */
@OptIn(ExperimentalComposeUiApi::class, InternalComposeUiApi::class)
class StartupAndShellRenderTest {

    /** 登录界面一旦复活,这些字眼必然出现在语义树里 —— 反向断言用它们当哨兵 */
    private val loginSignatures = listOf(
        "邮箱",            // 登录页输入区
        "口令",
        "验证码",
        "口令登录",
        "验证码登录",
        "以游客身份继续",
        "还没有账号",
        "已有账号",
        "退出登录",
        "账号与同步",
        "服务器地址"
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
        println("[StartupAndShellRenderTest] 已输出截图:${out.absolutePath} (${bytes.size} 字节)")
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

    /** 登录哨兵:返回命中的登录相关字眼(空 = 干净) */
    private fun loginLeaks(labels: List<String>): List<String> =
        labels.filter { label -> loginSignatures.any { label.contains(it) } }

    // ------------------------------------------------------------ 启动即主界面

    @Test
    fun `启动即主界面_且没有任何登录入口`() {
        val vm = viewModel()

        val bytes = renderBytes(1440, 900) { OrdoApp(vm) }
        val out = saveBytes(bytes, "ordo-startup-main.png")

        // 同一次渲染里顺便把"没有任何登录入口"钉死(离屏场景与截图完全同源)
        val scene = ImageComposeScene(width = 1280, height = 800, density = Density(1f)) { OrdoApp(vm) }
        try {
            scene.render(0L)
            scene.render(16_000_000L)
            val labels = texts(scene)
            assertTrue("启动后必须是主界面(六个清单都在):$labels", labels.containsAll(
                listOf("收件箱", "今天", "计划", "随时", "某天", "日志簿")
            ))
            assertTrue("截图为本次交付物", out.length() > 5_000)
            assertEquals("不得出现任何登录相关字眼", emptyList<String>(), loginLeaks(labels))
        } finally {
            scene.close()
        }
    }

    @Test
    fun `全新安装_没有会话也直接进主界面(离线首启)`() {
        // 一个 token 都没有:过去会停在登录页,现在必须照常进主界面(本地数据立刻可用)
        val storage = InMemoryStorage()
        val engine = OrdoEngine(storage)
        engine.seedDemoData(force = true)
        val vm = OrdoViewModel(engine = engine, storage = storage, scope = CoroutineScope(Dispatchers.Unconfined))
        vm.tokens = TokenStore(storage)

        val scene = ImageComposeScene(width = 1280, height = 800, density = Density(1f)) { OrdoApp(vm) }
        try {
            scene.render(0L)
            scene.render(16_000_000L)
            val labels = texts(scene)
            assertTrue("没有会话也必须能用:$labels", labels.contains("今天") && labels.any { it == "收件箱" })
            assertEquals("没有会话时更没有登录页", emptyList<String>(), loginLeaks(labels))
        } finally {
            scene.close()
        }
    }

    @Test
    fun `有会话时同样直接进主界面`() {
        val vm = viewModel()
        val storage = InMemoryStorage()
        val tokens = TokenStore(storage)
        tokens.saveSession(
            OrdoSession("u-1", null, isGuest = true, accessToken = "at", refreshToken = "rt", expiresAt = 0L)
        )
        vm.tokens = tokens

        val scene = ImageComposeScene(width = 1280, height = 800, density = Density(1f)) { OrdoApp(vm) }
        try {
            scene.render(0L)
            scene.render(16_000_000L)
            val labels = texts(scene)
            assertTrue("有会话也是同一个主界面:$labels", labels.contains("今天"))
            assertEquals("登录界面不该再存在", emptyList<String>(), loginLeaks(labels))
        } finally {
            scene.close()
        }
    }

    // ------------------------------------------------------------ 设置页:登录相关入口已删除

    @Test
    fun `设置页不再有账号_退出登录_服务器地址`() {
        val vm = viewModel()
        vm.openSettings()
        assertTrue("设置页应处于打开状态", vm.state.value.settingsOpen)

        val scene = ImageComposeScene(width = 1280, height = 900, density = Density(1f)) { OrdoApp(vm) }
        try {
            scene.render(0L)
            scene.render(16_000_000L)
            val labels = texts(scene)

            for (section in listOf("外观与启动", "同步", "同步诊断", "数据", "快捷键")) {
                assertTrue("设置页应保留「$section」:$labels", labels.contains(section))
            }
            assertTrue("同步入口还在:$labels", labels.contains("立即同步"))
            assertEquals("账号 / 退出登录 / 服务器地址必须删干净", emptyList<String>(), loginLeaks(labels))
        } finally {
            scene.close()
        }
    }

    // ------------------------------------------------------------ 截图:快加号菜单

    @Test
    fun `快加号菜单展开可离屏渲染并产出截图`() {
        val vm = viewModel()
        // 菜单只有在"项目内"才多出「新建标题」(参照原型同样只在项目里给这一项),
        // 所以先进一个项目,好让四个新图标(＋ / H / 圆角方框+点 / ≡)都在同一张截图里可核对
        val project = vm.engine.createProject("Q4 产品发布")
        vm.navigate(OrdoRoute.Project(project.id))
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
        vm.navigate(OrdoRoute.Project(project.id))
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
            println("[StartupAndShellRenderTest] 已输出截图:${out.absolutePath} (${out.length()} 字节)")
        } finally {
            scene.close()
        }
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
        projectVm.navigate(OrdoRoute.Project(project.id))
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

    // ------------------------------------------------------------ 截图:刷新控件

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
            println("[StartupAndShellRenderTest] 已输出截图:${out.absolutePath} (${out.length()} 字节)")
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
            println("[StartupAndShellRenderTest] 已输出截图:${out.absolutePath} (${out.length()} 字节)")
        } finally {
            scene.close()
        }
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
