package com.ordo.desktop.net

import com.ordo.core.model.Op
import com.ordo.core.sync.AuthApi
import com.ordo.core.sync.AuthRequest
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.EmailCodeLoginRequest
import com.ordo.core.sync.EmailCodeRequest
import com.ordo.core.sync.EmailCodeSent
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
import com.ordo.core.sync.UpgradeRequest
import com.ordo.core.sync.UpgradeResponse
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
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.concurrent.atomic.AtomicBoolean

/* ============================================================================
 * 网络层(契约 §7.4 / §7.5):Ktor CIO 客户端 + 四个接口实现
 * ========================================================================== */

/** 服务端错误信封 `{ "error": { "code", "message", "details" } }` */
@Serializable
data class ErrorEnvelope(val error: ErrorBody)

@Serializable
data class ErrorBody(val code: String, val message: String, val details: JsonElement? = null)

/**
 * 带 `details` 的服务端错误(契约 §7.4 / §7.6.2 / §7.6.5)。
 *
 * 共享核心的 [OrdoApiException] 只冻结了 `code` / `message`(而且是 final,不能继承),但契约
 * §7.6.2、§7.6.5 明确规定**不新增错误码**,而是用 `details.reason` 区分同一 code 下的细分场景
 * (`not_guest` / `code_throttled` / `code_invalid` / `code_expired` / `code_attempts_exceeded`),
 * 429 还带一个等待秒数。共享核心冻结、本轮不得修改,所以这里在 Windows 网络层并列一个更完整的
 * 错误类型把 reason 与 retryAfterSec 透出来 —— 界面据此给中文文案与倒计时秒数。
 *
 * 老代码判断 `error is OrdoApiException` 依然成立:改用 [errorCodeOf] 取码,语义完全一致。
 */
class OrdoHttpException(
    /** 契约 §7.4 的冻结错误码,例如 `AUTH_INVALID_CREDENTIALS` / `RATE_LIMITED` */
    val code: String,
    override val message: String,
    /** `details.reason`,例如 `code_invalid`;缺失为 null */
    val reason: String? = null,
    /** 限流时的等待秒数:来自 `details.retryAfterSec`(或顶层 `retryAfter`) */
    val retryAfterSec: Long? = null
) : Exception(message) {

    /** HTTP 层没给出业务错误码时的兜底(如 `HTTP_500`) */
    val httpCode: String? get() = code.takeIf { it.startsWith("HTTP_") }
}

/** 从任意异常里取业务错误码:两类异常都兼容,其余为 null(网络不可达等) */
fun errorCodeOf(error: Throwable): String? = when (error) {
    is OrdoHttpException -> error.code
    is OrdoApiException -> error.code
    else -> null
}

/** 从任意异常里取 `details.reason`(只有 [OrdoHttpException] 带得动) */
fun errorReasonOf(error: Throwable): String? = (error as? OrdoHttpException)?.reason

/**
 * 限流错误里的等待秒数(契约 §7.6.5:`error.details.retryAfterSec`)。
 *
 * 缺失 / 非正数时回落到 [DEFAULT_RETRY_AFTER_SECONDS](与成功体顶层 `retryAfter` 的默认值一致),
 * 并且夹在 (0, [MAX_RETRY_AFTER_SECONDS]] 内 —— 服务端给出离谱值时也不至于把按钮永久锁死。
 */
fun retryAfterSecondsOf(error: Throwable): Long {
    val raw = (error as? OrdoHttpException)?.retryAfterSec ?: return DEFAULT_RETRY_AFTER_SECONDS
    return raw.coerceIn(1L, MAX_RETRY_AFTER_SECONDS)
}

/** 契约 §7.6.5:同一邮箱再次请求的最小间隔默认 60 秒 */
const val DEFAULT_RETRY_AFTER_SECONDS = 60L

/** 上限只是防御离谱响应,不是契约值 */
const val MAX_RETRY_AFTER_SECONDS = 3_600L

/** `details` 里的字段(全部可选:服务端只保证是对象) */
private fun JsonElement?.detailString(key: String): String? =
    runCatching { this?.jsonObject?.get(key)?.jsonPrimitive?.content }.getOrNull()

private fun JsonElement?.detailLong(key: String): Long? =
    runCatching { this?.jsonObject?.get(key)?.jsonPrimitive?.content?.toLongOrNull() }.getOrNull()

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

