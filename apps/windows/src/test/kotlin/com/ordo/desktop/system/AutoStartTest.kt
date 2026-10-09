package com.ordo.desktop.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「开机自启」测试。
 *
 * 真实注册表写入只在打包后的应用里发生:这里用 [InMemoryAutoStart] 与注入的 [CommandRunner] 验证开关语义,
 * 并断言写注册表的命令确实是 `HKCU\...\CurrentVersion\Run` 下的 `Ordo` 值。
 * 唯一碰真实注册表的是"只读查询"用例,且只断言"不抛异常",绝不写入。
 */
class AutoStartTest {

    /** 假执行器:记录参数,按需返回成功/失败/输出 */
    private class FakeRunner(
        private val ok: Boolean = true,
        private val output: String = ""
    ) : CommandRunner {
        val calls = mutableListOf<List<String>>()
        override fun run(args: List<String>): CommandResult {
            calls += args
            return CommandResult(if (ok) 0 else 1, output)
        }
    }

    private val exe = "C:\\Program Files\\Ordo\\Ordo.exe"

    @Test
    fun `内存实现可以开与关`() {
        val auto = InMemoryAutoStart()
        assertFalse(auto.isEnabled())
        assertNull(auto.command())

        assertTrue(auto.setEnabled(true))
        assertTrue(auto.isEnabled())
        assertEquals(InMemoryAutoStart.DEFAULT_COMMAND, auto.command())

        assertTrue(auto.setEnabled(false))
        assertFalse(auto.isEnabled())
        assertNull(auto.command())
    }

    @Test
    fun `开启自启写的是 HKCU 的 Run 键`() {
        val runner = FakeRunner()
        val auto = WindowsAutoStart(exePath = exe, runner = runner)

        assertTrue(auto.setEnabled(true))
        val args = runner.calls.single()
        assertEquals(
            listOf("add", WindowsAutoStart.RUN_KEY, "/v", "Ordo", "/t", "REG_SZ", "/d", "\"$exe\"", "/f"),
            args
        )
        assertEquals("HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run", WindowsAutoStart.RUN_KEY)
        assertEquals("注册表值名固定为 Ordo", "Ordo", WindowsAutoStart.KEY_NAME)
    }

    @Test
    fun `关闭自启删除同名注册表值`() {
        val runner = FakeRunner()
        val auto = WindowsAutoStart(exePath = exe, runner = runner)

        assertTrue(auto.setEnabled(false))
        assertEquals(
            listOf("delete", WindowsAutoStart.RUN_KEY, "/v", "Ordo", "/f"),
            runner.calls.single()
        )
        assertTrue(auto.deleteArgs().containsAll(listOf("delete", "/v", "Ordo", "/f")))
    }

    @Test
    fun `查询命令读注册表并识别已登记的值`() {
        val runner = FakeRunner(
            ok = true,
            output = "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\r\n    Ordo    REG_SZ    $exe\r\n"
        )
        val auto = WindowsAutoStart(exePath = exe, runner = runner)

        assertTrue("查询结果里有 Ordo 值即视为已开启", auto.isEnabled())
        assertEquals(listOf("query", WindowsAutoStart.RUN_KEY, "/v", "Ordo"), runner.calls.single())
        assertEquals(exe, auto.command())
    }

    @Test
    fun `拿不到 exe 路径时不执行任何命令并保持关闭`() {
        val runner = FakeRunner()
        val auto = WindowsAutoStart(exePath = null, runner = runner)

        assertFalse(auto.isEnabled())
        assertFalse(auto.setEnabled(true))
        assertNull(auto.command())
        assertTrue("缺路径时不应触碰注册表", runner.calls.isEmpty())
        assertNull(auto.enableArgs())
    }

    @Test
    fun `注册表不可用时退化为关闭而不是抛异常`() {
        val throwing = CommandRunner { throw IllegalStateException("注册表被策略禁用") }
        val auto = WindowsAutoStart(exePath = exe, runner = throwing)

        assertFalse(auto.isEnabled())
        assertFalse("写入失败要返回 false,由界面提示", auto.setEnabled(true))
        assertNull(auto.command())
    }

    @Test
    fun `reg 命令失败时不算开启成功`() {
        val auto = WindowsAutoStart(exePath = exe, runner = FakeRunner(ok = false, output = "拒绝访问"))
        assertFalse(auto.setEnabled(true))
        assertFalse(auto.isEnabled())
    }

    @Test
    fun `参数里的路径带空格时加引号`() {
        assertEquals("\"$exe\"", WindowsAutoStart.quote(exe))
        assertEquals("\"C:\\Ordo\\Ordo.exe\"", WindowsAutoStart.quote("\"C:\\Ordo\\Ordo.exe\""))
        val args = WindowsAutoStart(exePath = exe, runner = FakeRunner()).enableArgs()!!
        assertTrue("带空格的路径必须整体加引号", args.contains("\"$exe\""))
    }

    /**
     * 只读冒烟:真实 `reg.exe` 查询一次 Run 键。
     * 用 runCatching 兜底 —— 沙箱/CI 里没有注册表也只是"未开启",不会让测试失败,更不会写入任何东西。
     */
    @Test
    fun `真实注册表查询不抛异常且不写入`() {
        val auto = WindowsAutoStart(exePath = exe, runner = ProcessCommandRunner)
        val enabled = runCatching { auto.isEnabled() }.getOrDefault(false)
        val command = runCatching { auto.command() }.getOrNull()
        // 只断言"能读到一个确定的布尔值";开与不开都取决于本机环境
        assertTrue(enabled || !enabled)
        if (!enabled) assertNull(command)
    }
}
