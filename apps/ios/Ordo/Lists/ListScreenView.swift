//
//  ListScreenView.swift
//  Ordo
//
//  清单主界面(设计规范 §3 布局骨架 / §4 组件 / §5 动效 / §6 手势)。
//
//  · 顶部:汉堡(紧凑宽度)+ 大标题 28/34 + 副标题/计数 + 工具按钮(快找 / 更多);
//  · 内容:最大宽度 720 居中;今天清单顶部有只读日程区块;分区标题 + 待办行 38pt;
//  · 详情:内联展开的白色卡片(规范 §3「详情以内联卡片展开」);
//  · 完成动效:0/80/160/240/700/900ms 时序,行在动画期间由 `completing` 保留列表维持渲染;
//  · 拖拽排序(规范 §6):长按行 → 拖到目标行 → 提交整段新顺序给核心 `reorderTodos(ids:)`。
//    只对「可手动排序」的视图开放(收件箱/随时/某天/项目内),且必须**同一容器**
//    —— 核心的 `order` 以 `(when, projectId, headingId)` 为作用域连续,详见 `AppEnvironment.reorderTodos`。
//

import SwiftUI

public struct ListScreenView: View {

    private let shell: ShellViewModel
    private let environment: AppEnvironment
    private let onRequestFocus: () -> Void

    @State private var completing: [CompletingRow] = []
    @State private var collapsedSections: Set<String> = []
    @State private var composerSectionId: String?
    @State private var composerText = ""
    /// 正在被拖拽的行(设计规范 §6:拖拽时行整体降透明度,由系统拖拽预览表达)。
    @State private var draggingTodoId: String?
    /// 当前高亮的投放目标行。
    @State private var dropTargetTodoId: String?
    /// 拖拽状态复位任务(拖拽被取消时 `performDrop` 不会被调用,需要兜底清理)。
    @State private var dragResetTask: Task<Void, Never>?
    @FocusState private var composerFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(shell: ShellViewModel, environment: AppEnvironment, onRequestFocus: @escaping () -> Void = {}) {
        self.shell = shell
        self.environment = environment
        self.onRequestFocus = onRequestFocus
    }

