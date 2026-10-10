package com.ordo.core

import com.ordo.core.model.Status
import com.ordo.core.model.When
import com.ordo.core.platform.FixedOrdoClock
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.DeviceDto
import com.ordo.core.sync.OrdoSession
import com.ordo.core.sync.OrdoSessionStore
import com.ordo.core.sync.UserDto
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** 契约 §7.6:会话模型、游客标记、按用户隔离的目录名 */
class SessionTest {

    private val now = 1_700_000_000_000L
    private val clock = FixedOrdoClock(now)

    private fun authResponse(
        userId: String = "u-1",
        email: String = "a@b.c",
        isGuest: Boolean = false,
        expiresIn: Long = 3600,
    ) = AuthResponse(
        user = UserDto(id = userId, email = email, isGuest = isGuest),
        device = DeviceDto(id = "dev_x", name = "PC", platform = "windows"),
        accessToken = "access-1",
        refreshToken = "refresh-1",
        expiresIn = expiresIn,
    )

    @Test
    fun sessionRoundTripThroughStorage() {
        val storage = InMemoryStorage()
        val store = OrdoSessionStore(storage)
        assertNull(store.load(), "初始没有会话")

        store.save(OrdoSessionStore.from(authResponse(), now))
        val loaded = store.load()!!
        assertEquals("u-1", loaded.userId)
        assertEquals("a@b.c", loaded.email)
        assertFalse(loaded.isGuest)
        assertEquals("access-1", loaded.accessToken)
        assertEquals(now + 3600_000L, loaded.expiresAt, "expiresIn 秒要换算成绝对毫秒")
    }

    @Test
    fun guestSessionHasNoEmailAndDisplayNameIsGuest() {
        val store = OrdoSessionStore(InMemoryStorage())
        store.save(OrdoSessionStore.from(authResponse(email = "", isGuest = true), now))
        val s = store.load()!!
        assertTrue(s.isGuest)
        assertNull(s.email, "空邮箱要归一化成 null")
        assertEquals("游客", s.displayName())
    }

    @Test
    fun formalAccountDisplayNameIsEmail() {
        val s = OrdoSessionStore.from(authResponse(email = "me@ordo.app", isGuest = false), now)
        assertEquals("me@ordo.app", s.displayName())
        assertEquals("me@ordo.app", s.email)
    }

    @Test
    fun expiryIsEvaluatedAgainstAbsoluteTime() {
        val s = OrdoSessionStore.from(authResponse(expiresIn = 60), now)
        assertFalse(s.isExpired(now + 59_000), "未到期")
        assertTrue(s.isExpired(now + 60_000), "到点即过期")
        // expiresIn 为 0 表示服务端没给过期时间:按未过期处理,由 401 兜底
        val unknown = OrdoSessionStore.from(authResponse(expiresIn = 0), now)
        assertFalse(unknown.isExpired(now + 10L * 365 * 24 * 3600 * 1000))
    }

    @Test
    fun clearRemovesSessionOnly() {
        val storage = InMemoryStorage()
        val store = OrdoSessionStore(storage)
        store.save(OrdoSessionStore.from(authResponse(), now))
        storage.kvSet("ordo.deviceId", "dev_keepme")
        store.clear()
        assertNull(store.load(), "退出登录要清掉会话")
        assertEquals("dev_keepme", storage.kvGet("ordo.deviceId"), "设备标识不属于会话,不能被清掉")
    }

    @Test
    fun corruptSessionDegradesToNullInsteadOfCrashing() {
        val storage = InMemoryStorage()
        storage.kvSet(OrdoSessionStore.KEY_SESSION, "{not-json")
        assertNull(OrdoSessionStore(InMemoryStorage().also { it.kvSet(OrdoSessionStore.KEY_SESSION, "{not-json") }).load())
        assertNull(OrdoSessionStore(storage).load(), "损坏的会话应视为未登录,不能让启动崩溃")
    }

    @Test
    fun userDataDirNameIsSafeAndPerUser() {
        assertEquals("a1b2-c3_d4", OrdoSessionStore.userDataDirName("a1b2-c3_d4"))
        // 任何可疑字符都被替换掉,避免路径穿越(`.` `.` `/` 三个字符各替换成一个 `_`)
        assertEquals("___etc__passwd", OrdoSessionStore.userDataDirName("../etc//passwd"))
        assertFalse(OrdoSessionStore.userDataDirName("..").contains("."), "不得残留点号")
        assertFalse(OrdoSessionStore.userDataDirName("u-1") == OrdoSessionStore.userDataDirName("u-2"),
            "不同用户必须落到不同目录(契约 §7.6.3)")
    }

    @Test
    fun engineStillWorksPerUserStorage() {
        // 两个用户各自一份 storage:数据天然隔离,互不可见
        val a = OrdoEngine(InMemoryStorage(), clock)
        val b = OrdoEngine(InMemoryStorage(), clock)
        a.createTodo("A 的待办")
        b.createTodo("B 的待办")
        assertEquals(1, a.snapshot.todos.size)
        assertEquals(1, b.snapshot.todos.size)
        assertEquals("A 的待办", a.snapshot.todos.first().title)
        assertEquals("B 的待办", b.snapshot.todos.first().title)
        assertEquals(When.INBOX, a.snapshot.todos.first().`when`)
        assertEquals(Status.OPEN, b.snapshot.todos.first().status)
    }
}
