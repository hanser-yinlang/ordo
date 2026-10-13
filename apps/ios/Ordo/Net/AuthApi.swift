//
//  AuthApi.swift
//  Ordo
//
//  契约 §7.6.2 的**匿名会话**传输层(v1.3:不再有登录界面)。
//
//  只保留两个端点:
//    · `POST /v1/auth/guest`   —— 静默建匿名账号(首次启动 / 令牌被服务端否认后重建);
//    · `POST /v1/auth/refresh` —— accessToken 过期时轮换令牌。
//  注册 / 口令登录 / 游客升级 / 邮箱验证码登录(v1.2~v1.3 早期)已随登录系统一并移除。
//
//  同时实现 `OrdoTokenRefresher`,供 `OrdoHTTPClient` 做 401 自动重放。
//

import Foundation

public actor URLSessionAuthApi: OrdoAuthAPI, OrdoTokenRefresher {

    private let client: OrdoHTTPClient
    private let platform: String

    public init(client: OrdoHTTPClient, platform: String = "ios/1.0.0") {
        self.client = client
        self.platform = platform
    }

    // MARK: 匿名(游客)会话

    /// 静默建匿名账号:服务端签发**正常令牌**(匿名不是离线模式,数据同样入库、同样多端同步)。
    public func guest(_ request: OrdoGuestAuthRequest) async throws -> OrdoAuthSession {
        let body = try OrdoJSON.encode(request)
        return try await client.send(
            OrdoEndpoint(method: "POST", path: "/v1/auth/guest", body: body, authorized: false),
            as: OrdoAuthSession.self
        )
    }

    // MARK: 刷新

    public func refresh(refreshToken: String) async throws -> OrdoAuthSession {
        let body = try OrdoJSON.encode(RefreshRequest(refreshToken: refreshToken))
        return try await client.send(
            OrdoEndpoint(method: "POST", path: "/v1/auth/refresh", body: body, authorized: false),
            as: OrdoAuthSession.self
        )
    }

    // MARK: OrdoTokenRefresher

    /// 旧 refresh 轮换失效:刷新成功后返回新的 access + refresh。
    public func refreshTokens(using refreshToken: String) async throws -> OrdoTokens {
        let session = try await refresh(refreshToken: refreshToken)
        return OrdoTokens(session: session)
    }

    // MARK: 请求体

    private struct RefreshRequest: Codable, Sendable {
        var refreshToken: String
    }
}
