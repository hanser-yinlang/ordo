package com.ordo.desktop.system

import java.io.File

/**
 * 「开机自启」抽象(设置页开关)。
 *
 * 桌面端的真实实现写 Windows 注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`;
 * 单元测试与无注册表环境用 [InMemoryAutoStart] / 注入的 [CommandRunner],互不干扰。
 */
interface AutoStart {

    /** 当前是否已登记开机自启 */
    fun isEnabled(): Boolean

    /** 打开/关闭开机自启;返回是否操作成功(失败不抛异常,由界面提示) */
    fun setEnabled(enabled: Boolean): Boolean

    /** 展示用:当前登记的命令行(未开启时为空) */
    fun command(): String?
}

/** 内存实现:测试默认,也用于"便携模式"下不写注册表的场景 */
class InMemoryAutoStart(initial: Boolean = false, private val command: String = DEFAULT_COMMAND) : AutoStart {

    private var enabled: Boolean = initial

    override fun isEnabled(): Boolean = enabled

    override fun setEnabled(enabled: Boolean): Boolean {
        this.enabled = enabled
        return true
    }

    override fun command(): String? = if (enabled) command else null

    companion object {
        const val DEFAULT_COMMAND = "\"C:\\Ordo\\Ordo.exe\""
    }
}

/** 一次外部命令的调用结果 */
data class CommandResult(val exitCode: Int, val output: String) {
    val ok: Boolean get() = exitCode == 0
}

/** 可注入的命令执行器:真实实现走 `reg.exe`,测试用假实现记录调用 */
fun interface CommandRunner {
    fun run(args: List<String>): CommandResult
}

/**
 * Windows 注册表 Run 键实现(契约:设置页"开机自启")。
 *
 * 走系统的 `reg.exe`,不引第三方库、不依赖 JNI:
 *  - 打开:`reg add HKCU\...\Run /v Ordo /t REG_SZ /d "<exe>" /f`
 *  - 关闭:`reg delete HKCU\...\Run /v Ordo /f`
 *  - 查询:`reg query HKCU\...\Run /v Ordo`
 *
 * **所有真实调用都包在 [runCatching] 里**:注册表被策略禁用、`reg.exe` 缺失、无权限时
 * 一律退化为"未开启/操作失败",绝不因为一个开关把主界面拖崩。
 */
class WindowsAutoStart(
    private val exePath: String? = defaultExePath(),
    private val runner: CommandRunner = ProcessCommandRunner
) : AutoStart {

    override fun isEnabled(): Boolean = runCatching {
        val target = exePath ?: return@runCatching false
        val result = runner.run(ArrayList(queryArgs()))
        result.ok && result.output.contains(KEY_NAME, ignoreCase = true) && target.isNotBlank()
    }.getOrDefault(false)

    override fun setEnabled(enabled: Boolean): Boolean = runCatching {
        val args = if (enabled) enableArgs() ?: return@runCatching false else deleteArgs()
        runner.run(args).ok
    }.getOrDefault(false)

    override fun command(): String? = runCatching {
        if (!isEnabled()) null else exePath
    }.getOrNull()

    /** 组装"开启自启"的参数;拿不到可执行文件路径时返回 null */
    fun enableArgs(): List<String>? {
        val target = exePath?.takeIf { it.isNotBlank() } ?: return null
        return listOf("add", RUN_KEY, "/v", KEY_NAME, "/t", "REG_SZ", "/d", quote(target), "/f")
    }

    fun deleteArgs(): List<String> = listOf("delete", RUN_KEY, "/v", KEY_NAME, "/f")

    fun queryArgs(): List<String> = listOf("query", RUN_KEY, "/v", KEY_NAME)

    companion object {
        const val RUN_KEY = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
        const val KEY_NAME = "Ordo"

        /** 参数里的可执行文件路径要用引号包住,路径含空格时才不会被截断 */
        fun quote(path: String): String = if (path.startsWith("\"")) path else "\"$path\""

        /** 打包运行时 = 启动器自身;开发态退回 `java -jar` 不可靠,直接留空 */
        fun defaultExePath(): String? = runCatching {
            val home = System.getProperty("jpackage.app-path")
            if (!home.isNullOrBlank()) return@runCatching home
            val command = ProcessHandle.current().info().command().orElse(null)
            command?.takeIf { it.endsWith("Ordo.exe", ignoreCase = true) }
        }.getOrNull()

        /** 便携/绿色版:exe 就在应用目录下 */
        fun exeBeside(dir: File): String? = File(dir, "Ordo.exe").takeIf { it.isFile }?.absolutePath
    }
}

/** 真实执行器:`reg.exe`,输出合并 stdout+stderr,永不抛异常 */
object ProcessCommandRunner : CommandRunner {
    override fun run(args: List<String>): CommandResult = runCatching {
        val process = ProcessBuilder(listOf("reg.exe") + args)
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().use { it.readText() }
        val finished = process.waitFor(REG_TIMEOUT_SECONDS, java.util.concurrent.TimeUnit.SECONDS)
        if (!finished) {
            process.destroyForcibly()
            return@runCatching CommandResult(-1, "reg.exe 超时")
        }
        CommandResult(process.exitValue(), output)
    }.getOrElse { error ->
        CommandResult(-1, error.message ?: "reg.exe 调用失败")
    }

    private const val REG_TIMEOUT_SECONDS = 10L
}
