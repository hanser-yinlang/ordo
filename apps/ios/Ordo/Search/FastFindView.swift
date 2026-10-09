//
//  FastFindView.swift
//  Ordo
//
//  快找(设计规范 §1.2「FastFind」/ §4「快找浮层」)。
//
//  规格:顶部输入 44 高,结果行 36,高亮匹配片段;支持 ↑↓ / Enter / Esc;
//        输入 `#标签` 进入标签过滤;回车直达目标清单或待办详情。
//
//  搜索规则(契约 §4「搜索」):待办按「未完成优先 → updatedAt 倒序」由 KMP 核心给出;
//  项目 / 区域 / 标签按名称大小写不敏感匹配(它们不属于契约的搜索条目,属导航范畴)。
//

import SwiftUI

public struct FastFindView: View {

    private let shell: ShellViewModel
    private let environment: AppEnvironment

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var inputFocused: Bool

    public init(shell: ShellViewModel, environment: AppEnvironment) {
        self.shell = shell
        self.environment = environment
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                inputRow
                if !results.isEmpty {
                    Divider().overlay(OrdoColor.hairline)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                                resultRow(result, isSelected: index == selectedIndex)
                                    .onTapGesture { open(result) }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                } else if !query.isEmpty {
                    Text("没有找到匹配的内容")
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textSecondary)
                        .padding(OrdoSpacing.l)
                }

                footer
            }
            .frame(maxWidth: 520)
            .background(
                RoundedRectangle(cornerRadius: OrdoRadius.sheet, style: .continuous)
                    .fill(OrdoColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OrdoRadius.sheet, style: .continuous)
                    .stroke(OrdoColor.hairline, lineWidth: 1)
            )
            .ordoSheetElevation()
            .padding(.top, 64)
            .padding(.horizontal, OrdoSpacing.l)
        }
        .transition(.opacity)
        .ordoKeyCapture(handleKey)
        .onAppear {
            query = shell.fastFindQuery
            selectedIndex = 0
            inputFocused = true
        }
    }

    // MARK: 输入

    private var inputRow: some View {
        HStack(spacing: OrdoSpacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(OrdoColor.textSecondary)

            TextField("搜索待办、项目、区域、标签…", text: $query)
                .font(OrdoFont.body)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .frame(height: OrdoSpacing.fastFindInputHeight)
                .onChange(of: query) { _, _ in selectedIndex = 0 }
                .onSubmit { openSelected() }
                .accessibilityLabel("快找输入框")

            Text("Esc")
                .font(OrdoFont.micro)
                .foregroundStyle(OrdoColor.textTertiary)
                .padding(.horizontal, OrdoSpacing.xs)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(OrdoColor.chipBackground)
                )
        }
        .padding(.horizontal, OrdoSpacing.m)
    }

    private var footer: some View {
        HStack(spacing: OrdoSpacing.m) {
            hint("↑↓", "选择")
            hint("Enter", "打开")
            hint("Esc", "关闭")
            Spacer()
            Text("输入 #标签 可过滤")
                .font(OrdoFont.micro)
                .foregroundStyle(OrdoColor.textTertiary)
        }
        .padding(.horizontal, OrdoSpacing.m)
        .padding(.vertical, OrdoSpacing.s)
        .background(OrdoColor.canvas.opacity(0.6))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: OrdoSpacing.xs) {
            Text(key)
                .font(OrdoFont.micro)
                .foregroundStyle(OrdoColor.textSecondary)
                .padding(.horizontal, OrdoSpacing.xs)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(OrdoColor.chipBackground)
                )
            Text(label)
                .font(OrdoFont.micro)
                .foregroundStyle(OrdoColor.textTertiary)
        }
    }

    // MARK: 结果行

    private func resultRow(_ result: FastFindResult, isSelected: Bool) -> some View {
        HStack(spacing: OrdoSpacing.s) {
            Image(systemName: result.systemImage)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(isSelected ? OrdoColor.accent : OrdoColor.textSecondary)

            VStack(alignment: .leading, spacing: 0) {
                highlighted(result.title, query: query)
                    .font(OrdoFont.body)
                    .lineLimit(1)
                if let subtitle = result.subtitle {
                    Text(subtitle)
                        .font(OrdoFont.micro)
                        .foregroundStyle(OrdoColor.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let badge = result.badge {
                Text(badge)
                    .font(OrdoFont.micro)
                    .foregroundStyle(OrdoColor.textSecondary)
            }
        }
        .padding(.horizontal, OrdoSpacing.m)
        .frame(height: OrdoSpacing.fastFindRowHeight)
        .background(isSelected ? OrdoColor.selectionFill : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.kindLabel):\(result.title)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 高亮匹配片段(不区分大小写)。
    private func highlighted(_ text: String, query: String) -> Text {
        let keyword = query.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        guard !keyword.isEmpty, let range = text.lowercased().range(of: keyword) else {
            return Text(text).foregroundColor(OrdoColor.textPrimary)
        }
        let prefix = String(text[text.startIndex..<range.lowerBound])
        let match = String(text[range])
        let suffix = String(text[range.upperBound...])
        return Text(prefix).foregroundColor(OrdoColor.textPrimary)
            + Text(match).foregroundColor(OrdoColor.accent).bold()
            + Text(suffix).foregroundColor(OrdoColor.textPrimary)
    }

    // MARK: 结果计算

    private var results: [FastFindResult] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return defaultResults }

        if keyword.hasPrefix("#") {
            let name = String(keyword.dropFirst())
            return environment.snapshot.tags
                .filter { name.isEmpty || $0.name.lowercased().contains(name.lowercased()) }
                .map { FastFindResult.tag($0, count: environment.counts.tagCount($0.name)) }
        }

        var items: [FastFindResult] = []

        // 待办:走 KMP 核心的搜索(契约 §4:未完成优先 → updatedAt 倒序)
        let todos = environment.list(for: .search(keyword))
        items.append(contentsOf: todos.prefix(12).map { FastFindResult.todo($0, projectName: environment.snapshot.project(id: $0.projectId)?.name) })

        // 项目 / 区域 / 标签:导航类匹配
        let lowered = keyword.lowercased()
        items.append(contentsOf: environment.snapshot.projects
            .filter { !$0.deleted && $0.name.lowercased().contains(lowered) }
            .prefix(6)
            .map { FastFindResult.project($0, open: environment.counts.projectCount($0.id)) })

        items.append(contentsOf: environment.snapshot.areas
            .filter { !$0.deleted && $0.name.lowercased().contains(lowered) }
            .prefix(4)
            .map { FastFindResult.area($0) })

        items.append(contentsOf: environment.snapshot.tags
            .filter { $0.name.lowercased().contains(lowered) }
            .prefix(4)
            .map { FastFindResult.tag($0, count: environment.counts.tagCount($0.name)) })

        return items
    }

    private var defaultResults: [FastFindResult] {
        OrdoListKind.pinnedOrder.map { kind in
            FastFindResult.list(kind, count: environment.counts.count(for: kind))
        }
    }

    // MARK: 动作

    private func openSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        open(results[selectedIndex])
    }

    private func open(_ result: FastFindResult) {
        switch result {
        case .todo(let todo, _):
            shell.open(ListResolver.list(for: todo))
            shell.openTodo(id: todo.id)
        case .project(let project, _):
            shell.open(.project(project.id))
        case .area(let area):
            shell.open(.area(area.id))
        case .tag(let tag, _):
            shell.open(.tag(tag.name))
        case .list(let kind, _):
            shell.open(OrdoListQuery(kind: kind))
        }
        dismiss()
    }

    private func dismiss() {
        shell.isFastFindPresented = false
        shell.fastFindQuery = ""
    }

    // MARK: 键盘

    public func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            selectedIndex = max(0, selectedIndex - 1)
            return .handled
        case .downArrow:
            selectedIndex = min(max(0, results.count - 1), selectedIndex + 1)
            return .handled
        case .return:
            openSelected()
            return .handled
        case .escape:
            dismiss()
            return .handled
        default:
            return .ignored
        }
    }
}

