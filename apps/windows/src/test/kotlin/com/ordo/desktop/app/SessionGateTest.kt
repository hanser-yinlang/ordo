package com.ordo.desktop.app

import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.DeviceDto
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.OrdoSessionStore
import com.ordo.core.sync.UserDto
import com.ordo.desktop.data.JsonFileStorage
import com.ordo.desktop.data.UserDataDirs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 登录门禁与账号会话(契约 §7.6 / 04-UI规范 §5.1)。
 *
 * 覆盖四件事:
 *  1. 会话读写与游客标记(游客与正式账号的门禁完全一致);
 *  2. 启动门禁状态机:无会话 → 登录页;有会话 → 主界面;过期 → 先刷新,失败才回登录页;
 *  3. 退出登录只清会话、**保留**该 userId 的数据目录(§7.6.3 硬约束);
 *  4. 账号展示口径(邮箱 或 "游客")。
 */
class SessionGateTest {

    private fun session(
        userId: String = "u-1",
        email: String? = "a@b.c",
        guest: Boolean = false,
        accessToken: String = "at",
        refreshToken: String = "rt",
        expiresAt: Long = 0L
    ) = OrdoSession(
        userId = userId,
        email = email,
        isGuest = guest,
        accessToken = accessToken,
        refreshToken = refreshToken,
        expiresAt = expiresAt
    )

    private fun response(userId: String, email: String, guest: Boolean) = AuthResponse(
        user = UserDto(id = userId, email = email, isGuest = guest),
        device = DeviceDto(id = "dev_1", name = "Ordo Windows", platform = "windows"),
        accessToken = "access-1",
        refreshToken = "refresh-1",
        expiresIn = 1_800L
    )

    // ------------------------------------------------------------ 会话读写

    @Test
    fun `登录响应落成会话,能被重新读出来`() {
        val storage = InMemoryStorage()
        val store = OrdoSessionStore(storage)
        val now = 1_000_000L

        store.save(OrdoSessionStore.from(response("u-9", "me@ordo.app", guest = false), now))

        // 换一个实例读(等价于重新启动)
        val loaded = OrdoSessionStore(storage).load()!!
        assertEquals("u-9", loaded.userId)
        assertEquals("me@ordo.app", loaded.email)
        assertFalse("正式账号不是游客", loaded.isGuest)
        assertEquals("access-1", loaded.accessToken)
        assertEquals("refresh-1", loaded.refreshToken)
        assertEquals("过期时刻 = now + expiresIn×1000", now + 1_800_000L, loaded.expiresAt)
        assertFalse(loaded.isExpired(now))
        assertTrue(loaded.isExpired(now + 1_800_000L))
    }

    @Test
    fun `游客登录落成游客会话,展示名是游客`() {
        val storage = InMemoryStorage()
        val store = OrdoSessionStore(storage)

        store.save(OrdoSessionStore.from(response("u-guest", "", guest = true), 0L))

        val loaded = store.load()!!
        assertTrue(loaded.isGuest)
        assertNull("游客没有邮箱", loaded.email)
        assertEquals("游客", loaded.displayName())
        assertEquals("游客", AccountInfo.of(loaded).displayName)
        assertTrue(AccountInfo.of(loaded).isGuest)
    }

    @Test
    fun `没有会话时读出 null`() {
        assertNull(OrdoSessionStore(InMemoryStorage()).load())
    }

    @Test
    fun `退出登录只清会话,目录里的数据仍在`() {
        val base = java.nio.file.Files.createTempDirectory("ordo-gate").toFile()
        try {
            val userDir = UserDataDirs.userDir(base, "u-1")
            JsonFileStorage(userDir).kvSet("ordo.demo", "v")

            val sessionStorage = JsonFileStorage(base)
            val store = OrdoSessionStore(sessionStorage)
            store.save(session())
            assertEquals("u-1", store.load()!!.userId)

            store.clear()

            assertNull("退出登录后没有会话", store.load())
            assertTrue("数据目录必须保留(契约 §7.6.3)", userDir.exists())
            assertEquals("老数据还在", "v", JsonFileStorage(userDir).kvGet("ordo.demo"))
        } finally {
            base.deleteRecursively()
        }
    }

    // ------------------------------------------------------------ 启动门禁

    @Test
    fun `无会话进入登录页`() {
        val decision = SessionGate.boot(null, 1_000L)
        assertEquals(GateStage.LOGIN, decision.stage)
        assertNull(decision.session)
        assertFalse("登录页不需要刷新令牌", decision.needsRefresh)
        assertNull(decision.notice)
    }

