//
//  OrdoAuthService.swift
//  Ordo
//
//  契约 §7.6「登录门禁」的应用层装配:
//    · 会话读写(根目录 `session.json` → 核心 `OrdoSessionStore`);
//    · 四个入口:登录 / 注册 / **以游客身份继续** / **邮箱验证码登录**(契约 §7.6.5);
//    · 启动路由:有且未过期 → 直进;过期 → 先 refresh;refresh 失败 / 无 → 登录页;
//    · refresh 轮换后的会话回写(令牌的唯一宿主就是会话)。
//
//  本类**只依赖协议**(`OrdoSessionStoring` / `OrdoAccountTokenStore` / `OrdoAuthAPI`),
//  因此可以在 XCTest 里用桩实现驱动全部状态机分支(见 `OrdoSessionTests`)。
//

import Foundation
import Observation

@MainActor
@Observable
public final class OrdoAuthService {

    // MARK: 状态

    /// 当前会话(登录页/设置页/门禁都读它)。
    public private(set) var session: OrdoSessionRecord?
    /// 网络请求进行中(登录页用它禁用输入与三个入口)。
    public private(set) var isBusy = false
    /// 最近一次失败的**用户可读**提示(登录页的错误区文案)。
    public private(set) var lastError: String?

    // MARK: 依赖

    public let sessionStore: OrdoSessionStoring
    public let tokenStore: OrdoAccountTokenStore
    public let authAPI: OrdoAuthAPI
    /// 供同步用的 HTTP 客户端复用同一个刷新器(契约 §7.4:401 → refresh → 重放一次)。
    public let tokenRefresher: OrdoTokenRefresher?
    private let clock: OrdoClock

    public init(
        sessionStore: OrdoSessionStoring,
        tokenStore: OrdoAccountTokenStore,
        authAPI: OrdoAuthAPI,
        clock: OrdoClock = OrdoSystemClock()
    ) {
        self.sessionStore = sessionStore
        self.tokenStore = tokenStore
        self.authAPI = authAPI
        self.tokenRefresher = authAPI as? OrdoTokenRefresher
        self.clock = clock
    }

    /// 应用级装配:`Application Support/Ordo/session.json` + URLSession 网络层。
    public static func makeAppLevel(
        apiBaseURL: URL = OrdoAPIEnvironment.default.baseURL
    ) throws -> OrdoAuthService {
        let kv = try OrdoFileKVStorage(fileURL: OrdoAppDirectories.sessionFileURL())
        let sessionStore = OrdoCoreSessionStore(kvStorage: kv)
        let tokenStore = OrdoSessionTokenStore(sessions: sessionStore, kv: kv)
        let httpClient = OrdoHTTPClient(
            environment: OrdoAPIEnvironment(baseURL: apiBaseURL),
            tokenStore: tokenStore,
            deviceIdentity: tokenStore
        )
        let authAPI = URLSessionAuthApi(client: httpClient)
        // 契约 §7.4:401 时自动 refresh 并重放原请求一次。
        await httpClient.setRefresher(authAPI)
        return OrdoAuthService(sessionStore: sessionStore, tokenStore: tokenStore, authAPI: authAPI)
    }

    // MARK: 启动(契约 §7.6.4)

    /// 读会话并按契约决定去向;`accessToken` 过期时**先 refresh**,失败则回登录页。
    ///
    /// 无论哪条分支,该 userId 的本地数据目录都**不会**被删除(契约 §7.6.3);
    /// refresh 失败时只清掉这份已经不可用的会话。
    public func restore() async -> OrdoStartupPlan {
        let stored = await sessionStore.load()
        switch OrdoStartupPlanner.plan(session: stored, nowMillis: clock.nowMillis()) {
        case .showLogin:
            session = stored
            return .showLogin

        case .resume(let value):
            session = value
            return .resume(value)

        case .refresh(let expired):
            do {
                let refreshed = try await performRefresh(expired)
                session = refreshed
                return .resume(refreshed)
            } catch {
                lastError = Self.hint(for: error)
                await sessionStore.clear()
                session = nil
                return OrdoStartupPlanner.planAfterRefreshFailure(session: expired)
            }
        }
    }

