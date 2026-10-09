package com.ordo.desktop.app

import com.ordo.core.model.RepeatRule
import com.ordo.core.model.Status
import com.ordo.core.model.When
import com.ordo.core.query.ListQuery
import com.ordo.core.storage.OrdoStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.store.TodoOptions
import com.ordo.core.util.OrdoDate
import com.ordo.desktop.data.LocalAgenda
import com.ordo.desktop.sync.SyncCoordinator
import com.ordo.desktop.sync.SyncDiagnostics
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Windows 端状态层。
 *
 * 只做三件事:①持有 [OrdoEngine];②把引擎快照折叠成 [UiState];③把界面意图翻译成引擎调用。
 * 业务规则(派生清单、NLP、重复、合并)全部在共享核心里,这里不重复实现。
 */
class OrdoViewModel(
    val engine: OrdoEngine,
    private val storage: OrdoStorage,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main),
    /** 只有本进程的第一个窗口负责写入演示数据(多窗口时新窗口不该重新播种) */
    private val seedDemoData: Boolean = true
) {

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    private var unsubscribe: (() -> Unit)? = null
    private var unsubscribeSync: (() -> Unit)? = null
    private var toastSeq = 0L
    private var syncCoordinator: SyncCoordinator? = null

    init {
        // 首次启动写入演示数据;已有内容时不覆盖(多窗口的后续窗口不参与播种)
        if (seedDemoData) engine.seedDemoData(force = false)
        val mode = runCatching { ThemeMode.valueOf(storage.kvGet(KEY_THEME) ?: ThemeMode.AUTO.name) }
            .getOrDefault(ThemeMode.AUTO)
        val tray = storage.kvGet(KEY_CLOSE_TO_TRAY)?.toBooleanStrictOrNull() ?: true
        val follow = storage.kvGet(KEY_FOLLOW_SELECTION)?.toBooleanStrictOrNull() ?: true
        _state.update {
            it.copy(themeMode = mode, dark = resolveDark(mode), closeToTray = tray, followSelection = follow)
        }
        unsubscribe = engine.subscribe { scope.launch { refresh() } }
        refresh()
    }

    // ---------------------------------------------------------------- 派生

    fun refresh() {
        val current = _state.value
        val route = current.route
        val query: ListQuery = if (route is OrdoRoute.Search) ListQuery.Search(route.text) else route.query
        val snapshot = engine.snapshot
        // 项目卡片状态:openCount 直接取共享核心的计数(=status==OPEN 的待办数),totalCount 取快照口径。
        // 端上不自己判断契约 §2.2 的完成规则,所以"按钮能不能点""提示说什么""核心会不会答应"永远同源。
        val projectCards = snapshot.projects
            .filter { project -> !project.deleted }
            .associate { project ->
                val live = snapshot.todos.filter { todo -> !todo.deleted && todo.projectId == project.id }
                project.id to ProjectCardState(
                    projectId = project.id,
                    openCount = live.count { todo -> todo.status == Status.OPEN },
                    totalCount = live.size
                )
            }
        _state.update {
            it.copy(
                // 派生清单(含「随时 / 某天」的 order 手工排序)完全由共享核心给出,本端不做任何二次排序
                sections = engine.sections(query),
                counts = engine.counts(),
                areas = snapshot.areas.filter { a -> !a.deleted }.sortedBy { a -> a.order },
                projects = snapshot.projects.filter { p -> !p.deleted }.sortedBy { p -> p.order },
                projectCards = projectCards,
                headings = snapshot.headings.filter { h -> !h.deleted },
                tags = engine.tags(),
                agenda = if (route == OrdoRoute.Today) LocalAgenda.eventsFor(storage) else it.agenda
            )
        }
    }

    /** 窗口标题随当前清单变化(§3) */
    fun windowTitle(): String {
        val s = _state.value
        val name = when (val r = s.route) {
            is OrdoRoute.Project -> engine.project(r.id)?.name ?: "项目"
            is OrdoRoute.Area -> engine.area(r.id)?.name ?: "区域"
            is OrdoRoute.Tag -> r.name
            else -> r.title
        }
        return "Ordo · $name"
    }

    // ---------------------------------------------------------------- 导航

    fun navigate(route: OrdoRoute) {
        _state.update { it.copy(route = route, selectedId = null, fastFindOpen = false) }
        refresh()
    }

    fun selectTodo(id: String?) {
        _state.update { it.copy(selectedId = id) }
        publishSelection(id)
    }

    fun toggleDetail(id: String) {
        val next = if (_state.value.selectedId == id) null else id
        _state.update { it.copy(selectedId = next) }
        publishSelection(next)
    }

    // ---------------------------------------------------------------- 多窗口跟随选中

    private var selectionBus: SharedSelection? = null
    private var selectionJob: kotlinx.coroutines.Job? = null

    /** 订阅跨窗口的"跟随选中";设置里关掉时只发布不接收 */
    fun attachSelectionBus(bus: SharedSelection) {
        selectionBus = bus
        selectionJob?.cancel()
        selectionJob = scope.launch {
            bus.current.collect { id ->
                if (id == null || !followSelection()) return@collect
                // 只在自己清单里正好有这条待办时高亮,不改动本窗口的路由
                if (_state.value.flatTodos.any { it.id == id } && _state.value.highlightId != id) {
                    _state.update { it.copy(highlightId = id) }
                }
            }
        }
    }

    private fun publishSelection(id: String?) {
        if (id != null) selectionBus?.publish(id)
    }

    /** 跨窗口跟随选中(设置页开关,默认开) */
    fun followSelection(): Boolean = storage.kvGet(KEY_FOLLOW_SELECTION)?.toBooleanStrictOrNull() ?: true

    fun setFollowSelection(enabled: Boolean) {
        storage.kvSet(KEY_FOLLOW_SELECTION, enabled.toString())
        _state.update { it.copy(followSelection = enabled) }
    }

    fun moveSelection(delta: Int) {
        val todos = _state.value.flatTodos
        if (todos.isEmpty()) return
        val currentId = _state.value.highlightId ?: _state.value.selectedId
        val index = todos.indexOfFirst { it.id == currentId }
        val next = when {
            index < 0 -> if (delta > 0) 0 else todos.lastIndex
            else -> (index + delta).coerceIn(0, todos.lastIndex)
        }
        _state.update { it.copy(highlightId = todos[next].id) }
    }

    /** Enter:打开(或收起)高亮行的详情 */
    fun openHighlighted() {
        val id = _state.value.highlightId ?: _state.value.selectedId ?: return
        toggleDetail(id)
    }

    /** Space:切换高亮行完成状态 */
    fun toggleHighlighted() {
        val id = _state.value.highlightId ?: _state.value.selectedId ?: return
        engine.toggleDone(id)
    }

    /** Delete:删除高亮行 */
    fun deleteHighlighted() {
        val id = _state.value.highlightId ?: _state.value.selectedId ?: return
        deleteTodo(id)
    }

    fun openFastFind() = _state.update { it.copy(fastFindOpen = true) }

    fun closeFastFind() = _state.update { it.copy(fastFindOpen = false) }

    fun openSettings() = _state.update { it.copy(settingsOpen = true) }

    fun closeSettings() = _state.update { it.copy(settingsOpen = false) }

    fun openSchedule(todoId: String, forDeadline: Boolean = false) =
        _state.update { it.copy(scheduleTargetId = todoId, scheduleForDeadline = forDeadline, selectedId = todoId) }

    fun openDeadlinePicker(todoId: String) = openSchedule(todoId, forDeadline = true)

    fun closeSchedule() = _state.update { it.copy(scheduleTargetId = null, scheduleForDeadline = false) }

    fun setQuickAddMenu(open: Boolean) = _state.update { it.copy(quickAddMenuOpen = open) }

    /**
     * 打开行内输入框(Ctrl+N / 标题栏加号 / 分组加号 / 右下角快加号都走这里)。
     *
     * **每次调用都自增 [UiState.composerFocusToken]**,包括"输入框已经开着"的情况:
     * 列表侧观察到令牌变化就重新请求键盘焦点并把列表滚到输入行 ——
     * 这正是"右下角加号点了没反应"的修复点(以前已打开时是彻底的空操作)。
     */
    fun openComposer(`when`: When? = null, headingId: String? = null) =
        _state.update {
            it.copy(
                composerOpen = true,
                composerWhen = `when`,
                composerHeadingId = headingId,
                quickAddMenuOpen = false,
                composerFocusToken = it.composerFocusToken + 1L,
                composerFocusRequests = it.composerFocusRequests + 1
            )
        }

    /**
     * 界面侧回报输入框的焦点实况(与 [UiState.composerFocusRequests] 区分:
     * 那里是"请求了",这里是"落地了",便于测试与自检分辨是哪一环断了)。
     */
    fun notifyComposerFocused(focused: Boolean) =
        _state.update { if (it.composerFocused == focused) it else it.copy(composerFocused = focused) }

    fun closeComposer() =
        _state.update { it.copy(composerOpen = false, composerWhen = null, composerHeadingId = null, composerFocused = false) }

    /** Esc:由内到外依次关闭浮层 → 详情;拖拽中优先取消拖拽(04-UI规范 §6) */
    fun escape() {
        val s = _state.value
        when {
            s.confirm != null -> _state.update { it.copy(confirm = null) }
            s.dragActive -> _state.update { it.copy(dragCancelToken = it.dragCancelToken + 1L) }
            s.settingsOpen -> _state.update { it.copy(settingsOpen = false) }
            s.fastFindOpen -> _state.update { it.copy(fastFindOpen = false) }
            s.quickAddMenuOpen -> _state.update { it.copy(quickAddMenuOpen = false) }
            s.composerOpen -> _state.update { it.copy(composerOpen = false) }
            s.scheduleTargetId != null -> _state.update { it.copy(scheduleTargetId = null) }
            s.selectedId != null -> _state.update { it.copy(selectedId = null) }
        }
    }

    /** 列表侧同步拖拽状态(拖动中 Esc 语义不同) */
    fun setDragActive(active: Boolean) = _state.update { it.copy(dragActive = active) }

    // ---------------------------------------------------------------- 破坏性操作二次确认

    fun requestDeleteProject(id: String, name: String) =
        _state.update { it.copy(confirm = ConfirmRequest(ConfirmKind.PROJECT, id, name)) }

    fun requestDeleteArea(id: String, name: String) =
        _state.update { it.copy(confirm = ConfirmRequest(ConfirmKind.AREA, id, name)) }

    fun requestDeleteHeading(id: String, name: String) =
        _state.update { it.copy(confirm = ConfirmRequest(ConfirmKind.HEADING, id, name)) }

    fun cancelConfirm() = _state.update { it.copy(confirm = null) }

    /** 确认删除:按类型落到引擎(契约 §3 一律软删除 + 墓碑) */
    fun confirmDelete() {
        val request = _state.value.confirm ?: return
        _state.update { it.copy(confirm = null) }
        when (request.kind) {
            ConfirmKind.PROJECT -> deleteProject(request.id)
            ConfirmKind.AREA -> deleteArea(request.id)
            ConfirmKind.HEADING -> deleteHeading(request.id)
        }
    }

    fun toast(text: String) {
        toastSeq += 1
        _state.update { it.copy(toast = ToastMessage(text, toastSeq)) }
    }

    fun dismissToast(id: Long) = _state.update { if (it.toast?.id == id) it.copy(toast = null) else it }

    // ---------------------------------------------------------------- 外观

    fun cycleTheme() {
        val next = when (_state.value.themeMode) {
            ThemeMode.AUTO -> ThemeMode.LIGHT
            ThemeMode.LIGHT -> ThemeMode.DARK
            ThemeMode.DARK -> ThemeMode.AUTO
        }
        setTheme(next)
    }

    fun setTheme(mode: ThemeMode) {
        storage.kvSet(KEY_THEME, mode.name)
        _state.update { it.copy(themeMode = mode, dark = resolveDark(mode)) }
    }

    private fun resolveDark(mode: ThemeMode): Boolean = when (mode) {
        ThemeMode.LIGHT -> false
        ThemeMode.DARK -> true
        ThemeMode.AUTO -> com.ordo.desktop.system.WindowsTheme.isDark()
    }

    // ---------------------------------------------------------------- 待办写操作

    fun createTodo(raw: String, opts: TodoOptions = TodoOptions()): String? {
        val title = raw.trim()
        if (title.isEmpty() && opts.tags.isEmpty()) return null
        val todo = engine.createTodo(title, opts)
        toast("已加入「${routeNameFor(todo.`when`)}」")
        return todo.id
    }

    private fun routeNameFor(`when`: When): String = when (`when`) {
        When.INBOX -> "收件箱"
        When.TODAY, When.EVENING -> "今天"
        When.ANYTIME -> "随时"
        When.SOMEDAY -> "某天"
        When.DATE -> "计划"
    }

    /** 完成(带 §5 动效的时序由界面驱动,这里只落库) */
    fun toggleDone(id: String) = engine.toggleDone(id)

    fun reopen(id: String) = engine.reopen(id)

    fun deleteTodo(id: String) {
        engine.deleteTodo(id)
        _state.update { it.copy(selectedId = if (it.selectedId == id) null else it.selectedId) }
        toast("已删除")
    }

    fun duplicateTodo(id: String) {
        engine.duplicateTodo(id)
        toast("已复制")
    }

    fun setTitle(id: String, title: String) {
        // 标题清空 = 删除(契约 §3)
        if (title.isBlank()) deleteTodo(id) else engine.setTitle(id, title.trim())
    }

    fun setNote(id: String, note: String) = engine.setNote(id, note)

    fun setWhen(id: String, `when`: When, date: String? = null) = engine.setWhen(id, `when`, date)

    fun setDeadline(id: String, date: String?) = engine.setDeadline(id, date)

    fun setReminder(id: String, reminder: String?) = engine.setReminder(id, reminder)

    fun setRepeat(id: String, repeat: RepeatRule?) = engine.setRepeat(id, repeat)

    fun addTag(id: String, tag: String) {
        engine.addTag(id, tag)
        toast("已加标签 #${tag.trim().removePrefix("#")}")
    }

    fun removeTag(id: String, tag: String) = engine.removeTag(id, tag)

    fun addChecklistItem(id: String, title: String) = engine.addChecklistItem(id, title)

    fun setChecklistItemTitle(todoId: String, itemId: String, title: String) =
        engine.setChecklistItemTitle(todoId, itemId, title)

    fun toggleChecklistItem(todoId: String, itemId: String) = engine.toggleChecklistItem(todoId, itemId)

    fun removeChecklistItem(todoId: String, itemId: String) = engine.removeChecklistItem(todoId, itemId)

    fun moveTodo(id: String, projectId: String?, areaId: String?, headingId: String? = null) =
        engine.moveTodo(id, projectId, areaId, headingId)

    fun reorder(ids: List<String>) = engine.reorderTodos(ids)

    // ---------------------------------------------------------------- 项目 / 标题 / 区域

    fun createProject(name: String, areaId: String? = null): String? {
        val clean = name.trim()
        if (clean.isEmpty()) return null
        val project = engine.createProject(clean, areaId)
        toast("已新建项目「$clean」")
        return project.id
    }

    fun renameProject(id: String, name: String) {
        if (name.isBlank()) return
        engine.renameProject(id, name.trim())
    }

    fun setProjectNote(id: String, note: String) = engine.setProjectNote(id, note)

    /**
     * 完成项目(契约 §2.2 v1.1:唯一硬约束是"该项目下所有 todo 都已结束")。
     *
     * 失败时**唯一**可能的原因是还有未完成的待办,所以提示文案只谈待办并带上真实条数;
     * heading 不再阻塞完成(核心会在完成时自动归档),文案里也就不该再出现"标题"
     * —— 之前那句「还有未完成的待办或标题」正是用户"显示 0 项未完成却完不成"困惑的来源之一。
     */
    fun completeProject(id: String): Boolean {
        // 文案基于"点下去之前"的真实原因;引擎同步广播后 _state 已是新状态,不能再拿来算旧原因
        val before = _state.value.projectCards[id]
        val ok = engine.completeProject(id)
        toast(if (ok) "项目已完成" else before?.resultMessage(false) ?: "还有未完成的待办")
        return ok
    }

    /** 该项目下仍未结束的待办数(与卡片文案、按钮可用性同源,供测试与自检使用) */
    fun openTodoCount(projectId: String): Int = engine.snapshot.todos.count { todo ->
        !todo.deleted && todo.projectId == projectId && todo.status == Status.OPEN
    }

    fun reopenProject(id: String) = engine.reopenProject(id)

    fun deleteProject(id: String) {
        engine.deleteProject(id)
        toast("已删除项目")
    }

    fun createHeading(projectId: String, name: String) {
        if (name.isBlank()) return
        engine.createHeading(projectId, name.trim())
    }

    fun renameHeading(id: String, name: String) {
        if (name.isBlank()) return
        engine.renameHeading(id, name.trim())
    }

    fun toggleHeadingCollapsed(id: String) = engine.toggleHeadingCollapsed(id)

    fun archiveHeading(id: String) {
        val ok = engine.archiveHeading(id)
        toast(if (ok) "标题已归档" else "该标题下还有未完成的待办")
    }

    fun deleteHeading(id: String) {
        engine.deleteHeading(id)
        toast("已删除标题")
    }

    fun createArea(name: String) {
        if (name.isBlank()) return
        engine.createArea(name.trim())
        toast("已新建区域「${name.trim()}」")
    }

    fun renameArea(id: String, name: String) {
        if (name.isBlank()) return
        engine.renameArea(id, name.trim())
    }

    fun deleteArea(id: String) {
        engine.deleteArea(id)
        toast("已删除区域")
    }

    // ---------------------------------------------------------------- 同步

    fun attachSync(coordinator: SyncCoordinator) {
        syncCoordinator = coordinator
        // 多窗口:每个窗口各订阅一份,由 SyncCoordinator 广播;dispose 时退订
        val listener: (com.ordo.core.sync.SyncResult) -> Unit = { result ->
            scope.launch {
                _state.update {
                    it.copy(
                        syncStatus = if (result.ok) SyncStatus.SYNCED else SyncStatus.OFFLINE,
                        syncDetail = result.error
                    )
                }
            }
            Unit
        }
        coordinator.addResultListener(listener)
        unsubscribeSync = { coordinator.removeResultListener(listener) }
    }

    fun syncNow() {
        val coordinator = syncCoordinator ?: return
        _state.update { it.copy(syncStatus = SyncStatus.SYNCING) }
        coordinator.requestSync(immediate = true)
    }

    fun setSyncStatus(status: SyncStatus, detail: String? = null) =
        _state.update { it.copy(syncStatus = status, syncDetail = detail) }

    // ---------------------------------------------------------------- 账号

    /** 由入口注入;未注入时设置页的登录按钮会提示"网络层未初始化" */
    var authApi: com.ordo.desktop.net.KtorAuthApi? = null
    var tokens: com.ordo.desktop.net.TokenStore? = null
    var onAuthChanged: (() -> Unit)? = null

    val serverUrl: String get() = tokens?.serverUrl ?: com.ordo.desktop.net.TokenStore.DEFAULT_SERVER
    val accountEmail: String? get() = tokens?.email
    val isLoggedIn: Boolean get() = tokens?.isLoggedIn == true

    fun setServerUrl(url: String) {
        tokens?.serverUrl = url
        refresh()
    }

    fun login(email: String, password: String, register: Boolean, done: (Boolean, String?) -> Unit) {
        val api = authApi
        val store = tokens
        if (api == null || store == null) {
            done(false, "网络层未初始化")
            return
        }
        val request = com.ordo.core.sync.AuthRequest(
            email = email.trim(),
            password = password,
            deviceName = "Ordo Windows",
            platform = "windows"
        )
        scope.launch {
            runCatching { if (register) api.register(request) else api.login(request) }
                .onSuccess { response ->
                    store.save(response)
                    _state.update { it.copy(syncStatus = SyncStatus.SYNCING) }
                    onAuthChanged?.invoke()
                    done(true, null)
                }
                .onFailure { error -> done(false, error.message ?: "请求失败") }
        }
    }

    fun logout() {
        val api = authApi
        scope.launch {
            runCatching { api?.logout() }
            tokens?.clear()
            _state.update { it.copy(syncStatus = SyncStatus.LOCAL, syncDetail = null) }
            onAuthChanged?.invoke()
        }
    }

    fun pendingOpCount(): Int = engine.pendingOpCount()

    fun lastServerSeq(): Long = engine.lastServerSeq()

    /** 设置页「同步诊断」的数据来源:outbox 条数 / 服务端序号 / 上次错误 / 前 10 条明细 */
    fun syncDiagnostics(): SyncDiagnostics =
        SyncDiagnostics.of(engine, _state.value.syncDetail ?: syncCoordinator?.currentError())

    // ---------------------------------------------------------------- 系统集成

    /**
     * 开机自启:入口注入真实注册表实现;未注入时是内存实现(测试与离屏渲染绝不写注册表)。
     */
    var autoStart: com.ordo.desktop.system.AutoStart = com.ordo.desktop.system.InMemoryAutoStart()

    fun isAutoStartEnabled(): Boolean =
        runCatching { autoStart.isEnabled() }.getOrDefault(false)

    fun setAutoStart(enabled: Boolean): Boolean =
        runCatching { autoStart.setEnabled(enabled) }.getOrDefault(false)

    /** 设置页开关下面的一句说明 */
    fun autoStartHint(): String? {
        val command = runCatching { autoStart.command() }.getOrNull()
        return when {
            command != null -> "登记的启动命令:$command"
            autoStart is com.ordo.desktop.system.InMemoryAutoStart -> "便携模式:开关仅记录在内存中,不写注册表"
            else -> null
        }
    }

    /**
     * `ordo://` 协议注册(04-UI规范 §7:Windows 端协议注册)。
     * 同样由入口注入真实实现,未注入时是内存实现;所有注册表调用都在实现里 runCatching。
     */
    var protocol: com.ordo.desktop.system.ProtocolRegistrar = com.ordo.desktop.system.InMemoryProtocolRegistrar()

    fun isProtocolRegistered(): Boolean = runCatching { protocol.isRegistered() }.getOrDefault(false)

    fun registerProtocol(): Boolean {
        val ok = runCatching { protocol.register() }.getOrDefault(false)
        if (ok) storage.kvSet(KEY_PROTOCOL_REGISTERED, "1")
        return ok
    }

    fun protocolHint(): String = when {
        isProtocolRegistered() -> "已在注册表登记 HKCU\\Software\\Classes\\ordo,浏览器/其它应用可直接打开 ordo:// 链接"
        protocol is com.ordo.desktop.system.InMemoryProtocolRegistrar -> "便携模式:不会写注册表"
        else -> "未注册:命令行深链(Ordo.exe ordo://today)仍可用,点击链接打开需要先注册"
    }

    /** 关闭窗口时最小化到托盘(而不是退出);入口据此决定 onCloseRequest 行为 */
    fun closeToTray(): Boolean = storage.kvGet(KEY_CLOSE_TO_TRAY)?.toBooleanStrictOrNull() ?: true

    fun setCloseToTray(enabled: Boolean) {
        storage.kvSet(KEY_CLOSE_TO_TRAY, enabled.toString())
        _state.update { it.copy(closeToTray = enabled) }
    }

    /** 新建窗口(多窗口,每窗口独立路由);由入口注入 */
    var onNewWindow: (() -> Unit)? = null

    fun openNewWindow() {
        onNewWindow?.invoke() ?: toast("多窗口不可用")
    }

    // ---------------------------------------------------------------- 数据管理

    fun resetDemoData() {
        engine.seedDemoData(force = true)
        _state.update { it.copy(selectedId = null) }
        refresh()
        toast("已重置为示例数据")
    }

    fun clearAllData() {
        engine.clearAll()
        _state.update { it.copy(selectedId = null) }
        refresh()
        toast("已清空本地数据")
    }

    fun todayISO(): String = OrdoDate.todayISO()

    fun dispose() {
        unsubscribe?.invoke()
        unsubscribe = null
        unsubscribeSync?.invoke()
        unsubscribeSync = null
        selectionJob?.cancel()
        selectionJob = null
        selectionBus = null
    }

    companion object {
        const val KEY_THEME = "ordo.theme"
        const val KEY_WINDOW_W = "ordo.window.width"
        const val KEY_WINDOW_H = "ordo.window.height"
        const val KEY_WINDOW_X = "ordo.window.x"
        const val KEY_WINDOW_Y = "ordo.window.y"
        const val KEY_CLOSE_TO_TRAY = "ordo.closeToTray"
        const val KEY_PROTOCOL_REGISTERED = "ordo.protocol.registered"
        const val KEY_FOLLOW_SELECTION = "ordo.followSelection"
    }
}
