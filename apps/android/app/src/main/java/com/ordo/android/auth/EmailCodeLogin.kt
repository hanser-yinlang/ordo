package com.ordo.android.auth

import com.ordo.android.net.OrdoAuthError
import com.ordo.android.net.OrdoErrors
import com.ordo.core.sync.OrdoApiException
import java.io.IOException

/* ============================================================================
 * 邮箱验证码登录的纯逻辑（契约 §7.6.5 · UI §5.1 v1.3）
 *
 * 这里不依赖 Android 框架，判定规则全部可以直接跑 JVM 单测：
 * ViewModel 只负责「调用接口 + 把结果翻译成界面状态」，倒计时 / 可提交 /
 * 码格式 / 忙碌态 / 错误映射的唯一事实来源都在本文件。
 * ========================================================================== */

/** 契约 §7.6.5 错误表里的 `details.reason` 枚举值 */
object EmailCodeReason {
    const val CODE_THROTTLED = "code_throttled"
    const val CODE_INVALID = "code_invalid"
    const val CODE_EXPIRED = "code_expired"
    const val CODE_ATTEMPTS_EXCEEDED = "code_attempts_exceeded"
    const val MAIL_FAILED = "mail_failed"
}

/** 验证码流程的失败类型（→ ViewModel 映射成中文文案；不靠颜色单独表达，UI §5.1） */
enum class EmailCodeError {
    EMAIL_REQUIRED,
    EMAIL_INVALID,
    CODE_INCOMPLETE,
    CODE_INVALID,
    CODE_EXPIRED,
    CODE_ATTEMPTS_EXCEEDED,
    THROTTLED,
    MAIL_FAILED,
    NETWORK,
    UNKNOWN,
}

/**
 * 失败发生在哪一步。
 *
 * 同一个 `VALIDATION_FAILED`：请求验证码时是邮箱格式问题，提交验证码时是码格式问题
 * （契约 §7.6.5 错误表第一行），必须分开映射。
 */
enum class EmailCodeAction { REQUEST_CODE, SUBMIT_CODE }

/** 「获取验证码」按钮的显示状态 */
enum class CodeSendState { IDLE, SENDING, COOLDOWN, DISABLED }

/** 底部长文本链接的目标状态（三入口硬约束 + 免密登录） */
data class AuthLinkTarget(val method: AuthMethod, val mode: AuthMode)

object EmailCodeRules {

    /** 契约 §7.6.5：验证码固定 6 位数字 */
    const val CODE_LENGTH = 6

    /** 契约 §7.6.5：同一邮箱再次请求的最小间隔 60s（服务端 retryAfter 的兜底值） */
    const val DEFAULT_RETRY_AFTER_SECONDS = 60

    /** 倒计时上限：服务端给再大的值也不会把按钮锁死太久（防御性夹取） */
    const val MAX_RETRY_AFTER_SECONDS = 3600

    /** 只保留数字并截到 6 位：输入法带空格/字母、粘贴整段文本都不会把校验卡死 */
    fun sanitizeCode(raw: String): String = raw.filter { it.isDigit() }.take(CODE_LENGTH)

    /** 满 6 位数字才算填完（「满 6 位自动提交」的触发条件） */
    fun isCodeComplete(code: String): Boolean =
        code.length == CODE_LENGTH && code.all { it.isDigit() }

    /** 邮箱是否像一个邮箱（本地先拦，避免白跑一次网络；与服务端口径一致的宽松判断） */
    fun emailLooksValid(email: String): Boolean {
        val mail = email.trim()
        return mail.contains('@') &&
            !mail.startsWith('@') &&
            !mail.endsWith('@') &&
            !mail.contains(' ') &&
            !mail.contains('\t')
    }

    /** 请求验证码的本地前置条件；null = 可以请求 */
    fun requestBlocker(email: String): EmailCodeError? {
        if (email.isBlank()) return EmailCodeError.EMAIL_REQUIRED
        if (!emailLooksValid(email)) return EmailCodeError.EMAIL_INVALID
        return null
    }

    /** 提交验证码的本地前置条件；null = 可以提交 */
    fun submitBlocker(email: String, code: String): EmailCodeError? {
        requestBlocker(email)?.let { return it }
        if (!isCodeComplete(code)) return EmailCodeError.CODE_INCOMPLETE
        return null
    }

    /** 服务端 retryAfter（秒）→ 倒计时秒数；缺失/非正数用 60，超大值夹取 */
    fun normalizedRetryAfter(retryAfterSeconds: Long?): Int {
        val value = retryAfterSeconds ?: 0L
        if (value <= 0L) return DEFAULT_RETRY_AFTER_SECONDS
        return value.coerceAtMost(MAX_RETRY_AFTER_SECONDS.toLong()).toInt()
    }

