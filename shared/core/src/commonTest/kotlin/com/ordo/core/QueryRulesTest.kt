package com.ordo.core

import com.ordo.core.model.Status
import com.ordo.core.model.RepeatFreq
import com.ordo.core.model.RepeatMode
import com.ordo.core.model.RepeatRule
import com.ordo.core.model.Todo
import com.ordo.core.model.When
import com.ordo.core.platform.FixedOrdoClock
import com.ordo.core.query.ListQuery
import com.ordo.core.query.SectionKind
import com.ordo.core.seed.SeedData
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.store.TodoOptions
import com.ordo.core.util.OrdoDate
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 派生清单规则测试 —— 逐条覆盖契约 §4。
 * 用例基于"今天"相对构造,保证任何时区/日期运行都成立。
 */
class QueryRulesTest {

    // 固定时钟的取值必须与"真实今天"对齐,否则演示数据里的相对日期会和断言错位
    private val fixedMillis = OrdoDate.nowMillis()
    private fun engine(): OrdoEngine {
        val clock = FixedOrdoClock(fixedMillis)
        val engine = OrdoEngine(InMemoryStorage(), clock)
        engine.seedDemoData(force = true)
        return engine
    }

    @Test
    fun inboxOnlyContainsInboxItems() {
        val e = engine()
        val inbox = e.list(ListQuery.Inbox)
        assertTrue(inbox.isNotEmpty(), "收件箱应有演示数据")
        assertTrue(inbox.all { it.`when` == When.INBOX }, "收件箱只能包含 `when`=inbox")
        assertTrue(inbox.all { it.status == Status.OPEN })
    }

    @Test
    fun todayIncludesOverdueDeadline() {
        val e = engine()
        val today = e.list(ListQuery.Today)
        val overdue = today.filter { it.deadline != null && it.deadline < OrdoDate.todayISO() }
        assertTrue(overdue.isNotEmpty(), "今天列表必须包含已逾期的截止项(契约 §4)")
    }

    @Test
    fun todaySectionsSplitTonight() {
        val e = engine()
        val sections = e.sections(ListQuery.Today)
        val tonight = sections.firstOrNull { it.title == "今晚" }
        assertTrue(tonight != null, "今天列表应有「今晚」分区")
        assertTrue(tonight!!.todos.all { it.`when` == When.EVENING })
        assertTrue(sections.first().title == "今天")
    }

    @Test
    fun upcomingWindowAndOverflow() {
        val e = engine()
        val sections = e.sections(ListQuery.Upcoming)
        assertTrue(sections.isNotEmpty())
        // 演示数据里 d(11) 的"整理书单并下单"在 14 天窗口内
        val all = sections.flatMap { it.todos }
        assertTrue(all.any { it.title.contains("整理书单") })
        // 分组标题都应是"…·周X"或"更晚"
        assertTrue(sections.all { it.title == "更晚" || it.title.contains("·") })
    }

    @Test
    fun somedayAndAnytimeAreDisjoint() {
        val e = engine()
        val someday = e.list(ListQuery.Someday)
        val anytime = e.list(ListQuery.Anytime)
        assertTrue(someday.all { it.`when` == When.SOMEDAY })
        assertTrue(anytime.all { it.`when` == When.ANYTIME })
        assertTrue(someday.map { it.id }.intersect(anytime.map { it.id }.toSet()).isEmpty())
    }

    @Test
    fun logbookOnlyClosedSortedDesc() {
        val e = engine()
        val logbook = e.list(ListQuery.Logbook)
        assertTrue(logbook.size >= 5, "演示数据含 5 条日志簿记录")
        assertTrue(logbook.all { it.status.isClosed })
        val completed = logbook.mapNotNull { it.completedAt }
        assertEquals(completed.sortedDescending(), completed)
    }

