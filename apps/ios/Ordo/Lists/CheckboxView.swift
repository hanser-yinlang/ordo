//
//  CheckboxView.swift
//  Ordo
//
//  待办复选框(设计规范 §4「复选框」+ §5「完成一条待办」时序)。
//
//  规格:20×20 圆形;未完成 1.6px `#C6C3BA` 描边;完成 → 填充 `accent.primary` + 白色对勾;
//       已取消 → `state.danger` 描边 + 斜线。
//  时序(±40ms):
//    0ms    按压 scale 0.92(90ms)
//    80ms   圆圈填充 accent.primary(0.92 → 1.06 → 1,spring)
//    160ms  白色对勾 stroke 0 → 1(120ms)
//    240ms  标题弱化(由行负责)
//

import SwiftUI

/// 完成动画的阶段。由 `TodoRowView` 驱动,`CheckboxView` 只负责呈现。
public enum OrdoCompletionStage: Int, Comparable, Sendable {
    case idle = 0
    case pressing = 1
    case filling = 2
    case checking = 3
    case dimmed = 4
    case collapsing = 5

    public static func < (lhs: OrdoCompletionStage, rhs: OrdoCompletionStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct CheckboxView: View {

    public var status: OrdoStatus
    public var stage: OrdoCompletionStage
    public var size: CGFloat
    public var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        status: OrdoStatus,
        stage: OrdoCompletionStage = .idle,
        size: CGFloat = OrdoSpacing.checkboxSize,
        action: @escaping () -> Void
    ) {
        self.status = status
        self.stage = stage
        self.size = size
        self.action = action
    }

    /// 是否处于「已完成」外观:数据已完成,或动画已推进到填充阶段。
    private var isFilled: Bool {
        status == .done || stage >= .filling
    }

    private var isCanceled: Bool { status == .canceled }

    private var scale: CGFloat {
        switch stage {
        case .idle: return status == .done ? 1 : 1
        case .pressing: return OrdoMotion.Completion.pressScale
        case .filling: return OrdoMotion.Completion.fillOvershoot
        default: return 1
        }
    }

    /// 对勾的描边进度:0 → 1(规范 §5:160ms 开始,120ms 完成)。
    private var checkProgress: CGFloat {
        if status == .done && stage == .idle { return 1 }
        return stage >= .checking ? 1 : 0
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isFilled ? OrdoColor.accent : Color.clear)
                    .overlay(
                        Circle()
                            .stroke(strokeColor, lineWidth: OrdoSpacing.checkboxStroke)
                    )

                if isCanceled {
                    // 已取消:斜线(不仅靠颜色传达状态,规范 §8)
                    Capsule()
                        .fill(OrdoColor.danger)
                        .frame(width: size * 0.52, height: OrdoSpacing.checkboxStroke)
                        .rotationEffect(.degrees(-45))
                } else {
                    CheckmarkShape()
                        .trim(from: 0, to: checkProgress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: max(1.6, size * 0.1), lineCap: .round, lineJoin: .round))
                        .frame(width: size * 0.5, height: size * 0.5)
                        .opacity(isFilled ? 1 : 0)
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(scale)
            // 触控目标 ≥ 44×44(规范 §8)
            .frame(width: OrdoSpacing.minTouchTarget, height: OrdoSpacing.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : OrdoMotion.Completion.fill, value: stage)
        .animation(reduceMotion ? nil : OrdoMotion.Completion.check, value: stage)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("双击切换完成状态")
        .accessibilityAddTraits(isFilled ? [.isSelected] : [])
    }

    private var strokeColor: Color {
        if isCanceled { return OrdoColor.danger }
        if isFilled { return OrdoColor.accent }
        return OrdoColor.checkboxIdle
    }

    private var accessibilityLabel: String {
        switch status {
        case .open: return stage >= .filling ? "已完成" : "未完成"
        case .done: return "已完成"
        case .canceled: return "已取消"
        }
    }
}

/// 对勾形状(用于描边动画)。
public struct CheckmarkShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.36, y: rect.minY + height * 0.9))
        path.addLine(to: CGPoint(x: rect.minX + width, y: rect.minY + height * 0.12))
        return path
    }
}
