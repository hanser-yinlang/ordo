package com.ordo.core.sync

import com.ordo.core.model.Area
import com.ordo.core.model.Heading
import com.ordo.core.model.Op
import com.ordo.core.model.Project
import com.ordo.core.model.Tag
import com.ordo.core.model.Todo
import kotlinx.serialization.Serializable

/* ============================================================================
 * 同步协议 DTO(契约 §7.4 / §7.5)—— 字段名与 TS 后端严格一致
 * ========================================================================== */

@Serializable
data class UserDto(
    val id: String,
    /**
     * 游客账号没有邮箱,服务端返回 `email: null`(契约 §7.6.1)。
     * 这里必须可空 —— 否则用 kotlinx 直接解码的端(Android / Windows)在游客登录时会抛解码异常。
     */
    val email: String? = null,
    val isGuest: Boolean = false,
)

@Serializable
data class DeviceDto(val id: String, val name: String, val platform: String)

@Serializable
data class AuthRequest(
    val email: String,
    val password: String,
    val deviceName: String,
    val platform: String
)

/** 游客登录:不需要邮箱口令,只带设备信息(契约 §7.6.2) */
@Serializable
data class GuestAuthRequest(
    val deviceId: String? = null,
    val deviceName: String,
    val platform: String
)

/** 游客升级为正式账号:userId 与数据都不变(契约 §7.6.2) */
@Serializable
data class UpgradeRequest(val email: String, val password: String)

@Serializable
data class UpgradeResponse(val user: UserDto)

/* ---- 邮箱验证码登录(契约 §7.6.5,v1.3 新增)---- */

/** 请求邮箱登录验证码 */
@Serializable
data class EmailCodeRequest(val email: String)

/**
 * 验证码已受理。[expiresIn] 为验证码有效期(秒,默认 300),
 * [retryAfter] 为同一邮箱再次请求的最小间隔(秒,默认 60,客户端据此跑倒计时)。
 *
 * [devCode] **只在开发模式**(服务端 `ORDO_MAIL_TRANSPORT=console` 且 `ORDO_DEV_ECHO_CODE=1`)
 * 才会返回,生产环境恒为 null —— 客户端不得依赖它,只应在联调时展示。
 */
@Serializable
data class EmailCodeSent(
    val sent: Boolean = true,
    val expiresIn: Long = 300,
    val retryAfter: Long = 60,
    val devCode: String? = null,
)

/** 邮箱验证码登录:未注册邮箱由服务端**自动建号**(契约 §7.6.5) */
@Serializable
data class EmailCodeLoginRequest(
    val email: String,
    val code: String,
    val deviceId: String? = null,
    val deviceName: String,
    val platform: String,
)

@Serializable
data class RefreshRequest(val refreshToken: String)

@Serializable
data class AuthResponse(
    val user: UserDto,
    val device: DeviceDto,
    val accessToken: String,
    val refreshToken: String,
    val expiresIn: Long
)

@Serializable
data class SnapshotResponse(
    val serverSeq: Long,
    val areas: List<Area> = emptyList(),
    val projects: List<Project> = emptyList(),
    val headings: List<Heading> = emptyList(),
    val todos: List<Todo> = emptyList(),
    val tags: List<Tag> = emptyList()
)

@Serializable
data class PushRequest(
    val deviceId: String,
    val sinceSeq: Long,
    val ops: List<Op>
)

@Serializable
data class RejectedOp(val opId: String, val reason: String)

@Serializable
data class PushResponse(
    val serverSeq: Long,
    val accepted: List<String> = emptyList(),
    val rejected: List<RejectedOp> = emptyList(),
    /** 捎带拉取:sinceSeq 之后服务端产生的 ops */
    val ops: List<Op> = emptyList()
)

@Serializable
data class PullResponse(
    val serverSeq: Long,
    val ops: List<Op> = emptyList(),
    val hasMore: Boolean = false
)

@Serializable
data class ApiErrorBody(val code: String, val message: String)

/** 服务端返回的结构化错误 */
class OrdoApiException(val code: String, override val message: String) : Exception(message)

/* ============================================================================
 * 由各端实现的网络接口(Ktor / URLSession / ohos.net.http)
 * ========================================================================== */

interface SyncApi {
    suspend fun push(request: PushRequest): PushResponse

    suspend fun pull(sinceSeq: Long, limit: Int = 500): PullResponse

    suspend fun fetchSnapshot(): SnapshotResponse
}

interface AuthApi {
    suspend fun register(request: AuthRequest): AuthResponse

    suspend fun login(request: AuthRequest): AuthResponse

    suspend fun refresh(refreshToken: String): AuthResponse

    /** 游客登录:服务端创建匿名账号并返回正常令牌(数据同样入库、同样多端同步,契约 §7.6) */
    suspend fun guest(request: GuestAuthRequest): AuthResponse

    /** 把游客账号升级为正式账号(userId 与数据不变) */
    suspend fun upgrade(accessToken: String, request: UpgradeRequest): UpgradeResponse

    /**
     * 请求邮箱登录验证码(契约 §7.6.5)。
     * 同一邮箱 60s 内重复请求会被服务端以 429 `RATE_LIMITED`(details.reason = code_throttled)拒绝。
     */
    suspend fun requestEmailCode(request: EmailCodeRequest): EmailCodeSent

    /**
     * 邮箱验证码登录(契约 §7.6.5):响应与 register / login / guest **同构**。
     * 邮箱未注册时服务端自动建号(正式账号、无口令);已注册时直接登录该账号。
     */
    suspend fun emailLogin(request: EmailCodeLoginRequest): AuthResponse
}

/** 快车道推送(契约 §7.5) */
@Serializable
data class ReminderPush(
    val todoId: String,
    val title: String,
    val at: String
)

/** 实时通道:各端用各自 WebSocket 实现,行为一致 */
interface RealtimeChannel {
    /**
     * 建立连接并持续接收;内部需实现指数退避重连。
     * @param onOps 收到远端 ops(批量)
     * @param onReminder 收到快车道提醒
     */
    suspend fun connect(
        deviceId: String,
        onOps: (List<Op>, Long) -> Unit,
        onReminder: (ReminderPush) -> Unit
    )

    fun close()
}
