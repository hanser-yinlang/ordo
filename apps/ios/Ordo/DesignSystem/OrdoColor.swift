//
//  OrdoColor.swift
//  Ordo
//
//  设计令牌 · 色彩(UI 规范 §2.1)。浅色 / 深色两套值必须一致落地。
//
//  | Token            | 浅色        | 深色        |
//  |------------------|-------------|-------------|
//  | bg.canvas        | #FBFAF7     | #141416     |
//  | bg.surface       | #FFFFFF     | #1D1D21     |
//  | bg.sidebar       | #F4F3EF     | #191919     |
//  | line.hairline    | #E7E5DF     | #2E2E33     |
//  | text.primary     | #1C1B19     | #F2F1EE     |
//  | text.secondary   | #7A776F     | #9A968E     |
//  | text.tertiary    | #A8A49B     | #6E6B65     |
//  | accent.primary   | #5B5BD6     | #7C7CF0     |
//  | accent.tonight   | #D98324     | #E8A13F     |
//  | state.danger     | #E5533D     | #F2705C     |
//  | state.success    | #2FA36B     | #3FBF83     |
//  | chip.bg/text     | #EFEDE8/#6B6860 | #2A2A2F/#B9B5AC |
//  | focus.ring       | rgba(91,91,214,.45) | rgba(124,124,240,.5) |
//
//  对比度(规范 §2.1):正文 ≥ 4.5:1;大字/图标 ≥ 3:1。
//  说明:text.secondary(#7A776F)对 bg.canvas(#FBFAF7)实测 ≈ 4.9:1,
//  text.tertiary(#A8A49B)仅用于占位/禁用等非关键信息(≈ 2.6:1,不承载正文)。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public enum OrdoColor {

    // MARK: 背景

    /// 列表区背景(暖纸感)
    public static let canvas = Color(light: "#FBFAF7", dark: "#141416")
    /// 卡片、浮层
    public static let surface = Color(light: "#FFFFFF", dark: "#1D1D21")
    /// 侧栏
    public static let sidebar = Color(light: "#F4F3EF", dark: "#191919")

    // MARK: 线条

    /// 分隔线
    public static let hairline = Color(light: "#E7E5DF", dark: "#2E2E33")

    // MARK: 文字

    /// 主文字
    public static let textPrimary = Color(light: "#1C1B19", dark: "#F2F1EE")
    /// 次要信息
    public static let textSecondary = Color(light: "#7A776F", dark: "#9A968E")
    /// 占位、禁用
    public static let textTertiary = Color(light: "#A8A49B", dark: "#6E6B65")

    // MARK: 强调

    /// 主强调(选中、复选框、主按钮)
    public static let accent = Color(light: "#5B5BD6", dark: "#7C7CF0")
    /// 今晚分区
    public static let tonight = Color(light: "#D98324", dark: "#E8A13F")

    // MARK: 状态

    /// 逾期、删除
    public static let danger = Color(light: "#E5533D", dark: "#F2705C")
    /// 完成反馈
    public static let success = Color(light: "#2FA36B", dark: "#3FBF83")

    // MARK: Chip

    public static let chipBackground = Color(light: "#EFEDE8", dark: "#2A2A2F")
    public static let chipText = Color(light: "#6B6860", dark: "#B9B5AC")

    // MARK: 焦点环

    public static let focusRing = Color(light: "#5B5BD6", dark: "#7C7CF0").opacity(0.45)

    // MARK: 语义派生

    /// 选中态底色:`accent.primary` 12%(规范 §4「侧栏项」)。
    public static var selectionFill: Color { accent.opacity(0.12) }
    /// 行悬浮底色。
    public static let rowHover = Color(light: "#000000", dark: "#FFFFFF").opacity(0.04)
    /// 复选框未完成描边(规范 §4:`1.6px #C6C3BA`)。
    public static let checkboxIdle = Color(light: "#C6C3BA", dark: "#5A5A5E")
    /// 卡片阴影(规范 §2.3 `elev.card`)。
    public static let cardShadow = Color.black.opacity(0.08)
    /// 浮层阴影(规范 §2.3 `elev.sheet`)。
    public static let sheetShadow = Color.black.opacity(0.18)

    /// 十六进制颜色(用于区域/标签的自定义色,契约 §2.1/§2.6 的 `color` 字段)。
    public static func hex(_ value: String) -> Color {
        Color(uiColor: UIColor(ordoHex: value) ?? .systemGray)
    }
}

// MARK: - 十六进制解析

public extension UIColor {
    /// 解析 `#RRGGBB` / `RRGGBB` / `#RGB`;失败返回 nil。
    convenience init?(ordoHex: String) {
        var text = ordoHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

public extension Color {
    /// 用浅/深两个十六进制值构造随外观切换的颜色。
    init(light: String, dark: String) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? (UIColor(ordoHex: dark) ?? .black)
                : (UIColor(ordoHex: light) ?? .white)
        })
        #else
        self.init(ordoHexFallback: light)
        #endif
    }
}

#if !canImport(UIKit)
private extension Color {
    init(ordoHexFallback value: String) { self = .gray }
}
#endif
