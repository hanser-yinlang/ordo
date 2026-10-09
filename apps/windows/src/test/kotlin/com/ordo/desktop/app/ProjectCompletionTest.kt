package com.ordo.desktop.app

import com.ordo.core.model.Status
import com.ordo.core.query.ListQuery
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.store.TodoOptions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 任务 1:项目完成的 UI 与状态一致性(契约 §2.2 v1.1)。
 *
 * 用户实测场景:项目卡片写着「剩 0 项未完成 / 进度 100%」,点「完成项目」却被拒。
 * 根因有两处,都在端上:
 *  ① 卡片按钮的 `enabled` 还带着旧规则的 `sections.all { … HEADING … }` 判据;
 *  ② 拒绝时的 Toast 还是旧文案「还有未完成的待办或标题」。
 * 核心已按 v1.1 修好(heading 不阻塞完成、完成时自动归档),这里守住端侧的口径与文案。
 */
class ProjectCompletionTest {

    /** 不用演示数据:每个用例自己造一个干净的项目,结论只取决于本用例构造的状态 */
    private fun vm(): OrdoViewModel {
        val storage = InMemoryStorage()
        return OrdoViewModel(
            engine = OrdoEngine(storage),
            storage = storage,
            scope = CoroutineScope(Dispatchers.Unconfined),
            seedDemoData = false
        )
    }

    private fun projectWith(vm: OrdoViewModel, name: String, headings: List<String>): Pair<String, List<String>> {
        val project = vm.engine.createProject(name)
        val ids = headings.map { vm.engine.createHeading(project.id, it).id }
        vm.navigate(OrdoRoute.Project(project.id))
        return project.id to ids
    }

    private fun addTodo(vm: OrdoViewModel, projectId: String, title: String, headingId: String? = null): String =
        vm.engine.createTodo(title, TodoOptions(projectId = projectId, headingId = headingId)).id

    private fun archivedHeadingIds(vm: OrdoViewModel, projectId: String): List<String> =
        vm.engine.snapshot.headings
            .filter { it.projectId == projectId && !it.deleted && it.archived }
            .map { it.id }

    // ------------------------------------------------------------ ① 有未完成待办:拒绝 + 文案正确

    @Test
    fun `还有未完成待办时拒绝完成,提示说的是真实原因与条数`() {
        val vm = vm()
        val (projectId, headingIds) = projectWith(vm, "未完成项目", listOf("设计", "开发"))
        val t1 = addTodo(vm, projectId, "写方案", headingId = headingIds[0])
        addTodo(vm, projectId, "画原型")
        vm.engine.complete(t1)

        val card = vm.state.value.projectCard
        assertNotNull("项目路由下应有卡片状态", card)
        assertEquals("还有 1 项未完成", 1, card!!.openCount)
        assertFalse("还有未完成待办时不可完成", card.canComplete)

        val ok = vm.completeProject(projectId)

        assertFalse("核心必须拒绝", ok)
        assertEquals("项目状态不得改变", Status.OPEN, vm.engine.project(projectId)!!.status)
        val toast = vm.state.value.toast
        assertNotNull("拒绝时必须有提示", toast)
        assertEquals("还有 1 项未完成的待办", toast!!.text)
        assertFalse("v1.1 后文案不该再提「标题」", toast.text.contains("标题"))
        assertTrue("文案要带真实条数", toast.text.contains("1"))
    }

    @Test
    fun `多条未完成待办时条数与核心计数一致`() {
        val vm = vm()
        val (projectId, _) = projectWith(vm, "三条未完成", emptyList())
        repeat(3) { addTodo(vm, projectId, "待办 ${it + 1}") }

        assertEquals(3, vm.state.value.projectCard!!.openCount)
        assertFalse(vm.completeProject(projectId))
        assertEquals("还有 3 项未完成的待办", vm.state.value.toast!!.text)
        assertEquals("提示条数必须等于真实未完成数", vm.openTodoCount(projectId), 3)
    }

    @Test
    fun `取消的待办不算未完成,不阻塞项目完成`() {
        val vm = vm()
        val (projectId, _) = projectWith(vm, "有取消项的项目", emptyList())
        val t1 = addTodo(vm, projectId, "做了一半不做了")
        addTodo(vm, projectId, "正常做完").let { vm.engine.complete(it) }
        vm.engine.complete(t1, canceled = true)

        assertEquals("canceled 属于已结束", 0, vm.state.value.projectCard!!.openCount)
        assertTrue(vm.completeProject(projectId))
        assertEquals(Status.DONE, vm.engine.project(projectId)!!.status)
    }

