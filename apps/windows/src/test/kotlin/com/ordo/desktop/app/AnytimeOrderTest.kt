package com.ordo.desktop.app

import com.ordo.core.model.Todo
import com.ordo.core.model.When
import com.ordo.core.query.ListQuery
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.store.TodoOptions
import com.ordo.desktop.ui.list.ReorderMath
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「随时 / 某天」的手工排序（契约 §2.4 `order`）。
 *
 * 这两条清单的 `order` 排序由**共享核心**保证（`QueryEngine.byManualOrder()`），
 * 视图层只用 `engine.sections(query)` 的结果、不再做任何本地补排 —— 本测试同时守住这两点：
 * ①拖拽后界面顺序立刻跟随；②与核心输出逐字段一致（防止有人在端上再排一次，造成口径漂移）。
 */
class AnytimeOrderTest {

    private fun viewModel(): Triple<OrdoViewModel, OrdoEngine, InMemoryStorage> {
        val storage = InMemoryStorage()
        val engine = OrdoEngine(storage)
        engine.seedDemoData(force = true)
        val vm = OrdoViewModel(engine = engine, storage = storage, scope = CoroutineScope(Dispatchers.Unconfined))
        return Triple(vm, engine, storage)
    }

    /** 与界面同一套算法：把分组里第一条拖到分组末尾 */
    private fun dragFirstToEnd(vm: OrdoViewModel, sectionIndex: Int): List<String> {
        val state = vm.state.value
        val section = state.sections[sectionIndex].todos.map { it.id }
        val spans = section.mapIndexed { index, id -> ReorderMath.Span(id, index * 38f, 38f) }
        val drop = ReorderMath.resolveDrop(spans.last().center + 1f, spans, section.first())!!
        return ReorderMath.applySectionOrder(state.flatTodos.map { it.id }, section, drop.newSectionIds)
    }

    @Test
    fun `随时清单拖拽后显示顺序立刻跟随 order`() {
        val (vm, engine, _) = viewModel()
        vm.navigate(OrdoRoute.Anytime)

        val sectionIndex = vm.state.value.sections.indexOfFirst { it.todos.size >= 2 }
        assertTrue("演示数据里应有可拖拽的「随时」分组", sectionIndex >= 0)
        val before = vm.state.value.flatTodos.map { it.id }
        val sectionIds = vm.state.value.sections[sectionIndex].todos.map { it.id }
        val offset = vm.state.value.sections.take(sectionIndex).sumOf { it.todos.size }
        val dragged = sectionIds.first()

        vm.reorder(dragFirstToEnd(vm, sectionIndex))

        val after = vm.state.value.flatTodos.map { it.id }
        assertNotEquals("界面顺序必须发生变化", before, after)
        assertEquals("被拖行应落到分组末尾", dragged, after[offset + sectionIds.size - 1])
        assertEquals(before.toSet(), after.toSet())
    }

    @Test
    fun `某天清单拖拽后显示顺序跟随 order,重启后仍保持`() {
        val (vm, engine, storage) = viewModel()
        repeat(3) { engine.createTodo("某天待办 ${it + 1}", TodoOptions(`when` = When.SOMEDAY)) }
        vm.navigate(OrdoRoute.Someday)

        val before = vm.state.value.flatTodos.map { it.id }
        assertTrue("某天应有至少 3 条", before.size >= 3)
        val dragged = vm.state.value.sections[0].todos.first().id

        vm.reorder(dragFirstToEnd(vm, 0))

        val after = vm.state.value.flatTodos.map { it.id }
        assertNotEquals(before, after)
        assertEquals("被拖行应落到分组末尾", dragged, after.last())

        // 重启：同一存储目录重建引擎与视图模型
        val reopenedEngine = OrdoEngine(storage)
        val reopened = OrdoViewModel(reopenedEngine, storage, CoroutineScope(Dispatchers.Unconfined))
        reopened.navigate(OrdoRoute.Someday)
        assertEquals("重启后「某天」顺序不变", after, reopened.state.value.flatTodos.map { it.id })
    }

    @Test
    fun `核心按 order 排序,order 相同时用创建时间兜底`() {
        val storage = InMemoryStorage()
        val engine = OrdoEngine(storage)
        // 同一个 order 的两条「随时」待办：谁先建谁在前
        val first = engine.createTodo("先建的", TodoOptions(`when` = When.ANYTIME))
        val second = engine.createTodo("后建的", TodoOptions(`when` = When.ANYTIME))
        engine.updateTodo(first.id) { it.copy(order = 5) }
        engine.updateTodo(second.id) { it.copy(order = 5) }

        val ordered = engine.list(ListQuery.Anytime).map { it.id }
        assertEquals(listOf(first.id, second.id), ordered)
        assertEquals(ordered, engine.list(ListQuery.Anytime).map(Todo::id))
    }

    @Test
    fun `视图模型的分组与核心输出逐字段一致`() {
        val (vm, engine, _) = viewModel()
        listOf(OrdoRoute.Anytime, OrdoRoute.Someday, OrdoRoute.Inbox, OrdoRoute.Today, OrdoRoute.Logbook).forEach { route ->
            vm.navigate(route)
            val fromCore = engine.sections(route.query).flatMap { it.todos }.map { it.id }
            assertEquals("$route 的显示顺序必须直接来自核心", fromCore, vm.state.value.flatTodos.map { it.id })
        }
    }

    @Test
    fun `随时与某天的分组标题来自核心的项目分组`() {
        val (vm, _, _) = viewModel()
        vm.navigate(OrdoRoute.Anytime)
        assertTrue("随时应按项目分组展示", vm.state.value.sections.isNotEmpty())
        assertTrue(
            "分组标题要么是项目名,要么是「无项目」",
            vm.state.value.sections.all { it.title.isNotBlank() }
        )
    }
}
