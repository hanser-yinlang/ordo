package com.ordo.core.sync

import com.ordo.core.storage.OrdoStorage
import com.ordo.core.util.OrdoJson
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString

/**
 * 登录会话(契约 §7.6)。
 *
 * 启动流程(四端一致):
 * ```
 * 读 session
 *   ├─ 有且未过期            → 直接进主界面(后台静默 refresh)
 *   ├─ 有但 accessToken 过期 → 先 refresh;失败 → 登录页(保留该 userId 的本地目录)
 *   └─ 无                    → 登录页(登录 / 注册 / 游客登录 三个入口)
 * ```
 *
 * **游客不是离线模式**:`isGuest=true` 只是"没有邮箱口令",令牌与同步能力完全一致。
 */
@Serializable
data class OrdoSession(
    val userId: String,
    val email: String? = null,
    val isGuest: Boolean = false,
    val accessToken: String,
    val refreshToken: String,
    /** 过期时刻(epoch millis);0 表示未知(按未过期处理,由服务端 401 兜底) */
    val expiresAt: Long = 0L,
) {
    fun isExpired(nowMillis: Long): Boolean = expiresAt > 0L && nowMillis >= expiresAt

    /** 展示名:正式账号用邮箱,游客用"游客" */
    fun displayName(): String = email?.takeIf { it.isNotBlank() } ?: "游客"
}

/**
 * 会话的本地读写。
 *
 * 直接基于 [OrdoStorage] 的 kv 接口,因此四端无需各自实现;
 * 各端只需保证传入的 storage 是**该 userId 专属目录**里的实例(契约 §7.6.3 硬约束)。
 */
class OrdoSessionStore(private val storage: OrdoStorage) {

    fun load(): OrdoSession? {
        val raw = storage.kvGet(KEY_SESSION) ?: return null
        if (raw.isBlank()) return null
        return runCatching {
            OrdoJson.instance.decodeFromString(OrdoSession.serializer(), raw)
        }.getOrNull()
    }

    fun save(session: OrdoSession) {
        storage.kvSet(KEY_SESSION, OrdoJson.instance.encodeToString(session))
    }

    fun clear() {
        storage.kvSet(KEY_SESSION, null)
    }

    companion object {
        const val KEY_SESSION = "ordo.session"

        /** 由登录响应构造会话;`nowMillis` 用于把 `expiresIn`(秒)换算成绝对过期时刻 */
        fun from(response: AuthResponse, nowMillis: Long): OrdoSession = OrdoSession(
            userId = response.user.id,
            email = response.user.email.takeIf { it.isNotBlank() },
            isGuest = response.user.isGuest,
            accessToken = response.accessToken,
            refreshToken = response.refreshToken,
            expiresAt = if (response.expiresIn > 0) nowMillis + response.expiresIn * 1000L else 0L,
        )

        /**
         * 本地数据目录名(契约 §7.6.3):每个账号一个子目录,防止两个账号共用同一份数据。
         * userId 是服务端生成的 uuid,直接用作目录名是安全的;这里再做一次防御性清洗。
         */
        fun userDataDirName(userId: String): String =
            userId.map { ch -> if (ch.isLetterOrDigit() || ch == '-' || ch == '_') ch else '_' }.joinToString("")
    }
}
