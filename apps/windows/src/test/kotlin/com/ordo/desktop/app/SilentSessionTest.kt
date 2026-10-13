package com.ordo.desktop.app

import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.DeviceDto
import com.ordo.core.sync.GuestAuthRequest
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.OrdoSessionStore
import com.ordo.core.sync.UserDto
import com.ordo.desktop.net.SilentAuthApi
import com.ordo.desktop.net.TokenStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 静默匿名会话(产品决策:不再需要登录)。
 *
 * 这一层代替了原来的"登录门禁":启动时读会话 → 有效直接用;过期先 refresh;失败或没有 → 静默建匿名账号;
 * 网络不可达照常离线可用并后台退避重试。全程**没有任何界面**,所以这里断言的全是状态与调用,而不是 UI。
 */
class SilentSessionTest {

    /** 可编排的静默 auth:记录调用、可失败、可挂起(inner:需要访问外层的 authResponse 构造器) */
    private inner class FakeSilentAuthApi(
        var refreshResult: (() -> AuthResponse)? = null,
        var guestResult: (() -> AuthResponse)? = null,
        var refreshFailure: Throwable? = null,
        var guestFailure: Throwable? = null,
        var gate: CompletableDeferred<Unit>? = null
    ) : SilentAuthApi {

        var refreshCalls = 0
        var guestCalls = 0
        var lastGuestRequest: GuestAuthRequest? = null

        override suspend fun refresh(refreshToken: String): AuthResponse {
            refreshCalls += 1
            gate?.await()
            refreshFailure?.let { throw it }
            return refreshResult?.invoke() ?: authResponse("u-refreshed", guest = false)
        }

        override suspend fun guest(request: GuestAuthRequest): AuthResponse {
            guestCalls += 1
            lastGuestRequest = request
            gate?.await()
            guestFailure?.let { throw it }
            return guestResult?.invoke() ?: authResponse("u-anon", guest = true)
        }
    }

    private fun authResponse(userId: String, guest: Boolean) = AuthResponse(
        user = UserDto(id = userId, email = if (guest) null else "me@ordo.app", isGuest = guest),
        device = DeviceDto("dev_1", "Ordo Windows", "windows"),
        accessToken = "at-$userId",
        refreshToken = "rt-$userId",
        expiresIn = 1_800L
    )

    private fun session(userId: String = "u-old", expiresAt: Long = 10_000L) = OrdoSession(
        userId = userId,
        email = null,
        isGuest = true,
        accessToken = "at-old",
        refreshToken = "rt-old",
        expiresAt = expiresAt
    )

    private fun keeper(
        api: SilentAuthApi,
        storage: InMemoryStorage = InMemoryStorage(),
        now: Long = 5_000L,
        scope: CoroutineScope = CoroutineScope(Dispatchers.Unconfined),
        onSession: (OrdoSession) -> Unit = {}
    ): Pair<SilentSessionKeeper, TokenStore> {
        val tokens = TokenStore(storage)
        val keeper = SilentSessionKeeper(
            api = api,
            tokens = tokens,
            scope = scope,
            now = { now },
            // 退避在测试里即时返回:否则重试一次就要真等 1s/2s…
            sleeper = { },
            onSession = onSession
        )
        return keeper to tokens
    }

    // ------------------------------------------------------------ 纯判定

    @Test
    fun `启动落点——没有会话建匿名,过期先续期,有效直接用`() {
        assertEquals(SessionAction.CREATE_ANONYMOUS, SilentSession.actionFor(null, 1_000L))
        assertEquals(SessionAction.REFRESH_SESSION, SilentSession.actionFor(session(expiresAt = 500L), 1_000L))
        assertEquals(SessionAction.USE_SESSION, SilentSession.actionFor(session(expiresAt = 9_000L), 1_000L))
    }

    @Test
    fun `后台重试退避是 1s_2s_4s_上限 60s`() {
        assertEquals(1_000L, SilentSession.backoffMillis(1))
        assertEquals(2_000L, SilentSession.backoffMillis(2))
        assertEquals(4_000L, SilentSession.backoffMillis(3))
        assertEquals(60_000L, SilentSession.backoffMillis(10))
        assertEquals("attempt 从 1 起,0 与负数都按第一次算", 1_000L, SilentSession.backoffMillis(0))
    }

    // ------------------------------------------------------------ 一次性尝试

