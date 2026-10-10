//
//  QuickAddIcons.swift
//  Ordo
//
//  快加号菜单的前导图标(UI 规范 §5.2「菜单项图标(v1.3 对齐参照原型,四端一致)」)。
//
//  为什么这四个图标全部**自绘**而不是用 SF Symbols:规范给的是 20×20 viewBox 上的具体形状与
//  线宽(＋ = 两条 2.1 粗圆头直线、项目 = H 两竖一横 stroke 1.7、
//  区域 = 14×14 圆角 4 的描边方框 stroke 1.5(取自参照原型 `i-area` 的原始 `stroke-width`)
//  + 中心 r2.6 实心点、标题 = 三横线 ≡ stroke 1.7),而系统符号里没有与它们**形状等价**的选项:
//    · `plus.circle` 多一个圆圈;`plus` 是裸加号但线宽由字重决定,无法钉到 2.1;
//    · `circle.dashed` 是虚线圆、`h.square` 是「带 H 的方框」,都不是「两竖一横的 H」;
//    · `square.grid.2x2` 是 2×2 网格,不是「方框 + 中心点」;
//    · `text.line.first.and.arrowtriangle.forward` 是带箭头的文本行,不是三横线。
//  为了凑形状换符号会引入语义漂移,因此统一用 `Path` 自绘;线宽/圆角/半径都取自
//  `QuickAddIconMetrics`,可以被 XCTest 逐条钉住(见 `OrdoTests/QuickAddMenuTests.swift`)。
//
//  颜色由调用方传入:规范 §5.2 要求菜单项图标用 `textSecondary`(只有 FAB 与选中态用
//  `accent.primary`),并且**不引入参照原型的蓝色**。
//

import SwiftUI

// MARK: - 图标种类(图标 → 形状的映射由 `QuickAddItem.iconKind` 固定)

/// 菜单项图标的**形状种类**。四种形状互不相同,一一对应 §5.2 表格的四行。
public enum QuickAddIconKind: String, CaseIterable, Sendable {
    /// 新建待办:＋(两条圆头直线交叉)。
    case plus
    /// 新建项目:H(两竖 + 中间一横)。
    case letterH
    /// 新建区域:圆角方框 + 中心实心点。
    case areaBox
    /// 新建标题:三横线(≡;Ordo 自有项,参照原型没有)。
    case headingLines
}

// MARK: - 几何(规范 §5.2 表格里的数值)

/// 图标几何常量:viewBox 固定 **20×20**,所有数值都是该坐标系下的绝对量。
public enum QuickAddIconMetrics {

    /// 规范:20×20 viewBox。
    public static let viewBox: CGFloat = 20

    // ＋(新建待办)

    /// 规范:两条 **2.1** 粗圆头直线。
    public static let plusStroke: CGFloat = 2.1
    /// 臂长 12(即 4 → 16,四周各留 4)。
    public static let plusArmLength: CGFloat = 12

    // H(新建项目)

    /// 规范:**stroke 1.7 圆头**。
    public static let letterHStroke: CGFloat = 1.7
    /// 两竖的横向跨度(5 → 15)与纵向高度(4 → 16);中间一横连两竖。
    public static let letterHWidth: CGFloat = 10
    public static let letterHHeight: CGFloat = 12

    // 圆角方框 + 中心点(新建区域)

    /// 规范:**14×14 圆角 4** 的描边方框。
    public static let areaBoxSize: CGFloat = 14
    public static let areaBoxCornerRadius: CGFloat = 4
    /// 规范 (**v1.3 已定**):方框 **stroke 1.5**,取自参照原型 `i-area` 的原始 `stroke-width`;
    /// 比 H 的 1.7 细一档,是刻意的(方框是「容器」形状,细一点才不像实心块)。
    public static let areaBoxStroke: CGFloat = 1.5
    /// 规范:中心 **2.6** 半径实心点。
    public static let areaDotRadius: CGFloat = 2.6

    // 三横线 ≡(新建标题)

    /// 三横线:线宽与 H 同粗(1.7),每行长 11(4.5 → 15.5),y = 5 / 10 / 15。
    public static let headingLineStroke: CGFloat = 1.7
    public static let headingLineLength: CGFloat = 11
    public static let headingLineCount: Int = 3
    public static let headingLineSpacing: CGFloat = 5
}

// MARK: - 逻辑坐标 → 实际 rect

/// 把 20×20 的逻辑坐标映射到 `Shape.path(in:)` 拿到的 `rect`。
///
/// 图标默认就以 20×20 渲染,这里做等比缩放是为了「换个尺寸也不会画歪」。
struct QuickAddIconGeometry {

    private let origin: CGPoint
    private let unit: CGFloat

    init(_ rect: CGRect) {
        let side = min(rect.width, rect.height)
        unit = side / QuickAddIconMetrics.viewBox
        origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
    }

    /// 逻辑点 → 实际点。
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
    }

    /// 逻辑长度 → 实际长度。
    func length(_ value: CGFloat) -> CGFloat { value * unit }

    /// 逻辑矩形 → 实际矩形。
    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + x * unit,
            y: origin.y + y * unit,
            width: width * unit,
            height: height * unit
        )
    }
}

