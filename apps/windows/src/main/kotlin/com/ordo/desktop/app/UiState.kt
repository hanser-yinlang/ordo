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

/** 提示条(§4 Toast) */
data class ToastMessage(val text: String, val id: Long)

/** 需要二次确认的破坏性操作(删除项目 / 区域 / 标题) */
enum class ConfirmKind { PROJECT, AREA, HEADING }

/**
 * 项目卡片的一句话状态:把"能不能完成 / 为什么不能"收敛成一个**可测的纯值**,
 * 由视图模型按 [com.ordo.core.query.SidebarCounts.projects] 填好,界面只负责画。
 *
 * @param openCount 该项目下 `status == OPEN` 的待办数 —— 契约 §2.2 v1.1 的**唯一**硬约束
 * @param totalCount 该项目下未删除的待办总数(仅用于卡片文案,不参与判定)
 */
data class ProjectCardState(
    val projectId: String,
    val openCount: Int,
    val totalCount: Int
) {
    /** 唯一硬约束:所有待办都已结束(done / canceled)才允许完成;heading 是容器,不阻塞完成 */
    val canComplete: Boolean get() = openCount == 0

    fun countText(): String = "$totalCount 项 · 剩 $openCount 项未完成"

    /** 不可完成时按钮上的原因(与 [resultMessage] 同源,不会出现"文案说能、行为说不能") */
    fun blockedReason(): String = completionBlockedMessage(openCount)

    /**
     * 完成结果提示。
     *
     * v1.1 修订后 `completeProject` 返回 false 的**唯一**原因是"还有 N 项未完成待办":
     * 旧文案「还有未完成的待办或标题」会把用户引向已不存在的 heading 归档要求。
     */
    fun resultMessage(ok: Boolean): String = if (ok) "项目已完成" else blockedReason()

    companion object {
        fun completionBlockedMessage(openCount: Int): String = "还有 $openCount 项未完成的待办"
    }
}

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
    /** 每个项目的卡片状态(openCount 来自核心计数,供"完成项目"按钮与提示文案共用同一口径) */
    val projectCards: Map<String, ProjectCardState> = emptyMap(),
    val headings: List<Heading> = emptyList(),
    val tags: List<Tag> = emptyList(),
    val agenda: List<CalendarEvent> = emptyList(),
    val selectedId: String? = null,
    /** 键盘 ↑↓ 移动的高亮行(与"展开详情"分离,见 04-UI规范 §6) */
    val highlightId: String? = null,
    val themeMode: ThemeMode = ThemeMode.AUTO,
    val dark: Boolean = false,
    val fastFindOpen: Boolean = false,
    val settingsOpen: Boolean = false,
    val scheduleTargetId: String? = null,
    val scheduleForDeadline: Boolean = false,
    val quickAddMenuOpen: Boolean = false,
    val composerOpen: Boolean = false,
    val composerWhen: When? = null,
    val composerHeadingId: String? = null,
    /**
     * 行内输入框的"请求聚焦 + 滚到可见"令牌:每次 [OrdoViewModel.openComposer] 都自增一次。
     *
     * 关键是**已打开时也自增** —— 右下角加号在输入框已经开着的情况下再点,过去是彻底的空操作;
     * 现在令牌变化会让输入行重新抢键盘焦点并把列表滚到它那里(需求:点了必有可见反馈)。
     */
    val composerFocusToken: Long = 0L,
    /** 已发生的聚焦请求次数(与 [composerFocusToken] 同步自增,供测试断言"焦点目标被请求") */
    val composerFocusRequests: Int = 0,
    /** 输入框**真的**拿到了键盘焦点(界面在 onFocusChanged 里回报;关闭时复位) */
    val composerFocused: Boolean = false,
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

    /**
     * 当前路由若是项目,给出项目卡片的可测状态(能不能完成 / 为什么不能)。
     *
     * 取值只来自 [projectCards](由视图模型从**共享核心的计数与快照**填好):
     * 端上不重新实现契约 §2.2 的完成规则,避免"显示与行为不一致"再次出现。
     */
    val projectCard: ProjectCardState?
        get() = (route as? OrdoRoute.Project)?.let { projectCards[it.id] }

    val headerTitle: String get() = route.title
    val totalCount: Int get() = flatTodos.size
}