    @Test
    fun `有有效会话时一次网络请求都不发`() {
        val api = FakeSilentAuthApi()
        val (keeper, tokens) = keeper(api)
        tokens.saveSession(session(expiresAt = 9_000L))

        assertTrue("有效会话直接用", runBlocking { keeper.ensure() })
        assertEquals(0, api.guestCalls)
        assertEquals(0, api.refreshCalls)
        assertEquals("会话没被改写", "u-old", tokens.currentSession()!!.userId)
        assertTrue(keeper.hasSession)
    }

    @Test
    fun `会话过期先静默续期,成功后写回新会话`() {
        val api = FakeSilentAuthApi()
        val (keeper, tokens) = keeper(api)
        tokens.saveSession(session(expiresAt = 500L))

        assertTrue(runBlocking { keeper.ensure() })

        assertEquals(1, api.refreshCalls)
        assertEquals("续期成功就不该再建匿名", 0, api.guestCalls)
        val now = tokens.currentSession()!!
        assertEquals("u-refreshed", now.userId)
        assertEquals("过期时刻 = now + 1800s", 5_000L + 1_800_000L, now.expiresAt)
    }

    @Test
    fun `续期失败就静默换匿名账号,不留半个会话`() {
        val api = FakeSilentAuthApi(refreshFailure = IllegalStateException("token revoked"))
        val (keeper, tokens) = keeper(api)
        tokens.saveSession(session(expiresAt = 500L))

        assertTrue(runBlocking { keeper.ensure() })

        assertEquals(1, api.refreshCalls)
        assertEquals("刷不动就换匿名账号", 1, api.guestCalls)
        val now = tokens.currentSession()!!
        assertEquals("u-anon", now.userId)
        assertTrue("匿名账号同样是正常令牌(不是受限模式)", now.isGuest)
        assertEquals("at-u-anon", now.accessToken)
    }

    @Test
    fun `没有会话时直接建匿名账号,并带上设备信息`() {
        val api = FakeSilentAuthApi()
        val (keeper, tokens) = keeper(api)

        assertTrue(runBlocking { keeper.ensure() })

        assertEquals(0, api.refreshCalls)
        assertEquals(1, api.guestCalls)
        assertEquals("windows", api.lastGuestRequest!!.platform)
        assertEquals("Ordo Windows", api.lastGuestRequest!!.deviceName)
        assertNull("匿名请求不带 deviceId(由服务端分配)", api.lastGuestRequest!!.deviceId)
        assertEquals("u-anon", tokens.currentSession()!!.userId)
    }

    // ------------------------------------------------------------ 离线:不阻塞、可恢复

    @Test
    fun `网络不可达——不抛异常、不留会话、返回 false(界面照常可用)`() {
        val api = FakeSilentAuthApi(guestFailure = java.net.ConnectException("connection refused"))
        val (keeper, tokens) = keeper(api)

        assertFalse("拿不到会话也不该把异常抛给启动流程", runBlocking { keeper.ensure() })
        assertNull("不能留下半个会话", tokens.currentSession())
        assertFalse(keeper.hasSession)
    }

    @Test
    fun `后台守护——先离线失败,网络恢复后自动拿到会话`() {
        // 第一次 guest 失败,第二次成功 —— 模拟"启动时断网,随后联网"
        var attempts = 0
        val api = object : SilentAuthApi {
            override suspend fun refresh(refreshToken: String): AuthResponse = error("no session to refresh")
            override suspend fun guest(request: GuestAuthRequest): AuthResponse {
                attempts += 1
                if (attempts == 1) throw java.net.ConnectException("offline")
                return authResponse("u-anon", guest = true)
            }
        }
        val scope = CoroutineScope(Dispatchers.Unconfined)
        val (keeper, tokens) = keeper(api, scope = scope)

        keeper.start()
        // sleeper 即时返回,Unconfined 下整个重试循环同步跑完
        assertEquals("重试到成功为止", 2, attempts)
        assertNotNull("最终必须拿到会话", tokens.currentSession())
        assertEquals("u-anon", tokens.currentSession()!!.userId)
        keeper.stop()
    }

    @Test
    fun `后台守护拿到会话只回调一次`() {
        val seen = mutableListOf<String>()
        val api = FakeSilentAuthApi()
        val scope = CoroutineScope(Dispatchers.Unconfined)
        val (keeper, _) = keeper(api, scope = scope, onSession = { seen.add(it.userId) })

        keeper.start()
        keeper.start() // 幂等:重复调用不该再起一个协程/再拿一次会话

        assertEquals(listOf("u-anon"), seen)
        assertEquals(1, api.guestCalls)
        keeper.stop()
    }

