//
//  QuickAddMenuTests.swift
//  OrdoTests
//
//  UI 规范 §5.2「菜单项图标(v1.3 对齐参照原型,四端一致)」的用例:
//    · 菜单仍是 **4 项**、顺序与文案(新建待办 / 项目 / 区域 / 标题);
//    · **图标 → 形状**的映射枚举(＋ / H / 圆角方框+中心点 / ≡),四者互不相同;
//    · 快捷键提示只有「新建待办」显示 ⌘N;
//    · 「新建标题」只在项目视图出现(标题必须归属项目,契约 §2.3);
//    · 20×20 viewBox 与形状几何(线宽 2.1 / H 1.7 / 方框 14×14 圆角 4 / 中心点 r2.6 / 三横线);
//    · 面板与条目尺寸(最小宽 ≥208、radius 12、条目高 ≥44、左 9、图标↔文字 8、条目 radius 7、字号 13.5);
//    · 自绘 `Path` 真的落在 viewBox 内(含线宽的一半也不越界)。
//
//  ⚠️ 本机(Windows)没有 macOS/Swift 工具链,这些用例**无法运行**;
//     请在 macOS 上执行 `bash apps/ios/tools/verify_ios.sh`(或 Xcode 里跑 OrdoTests 目标)。
//     本文件只覆盖纯几何/模型断言,不依赖 `OrdoCore`(KMP)。
//

import CoreGraphics
import XCTest
import SwiftUI
// 模块名两条构建路径不同:Xcode 工程(PRODUCT_NAME=Ordo)是 `Ordo`,SwiftPM 是 `OrdoKit`。
#if canImport(OrdoKit)
@testable import OrdoKit
#else
@testable import Ordo
#endif

// MARK: - 菜单项模型(顺序 / 文案 / 图标映射 / 快捷键)

final class OrdoQuickAddMenuTests: XCTestCase {

    /// 规范 §5.2:菜单仍是 **4 项**,顺序即表格自上而下。
    func testMenuHasFourItemsInSpecOrder() {
        XCTAssertEqual(QuickAddItem.allCases.count, 4)
        XCTAssertEqual(
            QuickAddItem.allCases.map(\.title),
            ["新建待办", "新建项目", "新建区域", "新建标题"]
        )
        XCTAssertEqual(QuickAddItem.displayOrder, [.todo, .project, .area, .heading])
    }

    /// 规范 §5.2「菜单项图标」表:图标 → 形状的映射,四端一致。
    func testIconKindMapping() {
        XCTAssertEqual(QuickAddItem.todo.iconKind, .plus)
        XCTAssertEqual(QuickAddItem.project.iconKind, .letterH)
        XCTAssertEqual(QuickAddItem.area.iconKind, .areaBox)
        XCTAssertEqual(QuickAddItem.heading.iconKind, .headingLines)
        // 四个形状必须互不相同,否则「H 与 ≡ 可区分」等要求就落空了。
        XCTAssertEqual(Set(QuickAddItem.allCases.map(\.iconKind)).count, 4)
    }

    /// 形状种类的 rawValue 是跨端对齐时引用的名字,改名必须显式改这里。
    func testIconKindRawValuesAreStable() {
        XCTAssertEqual(
            QuickAddIconKind.allCases.map(\.rawValue),
            ["plus", "letterH", "areaBox", "headingLines"]
        )
    }

    /// 规范 §5.2:快捷键提示只有「新建待办」显示 ⌘N。
    func testShortcutOnlyOnTodo() {
        XCTAssertEqual(QuickAddItem.todo.shortcut, "⌘N")
        XCTAssertNil(QuickAddItem.project.shortcut)
        XCTAssertNil(QuickAddItem.area.shortcut)
        XCTAssertNil(QuickAddItem.heading.shortcut)
        XCTAssertEqual(QuickAddItem.allCases.filter { $0.shortcut != nil }, [.todo])
    }

