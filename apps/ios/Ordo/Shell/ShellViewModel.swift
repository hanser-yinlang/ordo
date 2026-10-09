//
//  ShellViewModel.swift
//  Ordo
//
//  外壳状态:当前清单、展开的详情、快找/设置/排期浮层、键盘选中、主题、侧栏可见性。
//  派生数据一律来自 `AppEnvironment`(即 KMP 核心),本类不复制任何业务规则。
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class ShellViewModel {

    // MARK: 导航状态

    /// 当前清单(默认「今天」)。
    public var selection: OrdoListQuery = .today
    /// 内联展开的待办详情(规范 §3:详情以内联卡片展开)。
    public var expandedTodoId: String?
    /// 键盘高亮的行(规范 §6:↑↓ 移动选中)。
    public var highlightedIndex: Int = 0

    // MARK: 浮层

    public var isFastFindPresented = false
    public var fastFindQuery = ""
    public var isSettingsPresented = false
    /// 由快加号/快捷键发起的「打开行内新建输入框」请求(列表视图消费后置回 false)。
    public var requestComposer = false
    /// 排期面板:为某条待办排期(`when`)或设置截止(`deadline`)。
    public enum ScheduleTarget: Equatable, Sendable {
        case when(todoId: String)
        case deadline(todoId: String)
    }
    public var scheduleTarget: ScheduleTarget?
    /// iPhone(紧凑宽度)上被 push 的详情页目标。
    public var compactDetailTodoId: String?
    /// iPhone 上的侧栏抽屉。
    public var isSidebarDrawerOpen = false

    // MARK: 外观

    public var theme: OrdoThemePreference = .system

    // MARK: 依赖

    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: 派生数据

    /// 当前清单的所有分区(由 KMP `sections(query)` 给出)。
    public var sections: [OrdoListSection] {
        environment.sections(for: selection)
    }

    /// 展平后的待办(键盘导航、计数、批量操作使用)。
    public var visibleTodos: [OrdoTodo] {
        sections.flatMap(\.todos)
    }

    public var title: String { environment.title(for: selection) }

    public var subtitle: String { environment.subtitle(for: selection) }

    public var counts: OrdoSidebarCounts { environment.counts }

    /// 状态栏文案:共 N 项 · 已完成 M 项 · 同步状态(规范 §3)。
    public var statusSummary: String {
        let total = visibleTodos.count
        let done: Int
        switch selection.kind {
        case .logbook:
            done = total
        default:
            done = visibleTodos.filter { $0.status == .done }.count
        }
        return "共 \(total) 项 · 已完成 \(done) 项"
    }

    public var syncLabel: String {
        environment.sync?.status.label ?? "未启用同步"
    }

    public var syncIsProblem: Bool {
        environment.sync?.status.isProblem ?? false
    }

    /// 今日日程(仅「今天」清单展示,规范 §3)。
    public var agendaEvents: [OrdoCalendarEvent] {
        selection.kind == .today ? environment.calendarEvents : []
    }

    /// 日程来源:`.calendar` = 系统日历(EventKit 只读),`.sample` = 权限被拒/当天无日程时的示例回退。
    public var agendaSource: OrdoAgendaSource { environment.agendaSource }

    /// 应用内兜底提醒的未读角标(通知权限被拒或 App 前台时使用,见 `ReminderScheduler`)。
    public var reminderBadgeCount: Int { environment.reminders.unreadReminderCount }

    /// 当前清单是否支持拖拽排序(与 `ListScreenView.canReorder` 的视图级判据一致)。
    public var supportsManualReorder: Bool {
        switch selection.kind {
        case .inbox, .anytime, .someday, .project, .area: return true
        case .today, .upcoming, .logbook, .tag, .search: return false
        }
    }

    public var projectsByArea: [(area: OrdoArea, projects: [OrdoProject])] {
        let areas = environment.snapshot.areas.filter { !$0.deleted && !$0.archived }
        return areas.map { area in
            (area, environment.snapshot.projects.filter { $0.areaId == area.id && !$0.deleted && $0.status == .open })
        }
    }

    public var inboxProjects: [OrdoProject] {
        environment.snapshot.projects.filter { $0.areaId == nil && !$0.deleted && $0.status == .open }
    }

    public var tags: [OrdoTag] { environment.snapshot.tags }

    /// 区域数量(仅用于默认命名,不参与任何派生清单规则)。
    public var snapshotAreaCount: Int { environment.snapshot.areas.count }

    // MARK: 导航

    public func open(_ query: OrdoListQuery) {
        selection = query
        expandedTodoId = nil
        highlightedIndex = 0
        isSidebarDrawerOpen = false
    }

    public func openTodo(id: String) {
        let todos = visibleTodos
        guard let index = todos.firstIndex(where: { $0.id == id }) else {
            // 目标不在当前清单:尝试从全量快照里定位其所属清单。
            if let todo = environment.snapshot.todo(id: id) {
                open(ListResolver.list(for: todo))
                if let index = visibleTodos.firstIndex(where: { $0.id == id }) {
                    highlightedIndex = index
                }
                expandedTodoId = id
            }
            return
        }
        highlightedIndex = index
        expandedTodoId = id
    }

    public func toggleExpanded(_ id: String) {
        expandedTodoId = (expandedTodoId == id) ? nil : id
    }

    // MARK: 键盘(规范 §6)

    public func moveHighlight(by delta: Int) {
        let todos = visibleTodos
        guard !todos.isEmpty else { return }
        highlightedIndex = min(max(0, highlightedIndex + delta), todos.count - 1)
    }

    public func activateHighlighted() {
        let todos = visibleTodos
        guard todos.indices.contains(highlightedIndex) else { return }
        toggleExpanded(todos[highlightedIndex].id)
    }

    public func toggleHighlightedDone() {
        let todos = visibleTodos
        guard todos.indices.contains(highlightedIndex) else { return }
        environment.toggleDone(id: todos[highlightedIndex].id)
    }

    public func deleteHighlighted() {
        let todos = visibleTodos
        guard todos.indices.contains(highlightedIndex) else { return }
        let id = todos[highlightedIndex].id
        environment.deleteTodo(id: id)
        highlightedIndex = max(0, min(highlightedIndex, max(0, visibleTodos.count - 1)))
    }

    /// 数字键 1…6 切换固定清单。
    public func openPinnedList(index: Int) {
        let order: [OrdoListKind] = [.inbox, .today, .upcoming, .anytime, .someday, .logbook]
        guard order.indices.contains(index) else { return }
        open(OrdoListQuery(kind: order[index]))
    }

    /// ⌘⇧D 循环主题(自动 → 浅色 → 深色)。
    public func cycleTheme() {
        theme = theme.next
        Task { await environment.setTheme(theme) }
    }

    public func loadStoredTheme() async {
        theme = await environment.storedTheme()
    }

    // MARK: 新建

    /// ⌘N「新建待办」:与快加号**单击**同义 —— 请求列表视图打开行内输入框。
    ///
    /// 原实现只置一个 `isQuickAddMenuPresented` 标志,而没有任何视图消费它
    /// (SwiftUI 的 `.contextMenu` 只能由长按弹出,无法编程打开),
    /// 于是 ⌘N 表现为「按了没有任何反应」。
    public func beginQuickAdd() {
        requestComposer = true
    }

    /// 在当前清单里新建一条待办(快加号单击行为)。
    /// 标题里的日期/时间/标签由 KMP 核心解析(契约 §5),因此这里直接传原文。
    @discardableResult
    public func createTodoInCurrentList(title: String) -> OrdoTodo {
        var options = OrdoTodoOptions.none
        switch selection.kind {
        case .inbox:
            options.when = .inbox
        case .today:
            options.when = .today
        case .anytime:
            options.when = .anytime
        case .someday:
            options.when = .someday
        case .project:
            options.projectId = selection.id
            options.when = .anytime
        case .area:
            options.areaId = selection.id
            options.when = .anytime
        case .upcoming, .logbook, .tag, .search:
            options.when = .today
        }
        return environment.createTodo(fromRawInput: title, options: options)
    }

    // MARK: 容器新建(快加号菜单复用)

    @discardableResult
    public func createProject(name: String, areaId: String?, headingNames: [String] = []) -> OrdoProject {
        environment.createProject(name: name, areaId: areaId, headingNames: headingNames)
    }

    @discardableResult
    public func createArea(name: String) -> OrdoArea {
        environment.createArea(name: name)
    }

    @discardableResult
    public func createHeading(projectId: String, name: String) -> OrdoHeading {
        environment.createHeading(projectId: projectId, name: name)
    }

    /// 标题数量来自核心查询(`headingsOf`),不在 Swift 侧自行过滤。
    public func headingsCount(projectId: String) -> Int {
        environment.headings(of: projectId).count
    }
}

/// 由待办反查它所属的清单(用于深链/搜索跳转)。
public enum ListResolver {
    public static func list(for todo: OrdoTodo) -> OrdoListQuery {
        switch todo.status {
        case .done, .canceled:
            return .logbook
        case .open:
            break
        }
        switch todo.when {
        case .inbox: return todo.projectId == nil ? .inbox : .project(todo.projectId ?? "")
        case .today, .evening: return .today
        case .anytime: return todo.projectId.map { OrdoListQuery.project($0) } ?? .anytime
        case .someday: return .someday
        case .date: return .upcoming
        }
    }
}
