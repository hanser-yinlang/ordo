package com.ordo.core

import com.ordo.core.model.RepeatFreq
import com.ordo.core.model.RepeatMode
import com.ordo.core.model.RepeatRule
import com.ordo.core.model.Status
import com.ordo.core.model.Todo
import com.ordo.core.model.When
import com.ordo.core.platform.FixedOrdoClock
import com.ordo.core.repeat.RepeatEngine
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.util.OrdoDate
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** 重复规则测试 —— 覆盖契约 §6 */
class RepeatEngineTest {

    @Test
    fun dailyAndWeekly() {
        val daily = RepeatRule(RepeatFreq.DAILY)
        assertEquals("2026-10-09", RepeatEngine.nextDate(daily, "2026-10-08"))
        assertEquals("2026-10-11", RepeatEngine.nextDate(daily, "2026-10-08", interval = 3))

        val weekly = RepeatRule(RepeatFreq.WEEKLY)
        assertEquals("2026-10-15", RepeatEngine.nextDate(weekly, "2026-10-08"))
        assertEquals("2026-10-22", RepeatEngine.nextDate(weekly, "2026-10-08", interval = 2))
    }

    @Test
    fun monthlyOverflowUsesLastDayOfMonth() {
        val monthly = RepeatRule(RepeatFreq.MONTHLY)
        assertEquals("2026-11-30", RepeatEngine.nextDate(monthly, "2026-10-31"))
        assertEquals("2027-02-28", RepeatEngine.nextDate(monthly, "2027-01-31"))
        assertEquals("2028-02-29", RepeatEngine.nextDate(monthly, "2028-01-31"), "闰年 2 月应有 29 天")
    }

    @Test
    fun yearly() {
        val yearly = RepeatRule(RepeatFreq.YEARLY)
        assertEquals("2027-10-08", RepeatEngine.nextDate(yearly, "2026-10-08"))
        assertEquals("2027-02-28", RepeatEngine.nextDate(yearly, "2026-02-28"))
    }

    @Test
    fun fixedModeKeepsOriginalDate() {
        val todo = Todo(
            id = "t1", title = "每周复盘", `when` = When.DATE, date = "2026-10-08",
            repeat = RepeatRule(RepeatFreq.WEEKLY, 1, RepeatMode.FIXED)
        )
        val next = RepeatEngine.spawnNext(todo, completedAtMillis = 1_760_000_000_000L, newId = "t2", utcOffsetMillis = 0)
        assertNotNull(next)
        assertEquals("2026-10-15", next!!.date)
        assertEquals(Status.OPEN, next.status)
        assertNull(next.completedAt)
        assertEquals("t2", next.id)
    }

    @Test
    fun afterCompletionModeUsesCompletionDay() {
        val todo = Todo(
            id = "t1", title = "交房租", `when` = When.DATE, date = "2026-10-05",
            repeat = RepeatRule(RepeatFreq.MONTHLY, 1, RepeatMode.AFTER_COMPLETION)
        )
        // 完成日由传入的 epoch 毫秒与偏移推导,期望值同样动态计算,避免硬编码日期
        val completedAt = 1_760_000_000_000L
        val offset = 8 * 3_600_000L
        val next = RepeatEngine.spawnNext(todo, completedAt, "t2", offset)
        assertNotNull(next)
        val completionDay = OrdoDate.isoFromLocalMillis(completedAt + offset)
        assertEquals(OrdoDate.plusMonths(completionDay, 1), next!!.date)
    }

    @Test
    fun completingRepeatingTodoCreatesNextInstance() {
        val clock = FixedOrdoClock(1_759_900_000_000L)
        val engine = OrdoEngine(InMemoryStorage(), clock)
        val todo = engine.createTodo(
            "每周复盘与计划",
            com.ordo.core.store.TodoOptions(`when` = When.DATE, date = OrdoDate.todayISO(clock))
        )
        engine.setRepeat(todo.id, RepeatRule(RepeatFreq.WEEKLY))
        val before = engine.snapshot.todos.size

        engine.complete(todo.id)

        val after = engine.snapshot.todos
        assertEquals(before + 1, after.size, "完成后应生成下一次实例")
        assertEquals(Status.DONE, engine.todo(todo.id)!!.status)
        val next = after.firstOrNull { it.title == "每周复盘与计划" && it.status == Status.OPEN }
        assertNotNull(next)
        assertEquals(OrdoDate.plusDays(engine.todo(todo.id)!!.date!!, 7), next!!.date)
        assertEquals(0, next.checklist.count { it.done })
    }

    @Test
    fun nonRepeatingTodoDoesNotSpawn() {
        val clock = FixedOrdoClock(1_759_900_000_000L)
        val engine = OrdoEngine(InMemoryStorage(), clock)
        val todo = engine.createTodo("普通待办")
        val before = engine.snapshot.todos.size
        engine.complete(todo.id)
        assertEquals(before, engine.snapshot.todos.size)
    }

    @Test
    fun reopenRestoresOpenState() {
        val clock = FixedOrdoClock(1_759_900_000_000L)
        val engine = OrdoEngine(InMemoryStorage(), clock)
        val todo = engine.createTodo("临时任务")
        engine.complete(todo.id)
        engine.reopen(todo.id)
        val reopened = engine.todo(todo.id)!!
        assertEquals(Status.OPEN, reopened.status)
        assertNull(reopened.completedAt)
    }
}