    /// 菜单始终是 4 项;「新建标题」只在项目视图里出现(契约 §2.3:heading 必须归属 project)。
    func testHeadingOnlyAvailableInsideProject() {
        XCTAssertEqual(QuickAddItem.menuItems(in: .project), [.todo, .project, .area, .heading])
        XCTAssertEqual(QuickAddItem.menuItems(in: .inbox), [.todo, .project, .area])
        XCTAssertEqual(QuickAddItem.menuItems(in: .area), [.todo, .project, .area])
        XCTAssertEqual(QuickAddItem.menuItems(in: .today), [.todo, .project, .area])
        XCTAssertEqual(QuickAddItem.menuItems(in: .tag), [.todo, .project, .area])

        for item in QuickAddItem.allCases {
            XCTAssertTrue(item.isAvailable(in: .project), "\(item.title)在项目视图里都应可选")
        }
        XCTAssertTrue(QuickAddItem.todo.isAvailable(in: .inbox))
        XCTAssertFalse(QuickAddItem.heading.isAvailable(in: .inbox))
    }

    /// 任何上下文下菜单都不超过 4 项、且不含重复项(规范 §5.2:菜单仍是 4 项)。
    func testMenuNeverExceedsFourDistinctItems() {
        for kind in OrdoListKind.allCases {
            let items = QuickAddItem.menuItems(in: kind)
            XCTAssertLessThanOrEqual(items.count, 4, "\(kind) 的菜单项超过 4 项")
            XCTAssertEqual(Set(items).count, items.count, "\(kind) 的菜单项出现重复")
            XCTAssertTrue(items.contains(.todo))
            XCTAssertTrue(items.contains(.project))
            XCTAssertTrue(items.contains(.area))
        }
    }
}

// MARK: - 图标几何与自绘 Path(20×20 viewBox)

final class OrdoQuickAddIconShapeTests: XCTestCase {

    private var viewBox: CGRect {
        CGRect(x: 0, y: 0, width: QuickAddIconMetrics.viewBox, height: QuickAddIconMetrics.viewBox)
    }

    /// 规范 §5.2 表格里的几何数值(线宽取自参照原型的原始定义)。
    func testGeometryMatchesSpec() {
        XCTAssertEqual(QuickAddIconMetrics.viewBox, 20)

        // ＋:两条 2.1 粗圆头直线,臂长 12(4 → 16)
        XCTAssertEqual(QuickAddIconMetrics.plusStroke, 2.1, accuracy: 0.0001)
        XCTAssertEqual(QuickAddIconMetrics.plusArmLength, 12, accuracy: 0.0001)

        // H:stroke 1.7
        XCTAssertEqual(QuickAddIconMetrics.letterHStroke, 1.7, accuracy: 0.0001)

        // 区域:14×14 圆角 4 的描边方框(**stroke 1.5**,参照原型 `i-area`)+ 中心 2.6 半径实心点
        XCTAssertEqual(QuickAddIconMetrics.areaBoxSize, 14, accuracy: 0.0001)
        XCTAssertEqual(QuickAddIconMetrics.areaBoxCornerRadius, 4, accuracy: 0.0001)
        XCTAssertEqual(QuickAddIconMetrics.areaBoxStroke, 1.5, accuracy: 0.0001)
        XCTAssertEqual(QuickAddIconMetrics.areaDotRadius, 2.6, accuracy: 0.0001)

        // ≡:三横线(y = 5 / 10 / 15),stroke 与 H 同粗 1.7
        XCTAssertEqual(QuickAddIconMetrics.headingLineStroke, 1.7, accuracy: 0.0001)
        XCTAssertEqual(QuickAddIconMetrics.headingLineCount, 3)
        XCTAssertEqual(QuickAddIconMetrics.headingLineSpacing, 5, accuracy: 0.0001)
    }