    /// 动画期间被「留住」的行(数据已变,但仍要渲染到动画结束)。
    struct CompletingRow: Identifiable {
        var id: String { todo.id }
        var todo: OrdoTodo
        var sectionId: String
        var sectionKind: OrdoSectionKind
        var sectionTitle: String
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: OrdoLayout.sectionSpacing) {
                    if shell.selection.kind == .today {
                        AgendaSectionView(events: shell.agendaEvents, source: shell.agendaSource)
                            .padding(.top, OrdoSpacing.s)
                    }

                    if renderSections.isEmpty {
                        emptyState
                    } else {
                        ForEach(renderSections) { section in
                            sectionView(section)
                        }
                    }

                    Color.clear.frame(height: OrdoSpacing.xxl * 3)
                }
                .frame(maxWidth: OrdoSpacing.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, OrdoSpacing.contentHorizontalPadding)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(OrdoColor.canvas)
        .onChange(of: shell.selection.stableIdentifier) { _, _ in
            collapsedSections.removeAll()
            composerSectionId = nil
            // 进入「今天」= 用户已看到当前的应用内提醒 → 清空角标(见 AppEnvironment.markRemindersRead)
            if shell.selection.kind == .today {
                environment.markRemindersRead()
            }
        }
        .onChange(of: shell.requestComposer) { _, requested in
            guard requested else { return }
            beginComposer(in: nil)
            shell.requestComposer = false
        }
        // 拖拽被取消时不会有任何 DropDelegate 回调,这里做状态兜底复位
        .onChange(of: draggingTodoId) { _, newValue in
            dragResetTask?.cancel()
            guard newValue != nil else { return }
            dragResetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled, draggingTodoId != nil else { return }
                draggingTodoId = nil
                dropTargetTodoId = nil
            }
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: OrdoSpacing.s) {
            if isCompactWidth {
                Button {
                    withAnimation(OrdoMotion.resolved(OrdoMotion.sidebarCollapse, reduceMotion: reduceMotion)) {
                        shell.isSidebarDrawerOpen = true
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(OrdoColor.textSecondary)
                        .frame(width: OrdoSpacing.minTouchTarget, height: OrdoSpacing.minTouchTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开侧栏")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(shell.title)
                    .font(OrdoFont.display)
                    .lineSpacing(OrdoFont.displayLineSpacing)
                    .foregroundStyle(OrdoColor.textPrimary)
                    .lineLimit(1)
                if !shell.subtitle.isEmpty {
                    Text(shell.subtitle)
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: OrdoSpacing.s)

            HStack(spacing: OrdoSpacing.xs) {
                Button {
                    shell.isFastFindPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(OrdoColor.textSecondary)
                        .frame(width: OrdoSpacing.minTouchTarget, height: OrdoSpacing.minTouchTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("快找")

                Menu {
                    Button("新建待办") { beginComposer(in: renderSections.first) }
                    Button("新建项目") { createProjectInCurrentContext() }
                    Button("新建区域") { createArea() }
                    Divider()
                    Button("切换外观(⌘⇧D)") { shell.cycleTheme() }
                    Button("设置") { shell.isSettingsPresented = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(OrdoColor.textSecondary)
                        .frame(width: OrdoSpacing.minTouchTarget, height: OrdoSpacing.minTouchTarget)
                }
                .accessibilityLabel("更多操作")
            }
        }
        .padding(.horizontal, OrdoSpacing.contentHorizontalPadding)
        .padding(.top, OrdoSpacing.m)
        .padding(.bottom, OrdoSpacing.s)
        .frame(maxWidth: OrdoSpacing.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(OrdoColor.canvas)
    }

    private var isCompactWidth: Bool { horizontalSizeClass == .compact }

    // MARK: 分区

    @ViewBuilder
    private func sectionView(_ section: OrdoListSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeaderView(
                title: section.title,
                kind: section.kind,
                count: section.todos.count,
                isCollapsible: section.kind == .heading || section.kind == .day,
                isCollapsed: collapsedSections.contains(section.id),
                onToggle: { toggleSection(section.id) },
                onAdd: { beginComposer(in: section) }
            )

            if !collapsedSections.contains(section.id) {
                ForEach(section.todos) { todo in
                    rowView(todo, in: section)
                }

                if composerSectionId == section.id {
                    composerRow
                }

                if section.todos.isEmpty && composerSectionId != section.id {
                    Text("暂无待办")
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textTertiary)
                        .padding(.horizontal, OrdoSpacing.m)
                        .padding(.vertical, OrdoSpacing.s)
                        .accessibilityLabel("暂无待办")
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ todo: OrdoTodo, in section: OrdoListSection) -> some View {
        let isExpanded = shell.expandedTodoId == todo.id
        let isCompleting = completing.contains { $0.todo.id == todo.id }

        VStack(alignment: .leading, spacing: 0) {
            TodoRowView(
                todo: todo,
                isExpanded: isExpanded,
                isHighlighted: highlightedTodoId == todo.id,
                isCompleting: isCompleting,
                projectName: environment.snapshot.project(id: todo.projectId)?.name,
                tagColor: { name in environment.snapshot.tags.first { $0.name == name }?.color },
                onToggleDone: { toggleDone(todo, in: section) },
                onCompletionFinished: { removeCompleting(todo.id) },
                onToggleExpand: {
                    onRequestFocus()
                    shell.toggleExpanded(todo.id)
                },
                onSchedule: { shell.scheduleTarget = .when(todoId: todo.id) },
                onDeadline: { shell.scheduleTarget = .deadline(todoId: todo.id) },
                onTagTap: { name in shell.open(.tag(name)) },
                onRestore: todo.status == .open ? nil : { restore(todo) }
            )
            .ordoSwipeActions(
                leading: todo.status == .open
                    ? [.complete { toggleDone(todo, in: section) }]
                    : [],
                trailing: [.delete { environment.deleteTodo(id: todo.id) }]
            )
            .opacity(draggingTodoId == todo.id ? 0.45 : 1)
            .modifier(OrdoReorderModifier(
                isEnabled: canReorder(section),
                todoId: todo.id,
                isDropTarget: dropTargetTodoId == todo.id,
                delegate: OrdoReorderDropDelegate(
                    target: todo,
                    section: section,
                    dragging: $draggingTodoId,
                    dropTarget: $dropTargetTodoId,
                    onCommit: { moved in
                        withAnimation(OrdoMotion.resolved(OrdoMotion.fastEase, reduceMotion: reduceMotion)) {
                            _ = environment.reorderTodos(ids: moved)
                        }
                    }
                )
            ))

            if isExpanded {
                TodoDetailView(todoId: todo.id, shell: shell, environment: environment)
                    .padding(.top, OrdoSpacing.xs)
                    .padding(.horizontal, OrdoSpacing.xs)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 1)
        .id(todo.id)
    }

    // MARK: 拖拽排序(设计规范 §6)

    /// 该分区能否手动排序。
    ///
    /// 判据(与 KMP 核心的查询规则严格对应):
    /// · 只有 `order` 真正参与排序的视图才开放 —— 收件箱 / 随时 / 某天 / 项目(含标题分区)/ 区域;
    /// · 「今天」「计划」「日志簿」由日期或完成时间决定顺序,核心不读 `order`,因此不开放拖拽;
    /// · 标签视图跨容器聚合,拖拽会让两个容器的 order 互相竞争,同样不开放。
    private func canReorder(_ section: OrdoListSection) -> Bool {
        guard section.todos.count > 1 else { return false }
        switch section.kind {
        case .plain, .plainToday, .tonight, .heading:
            break
        case .agenda, .day, .later, .completedDay:
            return false
        }
        switch shell.selection.kind {
        case .inbox, .anytime, .someday, .project, .area:
            // 同一分区内的待办必须同容器(order 的作用域),否则拖拽无意义
            return Set(section.todos.map(AppEnvironment.containerKey(for:))).count == 1
        case .today, .upcoming, .logbook, .tag, .search:
            return false
        }
    }

    /// 计算拖放后的目标顺序(与核心 `reorderTodos(ids:)` 的语义一致:
    /// 提交的数组下标即新的 `order`,因此必须给出**该容器内的完整序列**)。
    ///
    /// 同容器内的元素位置不变,因此「分区内可见序列」与「容器内完整序列」的下标一致。
    static func movedOrder(
        _ todos: [OrdoTodo],
        moving sourceId: String,
        before targetId: String
    ) -> [String]? {
        guard let from = todos.firstIndex(where: { $0.id == sourceId }),
              let targetIndex = todos.firstIndex(where: { $0.id == targetId }),
              from != targetIndex else { return nil }

        var ids = todos.map(\.id)
        let moved = ids.remove(at: from)
        // 目标下标以「移除后」的数组为准,保证向上/向下拖动的落点都符合直觉
        let insertion = from < targetIndex ? targetIndex - 1 : targetIndex
        ids.insert(moved, at: min(max(insertion, 0), ids.count))
        guard ids != todos.map(\.id) else { return nil }
        return ids
    }

    // MARK: 行内新建

    private var composerRow: some View {
        HStack(spacing: OrdoSpacing.s) {
            Image(systemName: "plus.circle")
                .font(.system(size: 15))
                .foregroundStyle(OrdoColor.accent)
                .frame(width: OrdoSpacing.minTouchTarget, height: OrdoSpacing.rowHeight)

            TextField("新待办(支持「明天 18:00 交报告 #重要」)", text: $composerText)
                .font(OrdoFont.body)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .submitLabel(.done)
                .onSubmit { commitComposer() }
                .accessibilityLabel("新待办标题")

            Button("完成") { commitComposer() }
                .font(OrdoFont.captionEmphasis)
                .foregroundStyle(OrdoColor.accent)
                .buttonStyle(.plain)
                .accessibilityLabel("保存待办")

            Button {
                composerSectionId = nil
                composerText = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OrdoColor.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消")
        }
        .padding(.horizontal, OrdoSpacing.m)
        .padding(.vertical, OrdoSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: OrdoRadius.row, style: .continuous)
                .fill(OrdoColor.surface)
        )
        .padding(.horizontal, OrdoSpacing.s)
    }

    // MARK: 空状态

    private var emptyState: some View {
        Group {
            if let status = environment.sync?.status, status == .offline {
                EmptyStateView(kind: .offline)
            } else {
                EmptyStateView(kind: .empty, actionTitle: "新建待办") { beginComposer(in: nil) }
            }
        }
    }

    // MARK: 派生:分区 + 保留行

    private var renderSections: [OrdoListSection] {
        let base = shell.sections
        guard !completing.isEmpty else { return base }

        var result = base.map { section -> OrdoListSection in
            var todos = section.todos
            for row in completing where row.sectionId == section.id {
                if !todos.contains(where: { $0.id == row.todo.id }) {
                    let index = todos.firstIndex { $0.order > row.todo.order } ?? todos.endIndex
                    todos.insert(row.todo, at: index)
                }
            }
            var copy = section
            copy.todos = todos
            return copy
        }

        // 分区因为唯一一条待办被完成而消失时,临时补回该分区,保证动画不中断。
        for row in completing where !result.contains(where: { $0.id == row.sectionId }) {
            result.append(
                OrdoListSection(
                    id: row.sectionId,
                    kind: row.sectionKind,
                    title: row.sectionTitle,
                    todos: [row.todo]
                )
            )
        }
        return result
    }

    private var highlightedTodoId: String? {
        let todos = renderSections.flatMap(\.todos)
        guard todos.indices.contains(shell.highlightedIndex) else { return nil }
        return todos[shell.highlightedIndex].id
    }

    // MARK: 动作

    private func toggleDone(_ todo: OrdoTodo, in section: OrdoListSection) {
        if todo.status == .open {
            // 先登记「保留行」,再改数据:动画期间列表里仍有这一行。
            completing.append(
                CompletingRow(
                    todo: todo,
                    sectionId: section.id,
                    sectionKind: section.kind,
                    sectionTitle: section.title
                )
            )
        }
        environment.toggleDone(id: todo.id)
    }

    private func removeCompleting(_ id: String) {
        completing.removeAll { $0.todo.id == id }
    }

    private func restore(_ todo: OrdoTodo) {
        environment.updateTodo(id: todo.id) { value in
            value.status = .open
            value.completedAt = nil
        }
        environment.toast("已恢复为未完成", kind: .success)
    }

    private func toggleSection(_ id: String) {
        withAnimation(OrdoMotion.resolved(OrdoMotion.expand, reduceMotion: reduceMotion)) {
            if collapsedSections.contains(id) {
                collapsedSections.remove(id)
            } else {
                collapsedSections.insert(id)
            }
        }
    }

    private func beginComposer(in section: OrdoListSection?) {
        composerSectionId = section?.id ?? renderSections.first?.id ?? "default"
        composerText = ""
        composerFocused = true
    }

    private func commitComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            composerSectionId = nil
            return
        }
        var options = OrdoTodoOptions.none
        switch shell.selection.kind {
        case .inbox: options.when = .inbox
        case .today: options.when = .today
        case .anytime: options.when = .anytime
        case .someday: options.when = .someday
        case .project:
            options.projectId = shell.selection.id
            options.when = .anytime
        case .area:
            options.areaId = shell.selection.id
            options.when = .anytime
        case .upcoming, .logbook, .tag, .search:
            options.when = .today
        }

        // 今晚分区 / 项目内标题的分区:补上对应归属。
        if let sectionId = composerSectionId,
           let section = renderSections.first(where: { $0.id == sectionId }) {
            if section.kind == .tonight {
                options.when = .evening
            } else if section.kind == .heading {
                options.headingId = sectionId
                options.projectId = shell.selection.id
                options.when = .anytime
            }
        }

        let created = environment.createTodo(fromRawInput: text, options: options)
        composerText = ""
        environment.toast("已添加:\(created.title)", kind: .success)
        composerFocused = true
    }

    private func createProjectInCurrentContext() {
        let areaId: String? = shell.selection.kind == .area ? shell.selection.id : nil
        let name = "新项目 \(environment.snapshot.projects.count + 1)"
        let project = environment.createProject(name: name, areaId: areaId)
        shell.open(.project(project.id))
    }

    private func createArea() {
        let name = "新区域 \(environment.snapshot.areas.count + 1)"
        _ = environment.createArea(name: name)
        environment.toast("已创建区域:\(name)", kind: .success)
    }
}

// MARK: - 拖拽排序的投放代理

/// `onDrag` / `onDrop` 的桥接(delegate 形式,而不是 `.dropDestination(for:)`)。
///
/// 原因:delegate 能拿到**目标行的上下文**(分区 + 该行在分区中的位置),
/// 可以明确算出「插到目标行之前」的新顺序;`Transferable` 形式在 iOS 17 上
/// 还需要为局部使用的 `String` 声明 `UTType` 导出,多一层不必要的注册。
///
/// 标注 `@MainActor`:委托回调都在主线程触发,且它持有指向视图 `@State` 的 `Binding`
/// (非 `Sendable`),限定主执行器可避免 Swift 6 严格并发下的「捕获非 Sendable 值」报错。
@MainActor
struct OrdoReorderDropDelegate: DropDelegate {

    let target: OrdoTodo
    let section: OrdoListSection
    @Binding var dragging: String?
    @Binding var dropTarget: String?
    let onCommit: ([String]) -> Void

    /// 数据变化时 SwiftUI 会调用;返回 true 让系统在拖拽过程中实时反馈。
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    /// 开始拖动新的一行时复位上一次的拖拽状态(上一次可能被取消而没走到 `performDrop`)。
    func resetDragState(keeping todoId: String) {
        dragging = todoId
        dropTarget = nil
    }

    func dropEntered(info: DropInfo) {
        dropTarget = target.id
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target.id { dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragging = nil
            dropTarget = nil
        }
        guard let sourceId = dragging, sourceId != target.id else { return false }
        // 源与目标必须同容器(核心 order 的作用域),否则拒绝
        guard Set(section.todos.map(AppEnvironment.containerKey(for:))).count == 1,
              let source = section.todos.first(where: { $0.id == sourceId }),
              AppEnvironment.containerKey(for: source) == AppEnvironment.containerKey(for: target),
              let moved = ListScreenView.movedOrder(section.todos, moving: sourceId, before: target.id)
        else { return false }

        onCommit(moved)
        return true
    }
}

/// 行的拖拽 / 投放修饰器:仅当分区可排序时才挂上手势。
struct OrdoReorderModifier: ViewModifier {

    let isEnabled: Bool
    let todoId: String
    let isDropTarget: Bool
    let delegate: OrdoReorderDropDelegate

    func body(content: Content) -> some View {
        if isEnabled {
            content
                // 长按后拖动:系统生成行快照作为拖拽预览(规范 §6)
                .onDrag {
                    // 兜底:上一次拖拽若被取消(没有命中任何投放目标),这里复位,避免行一直停在半透明态
                    delegate.resetDragState(keeping: todoId)
                    return NSItemProvider(object: todoId as NSString)
                } preview: {
                    Text("移动")
                        .font(OrdoFont.caption)
                        .padding(.horizontal, OrdoSpacing.s)
                        .padding(.vertical, OrdoSpacing.xs)
                        .background(Capsule().fill(OrdoColor.surface))
                }
                .onDrop(of: [.text], delegate: delegate)
                .overlay(alignment: .top) {
                    // 投放位置提示(不靠颜色单独传达状态:同时插入一条 2pt 强调线)
                    Rectangle()
                        .fill(OrdoColor.accent)
                        .frame(height: 2)
                        .opacity(isDropTarget ? 1 : 0)
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}
