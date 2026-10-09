//
//  SyncCoordinator.swift
//  Ordo
//
//  契约 §7.1「本地优先」的调度者:
//  - 前台每 30s 触发一次增量同步;
//  - 场景切换(进入前台)立即触发;
//  - `NWPathMonitor` 检测到网络恢复立即触发;
//  - 收到实时通道 `ops` 立即应用;收到 `reminder`(Fastlane)立即交由提醒调度器处理。
//
//  同步流程(全部通过 KMP 引擎的同步 API,不在 Swift 侧重算状态):
//    ① `engine.pendingOps()` 取待上传 ops
//    ② `SyncApi.push`(自动分片 ≤500 ops/次)
//    ③ `engine.ackOps(accepted)` 清理 outbox;`engine.applyRemote(响应捎带的 ops)`
//    ④ 循环 `SyncApi.pull` 直到 `hasMore == false`
//    ⑤ `engine.lastServerSeq()` / `setLastServerSeq` 由核心维护(kv `ordo.lastServerSeq`)
//
//  合并裁决(LWW / 完成不可回滚 / 标签并集 / 清单合并 / 墓碑)全部在 KMP `applyRemote` 内完成。
//

import Foundation
import Network
import Observation

@MainActor
@Observable
public final class SyncCoordinator {

    // MARK: 状态

    public enum Status: Equatable, Sendable {
        case idle
        case syncing
        case offline
        case signedOut
        case failed(String)

        public var label: String {
            switch self {
            case .idle: return "已同步"
            case .syncing: return "同步中"
            case .offline: return "离线"
            case .signedOut: return "未登录"
            case .failed(let message): return "同步失败:\(message)"
            }
        }

        public var isProblem: Bool {
            switch self {
            case .failed, .offline: return true
            default: return false
            }
        }
    }

    public private(set) var status: Status = .idle
    public private(set) var lastSyncedAt: Int64?
    public private(set) var pendingCount: Int = 0
    public private(set) var lastError: String?
    /// 最近一次被服务端拒绝的 op(契约 §7.3 的 stale / completion_immutable 等)。
    public private(set) var lastRejections: [OrdoRejectedOp] = []

    /// 前台同步间隔(契约要求 30s)。
    public var foregroundInterval: TimeInterval = 30

    // MARK: 依赖

    private let engine: OrdoEngineProtocol
    private let storage: OrdoStorageProtocol
    private let tokenStore: OrdoStorageTokenStore
    private let syncAPI: OrdoSyncAPI?
    private let realtime: OrdoRealtimeClient?
    private let clock: OrdoClock
    private let onReminder: (@Sendable (String, String, String) -> Void)?

    private var timerTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var isNetworkAvailable = true
    private var isSyncing = false

    public init(
        engine: OrdoEngineProtocol,
        storage: OrdoStorageProtocol,
        tokenStore: OrdoStorageTokenStore,
        syncAPI: OrdoSyncAPI?,
        realtime: OrdoRealtimeClient?,
        clock: OrdoClock = OrdoSystemClock(),
        onReminder: (@Sendable (String, String, String) -> Void)? = nil
    ) {
        self.engine = engine
        self.storage = storage
        self.tokenStore = tokenStore
        self.syncAPI = syncAPI
        self.realtime = realtime
        self.clock = clock
        self.onReminder = onReminder
    }

    // MARK: 生命周期

