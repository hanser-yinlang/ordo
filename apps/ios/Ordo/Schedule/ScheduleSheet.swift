//
//  ScheduleSheet.swift
//  Ordo
//
//  排期面板(设计规范 §1.2「Schedule Sheet」/ §4「排期面板」)。
//
//  规格:浮层宽 280;上部自然语言输入,中部快捷项(今天 / 今晚 / 明天 / 本周末 / 某天),
//        下部月历,底部危险色「清除」。本实现把「提醒」也并入同一面板 ——
//        命名主张是「一处完成何时做 / 何时提醒」(§1.2)。
//
//  自然语言解析来自 KMP `NaturalDateParser`(契约 §5),Swift 侧不重复实现规则。
//

import SwiftUI

public struct ScheduleSheet: View {

    public enum Mode: String, Sendable {
        case when
        case deadline

        var title: String { self == .when ? "排期" : "截止日期" }
        var clearTitle: String { self == .when ? "清除排期" : "清除截止日期" }
    }

    private let shell: ShellViewModel
    private let environment: AppEnvironment
    private let todoId: String
    private let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var month: Date = Date()
    @State private var reminderTime: Date = Date()

    public init(shell: ShellViewModel, environment: AppEnvironment, todoId: String, mode: Mode) {
        self.shell = shell
        self.environment = environment
        self.todoId = todoId
        self.mode = mode
    }

    private var todo: OrdoTodo? { environment.snapshot.todo(id: todoId) }

    private var formatter: OrdoDateFormatter { OrdoDateFormatter.shared }

