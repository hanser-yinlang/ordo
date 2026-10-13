package com.ordo.android.di

import android.app.Application
import android.content.Context
import com.ordo.android.data.LocalAccount
import com.ordo.android.data.SettingsStore
import com.ordo.android.data.SqliteStorage
import com.ordo.android.data.UserDataDir
import com.ordo.android.auth.SilentSessionRules
import com.ordo.android.net.HttpClientFactory
import com.ordo.android.net.KtorSyncApi
import com.ordo.android.net.OrdoAuthApi
import com.ordo.android.net.RealtimeClient
import com.ordo.android.net.TokenStore
import com.ordo.android.notify.Notifier
import com.ordo.android.sync.SyncScheduler
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.sync.GuestAuthRequest
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.OrdoSessionStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File

/**
 * 手工依赖装配（不引入 Hilt，保持依赖面最小）。
 *
 * 两层存储（契约 §7.6.3 硬约束）：
 * ```
 * 引导层 filesDir/ordo-bootstrap.db   会话 + 服务器地址 + 设备标识（跨账号唯一，需要先于账号读到）
 * 账号层 filesDir/<userId>/ordo.db    实体 / outbox / 墓碑 / 同步游标（每个账号一份，绝不共用）
 * ```
 * v1.3（不再有登录界面）：**引导层必须保留**——「读会话」本身需要一份不属于任何账号的存储，
 * 设备标识也必须跨账号稳定；去掉它会造成"先有 userId 才能读 session、先有 session 才知道 userId"
 * 的循环依赖，而不是简化。改动只是：没有会话时不再有「未登录」这条界面路径，
 * 而是先挂**临时工作区** `filesDir/local-<deviceId>/`（离线可用），再静默建匿名账号后认领（改名）。
 */
object ServiceLocator {

    private lateinit var application: Application

    val applicationScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _ready = MutableStateFlow(false)
    val ready: StateFlow<Boolean> = _ready.asStateFlow()

    val appContext: Context
        get() = application.applicationContext

    fun init(app: Application) {
        application = app

        // ① 钉住本机数据目录 id（契约 §7.6.6）：与会话无关；首次运行生成并持久化，此后永不改变。
        //    升级场景（升级前已登录过）由 LocalAccount.resolve 沿用既有的服务端 userId 目录，不做迁移。
        val dirId = dataDirId
        val firstRun = !UserDataDir.dbFileFor(appContext.filesDir, dirId).exists()
        runCatching { bindDataDir(dirId, seedIfEmpty = firstRun) }

        // ② 同步调度：网络恢复时同步（未绑定时不发请求）
        scheduler.start(applicationScope)
        scheduler.onNetworkAvailable = {
            // 网络恢复：先把会话补上（首启离线时可能还没有），再同步
            ensureAnonymousSession()
            if (isBound && tokens.isLoggedIn()) applicationScope.launch { runCatching { scheduler.syncOnce() } }
        }
        // ③ 实时通道只在有会话时建立（契约 §7.5）
        val session = runCatching { sessions.load() }.getOrNull()
        if (session != null && tokens.isLoggedIn()) startRealtime()
        // ④ 没有可用会话：静默建匿名账号（不阻塞启动、不弹界面，失败按 1s→2s→…→60s 退避重试）
        if (session == null || !tokens.isLoggedIn()) ensureAnonymousSession()
        _ready.value = true
    }

    /* ------------------------------ 引导层 ------------------------------ */

    /** 引导库：会话（`kv["ordo.session"]`）与服务器地址 */
    val bootstrapStorage: SqliteStorage by lazy {
        SqliteStorage(appContext, UserDataDir.bootstrapDbFile(appContext.filesDir))
    }

    val sessions: OrdoSessionStore by lazy { OrdoSessionStore(bootstrapStorage) }

    val settings: SettingsStore by lazy { SettingsStore(appContext) }

    /** 会话/令牌读写：始终落在引导库（登录前也要能读） */
    val tokens: TokenStore by lazy { TokenStore(bootstrapStorage) }

