//
//  ProgressRingView.swift
//  Ordo
//
//  项目进度环(设计规范 §4「项目行」):18×18,底 `line.hairline`,进度 `accent.primary`,线宽 2。
//  规范 §5:项目完成度到达 100% 时播放一次高亮脉冲(900ms,220ms ease-out)。
//

import SwiftUI

public struct ProgressRingView: View {

    public var fraction: Double
    public var size: CGFloat
    public var lineWidth: CGFloat
    /// 是否允许播放「完成脉冲」。
    public var showsPulse: Bool
    /// 大号进度环(项目视图头部使用)。
    public var showsLabel: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    public init(
        fraction: Double,
        size: CGFloat = OrdoSpacing.progressRingSize,
        lineWidth: CGFloat = OrdoSpacing.progressRingLineWidth,
        showsPulse: Bool = false,
        showsLabel: Bool = false
    ) {
        self.fraction = min(max(fraction, 0), 1)
        self.size = size
        self.lineWidth = lineWidth
        self.showsPulse = showsPulse
        self.showsLabel = showsLabel
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(OrdoColor.hairline, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    OrdoColor.accent,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(OrdoMotion.resolved(OrdoMotion.slowEase, reduceMotion: reduceMotion), value: fraction)

            if showsLabel {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundStyle(OrdoColor.textPrimary)
                    .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(pulse ? 1.18 : 1)
        .overlay(
            Circle()
                .stroke(OrdoColor.accent.opacity(pulse ? 0.35 : 0), lineWidth: lineWidth * 1.6)
                .scaleEffect(pulse ? 1.5 : 1)
        )
        .onChange(of: showsPulse) { _, isComplete in
            guard isComplete, !reduceMotion else { return }
            withAnimation(OrdoMotion.Completion.ringPulse) { pulse = true }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(OrdoMotion.Completion.ringPulseDuration * 1_000_000_000))
                withAnimation(OrdoMotion.Completion.ringPulse) { pulse = false }
            }
        }
        .accessibilityLabel("进度 \(Int(fraction * 100))%")
        .accessibilityHidden(!showsLabel && size < OrdoSpacing.progressRingSize * 1.5)
    }
}
