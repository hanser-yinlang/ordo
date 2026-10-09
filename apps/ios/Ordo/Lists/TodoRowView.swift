//
//  TodoRowView.swift
//  Ordo
//
//  待办行(设计规范 §3 布局 / §4 组件规格 / §5 完成动效)。
//
//  规格:行高 38;左侧复选框 20×20 圆形;标题 15/22;元信息行 13/18(gap 6);
//        悬浮显示行内「排期(日历)」「截止(旗标)」按钮;圆角 10。
//
//  完成动效严格按 §5 时序推进(0/80/160/240/700/900ms),数据变更在 80ms 时发生,
//  行本身由 `ListScreenView` 的「保留行」机制继续渲染,直到 900ms 动画结束才移除。
//

import SwiftUI

public struct TodoRowView: View {

    public var todo: OrdoTodo
    public var isExpanded: Bool
    public var isHighlighted: Bool
    public var isCompleting: Bool
    public var projectName: String?
    public var tagColor: (String) -> String?
    /// 触发完成(数据变更,发生在动画 80ms 处)。
    public var onToggleDone: () -> Void
    /// 动画全部结束(900ms),用于把保留行移出列表。
    public var onCompletionFinished: () -> Void
    public var onToggleExpand: () -> Void
    public var onSchedule: () -> Void
    public var onDeadline: () -> Void
    public var onTagTap: (String) -> Void
    public var onRestore: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage: OrdoCompletionStage = .idle
    @State private var isHovering = false

    public init(
        todo: OrdoTodo,
        isExpanded: Bool = false,
        isHighlighted: Bool = false,
        isCompleting: Bool = false,
        projectName: String? = nil,
        tagColor: @escaping (String) -> String? = { _ in nil },
        onToggleDone: @escaping () -> Void,
        onCompletionFinished: @escaping () -> Void = {},
        onToggleExpand: @escaping () -> Void,
        onSchedule: @escaping () -> Void,
        onDeadline: @escaping () -> Void,
        onTagTap: @escaping (String) -> Void = { _ in },
        onRestore: (() -> Void)? = nil
    ) {
        self.todo = todo
        self.isExpanded = isExpanded
        self.isHighlighted = isHighlighted
        self.isCompleting = isCompleting
        self.projectName = projectName
        self.tagColor = tagColor
        self.onToggleDone = onToggleDone
        self.onCompletionFinished = onCompletionFinished
        self.onToggleExpand = onToggleExpand
        self.onSchedule = onSchedule
        self.onDeadline = onDeadline
        self.onTagTap = onTagTap
        self.onRestore = onRestore
    }

    private var formatter: OrdoDateFormatter { OrdoDateFormatter.shared }

    private var isClosed: Bool { todo.status != .open }