    /// 启动后的静默 refresh(规范 §7.6.4「有且未过期 → 后台静默 refresh」)。
    ///
    /// 失败不打扰用户:会话仍然可用,下一次 401 会再走一遍 refresh 或转登录页。
    public func refreshInBackground() async {
        guard let current = session else { return }
        _ = try? await performRefresh(current)
    }

    // MARK: 三个入口

    @discardableResult
    public func login(email: String, password: String) async throws -> OrdoSessionRecord {
        try await authenticate { deviceName in
            try await self.authAPI.login(email: email, password: password, deviceName: deviceName)
        }
    }

    @discardableResult
    public func register(email: String, password: String) async throws -> OrdoSessionRecord {
        try await authenticate { deviceName in
            try await self.authAPI.register(email: email, password: password, deviceName: deviceName)
        }
    }

    /// 「以游客身份继续」:与正式登录**体验对等**(同一套令牌、同一套同步能力)。
    @discardableResult
    public func continueAsGuest() async throws -> OrdoSessionRecord {
        try await authenticate { deviceName in
            try await self.authAPI.guest(deviceName: deviceName)
        }
    }

    // MARK: 邮箱验证码登录(契约 §7.6.5)

    /// 请求邮箱验证码(免密登录第一步)。
    ///
    /// · 成功:`202` 受理,调用方按返回的 `retryAfter`(契约默认 60s)跑倒计时、置灰按钮;
    /// · 60s 内重复 / 超限:`429 RATE_LIMITED`(`details.reason = code_throttled`,
    ///   新秒数在 `details.retryAfterSec`,用 `retryAfterSeconds(from:)` 解析);
    /// · 邮箱格式不合法:`400 VALIDATION_FAILED`。
    ///
    /// 这里**不写** `lastError`:该字段是登录门禁的进入页提示,验证码请求的失败只属于当前表单,
    /// 由 `LoginView` 写进卡片错误区。
    @discardableResult
    public func requestEmailCode(email: String) async throws -> OrdoEmailCodeSent {
        try await authAPI.requestEmailCode(OrdoEmailCodeRequest(email: email))
    }

    /// 验证码登录(免密登录第二步):未注册邮箱由服务端**自动建号**,
    /// 已注册邮箱直接登录该账号 —— 两者与口令登录共用同一 `userId` 与同一套 refreshToken 体系。
    @discardableResult
    public func loginWithEmailCode(email: String, code: String) async throws -> OrdoSessionRecord {
        try await authenticate { deviceName in
            try await self.authAPI.emailLogin(
                OrdoEmailCodeLoginRequest(email: email, code: code, deviceName: deviceName)
            )
        }
    }

    /// 游客升级为正式账号(userId 与数据不变);邮箱被占用时抛 `AUTH_EMAIL_TAKEN`。
    @discardableResult
    public func upgrade(email: String, password: String) async throws -> OrdoSessionRecord {
        guard let current = session else {
            throw OrdoAPIError(code: .authRequired, message: "当前没有游客会话")
        }
        isBusy = true
        defer { isBusy = false }
        let response = try await authAPI.upgrade(
            accessToken: current.accessToken,
            OrdoUpgradeRequest(email: email, password: password)
        )
        let upgraded = OrdoSessionRecord(
            userId: response.user.id,
            email: response.user.email,
            isGuest: response.user.isGuest,
            accessToken: current.accessToken,
            refreshToken: current.refreshToken,
            expiresAt: current.expiresAt
        )
        await sessionStore.save(upgraded)
        session = upgraded
        return upgraded
    }

    // MARK: 登出

    /// 契约 §7.4 + §7.6.3:先尽力通知服务端,然后**只清会话**,本地数据目录原样保留。
    public func signOut() async {
        if let current = session {
            try? await authAPI.logout(refreshToken: current.refreshToken)
        }
        await sessionStore.clear()
        session = nil
    }

    /// 令牌已被服务端判定失效(401 且 refresh 也失败)时的本地清理。
    /// 只清会话,**不删**该 userId 的数据目录(契约 §7.6.3);
    /// 登录页会通过 `lastError` 告知用户为什么回到了这里。
    public func invalidateSession() async {
        lastError = "登录已过期,请重新登录"
        await sessionStore.clear()
        session = nil
    }

    // MARK: 令牌

    public func accessToken() async -> String? {
        await tokenStore.load()?.accessToken
    }

