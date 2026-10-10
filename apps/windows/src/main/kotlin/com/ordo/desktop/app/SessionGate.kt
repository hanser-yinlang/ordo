package com.ordo.desktop.app

import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.OrdoSessionStore

/**
 * 启动门禁的落点(契约 §7.6.4 / 04-UI规范 §5.1)。
 *
 * 只有两个:登录页、主界面。"有没有会话"是唯一的判据 —— 不引入"游客 = 受限模式"之类的第三态。
 */
enum class GateStage { LOGIN, MAIN }

/**
 * 一次门禁判定的结果(可测的纯值)。
 *
 * @param session 判定时的会话(登录页为 null)
 * @param needsRefresh 是否要在后台静默 refresh(`expiresAt` 未知或已过期时为 true,契约 §7.6.4)
 * @param notice 回登录页时给用户的一句解释(例如"会话过期"),由界面显示
 */
data class GateDecision(
    val stage: GateStage,
    val session: OrdoSession? = null,
    val needsRefresh: Boolean = false,
    val notice: String? = null
)

/**
 * 登录门禁状态机(契约 §7.6.4「启动流程(四端一致)」)。
 *
 * ```
 * 启动 → 读 session
 *   ├─ 有且未过期            → 直接进入主界面(后台静默 refresh)
 *   ├─ 有但 accessToken 过期 → 先 refresh;refresh 失败 → 登录页(保留 userId 目录)
 *   └─ 无                    → 登录页(必须选择:登录 / 注册 / 游客登录)
 * ```
 *
 * 全部是纯函数:输入会话与当前时刻,输出落点,不碰网络也不碰界面 —— 门禁本身因此可以逐条断言。
 * 网络部分(refresh / 登录 / 游客登录)由 [com.ordo.desktop.net.TokenStore] 与登录控制器承担。
 */
object SessionGate {

    /**
     * 启动判定。
     *
     * 有会话就**先进主界面**(本地数据立刻可用,离线也能看),
     * 同时用 [GateDecision.needsRefresh] 告诉调用方"要静默刷一次";
     * 过期会话刷失败时才回登录页 —— 而不是把用户堵在转圈的启动页上。
     */
    fun boot(session: OrdoSession?, nowMillis: Long): GateDecision =
        if (session == null) {
            GateDecision(GateStage.LOGIN)
        } else {
            GateDecision(GateStage.MAIN, session = session, needsRefresh = true)
        }

    /**
     * 静默 refresh 结束后的落点。
     *
     * - 成功 → 留在主界面(用刷新后的会话,令牌与过期时刻都是新的);
     * - 失败但**原会话还没过期** → 仍留在主界面(令牌没到期,服务端 401 会再兜一次);
     * - 失败且**原会话已过期** → 回登录页,并保留该 userId 的数据目录(契约 §7.6.3)。
     */
    fun afterRefresh(session: OrdoSession, ok: Boolean, refreshed: OrdoSession?, nowMillis: Long): GateDecision =
        when {
            ok -> GateDecision(GateStage.MAIN, session = refreshed ?: session, needsRefresh = false)
            session.isExpired(nowMillis) -> GateDecision(
                stage = GateStage.LOGIN,
                session = null,
                notice = expiredNotice(session)
            )
            else -> GateDecision(GateStage.MAIN, session = session, needsRefresh = false)
        }

    /** 登录 / 注册 / 游客登录成功 → 主界面 */
    fun afterAuthenticated(session: OrdoSession): GateDecision =
        GateDecision(GateStage.MAIN, session = session, needsRefresh = false)

    /** 退出登录 → 登录页(只清会话,目录保留) */
    fun afterSignOut(): GateDecision = GateDecision(GateStage.LOGIN)

    /** 会话过期回登录页时的一句话:同时说明"本地数据没丢",免得用户以为被清空了 */
    fun expiredNotice(session: OrdoSession): String =
        "「${session.displayName()}」的登录状态已过期，请重新登录；本地数据仍保留在 " +
            "Ordo\\${OrdoSessionStore.userDataDirName(session.userId)}\\ 目录中。"
}

/**
 * 当前账号(设置页展示 + 本地目录定位)。
 *
 * 游客与正式账号在这里**只有展示差异**:`displayName` 分别是"游客"与邮箱,
 * 数据目录、同步能力完全对等(契约 §7.6.1)。
 */
data class AccountInfo(
    val userId: String,
    val email: String? = null,
    val isGuest: Boolean = false
) {
    /** 邮箱或"游客"(契约 §7.6.3 的账号展示口径) */
    val displayName: String get() = email?.takeIf { it.isNotBlank() } ?: GUEST_LABEL

    /** 该账号的本地数据目录名(契约 §7.6.3:一个 userId 一个目录) */
    fun dataDirName(): String = OrdoSessionStore.userDataDirName(userId)

    companion object {
        const val GUEST_LABEL = "游客"

        fun of(session: OrdoSession): AccountInfo =
            AccountInfo(userId = session.userId, email = session.email, isGuest = session.isGuest)

        /** 无会话时没有账号(登录页) */
        fun ofOrNull(session: OrdoSession?): AccountInfo? = session?.let { of(it) }
    }
}
