package com.ordo.desktop

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.awt.ComposeWindow
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.ApplicationScope
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.WindowState
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import com.ordo.core.platform.SystemOrdoClock
import com.ordo.core.store.OrdoEngine
import com.ordo.desktop.app.OrdoRoute
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.SharedSelection
import com.ordo.desktop.app.UiState
import com.ordo.desktop.data.JsonFileStorage
import com.ordo.desktop.net.KtorAuthApi
import com.ordo.desktop.net.KtorRealtimeChannel
import com.ordo.desktop.net.KtorSyncApi
import com.ordo.desktop.net.OrdoHttp
import com.ordo.desktop.net.TokenStore
import com.ordo.desktop.sync.SyncCoordinator
import com.ordo.desktop.system.DeepLink
import com.ordo.desktop.system.DeepLinkInbox
import com.ordo.desktop.system.LockResult
import com.ordo.desktop.system.ReminderScheduler
import com.ordo.desktop.system.SingleInstanceLock
import com.ordo.desktop.system.TrayNotifications
import com.ordo.desktop.system.WindowsAutoStart
import com.ordo.desktop.system.WindowsProtocolRegistrar
import com.ordo.desktop.ui.common.OrdoInputFocus
import com.ordo.desktop.ui.shell.OrdoApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import java.awt.Dimension
import java.awt.GraphicsEnvironment
import java.awt.Point
import java.awt.Rectangle
import java.io.File

/** 版本号(与 build.gradle.kts 的 packageVersion 一致;`Ordo.exe --version` 用于打包冒烟) */
private const val APP_VERSION = "1.0.0"

/**
 * Ordo 桌面端入口(Compose Multiplatform Desktop)。
 *
 * 装配顺序(全部本地优先,契约 §7.1):
 *   单实例锁 → 本地文件仓储 → 共享核心引擎(首次启动写入演示数据)→ 网络与同步 → 托盘/提醒 → 窗口
 *
 * **多窗口**(04-UI规范 §3):每个窗口一份 [OrdoViewModel] —— 独立路由 / 选中 / 浮层,共享同一个引擎与同步;
 * `Ctrl+Shift+N` 或「设置 → 窗口 → 新建窗口」开新窗口,托盘可随时把它们叫回来。
 *
 * **托盘常驻**:默认关闭窗口 = 最小化到托盘(「设置 → 关闭窗口」可改成直接退出)。
 *
 * 命令行:
 *   `--version`            打印版本后直接退出(打包产物自检,不启动界面)
 *   `--selftest=<报告文件>` 启动真实界面,把窗口/存储状态写进报告后自动退出(打包冒烟;见 README §2)
 *   `--data-dir=<路径>`    覆盖数据目录(便携部署 / 自动化冒烟)
 *   `ordo://…`             深链:today / project/<id> / todo/<id>
 */
fun main(args: Array<String>) {
    if (args.any { it == "--version" || it == "-v" }) {
        println("Ordo $APP_VERSION · windows-desktop · Compose Multiplatform")
        return
    }
    val selfTest = args.firstOrNull { it.startsWith(SELFTEST_FLAG) }
        ?.removePrefix(SELFTEST_FLAG)
        ?.takeIf { it.isNotBlank() }
        ?.let { File(it) }

    val dataDir = resolveDataDir(args)
    // 单实例:托盘常驻后用户可能再次双击图标,两个引擎写同一份 JSON 会互相覆盖
    val lockResult = SingleInstanceLock.acquire(dataDir)
    when (lockResult) {
        is LockResult.Unavailable -> {
            // 环境问题(权限 / IO)不该把用户挡在门外:继续启动,只是没有单实例保护
            println("单实例锁不可用(${lockResult.reason}),继续启动")
        }
        LockResult.AlreadyRunning -> {
            // 已有实例在跑:把 ordo:// 链接转交给它(没有链接就只要求唤出窗口),然后自己退出
            val inbox = DeepLinkInbox.of(dataDir)
            val forwarded = inbox.submit(args.toList())
            val focused = forwarded || inbox.submitFocus()
            println(
                when {
                    forwarded -> "Ordo 已在运行,已把链接转交给它"
                    focused -> "Ordo 已在运行,已唤出它的窗口"
                    else -> "Ordo 已在运行(可在系统托盘里打开窗口)"
                }
            )
            if (!focused) notifyAlreadyRunning()
            return
        }
        is LockResult.Acquired -> Unit
    }

    application { desktopApp(args, dataDir, selfTest) }
}

