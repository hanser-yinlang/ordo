package com.ordo.desktop.app

import com.ordo.core.query.ListQuery
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 破坏性操作的二次确认(项目 / 区域 / 标题)。
 *
 * 侧栏与列表的删除按钮改成"先请求 → 再确认",这里验证:请求阶段不动数据、确认才落库、取消与 Esc 都不落库。
 */
class ConfirmDeleteTest {

    private fun viewModel(): Triple<OrdoViewModel, OrdoEngine, InMemoryStorage> {
        val storage = InMemoryStorage()
        val engine = OrdoEngine(storage)
        engine.seedDemoData(force = true)
        val vm = OrdoViewModel(engine = engine, storage = storage, scope = CoroutineScope(Dispatchers.Unconfined))
        return Triple(vm, engine, storage)
    }

    @Test
    fun `删除项目要先请求再确认`() {
        val (vm, engine, _) = viewModel()
        val project = engine.snapshot.projects.first { !it.deleted }

        vm.requestDeleteProject(project.id, project.name)

        val request = vm.state.value.confirm
        assertNotNull("应产生待确认请求", request)
        assertEquals(ConfirmKind.PROJECT, request!!.kind)
        assertEquals(project.id, request.id)
        assertTrue("标题应说明删的是什么", request.message.contains(project.name))
        assertFalse("请求阶段不得落库", deletedProject(engine, project.id))

        vm.confirmDelete()

        assertTrue("确认后才软删除", deletedProject(engine, project.id))
        assertNull("确认后请求应清空", vm.state.value.confirm)
    }

    @Test
    fun `取消确认不落库`() {
        val (vm, engine, _) = viewModel()
        val project = engine.snapshot.projects.first { !it.deleted }
        vm.requestDeleteProject(project.id, project.name)

        vm.cancelConfirm()

        assertNull(vm.state.value.confirm)
        assertFalse("取消后项目必须还在", deletedProject(engine, project.id))
    }

    @Test
    fun `删除区域要先请求再确认`() {
        val (vm, engine, _) = viewModel()
        val area = engine.snapshot.areas.first { !it.deleted }
        val childProjects = engine.snapshot.projects.filter { it.areaId == area.id && !it.deleted }

        vm.requestDeleteArea(area.id, area.name)
        assertEquals(ConfirmKind.AREA, vm.state.value.confirm!!.kind)
        assertFalse(deletedArea(engine, area.id))

        vm.confirmDelete()

        assertTrue(deletedArea(engine, area.id))
        assertTrue("区域下的项目应变为「无区域」", childProjects.all { engine.project(it.id)!!.areaId == null })
    }

    @Test
    fun `删除标题要先请求再确认,标题下待办转到其他`() {
        val (vm, engine, _) = viewModel()
        val heading = engine.snapshot.headings.first { !it.deleted && !it.archived }
        val children = engine.snapshot.todos.filter { it.headingId == heading.id && !it.deleted }

        vm.requestDeleteHeading(heading.id, heading.name)
        assertEquals(ConfirmKind.HEADING, vm.state.value.confirm!!.kind)
        assertFalse(deletedHeading(engine, heading.id))

        vm.confirmDelete()

        assertTrue(deletedHeading(engine, heading.id))
        assertTrue("标题下的待办应回到「其他」", children.all { engine.todo(it.id)!!.headingId == null })
    }

    @Test
    fun `Esc 优先取消确认,不会顺手关掉别的东西`() {
        val (vm, engine, _) = viewModel()
        val project = engine.snapshot.projects.first { !it.deleted }
        vm.openSettings()
        vm.requestDeleteProject(project.id, project.name)

        vm.escape()

        assertNull("Esc 应清掉确认请求", vm.state.value.confirm)
        assertTrue("设置浮层不该被一起关掉", vm.state.value.settingsOpen)
        assertFalse(deletedProject(engine, project.id))

        vm.escape()
        assertFalse("第二次 Esc 才关浮层", vm.state.value.settingsOpen)
    }

    @Test
    fun `没有请求时确认是安全空操作`() {
        val (vm, engine, _) = viewModel()
        val before = engine.snapshot.todos.count { !it.deleted }
        vm.confirmDelete()
        assertEquals(before, engine.snapshot.todos.count { !it.deleted })
        assertNull(vm.state.value.confirm)
    }

    @Test
    fun `删除项目后它从侧栏与清单里消失`() {
        val (vm, engine, _) = viewModel()
        val project = engine.snapshot.projects.first { !it.deleted }
        vm.requestDeleteProject(project.id, project.name)
        vm.confirmDelete()

        assertTrue("侧栏项目列表不应再包含它", vm.state.value.projects.none { it.id == project.id })
        vm.navigate(OrdoRoute.Project(project.id))
        assertTrue("项目清单应为空", vm.state.value.flatTodos.isEmpty())
    }

    @Test
    fun `删除会产生可供同步推送的 op`() {
        val (vm, engine, _) = viewModel()
        val project = engine.snapshot.projects.first { !it.deleted }
        val before = engine.pendingOpCount()

        vm.requestDeleteProject(project.id, project.name)
        vm.confirmDelete()

        assertTrue("删除必须进 outbox", engine.pendingOpCount() > before)
        // 契约 §2:删除既可以是 type=delete,也可以是 upsert + payload.deleted=true
        val op = engine.pendingOps().last { it.entityId == project.id }
        assertEquals(com.ordo.core.model.EntityType.PROJECT, op.entity)
        val payload = op.payload.toString()
        assertTrue("载荷里必须带 deleted=true:$payload", payload.contains("\"deleted\":true"))
        assertEquals(
            "项目应从项目清单消失",
            emptyList<String>(),
            engine.list(ListQuery.ProjectScope(project.id)).map { it.id }
        )
    }

    /** 软删除后 `engine.project(id)` 会返回 null,这里直接看快照 */
    private fun deletedProject(engine: OrdoEngine, id: String): Boolean =
        engine.snapshot.projects.first { it.id == id }.deleted

    private fun deletedArea(engine: OrdoEngine, id: String): Boolean =
        engine.snapshot.areas.first { it.id == id }.deleted

    private fun deletedHeading(engine: OrdoEngine, id: String): Boolean =
        engine.snapshot.headings.first { it.id == id }.deleted
}