    @Test
    fun projectScopeGroupsByHeading() {
        val e = engine()
        val sections = e.sections(ListQuery.ProjectScope("p-launch"))
        val titles = sections.map { it.title }
        assertTrue(titles.contains("设计"))
        assertTrue(titles.contains("开发"))
        assertTrue(titles.contains("上线"))
        assertTrue(sections.flatMap { it.todos }.all { it.projectId == "p-launch" })
    }

    @Test
    fun tagScopeExcludesCompletedByDefault() {
        val e = engine()
        val open = e.list(ListQuery.TagScope("深度工作"))
        assertTrue(open.isNotEmpty())
        assertTrue(open.all { it.status == Status.OPEN && it.tags.contains("深度工作") })
    }

    @Test
    fun searchMatchesTitleAndNote() {
        val e = engine()
        assertTrue(e.list(ListQuery.Search("评审")).isNotEmpty())
        assertTrue(e.list(ListQuery.Search("finance/q3.csv")).isNotEmpty(), "应能搜到备注内容")
        assertTrue(e.list(ListQuery.Search("不存在的关键词")).isEmpty())
    }

    @Test
    fun countsMatchLists() {
        val e = engine()
        val counts = e.counts()
        assertEquals(e.list(ListQuery.Inbox).size, counts.inbox)
        assertEquals(e.list(ListQuery.Someday).size, counts.someday)
        assertEquals(e.list(ListQuery.Logbook).size, counts.logbook)
        assertTrue(counts.projects.containsKey("p-launch"))
        val progress = counts.projectProgress["p-launch"] ?: 0f
        assertTrue(progress > 0f && progress < 1f, "Q4 产品发布应处于进行中")
    }

    /** 契约 §3 不变量:移入项目后 inbox 自动变 anytime */
    @Test
    fun movingInboxTodoIntoProjectChangesWhen() {
        val e = engine()
        val inboxItem = e.list(ListQuery.Inbox).first()
        e.moveTodo(inboxItem.id, "p-web", null, null)
        val moved = e.todo(inboxItem.id)!!
        assertEquals(When.ANYTIME, moved.`when`)
        assertTrue(e.list(ListQuery.Inbox).none { it.id == inboxItem.id })
    }

    /** 契约 §3 不变量:设置提醒会把无日期待办移入今天 */
    @Test
    fun settingReminderMovesTodoToToday() {
        val e = engine()
        val someday = e.list(ListQuery.Someday).first()
        e.setReminder(someday.id, OrdoDate.dateTime(OrdoDate.todayISO(), "18:00"))
        val updated = e.todo(someday.id)!!
        assertEquals(When.TODAY, updated.`when`)
        assertTrue(e.list(ListQuery.Today).any { it.id == someday.id })
    }

    @Test
    fun createTodoParsesNaturalLanguage() {
        val e = engine()
        val todo: Todo = e.createTodo("明天 18:00 交季度报告 #重要")
        assertEquals("交季度报告", todo.title)
        assertEquals(When.DATE, todo.`when`)
        assertEquals(OrdoDate.plusDays(OrdoDate.todayISO(), 1), todo.date)
        assertEquals(OrdoDate.dateTime(todo.date!!, "18:00"), todo.reminder)
        assertEquals(listOf("重要"), todo.tags)
        assertTrue(e.tags().any { it.name == "重要" })
    }

    @Test
    fun newTodoWithoutProjectGoesToInbox() {
        val e = engine()
        val todo = e.createTodo("随手记一件事")
        assertEquals(When.INBOX, todo.`when`)
        assertTrue(e.list(ListQuery.Inbox).any { it.id == todo.id })
    }

    @Test
    fun newTodoInsideProjectGoesToAnytime() {
        val e = engine()
        val todo = e.createTodo("写测试", com.ordo.core.store.TodoOptions(projectId = "p-web"))
        assertEquals(When.ANYTIME, todo.`when`)
    }

