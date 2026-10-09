package com.ordo.desktop.system

/**
 * Windows 系统外观与无障碍设置的读取(注册表)。
 *
 * 只读、失败即回退默认值:读不到就当浅色 + 允许动效,绝不影响启动。
 */
object WindowsTheme {

    private const val PERSONALIZE = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"
    private const val DESKTOP_METRICS = "HKCU\\Control Panel\\Desktop\\WindowMetrics"

    @Volatile
    private var darkCache: Boolean? = null

    @Volatile
    private var reduceMotionCache: Boolean? = null

    /** 系统是否处于深色模式(`AppsUseLightTheme == 0`) */
    fun isDark(): Boolean {
        darkCache?.let { return it }
        val value = readDword(PERSONALIZE, "AppsUseLightTheme") == 0
        darkCache = value
        return value
    }

    /** 系统是否要求"减弱动态效果"(`MinAnimate == 0`) */
    fun reduceMotion(): Boolean {
        reduceMotionCache?.let { return it }
        val value = readDword(DESKTOP_METRICS, "MinAnimate") == 0
        reduceMotionCache = value
        return value
    }

    /** 设置变化后强制重读 */
    fun invalidate() {
        darkCache = null
        reduceMotionCache = null
    }

    private fun readDword(path: String, name: String): Int? = runCatching {
        val process = ProcessBuilder("reg", "query", path, "/v", name)
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().use { it.readText() }
        process.waitFor()
        val match = Regex("$name\\s+REG_DWORD\\s+0x([0-9a-fA-F]+)").find(output) ?: return null
        match.groupValues[1].toInt(16)
    }.getOrNull()
}
