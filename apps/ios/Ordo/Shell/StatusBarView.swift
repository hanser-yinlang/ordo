//
//  StatusBarView.swift
//  Ordo
//
//  底部状态栏(设计规范 §3):共 N 项 · 已完成 M 项 · 同步状态(已同步/同步中/离线)。
//  离线或存储降级时提供明确文案(规范 §9「离线态」)。
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

            Text("·")
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.textTertiary)

            syncIndicator

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
        }
        .padding(.horizontal, OrdoSpacing.l)
        .frame(height: OrdoLayout.statusBarHeight)
        .background(OrdoColor.sidebar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OrdoColor.hairline)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shell.statusSummary),\(shell.syncLabel)")
    }

    private var syncIndicator: some View {
        HStack(spacing: OrdoSpacing.xs) {
            Circle()
                .fill(syncColor)
                .frame(width: 6, height: 6)
            Text(shell.syncLabel)
                .font(OrdoFont.caption)
                .foregroundStyle(shell.syncIsProblem ? OrdoColor.danger : OrdoColor.textSecondary)
        }
        .accessibilityLabel("同步状态:\(shell.syncLabel)")
    }

    private var syncColor: Color {
        guard let status = environment.sync?.status else { return OrdoColor.textTertiary }
        switch status {
        case .idle: return OrdoColor.success
        case .syncing: return OrdoColor.accent
        case .offline, .signedOut: return OrdoColor.textTertiary
        case .failed: return OrdoColor.danger
        }
    }
}
