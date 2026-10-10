package com.ordo.android.net

import com.ordo.core.util.OrdoJson
import io.ktor.client.statement.HttpResponse
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/* ============================================================================
 * 认证接口错误（契约 §7.4 错误模型 + §7.6.5 的 `details`）
 *
 * shared:core 的 `OrdoApiException` 是 final 且只带 code/message，装不下
 * `details.reason` / `details.retryAfterSec`；验证码登录必须按 reason 给精确中文提示
 * （code_invalid / code_expired / code_attempts_exceeded / code_throttled / mail_failed），
 * 因此在 Android 端做一层解析，不改动 shared。
 * ========================================================================== */

/**
 * 认证接口的结构化错误。
 *
 * @param code 契约 §7.4 的冻结错误码（与 [com.ordo.core.sync.OrdoApiException.code] 同源）
 * @param reason `details.reason`：更精确的原因（契约 §7.6.5；缺失即 null）
 * @param retryAfterSeconds `details.retryAfterSec`（整数秒，与 §7.4 全局限流同名）：
 *   限流时建议的重试间隔；兼容 `details.retryAfter` 与根 `retryAfter` 兜底
 */
class OrdoAuthError(
    val code: String,
    val reason: String? = null,
    val retryAfterSeconds: Long? = null,
    override val message: String = "",
) : Exception(message)

/** `details` 里客户端用得到的字段 */
data class ApiErrorDetails(val reason: String?, val retryAfterSeconds: Long?)

/**
 * 解析 `{error:{code,message,details:{reason,retryAfterSec}}}`（兼容 details 直接挂在根节点）。
 *
 * 限流秒数按契约澄清读 `error.details.retryAfterSec`（整数秒，与 §7.4 全局限流同名），
 * 并保留 `details.retryAfter` 与根 `retryAfter` 作为兜底：
 * **details.retryAfterSec > details.retryAfter > 根 retryAfter**。
 *
 * 注意区分：成功响应体顶层的 `retryAfter`（`202 {sent,expiresIn,retryAfter}`，见
 * [com.ordo.core.sync.EmailCodeSent]）是另一处，与错误体里的 `details.retryAfterSec` 无关。
 */
fun parseErrorDetails(body: String): ApiErrorDetails {
    val root = runCatching { OrdoJson.instance.parseToJsonElement(body).jsonObject }.getOrNull()
        ?: return ApiErrorDetails(null, null)
    val scope: JsonObject = root["error"]?.let { runCatching { it.jsonObject }.getOrNull() } ?: root
    val details = scope["details"]?.let { runCatching { it.jsonObject }.getOrNull() }
    val reason = details?.get("reason")?.jsonPrimitive?.contentOrNull
        ?: scope["reason"]?.jsonPrimitive?.contentOrNull
    val retryAfter = details?.get("retryAfterSec")?.jsonPrimitive?.longOrNull
        ?: details?.get("retryAfter")?.jsonPrimitive?.longOrNull
        ?: scope["retryAfter"]?.jsonPrimitive?.longOrNull
    return ApiErrorDetails(reason?.takeIf { it.isNotBlank() }, retryAfter)
}

/** 非 2xx 时抛 [OrdoAuthError]：保留 code，并带上 details.reason / retryAfterSec */
fun HttpResponse.throwAuthError(body: String) {
    if (status.value in 200..299) return
    val base = parseApiError(body)
    val details = parseErrorDetails(body)
    throw OrdoAuthError(
        code = base?.code ?: OrdoErrors.INTERNAL,
        reason = details.reason,
        retryAfterSeconds = details.retryAfterSeconds,
        message = base?.message?.takeIf { it.isNotBlank() } ?: "HTTP ${status.value}",
    )
}
