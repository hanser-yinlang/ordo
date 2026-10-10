//
//  OrdoRadius.swift
//  Ordo
//
//  设计令牌 · 圆角与阴影(UI 规范 §2.3)。
//
//  radius.row / card / sheet / pill = 10 / 14 / 14 / 999
//  elev.card  = 0 1 2 rgba(0,0,0,.06), 0 8 24 rgba(0,0,0,.08)
//  elev.sheet = 0 12 40 rgba(0,0,0,.18), 0 2 8 rgba(0,0,0,.08)
//

import SwiftUI

public enum OrdoRadius {
    /// 待办行、列表项。
    public static let row: CGFloat = 10
    /// 卡片(详情卡片)。
    public static let card: CGFloat = 14
    /// 浮层(排期面板、快找、菜单)。
    public static let sheet: CGFloat = 14
    /// 胶囊(标签 chip、Toast、字段按钮)。
    public static let pill: CGFloat = 999
    /// 输入框。
    public static let field: CGFloat = 10
    /// 登录卡片(规范 §5.1:卡片 `radius 16`,与 §2.3 的 `radius.card` 14 不同)。
    public static let loginCard: CGFloat = 16
    /// 主按钮(规范 §5.1:`radius 10`,高 44)。
    public static let primaryButton: CGFloat = 10
    /// 主按钮高度(规范 §5.1:高 44)。
    public static let primaryButtonHeight: CGFloat = 44
}

public enum OrdoElevation {
    /// 卡片阴影。
    public struct Card: ViewModifier {
        public func body(content: Content) -> some View {
            content
                .shadow(color: Color.black.opacity(0.06), radius: 1, x: 0, y: 1)
                .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 8)
        }
    }

    /// 浮层阴影。
    public struct Sheet: ViewModifier {
        public func body(content: Content) -> some View {
            content
                .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 12)
                .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
        }
    }

    /// 快加号阴影(规范 §4:使用 `elev.sheet`)。
    public struct QuickAdd: ViewModifier {
        public func body(content: Content) -> some View {
            content
                .shadow(color: OrdoColor.sheetShadow, radius: 20, x: 0, y: 12)
                .shadow(color: OrdoColor.cardShadow, radius: 4, x: 0, y: 2)
        }
    }
}

public extension View {
    func ordoCardElevation() -> some View { modifier(OrdoElevation.Card()) }
    func ordoSheetElevation() -> some View { modifier(OrdoElevation.Sheet()) }
    func ordoQuickAddElevation() -> some View { modifier(OrdoElevation.QuickAdd()) }
}
