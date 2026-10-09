package com.ordo.android

import com.ordo.core.model.Status
import com.ordo.core.store.TodoOptions
import com.ordo.core.model.When
import com.ordo.core.query.ListQuery
import com.ordo.core.query.SectionKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 契约 §4「派生清单查询规范」的边界验收（固定时钟 = 2026-10-08 09:00）。
 */
class QueryRulesTest {

    private val today = TestSupport.TODAY

    private fun day(offset: Int) = TestSupport.day(offset)

    @Test
    fun `收件箱只包含 when=inbox 的未完成待办`() {
        val engine = TestSupport.engine()
        val inbox = engine.createTodo("收件箱事项", TodoOptions(`when` = When.INBOX))
        engine.createTodo("今天事项", TodoOptions(`when` = When.TODAY))
        engine.createTodo("随时事项", TodoOptions(`when` = When.ANYTIME))

        val list = engine.list(ListQuery.Inbox)
        assertEquals(1, list.size)
        assertEquals(inbox.id, list.first().id)
    }

    @Test
    fun `未指定 when 与项目时默认进入收件箱`() {
        val engine = TestSupport.engine()
        val todo = engine.createTodo("默认归属")
        assertEquals(When.INBOX, todo.`when`)
        assertTrue(engine.list(ListQuery.Inbox).any { it.id == todo.id })
    }

    @Test
    fun `指定项目但未指定 when 时默认 anytime`() {
        val engine = TestSupport.engine()
        val project = engine.createProject("项目 A")
        val todo = engine.createTodo("项目里的第一条", TodoOptions(projectId = project.id))
        assertEquals(When.ANYTIME, todo.`when`)
    }

    @Test
    fun `收件箱待办移入项目后自动变 anytime 且离开收件箱`() {
        val engine = TestSupport.engine()
        val project = engine.createProject("项目 B")
        val todo = engine.createTodo("待归类", TodoOptions(`when` = When.INBOX))

        engine.moveTodo(todo.id, project.id, null, null)

        assertFalse(engine.list(ListQuery.Inbox).any { it.id == todo.id })
        assertTrue(engine.list(ListQuery.Anytime).any { it.id == todo.id })
        assertEquals(When.ANYTIME, engine.todo(todo.id)?.`when`)
    }

    @Test
    fun `今天包含 today evening 过去日期与逾期截止`() {
        val engine = TestSupport.engine()
        val todayTodo = engine.createTodo("今天的", TodoOptions(`when` = When.TODAY))
        val eveningTodo = engine.createTodo("今晚的", TodoOptions(`when` = When.EVENING))
        val pastDate = engine.createTodo("排在过去", TodoOptions(`when` = When.DATE, date = day(-2)))
        val overdueDeadline = engine.createTodo("逾期截止", TodoOptions(`when` = When.ANYTIME))
        engine.setDeadline(overdueDeadline.id, day(-1))
        val future = engine.createTodo("未来的", TodoOptions(`when` = When.DATE, date = day(3)))

        val ids = engine.list(ListQuery.Today).map { it.id }
        assertTrue(ids.contains(todayTodo.id))
        assertTrue(ids.contains(eveningTodo.id))
        assertTrue(ids.contains(pastDate.id))
        assertTrue(ids.contains(overdueDeadline.id))
        assertFalse(ids.contains(future.id))
    }

    @Test
    fun `今晚分区使用 TONIGHT 类型且只含 evening`() {
        val engine = TestSupport.engine()
        engine.createTodo("白天的事", TodoOptions(`when` = When.TODAY))
        val evening = engine.createTodo("晚上的事", TodoOptions(`when` = When.EVENING))

        val sections = engine.sections(ListQuery.Today)
        val tonight = sections.firstOrNull { it.kind == SectionKind.TONIGHT }
        assertTrue("应存在 TONIGHT 分区", tonight != null)
        assertEquals(evening.id, tonight?.todos?.first()?.id)
        assertTrue(tonight?.todos?.all { it.`when` == When.EVENING } == true)
    }

    @Test
    fun `计划窗口是明天起 14 天 超出窗口归入更晚`() {
        val engine = TestSupport.engine()
        val day1 = engine.createTodo("明天", TodoOptions(`when` = When.DATE, date = day(1)))
        val day14 = engine.createTodo("第 14 天", TodoOptions(`when` = When.DATE, date = day(14)))
        val day15 = engine.createTodo("第 15 天", TodoOptions(`when` = When.DATE, date = day(15)))

        val sections = engine.sections(ListQuery.Upcoming)
        val inWindow = sections.filter { it.kind == SectionKind.DAY }.flatMap { it.todos }.map { it.id }
        assertTrue(inWindow.contains(day1.id))
        assertTrue(inWindow.contains(day14.id))
        assertFalse("第 15 天不应落在 14 天窗口的日期分组里", inWindow.contains(day15.id))

        // 契约 §4：超出窗口的待办归入「更晚」分组，而不是从计划里消失
        val later = sections.filter { it.kind == SectionKind.LATER }.flatMap { it.todos }.map { it.id }
        assertTrue("超出窗口应归入「更晚」", later.contains(day15.id))

        val listed = engine.list(ListQuery.Upcoming).map { it.id }
        assertTrue(listed.containsAll(listOf(day1.id, day14.id, day15.id)))
    }