/** `--selftest=<报告文件>` */
private const val SELFTEST_FLAG = "--selftest="

/** 自检报告:逐行追加,便于定位卡在启动的哪一步 */
private fun selfTestReport(file: File?, line: String) {
    if (file == null) return
    runCatching {
        file.parentFile?.mkdirs()
        file.appendText(line + System.lineSeparator())
    }
}

@Composable
private fun ApplicationScope.desktopApp(args: Array<String>, dataDir: File, selfTest: File? = null) {
    val appScope = remember { CoroutineScope(SupervisorJob() + Dispatchers.Default) }

    /* ---------------- 数据层:JSON 文件仓储(契约 §8) ---------------- */
    selfTestReport(selfTest, "step=data-dir dir=${dataDir.absolutePath}")
    val storage = remember { JsonFileStorage(dataDir) }
    val engine = remember { OrdoEngine(storage, SystemOrdoClock) }

    /* ---------------- 网络与同步(契约 §7.4 / §7.5) ---------------- */
    val client = remember { OrdoHttp.create() }
    val tokens = remember { TokenStore(storage) }
    val authApi = remember { KtorAuthApi(client, tokens) }
    val syncApi = remember { KtorSyncApi(client, tokens, engine.deviceId) }
    val realtime = remember { KtorRealtimeChannel(client, tokens) }
    selfTestReport(selfTest, "step=engine+net ready todos=${engine.snapshot.todos.size}")

    /* ---------------- 窗口列表(多窗口:每个 id = 一份独立路由的窗口) ---------------- */
    val windowIds = remember { mutableStateListOf(FIRST_WINDOW_ID) }
    val windowVisible = remember { mutableStateMapOf(FIRST_WINDOW_ID to true) }
    val windowRoutes = remember { mutableStateMapOf<Int, OrdoRoute>(FIRST_WINDOW_ID to OrdoRoute.Today) }
    val vmRegistry = remember { mutableStateMapOf<Int, OrdoViewModel>() }
    val selectionBus = remember { SharedSelection() }
    var nextWindowId by remember { mutableStateOf(FIRST_WINDOW_ID + 1) }
    val savedLayout = remember { loadWindowLayout(storage) }

    fun openWindow(route: OrdoRoute) {
        val id = nextWindowId++
        windowRoutes[id] = route
        windowVisible[id] = true
        windowIds.add(id)
    }

    /** 托盘「打开 Ordo」:先把隐藏的窗口叫回来,一个都没有就新开一个 */
    fun showOrOpenWindow() {
        val hidden = windowIds.firstOrNull { windowVisible[it] != true }
        if (hidden != null) windowVisible[hidden] = true else openWindow(OrdoRoute.Today)
    }

    val tray = remember {
        TrayNotifications(
            onOpenWindow = { showOrOpenWindow() },
            onQuit = {
                // 真正退出:数据已逐次落盘,这里只需要关闭通道
                exitApplication()
            },
            onOpenTodo = { todoId ->
                // 点托盘通知:把窗口叫回来并选中对应待办(04-UI规范 §7 系统通知)
                showOrOpenWindow()
                windowIds.firstOrNull()?.let { id -> vmRegistry[id]?.selectTodo(todoId) }
            }
        )
    }

    val coordinator = remember {
        SyncCoordinator(
            engine = engine,
            syncApi = syncApi,
            authApi = authApi,
            tokens = tokens,
            realtime = realtime,
            scope = appScope,
            onRemoteReminder = { push -> tray.notify(push.todoId, push.title, push.at) }
        )
    }

    val reminderScheduler = remember {
        ReminderScheduler(
            engine = engine,
            storage = storage,
            notifier = { todoId, title, at -> tray.notify(todoId, title, "提醒时间 $at") },
            scope = appScope
        )
    }

    /** 到点提醒的轮询 Job(用状态持有,重组时不会被重置) */
    val reminderJob = remember { mutableStateOf<Job?>(null) }

    LaunchedEffect(Unit) {
        // 首次启动:注册 ordo:// 协议(失败不影响启动,设置页可手动重试)
        runCatching {
            val registrar = WindowsProtocolRegistrar()
            if (!registrar.isRegistered()) registrar.register()
        }
        coordinator.start()
        tray.install()
        reminderJob.value = reminderScheduler.start()
    }

    DisposableEffect(Unit) {
        onDispose {
            runCatching { reminderJob.value?.cancel() }
            runCatching { coordinator.stop() }
            runCatching { realtime.close() }
            runCatching { tray.remove() }
            runCatching { client.close() }
            appScope.cancel()
        }
    }

    // 深链:ordo://today / ordo://project/<id> / ordo://todo/<id>(作用于第一个窗口)
    val deepLink = remember { DeepLink.fromArgs(args) }
    // 跨进程深链转交:第二个实例把链接写进 .ordo.inbox,这里轮询消费
    // (命名管道要 JNI、本地 socket 要占端口,文件转交零依赖且可单测)
    val linkInbox = remember { DeepLinkInbox.of(dataDir) }
    LaunchedEffect(Unit) {
        linkInbox.cleanupTemp()
        while (true) {
            linkInbox.drain().forEach { raw ->
                // 只要"唤出窗口"的转交(第二个实例没带深链时)
                if (raw == DeepLinkInbox.FOCUS_LINK) {
                    showOrOpenWindow()
                    selfTestReport(selfTest, "step=focus-requested")
                    return@forEach
                }
                val target = DeepLink.safeParse(raw) ?: return@forEach
                showOrOpenWindow()
                windowIds.firstOrNull()?.let { id ->
                    vmRegistry[id]?.let { vm ->
                        vm.navigate(target.route)
                        target.todoId?.let { vm.selectTodo(it) }
                    }
                }
                selfTestReport(selfTest, "step=forwarded route=${target.route} todo=${target.todoId}")
            }
            kotlinx.coroutines.delay(DeepLinkInbox.POLL_MILLIS)
        }
    }

    // 自检:额外开一个窗口,验证"多窗口 + 每窗口独立路由"在打包产物里真的能起来
    LaunchedEffect(selfTest) {
        if (selfTest == null) return@LaunchedEffect
        kotlinx.coroutines.delay(SELFTEST_SECOND_WINDOW_DELAY_MILLIS)
        openWindow(OrdoRoute.Inbox)
        selfTestReport(selfTest, "step=second-window requested route=inbox")
        kotlinx.coroutines.delay(SELFTEST_FORWARD_REPORT_DELAY_MILLIS)
        windowIds.firstOrNull()?.let { id ->
            selfTestReport(selfTest, "step=first-window route=${vmRegistry[id]?.state?.value?.route}")
        }
    }
    LaunchedEffect(selfTest, windowIds.size) {
        if (selfTest == null) return@LaunchedEffect
        selfTestReport(selfTest, "step=windows count=${windowIds.size} visible=${windowIds.count { windowVisible[it] == true }}")
    }

    windowIds.toList().forEachIndexed { index, windowId ->
        key(windowId) {
            DesktopWindow(
                windowId = windowId,
                isFirst = index == 0,
                engine = engine,
                storage = storage,
                scope = appScope,
                coordinator = coordinator,
                authApi = authApi,
                tokens = tokens,
                selectionBus = selectionBus,
                savedLayout = savedLayout,
                cascadeIndex = index,
                initialRoute = windowRoutes[windowId] ?: OrdoRoute.Today,
                deepLink = if (index == 0) deepLink else null,
                visible = windowVisible[windowId] != false,
                selfTest = if (index == 0) selfTest else null,
                onRequestNewWindow = { openWindow(windowRoutes[windowId] ?: OrdoRoute.Today) },
                onPersistLayout = { state, location -> saveWindowLayout(storage, state.size, location) },
                onVisibilityChange = { visible -> windowVisible[windowId] = visible },
                onVmReady = { vm -> vmRegistry[windowId] = vm },
                onVmGone = { vmRegistry.remove(windowId) },
                onClose = { keepAlive ->
                    if (!keepAlive) {
                        windowIds.remove(windowId)
                        windowVisible.remove(windowId)
                        windowRoutes.remove(windowId)
                        if (windowIds.isEmpty()) exitApplication()
                    }
                }
            )
        }
    }
}

