package com.ordo.desktop.system

import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock

/**
 * 单实例锁。
 *
 * 托盘常驻之后,"关闭窗口"不再等于退出,用户很可能再双击一次图标 —— 两个进程各持一个
 * [com.ordo.core.store.OrdoEngine] 写同一份 JSON 会互相覆盖。这里在数据目录上放一把文件锁:
 * 第二个实例拿不到锁就直接提示并退出(锁由操作系统在进程结束时释放,不会留下僵尸锁)。
 */
class SingleInstanceLock private constructor(
    private val file: RandomAccessFile,
    private val lock: FileLock
) {

    /** 释放锁(退出前调用;进程被强杀时由系统释放) */
    fun release() {
        runCatching { lock.release() }
        runCatching { file.close() }
    }

    companion object {
        const val FILE_NAME = ".ordo.lock"

        /** 拿到锁返回实例;已有实例在跑(或文件不可写)返回 null */
        fun acquire(dir: File): SingleInstanceLock? = runCatching {
            if (!dir.exists()) dir.mkdirs()
            val file = RandomAccessFile(File(dir, FILE_NAME), "rw")
            // 同一 JVM 内重复加锁会抛 OverlappingFileLockException,同样按"已有实例"处理
            val lock = file.channel.tryLock()
            if (lock == null) {
                file.close()
                null
            } else {
                SingleInstanceLock(file, lock)
            }
        }.getOrNull()
    }
}
