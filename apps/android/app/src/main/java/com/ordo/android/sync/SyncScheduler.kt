package com.ordo.android.sync

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import com.ordo.android.data.SettingsStore
import com.ordo.android.data.SqliteStorage
import com.ordo.android.net.KtorSyncApi
import com.ordo.android.net.OrdoAuthApi
import com.ordo.android.net.OrdoErrors
import com.ordo.android.net.TokenStore
import com.ordo.core.store.OrdoEngine
import com.ordo.core.sync.SyncEngine
import com.ordo.core.sync.SyncResult
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** 同步状态（状态栏展示，04 文档 §3） */
enum class SyncState {
    IDLE,
    SYNCING,
    OFFLINE,
    FAILED,
    NOT_LOGGED_IN,
}

/**
 * 同步调度：三个触发源
 *   1. 应用在前台时每 30 秒一次
 *   2. 回到前台立即一次
 *   3. 网络恢复立即一次
 *
 * 真正的同步动作委托给共享核心的 [SyncEngine]（push outbox → 应用捎带 ops → 循环 pull，
 * 幂等与冲突合并全部由 core 负责，契约 §7.3）。
 *
 * [engine] 与 [storage] 用**取值函数**而不是实例：本地数据目录按账号隔离（契约 §7.6.3），
 * 换账号/退出登录会重新绑定目录，调度器必须每次取当前账号的那一份。
 */
class SyncScheduler(
    private val context: Context,
    private val engine: () -> OrdoEngine,
    private val api: KtorSyncApi,
    private val auth: OrdoAuthApi,
    private val tokens: TokenStore,
    private val storage: () -> SqliteStorage,
    private val settings: SettingsStore,
) {

    private val _state = MutableStateFlow(SyncState.IDLE)
    val state: StateFlow<SyncState> = _state.asStateFlow()

    private val _lastResult = MutableStateFlow<SyncResult?>(null)
    val lastResult: StateFlow<SyncResult?> = _lastResult.asStateFlow()

    private var loopJob: Job? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var foreground = false

    /** 由 ServiceLocator 注入：网络恢复时触发的动作 */
    var onNetworkAvailable: (() -> Unit)? = null

    fun start(scope: CoroutineScope) {
        if (loopJob?.isActive == true) return
        registerNetworkCallback()
        loopJob = scope.launch {
            while (isActive) {
                delay(FOREGROUND_INTERVAL_MILLIS)
                if (foreground) syncOnce()
            }
        }
    }

    fun stop() {
        loopJob?.cancel()
        loopJob = null
        unregisterNetworkCallback()
    }

    fun onForeground() {
        foreground = true
    }

    fun onBackground() {
        foreground = false
    }

    fun syncOnResume(scope: CoroutineScope) {
        foreground = true
        scope.launch { syncOnce() }
    }

    fun isOnline(): Boolean {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return true
        val network = manager.activeNetwork ?: return false
        val capabilities = manager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    /** 单次同步；调用于前台轮询 / 回前台 / 网络恢复 / 状态栏刷新键 / 下拉刷新 */
    suspend fun syncOnce(): SyncState {
        if (!tokens.isLoggedIn()) {
            _state.value = SyncState.NOT_LOGGED_IN
            return SyncState.NOT_LOGGED_IN
        }
        if (!isOnline()) {
            _state.value = SyncState.OFFLINE
            return SyncState.OFFLINE
        }
        _state.value = SyncState.SYNCING
        // 退出登录会关闭账号库句柄：正在跑的同步可能抛异常。
        // 这里兜底成 FAILED（而不是让异常穿出去把状态永久留在 SYNCING —— 那样刷新图标会一直转）。
        val result = try {
            SyncEngine(engine(), api, pullLimit = KtorSyncApi.MAX_PULL_LIMIT).syncOnce()
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            _lastResult.value = null
            _state.value = SyncState.FAILED
            return SyncState.FAILED
        }
        _lastResult.value = result

        // 契约 §7.4：SYNC_SEQ_GAP 表示本地游标与服务端断档 → 退回全量快照
        if (!result.ok && OrdoErrors.needsFullResync(OrdoErrors.codeOf(result.error))) {
            return fullResync()
        }

        _state.value = when {
            result.ok -> SyncState.IDLE
            OrdoErrors.isAuthFailure(OrdoErrors.codeOf(result.error)) -> SyncState.NOT_LOGGED_IN
            else -> SyncState.FAILED
        }
        if (result.ok) {
            runCatching { settings.setLastSyncAt(System.currentTimeMillis()) }
        }
        return _state.value
    }

    /** 换设备 / 数据修复 / SEQ_GAP 恢复：用服务端快照整表替换（本地 outbox 保留） */
    suspend fun fullResync(): SyncState {
        _state.value = SyncState.SYNCING
        val result = SyncEngine(engine(), api, pullLimit = KtorSyncApi.MAX_PULL_LIMIT).fullResync()
        _lastResult.value = result
        _state.value = if (result.ok) SyncState.IDLE else SyncState.FAILED
        return _state.value
    }

    suspend fun outboxCount(): Int = runCatching { storage().outboxCount() }.getOrDefault(0)

    private fun registerNetworkCallback() {
        if (networkCallback != null) return
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                onNetworkAvailable?.invoke()
            }
        }
        runCatching { manager.registerDefaultNetworkCallback(callback) }
        networkCallback = callback
    }

    private fun unregisterNetworkCallback() {
        val callback = networkCallback ?: return
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        runCatching { manager?.unregisterNetworkCallback(callback) }
        networkCallback = null
    }

    companion object {
        const val FOREGROUND_INTERVAL_MILLIS = 30_000L
        const val TAG = "ordo-sync"
    }
}
