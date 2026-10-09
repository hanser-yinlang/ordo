package com.ordo.android.net

import com.ordo.core.sync.OrdoApiException
import com.ordo.core.sync.PullResponse
import com.ordo.core.sync.PushRequest
import com.ordo.core.sync.PushResponse
import com.ordo.core.sync.SnapshotResponse
import com.ordo.core.sync.SyncApi
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode

/**
 * 契约 §7.4 同步接口的 Ktor 实现（shared:core 的 [SyncApi] 接口）。
 *
 *   GET  /v1/sync/snapshot                → SnapshotResponse
 *   POST /v1/sync/push（捎带拉取）          → PushResponse
 *   GET  /v1/sync/pull?sinceSeq=&limit=   → PullResponse
 *
 * 401 处理（契约 §7.4）：遇 AUTH_TOKEN_EXPIRED 自动 refresh 并**重放一次**；
 * refresh 亦失败 → 抛 AUTH_REQUIRED，由上层转登录态但保留本地数据。
 * 请求/响应实体直接复用共享核心的 DTO（OrdoJson 序列化行为四端一致）。
 */
class KtorSyncApi(
    private val client: HttpClient,
    private val tokens: TokenStore,
    private val auth: OrdoAuthApi,
) : SyncApi {

    override suspend fun push(request: PushRequest): PushResponse {
        val response = authorized { token ->
            client.post("${tokens.serverUrl()}/v1/sync/push") {
                header(HttpHeaders.Authorization, "Bearer $token")
                setBody(request)
            }
        }
        return response.body()
    }

    override suspend fun pull(sinceSeq: Long, limit: Int): PullResponse {
        val safeLimit = limit.coerceIn(1, MAX_PULL_LIMIT)
        val response = authorized { token ->
            client.get("${tokens.serverUrl()}/v1/sync/pull?sinceSeq=$sinceSeq&limit=$safeLimit") {
                header(HttpHeaders.Authorization, "Bearer $token")
            }
        }
        return response.body()
    }

    override suspend fun fetchSnapshot(): SnapshotResponse {
        val response = authorized { token ->
            client.get("${tokens.serverUrl()}/v1/sync/snapshot") {
                header(HttpHeaders.Authorization, "Bearer $token")
            }
        }
        return response.body()
    }

    /** 更新设备信息（契约 §7.4 POST /v1/devices/register） */
    suspend fun registerDevice(deviceId: String, deviceName: String) {
        runCatching {
            val response = authorized { token ->
                client.post("${tokens.serverUrl()}/v1/devices/register") {
                    header(HttpHeaders.Authorization, "Bearer $token")
                    setBody(
                        mapOf(
                            "deviceId" to deviceId,
                            "deviceName" to deviceName,
                            "platform" to "android",
                        ),
                    )
                }
            }
            response.throwIfError(response.bodyAsText())
        }
    }

    /** 带 Bearer 的请求；401 → refresh → 重放一次 */
    private suspend fun authorized(block: suspend (String) -> HttpResponse): HttpResponse {
        val token = tokens.accessToken()
            ?: throw OrdoApiException(OrdoErrors.AUTH_REQUIRED, "需要登录")
        val first = block(token)
        if (first.status != HttpStatusCode.Unauthorized) {
            first.throwIfError(first.bodyAsText().takeIf { first.status.value !in 200..299 }.orEmpty())
            return first
        }
        val refreshed = auth.refreshSaved()
            ?: throw OrdoApiException(OrdoErrors.AUTH_TOKEN_EXPIRED, "登录已过期，请重新登录")
        val second = block(refreshed.accessToken)
        if (second.status == HttpStatusCode.Unauthorized) {
            throw OrdoApiException(OrdoErrors.AUTH_TOKEN_EXPIRED, "登录已过期，请重新登录")
        }
        if (second.status.value !in 200..299) {
            second.throwIfError(second.bodyAsText())
        }
        return second
    }

    companion object {
        const val MAX_PULL_LIMIT = 1000

        /** 契约 §7.4：单次 push ≤ 500 ops、单 op payload ≤ 256 KB */
        const val MAX_PUSH_OPS = 500
        const val MAX_OP_BYTES = 256 * 1024
    }
}
