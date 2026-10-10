package com.ordo.desktop.net

import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.sync.EmailCodeLoginRequest
import com.ordo.core.sync.EmailCodeRequest
import com.ordo.core.sync.EmailCodeSent
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `KtorAuthApi` 的两个新方法(契约 §7.6.5)与错误信封解析。
 *
 * 用 JDK 自带的 `HttpServer` 起一个**只在 127.0.0.1 随机端口**的临时服务端,拿真实 Ktor CIO 客户端打:
 * 这样连路径、请求体、错误信封的字段位置一起验,而不是只测一个解析函数。
 * 每个用例都在 finally 里 `stop(0)` 停服(不留占端口的进程),客户端也显式关闭。
 */
class OrdoHttpErrorTest {

    private val routes = mutableMapOf<String, Pair<Int, String>>()

    private fun serve(status: Int, body: String) = status to body

    /** 起服务端 → 跑用例 → 无论如何都停服 */
    private fun withServer(block: (baseUrl: String) -> Unit) {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange: HttpExchange ->
            exchange.use {
                val hit = routes[it.requestURI.path]
                if (hit == null) {
                    respond(it, 404, """{"error":{"code":"NOT_FOUND","message":"no route"}}""")
                } else {
                    respond(it, hit.first, hit.second)
                }
            }
        }
        server.executor = null
        server.start()
        try {
            block("http://127.0.0.1:${server.address.port}")
        } finally {
            server.stop(0)
        }
    }

    private fun respond(exchange: HttpExchange, status: Int, body: String) {
        // 请求体必须读完,否则连接复用时会串到下一个请求
        exchange.requestBody.readBytes()
        val bytes = body.toByteArray(StandardCharsets.UTF_8)
        exchange.responseHeaders.add("Content-Type", "application/json; charset=utf-8")
        exchange.sendResponseHeaders(status, bytes.size.toLong())
        exchange.responseBody.use { it.write(bytes) }
    }

    private fun api(baseUrl: String): KtorAuthApi {
        val tokens = TokenStore(InMemoryStorage())
        tokens.serverUrl = baseUrl
        return KtorAuthApi(OrdoHttp.create(), tokens)
    }

    @Test
    fun `429 限流错误按 details 读出 reason 与 retryAfterSec`() {
        routes["/v1/auth/email/code"] = serve(
            429,
            """{"error":{"code":"RATE_LIMITED","message":"too many requests","details":{"reason":"code_throttled","retryAfterSec":42}}}"""
        )
        withServer { baseUrl ->
            val client = api(baseUrl)
            val error = assertThrows(OrdoHttpException::class.java) {
                runBlocking { client.requestEmailCode(EmailCodeRequest("me@ordo.app")) }
            }

            assertEquals("RATE_LIMITED", error.code)
            assertEquals("code_throttled", error.reason)
            assertEquals("错误体里是 details.retryAfterSec", 42L, error.retryAfterSec)
            assertEquals(42L, retryAfterSecondsOf(error))
            assertEquals("RATE_LIMITED", errorCodeOf(error))
            assertEquals("code_throttled", errorReasonOf(error))
        }
    }

    @Test
    fun `限流错误没给秒数时回落契约默认 60`() {
        routes["/v1/auth/email/code"] = serve(
            429,
            """{"error":{"code":"RATE_LIMITED","message":"slow down","details":{"reason":"code_throttled"}}}"""
        )
        withServer { baseUrl ->
            val client = api(baseUrl)
            val error = assertThrows(OrdoHttpException::class.java) {
                runBlocking { client.requestEmailCode(EmailCodeRequest("me@ordo.app")) }
            }
            assertNull("没有就不要瞎猜", error.retryAfterSec)
            assertEquals("兜底 60s", 60L, retryAfterSecondsOf(error))
        }
    }

    @Test
    fun `401 错码错误带上 reason,没有秒数`() {
        routes["/v1/auth/email/login"] = serve(
            401,
            """{"error":{"code":"AUTH_INVALID_CREDENTIALS","message":"bad code","details":{"reason":"code_expired"}}}"""
        )
        withServer { baseUrl ->
            val client = api(baseUrl)
            val error = assertThrows(OrdoHttpException::class.java) {
                runBlocking {
                    client.emailLogin(
                        EmailCodeLoginRequest(
                            email = "me@ordo.app",
                            code = "123456",
                            deviceName = "Ordo Windows",
                            platform = "windows"
                        )
                    )
                }
            }

            assertEquals("AUTH_INVALID_CREDENTIALS", error.code)
            assertEquals("code_expired", error.reason)
            assertNull("这个场景没有限流秒数", error.retryAfterSec)
        }
    }

    @Test
    fun `没有 details 的错误退化为纯错误码,不抛解码异常`() {
        routes["/v1/auth/email/code"] = serve(500, """{"error":{"code":"INTERNAL","message":"boom"}}""")
        withServer { baseUrl ->
            val client = api(baseUrl)
            val error = assertThrows(OrdoHttpException::class.java) {
                runBlocking { client.requestEmailCode(EmailCodeRequest("me@ordo.app")) }
            }
            assertEquals("INTERNAL", error.code)
            assertNull(error.reason)
            assertNull(error.retryAfterSec)
            assertNull("不是 HTTP 兜底码", error.httpCode)
        }
    }

    @Test
    fun `非 JSON 错误体也退化成 HTTP 兜底码`() {
        routes["/v1/auth/email/code"] = serve(502, "<html>bad gateway</html>")
        withServer { baseUrl ->
            val client = api(baseUrl)
            val error = assertThrows(OrdoHttpException::class.java) {
                runBlocking { client.requestEmailCode(EmailCodeRequest("me@ordo.app")) }
            }
            assertEquals("HTTP_502", error.code)
            assertEquals("HTTP_502", error.httpCode)
            assertNull(error.reason)
        }
    }

    @Test
    fun `成功响应解析出 sent expiresIn retryAfter 与 devCode`() {
        routes["/v1/auth/email/code"] = serve(
            202,
            """{"sent":true,"expiresIn":300,"retryAfter":60,"devCode":"654321"}"""
        )
        withServer { baseUrl ->
            val client = api(baseUrl)
            val sent = runBlocking { client.requestEmailCode(EmailCodeRequest("me@ordo.app")) }
            assertEquals(EmailCodeSent(sent = true, expiresIn = 300, retryAfter = 60, devCode = "654321"), sent)
        }
    }

    @Test
    fun `成功响应不带 devCode 时它是 null,并且请求打到正确路径`() {
        val seen = StringBuilder()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange: HttpExchange ->
            exchange.use {
                seen.append(it.requestURI.path)
                respond(it, 202, """{"sent":true,"expiresIn":300,"retryAfter":60}""")
            }
        }
        server.start()
        try {
            val client = api("http://127.0.0.1:${server.address.port}")
            val sent = runBlocking { client.requestEmailCode(EmailCodeRequest("me@ordo.app")) }

            assertEquals("路径必须与契约一致", "/v1/auth/email/code", seen.toString())
            assertNull("生产环境绝不回显验证码", sent.devCode)
            assertEquals(60L, sent.retryAfter)
            assertEquals(300L, sent.expiresIn)
            assertTrue(sent.sent)
        } finally {
            server.stop(0)
        }
    }
}