    @Test
    fun `某天只包含 when=someday`() {
        val engine = TestSupport.engine()
        val someday = engine.createTodo("以后再说", TodoOptions(`when` = When.SOMEDAY))
        engine.createTodo("随时可做", TodoOptions(`when` = When.ANYTIME))
        assertEquals(listOf(someday.id), engine.list(ListQuery.Someday).map { it.id })
    }

    @Test
    fun `完成后的待办离开今天并进入日志簿`() {
        val engine = TestSupport.engine()
        val todo = engine.createTodo("要做完的事", TodoOptions(`when` = When.TODAY))
        engine.toggleDone(todo.id)

        assertFalse(engine.list(ListQuery.Today).any { it.id == todo.id })
        assertTrue(engine.list(ListQuery.Logbook).any { it.id == todo.id })
        assertEquals(Status.DONE, engine.todo(todo.id)?.status)
    }

    @Test
    fun `标签视图默认只看未完成 开启后包含已完成`() {
        val engine = TestSupport.engine()
        engine.ensureTag("重要")
        val open = engine.createTodo("未完成", TodoOptions(`when` = When.ANYTIME))
        engine.addTag(open.id, "重要")
        val done = engine.createTodo("已完成", TodoOptions(`when` = When.ANYTIME))
        engine.addTag(done.id, "重要")
        engine.toggleDone(done.id)

        val openOnly = engine.list(ListQuery.TagScope("重要")).map { it.id }
        assertEquals(listOf(open.id), openOnly)

        val all = engine.list(ListQuery.TagScope("重要", includeCompleted = true)).map { it.id }
        assertTrue(all.contains(open.id))
        assertTrue(all.contains(done.id))
    }

    @Test
    fun `项目进度等于 done 除以 done 加 open`() {
        val engine = TestSupport.engine()
        val project = engine.createProject("进度项目")
        val first = engine.createTodo("第一条", TodoOptions(`when` = When.ANYTIME, projectId = project.id))
        engine.createTodo("第二条", TodoOptions(`when` = When.ANYTIME, projectId = project.id))
        engine.toggleDone(first.id)

        assertEquals(0.5f, engine.projectProgress(project.id), 0.0001f)
        assertEquals(1, engine.counts().projects[project.id])
    }

    @Test
    fun `搜索命中标题与备注 且未完成优先`() {
        val engine = TestSupport.engine()
        val open = engine.createTodo("接口联调纪要", TodoOptions(`when` = When.ANYTIME))
        val doneTodo = engine.createTodo("接口联调复盘", TodoOptions(`when` = When.ANYTIME))
        engine.toggleDone(doneTodo.id)

        val results = engine.list(ListQuery.Search("接口联调")).map { it.id }
        assertTrue(results.contains(open.id))
        assertTrue(results.contains(doneTodo.id))
        assertEquals(open.id, results.first())
    }

    @Test
    fun `设置提醒后 when 自动提升为 today`() {
        val engine = TestSupport.engine()
        val todo = engine.createTodo("带提醒", TodoOptions(`when` = When.ANYTIME))
        engine.setReminder(todo.id, "${today}T18:00")

        val stored = engine.todo(todo.id)
        assertEquals("${today}T18:00", stored?.reminder)
        assertEquals(When.TODAY, stored?.`when`)
    }

    @Test
    fun `侧栏计数与各清单一致`() {
        val engine = TestSupport.engine()
        engine.createTodo("收件箱", TodoOptions(`when` = When.INBOX))
        engine.createTodo("今天", TodoOptions(`when` = When.TODAY))
        engine.createTodo("随时", TodoOptions(`when` = When.ANYTIME))
        engine.createTodo("某天", TodoOptions(`when` = When.SOMEDAY))
        engine.createTodo("计划", TodoOptions(`when` = When.DATE, date = day(2)))

        val counts = engine.counts()
        assertEquals(1, counts.inbox)
        assertEquals(1, counts.today)
        assertEquals(1, counts.anytime)
        assertEquals(1, counts.someday)
        assertEquals(1, counts.upcoming)
        assertEquals(0, counts.logbook)
    }

    @Test
    fun `演示数据规模符合契约与验收要求`() {
        // Android 端的 SeedData 只是共享核心示例数据的入口，这里守住"规模不缩水"
        val snapshot = com.ordo.android.data.SeedData.snapshot(TestSupport.nowMillis(), today)
        assertEquals(4, snapshot.areas.size)
        assertEquals(5, snapshot.projects.size)
        assertEquals(3, snapshot.headings.size)
        assertEquals(7, snapshot.tags.size)
        assertTrue("待办应不少于 30 条，实际 ${snapshot.todos.size}", snapshot.todos.size >= 30)
        assertTrue("应含已完成/已取消记录", snapshot.todos.any { it.status != Status.OPEN })
        assertTrue("应含重复待办", snapshot.todos.any { it.repeat != null })
        assertTrue("应含提醒", snapshot.todos.any { it.reminder != null })

        val events = com.ordo.android.data.SeedData.events(today)
        assertEquals(3, events.size)
        assertTrue(events.all { it.start.startsWith(today) })
    }
}
