//
//  MarkdownNoteView.swift
//  Ordo
//
//  备注的轻量 Markdown 渲染(设计规范 §4「详情卡片」:备注 Markdown 预览)。
//
//  支持子集(与 Web 原型一致,契约未规定语法细节):
//    `# 标题` / `## 标题`      → 加粗标题行
//    `- 列表` / `1. 列表`      → 项目符号行
//    `**加粗**`               → 加粗
//    `` `代码` ``             → 等宽 + 底色
//    `[文字](链接)`            → 可点击链接
//    `> 引用`                 → 次要色斜体
//  其余按普通段落处理。实现刻意保持简单:不引入第三方依赖,不做 HTML 注入。
//

import SwiftUI

public struct MarkdownNoteView: View {

    public var text: String
    public var lineLimit: Int?

    public init(text: String, lineLimit: Int? = nil) {
        self.text = text
        self.lineLimit = lineLimit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OrdoSpacing.xs) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let content):
            inlineText(content)
                .font(level <= 1 ? OrdoFont.bodyEmphasis : OrdoFont.captionEmphasis)
                .foregroundStyle(OrdoColor.textPrimary)
                .padding(.top, level <= 1 ? OrdoSpacing.xs : 0)
        case .bullet(let content):
            HStack(alignment: .firstTextBaseline, spacing: OrdoSpacing.s) {
                Text("•")
                    .font(OrdoFont.body)
                    .foregroundStyle(OrdoColor.textSecondary)
                inlineText(content)
                    .font(OrdoFont.body)
                    .foregroundStyle(OrdoColor.textPrimary)
            }
        case .ordered(let index, let content):
            HStack(alignment: .firstTextBaseline, spacing: OrdoSpacing.s) {
                Text("\(index).")
                    .font(OrdoFont.caption)
                    .foregroundStyle(OrdoColor.textSecondary)
                    .monospacedDigit()
                inlineText(content)
                    .font(OrdoFont.body)
                    .foregroundStyle(OrdoColor.textPrimary)
            }
        case .quote(let content):
            HStack(alignment: .top, spacing: OrdoSpacing.s) {
                Rectangle()
                    .fill(OrdoColor.hairline)
                    .frame(width: 2)
                inlineText(content)
                    .font(OrdoFont.body)
                    .foregroundStyle(OrdoColor.textSecondary)
                    .italic()
            }
        case .paragraph(let content):
            inlineText(content)
                .font(OrdoFont.body)
                .foregroundStyle(OrdoColor.textPrimary)
        }
    }

    private func inlineText(_ content: String) -> Text {
        var result = Text("")
        for token in Self.inlineTokens(content) {
            switch token {
            case .plain(let value):
                result = result + Text(value)
            case .bold(let value):
                result = result + Text(value).bold()
            case .code(let value):
                result = result + Text(value).font(OrdoFont.mono).foregroundColor(OrdoColor.accent)
            case .link(let label, _):
                result = result + Text(label).foregroundColor(OrdoColor.accent).underline()
            }
        }
        return result
    }

    // MARK: 解析

    enum Block {
        case heading(level: Int, content: String)
        case bullet(String)
        case ordered(index: Int, content: String)
        case quote(String)
        case paragraph(String)
    }

    enum InlineToken {
        case plain(String)
        case bold(String)
        case code(String)
        case link(label: String, url: String)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var orderCounter = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                orderCounter = 0
                continue
            }
            if line.hasPrefix("## ") {
                blocks.append(.heading(level: 2, content: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                blocks.append(.heading(level: 1, content: String(line.dropFirst(2))))
            } else if line.hasPrefix("> ") {
                blocks.append(.quote(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let match = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                orderCounter += 1
                blocks.append(.ordered(index: orderCounter, content: String(line[match.upperBound...])))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        return blocks
    }

    static func inlineTokens(_ text: String) -> [InlineToken] {
        var tokens: [InlineToken] = []
        var buffer = ""
        var index = text.startIndex

        func flushBuffer() {
            if !buffer.isEmpty {
                tokens.append(.plain(buffer))
                buffer = ""
            }
        }

        while index < text.endIndex {
            let character = text[index]
            if character == "*", text[index...].hasPrefix("**") {
                let afterOpen = text.index(index, offsetBy: 2)
                if let closing = text.range(of: "**", range: afterOpen..<text.endIndex) {
                    flushBuffer()
                    tokens.append(.bold(String(text[afterOpen..<closing.lowerBound])))
                    index = closing.upperBound
                    continue
                }
            }
            if character == "`" {
                let afterOpen = text.index(after: index)
                if let closing = text[afterOpen...].firstIndex(of: "`") {
                    flushBuffer()
                    tokens.append(.code(String(text[afterOpen..<closing])))
                    index = text.index(after: closing)
                    continue
                }
            }
            if character == "[" {
                let afterOpen = text.index(after: index)
                if let closingBracket = text[afterOpen...].firstIndex(of: "]"),
                   text.index(after: closingBracket) < text.endIndex,
                   text[text.index(after: closingBracket)] == "(",
                   let closingParen = text[text.index(after: closingBracket)...].firstIndex(of: ")") {
                    let label = String(text[afterOpen..<closingBracket])
                    let url = String(text[text.index(closingBracket, offsetBy: 2)..<closingParen])
                    flushBuffer()
                    tokens.append(.link(label: label, url: url))
                    index = text.index(after: closingParen)
                    continue
                }
            }
            buffer.append(character)
            index = text.index(after: index)
        }
        flushBuffer()
        return tokens
    }

    /// 纯文本单行预览(去掉 Markdown 记号,用于列表行的备注摘要)。
    public static func plainPreview(_ text: String, limit: Int = 90) -> String {
        let stripped = inlineTokens(text.replacingOccurrences(of: "\n", with: " "))
            .map { token -> String in
                switch token {
                case .plain(let value): return value
                case .bold(let value): return value
                case .code(let value): return value
                case .link(let label, _): return label
                }
            }
            .joined()
            .replacingOccurrences(of: #"^[#>\-\*\d\.\s]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return stripped.count > limit ? String(stripped.prefix(limit)) : stripped
    }
}
