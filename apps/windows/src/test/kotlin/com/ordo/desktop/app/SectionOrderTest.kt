package com.ordo.desktop.app

import com.ordo.core.model.When
import com.ordo.core.query.SectionKind
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.store.TodoOptions
import com.ordo.desktop.ui.list.ReorderMath
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「随时 / 某天」的拖拽排序可见性测试。
 *
 * 共享核心在这两个清单按创建顺序返回(`order` 被忽略),本模块用 [orderedSections] 补齐 `order` 排序;
 * 这里验证:①适配层只作用于这两个清单;②真实拖拽 → `vm.reorder` → 界面顺序立刻跟随。
 */
class SectionOrderTest {

    private fun viewModel(): Triple<OrdoViewModel, OrdoEngine, InMemoryStorage> {
        val storage = InMemoryStorage()
        val engine = OrdoEngine(storage)
        engine.seedDemoData(force = true)
        val vm = OrdoViewModel(engine = engine, storage = storage, scope = CoroutineScope(Dispatchers.Unconfined))
        return Triple(vm, engine, storage)
    }

    /** 与界面同一套算法:把分组里第一条拖到分组末尾 */
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
        // 数据层同样按新 order 排列(随时清单在核心侧的顺序仍是创建顺序,这里比对集合)
        assertEquals(before.toSet(), after.toSet())
        assertEquals(before.toSet(), engine.list(com.ordo.core.query.ListQuery.Anytime).map { it.id }.toSet())
    }

    @Test
    fun `某天清单拖拽后显示顺序立刻跟随 order,且重启后仍保持`() {
        val (vm, engine, storage) = viewModel()
        // 造 3 条「某天」待办,确保同一分组里有多行
        repeat(3) { engine.createTodo("某天待办 ${it + 1}", TodoOptions(`when` = When.SOMEDAY)) }
        vm.navigate(OrdoRoute.Someday)

        val before = vm.state.value.flatTodos.map { it.id }
        assertTrue("某天应有至少 3 条", before.size >= 3)
        val sectionIds = vm.state.value.sections[0].todos.map { it.id }
        val dragged = sectionIds.first()

        vm.reorder(dragFirstToEnd(vm, 0))

        val after = vm.state.value.flatTodos.map { it.id }
        assertNotEquals(before, after)
        assertEquals("被拖行应落到分组末尾", dragged, after.last())

        // 重启:同一存储目录新建引擎 + 视图模型,顺序不变
        val reopenedEngine = OrdoEngine(storage)
        val reopened = OrdoViewModel(reopenedEngine, storage, CoroutineScope(Dispatchers.Unconfined))
        reopened.navigate(OrdoRoute.Someday)
        assertEquals("重启后「某天」顺序不变", after, reopened.state.value.flatTodos.map { it.id })
    }

    @Test
    fun `适配层只作用于随时与某天`() {
        assertTrue(needsLocalOrder(OrdoRoute.Anytime))
        assertTrue(needsLocalOrder(OrdoRoute.Someday))
        assertFalse(needsLocalOrder(OrdoRoute.Inbox))
        assertFalse(needsLocalOrder(OrdoRoute.Today))
        assertFalse(needsLocalOrder(OrdoRoute.Logbook))
        assertFalse(needsLocalOrder(OrdoRoute.Upcoming))
        assertFalse(needsLocalOrder(OrdoRoute.Tag("重要")))
    }

    @Test
    fun `适配层按 order 与 createdAt 排序且不改动其它清单`() {
        val (vm, _, _) = viewModel()
        vm.navigate(OrdoRoute.Anytime)
        vm.state.value.sections.forEach { section ->
            assertEquals(
                "分组内必须按 (order, createdAt) 升序",
                section.todos.sortedWith(compareBy({ it.order }, { it.createdAt })).map { it.id },
                section.todos.map { it.id }
            )
        }
        // 日志簿按完成时间倒序,不该被适配层碰
        vm.navigate(OrdoRoute.Logbook)
        val logbook = vm.state.value.sections.flatMap { it.todos }
        assertEquals(
            logbook.sortedByDescending { it.completedAt ?: it.updatedAt }.map { it.id },
            logbook.map { it.id }
        )
        assertTrue(vm.state.value.sections.all { it.kind == SectionKind.COMPLETION_DAY })
    }
}
