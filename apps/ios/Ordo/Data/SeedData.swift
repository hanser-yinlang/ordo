//
//  SeedData.swift
//  Ordo
//
//  iOS 端只保留**设备本地**的示例数据与日期工具:
//    · 今日日程(契约 §2.8:CalendarEvent 只读、设备本地、不参与同步);
//    · 日期平移工具(排期面板/测试使用)。
//
//  ⚠️ 示例待办/项目/区域/标签**不在本文件** —— 演示数据由 KMP 核心的
//     `OrdoEngine.seedDemoData(force:)`(shared/core/.../seed/SeedData.kt)提供,
//     保证四端示例数据完全一致,避免在 Swift 侧重复实现一份。
//

import Foundation

public enum OrdoSeedData {

    /// 今日日程(设备本地只读;契约 §2.8)。
    public static func calendarEvents(
        today: String = OrdoDateFormatter.shared.today(),
        calendar: Calendar = .current
    ) -> [OrdoCalendarEvent] {
        let formatter = OrdoDateFormatter.shared
        guard let day = formatter.date(fromISO: today) else { return [] }
        let specs: [(String, Int, Int, String)] = [
            ("产品评审会", 10, 0, "工作"),
            ("与设计师 1:1", 14, 30, "工作"),
            ("健身", 19, 0, "个人")
        ]
        return specs.enumerated().compactMap { offset, spec in
            guard let start = calendar.date(byAdding: .minute, value: spec.1 * 60 + spec.2, to: day) else { return nil }
            let end = calendar.date(byAdding: .minute, value: 45, to: start) ?? start
            return OrdoCalendarEvent(
                id: "e\(offset + 1)",
                title: spec.0,
                start: start,
                end: end,
                calendar: spec.3,
                allDay: false
            )
        }
    }

    /// 把 `YYYY-MM-DD` 平移若干天(负数为过去)。
    public static func shift(_ isoDay: String, by days: Int, calendar: Calendar = .current) -> String {
        let formatter = OrdoDateFormatter.shared
        guard let date = formatter.date(fromISO: isoDay),
              let shifted = calendar.date(byAdding: .day, value: days, to: date) else {
            return isoDay
        }
        return formatter.isoDay(shifted)
    }
}
