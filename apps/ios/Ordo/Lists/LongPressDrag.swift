//
//  LongPressDrag.swift
//  Ordo
//
//  UI 规范 §5.4「长按拖拽(统一为独立手势)」。
//
//  变更要点:原先用 `.onDrag`(长按 + 系统拖拽预览)是**独立于点击的第二条路径**,
//  与「点击行 → 打开详情」互相抢手势。现在统一成**长按 400ms 后拖动**这一件事:
//
//  | 阶段 | 规范 |
//  |---|---|
//  | 按下 | 计时 400ms;**移动 < 6pt 视为点击**,不进入拖拽(避免抢走「打开详情」) |
//  | 进入拖拽 | 行抬起:scale 1.02 + 12dp 投影 + 背景转 `surface`;一次轻微触感 |
//  | 拖拽中 | 插入指示线 2dp `accent`(左端 4dp 圆点);被拖行 alpha 0.55;其余行让位 120ms |
//  | 松手 | 落库 + 行回落(160ms spring);**位置未变则不写库** |
//  | 取消 | `Esc` / 右键 / 拖出窗口 → 行回到原位,**不写库** |
//
//  判定逻辑放在纯值类型 `OrdoLongPressDragState`(可在 XCTest 里逐条断言阈值与时序),
//  SwiftUI 部分只做手势接线与视觉。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 纯判定逻辑(无 SwiftUI 依赖)

/// 手势坐标点(避免在纯逻辑里引入 CoreGraphics)。
public struct OrdoDragPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: OrdoDragPoint) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// 手势的判定结果。
public enum OrdoDragEvent: Equatable, Sendable {
    case none
    /// 未进入拖拽且移动 < 6pt → 交给「打开详情」。
    case click
    /// 长按到点,进入拖拽(行抬起)。
    case beganDragging
    /// 松手:是否写库由调用方按落点判断(位置未变则不写)。
    case ended
    /// 取消:行回原位,不写库。
    case cancelled
}

/// 长按拖拽的判定状态机(UI 规范 §5.4)。
public struct OrdoLongPressDragState: Equatable, Sendable {

    public enum Phase: Equatable, Sendable {
        case idle
        case pressing
        case dragging
    }

    /// 长按阈值 400ms。
    public static let longPressDuration: Double = OrdoMotion.Drag.longPressDuration
    /// 点击容差 6pt(移动超过它就不再是点击)。
    public static let clickSlop: Double = Double(OrdoMotion.Drag.clickSlop)

    public private(set) var phase: Phase = .idle
    public private(set) var start: OrdoDragPoint?
    public private(set) var current: OrdoDragPoint?
    /// 是否已越过点击容差(用于取消长按计时)。
    public private(set) var didExceedSlop = false

    public init() {}

    /// 按下:开始计时;返回 `false` 表示这一下不该被当作新的按下(已在拖拽中)。
    @discardableResult
    public mutating func press(at point: OrdoDragPoint) -> Bool {
        guard phase == .idle else { return false }
        phase = .pressing
        start = point
        current = point
        didExceedSlop = false
        return true
    }

    /// 移动。返回 `true` 表示应取消长按计时(用户其实是在滚动列表)。
    @discardableResult
    public mutating func move(to point: OrdoDragPoint) -> Bool {
        current = point
        guard phase == .pressing, let start else { return false }
        guard !didExceedSlop else { return false }
        if point.distance(to: start) >= Self.clickSlop {
            didExceedSlop = true
            return true
        }
        return false
    }

    /// 400ms 到点。
    public mutating func longPressFired() -> OrdoDragEvent {
        guard phase == .pressing, !didExceedSlop else { return .none }
        phase = .dragging
        return .beganDragging
    }

    /// 抬手。
    public mutating func release() -> OrdoDragEvent {
        defer { reset() }
        switch phase {
        case .dragging:
            return .ended
        case .pressing:
            // 移动 < 6pt → 点击(打开详情)
            return didExceedSlop ? .none : .click
        case .idle:
            return .none
        }
    }

    /// 取消(Esc / 右键 / 拖出窗口)。
    public mutating func cancel() -> OrdoDragEvent {
        defer { reset() }
        return phase == .dragging ? .cancelled : .none
    }

    /// 拖拽结束后是否应该写库(位置未变则不写)。
    public static func shouldCommit(sourceId: String, targetId: String?) -> Bool {
        guard let targetId else { return false }
        return targetId != sourceId
    }

    private mutating func reset() {
        phase = .idle
        start = nil
        current = nil
        didExceedSlop = false
    }
}

// MARK: - 触感反馈

/// 抬起时的轻微触感(规范 §5.4;平台有则用,没有就静默跳过)。
public enum OrdoHaptics {
    @MainActor
    public static func lift() {
        #if canImport(UIKit)
        guard OrdoMotion.Drag.hapticOnLift else { return }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        #endif
    }
}

// MARK: - 手势修饰器

/// 把「长按 400ms → 抬起 → 拖动 → 松手/取消」接到一行上。
///
/// 视觉:抬起时 scale 1.02 + 12dp 投影(`isDragging`);投放目标的插入指示线 2dp + 左端 4dp 圆点。
/// 被拖行 alpha 0.55 与背景转 `surface` 由行自己负责(见 `TodoRowView.isLifted`)。
public struct OrdoLongPressDragModifier: ViewModifier {

