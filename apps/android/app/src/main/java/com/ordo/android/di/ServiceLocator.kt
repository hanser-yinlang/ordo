package com.ordo.android.di

import android.app.Application
import android.content.Context
import com.ordo.android.data.SettingsStore
import com.ordo.android.data.SqliteStorage
import com.ordo.android.data.UserDataDir
import com.ordo.android.net.HttpClientFactory
import com.ordo.android.net.KtorSyncApi
import com.ordo.android.net.OrdoAuthApi
import com.ordo.android.net.RealtimeClient
import com.ordo.android.net.TokenStore
import com.ordo.android.notify.Notifier
import com.ordo.android.sync.SyncScheduler
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.sync.OrdoSessionStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File

/**
 * 手工依赖装配（不引入 Hilt，保持依赖面最小）。
 *
 * 两层存储（契约 §7.6.3 硬约束）：
 * ```
 * 引导层 filesDir/ordo-bootstrap.db   会话 + 服务器地址 + 设备标识（跨账号唯一，登录前就要读）
 * 账号层 filesDir/<userId>/ordo.db    实体 / outbox / 墓碑 / 同步游标（每个账号一份，绝不共用）
 * ```
 * 未登录时不打开任何账号目录：[engine] 退化为**纯内存**引擎（不落盘、不种演示数据、不参与同步），
 * 于是"登录前"这条路径上不可能把 A 的数据写进 B 的目录。
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

        // ① 有会话就先挂载该账号的本地目录（离线可用，不发任何网络请求；退出登录后目录保留）
        val session = runCatching { sessions.load() }.getOrNull()
        if (session != null && session.userId.isNotBlank()) {
            runCatching { bindUser(session.userId, seedIfEmpty = false) }
        }

        // ② 同步调度：网络恢复时同步（未绑定时不发请求）
        scheduler.start(applicationScope)
        scheduler.onNetworkAvailable = {
            if (isBound) applicationScope.launch { runCatching { scheduler.syncOnce() } }
        }
        // ③ 实时通道只在有会话时建立（契约 §7.5）
        if (session != null) startRealtime()
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

    /* ------------------------------ 账号层 ------------------------------ */

    @Volatile
    private var boundUserId: String? = null

    @Volatile
    private var userStorageRef: SqliteStorage? = null

    @Volatile
    private var userEngineRef: OrdoEngine? = null

    /** 实时通道是否已启动（避免为了关闭而提前实例化 Ktor/OkHttp） */
    @Volatile
    private var realtimeStarted = false

    /** 未登录时的占位引擎：纯内存、不落盘（任何误访问都不会污染账号目录） */
    private val memoryFallback: OrdoEngine by lazy { OrdoEngine(InMemoryStorage(), deviceId = deviceId) }

    val activeUserId: String?
        get() = boundUserId

    val isBound: Boolean
        get() = boundUserId != null

    /** 当前账号的数据目录 `filesDir/<userId>/`；未绑定时 null */
    fun userDir(userId: String? = boundUserId): File? =
        userId?.takeIf { it.isNotBlank() }?.let { UserDataDir.dirFor(appContext.filesDir, it) }

    /** 当前账号的本地库（提醒扫描等后台任务用）；未绑定时退化为引导库（其中没有待办） */
    val storage: SqliteStorage
        get() = userStorageRef ?: bootstrapStorage

    /** 当前账号的引擎；未登录时是内存引擎 */
    val engine: OrdoEngine
        get() = userEngineRef ?: memoryFallback

    /**
     * 绑定账号：把本地数据目录切到 `filesDir/<userId>/`（契约 §7.6.3）。
     *
     * 幂等：同一 userId 重复调用不会重开数据库、不会覆盖内存中的快照。
     * 换账号：先把旧账号解绑（关闭句柄，**保留其目录**），再挂新目录。
     *
     * @param seedIfEmpty 仅在「首次登录某账号且本地无数据」时写演示数据（契约 §7.6.3）；
     *   启动恢复会话时传 false —— 本地为空应该等服务端快照，而不是先造一批演示数据再推上去。
     */
    @Synchronized
    fun bindUser(userId: String, seedIfEmpty: Boolean = false): OrdoEngine {
        require(userId.isNotBlank()) { "userId 不能为空：数据目录必须按账号隔离" }
        userEngineRef?.let { if (boundUserId == userId) return it }

        if (boundUserId != null) unbindUser()   // 换账号：先关旧句柄（其目录保留）

        val storage = SqliteStorage(appContext, UserDataDir.dbFileFor(appContext.filesDir, userId))
        val engine = OrdoEngine(storage, deviceId = deviceId)
        boundUserId = userId
        userStorageRef = storage
        userEngineRef = engine

        if (seedIfEmpty && storage.loadSnapshot() == null) {
            runCatching { engine.seedDemoData() }
        }
        return engine
    }

    /** 解绑（退出登录）：停实时通道、关闭句柄；**目录与数据一律保留**（契约 §7.6.3） */
    @Synchronized
    fun unbindUser() {
        stopRealtime()
        userStorageRef?.let { runCatching { it.close() } }
        userStorageRef = null
        userEngineRef = null
        boundUserId = null
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

    /** 登录成功后启动实时通道（契约 §7.5） */
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
