package com.ordo.android.di

import android.app.Application
import android.content.Context
import com.ordo.android.data.SettingsStore
import com.ordo.android.data.SqliteStorage
import com.ordo.android.net.HttpClientFactory
import com.ordo.android.net.KtorSyncApi
import com.ordo.android.net.OrdoAuthApi
import com.ordo.android.net.RealtimeClient
import com.ordo.android.net.TokenStore
import com.ordo.android.notify.Notifier
import com.ordo.android.sync.SyncScheduler
import com.ordo.core.store.OrdoEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * 手工依赖装配（不引入 Hilt，保持依赖面最小）。
 *
 * 共享核心构造是同步的（`OrdoEngine(storage)` 内部从 storage 读快照），
 * 因此这里用 lazy 即可，无需异步初始化。
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
        // 首次启动写入演示数据（core 负责内容，force=false 时已有数据则跳过），契约 §8
        runCatching { engine.seedDemoData() }
        scheduler.start(applicationScope)
        scheduler.onNetworkAvailable = {
            applicationScope.launch { scheduler.syncOnce() }
        }
        if (tokens.isLoggedIn()) startRealtime()
        _ready.value = true
    }

    /* ------------------------------ 数据层 ------------------------------ */

    /**
     * 本地存储:原生 SQLite(实体按 JSON 快照整行存放,与服务端 entities 表同构,架构 ADR-004)。
     * 不依赖 Room/KSP,避免注解处理器与 Kotlin 版本强耦合带来的构建风险。
     */
    val storage: SqliteStorage by lazy { SqliteStorage(appContext) }

    val settings: SettingsStore by lazy { SettingsStore(appContext) }

    val tokens: TokenStore by lazy { TokenStore(storage) }

    /** deviceId 由共享核心生成并保存在 kv（契约 §7.2） */
    val engine: OrdoEngine by lazy { OrdoEngine(storage) }

    /* ------------------------------ 网络层 ------------------------------ */

    val httpClient by lazy { HttpClientFactory { engine.deviceId }.create() }

    val authApi: OrdoAuthApi by lazy { OrdoAuthApi(httpClient, tokens) }

    val syncApi: KtorSyncApi by lazy { KtorSyncApi(httpClient, tokens, authApi) }

    val realtime: RealtimeClient by lazy { RealtimeClient(httpClient, tokens, authApi) }

    /* ------------------------------ 其它 ------------------------------ */

    val notifier: Notifier by lazy { Notifier(appContext) }

    val scheduler: SyncScheduler by lazy {
        SyncScheduler(
            context = appContext,
            engine = engine,
            api = syncApi,
            auth = authApi,
            tokens = tokens,
            storage = storage,
            settings = settings,
        )
    }

    /** 登录成功后启动实时通道（契约 §7.5） */
    fun startRealtime() {
        realtime.start(
            scope = applicationScope,
            deviceId = engine.deviceId,
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
        realtime.close()
    }
}
