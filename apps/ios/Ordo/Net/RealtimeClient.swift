//
//  RealtimeClient.swift
//  Ordo
//
//  契约 §7.5 实时通道:`URLSessionWebSocketTask` 连接 `/v1/ws?token=<accessToken>`。
//
//  职责:
//  - 连接后发送 `subscribe`(带 deviceId),接收 `hello`/`ops`/`reminder`/`ping`;
//  - `reminder` 为 Fastlane 消息,立刻上抛(Fastlane:不等待批量合并);
//  - 断线指数退避重连:1s → 2s → 4s … 上限 60s,附 ±20% 抖动;
//  - 收到 `ping` 回 `pong`;每 30s 主动发送 `ack`(最近 serverSeq)。
//

import Foundation

/// 实时通道事件(交给 `SyncCoordinator` / `ReminderScheduler` 处理)。
public enum OrdoRealtimeEvent: Sendable {
    case connected(serverSeq: Int64, serverTime: Int64)
    case ops(serverSeq: Int64, ops: [OrdoOp])
    case reminder(todoId: String, title: String, at: String)
    case disconnected(reason: String)
}

/// URLSessionWebSocketTask 客户端。
public actor OrdoRealtimeClient {

    public struct Configuration: Sendable {
        public var baseURL: URL
        public var deviceId: String
        public var initialBackoff: TimeInterval = 1
        public var maxBackoff: TimeInterval = 60
        public var heartbeatInterval: TimeInterval = 30

        public init(baseURL: URL, deviceId: String) {
            self.baseURL = baseURL
            self.deviceId = deviceId
        }
    }

    private let configuration: Configuration
    private let session: URLSession
    private let tokenProvider: @Sendable () async -> String?
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var attempt = 0
    private var lastServerSeq: Int64 = 0
    private var isStopped = false
    private var eventHandler: (@Sendable (OrdoRealtimeEvent) -> Void)?

    public init(
        configuration: Configuration,
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () async -> String?
    ) {
        self.configuration = configuration
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func setEventHandler(_ handler: @escaping @Sendable (OrdoRealtimeEvent) -> Void) {
        eventHandler = handler
    }

    // MARK: 生命周期

    public func start() {
        isStopped = false
        guard task == nil else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.connect()
        }
    }

    public func stop(reason: String = "客户端主动断开") {
        isStopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        emit(.disconnected(reason: reason))
    }

    /// 更新最近确认的服务端序号,供心跳 ack 与重连后的增量拉取使用。
    public func acknowledge(serverSeq: Int64) {
        lastServerSeq = max(lastServerSeq, serverSeq)
        send(.ack(serverSeq: lastServerSeq))
    }

    // MARK: 连接

    private func connect() async {
        guard !isStopped else { return }
        guard let token = await tokenProvider() else {
            emit(.disconnected(reason: "缺少访问令牌"))
            return
        }
        guard var components = URLComponents(url: configuration.baseURL.appendingPathComponent("/v1/ws"), resolvingAgainstBaseURL: false) else {
            emit(.disconnected(reason: "非法 WebSocket 地址"))
            return
        }
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            emit(.disconnected(reason: "非法 WebSocket 地址"))
            return
        }

        let socket = session.webSocketTask(with: url)
        task = socket
        socket.resume()
        send(.subscribe(deviceId: configuration.deviceId))
        startHeartbeat()
        receiveLoop = Task { [weak self] in
            await self?.receive(in: socket)
        }
    }

    private func receive(in socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let text: String
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(decoding: data, as: UTF8.self)
                @unknown default: continue
                }
                await handle(text: text)
            } catch {
                guard !Task.isCancelled, !isStopped else { return }
                emit(.disconnected(reason: error.localizedDescription))
                scheduleReconnect()
                return
            }
        }
    }

    private func handle(text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? OrdoJSONValue.decode(from: data) else { return }
        guard let message = try? OrdoSocketServerMessage.decode(from: json) else { return }

        switch message {
        case .hello(let serverSeq, let serverTime):
            attempt = 0
            lastServerSeq = max(lastServerSeq, serverSeq)
            emit(.connected(serverSeq: serverSeq, serverTime: serverTime))
        case .ops(let serverSeq, let ops):
            lastServerSeq = max(lastServerSeq, serverSeq)
            emit(.ops(serverSeq: serverSeq, ops: ops))
            send(.ack(serverSeq: lastServerSeq))
        case .reminder(let todoId, let title, let at):
            // Fastlane:立即上抛,由提醒调度器处理。
            emit(.reminder(todoId: todoId, title: title, at: at))
        case .ping:
            send(.pong)
        case .unknown:
            break
        }
    }

    // MARK: 发送

    private func send(_ message: OrdoSocketClientMessage) {
        guard let task, let text = try? message.encode() else { return }
        task.send(.string(text)) { _ in
            // 发送失败由 receive 循环的重连逻辑兜底,这里不重复处理。
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.configuration.heartbeatInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let client = self, await client.isActive else { return }
                await client.acknowledge(serverSeq: await client.currentServerSeq)
            }
        }
    }

    private var isActive: Bool { task != nil && !isStopped }

    private var currentServerSeq: Int64 { lastServerSeq }

    // MARK: 重连(指数退避 + 抖动)

    private func scheduleReconnect() {
        guard !isStopped else { return }
        receiveLoop?.cancel()
        receiveLoop = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil

        attempt += 1
        let base = min(configuration.maxBackoff, configuration.initialBackoff * pow(2, Double(attempt - 1)))
        let jitter = base * Double.random(in: -0.2...0.2)
        let delay = max(0.5, base + jitter)

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func emit(_ event: OrdoRealtimeEvent) {
        eventHandler?(event)
    }
}
