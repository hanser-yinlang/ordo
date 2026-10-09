package com.ordo.desktop.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * 跨进程深链转交测试。
 *
 * 场景:托盘常驻后再次双击图标(或浏览器点击 `ordo://…`)会起第二个进程;它拿到不到单实例锁,
 * 于是把链接写进 `.ordo.inbox`,由运行中的实例消费。
 */
class DeepLinkInboxTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun inbox(dir: File = tmp.newFolder("ordo")) = DeepLinkInbox.of(dir)

    @Test
    fun `第二个实例写入链接,运行中的实例消费到`() {
        val dir = tmp.newFolder("ordo")
        val second = DeepLinkInbox.of(dir)

        assertTrue(second.submit(listOf("Ordo.exe", "ordo://project/p-launch")))

        val running = DeepLinkInbox.of(dir)
        assertEquals(listOf("ordo://project/p-launch"), running.drain())
        assertTrue("消费后必须清空,不能反复导航", running.drain().isEmpty())
    }

    @Test
    fun `没有深链时不写文件`() {
        val second = inbox()
        assertFalse("普通启动(无参数)不该留下转交文件", second.submit(listOf("Ordo.exe")))
        assertFalse(second.submit(listOf("Ordo.exe", "--data-dir=D:\\Ordo")))
        assertTrue(second.drain().isEmpty())
    }

    @Test
    fun `多个链接按写入顺序消费`() {
        val dir = tmp.newFolder("ordo")
        val second = DeepLinkInbox.of(dir)
        second.submit(listOf("ordo://inbox"))
        Thread.sleep(5)
        second.submit(listOf("ordo://logbook"))

        val links = DeepLinkInbox.of(dir).drain()
        assertEquals(listOf("ordo://inbox", "ordo://logbook"), links)
    }

    @Test
    fun `只挑出 ordo 开头的参数,其它参数忽略`() {
        val dir = tmp.newFolder("ordo")
        DeepLinkInbox.of(dir).submit(listOf("Ordo.exe", "--selftest=C:\\tmp\\r.txt", "ordo://todo/seed-t01"))
        assertEquals(listOf("ordo://todo/seed-t01"), DeepLinkInbox.of(dir).drain())
    }

    @Test
    fun `损坏或非法内容被丢弃,不影响后续`() {
        val dir = tmp.newFolder("ordo")
        val inbox = DeepLinkInbox.of(dir)
        inbox.submit(listOf("ordo://today"))
        // 手工塞一个内容非法的文件
        File(dir, DeepLinkInbox.DIR_NAME).let { it.mkdirs() }
        File(File(dir, DeepLinkInbox.DIR_NAME), "999-bad.link").writeText("hello", Charsets.UTF_8)

        assertEquals(listOf("ordo://today"), inbox.drain())
        assertTrue(inbox.drain().isEmpty())
    }

    @Test
    fun `半截临时文件会被清理且不会被消费`() {
        val dir = tmp.newFolder("ordo")
        val inboxDir = File(dir, DeepLinkInbox.DIR_NAME).apply { mkdirs() }
        File(inboxDir, "half.link.tmp").writeText("ordo://in", Charsets.UTF_8)

        val inbox = DeepLinkInbox.of(dir)
        assertTrue("临时文件不算待处理链接", inbox.drain().isEmpty())
        inbox.cleanupTemp()
        assertTrue("残留临时文件应被清掉", inboxDir.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun `目录不存在时会自动创建`() {
        val dir = File(tmp.newFolder("parent"), "nested/ordo")
        val inbox = DeepLinkInbox.of(dir)
        assertTrue(inbox.submit(listOf("ordo://today")))
        assertEquals(listOf("ordo://today"), inbox.drain())
    }

    @Test
    fun `深链解析与写入内容一致`() {
        val dir = tmp.newFolder("ordo")
        DeepLinkInbox.of(dir).submit(listOf("ordo://search?q=%E6%8A%A5%E5%91%8A"))
        val link = DeepLinkInbox.of(dir).drain().single()
        val target = DeepLink.parse(link)
        assertEquals(com.ordo.desktop.app.OrdoRoute.Search("报告"), target?.route)
    }
}
