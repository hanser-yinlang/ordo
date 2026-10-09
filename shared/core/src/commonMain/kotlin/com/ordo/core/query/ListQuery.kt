package com.ordo.core.query

import com.ordo.core.model.Todo

/** 派生清单查询(契约 §4)。所有清单都是查询,不落库。 */
sealed class ListQuery {
    object Inbox : ListQuery()
    object Today : ListQuery()
    object Upcoming : ListQuery()
    object Anytime : ListQuery()
    object Someday : ListQuery()
    object Logbook : ListQuery()
    data class ProjectScope(val id: String) : ListQuery()
    data class AreaScope(val id: String) : ListQuery()
    data class TagScope(val name: String, val includeCompleted: Boolean = false) : ListQuery()
    data class Search(val text: String) : ListQuery()

    /** 路由名称,四端一致:`inbox` / `today` / `project/<id>` … */
    val route: String
        get() = when (this) {
            is Inbox -> "inbox"
            is Today -> "today"
            is Upcoming -> "upcoming"
            is Anytime -> "anytime"
            is Someday -> "someday"
            is Logbook -> "logbook"
            is ProjectScope -> "project/$id"
            is AreaScope -> "area/$id"
            is TagScope -> "tag/$name"
            is Search -> "search"
        }
}

enum class SectionKind {
    /** 普通分组(随时/某天/标签) */
    PLAIN,

    /** 今天的日程之后、主列表之前 */
    PLAIN_TODAY,

    /** 「今晚」分区 */
    TONIGHT,

    /** 按天分组(计划/日志簿) */
    DAY,

    /** 项目内的标题(Heading)分组 */
    HEADING,

    /** 超出计划窗口的「更晚」 */
    LATER,

    /** 日志簿按完成日分组 */
    COMPLETION_DAY
}

data class ListSection(
    val title: String,
    val subtitle: String? = null,
    val kind: SectionKind = SectionKind.PLAIN,
    val todos: List<Todo> = emptyList(),
    /** 项目视图:标题 id(用于折叠/重命名);其他视图为 null */
    val headingId: String? = null
)

/** 侧栏计数与进度 */
data class SidebarCounts(
    val inbox: Int = 0,
    val today: Int = 0,
    val upcoming: Int = 0,
    val anytime: Int = 0,
    val someday: Int = 0,
    val logbook: Int = 0,
    val projects: Map<String, Int> = emptyMap(),
    val projectProgress: Map<String, Float> = emptyMap(),
    val tags: Map<String, Int> = emptyMap()
)