/**
 * 一个桌面窗口 = 一份视图模型(独立路由 / 选中 / 浮层)+ 自己的窗口状态。
 *
 * @param onClose 参数 `keepAlive = true` 表示"只是最小化到托盘",窗口仍留在列表里
 */
@Composable
private fun ApplicationScope.DesktopWindow(
    windowId: Int,
    isFirst: Boolean,
    engine: OrdoEngine,
    storage: JsonFileStorage,
    scope: CoroutineScope,
    coordinator: SyncCoordinator,
    authApi: KtorAuthApi,
    tokens: TokenStore,
    selectionBus: SharedSelection,
    savedLayout: WindowLayout,
    cascadeIndex: Int,
    initialRoute: OrdoRoute,
    deepLink: DeepLink.Target?,
    visible: Boolean,
    selfTest: File?,
    onRequestNewWindow: () -> Unit,
    onPersistLayout: (WindowState, Point?) -> Unit,
    onVisibilityChange: (Boolean) -> Unit,
    onVmReady: (OrdoViewModel) -> Unit,
    onVmGone: (OrdoViewModel) -> Unit,
    onClose: (keepAlive: Boolean) -> Unit
) {
    val vm = remember {
        OrdoViewModel(engine = engine, storage = storage, scope = scope, seedDemoData = isFirst)
    }
    val windowState = rememberWindowState(
        size = savedLayout.size,
        position = if (isFirst) savedLayout.position() else cascadePosition(cascadeIndex)
    )
    val windowRef = remember { mutableStateOf<ComposeWindow?>(null) }

    DisposableEffect(Unit) {
        onVmReady(vm)
        onDispose {
            onVmGone(vm)
            vm.dispose()
        }
    }

    LaunchedEffect(Unit) {
        vm.authApi = authApi
        vm.tokens = tokens
        vm.onAuthChanged = { coordinator.onLoggedIn() }
        // 系统集成:开机自启与 ordo:// 协议(拿不到 exe 路径时自动退化为不可用)
        vm.autoStart = WindowsAutoStart()
        vm.protocol = WindowsProtocolRegistrar()
        vm.onNewWindow = onRequestNewWindow
        vm.attachSync(coordinator)
        vm.attachSelectionBus(selectionBus)
        if (initialRoute != OrdoRoute.Today) vm.navigate(initialRoute)
        deepLink?.let { target ->
            vm.navigate(target.route)
            target.todoId?.let { vm.selectTodo(it) }
        }
    }

    val state by vm.state.collectAsState()

    Window(
        onCloseRequest = {
            onPersistLayout(windowState, windowRef.value?.location)
            if (vm.closeToTray()) {
                // 托盘常驻:只是把窗口藏起来,引擎/提醒/同步继续跑
                onVisibilityChange(false)
                onClose(true)
            } else {
                onClose(false)
            }
        },
        state = windowState,
        visible = visible,
        title = windowTitle(state, vm),
        onKeyEvent = { event -> handleShortcut(event, vm, onRequestNewWindow) }
    ) {
        LaunchedEffect(Unit) {
            windowRef.value = window
            window.minimumSize = Dimension(MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT)
            if (isFirst) savedLayout.applyLocation(window)
        }
        // 尺寸 / 位置随时记忆(拖动缩放过程中合并写入,退出路径不必再补救)
        LaunchedEffect(Unit) {
            snapshotFlow { windowState.size to windowState.position }
                .collectLatest {
                    kotlinx.coroutines.delay(LAYOUT_SAVE_DEBOUNCE_MILLIS)
                    saveWindowLayout(storage, windowState.size, windowRef.value?.location)
                }
        }
        // 从托盘恢复时把窗口提到最前
        LaunchedEffect(visible) {
            if (visible) runCatching { window.toFront() }
        }
        if (selfTest != null) {
            SelfTestHook(window = window, file = selfTest, engine = engine, dataDir = storage.dir)
        }
        OrdoApp(vm)
    }
}

