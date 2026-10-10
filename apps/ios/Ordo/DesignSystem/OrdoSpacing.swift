//
//  OrdoSpacing.swift
//  Ordo
//
//  设计令牌 · 间距与布局常量(UI 规范 §2.3 / §3 / §4)。
//
//  space.xs/s/m/l/xl = 4 / 8 / 12 / 16 / 24 / 32
//  布局:侧栏 248、内容最大宽度 720、待办行高 38、复选框 20、侧栏项高 34、
//        项目进度环 18(线宽 2)、快加号直径 52、排期浮层宽 280。
//

import CoreGraphics
import SwiftUI

public enum OrdoSpacing {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32

    // MARK: 布局(规范 §3)

    /// 侧栏宽度。
    public static let sidebarWidth: CGFloat = 248
    /// 列表内容最大宽度(居中)。
    public static let contentMaxWidth: CGFloat = 720
    /// 列表区左右留白。
    public static let contentHorizontalPadding: CGFloat = 20
    /// 断点(规范 §3):≥ 该宽度为三栏;iPhone 走抽屉 + 全屏详情。
    public static let threeColumnMinWidth: CGFloat = 1100

    // MARK: 组件(规范 §4)

    /// 待办行高。
    public static let rowHeight: CGFloat = 38
    /// 复选框直径。
    public static let checkboxSize: CGFloat = 20
    /// 复选框描边宽度。
    public static let checkboxStroke: CGFloat = 1.6
    /// 侧栏项高。
    public static let sidebarItemHeight: CGFloat = 34
    /// 侧栏项左内边距。
    public static let sidebarItemLeading: CGFloat = 12
    /// 侧栏图标尺寸。
    public static let sidebarIconSize: CGFloat = 18
    /// 项目进度环尺寸与线宽。
    public static let progressRingSize: CGFloat = 18
    public static let progressRingLineWidth: CGFloat = 2
    /// 详情卡片内边距。
    public static let cardPadding: CGFloat = 16
    /// 标签 chip 高度与内边距。
    public static let chipHeight: CGFloat = 20
    public static let chipHorizontalPadding: CGFloat = 6
    public static let chipVerticalPadding: CGFloat = 2
    /// 元信息图标尺寸。
    public static let metaIconSize: CGFloat = 14
    /// 快加号直径。
    ///
    /// UI 规范 §4 的旧值是 52,§5.2(v1.1「快加号集群」重构)明确为 **56** 并删除了旁边的折叠箭头,
    /// 因此这里取 56(与 `OrdoMotion.QuickAdd.diameter` 一致)。
    public static let quickAddDiameter: CGFloat = OrdoMotion.QuickAdd.diameter
    /// 排期面板宽度。
    public static let schedulePopoverWidth: CGFloat = 280
    /// 快找输入框高度 / 结果行高。
    public static let fastFindInputHeight: CGFloat = 44
    public static let fastFindRowHeight: CGFloat = 36
    /// 空状态插图尺寸。
    public static let emptyIllustrationSize: CGFloat = 64
    /// 触控目标最小值(规范 §8:移动端 ≥ 44 × 44)。
    public static let minTouchTarget: CGFloat = 44
}

public enum OrdoLayout {
    /// 分组之间的垂直间距。
    public static let sectionSpacing: CGFloat = OrdoSpacing.xl
    /// 分组标题与首行之间的距离。
    public static let sectionHeaderSpacing: CGFloat = OrdoSpacing.s
    /// 待办行之间的间距(行本身 38,靠 padding 拉开)。
    public static let rowSpacing: CGFloat = 0
    /// 状态栏高度。
    public static let statusBarHeight: CGFloat = 28
}
