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

    // MARK: 登录页(规范 §5.1)

    public enum Login {
        /// 进入登录页:fade + 上移 12px,220ms,`motion.easing.standard`。
        public static let enterOffset: CGFloat = 12
        public static let enterDuration: Double = base
        public static var enter: Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: enterDuration) }
        /// 输入框聚焦:边框转 accent,120ms。
        public static let focusDuration: Double = fast
        public static var focus: Animation { .easeOut(duration: focusDuration) }
        /// 主按钮按压 scale → 0.98(90ms)。
        public static let pressScale: CGFloat = 0.98
        public static let pressDuration: Double = 0.09
        public static var press: Animation { .easeOut(duration: pressDuration) }
        /// 登录成功:卡片 fade out 160ms → 主界面 fade in 220ms。
        public static let cardOutDuration: Double = 0.16
        public static var cardOut: Animation { .easeIn(duration: cardOutDuration) }
        public static var mainIn: Animation { .easeIn(duration: base) }
        /// 错误抖动:振幅 6px,320ms,衰减两次。
        public static let shakeAmplitude: CGFloat = 6
        public static let shakeDuration: Double = 0.32
        public static let shakeCycles: Int = 2
        /// 错误区固定预留高度(规范 §5.1)。
        public static let errorReservedHeight: CGFloat = 20
        /// 登录卡片宽度(规范 §5.1:宽 400)。
        public static let cardWidth: CGFloat = 400
        /// 提交中转圈尺寸(规范 §5.1:16dp 转圈)。
        public static let spinnerSize: CGFloat = 16
    }

    // MARK: 快加号集群(规范 §5.2)

    public enum QuickAdd {
        /// 直径 56(规范 §5.2;令牌 `OrdoSpacing.quickAddDiameter` 同步为 56)。
        public static let diameter: CGFloat = 56
        /// 按压 scale → 0.96(90ms)。
        public static let pressScale: CGFloat = 0.96
        public static let pressDuration: Double = 0.09
        public static var press: Animation { .easeOut(duration: pressDuration) }
        /// 长按到 400ms:轻微放大到 1.06 并保持。
        public static let holdScale: CGFloat = 1.06
        public static let holdDuration: Double = 0.4
        public static var hold: Animation { .easeOut(duration: fast) }
        /// 菜单展开:面板 scale 0.9→1 + alpha 0→1(180ms);收起反向 140ms。
        public static let menuInitialScale: CGFloat = 0.9
        public static let menuInDuration: Double = 0.18
        public static let menuOutDuration: Double = 0.14
        public static var menuIn: Animation { .easeOut(duration: menuInDuration) }
        public static var menuOut: Animation { .easeIn(duration: menuOutDuration) }
        /// 菜单项逐个错位 40ms 淡入并上移 6px。
        public static let itemStagger: Double = 0.04
        public static let itemOffset: CGFloat = 6
        /// 展开时按钮旋转 45°(「+」变「×」)。
        public static let expandedRotation: Double = 45
        public static let rotateDuration: Double = 0.18
        public static var rotate: Animation { .easeInOut(duration: rotateDuration) }
    }

    // MARK: 长按拖拽(规范 §5.4)

    public enum Drag {
        /// 长按 400ms 后进入拖拽。
        public static let longPressDuration: Double = 0.4
        /// 移动 < 6pt 视为点击(不抢走「打开详情」)。
        public static let clickSlop: CGFloat = 6
        /// 行抬起:scale 1.02 + 12dp 投影 + 背景转 surface。
        public static let liftScale: CGFloat = 1.02
        public static let liftShadowRadius: CGFloat = 12
        public static let liftShadowOpacity: Double = 0.18
        /// 被拖行 alpha 0.55。
        public static let draggedOpacity: Double = 0.55
        /// 其余行让位 120ms。
        public static let othersShiftDuration: Double = fast
        public static var othersShift: Animation { .easeOut(duration: othersShiftDuration) }
        /// 行回落 160ms spring;插入指示线 2dp + 左端 4dp 圆点。
        public static let dropDuration: Double = 0.16
        public static var drop: Animation { .spring(response: dropDuration, dampingFraction: 0.78) }
        public static let insertionLineHeight: CGFloat = 2
        public static let insertionDotSize: CGFloat = 4
        /// 抬起时的轻微触感反馈(平台有则用)。
        public static let hapticOnLift = true
    }

    // MARK: 刷新控件(规范 §5.3)

    public enum Refresh {
        /// 同步中:图标连续旋转,每圈 900ms,linear。
        public static let turnDuration: Double = 0.9
        public static var spin: Animation { .linear(duration: turnDuration).repeatForever(autoreverses: false) }
        /// 成功:图标短暂转 success 色 320ms,文字「已同步」,1.4s 后回到常态。
        public static let successFlash: Double = 0.32
        public static let resetDelay: Double = 1.4
        /// 结束后 1.4s 内保持禁用(防抖)。
        public static let debounce: Double = 1.4
        /// 图标按钮直径 28(规范 §5.3)。
        public static let iconSize: CGFloat = 28
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
