package com.ordo.desktop

import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.unit.Density
import com.ordo.core.query.ListQuery
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.desktop.app.OrdoRoute
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.ui.list.ListPane
import com.ordo.desktop.ui.list.ListReorderState
import com.ordo.desktop.ui.shell.OrdoApp
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 界面冒烟测试:**离屏渲染**真实的「今天」界面并产出 PNG(Compose Desktop 的 ImageComposeScene,
 * 不创建 AWT 窗口,可在无显示器的构建机上运行)。
 *
 * 产物:`<buildDir>/reports/ordo-today.png`(由 build.gradle.kts 注入 `ordo.reportDir`)。
 * 它同时验证:共享核心 → 视图模型 → UI 的整条链路可用,且界面不是空白。
 */
@OptIn(ExperimentalComposeUiApi::class)
class RenderSmokeTest {

    private fun viewModel(): OrdoViewModel {
        val storage = InMemoryStorage()
        val engine = OrdoEngine(storage)
        engine.seedDemoData(force = true)
        // 测试环境没有 Main 调度器,用 Unconfined 让协程立即执行
        return OrdoViewModel(engine = engine, storage = storage, scope = CoroutineScope(Dispatchers.Unconfined))
    }

    @Test
    fun `今天界面可离屏渲染并产出 PNG`() {
        val vm = viewModel()
        assertEquals(OrdoRoute.Today, vm.state.value.route)

        val scene = ImageComposeScene(width = 1440, height = 900, density = Density(1f)) {
            OrdoApp(vm)
        }
        val image = scene.render()
        val bytes = image.encodeToData()?.bytes
        scene.close()

        assertEquals("宽度应为 1440", 1440, image.width)
        assertEquals("高度应为 900", 900, image.height)
        assertTrue("渲染结果不应为空", bytes != null && bytes.isNotEmpty())
        assertTrue("PNG 体积过小,可能是空白界面", (bytes?.size ?: 0) > 5_000)

        val dir = File(System.getProperty("ordo.reportDir") ?: "build/reports")
        dir.mkdirs()
        val out = File(dir, "ordo-today.png")
        out.writeBytes(bytes!!)
        assertTrue("截图应落盘:" + out.absolutePath, out.length() > 5_000)
        println("[RenderSmokeTest] 已输出界面截图:${out.absolutePath} (${out.length()} 字节)")
    }

    @Test
    fun `深色主题与快加号菜单同样可以离屏渲染`() {
        val vm = viewModel()
        vm.setTheme(com.ordo.desktop.app.ThemeMode.DARK)
        vm.setQuickAddMenu(true)

        val scene = ImageComposeScene(width = 1440, height = 900, density = Density(1f)) {
            OrdoApp(vm)
        }
        val image = scene.render()
        val bytes = image.encodeToData()?.bytes
        scene.close()

        assertEquals(1440, image.width)
        assertEquals(900, image.height)
        assertTrue("深色渲染结果不应为空", bytes != null && bytes.size > 5_000)

        val dir = File(System.getProperty("ordo.reportDir") ?: "build/reports")
        dir.mkdirs()
        val out = File(dir, "ordo-dark-quickadd.png")
        out.writeBytes(bytes!!)
        println("[RenderSmokeTest] 已输出深色界面截图:${out.absolutePath} (${out.length()} 字节)")
    }

    @Test
    fun `视图模型按派生清单规则提供分组与计数`() {
        val vm = viewModel()
        val state = vm.state.value

        assertTrue("今天应有演示数据", state.flatTodos.isNotEmpty())
        assertTrue("今天应有「今晚」分区", state.sections.any { it.title == "今晚" })
        assertTrue("侧栏计数应大于 0", state.counts.inbox > 0)
        assertTrue("今天列表必须包含逾期截止项", state.flatTodos.any { it.deadline != null })

        // 路由切换后标题与内容同步变化
        vm.navigate(OrdoRoute.Inbox)
        assertEquals(OrdoRoute.Inbox, vm.state.value.route)
        assertTrue(vm.state.value.flatTodos.all { it.`when` == com.ordo.core.model.When.INBOX })

        vm.navigate(OrdoRoute.Logbook)
        assertTrue("日志簿应只含已完成/已取消", vm.state.value.flatTodos.all { it.status.isClosed })

        vm.navigate(OrdoRoute.Upcoming)
        assertTrue(vm.state.value.flatTodos.isNotEmpty())
    }

    @Test
    fun `新建待办走中文自然语言解析并进入对应清单`() {
        val vm = viewModel()
        val id = vm.createTodo("明天 18:00 交季度报告 #重要")
        assertTrue(id != null)

        val todo = vm.engine.todo(id!!)!!
        assertEquals("交季度报告", todo.title)
        assertTrue("应带提醒", todo.reminder?.endsWith("T18:00") == true)
        assertTrue("应带标签", todo.tags.contains("重要"))
        assertTrue(
            "应出现在计划清单",
            vm.engine.list(ListQuery.Upcoming).any { it.id == id }
        )
    }

