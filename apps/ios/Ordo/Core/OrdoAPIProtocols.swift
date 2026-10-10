//
//  OrdoAPIProtocols.swift
//  Ordo
//
//  契约 §7.4(HTTP 接口)/ §7.5(WebSocket 消息)的 Swift 侧协议与 DTO。
//
//  统一请求头:
//    X-Ordo-Schema: 1
//    X-Ordo-Device: <deviceId>
//    X-Ordo-Client: ios/1.0.0
//  Authorization: Bearer <accessToken>(/auth/* 与 /health 除外)
//

import Foundation

// MARK: - 通用

/// 契约 §7.4 错误模型 `{ "error": { "code", "message", "details" } }`。
public struct OrdoAPIErrorBody: Codable, Sendable {
    public var error: OrdoAPIErrorPayload
}

public struct OrdoAPIErrorPayload: Codable, Sendable {
    public var code: String
    public var message: String
    public var details: [String: OrdoJSONValue]?

    public init(code: String, message: String, details: [String: OrdoJSONValue]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

/// 契约 §7.4 错误码全集。
public enum OrdoAPIErrorCode: String, Codable, Sendable {
    case validationFailed = "VALIDATION_FAILED"
    case authRequired = "AUTH_REQUIRED"
    case authInvalidCredentials = "AUTH_INVALID_CREDENTIALS"
    case authTokenExpired = "AUTH_TOKEN_EXPIRED"
    case authEmailTaken = "AUTH_EMAIL_TAKEN"
    case syncSeqGap = "SYNC_SEQ_GAP"
    case syncOpTooLarge = "SYNC_OP_TOO_LARGE"
    case notFound = "NOT_FOUND"
    case rateLimited = "RATE_LIMITED"
    case `internal` = "INTERNAL"
    /// 客户端本地错误(网络中断、解码失败等),服务端不会返回该值。
    case transport = "TRANSPORT"
    case decoding = "DECODING"
}

public struct OrdoAPIError: Error, LocalizedError, Sendable {
    public var code: OrdoAPIErrorCode
    public var message: String
    public var httpStatus: Int?
    public var details: [String: OrdoJSONValue]?

    public init(code: OrdoAPIErrorCode, message: String, httpStatus: Int? = nil, details: [String: OrdoJSONValue]? = nil) {
        self.code = code
        self.message = message
        self.httpStatus = httpStatus
        self.details = details
    }

    public var errorDescription: String? { message }

    /// 是否需要走 refresh 重放(契约 §7.4「401 处理」)。
    public var requiresTokenRefresh: Bool {
        code == .authTokenExpired || (httpStatus == 401 && code != .authInvalidCredentials)
    }

    /// 中文提示,直接可用于 Toast。
    public var localizedHint: String {
        switch code {
        case .validationFailed: return "数据校验未通过,请升级或检查输入"
        case .authRequired: return "需要登录"
        case .authInvalidCredentials: return "邮箱或密码不正确"
        case .authTokenExpired: return "登录已过期,正在重新登录"
        case .authEmailTaken: return "该邮箱已被注册"
        case .syncSeqGap: return "同步序号出现缺口,正在重新拉取"
        case .syncOpTooLarge: return "单条变更过大,已跳过"
        case .notFound: return "服务端未找到该资源"
        case .rateLimited: return "操作过于频繁,请稍后再试"
        case .internal: return "服务端异常"
        case .transport: return "网络不可用"
        case .decoding: return "响应解析失败"
        }
    }

    public static func transport(_ message: String) -> OrdoAPIError {
        OrdoAPIError(code: .transport, message: message)
    }

    public static func decoding(_ message: String) -> OrdoAPIError {
        OrdoAPIError(code: .decoding, message: message)
    }
}

// MARK: - 健康检查 / 鉴权

public struct OrdoHealth: Codable, Sendable {
    public var status: String
    public var version: String
    public var serverTime: Int64
}

/// 契约 §7.6.1 的账号主体。
///
/// · `email` 可为 `null` —— 游客账号在服务端就是 `email: null`(`server/src/routes/auth.ts`);
/// · `isGuest` 是 v1.2 新增字段,老服务端不返回时应退化为 `false`(而不是解码失败)。
public struct OrdoUser: Codable, Hashable, Sendable {
    public var id: String
    public var email: String?
    public var isGuest: Bool

    public init(id: String, email: String?, isGuest: Bool = false) {
        self.id = id
        self.email = email
        self.isGuest = isGuest
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, isGuest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.isGuest = try container.decodeIfPresent(Bool.self, forKey: .isGuest) ?? false
    }
}

public struct OrdoDevice: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var platform: String
}

public struct OrdoAuthSession: Codable, Sendable {
    public var user: OrdoUser
    public var device: OrdoDevice
    public var accessToken: String
    public var refreshToken: String
    /// 秒。
    public var expiresIn: Int
}

// MARK: - 游客登录 / 升级(契约 §7.6.2)

/// `POST /v1/auth/guest` 的请求体(与核心 `sync.GuestAuthRequest` 一致)。
public struct OrdoGuestAuthRequest: Codable, Sendable {
    public var deviceId: String?
    public var deviceName: String
    public var platform: String

