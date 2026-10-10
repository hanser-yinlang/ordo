package com.ordo.android

import com.ordo.android.auth.AuthMethod
import com.ordo.android.auth.AuthMode
import com.ordo.android.auth.AuthStage
import com.ordo.android.auth.CodeSendState
import com.ordo.android.auth.EmailCodeAction
import com.ordo.android.auth.EmailCodeError
import com.ordo.android.auth.EmailCodeErrorMapper
import com.ordo.android.auth.EmailCodeRules
import com.ordo.android.net.OrdoAuthError
import com.ordo.android.net.parseApiError
import com.ordo.android.net.parseErrorDetails
import com.ordo.android.vm.AuthUi
import com.ordo.core.sync.OrdoApiException
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 邮箱验证码登录（契约 §7.6.5 · UI §5.1 v1.3）的纯逻辑验收。
 *
 * 覆盖：① 码格式/邮箱校验（本地先拦）；② 倒计时与 retryAfter 夹取；
 * ③ 「获取验证码」按钮状态机；④ canSubmit / busy（主按钮与验证码按钮互斥）；
 * ⑤ 服务端错误码 + details.reason → 中文提示类型的映射；⑥ 底部链接的三入口可达性。
 */
class EmailCodeLoginTest {

    /* ------------------------ ① 验证码格式与邮箱校验 ------------------------ */

    @Test
    fun `验证码输入只保留数字并截到6位`() {
        assertEquals("123456", EmailCodeRules.sanitizeCode("123456"))
        assertEquals("只保留数字", "1234", EmailCodeRules.sanitizeCode("1a2b3c4"))
        assertEquals("超过6位截断", "123456", EmailCodeRules.sanitizeCode("1234567890"))
        assertEquals("空格与字母全部丢弃", "", EmailCodeRules.sanitizeCode("  abc  "))
    }

    @Test
    fun `满6位数字才算填完`() {
        assertTrue(EmailCodeRules.isCodeComplete("123456"))
        assertFalse("5位不算填完", EmailCodeRules.isCodeComplete("12345"))
        assertFalse("含非数字不算填完", EmailCodeRules.isCodeComplete("12345a"))
        assertFalse(EmailCodeRules.isCodeComplete(""))
    }

    @Test
    fun `请求验证码前本地拦截空邮箱与非法邮箱`() {
        assertEquals(EmailCodeError.EMAIL_REQUIRED, EmailCodeRules.requestBlocker("   "))
        assertEquals(EmailCodeError.EMAIL_INVALID, EmailCodeRules.requestBlocker("no-at-sign"))
        assertEquals(EmailCodeError.EMAIL_INVALID, EmailCodeRules.requestBlocker("a b@ordo.app"))
        assertEquals(EmailCodeError.EMAIL_INVALID, EmailCodeRules.requestBlocker("@ordo.app"))
        assertNull("合法邮箱放行（前后空格先 trim）", EmailCodeRules.requestBlocker("  a@ordo.app  "))
    }

    @Test
    fun `提交前必须邮箱合法且码满6位`() {
        assertEquals(EmailCodeError.EMAIL_REQUIRED, EmailCodeRules.submitBlocker("", "123456"))
        assertEquals(EmailCodeError.EMAIL_INVALID, EmailCodeRules.submitBlocker("bad", "123456"))
        assertEquals(EmailCodeError.CODE_INCOMPLETE, EmailCodeRules.submitBlocker("a@ordo.app", "12345"))
        assertNull(EmailCodeRules.submitBlocker("a@ordo.app", "123456"))
    }

    /* ---------------------- ② 倒计时（retryAfter，§7.6.5） ---------------------- */

    @Test
    fun `retryAfter缺失或非法时回退到契约默认60秒`() {
        assertEquals(60, EmailCodeRules.normalizedRetryAfter(null))
        assertEquals(60, EmailCodeRules.normalizedRetryAfter(0L))
        assertEquals(60, EmailCodeRules.normalizedRetryAfter(-5L))
        assertEquals("服务端给的值优先", 42, EmailCodeRules.normalizedRetryAfter(42L))
    }

    @Test
    fun `retryAfter超大值被夹取避免按钮长期锁死`() {
        assertEquals(EmailCodeRules.MAX_RETRY_AFTER_SECONDS, EmailCodeRules.normalizedRetryAfter(999_999L))
        assertEquals(3600, EmailCodeRules.normalizedRetryAfter(3_600L))
    }