    // ------------------------------------------------------------ ② 待办全完成 + 标题未归档:允许 + 自动归档 + 进日志簿

    @Test
    fun `所有待办已完成但标题未归档时允许完成,标题被自动归档`() {
        val vm = vm()
        val (projectId, headingIds) = projectWith(vm, "Q4 产品发布", listOf("设计", "开发"))
        addTodo(vm, projectId, "写方案", headingId = headingIds[0]).let { vm.engine.complete(it) }
        addTodo(vm, projectId, "联调", headingId = headingIds[1]).let { vm.engine.complete(it) }

        assertEquals("两个标题都还没归档", emptyList<String>(), archivedHeadingIds(vm, projectId))
        val card = vm.state.value.projectCard!!
        assertEquals(0, card.openCount)
        assertTrue("唯一硬约束已满足,按钮必须可用", card.canComplete)
        assertEquals("卡片文案:2 项 · 剩 0 项未完成", "2 项 · 剩 0 项未完成", card.countText())

        val ok = vm.completeProject(projectId)

        assertTrue("v1.1:标题不阻塞完成", ok)
        assertEquals("项目已完成", vm.state.value.toast!!.text)
        assertEquals(Status.DONE, vm.engine.project(projectId)!!.status)
        assertEquals(
            "完成后不变量:项目下不应再有未归档标题",
            headingIds.sorted(),
            archivedHeadingIds(vm, projectId).sorted()
        )
    }

    @Test
    fun `自动归档的每个标题都产出一条可同步的 Op`() {
        val vm = vm()
        val (projectId, headingIds) = projectWith(vm, "两个标题的项目", listOf("设计", "开发"))
        addTodo(vm, projectId, "写方案", headingId = headingIds[0]).let { vm.engine.complete(it) }
        val opsBefore = vm.engine.pendingOps().size

        vm.completeProject(projectId)

        // 2 条 heading 归档 Op + 1 条 project 完成 Op,与手工归档同构
        assertEquals(3, vm.engine.pendingOps().size - opsBefore)
        val archivedOps = vm.engine.pendingOps().count { op ->
            op.entity == com.ordo.core.model.EntityType.HEADING &&
                op.payload?.toString()?.contains("\"archived\":true") == true
        }
        assertEquals("两个标题都要能同步到其它端", 2, archivedOps)
    }

    @Test
    fun `完成后项目进入日志簿口径,且不再出现完成项目按钮`() {
        val vm = vm()
        val (projectId, headingIds) = projectWith(vm, "已收尾的项目", listOf("设计"))
        addTodo(vm, projectId, "写方案", headingId = headingIds[0]).let { vm.engine.complete(it) }

        vm.completeProject(projectId)

        // 日志簿(按完成时间聚合的派生清单)必须收录这条已完成的待办
        val logbook = vm.engine.list(ListQuery.Logbook)
        assertEquals("已完成的待办应进入日志簿", 1, logbook.size)
        assertEquals(projectId, logbook.first().projectId)

        // 卡片回到"已完成"态:按钮变成「重新打开」,「完成项目」不再存在
        val done = vm.engine.project(projectId)!!
        assertEquals(Status.DONE, done.status)
        assertTrue("已完成的项目不应再有未归档标题", archivedHeadingIds(vm, projectId).isNotEmpty())

        // 只有 OPEN 的项目才画「完成项目」按钮;DONE 时画的是「重新打开」
        assertFalse("已完成的项目不再显示完成入口", done.status == Status.OPEN)
        assertFalse("重复完成必须被核心拒绝(按钮已不在,这里是防御性断言)", vm.completeProject(projectId))
        assertFalse("重复完成的提示也不该提「标题」", vm.state.value.toast!!.text.contains("标题"))
    }

    @Test
    fun `完成项目后项目仍留在侧栏,只是清单里不再有未完成待办`() {
        val vm = vm()
        val (projectId, _) = projectWith(vm, "收尾项目", emptyList())
        addTodo(vm, projectId, "唯一一件事").let { vm.engine.complete(it) }

        vm.completeProject(projectId)

        assertEquals(
            "项目仍应留在侧栏(状态是已完成,不是删除)",
            1,
            vm.state.value.projects.count { it.id == projectId }
        )
        assertEquals("项目清单里不再有未完成待办", 0, vm.state.value.flatTodos.size)
        assertNotNull("项目本身应仍可访问(要能重新打开)", vm.engine.project(projectId))
    }
}
