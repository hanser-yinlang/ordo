package com.ordo.android

import com.ordo.core.model.RepeatFreq
import com.ordo.core.model.RepeatMode
import com.ordo.core.model.RepeatRule
import com.ordo.core.model.Status
import com.ordo.core.store.TodoOptions
import com.ordo.core.model.When
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 契约 §6「重复规则引擎」验收（固定时钟 = 2026-10-08 09:00）。
 */
class RepeatEngineTest {

    private val today = TestSupport.TODAY

    private fun day(offset: Int) = TestSupport.day(offset)

    private fun com.ordo.core.store.OrdoEngine.newRepeating(
        title: String,
        date: String,
        freq: RepeatFreq,
        mode: RepeatMode = RepeatMode.FIXED,
    ): String {
        val todo = createTodo(title, TodoOptions(`when` = When.DATE, date = date))
        setRepeat(todo.id, RepeatRule(freq = freq, interval = 1, mode = mode))
        return todo.id
    }

    private fun com.ordo.core.store.OrdoEngine.nextOpen(originalId: String, title: String) =
        snapshot.todos.firstOrNull { it.id != originalId && it.title == title && it.isOpen }

    @Test
    fun `fixed 每天基于原日期递推一天`() {
        val engine = TestSupport.engine()
        val base = day(-3)
        val id = engine.newRepeating("每日复盘", base, RepeatFreq.DAILY)

        engine.toggleDone(id)

        val original = engine.todo(id)
        assertEquals(Status.DONE, original?.status)
        assertTrue("原实例应保留 repeat 供日志簿展示", original?.repeat != null)

        val next = engine.nextOpen(id, "每日复盘")
        assertTrue("应生成下一次实例", next != null)
        assertEquals(TestSupport.day(1, base), next?.date)
    }

    @Test
    fun `fixed 每周基于原日期加七天`() {
        val engine = TestSupport.engine()
        val base = day(-10)
        val id = engine.newRepeating("每周复盘", base, RepeatFreq.WEEKLY)
        engine.toggleDone(id)
        assertEquals(TestSupport.day(7, base), engine.nextOpen(id, "每周复盘")?.date)
    }

    @Test
    fun `fixed 每月遇到月末溢出取当月最后一天`() {
        val engine = TestSupport.engine()
        // 2026-01-31 + 1 个月 → 2026-02-28（2026 非闰年）
        val id = engine.newRepeating("月末结算", "2026-01-31", RepeatFreq.MONTHLY)
        engine.toggleDone(id)
        assertEquals("2026-02-28", engine.nextOpen(id, "月末结算")?.date)
    }

    @Test
    fun `fixed 每年年份加一`() {
        val engine = TestSupport.engine()
        val id = engine.newRepeating("年度体检", "2026-03-15", RepeatFreq.YEARLY)
        engine.toggleDone(id)
        assertEquals("2027-03-15", engine.nextOpen(id, "年度体检")?.date)
    }

    @Test
    fun `afterCompletion 以完成日为基准递推`() {
        val engine = TestSupport.engine()
        // 原定日期在过去很久；afterCompletion 必须以"今天"为基准
        val id = engine.newRepeating("换滤芯", day(-30), RepeatFreq.WEEKLY, RepeatMode.AFTER_COMPLETION)
        engine.toggleDone(id)
        assertEquals(TestSupport.day(7, today), engine.nextOpen(id, "换滤芯")?.date)
    }

    @Test
    fun `新实例 id 不同 状态为 open 且完成时间为空`() {
        val engine = TestSupport.engine()
        val id = engine.newRepeating("每日站立会", day(-1), RepeatFreq.DAILY)
        engine.toggleDone(id)

        val next = engine.nextOpen(id, "每日站立会")
        assertNotEquals(id, next?.id)
        assertEquals(Status.OPEN, next?.status)
        assertNull(next?.completedAt)
        assertEquals(When.DATE, next?.`when`)
    }

    @Test
    fun `新实例的清单项全部重置为未完成`() {
        val engine = TestSupport.engine()
        val id = engine.newRepeating("每周采购", day(-7), RepeatFreq.WEEKLY)
        engine.addChecklistItem(id, "牛奶")
        engine.addChecklistItem(id, "面包")
        val first = engine.todo(id)?.checklist?.first()
        assertTrue(first != null)
        engine.toggleChecklistItem(id, first!!.id)

        engine.toggleDone(id)

        val next = engine.nextOpen(id, "每周采购")
        assertEquals(2, next?.checklist?.size)
        assertTrue("清单项应全部重置为未完成", next?.checklist?.all { !it.done } == true)
    }

    @Test
    fun `非重复待办完成后不生成新实例`() {
        val engine = TestSupport.engine()
        val todo = engine.createTodo("一次性的", TodoOptions(`when` = When.TODAY))
        val before = engine.snapshot.todos.size
        engine.toggleDone(todo.id)
        assertEquals(before, engine.snapshot.todos.size)
    }

    @Test
    fun `取消重复规则后完成不再生成新实例`() {
        val engine = TestSupport.engine()
        val id = engine.newRepeating("临时重复", today, RepeatFreq.DAILY)
        engine.setRepeat(id, null)
        val before = engine.snapshot.todos.size
        engine.toggleDone(id)
        assertEquals(before, engine.snapshot.todos.size)
    }
}
