//
//  SwipeActions.swift
//  Ordo
//
//  手势(设计规范 §6):「切换完成」= 右滑;「删除」= 左滑;「排期」= 行右滑。
//
//  实现说明:列表使用 ScrollView + LazyVStack(便于内联详情卡片与自定义 38pt 行高),
//  因此不能使用 `List` 的 `.swipeActions`,这里提供等价的手势实现:
//  拖动超过阈值即触发;未超过阈值回弹。全部动作同时提供按钮入口(无障碍要求,规范 §8)。
//

import SwiftUI

public struct OrdoSwipeAction: Identifiable {
    public enum Edge {
        case leading
        case trailing
    }

    public let id = UUID()
    public var edge: Edge
    public var systemImage: String
    public var label: String
    public var tint: Color
    public var action: () -> Void

    public init(edge: Edge, systemImage: String, label: String, tint: Color, action: @escaping () -> Void) {
        self.edge = edge
        self.systemImage = systemImage
        self.label = label
        self.tint = tint
        self.action = action
    }

    public static func complete(_ action: @escaping () -> Void) -> OrdoSwipeAction {
        OrdoSwipeAction(edge: .leading, systemImage: "checkmark.circle.fill", label: "完成", tint: OrdoColor.success, action: action)
    }

    public static func schedule(_ action: @escaping () -> Void) -> OrdoSwipeAction {
        OrdoSwipeAction(edge: .leading, systemImage: "calendar", label: "排期", tint: OrdoColor.accent, action: action)
    }

    public static func delete(_ action: @escaping () -> Void) -> OrdoSwipeAction {
        OrdoSwipeAction(edge: .trailing, systemImage: "trash", label: "删除", tint: OrdoColor.danger, action: action)
    }
}

public struct OrdoSwipeActionsModifier: ViewModifier {

    public var leading: [OrdoSwipeAction]
    public var trailing: [OrdoSwipeAction]
    /// 触发阈值(规范未明确,取 56pt:既不易误触,又能单手完成)。
    public var threshold: CGFloat = 56

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var isTriggered = false

    public func body(content: Content) -> some View {
        ZStack {
            backgroundLayer
            content
                .offset(x: offset)
                .gesture(dragGesture)
        }
        .clipShape(RoundedRectangle(cornerRadius: OrdoRadius.row, style: .continuous))
        .accessibilityAction(named: "完成", leading.first?.action ?? {})
        .accessibilityAction(named: "删除", trailing.first?.action ?? {})
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isTriggered else { return }
                let translation = value.translation.width
                // 只响应横向意图明显的拖动,避免与纵向滚动冲突。
                guard abs(translation) > abs(value.translation.height) else { return }
                offset = translation
            }
            .onEnded { value in
                defer { offset = 0 }
                let translation = value.translation.width
                if translation >= threshold, let action = leading.first {
                    trigger(action)
                } else if translation <= -threshold, let action = trailing.first {
                    trigger(action)
                }
            }
    }

    private func trigger(_ action: OrdoSwipeAction) {
        isTriggered = true
        withAnimation(OrdoMotion.resolved(OrdoMotion.fastEase, reduceMotion: reduceMotion)) {
            action.action()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            isTriggered = false
        }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        HStack(spacing: 0) {
            if offset > 0, let action = leading.first {
                label(action)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            if offset < 0, let action = trailing.first {
                label(action)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .opacity(min(1, abs(offset) / threshold))
    }

    private func label(_ action: OrdoSwipeAction) -> some View {
        HStack(spacing: OrdoSpacing.xs) {
            Image(systemName: action.systemImage)
                .font(.system(size: 14, weight: .semibold))
            Text(action.label)
                .font(OrdoFont.captionEmphasis)
        }
        .foregroundStyle(action.tint)
        .padding(.horizontal, OrdoSpacing.m)
    }
}

public extension View {
    /// 行级滑动手势(见设计规范 §6)。
    func ordoSwipeActions(
        leading: [OrdoSwipeAction] = [],
        trailing: [OrdoSwipeAction] = []
    ) -> some View {
        modifier(OrdoSwipeActionsModifier(leading: leading, trailing: trailing))
    }
}
