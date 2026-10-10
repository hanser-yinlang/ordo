package com.ordo.desktop.app

import com.ordo.desktop.net.OrdoHttpException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 验证码登录的**纯状态机**用例(契约 §7.6.5 / 04-UI规范 §5.1)。
 *
 * 这里不碰协程、不碰网络、不碰时钟:倒计时、canSubmit、码格式、busy、按钮文案
 * 全部是 [EmailCodeState] 上的纯函数,直接给定时间戳断言即可。
 */
class EmailCodeStateTest {

    private fun state(email: String = "me@ordo.app") = EmailCodeState(email = email)

    // ------------------------------------------------------------ 倒计时

    @Test
    fun `进入倒计时后按截止时刻算剩余秒数`() {
        val code = state().startCooldown(nowMillis = 1_000L, retryAfterSeconds = 60L)

        assertEquals("契约 §7.6.5:retryAfter 默认 60", 60L, code.remainingSeconds)
        assertEquals(61_000L, code.cooldownUntil!!)
        assertTrue(code.coolingDown)
        assertFalse("倒计时中不能请求", code.canRequestCode)
    }

    @Test
    fun `倒计时按秒递减,归零后恢复可用并清空截止时刻`() {
        val code = state().startCooldown(nowMillis = 0L, retryAfterSeconds = 60L)

        assertEquals(59L, code.tick(1_000L).remainingSeconds)
        assertEquals(30L, code.tick(30_000L).remainingSeconds)
        assertEquals(1L, code.tick(59_000L).remainingSeconds)

        val finished = code.tick(60_000L)
        assertEquals(0L, finished.remainingSeconds)
        assertNull("结束时清空截止时刻", finished.cooldownUntil)
        assertFalse(finished.coolingDown)
        assertTrue("恢复可用", finished.canRequestCode)
    }

    @Test
    fun `不足一秒向上取整_不会提前显示 0s`() {
        val code = state().startCooldown(nowMillis = 0L, retryAfterSeconds = 60)

        assertEquals("还剩 0.4s 也要显示 1s", 1L, code.tick(59_600L).remainingSeconds)
        assertEquals(0L, code.tick(60_000L).remainingSeconds)
    }

    @Test
    fun `窗口挂起后补算_用截止时刻而不是逐秒减一`() {
        val code = state().startCooldown(nowMillis = 10_000L, retryAfterSeconds = 60)

        // 中间一帧都没跑(窗口被挂起 45s),醒来直接按墙上时间重算
        assertEquals("掉帧不会让倒计时变慢", 15L, code.tick(55_000L).remainingSeconds)
        // 甚至一觉睡过截止时刻
        assertEquals(0L, code.tick(500_000L).remainingSeconds)
    }

    @Test
    fun `retryAfter 为 0 或异常值时不会把按钮锁死`() {
        val zero = state().startCooldown(nowMillis = 0L, retryAfterSeconds = 0L)
        assertFalse(zero.coolingDown)
        assertTrue(zero.canRequestCode)

        val absurd = state().startCooldown(nowMillis = 0L, retryAfterSeconds = 999_999L)
        assertEquals(
            "离谱值被夹在上限内,不至于永久置灰",
            EmailCodeState.MAX_COOLDOWN_SECONDS,
            absurd.remainingSeconds
        )
        assertTrue("上限内仍然是倒计时态", absurd.coolingDown)
    }

    @Test
    fun `未进入倒计时时 tick 是恒等操作`() {
        val code = state()
        assertEquals(code, code.tick(123_456L))
    }

    // ------------------------------------------------------------ 按钮文案与可用性

    @Test
    fun `获取验证码按钮文案随状态变化`() {
        assertEquals("获取验证码", state().requestButtonLabel)
        assertEquals("重新获取", state().copy(requested = true).requestButtonLabel)
        assertEquals(
            "倒计时中显示剩余秒数",
            "42s 后重试",
            state().startCooldown(0L, 60L).copy(remainingSeconds = 42L).requestButtonLabel
        )
    }

    @Test
    fun `邮箱不合法时不能请求也不能提交`() {
        for (bad in listOf("", "  ", "not-an-email", "a@b", "@b.c", "a@b.", "a.b@c")) {
            val code = EmailCodeState(email = bad, code = "123456")
            assertFalse("非法邮箱不能请求验证码:$bad", code.canRequestCode)
            assertFalse("非法邮箱不能提交:$bad", code.canSubmitCode)
            assertFalse("非法邮箱:$bad", EmailCodeState.isValidEmail(bad))
        }
        assertTrue(EmailCodeState.isValidEmail("me@ordo.app"))
        assertTrue(EmailCodeState.isValidEmail("a.b+tag@sub.example.cn"))
    }

