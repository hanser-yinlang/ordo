package com.ordo.core.query

import com.ordo.core.model.Heading
import com.ordo.core.model.OrdoSnapshot
import com.ordo.core.model.Status
import com.ordo.core.model.Todo
import com.ordo.core.model.When
import com.ordo.core.platform.OrdoClock
import com.ordo.core.platform.SystemOrdoClock
import com.ordo.core.repeat.RepeatEngine
import com.ordo.core.util.OrdoDate

/**
 * 派生清单查询引擎 —— 严格实现契约 §4 的每一条规则。
 * 纯函数式:输入快照,输出列表/分组/计数,不修改任何状态。
 */
class QueryEngine(
    private val snapshotProvider: () -> OrdoSnapshot,
    private val clock: OrdoClock = SystemOrdoClock
) {

    private val snapshot: OrdoSnapshot get() = snapshotProvider()

    private fun live(): List<Todo> = snapshot.todos.filter { !it.deleted }

    private fun open(): List<Todo> = live().filter { it.status == Status.OPEN }

    // ---------------------------------------------------------------- 单清单

    fun list(query: ListQuery): List<Todo> = when (query) {
        is ListQuery.Inbox -> inbox()
        is ListQuery.Today -> today()
        is ListQuery.Upcoming -> upcoming()
        is ListQuery.Anytime -> open().filter { it.`when` == When.ANYTIME }.byManualOrder()
        is ListQuery.Someday -> open().filter { it.`when` == When.SOMEDAY }.byManualOrder()
        is ListQuery.Logbook -> logbook()
        is ListQuery.ProjectScope -> projectTodos(query.id)
        is ListQuery.AreaScope -> areaTodos(query.id)
        is ListQuery.TagScope -> tagged(query.name, query.includeCompleted)
        is ListQuery.Search -> search(query.text)
    }

    fun inbox(): List<Todo> = open()
        .filter { it.`when` == When.INBOX }
        .sortedWith(compareBy({ it.order }, { it.createdAt }))

    /** 今天 = `when`∈{today,evening} ∪ 今天或更早开始的 date 项 ∪ 今天或更早的截止项(契约 §4) */
    fun today(): List<Todo> {
        val t = OrdoDate.todayISO(clock)
        return open().filter { todo ->
            when (todo.`when`) {
                When.TODAY, When.EVENING -> true
                When.DATE -> todo.date != null && todo.date <= t
                else -> false
            } || (todo.deadline != null && todo.deadline <= t)
        }.sortedWith(compareBy({ if (it.`when` == When.EVENING) 1 else 0 }, { it.order }, { it.createdAt }))
    }

    /** 计划:明天起 14 天窗口(契约 §4) */
    fun upcoming(): List<Todo> {
        val today = OrdoDate.todayISO(clock)
        val windowEnd = OrdoDate.plusDays(today, UPCOMING_WINDOW_DAYS)
        return open().mapNotNull { todo ->
            val day = upcomingDayOf(todo, today, windowEnd) ?: return@mapNotNull null
            todo to day
        }.sortedWith(compareBy({ it.second }, { it.first.order }))
            .map { it.first }
    }

    private fun upcomingDayOf(todo: Todo, today: String, windowEnd: String): String? {
        // 契约 §4 来源 3:重复实例按"下一次发生日"进计划窗口。
        // 基准日取 date(首次发生日);没有 date 的重复待办按今天起算。
        // 注意:基准日往往早已过期,必须一路推进到今天之后,否则会出现
        // "重复待办在计划清单里永远不出现"或"首次发生日已过期就被整条丢弃"两类错误。
        val repeat = todo.repeat
        if (repeat != null) {
            var next = RepeatEngine.nextDate(repeat, todo.date ?: today)
            var guard = 0
            while (next <= today && guard < MAX_REPEAT_ADVANCE) {
                next = RepeatEngine.nextDate(repeat, next)
                guard++
            }
            if (next > today && next <= windowEnd) return next
            if (next > windowEnd) return OVERFLOW_DAY
            return null
        }
        todo.date?.let { d ->
            if (todo.`when` == When.DATE && d > today && d <= windowEnd) return d
            if (todo.`when` == When.DATE && d > windowEnd) return OVERFLOW_DAY
        }
        todo.deadline?.let { d ->
            if (d > today && d <= windowEnd) return d
            if (d > windowEnd) return OVERFLOW_DAY
        }
        return null
    }

    fun logbook(): List<Todo> = live()
        .filter { it.status.isClosed }
        .sortedByDescending { it.completedAt ?: it.updatedAt }

    fun projectTodos(projectId: String): List<Todo> = open()
        .filter { it.projectId == projectId }
        .sortedWith(compareBy({ it.order }, { it.createdAt }))

    fun areaTodos(areaId: String): List<Todo> {
        val projectIds = snapshot.projects.filter { it.areaId == areaId && !it.deleted }.map { it.id }.toSet()
        return open()
            .filter { it.areaId == areaId || (it.projectId != null && it.projectId in projectIds) }
            .sortedWith(compareBy({ it.order }, { it.createdAt }))
    }

    fun tagged(name: String, includeCompleted: Boolean = false): List<Todo> =
        live().filter { it.tags.contains(name) && (includeCompleted || it.status == Status.OPEN) }
            .sortedWith(compareBy({ it.status.isClosed }, { -it.updatedAt }))

    fun search(text: String): List<Todo> {
        val q = text.trim().lowercase()
        if (q.isEmpty()) return emptyList()
        return live()
            .filter { it.title.lowercase().contains(q) || it.note.lowercase().contains(q) }
            .sortedWith(compareBy({ it.status.isClosed }, { -it.updatedAt }))
    }

    // ---------------------------------------------------------------- 分组

    fun sections(query: ListQuery): List<ListSection> = when (query) {
        is ListQuery.Today -> todaySections()
        is ListQuery.Upcoming -> upcomingSections()
        is ListQuery.Logbook -> logbookSections()
        is ListQuery.ProjectScope -> projectSections(query.id)
        is ListQuery.Anytime -> groupByProject(open().filter { it.`when` == When.ANYTIME }.byManualOrder())
        is ListQuery.AreaScope -> groupByProject(areaTodos(query.id))
        is ListQuery.TagScope -> groupByProject(tagged(query.name, query.includeCompleted))
        else -> list(query).let { if (it.isEmpty()) emptyList() else listOf(ListSection("", null, SectionKind.PLAIN, it)) }
    }

    private fun todaySections(): List<ListSection> {
        val all = today()
        val day = all.filter { it.`when` != When.EVENING }
        val evening = all.filter { it.`when` == When.EVENING }
        val out = ArrayList<ListSection>(2)
        if (day.isNotEmpty()) out.add(ListSection("今天", day.size.toString(), SectionKind.PLAIN_TODAY, day))
        if (evening.isNotEmpty()) out.add(ListSection("今晚", evening.size.toString(), SectionKind.TONIGHT, evening))
        return out
    }

    private fun upcomingSections(): List<ListSection> {
        val today = OrdoDate.todayISO(clock)
        val windowEnd = OrdoDate.plusDays(today, UPCOMING_WINDOW_DAYS)
        val buckets = LinkedHashMap<String, MutableList<Todo>>()
        open().forEach { todo ->
            val day = upcomingDayOf(todo, today, windowEnd) ?: return@forEach
            buckets.getOrPut(day) { mutableListOf() }.add(todo)
        }
        return buckets.entries.sortedBy { it.key }.map { (day, todos) ->
            val isOverflow = day == OVERFLOW_DAY
            ListSection(
                title = if (isOverflow) "更晚" else OrdoDate.dayLabelCn(day, clock),
                subtitle = todos.size.toString(),
                kind = if (isOverflow) SectionKind.LATER else SectionKind.DAY,
                todos = todos.sortedBy { it.order }
            )
        }
    }

    private fun logbookSections(): List<ListSection> {
        val byDay = logbook().groupBy { todo ->
            val millis = todo.completedAt
            if (millis == null) OrdoDate.todayISO(clock)
            else OrdoDate.isoFromLocalMillis(millis + utcOffset())
        }
        return byDay.entries.sortedByDescending { it.key }.map { (day, todos) ->
            ListSection(
                title = OrdoDate.dayLabelCn(day, clock),
                subtitle = todos.size.toString(),
                kind = SectionKind.COMPLETION_DAY,
                todos = todos
            )
        }
    }

    private fun projectSections(projectId: String): List<ListSection> {
        val todos = projectTodos(projectId)
        val headings = headingsOf(projectId)
        val out = ArrayList<ListSection>()
        headings.forEach { heading ->
            val group = todos.filter { it.headingId == heading.id }
            out.add(
                ListSection(
                    title = heading.name,
                    subtitle = if (group.isEmpty()) null else group.size.toString(),
                    kind = SectionKind.HEADING,
                    todos = group,
                    headingId = heading.id
                )
            )
        }
        val orphans = todos.filter { todo -> headings.none { it.id == todo.headingId } }
        if (orphans.isNotEmpty()) {
            out.add(ListSection("其他", orphans.size.toString(), SectionKind.PLAIN, orphans))
        }
        return out
    }

    private fun groupByProject(todos: List<Todo>): List<ListSection> {
        if (todos.isEmpty()) return emptyList()
        val byProject = LinkedHashMap<String, MutableList<Todo>>()
        val buckets = ArrayList<ListSection>()
        todos.forEach { todo ->
            val key = todo.projectId ?: AREA_LESS_KEY
            byProject.getOrPut(key) { mutableListOf() }.add(todo)
        }
        byProject.forEach { (key, group) ->
            val title = if (key == AREA_LESS_KEY) "无项目"
            else snapshot.projects.firstOrNull { it.id == key }?.name ?: "无项目"
            // 组内同样遵循用户手工排序(order),否则拖拽后行会弹回原位
            buckets.add(ListSection(title, group.size.toString(), SectionKind.PLAIN, group.byManualOrder()))
        }
        return buckets
    }

    /** 用户手工排序(契约 §2.4 的 order 字段):先 order,再按创建时间兜底 */
    private fun List<Todo>.byManualOrder(): List<Todo> =
        sortedWith(compareBy({ it.order }, { it.createdAt }))

    // ---------------------------------------------------------------- 辅助

    fun headingsOf(projectId: String): List<Heading> =
        snapshot.headings.filter { it.projectId == projectId && !it.deleted && !it.archived }
            .sortedBy { it.order }

    fun projectProgress(projectId: String): Float {
        val all = live().filter { it.projectId == projectId }
        if (all.isEmpty()) return 0f
        val done = all.count { it.status == Status.DONE }
        return done.toFloat() / all.size.toFloat()
    }

    fun counts(): SidebarCounts {
        val openTodos = open()
        val projectCounts = HashMap<String, Int>()
        val projectProgress = HashMap<String, Float>()
        snapshot.projects.filter { !it.deleted }.forEach { project ->
            val all = live().filter { it.projectId == project.id }
            projectCounts[project.id] = all.count { it.status == Status.OPEN }
            projectProgress[project.id] =
                if (all.isEmpty()) 0f else all.count { it.status == Status.DONE }.toFloat() / all.size.toFloat()
        }
        val tagCounts = HashMap<String, Int>()
        openTodos.forEach { todo -> todo.tags.forEach { tag -> tagCounts[tag] = (tagCounts[tag] ?: 0) + 1 } }
        snapshot.tags.filter { !it.deleted }.forEach { tagCounts.getOrPut(it.name) { 0 } }

        val todayCount = today().size
        return SidebarCounts(
            inbox = inbox().size,
            today = todayCount,
            upcoming = upcoming().size,
            anytime = openTodos.count { it.`when` == When.ANYTIME },
            someday = openTodos.count { it.`when` == When.SOMEDAY },
            logbook = live().count { it.status.isClosed },
            projects = projectCounts,
            projectProgress = projectProgress,
            tags = tagCounts
        )
    }

    private fun utcOffset(): Long = com.ordo.core.platform.PlatformTime.utcOffsetMillis()

    companion object {
        const val UPCOMING_WINDOW_DAYS = 14
        const val OVERFLOW_DAY = "9999-12-31"
        /** 推进重复实例时的安全上限:每天一次的规则推进 400 次足够覆盖约 1 年的过期量 */
        private const val MAX_REPEAT_ADVANCE = 400
        private const val AREA_LESS_KEY = "__none__"
    }
}
