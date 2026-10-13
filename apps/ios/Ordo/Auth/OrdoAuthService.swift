//
//  OrdoAuthService.swift
//  Ordo
//
//  **静默匿名会话**(v1.3:产品决定「不再需要登录」)。
//
//  · 没有登录界面、没有门禁:App 启动后**任何路径都直接进主界面**;
//  · 会话只有一种来源:后台 `POST /v1/auth/guest` 建匿名账号(契约 §7.6.2 的 guest,用户无感);
//  · 启动:读会话 → 有 userId 直接用(令牌为空也行);accessToken 过期先 refresh;
//    网络不可达 → 照常进主界面离线可用(后台退避重试);服务端明确否认或根本没有会话
//    → 静默重建匿名会话;
//  · 会话的 `userId` 是**本机稳定标识**(见 `OrdoLocalAccount`),服务端账号只提供令牌 ——
//    这样「离线首启 → 联网认领」与「401 重建匿名会话」都不会换本地目录、不会丢数据(不做迁移)。
//
//  本类只依赖协议(`OrdoSessionStoring` / `OrdoAccountTokenStore` / `OrdoAuthAPI`),
//  因此可以在 XCTest 里用桩实现驱动全部分支(见 `OrdoTests/SessionAndSilentAuthTests.swift`)。
//

import Foundation
import Observation

@MainActor
@Observable
public final class OrdoAuthService {

    // MARK: 状态

    /// 当前会话(令牌的唯一宿主)。`nil` 只会出现在「还没来得及建会话」的启动窗口里。
    public private(set) var session: OrdoSessionRecord?

    // MARK: 依赖

    public let sessionStore: OrdoSessionStoring
    public let tokenStore: OrdoAccountTokenStore
    public let authAPI: OrdoAuthAPI
    /// 供同步用的 HTTP 客户端复用同一个刷新器(契约 §7.4:401 → refresh → 重放一次)。
    public let tokenRefresher: OrdoTokenRefresher?
    /// 本机账号标识:决定本地数据目录,跨启动稳定(见 `OrdoLocalAccount`)。
    public let localAccountId: String
    private let clock: OrdoClock

    public init(
        sessionStore: OrdoSessionStoring,
        tokenStore: OrdoAccountTokenStore,
        authAPI: OrdoAuthAPI,
        localAccountId: String = OrdoLocalAccount.generate(),
        clock: OrdoClock = OrdoSystemClock()
    ) {
        self.sessionStore = sessionStore
        self.tokenStore = tokenStore
        self.authAPI = authAPI
        self.localAccountId = localAccountId
        self.tokenRefresher = authAPI as? OrdoTokenRefresher
        self.clock = clock
    }

    /// 应用级装配:`Application Support/Ordo/session.json` + URLSession 网络层。
    ///
    /// 服务端地址走**隐藏覆盖**(`OrdoAPIEnvironment.resolved()`:UserDefaults 的
    /// `ordo.apiBaseURL`,没有配置就是本机开发地址)。
    public static func makeAppLevel(
        apiBaseURL: URL = OrdoAPIEnvironment.resolved().baseURL
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
        return OrdoAuthService(
            sessionStore: sessionStore,
            tokenStore: tokenStore,
            authAPI: authAPI,
            localAccountId: OrdoLocalAccount.resolve(in: kv)
        )
    }

    // MARK: 启动(读会话 → 直接用 / 刷新 / 静默建匿名)

