package com.ordo.android.net

/**
 * 契约 §7.4 错误码全集与客户端应对策略。
 *
 * 服务端统一错误模型：`{ "error": { "code": …, "message": … } }`
 * 这里集中定义客户端需要识别的错误码，避免在业务代码里散落字符串字面量。
 */
object OrdoErrors {

    const val VALIDATION_FAILED = "VALIDATION_FAILED"
    const val AUTH_REQUIRED = "AUTH_REQUIRED"
    const val AUTH_INVALID_CREDENTIALS = "AUTH_INVALID_CREDENTIALS"
    const val AUTH_TOKEN_EXPIRED = "AUTH_TOKEN_EXPIRED"
    const val AUTH_EMAIL_TAKEN = "AUTH_EMAIL_TAKEN"
    const val SYNC_SEQ_GAP = "SYNC_SEQ_GAP"
    const val SYNC_OP_TOO_LARGE = "SYNC_OP_TOO_LARGE"
    const val NOT_FOUND = "NOT_FOUND"
    const val RATE_LIMITED = "RATE_LIMITED"
    const val INTERNAL = "INTERNAL"

    /** 登录态失效：需要重新登录（保留本地数据，契约 §7.4） */
    fun isAuthFailure(code: String?): Boolean =
        code == AUTH_REQUIRED || code == AUTH_TOKEN_EXPIRED

    /** 需要全量快照重同步（契约 §7.4：SYNC_SEQ_GAP） */
    fun needsFullResync(code: String?): Boolean = code == SYNC_SEQ_GAP

    /** 需要退避重试（写接口限流 10 req/s） */
    fun shouldBackoff(code: String?): Boolean = code == RATE_LIMITED

    /** 客户端版本不兼容：契约 §8 要求提示升级并停止同步 */
    fun needsUpgrade(code: String?): Boolean = code == VALIDATION_FAILED

    /** op 体积超限：应拆分或丢弃该 op（契约 §7.4：单 op ≤ 256 KB） */
    fun isOpTooLarge(code: String?): Boolean = code == SYNC_OP_TOO_LARGE

    /** 从 SyncEngine 返回的 "CODE: message" 文本中取出错误码 */
    fun codeOf(errorText: String?): String? =
        errorText?.substringBefore(':')?.trim()?.takeIf { it.isNotEmpty() }
}
