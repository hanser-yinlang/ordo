//
//  OrdoToast.swift
//  Ordo
//
//  设计规范 §4「提示条 Toast」:底部居中,圆角 pill,2.4s 自动消失;
//  失败类提示常驻并带「重试」。
//

import SwiftUI

public struct OrdoToast: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case info
        case success
        case failure
    }

    public let id: UUID
    public var text: String
    public var kind: Kind
    /// 失败类提示的重试动作标识(由调用方在 `AppEnvironment` 中处理)。
    /// 标记 `@Sendable`:Toast 是 `Sendable` 值类型,闭包也必须可跨执行器传递。
    public var retryAction: (@Sendable () -> Void)?
    public var autoDismiss: Bool

    public init(text: String, kind: Kind = .info, retryAction: (@Sendable () -> Void)? = nil) {
        self.id = UUID()
        self.text = text
        self.kind = kind
        self.retryAction = retryAction
        // 规范 §4:2.4s 自动消失;失败类常驻。
        self.autoDismiss = kind != .failure
    }

    public static func == (lhs: OrdoToast, rhs: OrdoToast) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.kind == rhs.kind
    }

    public var iconName: String {
        switch kind {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .failure: return "exclamationmark.triangle"
        }
    }

    public var tint: Color {
        switch kind {
        case .info: return OrdoColor.textPrimary
        case .success: return OrdoColor.success
        case .failure: return OrdoColor.danger
        }
    }

    /// 规范 §4:Toast 停留时长。
    public static let autoDismissSeconds: Double = 2.4
}

/// 底部居中的 Toast 容器。
public struct OrdoToastOverlay: View {
    public var toasts: [OrdoToast]
    public var onDismiss: (UUID) -> Void

    public init(toasts: [OrdoToast], onDismiss: @escaping (UUID) -> Void) {
        self.toasts = toasts
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: OrdoSpacing.s) {
            ForEach(toasts) { toast in
                HStack(spacing: OrdoSpacing.s) {
                    Image(systemName: toast.iconName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(toast.tint)
                    Text(toast.text)
                        .font(OrdoFont.captionEmphasis)
                        .foregroundStyle(OrdoColor.textPrimary)
                        .lineLimit(2)
                    if toast.retryAction != nil {
                        Button("重试") { toast.retryAction?() }
                            .font(OrdoFont.captionEmphasis)
                            .foregroundStyle(OrdoColor.accent)
                            .buttonStyle(.plain)
                            .accessibilityLabel("重试")
                    }
                    if !toast.autoDismiss {
                        Button {
                            onDismiss(toast.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(OrdoColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭提示")
                    }
                }
                .padding(.horizontal, OrdoSpacing.m)
                .padding(.vertical, OrdoSpacing.s)
                .background(
                    Capsule(style: .continuous)
                        .fill(OrdoColor.surface)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(OrdoColor.hairline, lineWidth: 1)
                        )
                )
                .ordoSheetElevation()
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    guard toast.autoDismiss else { return }
                    try? await Task.sleep(nanoseconds: UInt64(OrdoToast.autoDismissSeconds * 1_000_000_000))
                    onDismiss(toast.id)
                }
            }
        }
        .padding(.bottom, OrdoSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .center)
        .allowsHitTesting(true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("提示")
    }
}
