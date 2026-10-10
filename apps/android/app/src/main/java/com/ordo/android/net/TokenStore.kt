package com.ordo.android.net

import com.ordo.android.data.SqliteStorage
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.OrdoSessionStore
import com.ordo.core.sync.UserDto

/**
 * 会话/令牌持久化（契约 §7.6.1：`session = { userId, email?, isGuest, accessToken, refreshToken, expiresAt }`
 * 存于本地 `kv["ordo.session"]`）。
 *
 * 实现直接委托给共享核心的 [OrdoSessionStore]，本类只负责【语义命名】与【向后兼容的冗余字段】：
 *  - 令牌读写一律走 session（游客也有正常令牌，因此 `accessToken` 非空即可认为已登录）；
 *  - `userEmail` 仍冗余写一份，方便排查问题（契约 §9：不打印 token，只留邮箱）；
 *  - [clearSession] **只清会话**，绝不删除该 userId 的数据目录（契约 §7.6.3）。
 *
 * 传入的 [storage] 必须是**会话所在的库**（Android 端的引导库），而不是某个账号的数据目录 ——
 * 登录前就要能读到会话。
 */
class TokenStore(
    private val storage: SqliteStorage,
) {

    private val sessions = OrdoSessionStore(storage)

    /** 会话读取入口（启动门禁 / 设置页展示当前账号） */
    fun sessionStore(): OrdoSessionStore = sessions

    fun session(): OrdoSession? = runCatching { sessions.load() }.getOrNull()

    fun accessToken(): String? = session()?.accessToken?.takeIf { it.isNotBlank() }

    fun refreshToken(): String? = session()?.refreshToken?.takeIf { it.isNotBlank() }

    fun email(): String? = session()?.email

    fun userId(): String? = session()?.userId

    fun isGuest(): Boolean = session()?.isGuest == true

    /** 展示名：正式账号用邮箱，游客用「游客」 */
    fun displayName(): String = session()?.displayName().orEmpty()

    fun isLoggedIn(): Boolean = !accessToken().isNullOrBlank() && !refreshToken().isNullOrBlank()

    fun serverUrl(): String =
        storage.kvGet(SqliteStorage.KEY_SERVER_URL)?.takeIf { it.isNotBlank() } ?: SqliteStorage.DEFAULT_SERVER_URL

    fun saveServerUrl(url: String) {
        storage.kvSet(SqliteStorage.KEY_SERVER_URL, url.trim().trimEnd('/'))
    }

    /** 登录 / 注册 / 游客登录成功后写会话（`expiresIn` 秒 → 绝对过期时刻） */
    fun saveSession(response: AuthResponse, nowMillis: Long = System.currentTimeMillis()) {
        sessions.save(OrdoSessionStore.from(response, nowMillis))
        storage.kvSet(SqliteStorage.KEY_USER_EMAIL, response.user.email)
    }

    /**
     * 游客升级为正式账号（契约 §7.6.2）：**userId 不变、数据不变**，只更新邮箱与游客标记。
     * 令牌不动 —— 升级接口不轮换令牌。
     */
    fun applyUpgrade(user: UserDto) {
        val current = session() ?: return
        sessions.save(
            current.copy(
                // 游客账号没有邮箱(服务端返回 email: null,契约 §7.6.1)
                email = user.email?.takeIf { it.isNotBlank() },
                isGuest = user.isGuest,
            ),
        )
        storage.kvSet(SqliteStorage.KEY_USER_EMAIL, user.email)
    }

    /** 退出登录：只清会话，**保留该 userId 的数据目录**（契约 §7.6.3） */
    fun clearSession() {
        sessions.clear()
        storage.kvSet(SqliteStorage.KEY_USER_EMAIL, null)
    }
}
