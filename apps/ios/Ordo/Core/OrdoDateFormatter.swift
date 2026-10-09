//
//  OrdoDateFormatter.swift
//  Ordo
//
//  契约 §2 的日期格式常量与展示格式化。
//
//  格式(四端一致):
//    日期      `YYYY-MM-DD`
//    日期时间  `YYYY-MM-DDTHH:mm`(本地时区,不带秒)
//  本文件只做**展示层**格式化(标题、元信息 pill、分组标题),
//  任何业务判定(是否逾期、是否落在 Upcoming 窗口)由 KMP 核心给出。
//

import Foundation

public protocol OrdoDateFormatting: Sendable {
    /// `YYYY-MM-DD`
    func isoDay(_ date: Date) -> String
    /// `YYYY-MM-DDTHH:mm`
    func isoDayTime(_ date: Date) -> String
    /// 解析 `YYYY-MM-DD`
    func date(fromISO day: String) -> Date?
    /// 解析 `YYYY-MM-DDTHH:mm`
    func dateTime(fromISO value: String) -> Date?
    /// 「今天」= `YYYY-MM-DD`
    func today() -> String
    /// 「现在」= `YYYY-MM-DDTHH:mm`
    func nowDayTime() -> String
    /// 「今天 · 周三」/「明天 · 周四」/「10月9日 · 周五」
    func dayLabel(_ iso: String) -> String
    /// 「今天」/「明天」/「昨天」/「10月9日」
    func shortDate(_ iso: String) -> String
    /// 「10月9日」
    func monthDay(_ iso: String) -> String
    /// 「周三」
    func weekday(_ iso: String) -> String
    /// 「18:00」
    func timeLabel(_ isoDateTime: String) -> String
    /// 提醒 pill:「18:00」(今天)/「明天 09:30」/「10月9日 18:00」
    func reminderLabel(_ isoDateTime: String) -> String
    /// 相对天数:正数表示未来,负数表示过去。
    func dayOffset(_ iso: String) -> Int?
}

/// 线程安全的展示格式化器。
/// `DateFormatter` 非 `Sendable`,这里用锁缓存实例并标记 `@unchecked Sendable`
/// (所有可变状态都在锁内访问)。
public final class OrdoDateFormatter: OrdoDateFormatting, @unchecked Sendable {

    public static let shared = OrdoDateFormatter()

    private let lock = NSLock()
    private var dayFormatter: DateFormatter?
    private var dayTimeFormatter: DateFormatter?
    private let calendar: Calendar

    /// 中文星期(与系统区域无关,保证四端文案一致)。
    private static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: 基础格式

    private func cachedDayFormatter() -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let dayFormatter { return dayFormatter }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        dayFormatter = formatter
        return formatter
    }

    private func cachedDayTimeFormatter() -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let dayTimeFormatter { return dayTimeFormatter }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        dayTimeFormatter = formatter
        return formatter
    }

    public func isoDay(_ date: Date) -> String {
        cachedDayFormatter().string(from: date)
    }

    public func isoDayTime(_ date: Date) -> String {
        cachedDayTimeFormatter().string(from: date)
    }

    public func date(fromISO day: String) -> Date? {
        cachedDayFormatter().date(from: String(day.prefix(10)))
    }

    public func dateTime(fromISO value: String) -> Date? {
        cachedDayTimeFormatter().date(from: String(value.prefix(16)))
    }

    public func today() -> String { isoDay(Date()) }

    public func nowDayTime() -> String { isoDayTime(Date()) }

    // MARK: 展示

    public func dayOffset(_ iso: String) -> Int? {
        guard let date = date(fromISO: iso) else { return nil }
        let start = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: Date())
        return calendar.dateComponents([.day], from: today, to: start).day
    }

    public func weekday(_ iso: String) -> String {
        guard let date = date(fromISO: iso) else { return "" }
        let index = calendar.component(.weekday, from: date) - 1
        guard index >= 0 && index < Self.weekdayNames.count else { return "" }
        return Self.weekdayNames[index]
    }

    public func monthDay(_ iso: String) -> String {
        guard let date = date(fromISO: iso) else { return iso }
        let components = calendar.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)月\(components.day ?? 0)日"
    }

    public func shortDate(_ iso: String) -> String {
        switch dayOffset(iso) {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        case -1: return "昨天"
        default: return monthDay(iso)
        }
    }

    public func dayLabel(_ iso: String) -> String {
        let weekdayText = weekday(iso)
        let prefix: String
        switch dayOffset(iso) {
        case 0: prefix = "今天"
        case 1: prefix = "明天"
        case 2: prefix = "后天"
        case -1: prefix = "昨天"
        default:
            let year = calendar.component(.year, from: date(fromISO: iso) ?? Date())
            let currentYear = calendar.component(.year, from: Date())
            prefix = year == currentYear ? monthDay(iso) : "\(year)年\(monthDay(iso))"
        }
        return weekdayText.isEmpty ? prefix : "\(prefix) · \(weekdayText)"
    }

    public func timeLabel(_ isoDateTime: String) -> String {
        guard isoDateTime.count >= 16 else { return "" }
        return String(isoDateTime.suffix(5))
    }

    public func reminderLabel(_ isoDateTime: String) -> String {
        guard isoDateTime.count >= 16 else { return isoDateTime }
        let day = String(isoDateTime.prefix(10))
        let time = timeLabel(isoDateTime)
        let offset = dayOffset(day)
        if offset == 0 { return time }
        return "\(shortDate(day)) \(time)"
    }
}
