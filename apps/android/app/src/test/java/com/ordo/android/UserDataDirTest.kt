package com.ordo.android

import com.ordo.android.data.LocalAccount
import com.ordo.android.data.UserDataDir
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Before
import org.junit.Test

/**
 * 本地数据目录（契约 §7.6.3 隔离 + §7.6.6 本机稳定目录 id）的纯逻辑验收。
 *
 * 这些用例原先与登录门禁混在一个测试类里；v1.3 删掉登录后，
 * **与登录无关的目录隔离用例**在这里保留（登录相关的用例随登录代码一起删除）。
 */
class UserDataDirTest {

    private lateinit var base: File

    @Before
    fun setUp() {
        base = File("build/tmp/user-data-dir-test").apply {
            deleteRecursively()
            mkdirs()
        }
    }

    @After
    fun tearDown() {
        base.deleteRecursively()
    }

    private fun dirWith(userId: String, content: String): File =
        UserDataDir.dirFor(base, userId).apply {
            mkdirs()
            File(this, UserDataDir.DB_NAME).writeText(content)
        }

    /* ---------------------- 目录名与隔离（原有覆盖） ---------------------- */

    @Test
    fun `目录名由 userId 决定并对非法字符做清洗`() {
        assertEquals("uuid 原样保留", "9f1c-4a2b", UserDataDir.dirName("9f1c-4a2b"))
        assertEquals("路径分隔符等非法字符一律替换为下划线", "a_b_c", UserDataDir.dirName("a/b\\c"))
        assertEquals("空 userId 得到空目录名（调用方必须拒绝使用）", "", UserDataDir.dirName(""))
    }

    @Test
    fun `不同账号的本地数据目录必须不同_同一账号必须稳定`() {
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
            "引导库（会话 / 设备标识）不在任何账号目录里",
            UserDataDir.dbFileFor(base, "user-a").path,
            UserDataDir.bootstrapDbFile(base).path,
        )
    }

    /* --------- 既有工作区扫描（契约 §7.6.6「升级前已在用的目录继续沿用」） --------- */

    @Test
    fun `只把含数据库的目录算作既有工作区`() {
        dirWith("u-legacy", "legacy data")
        dirWith(LocalAccount.newId("0123456789abcdef"), "local data")
        File(base, "empty-dir").mkdirs()
        File(base, UserDataDir.BOOTSTRAP_DB_NAME).writeText("bootstrap")

        assertEquals(
            listOf(LocalAccount.newId("0123456789abcdef"), "u-legacy"),
            UserDataDir.existingDirIds(base),
        )
    }

    @Test
    fun `没有任何既有工作区时返回空列表`() {
        assertTrue("全新安装：filesDir 里还没有数据目录", UserDataDir.existingDirIds(base).isEmpty())

        File(base, UserDataDir.BOOTSTRAP_DB_NAME).writeText("bootstrap")
        assertTrue("只有引导库（它是文件不是目录）也算没有", UserDataDir.existingDirIds(base).isEmpty())
    }

    @Test
    fun `升级沿用旧目录后可被解析到_且不会新建目录`() {
        dirWith("u-legacy", "legacy data")

        val resolved = LocalAccount.resolve(
            pinned = null,
            existingDirIds = UserDataDir.existingDirIds(base),
        )

        assertEquals("唯一既有目录 = 升级前在用的目录", "u-legacy", resolved)
        assertEquals(
            "沿用即原地读取，数据不能被动过",
            "legacy data",
            File(UserDataDir.dirFor(base, "u-legacy"), UserDataDir.DB_NAME).readText(),
        )
    }
}
