package com.ordo.android

import java.io.File

/**
 * 只读解析 `src/main/` 下的源码（**源码级契约断言**用）。
 *
 * 与 [TestStrings] 同样的思路：Android 单测跑在 JVM 上、不引入 Robolectric，
 * 但"必须用径向渐变、禁止退回彩色阴影"这类要求是**实现方式**上的硬约束，
 * 只能直接读源码断言 —— 只依赖 JDK，不新增任何依赖。
 */
object TestSource {

    /** 读取 `app/src/main/<relativePath>` 的源码原文（路径用 `/` 分隔） */
    fun read(relativePath: String): String {
        val start = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val candidates = generateSequence(start) { it.parentFile }
            .take(6)
            .map { File(it, "src/main/$relativePath") }
            .toList()
        val file = candidates.firstOrNull { it.isFile }
            ?: error("找不到 src/main/$relativePath，已尝试：${candidates.joinToString(" | ") { it.path }}")
        return file.readText(Charsets.UTF_8)
    }

    /**
     * 同 [read]，但先去掉注释。
     *
     * "禁止出现 XXX" 这类断言必须只看**代码**：注释里为了说明"不要用 ambientColor/spotColor"
     * 反而会包含这些词，直接断言原文会误报。
     */
    fun readCode(relativePath: String): String =
        read(relativePath)
            .replace(Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL), " ")
            .replace(Regex("""//[^\n]*"""), " ")
}