    // ------------------------------------------------------------ 同步 401:静默重建

    @Test
    fun `同步遇 401——先续期,续期失败再建匿名账号`() {
        val refreshed = FakeSilentAuthApi()
        val (keeperA, tokensA) = keeper(refreshed)
        tokensA.saveSession(session(expiresAt = 9_000L))
        assertTrue(runBlocking { keeperA.recover() })
        assertEquals("还能续期就续期", 1, refreshed.refreshCalls)
        assertEquals(0, refreshed.guestCalls)

        val revoked = FakeSilentAuthApi(refreshFailure = IllegalStateException("revoked"))
        val (keeperB, tokensB) = keeper(revoked)
        tokensB.saveSession(session(expiresAt = 9_000L))
        assertTrue("续期失败也要能恢复(否则同步会永久 401)", runBlocking { keeperB.recover() })
        assertEquals(1, revoked.guestCalls)
        assertEquals("u-anon", tokensB.currentSession()!!.userId)
    }

    @Test
    fun `恢复过程网络中断不抛异常,只是返回 false`() {
        val api = FakeSilentAuthApi(
            refreshFailure = java.net.ConnectException("offline"),
            guestFailure = java.net.ConnectException("still offline")
        )
        val (keeper, tokens) = keeper(api)
        tokens.saveSession(session(expiresAt = 9_000L))

        assertFalse("离线时同步这一轮放弃,下一轮再试", runBlocking { keeper.recover() })
        assertNotNull("原会话不清掉:离线仍要能用本地数据", tokens.currentSession())
    }

    // ------------------------------------------------------------ awaitSession

    @Test
    fun `awaitSession 会等到后台守护拿到会话`() {
        val gate = CompletableDeferred<Unit>()
        val api = FakeSilentAuthApi(gate = gate)
        val scope = CoroutineScope(Dispatchers.Unconfined)
        val (keeper, tokens) = keeper(api, scope = scope)

        var waited = false
        val waiter = scope.launch {
            keeper.awaitSession()
            waited = true
        }

        keeper.start()
        assertFalse("拿到会话之前不该放行", waited)

        gate.complete(Unit)
        runBlocking { waiter.join() }

        assertTrue("会话到手就放行", waited)
        assertNotNull(tokens.currentSession())
        keeper.stop()
    }

    @Test
    fun `已经有会话时 awaitSession 立刻返回`() {
        val (keeper, tokens) = keeper(FakeSilentAuthApi())
        tokens.saveSession(session())
        assertTrue(runBlocking { keeper.awaitSession() })
    }

    @Test
    fun `SessionRecovery_NONE 是安全的空实现`() {
        assertFalse(runBlocking { SessionRecovery.NONE.recover() })
        assertFalse(runBlocking { SessionRecovery.NONE.awaitSession() })
    }

    /** 会话与目录的口径:重建会话**不**换数据目录(目录由入口钉住的 id 决定) */
    @Test
    fun `重建匿名会话不会改变数据目录 id`() {
        val storage = InMemoryStorage()
        val tokens = TokenStore(storage)
        tokens.saveSession(session(userId = "u-old"))
        val pinned = com.ordo.desktop.data.UserDataDirs.resolveDataDirId(storage, tokens.currentSession()?.userId)
        assertEquals("u-old", pinned)

        val api = FakeSilentAuthApi(refreshFailure = IllegalStateException("revoked"))
        val keeper = SilentSessionKeeper(api = api, tokens = tokens, scope = CoroutineScope(Dispatchers.Unconfined), sleeper = { })
        assertTrue(runBlocking { keeper.recover() })
        assertEquals("会话换了,但目录 id 依旧钉住", "u-anon", tokens.currentSession()!!.userId)
        assertEquals(
            pinned,
            com.ordo.desktop.data.UserDataDirs.resolveDataDirId(storage, tokens.currentSession()?.userId)
        )
    }

    /** 会话写入的落点就是 kv[ordo.session](与共享核心同一口径) */
    @Test
    fun `匿名会话写进 kv_ordo_session`() {
        val storage = InMemoryStorage()
        val (keeper, tokens) = keeper(FakeSilentAuthApi(), storage = storage)
        runBlocking { keeper.ensure() }
        assertEquals(
            tokens.currentSession(),
            OrdoSessionStore(storage).load()
        )
    }
}