    @Test
    fun `busy 时请求与提交都禁用`() {
        val code = EmailCodeState(email = "me@ordo.app", code = "123456", busy = true)
        assertFalse(code.canRequestCode)
        assertFalse(code.canSubmitCode)
    }

    @Test
    fun `提交要求 6 位数字,其余一律不放行`() {
        val valid = EmailCodeState(email = "me@ordo.app", code = "012345")
        assertTrue("前导 0 也是合法验证码", valid.codeComplete)
        assertTrue(valid.canSubmitCode)

        for (bad in listOf("", "1", "12345", "1234567", "12345a", "12 345")) {
            val code = EmailCodeState(email = "me@ordo.app", code = bad)
            assertFalse("不是 6 位数字不该放行:$bad", code.codeComplete)
            assertFalse("不是 6 位数字不该放行:$bad", code.canSubmitCode)
        }
    }

    // ------------------------------------------------------------ 输入清洗与自动提交

    @Test
    fun `验证码输入只留数字并截断到 6 位`() {
        val code = state()
        assertEquals("123456", code.withCodeInput("12 34-56").code)
        assertEquals("123456", code.withCodeInput("1234567890").code)
        assertEquals("1234", code.withCodeInput("12a34").code)
        assertEquals("", code.withCodeInput("abc").code)
    }

    @Test
    fun `改码会复位自动提交记录,同一个码只自动提交一次`() {
        val submitted = state().copy(code = "123456", autoSubmittedCode = "123456")
        assertTrue("同一个码不该再自动提交", submitted.alreadyAutoSubmitted())
        assertEquals("原样输入同一个码不改变状态", submitted, submitted.withCodeInput("123456"))

        val edited = submitted.withCodeInput("123457")
        assertFalse("改一位后应允许重新自动提交", edited.alreadyAutoSubmitted())
    }

    @Test
    fun `换邮箱会清掉「需重新获取」提示`() {
        val code = state().copy(mustRequestAgain = true)
        assertFalse(code.withEmailInput("other@ordo.app").mustRequestAgain)
        assertEquals("other@ordo.app", code.withEmailInput("other@ordo.app").email)
        assertTrue("同一个邮箱原样输入不动状态", code.withEmailInput("me@ordo.app").mustRequestAgain)
    }

    // ------------------------------------------------------------ 错误文案(契约 §7.6.5)

    @Test
    fun `验证码错误的细分 reason 都有中文文案`() {
        assertEquals("验证码不正确，请检查后重试", LoginMessages.codeError("AUTH_INVALID_CREDENTIALS", "code_invalid"))
        assertEquals("验证码已过期，请重新获取", LoginMessages.codeError("AUTH_INVALID_CREDENTIALS", "code_expired"))
        assertEquals(
            "该验证码尝试次数过多，请重新获取",
            LoginMessages.codeError("AUTH_INVALID_CREDENTIALS", "code_attempts_exceeded")
        )
        assertEquals("请求过于频繁，请稍后再试", LoginMessages.codeError("RATE_LIMITED", "code_throttled"))
    }

    @Test
    fun `没有 reason 时回落到错误码文案,离线说人话`() {
        assertEquals("验证码不正确或已失效，请重新获取", LoginMessages.codeError("AUTH_INVALID_CREDENTIALS", null))
        assertEquals("请求过于频繁，请稍后再试", LoginMessages.codeError("RATE_LIMITED", null))
        assertEquals("无法连接服务器，请检查地址与网络", LoginMessages.codeError(null, null))
        assertTrue(LoginMessages.codeError("VALIDATION_FAILED", null).contains("6 位"))
        assertNotNull(LoginMessages.codeError("SOMETHING_NEW", null))
    }

    @Test
    fun `重试间隔取服务端 retryAfterSec,缺失回落到契约默认 60`() {
        assertEquals(
            42L,
            LoginMessages.retryAfterOf(
                OrdoHttpException("RATE_LIMITED", "x", reason = "code_throttled", retryAfterSec = 42L)
            )
        )
        assertEquals(60L, LoginMessages.retryAfterOf(RuntimeException("connection refused")))
        assertEquals(
            "0 秒没有意义:夹到下限 1s,不会变成 0 秒空转",
            1L,
            LoginMessages.retryAfterOf(OrdoHttpException("RATE_LIMITED", "x", retryAfterSec = 0L))
        )
        assertEquals(
            "离谱的大值被夹到上限",
            com.ordo.desktop.net.MAX_RETRY_AFTER_SECONDS,
            LoginMessages.retryAfterOf(OrdoHttpException("RATE_LIMITED", "x", retryAfterSec = 999_999L))
        )
    }
}