    @Test
    fun `倒计时递减到0后不再变负`() {
        assertEquals(59, EmailCodeRules.tick(60))
        assertEquals(1, EmailCodeRules.tick(2))
        assertEquals(0, EmailCodeRules.tick(1))
        assertEquals(0, EmailCodeRules.tick(0))
        assertEquals(0, EmailCodeRules.tick(-3))
    }

    /* ------------------ ③ 「获取验证码」按钮状态机（busy） ------------------ */

    @Test
    fun `获取验证码按钮状态机`() {
        assertEquals(
            CodeSendState.IDLE,
            EmailCodeRules.sendState("a@ordo.app", 0, requesting = false, submitting = false),
        )
        assertEquals(
            "请求中显示转圈",
            CodeSendState.SENDING,
            EmailCodeRules.sendState("a@ordo.app", 0, requesting = true, submitting = false),
        )
        assertEquals(
            "倒计时中置灰并显示剩余秒数",
            CodeSendState.COOLDOWN,
            EmailCodeRules.sendState("a@ordo.app", 37, requesting = false, submitting = false),
        )
        assertEquals(
            "整体提交中禁止再请求（避免与登录请求竞争）",
            CodeSendState.DISABLED,
            EmailCodeRules.sendState("a@ordo.app", 0, requesting = false, submitting = true),
        )
        assertEquals(
            "邮箱不合法时置灰",
            CodeSendState.DISABLED,
            EmailCodeRules.sendState("bad", 0, requesting = false, submitting = false),
        )
        assertEquals(
            "请求中优先于倒计时",
            CodeSendState.SENDING,
            EmailCodeRules.sendState("a@ordo.app", 37, requesting = true, submitting = false),
        )
    }

    /* ------------------------- ④ AuthUi 的派生状态 ------------------------- */

    @Test
    fun `口令模式的canSubmit语义保持不变`() {
        val empty = AuthUi(stage = AuthStage.LOGIN, loginMethod = AuthMethod.PASSWORD)
        assertTrue("口令模式空表单仍可点，点后给本地校验文案", empty.canSubmit)
        assertTrue(empty.copy(mode = AuthMode.REGISTER).canSubmit)
        assertFalse("提交中禁用", empty.copy(submitting = true).canSubmit)
        assertFalse("未进入登录页不可提交", empty.copy(stage = AuthStage.LOADING).canSubmit)
        assertFalse(
            "口令模式不应误判验证码状态",
            empty.copy(codeRequesting = true).canSubmit,
        )
    }

    @Test
    fun `验证码模式必须邮箱合法且满6位才能提交`() {
        val base = AuthUi(
            stage = AuthStage.LOGIN,
            loginMethod = AuthMethod.EMAIL_CODE,
            email = "a@ordo.app",
        )
        assertFalse("未填码不可提交", base.canSubmit)
        assertFalse("不足6位不可提交", base.copy(code = "12345").canSubmit)
        assertTrue("满6位可提交", base.copy(code = "123456").canSubmit)
        assertFalse("邮箱非法不可提交", base.copy(email = "bad", code = "123456").canSubmit)
        assertFalse("提交中不可重复提交", base.copy(code = "123456", submitting = true).canSubmit)
        assertFalse("请求验证码中不可提交", base.copy(code = "123456", codeRequesting = true).canSubmit)
    }

    @Test
    fun `canRequestCode只在验证码模式且非忙碌非倒计时时为真`() {
        val codeMode = AuthUi(
            stage = AuthStage.LOGIN,
            loginMethod = AuthMethod.EMAIL_CODE,
            email = "a@ordo.app",
        )
        assertTrue(codeMode.canRequestCode)
        assertFalse("倒计时中不可请求", codeMode.copy(codeCooldownSeconds = 60).canRequestCode)
        assertFalse("请求中不可重复点击", codeMode.copy(codeRequesting = true).canRequestCode)
        assertFalse("提交中不可请求", codeMode.copy(submitting = true).canRequestCode)
        assertFalse("邮箱非法不可请求", codeMode.copy(email = "bad").canRequestCode)
        assertFalse(
            "口令模式没有验证码按钮",
            AuthUi(stage = AuthStage.LOGIN, loginMethod = AuthMethod.PASSWORD, email = "a@ordo.app").canRequestCode,
        )
    }

    /* ---------------------- ⑤ 错误映射（code + reason） ---------------------- */

    @Test
    fun `429限流映射为请求过频`() {
        assertEquals(
            EmailCodeError.THROTTLED,
            EmailCodeErrorMapper.fromApi(EmailCodeAction.REQUEST_CODE, "RATE_LIMITED", "code_throttled"),
        )
        assertEquals(
            "没有 reason 也按限流处理（错误码是冻结枚举）",
            EmailCodeError.THROTTLED,
            EmailCodeErrorMapper.fromApi(EmailCodeAction.SUBMIT_CODE, "RATE_LIMITED", null),
        )
    }