// MARK: - 四个形状

/// ＋:两条 2.1 粗圆头直线交叉(中心 10,10)。
struct OrdoQuickAddPlusShape: Shape {
    func path(in rect: CGRect) -> Path {
        let geometry = QuickAddIconGeometry(rect)
        let arm = QuickAddIconMetrics.plusArmLength / 2
        var path = Path()
        path.move(to: geometry.point(10 - arm, 10))
        path.addLine(to: geometry.point(10 + arm, 10))
        path.move(to: geometry.point(10, 10 - arm))
        path.addLine(to: geometry.point(10, 10 + arm))
        return path
    }
}

/// H:两竖(x = 5 / 15,y 4 → 16)+ 中间一横(y = 10),stroke 1.7 圆头。
struct OrdoQuickAddLetterHShape: Shape {
    func path(in rect: CGRect) -> Path {
        let geometry = QuickAddIconGeometry(rect)
        let halfWidth = QuickAddIconMetrics.letterHWidth / 2
        let halfHeight = QuickAddIconMetrics.letterHHeight / 2
        var path = Path()
        path.move(to: geometry.point(10 - halfWidth, 10 - halfHeight))
        path.addLine(to: geometry.point(10 - halfWidth, 10 + halfHeight))
        path.move(to: geometry.point(10 + halfWidth, 10 - halfHeight))
        path.addLine(to: geometry.point(10 + halfWidth, 10 + halfHeight))
        path.move(to: geometry.point(10 - halfWidth, 10))
        path.addLine(to: geometry.point(10 + halfWidth, 10))
        return path
    }
}

/// 圆角方框:14×14、圆角 4,描边(stroke 1.5,取自参照原型 `i-area`)。
struct OrdoQuickAddAreaBoxShape: Shape {
    func path(in rect: CGRect) -> Path {
        let geometry = QuickAddIconGeometry(rect)
        let size = QuickAddIconMetrics.areaBoxSize
        let corner = QuickAddIconMetrics.areaBoxCornerRadius
        var path = Path()
        path.addRoundedRect(
            in: geometry.rect(10 - size / 2, 10 - size / 2, size, size),
            cornerSize: CGSize(width: geometry.length(corner), height: geometry.length(corner))
        )
        return path
    }
}

/// 中心实心点:半径 2.6(fill,不描边)。
struct OrdoQuickAddAreaDotShape: Shape {
    func path(in rect: CGRect) -> Path {
        let geometry = QuickAddIconGeometry(rect)
        let radius = QuickAddIconMetrics.areaDotRadius
        return Path(ellipseIn: geometry.rect(10 - radius, 10 - radius, radius * 2, radius * 2))
    }
}

/// 三横线 ≡:y = 5 / 10 / 15,每行长 11,stroke 1.7 圆头。
struct OrdoQuickAddHeadingLinesShape: Shape {
    func path(in rect: CGRect) -> Path {
        let geometry = QuickAddIconGeometry(rect)
        let halfLength = QuickAddIconMetrics.headingLineLength / 2
        let count = QuickAddIconMetrics.headingLineCount
        let spacing = QuickAddIconMetrics.headingLineSpacing
        let firstY = 10 - spacing * CGFloat(count - 1) / 2
        var path = Path()
        for index in 0..<count {
            let y = firstY + spacing * CGFloat(index)
            path.move(to: geometry.point(10 - halfLength, y))
            path.addLine(to: geometry.point(10 + halfLength, y))
        }
        return path
    }
}

// MARK: - 图标视图

/// 20×20 的矢量图标(颜色由调用方给,规范 §5.2:菜单项用 `textSecondary`)。
struct QuickAddIcon: View {

    let kind: QuickAddIconKind
    let color: Color

    var body: some View {
        ZStack {
            switch kind {
            case .plus:
                OrdoQuickAddPlusShape()
                    .stroke(color, style: stroke(QuickAddIconMetrics.plusStroke))
            case .letterH:
                OrdoQuickAddLetterHShape()
                    .stroke(color, style: stroke(QuickAddIconMetrics.letterHStroke))
            case .areaBox:
                OrdoQuickAddAreaBoxShape()
                    .stroke(color, style: stroke(QuickAddIconMetrics.areaBoxStroke))
                OrdoQuickAddAreaDotShape()
                    .fill(color)
            case .headingLines:
                OrdoQuickAddHeadingLinesShape()
                    .stroke(color, style: stroke(QuickAddIconMetrics.headingLineStroke))
            }
        }
        .frame(
            width: QuickAddIconMetrics.viewBox,
            height: QuickAddIconMetrics.viewBox
        )
        // 形状语义由所在菜单项的 accessibilityLabel 表达,图标本身不重复播报。
        .accessibilityHidden(true)
    }

    /// 规范 §5.2:线宽固定、圆头(圆角连接),因此用 `.round` cap/join。
    private func stroke(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}
