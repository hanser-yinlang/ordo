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
    /// 正在被拖拽的行(规范 §5.4:长按 400ms 后行抬起)。
    @State private var draggingTodoId: String?
    /// 当前高亮的投放目标行(插入指示线画在它上方)。
    @State private var dropTargetTodoId: String?
    /// 每一行在列表坐标系中的位置(把手指位置换算成投放目标,不依赖系统拖放会话)。
    @State private var rowFrames: [String: CGRect] = [:]
    /// 列表可视区域大小(判断「拖出窗口 → 取消」)。
    @State private var viewportSize: CGSize = .zero
    /// 拖拽状态复位任务(兜底:手势被系统中断时不会有 onEnded)。
    @State private var dragResetTask: Task<Void, Never>?
    @FocusState private var composerFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// 行的列表坐标空间(命中测试与插入线都基于它)。
    static let listCoordinateSpace = "ordo.list"

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

            projectCompletionBar

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

                    // 空清单(刚建的项目 / 今天没有待办)没有任何分区可以挂载输入框,
                    // 此时把它渲染在空状态下方 —— 否则点快加号会「没有任何可见变化」。
                    if composerIsDetached {
                        composerRow
                    }

                    Color.clear.frame(height: OrdoSpacing.xxl * 3)
                }
                .frame(maxWidth: OrdoSpacing.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, OrdoSpacing.contentHorizontalPadding)
            }
            // 长按拖拽(规范 §5.4):行位置在同一个坐标空间里采集
            .coordinateSpace(name: Self.listCoordinateSpace)
            // 拖拽期间禁止列表滚动(否则行在移动、列表也在滚)
            .scrollDisabled(draggingTodoId != nil)
            .background(viewportReader)
            .onPreferenceChange(OrdoRowFramePreferenceKey.self) { frames in
                rowFrames = frames
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
        // UI 规范 §5.4:Esc 取消拖拽(行回原位,不写库)
        .onChange(of: shell.dragCancelToken) { _, _ in
            cancelDrag()
        }
        // 拖拽被系统中断时不会有 onEnded,这里做状态兜底复位
        .onChange(of: draggingTodoId) { _, newValue in
            dragResetTask?.cancel()
            guard newValue != nil else { return }
            dragResetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, draggingTodoId != nil else { return }
                cancelDrag()
            }
        }
    }

    /// 采集可视区域尺寸(用于「拖出窗口 → 取消」的判定)。
    private var viewportReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { viewportSize = proxy.size }
                .onChange(of: proxy.size) { _, size in viewportSize = size }
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

    // MARK: 项目完成入口(契约 §2.2 v1.1)

    /// 当前清单是项目时的完成入口。
    ///
    /// · 判定与「自动归档未归档标题」都在 KMP 核心 `completeProject` 内完成,Swift 侧**不复制规则**
    ///   (尤其不检查 `heading.archived`:标题是组织容器,不阻塞完成);
    /// · 项目一旦完成,「完成项目」入口整体消失,只剩状态徽标与「重新打开」;
    /// · 还有未完成待办时按钮仍可点,由 `AppEnvironment.completeProject` 给出与真实原因一致的提示。
    @ViewBuilder
    private var projectCompletionBar: some View {
        if shell.selection.kind == .project,
           let projectId = shell.selection.id,
           let project = environment.snapshot.project(id: projectId),
           !project.deleted {
            HStack(spacing: OrdoSpacing.s) {
                if project.status == .done {
                    Label("项目已完成", systemImage: "checkmark.circle.fill")
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.success)

                    Spacer(minLength: OrdoSpacing.s)

                    Button("重新打开") { environment.reopenProject(id: projectId) }
                        .font(OrdoFont.captionEmphasis)
                        .foregroundStyle(OrdoColor.accent)
                        .buttonStyle(.plain)
                        .accessibilityLabel("重新打开项目")
                } else {
                    Button {
                        environment.completeProject(id: projectId)
                    } label: {
                        Label("完成项目", systemImage: "checkmark.circle")
                            .font(OrdoFont.captionEmphasis)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OrdoColor.accent)
                    .accessibilityLabel("完成项目")

                    Spacer(minLength: OrdoSpacing.s)

                    Text(openTodosHint(projectId))
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, OrdoSpacing.contentHorizontalPadding)
            .padding(.bottom, OrdoSpacing.s)
            .frame(maxWidth: OrdoSpacing.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// 未完成待办提示。计数取自核心查询结果(`AppEnvironment.projectProgress`),
    /// 与完成判定同源,避免两处口径不一致。
    private func openTodosHint(_ projectId: String) -> String {
        let open = environment.projectProgress(projectId).open
        return open == 0 ? "可以完成" : "还有 \(open) 项未完成"
    }

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
        let isDragging = draggingTodoId == todo.id
        let isReorderable = canReorder(section)

        VStack(alignment: .leading, spacing: 0) {
            TodoRowView(
                todo: todo,
                isExpanded: isExpanded,
                isHighlighted: highlightedTodoId == todo.id,
                isCompleting: isCompleting,
                isLifted: isDragging,
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
                onRestore: todo.status == .open ? nil : { restore(todo) },
                frameCoordinateSpace: Self.listCoordinateSpace
            )
            .ordoSwipeActions(
                leading: todo.status == .open
                    ? [.complete { toggleDone(todo, in: section) }]
                    : [],
                trailing: [.delete { environment.deleteTodo(id: todo.id) }]
            )
            // 规范 §5.4:被拖行 alpha 0.55
            .opacity(isDragging ? OrdoMotion.Drag.draggedOpacity : 1)
            .ordoRowFrame(id: todo.id, in: Self.listCoordinateSpace)
            .modifier(OrdoLongPressDragModifier(
                // 不可手动排序的分区仍保留「点击打开详情」,只是不进入拖拽
                isEnabled: isReorderable,
                isDragging: isDragging,
                isDropTarget: dropTargetTodoId == todo.id && isReorderable,
                coordinateSpace: Self.listCoordinateSpace,
                onPressChange: { _ in },
                onBegin: { beginDrag(todo.id) },
                onMove: { location in updateDropTarget(dragging: todo.id, at: location, in: section) },
                onEnd: { commitDrag(in: section) },
                onCancel: { cancelDrag() },
                onTap: { location in
                    // §5.4:落在行内控件(复选框 / 排期 / 截止 / 恢复)上的点击由控件自己处理,
                    // 否则一次点击会既完成待办又展开详情。
                    guard !TodoRowView.isControlLocation(location, todoId: todo.id, frames: rowFrames) else { return }
                    onRequestFocus()
                    shell.toggleExpanded(todo.id)
                }
            ))
            .animation(OrdoMotion.resolved(OrdoMotion.Drag.othersShift, reduceMotion: reduceMotion), value: isDragging)

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

    // MARK: 长按拖拽的状态流转(规范 §5.4)

    /// 行抬起(长按 400ms 到点)。
    private func beginDrag(_ todoId: String) {
        draggingTodoId = todoId
        dropTargetTodoId = nil
    }

    /// 拖拽中:把手指位置换算成投放目标行。
    ///
    /// 三种落空都视为「没有目标」(松手 = 不写库):
    /// ① 位置落在任何行之外;② 拖出可视区域(规范 §5.4「拖出窗口」);③ 目标就是自己。
    private func updateDropTarget(dragging todoId: String, at location: CGPoint, in section: OrdoListSection) {
        guard draggingTodoId == todoId else { return }

        let margin = OrdoSpacing.minTouchTarget * 2
        if location.y < -margin || location.y > viewportSize.height + margin {
            cancelDrag()
            return
        }

        let candidates = section.todos.filter { candidate in
            guard let frame = rowFrames[candidate.id] else { return false }
            return location.y >= frame.minY && location.y <= frame.maxY
        }
        let target = candidates.first { $0.id != todoId }?.id
            ?? nearestRow(to: location, in: section, excluding: todoId)
        dropTargetTodoId = target
    }

    /// 兜底:取竖直方向上离手指最近的一行(行与行之间的空隙也能投放)。
    private func nearestRow(to location: CGPoint, in section: OrdoListSection, excluding todoId: String) -> String? {
        let best = section.todos
            .filter { $0.id != todoId }
            .compactMap { candidate -> (id: String, distance: CGFloat)? in
                guard let frame = rowFrames[candidate.id] else { return nil }
                return (candidate.id, abs(frame.midY - location.y))
            }
            .min { $0.distance < $1.distance }
        return best?.id
    }

    /// 松手:位置变了才写库(规范 §5.4「位置未变则不写库」)。
    private func commitDrag(in section: OrdoListSection) {
        let sourceId = draggingTodoId
        let targetId = dropTargetTodoId
        defer {
            draggingTodoId = nil
            dropTargetTodoId = nil
        }
        guard let sourceId, OrdoLongPressDragState.shouldCommit(sourceId: sourceId, targetId: targetId),
              let targetId,
              let moved = Self.movedOrder(section.todos, moving: sourceId, before: targetId)
        else { return }

        withAnimation(OrdoMotion.resolved(OrdoMotion.Drag.drop, reduceMotion: reduceMotion)) {
            _ = environment.reorderTodos(ids: moved)
        }
    }

    /// 取消(Esc / 拖出窗口):行回原位,不写库(规范 §5.4)。
    private func cancelDrag() {
        dragResetTask?.cancel()
        dragResetTask = nil
        withAnimation(OrdoMotion.resolved(OrdoMotion.Drag.drop, reduceMotion: reduceMotion)) {
            draggingTodoId = nil
            dropTargetTodoId = nil
        }
    }

    // MARK: 行内新建

    /// 没有可用分区时(空清单 / 空项目)输入框使用的占位 id。
    ///
    /// 分区的 id 由核心映射合成,恒为 `heading:<id>` 或 `<kind>:<title>`(必含冒号),
    /// 因此这个不含冒号的常量不可能与真实分区冲突。
    private static let detachedComposerId = "detached-composer"

    /// 输入框是否「没有可见的分区可以挂载」:此时渲染在列表末尾,保证点快加号一定有可见变化。
    ///
    /// 两种情形:① 空清单(没有任何分区);② 目标分区被折叠(折叠的分区不渲染行,输入框会跟着消失)。
    private var composerIsDetached: Bool {
        guard let id = composerSectionId else { return false }
        guard let host = renderSections.first(where: { $0.id == id }) else { return true }
        return collapsedSections.contains(host.id)
    }

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
                composerFocused = false
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

    /// 打开行内新建输入框。
    ///
    /// · `section == nil`(快加号单击 / ⌘N / 空状态按钮)=「把输入框给我」:已经打开时**只抢焦点**,
    ///   不清空用户已输入的文本,也不把输入框挪到别的分区;
    /// · 指定分区(分区标题的 +)= 明确要往该分区里加:同一分区同样只抢焦点,换分区才移动并清空。
    ///
    /// 另外:空清单没有任何分区,`renderSections.first?.id` 为 nil,此时用占位 id,
    /// 由 `composerIsDetached` 把它渲染到空状态下方。
    private func beginComposer(in section: OrdoListSection?) {
        let targetId = section?.id ?? renderSections.first?.id ?? Self.detachedComposerId
        if composerSectionId != nil, section == nil || composerSectionId == targetId {
            focusComposer()
            return
        }
        composerSectionId = targetId
        composerText = ""
        // 折叠的分区不会渲染它的行:要往里加东西就先展开它
        collapsedSections.remove(targetId)
        focusComposer()
    }

    /// 让输入框成为第一响应者(键盘弹出)。
    ///
    /// 新插入的 `TextField` 在当帧还没进入响应链,这一次 `@FocusState` 赋值可能被丢弃,
    /// 因此下一帧再补一次请求 —— 这是「点了加号却没弹键盘」的常见成因。
    private func focusComposer() {
        composerFocused = true
        Task { @MainActor in
            composerFocused = true
        }
    }

    /// 分区 id → 核心的 `headingId`。
    ///
    /// `OrdoListSection.id` 是 Swift 侧为了 SwiftUI 列表合成的稳定 id:标题分区为
    /// `heading:<uuid>`(见 `OrdoCoreMapping.map(sections:)`),其余为 `<kind>:<title>`。
    /// 只有前者能还原出真正的标题 id。
    private static func headingId(fromSectionId id: String) -> String? {
        let prefix = "heading:"
        guard id.hasPrefix(prefix) else { return nil }
        let value = String(id.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
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
            } else if section.kind == .heading, let headingId = Self.headingId(fromSectionId: sectionId) {
                // 注意:分区的 id 是 Swift 侧合成的 `heading:<uuid>`(见 OrdoCoreMapping),
                // 直接把它当 headingId 传给核心会被契约 §3 判为「不属于该项目」而置空
                // (OrdoEngine.normalize:726 → headingId = null),待办会掉进「其他」分区。
                options.headingId = headingId
                options.projectId = shell.selection.id
                options.when = .anytime
            }
        }

        let created = environment.createTodo(fromRawInput: text, options: options)
        composerText = ""
        environment.toast("已添加:\(created.title)", kind: .success)
        // 连续录入:输入框保持打开并保住键盘焦点
        focusComposer()
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
