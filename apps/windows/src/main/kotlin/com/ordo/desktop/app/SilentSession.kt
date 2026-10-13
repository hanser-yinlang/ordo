package com.ordo.desktop.app

import com.ordo.core.sync.GuestAuthRequest
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.OrdoSessionStore
import com.ordo.desktop.net.SilentAuthApi
import com.ordo.desktop.net.TokenStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 启动时该拿哪种会话(纯判定,不碰网络 —— 因此可以逐条断言)。
 */
enum class SessionAction {
    /** 本地会话还在有效期内:直接用,一次网络请求都不发 */
    USE_SESSION,

    /** 会话过期:先静默 refresh,失败再退到 [CREATE_ANONYMOUS] */
    REFRESH_SESSION,

    /** 没有会话(全新安装 / 本地被清):静默建匿名账号 */
    CREATE_ANONYMOUS
}

/**
 * 静默匿名会话的规则与常量(产品决策:不再需要登录)。
 *
 * 时序(全部在后台,不弹界面、不阻塞启动):
 * ```
 * 读 kv[ordo.session]
 *   ├─ 有效            → 直接用
 *   ├─ 已过期          → 静默 refresh ─┬─ 成功 → 用新会话
 *   │                                  └─ 失败 → 静默 POST /v1/auth/guest
 *   └─ 没有            → 静默 POST /v1/auth/guest
 *
 * 上面任一步"网络不可达" → 照常进主界面(离线可用),按退避在后台重试,直到拿到会话
 * ```
 */
object SilentSession {

    /** 匿名账号的设备信息(契约 §7.6.2:游客登录也要带 deviceName/platform) */
    const val DEVICE_NAME = "Ordo Windows"
    const val PLATFORM = "windows"

    /** 后台重试的退避上限:1s → 2s → 4s → … 最多 60s */
    const val MAX_BACKOFF_MILLIS = 60_000L

    /** 该走哪条路(纯函数:给定会话与当前时刻,给出落点) */
    fun actionFor(session: OrdoSession?, nowMillis: Long): SessionAction = when {
        session == null -> SessionAction.CREATE_ANONYMOUS
        session.isExpired(nowMillis) -> SessionAction.REFRESH_SESSION
        else -> SessionAction.USE_SESSION
    }

    /** 第 [attempt] 次失败后的等待时长(attempt 从 1 起) */
    fun backoffMillis(attempt: Int): Long =
        (1_000L shl (attempt - 1).coerceIn(0, 6)).coerceAtMost(MAX_BACKOFF_MILLIS)

    /** 会话失效时的提示口径(只用于日志与自检报告,不进界面) */
    fun describe(session: OrdoSession?): String =
        session?.let { "user=${it.userId} dir=${OrdoSessionStore.userDataDirName(it.userId)}" } ?: "none"
}

/**
 * 会话的"静默恢复"能力 —— 同步协调器只依赖这一个窄接口,
 * 因此它可以被假实现直接替换(测试不需要网络),也不需要知道"登录"这件事。
 */
interface SessionRecovery {

    /** 会话失效(同步 401)时静默重建:先 refresh,失败再建匿名账号。返回是否已有可用会话 */
    suspend fun recover(): Boolean

    /** 等到有可用会话为止(静默会话守护在后台重试);拿到返回 true */
    suspend fun awaitSession(): Boolean

    companion object {
        /** 不做任何恢复(仅测试 / 不需要同步的场景) */
        val NONE: SessionRecovery = object : SessionRecovery {
            override suspend fun recover(): Boolean = false
            override suspend fun awaitSession(): Boolean = false
        }
    }
}

/**
 * 静默会话守护:后台保证"总有可用会话"。
 *
 * 三条硬约束:
 * 1. **不阻塞启动**:[start] 只是起一个协程,界面立刻可用(哪怕此刻在离线);
 * 2. **不弹界面**:失败只有退避重试,没有任何界面/对话框/退出路径;
 * 3. **不丢本地数据**:会话只是同步用的凭据,数据目录由入口用钉住的 id 决定(见
 *    [com.ordo.desktop.data.UserDataDirs.resolveDataDirId]),重建匿名会话不会换目录。
 *
 * @param sleeper 退避用的等待函数(测试注入即时返回,避免真等 1s/2s…)
 */
