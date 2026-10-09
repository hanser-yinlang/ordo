//
//  TodoDetailView.swift
//  Ordo
//
//  详情卡片(设计规范 §4「详情卡片」)。
//
//  规格:白纸感,圆角 14,内边距 16;标题输入 20/26;备注 Markdown 预览;
//        字段区为可点胶囊按钮(何时 / 截止 / 提醒 / 重复 / 移动到 / 标签 / 清单)。
//
//  数据来源始终是 KMP 核心(`environment.snapshot`);本视图只持有输入草稿,
//  提交时通过 `environment.updateTodo(id:mutate:)` 回写。
//

import SwiftUI

public struct TodoDetailView: View {

    public var todoId: String
    private let shell: ShellViewModel
    private let environment: AppEnvironment
    /// 紧凑宽度(全屏详情页)下展示更大的内边距。
    public var isFullScreen: Bool

    @State private var draftTitle = ""
    @State private var draftNote = ""
    @State private var tagInput = ""
    @State private var checklistInput = ""
    @State private var isEditingNote = false
    @State private var lastLoadedId: String?

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title
        case note
        case tag
        case checklist
    }

    public init(todoId: String, shell: ShellViewModel, environment: AppEnvironment, isFullScreen: Bool = false) {
        self.todoId = todoId
        self.shell = shell
        self.environment = environment
        self.isFullScreen = isFullScreen
    }

    private var todo: OrdoTodo? { environment.snapshot.todo(id: todoId) }

    private var formatter: OrdoDateFormatter { OrdoDateFormatter.shared }

    public var body: some View {
        if let todo {
            card(todo)
                .task(id: todoId) { loadDrafts(from: todo) }
        } else {
            EmptyStateView(kind: .error("这条待办已不存在,可能已在其它设备上删除。"))
                .padding(OrdoSpacing.l)
        }
    }

    // MARK: 卡片

    private func card(_ todo: OrdoTodo) -> some View {
        VStack(alignment: .leading, spacing: OrdoSpacing.m) {
            titleField(todo)
            noteSection(todo)
            fieldButtons(todo)
            tagSection(todo)
            checklistSection(todo)
            footer(todo)
        }
        .padding(OrdoSpacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: OrdoRadius.card, style: .continuous)
                .fill(OrdoColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrdoRadius.card, style: .continuous)
                .stroke(OrdoColor.hairline, lineWidth: 1)
        )
        .ordoCardElevation()
        .padding(.horizontal, isFullScreen ? 0 : OrdoSpacing.s)
    }

    // MARK: 标题

    private func titleField(_ todo: OrdoTodo) -> some View {
        HStack(alignment: .top, spacing: OrdoSpacing.s) {
            CheckboxView(status: todo.status) {
                environment.toggleDone(id: todo.id)
                environment.rescheduleReminders()
            }
            .padding(.top, 2)

            TextField("标题", text: $draftTitle, axis: .vertical)
                .font(OrdoFont.title)
                .lineSpacing(OrdoFont.titleLineSpacing)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .title)
                .onSubmit { commitTitle() }
                .onChange(of: focusedField) { _, newValue in
                    if newValue != .title { commitTitle() }
                }
                .accessibilityLabel("待办标题")

            Spacer(minLength: 0)

            Button {
                shell.expandedTodoId = nil
                if isFullScreen { shell.compactDetailTodoId = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OrdoColor.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭详情")
        }
    }

    // MARK: 备注

    private func noteSection(_ todo: OrdoTodo) -> some View {
        VStack(alignment: .leading, spacing: OrdoSpacing.s) {
            if isEditingNote || draftNote.isEmpty {
                TextField("备注(支持 # 标题、- 列表、**加粗**、`代码`、[链接](地址))", text: $draftNote, axis: .vertical)
                    .font(OrdoFont.body)
                    .lineSpacing(OrdoFont.bodyLineSpacing)
                    .textFieldStyle(.plain)
                    .lineLimit(3...10)
                    .focused($focusedField, equals: .note)
                    .padding(OrdoSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: OrdoRadius.field, style: .continuous)
                            .fill(OrdoColor.canvas)
                    )
                    .accessibilityLabel("备注")
            }

            if !draftNote.isEmpty {
                VStack(alignment: .leading, spacing: OrdoSpacing.xs) {
                    MarkdownNoteView(text: draftNote)
                }
                .padding(OrdoSpacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: OrdoRadius.field, style: .continuous)
                        .fill(OrdoColor.canvas)
                )
            }

            HStack(spacing: OrdoSpacing.s) {
                Button(isEditingNote ? "完成编辑" : "编辑备注") {
                    if isEditingNote { commitNote() }
                    isEditingNote.toggle()
                }
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.accent)
                .buttonStyle(.plain)
                .accessibilityLabel(isEditingNote ? "完成备注编辑" : "编辑备注")

                Spacer(minLength: 0)

                if todo.note != draftNote {
                    Button("保存") { commitNote() }
                        .font(OrdoFont.captionEmphasis)
                        .foregroundStyle(OrdoColor.accent)
                        .buttonStyle(.plain)
                }
            }
        }
        .onChange(of: focusedField) { _, newValue in
            if newValue != .note { commitNote() }
        }
    }

    // MARK: 字段按钮

    private func fieldButtons(_ todo: OrdoTodo) -> some View {
        FlowingRow(spacing: OrdoSpacing.s, rowSpacing: OrdoSpacing.s) {
            fieldButton(
                systemImage: "calendar",
                text: whenText(todo),
                tint: isScheduledToday(todo) ? OrdoColor.accent : OrdoColor.textSecondary
            ) {
                shell.scheduleTarget = .when(todoId: todo.id)
            }

            fieldButton(
                systemImage: "flag",
                text: todo.deadline.map { "截止 " + formatter.shortDate($0) } ?? "截止日期",
                tint: isDeadlineOverdue(todo) ? OrdoColor.danger : OrdoColor.textSecondary
            ) {
                shell.scheduleTarget = .deadline(todoId: todo.id)
            }

            fieldButton(
                systemImage: "bell",
                text: todo.reminder.map { "提醒 " + formatter.reminderLabel($0) } ?? "提醒",
                tint: todo.reminder == nil ? OrdoColor.textSecondary : OrdoColor.accent
            ) {
                shell.scheduleTarget = .when(todoId: todo.id)
            }

            repeatMenu(todo)
            moveMenu(todo)
        }
    }

    private func fieldButton(
        systemImage: String,
        text: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: OrdoSpacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(text)
                    .font(OrdoFont.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, OrdoSpacing.m)
            .padding(.vertical, OrdoSpacing.xs + 2)
            .background(
                Capsule(style: .continuous)
                    .fill(OrdoColor.chipBackground)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
    }

    private func repeatMenu(_ todo: OrdoTodo) -> some View {
        Menu {
            Button("不重复") { setRepeat(todo, rule: nil) }
            Button("每天") { setRepeat(todo, rule: OrdoRepeatRule(freq: .daily)) }
            Button("每周") { setRepeat(todo, rule: OrdoRepeatRule(freq: .weekly)) }
            Button("每月") { setRepeat(todo, rule: OrdoRepeatRule(freq: .monthly)) }
            Button("每年") { setRepeat(todo, rule: OrdoRepeatRule(freq: .yearly)) }
            Divider()
            Button("基于原日期(fixed)") { setRepeatMode(todo, mode: .fixed) }
            Button("基于完成日(afterCompletion)") { setRepeatMode(todo, mode: .afterCompletion) }
        } label: {
            HStack(spacing: OrdoSpacing.xs) {
                Image(systemName: "repeat")
                    .font(.system(size: 12, weight: .medium))
                Text(repeatText(todo))
                    .font(OrdoFont.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(todo.repeatRule == nil ? OrdoColor.textSecondary : OrdoColor.accent)
            .padding(.horizontal, OrdoSpacing.m)
            .padding(.vertical, OrdoSpacing.xs + 2)
            .background(Capsule(style: .continuous).fill(OrdoColor.chipBackground))
        }
        .accessibilityLabel("重复设置")
    }

    private func moveMenu(_ todo: OrdoTodo) -> some View {
        Menu {
            Button("无项目") { environment.moveTodo(id: todo.id, projectId: nil, areaId: nil, headingId: nil) }
            ForEach(environment.snapshot.areas.filter { !$0.deleted }, id: \.id) { area in
                Section(area.name) {
                    Button("(直接放区域)") {
                        environment.moveTodo(id: todo.id, projectId: nil, areaId: area.id, headingId: nil)
                    }
                    ForEach(environment.snapshot.projects.filter { $0.areaId == area.id && !$0.deleted && $0.status == .open }, id: \.id) { project in
                        Button(project.name) {
                            environment.moveTodo(id: todo.id, projectId: project.id, areaId: area.id, headingId: nil)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: OrdoSpacing.xs) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .medium))
                Text(moveText(todo))
                    .font(OrdoFont.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(OrdoColor.textSecondary)
            .padding(.horizontal, OrdoSpacing.m)
            .padding(.vertical, OrdoSpacing.xs + 2)
            .background(Capsule(style: .continuous).fill(OrdoColor.chipBackground))
        }
        .accessibilityLabel("移动到")
    }

    // MARK: 标签

    private func tagSection(_ todo: OrdoTodo) -> some View {
        FlowingRow(spacing: OrdoSpacing.s, rowSpacing: OrdoSpacing.s) {
            ForEach(todo.tags, id: \.self) { tag in
                HStack(spacing: OrdoSpacing.xs) {
                    OrdoTagChip(name: tag, color: colorForTag(tag))
                    Button {
                        environment.removeTag(todoId: todo.id, tag: tag)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(OrdoColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除标签 \(tag)")
                }
            }

            HStack(spacing: OrdoSpacing.xs) {
                Image(systemName: "tag")
                    .font(.system(size: 12))
                    .foregroundStyle(OrdoColor.textSecondary)
                TextField("加标签", text: $tagInput)
                    .font(OrdoFont.caption)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 68)
                    .focused($focusedField, equals: .tag)
                    .onSubmit { commitTag(todo) }
                    .accessibilityLabel("添加标签")
            }
            .padding(.horizontal, OrdoSpacing.s)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(OrdoColor.canvas))
        }
    }

    // MARK: 清单

    private func checklistSection(_ todo: OrdoTodo) -> some View {
        VStack(alignment: .leading, spacing: OrdoSpacing.xs) {
            HStack {
                Text("清单")
                    .font(OrdoFont.micro)
                    .tracking(OrdoFont.groupTitleTracking)
                    .foregroundStyle(OrdoColor.textSecondary)
                if let progress = todo.checklistProgress {
                    Text(progress)
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textSecondary)
                        .monospacedDigit()
                }
                Spacer()
            }

            ForEach(todo.checklist) { item in
                HStack(spacing: OrdoSpacing.s) {
                    CheckboxView(status: item.done ? .done : .open, size: 16) {
                        environment.toggleChecklistItem(todoId: todo.id, itemId: item.id)
                    }
                    Text(item.title)
                        .font(OrdoFont.body)
                        .foregroundStyle(item.done ? OrdoColor.textTertiary : OrdoColor.textPrimary)
                        .strikethrough(item.done, color: OrdoColor.textTertiary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("清单项 \(item.title)")
            }

            HStack(spacing: OrdoSpacing.s) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(OrdoColor.accent)
                TextField("新清单项", text: $checklistInput)
                    .font(OrdoFont.body)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .checklist)
                    .onSubmit { commitChecklistItem(todo) }
                    .accessibilityLabel("新清单项")
            }
        }
    }

    // MARK: 底部

    private func footer(_ todo: OrdoTodo) -> some View {
        HStack(spacing: OrdoSpacing.s) {
            if let project = environment.snapshot.project(id: todo.projectId) {
                OrdoMetaPill(systemImage: "circle.dashed", text: project.name)
            } else if let area = environment.snapshot.area(id: todo.areaId) {
                OrdoMetaPill(systemImage: "square.grid.2x2", text: area.name)
            } else {
                OrdoMetaPill(systemImage: "tray", text: "收件箱")
            }

            Spacer(minLength: 0)

            Button {
                duplicate(todo)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13))
                    .foregroundStyle(OrdoColor.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("复制待办")

            Button {
                environment.deleteTodo(id: todo.id)
                shell.expandedTodoId = nil
                if isFullScreen { shell.compactDetailTodoId = nil }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(OrdoColor.danger)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除待办")
        }
    }

    // MARK: 草稿

    private func loadDrafts(from todo: OrdoTodo) {
        guard lastLoadedId != todo.id else { return }
        draftTitle = todo.title
        draftNote = todo.note
        lastLoadedId = todo.id
        isEditingNote = todo.note.isEmpty
    }

    private func commitTitle() {
        guard let todo, draftTitle != todo.title else { return }
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // 契约 §3:标题为空视为删除。
            environment.deleteTodo(id: todo.id)
            shell.expandedTodoId = nil
            return
        }
        environment.updateTodo(id: todo.id) { $0.title = trimmed }
    }

    private func commitNote() {
        guard let todo, draftNote != todo.note else { return }
        environment.updateTodo(id: todo.id) { $0.note = draftNote }
    }

    private func commitTag(_ todo: OrdoTodo) {
        let name = tagInput.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard !name.isEmpty else { return }
        environment.addTag(todoId: todo.id, tag: name)
        tagInput = ""
    }

    private func commitChecklistItem(_ todo: OrdoTodo) {
        let title = checklistInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard todo.checklist.count < 100 else {
            environment.toast("清单最多 100 项", kind: .failure)
            return
        }
        environment.addChecklistItem(todoId: todo.id, title: title)
        checklistInput = ""
    }

    private func duplicate(_ todo: OrdoTodo) {
        // 契约 §6 的复制语义由核心实现(含清单项重置、日期/截止平移),
        // Swift 侧不再自行拼装字段。
        guard environment.duplicateTodo(id: todo.id) != nil else {
            environment.toast("复制失败,这条待办可能已不存在", kind: .failure)
            return
        }
        environment.toast("已复制", kind: .success)
    }

    private func setRepeat(_ todo: OrdoTodo, rule: OrdoRepeatRule?) {
        // 核心会处理「设置重复后自动落到具体日期」等不变量(见 OrdoEngine.setRepeat)。
        environment.setRepeat(id: todo.id, rule: rule)
    }

    private func setRepeatMode(_ todo: OrdoTodo, mode: OrdoRepeatMode) {
        guard var rule = todo.repeatRule else { return }
        rule.mode = mode
        environment.setRepeat(id: todo.id, rule: rule)
    }

    // MARK: 文案

    private func whenText(_ todo: OrdoTodo) -> String {
        switch todo.when {
        case .inbox: return "收件箱"
        case .today: return "今天"
        case .evening: return "今晚"
        case .anytime: return "随时"
        case .someday: return "某天"
        case .date: return todo.date.map { formatter.shortDate($0) } ?? "选择日期"
        }
    }

    private func repeatText(_ todo: OrdoTodo) -> String {
        guard let rule = todo.repeatRule else { return "重复" }
        let unit: String
        switch rule.freq {
        case .daily: unit = "天"
        case .weekly: unit = "周"
        case .monthly: unit = "月"
        case .yearly: unit = "年"
        }
        let base = rule.interval <= 1 ? "每\(unit)" : "每 \(rule.interval) \(unit)"
        return rule.mode == .afterCompletion ? base + "(完成后)" : base
    }

    private func moveText(_ todo: OrdoTodo) -> String {
        if let project = environment.snapshot.project(id: todo.projectId) { return project.name }
        if let area = environment.snapshot.area(id: todo.areaId) { return area.name }
        return "移动到…"
    }

    private func isScheduledToday(_ todo: OrdoTodo) -> Bool {
        if todo.when == .today || todo.when == .evening { return true }
        if todo.when == .date, let date = todo.date, date <= formatter.today() { return true }
        return false
    }

    private func isDeadlineOverdue(_ todo: OrdoTodo) -> Bool {
        guard let deadline = todo.deadline else { return false }
        return deadline < formatter.today() && todo.status == .open
    }

    private func colorForTag(_ name: String) -> String? {
        environment.snapshot.tags.first { $0.name == name }?.color
    }
}

// MARK: - 紧凑宽度下的全屏详情

public struct TodoDetailScreen: View {

    public var todoId: String
    private let shell: ShellViewModel
    private let environment: AppEnvironment

    public init(todoId: String, shell: ShellViewModel, environment: AppEnvironment) {
        self.todoId = todoId
        self.shell = shell
        self.environment = environment
    }

    public var body: some View {
        ScrollView {
            TodoDetailView(todoId: todoId, shell: shell, environment: environment, isFullScreen: true)
                .padding(OrdoSpacing.l)
        }
        .background(OrdoColor.canvas)
        .navigationTitle(environment.snapshot.todo(id: todoId)?.title ?? "待办")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 自动换行的横向排列

/// 简单的流式布局:字段胶囊按钮与标签 chip 会自动换行(规范 §8:字体放大 200% 不截断)。
public struct FlowingRow: Layout {

    public var spacing: CGFloat
    public var rowSpacing: CGFloat

    public init(spacing: CGFloat = OrdoSpacing.s, rowSpacing: CGFloat = OrdoSpacing.s) {
        self.spacing = spacing
        self.rowSpacing = rowSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentRowWidth + size.width > maxWidth, currentRowWidth > 0 {
                totalHeight += rowHeight + rowSpacing
                currentRowWidth = 0
                rowHeight = 0
            }
            currentRowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: proposal.width ?? currentRowWidth, height: totalHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
