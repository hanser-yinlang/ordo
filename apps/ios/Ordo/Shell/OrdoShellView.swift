//
//  OrdoShellView.swift
//  Ordo
//
//  应用外壳(设计规范 §3 布局骨架、§6 键盘与手势)。
//
//  ≥ 1100px:三栏骨架 —— 侧栏 248 常驻 + 列表(内容最大宽 720 居中)+ 详情以内联卡片展开。
//  < 1100px(含 iPhone):侧栏变抽屉(汉堡 + 遮罩),详情变为全屏 sheet。
//  底部常驻状态栏:共 N 项 · 已完成 M 项 · 同步状态。
//

import SwiftUI

public struct OrdoShellView: View {

    @State private var shell: ShellViewModel
    private let environment: AppEnvironment
    /// 由 `RootView` 转交的深链(冷启动时先于 Shell 到达)。
    @Binding private var externalURL: URL?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var listFocused: Bool

    public init(environment: AppEnvironment, externalURL: Binding<URL?> = .constant(nil)) {
        self.environment = environment
        self._externalURL = externalURL
        _shell = State(initialValue: ShellViewModel(environment: environment))
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            OrdoColor.canvas.ignoresSafeArea()

            if isCompact {
                compactLayout
            } else {
                regularLayout
            }

            // 紧凑宽度下被 push 的待办详情是全屏上下文:此时快加号即便可点,
            // 打开的行内输入框也只会落在后面的列表里(用户看到的是「点了没反应」),因此不渲染。
            if !(isCompact && shell.compactDetailTodoId != nil) {
                QuickAddButton(shell: shell)
                    .padding(.trailing, OrdoSpacing.xl)
                    .padding(.bottom, OrdoSpacing.xl)
            }
        }
        .overlay(alignment: .bottom) {
            OrdoToastOverlay(toasts: environment.toasts) { id in
                environment.dismissToast(id)
            }
        }
        .overlay {
            if shell.isFastFindPresented {
                FastFindView(shell: shell, environment: environment)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .sheet(isPresented: binding(\.isSettingsPresented)) {
            SettingsView(shell: shell, environment: environment)
        }
        .sheet(item: scheduleItemBinding) { item in
            ScheduleSheet(
                shell: shell,
                environment: environment,
                todoId: item.todoId,
                mode: item.mode
            )
        }
        .task {
            await environment.start()
            await shell.loadStoredTheme()
            if let url = externalURL {
                handle(link: OrdoDeepLink.parse(url))
                externalURL = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await environment.handleScenePhase(isActive: phase == .active) }
        }
        .onChange(of: externalURL) { _, url in
            guard let url else { return }
            handle(link: OrdoDeepLink.parse(url))
            externalURL = nil
        }
        .onChange(of: environment.notificationDeepLink) { _, link in
            guard let link, let url = URL(string: link) else { return }
            handle(link: OrdoDeepLink.parse(url))
            environment.notificationDeepLink = nil
        }
        .preferredColorScheme(shell.theme.colorScheme)
        .background(keyboardShortcuts)
    }

    // MARK: 布局

    private var regularLayout: some View {
        HStack(spacing: 0) {
            SidebarView(shell: shell, environment: environment)
                .frame(width: OrdoSpacing.sidebarWidth)
                .background(OrdoColor.sidebar)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(OrdoColor.hairline)
                        .frame(width: 1)
                }

            VStack(spacing: 0) {
                ListScreenView(shell: shell, environment: environment, onRequestFocus: { listFocused = true })
                    .focusable()
                    .focused($listFocused)
                    .ordoKeyCapture(handleKeyPress)
                StatusBarView(shell: shell, environment: environment)
            }
        }
    }

