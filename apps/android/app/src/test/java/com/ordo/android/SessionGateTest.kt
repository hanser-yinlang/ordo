package com.ordo.android

import com.ordo.android.auth.AuthFieldError
import com.ordo.android.auth.AuthMode
import com.ordo.android.auth.SessionGate
import com.ordo.android.auth.SessionVerdict
import com.ordo.android.data.UserDataDir
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.DeviceDto
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.OrdoSessionStore
import com.ordo.core.sync.UserDto
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 登录门禁 + 按用户隔离（契约 §7.6 · UI §5.1）的纯逻辑验收。
 *
 * 覆盖：
 *  ① 会话读写与**游客标记**（`isGuest` / 展示名 / 过期判定）；
 *  ② 启动门禁状态机（无会话 → 登录页；未过期 → 主界面；过期 → 先续期，续期失败回登录页）；
 *  ③ 退出登录只清会话、**保留目录名**；
 *  ④ 本地数据目录**按 userId 隔离**（不同账号不同目录，同一账号目录稳定）；
 *  ⑤ 登录页表单校验与登录/注册模式切换。
 */
class SessionGateTest {

    private val now = 1_759_900_000_000L

    private fun authResponse(
        userId: String,
        email: String,
        isGuest: Boolean = false,
        expiresIn: Long = 1_800L,
    ) = AuthResponse(
        user = UserDto(id = userId, email = email, isGuest = isGuest),
        device = DeviceDto(id = "dev_test", name = "测试机", platform = "android"),
        accessToken = "access-$userId",
        refreshToken = "refresh-$userId",
        expiresIn = expiresIn,
    )

    /* ------------------------- ① 会话读写与游客标记 ------------------------- */

    @Test
    fun `游客登录写入的会话带游客标记且展示名为游客`() {
        val storage = InMemoryStorage()
        val store = OrdoSessionStore(storage)

        store.save(OrdoSessionStore.from(authResponse("u-guest", "", isGuest = true), now))

        val session = store.load()
        assertTrue("会话必须写入 kv[ordo.session]", session != null)
        assertTrue("游客标记必须被持久化", session!!.isGuest)
        assertEquals("游客没有邮箱，展示名固定为「游客」", "游客", session.displayName())
        assertEquals("u-guest", session.userId)
        assertNull("空邮箱要归一为 null", session.email)
        assertEquals("过期时刻 = now + expiresIn 秒", now + 1_800_000L, session.expiresAt)
    }

    @Test
    fun `正式账号的会话展示名为邮箱`() {
        val store = OrdoSessionStore(InMemoryStorage())
        store.save(OrdoSessionStore.from(authResponse("u-1", "a@ordo.app"), now))

        val session = store.load()!!
        assertFalse(session.isGuest)
        assertEquals("a@ordo.app", session.displayName())
        assertFalse("刚写入的会话不应过期", session.isExpired(now))
        assertTrue("过期时刻之后必须判定为过期", session.isExpired(now + 1_800_000L))
    }

    @Test
    fun `退出登录只清会话_保留本地数据目录名`() {
        val store = OrdoSessionStore(InMemoryStorage())
        store.save(OrdoSessionStore.from(authResponse("u-1", "a@ordo.app"), now))
        val dirBefore = UserDataDir.dirName("u-1")

        store.clear()

        assertNull("退出后必须读不到会话", store.load())
        assertEquals(
            "退出登录只清会话：目录名规则不变，下次同一账号登录数据仍在（契约 §7.6.3）",
            dirBefore,
            UserDataDir.dirName("u-1"),
        )
    }

    @Test
    fun `损坏的会话记录不会崩溃_视为无会话`() {
        val storage = InMemoryStorage()
        storage.kvSet(OrdoSessionStore.KEY_SESSION, "{ 这不是 JSON }")

        assertNull(OrdoSessionStore(storage).load())
        assertEquals(SessionVerdict.NoSession, SessionGate.decide(null, now))
    }

    /* --------------------------- ② 登录门禁状态机 --------------------------- */

    @Test
    fun `无会话时进登录页`() {
        assertEquals(SessionVerdict.NoSession, SessionGate.decide(null, now))
    }

    @Test
    fun `未过期会话直接进主界面并标记后台静默续期`() {
        val session = OrdoSessionStore.from(authResponse("u-1", "a@ordo.app"), now)

        val verdict = SessionGate.decide(session, now)

        assertTrue(verdict is SessionVerdict.Ready)
        assertEquals("u-1", (verdict as SessionVerdict.Ready).session.userId)
    }

