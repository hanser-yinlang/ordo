//
//  OrdoFont.swift
//  Ordo
//
//  设计令牌 · 排版(UI 规范 §2.2)。
//
//  | Token        | 字号/行高 | 字重 |
//  |--------------|-----------|------|
//  | font.display | 28 / 34   | 600  |  清单大标题
//  | font.title   | 20 / 26   | 600  |  卡片标题、项目名
//  | font.body    | 15 / 22   | 400  |  待办标题、正文
//  | font.caption | 13 / 18   | 400  |  元信息、日期、计数
//  | font.micro   | 11 / 14   | 500  |  标签 chip、分组标题(全大写时字距 +0.4)
//
//  字体栈:iOS 使用系统字体(SF Pro);不内嵌字体文件。
//  无障碍(规范 §8):必须支持系统字体缩放至 200% 不截断 —— 因此全部使用
//  `Font.system(size:weight:design:)`,它随 Dynamic Type 缩放;行高通过 `lineSpacing` 表达。
//

import SwiftUI

public enum OrdoFont {

    // MARK: 字号(基准)

    public enum Size {
        public static let display: CGFloat = 28
        public static let title: CGFloat = 20
        public static let body: CGFloat = 15
        public static let caption: CGFloat = 13
        public static let micro: CGFloat = 11
    }

    // MARK: 行高(规范给出;SwiftUI 用 lineSpacing = 行高 - 字号 * 1.2 近似)

    public enum LineHeight {
        public static let display: CGFloat = 34
        public static let title: CGFloat = 26
        public static let body: CGFloat = 22
        public static let caption: CGFloat = 18
        public static let micro: CGFloat = 14
    }

    // MARK: 字体

    /// 28 / 34 · 600
    public static let display = Font.system(size: Size.display, weight: .semibold, design: .default)
    /// 20 / 26 · 600
    public static let title = Font.system(size: Size.title, weight: .semibold, design: .default)
    /// 15 / 22 · 400
    public static let body = Font.system(size: Size.body, weight: .regular, design: .default)
    /// 15 / 22 · 500(强调正文,例如项目名)
    public static let bodyEmphasis = Font.system(size: Size.body, weight: .medium, design: .default)
    /// 13 / 18 · 400
    public static let caption = Font.system(size: Size.caption, weight: .regular, design: .default)
    /// 13 / 18 · 500(计数、可点击元信息)
    public static let captionEmphasis = Font.system(size: Size.caption, weight: .medium, design: .default)
    /// 11 / 14 · 500
    public static let micro = Font.system(size: Size.micro, weight: .medium, design: .default)

    /// 登录页品牌字(UI 规范 §5.1:24 / 32 · 600;清单大标题用 `display` 28/34,两者刻意不同)。
    public static let loginBrand = Font.system(size: loginBrandSize, weight: .semibold, design: .default)
    public static let loginBrandSize: CGFloat = 24
    public static let loginBrandLineHeight: CGFloat = 32

    /// 快加号菜单条目(UI 规范 §5.2:字号 **13.5**,介于 `caption` 13 与 `body` 15 之间;
    /// 规范未定字重,取 `.medium` 与既有的 `bodyEmphasis` 菜单写法保持一致)。
    public static let quickAddItem = Font.system(size: quickAddItemSize, weight: .medium, design: .default)
    public static let quickAddItemSize: CGFloat = 13.5

    /// 等宽(备注中的 `代码`、调试信息)。
    public static let mono = Font.system(size: Size.caption, weight: .regular, design: .monospaced)

    // MARK: 行距换算

    /// 把规范里的「行高」换算为 SwiftUI 的 `lineSpacing`。
    public static func lineSpacing(lineHeight: CGFloat, fontSize: CGFloat) -> CGFloat {
        max(0, lineHeight - fontSize * 1.2)
    }

    public static let bodyLineSpacing = lineSpacing(lineHeight: LineHeight.body, fontSize: Size.body)
    public static let displayLineSpacing = lineSpacing(lineHeight: LineHeight.display, fontSize: Size.display)
    public static let titleLineSpacing = lineSpacing(lineHeight: LineHeight.title, fontSize: Size.title)
    public static let captionLineSpacing = lineSpacing(lineHeight: LineHeight.caption, fontSize: Size.caption)

    /// 分组标题(全大写时字距 +0.4;中文标题不加字距)。
    public static let groupTitleTracking: CGFloat = 0.4
}

// MARK: - 便捷修饰符

public extension View {
    /// 应用正文排版(15/22)。
    func ordoBodyText() -> some View {
        font(OrdoFont.body)
            .lineSpacing(OrdoFont.bodyLineSpacing)
    }

    /// 应用元信息排版(13/18)。
    func ordoCaptionText() -> some View {
        font(OrdoFont.caption)
            .lineSpacing(OrdoFont.captionLineSpacing)
    }
}