    public init(deviceId: String? = nil, deviceName: String, platform: String = "ios/1.0.0") {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
    }
}

/// `POST /v1/auth/upgrade` 的请求体(需带 Access Token;邮箱被占用返回 `AUTH_EMAIL_TAKEN`)。
public struct OrdoUpgradeRequest: Codable, Sendable {
    public var email: String
    public var password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

/// `POST /v1/auth/upgrade` 的响应:**userId 与数据都不变**,只翻转 `isGuest`。
public struct OrdoUpgradeResponse: Codable, Sendable {
    public var user: OrdoUser
}

// MARK: - 邮箱验证码登录(契约 §7.6.5,v1.3 新增)

/// `POST /v1/auth/email/code` 的请求体(与核心 `sync.EmailCodeRequest` 一致)。
public struct OrdoEmailCodeRequest: Codable, Sendable {
    public var email: String

    public init(email: String) {
        self.email = email
    }
}

/// `POST /v1/auth/email/code` 的响应(与核心 `sync.EmailCodeSent` 一致,202 受理)。
///
/// · `expiresIn`:验证码有效期(秒),契约默认 **300**;
/// · `retryAfter`:同一邮箱再次请求的最小间隔(秒),契约默认 **60**,客户端据此跑倒计时;
/// · `devCode`:**仅开发模式**(`ORDO_MAIL_TRANSPORT=console` 且 `ORDO_DEV_ECHO_CODE=1`)才回显,
///   生产环境恒为 `nil`。它只用于本地联调时自动填入输入框,**任何生产路径都不得依赖**。
///
/// 字段全部按「缺省即契约默认值」解码,避免老服务端少回一个字段就整条响应解码失败。
public struct OrdoEmailCodeSent: Codable, Sendable {
    public var sent: Bool
    public var expiresIn: Int64
    public var retryAfter: Int64
    public var devCode: String?

    public init(sent: Bool = true, expiresIn: Int64 = 300, retryAfter: Int64 = 60, devCode: String? = nil) {
        self.sent = sent
        self.expiresIn = expiresIn
        self.retryAfter = retryAfter
        self.devCode = devCode
    }

    private enum CodingKeys: String, CodingKey {
        case sent, expiresIn, retryAfter, devCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sent = try container.decodeIfPresent(Bool.self, forKey: .sent) ?? true
        self.expiresIn = try container.decodeIfPresent(Int64.self, forKey: .expiresIn) ?? 300
        self.retryAfter = try container.decodeIfPresent(Int64.self, forKey: .retryAfter) ?? 60
        self.devCode = try container.decodeIfPresent(String.self, forKey: .devCode)
    }
}

/// `POST /v1/auth/email/login` 的请求体(与核心 `sync.EmailCodeLoginRequest` 一致)。
///
/// 响应与 register/login/guest **同构**(`OrdoAuthSession`);邮箱未注册时服务端**自动建号**。
public struct OrdoEmailCodeLoginRequest: Codable, Sendable {
    public var email: String
    public var code: String
    public var deviceId: String?
    public var deviceName: String
    public var platform: String

