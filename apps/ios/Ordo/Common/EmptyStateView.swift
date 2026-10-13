//
//  EmptyStateView.swift
//  Ordo
//
//  设计规范 §4「空状态」:居中插图(线性 64)+ 标题 20/26 + 副文案 13/18 text.secondary + 主按钮。
//  规范 §9 要求三类边界界面齐全:空状态、错误态、离线态 —— 本组件通过 `kind` 统一表达。
//

import SwiftUI

public struct EmptyStateView: View {

    public enum Kind: Equatable, Sendable {
        case empty
        case noResults(String)
        case offline
        case error(String)

        var title: String {
            switch self {
            case .empty: return "这里还没有待办"
            case .noResults(let text): return text.isEmpty ? "没有匹配结果" : "没有匹配「\(text)」的结果"
            case .offline: return "当前离线"
            case .error: return "出了点问题"
            }
        }

        var message: String {
            switch self {
            case .empty: return "按 ⌘N 或点击右下角的快加号,把想到的事先记下来。"
            case .noResults: return "换个关键词,或检查标签拼写。"
            case .offline: return "本地改动已保存,联网后会自动同步。"
            case .error(let detail): return detail
            }
        }

        var icon: String {
            switch self {
            case .empty: return "tray"
            case .noResults: return "magnifyingglass"
            case .offline: return "wifi.slash"
            case .error: return "exclamationmark.triangle"
            }
        }

        var accent: Color {
            switch self {
            case .error: return OrdoColor.danger
            case .offline: return OrdoColor.textSecondary
            default: return OrdoColor.accent
            }
        }
    }

    public var kind: Kind
    public var actionTitle: String?
    public var action: (() -> Void)?

    public init(kind: Kind, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.kind = kind
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: OrdoSpacing.m) {
            Image(systemName: kind.icon)
                .font(.system(size: OrdoSpacing.emptyIllustrationSize * 0.6, weight: .light))
                .foregroundStyle(kind.accent.opacity(0.85))
                .frame(width: OrdoSpacing.emptyIllustrationSize, height: OrdoSpacing.emptyIllustrationSize)
                .accessibilityHidden(true)

            Text(kind.title)
                .font(OrdoFont.title)
                .foregroundStyle(OrdoColor.textPrimary)
                .multilineTextAlignment(.center)

            Text(kind.message)
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(OrdoFont.bodyEmphasis)
                    .foregroundStyle(.white)
                    .padding(.horizontal, OrdoSpacing.l)
                    .padding(.vertical, OrdoSpacing.s)
                    .background(
                        Capsule(style: .continuous).fill(OrdoColor.accent)
                    )
                    .padding(.top, OrdoSpacing.xs)
                    .accessibilityLabel(actionTitle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, OrdoSpacing.xxl)
        .accessibilityElement(children: .combine)
    }
}
