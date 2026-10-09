package com.ordo.desktop.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `ordo://` 深链解析测试。
 *
 * 命令行与跨进程转交都会把**外部字符串**喂给解析器,所以这里重点是"任何输入都不许抛异常":
 * 未知路由回落到「今天」,格式不对就当没有深链(曾经的实现会在未知 key 上抛 NPE 把应用打崩)。
 */
class DeepLinkTest {

    @Test
    fun `固定清单与快捷清单都能解析`() {
        assertEquals(com.ordo.desktop.app.OrdoRoute.Inbox, DeepLink.parse("ordo://inbox")?.route)
        assertEquals(com.ordo.desktop.app.OrdoRoute.Today, DeepLink.parse("ordo://today")?.route)
        assertEquals(com.ordo.desktop.app.OrdoRoute.Upcoming, DeepLink.parse("ordo://upcoming")?.route)
        assertEquals(com.ordo.desktop.app.OrdoRoute.Anytime, DeepLink.parse("ordo://anytime")?.route)
        assertEquals(com.ordo.desktop.app.OrdoRoute.Someday, DeepLink.parse("ordo://someday")?.route)
        assertEquals("日志簿必须解析成 Logbook 而不是崩溃", com.ordo.desktop.app.OrdoRoute.Logbook, DeepLink.parse("ordo://logbook")?.route)
    }

    @Test
    fun `未知路由回落到今天而不是抛异常`() {
        listOf("ordo://nonsense", "ordo://x/y/z", "ordo://", "ordo://?", "ordo://  ").forEach { raw ->
            val target = runCatching { DeepLink.parse(raw) }.getOrNull()
            assertTrue("$raw 不该抛异常", target != null)
        }
    }

    @Test
    fun `项目 区域 标签 待办 搜索`() {
        assertEquals(com.ordo.desktop.app.OrdoRoute.Project("p-1"), DeepLink.parse("ordo://project/p-1")?.route)
        assertEquals(com.ordo.desktop.app.OrdoRoute.Area("a-1"), DeepLink.parse("ordo://area/a-1")?.route)
        assertEquals(com.ordo.desktop.app.OrdoRoute.Tag("重要"), DeepLink.parse("ordo://tag/%E9%87%8D%E8%A6%81")?.route)
        val todo = DeepLink.parse("ordo://todo/seed-t01")
        assertEquals(com.ordo.desktop.app.OrdoRoute.Today, todo?.route)
        assertEquals("seed-t01", todo?.todoId)
        assertEquals(com.ordo.desktop.app.OrdoRoute.Search("周报"), DeepLink.parse("ordo://search?q=%E5%91%A8%E6%8A%A5")?.route)
    }

    @Test
    fun `非 ordo 参数一律忽略`() {
        assertNull(DeepLink.parse("--data-dir=C:\\Ordo"))
        assertNull(DeepLink.parse(""))
        assertNull(DeepLink.parse(null))
        assertNull(DeepLink.parse("https://example.com/ordo://today"))
        assertNull(DeepLink.fromArgs(arrayOf("--selftest=a.txt", "--data-dir=D:\\x")))
    }

    @Test
    fun `从命令行参数里挑出深链且不受大小写影响`() {
        val target = DeepLink.fromArgs(arrayOf("--data-dir=D:\\Ordo", "ORDO://LOGbook"))
        assertEquals(com.ordo.desktop.app.OrdoRoute.Logbook, target?.route)
    }

    @Test
    fun `safeParse 吞掉任何异常`() {
        assertNull(DeepLink.safeParse(null))
        assertNull(DeepLink.safeParse("ordo://project/"))   // 缺 id
        assertEquals(com.ordo.desktop.app.OrdoRoute.Today, DeepLink.safeParse("ordo://today")?.route)
    }

    @Test
    fun `路由 key 与解析结果互逆`() {
        com.ordo.desktop.app.OrdoRoute.fixed.forEach { route ->
            assertEquals("${route.key} 应能解析回自身", route, DeepLink.parse("ordo://${route.key}")?.route)
            assertEquals(route, com.ordo.desktop.app.OrdoRoute.fromKey(route.key))
        }
    }

    @Test
    fun `固定清单里没有空元素,并发读取也稳定`() {
        val routes = com.ordo.desktop.app.OrdoRoute.fixed
        assertEquals(6, routes.size)
        assertTrue("固定清单不该出现 null 元素", routes.all { it.key.isNotBlank() })

        val errors = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()
        val threads = (1..8).map {
            Thread {
                repeat(200) {
                    runCatching { com.ordo.desktop.app.OrdoRoute.fromKey("logbook") }
                        .onFailure { error -> errors.add(error) }
                }
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join() }
        assertTrue("并发解析不该出异常:${errors.firstOrNull()}", errors.isEmpty())
    }
}
