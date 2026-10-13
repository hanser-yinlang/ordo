package com.ordo.android

import com.ordo.android.data.LocalAccount
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 本机数据目录标识（契约 §7.6.6）的纯逻辑验收。
 *
 * 规则：**目录标识 = 本机稳定账号标识，不是服务端 userId**；首次运行生成并持久化，
 * 此后永不因会话重建而改变；不做数据迁移，升级前已在用的目录继续沿用。
 */
class LocalAccountTest {

    /* --------------------------- 生成形态 --------------------------- */

    @Test
    fun `新id是local加16位十六进制`() {
        val id = LocalAccount.newId("0123456789abcdef0123")
        assertEquals("local-0123456789abcdef", id)
        assertTrue("前缀必须与既有服务端 userId 目录可分", id.startsWith(LocalAccount.PREFIX))
        assertEquals("随机段固定 16 位", LocalAccount.ID_LENGTH, id.removePrefix(LocalAccount.PREFIX).length)
    }

    @Test
    fun `新id清洗非法字符并绝不退化成空目录名`() {
        assertEquals("local-aabbccddeeff0011", LocalAccount.newId("AABBCCDD-EEFF-0011"))
        assertEquals("local-0000000000000000", LocalAccount.newId(""))
        assertEquals("local-0000000000000000", LocalAccount.newId("!!!@@@"))
        assertEquals("随机段不足时右侧补齐", 16, LocalAccount.newId("abc").removePrefix(LocalAccount.PREFIX).length)
    }

    @Test
    fun `两次生成的id不同_不会互相覆盖工作区`() {
        assertNotEquals(LocalAccount.newId("aaaaaaaaaaaaaaaa"), LocalAccount.newId("bbbbbbbbbbbbbbbb"))
    }

    /* --------------------------- 解析优先级 --------------------------- */

    @Test
    fun `已钉住的id永远优先_不会被任何后来状态改写`() {
        assertEquals(
            "哪怕磁盘上还有别的目录，也必须继续用钉住的目录",
            "local-0123456789abcdef",
            LocalAccount.resolve(
                pinned = "local-0123456789abcdef",
                existingDirIds = listOf("u-old", "local-0123456789abcdef"),
            ),
        )
    }

    @Test
    fun `升级时沿用磁盘上已有的唯一目录_不做迁移`() {
        assertEquals(
            "升级场景：还没有钉住的值，就沿用升级前在用的那个目录",
            "u-legacy",
            LocalAccount.resolve(pinned = null, existingDirIds = listOf("u-legacy")),
        )
        assertEquals(
            "kv 里是空串也按未钉住处理",
            "u-legacy",
            LocalAccount.resolve(pinned = "   ", existingDirIds = listOf("u-legacy")),
        )
    }

    @Test
    fun `既有目录多于一个时不猜_交给调用方新建`() {
        assertNull(
            "多个历史目录时宁可新建空工作区，也不把别的数据当自己的展示",
            LocalAccount.resolve(pinned = null, existingDirIds = listOf("u-a", "u-b")),
        )
        assertNull(
            "什么都没有（真正首次运行）→ 新建",
            LocalAccount.resolve(pinned = null, existingDirIds = emptyList()),
        )
        assertNull(
            "空白目录名不算候选",
            LocalAccount.resolve(pinned = null, existingDirIds = listOf("   ", "")),
        )
        assertEquals(
            "候选去重后只剩一个仍然可用",
            "u-a",
            LocalAccount.resolve(pinned = null, existingDirIds = listOf("u-a", "u-a")),
        )
    }
}