    public var body: some View {
        HStack(alignment: .top, spacing: OrdoSpacing.s) {
            CheckboxView(status: todo.status, stage: stage) {
                beginToggle()
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title)
                    .font(OrdoFont.body)
                    .foregroundStyle(titleColor)
                    .strikethrough(isClosed || stage >= .dimmed, color: OrdoColor.textTertiary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                if !notePreview.isEmpty {
                    Text(notePreview)
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textSecondary)
                        .lineLimit(1)
                }

                OrdoTodoMetaRow(
                    todo: todo,
                    showsWhen: showsWhenPill,
                    showsCompletion: isClosed,
                    tagColor: tagColor,
                    onTagTap: onTagTap
                )
                .padding(.top, metaTopPadding)
            }
            .padding(.vertical, verticalPadding)

            Spacer(minLength: OrdoSpacing.xs)

            rowActions
        }
        .padding(.horizontal, OrdoSpacing.m)
        .frame(minHeight: OrdoSpacing.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: OrdoRadius.row, style: .continuous)
                .fill(backgroundFill)
        )
        .contentShape(Rectangle())
        .onTapGesture { onToggleExpand() }
        .onHover { isHovering = $0 }
        .opacity(rowOpacity)
        .animation(reduceMotion ? nil : OrdoMotion.standard, value: isHighlighted)
        .animation(reduceMotion ? nil : OrdoMotion.standard, value: isExpanded)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("双击展开详情")
        .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
    }

    // MARK: 外观

    private var titleColor: Color {
        if isClosed || stage >= .dimmed { return OrdoColor.textTertiary }
        return OrdoColor.textPrimary
    }

    private var backgroundFill: Color {
        if isExpanded { return OrdoColor.selectionFill.opacity(0.6) }
        if isHighlighted { return OrdoColor.selectionFill }
        if isHovering { return OrdoColor.rowHover }
        return Color.clear
    }

    private var rowOpacity: Double {
        if stage >= .collapsing { return 0 }
        if isClosed || stage >= .dimmed { return OrdoMotion.Completion.dimmedOpacity }
        return 1
    }

    private var notePreview: String {
        MarkdownNoteView.plainPreview(todo.note)
    }

    private var verticalPadding: CGFloat {
        notePreview.isEmpty && todo.tags.isEmpty && todo.checklist.isEmpty ? 7 : 6
    }

    private var metaTopPadding: CGFloat {
        (notePreview.isEmpty ? 2 : 4)
    }

    /// 固定清单里显示「何时」pill;项目/标签视图里也显示,便于判断排期。
    private var showsWhenPill: Bool {
        switch todo.when {
        case .today, .evening, .date: return true
        case .inbox, .anytime, .someday: return false
        }
    }

    @ViewBuilder
    private var rowActions: some View {
        HStack(spacing: OrdoSpacing.xs) {
            if let onRestore, isClosed {
                Button(action: onRestore) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(OrdoColor.textSecondary)
                .frame(width: 28, height: 28)
                .accessibilityLabel("恢复为未完成")
            }

            Button(action: onSchedule) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(OrdoColor.textSecondary)
            .frame(width: 28, height: 28)
            .accessibilityLabel("排期")

            Button(action: onDeadline) {
                Image(systemName: "flag")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(OrdoColor.textSecondary)
            .frame(width: 28, height: 28)
            .accessibilityLabel("设置截止日期")
        }
        .opacity(isHovering || isHighlighted || isExpanded ? 1 : 0.001)
        .animation(reduceMotion ? nil : OrdoMotion.fastEase, value: isHovering)
    }

    private var accessibilityLabel: String {
        var parts: [String] = [todo.title]
        parts.append(todo.status == .open ? "未完成" : (todo.status == .done ? "已完成" : "已取消"))
        if let projectName { parts.append("项目 \(projectName)") }
        if let deadline = todo.deadline { parts.append("截止 \(formatter.shortDate(deadline))") }
        if let reminder = todo.reminder { parts.append("提醒 \(formatter.reminderLabel(reminder))") }
        if !todo.tags.isEmpty { parts.append("标签 \(todo.tags.joined(separator: "、"))") }
        return parts.joined(separator: ",")
    }

    // MARK: 完成动效(规范 §5)

    private func beginToggle() {
        // 已完成 → 取消完成(立即恢复,不需要收起动画)
        guard todo.status == .open else {
            onToggleDone()
            return
        }
        guard !isCompleting, stage == .idle else { return }

        if reduceMotion {
            // 规范 §5/§8:开启「减弱动态效果」时动效降为 0ms,直接切换。
            onToggleDone()
            onCompletionFinished()
            return
        }

        Task { @MainActor in
            // 0ms:按压
            stage = .pressing
            try? await Task.sleep(nanoseconds: 80_000_000)
            // 80ms:圆圈填充 + 数据变更(引擎写库,行由保留机制继续渲染)
            stage = .filling
            onToggleDone()
            try? await Task.sleep(nanoseconds: 80_000_000)
            // 160ms:对勾描边
            stage = .checking
            try? await Task.sleep(nanoseconds: 80_000_000)
            // 240ms:标题弱化 + 行透明度 0.72
            stage = .dimmed
            try? await Task.sleep(nanoseconds: 460_000_000)
            // 700ms:行收起(180ms ease-in)
            stage = .collapsing
            try? await Task.sleep(nanoseconds: 200_000_000)
            // 900ms:动画结束,从列表移除
            stage = .idle
            onCompletionFinished()
        }
    }
}
