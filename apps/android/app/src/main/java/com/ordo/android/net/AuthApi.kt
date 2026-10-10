package com.ordo.android.net

import com.ordo.core.sync.AuthApi
import com.ordo.core.sync.AuthRequest
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.EmailCodeLoginRequest
import com.ordo.core.sync.EmailCodeRequest
import com.ordo.core.sync.EmailCodeSent
import com.ordo.core.sync.GuestAuthRequest
import com.ordo.core.sync.OrdoApiException
import com.ordo.core.sync.RefreshRequest
import com.ordo.core.sync.UpgradeRequest
import com.ordo.core.sync.UpgradeResponse
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * 契约 §7.4 / §7.6.2 认证接口的 Ktor 实现（shared:core 的 [AuthApi] 接口）。
 *
 *   POST /v1/auth/register · /v1/auth/login · /v1/auth/guest · /v1/auth/refresh · /v1/auth/logout
 *   POST /v1/auth/email/code · /v1/auth/email/login（邮箱验证码登录，契约 §7.6.5）
 *   POST /v1/auth/upgrade（需带 Access Token；userId 与数据不变）
 *
 * refresh 为轮换制：成功后立即持久化新的 accessToken + refreshToken。
 * 游客登录与正式登录在这里**完全同构**（都返回正常令牌、都写同一份会话）——
 * 游客不是"离线模式"，差别只有"没有邮箱口令"（契约 §7.6.1）。
 */
class OrdoAuthApi(
    private val client: HttpClient,
    private val tokens: TokenStore,
) : AuthApi {

    private val refreshMutex = Mutex()

    override suspend fun register(request: AuthRequest): AuthResponse {
        val response = postAuth<AuthRequest, AuthResponse>("/v1/auth/register", request)
        tokens.saveSession(response)
        return response
    }

    override suspend fun login(request: AuthRequest): AuthResponse {
        val response = postAuth<AuthRequest, AuthResponse>("/v1/auth/login", request)
        tokens.saveSession(response)
        return response
    }

    /** 游客登录：服务端创建匿名账号并返回正常令牌（契约 §7.6.2） */
    override suspend fun guest(request: GuestAuthRequest): AuthResponse {
        val response = postAuth<GuestAuthRequest, AuthResponse>("/v1/auth/guest", request)
        tokens.saveSession(response)
        return response
    }

    /**
     * 请求邮箱登录验证码（契约 §7.6.5）：202 + `{sent, expiresIn, retryAfter}`。
     *
     * 服务端**绝不回显验证码**；[EmailCodeSent.devCode] 只在开发模式
     * （`ORDO_MAIL_TRANSPORT=console` 且 `ORDO_DEV_ECHO_CODE=1`）出现，界面不得依赖。
     * 60s 内重复请求返回 429 `RATE_LIMITED`（details.reason=code_throttled）。
     */
    override suspend fun requestEmailCode(request: EmailCodeRequest): EmailCodeSent {
        val response = client.post("${tokens.serverUrl()}/v1/auth/email/code") { setBody(request) }
        val text = response.bodyAsText()
        response.throwAuthError(text)
        if (text.isBlank()) throw OrdoApiException("INTERNAL", "验证码响应为空")
        return response.body()
    }

    /**
     * 邮箱验证码登录（契约 §7.6.5）：与 register/login/guest **同构**，
     * 未注册邮箱由服务端自动建号；成功后与其它登录方式一样立即写会话
     * （共用同一 userId、同一份云端数据、同一套 refreshToken 体系）。
     */
    override suspend fun emailLogin(request: EmailCodeLoginRequest): AuthResponse {
        val response = client.post("${tokens.serverUrl()}/v1/auth/email/login") { setBody(request) }
        val text = response.bodyAsText()
        response.throwAuthError(text)
        if (text.isBlank()) throw OrdoApiException("INTERNAL", "认证响应为空")
        val body: AuthResponse = response.body()
        tokens.saveSession(body)
        return body
    }

    /**
     * 游客升级为正式账号（契约 §7.6.2）：需要当前 Access Token；
     * 邮箱已占用时服务端返回 `AUTH_EMAIL_TAKEN`，此处原样抛出（由界面提示）。
     */
    override suspend fun upgrade(accessToken: String, request: UpgradeRequest): UpgradeResponse {
        val response = client.post("${tokens.serverUrl()}/v1/auth/upgrade") {
            header(HttpHeaders.Authorization, "Bearer $accessToken")
            setBody(request)
        }
        val text = response.bodyAsText()
        response.throwIfError(text)
        if (text.isBlank()) throw OrdoApiException("INTERNAL", "升级响应为空")
        val body: UpgradeResponse = response.body()
        tokens.applyUpgrade(body.user)
        return body
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

    /** 退出登录：通知服务端（忽略失败）+ 清本地会话，保留本地数据（契约 §7.6.3） */
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

    private suspend inline fun <reified B, reified R> postAuth(path: String, request: B): R {
        val response: HttpResponse = client.post("${tokens.serverUrl()}$path") { setBody(request) }
        val text = response.bodyAsText()
        response.throwIfError(text)
        if (text.isBlank()) throw OrdoApiException("INTERNAL", "认证响应为空")
        return response.body()
    }
}
