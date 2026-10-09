package com.ordo.desktop.system

import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/**
 * 跨进程深链转交。
 *
 * Windows 上再次双击图标(或浏览器点击 `ordo://…`)会起**第二个进程**,而单实例锁会把它挡下。
 * 为了让链接仍然生效,第二个进程把命令行里的 `ordo://…` 写进数据目录的 `.ordo.inbox/`
 * (先写 `.tmp` 再原子改名,避免运行中的实例读到半截文件),随后自己退出;
 * 已运行的实例轮询这个目录,消费到链接就唤出窗口并导航。
 *
 * 为什么不用命名管道 / 本地 socket:两者都需要 JNI 或占用端口,而这里只需要"极小概率、极低频率"的一次转交,
 * 目录轮询(默认 500ms)足够且零依赖、可单测。
 */
class DeepLinkInbox(private val dir: File) {

    /** 第二个实例:把参数里的深链转交给正在运行的实例;没有可转交的链接时返回 false */
    fun submit(args: List<String>): Boolean {
        val link = args.firstOrNull { it.trim().startsWith(SCHEME_PREFIX) }?.trim() ?: return false
        return write(link)
    }

    /** 第二个实例:没有深链时也要"把已有窗口叫出来",避免用户以为没反应 */
    fun submitFocus(): Boolean = write(FOCUS_LINK)

    private fun write(content: String): Boolean = runCatching {
        if (!dir.exists()) dir.mkdirs()
        val tmp = File(dir, "${UUID.randomUUID()}$TMP_SUFFIX")
        tmp.writeText(content, StandardCharsets.UTF_8)
        Files.move(
            tmp.toPath(),
            File(dir, "${System.currentTimeMillis()}-${UUID.randomUUID()}$FILE_SUFFIX").toPath(),
            StandardCopyOption.ATOMIC_MOVE
        )
    }.isSuccess

    /** 运行中的实例:取出并删除待处理的链接(按写入顺序) */
    fun drain(): List<String> {
        val files = dir.listFiles { file -> file.isFile && file.name.endsWith(FILE_SUFFIX) } ?: return emptyList()
        return files.sortedBy { it.name }.mapNotNull { file ->
            val text = runCatching { file.readText(StandardCharsets.UTF_8).trim() }.getOrNull()
            runCatching { file.delete() }
            text?.takeIf { it.startsWith(SCHEME_PREFIX) }
        }
    }

    /** 清理写了一半的临时文件(进程被强杀时可能残留) */
    fun cleanupTemp() {
        runCatching {
            dir.listFiles { file -> file.isFile && file.name.endsWith(TMP_SUFFIX) }?.forEach { it.delete() }
        }
    }

    companion object {
        const val DIR_NAME = ".ordo.inbox"
        const val SCHEME_PREFIX = "ordo://"

        /** 只要求"唤出窗口"、不导航的特殊链接(第二个实例没带深链时使用) */
        const val FOCUS_LINK = "ordo://focus"

        private const val FILE_SUFFIX = ".link"
        private const val TMP_SUFFIX = ".tmp"

        /** 默认轮询间隔(运行中实例) */
        const val POLL_MILLIS = 500L

        fun of(dataDir: File): DeepLinkInbox = DeepLinkInbox(File(dataDir, DIR_NAME))
    }
}