// MARK: - 结果模型

public enum FastFindResult {
    case todo(OrdoTodo, projectName: String?)
    case project(OrdoProject, open: Int)
    case area(OrdoArea)
    case tag(OrdoTag, count: Int)
    case list(OrdoListKind, count: Int)

    var title: String {
        switch self {
        case .todo(let todo, _): return todo.title
        case .project(let project, _): return project.name
        case .area(let area): return area.name
        case .tag(let tag, _): return "#" + tag.name
        case .list(let kind, _): return kind.displayName
        }
    }

    var subtitle: String? {
        switch self {
        case .todo(let todo, let projectName):
            var parts: [String] = []
            if let projectName { parts.append(projectName) }
            if let progress = todo.checklistProgress { parts.append("清单 \(progress)") }
            if let deadline = todo.deadline { parts.append("截止 " + OrdoDateFormatter.shared.shortDate(deadline)) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .project:
            return "项目"
        case .area:
            return "区域"
        case .tag:
            return "标签"
        case .list:
            return "清单"
        }
    }

    var badge: String? {
        switch self {
        case .todo(let todo, _):
            switch todo.status {
            case .open: return nil
            case .done: return "已完成"
            case .canceled: return "已取消"
            }
        case .project(_, let open): return "\(open) 项未完成"
        case .tag(_, let count): return "\(count) 项"
        case .list(_, let count): return "\(count) 项"
        case .area:
            return nil
        }
    }

    var systemImage: String {
        switch self {
        case .todo(let todo, _):
            switch todo.status {
            case .open: return "circle"
            case .done: return "checkmark.circle"
            case .canceled: return "slash.circle"
            }
        case .project: return "circle.dashed"
        case .area: return "square.grid.2x2"
        case .tag: return "tag"
        case .list(let kind, _): return kind.systemImage
        }
    }

    var kindLabel: String {
        switch self {
        case .todo: return "待办"
        case .project: return "项目"
        case .area: return "区域"
        case .tag: return "标签"
        case .list: return "清单"
        }
    }
}
