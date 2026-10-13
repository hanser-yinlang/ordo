package com.ordo.android.auth

import com.ordo.android.net.OrdoAuthError
import com.ordo.android.net.OrdoErrors
import com.ordo.core.sync.OrdoApiException
import com.ordo.core.sync.OrdoSession

/* ============================================================================
 * 静默匿名会话（产品决策 v1.3：应用不再有登录界面）
 *
 * 启动时只有三种处置：
 *   ① 现有会话可用            → 直接进主界面（后台静默 refresh）；
 *   ② accessToken 过期        → 先 refresh；成功用新会话，失败按 ③ 或继续离线；
 *   ③ 没有会话 / 会话被否认   → **静默** POST /v1/auth/guest 建匿名账号并保存。
 *
 * 任何分支都直接进主界面：网络不可达也照常离线可用，由后台退避重试补会话。
 * 这里全部是纯逻辑（不依赖 Android 框架），可直接跑 JVM 单测。
 * ========================================================================== */

/** 启动时的会话处置 */
sealed interface SessionPlan {

    /** 现有会话可直接用（顺带后台静默 refresh） */
    data class UseExisting(
        val session: OrdoSession,
        val silentRefresh: Boolean = true,
    ) : SessionPlan

    /** accessToken 已过期：先 refresh 再决定（refresh 失败也不回登录页） */
    data class RefreshFirst(val session: OrdoSession) : SessionPlan

    /** 没有会话（或会话残缺）：静默建匿名账号 */
    data object CreateAnonymous : SessionPlan
}

object SilentSessionRules {

    /** 退避起点 1s、上限 60s（与实时通道重连同量级） */
    const val INITIAL_BACKOFF_MILLIS = 1_000L
    const val MAX_BACKOFF_MILLIS = 60_000L

    /**
     * 启动处置（与旧登录门禁同源，只是「无会话」不再去登录页，而是静默建号）。
     *
     * @param session [com.ordo.core.sync.OrdoSessionStore.load] 的结果
     * @param nowMillis 当前时刻（epoch millis）
     */
    fun plan(session: OrdoSession?, nowMillis: Long): SessionPlan = when {
        session == null -> SessionPlan.CreateAnonymous
        session.userId.isBlank() -> SessionPlan.CreateAnonymous
        // 令牌残缺（例如写了一半就崩溃）视为没有会话：宁可静默重建，也不要带半截令牌发请求
        session.accessToken.isBlank() || session.refreshToken.isBlank() -> SessionPlan.CreateAnonymous
        session.isExpired(nowMillis) -> SessionPlan.RefreshFirst(session)
        else -> SessionPlan.UseExisting(session)
    }

    /**
     * 服务端是否**否认**了这个会话（401 类）。
     *
     * 只有服务端明确否认（`AUTH_REQUIRED` / `AUTH_TOKEN_EXPIRED`）才算会话失效；
     * 网络不可达 / 超时 / 5xx 一律按「暂时同步不上」处理，继续离线可用。
     */
    fun isSessionDenied(errorCode: String?): Boolean = OrdoErrors.isAuthFailure(errorCode)

    /** 从异常里取契约错误码（shared 的 `OrdoApiException` 或 Android 端带 details 的 `OrdoAuthError`） */
    fun errorCodeOf(error: Throwable?): String? = when (error) {
        null -> null
        is OrdoApiException -> error.code
        is OrdoAuthError -> error.code
        else -> null
    }

    /**
     * 静默建号的退避序列：1s、2s、4s … 上限 60s（`attempt` 从 0 起）。
     *
     * 不用位移是因为 `attempt` 很大时会整数溢出；循环乘法天然被上限夹住。
     */
    fun backoffMillis(attempt: Int): Long {
        var value = INITIAL_BACKOFF_MILLIS
        var step = 0
        while (step < attempt && value < MAX_BACKOFF_MILLIS) {
            value *= 2
            step++
        }
        return value.coerceAtMost(MAX_BACKOFF_MILLIS)
    }
}
