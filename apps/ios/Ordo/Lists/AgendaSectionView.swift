//
//  AgendaSectionView.swift
//  Ordo
//
//  今日日程区块(设计规范 §3:只读日历事件)。
//
//  契约 §2.8:日历事件只读、设备本地、不参与同步。
//  视觉:左侧时间(13/18 等宽,次要色),中间 2px 强调竖条,右侧标题;
//        已过去的日程降低不透明度,但仍以文字表达状态(无障碍要求,规范 §8)。
//
//  数据来源由 `OrdoAgendaProviding` 决定(默认 EventKit 只读,权限被拒回退示例数据);
//  回退时在分区标题右侧标注「示例」,避免把示例日程误当成真实日程。
//

import SwiftUI

public struct AgendaSectionView: View {

    public var events: [OrdoCalendarEvent]
    public var now: Date
    /// 日程来源:`.sample` 时展示「示例」标记。
    public var source: OrdoAgendaSource

    public init(
        events: [OrdoCalendarEvent],
        now: Date = Date(),
        source: OrdoAgendaSource = .calendar
    ) {
        self.events = events
        self.now = now
        self.source = source
    }

    private var formatter: OrdoDateFormatter { OrdoDateFormatter.shared }

    public var body: some View {
        if events.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                GroupHeaderView(title: headerTitle, kind: .agenda, count: events.count)

                VStack(spacing: OrdoSpacing.xs) {
                    ForEach(sortedEvents) { event in
                        row(for: event)
                    }
                }
                .padding(.horizontal, OrdoSpacing.m)
                .padding(.bottom, OrdoSpacing.xs)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("今日日程")
        }
    }

    /// 无系统日历权限时明确标注「示例」,不让用户误以为读到了真实日历。
    private var headerTitle: String {
        source == .sample ? "日程 · 示例" : "日程"
    }

    private var sortedEvents: [OrdoCalendarEvent] {
        events.sorted { $0.start < $1.start }
    }

    private func row(for event: OrdoCalendarEvent) -> some View {
        let isPast = event.end < now
        return HStack(spacing: OrdoSpacing.s) {
            Text(formatter.timeLabel(formatter.isoDayTime(event.start)))
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.textSecondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(OrdoColor.accent.opacity(isPast ? 0.35 : 0.9))
                .frame(width: 2)

            Text(event.title)
                .font(OrdoFont.body)
                .foregroundStyle(isPast ? OrdoColor.textSecondary : OrdoColor.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if isPast {
                Text("已结束")
                    .font(OrdoFont.micro)
                    .foregroundStyle(OrdoColor.textTertiary)
            } else if let calendarName = event.calendar.isEmpty ? nil : event.calendar {
                Text(calendarName)
                    .font(OrdoFont.micro)
                    .foregroundStyle(OrdoColor.textTertiary)
            }
        }
        .padding(.vertical, 2)
        .frame(minHeight: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(formatter.timeLabel(formatter.isoDayTime(event.start))) \(event.title)\(isPast ? ",已结束" : "")")
    }
}