/** 打包冒烟:等窗口真正可见后写报告并退出(仅用于 `--selftest`) */
@Composable
private fun SelfTestHook(window: ComposeWindow, file: File, engine: OrdoEngine, dataDir: File) {
    LaunchedEffect(Unit) {
        var shown = false
        val start = System.currentTimeMillis()
        while (!shown && System.currentTimeMillis() - start < SELFTEST_TIMEOUT_MILLIS) {
            withFrameNanos { }
            shown = runCatching { window.isShowing }.getOrDefault(false)
        }
        selfTestReport(
            file,
            "step=window showing=$shown waitedMs=${System.currentTimeMillis() - start} " +
                "size=${window.width}x${window.height} at=${window.location.x},${window.location.y}"
        )
        selfTestReport(file, "step=data dir=${dataDir.absolutePath} todos=${engine.snapshot.todos.size}")
        kotlinx.coroutines.delay(SELFTEST_EXIT_DELAY_MILLIS)
        selfTestReport(file, "step=still-showing=${runCatching { window.isShowing }.getOrDefault(false)}")
        selfTestReport(file, "step=done ok=$shown")
        kotlin.system.exitProcess(0)
    }
}

/** 自检最长等待(毫秒)、窗口建好后的退出延迟、第二个窗口的开启时刻、转交结果的报告时刻 */
private const val SELFTEST_TIMEOUT_MILLIS = 20_000L
private const val SELFTEST_EXIT_DELAY_MILLIS = 9_000L
private const val SELFTEST_SECOND_WINDOW_DELAY_MILLIS = 2_500L
private const val SELFTEST_FORWARD_REPORT_DELAY_MILLIS = 3_500L

