package com.ordo.android.vm

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.ordo.android.R
import com.ordo.android.auth.SessionPlan
import com.ordo.android.auth.SilentSessionRules
import com.ordo.android.data.SeedData
import com.ordo.android.data.whenValue
import com.ordo.android.di.ServiceLocator
import com.ordo.android.net.OrdoAuthApi
import com.ordo.android.sync.RefreshController
import com.ordo.android.sync.RefreshPhase
import com.ordo.android.sync.SyncState
import com.ordo.android.ui.common.OrdoFormatter
import com.ordo.android.ui.theme.ThemeMode
import com.ordo.core.model.CalendarEvent
import com.ordo.core.model.ChecklistItem
import com.ordo.core.model.OrdoSnapshot
import com.ordo.core.model.RepeatFreq
import com.ordo.core.model.RepeatMode
import com.ordo.core.model.RepeatRule
import com.ordo.core.model.Status
import com.ordo.core.model.Todo
import com.ordo.core.store.TodoOptions
import com.ordo.core.model.When
import com.ordo.core.nlp.NaturalDateParser
import com.ordo.core.query.ListQuery
import com.ordo.core.query.ListSection
import com.ordo.core.query.SectionKind
import com.ordo.core.query.SidebarCounts
import com.ordo.core.store.OrdoEngine
import com.ordo.core.sync.OrdoSession
import com.ordo.core.util.OrdoDate
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * 唯一的 UI 状态持有者。
 *
 * 单向数据流：UI → ViewModel → OrdoEngine（shared:core）→ subscribe 回调 → StateFlow → UI。
 * 所有写操作都必须经过 [OrdoEngine]，ViewModel 不直接改数据（契约 §7.1 本地优先）。
 */
class OrdoViewModel : ViewModel() {

    /**
     * 当前账号的引擎。**不能**在字段初始化时读成 val：
     * 数据目录按账号隔离（契约 §7.6.3），登录/退出都会重新绑定，必须每次取当前账号的那一份。
     */
    private val engine: OrdoEngine get() = ServiceLocator.engine
    private val settings = ServiceLocator.settings
    private val tokens = ServiceLocator.tokens
    private val sessions = ServiceLocator.sessions
    private val scheduler = ServiceLocator.scheduler
    private val authApi: OrdoAuthApi = ServiceLocator.authApi
    private val context: Context = ServiceLocator.appContext
    private val formatter = OrdoFormatter(context)

    /** 刷新控件状态机（UI §5.3）：状态栏刷新键与下拉刷新共用同一份状态 */
    private val refreshController = RefreshController()

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    private var unsubscribe: (() -> Unit)? = null
    private var toastJob: Job? = null
    private var settleJob: Job? = null

    /** 会话修复（网络抖动 vs 服务端否认）正在判定中，避免并发重复请求 */
    private var sessionRepairJob: Job? = null

    /** 区域折叠是设备本地 UI 偏好（契约 §2.3 的同类本地状态），由界面层持有 */
    private val collapsedAreas = mutableSetOf<String>()

    init {
        viewModelScope.launch {
            settings.themeMode.collect { mode -> _state.update { it.copy(themeMode = mode) } }
        }
        viewModelScope.launch {
            scheduler.state.collect { value ->
                _state.update { it.copy(syncState = value) }
                applySyncState(value)
            }
        }
        viewModelScope.launch {
            refreshController.state.collect { value -> _state.update { it.copy(refresh = value) } }
        }
        // 静默建号 / 续期成功后：ServiceLocator 已起实时通道，这里重新挂引擎并补一次同步
        viewModelScope.launch {
            ServiceLocator.session.collect { session -> if (session != null) onSessionReady() }
        }
        viewModelScope.launch {
            _state.update {
                it.copy(
                    eventList = runCatching { SeedData.events() }.getOrDefault(emptyList()),
                    loading = false,
                )
            }
            startSilentSession()
        }
    }

    override fun onCleared() {
        unsubscribe?.invoke()
        super.onCleared()
    }

    /* ======================= 静默会话（v1.3：无登录界面） ======================= */