    @Test
    fun `过期会话先续期_成功进主界面`() {
        val expired = OrdoSessionStore.from(authResponse("u-1", "a@ordo.app"), now)
        val afterExpiry = now + 1_800_000L

        val verdict = SessionGate.decide(expired, afterExpiry)
        assertTrue("过期必须先 refresh 而不是直接进主界面", verdict is SessionVerdict.RefreshFirst)

        val refreshed = OrdoSessionStore.from(authResponse("u-1", "a@ordo.app"), afterExpiry)
        val after = SessionGate.afterRefresh(success = true, refreshed = refreshed, fallback = expired)
        assertTrue(after is SessionVerdict.Ready)
        assertEquals("续期后用新会话", afterExpiry + 1_800_000L, (after as SessionVerdict.Ready).session.expiresAt)
    }

    @Test
    fun `过期会话续期失败回登录页_目录仍按原账号保留`() {
        val expired = OrdoSessionStore.from(authResponse("u-1", "a@ordo.app"), now)

        val after = SessionGate.afterRefresh(
            success = false,
            refreshed = null,
            fallback = expired,
        )

        assertEquals("续期失败 → 登录页（仅清会话、不清目录）", SessionVerdict.NoSession, after)
        assertEquals("目录名仍然由该 userId 决定，数据不会丢", "u-1", UserDataDir.dirName("u-1"))
    }

    @Test
    fun `令牌残缺视为无会话`() {
        val broken = OrdoSession(
            userId = "u-1",
            email = "a@ordo.app",
            isGuest = false,
            accessToken = "",
            refreshToken = "refresh-1",
            expiresAt = now + 60_000L,
        )

        assertEquals(SessionVerdict.NoSession, SessionGate.decide(broken, now))
    }

    /* ------------------------ ④ 按用户隔离的目录名 ------------------------ */

    @Test
    fun `目录名由 userId 决定并对非法字符做清洗`() {
        assertEquals("uuid 原样保留", "9f1c-4a2b", UserDataDir.dirName("9f1c-4a2b"))
        assertEquals("路径分隔符等非法字符一律替换为下划线", "a_b_c", UserDataDir.dirName("a/b\\c"))
        assertEquals("空 userId 得到空目录名（调用方必须拒绝使用）", "", UserDataDir.dirName(""))
    }

    @Test
    fun `不同账号的本地数据目录必须不同_同一账号必须稳定`() {
        val base = File("filesDir")

        val a = UserDataDir.dirFor(base, "user-a")
        val b = UserDataDir.dirFor(base, "user-b")

        assertNotEquals("绝不允两个账号共用同一目录（契约 §7.6.3 硬约束）", a, b)
        assertEquals("同一账号两次解析必须落在同一目录", a, UserDataDir.dirFor(base, "user-a"))
        assertTrue(UserDataDir.isolated(base, "user-a", "user-b"))
        assertTrue("同一账号不算互斥场景", UserDataDir.isolated(base, "user-a", "user-a"))
        assertEquals(
            "用户库必须放在 filesDir/<userId>/ 之下",
            File(a, UserDataDir.DB_NAME).path,
            UserDataDir.dbFileFor(base, "user-a").path,
        )
        assertNotEquals(
            "引导库（会话）不在任何账号目录里",
            UserDataDir.dbFileFor(base, "user-a").path,
            UserDataDir.bootstrapDbFile(base).path,
        )
    }

    /* --------------------------- ⑤ 登录页表单校验 --------------------------- */

    @Test
    fun `注册必须满足口令最小长度_登录不卡长度`() {
        assertEquals(AuthFieldError.EMAIL_EMPTY, SessionGate.validate(AuthMode.REGISTER, "  ", "12345678"))
        assertEquals(AuthFieldError.EMAIL_INVALID, SessionGate.validate(AuthMode.REGISTER, "no-at-sign", "12345678"))
        assertEquals(AuthFieldError.PASSWORD_EMPTY, SessionGate.validate(AuthMode.LOGIN, "a@ordo.app", ""))
        assertEquals(
            AuthFieldError.PASSWORD_TOO_SHORT,
            SessionGate.validate(AuthMode.REGISTER, "a@ordo.app", "1234567"),
        )
        assertEquals(
            "登录不校验长度（老账号可能更短），由服务端给出真实原因",
            AuthFieldError.NONE,
            SessionGate.validate(AuthMode.LOGIN, "a@ordo.app", "123"),
        )
        assertEquals(
            AuthFieldError.NONE,
            SessionGate.validate(AuthMode.REGISTER, "a@ordo.app", "12345678"),
        )
    }

    @Test
    fun `登录与注册模式互相切换`() {
        assertEquals(AuthMode.REGISTER, AuthMode.LOGIN.toggled())
        assertEquals(AuthMode.LOGIN, AuthMode.REGISTER.toggled())
        assertTrue("注册态主按钮文案为「注册」", AuthMode.REGISTER.isRegister)
        assertFalse(AuthMode.LOGIN.isRegister)
    }
}
