package com.ordo.android.net

import com.ordo.android.BuildConfig
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.plugins.defaultRequest
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import io.ktor.serialization.kotlinx.json.json
import com.ordo.core.util.OrdoJson

/**
 * 契约 §7.4 统一请求头：
 *   X-Ordo-Schema: 1 · X-Ordo-Device: <deviceId> · X-Ordo-Client: android/1.0.0
 * Authorization 由各请求自行附加（认证接口不带）。
 *
 * JSON 行为必须与四端一致，因此序列化直接用共享核心的 OrdoJson.instance。
 */
class HttpClientFactory(
    private val deviceIdProvider: () -> String,
) {
    fun create(): HttpClient = HttpClient(OkHttp) {
        expectSuccess = false

        install(HttpTimeout) {
            connectTimeoutMillis = 10_000
            requestTimeoutMillis = 20_000
            socketTimeoutMillis = 30_000
        }

        install(ContentNegotiation) {
            json(OrdoJson.instance)
        }

        install(WebSockets)

        defaultRequest {
            contentType(ContentType.Application.Json)
            headers.append(HttpHeaders.Accept, ContentType.Application.Json.toString())
            headers.append(OrdoHeaders.SCHEMA, BuildConfig.ORDO_SCHEMA)
            headers.append(OrdoHeaders.CLIENT, BuildConfig.ORDO_CLIENT)
            headers.append(OrdoHeaders.DEVICE, deviceIdProvider())
        }
    }
}