    /**
     * 启动流程（产品决策 v1.3，取代旧的登录门禁）：
     * ```
     * 读 session（本地数据目录已由 ServiceLocator 按"钉住的本机 id"挂好，与会话无关）
     *   ├─ 有且未过期            → 直接进主界面（后台静默 refresh）
     *   ├─ 有但 accessToken 过期 → 先 refresh；成功用新会话
     *   │                          失败且是 401（服务端否认）→ 静默重建匿名会话
     *   │                          失败但不是 401（网络不可达）→ 继续离线用旧会话
     *   └─ 无                    → 直接进主界面（离线可用），后台静默建匿名账号
     * ```
     * 三个分支都**直接进主界面**：不再有登录页，网络不可达也不阻塞启动。
     */
    private fun startSilentSession() {
        val session = runCatching { sessions.load() }.getOrNull()
        when (val plan = SilentSessionRules.plan(session, System.currentTimeMillis())) {
            is SessionPlan.UseExisting ->
                enterMain(sessionReady = true, silentRefresh = plan.silentRefresh)

            is SessionPlan.RefreshFirst -> viewModelScope.launch {
                val outcome = runCatching { authApi.refresh(plan.session.refreshToken) }
                when {
                    // 续期成功：AuthApi 已把新会话写进引导库（本地工作区不变，契约 §7.6.6）
                    outcome.isSuccess -> enterMain(sessionReady = true, silentRefresh = false)

                    // 服务端否认了旧会话：静默建匿名账号（本地目录不动，用户数据不"消失"）
                    SilentSessionRules.isSessionDenied(SilentSessionRules.errorCodeOf(outcome.exceptionOrNull())) -> {
                        enterMain(sessionReady = false, silentRefresh = false)
                        ServiceLocator.ensureAnonymousSession(replaceExisting = true)
                    }

                    // 网络不可达 / 5xx：按「暂时同步不上」处理，离线继续用旧会话
                    else -> enterMain(sessionReady = false, silentRefresh = false)
                }
            }

            SessionPlan.CreateAnonymous -> {
                // 还没有账号：本机工作区立刻可用（离线也能写）；建号成功后 ServiceLocator 通知界面
                enterMain(sessionReady = false, silentRefresh = false)
                ServiceLocator.ensureAnonymousSession()
            }
        }
    }

