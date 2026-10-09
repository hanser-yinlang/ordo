package com.ordo.desktop.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * 单实例锁测试。
 *
 * 托盘常驻后"关闭窗口"不再等于退出,用户再次双击图标就会起第二个进程;
 * 两个引擎写同一份 JSON 会互相覆盖,所以第二个实例必须拿不到锁 —— 而**环境问题**又不该把用户挡在门外。
 */
class SingleInstanceLockTest {

    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun `第二个实例被告知已在运行,释放后可以再拿`() {
        val dir = tmp.newFolder("ordo")
        val first = SingleInstanceLock.acquire(dir)
        assertTrue("第一个实例应拿到锁", first is LockResult.Acquired)

        assertEquals("第二个实例必须被挡住", LockResult.AlreadyRunning, SingleInstanceLock.acquire(dir))

        (first as LockResult.Acquired).lock.release()

        val third = SingleInstanceLock.acquire(dir)
        assertTrue("释放后应能重新拿到", third is LockResult.Acquired)
        (third as LockResult.Acquired).lock.release()
    }

    @Test
    fun `锁对象被进程级强引用,不会被回收后丢锁`() {
        val dir = tmp.newFolder("ordo-hold")
        val first = SingleInstanceLock.acquire(dir) as LockResult.Acquired
        // 主动触发 GC:实现里持有强引用,锁必须还在
        System.gc()
        Thread.sleep(50)
        System.gc()
        assertEquals("GC 之后第二个实例仍然拿不到锁", LockResult.AlreadyRunning, SingleInstanceLock.acquire(dir))
        first.lock.release()
    }

    @Test
    fun `锁文件放在数据目录下且不写入内容`() {
        val dir = tmp.newFolder("ordo-lock")
        val lock = (SingleInstanceLock.acquire(dir) as LockResult.Acquired).lock
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
        assertTrue(a is LockResult.Acquired)
        assertTrue("便携版可以同时开两份(数据目录不同)", b is LockResult.Acquired)
        (a as LockResult.Acquired).lock.release()
        (b as LockResult.Acquired).lock.release()
    }

    @Test
    fun `数据目录不存在时会自动创建`() {
        val dir = File(tmp.newFolder("parent"), "nested/ordo")
        val result = SingleInstanceLock.acquire(dir)
        assertTrue(result is LockResult.Acquired)
        assertTrue(dir.isDirectory)
        (result as LockResult.Acquired).lock.release()
    }

    @Test
    fun `数据目录不可用时返回 Unavailable 而不是当作已在运行`() {
        // 用一个"文件"当数据目录:mkdirs 失败、RandomAccessFile 也会失败
        val blocker = tmp.newFile("not-a-dir")
        val result = SingleInstanceLock.acquire(blocker)
        assertTrue("环境问题必须与'已有实例'区分开,调用方应放行启动", result is LockResult.Unavailable)
        assertNotNull((result as LockResult.Unavailable).reason)
    }
}
