package com.ordo.desktop.sync

import com.ordo.core.model.Op
import com.ordo.core.store.OrdoEngine
import com.ordo.core.sync.AuthApi
import com.ordo.core.sync.OrdoApiException
import com.ordo.core.sync.RealtimeChannel
import com.ordo.core.sync.ReminderPush
import com.ordo.core.sync.SyncApi
import com.ordo.core.sync.SyncEngine
import com.ordo.core.sync.SyncResult
import com.ordo.desktop.net.TokenStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * 桌面端同步调度(契约 §7.1)。
 *
 * - 启动后立即同步一次,之后每 30 秒一次;
 * - 任何写操作后 2 秒防抖触发一次(界面调用 [requestSync]);
 * - 401 自动 refresh 并重放一次;refresh 失败则转离线但保留本地数据(契约 §7.4);
 * - 实时通道的 ops 直接 `applyRemote`,提醒走 Fastlane 回调。
 */
class SyncCoordinator(
    private val engine: OrdoEngine,
    private val syncApi: SyncApi,
    private val authApi: AuthApi,
    private val tokens: TokenStore,
    private val realtime: RealtimeChannel?,
    private val scope: CoroutineScope,
    private val onRemoteReminder: (ReminderPush) -> Unit = {},
    private val periodicMillis: Long = 30_000L,
    private val debounceMillis: Long = 2_000L
) {

    /**
     * 每次同步结束的监听者(多窗口:每个窗口的视图模型各订阅一份,状态栏各自更新)。
     */
    private val resultListeners = mutableListOf<(SyncResult) -> Unit>()

    fun addResultListener(listener: (SyncResult) -> Unit) {
        if (!resultListeners.contains(listener)) resultListeners.add(listener)
    }

    fun removeResultListener(listener: (SyncResult) -> Unit) {
        resultListeners.remove(listener)
    }

    private fun publish(result: SyncResult) = resultListeners.toList().forEach { it(result) }

    private val syncEngine = SyncEngine(engine, syncApi)

    private var tickerJob: Job? = null
    private var debounceJob: Job? = null
    private var realtimeJob: Job? = null

    /** 最近一次同步的错误(成功即清空),供设置页「同步诊断」展示 */
    private var lastError: String? = null

    val isLoggedIn: Boolean get() = tokens.isLoggedIn

    fun start() {
        stop()
        tickerJob = scope.launch {
            while (isActive) {
                if (tokens.isLoggedIn) syncOnce()
                delay(periodicMillis)
            }
        }
        realtimeJob = scope.launch {
            realtime?.connect(
                deviceId = engine.deviceId,
                onOps = { ops, seq -> applyRemote(ops, seq) },
                onReminder = { push -> onRemoteReminder(push) }
            )
        }
        if (tokens.isLoggedIn) requestSync(immediate = true)
    }

    fun stop() {
        tickerJob?.cancel(); tickerJob = null
        debounceJob?.cancel(); debounceJob = null
        realtimeJob?.cancel(); realtimeJob = null
        runCatching { realtime?.close() }
    }

    /** 写操作后调用:2 秒防抖合并多次写 */
    fun requestSync(immediate: Boolean = false) {
        if (!tokens.isLoggedIn) return
        debounceJob?.cancel()
        debounceJob = scope.launch {
            if (!immediate) delay(debounceMillis)
            syncOnce()
        }
    }

    suspend fun syncOnce(): SyncResult {
        var result = syncEngine.syncOnce()

        // 401:刷新令牌后重放一次(契约 §7.4)
        if (!result.ok && codeOf(result.error) in AUTH_CODES) {
            result = runCatching {
                val refreshed = authApi.refresh(tokens.refreshToken ?: return@runCatching result)
                tokens.save(refreshed)
                syncEngine.syncOnce()
            }.getOrElse { error ->
                SyncResult(ok = false, error = error.message ?: "refresh failed")
            }
        }

        // 序号缺口:退回全量快照重建(契约 §7.4 SYNC_SEQ_GAP)
        if (!result.ok && codeOf(result.error) == "SYNC_SEQ_GAP") {
            result = runCatching { syncEngine.fullResync() }
                .getOrElse { error -> SyncResult(ok = false, error = error.message ?: "full resync failed") }
        }

        // 限流:本轮放弃,交由下一次周期触发(指数退避由 ticker 的节奏承担)
        if (!result.ok && codeOf(result.error) == "RATE_LIMITED") {
            delay(RATE_LIMIT_BACKOFF_MILLIS)
        }

        lastError = if (result.ok) null else (result.error ?: "未知错误")
        publish(result)
        return result
    }

    private fun codeOf(error: String?): String? = error?.substringBefore(':')?.trim()?.takeIf { it.isNotEmpty() }

    /** 错误码 → 客户端处置(契约 §7.4 全量错误码) */
    @Suppress("unused")
    private fun handlingOf(code: String): String = when (code) {
        "AUTH_REQUIRED", "AUTH_TOKEN_EXPIRED" -> "刷新令牌并重放一次"
        "AUTH_INVALID_CREDENTIALS", "AUTH_EMAIL_TAKEN" -> "提示用户重新登录 / 更换邮箱"
        "SYNC_SEQ_GAP" -> "全量快照重建"
        "SYNC_OP_TOO_LARGE" -> "该批次已被服务端拒绝,已从 outbox 出队并提示用户"
        "VALIDATION_FAILED" -> "客户端或数据版本不兼容:提示升级,并保留本地数据"
        "RATE_LIMITED" -> "退避后重试"
        "NOT_FOUND" -> "目标实体已被删除,丢弃该 op"
        else -> "记录错误并在状态栏提示"
    }

    private fun applyRemote(ops: List<Op>, serverSeq: Long) {
        val applied = engine.applyRemote(ops)
        if (serverSeq > 0) engine.setLastServerSeq(maxOf(engine.lastServerSeq(), serverSeq))
        if (applied > 0) publish(SyncResult(ok = true, pulled = applied, serverSeq = engine.lastServerSeq()))
    }

    /** 登录成功后调用:建立实时通道并做一次全量同步 */
    fun onLoggedIn() {
        start()
    }

    /** 退出登录:停止同步并清空令牌(本地数据保留,契约 §7.4) */
    fun onLoggedOut() {
        stop()
        tokens.clear()
    }

    /** 换设备/数据修复 */
    suspend fun fullResync(): SyncResult {
        val result = syncEngine.fullResync()
        publish(result)
        return result
    }

    /** 供设置页展示:待推送 op 数 */
    fun pendingOps(): Int = engine.pendingOpCount()

    fun lastServerSeq(): Long = engine.lastServerSeq()

    /** 最近一次同步失败的原因(成功一次即清空);「同步诊断」面板的"上次错误" */
    fun currentError(): String? = lastError

    companion object {
        /** 需要"刷新令牌 + 重放"的错误码 */
        private val AUTH_CODES = setOf("AUTH_TOKEN_EXPIRED", "AUTH_REQUIRED")

        /** 被限流后的退避时长(下一次周期触发前不再打服务端) */
        private const val RATE_LIMIT_BACKOFF_MILLIS = 15_000L

        fun isAuthError(t: Throwable): Boolean = t is OrdoApiException &&
            (t.code == "AUTH_TOKEN_EXPIRED" || t.code == "AUTH_REQUIRED")
    }
}
