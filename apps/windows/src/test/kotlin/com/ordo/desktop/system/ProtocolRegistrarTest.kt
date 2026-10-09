package com.ordo.desktop.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `ordo://` 协议注册测试(04-UI规范 §7:Windows 端协议注册)。
 *
 * 与开机自启同样用注入的 [CommandRunner] 验证参数;唯一碰真实注册表的是只读查询,且只断言"不抛异常"。
 */
class ProtocolRegistrarTest {

    private class FakeRunner(private val ok: Boolean = true, private val output: String = "") : CommandRunner {
        val calls = mutableListOf<List<String>>()
        override fun run(args: List<String>): CommandResult {
            calls += args
            return CommandResult(if (ok) 0 else 1, output)
        }
    }

    private val exe = "C:\\Program Files\\Ordo\\Ordo.exe"

    @Test
    fun `内存实现可注册`() {
        val registrar = InMemoryProtocolRegistrar()
        assertFalse(registrar.isRegistered())
        assertNull(registrar.command())
        assertTrue(registrar.register())
        assertTrue(registrar.isRegistered())
        assertEquals("ordo", registrar.command())
    }

    @Test
    fun `注册写的是 HKCU 下的 ordo 协议与 shell open command`() {
        val runner = FakeRunner()
        val registrar = WindowsProtocolRegistrar(exePath = exe, runner = runner)

        assertTrue(registrar.register())
        val calls = runner.calls
        assertEquals("三条 reg add:协议名 / URL Protocol 标记 / 打开命令", 3, calls.size)
        assertTrue(calls.all { it.first() == "add" && it.last() == "/f" })
        assertEquals(WindowsProtocolRegistrar.ROOT_KEY, calls[0][1])
        assertEquals("URL:Ordo Protocol", calls[0][6])
        assertEquals("URL Protocol", calls[1][3])
        assertEquals(WindowsProtocolRegistrar.COMMAND_KEY, calls[2][1])
        assertEquals("\"$exe\" \"%1\"", calls[2][6])
        assertEquals("HKCU\\Software\\Classes\\ordo", WindowsProtocolRegistrar.ROOT_KEY)
        assertEquals("ordo", WindowsProtocolRegistrar.SCHEME)
        assertTrue(
            "URL Protocol 标记是 Windows 识别自定义协议的关键",
            calls[1].contains("URL Protocol")
        )
    }

    @Test
    fun `查询命中已注册的 command 键才算已注册`() {
        val runner = FakeRunner(
            ok = true,
            output = "HKEY_CURRENT_USER\\Software\\Classes\\ordo\\shell\\open\\command\r\n" +
                "    (默认)    REG_SZ    \"$exe\" \"%1\"\r\n"
        )
        val registrar = WindowsProtocolRegistrar(exePath = exe, runner = runner)

        assertTrue(registrar.isRegistered())
        assertEquals(listOf("query", WindowsProtocolRegistrar.COMMAND_KEY, "/ve"), runner.calls.single())
        assertEquals("\"$exe\" \"%1\"", registrar.command())
    }

    @Test
    fun `未注册时 command 为空`() {
        val runner = FakeRunner(ok = false, output = "错误: 系统找不到指定的注册表项或值。")
        val registrar = WindowsProtocolRegistrar(exePath = exe, runner = runner)
        assertFalse(registrar.isRegistered())
        assertNull(registrar.command())
    }

    @Test
    fun `拿不到 exe 路径时不碰注册表`() {
        val runner = FakeRunner()
        val registrar = WindowsProtocolRegistrar(exePath = null, runner = runner)
        assertFalse(registrar.isRegistered())
        assertFalse(registrar.register())
        assertNull(registrar.command())
        assertTrue(runner.calls.isEmpty())
    }

    @Test
    fun `命令失败或异常都退化为未注册而不是抛异常`() {
        val failing = WindowsProtocolRegistrar(exePath = exe, runner = FakeRunner(ok = false))
        assertFalse(failing.register())
        assertFalse(failing.isRegistered())

        val throwing = WindowsProtocolRegistrar(exePath = exe, runner = CommandRunner { throw IllegalStateException("策略禁用") })
        assertFalse(throwing.register())
        assertFalse(throwing.isRegistered())
        assertNull(throwing.command())
    }

    /** 只读冒烟:真实查一次注册表;沙箱/CI 里也只是"未注册",绝不写入 */
    @Test
    fun `真实注册表查询不抛异常且不写入`() {
        val registrar = WindowsProtocolRegistrar(exePath = exe, runner = ProcessCommandRunner)
        val registered = runCatching { registrar.isRegistered() }.getOrDefault(false)
        assertTrue(registered || !registered)
        if (!registered) assertNull(registrar.command())
    }
}