    /// 四者线宽必须与规范逐项一致(＋ 2.1 / H 1.7 / 方框 1.5 / ≡ 1.7):
    /// 方框比 H **细一档**是 v1.3 的刻意规定,不能被「统一笔触」改回去。
    func testStrokeWidthsMatchSpecExactly() {
        XCTAssertEqual(QuickAddIconMetrics.plusStroke, 2.1, accuracy: 0.0001)
        XCTAssertEqual(QuickAddIconMetrics.letterHStroke, 1.7, accuracy: 0.0001)
        XCTAssertEqual(
            QuickAddIconMetrics.areaBoxStroke,
            1.5,
            accuracy: 0.0001,
            "区域方框线宽由规范定为 1.5(不是与 H 相同的 1.7)"
        )
        XCTAssertEqual(QuickAddIconMetrics.headingLineStroke, 1.7, accuracy: 0.0001)

        XCTAssertLessThan(QuickAddIconMetrics.areaBoxStroke, QuickAddIconMetrics.letterHStroke)
        XCTAssertGreaterThan(QuickAddIconMetrics.plusStroke, QuickAddIconMetrics.letterHStroke)
        XCTAssertEqual(QuickAddIconMetrics.headingLineStroke, QuickAddIconMetrics.letterHStroke)
    }

    /// 面板与条目尺寸(规范 §5.2:最小宽 ≥208 / radius 12 / 条目 ≥44 / 左 9 / 间距 8 / radius 7 / 13.5)。
    func testMenuPanelAndItemMetricsMatchSpec() {
        XCTAssertGreaterThanOrEqual(OrdoMotion.QuickAdd.menuMinWidth, 208)
        XCTAssertEqual(OrdoRadius.quickAddMenu, 12)

        XCTAssertGreaterThanOrEqual(OrdoMotion.QuickAdd.menuItemHeight, 44)
        XCTAssertEqual(OrdoMotion.QuickAdd.menuItemHeight, OrdoSpacing.minTouchTarget, "条目高取触控目标 44")
        XCTAssertEqual(OrdoMotion.QuickAdd.menuItemLeading, 9)
        XCTAssertEqual(OrdoMotion.QuickAdd.menuItemIconTextGap, 8)
        XCTAssertEqual(OrdoRadius.quickAddItem, 7)

        XCTAssertEqual(OrdoFont.quickAddItemSize, 13.5)
        XCTAssertGreaterThan(OrdoFont.quickAddItemSize, OrdoFont.Size.caption)
        XCTAssertLessThan(OrdoFont.quickAddItemSize, OrdoFont.Size.body)
    }

    /// 四种自绘形状的几何尺寸(直接跑 `Shape.path(in:)`,防止「枚举有了但图形没画」)。
    func testShapesProduceExpectedPaths() {
        let plus = OrdoQuickAddPlusShape().path(in: viewBox).boundingRect
        XCTAssertEqual(plus.width, 12, accuracy: 0.001)
        XCTAssertEqual(plus.height, 12, accuracy: 0.001)
        XCTAssertEqual(plus.midX, 10, accuracy: 0.001)
        XCTAssertEqual(plus.midY, 10, accuracy: 0.001)

        let letterH = OrdoQuickAddLetterHShape().path(in: viewBox).boundingRect
        XCTAssertEqual(letterH.width, 10, accuracy: 0.001)
        XCTAssertEqual(letterH.height, 12, accuracy: 0.001)
        XCTAssertEqual(letterH.midX, 10, accuracy: 0.001)

        let box = OrdoQuickAddAreaBoxShape().path(in: viewBox).boundingRect
        XCTAssertEqual(box.width, 14, accuracy: 0.001)
        XCTAssertEqual(box.height, 14, accuracy: 0.001)
        XCTAssertEqual(box.midX, 10, accuracy: 0.001)

        let dot = OrdoQuickAddAreaDotShape().path(in: viewBox).boundingRect
        XCTAssertEqual(dot.width, 5.2, accuracy: 0.001)
        XCTAssertEqual(dot.height, 5.2, accuracy: 0.001)
        XCTAssertEqual(dot.midX, 10, accuracy: 0.001)
        XCTAssertEqual(dot.midY, 10, accuracy: 0.001)

        // 三横线:三行 y = 5 / 10 / 15,每行长 11
        let lines = OrdoQuickAddHeadingLinesShape().path(in: viewBox).boundingRect
        XCTAssertEqual(lines.width, 11, accuracy: 0.001)
        XCTAssertEqual(lines.height, 10, accuracy: 0.001)
        XCTAssertEqual(lines.minY, 5, accuracy: 0.001)
        XCTAssertEqual(lines.maxY, 15, accuracy: 0.001)
    }

