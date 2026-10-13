package com.ordo.android.vm

import com.ordo.android.ui.theme.ThemeMode
import com.ordo.core.model.CalendarEvent
import com.ordo.core.model.RepeatFreq
import com.ordo.core.model.RepeatMode
import com.ordo.core.model.Status
import com.ordo.core.model.When
import com.ordo.core.query.SectionKind

/* ============================================================================
 * UI 状态（单向数据流：UI → ViewModel → OrdoEngine → StateFlow → UI）
 * 所有字段都是不可变值对象，供 Compose 直接渲染。
 * ========================================================================== */

data class SidebarCountsUi(
    val inbox: Int = 0,
    val today: Int = 0,
    val upcoming: Int = 0,
    val anytime: Int = 0,
    val someday: Int = 0,
    val logbook: Int = 0,
)

data class ProjectNodeUi(
    val id: String,
    val name: String,
    val areaId: String?,
    /** 0f..1f（来自 core 的 SidebarCounts.projectProgress，契约 §4） */
    val progress: Float,
    val openCount: Int,
)

data class AreaNodeUi(
    val id: String,
    val name: String,
    val color: String?,
    val collapsed: Boolean,
    val projects: List<ProjectNodeUi>,
)

data class TagNodeUi(
    val name: String,
    val color: String?,
    val count: Int,
)

data class ChecklistItemUi(
    val id: String,
    val title: String,
    val done: Boolean,
)

data class TodoRowUi(
    val id: String,
    val title: String,
    val notePreview: String,
    val status: Status,
    val whenValue: When,
    val whenLabel: String?,
    val reminderLabel: String?,
    val reminderPast: Boolean,
    val deadlineLabel: String?,
    val deadlineOverdue: Boolean,
    val tags: List<String>,
    val checklistDone: Int,
    val checklistTotal: Int,
    val hasNote: Boolean,
    val repeat: Boolean,
    val completedAtLabel: String?,
)

data class SectionUi(
    /** 分组标题（今天的「今晚」、「计划」的日期、项目内的标题…） */
    val title: String?,
    val kind: SectionKind,
    val todos: List<TodoRowUi>,
    /** 项目视图：标题 id（来自 core 的 ListSection.headingId） */
    val headingId: String? = null,
    val collapsed: Boolean = false,
)

data class AgendaItemUi(
    val id: String,
    val time: String,
    val title: String,
    val calendar: String,
    val past: Boolean,
)

data class HeadingUi(
    val id: String,
    val name: String,
    val collapsed: Boolean,
    val archived: Boolean,
)

data class ProjectHeaderUi(
    val id: String,
    val name: String,
    val note: String,
    val areaName: String?,
    val progress: Float,
    val doneCount: Int,
    val openCount: Int,
    val headings: List<HeadingUi>,
    val status: Status,
)

data class DetailUi(
    val id: String,
    val title: String,
    val note: String,
    val whenValue: When,
    val whenLabel: String,
    val deadlineLabel: String?,
    val deadlineOverdue: Boolean,
    val reminderLabel: String?,
    val reminderRaw: String?,
    val reminderPast: Boolean,
    val repeatLabel: String?,
    val repeatFreq: RepeatFreq?,
    val repeatMode: RepeatMode?,
    val projectId: String?,
    val projectName: String?,
    val tags: List<String>,
    val checklist: List<ChecklistItemUi>,
    val status: Status,
)

enum class SearchKind { TODO, PROJECT, AREA, TAG }

data class SearchResultUi(
    val id: String,
    val kind: SearchKind,
    val title: String,
    val subtitle: String?,
    /** 目标路由（与 nav/Routes.kt 一致） */
    val route: String,
)

data class ScheduleTargetUi(
    val todoId: String,
    /** true = 正在为「截止日期」排期 */
    val forDeadline: Boolean,
)

data class UiState(
    val loading: Boolean = true,
    val routeKey: String = ROUTE_TODAY,
    val title: String = "",
    val subtitle: String = "",
    val sections: List<SectionUi> = emptyList(),
    val agenda: List<AgendaItemUi> = emptyList(),
    val counts: SidebarCountsUi = SidebarCountsUi(),
    val areas: List<AreaNodeUi> = emptyList(),
    val tags: List<TagNodeUi> = emptyList(),
    val projectHeader: ProjectHeaderUi? = null,
    val selectedTodoId: String? = null,
    val detail: DetailUi? = null,
    val themeMode: ThemeMode = ThemeMode.AUTO,
    val searchQuery: String = "",
    val searchResults: List<SearchResultUi> = emptyList(),
    val fastFindOpen: Boolean = false,
    val quickAddMenuOpen: Boolean = false,
    val scheduleTarget: ScheduleTargetUi? = null,
    /** 新建待办浮层：纯状态机见 [ComposerState]（打开/重复点击/关闭/提交四处语义都在那里） */
    val composer: ComposerState = ComposerState(),
    val showCompleted: Boolean = false,
    val toast: String? = null,
    val totalCount: Int = 0,
    val doneCount: Int = 0,
    val sidebarOpen: Boolean = false,
    /** 设备本地只读日历事件（契约 §2.8，不上传） */
    val eventList: List<CalendarEvent> = emptyList(),
) {
    companion object {
        const val ROUTE_INBOX = "inbox"
        const val ROUTE_TODAY = "today"
        const val ROUTE_UPCOMING = "upcoming"
        const val ROUTE_ANYTIME = "anytime"
        const val ROUTE_SOMEDAY = "someday"
        const val ROUTE_LOGBOOK = "logbook"
        const val ROUTE_SEARCH = "search"
        const val ROUTE_SETTINGS = "settings"
    }
}