    @Test
    fun `401的三个reason映射成三种失败`() {
        assertEquals(
            EmailCodeError.CODE_INVALID,
            EmailCodeErrorMapper.fromApi(EmailCodeAction.SUBMIT_CODE, "AUTH_INVALID_CREDENTIALS", "code_invalid"),
        )
        assertEquals(
            EmailCodeError.CODE_EXPIRED,
            EmailCodeErrorMapper.fromApi(EmailCodeAction.SUBMIT_CODE, "AUTH_INVALID_CREDENTIALS", "code_expired"),
        )
        assertEquals(
            EmailCodeError.CODE_ATTEMPTS_EXCEEDED,
            EmailCodeErrorMapper.fromApi(
                EmailCodeAction.SUBMIT_CODE,
                "AUTH_INVALID_CREDENTIALS",
                "code_attempts_exceeded",
            ),
        )
        assertEquals(
            "reason 大小写/空格不影响映射",
            EmailCodeError.CODE_EXPIRED,
            EmailCodeErrorMapper.fromApi(EmailCodeAction.SUBMIT_CODE, "AUTH_INVALID_CREDENTIALS", " Code_Expired "),
        )
    }

    @Test
    fun `401没有reason时按验证码不正确处理不泄漏账号存在性`() {
        assertEquals(
            EmailCodeError.CODE_INVALID,
            EmailCodeErrorMapper.fromApi(EmailCodeAction.SUBMIT_CODE, "AUTH_INVALID_CREDENTIALS", null),
        )
        assertEquals(
            EmailCodeError.CODE_INVALID,
            EmailCodeErrorMapper.fromApi(EmailCodeAction.SUBMIT_CODE, "AUTH_INVALID_CREDENTIALS", "unknown_reason"),
        )
    }

    @Test
    fun `VALIDATION_FAILED按动作分别映射为邮箱问题与码格式问题`() {
        assertEquals(
            EmailCodeError.EMAIL_INVALID,
            EmailCodeErrorMapper.fromApi(EmailCodeAction.REQUEST_CODE, "VALIDATION_FAILED", null),
        )
        assertEquals(
            EmailCodeError.CODE_INCOMPLETE,
            EmailCodeErrorMapper.fromApi(EmailCodeAction.SUBMIT_CODE, "VALIDATION_FAILED", null),
        )
    }

    @Test
    fun `发信失败与未知错误分别映射`() {
        assertEquals(
            EmailCodeError.MAIL_FAILED,
            EmailCodeErrorMapper.fromApi(EmailCodeAction.REQUEST_CODE, "INTERNAL", "mail_failed"),
        )
        assertEquals(
            "INTERNAL 但没有 mail_failed 时归为未知",
            EmailCodeError.UNKNOWN,
            EmailCodeErrorMapper.fromApi(EmailCodeAction.REQUEST_CODE, "INTERNAL", null),
        )
        assertEquals(
            EmailCodeError.UNKNOWN,
            EmailCodeErrorMapper.fromApi(EmailCodeAction.SUBMIT_CODE, "NOT_FOUND", null),
        )
        assertEquals(
            "空错误码按网络问题处理（无结构化响应体）",
            EmailCodeError.NETWORK,
            EmailCodeErrorMapper.fromApi(EmailCodeAction.REQUEST_CODE, null, null),
        )
    }

    @Test
    fun `异常翻译优先看结构化错误再看网络`() {
        assertEquals(
            EmailCodeError.CODE_EXPIRED,
            EmailCodeErrorMapper.fromThrowable(
                OrdoAuthError("AUTH_INVALID_CREDENTIALS", "code_expired", 300L, "验证码已过期"),
                EmailCodeAction.SUBMIT_CODE,
            ),
        )
        assertEquals(
            "不带 reason 的 shared 异常按码不正确处理",
            EmailCodeError.CODE_INVALID,
            EmailCodeErrorMapper.fromThrowable(
                OrdoApiException("AUTH_INVALID_CREDENTIALS", "invalid"),
                EmailCodeAction.SUBMIT_CODE,
            ),
        )
        assertEquals(
            EmailCodeError.NETWORK,
            EmailCodeErrorMapper.fromThrowable(IOException("连接超时"), EmailCodeAction.REQUEST_CODE),
        )
        assertEquals(
            EmailCodeError.UNKNOWN,
            EmailCodeErrorMapper.fromThrowable(IllegalStateException("boom"), EmailCodeAction.REQUEST_CODE),
        )
    }

