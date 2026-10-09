package com.ordo.desktop

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.awt.ComposeWindow
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.ApplicationScope
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import com.ordo.core.platform.SystemOrdoClock
import com.ordo.core.store.OrdoEngine
import com.ordo.desktop.app.OrdoRoute
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.UiState
import com.ordo.desktop.data.JsonFileStorage
import com.ordo.desktop.net.KtorAuthApi
import com.ordo.desktop.net.KtorRealtimeChannel
import com.ordo.desktop.net.KtorSyncApi
import com.ordo.desktop.net.OrdoHttp
import com.ordo.desktop.net.TokenStore
import com.ordo.desktop.sync.SyncCoordinator
import com.ordo.desktop.system.DeepLink
import com.ordo.desktop.system.ReminderScheduler
import com.ordo.desktop.system.TrayNotifications
import com.ordo.desktop.system.WindowsAutoStart
import com.ordo.desktop.ui.common.OrdoInputFocus
import com.ordo.desktop.ui.shell.OrdoApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.Job
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
 *   本地文件仓储 → 共享核心引擎(首次启动写入演示数据)→ 视图模型 → 网络与同步 → 托盘/提醒 → 窗口
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
    application { desktopApp(args, selfTest) }
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
private fun ApplicationScope.desktopApp(args: Array<String>, selfTest: File? = null) {
    val appScope = remember { CoroutineScope(SupervisorJob() + Dispatchers.Default) }

    /* ---------------- 数据层:JSON 文件仓储(契约 §8) ---------------- */
    val dataDir = remember { resolveDataDir(args) }
    selfTestReport(selfTest, "step=data-dir dir=${dataDir.absolutePath}")
    val storage = remember { JsonFileStorage(dataDir) }
    val engine = remember { OrdoEngine(storage, SystemOrdoClock) }

    /* ---------------- 状态层 ---------------- */
    val vm = remember { OrdoViewModel(engine = engine, storage = storage, scope = appScope) }
    selfTestReport(selfTest, "step=engine ready todos=${engine.snapshot.todos.size}")

    /* ---------------- 窗口尺寸 / 位置记忆(04-UI规范 §3) ---------------- */
    val savedLayout = remember { loadWindowLayout(storage) }
    val windowState = rememberWindowState(
        size = savedLayout.size,
        position = savedLayout.position()
    )
    val windowRef = remember { mutableStateOf<ComposeWindow?>(null) }
    val persistWindowLayout: () -> Unit = {
        windowRef.value?.let { saveWindowLayout(storage, windowState.size, it.location) }
    }

    /* ---------------- 网络与同步(契约 §7.4 / §7.5) ---------------- */
    val client = remember { OrdoHttp.create() }
    val tokens = remember { TokenStore(storage) }
    val authApi = remember { KtorAuthApi(client, tokens) }
    val syncApi = remember { KtorSyncApi(client, tokens, engine.deviceId) }
    val realtime = remember { KtorRealtimeChannel(client, tokens) }

    val tray = remember {
        TrayNotifications(
            onOpenWindow = { /* 主窗口常驻,托盘双击由系统前置 */ },
            onQuit = {
                persistWindowLayout()
                exitApplication()
            },
            onOpenTodo = { id -> vm.selectTodo(id) }
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

    selfTestReport(selfTest, "step=network-ready headless=${runCatching { java.awt.GraphicsEnvironment.isHeadless() }.getOrDefault(true)}")

    LaunchedEffect(Unit) {
        // 账号与令牌注入设置页;登录成功后拉起同步与实时通道
        vm.authApi = authApi
        vm.tokens = tokens
        vm.onAuthChanged = { coordinator.onLoggedIn() }
        // 开机自启:真实实现写 HKCU\...\Run(拿不到 exe 路径时自动退化为不可用)
        vm.autoStart = WindowsAutoStart()
        vm.attachSync(coordinator)
        coordinator.start()
        tray.install()
        reminderJob.value = reminderScheduler.start()
        // 深链:ordo://today / ordo://project/<id> / ordo://todo/<id>
        DeepLink.fromArgs(args)?.let { target ->
            vm.navigate(target.route)
            target.todoId?.let { vm.selectTodo(it) }
        }
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

    // 自检兜底:窗口迟迟没建起来时也要落报告并退出,便于打包冒烟判定失败
    LaunchedEffect(selfTest) {
        if (selfTest == null) return@LaunchedEffect
        kotlinx.coroutines.delay(SELFTEST_TIMEOUT_MILLIS)
        selfTestReport(selfTest, "step=timeout windows=${windowRef.value != null}")
        exitApplication()
        return@LaunchedEffect
    }

    val state by vm.state.collectAsState()

    Window(
        onCloseRequest = {
            persistWindowLayout()
            exitApplication()
        },
        state = windowState,
        title = windowTitle(state, vm),
        onKeyEvent = { event -> handleShortcut(event, vm) }
    ) {
        LaunchedEffect(Unit) {
            windowRef.value = window
            window.minimumSize = Dimension(MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT)
            // 位置按像素精确恢复(Dp 在缩放屏上会漂移);越界时保持居中
            savedLayout.applyLocation(window)
            if (selfTest != null) {
                // 等窗口真正可见(首帧渲染完成):打包冒烟据此判定"界面起来了"
                var shown = false
                val start = System.currentTimeMillis()
                while (!shown && System.currentTimeMillis() - start < SELFTEST_TIMEOUT_MILLIS) {
                    withFrameNanos { }
                    shown = runCatching { window.isShowing }.getOrDefault(false)
                }
                selfTestReport(
                    selfTest,
                    "step=window showing=$shown waitedMs=${System.currentTimeMillis() - start} " +
                        "size=${window.width}x${window.height} at=${window.location.x},${window.location.y}"
                )
                kotlinx.coroutines.delay(SELFTEST_EXIT_DELAY_MILLIS)
                selfTestReport(selfTest, "step=done ok=$shown")
                exitApplication()
            }
        }
        OrdoApp(vm)
    }
}

/** 自检最长等待(毫秒)与窗口建好后的退出延迟 */
private const val SELFTEST_TIMEOUT_MILLIS = 20_000L
private const val SELFTEST_EXIT_DELAY_MILLIS = 1_500L

/** 窗口最小尺寸(04-UI规范 §3:480×640) */
private const val MIN_WINDOW_WIDTH = 480
private const val MIN_WINDOW_HEIGHT = 640
private const val KEY_WINDOW_W = "ordo.window.width"
private const val KEY_WINDOW_H = "ordo.window.height"
private const val KEY_WINDOW_X = "ordo.window.x"
private const val KEY_WINDOW_Y = "ordo.window.y"

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
    val width = storage.kvGet(KEY_WINDOW_W)?.toFloatOrNull() ?: 1180f
    val height = storage.kvGet(KEY_WINDOW_H)?.toFloatOrNull() ?: 760f
    val x = storage.kvGet(KEY_WINDOW_X)?.toIntOrNull()
    val y = storage.kvGet(KEY_WINDOW_Y)?.toIntOrNull()
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

private fun saveWindowLayout(storage: JsonFileStorage, size: DpSize, location: Point) {
    storage.kvSet(KEY_WINDOW_W, size.width.value.toInt().toString())
    storage.kvSet(KEY_WINDOW_H, size.height.value.toInt().toString())
    storage.kvSet(KEY_WINDOW_X, location.x.toString())
    storage.kvSet(KEY_WINDOW_Y, location.y.toString())
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
private fun handleShortcut(event: KeyEvent, vm: OrdoViewModel): Boolean {
    if (event.type != KeyEventType.KeyDown) return false

    if (event.isCtrlPressed) {
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
