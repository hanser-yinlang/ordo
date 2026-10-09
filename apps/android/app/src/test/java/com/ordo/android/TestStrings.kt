package com.ordo.android

import java.io.File

/**
 * 只读解析 `src/main/res/values/strings.xml`（文案契约测试用）。
 *
 * Android 单元测试跑在 JVM 上、不引入 Robolectric（也不启用 androidResources），拿不到
 * `Resources.getString`；但"拒绝文案必须与真实原因一致、必须带 N、不得再提标题"是契约
 * §2.2 v1.1 的硬要求，因此这里直接读资源文件断言模板原文 —— 只依赖 JDK，不新增任何依赖。
 *
 * Gradle 的 Test 任务默认把工作目录设为模块目录（`apps/android/app`），
 * 这里再向上一层目录兜底，保证从 IDE / 命令行运行都能定位到资源文件。
 */
object TestStrings {

    private val stringsFile: File by lazy {
        val start = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val candidates = generateSequence(start) { it.parentFile }
            .take(6)
            .map { File(it, "src/main/res/values/strings.xml") }
            .toList()
        candidates.firstOrNull { it.isFile }
            ?: error("找不到 res/values/strings.xml，已尝试：${candidates.joinToString(" | ") { it.path }}")
    }

    /** 取 `<string name="...">` 的模板原文：`%1$d` 之类的占位符保持原样 */
    fun value(name: String): String {
        val text = stringsFile.readText(Charsets.UTF_8)
        val pattern = Regex(
            "<string name=\"${Regex.escape(name)}\">(.*?)</string>",
            RegexOption.DOT_MATCHES_ALL,
        )
        val match = pattern.find(text) ?: error("strings.xml 里没有 <string name=\"$name\">")
        return match.groupValues[1]
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("\\'", "'")
    }
}
