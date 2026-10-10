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
data class UserDto(val id: String, val email: String, val isGuest: Boolean = false)

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
