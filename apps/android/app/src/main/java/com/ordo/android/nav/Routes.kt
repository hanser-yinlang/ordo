package com.ordo.android.nav

/** 路由定义（与契约 §4 的派生清单一一对应） */
object Routes {
    const val INBOX = "inbox"
    const val TODAY = "today"
    const val UPCOMING = "upcoming"
    const val ANYTIME = "anytime"
    const val SOMEDAY = "someday"
    const val LOGBOOK = "logbook"
    const val SEARCH = "search"
    const val SETTINGS = "settings"

    const val PROJECT_ARG = "projectId"
    const val AREA_ARG = "areaId"
    const val TAG_ARG = "tagName"

    const val PROJECT_PATTERN = "project/{$PROJECT_ARG}"
    const val AREA_PATTERN = "area/{$AREA_ARG}"
    const val TAG_PATTERN = "tag/{$TAG_ARG}"

    fun project(id: String): String = "project/$id"

    fun area(id: String): String = "area/$id"

    fun tag(name: String): String = "tag/" + java.net.URLEncoder.encode(name, "UTF-8")

    /** 深链 ordo://... → 路由 */
    fun fromDeepLink(host: String?, segment: String?): String? = when (host) {
        "todo" -> segment?.let { "detail/$it" }
        "project" -> segment?.let { project(it) }
        "area" -> segment?.let { area(it) }
        "tag" -> segment?.let { tag(it) }
        "list" -> segment
        "today" -> TODAY
        "inbox" -> INBOX
        else -> null
    }

    val startDestinations: List<String> = listOf(INBOX, TODAY, UPCOMING, ANYTIME, SOMEDAY, LOGBOOK)
}