    private var parsed: OrdoParsedInput {
        environment.parser.parse(
            input,
            today: formatter.today(),
            now: formatter.nowDayTime()
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OrdoSpacing.m) {
                Text(mode.title)
                    .font(OrdoFont.title)
                    .foregroundStyle(OrdoColor.textPrimary)

                if let todo {
                    Text(todo.title)
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textSecondary)
                        .lineLimit(2)
                }

                naturalLanguageField
                quickActions

                if mode == .when {
                    reminderSection
                }

                Divider().overlay(OrdoColor.hairline)

                calendar

                Divider().overlay(OrdoColor.hairline)

                Button {
                    clear()
                } label: {
                    Label(mode.clearTitle, systemImage: "xmark.circle")
                        .font(OrdoFont.body)
                        .foregroundStyle(OrdoColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, OrdoSpacing.s)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.clearTitle)
            }
            .padding(OrdoSpacing.l)
            .frame(maxWidth: OrdoSpacing.schedulePopoverWidth + OrdoSpacing.xxl)
            .frame(maxWidth: .infinity)
        }
        .background(OrdoColor.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if let date = todo?.date, let parsedDate = formatter.date(fromISO: date) {
                month = parsedDate
            }
            if let reminder = todo?.reminder, let date = formatter.dateTime(fromISO: reminder) {
                reminderTime = date
            }
        }
    }

    // MARK: 自然语言输入

    private var naturalLanguageField: some View {
        VStack(alignment: .leading, spacing: OrdoSpacing.xs) {
            HStack(spacing: OrdoSpacing.s) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 13))
                    .foregroundStyle(OrdoColor.textSecondary)
                TextField("试试「明天」「周五」「18:00」「下周一」", text: $input)
                    .font(OrdoFont.body)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .onSubmit { applyNaturalLanguage() }
                    .accessibilityLabel("自然语言排期")
            }
            .padding(.horizontal, OrdoSpacing.m)
            .padding(.vertical, OrdoSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: OrdoRadius.field, style: .continuous)
                    .fill(OrdoColor.canvas)
            )

            if let hint = parsed.hint(using: formatter), !input.isEmpty {
                HStack(spacing: OrdoSpacing.s) {
                    Text("识别为:\(hint)")
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.accent)
                    Spacer()
                    Button("应用") { applyNaturalLanguage() }
                        .font(OrdoFont.captionEmphasis)
                        .foregroundStyle(OrdoColor.accent)
                        .buttonStyle(.plain)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: 快捷项

    private var quickActions: some View {
        VStack(spacing: 0) {
            quickRow("今天", systemImage: "star", detail: formatter.monthDay(formatter.today())) {
                setWhen(.today)
            }
            quickRow("今晚", systemImage: "moon.stars", detail: nil) {
                setWhen(.evening)
            }
            quickRow("明天", systemImage: "calendar", detail: formatter.monthDay(OrdoSeedData.shift(formatter.today(), by: 1))) {
                setWhen(.date, date: OrdoSeedData.shift(formatter.today(), by: 1))
            }
            quickRow("本周末", systemImage: "calendar.badge.clock", detail: nil) {
                setWhen(.date, date: nextWeekendISO())
            }
            quickRow("某天", systemImage: "archivebox", detail: nil) {
                setWhen(.someday)
            }
        }
    }

    private func quickRow(_ title: String, systemImage: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: OrdoSpacing.s) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(OrdoColor.textSecondary)
                Text(title)
                    .font(OrdoFont.body)
                    .foregroundStyle(OrdoColor.textPrimary)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textSecondary)
                }
            }
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: 提醒

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: OrdoSpacing.s) {
            Text("提醒")
                .font(OrdoFont.micro)
                .tracking(OrdoFont.groupTitleTracking)
                .foregroundStyle(OrdoColor.textSecondary)

            DatePicker("提醒时间", selection: $reminderTime, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
                .onChange(of: reminderTime) { _, newValue in
                    environment.setReminder(id: todoId, reminder: formatter.isoDayTime(newValue))
                }

            HStack(spacing: OrdoSpacing.s) {
                smallButton("今天 09:00") { setReminder(hour: 9, dayOffset: 0) }
                smallButton("今天 18:00") { setReminder(hour: 18, dayOffset: 0) }
                smallButton("明天 09:00") { setReminder(hour: 9, dayOffset: 1) }
            }

            if todo?.reminder != nil {
                Button("清除提醒") {
                    environment.setReminder(id: todoId, reminder: nil)
                }
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.danger)
                .buttonStyle(.plain)
                .accessibilityLabel("清除提醒")
            }
        }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.accent)
                .padding(.horizontal, OrdoSpacing.s)
                .padding(.vertical, OrdoSpacing.xs)
                .background(Capsule(style: .continuous).fill(OrdoColor.chipBackground))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: 月历

    private var calendar: some View {
        VStack(alignment: .leading, spacing: OrdoSpacing.s) {
            HStack {
                Button {
                    shiftMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OrdoColor.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("上个月")

                Spacer()

                Text(monthTitle)
                    .font(OrdoFont.captionEmphasis)
                    .foregroundStyle(OrdoColor.textPrimary)

                Spacer()

                Button {
                    shiftMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OrdoColor.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("下个月")
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in
                    Text(day)
                        .font(OrdoFont.micro)
                        .foregroundStyle(OrdoColor.textTertiary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 32)
                    }
                }
            }
        }
    }

    private func dayCell(_ iso: String) -> some View {
        let isToday = iso == formatter.today()
        let isSelected = selectedDate == iso
        return Button {
            select(iso)
        } label: {
            Text("\(Int(iso.suffix(2)) ?? 0)")
                .font(OrdoFont.caption)
                .monospacedDigit()
                .foregroundStyle(isSelected ? .white : (isToday ? OrdoColor.accent : OrdoColor.textPrimary))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: OrdoRadius.row, style: .continuous)
                        .fill(isSelected ? OrdoColor.accent : (isToday ? OrdoColor.selectionFill : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(formatter.monthDay(iso))\(isToday ? ",今天" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: 计算

    private var monthTitle: String {
        let components = Calendar.current.dateComponents([.year, .month], from: month)
        return "\(components.year ?? 0) 年 \(components.month ?? 0) 月"
    }

    /// 返回当月每一天的 ISO 串,前置补 nil 以对齐星期。
    private var monthDays: [String?] {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else {
            return []
        }
        let weekday = calendar.component(.weekday, from: firstDay) - 1
        let components = calendar.dateComponents([.year, .month], from: month)
        var result: [String?] = Array(repeating: nil, count: max(0, weekday))
        for day in range {
            let iso = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, day)
            result.append(iso)
        }
        return result
    }

    private var selectedDate: String? {
        switch mode {
        case .when:
            guard let todo, todo.when == .date else { return nil }
            return todo.date
        case .deadline:
            return todo?.deadline
        }
    }

    // MARK: 动作

    private func setWhen(_ when: OrdoWhen, date: String? = nil) {
        environment.setWhen(id: todoId, when: when, date: date)
        dismiss()
    }

    private func select(_ iso: String) {
        if mode == .deadline {
            environment.setDeadline(id: todoId, date: iso)
        } else {
            environment.setWhen(id: todoId, when: .date, date: iso)
        }
        dismiss()
    }

    private func clear() {
        switch mode {
        case .when:
            environment.setWhen(id: todoId, when: .anytime, date: nil)
            environment.setDeadline(id: todoId, date: nil)
            environment.setReminder(id: todoId, reminder: nil)
        case .deadline:
            environment.setDeadline(id: todoId, date: nil)
        }
        dismiss()
    }

    private func applyNaturalLanguage() {
        let result = parsed
        guard result.hasStructuredContent else {
            environment.toast("没能识别出日期,试试「明天」或「10月9日」", kind: .failure)
            return
        }
        if mode == .deadline {
            let date = result.date ?? (result.when == .today ? formatter.today() : nil)
            guard let date else {
                environment.toast("截止日期需要一个具体日期", kind: .failure)
                return
            }
            environment.setDeadline(id: todoId, date: date)
        } else {
            if let when = result.when {
                environment.setWhen(id: todoId, when: when, date: result.date)
            } else if let date = result.date {
                environment.setWhen(id: todoId, when: .date, date: date)
            }
            if let reminder = result.reminder {
                environment.setReminder(id: todoId, reminder: reminder)
            }
        }
        dismiss()
    }

    private func setReminder(hour: Int, dayOffset: Int) {
        let day = OrdoSeedData.shift(formatter.today(), by: dayOffset)
        environment.setReminder(id: todoId, reminder: String(format: "%@T%02d:00", day, hour))
    }

    private func nextWeekendISO() -> String {
        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        // 最近的周六(weekday: 7 = 周六)
        var delta = (7 - weekday + 7) % 7
        if delta == 0 { delta = 7 }
        return OrdoSeedData.shift(formatter.today(), by: delta)
    }

    private func shiftMonth(by value: Int) {
        if let newMonth = Calendar.current.date(byAdding: .month, value: value, to: month) {
            month = newMonth
        }
    }
}
