package com.ordo.android.net

import com.ordo.core.sync.OrdoApiException
import com.ordo.core.sync.ReminderPush
import com.ordo.core.util.OrdoJson
import io.ktor.client.statement.HttpResponse
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/* ============================================================================
 * HTTP / WebSocket 传输辅助（契约 §7.4 / §7.5）
 *
 * 说明：请求/响应实体一律复用 shared:core 的 @Serializable DTO
 * （PushRequest / PushResponse / PullResponse / SnapshotResponse / AuthRequest / AuthResponse …），
 * 由 Ktor 的 ContentNegotiation 直接编解码；这里只处理"信封外层"的东西：
 * 统一请求头、错误模型、WebSocket 帧。
 * ========================================================================== */

/** 契约 §7.4 统一请求头 */
object OrdoHeaders {
    const val SCHEMA = "X-Ordo-Schema"
    const val DEVICE = "X-Ordo-Device"
    const val CLIENT = "X-Ordo-Client"
}

/**
 * 解析错误模型 `{ "error": { "code": …, "message": … } }`。
 * 兼容直接返回 `{ "code": …, "message": … }` 的形式。
 */
fun parseApiError(body: String): OrdoApiException? {
    val root = runCatching { OrdoJson.instance.parseToJsonElement(body).jsonObject }.getOrNull() ?: return null
    val errorObj: JsonObject = root["error"]?.let { runCatching { it.jsonObject }.getOrNull() } ?: root
    val code = errorObj["code"]?.jsonPrimitive?.contentOrNull ?: return null
    val message = errorObj["message"]?.jsonPrimitive?.contentOrNull.orEmpty()
    return OrdoApiException(code, message)
}

/** 非 2xx 时抛结构化错误（无错误体时抛 INTERNAL） */
fun HttpResponse.throwIfError(body: String) {
    if (status.value in 200..299) return
    throw parseApiError(body) ?: OrdoApiException("INTERNAL", "HTTP ${status.value}")
}

/* ------------------------------ WebSocket ------------------------------ */

/** 契约 §7.5 服务端下行消息 */
sealed interface WsInbound {
    data class Hello(val serverSeq: Long, val serverTime: Long) : WsInbound
    data class Ops(val serverSeq: Long, val opsJson: String) : WsInbound
    data class Reminder(val push: ReminderPush) : WsInbound
    data object Ping : WsInbound
    data object Unknown : WsInbound
}

fun parseWsInbound(raw: String): WsInbound {
    val root = runCatching { OrdoJson.instance.parseToJsonElement(raw).jsonObject }.getOrNull()
        ?: return WsInbound.Unknown
    fun str(key: String) = root[key]?.jsonPrimitive?.contentOrNull
    fun long(key: String) = str(key)?.toLongOrNull() ?: 0L
    return when (str("type")) {
        "hello" -> WsInbound.Hello(long("serverSeq"), long("serverTime"))
        "ops" -> WsInbound.Ops(long("serverSeq"), root["ops"]?.toString() ?: "[]")
        "reminder" -> WsInbound.Reminder(
            ReminderPush(
                todoId = str("todoId").orEmpty(),
                title = str("title").orEmpty(),
                at = str("at").orEmpty(),
            ),
        )
        "ping" -> WsInbound.Ping
        else -> WsInbound.Unknown
    }
}

/** 客户端上行：subscribe（契约 §7.5） */
fun wsSubscribeFrame(deviceId: String): String =
    """{"type":"subscribe","deviceId":"$deviceId"}"""

/** 客户端上行：ack serverSeq */
fun wsAckFrame(serverSeq: Long): String =
    """{"type":"ack","serverSeq":$serverSeq}"""

/** 客户端上行：pong */
const val WS_PONG_FRAME: String = """{"type":"pong"}"""