    /// 是否允许拖拽排序(不可排序时仍保留「点击打开详情」)。
    public let isEnabled: Bool
    public let isDragging: Bool
    public let isDropTarget: Bool
    public let coordinateSpace: String
    public let onPressChange: (Bool) -> Void
    public let onBegin: () -> Void
    public let onMove: (CGPoint) -> Void
    public let onEnd: () -> Void
    public let onCancel: () -> Void
    /// 点击(移动 < 6pt 的抬手)。参数是**按下位置**(列表坐标系),调用方据此避开行内控件
    /// (复选框 / 排期 / 截止 / 恢复按钮自己处理点击,不能再抢一次「打开详情」)。
    public let onTap: (CGPoint) -> Void

    @State private var state = OrdoLongPressDragState()
    @State private var longPressTask: Task<Void, Never>?

    public init(
        isEnabled: Bool,
        isDragging: Bool,
        isDropTarget: Bool,
        coordinateSpace: String,
        onPressChange: @escaping (Bool) -> Void,
        onBegin: @escaping () -> Void,
        onMove: @escaping (CGPoint) -> Void,
        onEnd: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onTap: @escaping (CGPoint) -> Void
    ) {
        self.isEnabled = isEnabled
        self.isDragging = isDragging
        self.isDropTarget = isDropTarget
        self.coordinateSpace = coordinateSpace
        self.onPressChange = onPressChange
        self.onBegin = onBegin
        self.onMove = onMove
        self.onEnd = onEnd
        self.onCancel = onCancel
        self.onTap = onTap
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(isDragging ? OrdoMotion.Drag.liftScale : 1)
            .shadow(
                color: isDragging ? OrdoColor.cardShadow : .clear,
                radius: isDragging ? OrdoMotion.Drag.liftShadowRadius : 0,
                x: 0,
                y: isDragging ? 4 : 0
            )
            .zIndex(isDragging ? 1 : 0)
            .overlay(alignment: .top) {
                insertionIndicator
            }
            // 用 simultaneousGesture:列表仍可正常滚动,只有长按到点后才接管拖动
            .simultaneousGesture(dragGesture)
    }

    /// 插入指示线:2dp accent + 左端 4dp 圆点(规范 §5.4)。
    private var insertionIndicator: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(OrdoColor.accent)
                .frame(width: OrdoMotion.Drag.insertionDotSize, height: OrdoMotion.Drag.insertionDotSize)
            Rectangle()
                .fill(OrdoColor.accent)
                .frame(height: OrdoMotion.Drag.insertionLineHeight)
        }
        .opacity(isDropTarget && isEnabled ? 1 : 0)
        .accessibilityHidden(true)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                if state.phase == .idle {
                    guard state.press(at: OrdoDragPoint(x: value.startLocation.x, y: value.startLocation.y)) else { return }
                    onPressChange(true)
                    startLongPressTimer()
                }
                let shouldCancelTimer = state.move(to: OrdoDragPoint(x: value.location.x, y: value.location.y))
                if shouldCancelTimer { cancelLongPressTimer() }
                if state.phase == .dragging {
                    onMove(value.location)
                }
            }
            .onEnded { value in
                cancelLongPressTimer()
                onPressChange(false)
                switch state.release() {
                case .click:
                    onTap(value.startLocation)
                case .ended:
                    onEnd()
                case .cancelled:
                    onCancel()
                case .none, .beganDragging:
                    break
                }
            }
    }

    private func startLongPressTimer() {
        cancelLongPressTimer()
        guard isEnabled else { return }
        longPressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(OrdoMotion.Drag.longPressDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard state.longPressFired() == .beganDragging else { return }
            OrdoHaptics.lift()
            onBegin()
        }
    }

    private func cancelLongPressTimer() {
        longPressTask?.cancel()
        longPressTask = nil
    }
}

// MARK: - 行位置采集(命中测试用)

/// 收集每一行在列表坐标系里的 frame,用于把手指位置换算成「投放目标行」。
public struct OrdoRowFramePreferenceKey: PreferenceKey {
    public static let defaultValue: [String: CGRect] = [:]

    public static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

public extension View {
    /// 汇报自己在 `coordinateSpace` 里的位置。
    func ordoRowFrame(id: String, in coordinateSpace: String) -> some View {
        background(OrdoFrameReporter(id: id, coordinateSpace: coordinateSpace))
    }
}

/// 上报某个子区域(例如行内的复选框、行尾按钮组)在列表坐标系里的 frame。
///
/// 用途:长按拖拽用的是 `simultaneousGesture`,它**同时**收到落在行内控件上的触摸;
/// 列表据此在「点击打开详情」前排除控件区域,避免一次点击既完成待办又展开详情。
public struct OrdoFrameReporter: View {
    public let id: String
    public let coordinateSpace: String?

    public init(id: String, coordinateSpace: String?) {
        self.id = id
        self.coordinateSpace = coordinateSpace
    }

    public var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: OrdoRowFramePreferenceKey.self,
                value: coordinateSpace.map { [id: proxy.frame(in: .named($0))] } ?? [:]
            )
        }
    }
}
