package com.ordo.desktop.system

import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * 单实例锁测试。
 *
 * 托盘常驻后"关闭窗口"不再等于退出,用户再次双击图标就会起第二个进程;
 * 两个引擎写同一份 JSON 会互相覆盖,所以第二个实例必须拿不到锁。
 */
class SingleInstanceLockTest {

    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun `第二个实例拿不到锁,释放后可以再拿`() {
        val dir = tmp.newFolder("ordo")
        val first = SingleInstanceLock.acquire(dir)
        assertNotNull("第一个实例应拿到锁", first)

        val second = SingleInstanceLock.acquire(dir)
        assertNull("第二个实例必须被挡住", second)

        first!!.release()

        val third = SingleInstanceLock.acquire(dir)
        assertNotNull("释放后应能重新拿到", third)
        third!!.release()
    }

    @Test
    fun `锁文件放在数据目录下且不写入内容`() {
        val dir = tmp.newFolder("ordo-lock")
        val lock = SingleInstanceLock.acquire(dir)!!
        val file = File(dir, SingleInstanceLock.FILE_NAME)
        assertTrue("锁文件应位于数据目录", file.exists())
        assertTrue("锁文件只是占位,不应有内容", file.length() == 0L)
        lock.release()
        assertTrue("释放后文件仍在(避免误删别人的锁)", file.exists())
    }

    @Test
    fun `不同数据目录互不影响`() {
        val a = SingleInstanceLock.acquire(tmp.newFolder("a"))
        val b = SingleInstanceLock.acquire(tmp.newFolder("b"))
        assertNotNull(a)
        assertNotNull("便携版可以同时开两份(数据目录不同)", b)
        a!!.release()
        b!!.release()
    }

    @Test
    fun `数据目录不存在时会自动创建`() {
        val dir = File(tmp.newFolder("parent"), "nested/ordo")
        val lock = SingleInstanceLock.acquire(dir)
        assertNotNull("应能自动建目录并加锁", lock)
        assertTrue(dir.isDirectory)
        lock!!.release()
    }
}
