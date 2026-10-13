//
//  StatusBarView.swift
//  Ordo
//
//  底部状态栏(设计规范 §3 + §5.3):共 N 项 · 已完成 M 项 …… [刷新控件]。
//
//  §5.3「刷新控件(必须有可见效果)」——原实现右侧只是一个可点文字,点了只有文字变化;
//  现在改为 **28dp 圆形图标按钮(`arrow.triangle.2.circlepath`)+ 状态文字**:
//    · 点击(或 ⌘R / Ctrl+R)→ 图标**连续旋转**(每圈 900ms,linear,持续到同步结束)+「同步中…」;
//    · 成功 → 图标停转并短暂转 `success` 色(320ms)+「已同步」,1.4s 后回到常态;
//    · 失败 → 图标转 `danger` 色 +「同步失败,点击重试」(常驻,直到重试);
//    · 同步进行中按钮禁用,结束后 1.4s 内保持禁用(防抖)。
//  状态机在 `RefreshControlModel.swift`(可单测),本文件只做渲染与把事件接上。
//

import SwiftUI

public struct StatusBarView: View {

    private let shell: ShellViewModel
    private let environment: AppEnvironment

    public init(shell: ShellViewModel, environment: AppEnvironment) {
        self.shell = shell
        self.environment = environment
    }

    public var body: some View {
        HStack(spacing: OrdoSpacing.s) {
            Text(shell.statusSummary)
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.textSecondary)
                .monospacedDigit()

            Spacer(minLength: OrdoSpacing.s)

            // 通知权限被拒 / App 前台时的应用内兜底角标(见 Notifications/ReminderScheduler)
            if shell.reminderBadgeCount > 0 {
                HStack(spacing: OrdoSpacing.xs) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 11, weight: .medium))
                    Text("\(shell.reminderBadgeCount)")
                        .font(OrdoFont.captionEmphasis)
                        .monospacedDigit()
                }
                .foregroundStyle(OrdoColor.accent)
                .accessibilityLabel("有 \(shell.reminderBadgeCount) 条应用内提醒")
            }

            if let notice = environment.storageNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(OrdoFont.caption)
                    .foregroundStyle(OrdoColor.danger)
                    .lineLimit(1)
            } else if let pending = environment.sync?.pendingCount, pending > 0 {
                Text("待同步 \(pending) 条")
                    .font(OrdoFont.caption)
                    .foregroundStyle(OrdoColor.textSecondary)
                    .monospacedDigit()
            }

            OrdoRefreshControlView(shell: shell, environment: environment)
        }
        .padding(.horizontal, OrdoSpacing.l)
        .frame(height: OrdoLayout.statusBarHeight)
        .background(OrdoColor.sidebar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OrdoColor.hairline)
                .frame(height: 1)
        }
    }
}

// MARK: - 刷新控件(规范 §5.3)

/// 图标 + 文字的刷新控件;图标在同步期间连续旋转。
public struct OrdoRefreshControlView: View {

    private let shell: ShellViewModel
    private let environment: AppEnvironment

    @State private var control = OrdoRefreshControl()
    @State private var rotation: Double = 0
    /// 防抖窗口内(规范 §5.3:结束后 1.4s 内保持禁用),由下面的 `.task` 维护。
    @State private var isCoolingDown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(shell: ShellViewModel, environment: AppEnvironment) {
        self.shell = shell
        self.environment = environment
    }

    public var body: some View {
        HStack(spacing: OrdoSpacing.xs) {
            Button {
                trigger()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .rotationEffect(.degrees(rotation))
                    .frame(width: OrdoMotion.Refresh.iconSize, height: OrdoMotion.Refresh.iconSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(control.isSpinning || isCoolingDown)
            .opacity(control.isSpinning || isCoolingDown ? 0.55 : 1)
            .accessibilityLabel(control.accessibilityLabel)
            .accessibilityHint("立即同步一次")

            Text(control.label)
                .font(OrdoFont.caption)
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .animation(OrdoMotion.resolved(OrdoMotion.fastEase, reduceMotion: reduceMotion), value: control.phase)
        .onChange(of: control.isSpinning) { _, spinning in
            updateRotation(spinning: spinning)
        }
        .onChange(of: syncStatus) { _, status in
            mirror(status: status)
        }
        .onChange(of: shell.refreshRequestToken) { _, _ in
            // ⌘R / Ctrl+R(规范 §5.3 / §6)。
            trigger()
        }
        .task(id: control.phase) {
            await settleAfterPhaseChange()
        }
    }

    private var syncStatus: SyncCoordinator.Status? { environment.sync?.status }

    // MARK: 颜色

    private var iconColor: Color {
        switch control.iconTint {
        case .normal: return OrdoColor.textSecondary
        case .active: return OrdoColor.accent
        case .success: return OrdoColor.success
        case .danger: return OrdoColor.danger
        }
    }

    private var textColor: Color {
        switch control.iconTint {
        case .danger: return OrdoColor.danger
        case .normal, .active, .success: return OrdoColor.textSecondary
        }
    }

    // MARK: 行为

    /// 点击刷新:先占位(防止重复触发),再等同步真正结束并落到成功/失败态。
    private func trigger() {
        guard control.begin() else { return }
        Task { @MainActor in
            await environment.sync?.syncNow(reason: "手动刷新")
            // 状态变化可能已经把它收尾(见 mirror(status:)),这里只兜底「仍然在转」的情况。
            guard control.isSpinning else { return }
            control.finish(OrdoRefreshOutcome.from(status: environment.sync?.status))
        }
    }

    /// 后台同步(前台定时 / 网络恢复 / 回到前台 / 实时事件)同样要有可见反馈。
    private func mirror(status: SyncCoordinator.Status?) {
        guard let status else { return }
        switch status {
        case .syncing:
            if !control.isSpinning { control.markSyncing() }
        case .idle, .offline, .localOnly, .failed:
            if control.isSpinning { control.finish(OrdoRefreshOutcome.from(status: status)) }
        }
    }

    /// 阶段变化后的时序:成功态 1.4s 归位;成功/失败都要等防抖窗口过去才能再次点击(规范 §5.3)。
    private func settleAfterPhaseChange() async {
        switch control.phase {
        case .success:
            isCoolingDown = true
            try? await Task.sleep(nanoseconds: UInt64(OrdoMotion.Refresh.resetDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            control.settle()
            isCoolingDown = false
        case .failed:
            isCoolingDown = true
            try? await Task.sleep(nanoseconds: UInt64(OrdoMotion.Refresh.debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            isCoolingDown = false
        case .idle, .syncing:
            isCoolingDown = false
        }
    }

    /// 连续旋转:每圈 900ms linear,持续到同步结束(规范 §5.3)。
    private func updateRotation(spinning: Bool) {
        guard !reduceMotion else {
            rotation = 0
            return
        }
        if spinning {
            rotation = 0
            withAnimation(OrdoMotion.Refresh.spin) {
                rotation = 360
            }
        } else {
            rotation = 0
        }
    }
}