/** 解析响应体;非 2xx 抛出结构化的 [OrdoHttpException](带 `details.reason` 与 `retryAfterSec`) */
suspend fun <T> HttpResponse.bodyOrThrow(deserializer: (String) -> T): T {
    val text = bodyAsText()
    if (status.isSuccess()) return deserializer(text)
    val envelope = runCatching { OrdoJson.instance.decodeFromString(ErrorEnvelope.serializer(), text) }.getOrNull()
    val details = envelope?.error?.details
    throw OrdoHttpException(
        code = envelope?.error?.code ?: "HTTP_${status.value}",
        message = envelope?.error?.message ?: text.take(300).ifBlank { "请求失败" },
        // 契约 §7.6.5:`details.reason` 用来区分同一错误码下的细分场景
        reason = details.detailString("reason"),
        // 契约 §7.6.5 的 429:`{error:{code:RATE_LIMITED,details:{reason:code_throttled,retryAfterSec:42}}}`
        // —— 错误体里是 **details.retryAfterSec**(与成功体顶层的 retryAfter 位置不同、含义相同)
        retryAfterSec = details.detailLong("retryAfterSec")
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

    /** 游客账号(契约 §7.6.1:游客也持有正常令牌,只是没有邮箱口令) */
    val isGuest: Boolean get() = currentSession()?.isGuest == true

    val userId: String? get() = currentSession()?.userId

    val isLoggedIn: Boolean get() = !refreshToken.isNullOrBlank()

    /** 登录 / 注册 / 游客登录 / refresh 的统一落库入口 */
    fun save(response: AuthResponse, nowMillis: Long = System.currentTimeMillis()) {
        sessionStore.save(OrdoSessionStore.from(response, nowMillis))
    }

    fun saveSession(session: OrdoSession) = sessionStore.save(session)

    /** 退出登录:只清会话,保留该 userId 的数据目录(契约 §7.6.3 硬约束) */
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

    /**
     * 游客登录(契约 §7.6.2):服务端建匿名账号并返回**正常令牌** ——
     * 游客不是离线模式,数据同样入库、同样多端同步,只是没有邮箱口令。
     */
    override suspend fun guest(request: GuestAuthRequest): AuthResponse =
        client.post("${tokens.serverUrl}/v1/auth/guest") {
            baseHeaders()
            contentType(ContentType.Application.Json)
            setBody(request)
        }.bodyOrThrow { text -> OrdoJson.instance.decodeFromString(AuthResponse.serializer(), text) }

    /**
     * 游客升级为正式账号(契约 §7.6.2):`userId` 与数据都不变。
     *
     * 与其它 auth 接口不同,这个必须带 Access Token(走 Authorization 头,不是 body)。
     */
    override suspend fun upgrade(accessToken: String, request: UpgradeRequest): UpgradeResponse =
        client.post("${tokens.serverUrl}/v1/auth/upgrade") {
            baseHeaders()
            header("Authorization", "Bearer $accessToken")
            contentType(ContentType.Application.Json)
            setBody(request)
        }.bodyOrThrow { text -> OrdoJson.instance.decodeFromString(UpgradeResponse.serializer(), text) }

    /**
     * 请求邮箱登录验证码(契约 §7.6.5):`POST /v1/auth/email/code` → 202
     * `{sent,expiresIn,retryAfter}`。**响应绝不回显验证码**,唯一例外是开发模式(`console` 通道 +
     * 显式开关)会带 `devCode` —— 界面只把它当作联调便利自动填入,绝不依赖它。
     *
     * 同一邮箱 60s 内重复请求 → 429 `RATE_LIMITED`(details.reason = `code_throttled`,带等待秒数),
     * 这个 `retryAfterSec` 由 [OrdoHttpException] 透出,交给登录页跑倒计时。
     */
    override suspend fun requestEmailCode(request: EmailCodeRequest): EmailCodeSent =
        client.post("${tokens.serverUrl}/v1/auth/email/code") {
            baseHeaders()
            contentType(ContentType.Application.Json)
            setBody(request)
        }.bodyOrThrow { text -> OrdoJson.instance.decodeFromString(EmailCodeSent.serializer(), text) }

    /**
     * 邮箱验证码登录(契约 §7.6.5):`POST /v1/auth/email/login` → 200,响应与 register / login / guest
     * **同构**(同一 userId、同一份云端数据、同一套 refreshToken 体系);未注册邮箱由服务端自动建号。
     */
    override suspend fun emailLogin(request: EmailCodeLoginRequest): AuthResponse =
        client.post("${tokens.serverUrl}/v1/auth/email/login") {
            baseHeaders()
            contentType(ContentType.Application.Json)
            setBody(request)
        }.bodyOrThrow { text -> OrdoJson.instance.decodeFromString(AuthResponse.serializer(), text) }

    /**
     * 退出登录(204 无响应体)。
     *
     * 显式传 refreshToken:退出时我们**先清本地会话再发请求**(不能因为网络阻塞就不退),
     * 所以这里不能依赖读 [TokenStore] 的当前值。
     */
    suspend fun logout(refreshToken: String? = tokens.refreshToken) {
        val token = refreshToken ?: return
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
