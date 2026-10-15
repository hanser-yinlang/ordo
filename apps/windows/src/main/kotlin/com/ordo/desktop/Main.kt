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
import javax.imageio.ImageIO

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
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.toComposeImageBitmap
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
import com.ordo.desktop.data.UserDataDirs
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

    val baseDir = UserDataDirs.resolveBase(args)
    // 单实例:托盘常驻后用户可能再次双击图标,两个引擎写同一份 JSON 会互相覆盖。
    // 锁放在**基目录**(与账号无关):第二个实例启动时还不知道 userId,必须能先撞上这把锁。
    val lockResult = SingleInstanceLock.acquire(baseDir)
    selfTestReport(
        selfTest,
        "step=lock result=${lockResult::class.simpleName} held=${SingleInstanceLock.isHeldByThisProcess()} " +
            "count=${SingleInstanceLock.heldCount()} dir=${baseDir.absolutePath}"
    )
    when (lockResult) {
        is LockResult.Unavailable -> {
            // 环境问题(权限 / IO)不该把用户挡在门外:继续启动,只是没有单实例保护
            System.err.println("Ordo: 单实例锁不可用(${lockResult.reason}),继续启动")
            System.err.flush()
        }
        LockResult.AlreadyRunning -> {
            // 已有实例在跑:把 ordo:// 链接转交给它(没有链接就只要求唤出窗口),然后自己退出
            val inbox = DeepLinkInbox.of(baseDir)
            val forwarded = inbox.submit(args.toList())
            val focused = forwarded || inbox.submitFocus()
            println(
                when {
                    forwarded -> "Ordo 已在运行,已把链接转交给它"
                    focused -> "Ordo 已在运行,已唤出它的窗口"
                    else -> "Ordo 已在运行(可在系统托盘里打开窗口)"
                }
            )
            System.out.flush()
            if (!focused) notifyAlreadyRunning()
            return
        }
        is LockResult.Acquired -> Unit
    }

    application { desktopApp(args, baseDir, selfTest) }
}

/** `--selftest=<报告文件>` */
private const val SELFTEST_FLAG = "--selftest="

/** 自检报告:逐行追加(带相对时间戳),便于定位启动与转交的时序 */
private val selfTestStart = System.currentTimeMillis()

private fun selfTestReport(file: File?, line: String) {
    if (file == null) return
    runCatching {
        file.parentFile?.mkdirs()
        file.appendText("+${System.currentTimeMillis() - selfTestStart}ms $line" + System.lineSeparator())
    }
}

@Composable
private fun ApplicationScope.desktopApp(args: Array<String>, baseDir: File, selfTest: File? = null) {
    val appScope = remember { CoroutineScope(SupervisorJob() + Dispatchers.Default) }

    /* ---------------- 纯本地:只读本机基目录,不建任何网络对象 ---------------- */
    // 产品决策(2026-10-13):云同步彻底删除 —— 本端是纯本地应用,启动到退出**一个网络请求都不发**,
    // 类路径上也没有任何 HTTP / WebSocket 客户端(见 NoNetworkTest 的三重断言)。
    selfTestReport(selfTest, "step=base-dir dir=${baseDir.absolutePath} mode=local-only")
    val bootstrap = remember { JsonFileStorage(baseDir) }

    // 数据目录 id:**本机稳定标识**(契约 §7.6.6),首次启动即钉进 kv,之后**永不变**:
    // 老机器沿用已在用的目录(不改名、不迁移),全新安装生成一个本地 id。
    val dataDirId = remember {
        val id = UserDataDirs.resolveDataDirId(bootstrap, baseDir)
        selfTestReport(selfTest, "step=data-dir id=$id")
        id
    }

    selfTestReport(selfTest, "step=startup ui=main(local-only)")

    AppWindows(
        args = args,
        baseDir = baseDir,
        bootstrap = bootstrap,
        scope = appScope,
        dataDirId = dataDirId,
        selfTest = selfTest
    )
}

/**
 * 主界面:一个数据目录 = N 个窗口。
 *
 * `key(dataDirId)` 保证数据目录切换时整棵树(引擎 / 窗口 / 托盘)重建 ——
 * 数据目录 id 是**本机钉住**的,所以正常运行期间它不会变。
 */
@Composable
private fun ApplicationScope.AppWindows(
    args: Array<String>,
    baseDir: File,
    bootstrap: JsonFileStorage,
    scope: CoroutineScope,
    dataDirId: String,
    selfTest: File?
) {
    key(dataDirId) {
        LocalApp(
            args = args,
            baseDir = baseDir,
            bootstrap = bootstrap,
            scope = scope,
            dataDirId = dataDirId,
            selfTest = selfTest
        )
    }
}

