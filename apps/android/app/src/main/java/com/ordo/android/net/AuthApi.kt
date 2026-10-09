package com.ordo.android.net

import com.ordo.core.sync.AuthApi
import com.ordo.core.sync.AuthRequest
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.OrdoApiException
import com.ordo.core.sync.RefreshRequest
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * 契约 §7.4 认证接口的 Ktor 实现（shared:core 的 [AuthApi] 接口）。
 *
 *   POST /v1/auth/register · /v1/auth/login · /v1/auth/refresh · /v1/auth/logout
 * refresh 为轮换制：成功后立即持久化新的 accessToken + refreshToken。
 */
class OrdoAuthApi(
    private val client: HttpClient,
    private val tokens: TokenStore,
) : AuthApi {

    private val refreshMutex = Mutex()

    override suspend fun register(request: AuthRequest): AuthResponse {
        val response = postAuth("/v1/auth/register", request)
        tokens.saveSession(response)
        return response
    }

    override suspend fun login(request: AuthRequest): AuthResponse {
        val response = postAuth("/v1/auth/login", request)
        tokens.saveSession(response)
        return response
    }

    override suspend fun refresh(refreshToken: String): AuthResponse = refreshMutex.withLock {
        val response = client.post("${tokens.serverUrl()}/v1/auth/refresh") {
            setBody(RefreshRequest(refreshToken))
        }
        val text = response.bodyAsText()
        response.throwIfError(text)
        val body: AuthResponse = response.body()
        tokens.saveSession(body)
        body
    }

    /** 退出登录：通知服务端（忽略失败）+ 清本地令牌，保留本地数据 */
    suspend fun logout() {
        val refreshToken = tokens.refreshToken()
        if (!refreshToken.isNullOrBlank()) {
            runCatching {
                client.post("${tokens.serverUrl()}/v1/auth/logout") {
                    setBody(RefreshRequest(refreshToken))
                }
            }
        }
        tokens.clearSession()
    }

    /** 用已保存的 refreshToken 续期；无 refreshToken 时返回 null */
    suspend fun refreshSaved(): AuthResponse? {
        val token = tokens.refreshToken() ?: return null
        return runCatching { refresh(token) }.getOrNull()
    }

    private suspend fun postAuth(path: String, request: AuthRequest): AuthResponse {
        val response = client.post("${tokens.serverUrl()}$path") { setBody(request) }
        val text = response.bodyAsText()
        response.throwIfError(text)
        if (text.isBlank()) throw OrdoApiException("INTERNAL", "认证响应为空")
        return response.body()
    }
}