    private var compactLayout: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ListScreenView(shell: shell, environment: environment, onRequestFocus: { listFocused = true })
                    .focusable()
                    .focused($listFocused)
                    .ordoKeyCapture(handleKeyPress)
                StatusBarView(shell: shell, environment: environment)
            }
            .background(OrdoColor.canvas)
            .navigationDestination(isPresented: compactDetailBinding) {
                if let id = shell.compactDetailTodoId {
                    TodoDetailScreen(todoId: id, shell: shell, environment: environment)
                }
            }
            .overlay(alignment: .leading) {
                if shell.isSidebarDrawerOpen {
                    drawer
                }
            }
        }
    }

    private var drawer: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { closeDrawer() }
                .accessibilityLabel("关闭侧栏")
            SidebarView(shell: shell, environment: environment)
                .frame(width: OrdoSpacing.sidebarWidth)
                .background(OrdoColor.sidebar)
                .transition(reduceMotion ? .identity : .move(edge: .leading))
        }
        .transition(reduceMotion ? .identity : .opacity)
    }

    private func closeDrawer() {
        withAnimation(OrdoMotion.resolved(OrdoMotion.sidebarCollapse, reduceMotion: reduceMotion)) {
            shell.isSidebarDrawerOpen = false
        }
    }

    // MARK: 绑定

    private func binding(_ keyPath: ReferenceWritableKeyPath<ShellViewModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { shell[keyPath: keyPath] },
            set: { shell[keyPath: keyPath] = $0 }
        )
    }

    private var compactDetailBinding: Binding<Bool> {
        Binding(
            get: { shell.compactDetailTodoId != nil },
            set: { if !$0 { shell.compactDetailTodoId = nil } }
        )
    }

    private struct ScheduleItem: Identifiable {
        let todoId: String
        let mode: ScheduleSheet.Mode
        var id: String { "\(mode)-\(todoId)" }
    }

    private var scheduleItemBinding: Binding<ScheduleItem?> {
        Binding(
            get: {
                guard let target = shell.scheduleTarget else { return nil }
                switch target {
                case .when(let todoId): return ScheduleItem(todoId: todoId, mode: .when)
                case .deadline(let todoId): return ScheduleItem(todoId: todoId, mode: .deadline)
                }
            },
            set: { if $0 == nil { shell.scheduleTarget = nil } }
        )
    }

    // MARK: 深链

    private func handle(link: OrdoDeepLink) {
        switch link {
        case .list(let query):
            shell.open(query)
        case .todo(let id):
            if isCompact {
                shell.compactDetailTodoId = id
            } else {
                shell.openTodo(id: id)
            }
        case .search(let text):
            shell.fastFindQuery = text
            shell.isFastFindPresented = true
        case .unknown(let raw):
            environment.toast("无法识别的链接:\(raw)", kind: .failure)
        }
    }

    // MARK: 键盘快捷键(规范 §6)

    private var keyboardShortcuts: some View {
        ZStack {
            // ⌘N 新建待办
            Button("新建待办") { shell.beginQuickAdd() }
                .keyboardShortcut("n", modifiers: .command)
            // ⌘K 快找
            Button("快找") { shell.isFastFindPresented = true }
                .keyboardShortcut("k", modifiers: .command)
            // ⌘⇧D 切换深色
            Button("切换外观") { shell.cycleTheme() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            // 1…6 切换清单
            ForEach(Array([OrdoListKind.inbox, .today, .upcoming, .anytime, .someday, .logbook].enumerated()), id: \.offset) { index, _ in
                Button("切换到清单 \(index + 1)") { shell.openPinnedList(index: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
            }
        }
        .opacity(0.001)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: 键盘事件(↑↓ / Enter / Space / Delete / Esc)

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            shell.moveHighlight(by: -1)
            return .handled
        case .downArrow:
            shell.moveHighlight(by: 1)
            return .handled
        case .return:
            shell.activateHighlighted()
            return .handled
        case .space:
            shell.toggleHighlightedDone()
            return .handled
        case .delete, .deleteForward:
            shell.deleteHighlighted()
            return .handled
        case .escape:
            if shell.isFastFindPresented {
                shell.isFastFindPresented = false
            } else if shell.expandedTodoId != nil {
                shell.expandedTodoId = nil
            } else if shell.isSidebarDrawerOpen {
                closeDrawer()
            }
            return .handled
        default:
            // 直接输入触发快找(规范 §6「直接输入」)
            if let character = press.characters.first, character.isLetter || character.isNumber || character == "#" {
                shell.fastFindQuery = String(press.characters)
                shell.isFastFindPresented = true
                return .handled
            }
            return .ignored
        }
    }
}

// MARK: - 键盘事件接入

/// `onKeyPress` 需要视图可聚焦;这里把按键处理挂到列表容器上。
public struct OrdoKeyCapture: ViewModifier {
    public var handler: (KeyPress) -> KeyPress.Result

    public func body(content: Content) -> some View {
        content
            .onKeyPress { press in handler(press) }
    }
}

public extension View {
    func ordoKeyCapture(_ handler: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        modifier(OrdoKeyCapture(handler: handler))
    }
}
