//
//  OrdoMotion.swift
//  Ordo
//
//  设计令牌 · 动效(UI 规范 §5)。
//
//  时长:motion.fast / base / slow = 120ms / 220ms / 320ms
//  缓动:motion.easing.standard = cubic-bezier(.2, .8, .2, 1)
//
//  「完成一条待办」统一时序(四端一致,±40ms):
//    0ms    按压反馈:复选框 scale → 0.92(90ms)
//    80ms   圆圈填充 accent.primary(0.92 → 1.06 → 1,spring)
//    160ms  白色对勾 stroke-dashoffset 0 → 1(120ms)
//    240ms  标题转 text.tertiary + 删除线;行透明度 → 0.72
//    700ms  行高度收起 + 透明度 → 0(180ms ease-in)后从列表移除
//    900ms  项目完成度到 100% 时进度环播放一次高亮脉冲
//
//  必须遵守系统「减弱动态效果」:开启后所有动效降为 0ms 直接切换。
//

import SwiftUI

public enum OrdoMotion {

    // MARK: 时长(秒)

    public static let fast: Double = 0.12
    public static let base: Double = 0.22
    public static let slow: Double = 0.32

    // MARK: 标准缓动(规范 §2.3 `cubic-bezier(.2,.8,.2,1)`)

    public static let standardCurve = AnimationTimingCurve(
        p1x: 0.2, p1y: 0.8,
        p2x: 0.2, p2y: 1.0
    )

    public static var standard: Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: base) }
    public static var fastEase: Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: fast) }
    public static var slowEase: Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: slow) }

    // MARK: 完成动效时序(规范 §5)

    public enum Completion {
        /// 0ms:按压 scale
        public static let pressScale: CGFloat = 0.92
        public static let pressDuration: Double = 0.09
        /// 80ms:填充弹跳
        public static let fillDelay: Double = 0.08
        public static let fillOvershoot: CGFloat = 1.06
        public static let fillDuration: Double = 0.16
        /// 160ms:对勾描边
        public static let checkDelay: Double = 0.16
        public static let checkDuration: Double = 0.12
        /// 240ms:标题弱化 + 行透明度
        public static let dimDelay: Double = 0.24
        public static let dimmedOpacity: Double = 0.72
        /// 700ms:行收起
        public static let collapseDelay: Double = 0.70
        public static let collapseDuration: Double = 0.18
        /// 900ms:进度环脉冲
        public static let ringPulseDelay: Double = 0.90
        public static let ringPulseDuration: Double = 0.22

        public static var press: Animation { .easeOut(duration: pressDuration) }
        public static var fill: Animation { .spring(response: fillDuration, dampingFraction: 0.55) }
        public static var check: Animation { .easeOut(duration: checkDuration) }
        public static var dim: Animation { .easeOut(duration: 0.16) }
        public static var collapse: Animation { .easeIn(duration: collapseDuration) }
        public static var ringPulse: Animation { .easeOut(duration: ringPulseDuration) }
    }

    // MARK: 其它(规范 §5 末段)

    /// 清单展开 220ms ease-out。
    public static var expand: Animation { .easeOut(duration: base) }
    /// 侧栏折叠 260ms。
    public static var sidebarCollapse: Animation { .easeInOut(duration: 0.26) }
    /// 浮层 pop-in 180ms `scale(.98) → 1`。
    public static var popIn: Animation { .easeOut(duration: 0.18) }
    public static let popInInitialScale: CGFloat = 0.98
    /// 页面切换淡入 160ms。
    public static var pageFade: Animation { .easeInOut(duration: 0.16) }

    // MARK: 减弱动态效果

    /// 规范 §5:系统开启「减弱动态效果」时,所有动效降为 0ms 直接切换。
    public static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    public static func duration(_ seconds: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : seconds
    }
}

/// 便于在非 SwiftUI 环境(测试、时序断言)表达缓动曲线。
public struct AnimationTimingCurve: Equatable, Sendable {
    public var p1x: Double
    public var p1y: Double
    public var p2x: Double
    public var p2y: Double

    public init(p1x: Double, p1y: Double, p2x: Double, p2y: Double) {
        self.p1x = p1x
        self.p1y = p1y
        self.p2x = p2x
        self.p2y = p2y
    }
}

// MARK: - 环境读取

public extension View {
    /// 依据「减弱动态效果」设置执行动画。
    func ordoAnimation<V: Equatable>(_ animation: Animation, value: V, reduceMotion: Bool) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }
}