    /** 设备标识：一台设备一个（跨账号一致），存在引导库（契约 §7.2） */
    val deviceId: String by lazy {
        bootstrapStorage.kvGet(OrdoEngine.KEY_DEVICE_ID)?.takeIf { it.isNotBlank() }
            ?: ("dev_" + java.util.UUID.randomUUID().toString().replace("-", "").take(10)).also {
                bootstrapStorage.kvSet(OrdoEngine.KEY_DEVICE_ID, it)
            }
    }

    /**
     * 本机数据目录 id（契约 §7.6.6）：首次运行解析后**写进引导库钉住**，此后
     * 静默建号 / 401 重建 / 续期等任何会话变化都**不再改动它**。
     *
     * 优先级见 [LocalAccount.resolve]：已钉住 > 升级前会话的 userId 目录 > 唯一既有目录 > 新生成。
     * 服务端 `userId` 只用于鉴权与同步，不参与目录选择。
     */
    val dataDirId: String by lazy {
        val pinned = bootstrapStorage.kvGet(LocalAccount.KEY_LOCAL_ACCOUNT_ID)
        val sessionUserId = runCatching { sessions.load() }.getOrNull()?.userId
        val existing = runCatching { UserDataDir.existingDirIds(appContext.filesDir) }.getOrDefault(emptyList())
        val resolved = LocalAccount.resolve(pinned, sessionUserId, existing)
            ?: LocalAccount.newId(java.util.UUID.randomUUID().toString().replace("-", ""))
        bootstrapStorage.kvSet(LocalAccount.KEY_LOCAL_ACCOUNT_ID, resolved)
        resolved
    }

    /* ------------------------- 静默匿名会话（v1.3） ------------------------- */

    private val _session = MutableStateFlow<OrdoSession?>(null)

    /** 静默建号成功后的会话：界面据此重新挂引擎并补一次同步（null = 还在重试） */
    val session: StateFlow<OrdoSession?> = _session.asStateFlow()

    private var bootstrapJob: Job? = null

    /**
     * 静默建匿名账号（**没有登录界面**）：没有可用会话、或服务端否认了旧会话时调用。
     *
     * 在 applicationScope 里按 1s→2s→…→60s 退避重试，直到拿到会话；不阻塞启动、不弹任何界面。
     * 已经在重试时重复调用是空操作。
     *
     * @param replaceExisting true = 先丢掉当前（已被服务端否认的）会话再建新的
     */
    fun ensureAnonymousSession(replaceExisting: Boolean = false) {
        if (bootstrapJob?.isActive == true) return
        bootstrapJob = applicationScope.launch {
            if (replaceExisting) runCatching { tokens.clearSession() }
            var attempt = 0
            while (isActive) {
                if (tokens.isLoggedIn()) {
                    onSessionReady()
                    return@launch
                }
                val created = runCatching {
                    authApi.guest(
                        GuestAuthRequest(
                            deviceId = deviceId,
                            deviceName = deviceName(),
                            platform = PLATFORM,
                        ),
                    )
                }.isSuccess
                if (created) {
                    onSessionReady()
                    return@launch
                }
                delay(SilentSessionRules.backoffMillis(attempt))
                attempt++
            }
        }
    }

    /**
     * 会话就绪（静默建号成功 / 续期成功）：起实时通道 → 通知界面补一次同步。
     *
     * **不切换本地数据目录**（契约 §7.6.6）：目录 id 是本机钉住的，会话重建只换令牌。
     */
    private fun onSessionReady() {
        val session = runCatching { sessions.load() }.getOrNull() ?: return
        startRealtime()
        _session.value = session
    }

