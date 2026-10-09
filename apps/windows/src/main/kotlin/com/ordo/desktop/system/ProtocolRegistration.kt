package com.ordo.desktop.system

/**
 * `ordo://` 协议注册(04-UI规范 §7 各端实现映射:Windows 端 = `ordo://` 协议注册)。
 *
 * 真实实现写 **当前用户** 的注册表(HKCU,不需要管理员):
 * ```
 * HKCU\Software\Classes\ordo                     (默认) = "URL:Ordo Protocol"
 * HKCU\Software\Classes\ordo                     URL Protocol = ""
 * HKCU\Software\Classes\ordo\shell\open\command  (默认) = "<exe>" "%1"
 * ```
 * 注册后浏览器 / 其它应用里的 `ordo://today`、`ordo://project/<id>`、`ordo://todo/<id>`
 * 会以命令行参数形式拉起应用,由 `DeepLink.fromArgs` 解析。
 */
interface ProtocolRegistrar {

    /** 当前用户是否已把 `ordo://` 指向本应用 */
    fun isRegistered(): Boolean

    /** 写入注册表;失败返回 false(不抛异常) */
    fun register(): Boolean

    /** 展示用:当前登记的命令行 */
    fun command(): String?
}

/** 内存实现:测试与离屏渲染用,绝不碰注册表 */
class InMemoryProtocolRegistrar(initial: Boolean = false, private val command: String = "ordo") : ProtocolRegistrar {

    private var registered: Boolean = initial

    override fun isRegistered(): Boolean = registered

    override fun register(): Boolean {
        registered = true
        return true
    }

    override fun command(): String? = if (registered) command else null
}

/**
 * Windows 实现:走 `reg.exe` 写 HKCU(与 [WindowsAutoStart] 同一套 [CommandRunner] 抽象)。
 * 所有真实调用都在 [runCatching] 里,策略禁用 / 无权限时退化为"未注册",不影响主流程。
 */
class WindowsProtocolRegistrar(
    private val exePath: String? = WindowsAutoStart.defaultExePath(),
    private val runner: CommandRunner = ProcessCommandRunner
) : ProtocolRegistrar {

    override fun isRegistered(): Boolean = runCatching {
        if (exePath.isNullOrBlank()) return@runCatching false
        val result = runner.run(queryArgs())
        result.ok && result.output.contains("ordo", ignoreCase = true) && result.output.contains("shell", ignoreCase = true)
    }.getOrDefault(false)

    override fun register(): Boolean = runCatching {
        val target = exePath?.takeIf { it.isNotBlank() } ?: return@runCatching false
        registerArgs(target).all { args -> runner.run(args).ok }
    }.getOrDefault(false)

    override fun command(): String? = runCatching {
        val target = exePath?.takeIf { it.isNotBlank() } ?: return@runCatching null
        if (!isRegistered()) null else "${WindowsAutoStart.quote(target)} \"%1\""
    }.getOrNull()

    /** 三条 `reg add`:协议名 / URL Protocol 标记 / 打开命令 */
    fun registerArgs(target: String): List<List<String>> = listOf(
        listOf("add", ROOT_KEY, "/ve", "/t", "REG_SZ", "/d", "URL:Ordo Protocol", "/f"),
        listOf("add", ROOT_KEY, "/v", "URL Protocol", "/t", "REG_SZ", "/d", "", "/f"),
        listOf("add", COMMAND_KEY, "/ve", "/t", "REG_SZ", "/d", "${WindowsAutoStart.quote(target)} \"%1\"", "/f")
    )

    fun queryArgs(): List<String> = listOf("query", COMMAND_KEY, "/ve")

    companion object {
        /** 当前用户级协议根键(不需要管理员权限) */
        const val ROOT_KEY = "HKCU\\Software\\Classes\\ordo"
        const val COMMAND_KEY = "HKCU\\Software\\Classes\\ordo\\shell\\open\\command"

        /** 深链协议名 */
        const val SCHEME = "ordo"
    }
}