/** 窗口尺寸/位置落盘的合并窗口(拖动过程中不要每帧写文件) */
private const val LAYOUT_SAVE_DEBOUNCE_MILLIS = 700L

private const val FIRST_WINDOW_ID = 1

/** 新窗口层叠位置:相对屏幕居中再偏移,避免完全盖住主窗口 */
private fun cascadePosition(index: Int): WindowPosition {
    if (index <= 0) return WindowPosition(Alignment.Center)
    val offset = (32 * index).dp
    return WindowPosition(offset, offset)
}

/** 窗口最小尺寸(04-UI规范 §3:480×640) */
private const val MIN_WINDOW_WIDTH = 480
private const val MIN_WINDOW_HEIGHT = 640

/** 记忆下来的窗口尺寸与位置(位置为屏幕像素;越界则回落到居中) */
private data class WindowLayout(val size: DpSize, val x: Int?, val y: Int?) {

    fun position(): WindowPosition =
        if (x != null && y != null) WindowPosition(x.dp, y.dp) else WindowPosition(Alignment.Center)

    /** 像素级恢复位置;窗口被移到屏幕外(拔掉外接屏)时不动,保持居中 */
    fun applyLocation(window: ComposeWindow) {
        val px = x ?: return
        val py = y ?: return
        if (!isOnScreen(px, py)) return
        runCatching { window.setLocation(px, py) }
    }
}

private fun loadWindowLayout(storage: JsonFileStorage): WindowLayout {
    val width = storage.kvGet(OrdoViewModel.KEY_WINDOW_W)?.toFloatOrNull() ?: 1180f
    val height = storage.kvGet(OrdoViewModel.KEY_WINDOW_H)?.toFloatOrNull() ?: 760f
    val x = storage.kvGet(OrdoViewModel.KEY_WINDOW_X)?.toIntOrNull()
    val y = storage.kvGet(OrdoViewModel.KEY_WINDOW_Y)?.toIntOrNull()
    val visible = x != null && y != null && isOnScreen(x, y)
    return WindowLayout(
        size = DpSize(
            width.coerceAtLeast(MIN_WINDOW_WIDTH.toFloat()).dp,
            height.coerceAtLeast(MIN_WINDOW_HEIGHT.toFloat()).dp
        ),
        x = if (visible) x else null,
        y = if (visible) y else null
    )
}

private fun saveWindowLayout(storage: JsonFileStorage, size: DpSize, location: Point?) {
    storage.kvSet(OrdoViewModel.KEY_WINDOW_W, size.width.value.toInt().toString())
    storage.kvSet(OrdoViewModel.KEY_WINDOW_H, size.height.value.toInt().toString())
    location?.let {
        storage.kvSet(OrdoViewModel.KEY_WINDOW_X, it.x.toString())
        storage.kvSet(OrdoViewModel.KEY_WINDOW_Y, it.y.toString())
    }
}

