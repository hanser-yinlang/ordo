package com.ordo.desktop.app

import com.ordo.core.query.ListQuery

/**
 * 桌面端路由:清单即路由(契约 §4)。
 *
 * `key` 与 [ListQuery.route] 完全一致,便于四端对齐与深链解析(`ordo://today`)。
 */
sealed class OrdoRoute {

    abstract val key: String
    abstract val title: String
    abstract val query: ListQuery

    object Inbox : OrdoRoute() {
        override val key = "inbox"
        override val title = "收件箱"
        override val query: ListQuery = ListQuery.Inbox
    }

    object Today : OrdoRoute() {
        override val key = "today"
        override val title = "今天"
        override val query: ListQuery = ListQuery.Today
    }

    object Upcoming : OrdoRoute() {
        override val key = "upcoming"
        override val title = "计划"
        override val query: ListQuery = ListQuery.Upcoming
    }

    object Anytime : OrdoRoute() {
        override val key = "anytime"
        override val title = "随时"
        override val query: ListQuery = ListQuery.Anytime
    }

    object Someday : OrdoRoute() {
        override val key = "someday"
        override val title = "某天"
        override val query: ListQuery = ListQuery.Someday
    }

    object Logbook : OrdoRoute() {
        override val key = "logbook"
        override val title = "日志簿"
        override val query: ListQuery = ListQuery.Logbook
    }

    data class Project(val id: String) : OrdoRoute() {
        override val key get() = "project/$id"
        override val title get() = "项目"
        override val query: ListQuery get() = ListQuery.ProjectScope(id)
    }

    data class Area(val id: String) : OrdoRoute() {
        override val key get() = "area/$id"
        override val title get() = "区域"
        override val query: ListQuery get() = ListQuery.AreaScope(id)
    }

    data class Tag(val name: String) : OrdoRoute() {
        override val key get() = "tag/$name"
        override val title get() = name
        override val query: ListQuery get() = ListQuery.TagScope(name)
    }

    data class Search(val text: String) : OrdoRoute() {
        override val key get() = "search"
        override val title get() = "搜索"
        override val query: ListQuery get() = ListQuery.Search(text)
    }

    companion object {

        /** 固定清单(快捷键 1–6 的顺序) */
        val fixed: List<OrdoRoute> = fixedRoutes()

        /** 固定清单的构造:用函数而不是共享列表字面量,避免调用方看到静态初始化期的半成品 */
        private fun fixedRoutes(): List<OrdoRoute> =
            listOf(Inbox, Today, Upcoming, Anytime, Someday, Logbook)

        /**
         * 路由 key → 路由(深链 / 快找用)。
         *
         * 未知 key 一律回落到「今天」:**深链绝不能把应用打崩**(外面的进程可能传来任何字符串),
         * 因此这里逐个比较、并对拿到的元素做非空防御。
         */
        fun fromKey(key: String): OrdoRoute {
            val clean = key.trim().removePrefix("#").removePrefix("/")
            return when {
                clean.startsWith("project/") -> Project(clean.removePrefix("project/"))
                clean.startsWith("area/") -> Area(clean.removePrefix("area/"))
                clean.startsWith("tag/") -> Tag(decode(clean.removePrefix("tag/")))
                clean.startsWith("search") -> Search("")
                clean.equals("inbox", true) -> Inbox
                clean.equals("today", true) -> Today
                clean.equals("upcoming", true) -> Upcoming
                clean.equals("anytime", true) -> Anytime
                clean.equals("someday", true) -> Someday
                clean.equals("logbook", true) -> Logbook
                else -> Today
            }
        }

        private fun decode(value: String): String =
            runCatching { java.net.URLDecoder.decode(value, "UTF-8") }.getOrDefault(value)
    }
}
