package com.ordo.desktop.system

import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException

/**
 * 单实例锁。
 *
 * 托盘常驻之后,"关闭窗口"不再等于退出,用户很可能再双击一次图标 —— 两个进程各持一个
 * [com.ordo.core.store.OrdoEngine] 写同一份 JSON 会互相覆盖。这里在数据目录上放一把文件锁:
 * 第二个实例拿不到锁时会把深链转交给运行中的实例并退出(锁由操作系统在进程结束时释放,不会留下僵尸锁)。
 *
 * 注意区分两种"没拿到锁":**别人拿着**(正常单实例)与**环境问题**(权限 / 路径 / IO)。
 * 后者不该把用户挡在门外,调用方应放行启动([LockResult.Unavailable])。
 */
class SingleInstanceLock private constructor(
    private val file: RandomAccessFile,
    private val lock: FileLock
) {

    /** 释放锁(退出前调用;进程被强杀时由系统释放) */
    fun release() {
        runCatching { lock.release() }
        runCatching { file.close() }
        held.remove(this)
    }

    companion object {
        const val FILE_NAME = ".ordo.lock"

        /**
         * 进程级强引用。
         *
         * 必须持有:一旦 [SingleInstanceLock] 不可达,`RandomAccessFile` / `FileChannel` 被回收时会连带
         * 释放文件锁,单实例就形同虚设(实测踩到过:第二个实例以为自己拿到了锁,于是两个引擎同时写一份 JSON)。
         */
        private val held = mutableListOf<SingleInstanceLock>()

        /** 自检 / 诊断用:本进程当前是否真的还持有锁 */
        fun isHeldByThisProcess(): Boolean = held.any { runCatching { it.lock.isValid }.getOrDefault(false) }

        /** 自检 / 诊断用:本进程持有的锁数量 */
        fun heldCount(): Int = held.size

        fun acquire(dir: File): LockResult {
            // 瞬时失败(杀毒/索引器刚碰过这个文件、上一个实例刚退出)重试几次再判定,
            // 否则会误判成"环境不可用"从而放行第二个实例
            var lastReason = "未知原因"
            repeat(ACQUIRE_ATTEMPTS) { attempt ->
                when (val result = tryAcquireOnce(dir)) {
                    is LockResult.Acquired -> return result
                    LockResult.AlreadyRunning -> return result
                    is LockResult.Unavailable -> {
                        lastReason = result.reason
                        if (attempt < ACQUIRE_ATTEMPTS - 1) Thread.sleep(ACQUIRE_RETRY_MILLIS)
                    }
                }
            }
            return LockResult.Unavailable(lastReason)
        }

        private fun tryAcquireOnce(dir: File): LockResult {
            val file = try {
                if (!dir.exists()) dir.mkdirs()
                RandomAccessFile(File(dir, FILE_NAME), "rw")
            } catch (error: Throwable) {
                return LockResult.Unavailable(error.message ?: error::class.simpleName ?: "无法打开锁文件")
            }
            return try {
                val lock = file.channel.tryLock()
                if (lock == null) {
                    runCatching { file.close() }
                    LockResult.AlreadyRunning
                } else {
                    val instance = SingleInstanceLock(file, lock)
                    held.add(instance)
                    LockResult.Acquired(instance)
                }
            } catch (overlapping: OverlappingFileLockException) {
                // 同一 JVM 内重复加锁:同样按"已有实例"处理
                runCatching { file.close() }
                LockResult.AlreadyRunning
            } catch (error: Throwable) {
                runCatching { file.close() }
                LockResult.Unavailable(error.message ?: error::class.simpleName ?: "加锁失败")
            }
        }

        /** 重试次数与间隔(合计约 0.3 秒) */
        private const val ACQUIRE_ATTEMPTS = 3
        private const val ACQUIRE_RETRY_MILLIS = 150L
    }
}

/** [SingleInstanceLock.acquire] 的结果 */
sealed interface LockResult {

    /** 拿到锁,正常启动 */
    data class Acquired(val lock: SingleInstanceLock) : LockResult

    /** 已有实例在跑:转交深链 / 唤出窗口后退出 */
    object AlreadyRunning : LockResult

    /** 锁不可用(权限 / IO):不阻断启动,只是没有单实例保护 */
    data class Unavailable(val reason: String) : LockResult
}
