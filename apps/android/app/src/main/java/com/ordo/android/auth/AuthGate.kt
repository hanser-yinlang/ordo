package com.ordo.android.auth

import com.ordo.core.sync.OrdoSession

/* ============================================================================
 * 登录门禁（契约 §7.6.4 / UI §5.1）
 *
 *  启动 → 读 session
 *    ├─ 有且未过期            → 直接进入主界面（后台静默 refresh）
 *    ├─ 有但 accessToken 过期 → 先 refresh；refresh 失败 → 登录页（保留 userId 目录）
 *    └─ 无                    → 登录页（必须选择：登录 / 注册 / 游客登录）
 *
 * 这里全部是纯逻辑（不依赖 Android 框架），因此可以直接跑 JVM 单测：
 * ViewModel 只负责把 [SessionVerdict] 翻译成界面状态与副作用。
 * ========================================================================== */

/** 应用启动的三段式阶段 */
enum class AuthStage {
    /** 仍在读会话（首帧显示占位，不做任何数据访问） */
    LOADING,

    /** 登录页：必须选择 登录 / 注册 / 游客登录 三个入口之一 */
    LOGIN,

    /** 主界面 */
    MAIN,
}

/**
 * 登录页的两种模式。
 *
 * 三个入口 = 主按钮（[LOGIN] 或 [REGISTER] 两种模式切换）+ 「以游客身份继续」次要按钮。
 * 游客登录与正式登录**体验对等**（都能同步），不得做成受限入口。
 */
enum class AuthMode {
    LOGIN,
    REGISTER;

    fun toggled(): AuthMode = if (this == LOGIN) REGISTER else LOGIN

    /** 主按钮文案：登录 / 注册 */
    val isRegister: Boolean get() = this == REGISTER
}

/** 启动时读会话后的处置结果 */
sealed interface SessionVerdict {

    /** 无会话（或会话残缺）→ 登录页 */
    data object NoSession : SessionVerdict

    /** 有且未过期 → 直接进主界面（后台静默 refresh） */
    data class Ready(val session: OrdoSession) : SessionVerdict

    /** 有但 accessToken 过期 → 先 refresh；失败则回登录页，但**保留该 userId 的本地目录** */
    data class RefreshFirst(val session: OrdoSession) : SessionVerdict
}

/** 登录页表单校验结果 */
enum class AuthFieldError {
    NONE,
    EMAIL_EMPTY,
    EMAIL_INVALID,
    PASSWORD_EMPTY,
    PASSWORD_TOO_SHORT,
}

object SessionGate {

    /** 契约 §9：口令最小长度 8 */
    const val MIN_PASSWORD_LENGTH = 8

    /**
     * 启动时读会话的判断（契约 §7.6.4）。
     *
     * @param session [com.ordo.core.sync.OrdoSessionStore.load] 的结果
     * @param nowMillis 当前时刻（epoch millis）
     */
    fun decide(session: OrdoSession?, nowMillis: Long): SessionVerdict = when {
        session == null -> SessionVerdict.NoSession
        session.userId.isBlank() -> SessionVerdict.NoSession
        // 令牌残缺（例如写了一半就崩溃）视为无会话：宁可让用户重新登录，也不要带半截令牌发请求
        session.accessToken.isBlank() || session.refreshToken.isBlank() -> SessionVerdict.NoSession
        session.isExpired(nowMillis) -> SessionVerdict.RefreshFirst(session)
        else -> SessionVerdict.Ready(session)
    }

    /**
     * accessToken 过期后的续期结果（契约 §7.6.4 / §7.4）。
     *
     * 失败 → [SessionVerdict.NoSession]（回登录页），但调用方**只清会话、不清目录**：
     * 下次同一账号登录，本地数据仍在（离线可用，联网后增量同步）。
     */
    fun afterRefresh(
        success: Boolean,
        refreshed: OrdoSession?,
        fallback: OrdoSession,
    ): SessionVerdict = if (success) SessionVerdict.Ready(refreshed ?: fallback) else SessionVerdict.NoSession

    /** 展示名：正式账号用邮箱，游客用「游客」 */
    fun displayName(session: OrdoSession?): String = session?.displayName().orEmpty()

    /**
     * 登录页表单校验（先本地拦截，再发请求）。
     *
     * 注册必须满足契约 §9 的最小口令长度；登录不校验长度（老账号可能更短），
     * 只要求非空 —— 否则用户会在一个本地校验上被卡住却得不到服务端的真实原因。
     */
    fun validate(mode: AuthMode, email: String, password: String): AuthFieldError {
        val mail = email.trim()
        if (mail.isEmpty()) return AuthFieldError.EMAIL_EMPTY
        if (!mail.contains('@') || mail.startsWith('@') || mail.endsWith('@')) {
            return AuthFieldError.EMAIL_INVALID
        }
        if (password.isEmpty()) return AuthFieldError.PASSWORD_EMPTY
        if (mode == AuthMode.REGISTER && password.length < MIN_PASSWORD_LENGTH) {
            return AuthFieldError.PASSWORD_TOO_SHORT
        }
        return AuthFieldError.NONE
    }
}