    // MARK: 内部

    private func authenticate(
        _ operation: (String) async throws -> OrdoAuthSession
    ) async throws -> OrdoSessionRecord {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            let deviceName = await tokenStore.deviceName()
            let response = try await operation(deviceName)
            let record = OrdoSessionRecord(session: response, nowMillis: clock.nowMillis())
            await sessionStore.save(record)
            session = record
            return record
        } catch {
            lastError = Self.hint(for: error)
            throw error
        }
    }

    private func performRefresh(_ current: OrdoSessionRecord) async throws -> OrdoSessionRecord {
        let response = try await authAPI.refresh(refreshToken: current.refreshToken)
        let refreshed = OrdoSessionRecord(session: response, nowMillis: clock.nowMillis())
        await sessionStore.save(refreshed)
        session = refreshed
        return refreshed
    }

    /// 把错误翻译成登录页可读的中文(错误不靠颜色单独表达,规范 §5.1 硬约束)。
    ///
    /// 优先看 `error.details.reason`(契约 §7.6.5 与 §7.6.2 的 `not_guest` 同一手法):
    /// 同一个 `code`(如 `AUTH_INVALID_CREDENTIALS`)在验证码模式下要给出比「邮箱或密码不正确」
    /// 精确得多的提示,规范 §5.1.1 已冻结这四条文案。
    public nonisolated static func hint(for error: Error) -> String {
        if let api = error as? OrdoAPIError {
            if let mapped = codeHint(forReason: api.details?["reason"]?.stringValue) {
                return mapped
            }
            switch api.code {
            case .authInvalidCredentials: return "邮箱或密码不正确"
            case .authEmailTaken: return "该邮箱已被注册"
            case .validationFailed: return "请填写有效的邮箱,口令至少 8 位"
            case .transport: return "网络不可用,请检查网络后重试"
            case .rateLimited: return "操作过于频繁,请稍后再试"
            default: return api.localizedHint
            }
        }
        return error.localizedDescription
    }

    /// 契约 §7.6.5 / UI 规范 §5.1.1:`error.details.reason` → 中文文案。
    ///
    /// 未知 reason 一律返回 `nil`,由调用方回退到按 `code` 的通用提示(前向兼容)。
    public nonisolated static func codeHint(forReason reason: String?) -> String? {
        guard let reason else { return nil }
        switch reason {
        case "code_invalid": return "验证码不正确,请检查后重试"
        case "code_expired": return "验证码已过期,请重新获取"
        case "code_attempts_exceeded": return "尝试次数过多,请重新获取验证码"
        case "code_throttled": return "发送过于频繁,请稍后再试"
        // 契约 §7.6.5 的发信失败(500 INTERNAL / mail_failed)
        case "mail_failed": return "验证码发送失败,请稍后再试"
        default: return nil
        }
    }

    // MARK: 重发倒计时秒数(契约 §7.6.5)

    /// 从限流错误里取重发秒数(契约 §7.6.5)。
    ///
    /// · **错误体里的字段名是 `error.details.retryAfterSec`**(整数秒),
    ///   与成功体顶层的 `retryAfter` 刻意不同,不要混用;
    /// · 该字段缺失或非正数 → 回落到 `OrdoEmailCodePolicy.defaultRetryAfterSeconds`(60s);
    /// · 超过 `OrdoEmailCodePolicy.maximumRetryAfterSeconds` → 夹取到上限;
    /// · **不是限流错误**(网络失败、参数校验等)→ 返回 `nil`,
    ///   调用方保持既有倒计时,符合规范 §5.1.1「失败可立即重发,除非服务端给了新的 retryAfter」。
    public nonisolated static func retryAfterSeconds(from error: Error) -> Int64? {
        guard let api = error as? OrdoAPIError else { return nil }
        let reason = api.details?["reason"]?.stringValue
        let isThrottled = api.code == .rateLimited || reason == "code_throttled"
        guard isThrottled else { return nil }
        let fallback = OrdoEmailCodePolicy.defaultRetryAfterSeconds
        let raw = api.details?["retryAfterSec"]?.intValue ?? fallback
        return min(raw > 0 ? raw : fallback, OrdoEmailCodePolicy.maximumRetryAfterSeconds)
    }
}
