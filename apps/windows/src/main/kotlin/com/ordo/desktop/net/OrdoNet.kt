package com.ordo.desktop.net

import com.ordo.core.model.Op
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.GuestAuthRequest
import com.ordo.core.sync.OrdoApiException
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.OrdoSessionStore
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
 * 网络层(契约 §7.4 / §7.5):Ktor CIO 客户端 + 同步 / 实时通道 / 静默匿名会话
 * ========================================================================== */

/** 服务端错误信封 `{ "error": { "code", "message", "details" } }` */
@Serializable
data class ErrorEnvelope(val error: ErrorBody)

@Serializable
data class ErrorBody(val code: String, val message: String, val details: JsonElement? = null)

/**
 * 服务端错误(契约 §7.4 错误模型)。
 *
 * 共享核心的 [OrdoApiException] 只有 `code` / `message` 且是 `final`(不能继承)。本端要按错误码
 * 分流(401 刷令牌、`SYNC_SEQ_GAP` 全量重建…),所以并列一个同形状的类型,并补一个
 * [httpCode] 兜底:服务端没给出业务错误码时(网关 502、非 JSON 响应体)也能定位。
 */
class OrdoHttpException(
    /** 契约 §7.4 的冻结错误码,例如 `AUTH_REQUIRED` / `RATE_LIMITED`;兜底为 `HTTP_<status>` */
    val code: String,
    override val message: String
) : Exception(message) {

    /** HTTP 层没给出业务错误码时的兜底(如 `HTTP_502`) */
    val httpCode: String? get() = code.takeIf { it.startsWith("HTTP_") }
}

/** 从任意异常里取业务错误码:两类异常都兼容,其余为 null(网络不可达等) */
fun errorCodeOf(error: Throwable): String? = when (error) {
    is OrdoHttpException -> error.code
    is OrdoApiException -> error.code
    else -> null
}

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

/** 解析响应体;非 2xx 抛出结构化的 [OrdoHttpException] */
suspend fun <T> HttpResponse.bodyOrThrow(deserializer: (String) -> T): T {
    val text = bodyAsText()
    if (status.isSuccess()) return deserializer(text)
    val envelope = runCatching { OrdoJson.instance.decodeFromString(ErrorEnvelope.serializer(), text) }.getOrNull()
    throw OrdoHttpException(
        code = envelope?.error?.code ?: "HTTP_${status.value}",
        message = envelope?.error?.message ?: text.take(300).ifBlank { "请求失败" }
    )
}

/**
 * 登录态与服务器地址(契约 §7.6.1 / §8)。
 *
 * **令牌的唯一真源是 [com.ordo.core.sync.OrdoSession]**(存在 kv[OrdoSessionStore.KEY_SESSION]),
 * 这里只是它的一层便捷门面:以前 access/refresh/email 各占一个 kv 键,和 session 两份状态会漂移
 * (refresh 之后 session 还是旧的 expiresAt / token)。现在四端同源,401 刷新写回的就是会话本身。
 *
 * 传入的 storage 必须是**与账号无关的引导目录**(`%APPDATA%\Ordo`):登录发生在知道 userId 之前,
 * 会话不能住在某个账号的数据目录里,否则读不到 = 永远进不去。
 */
class TokenStore(private val storage: OrdoStorage) {

    /** 会话读写(契约 §7.6);登录页、退出登录、401 刷新都走它 */
    val sessionStore = OrdoSessionStore(storage)

    var serverUrl: String
        get() = storage.kvGet(KEY_SERVER) ?: DEFAULT_SERVER
        set(value) {
            storage.kvSet(KEY_SERVER, value.trim().trimEnd('/'))
        }

    /** 当前会话(无会话 = 未登录) */
    fun currentSession(): OrdoSession? = sessionStore.load()

    val accessToken: String? get() = currentSession()?.accessToken

    val refreshToken: String? get() = currentSession()?.refreshToken

    val email: String? get() = currentSession()?.email

    /** 匿名账号(契约 §7.6.1:匿名会话同样持有正常令牌,不是"受限模式") */
    val isGuest: Boolean get() = currentSession()?.isGuest == true

    val userId: String? get() = currentSession()?.userId

    /** 有 refreshToken 即视为有会话(是否过期交给 [SilentSessionKeeper] 判定与续期) */
    val hasSession: Boolean get() = !refreshToken.isNullOrBlank()

    /** 静默会话的统一落库入口(建匿名账号 / 续期) */
    fun save(response: AuthResponse, nowMillis: Long = System.currentTimeMillis()) {
        sessionStore.save(OrdoSessionStore.from(response, nowMillis))
    }

    fun saveSession(session: OrdoSession) = sessionStore.save(session)

    /** 清会话(只清凭据,不动数据目录 —— 数据目录 id 与本机绑定,契约 §7.6.6) */
    fun clear() = sessionStore.clear()

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

/**
 * 静默匿名会话需要的**全部**网络能力(产品决策:不再需要登录)。
 *
 * 共享核心的 `AuthApi` 还冻着 register / login / upgrade / emailCode 等接口,但本端已经不需要它们;
 * 与其实现一堆"永不调用"的方法,不如在这里声明一个窄接口 —— 客户端只依赖真正会用的两件事,
 * 且登录相关的 HTTP 代码(端点、DTO、错误分流)一并从本端消失。
 */
interface SilentAuthApi {

    /** 用 refreshToken 换新会话(启动静默续期 / 401 恢复) */
    suspend fun refresh(refreshToken: String): AuthResponse

    /**
     * 建匿名账号(契约 §7.6.2):服务端返回的是**正常令牌** ——
     * 匿名不是"离线模式",数据同样入库、同样多端同步。
     */
    suspend fun guest(request: GuestAuthRequest): AuthResponse
}

/** [SilentAuthApi] 的 Ktor 实现 */
class KtorAuthApi(
    private val client: HttpClient,
    private val tokens: TokenStore
) : SilentAuthApi {

    private fun HttpRequestBuilder.baseHeaders() {
        header("X-Ordo-Schema", OrdoHttp.SCHEMA_VERSION)
        header("X-Ordo-Client", OrdoHttp.CLIENT_ID)
    }

    override suspend fun refresh(refreshToken: String): AuthResponse =
        client.post("${tokens.serverUrl}/v1/auth/refresh") {
            baseHeaders()
            contentType(ContentType.Application.Json)
            setBody(RefreshRequest(refreshToken))
        }.bodyOrThrow { text -> OrdoJson.instance.decodeFromString(AuthResponse.serializer(), text) }

    override suspend fun guest(request: GuestAuthRequest): AuthResponse =
        client.post("${tokens.serverUrl}/v1/auth/guest") {
            baseHeaders()
            contentType(ContentType.Application.Json)
            setBody(request)
        }.bodyOrThrow { text -> OrdoJson.instance.decodeFromString(AuthResponse.serializer(), text) }
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
