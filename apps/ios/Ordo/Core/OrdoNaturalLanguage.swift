//
//  OrdoNaturalLanguage.swift
//  Ordo
//
//  契约 §5(NLP v1)在 Swift 侧的类型与协议。
//  规则实现**不在 Swift 中重复**——由 KMP `NaturalDateParser` 提供,
//  `OrdoCoreBridge`/`OrdoCoreNaturalLanguageParser` 负责桥接。
//
//  用途:
//  - 快加号(QuickAdd)与排期面板(ScheduleSheet)的输入实时预览;
//  - 单元测试通过 `OrdoNaturalLanguageParser` 断言契约 §5 的每一条规则。
//

import Foundation

/// 契约 §5 的输出:`{ cleanTitle, when, date, reminder, tags }`。
public struct OrdoParsedInput: Hashable, Sendable {
    public var cleanTitle: String
    public var when: OrdoWhen?
    public var date: String?
    public var reminder: String?
    public var tags: [String]

    public init(
        cleanTitle: String,
        when: OrdoWhen? = nil,
        date: String? = nil,
        reminder: String? = nil,
        tags: [String] = []
    ) {
        self.cleanTitle = cleanTitle
        self.when = when
        self.date = date
        self.reminder = reminder
        self.tags = tags
    }

    /// 输入中是否解析出了任何结构化信息。
    public var hasStructuredContent: Bool {
        when != nil || date != nil || reminder != nil || !tags.isEmpty
    }

    /// 供输入框下方做实时提示,例如「明天 · 18:00 · #重要」。
    public func hint(using formatter: OrdoDateFormatting = OrdoDateFormatter.shared) -> String? {
        var parts: [String] = []
        if let date, when == .date {
            parts.append(formatter.dayLabel(date))
        } else if let when {
            switch when {
            case .today: parts.append("今天")
            case .evening: parts.append("今晚")
            case .someday: parts.append("某天")
            case .anytime: parts.append("随时")
            case .inbox: parts.append("收件箱")
            case .date: break
            }
        }
        if let reminder, reminder.count >= 16 {
            parts.append(String(reminder.suffix(5)))
        }
        if !tags.isEmpty {
            parts.append(tags.map { "#\($0)" }.joined(separator: " "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 契约 §5 的解析入口。
public protocol OrdoNaturalLanguageParser: Sendable {
    /// - Parameters:
    ///   - input: 用户输入原文。
    ///   - today: `YYYY-MM-DD`。
    ///   - now: `YYYY-MM-DDTHH:mm`(本地时区)。
    func parse(_ input: String, today: String, now: String) -> OrdoParsedInput
}

public extension OrdoNaturalLanguageParser {
    /// 便捷重载:自动取当前日期与时刻。
    func parse(_ input: String, clock: OrdoClock = OrdoSystemClock()) -> OrdoParsedInput {
        let now = Date(timeIntervalSince1970: Double(clock.now()) / 1000)
        let formatter = OrdoDateFormatter.shared
        return parse(input, today: formatter.isoDay(now), now: formatter.isoDayTime(now))
    }
}

/// 测试与预览用的最小实现:仅按 `#标签` 切分,不做日期解析。
/// **不要**用它替代 KMP 解析器,它只服务于「无核心依赖」的 UI 预览路径。
public struct OrdoTagOnlyParser: OrdoNaturalLanguageParser {
    public init() {}

    public func parse(_ input: String, today: String, now: String) -> OrdoParsedInput {
        var tags: [String] = []
        var remaining = input
        while let range = remaining.range(of: "#") {
            let tail = remaining[range.upperBound...]
            let name = tail.prefix { !$0.isWhitespace && $0 != "#" }
            if !name.isEmpty {
                tags.append(String(name))
                remaining.removeSubrange(range.lowerBound..<remaining.index(range.upperBound, offsetBy: name.count))
            } else {
                remaining.removeSubrange(range)
                break
            }
        }
        let cleaned = remaining
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,，、:：-"))
        return OrdoParsedInput(cleanTitle: cleaned, tags: tags)
    }
}