    @Test
    fun `retryAfterOf取异常里的秒数否则用默认60`() {
        assertEquals(
            42,
            EmailCodeErrorMapper.retryAfterOf(
                OrdoAuthError("RATE_LIMITED", "code_throttled", 42L, "太频繁"),
            ),
        )
        assertEquals(
            "同一错误码但没有 retryAfter 时回退 60",
            EmailCodeRules.DEFAULT_RETRY_AFTER_SECONDS,
            EmailCodeErrorMapper.retryAfterOf(OrdoAuthError("RATE_LIMITED", "code_throttled", null, "太频繁")),
        )
        assertEquals(
            EmailCodeRules.DEFAULT_RETRY_AFTER_SECONDS,
            EmailCodeErrorMapper.retryAfterOf(IOException("net")),
        )
    }

    @Test
    fun `过期与试错超限后必须清空验证码重新获取`() {
        assertTrue(EmailCodeRules.clearsCode(EmailCodeError.CODE_EXPIRED))
        assertTrue(EmailCodeRules.clearsCode(EmailCodeError.CODE_ATTEMPTS_EXCEEDED))
        assertFalse("码错误可以原地改一位重试", EmailCodeRules.clearsCode(EmailCodeError.CODE_INVALID))
        assertFalse(EmailCodeRules.clearsCode(EmailCodeError.THROTTLED))
    }

    /* --------------------------- ⑥ 错误体 details 解析 --------------------------- */

    @Test
    fun `错误体解析出code与details里的reason和retryAfterSec`() {
        val body = """
            {"error":{"code":"RATE_LIMITED","message":"请求过于频繁",
            "details":{"reason":"code_throttled","retryAfterSec":60}}}
        """.trimIndent()

        assertEquals("RATE_LIMITED", parseApiError(body)?.code)
        val details = parseErrorDetails(body)
        assertEquals("code_throttled", details.reason)
        assertEquals("限流秒数以 details.retryAfterSec 为准", 60L, details.retryAfterSeconds)
    }

    @Test
    fun `retryAfterSec与retryAfter同时存在时取retryAfterSec`() {
        val body = """
            {"error":{"code":"RATE_LIMITED","message":"请求过于频繁",
            "details":{"reason":"code_throttled","retryAfterSec":30,"retryAfter":90}}}
        """.trimIndent()

        assertEquals(
            "契约澄清后以 retryAfterSec 为准，旧的 retryAfter 只做兜底",
            30L,
            parseErrorDetails(body).retryAfterSeconds,
        )
    }

    @Test
    fun `旧字段与根节点的retryAfter仍可兜底解析`() {
        val detailsOnly = """{"error":{"code":"RATE_LIMITED","details":{"retryAfter":45}}}"""
        assertEquals(45L, parseErrorDetails(detailsOnly).retryAfterSeconds)

        val rootOnly = """{"code":"RATE_LIMITED","message":"太频繁","retryAfter":77}"""
        assertEquals(77L, parseErrorDetails(rootOnly).retryAfterSeconds)
    }

    @Test
    fun `错误体没有details时不报错且字段为空`() {
        val details = parseErrorDetails("""{"error":{"code":"AUTH_INVALID_CREDENTIALS","message":"x"}}""")
        assertNull(details.reason)
        assertNull(details.retryAfterSeconds)

        val broken = parseErrorDetails("这不是 JSON")
        assertNull(broken.reason)
        assertNull(broken.retryAfterSeconds)
    }

    /* ------------------- ⑦ 底部链接：三个入口始终可达 ------------------- */

    @Test
    fun `底部链接在口令模式下登录注册互换`() {
        val toRegister = EmailCodeRules.linkTarget(AuthMethod.PASSWORD, AuthMode.LOGIN)
        assertEquals(AuthMethod.PASSWORD, toRegister.method)
        assertEquals(AuthMode.REGISTER, toRegister.mode)

        val toLogin = EmailCodeRules.linkTarget(AuthMethod.PASSWORD, AuthMode.REGISTER)
        assertEquals(AuthMethod.PASSWORD, toLogin.method)
        assertEquals(AuthMode.LOGIN, toLogin.mode)
    }

    @Test
    fun `底部链接在验证码模式下回到口令注册`() {
        val target = EmailCodeRules.linkTarget(AuthMethod.EMAIL_CODE, AuthMode.LOGIN)
        assertEquals("注册入口必须仍然点得到（UI 5_1 三入口硬约束）", AuthMethod.PASSWORD, target.method)
        assertEquals(AuthMode.REGISTER, target.mode)
    }
}