@Composable
private fun ApplicationScope.LocalApp(
    args: Array<String>,
    baseDir: File,
    bootstrap: JsonFileStorage,
    scope: CoroutineScope,
    dataDirId: String,
    selfTest: File?
) {
    /* ---------------- 数据层:该数据目录专属子目录 %APPDATA%\Ordo\<id>(契约 §7.6.3) ---------------- */
    val dataDir = remember(dataDirId) { UserDataDirs.userDir(baseDir, dataDirId) }
    val storage = remember(dataDir) { JsonFileStorage(dataDir) }
    val engine = remember(storage) { OrdoEngine(storage, SystemOrdoClock) }
    selfTestReport(selfTest, "step=engine ready todos=${engine.snapshot.todos.size} (no network)")

    /* ---------------- 窗口列表(多窗口:每个 id = 一份独立路由的窗口) ---------------- */
    val windowIds = remember { mutableStateListOf(FIRST_WINDOW_ID) }
    val windowVisible = remember { mutableStateMapOf(FIRST_WINDOW_ID to true) }
    val windowRoutes = remember { mutableStateMapOf<Int, OrdoRoute>(FIRST_WINDOW_ID to OrdoRoute.Today) }
    val vmRegistry = remember { mutableStateMapOf<Int, OrdoViewModel>() }
    val windowRaise = remember { mutableStateMapOf<Int, Int>() }
    val selectionBus = remember { SharedSelection() }
    var nextWindowId by remember { mutableStateOf(FIRST_WINDOW_ID + 1) }
    val savedLayout = remember(storage) { loadWindowLayout(storage) }

    fun openWindow(route: OrdoRoute) {
        val id = nextWindowId++
        windowRoutes[id] = route
        windowVisible[id] = true
        windowIds.add(id)
    }

    /** 把某个窗口叫出来并提到最前(每次请求自增令牌,即使它本来就可见也会重新 raise) */
    fun raiseWindow(id: Int) {
        windowVisible[id] = true
        windowRaise[id] = (windowRaise[id] ?: 0) + 1
    }

    /**
     * 托盘「打开 Ordo」/ 无参启动的第二次实例:优先复用已有窗口 ——
     * 有隐藏的就叫回来,一个窗口都没有才新建;已经有可见窗口时只把它提到最前,不再多开一个。
     */
    fun showOrOpenWindow() {
        val hidden = windowIds.firstOrNull { windowVisible[it] != true }
        when {
            hidden != null -> raiseWindow(hidden)
            windowIds.isEmpty() -> openWindow(OrdoRoute.Today)
            else -> windowIds.first().let { raiseWindow(it) }
        }
        // 唤回窗口时补一次「该不该播种」的判断:进程常驻托盘时窗口关了再开**不会**重建 ViewModel,
        // 用户「清空本地数据」后重启应用就会看到空界面(实测反馈)。播种与否由共享核心的持久化标记决定,
        // 所以这里只是"再问一次",用户自己删空的数据不会被复活。
        // (窗口刚创建的那一次 vmRegistry 里还没有 vm,那一路由第一个窗口自己的 [OrdoViewModel.init] 负责)
        windowIds.firstOrNull()?.let { id -> vmRegistry[id]?.onAppActivated() }
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

    val reminderScheduler = remember {
        ReminderScheduler(
            engine = engine,
            storage = storage,
            notifier = { todoId, title, at -> tray.notify(todoId, title, "提醒时间 $at") },
            scope = scope
        )
    }

    /** 到点提醒的轮询 Job(用状态持有,重组时不会被重置) */
    val reminderJob = remember { mutableStateOf<Job?>(null) }

    LaunchedEffect(Unit) {
        // 首次启动:静默注册 ordo:// 协议(失败不影响启动,也没有界面入口)
        runCatching {
            val registrar = WindowsProtocolRegistrar()
            if (!registrar.isRegistered()) registrar.register()
        }
        tray.install()
        reminderJob.value = reminderScheduler.start()
    }

    DisposableEffect(Unit) {
        onDispose {
            runCatching { reminderJob.value?.cancel() }
            runCatching { tray.remove() }
            // 注意:不在这里取消 appScope —— 它属于整个进程
        }
    }

    // 深链:ordo://today / ordo://project/<id> / ordo://todo/<id>(作用于第一个窗口)
    val deepLink = remember { DeepLink.fromArgs(args) }
    // 跨进程深链转交:第二个实例把链接写进 .ordo.inbox,这里轮询消费
    // (命名管道要 JNI、本地 socket 要占端口,文件转交零依赖且可单测)
    // 信箱放在**基目录**(与数据目录无关) —— 纯本地文件,不涉及任何网络
    val linkInbox = remember { DeepLinkInbox.of(baseDir) }
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
                // 复用已有窗口导航,不因为一条链接多开一个窗口;一个窗口都没有(极端情况)才新建
                val reuse = windowIds.isNotEmpty()
                if (!reuse) {
                    openWindow(target.route)
                } else {
                    val id = windowIds.first()
                    raiseWindow(id)
                    vmRegistry[id]?.let { vm ->
                        vm.navigate(target.route)
                        target.todoId?.let { vm.selectTodo(it) }
                    }
                }
                selfTestReport(
                    selfTest,
                    "step=forwarded route=${target.route} todo=${target.todoId} " +
                        "branch=${if (reuse) "reuse-window" else "new-window"}"
                )
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
        selfTestReport(
            selfTest,
            "step=windows count=${windowIds.size} visible=${windowIds.count { windowVisible[it] == true }} " +
                "ids=${windowIds.joinToString("/")}"
        )
    }

    windowIds.toList().forEachIndexed { index, windowId ->
        key(windowId) {
            DesktopWindow(
                windowId = windowId,
                isFirst = index == 0,
                engine = engine,
                storage = storage,
                scope = scope,
                selectionBus = selectionBus,
                savedLayout = savedLayout,
                cascadeIndex = index,
                initialRoute = windowRoutes[windowId] ?: OrdoRoute.Today,
                deepLink = if (index == 0) deepLink else null,
                visible = windowVisible[windowId] != false,
                raiseToken = windowRaise[windowId] ?: 0,
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
    selectionBus: SharedSelection,
    savedLayout: WindowLayout,
    cascadeIndex: Int,
    initialRoute: OrdoRoute,
    deepLink: DeepLink.Target?,
    visible: Boolean,
    raiseToken: Int,
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
        // 纯本地:没有会话 / 令牌 / 同步可挂,只做系统集成与路由
        vm.autoStart = WindowsAutoStart()
        vm.onNewWindow = onRequestNewWindow
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
        // 应用图标(任务栏 / Alt-Tab / 窗口左上角)。
        // 桌面端直接走 JVM 的 ImageIO + BitmapPainter:不用已被弃用的 painterResource(String),
        // 也不必为一个资源引入 Compose Resources 插件。资源与打包用的 icons/ordo-ring.ico 同源。
        icon = windowIcon(),
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
        // 从托盘 / 深链恢复时把窗口提到最前(令牌每请求一次自增,本来就可见也会生效)
        LaunchedEffect(visible, raiseToken) {
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
        selfTestReport(file, "step=lock-held-now=${com.ordo.desktop.system.SingleInstanceLock.isHeldByThisProcess()}")
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

/** 数据基目录:`%APPDATA%\Ordo`;**账号子目录由 [UserDataDirs.userDir] 追加**(契约 §7.6.3) */
private fun resolveDataDir(args: Array<String>): File = UserDataDirs.resolveBase(args)

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

/**
 * 加载窗口图标(任务栏 / Alt-Tab / 窗口左上角)。
 *
 * 为什么不用 `painterResource(String)`:该重载在 Compose Multiplatform 1.12 已弃用,
 * 官方建议迁移到 Compose Resources 库;但那需要为本模块引入资源生成插件 —— 对一个图标而言过重。
 * 桌面端直接用 JVM 的 ImageIO 解码,再包成 BitmapPainter,既无弃用告警也不增加依赖。
 * 资源缺失时返回 null(窗口退回系统默认图标),不让图标问题导致启动失败。
 */
private fun windowIcon(): Painter? = runCatching {
    val stream = Thread.currentThread().contextClassLoader
        ?.getResourceAsStream(WINDOW_ICON_RESOURCE) ?: return null
    stream.use { BitmapPainter(ImageIO.read(it).toComposeImageBitmap()) }
}.getOrNull()

/** 与打包用的 icons/ordo-ring.ico 同源(见 apps/windows/icons/,生成脚本与设计说明见 README §13) */
private const val WINDOW_ICON_RESOURCE = "ordo-icon-ring.png"