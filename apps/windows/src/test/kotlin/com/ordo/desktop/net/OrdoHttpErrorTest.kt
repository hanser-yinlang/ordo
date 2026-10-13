package com.ordo.desktop.net

import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.sync.GuestAuthRequest
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 静默匿名会话的网络层(契约 §7.4 / §7.6.2)。
 *
 * 产品决策「不再需要登录」后,本端只剩两条 auth 请求:`/v1/auth/guest`(建匿名账号)与
 * `/v1/auth/refresh`(静默续期)。这里用 JDK 自带的 `HttpServer` 起一个**只在 127.0.0.1 随机端口**
 * 的临时服务端,拿真实 Ktor CIO 客户端打 —— 连路径、请求体、错误信封的字段位置一起验,
 * 而不是只测一个解析函数。每个用例都在 finally 里 `stop(0)` 停服(不留占端口的进程)。
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

    private fun authResponse(userId: String = "u-guest", guest: Boolean = true) =
        """
        {"user":{"id":"$userId","email":null,"isGuest":$guest},
         "device":{"id":"d-1","name":"Ordo Windows","platform":"windows"},
         "accessToken":"at","refreshToken":"rt","expiresIn":1800}
        """.trimIndent()

    // ------------------------------------------------------------ 成功路径

    @Test
    fun `匿名会话打到 guest 端点并解析出正常令牌`() {
        val seen = StringBuilder()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange: HttpExchange ->
            exchange.use {
                seen.append(it.requestURI.path).append(' ').append(it.requestMethod)
                respond(it, 200, authResponse())
            }
        }
        server.start()
        try {
            val client = api("http://127.0.0.1:${server.address.port}")
            val session = runBlocking {
                client.guest(GuestAuthRequest(deviceName = "Ordo Windows", platform = "windows"))
            }

            assertEquals("路径与方法必须与契约一致", "/v1/auth/guest POST", seen.toString())
            assertEquals("u-guest", session.user.id)
            assertTrue("匿名账号也是游客标记", session.user.isGuest)
            assertEquals("at", session.accessToken)
            assertEquals("rt", session.refreshToken)
            assertEquals(1_800L, session.expiresIn)
            assertNotNull(session.device)
        } finally {
            server.stop(0)
        }
    }

    @Test
    fun `静默续期打到 refresh 端点`() {
        val seen = StringBuilder()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange: HttpExchange ->
            exchange.use {
                seen.append(it.requestURI.path).append(' ').append(it.requestMethod)
                respond(it, 200, authResponse(userId = "u-1", guest = false))
            }
        }
        server.start()
        try {
            val client = api("http://127.0.0.1:${server.address.port}")
            val session = runBlocking { client.refresh("rt-old") }

            assertEquals("/v1/auth/refresh POST", seen.toString())
            assertEquals("u-1", session.user.id)
        } finally {
            server.stop(0)
        }
    }

    // ------------------------------------------------------------ 错误信封

    @Test
    fun `服务端错误信封解析出冻结错误码`() {
        routes["/v1/auth/guest"] = serve(
            401,
            """{"error":{"code":"AUTH_TOKEN_EXPIRED","message":"token expired"}}"""
        )
        withServer { baseUrl ->
            val client = api(baseUrl)
            val error = assertThrows(OrdoHttpException::class.java) {
                runBlocking { client.guest(GuestAuthRequest(deviceName = "d", platform = "windows")) }
            }

            assertEquals("AUTH_TOKEN_EXPIRED", error.code)
            assertEquals("token expired", error.message)
            assertEquals("AUTH_TOKEN_EXPIRED", errorCodeOf(error))
            assertNull("不是 HTTP 兜底码", error.httpCode)
        }
    }

    @Test
    fun `非 JSON 错误体退化成 HTTP 兜底码`() {
        routes["/v1/auth/guest"] = serve(502, "<html>bad gateway</html>")
        withServer { baseUrl ->
            val client = api(baseUrl)
            val error = assertThrows(OrdoHttpException::class.java) {
                runBlocking { client.guest(GuestAuthRequest(deviceName = "d", platform = "windows")) }
            }

            assertEquals("HTTP_502", error.code)
            assertEquals("HTTP_502", error.httpCode)
            assertEquals("HTTP_502", errorCodeOf(error))
        }
    }

    @Test
    fun `没有信封的 5xx 不抛解码异常`() {
        routes["/v1/auth/guest"] = serve(500, """{"unexpected":true}""")
        withServer { baseUrl ->
            val client = api(baseUrl)
            val error = assertThrows(OrdoHttpException::class.java) {
                runBlocking { client.guest(GuestAuthRequest(deviceName = "d", platform = "windows")) }
            }

            assertEquals("HTTP_500", error.code)
            assertTrue("要带上一段原始响应体便于定位", error.message.contains("unexpected"))
        }
    }

    @Test
    fun `网络不可达时抛的是 IO 异常而不是错误信封`() {
        // 端口 1 上什么都没有:静默会话守护会吞掉这种异常并退避重试(见 SilentSessionKeeper)
        val client = api("http://127.0.0.1:1")
        val error = assertThrows(Exception::class.java) {
            runBlocking { client.guest(GuestAuthRequest(deviceName = "d", platform = "windows")) }
        }
        assertNull("连不上服务端不是业务错误码", errorCodeOf(error))
    }
}