    public init(
        email: String,
        code: String,
        deviceId: String? = nil,
        deviceName: String,
        platform: String = "ios/1.0.0"
    ) {
        self.email = email
        self.code = code
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
    }
}

public struct OrdoDeviceRegistration: Codable, Sendable {
    public var deviceId: String
    public var deviceName: String
    public var platform: String

    public init(deviceId: String, deviceName: String, platform: String = "ios/1.0.0") {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
    }
}

// MARK: - 同步

public struct OrdoPushRequest: Codable, Sendable {
    public var deviceId: String
    public var sinceSeq: Int64
    public var ops: [OrdoOp]

    public init(deviceId: String, sinceSeq: Int64, ops: [OrdoOp]) {
        self.deviceId = deviceId
        self.sinceSeq = sinceSeq
        self.ops = ops
    }
}

/// 单条 op 被接受的结果(与 `server/src/services/sync.ts` 的 `PushAccepted` 一致)。
public struct OrdoAcceptedOp: Codable, Hashable, Sendable {
    public var opId: String
    public var serverSeq: Int64?
    public var duplicate: Bool?
    public var applied: Bool?
    /// 命中 stale / completion_immutable,但仍按契约 §7.3 规则 3 合并了标签。
    public var tagsMerged: Bool?
}

/// op 被拒的原因(与 `server/src/domain/errors.ts` 的 `OpRejectionReason` 一致)。
public enum OrdoOpRejectionReason: String, Codable, Sendable {
    /// clientTs 早于服务端 updatedAt,LWW 判负
    case stale
    /// 完成不可回滚
    case completionImmutable = "completion_immutable"
    /// 命中删除墓碑,旧 op 不能复活实体
    case tombstoned
    /// 项目完成规则(§2.2 硬约束)不满足
    case projectIncomplete = "project_incomplete"
    /// payload 未通过 schema 校验
    case invalid
    /// 未知原因(服务端新增时的前向兼容)
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OrdoOpRejectionReason(rawValue: raw) ?? .unknown
    }

    public var hint: String {
        switch self {
        case .stale: return "本地版本较旧,已被远端覆盖"
        case .completionImmutable: return "完成状态不可回滚"
        case .tombstoned: return "该条目已删除"
        case .projectIncomplete: return "项目还有未完成的待办"
        case .invalid: return "数据未通过校验"
        case .unknown: return "服务端拒绝了该变更"
        }
    }
}

public struct OrdoRejectedOp: Codable, Hashable, Sendable {
    public var opId: String
    public var reason: OrdoOpRejectionReason
    public var message: String?
    public var tagsMerged: Bool?
}

public struct OrdoPushResponse: Codable, Sendable {
    public var serverSeq: Int64
    public var accepted: [OrdoAcceptedOp]
    public var rejected: [OrdoRejectedOp]
    /// 捎带拉取的远端 ops。
    public var ops: [OrdoOp]

    public var acceptedOpIds: [String] { accepted.map(\.opId) }
}

public struct OrdoPullResponse: Codable, Sendable {
    public var serverSeq: Int64
    public var ops: [OrdoOp]
    public var hasMore: Bool
}

/// `GET /v1/sync/snapshot` 的响应(与 `server/src/services/sync.ts` 的 `SnapshotResult` 一致)。
///
/// 注意:契约 §2.2 把 headings 内嵌在 project 中,而接口给出**扁平** `headings` 数组;
/// 另外该响应**不含** `schemaVersion`(只在本机快照里),因此这里是可选字段。
/// `merged()` 负责对齐成 Swift 侧的嵌套快照。
public struct OrdoRemoteSnapshot: Codable, Sendable {
    public var schemaVersion: Int?
    public var serverSeq: Int64
    public var areas: [OrdoArea]
    public var projects: [OrdoProject]
    public var headings: [OrdoHeading]?
    public var todos: [OrdoTodo]
    public var tags: [OrdoTag]

