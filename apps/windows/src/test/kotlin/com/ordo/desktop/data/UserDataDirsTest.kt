package com.ordo.desktop.data

import com.ordo.core.sync.OrdoSessionStore
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 本地数据按用户隔离(契约 §7.6.3 硬约束)。
 *
 * 这一条一旦破了,表现是"B 登录后看到 A 的待办" —— 所以这里逐条钉住:
 * 目录名怎么算、两个账号绝不共用、`--data-dir` 只覆盖基目录、退出登录不删目录。
 */
class UserDataDirsTest {

    private fun base(name: String): File =
        Files.createTempDirectory("ordo-dir-$name").toFile()

    @Test
    fun `每个 userId 一个子目录`() {
        val base = base("isolation")
        try {
            val a = UserDataDirs.userDir(base, "user-a")
            val b = UserDataDirs.userDir(base, "user-b")

            assertEquals(File(base, "user-a"), a)
            assertEquals(File(base, "user-b"), b)
            assertNotEquals("两个账号绝不能落到同一个目录", a.canonicalPath, b.canonicalPath)
            assertEquals("基目录不变", base, a.parentFile)
        } finally {
            base.deleteRecursively()
        }
    }

    @Test
    fun `两个账号的数据文件互相看不见`() {
        val base = base("files")
        try {
            JsonFileStorage(UserDataDirs.userDir(base, "user-a")).kvSet("ordo.note", "A 的待办")
            JsonFileStorage(UserDataDirs.userDir(base, "user-b")).kvSet("ordo.note", "B 的待办")

            assertEquals("A 的待办", JsonFileStorage(UserDataDirs.userDir(base, "user-a")).kvGet("ordo.note"))
            assertEquals("B 的待办", JsonFileStorage(UserDataDirs.userDir(base, "user-b")).kvGet("ordo.note"))
            // 全新账号读到的是空,不会"继承"别人的数据
            assertEquals(null, JsonFileStorage(UserDataDirs.userDir(base, "user-c")).kvGet("ordo.note"))
        } finally {
            base.deleteRecursively()
        }
    }

    @Test
    fun `目录名会做防御性清洗`() {
        // 每个非法字符(含 '.')都换成下划线:".." + "/" + ".." + "\" = 6 个
        assertEquals("_".repeat(6) + "etc", OrdoSessionStore.userDataDirName("../..\\etc"))
        assertEquals("a_b", OrdoSessionStore.userDataDirName("a:b"))
        assertEquals("550e8400-e29b-41d4-a716-446655440000", OrdoSessionStore.userDataDirName("550e8400-e29b-41d4-a716-446655440000"))

        val base = base("clean")
        try {
            val dir = UserDataDirs.userDir(base, "../../escape")
            assertEquals("清洗后仍然待在基目录里", base, dir.parentFile)
            assertFalse("名字里不能有分隔符", dir.name.contains("/") || dir.name.contains("\\"))
            // 真实落盘位置必须还在基目录下面(canonical 路径也不越界)
            assertTrue(dir.canonicalPath.startsWith(base.canonicalPath + File.separator))
        } finally {
            base.deleteRecursively()
        }
    }

    @Test
    fun `退出登录保留目录,再次登录还能读到旧数据`() {
        val base = base("relogin")
        try {
            val userDir = UserDataDirs.userDir(base, "user-a")
            JsonFileStorage(userDir).kvSet("ordo.demo", "seed")

            // 退出登录 = 清会话(基目录里的 kv),不动账号目录
            OrdoSessionStore(JsonFileStorage(base)).clear()

            assertTrue(userDir.exists())
            assertEquals("seed", JsonFileStorage(userDir).kvGet("ordo.demo"))
            assertTrue(File(userDir, JsonFileStorage.FILE_KV).exists())
        } finally {
            base.deleteRecursively()
        }
    }

    @Test
    fun `data-dir 只覆盖基目录,账号子目录照加`() {
        val override = File("C:\\tmp\\ordo-portable")

        val parsed = UserDataDirs.resolveBase(arrayOf("--data-dir=${override.absolutePath}"), property = null)

        assertEquals(override.absolutePath, parsed.absolutePath)
        assertEquals(
            "被覆盖的只是基目录",
            File(override, "user-a").absolutePath,
            UserDataDirs.userDir(parsed, "user-a").absolutePath
        )
    }

    @Test
    fun `没有覆盖时基目录是 APPDATA 下的 Ordo`() {
        assertEquals(JsonFileStorage.defaultDir(), UserDataDirs.resolveBase(emptyArray(), property = null))
    }

    @Test
    fun `系统属性同样只能覆盖基目录`() {
        val parsed = UserDataDirs.resolveBase(emptyArray(), property = "C:\\tmp\\ordo-prop")
        assertEquals("C:\\tmp\\ordo-prop", parsed.absolutePath)
        assertTrue(UserDataDirs.userDir(parsed, "u-1").absolutePath.endsWith("ordo-prop\\u-1"))
    }
}
