package com.ordo.android.net

import com.ordo.core.model.Op
import com.ordo.core.sync.RealtimeChannel
import com.ordo.core.sync.ReminderPush
import com.ordo.core.util.OrdoJson
import io.ktor.client.HttpClient
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.websocket.Frame
import io.ktor.websocket.readText
import io.ktor.websocket.send
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer

/**
 * 契约 §7.5 实时通道（shared:core 的 [RealtimeChannel] 接口）。
 *
 *   ws(s)://<host>/v1/ws?token=<accessToken>
 *   下行：hello / ops / reminder(Fastlane) / ping
 *   上行：subscribe(deviceId) / ack(serverSeq) / pong
 *
 * 断线重连：指数退避 1s → 2s → 4s … 上限 60s，连上后重置。
 */
class RealtimeClient(
    private val client: HttpClient,
    private val tokens: TokenStore,
    private val auth: OrdoAuthApi,
) : RealtimeChannel {

    private var job: Job? = null
    private var attempt = 0

    /** 由 ServiceLocator 在应用启动时调用（在给定 scope 内长期运行） */
    fun start(
        scope: CoroutineScope,
        deviceId: String,
        onOps: (List<Op>, Long) -> Unit,
        onReminder: (ReminderPush) -> Unit,
    ) {
        if (job?.isActive == true) return
        job = scope.launch {
            runCatching { connect(deviceId, onOps, onReminder) }
        }
    }

    override suspend fun connect(
        deviceId: String,
        onOps: (List<Op>, Long) -> Unit,
        onReminder: (ReminderPush) -> Unit,
    ) {
        while (true) {
            val token = tokens.accessToken()
            if (token.isNullOrBlank()) return
            try {
                client.webSocket(wsUrl(tokens.serverUrl(), token)) {
                    attempt = 0
                    send(wsSubscribeFrame(deviceId))
                    for (frame in incoming) {
                        if (frame !is Frame.Text) continue
                        when (val message = parseWsInbound(frame.readText())) {
                            is WsInbound.Hello -> Unit
                            is WsInbound.Ops -> {
                                decodeOps(message.opsJson).takeIf { it.isNotEmpty() }?.let { ops ->
                                    onOps(ops, message.serverSeq)
                                }
                                runCatching { send(wsAckFrame(message.serverSeq)) }
                            }
                            is WsInbound.Reminder -> onReminder(message.push)
                            WsInbound.Ping -> runCatching { send(WS_PONG_FRAME) }
                            WsInbound.Unknown -> Unit
                        }
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                // 连接异常：走退避重试；令牌过期时先尝试续期
                if (tokens.accessToken().isNullOrBlank()) return
                runCatching { auth.refreshSaved() }
            }
            attempt += 1
            delay(backoffMillis(attempt))
        }
    }

    override fun close() {
        job?.cancel()
        job = null
        attempt = 0
    }

    /** 应用回到前台 / 网络恢复时调用：立即重连一次 */
    fun restart(
        scope: CoroutineScope,
        deviceId: String,
        onOps: (List<Op>, Long) -> Unit,
        onReminder: (ReminderPush) -> Unit,
    ) {
        close()
        start(scope, deviceId, onOps, onReminder)
    }

    private fun decodeOps(raw: String): List<Op> = runCatching {
        OrdoJson.instance.decodeFromString(ListSerializer(Op.serializer()), raw)
    }.getOrDefault(emptyList())

    private fun wsUrl(base: String, token: String): String {
        val scheme = if (base.startsWith("https://")) "wss://" else "ws://"
        val host = base.removePrefix("https://").removePrefix("http://").trimEnd('/')
        return "$scheme$host/v1/ws?token=$token"
    }

    companion object {
        const val BASE_BACKOFF_MILLIS = 1_000L
        const val MAX_BACKOFF_MILLIS = 60_000L

        /** 指数退避：1s、2s、4s… 上限 60s */
        fun backoffMillis(attempt: Int): Long {
            val safe = attempt.coerceIn(1, 10)
            return (BASE_BACKOFF_MILLIS shl (safe - 1)).coerceAtMost(MAX_BACKOFF_MILLIS)
        }
    }
}
