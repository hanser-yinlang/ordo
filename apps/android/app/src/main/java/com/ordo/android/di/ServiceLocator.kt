package com.ordo.android.di

import android.app.Application
import android.content.Context
import com.ordo.android.data.LocalAccount
import com.ordo.android.data.SettingsStore
import com.ordo.android.data.SqliteStorage
import com.ordo.android.data.UserDataDir
import com.ordo.android.notify.Notifier
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * 手工依赖装配（不引入 Hilt，保持依赖面最小）。
 *
 * **v1.4（产品决策：彻底删除云同步）后本应用是纯本地的**：没有任何网络客户端、
 * 没有会话/令牌、没有同步调度器与实时通道，因此也**不申请 INTERNET 权限**。
 *
 * 两层存储：
 * ```
 * 引导层 filesDir/ordo-bootstrap.db   本机设置类 kv：数据目录 id + 设备标识（打开工作区前就要读到）
 * 工作区 filesDir/<dirId>/ordo.db     实体 / outbox / 墓碑 / 本地游标（v1 单工作区，绝不与他人共用）
 * ```
 * [dirId] 是**本机钉住的标识**（契约 §7.6.6）：首次运行解析后写回 kv，此后永不改变；
 * 升级前已在用的目录继续沿用（不做迁移）。
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

        // ① 钉住本机数据目录 id，然后挂上本地工作区（纯本地：不发任何网络请求）
        val dirId = dataDirId
        runCatching { bindDataDir(dirId, seedIfEmpty = true) }

        _ready.value = true
    }

    /* ------------------------------ 引导层（本机 kv） ------------------------------ */

    /** 引导库：只放"打开工作区之前就要读到"的本机信息（目录 id / 设备标识） */
    val bootstrapStorage: SqliteStorage by lazy {
        SqliteStorage(appContext, UserDataDir.bootstrapDbFile(appContext.filesDir))
    }

    val settings: SettingsStore by lazy { SettingsStore(bootstrapStorage) }

    /** 设备标识：一台设备一个（离线生成后长期稳定），存在引导库（契约 §7.2 的本地等价物） */
    val deviceId: String by lazy {
        bootstrapStorage.kvGet(OrdoEngine.KEY_DEVICE_ID)?.takeIf { it.isNotBlank() }
            ?: ("dev_" + java.util.UUID.randomUUID().toString().replace("-", "").take(10)).also {
                bootstrapStorage.kvSet(OrdoEngine.KEY_DEVICE_ID, it)
            }
    }

    /**
     * 本机数据目录 id（契约 §7.6.6）：首次访问解析后**写进引导库钉住**，此后永不改变。
     *
     * 优先级见 [LocalAccount.resolve]：已钉住 > 唯一既有工作区目录 > 新生成 `local-<16hex>`。
     */
    val dataDirId: String by lazy {
        val pinned = bootstrapStorage.kvGet(LocalAccount.KEY_LOCAL_ACCOUNT_ID)
        val existing = runCatching { UserDataDir.existingDirIds(appContext.filesDir) }.getOrDefault(emptyList())
        val resolved = LocalAccount.resolve(pinned, existing)
            ?: LocalAccount.newId(java.util.UUID.randomUUID().toString().replace("-", ""))
        bootstrapStorage.kvSet(LocalAccount.KEY_LOCAL_ACCOUNT_ID, resolved)
        resolved
    }

    /* ------------------------------ 工作区层 ------------------------------ */

    @Volatile
    private var boundDataDirId: String? = null

    @Volatile
    private var workspaceStorageRef: SqliteStorage? = null

    @Volatile
    private var workspaceEngineRef: OrdoEngine? = null

    /** 还没挂上工作区时的占位引擎：纯内存、不落盘（任何误访问都不会污染工作区目录） */
    private val memoryFallback: OrdoEngine by lazy { OrdoEngine(InMemoryStorage(), deviceId = deviceId) }

    /** 当前挂着的本机数据目录 id；未绑定时 null */
    val activeDataDirId: String?
        get() = boundDataDirId

    val isBound: Boolean
        get() = boundDataDirId != null

    /** 当前工作区的本地库（提醒扫描等后台任务用）；未绑定时退化为引导库（其中没有待办） */
    val storage: SqliteStorage
        get() = workspaceStorageRef ?: bootstrapStorage

    /** 当前工作区的引擎；未绑定时是内存引擎 */
    val engine: OrdoEngine
        get() = workspaceEngineRef ?: memoryFallback

    /**
     * 绑定本机工作区：把本地数据目录切到 `filesDir/<dirId>/`。
     *
     * [dirId] 是**本机钉住的标识**（[dataDirId]），正常流程只在启动时绑定一次。
     * 幂等：同一 dirId 重复调用不会重开数据库、不会覆盖内存中的快照。
     *
     * @param seedIfEmpty 是否在绑定后做一次**播种判定**（启动时为 true）。
     *   判据交给引擎（`OrdoEngine.seedDemoData(force = false)`）：它同时看「库里有没有内容」与
     *   「这台机器播过种没有」（`kv[ordo.seedMark]`）。因此：
     *    - 全新安装 → 写演示数据；
     *    - **「清空本地数据」把标记一起清掉** → 下次冷启动自动回到有演示数据的全新状态；
     *    - 用户自己把待办逐条删空（标记还在）→ 不会被演示数据复活。
     *   （旧实现用「库文件在不在」当判据，清空后文件还在，于是重启只会看到空界面 —— 用户反馈过。）
     */
    @Synchronized
    fun bindDataDir(dirId: String, seedIfEmpty: Boolean = false): OrdoEngine {
        require(dirId.isNotBlank()) { "数据目录 id 不能为空：本地数据必须按工作区隔离" }
        workspaceEngineRef?.let { if (boundDataDirId == dirId) return it }

        if (boundDataDirId != null) unbindDataDir()   // 换工作区：先关旧句柄（其目录保留）

        val storage = SqliteStorage(appContext, UserDataDir.dbFileFor(appContext.filesDir, dirId))
        val engine = OrdoEngine(storage, deviceId = deviceId)
        boundDataDirId = dirId
        workspaceStorageRef = storage
        workspaceEngineRef = engine

        if (seedIfEmpty) {
            runCatching { engine.seedDemoData(force = false) }
        }
        return engine
    }

    /** 解绑工作区：关闭句柄；**目录与数据一律保留** */
    @Synchronized
    fun unbindDataDir() {
        workspaceStorageRef?.let { runCatching { it.close() } }
        workspaceStorageRef = null
        workspaceEngineRef = null
        boundDataDirId = null
    }

    /* ------------------------------ 其它（纯本地） ------------------------------ */

    val notifier: Notifier by lazy { Notifier(appContext) }
}