    /**
     * 进入主界面（唯一入口）：订阅引擎 → 渲染本地数据 → 起实时通道 → 静默同步。
     *
     * 本地数据目录由 ServiceLocator 在启动时按**钉住的本机 id**（契约 §7.6.6）挂好，
     * 这里**不切换任何目录**：会话重建（静默建号 / 401）只换令牌，用户数据原地不动。
     *
     * @param sessionReady 是否已拿到可用会话（否则只渲染本地数据、不发请求，等静默建号）
     */
    private fun enterMain(sessionReady: Boolean, silentRefresh: Boolean) {
        unsubscribe?.invoke()
        unsubscribe = runCatching { engine.subscribe { snapshot -> rebuild(snapshot) } }.getOrNull()

        _state.update { it.copy(loading = false) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
        if (!sessionReady) return

        ServiceLocator.startRealtime()
        if (silentRefresh) {
            // 后台静默 refresh：失败也不打断使用（accessToken 仍有效，401 时由网络层兜底）
            viewModelScope.launch { runCatching { authApi.refreshSaved() } }
        }
        viewModelScope.launch { runCatching { scheduler.syncOnce() } }
    }

    /**
     * 会话就绪（静默建号成功 / 续期成功）后重新挂引擎并补一次同步。
     * ServiceLocator 已完成实时通道启动；本地目录不变，所以这里只做界面侧的重新订阅。
     */
    private fun onSessionReady() {
        _state.update { it.copy(loading = false) }
        enterMain(sessionReady = true, silentRefresh = false)
    }

    private fun deviceName(): String =
        runCatching { "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim() }
            .getOrDefault("Android 设备")

    /* ============================== 导航 ============================== */

    fun navigate(routeKey: String) {
        _state.update {
            it.copy(
                routeKey = routeKey,
                selectedTodoId = null,
                detail = null,
                sidebarOpen = false,
                fastFindOpen = false,
                composer = it.composer.closed(),
                scheduleTarget = null,
                searchQuery = if (routeKey == UiState.ROUTE_SEARCH) it.searchQuery else "",
                searchResults = if (routeKey == UiState.ROUTE_SEARCH) it.searchResults else emptyList(),
            )
        }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun openDetail(todoId: String) {
        _state.update { it.copy(selectedTodoId = todoId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun closeDetail() = _state.update { it.copy(selectedTodoId = null, detail = null) }

    fun toggleSidebar(open: Boolean) = _state.update { it.copy(sidebarOpen = open) }

    fun openFastFind() = _state.update { it.copy(fastFindOpen = true) }

    fun closeFastFind() = _state.update { it.copy(fastFindOpen = false, searchQuery = "", searchResults = emptyList()) }

    fun openQuickAddMenu(open: Boolean) = _state.update { it.copy(quickAddMenuOpen = open) }

    /**
     * 快加号单击（UI §5.2）：只保留一个 FAB，按"菜单是否已展开"分两种语义。
     *   菜单未展开 → 打开行内输入行（聚焦 + 弹软键盘）
     *   菜单已展开 → 收起菜单（按钮转回 0°），**不**打开输入行
     */
    fun onQuickAddTap() {
        if (_state.value.quickAddMenuOpen) {
            openQuickAddMenu(false)
        } else {
            openComposer(composerTarget())
        }
    }

    /** 快加号长按 400ms（UI §5.2）：从按钮左上方弹出快捷菜单，按钮旋转 45° */
    fun onQuickAddLongPress() = openQuickAddMenu(true)

    /** 菜单落地目标：当前处于项目/区域视图时把新待办直接放进去 */
    fun composerTarget(): String? = when (val route = _state.value.routeKey) {
        UiState.ROUTE_TODAY -> null
        else -> route.takeIf { it.startsWith(ROUTE_PROJECT_PREFIX) || it.startsWith(ROUTE_AREA_PREFIX) }
    }

    /**
     * 快加号菜单「新建标题」：标题必须属于某个项目（契约 §2.3），
     * 因此只在项目视图里创建；其它视图给出明确提示，而不是偷偷建到别的项目里。
     */
    fun createHeadingFromQuickAdd(name: String) {
        val projectId = _state.value.routeKey
            .takeIf { it.startsWith(ROUTE_PROJECT_PREFIX) }
            ?.removePrefix(ROUTE_PROJECT_PREFIX)
        if (projectId.isNullOrBlank()) {
            openQuickAddMenu(false)
            showToast(context.getString(R.string.quickadd_heading_need_project))
            return
        }
        val value = name.trim().ifEmpty { context.getString(R.string.heading_default_name) }
        createHeading(projectId, value)
        openQuickAddMenu(false)
    }

    /**
     * 长按拖拽落库（UI §5.4）：只重排**同一分组内**的待办。
     * 位置未变时界面层不会调用本方法（契约要求"位置未变则不写库"）。
     */
    fun reorderSection(orderedIds: List<String>) {
        if (orderedIds.size < 2) return
        runCatching { engine.reorderTodos(orderedIds) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    /* ============================ 状态重建 ============================ */

    private fun rebuild(snapshot: OrdoSnapshot?) {
        if (snapshot == null) return
        val route = _state.value.routeKey
        val sections = runCatching { buildSections(route, snapshot) }.getOrDefault(emptyList())
        val visible = sections.flatMap { it.todos }

        _state.update { current ->
            current.copy(
                loading = false,
                title = titleFor(route, snapshot),
                subtitle = subtitleFor(route, sections, snapshot),
                sections = sections,
                agenda = if (route == UiState.ROUTE_TODAY) buildAgenda() else emptyList(),
                counts = runCatching { engine.counts().toUi() }.getOrDefault(current.counts),
                areas = buildAreaNodes(snapshot),
                tags = buildTagNodes(snapshot),
                projectHeader = buildProjectHeader(route, snapshot),
                detail = current.selectedTodoId?.let { id -> buildDetail(id, snapshot) },
                totalCount = visible.size,
                doneCount = visible.count { it.status != Status.OPEN },
            )
        }
    }

    private fun buildSections(route: String, snapshot: OrdoSnapshot): List<SectionUi> = when {
        route == UiState.ROUTE_SEARCH || route == UiState.ROUTE_SETTINGS -> emptyList()

        route.startsWith(ROUTE_PROJECT_PREFIX) -> {
            val projectId = route.removePrefix(ROUTE_PROJECT_PREFIX)
            val collapsed = engine.headingsOf(projectId).associate { it.id to it.collapsed }
            engine.sections(ListQuery.ProjectScope(projectId)).map { section ->
                section.toUi(snapshot, collapsed[section.headingId] ?: false)
            }
        }

        route.startsWith(ROUTE_AREA_PREFIX) -> {
            val areaId = route.removePrefix(ROUTE_AREA_PREFIX)
            groupByProject(engine.list(ListQuery.AreaScope(areaId)), snapshot)
        }

        route.startsWith(ROUTE_TAG_PREFIX) -> {
            val name = URLDecoder.decode(route.removePrefix(ROUTE_TAG_PREFIX), "UTF-8")
            val todos = engine.list(ListQuery.TagScope(name, includeCompleted = _state.value.showCompleted))
            listOf(
                SectionUi(
                    title = null,
                    kind = SectionKind.PLAIN,
                    todos = todos.map { it.toRow() },
                ),
            )
        }

        else -> engine.sections(queryFor(route)).map { section -> section.toUi(snapshot, false) }
    }

    private fun queryFor(route: String): ListQuery = when (route) {
        UiState.ROUTE_INBOX -> ListQuery.Inbox
        UiState.ROUTE_UPCOMING -> ListQuery.Upcoming
        UiState.ROUTE_ANYTIME -> ListQuery.Anytime
        UiState.ROUTE_SOMEDAY -> ListQuery.Someday
        UiState.ROUTE_LOGBOOK -> ListQuery.Logbook
        else -> ListQuery.Today
    }

    private fun groupByProject(todos: List<Todo>, snapshot: OrdoSnapshot): List<SectionUi> =
        todos.groupBy { it.projectId }
            .map { (projectId, list) ->
                SectionUi(
                    title = projectId?.let { id -> snapshot.projects.firstOrNull { it.id == id }?.name }
                        ?: context.getString(R.string.detail_no_project),
                    kind = SectionKind.PLAIN,
                    todos = list.map { it.toRow() },
                )
            }
            .sortedBy { it.title }

    private fun ListSection.toUi(snapshot: OrdoSnapshot, collapsed: Boolean): SectionUi = SectionUi(
        title = title,
        kind = kind,
        todos = todos.map { it.toRow() },
        headingId = headingId,
        collapsed = collapsed,
    )

    private fun Todo.toRow(): TodoRowUi = TodoRowUi(
        id = id,
        title = title,
        notePreview = formatter.plainPreview(note).take(90),
        status = status,
        whenValue = whenValue,
        whenLabel = when (whenValue) {
            When.DATE, When.TODAY, When.EVENING -> formatter.whenLabel(whenValue, date)
            else -> null
        },
        reminderLabel = formatter.reminderLabel(reminder),
        reminderPast = formatter.reminderPast(reminder) && status == Status.OPEN,
        deadlineLabel = formatter.shortDate(deadline),
        deadlineOverdue = formatter.deadlineOverdue(deadline) && status == Status.OPEN,
        tags = tags,
        checklistDone = checklistDone,
        checklistTotal = checklist.size,
        hasNote = note.isNotBlank(),
        repeat = repeat != null,
        completedAtLabel = if (status != Status.OPEN) formatter.completedLabel(completedAt) else null,
    )

    private fun buildAgenda(): List<AgendaItemUi> {
        val now = OrdoDate.nowHHmm()
        return _state.value.eventList
            .filter { OrdoDate.datePartOf(it.start) == OrdoDate.todayISO() }
            .sortedBy { it.start }
            .map { event ->
                AgendaItemUi(
                    id = event.id,
                    time = OrdoDate.timePartOf(event.start) ?: event.start,
                    title = event.title,
                    calendar = event.calendar,
                    past = (OrdoDate.timePartOf(event.start) ?: "") < now,
                )
            }
    }

    private fun buildAreaNodes(snapshot: OrdoSnapshot): List<AreaNodeUi> {
        val counts = runCatching { engine.counts() }.getOrNull()
        return snapshot.areas
            .filter { !it.deleted && !it.archived }
            .sortedBy { it.order }
            .map { area ->
                val projects = snapshot.projects
                    .filter { it.areaId == area.id && !it.deleted && it.status == Status.OPEN }
                    .sortedBy { it.order }
                    .map { project ->
                        ProjectNodeUi(
                            id = project.id,
                            name = project.name,
                            areaId = project.areaId,
                            progress = counts?.projectProgress?.get(project.id)
                                ?: engine.projectProgress(project.id),
                            openCount = counts?.projects?.get(project.id)
                                ?: snapshot.todos.count { it.projectId == project.id && it.isOpen && !it.deleted },
                        )
                    }
                AreaNodeUi(
                    id = area.id,
                    name = area.name,
                    color = area.color,
                    collapsed = collapsedAreas.contains(area.id),
                    projects = projects,
                )
            }
    }

    private fun buildTagNodes(snapshot: OrdoSnapshot): List<TagNodeUi> {
        val counts = runCatching { engine.counts() }.getOrNull()
        return engine.tags().map { tag ->
            TagNodeUi(
                name = tag.name,
                color = tag.color,
                count = counts?.tags?.get(tag.name)
                    ?: snapshot.todos.count { !it.deleted && it.isOpen && it.tags.contains(tag.name) },
            )
        }
    }

    private fun buildProjectHeader(route: String, snapshot: OrdoSnapshot): ProjectHeaderUi? {
        if (!route.startsWith(ROUTE_PROJECT_PREFIX)) return null
        val project = engine.project(route.removePrefix(ROUTE_PROJECT_PREFIX)) ?: return null
        val children = snapshot.todos.filter { it.projectId == project.id && !it.deleted }
        return ProjectHeaderUi(
            id = project.id,
            name = project.name,
            note = project.note,
            areaName = project.areaId?.let { id -> snapshot.areas.firstOrNull { it.id == id }?.name },
            progress = engine.projectProgress(project.id),
            doneCount = children.count { it.status != Status.OPEN },
            openCount = children.count { it.isOpen },
            headings = engine.headingsOf(project.id).map {
                HeadingUi(id = it.id, name = it.name, collapsed = it.collapsed, archived = it.archived)
            },
            status = project.status,
        )
    }

    private fun buildDetail(todoId: String, snapshot: OrdoSnapshot): DetailUi? {
        val todo = engine.todo(todoId) ?: return null
        return DetailUi(
            id = todo.id,
            title = todo.title,
            note = todo.note,
            whenValue = todo.whenValue,
            whenLabel = formatter.whenLabel(todo.whenValue, todo.date),
            deadlineLabel = formatter.shortDate(todo.deadline),
            deadlineOverdue = formatter.deadlineOverdue(todo.deadline) && todo.isOpen,
            reminderLabel = formatter.reminderLabel(todo.reminder),
            reminderRaw = todo.reminder,
            reminderPast = formatter.reminderPast(todo.reminder) && todo.isOpen,
            repeatLabel = formatter.repeatLabel(todo.repeat?.freq, todo.repeat?.mode),
            repeatFreq = todo.repeat?.freq,
            repeatMode = todo.repeat?.mode,
            projectId = todo.projectId,
            projectName = todo.projectId?.let { id -> snapshot.projects.firstOrNull { it.id == id }?.name },
            tags = todo.tags,
            checklist = todo.checklist.map { ChecklistItemUi(it.id, it.title, it.done) },
            status = todo.status,
        )
    }

    private fun titleFor(route: String, snapshot: OrdoSnapshot): String = when {
        route == UiState.ROUTE_INBOX -> context.getString(R.string.nav_inbox)
        route == UiState.ROUTE_TODAY -> context.getString(R.string.nav_today)
        route == UiState.ROUTE_UPCOMING -> context.getString(R.string.nav_upcoming)
        route == UiState.ROUTE_ANYTIME -> context.getString(R.string.nav_anytime)
        route == UiState.ROUTE_SOMEDAY -> context.getString(R.string.nav_someday)
        route == UiState.ROUTE_LOGBOOK -> context.getString(R.string.nav_logbook)
        route == UiState.ROUTE_SEARCH -> context.getString(R.string.common_search)
        route == UiState.ROUTE_SETTINGS -> context.getString(R.string.settings_title)
        route.startsWith(ROUTE_PROJECT_PREFIX) ->
            engine.project(route.removePrefix(ROUTE_PROJECT_PREFIX))?.name
                ?: context.getString(R.string.nav_anytime)
        route.startsWith(ROUTE_AREA_PREFIX) -> snapshot.areas
            .firstOrNull { it.id == route.removePrefix(ROUTE_AREA_PREFIX) }?.name
            ?: context.getString(R.string.nav_section_areas)
        route.startsWith(ROUTE_TAG_PREFIX) -> URLDecoder.decode(route.removePrefix(ROUTE_TAG_PREFIX), "UTF-8")
        else -> context.getString(R.string.app_name)
    }

    private fun subtitleFor(route: String, sections: List<SectionUi>, snapshot: OrdoSnapshot): String {
        val count = sections.sumOf { it.todos.size }
        return when {
            route == UiState.ROUTE_TODAY -> context.getString(R.string.subtitle_today, count)
            route == UiState.ROUTE_UPCOMING -> context.getString(R.string.subtitle_upcoming, count)
            route == UiState.ROUTE_LOGBOOK -> context.getString(R.string.subtitle_logbook, count)
            route.startsWith(ROUTE_PROJECT_PREFIX) -> {
                val projectId = route.removePrefix(ROUTE_PROJECT_PREFIX)
                val open = snapshot.todos.count { it.projectId == projectId && it.isOpen && !it.deleted }
                context.getString(
                    R.string.subtitle_project,
                    (engine.projectProgress(projectId) * 100).toInt(),
                    open,
                )
            }
            else -> context.getString(R.string.subtitle_count, count)
        }
    }

    /* ============================== 写操作 ============================== */

    fun toggleDone(todoId: String) {
        runCatching { engine.toggleDone(todoId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun updateTitle(todoId: String, title: String) {
        val trimmed = title.trim()
        if (trimmed.isEmpty()) {
            deleteTodo(todoId)
            return
        }
        runCatching { engine.setTitle(todoId, trimmed) }
    }

    fun updateNote(todoId: String, note: String) {
        runCatching { engine.setNote(todoId, note) }
    }

    fun setWhen(todoId: String, `when`: When, date: String? = null) {
        runCatching { engine.setWhen(todoId, `when`, date) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun setDeadline(todoId: String, date: String?) {
        runCatching { engine.setDeadline(todoId, date) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun setReminder(todoId: String, reminder: String?) {
        runCatching { engine.setReminder(todoId, reminder) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    /** 提醒：今天/明天 + HH:mm（写入后由引擎按契约 §3 自动对齐 `when`） */
    fun setReminderAt(todoId: String, hourMinute: String, tomorrow: Boolean = false) {
        val normalized = OrdoDate.normalizeTime(hourMinute) ?: hourMinute
        val day = if (tomorrow) OrdoDate.plusDays(OrdoDate.todayISO(), 1) else OrdoDate.todayISO()
        setReminder(todoId, OrdoDate.dateTime(day, normalized))
        showToast(context.getString(R.string.toast_reminder_set, normalized))
    }

    fun clearReminder(todoId: String) {
        setReminder(todoId, null)
        showToast(context.getString(R.string.schedule_reminder_clear))
    }

    fun setRepeat(todoId: String, freq: RepeatFreq?, mode: RepeatMode = RepeatMode.FIXED) {
        runCatching { engine.setRepeat(todoId, freq?.let { RepeatRule(freq = it, interval = 1, mode = mode) }) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun addTag(todoId: String, tag: String) {
        val value = tag.trim().removePrefix("#")
        if (value.isEmpty()) return
        runCatching { engine.ensureTag(value) }
        runCatching { engine.addTag(todoId, value) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun removeTag(todoId: String, tag: String) {
        runCatching { engine.removeTag(todoId, tag) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun toggleChecklistItem(todoId: String, itemId: String) {
        runCatching { engine.toggleChecklistItem(todoId, itemId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun addChecklistItem(todoId: String, title: String) {
        val value = title.trim()
        if (value.isEmpty()) return
        runCatching { engine.addChecklistItem(todoId, value) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun deleteTodo(todoId: String) {
        runCatching { engine.deleteTodo(todoId) }
        _state.update { it.copy(selectedTodoId = null, detail = null) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
        showToast(context.getString(R.string.toast_deleted))
    }

    fun duplicateTodo(todoId: String) {
        runCatching { engine.duplicateTodo(todoId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
        showToast(context.getString(R.string.toast_duplicated))
    }

    fun moveTodo(todoId: String, projectId: String?, areaId: String?, headingId: String?) {
        runCatching { engine.moveTodo(todoId, projectId, areaId, headingId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    /**
     * 完成项目（契约 §2.2 v1.1）。
     *
     * 唯一硬约束是「项目下没有未完成的待办」；标题未归档不再阻塞（引擎会自动归档）。
     * 提示文案与实际原因必须一致：拒绝时带上是多少项未完成，且不再提「标题」。
     */
    fun completeProject(projectId: String) {
        val statusBefore = runCatching { engine.project(projectId)?.status }.getOrNull()
        val openCount = runCatching { engine.counts().projects[projectId] ?: 0 }.getOrDefault(0)
        val completed = runCatching { engine.completeProject(projectId) }.getOrDefault(false)
        rebuild(runCatching { engine.snapshot }.getOrNull())
        val outcome = resolveProjectComplete(completed, statusBefore, openCount)
        showToast(context.getString(outcome.messageRes, *outcome.messageArgs()))
    }

    /** 重新打开已完成的项目（卡片在 DONE 时显示「重新打开」而不是「完成项目」） */
    fun reopenProject(projectId: String) {
        runCatching { engine.reopenProject(projectId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
        showToast(context.getString(R.string.toast_project_reopened))
    }

    fun renameProject(projectId: String, name: String) {
        val value = name.trim()
        if (value.isEmpty()) return
        runCatching { engine.renameProject(projectId, value) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun createProject(name: String, areaId: String?) {
        val value = name.trim()
        if (value.isEmpty()) return
        val project = runCatching { engine.createProject(value, areaId) }.getOrNull() ?: return
        showToast(context.getString(R.string.toast_project_created, project.name))
        navigate("$ROUTE_PROJECT_PREFIX${project.id}")
    }

    fun createArea(name: String) {
        val value = name.trim()
        if (value.isEmpty()) return
        runCatching { engine.createArea(value) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
        showToast(context.getString(R.string.toast_area_created, value))
    }

    fun createHeading(projectId: String, name: String) {
        val value = name.trim()
        if (value.isEmpty()) return
        runCatching { engine.createHeading(projectId, value) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun toggleHeadingCollapsed(headingId: String) {
        runCatching { engine.toggleHeadingCollapsed(headingId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun toggleAreaCollapsed(areaId: String) {
        if (!collapsedAreas.add(areaId)) collapsedAreas.remove(areaId)
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun toggleShowCompleted() {
        _state.update { it.copy(showCompleted = !it.showCompleted) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
    }

    fun restore(todoId: String) {
        runCatching { engine.reopen(todoId) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
        showToast(context.getString(R.string.toast_restored))
    }

    /* ============================ 新建（快加） ============================ */

    /**
     * 打开「新建待办」浮层。
     *
     * 已经打开时**不是空操作**：保留已输入的草稿，只递增 `focusRequest`，
     * 界面据此重新聚焦输入框并弹起软键盘（实测缺陷「点加号没反应」的修复点之一）。
     */
    fun openComposer(target: String?) = _state.update {
        it.copy(composer = it.composer.opened(target), quickAddMenuOpen = false)
    }

    fun updateComposerDraft(text: String) = _state.update { it.copy(composer = it.composer.edited(text)) }

    /** 关闭浮层：草稿丢弃；空标题不会留下任何待办 */
    fun closeComposer() = _state.update { it.copy(composer = it.composer.closed()) }

    /** 提交新待办；标题里的日期/时间/标签由 core 的 NLP 解析（契约 §5） */
    fun submitComposer() {
        when (val verdict = _state.value.composer.submission()) {
            ComposerState.Submission.Empty -> closeComposer()

            is ComposerState.Submission.Create -> {
                val target = _state.value.composer.target
                val options = TodoOptions(
                    `when` = when (val route = _state.value.routeKey) {
                        UiState.ROUTE_TODAY -> When.TODAY
                        UiState.ROUTE_SOMEDAY -> When.SOMEDAY
                        UiState.ROUTE_ANYTIME -> When.ANYTIME
                        else -> if (route.startsWith(ROUTE_PROJECT_PREFIX)) When.ANYTIME else null
                    },
                    projectId = target?.takeIf { it.startsWith(ROUTE_PROJECT_PREFIX) }?.removePrefix(ROUTE_PROJECT_PREFIX),
                    areaId = target?.takeIf { it.startsWith(ROUTE_AREA_PREFIX) }?.removePrefix(ROUTE_AREA_PREFIX),
                    headingId = target?.takeIf { it.startsWith(HEADING_PREFIX) }?.removePrefix(HEADING_PREFIX),
                )
                val created = runCatching { engine.createTodo(verdict.title, options) }.getOrNull()
                closeComposer()
                rebuild(runCatching { engine.snapshot }.getOrNull())
                if (created != null) showToast(context.getString(R.string.toast_todo_created, created.title))
            }
        }
    }

    /* ============================ 排期面板 ============================ */

    fun openSchedule(todoId: String, forDeadline: Boolean = false) =
        _state.update { it.copy(scheduleTarget = ScheduleTargetUi(todoId, forDeadline)) }

    fun closeSchedule() = _state.update { it.copy(scheduleTarget = null) }

    fun applySchedule(`when`: When, date: String? = null) {
        val target = _state.value.scheduleTarget ?: return
        if (target.forDeadline) setDeadline(target.todoId, date) else setWhen(target.todoId, `when`, date)
        closeSchedule()
    }

    fun applyScheduleDate(date: String) {
        val target = _state.value.scheduleTarget ?: return
        if (target.forDeadline) setDeadline(target.todoId, date) else setWhen(target.todoId, When.DATE, date)
        closeSchedule()
    }

    fun applyScheduleTonight() {
        val target = _state.value.scheduleTarget ?: return
        setWhen(target.todoId, When.EVENING)
        closeSchedule()
    }

    fun applyScheduleTomorrow() = applyScheduleDate(OrdoDate.plusDays(OrdoDate.todayISO(), 1))

    fun applyScheduleWeekend() {
        val today = OrdoDate.todayISO()
        val offset = (6 - OrdoDate.dayOfWeek(today) + 7) % 7
        applyScheduleDate(OrdoDate.plusDays(today, if (offset == 0) 7 else offset))
    }

    fun applyScheduleSomeday() = applySchedule(When.SOMEDAY)

    fun clearScheduleTarget() {
        val target = _state.value.scheduleTarget ?: return
        if (target.forDeadline) setDeadline(target.todoId, null) else setWhen(target.todoId, When.ANYTIME)
        closeSchedule()
    }

    /** 排期面板里的自然语言输入：交给 core 的 NaturalDateParser（契约 §5） */
    fun applyNaturalLanguage(text: String) {
        val target = _state.value.scheduleTarget ?: return
        val parsed = runCatching { NaturalDateParser.parse(text) }.getOrNull()
        if (parsed == null) {
            closeSchedule()
            return
        }
        if (target.forDeadline) {
            setDeadline(target.todoId, parsed.date)
        } else {
            val `when` = parsed.`when` ?: if (parsed.date != null) When.DATE else When.ANYTIME
            setWhen(target.todoId, `when`, parsed.date)
            parsed.reminder?.let { setReminder(target.todoId, it) }
        }
        parsed.tags.forEach { addTag(target.todoId, it) }
        closeSchedule()
    }

    /* ============================== 快找 ============================== */

    fun onSearchQueryChange(query: String) {
        _state.update { it.copy(searchQuery = query) }
        val keyword = query.trim()
        if (keyword.isEmpty()) {
            _state.update { it.copy(searchResults = emptyList()) }
            return
        }
        val snapshot = runCatching { engine.snapshot }.getOrNull() ?: return
        val lower = keyword.lowercase().removePrefix("#")
        val results = mutableListOf<SearchResultUi>()

        runCatching { engine.list(ListQuery.Search(keyword)) }
            .getOrDefault(emptyList())
            .take(SEARCH_LIMIT)
            .forEach { todo ->
                results += SearchResultUi(
                    id = todo.id,
                    kind = SearchKind.TODO,
                    title = todo.title,
                    subtitle = formatter.plainPreview(todo.note).take(40).takeIf { it.isNotBlank() },
                    route = ROUTE_DETAIL_PREFIX + todo.id,
                )
            }

        snapshot.projects
            .filter { !it.deleted && it.name.lowercase().contains(lower) }
            .take(SEARCH_LIMIT)
            .forEach { project ->
                results += SearchResultUi(
                    id = project.id,
                    kind = SearchKind.PROJECT,
                    title = project.name,
                    subtitle = context.getString(R.string.fastfind_project),
                    route = "$ROUTE_PROJECT_PREFIX${project.id}",
                )
            }

        snapshot.areas
            .filter { !it.deleted && it.name.lowercase().contains(lower) }
            .take(SEARCH_LIMIT)
            .forEach { area ->
                results += SearchResultUi(
                    id = area.id,
                    kind = SearchKind.AREA,
                    title = area.name,
                    subtitle = context.getString(R.string.nav_section_areas),
                    route = "$ROUTE_AREA_PREFIX${area.id}",
                )
            }

        engine.tags()
            .filter { it.name.lowercase().contains(lower) }
            .take(SEARCH_LIMIT)
            .forEach { tag ->
                results += SearchResultUi(
                    id = tag.name,
                    kind = SearchKind.TAG,
                    title = "#${tag.name}",
                    subtitle = context.getString(R.string.nav_section_tags),
                    route = "$ROUTE_TAG_PREFIX${URLEncoder.encode(tag.name, "UTF-8")}",
                )
            }

        _state.update { it.copy(searchResults = results.take(SEARCH_LIMIT * 2)) }
    }

    /* ============================== 设置 ============================== */

    fun setThemeMode(mode: ThemeMode) {
        viewModelScope.launch { settings.setThemeMode(mode) }
    }

    fun cycleTheme() {
        viewModelScope.launch { settings.setThemeMode(_state.value.themeMode.next()) }
    }

    /** 重置为示例数据（core 负责内容） */
    fun resetToSeed() {
        runCatching { engine.seedDemoData(force = true) }
        rebuild(runCatching { engine.snapshot }.getOrNull())
        showToast(context.getString(R.string.toast_reset))
    }

    /* ============================== 同步 · 刷新 ============================== */

    /**
     * 状态栏刷新键（UI §5.3）与下拉刷新共用这一条路径，因此两处表现必然一致。
     * 同步中、或成功后 1.4s 防抖窗口内的点按是空操作。
     */
    fun refresh() {
        if (!tokens.isLoggedIn()) {
            refreshController.onNotLoggedIn()
            return
        }
        if (!refreshController.onClick()) return
        viewModelScope.launch { runCatching { scheduler.syncOnce() } }
    }

    /** 设置页的「立即同步」：走同一条路径，用户同样能看到图标连续旋转 */
    fun syncNow() = refresh()

    /**
     * 同步状态 → 刷新控件（把控制器做成 [SyncScheduler] 状态的**投影**，
     * 于是轮询 / 回前台 / 网络恢复触发的同步同样有转圈反馈）。
     */
    private fun applySyncState(value: SyncState) {
        val control = refreshController.state.value
        when (value) {
            SyncState.SYNCING -> refreshController.requestSync()

            SyncState.IDLE -> when (control.phase) {
                RefreshPhase.SYNCING -> {
                    refreshController.onSyncFinished(true)
                    settleJob?.cancel()
                    settleJob = viewModelScope.launch {
                        delay(RefreshController.SETTLE_MILLIS)
                        refreshController.settle()
                    }
                }
                RefreshPhase.SUCCESS, RefreshPhase.FAILED -> Unit
                RefreshPhase.IDLE -> refreshController.onIdle()
            }

            SyncState.FAILED -> if (control.phase == RefreshPhase.SYNCING) refreshController.onSyncFinished(false)

            SyncState.OFFLINE -> refreshController.onOffline()

            SyncState.NOT_LOGGED_IN -> {
                refreshController.onNotLoggedIn()
                // 没有会话（首启离线）→ 引导任务已在退避重试；
                // 有会话却被判为未登录 → 先确认服务端是否真的否认了令牌（见 repairSessionIfDenied）
                if (tokens.isLoggedIn()) repairSessionIfDenied()
            }
        }
    }

    /**
     * 同步被判为「未登录」时的**静默**修复（绝不弹登录界面，契约 §7.6.6 下也不会换目录）：
     *   ① 令牌其实还能续期（刚才只是网络抖动）→ 直接用新会话补一次同步；
     *   ② 服务端明确否认（401）→ 静默重建匿名会话（本地数据原地不动）；
     *   ③ 网络不可达 → 什么都不做，保持离线可用，等下次重试。
     */
    private fun repairSessionIfDenied() {
        if (sessionRepairJob?.isActive == true) return
        val refreshToken = tokens.refreshToken() ?: return
        sessionRepairJob = viewModelScope.launch {
            val outcome = runCatching { authApi.refresh(refreshToken) }
            when {
                outcome.isSuccess -> enterMain(sessionReady = true, silentRefresh = false)

                SilentSessionRules.isSessionDenied(SilentSessionRules.errorCodeOf(outcome.exceptionOrNull())) ->
                    ServiceLocator.ensureAnonymousSession(replaceExisting = true)

                else -> Unit // 网络问题：保持会话离线，等下次同步重试
            }
        }
    }

    fun onAppForeground() {
        scheduler.onForeground()
        if (!tokens.isLoggedIn()) {
            // 首启离线（还没有匿名会话）：回前台再试一次建号（幂等，正在重试时是空操作）
            ServiceLocator.ensureAnonymousSession()
            return
        }
        ServiceLocator.applicationScope.launch { runCatching { scheduler.syncOnce() } }
    }

    fun onAppBackground() = scheduler.onBackground()

    /* ============================== Toast ============================== */

    fun showToast(message: String) {
        toastJob?.cancel()
        _state.update { it.copy(toast = message) }
        toastJob = viewModelScope.launch {
            delay(TOAST_MILLIS)
            _state.update { it.copy(toast = null) }
        }
    }

    fun dismissToast() {
        toastJob?.cancel()
        _state.update { it.copy(toast = null) }
    }

    companion object {
        const val ROUTE_PROJECT_PREFIX = "project/"
        const val ROUTE_AREA_PREFIX = "area/"
        const val ROUTE_TAG_PREFIX = "tag/"
        const val ROUTE_DETAIL_PREFIX = "detail/"
        const val HEADING_PREFIX = "heading/"
        const val PLATFORM = "android"
        const val TOAST_MILLIS = 2_400L
        const val SEARCH_LIMIT = 12
    }
}

/* -------------------- core SidebarCounts → UI 模型（单点接触） -------------------- */
private fun SidebarCounts.toUi() = SidebarCountsUi(
    inbox = inbox,
    today = today,
    upcoming = upcoming,
    anytime = anytime,
    someday = someday,
    logbook = logbook,
)