    public init(
        schemaVersion: Int? = OrdoSchema.version,
        serverSeq: Int64,
        areas: [OrdoArea],
        projects: [OrdoProject],
        headings: [OrdoHeading]? = nil,
        todos: [OrdoTodo],
        tags: [OrdoTag]
    ) {
        self.schemaVersion = schemaVersion
        self.serverSeq = serverSeq
        self.areas = areas
        self.projects = projects
        self.headings = headings
        self.todos = todos
        self.tags = tags
    }

    /// Swift 嵌套快照 → 契约/Kotlin 的扁平 wire 形状(headings 同时保留在 projects 内;
    /// Kotlin 的 `ignoreUnknownKeys = true` 会忽略项目里的 `headings` 字段)。
    public init(snapshot: OrdoSnapshot, serverSeq: Int64 = 0) {
        self.schemaVersion = snapshot.schemaVersion
        self.serverSeq = serverSeq == 0 ? snapshot.serverSeq : serverSeq
        self.areas = snapshot.areas
        self.projects = snapshot.projects
        self.headings = snapshot.headings
        self.todos = snapshot.todos
        self.tags = snapshot.tags
    }

    public func merged() -> OrdoSnapshot {
        var resolvedProjects = projects
        if let headings, !headings.isEmpty {
            let grouped = Dictionary(grouping: headings, by: \.projectId)
            resolvedProjects = projects.map { project in
                var copy = project
                if let items = grouped[project.id] {
                    copy.headings = items.sorted { $0.order < $1.order }
                }
                return copy
            }
        }
        return OrdoSnapshot(
            schemaVersion: schemaVersion ?? OrdoSchema.version,
            serverSeq: serverSeq,
            areas: areas.sorted { $0.order < $1.order },
            projects: resolvedProjects.sorted { $0.order < $1.order },
            todos: todos.sorted { $0.order < $1.order },
            tags: tags.sorted { $0.name < $1.name }
        )
    }
}

// MARK: - 协议

public protocol OrdoSyncAPI: Sendable {
    func health() async throws -> OrdoHealth
    func snapshot() async throws -> OrdoRemoteSnapshot
    func push(_ request: OrdoPushRequest) async throws -> OrdoPushResponse
    func pull(sinceSeq: Int64, limit: Int) async throws -> OrdoPullResponse
    func registerDevice(_ registration: OrdoDeviceRegistration) async throws
}

public protocol OrdoAuthAPI: Sendable {
    func register(email: String, password: String, deviceName: String, platform: String) async throws -> OrdoAuthSession
    func login(email: String, password: String, deviceName: String, platform: String) async throws -> OrdoAuthSession
    func refresh(refreshToken: String) async throws -> OrdoAuthSession
    func logout(refreshToken: String) async throws
    /// 契约 §7.6.2:游客登录 —— 服务端创建匿名账号并返回**正常令牌**。
    func guest(_ request: OrdoGuestAuthRequest) async throws -> OrdoAuthSession
    /// 契约 §7.6.2:把游客账号升级为正式账号(userId 与数据不变)。
    func upgrade(accessToken: String, _ request: OrdoUpgradeRequest) async throws -> OrdoUpgradeResponse
    /// 契约 §7.6.5:请求邮箱验证码(`202`;60s 内重复 → `429 RATE_LIMITED` / `code_throttled`)。
    func requestEmailCode(_ request: OrdoEmailCodeRequest) async throws -> OrdoEmailCodeSent
    /// 契约 §7.6.5:验证码登录(邮箱未注册时服务端自动建号)。
    func emailLogin(_ request: OrdoEmailCodeLoginRequest) async throws -> OrdoAuthSession
}

public extension OrdoAuthAPI {
    func register(email: String, password: String, deviceName: String) async throws -> OrdoAuthSession {
        try await register(email: email, password: password, deviceName: deviceName, platform: "ios/1.0.0")
    }

    func login(email: String, password: String, deviceName: String) async throws -> OrdoAuthSession {
        try await login(email: email, password: password, deviceName: deviceName, platform: "ios/1.0.0")
    }

    /// 与核心 `AuthApi.guest(GuestAuthRequest)` 同名同参。
    func guest(deviceId: String? = nil, deviceName: String, platform: String = "ios/1.0.0") async throws -> OrdoAuthSession {
        try await guest(OrdoGuestAuthRequest(deviceId: deviceId, deviceName: deviceName, platform: platform))
    }

