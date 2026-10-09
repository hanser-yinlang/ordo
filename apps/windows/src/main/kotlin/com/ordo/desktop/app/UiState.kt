package com.ordo.desktop.app

import com.ordo.core.model.Area
import com.ordo.core.model.CalendarEvent
import com.ordo.core.model.Heading
import com.ordo.core.model.Project
import com.ordo.core.model.Tag
import com.ordo.core.model.Todo
import com.ordo.core.model.When
import com.ordo.core.query.ListSection
import com.ordo.core.query.SidebarCounts

/** 外观模式(04-UI规范 §6:Ctrl+D 循环 自动 / 浅色 / 深色) */
enum class ThemeMode { AUTO, LIGHT, DARK }

/** 同步状态(§3 状态栏) */
enum class SyncStatus { LOCAL, SYNCING, SYNCED, OFFLINE, ERROR }

/** 提示条(§4 Toast) */
data class ToastMessage(val text: String, val id: Long)

/** 需要二次确认的破坏性操作(删除项目 / 区域 / 标题) */
enum class ConfirmKind { PROJECT, AREA, HEADING }

/** 待确认的删除请求:只有点了"删除"才真正落库(契约 §3 一律软删除) */
data class ConfirmRequest(val kind: ConfirmKind, val id: String, val name: String) {

    val title: String
        get() = when (kind) {
            ConfirmKind.PROJECT -> "删除项目"
            ConfirmKind.AREA -> "删除区域"
            ConfirmKind.HEADING -> "删除标题"
        }

    val message: String
        get() = when (kind) {
            ConfirmKind.PROJECT -> "「$name」及其下的待办会被删除(软删除,会同步到其它端)。"
            ConfirmKind.AREA -> "「$name」会被删除,区域内的项目将变为「无区域」。"
            ConfirmKind.HEADING -> "「$name」会被删除,标题下的待办移到「其他」。"
        }
}

/** 桌面端界面状态:全部由 [OrdoViewModel] 从引擎快照派生 */
data class UiState(
    val route: OrdoRoute = OrdoRoute.Today,
    val sections: List<ListSection> = emptyList(),
    val counts: SidebarCounts = SidebarCounts(),
    val areas: List<Area> = emptyList(),
    val projects: List<Project> = emptyList(),
    val headings: List<Heading> = emptyList(),
    val tags: List<Tag> = emptyList(),
    val agenda: List<CalendarEvent> = emptyList(),
    val selectedId: String? = null,
    /** 键盘 ↑↓ 移动的高亮行(与"展开详情"分离,见 04-UI规范 §6) */
    val highlightId: String? = null,
    val themeMode: ThemeMode = ThemeMode.AUTO,
    val dark: Boolean = false,
    val syncStatus: SyncStatus = SyncStatus.LOCAL,
    val syncDetail: String? = null,
    val fastFindOpen: Boolean = false,
    val settingsOpen: Boolean = false,
    val scheduleTargetId: String? = null,
    val scheduleForDeadline: Boolean = false,
    val quickAddMenuOpen: Boolean = false,
    val composerOpen: Boolean = false,
    val composerWhen: When? = null,
    val composerHeadingId: String? = null,
    val toast: ToastMessage? = null,
    val focusTodoId: String? = null,
    /** 列表里正在拖拽排序(拖动中 Esc 优先取消拖动,而不是关浮层) */
    val dragActive: Boolean = false,
    /** Esc 取消拖动的令牌:自增一次,列表侧观察到变化就取消当前拖动 */
    val dragCancelToken: Long = 0L,
    /** 待二次确认的删除(项目 / 区域 / 标题) */
    val confirm: ConfirmRequest? = null,
    /** 关闭窗口时最小化到托盘(设置页开关) */
    val closeToTray: Boolean = true,
    /** 多窗口之间跟随选中(设置页开关) */
    val followSelection: Boolean = true
) {
    /** 当前清单的全部待办(按分组顺序拍平,供键盘上下移动使用) */
    val flatTodos: List<Todo> get() = sections.flatMap { it.todos }

    val headerTitle: String get() = route.title
    val totalCount: Int get() = flatTodos.size
}