class SilentSessionKeeper(
    private val api: SilentAuthApi,
    private val tokens: TokenStore,
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
    private val deviceName: String = SilentSession.DEVICE_NAME,
    private val platform: String = SilentSession.PLATFORM,
    private val sleeper: suspend (Long) -> Unit = { delay(it) },
    /** 每次拿到会话时的回调(入口用于写自检报告;后台线程调用) */
    private val onSession: (OrdoSession) -> Unit = {}
) : SessionRecovery {

    private var job: Job? = null

    /** 第一次拿到会话时完成:同步协调器据此"等到会话再连实时通道 / 再同步一次" */
    private val ready = CompletableDeferred<Unit>()

    /** [onSession] 每实例最多回调一次(重复 start / ensure 不该重复通知) */
    private val notified = AtomicBoolean(false)

    /** 当前是否已有可用会话(有 token 即视为可用,过期由 [ensure] 处理) */
    val hasSession: Boolean get() = tokens.hasSession

    /**
     * 启动后台守护:立刻尝试一次,失败则按 [SilentSession.backoffMillis] 退避重试,拿到会话即收工。
     *
     * **幂等**:只要起过就复用同一个 Job —— 否则在 `Dispatchers.Unconfined` 这类"同步跑完"的调度器下,
     * 已完成的 Job 不再 `isActive`,第二次调用会再起一个重试循环(真实场景里就是重复请求 + 重复回调)。
     * `stop()` 会把 Job 清空,所以停掉之后仍然可以重新 [start]。
     */
    fun start(): Job {
        if (tokens.hasSession) completeReady()
        job?.let { return it }
        val started = scope.launch {
            var attempt = 0
            while (isActive) {
                if (ensure()) return@launch
                attempt += 1
                sleeper(SilentSession.backoffMillis(attempt))
            }
        }
        job = started
        return started
    }

    fun stop() {
        job?.cancel()
        job = null
    }

    /**
     * 一次完整尝试:直接用 / refresh / 建匿名。任何异常都吞掉并返回 false
     * (调用方是后台重试循环,不需要也不应该向上抛)。
     */
    suspend fun ensure(): Boolean = runCatching { attempt() }.getOrElse { false }

    private suspend fun attempt(): Boolean {
        val session = tokens.currentSession()
        return when (SilentSession.actionFor(session, now())) {
            SessionAction.USE_SESSION -> {
                markReady(session!!)
                true
            }
            SessionAction.REFRESH_SESSION -> {
                val refreshed = runCatching { api.refresh(session!!.refreshToken) }.getOrNull()
                if (refreshed != null) {
                    tokens.save(refreshed, now())
                    markReady(tokens.currentSession())
                    true
                } else {
                    // 过期且刷不动(令牌被吊销 / 服务端不认):静默换一个匿名账号,不打扰用户
                    createAnonymous()
                }
            }
            SessionAction.CREATE_ANONYMOUS -> createAnonymous()
        }
    }

    /**
     * 静默建匿名账号(契约 §7.6.2:`/v1/auth/guest` 返回的是**正常令牌**,
     * 数据同样入库、同样多端同步 —— 不是"受限模式")。
     */
    suspend fun createAnonymous(): Boolean = runCatching {
        val response = api.guest(GuestAuthRequest(deviceName = deviceName, platform = platform))
        tokens.save(response, now())
        markReady(tokens.currentSession())
        true
    }.getOrElse { false }

    /** 同步遇 401:静默重建会话(先 refresh,失败再建匿名) */
    override suspend fun recover(): Boolean = runCatching {
        val session = tokens.currentSession()
        val refreshed = session?.let { runCatching { api.refresh(it.refreshToken) }.getOrNull() }
        if (refreshed != null) {
            tokens.save(refreshed, now())
            markReady(tokens.currentSession())
            true
        } else {
            createAnonymous()
        }
    }.getOrElse { false }

    override suspend fun awaitSession(): Boolean {
        if (tokens.hasSession) return true
        ready.await()
        return true
    }

    /**
     * 会话就位:放行 [awaitSession],并**只通知一次** [onSession]。
     *
     * 一次性标记是必要的:`ensure()` 可能被直接调用(测试、401 恢复、重复 start),
     * 而入口用 [onSession] 写自检报告 —— 重复通知会让报告里出现多条 "session ready"。
     */
    private fun markReady(session: OrdoSession?) {
        if (session == null) return
        completeReady()
        if (!notified.compareAndSet(false, true)) return
        runCatching { onSession(session) }
    }

    private fun completeReady() {
        if (!ready.isCompleted) ready.complete(Unit)
    }
}