    /** 倒计时每跳一次；到 0 为止（不会变成负数） */
    fun tick(seconds: Int): Int = if (seconds <= 0) 0 else seconds - 1

    /**
     * 「获取验证码」按钮状态。
     *
     * 优先级：请求中 → 转圈；整体提交中 → 置灰；倒计时中 → 显示剩余秒数（置灰）；
     * 邮箱不合法 → 置灰（用户改邮箱后自动恢复）。
     */
    fun sendState(
        email: String,
        cooldownSeconds: Int,
        requesting: Boolean,
        submitting: Boolean,
    ): CodeSendState = when {
        requesting -> CodeSendState.SENDING
        submitting -> CodeSendState.DISABLED
        cooldownSeconds > 0 -> CodeSendState.COOLDOWN
        requestBlocker(email) != null -> CodeSendState.DISABLED
        else -> CodeSendState.IDLE
    }

    /** 这两种失败后旧验证码已作废（过期/试错超限），必须清空并重新获取（契约 §7.6.5） */
    fun clearsCode(error: EmailCodeError): Boolean =
        error == EmailCodeError.CODE_EXPIRED || error == EmailCodeError.CODE_ATTEMPTS_EXCEEDED

    /**
     * 底部文本链接的目标（UI §5.1 三入口硬约束）：
     *  - 口令模式：登录 ⇄ 注册互换；
     *  - 验证码模式：回到「口令 + 注册」——注册入口任何时候都点得到。
     */
    fun linkTarget(method: AuthMethod, mode: AuthMode): AuthLinkTarget = when {
        method == AuthMethod.EMAIL_CODE -> AuthLinkTarget(AuthMethod.PASSWORD, AuthMode.REGISTER)
        mode == AuthMode.LOGIN -> AuthLinkTarget(AuthMethod.PASSWORD, AuthMode.REGISTER)
        else -> AuthLinkTarget(AuthMethod.PASSWORD, AuthMode.LOGIN)
    }
}

/** 服务端错误 → [EmailCodeError] 的纯映射（契约 §7.6.5 错误表） */
object EmailCodeErrorMapper {

    /**
     * @param code 契约 §7.4 错误码
     * @param reason `details.reason`（可空；服务端不一定给）
     */
    fun fromApi(action: EmailCodeAction, code: String?, reason: String?): EmailCodeError {
        val normalized = reason?.trim()?.lowercase()
        return when (code) {
            // 429：同邮箱 60s 内重复请求 / 超小时日上限（§7.6.5），客户端据 retryAfter 跑倒计时
            OrdoErrors.RATE_LIMITED -> EmailCodeError.THROTTLED

            OrdoErrors.AUTH_INVALID_CREDENTIALS -> when (normalized) {
                EmailCodeReason.CODE_EXPIRED -> EmailCodeError.CODE_EXPIRED
                EmailCodeReason.CODE_ATTEMPTS_EXCEEDED -> EmailCodeError.CODE_ATTEMPTS_EXCEEDED
                // 含 code_invalid 与「服务端没给 reason」两种情况：都按「验证码不正确」提示，
                // 不泄漏账号是否存在（与口令登录同一处理）
                else -> EmailCodeError.CODE_INVALID
            }

            OrdoErrors.VALIDATION_FAILED -> when (action) {
                EmailCodeAction.REQUEST_CODE -> EmailCodeError.EMAIL_INVALID
                EmailCodeAction.SUBMIT_CODE -> EmailCodeError.CODE_INCOMPLETE
            }

            OrdoErrors.INTERNAL ->
                if (normalized == EmailCodeReason.MAIL_FAILED) EmailCodeError.MAIL_FAILED
                else EmailCodeError.UNKNOWN

            null, "" -> EmailCodeError.NETWORK
            else -> EmailCodeError.UNKNOWN
        }
    }

    /** 把任意异常翻译成失败类型：结构化错误看 code/reason，网络类异常按「网络不可用」处理 */
    fun fromThrowable(error: Throwable, action: EmailCodeAction): EmailCodeError = when (error) {
        is OrdoAuthError -> fromApi(action, error.code, error.reason)
        is OrdoApiException -> fromApi(action, error.code, null)
        is IOException -> EmailCodeError.NETWORK
        else -> EmailCodeError.UNKNOWN
    }

    /** 429 的 retryAfter（秒）：异常里带就用它，否则用契约默认 60 */
    fun retryAfterOf(error: Throwable): Int =
        EmailCodeRules.normalizedRetryAfter((error as? OrdoAuthError)?.retryAfterSeconds)
}
