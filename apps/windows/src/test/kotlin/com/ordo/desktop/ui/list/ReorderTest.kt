package com.ordo.desktop.ui.list

import com.ordo.core.model.EntityType
import com.ordo.core.query.ListQuery
import com.ordo.core.query.SectionKind
import com.ordo.core.store.OrdoEngine
import com.ordo.desktop.data.JsonFileStorage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * 拖拽排序测试。
 *
 * 上半部分覆盖 [ReorderMath] 的纯计算(插入位、指示线、顺序拼接);
 * 下半部分是**落库联调**:构造引擎 → 按界面同一套算法算出新顺序 → `reorderTodos` → 重开引擎读同一目录,顺序不变。
 */
class ReorderTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun spans(ids: List<String>, height: Float = ROW): List<ReorderMath.Span> =
        ids.mapIndexed { index, id -> ReorderMath.Span(id, index * height, height) }

    // ---------------------------------------------------------------- 纯计算

    @Test
    fun `插入位按行中点判定`() {
        val rows = spans(listOf("a", "b", "c")) // 行高 38:0-38 / 38-76 / 76-114,中点 19 / 57 / 95
        assertEquals(0, ReorderMath.insertIndex(5f, rows))
        assertEquals(1, ReorderMath.insertIndex(30f, rows))
        assertEquals(2, ReorderMath.insertIndex(70f, rows))
        assertEquals(3, ReorderMath.insertIndex(200f, rows))
        assertEquals(0, ReorderMath.insertIndex(0f, emptyList()))
    }

    @Test
    fun `向下拖动一格真正落到下一格`() {
        // 向下:插入位在被拖行之后时要减去自身占掉的一格
        assertEquals(listOf("b", "a", "c"), ReorderMath.moveWithin(listOf("a", "b", "c"), "a", 2))
        assertEquals(listOf("b", "c", "a"), ReorderMath.moveWithin(listOf("a", "b", "c"), "a", 3))
        // 向上:插入位直接用
        assertEquals(listOf("c", "a", "b"), ReorderMath.moveWithin(listOf("a", "b", "c"), "c", 0))
        // 原地不动
        assertEquals(listOf("a", "b", "c"), ReorderMath.moveWithin(listOf("a", "b", "c"), "a", 0))
        assertEquals(listOf("a", "b", "c"), ReorderMath.moveWithin(listOf("a", "b", "c"), "b", 1))
        // 不存在的 id:原样返回
        assertEquals(listOf("a", "b", "c"), ReorderMath.moveWithin(listOf("a", "b", "c"), "zzz", 1))
    }

    @Test
    fun `指示线落在插入位上沿,末尾落在下沿`() {
        val rows = spans(listOf("a", "b"))
        assertEquals(0f, ReorderMath.indicatorY(5f, rows), 0.01f)
        assertEquals(38f, ReorderMath.indicatorY(45f, rows), 0.01f)
        assertEquals(76f, ReorderMath.indicatorY(200f, rows), 0.01f)
    }

    @Test
    fun `整表顺序替换只动被拖分组`() {
        val view = listOf("a1", "a2", "a3", "b1", "b2")
        val section = listOf("a1", "a2", "a3")
        assertEquals(
            listOf("a3", "a1", "a2", "b1", "b2"),
            ReorderMath.applySectionOrder(view, section, listOf("a3", "a1", "a2"))
        )
        // 分组没变时整表也不变
        assertEquals(view, ReorderMath.applySectionOrder(view, section, section))
        // 末个分组的顺序替换
        assertEquals(
            listOf("a1", "a2", "a3", "b2", "b1"),
            ReorderMath.applySectionOrder(view, listOf("b1", "b2"), listOf("b2", "b1"))
        )
    }

    @Test
    fun `落点要求被拖行属于该分组`() {
        val rows = spans(listOf("a", "b"))
        val drop = ReorderMath.resolveDrop(60f, rows, "a")
        assertTrue(drop != null && drop.changed)
        assertNull("被拖行不在分组里时不给落点", ReorderMath.resolveDrop(60f, rows, "other"))
    }

    // ---------------------------------------------------------------- 落库联调

    @Test
    fun `收件箱拖拽后的顺序在重启引擎后仍然保持`() {
        val dir = tmp.newFolder("reorder-inbox")
        val engine = OrdoEngine(JsonFileStorage(dir))
        engine.seedDemoData(force = true)

        val before = engine.list(ListQuery.Inbox).map { it.id }
        assertTrue("演示数据里收件箱应至少 3 条", before.size >= 3)
        val section = before.take(4)
        val rows = spans(section)
        // 把第一条拖到分组末尾(指针压过最后一行的中点)
        val drop = ReorderMath.resolveDrop(rows.last().center + 1f, rows, section.first())!!
        assertTrue("拖到末尾应当产生新顺序", drop.changed)
        assertEquals("被拖行应落到分组末尾", section.first(), drop.newSectionIds.last())

        val newView = ReorderMath.applySectionOrder(before, section, drop.newSectionIds)
        engine.reorderTodos(newView)
        assertEquals("写入后立即按新顺序返回", newView, engine.list(ListQuery.Inbox).map { it.id })

        // 重启:新建引擎读同一存储目录
        val reopened = OrdoEngine(JsonFileStorage(dir))
        assertEquals("重启后顺序不变", newView, reopened.list(ListQuery.Inbox).map { it.id })
        assertEquals("order 字段按新顺序密集重排", 0, reopened.todo(newView.first())!!.order)
        assertEquals(newView.size - 1, reopened.todo(newView.last())!!.order)
        assertEquals("每条重排都会进 outbox", newView.size, reopened.pendingOpCount())
        assertTrue("重排 op 都是待办实体", reopened.pendingOps().all { it.entity == EntityType.TODO })
    }

    @Test
    fun `今天清单按分组拖拽后重启仍然保持`() {
        val dir = tmp.newFolder("reorder-today")
        val engine = OrdoEngine(JsonFileStorage(dir))
        engine.seedDemoData(force = true)

        val before = engine.list(ListQuery.Today).map { it.id }
        val section = engine.sections(ListQuery.Today)
            .first { it.kind == SectionKind.PLAIN_TODAY }
            .todos.map { it.id }
        assertTrue("今天分组应有至少 2 条", section.size >= 2)

        // 把分组内的最后一条拖到最前
        val rows = spans(section)
        val drop = ReorderMath.resolveDrop(rows.first().top + 1f, rows, section.last())!!
        val newView = ReorderMath.applySectionOrder(before, section, drop.newSectionIds)
        assertEquals("被拖行应回到分组首位", section.last(), drop.newSectionIds.first())
        assertEquals("整表长度不变", before.size, newView.size)

        engine.reorderTodos(newView)
        assertEquals("今日清单按新顺序返回", newView, engine.list(ListQuery.Today).map { it.id })

        val reopened = OrdoEngine(JsonFileStorage(dir))
        assertEquals("重启后今日顺序不变", newView, reopened.list(ListQuery.Today).map { it.id })
    }

    @Test
    fun `顺序未变化时不写 outbox`() {
        val dir = tmp.newFolder("reorder-noop")
        val engine = OrdoEngine(JsonFileStorage(dir))
        engine.seedDemoData(force = true)
        val rows = spans(engine.list(ListQuery.Inbox).map { it.id })
        // 指针停在被拖行自己的中点上方 → 插入位 = 原位置
        val drop = ReorderMath.resolveDrop(rows.first().top + 1f, rows, rows.first().id)!!
        assertFalse("原地松手不算改动", drop.changed)
        assertEquals(0, engine.pendingOpCount())
    }

    private companion object {
        const val ROW = 38f
    }
}