    /// 与核心 `AuthApi.requestEmailCode(EmailCodeRequest)` 同名同参。
    func requestEmailCode(email: String) async throws -> OrdoEmailCodeSent {
        try await requestEmailCode(OrdoEmailCodeRequest(email: email))
    }

    /// 与核心 `AuthApi.emailLogin(EmailCodeLoginRequest)` 同名同参(deviceId 缺省由请求头 `X-Ordo-Device` 携带)。
    func emailLogin(
        email: String,
        code: String,
        deviceId: String? = nil,
        deviceName: String,
        platform: String = "ios/1.0.0"
    ) async throws -> OrdoAuthSession {
        try await emailLogin(
            OrdoEmailCodeLoginRequest(
                email: email,
                code: code,
                deviceId: deviceId,
                deviceName: deviceName,
                platform: platform
            )
        )
    }
}

// MARK: - WebSocket(契约 §7.5)

public enum OrdoSocketServerMessage: Sendable {
    case hello(serverSeq: Int64, serverTime: Int64)
    case ops(serverSeq: Int64, ops: [OrdoOp])
    case reminder(todoId: String, title: String, at: String)
    case ping(t: Int64)
    case unknown(type: String)

    public static func decode(from json: OrdoJSONValue) throws -> OrdoSocketServerMessage {
        guard let type = json["type"]?.stringValue else {
            throw OrdoJSONError.missingField("type")
        }
        switch type {
        case "hello":
            return .hello(serverSeq: json["serverSeq"]?.intValue ?? 0, serverTime: json["serverTime"]?.intValue ?? 0)
        case "ops":
            let ops: [OrdoOp]
            if let raw = json["ops"]?.arrayValue {
                ops = try raw.map { try OrdoPayloadCodec.decode(OrdoOp.self, from: $0) }
            } else {
                ops = []
            }
            return .ops(serverSeq: json["serverSeq"]?.intValue ?? 0, ops: ops)
        case "reminder":
            return .reminder(
                todoId: json["todoId"]?.stringValue ?? "",
                title: json["title"]?.stringValue ?? "",
                at: json["at"]?.stringValue ?? ""
            )
        case "ping":
            return .ping(t: json["t"]?.intValue ?? 0)
        default:
            return .unknown(type: type)
        }
    }
}

/// 客户端 → 服务端消息。`encode()` 生成契约 §7.5 的 JSON 文本帧。
public enum OrdoSocketClientMessage: Sendable {
    case subscribe(deviceId: String)
    case ack(serverSeq: Int64)
    case pong

    public func encode() throws -> String {
        let value: OrdoJSONValue
        switch self {
        case .subscribe(let deviceId):
            value = .object(["type": .string("subscribe"), "deviceId": .string(deviceId)])
        case .ack(let serverSeq):
            value = .object(["type": .string("ack"), "serverSeq": .int(serverSeq)])
        case .pong:
            value = .object(["type": .string("pong")])
        }
        let data = try value.data()
        guard let text = String(data: data, encoding: .utf8) else {
            throw OrdoJSONError.unsupportedType("utf8")
        }
        return text
    }
}

// MARK: - 令牌(契约 §9)

public struct OrdoTokens: Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    /// epoch millis。
    public var expiresAt: Int64

    public init(accessToken: String, refreshToken: String, expiresAt: Int64) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool { expiresAt <= Int64(Date().timeIntervalSince1970 * 1000) }

    public init(session: OrdoAuthSession, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.accessToken = session.accessToken
        self.refreshToken = session.refreshToken
        self.expiresAt = now + Int64(session.expiresIn) * 1000
    }
}

/// 令牌读写(落在 kv 表;refresh 轮换时整体覆盖)。
public protocol OrdoTokenStore: AnyObject, Sendable {
    func load() async -> OrdoTokens?
    func save(_ tokens: OrdoTokens?) async
    func currentDeviceId() async -> String
    func saveDeviceId(_ deviceId: String) async
}