    /**
     * 拖拽排序的视觉验证:注入同一个 [ListReorderState],先渲染一帧让行登记自己的位置,
     * 再直接驱动"拖动中"状态(等价于按住行尾手柄上移),对比两帧画面确认指示线与被拖行确实画出来了。
     */
    @Test
    fun `拖拽排序的插入指示线可以离屏渲染`() {
        val vm = viewModel()
        val drag = ListReorderState()

        val scene = ImageComposeScene(width = 1440, height = 900, density = Density(1f)) {
            OrdoTheme(dark = false) {
                ListPane(state = vm.state.value, vm = vm, dragState = drag)
            }
        }
        val idle = scene.render().encodeToData()!!.bytes

        val rows = drag.spansOf(0)
        assertTrue("首帧应登记今天分组里每一行的占位", rows.size >= 3)

        // 第一行拖到第三行之前
        drag.begin(rows[0].id, 0, 0, rows[2].top + 1f)
        assertEquals("指示线应落在插入位那一行的上沿", rows[2].top, drag.indicatorY()!!, 0.01f)

        val image = scene.render()
        val bytes = image.encodeToData()!!.bytes
        scene.close()

        assertEquals(1440, image.width)
        assertFalse("拖拽中的画面必须与静止时不同(指示线 + 被拖行变淡)", idle.contentEquals(bytes))
        assertTrue("截图不应为空", bytes.size > 5_000)

        val out = File(reportDir(), "ordo-drag-reorder.png")
        out.writeBytes(bytes)
        assertTrue(out.length() > 5_000)
        println("[RenderSmokeTest] 已输出拖拽排序截图:${out.absolutePath} (${out.length()} 字节)")
    }

    /** 设置页的两块新内容:开机自启开关 + 同步诊断(outbox 明细) */
    @Test
    fun `设置页含开机自启与同步诊断,可离屏渲染`() {
        val vm = viewModel()
        repeat(12) { vm.engine.createTodo("离线待推送 ${it + 1}") }
        vm.openSettings()
        assertTrue("设置页应处于打开状态", vm.state.value.settingsOpen)
        assertEquals("outbox 应有 12 条待推送", 12, vm.pendingOpCount())

        val scene = ImageComposeScene(width = 1440, height = 900, density = Density(1f)) {
            OrdoApp(vm)
        }
        val image = scene.render()
        val bytes = image.encodeToData()!!.bytes
        scene.close()

        assertEquals(1440, image.width)
        assertTrue("设置页渲染结果不应为空", bytes != null && bytes.size > 5_000)

        val out = File(reportDir(), "ordo-settings-sync.png")
        out.writeBytes(bytes!!)
        assertTrue(out.length() > 5_000)
        println("[RenderSmokeTest] 已输出设置页截图:${out.absolutePath} (${out.length()} 字节)")
    }

    /** 渲染产物目录(由 build.gradle.kts 注入 ordo.reportDir) */
    private fun reportDir(): File {
        val dir = File(System.getProperty("ordo.reportDir") ?: "build/reports")
        dir.mkdirs()
        return dir
    }

    /**
     * 端到端:对着行尾手柄发真实指针事件(按下 → 移动 → 松开),断言顺序被写回引擎。
     *
     * 全部在离屏场景里做,不会抢占用户鼠标;手柄只在"悬浮 / 选中 / 拖动中"出现,
     * 因此先把该行设为选中,保证手柄已组合出来。
     */
    @Test
    fun `按住行尾手柄拖动会真实写回顺序`() {
        val vm = viewModel()
        val drag = ListReorderState()
        val scene = ImageComposeScene(width = 1440, height = 900, density = Density(1f)) {
            // 必须订阅 StateFlow,否则选中行不会触发重组、手柄不会出现
            val state by vm.state.collectAsState()
            OrdoTheme(dark = false) {
                ListPane(state = state, vm = vm, dragState = drag)
            }
        }
        scene.render()

        val before = vm.engine.list(ListQuery.Today).map { it.id }
        val first = vm.state.value.flatTodos.first()
        // 选中后手柄常驻(与"悬浮"等价的可见条件)
        vm.selectTodo(first.id)
        scene.render()

        val rows = drag.spansOf(0)
        assertTrue("应至少登记 3 行", rows.size >= 3)
        val top = rows[0]
        val target = rows[2]

        // 内容区宽 720、在 1440 的场景里居中 → 右边界 1080;行内右边距 OrdoSpace.s,手柄宽 28
        val handleX = 1440f / 2f + OrdoSpace.contentMaxWidth.value / 2f - OrdoSpace.s.value - 14f
        // 行占位是"内容坐标",指针事件是"窗口坐标":用同一套换算,避免把按下点落到标题区
        val handleY = drag.rootYOf(top.top + 4f + 14f)
        val targetY = drag.rootYOf(target.center + 4f)

        scene.sendPointerEvent(PointerEventType.Move, Offset(handleX, handleY))
        scene.render()
        scene.sendPointerEvent(PointerEventType.Press, Offset(handleX, handleY))
        scene.render()
        // 分两步移动,确保越过触摸阈值并触发拖拽
        scene.sendPointerEvent(PointerEventType.Move, Offset(handleX, handleY + 24f))
        scene.render()
        scene.sendPointerEvent(PointerEventType.Move, Offset(handleX, targetY))
        scene.render()
        scene.sendPointerEvent(PointerEventType.Release, Offset(handleX, targetY))
        scene.render()
        scene.close()

        val after = vm.engine.list(ListQuery.Today).map { it.id }
        assertFalse("拖动后顺序应发生变化", before == after)
        assertEquals("被拖行应落到第三行之前", top.id, after[2])
        assertTrue("outbox 应记录重排", vm.engine.pendingOpCount() > 0)
    }
}