    public func start() async {
        pendingCount = engine.pendingOpCount()
        await refreshSignInState()
        startPathMonitor()
        startForegroundTimer()
        if realtime != nil {
            await realtime?.setEventHandler { [weak self] event in
                Task { @MainActor in self?.handle(realtimeEvent: event) }
            }
            await realtime?.start()
        }
        await syncNow(reason: "启动")
    }

    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        Task { await realtime?.stop(reason: "应用进入后台") }
    }

    /// 由 `OrdoShellView` 在 `scenePhase` 变化时调用。
    public func handleScenePhaseChange(isActive: Bool) async {
        if isActive {
            await realtime?.start()
            await syncNow(reason: "回到前台")
        } else {
            await realtime?.stop(reason: "应用进入后台")
        }
    }

    // MARK: 触发源

    private func startForegroundTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.foregroundInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.syncNow(reason: "前台定时")
            }
        }
    }

    private func startPathMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasUnavailable = !self.isNetworkAvailable
                self.isNetworkAvailable = path.status == .satisfied
                if self.isNetworkAvailable {
                    if wasUnavailable {
                        self.status = .idle
                        await self.syncNow(reason: "网络恢复")
                    }
                } else {
                    self.status = .offline
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.ordo.network.monitor"))
        pathMonitor = monitor
    }

    // MARK: 实时事件

    private func handle(realtimeEvent: OrdoRealtimeEvent) {
        switch realtimeEvent {
        case .connected:
            status = .idle
        case .ops(_, let ops):
            engine.applyRemote(ops)
            pendingCount = engine.pendingOpCount()
            onSnapshotRequiresReschedule?()
        case .reminder(let todoId, let title, let at):
            // Fastlane:立即交给提醒调度器(不走批量合并)。
            onReminder?(todoId, title, at)
        case .disconnected:
            if isNetworkAvailable {
                status = .offline
            }
        }
    }

    /// 远端数据变化后,提醒需要重新排期(由 AppEnvironment 注入实现)。
    public var onSnapshotRequiresReschedule: (@MainActor () -> Void)?

    // MARK: 同步主流程

    public func syncNow(reason: String) async {
        guard let syncAPI else {
            status = await tokenStore.isSignedIn() ? .idle : .signedOut
            return
        }
        guard isNetworkAvailable else {
            status = .offline
            return
        }
        guard !isSyncing else { return }
        guard await tokenStore.isSignedIn() else {
            status = .signedOut
            return
        }

        isSyncing = true
        status = .syncing
        defer { isSyncing = false }

        do {
            let ops = engine.pendingOps()
            pendingCount = ops.count

            if !ops.isEmpty {
                let response = try await syncAPI.push(
                    OrdoPushRequest(deviceId: engine.deviceId, sinceSeq: engine.lastServerSeq(), ops: ops)
                )
                // ③ 已接受的 op 从 outbox 移除(核心同时清理内存与持久层)
                if !response.acceptedOpIds.isEmpty {
                    engine.ackOps(response.acceptedOpIds)
                }
                lastRejections = response.rejected
                // 捎带拉取的远端 ops 立即合并
                if !response.ops.isEmpty {
                    engine.applyRemote(response.ops)
                }
                pendingCount = engine.pendingOpCount()
            }

            try await pullAll(using: syncAPI)

            lastSyncedAt = clock.nowMillis()
            lastError = nil
            status = .idle
            onSnapshotRequiresReschedule?()
            await pruneTombstones()
        } catch let error as OrdoAPIError {
            lastError = error.localizedHint
            switch error.code {
            case .transport:
                status = .offline
            case .authRequired, .authInvalidCredentials:
                status = .signedOut
            default:
                status = .failed(error.localizedHint)
            }
        } catch {
            lastError = error.localizedDescription
            status = .failed(error.localizedDescription)
        }
    }

    /// 循环拉取直到 `hasMore == false`(契约 §7.4 `limit ≤ 1000`)。
    private func pullAll(using syncAPI: OrdoSyncAPI) async throws {
        var hasMore = true
        var guardCounter = 0
        while hasMore && guardCounter < 50 {
            guardCounter += 1
            let response = try await syncAPI.pull(sinceSeq: engine.lastServerSeq(), limit: 500)
            if !response.ops.isEmpty {
                engine.applyRemote(response.ops)
            }
            hasMore = response.hasMore
        }
    }

    /// 墓碑保留 30 天(契约 §7.3.5)。
    private func pruneTombstones() async {
        let cutoff = clock.nowMillis() - Int64(30 * 24 * 60 * 60 * 1000)
        try? await storage.tombstonePrune(before: cutoff)
    }

    private func refreshSignInState() async {
        if !(await tokenStore.isSignedIn()) {
            status = .signedOut
        } else if !isNetworkAvailable {
            status = .offline
        }
    }

    // MARK: 登录 / 登出

    public func handleSignedIn(_ session: OrdoAuthSession) async {
        await tokenStore.save(session: session)
        status = .idle
        await syncNow(reason: "登录成功")
    }

    /// 契约 §7.4:refresh 也失败 → 转登录态但**保留本地数据**。
    public func handleSignedOut() async {
        await tokenStore.save(nil)
        status = .signedOut
        await realtime?.stop(reason: "已登出")
    }

    // MARK: 远端全量快照

    /// 登录后拉一次全量快照:服务端为空则把本地推上去,否则用远端快照替换本地(保留 outbox)。
    public func bootstrapFromRemoteIfEmpty() async {
        guard let syncAPI else { return }
        guard await tokenStore.isSignedIn() else { return }
        do {
            let remote = try await syncAPI.snapshot()
            let merged = remote.merged()
            if merged.todos.isEmpty && merged.projects.isEmpty && merged.areas.isEmpty {
                // 服务端为空:把本地数据推上去(首次登录的新账号)。
                await syncNow(reason: "首次上传本地数据")
            } else {
                engine.replaceWithRemote(merged)
                onSnapshotRequiresReschedule?()
            }
        } catch let error as OrdoAPIError {
            lastError = error.localizedHint
        } catch {
            lastError = error.localizedDescription
        }
    }
}
