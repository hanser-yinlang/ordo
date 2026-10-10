package com.ordo.android.vm

import com.ordo.android.auth.AuthMethod
import com.ordo.android.auth.AuthMode
import com.ordo.android.auth.AuthStage
import com.ordo.android.auth.CodeSendState
import com.ordo.android.auth.EmailCodeRules
import com.ordo.android.sync.RefreshUiState
import com.ordo.android.sync.SyncState
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

/**
 * 登录门禁的界面状态（契约 §7.6.4 / §7.6.5 · UI §5.1）。
 *
 * [errorNonce] 每失败一次 +1：界面据此**重放一次抖动动画**（同样的错误文案也要有反馈）。
 * 验证码登录与口令登录**同级**：[loginMethod] 切换，判定规则全部复用
 * [EmailCodeRules]（纯逻辑，可单测）。
 */
data class AuthUi(
    val stage: AuthStage = AuthStage.LOADING,
    val mode: AuthMode = AuthMode.LOGIN,
    /** 登录方式：口令 / 邮箱验证码（§7.6.5） */
    val loginMethod: AuthMethod = AuthMethod.PASSWORD,
    val email: String = "",
    val password: String = "",
    val passwordVisible: Boolean = false,
    /** 验证码（只保留数字，最多 6 位） */
    val code: String = "",
    /** 正在请求验证码：「获取验证码」转圈并禁用输入 */
    val codeRequesting: Boolean = false,
    /** 再次获取验证码的剩余秒数（取服务端 retryAfter，默认 60）；>0 时按钮置灰 */
    val codeCooldownSeconds: Int = 0,
    /** 开发模式服务端回显的 devCode 已自动填入（仅提示，界面不依赖，契约 §7.6.5） */
    val devCodeFilled: Boolean = false,
    /** 提交中：主按钮禁用 + 16dp 转圈；输入框与游客按钮一并禁用 */
    val submitting: Boolean = false,
    /** 错误文案（位于主按钮下方固定 20dp 高的错误区） */
    val error: String? = null,
    val errorNonce: Int = 0,
    /** 当前账号展示名：正式账号 = 邮箱，游客 = 「游客」 */
    val displayName: String = "",
    val isGuest: Boolean = false,
    val userId: String? = null,
) {
    /** 是否已进入主界面 */
    val loggedIn: Boolean get() = stage == AuthStage.MAIN

    /**
     * 主按钮是否可点。
     *
     * 口令模式沿用原语义（空表单也允许点，点后给本地校验文案）；
     * 验证码模式必须邮箱合法 + 满 6 位码（也让「满 6 位自动提交」有统一判据）。
     */
    val canSubmit: Boolean
        get() = when {
            stage != AuthStage.LOGIN || submitting || codeRequesting -> false
            loginMethod == AuthMethod.EMAIL_CODE -> EmailCodeRules.submitBlocker(email, code) == null
            else -> true
        }

    /** 「获取验证码」按钮状态（倒计时/请求中/邮箱非法都置灰） */
    val codeSendState: CodeSendState
        get() = EmailCodeRules.sendState(email, codeCooldownSeconds, codeRequesting, submitting)

    /** 「获取验证码」是否可点 */
    val canRequestCode: Boolean
        get() = stage == AuthStage.LOGIN &&
            loginMethod == AuthMethod.EMAIL_CODE &&
            codeSendState == CodeSendState.IDLE
}

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
    val syncState: SyncState = SyncState.IDLE,
    /** 登录门禁：LOADING → LOGIN / MAIN（契约 §7.6.4） */
    val auth: AuthUi = AuthUi(),
    /** 状态栏刷新控件（UI §5.3）：同步中连续旋转、成功 1.4s 后回常态、失败常驻 */
    val refresh: RefreshUiState = RefreshUiState(),
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
    /** 已进入主界面（登录门禁通过）；设置页与侧栏据此展示账号区 */
    val loggedIn: Boolean get() = auth.loggedIn

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