    @Test
    fun `有未过期会话直接进主界面,并要求后台静默刷新`() {
        val decision = SessionGate.boot(session(expiresAt = 10_000L), 1_000L)
        assertEquals(GateStage.MAIN, decision.stage)
        assertEquals("u-1", decision.session!!.userId)
        assertTrue("契约 §7.6.4:进入主界面后后台静默 refresh", decision.needsRefresh)
    }

    @Test
    fun `会话过期时先进主界面并刷新,刷新成功换成新令牌`() {
        val expired = session(accessToken = "old", expiresAt = 500L)
        val boot = SessionGate.boot(expired, 1_000L)
        assertEquals(GateStage.MAIN, boot.stage)
        assertTrue(boot.needsRefresh)

        val fresh = expired.copy(accessToken = "new", expiresAt = 9_999L)
        val after = SessionGate.afterRefresh(expired, ok = true, refreshed = fresh, nowMillis = 1_000L)

        assertEquals(GateStage.MAIN, after.stage)
        assertEquals("new", after.session!!.accessToken)
        assertFalse(after.needsRefresh)
    }

    @Test
    fun `过期会话刷新失败才回登录页,并保留该账号目录`() {
        val expired = session(userId = "u-77", expiresAt = 500L)

        val after = SessionGate.afterRefresh(expired, ok = false, refreshed = null, nowMillis = 1_000L)

        assertEquals(GateStage.LOGIN, after.stage)
        assertNull("回登录页 = 没有会话", after.session)
        val notice = after.notice!!
        assertTrue("要告诉用户本地数据没丢:$notice", notice.contains("u-77"))
        assertTrue(notice.contains("本地数据仍保留"))
    }

    @Test
    fun `未过期的会话刷新失败仍留在主界面(交给 401 兜底)`() {
        val alive = session(expiresAt = 9_999L)
        val after = SessionGate.afterRefresh(alive, ok = false, refreshed = null, nowMillis = 1_000L)
        assertEquals(GateStage.MAIN, after.stage)
        assertEquals("u-1", after.session!!.userId)
    }

    @Test
    fun `登录成功进入主界面,退出回到登录页`() {
        val logged = SessionGate.afterAuthenticated(session())
        assertEquals(GateStage.MAIN, logged.stage)
        assertEquals("u-1", logged.session!!.userId)

        assertEquals(GateStage.LOGIN, SessionGate.afterSignOut().stage)
    }

    @Test
    fun `游客会话与正式会话走同一条门禁(不是受限模式)`() {
        val guest = session(userId = "u-g", email = null, guest = true, expiresAt = 9_999L)
        val decision = SessionGate.boot(guest, 1_000L)

        assertEquals("游客同样直接进主界面", GateStage.MAIN, decision.stage)
        assertTrue(decision.session!!.isGuest)
        assertEquals(GateStage.MAIN, SessionGate.afterAuthenticated(guest).stage)
    }

    // ------------------------------------------------------------ 目录名(§7.6.3)

    @Test
    fun `目录名按 userId 一对一,两个账号绝不共用`() {
        val base = UserDataDirs.baseDir()
        val a = UserDataDirs.userDir(base, "11111111-1111")
        val b = UserDataDirs.userDir(base, "22222222-2222")

        assertFalse("两个账号的目录必须不同", a == b)
        assertEquals("11111111-1111", a.name)
        assertEquals("22222222-2222", b.name)
        assertEquals("都挂在同一个基目录下", base, a.parentFile)
        assertEquals(base, b.parentFile)
    }

    @Test
    fun `目录名不能带出路径分隔符`() {
        val base = UserDataDirs.baseDir()
        val dir = UserDataDirs.userDir(base, "../../evil")

        assertEquals("父目录必须还是基目录", base, dir.parentFile)
        assertFalse(dir.name.contains("/"))
        assertFalse(dir.name.contains("\\"))
        // 每个非法字符换成下划线:".." + "/" + ".." + "/" = 6 个
        assertEquals("_".repeat(6) + "evil", dir.name)
    }

    @Test
    fun `账号信息直接给出目录名`() {
        val info = AccountInfo(userId = "u-1", email = "me@ordo.app", isGuest = false)
        assertEquals("u-1", info.dataDirName())
        assertEquals("me@ordo.app", info.displayName)

        assertEquals("游客", AccountInfo(userId = "u-2", email = null, isGuest = true).displayName)
    }
}