/** 位置是否落在任一屏幕内(留 32px 让标题栏可点) */
private fun isOnScreen(x: Int, y: Int): Boolean = runCatching {
    val env = GraphicsEnvironment.getLocalGraphicsEnvironment()
    val bounds: Rectangle = env.screenDevices
        .map { it.defaultConfiguration.bounds }
        .reduceOrNull { a, b -> a.union(b) }
        ?: return@runCatching true
    bounds.contains(x + ON_SCREEN_MARGIN, y + ON_SCREEN_MARGIN)
}.getOrDefault(true)

private const val ON_SCREEN_MARGIN = 32

/** 窗口标题:Ordo · 今天 / Ordo · Q4 产品发布 …(04-UI规范 §3) */
private fun windowTitle(state: UiState, vm: OrdoViewModel): String =
    "Ordo · " + state.route.title.ifBlank { vm.windowTitle() }

/**
 * 全局快捷键(04-UI规范 §6 桌面列)。
 * 文本输入获得焦点时,除带修饰键的组合外一律让路(避免打字被吞)。
 */
private fun handleShortcut(event: KeyEvent, vm: OrdoViewModel, onNewWindow: () -> Unit): Boolean {
    if (event.type != KeyEventType.KeyDown) return false

    if (event.isCtrlPressed) {
        // Ctrl+Shift+N:新建窗口(多窗口,每窗口独立路由)
        if (event.isShiftPressed && event.key == Key.N) {
            onNewWindow()
            return true
        }
        return when (event.key) {
            Key.N -> { vm.openComposer(); true }
            Key.K -> { vm.openFastFind(); true }
            Key.D -> { vm.cycleTheme(); true }
            Key.One -> { vm.navigate(OrdoRoute.Inbox); true }
            Key.Two -> { vm.navigate(OrdoRoute.Today); true }
            Key.Three -> { vm.navigate(OrdoRoute.Upcoming); true }
            Key.Four -> { vm.navigate(OrdoRoute.Anytime); true }
            Key.Five -> { vm.navigate(OrdoRoute.Someday); true }
            Key.Six -> { vm.navigate(OrdoRoute.Logbook); true }
            else -> false
        }
    }

    if (OrdoInputFocus.isTyping) return false

    return when (event.key) {
        Key.DirectionDown -> { vm.moveSelection(1); true }
        Key.DirectionUp -> { vm.moveSelection(-1); true }
        Key.Enter -> { vm.openHighlighted(); true }
        Key.Spacebar -> { vm.toggleHighlighted(); true }
        Key.Delete, Key.Backspace -> { vm.deleteHighlighted(); true }
        // 拖动中优先取消拖动,否则关闭浮层 / 详情(OrdoViewModel.escape 内部判定)
        Key.Escape -> { vm.escape(); true }
        else -> false
    }
}

/** 数据目录:%APPDATA%\Ordo;`--data-dir=<路径>` 或 -Dordo.dataDir=... 可覆盖(便携部署 / 自动化测试) */
private fun resolveDataDir(args: Array<String>): File {
    args.firstOrNull { it.startsWith("--data-dir=") }
        ?.removePrefix("--data-dir=")
        ?.takeIf { it.isNotBlank() }
        ?.let { return File(it) }
    System.getProperty("ordo.dataDir")?.takeIf { it.isNotBlank() }?.let { return File(it) }
    val appData = System.getenv("APPDATA")
    val base = if (!appData.isNullOrBlank()) File(appData) else File(System.getProperty("user.home"), ".ordo")
    return File(base, "Ordo")
}

/** 已有实例时给个提示:对话框放在单独线程上,主线程不阻塞(拿不到图形环境就只打印) */
private fun notifyAlreadyRunning() {
    Thread {
        runCatching {
            javax.swing.JOptionPane.showMessageDialog(
                null,
                "Ordo 已经在运行了。\n请在系统托盘(右下角)双击 Ordo 图标打开窗口。",
                "Ordo 已在运行",
                javax.swing.JOptionPane.INFORMATION_MESSAGE
            )
        }
    }.apply { name = "ordo-already-running" }.start()
}
