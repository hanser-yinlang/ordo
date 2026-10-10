//
//  QuickAddMenuItem.swift
//  Ordo
//
//  快加号菜单的**菜单项模型**(UI 规范 §5.2「菜单项图标(v1.3 对齐参照原型,四端一致)」)。
//
//  · 菜单项固定 **4 项**:新建待办 / 项目 / 区域 / 标题(顺序即 §5.2 表格自上而下);
//  · 每项固定一个**形状种类**(`QuickAddIconKind`),形状由 `QuickAddIcons.swift` 用 `Path` 自绘;
//  · 快捷键提示只有「新建待办」显示 ⌘N;
//  · 「新建标题」只在项目视图里出现(标题必须归属项目,契约 §2.3),其余 3 项恒定出现。
//
//  把标题/图标/快捷键/可用性放在这里(而不是散在视图里)是为了能被 XCTest 直接断言:
//  见 `OrdoTests/QuickAddMenuTests.swift`。
//

import Foundation

/// 快加号菜单的一项(规范 §5.2 的四项)。
enum QuickAddItem: String, CaseIterable, Hashable {
    case todo
    case project
    case area
    case heading

    /// 菜单项文案(规范 §5.2 表格)。
    var title: String {
        switch self {
        case .todo: return "新建待办"
        case .project: return "新建项目"
        case .area: return "新建区域"
        case .heading: return "新建标题"
        }
    }

    /// **图标 → 形状**的映射(规范 §5.2「菜单项图标」表,四端一致)。
    var iconKind: QuickAddIconKind {
        switch self {
        case .todo: return .plus
        case .project: return .letterH
        case .area: return .areaBox
        case .heading: return .headingLines
        }
    }

    /// 快捷键提示:规范 §5.2 只有「新建待办」右侧显示 `⌘N`(macOS),其余项不显示。
    var shortcut: String? {
        self == .todo ? "⌘N" : nil
    }

    /// 该菜单项在当前清单上下文里是否出现。
    ///
    /// 菜单**始终按 4 项定义**(规范 §5.2「菜单仍是 4 项」);唯一带上下文条件的是「新建标题」:
    /// 标题必须归属某个项目(契约 §2.3 `heading.projectId`),因此它只在项目视图里可选 ——
    /// 与 Windows 端 `hasHeading = route is Project` 的处理一致,避免在收件箱里给出一个
    /// 必然失败(或静默落到别的项目)的入口。
    func isAvailable(in kind: OrdoListKind) -> Bool {
        self != .heading || kind == .project
    }

    /// 菜单项的规范顺序(§5.2 表格自上而下;`allCases` 即声明顺序)。
    static var displayOrder: [QuickAddItem] { allCases }

    /// 给定上下文里实际显示的菜单项(最多 4 项,顺序与规范一致)。
    static func menuItems(in kind: OrdoListKind) -> [QuickAddItem] {
        displayOrder.filter { $0.isAvailable(in: kind) }
    }
}
