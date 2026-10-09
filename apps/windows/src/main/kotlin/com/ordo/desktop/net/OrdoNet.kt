package com.ordo.desktop.net

import com.ordo.core.model.Op
import com.ordo.core.sync.AuthApi
import com.ordo.core.sync.AuthRequest
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.OrdoApiException
import com.ordo.core.sync.PullResponse
import com.ordo.core.sync.PushRequest
import com.ordo.core.sync.PushResponse
import com.ordo.core.sync.RefreshRequest
import com.ordo.core.sync.RealtimeChannel
import com.ordo.core.sync.ReminderPush
import com.ordo.core.sync.SnapshotResponse
import com.ordo.core.sync.SyncApi
import com.ordo.core.storage.OrdoStorage
import com.ordo.core.util.OrdoJson
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.parameter
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.serialization.kotlinx.json.json
import io.ktor.websocket.Frame
import io.ktor.websocket.readText
import io.ktor.websocket.send
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import java.util.concurrent.atomic.AtomicBoolean

/* ============================================================================
 * 网络层(契约 §7.4 / §7.5):Ktor CIO 客户端 + 四个接口实现
 * ========================================================================== */

/** 服务端错误信封 `{ "error": { "code", "message", "details" } }` */
@Serializable
data class ErrorEnvelope(val error: ErrorBody)

@Serializable
data class ErrorBody(val code: String, val message: String, val details: JsonElement? = null)

object OrdoHttp {

    const val SCHEMA_VERSION = "1"
    const val CLIENT_ID = "windows/1.0.0"

    fun create(): HttpClient = HttpClient(CIO) {
        expectSuccess = false
        install(ContentNegotiation) { json(OrdoJson.instance) }
        install(WebSockets)
        install(HttpTimeout) {
            requestTimeoutMillis = 20_000
            connectTimeoutMillis = 10_000
            socketTimeoutMillis = 30_000
        }
    }
}

/** 解析响应体;非 2xx 抛出结构化的 [OrdoApiException] */
suspend fun <T> HttpResponse.bodyOrThrow(deserializer: (String) -> T): T {
    val text = bodyAsText()
    if (status.isSuccess()) return deserializer(text)
    val envelope = runCatching { OrdoJson.instance.decodeFromString(ErrorEnvelope.serializer(), text) }.getOrNull()
    throw OrdoApiException(
        envelope?.error?.code ?: "HTTP_${status.value}",
        envelope?.error?.message ?: text.take(300).ifBlank { "请求失败" }
    )
}

/** 登录态与服务器地址(存本地 kv,契约 §8) */
class TokenStore(private val storage: OrdoStorage) {

    var serverUrl: String
        get() = storage.kvGet(KEY_SERVER) ?: DEFAULT_SERVER
        set(value) {
            storage.kvSet(KEY_SERVER, value.trim().trimEnd('/'))
        }

    var accessToken: String?
        get() = storage.kvGet(KEY_ACCESS)
        set(value) {
            storage.kvSet(KEY_ACCESS, value)
        }

    var refreshToken: String?
        get() = storage.kvGet(KEY_REFRESH)
        set(value) {
            storage.kvSet(KEY_REFRESH, value)
        }

    var email: String?
        get() = storage.kvGet(KEY_EMAIL)
        set(value) {
            storage.kvSet(KEY_EMAIL, value)
        }

    val isLoggedIn: Boolean get() = !refreshToken.isNullOrBlank()

    fun save(response: AuthResponse) {
        accessToken = response.accessToken
        refreshToken = response.refreshToken
        email = response.user.email
    }

    fun clear() {
        accessToken = null
        refreshToken = null
        email = null
    }

    /** `https://host:port` → `wss://host:port/v1/ws?token=…`(契约 §7.5) */
    fun webSocketUrl(): String? {
        val token = accessToken ?: return null
        val base = serverUrl
        val ws = when {
            base.startsWith("https://") -> "wss://" + base.removePrefix("https://")
            base.startsWith("http://") -> "ws://" + base.removePrefix("http://")
            else -> "ws://$base"
        }
        return "$ws/v1/ws?token=$token"
    }

    companion object {
        const val KEY_SERVER = "ordo.serverUrl"
        const val KEY_ACCESS = "ordo.auth.accessToken"
        const val KEY_REFRESH = "ordo.auth.refreshToken"
        const val KEY_EMAIL = "ordo.auth.email"
        /** 默认指向本仓库自带的后端(server/.env.example:PORT=8080) */
        const val DEFAULT_SERVER = "http://127.0.0.1:8080"
    }
}

/** [SyncApi] 的 Ktor 实现 */
class KtorSyncApi(
    private val client: HttpClient,
    private val tokens: TokenStore,
    private val deviceId: String
) : SyncApi {

    private fun HttpRequestBuilder.ordoHeaders() {
        header("X-Ordo-Schema", OrdoHttp.SCHEMA_VERSION)
        header("X-Ordo-Device", deviceId)
        header("X-Ordo-Client", OrdoHttp.CLIENT_ID)
        tokens.accessToken?.let { header("Authorization", "Bearer $it") }
    }

    override suspend fun push(request: PushRequest): PushResponse =
        client.post("${tokens.serverUrl}/v1/sync/push") {
            ordoHeaders()
            contentType(ContentType.Application.Json)
            setBody(request)
        }.bodyOrThrow { text ->
            OrdoJson.instance.decodeFromString(PushResponse.serializer(), text)
        }

    override suspend fun pull(sinceSeq: Long, limit: Int): PullResponse =
        client.get("${tokens.serverUrl}/v1/sync/pull") {
            ordoHeaders()
            parameter("sinceSeq", sinceSeq)
            parameter("limit", limit)
        }.bodyOrThrow { text ->
            OrdoJson.instance.decodeFromString(PullResponse.serializer(), text)
        }

    override suspend fun fetchSnapshot(): SnapshotResponse =
        client.get("${tokens.serverUrl}/v1/sync/snapshot") {
            ordoHeaders()
        }.bodyOrThrow { text ->
            OrdoJson.instance.decodeFromString(SnapshotResponse.serializer(), text)
        }
}

