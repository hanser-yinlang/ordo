package com.ordo.android

import com.ordo.android.auth.SessionPlan
import com.ordo.android.auth.SilentSessionRules
import com.ordo.android.net.OrdoAuthError
import com.ordo.core.sync.OrdoApiException
import com.ordo.core.sync.OrdoSession
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 静默匿名会话（产品决策 v1.3：不再有登录界面）的纯逻辑验收。
 *
 * 覆盖：① 启动处置（有效会话直接用 / 过期先续期 / 无会话或残缺 → 静默建号）；
 * ② 只有服务端明确否认（401）才算会话失效，网络类错误一律离线继续；
 * ③ 静默建号的退避序列（1s→2s→…→60s 封顶，不溢出）。
 *
 * 「本地数据目录标识」（契约 §7.6.6）的用例见 [LocalAccountTest]。
 */
class SilentSessionTest {

    private val now = 1_759_900_000_000L

    private fun session(
        userId: String = "u-1",
        accessToken: String = "access-1",
        refreshToken: String = "refresh-1",
        expiresAt: Long = now + 60_000L,
    ) = OrdoSession(
        userId = userId,
        email = null,
        isGuest = true,
        accessToken = accessToken,
        refreshToken = refreshToken,
        expiresAt = expiresAt,
    )

    /* ------------------------- ① 启动处置 ------------------------- */

    @Test
    fun `没有会话时静默建匿名账号而不是去登录页`() {
        assertEquals(SessionPlan.CreateAnonymous, SilentSessionRules.plan(null, now))
    }

    @Test
    fun `会话残缺时静默重建`() {
        assertEquals(SessionPlan.CreateAnonymous, SilentSessionRules.plan(session(userId = ""), now))
        assertEquals(SessionPlan.CreateAnonymous, SilentSessionRules.plan(session(accessToken = ""), now))
        assertEquals(SessionPlan.CreateAnonymous, SilentSessionRules.plan(session(refreshToken = ""), now))
    }

    @Test
    fun `有效会话直接进主界面并后台静默续期`() {
        val plan = SilentSessionRules.plan(session(), now)
        assertTrue(plan is SessionPlan.UseExisting)
        assertEquals("u-1", (plan as SessionPlan.UseExisting).session.userId)
        assertTrue("后台静默 refresh 不阻塞使用", plan.silentRefresh)
    }

    @Test
    fun `accessToken过期先续期`() {
        val plan = SilentSessionRules.plan(session(expiresAt = now - 1L), now)
        assertTrue(plan is SessionPlan.RefreshFirst)
        assertEquals("u-1", (plan as SessionPlan.RefreshFirst).session.userId)
    }

    /* ------------------- ② 会话失效 vs 网络故障 ------------------- */

    @Test
    fun `只有服务端明确否认才算会话失效`() {
        assertTrue(SilentSessionRules.isSessionDenied("AUTH_REQUIRED"))
        assertTrue(SilentSessionRules.isSessionDenied("AUTH_TOKEN_EXPIRED"))
        assertFalse("网络不可达不是会话失效（离线继续可用）", SilentSessionRules.isSessionDenied(null))
        assertFalse(SilentSessionRules.isSessionDenied("INTERNAL"))
        assertFalse(SilentSessionRules.isSessionDenied("RATE_LIMITED"))
        assertFalse(SilentSessionRules.isSessionDenied("SYNC_SEQ_GAP"))
    }

    @Test
    fun `从异常里取契约错误码`() {
        assertEquals("AUTH_REQUIRED", SilentSessionRules.errorCodeOf(OrdoApiException("AUTH_REQUIRED", "需要登录")))
        assertEquals(
            "带 details 的认证错误同样取到 code",
            "RATE_LIMITED",
            SilentSessionRules.errorCodeOf(OrdoAuthError("RATE_LIMITED", "code_throttled", 60L, "太频繁")),
        )
        assertNull("网络异常没有契约错误码", SilentSessionRules.errorCodeOf(IOException("连接超时")))
        assertNull(SilentSessionRules.errorCodeOf(null))
    }

    /* ------------------------- ③ 退避序列 ------------------------- */

    @Test
    fun `退避从1秒翻倍到60秒封顶`() {
        assertEquals(1_000L, SilentSessionRules.backoffMillis(0))
        assertEquals(2_000L, SilentSessionRules.backoffMillis(1))
        assertEquals(4_000L, SilentSessionRules.backoffMillis(2))
        assertEquals(8_000L, SilentSessionRules.backoffMillis(3))
        assertEquals(16_000L, SilentSessionRules.backoffMillis(4))
        assertEquals(32_000L, SilentSessionRules.backoffMillis(5))
        assertEquals(60_000L, SilentSessionRules.backoffMillis(6))
        assertEquals("超过上限一律封顶", 60_000L, SilentSessionRules.backoffMillis(7))
        assertEquals(60_000L, SilentSessionRules.backoffMillis(1_000))
    }

    @Test
    fun `退避单调不减且永不溢出`() {
        var previous = 0L
        for (attempt in 0..200) {
            val value = SilentSessionRules.backoffMillis(attempt)
            assertTrue("第 $attempt 次退避必须落在 [1s, 60s]", value in 1_000L..60_000L)
            assertTrue("退避必须单调不减", value >= previous)
            previous = value
        }
        assertEquals("负数按第 0 次算", 1_000L, SilentSessionRules.backoffMillis(-3))
    }
}
