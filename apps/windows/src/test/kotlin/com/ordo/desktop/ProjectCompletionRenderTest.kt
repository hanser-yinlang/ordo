package com.ordo.desktop

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.store.TodoOptions
import com.ordo.desktop.app.OrdoRoute
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.ui.shell.OrdoApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 本轮两个 bug 的**视觉证据**(离屏渲染,不创建 AWT 窗口,不抢用户鼠标)。
 *
 * 产物(1440×900,`<buildDir>/reports/`):
 *  - `ordo-project-completable.png`  待办全部结束、标题尚未归档 → 卡片可完成
 *  - `ordo-project-blocked.png`      还有未完成待办 → 卡片把真实原因与条数写在按钮上
 *  - `ordo-composer-focused.png`     右下角加号点开后,输入行在列表顶部并拿到焦点(主色描边)
 */
@OptIn(ExperimentalComposeUiApi::class)
class ProjectCompletionRenderTest {

    private fun vm(): OrdoViewModel {
        val storage = InMemoryStorage()
        return OrdoViewModel(
            engine = OrdoEngine(storage),
            storage = storage,
            scope = CoroutineScope(Dispatchers.Unconfined),
            seedDemoData = false
        )
    }

    private fun renderApp(vm: OrdoViewModel): ByteArray {
        val scene = ImageComposeScene(width = 1440, height = 900, density = Density(1f)) { OrdoApp(vm) }
        val bytes = scene.render().encodeToData()!!.bytes
        scene.close()
        return bytes
    }

    private fun reportDir(): File {
        val dir = File(System.getProperty("ordo.reportDir") ?: "build/reports")
        dir.mkdirs()
        return dir
    }

    private fun save(name: String, bytes: ByteArray): File {
        assertTrue("截图不应为空", bytes.size > 5_000)
        val out = File(reportDir(), name)
        out.writeBytes(bytes)
        assertTrue("截图应落盘:" + out.absolutePath, out.length() > 5_000)
        println("[ProjectCompletionRenderTest] 已输出截图:${out.absolutePath} (${out.length()} 字节)")
        return out
    }

    /**
     * 用户实测场景的"可完成"版本:14 项待办全部结束、两个标题都还没归档,
     * 卡片显示 100% / 剩 0 项未完成,「完成项目」按钮就在那里。
     */
    @Test
    fun `项目卡片可完成状态(标题未归档)可以离屏渲染`() {
        val vm = vm()
        val project = vm.engine.createProject("Q4 产品发布")
        val design = vm.engine.createHeading(project.id, "设计")
        val dev = vm.engine.createHeading(project.id, "开发")
        repeat(6) { index ->
            vm.engine.createTodo("设计任务 ${index + 1}", TodoOptions(projectId = project.id, headingId = design.id))
                .let { vm.engine.complete(it.id) }
        }
        repeat(8) { index ->
            vm.engine.createTodo("开发任务 ${index + 1}", TodoOptions(projectId = project.id, headingId = dev.id))
                .let { vm.engine.complete(it.id) }
        }
        vm.navigate(OrdoRoute.Project(project.id))

        val state = vm.state.value
        val card = state.projectCard
        assertNotNull("项目路由下必须有卡片状态", card)
        assertEquals("应有 14 项待办", 14, card!!.totalCount)
        assertEquals("剩 0 项未完成", 0, card.openCount)
        assertTrue("标题未归档也必须允许完成", card.canComplete)
        assertEquals("卡片文案", "14 项 · 剩 0 项未完成", card.countText())
        assertTrue("两个标题都还没归档", vm.engine.snapshot.headings.none { it.archived })

        val bytes = renderApp(vm)
        val out = save("ordo-project-completable.png", bytes)

        // 完成后同一张卡片应换成"已完成 + 重新打开"的形态,画面必须真的变了
        vm.completeProject(project.id)
        assertEquals(com.ordo.core.model.Status.DONE, vm.engine.project(project.id)!!.status)
        assertTrue("完成时自动归档两个标题", vm.engine.snapshot.headings.all { it.archived })
        val doneBytes = renderApp(vm)
        assertFalse("完成前后的卡片必须不同", out.readBytes().contentEquals(doneBytes))
        save("ordo-project-done.png", doneBytes)
    }

    /** "不可完成"版本:按钮直接把真实原因与条数写在脸上,而不是一个不解释的灰按钮 */
    @Test
    fun `项目卡片不可完成状态会写明原因与条数`() {
        val vm = vm()
        val project = vm.engine.createProject("还没收尾的项目")
        val heading = vm.engine.createHeading(project.id, "设计")
        vm.engine.createTodo("写方案", TodoOptions(projectId = project.id, headingId = heading.id))
        repeat(2) { index ->
            vm.engine.createTodo("已完成 ${index + 1}", TodoOptions(projectId = project.id))
                .let { vm.engine.complete(it.id) }
        }
        vm.navigate(OrdoRoute.Project(project.id))

        val card = vm.state.value.projectCard!!
        assertEquals(1, card.openCount)
        assertEquals(3, card.totalCount)
        assertFalse(card.canComplete)
        assertEquals("还有 1 项未完成的待办", card.blockedReason())

        val bytes = renderApp(vm)
        save("ordo-project-blocked.png", bytes)

        // 点下去也必须给出一模一样的解释(v1.1 下唯一原因就是待办)
        assertFalse(vm.completeProject(project.id))
        assertEquals("还有 1 项未完成的待办", vm.state.value.toast!!.text)
        val toastBytes = renderApp(vm)
        save("ordo-project-blocked-toast.png", toastBytes)
    }

    /**
     * 任务 2 的视觉证据:点开右下角加号后,输入行出现在列表顶部并**拿到焦点**
     * (主色描边 + 光标),不再是一个"点了没反应"的死按钮。
     */
    @Test
    fun `点开加号后输入行在列表顶部且带焦点描边`() {
        val vm = vm()
        repeat(14) { index -> vm.engine.createTodo("演示待办 ${index + 1}") }
        vm.openComposer()

        val scene = ImageComposeScene(width = 1440, height = 900, density = Density(1f)) { OrdoApp(vm) }
        scene.render()
        scene.render()
        // 断言必须在 scene.close() 之前:关掉场景会让输入框失焦(onFocusChanged 回报 false)
        assertTrue("输入框应处于打开状态", vm.state.value.composerOpen)
        assertTrue("输入框应真的拿到焦点(描边与光标由此点亮)", vm.state.value.composerFocused)

        val bytes = scene.render().encodeToData()!!.bytes
        scene.close()
        save("ordo-composer-focused.png", bytes)
    }
}