    /// 读会话并决定去向。**任何分支都不会出现登录界面。**
    ///
    /// | 本地状态 | 结果 |
    /// |---|---|
    /// | 有会话、未过期 | `.resume`(直接进主界面) |
    /// | 有会话、已过期 | 先 refresh;成功 → `.resume` |
    /// | refresh **网络失败** | `.resume`(离线可用,联网后再刷新) |
    /// | refresh **被服务端否认** | 清掉死会话 → `.createAnonymous` |
    /// | 无会话 / 无 userId | `.createAnonymous` |
    ///
    /// 只有「服务端明确否认令牌(401/403)」才算会话失效;网络类错误一律保留会话 ——
    /// 这正是「断网时不会把用户挡在门外」的实现方式。
    public func restore() async -> OrdoStartupPlan {
        let stored = await sessionStore.load()
        switch OrdoStartupPlanner.plan(session: stored, nowMillis: clock.nowMillis()) {
        case .createAnonymous:
            session = stored
            return .createAnonymous

        case .resume(let value):
            session = value
            return .resume(value)

        case .refresh(let expired):
            do {
                let refreshed = try await performRefresh(expired)
                session = refreshed
                return .resume(refreshed)
            } catch {
                let rejected = Self.isCredentialsRejected(error)
                if rejected {
                    await sessionStore.clear()
                    session = nil
                } else {
                    // 网络不可达:会话仍在,继续离线用。
                    session = expired
                }
                return OrdoStartupPlanner.planAfterRefreshFailure(
                    session: expired,
                    serverRejected: rejected
                )
            }
        }
    }

    /// 启动后的静默 refresh(有且未过期时后台跑一次)。
    ///
    /// 失败不打扰任何人:会话仍然可用,下一次 401 会再走一遍 refresh 或重建匿名会话。
    public func refreshInBackground() async {
        guard let current = session, current.hasCloudTokens else { return }
        _ = try? await performRefresh(current)
    }

    // MARK: 静默匿名会话

    /// **静默**(重)建匿名会话:调用 `POST /v1/auth/guest` 并落盘。
    ///
    /// `userId` 沿用本机既有值(老会话的 userId,或首次启动时的本机账号标识),因此:
    /// · 首次启动 → 目录 = 本机账号标识;
    /// · 401 之后重建 → **目录不变**,本地数据会在随后的同步里推到新的匿名账号上;
    /// · 离线首启后联网 → 同样不换目录。
    ///
    /// 失败(网络不可达 / 服务端 5xx)时**抛错但不改本地状态**:调用方据此进入离线模式并退避重试。
    @discardableResult
    public func startAnonymousSession() async throws -> OrdoSessionRecord {
        let userId = session?.userId ?? localAccountId
        let deviceName = await tokenStore.deviceName()
        let response = try await authAPI.guest(OrdoGuestAuthRequest(deviceName: deviceName))
        let record = OrdoSessionRecord(
            session: response,
            nowMillis: clock.nowMillis(),
            userId: userId
        )
        await sessionStore.save(record)
        session = record
        return record
    }

    /// 离线占位会话:还没有云端令牌,但需要立刻进主界面(「网络不可达也照常进主界面」)。
    ///
    /// 它会**落盘**,这样即使连续多次离线启动,本地目录也始终是同一个。
    @discardableResult
    public func startLocalOnlySession() async -> OrdoSessionRecord {
        if let existing = session, !existing.userId.isEmpty {
            return existing
        }
        let record = OrdoSessionRecord.localOnly(userId: localAccountId)
        await sessionStore.save(record)
        session = record
        return record
    }

    // MARK: 内部

    private func performRefresh(_ current: OrdoSessionRecord) async throws -> OrdoSessionRecord {
        let response = try await authAPI.refresh(refreshToken: current.refreshToken)
        let refreshed = OrdoSessionRecord(
            session: response,
            nowMillis: clock.nowMillis(),
            userId: current.userId
        )
        await sessionStore.save(refreshed)
        session = refreshed
        return refreshed
    }

    /// 服务端是否**明确否认**了令牌(而不是网络不可达 / 服务端故障)。
    ///
    /// 只有明确否认才意味着会话真的没用了、必须重建匿名会话;
    /// 网络类错误(transport)、5xx、解码失败一律返回 `false`,由调用方保留会话继续离线可用。
    public nonisolated static func isCredentialsRejected(_ error: Error) -> Bool {
        guard let api = error as? OrdoAPIError else { return false }
        switch api.code {
        case .authRequired, .authInvalidCredentials, .authTokenExpired:
            return true
        default:
            // 错误体缺失或换了 code 时,按 HTTP 状态兜底。
            return api.httpStatus == 401 || api.httpStatus == 403
        }
    }
}
