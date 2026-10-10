//
//  AuthApi.swift
//  Ordo
//
//  契约 §7.4 鉴权接口:`/v1/auth/register|login|refresh|logout`。
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

    // MARK: 注册 / 登录

    public func register(email: String, password: String, deviceName: String, platform: String) async throws -> OrdoAuthSession {
        try await authenticate(
            path: "/v1/auth/register",
            email: email,
            password: password,
            deviceName: deviceName,
            platform: platform
        )
    }

    public func login(email: String, password: String, deviceName: String, platform: String) async throws -> OrdoAuthSession {
        try await authenticate(
            path: "/v1/auth/login",
            email: email,
            password: password,
            deviceName: deviceName,
            platform: platform
        )
    }

    private func authenticate(
        path: String,
        email: String,
        password: String,
        deviceName: String,
        platform: String
    ) async throws -> OrdoAuthSession {
        let body = try OrdoJSON.encode(RegisterRequest(
            email: email,
            password: password,
            deviceName: deviceName,
            platform: platform
        ))
        // 契约 §7.4:/auth/* 不需要 Authorization。
        return try await client.send(
            OrdoEndpoint(method: "POST", path: path, body: body, authorized: false),
            as: OrdoAuthSession.self
        )
    }

    // MARK: 游客登录 / 升级(契约 §7.6.2)

    /// 游客登录:服务端创建匿名账号并签发**正常令牌**(游客不是离线模式,数据同样入库、同样多端同步)。
    public func guest(_ request: OrdoGuestAuthRequest) async throws -> OrdoAuthSession {
        let body = try OrdoJSON.encode(request)
        return try await client.send(
            OrdoEndpoint(method: "POST", path: "/v1/auth/guest", body: body, authorized: false),
            as: OrdoAuthSession.self
        )
    }

    /// 把游客账号升级为正式账号:userId 与数据都不变,只翻转 `isGuest`。
    /// 邮箱已被占用时服务端返回 `AUTH_EMAIL_TAKEN`。
    public func upgrade(accessToken: String, _ request: OrdoUpgradeRequest) async throws -> OrdoUpgradeResponse {
        let body = try OrdoJSON.encode(request)
        return try await client.send(
            OrdoEndpoint(method: "POST", path: "/v1/auth/upgrade", body: body, authorized: true, bearerToken: accessToken),
            as: OrdoUpgradeResponse.self
        )
    }

    // MARK: 刷新 / 登出

    public func refresh(refreshToken: String) async throws -> OrdoAuthSession {
        let body = try OrdoJSON.encode(RefreshRequest(refreshToken: refreshToken))
        return try await client.send(
            OrdoEndpoint(method: "POST", path: "/v1/auth/refresh", body: body, authorized: false),
            as: OrdoAuthSession.self
        )
    }

    public func logout(refreshToken: String) async throws {
        let body = try OrdoJSON.encode(RefreshRequest(refreshToken: refreshToken))
        try await client.sendVoid(
            OrdoEndpoint(method: "POST", path: "/v1/auth/logout", body: body, authorized: false)
        )
    }

    // MARK: OrdoTokenRefresher

    /// 旧 refresh 轮换失效:刷新成功后返回新的 access + refresh。
    public func refreshTokens(using refreshToken: String) async throws -> OrdoTokens {
        let session = try await refresh(refreshToken: refreshToken)
        return OrdoTokens(session: session)
    }

    // MARK: 请求体

    private struct RegisterRequest: Codable, Sendable {
        var email: String
        var password: String
        var deviceName: String
        var platform: String
    }

    private struct RefreshRequest: Codable, Sendable {
        var refreshToken: String
    }
}