    /// 含线宽的一半也不越出 20×20 viewBox(规范:20×20 等价形状)。
    func testShapesStayInsideViewBoxIncludingStroke() {
        let cases: [(name: String, rect: CGRect, halfStroke: CGFloat)] = [
            ("plus", OrdoQuickAddPlusShape().path(in: viewBox).boundingRect, QuickAddIconMetrics.plusStroke / 2),
            ("letterH", OrdoQuickAddLetterHShape().path(in: viewBox).boundingRect, QuickAddIconMetrics.letterHStroke / 2),
            ("areaBox", OrdoQuickAddAreaBoxShape().path(in: viewBox).boundingRect, QuickAddIconMetrics.areaBoxStroke / 2),
            ("areaDot", OrdoQuickAddAreaDotShape().path(in: viewBox).boundingRect, 0),
            (
                "headingLines",
                OrdoQuickAddHeadingLinesShape().path(in: viewBox).boundingRect,
                QuickAddIconMetrics.headingLineStroke / 2
            ),
        ]

        for item in cases {
            let painted = item.rect.insetBy(dx: -item.halfStroke, dy: -item.halfStroke)
            XCTAssertTrue(
                viewBox.contains(painted),
                "\(item.name) 描边后越出 viewBox:painted=\(painted) viewBox=\(viewBox)"
            )
        }
    }

    /// 每个形状种类都必须有对应的自绘 Shape 能产出非空路径(右侧 switch 与枚举保持同步)。
    func testEveryIconKindHasADrawableShape() {
        let shapes: [QuickAddIconKind: Path] = [
            .plus: OrdoQuickAddPlusShape().path(in: viewBox),
            .letterH: OrdoQuickAddLetterHShape().path(in: viewBox),
            .areaBox: OrdoQuickAddAreaBoxShape().path(in: viewBox),
            .headingLines: OrdoQuickAddHeadingLinesShape().path(in: viewBox),
        ]
        for kind in QuickAddIconKind.allCases {
            let path = shapes[kind]
            XCTAssertNotNil(path, "\(kind.rawValue) 缺少自绘形状")
            XCTAssertFalse(path?.isEmpty ?? true, "\(kind.rawValue) 的路径为空")
        }
        XCTAssertEqual(shapes.count, QuickAddIconKind.allCases.count)
        // 区域还有独立的中心点。
        XCTAssertFalse(OrdoQuickAddAreaDotShape().path(in: viewBox).isEmpty)
    }

    /// 形状按实际 rect 等比缩放(换个尺寸渲染也不会画歪)。
    func testShapesScaleWithRect() {
        let doubled = CGRect(x: 0, y: 0, width: 40, height: 40)
        let plus = OrdoQuickAddPlusShape().path(in: doubled).boundingRect
        XCTAssertEqual(plus.width, 24, accuracy: 0.001)
        XCTAssertEqual(plus.midX, 20, accuracy: 0.001)

        let box = OrdoQuickAddAreaBoxShape().path(in: doubled).boundingRect
        XCTAssertEqual(box.width, 28, accuracy: 0.001)

        // 非正方形 rect 取短边,居中绘制。
        let wide = CGRect(x: 0, y: 0, width: 60, height: 20)
        let dot = OrdoQuickAddAreaDotShape().path(in: wide).boundingRect
        XCTAssertEqual(dot.width, 5.2, accuracy: 0.001, "取短边 20 作为 viewBox 边长")
        XCTAssertEqual(dot.midX, 30, accuracy: 0.001)
    }
}