/** [AuthApi] 的 Ktor 实现 */
class KtorAuthApi(
    private val client: HttpClient,
    private val tokens: TokenStore
) : AuthApi {

    private fun HttpRequestBuilder.baseHeaders() {
        header("X-Ordo-Schema", OrdoHttp.SCHEMA_VERSION)
        header("X-Ordo-Client", OrdoHttp.CLIENT_ID)
    }

    override suspend fun register(request: AuthRequest): AuthResponse =
        client.post("${tokens.serverUrl}/v1/auth/register") {
            baseHeaders()
            contentType(ContentType.Application.Json)
            setBody(request)
        }.bodyOrThrow { text -> OrdoJson.instance.decodeFromString(AuthResponse.serializer(), text) }

    override suspend fun login(request: AuthRequest): AuthResponse =
        client.post("${tokens.serverUrl}/v1/auth/login") {
            baseHeaders()
            contentType(ContentType.Application.Json)
            setBody(request)
        }.bodyOrThrow { text -> OrdoJson.instance.decodeFromString(AuthResponse.serializer(), text) }

    override suspend fun refresh(refreshToken: String): AuthResponse =
        client.post("${tokens.serverUrl}/v1/auth/refresh") {
            baseHeaders()
            contentType(ContentType.Application.Json)
            setBody(RefreshRequest(refreshToken))
        }.bodyOrThrow { text -> OrdoJson.instance.decodeFromString(AuthResponse.serializer(), text) }

    /** 退出登录(204 无响应体) */
    suspend fun logout() {
        val token = tokens.refreshToken ?: return
        runCatching {
            client.post("${tokens.serverUrl}/v1/auth/logout") {
                baseHeaders()
                contentType(ContentType.Application.Json)
                setBody(RefreshRequest(token))
            }
        }
    }
}

/* ---------------------------------------------------------------- WebSocket DTO */

@Serializable
data class WsOutbound(val type: String, val deviceId: String? = null, val serverSeq: Long? = null)

@Serializable
data class WsInbound(
    val type: String,
    val serverSeq: Long? = null,
    val ops: List<Op> = emptyList(),
    val todoId: String? = null,
    val title: String? = null,
    val at: String? = null,
    val t: Long? = null
)

/**
 * 实时通道(契约 §7.5):下行 hello / ops / reminder / ping,上行 subscribe / ack / pong。
 * 断线后指数退避重连(1s → 2s → 4s … 上限 60s),直到 [close]。
 */
class KtorRealtimeChannel(
    private val client: HttpClient,
    private val tokens: TokenStore,
    private val onConnected: () -> Unit = {}
) : RealtimeChannel {

    private val closed = AtomicBoolean(false)

    @Volatile
    private var session: DefaultClientWebSocketSession? = null

    override suspend fun connect(
        deviceId: String,
        onOps: (List<Op>, Long) -> Unit,
        onReminder: (ReminderPush) -> Unit
    ) {
        var attempt = 0
        while (!closed.get()) {
            val url = tokens.webSocketUrl()
            if (url == null) return // 未登录:静默退出;登录后由协调器重新拉起
            try {
                client.webSocket(urlString = url) {
                    session = this
                    attempt = 0
                    send(Frame.Text(encode(WsOutbound("subscribe", deviceId))))
                    onConnected()
                    for (frame in incoming) {
                        if (frame !is Frame.Text) continue
                        val message = runCatching {
                            OrdoJson.instance.decodeFromString(WsInbound.serializer(), frame.readText())
                        }.getOrNull() ?: continue
                        when (message.type) {
                            "hello" -> message.serverSeq?.let { seq ->
                                send(Frame.Text(encode(WsOutbound("ack", serverSeq = seq))))
                            }
                            "ops" -> {
                                if (message.ops.isNotEmpty()) onOps(message.ops, message.serverSeq ?: 0L)
                                message.serverSeq?.let { seq ->
                                    send(Frame.Text(encode(WsOutbound("ack", serverSeq = seq))))
                                }
                            }
                            "reminder" -> message.todoId?.let { id ->
                                onReminder(ReminderPush(id, message.title ?: "", message.at ?: ""))
                            }
                            "ping" -> send(Frame.Text(encode(WsOutbound("pong"))))
                        }
                    }
                }
            } catch (t: Throwable) {
                if (closed.get()) break
            } finally {
                session = null
            }
            if (closed.get()) break
            attempt += 1
            delay(backoffMillis(attempt))
        }
    }

    override fun close() {
        closed.set(true)
        runCatching { session?.cancel() }
        session = null
    }

    private fun encode(message: WsOutbound): String =
        OrdoJson.instance.encodeToString(WsOutbound.serializer(), message)

    private fun backoffMillis(attempt: Int): Long =
        (1_000L shl (attempt - 1).coerceIn(0, 6)).coerceAtMost(60_000L)
}
