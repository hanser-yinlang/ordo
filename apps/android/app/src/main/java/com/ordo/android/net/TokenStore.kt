package com.ordo.android.net

import com.ordo.android.data.SqliteStorage
import com.ordo.core.sync.AuthResponse

/**
 * 令牌持久化（契约 §8：kv 表存 tokens；deviceId 与 lastServerSeq 由共享核心自己维护）。
 * 契约 §9：令牌只落本地，不写日志。
 */
class TokenStore(
    private val storage: SqliteStorage,
) {

    fun accessToken(): String? = storage.kvGet(SqliteStorage.KEY_ACCESS_TOKEN)

    fun refreshToken(): String? = storage.kvGet(SqliteStorage.KEY_REFRESH_TOKEN)

    fun email(): String? = storage.kvGet(SqliteStorage.KEY_USER_EMAIL)

    fun isLoggedIn(): Boolean =
        !accessToken().isNullOrBlank() && !refreshToken().isNullOrBlank()

    fun serverUrl(): String =
        storage.kvGet(SqliteStorage.KEY_SERVER_URL)?.takeIf { it.isNotBlank() } ?: SqliteStorage.DEFAULT_SERVER_URL

    fun saveServerUrl(url: String) {
        storage.kvSet(SqliteStorage.KEY_SERVER_URL, url.trim().trimEnd('/'))
    }

    fun saveSession(response: AuthResponse) {
        storage.kvSet(SqliteStorage.KEY_ACCESS_TOKEN, response.accessToken)
        storage.kvSet(SqliteStorage.KEY_REFRESH_TOKEN, response.refreshToken)
        storage.kvSet(SqliteStorage.KEY_USER_EMAIL, response.user.email)
    }

    /** 退出登录：清令牌，**保留本地数据**（契约 §7.4 末条） */
    fun clearSession() {
        storage.kvSet(SqliteStorage.KEY_ACCESS_TOKEN, null)
        storage.kvSet(SqliteStorage.KEY_REFRESH_TOKEN, null)
        storage.kvSet(SqliteStorage.KEY_USER_EMAIL, null)
    }
}