    private fun deviceName(): String =
        runCatching { "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim() }
            .getOrDefault("Android 设备")

    private const val PLATFORM = "android"

    /* ------------------------------ 工作区层 ------------------------------ */

    @Volatile
    private var boundDataDirId: String? = null

    @Volatile
    private var userStorageRef: SqliteStorage? = null

    @Volatile
    private var userEngineRef: OrdoEngine? = null

    /** 实时通道是否已启动（避免为了关闭而提前实例化 Ktor/OkHttp） */
    @Volatile
    private var realtimeStarted = false

    /** 还没挂上工作区时的占位引擎：纯内存、不落盘（任何误访问都不会污染工作区目录） */
    private val memoryFallback: OrdoEngine by lazy { OrdoEngine(InMemoryStorage(), deviceId = deviceId) }

    /** 当前挂着的本机数据目录 id；未绑定时 null */
    val activeDataDirId: String?
        get() = boundDataDirId

    val isBound: Boolean
        get() = boundDataDirId != null

    /** 当前工作区的本地库（提醒扫描等后台任务用）；未绑定时退化为引导库（其中没有待办） */
    val storage: SqliteStorage
        get() = userStorageRef ?: bootstrapStorage

    /** 当前工作区的引擎；未绑定时是内存引擎 */
    val engine: OrdoEngine
        get() = userEngineRef ?: memoryFallback

    /**
     * 绑定本机工作区：把本地数据目录切到 `filesDir/<dirId>/`（契约 §7.6.3 / §7.6.6）。
     *
     * [dirId] 是**本机钉住的标识**（[dataDirId]），不是服务端 userId；
     * 正常流程只在启动时绑定一次，会话重建不会调用它。
     *
     * 幂等：同一 dirId 重复调用不会重开数据库、不会覆盖内存中的快照。
     *
     * @param seedIfEmpty 仅在「首次运行且本地无数据」时写演示数据（契约 §7.6.3）。
     */
    @Synchronized
    fun bindDataDir(dirId: String, seedIfEmpty: Boolean = false): OrdoEngine {
        require(dirId.isNotBlank()) { "数据目录 id 不能为空：本地数据必须按工作区隔离" }
        userEngineRef?.let { if (boundDataDirId == dirId) return it }

        if (boundDataDirId != null) unbindDataDir()   // 换工作区：先关旧句柄（其目录保留）

        val storage = SqliteStorage(appContext, UserDataDir.dbFileFor(appContext.filesDir, dirId))
        val engine = OrdoEngine(storage, deviceId = deviceId)
        boundDataDirId = dirId
        userStorageRef = storage
        userEngineRef = engine

        if (seedIfEmpty && storage.loadSnapshot() == null) {
            runCatching { engine.seedDemoData() }
        }
        return engine
    }

    /** 解绑工作区：停实时通道、关闭句柄；**目录与数据一律保留**（契约 §7.6.3） */
    @Synchronized
    fun unbindDataDir() {
        stopRealtime()
        userStorageRef?.let { runCatching { it.close() } }
        userStorageRef = null
        userEngineRef = null
        boundDataDirId = null
    }

    /* ------------------------------ 网络层 ------------------------------ */

    val httpClient by lazy { HttpClientFactory { deviceId }.create() }

    val authApi: OrdoAuthApi by lazy { OrdoAuthApi(httpClient, tokens) }

    val syncApi: KtorSyncApi by lazy { KtorSyncApi(httpClient, tokens, authApi) }

    val realtime: RealtimeClient by lazy { RealtimeClient(httpClient, tokens, authApi) }

    /* ------------------------------ 其它 ------------------------------ */

    val notifier: Notifier by lazy { Notifier(appContext) }

    val scheduler: SyncScheduler by lazy {
        SyncScheduler(
            context = appContext,
            engine = { engine },
            api = syncApi,
            auth = authApi,
            tokens = tokens,
            storage = { storage },
            settings = settings,
        )
    }

    /** 会话就绪后启动实时通道（契约 §7.5） */
    fun startRealtime() {
        if (!isBound) return
        realtimeStarted = true
        realtime.start(
            scope = applicationScope,
            deviceId = deviceId,
            onOps = { ops, serverSeq ->
                runCatching { engine.applyRemote(ops) }
                if (serverSeq > engine.lastServerSeq()) engine.setLastServerSeq(serverSeq)
            },
            onReminder = { push ->
                // 快车道：服务端推来的提醒立即本地弹出
                notifier.notifyReminder(push.todoId, push.title, push.at)
            },
        )
    }

    fun stopRealtime() {
        if (!realtimeStarted) return
        realtimeStarted = false
        realtime.close()
    }
}
