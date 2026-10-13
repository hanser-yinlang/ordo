package com.ordo.desktop.data

import com.ordo.core.storage.InMemoryStorage
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

    // ------------------------------------------------------------ 数据目录 id 的"钉住"

    @Test
    fun `有会话时数据目录 id 就是会话 userId,并落到 kv`() {
        val storage = InMemoryStorage()

        val id = UserDataDirs.resolveDataDirId(storage, sessionUserId = "u-old")

        assertEquals("老用户的目录名与历史行为一致(不需要迁移)", "u-old", id)
        assertEquals("必须钉住,否则下次启动会换目录", "u-old", storage.kvGet(UserDataDirs.KEY_DATA_DIR_ID))
    }

    @Test
    fun `没有会话(全新安装且离线)时生成本地匿名 id 并钉住`() {
        val storage = InMemoryStorage()
        var generated = 0
        val generate = { generated += 1; "local-test-$generated" }

        val first = UserDataDirs.resolveDataDirId(storage, sessionUserId = null, generate = generate)

        assertEquals("local-test-1", first)
        assertEquals("只生成一次", 1, generated)
        assertEquals("钉在 kv 里", first, storage.kvGet(UserDataDirs.KEY_DATA_DIR_ID))
    }

    @Test
    fun `会话到手后目录 id 不会改名 —— 后续启动仍然用钉住的那个`() {
        val storage = InMemoryStorage()
        val local = UserDataDirs.resolveDataDirId(storage, sessionUserId = null) { "local-pinned" }

        // 静默匿名会话到手了(userId 与服务端分配的一致),但目录 id 依旧钉住:
        // 否则用户刚写的待办会"看起来消失"(数据其实还在旧目录里)
        val afterSession = UserDataDirs.resolveDataDirId(storage, sessionUserId = "u-server")

        assertEquals("local-pinned", local)
        assertEquals("local-pinned", afterSession)
        assertNotEquals("本地 id 不该被服务端 userId 顶掉", "u-server", afterSession)
    }

    @Test
    fun `空白 id 视为没有(不会钉出一个空目录名)`() {
        val storage = InMemoryStorage()
        storage.kvSet(UserDataDirs.KEY_DATA_DIR_ID, "   ")

        val id = UserDataDirs.resolveDataDirId(storage, sessionUserId = "u-1")

        assertEquals("u-1", id)
    }

    @Test
    fun `升级前用过、会话却已不在的机器——沿用唯一遗留数据目录(契约 §7_6_6 不做迁移)`() {
        val base = base("adopt-one")
        try {
            // v1.3 里退出过登录 → 会话被清,但目录与数据都还在
            val legacy = File(base, "550e8400-e29b-41d4-a716-446655440000")
            JsonFileStorage(legacy).kvSet("ordo.demo", "旧数据")

            val storage = InMemoryStorage()
            var generated = 0
            val id = UserDataDirs.resolveDataDirId(storage, sessionUserId = null, baseDir = base) {
                generated += 1
                "local-new"
            }

            assertEquals("必须沿用遗留目录名", legacy.name, id)
            assertEquals("不该走生成分支", 0, generated)
            assertEquals("钉在 kv 里", legacy.name, storage.kvGet(UserDataDirs.KEY_DATA_DIR_ID))
            assertEquals("旧数据原地可读", "旧数据", JsonFileStorage(UserDataDirs.userDir(base, id)).kvGet("ordo.demo"))
        } finally {
            base.deleteRecursively()
        }
    }

    @Test
    fun `遗留目录不唯一时不猜,直接生成新 id`() {
        val base = base("adopt-many")
        try {
            JsonFileStorage(File(base, "user-a")).kvSet("ordo.demo", "A")
            JsonFileStorage(File(base, "user-b")).kvSet("ordo.demo", "B")

            val storage = InMemoryStorage()
            val id = UserDataDirs.resolveDataDirId(storage, sessionUserId = null, baseDir = base) { "local-new" }

            assertEquals("多个候选无法判断归属,宁可不迁移", "local-new", id)
        } finally {
            base.deleteRecursively()
        }
    }

    @Test
    fun `隐藏目录与空目录不算遗留数据目录`() {
        val base = base("adopt-ignore")
        try {
            // 深链信箱 / 锁之类是隐藏目录;空目录也不是本端写过的数据目录
            File(base, ".ordo.inbox").mkdirs()
            File(File(base, ".ordo.inbox"), "x.txt").writeText("link")
            File(base, "empty-dir").mkdirs()

            val storage = InMemoryStorage()
            val id = UserDataDirs.resolveDataDirId(storage, sessionUserId = null, baseDir = base) { "local-new" }

            assertEquals("都不算,应该生成新 id", "local-new", id)
        } finally {
            base.deleteRecursively()
        }
    }

    @Test
    fun `已钉住的 id 优先于任何扫描与生成`() {
        val base = base("adopt-pinned")
        try {
            JsonFileStorage(File(base, "legacy-dir")).kvSet("ordo.demo", "旧数据")
            val storage = InMemoryStorage()
            storage.kvSet(UserDataDirs.KEY_DATA_DIR_ID, "already-pinned")

            val id = UserDataDirs.resolveDataDirId(storage, sessionUserId = "u-other", baseDir = base) { "local-new" }

            assertEquals("钉住之后永不改写:会话、遗留目录、生成器都不影响它", "already-pinned", id)
        } finally {
            base.deleteRecursively()
        }
    }
}
