//
//  RefreshControlModel.swift
//  Ordo
//
//  UI 规范 §5.3「刷新控件」的**纯状态机**(不 import SwiftUI,便于 XCTest 断言时序):
//
//  | 阶段   | 表现 |
//  |---|---|
//  | 同步中 | 图标连续旋转(每圈 900ms,linear,持续到结束)+ 文字「同步中…」 |
//  | 成功   | 图标停转并短暂转 `success` 色(320ms)+ 文字「已同步」,1.4s 后回到常态 |
//  | 失败   | 图标转 `danger` 色 + 文字「同步失败,点击重试」(常驻,直到重试) |
//
//  · 同步进行中按钮禁用;结束后 1.4s 内保持禁用(防抖)。
//  时间通过注入的 `OrdoClock` 取得,因此测试可以精确推进时间断言防抖与归位。
//

import Foundation
import Observation

// MARK: - 阶段

public enum OrdoRefreshPhase: Equatable, Sendable {
    /// 常态(图标不转)。
    case idle
    /// 同步中(图标连续旋转)。
    case syncing
    /// 刚成功:图标短暂转 success 色,1.4s 后回到 `idle`。
    case success
    /// 失败:常驻展示,直到用户重试。
    case failed(String)
}

/// 一次刷新的结果(由同步状态映射而来)。
public enum OrdoRefreshOutcome: Equatable, Sendable {
    case synced
    case failed(String)

    /// 把同步协调器的状态映射为刷新结果(失败原因保留,便于无障碍朗读)。
    ///
    /// 标注 `@MainActor`:`SyncCoordinator` 是主执行器隔离的类型,调用点(视图/测试)都在主执行器上。
    @MainActor
    public static func from(status: SyncCoordinator.Status?) -> OrdoRefreshOutcome {
        switch status {
        case .idle:
            return .synced
        case .offline:
            return .failed("网络不可用")
        case .signedOut:
            return .failed("未登录")
        case .failed(let message):
            return .failed(message)
        case .syncing:
            // 仍在同步中:按成功处理,随后由状态变化再次驱动。
            return .synced
        case .none:
            return .failed("同步未启用")
        }
    }
}

// MARK: - 状态机

@MainActor
@Observable
public final class OrdoRefreshControl {

    public private(set) var phase: OrdoRefreshPhase = .idle
    /// 最近一次失败的真实原因(界面文案固定为「同步失败,点击重试」,原因进无障碍标签)。
    public private(set) var lastFailureReason: String?

    private let clock: OrdoClock
    /// 防抖:该时刻之前不可再次触发。
    private var disableUntilMillis: Int64 = 0
    /// 成功态归位时刻。
    private var successUntilMillis: Int64 = 0

    public init(clock: OrdoClock = OrdoSystemClock()) {
        self.clock = clock
    }

    // MARK: 展示

    /// 状态文字(规范 §5.3 的三种文案)。
    public var label: String {
        switch phase {
        case .idle, .success: return "已同步"
        case .syncing: return "同步中…"
        case .failed: return "同步失败,点击重试"
        }
    }

    /// 图标是否连续旋转。
    public var isSpinning: Bool { phase == .syncing }

    /// 图标颜色语义(view 层据此选色,模型不认识 Color)。
    public enum IconTint: Equatable, Sendable {
        case normal
        case active
        case success
        case danger
    }

    public var iconTint: IconTint {
        switch phase {
        case .idle: return .normal
        case .syncing: return .active
        case .success: return .success
        case .failed: return .danger
        }
    }

    /// 无障碍标签:失败时把真实原因读出来(错误不靠颜色单独表达)。
    public var accessibilityLabel: String {
        switch phase {
        case .failed(let reason): return "同步失败:\(reason),点击重试"
        case .syncing: return "正在同步"
        case .success, .idle: return "同步状态:\(label)"
        }
    }

    // MARK: 触发

    /// 是否可触发(同步中或防抖窗口内为 false)。
    public func canTrigger() -> Bool {
        guard phase != .syncing else { return false }
        return clock.nowMillis() >= disableUntilMillis
    }

    /// 开始一次刷新;返回 false 表示被防抖/进行中挡下,调用方不应发起同步。
    @discardableResult
    public func begin() -> Bool {
        guard canTrigger() else { return false }
        phase = .syncing
        lastFailureReason = nil
        return true
    }

    /// 外部触发的同步(前台定时 / 网络恢复 / 回到前台 / 实时事件)开始:无条件进入同步中,
    /// 让用户对**任何**同步都有可见反馈(规范 §5.3 的意图);不受防抖限制。
    public func markSyncing() {
        phase = .syncing
        lastFailureReason = nil
    }

    /// 结束一次刷新。
    public func finish(_ outcome: OrdoRefreshOutcome) {
        let now = clock.nowMillis()
        switch outcome {
        case .synced:
            phase = .success
            successUntilMillis = now + Int64(OrdoMotion.Refresh.resetDelay * 1000)
        case .failed(let reason):
            phase = .failed(reason)
            lastFailureReason = reason
        }
        // 规范 §5.3:结束后 1.4s 内保持禁用(防抖)。
        disableUntilMillis = now + Int64(OrdoMotion.Refresh.debounce * 1000)
    }

    /// 成功态的自动归位(规范 §5.3:1.4s 后回到常态)。
    /// 由视图的定时任务调用;失败态**不**归位(常驻直到重试)。
    public func settle() {
        guard case .success = phase else { return }
        guard clock.nowMillis() >= successUntilMillis else { return }
        phase = .idle
    }

    /// 会话被清除(退出登录)时复位,避免残留「同步失败」文案。
    public func reset() {
        phase = .idle
        lastFailureReason = nil
        disableUntilMillis = 0
        successUntilMillis = 0
    }
}