    @Test
    fun anytimeRespectsManualOrder() {
        // 桌面端拖拽排序会写 order;若派生清单不按 order 排序,拖完行会"弹回原位"
        val e = engine()
        val before = e.list(ListQuery.Anytime)
        assertTrue(before.size >= 2, "需要至少两条随时待办才能验证排序")
        val reversedIds = before.map { it.id }.reversed()
        e.reorderTodos(reversedIds)

        assertEquals(reversedIds, e.list(ListQuery.Anytime).map { it.id }, "随时清单必须遵循手工排序")

        // 分组视图按项目分组,同一组的条目在全局手工序里可能不相邻,因此断言"组内有序"而非"拉平等于全局序"
        val rank = reversedIds.withIndex().associate { (i, id) -> id to i }
        val sections = e.sections(ListQuery.Anytime)
        assertTrue(sections.isNotEmpty())
        sections.forEach { section ->
            val ranks = section.todos.map { rank.getValue(it.id) }
            assertEquals(ranks.sorted(), ranks, "分组「${section.title}」内的顺序必须遵循手工排序")
        }
    }

    @Test
    fun somedayRespectsManualOrder() {
        val e = engine()
        val before = e.list(ListQuery.Someday)
        assertTrue(before.size >= 2)
        val reversedIds = before.map { it.id }.reversed()
        e.reorderTodos(reversedIds)
        assertEquals(reversedIds, e.list(ListQuery.Someday).map { it.id })
    }

    @Test
    fun repeatingTodoEntersUpcomingByNextOccurrence() {
        // 契约 §4 来源 3:repeat != null 的下一次发生日 ∈ 窗口 时必须进入「计划」。
        // 此前的实现只看 date/deadline,导致重复待办永远不进计划清单(鸿蒙移植版先发现,核心同病)。
        val e = engine()
        val today = OrdoDate.todayISO(FixedOrdoClock(fixedMillis))
        val todo = e.createTodo("每周复盘", TodoOptions(`when` = When.DATE, date = OrdoDate.plusDays(today, -30)))
        e.setRepeat(todo!!.id, RepeatRule(RepeatFreq.WEEKLY, interval = 1, mode = RepeatMode.FIXED))

        val inUpcoming = e.list(ListQuery.Upcoming).any { it.id == todo.id }
        assertTrue(inUpcoming, "每周重复的待办必须按下一次发生日进入「计划」")

        // 下一次发生日应落在窗口内,且严格晚于今天
        val sections = e.sections(ListQuery.Upcoming)
        val day = sections.firstOrNull { s -> s.todos.any { it.id == todo.id } }?.title
        assertTrue(day != null && day != "更晚", "下一次发生日应在 14 天窗口内,实际分组: $day")
    }

    @Test
    fun repeatingTodoFarInFutureGoesToOverflow() {
        // 每年一次、基准日在 3 年前 → 下一次发生日可能超出窗口 → 归入「更晚」而不是消失
        val e = engine()
        val today = OrdoDate.todayISO(FixedOrdoClock(fixedMillis))
        val todo = e.createTodo("年度体检", TodoOptions(`when` = When.DATE, date = OrdoDate.plusDays(today, -1000)))
        e.setRepeat(todo!!.id, RepeatRule(RepeatFreq.YEARLY, interval = 1, mode = RepeatMode.FIXED))

        val listed = e.list(ListQuery.Upcoming).any { it.id == todo.id }
        val overflow = e.sections(ListQuery.Upcoming).any { it.kind == SectionKind.LATER && it.todos.any { t -> t.id == todo.id } }
        // 要么落在窗口内,要么进「更晚」,不能两者都不出现
        assertTrue(listed || overflow, "重复待办即使超出窗口也必须归入「更晚」,不能凭空消失")
    }

    @Test
    fun seedDataHasExpectedShape() {
        val snapshot = SeedData.demo(fixedMillis, OrdoDate.todayISO())
        assertEquals(4, snapshot.areas.size)
        assertEquals(5, snapshot.projects.size)
        assertEquals(3, snapshot.headings.size)
        assertEquals(7, snapshot.tags.size)
        assertTrue(snapshot.todos.size >= 30)
    }
}
