//
//  MetaPillView.swift
//  Ordo
//
//  元信息 pill 与标签 chip(设计规范 §4)。
//
//  规格:
//    · 元信息 pill:图标 14 + 文字 13;提醒用铃铛;逾期/过期用 `state.danger`;清单进度 `2/5`。
//    · 标签 chip:高 20,内边距 6/2,圆角 pill,`chip.bg`;可点击进入标签视图。
//  无障碍(规范 §8):不仅靠颜色传达状态 —— 逾期同时有图标与文案。
//

import SwiftUI

public struct OrdoTagChip: View {
    public var name: String
    public var color: String?
    public var onTap: (() -> Void)?

    public init(name: String, color: String? = nil, onTap: (() -> Void)? = nil) {
        self.name = name
        self.color = color
        self.onTap = onTap
    }

    public var body: some View {
        Text(name)
            .font(OrdoFont.micro)
            .foregroundStyle(OrdoColor.chipText)
            .lineLimit(1)
            .padding(.horizontal, OrdoSpacing.chipHorizontalPadding)
            .padding(.vertical, OrdoSpacing.chipVerticalPadding)
            .frame(height: OrdoSpacing.chipHeight)
            .background(
                RoundedRectangle(cornerRadius: OrdoRadius.pill, style: .continuous)
                    .fill(OrdoColor.chipBackground)
            )
            .overlay(alignment: .leading) {
                if let color {
                    Circle()
                        .fill(OrdoColor.hex(color))
                        .frame(width: 6, height: 6)
                        .padding(.leading, OrdoSpacing.xs)
                        .opacity(0)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .accessibilityLabel("标签 \(name)")
            .accessibilityAddTraits(onTap == nil ? [] : [.isButton])
    }
}

public struct OrdoMetaPill: View {
    public var systemImage: String
    public var text: String?
    public var tint: Color
    public var emphasized: Bool
    public var accessibilityText: String?

    public init(
        systemImage: String,
        text: String? = nil,
        tint: Color = OrdoColor.textSecondary,
        emphasized: Bool = false,
        accessibilityText: String? = nil
    ) {
        self.systemImage = systemImage
        self.text = text
        self.tint = tint
        self.emphasized = emphasized
        self.accessibilityText = accessibilityText
    }

    public var body: some View {
        HStack(spacing: OrdoSpacing.xs) {
            Image(systemName: systemImage)
                .font(.system(size: OrdoSpacing.metaIconSize - 2, weight: .regular))
                .frame(width: OrdoSpacing.metaIconSize, height: OrdoSpacing.metaIconSize)
            if let text {
                Text(text)
                    .font(OrdoFont.caption)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, emphasized ? OrdoSpacing.xs : 0)
        .padding(.vertical, emphasized ? 1 : 0)
        .background(
            RoundedRectangle(cornerRadius: OrdoRadius.pill, style: .continuous)
                .fill(emphasized ? tint.opacity(0.12) : Color.clear)
        )
        .accessibilityLabel(accessibilityText ?? text ?? "")
    }
}

/// 一行待办的元信息集合(标签 / 清单进度 / 备注 / 重复 / 提醒 / 截止 / 完成时间)。
public struct OrdoTodoMetaRow: View {

    public var todo: OrdoTodo
    public var showsWhen: Bool
    public var showsCompletion: Bool
    public var tagColor: (String) -> String?
    public var onTagTap: (String) -> Void

    private let formatter = OrdoDateFormatter.shared

    public init(
        todo: OrdoTodo,
        showsWhen: Bool = false,
        showsCompletion: Bool = false,
        tagColor: @escaping (String) -> String? = { _ in nil },
        onTagTap: @escaping (String) -> Void = { _ in }
    ) {
        self.todo = todo
        self.showsWhen = showsWhen
        self.showsCompletion = showsCompletion
        self.tagColor = tagColor
        self.onTagTap = onTagTap
    }

    public var body: some View {
        HStack(spacing: OrdoSpacing.s) {
            if showsWhen {
                OrdoMetaPill(
                    systemImage: "calendar",
                    text: whenLabel,
                    accessibilityText: "何时:\(whenLabel)"
                )
            }

            ForEach(todo.tags, id: \.self) { tag in
                OrdoTagChip(name: tag, color: tagColor(tag)) { onTagTap(tag) }
            }

            if let progress = todo.checklistProgress {
                OrdoMetaPill(
                    systemImage: "checklist",
                    text: progress,
                    accessibilityText: "清单进度 \(progress)"
                )
            }

            if !todo.note.isEmpty {
                OrdoMetaPill(systemImage: "text.alignleft", accessibilityText: "含备注")
            }

            if todo.repeatRule != nil {
                OrdoMetaPill(systemImage: "repeat", accessibilityText: "重复待办")
            }

            if let reminder = todo.reminder, reminder.count >= 16 {
                let overdue = isReminderPast(reminder) && todo.status == .open
                OrdoMetaPill(
                    systemImage: "bell",
                    text: formatter.reminderLabel(reminder),
                    tint: overdue ? OrdoColor.danger : OrdoColor.textSecondary,
                    accessibilityText: overdue ? "提醒已过:\(formatter.reminderLabel(reminder))" : "提醒 \(formatter.reminderLabel(reminder))"
                )
            }

            if let deadline = todo.deadline {
                let overdue = deadline < formatter.today() && todo.status == .open
                OrdoMetaPill(
                    systemImage: overdue ? "exclamationmark.circle" : "flag",
                    text: formatter.shortDate(deadline),
                    tint: overdue ? OrdoColor.danger : OrdoColor.textSecondary,
                    accessibilityText: overdue ? "已逾期:\(formatter.shortDate(deadline))" : "截止 \(formatter.shortDate(deadline))"
                )
            }

            if showsCompletion, let completedAt = todo.completedAt {
                let day = formatter.isoDay(Date(timeIntervalSince1970: Double(completedAt) / 1000))
                OrdoMetaPill(
                    systemImage: "checkmark.circle",
                    text: "\(formatter.shortDate(day)) \(formatter.timeLabel(formatter.isoDayTime(Date(timeIntervalSince1970: Double(completedAt) / 1000))))",
                    accessibilityText: "完成于 \(formatter.shortDate(day))"
                )
            }
        }
    }

    private var whenLabel: String {
        switch todo.when {
        case .inbox: return "收件箱"
        case .today: return "今天"
        case .evening: return "今晚"
        case .anytime: return "随时"
        case .someday: return "某天"
        case .date: return todo.date.map { formatter.shortDate($0) } ?? "未定"
        }
    }

    private func isReminderPast(_ reminder: String) -> Bool {
        reminder < formatter.nowDayTime()
    }
}
