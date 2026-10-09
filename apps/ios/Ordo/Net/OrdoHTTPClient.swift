//
//  OrdoHTTPClient.swift
//  Ordo
//
//  契约 §7.4 的 HTTP 基础层:
//  - 统一请求头 `X-Ordo-Schema: 1` / `X-Ordo-Device` / `X-Ordo-Client: ios/1.0.0`;
//  - `Authorization: Bearer <accessToken>`(/auth/* 与 /health 除外);
//  - 401(`AUTH_TOKEN_EXPIRED`)自动 refresh 并**重放原请求一次**;refresh 也失败 → 转登录态但保留本地数据。
//  - 错误体 `{ "error": { code, message, details } }` 统一映射为 `OrdoAPIError`。
//

import Foundation

/// 服务端地址与客户端标识。
public struct OrdoAPIEnvironment: Sendable {
    public var baseURL: URL
    /// 契约 §7.4:`X-Ordo-Client: android/1.0.0` 对应 iOS 为 `ios/1.0.0`。
    public var clientHeader: String

    public init(baseURL: URL, clientHeader: String = "ios/1.0.0") {
        self.baseURL = baseURL
        self.clientHeader = clientHeader
    }

    public static let `default` = OrdoAPIEnvironment(baseURL: URL(string: "http://127.0.0.1:8787")!)
}

/// 令牌刷新能力(由鉴权 API 实现,注入到 HTTP 客户端以打破循环依赖)。
public protocol OrdoTokenRefresher: Sendable {
    func refreshTokens(using refreshToken: String) async throws -> OrdoTokens
}

/// 设备标识来源(同步请求头需要 deviceId)。
public protocol OrdoDeviceIdentifying: Sendable {
    func deviceId() async -> String
    func deviceName() async -> String
}

/// 一个 HTTP 端点描述。
public struct OrdoEndpoint: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var body: Data?
    public var authorized: Bool

    public init(method: String, path: String, query: [String: String] = [:], body: Data? = nil, authorized: Bool = true) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.authorized = authorized
    }

    public static func get(_ path: String, query: [String: String] = [:], authorized: Bool = true) -> OrdoEndpoint {
        OrdoEndpoint(method: "GET", path: path, query: query, authorized: authorized)
    }

    public static func post(_ path: String, body: Data? = nil, authorized: Bool = true) -> OrdoEndpoint {
        OrdoEndpoint(method: "POST", path: path, body: body, authorized: authorized)
    }
}

/// 线程安全的 HTTP 客户端(actor 串行化令牌刷新,避免并发刷新风暴)。
public actor OrdoHTTPClient {

    private let environment: OrdoAPIEnvironment
    private let session: URLSession
    private let tokenStore: OrdoTokenStore
    private let deviceIdentity: OrdoDeviceIdentifying?
    private var refresher: OrdoTokenRefresher?
    private var refreshTask: Task<OrdoTokens, Error>?

    public init(
        environment: OrdoAPIEnvironment = .default,
        session: URLSession = .shared,
        tokenStore: OrdoTokenStore,
        deviceIdentity: OrdoDeviceIdentifying? = nil,
        refresher: OrdoTokenRefresher? = nil
    ) {
        self.environment = environment
        self.session = session
        self.tokenStore = tokenStore
        self.deviceIdentity = deviceIdentity
        self.refresher = refresher
    }

    public func setRefresher(_ refresher: OrdoTokenRefresher?) {
        self.refresher = refresher
    }

    // MARK: 请求

    public func send<T: Decodable & Sendable>(_ endpoint: OrdoEndpoint, as type: T.Type) async throws -> T {
        let data = try await performWithAuth(endpoint, allowRefresh: true)
        if data.isEmpty, let empty = EmptyResponse() as? T {
            return empty
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OrdoAPIError.decoding("\(type) 解析失败:\(error.localizedDescription)")
        }
    }

    @discardableResult
    public func sendVoid(_ endpoint: OrdoEndpoint) async throws -> Int {
        let data = try await performWithAuth(endpoint, allowRefresh: true)
        return data.count
    }

    // MARK: 内部

    private func performWithAuth(_ endpoint: OrdoEndpoint, allowRefresh: Bool) async throws -> Data {
        if endpoint.authorized, let tokens = await tokenStore.load(), tokens.isExpired, allowRefresh {
            // 主动刷新,避免必然失败的 401 往返。
            _ = try? await refreshTokens()
        }
        do {
            return try await perform(endpoint)
        } catch let error as OrdoAPIError where error.requiresTokenRefresh && allowRefresh {
            _ = try await refreshTokens()
            // 契约 §7.4:自动 refresh 并重放原请求**一次**。
            return try await perform(endpoint)
        }
    }

    private func perform(_ endpoint: OrdoEndpoint) async throws -> Data {
        var components = URLComponents(url: environment.baseURL.appendingPathComponent(endpoint.path), resolvingAgainstBaseURL: false)
        if !endpoint.query.isEmpty {
            components?.queryItems = endpoint.query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw OrdoAPIError(code: .validationFailed, message: "非法请求地址:\(endpoint.path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(OrdoSchema.version)", forHTTPHeaderField: OrdoSchema.headerName)
        request.setValue(environment.clientHeader, forHTTPHeaderField: "X-Ordo-Client")
        if let deviceIdentity {
            request.setValue(await deviceIdentity.deviceId(), forHTTPHeaderField: "X-Ordo-Device")
        }
        if endpoint.authorized {
            guard let tokens = await tokenStore.load() else {
                throw OrdoAPIError(code: .authRequired, message: "本地没有访问令牌")
            }
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body = endpoint.body {
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OrdoAPIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OrdoAPIError.transport("响应不是 HTTP 响应")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw decodeError(data: data, status: http.statusCode)
        }
        return data
    }

    private func decodeError(data: Data, status: Int) -> OrdoAPIError {
        if let body = try? JSONDecoder().decode(OrdoAPIErrorBody.self, from: data) {
            let code = OrdoAPIErrorCode(rawValue: body.error.code) ?? .internal
            return OrdoAPIError(code: code, message: body.error.message, httpStatus: status, details: body.error.details)
        }
        let code: OrdoAPIErrorCode
        switch status {
        case 401: code = .authTokenExpired
        case 403: code = .authRequired
        case 404: code = .notFound
        case 429: code = .rateLimited
        case 400...499: code = .validationFailed
        default: code = .internal
        }
        return OrdoAPIError(code: code, message: "HTTP \(status)", httpStatus: status)
    }

    /// 刷新令牌。并发调用共享同一个刷新任务(refresh 轮换后旧的 refreshToken 立即失效)。
    @discardableResult
    private func refreshTokens() async throws -> OrdoTokens {
        if let existing = refreshTask {
            return try await existing.value
        }
        guard let refresher else {
            throw OrdoAPIError(code: .authRequired, message: "未配置令牌刷新器")
        }
        guard let current = await tokenStore.load() else {
            throw OrdoAPIError(code: .authRequired, message: "本地没有刷新令牌")
        }
        let task = Task<OrdoTokens, Error> { [tokenStore] in
            let tokens = try await refresher.refreshTokens(using: current.refreshToken)
            await tokenStore.save(tokens)
            return tokens
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}

/// 空响应占位(204/空体)。
public struct EmptyResponse: Codable, Sendable {
    public init() {}
}

/// 便捷 JSON 编码。
public enum OrdoJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
