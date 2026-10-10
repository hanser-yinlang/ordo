//
//  QuickAddButton.swift
//  Ordo
//
//  快加号集群(UI 规范 §5.2「重构:去掉多余元素」)。
//
//  问题(用户实测截图):右下角同时存在两个圆形按钮 —— 蓝色「+」与白色折叠箭头,视觉上互相叠压。
//  新规范:
//    · **只保留一个圆形按钮**:直径 56、`accent` 填充、白色「+」、投影 8dp;
//    · **删除**独立的折叠箭头按钮,也不再用系统 `.contextMenu`(它自带一套长按/预览行为,
//      与「展开时旋转 45°」「菜单展开中单击收起」这些要求冲突);
//    · 单击 → 打开行内输入行(聚焦 + 列表滚到输入行);
//    · **长按 400ms** → 展开快捷菜单(新建待办 / 项目 / 区域 / 标题),从按钮**左上方**弹出;
//    · 菜单展开中单击 → 收起菜单,按钮转回 0°;
//    · 菜单展开时按钮旋转 45°(「+」变「×」)。
//
//  动效:按压 scale → 0.96(90ms);长按到 400ms 轻微放大到 1.06 并保持;
//        面板 scale 0.9→1 + alpha 0→1(180ms);菜单项逐个错位 40ms 淡入并上移 6px;收起反向 140ms。
//
//  菜单视觉(v1.3 对齐参照原型,见 UI 规范 §5.2「菜单项图标」):
//    · 面板:最小宽 208、radius 12、1px hairline、底色 surface;
//    · 条目:高 44、左内边距 9、图标↔文字 8、字号 13.5、条目 radius 7、按下底 `rowSelected`;
//    · 前导图标四种形状(全部 `Path` 自绘,见 `QuickAddIcons.swift`):待办 ＋ / 项目 H / 区域 圆角方框+中心点 / 标题 ≡;
//    · 颜色:菜单项图标 `textSecondary`(FAB 与选中态才用 `accent`),不引入参照原型的蓝色;
//    · 快捷键提示只有「新建待办」显示 ⌘N(项模型见 `QuickAddMenuItem.swift`)。
//

import SwiftUI

public struct QuickAddButton: View {

    private let shell: ShellViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false
    @State private var isMenuOpen = false
    /// 已淡入的菜单项数量(逐个错位 40ms)。
    @State private var revealedItems = 0
    @State private var longPressTask: Task<Void, Never>?
    @State private var didLongPress = false

    public init(shell: ShellViewModel) {
        self.shell = shell
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: OrdoSpacing.s) {
            if isMenuOpen {
                menu
            }
            button
        }
        .onDisappear {
            longPressTask?.cancel()
            longPressTask = nil
        }
    }

    // MARK: 按钮(唯一的一个圆)

    private var button: some View {
        ZStack {
            Circle()
                .fill(OrdoColor.accent)
                .frame(width: OrdoSpacing.quickAddDiameter, height: OrdoSpacing.quickAddDiameter)
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(isMenuOpen ? OrdoMotion.QuickAdd.expandedRotation : 0))
                .animation(OrdoMotion.resolved(OrdoMotion.QuickAdd.rotate, reduceMotion: reduceMotion), value: isMenuOpen)
        }
        .scaleEffect(buttonScale)
        .animation(OrdoMotion.resolved(OrdoMotion.QuickAdd.press, reduceMotion: reduceMotion), value: isPressed)
        .animation(OrdoMotion.resolved(OrdoMotion.QuickAdd.hold, reduceMotion: reduceMotion), value: didLongPress)
        .ordoQuickAddElevation()
        .contentShape(Circle())
        .gesture(pressGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isMenuOpen ? "关闭新建菜单" : "快加号:新建待办")
        .accessibilityHint(isMenuOpen ? "再次点击收起菜单" : "长按 400 毫秒可选择新建项目、区域或标题")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("打开新建菜单")) {
            openMenu()
        }
    }

    /// 按压 0.96 → 长按保持 1.06(规范 §5.2 动效表)。
    private var buttonScale: CGFloat {
        if didLongPress { return OrdoMotion.QuickAdd.holdScale }
        return isPressed ? OrdoMotion.QuickAdd.pressScale : 1
    }

    /// 单手势同时覆盖「单击」与「长按 400ms」,不再依赖系统 contextMenu。
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isPressed { beginPress() }
                // 明显移动(> 6pt)说明用户在滚动列表,取消长按意图
                if abs(value.translation.width) > OrdoMotion.Drag.clickSlop
                    || abs(value.translation.height) > OrdoMotion.Drag.clickSlop {
                    cancelLongPressIntent()
                }
            }
            .onEnded { _ in endPress() }
    }

    // MARK: 菜单(从按钮左上方弹出)

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menuItems.enumerated()), id: \.offset) { index, item in
                menuRow(item)
                    .opacity(index < revealedItems ? 1 : 0)
                    .offset(y: index < revealedItems ? 0 : OrdoMotion.QuickAdd.itemOffset)
            }
        }
        .padding(OrdoSpacing.xs)
        // 规范 §5.2:最小宽 208;内容(如带 ⌘N 的「新建待办」)更宽时按内容撑开,
        // 但不吃满整屏 —— `fixedSize` 让面板取自身理想宽度,`minWidth` 兜住下限。
        .frame(minWidth: OrdoMotion.QuickAdd.menuMinWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: OrdoRadius.quickAddMenu, style: .continuous)
                .fill(OrdoColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrdoRadius.quickAddMenu, style: .continuous)
                .stroke(OrdoColor.hairline, lineWidth: 1)
        )
        .ordoSheetElevation()
        .transition(
            .scale(scale: OrdoMotion.QuickAdd.menuInitialScale, anchor: .bottomTrailing)
                .combined(with: .opacity)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("新建菜单")
    }

    /// 单个菜单条目:自绘图标 + 文案 + (仅待办)⌘N。
    private func menuRow(_ item: QuickAddItem) -> some View {
        Button {
            perform(item)
        } label: {
            HStack(spacing: OrdoMotion.QuickAdd.menuItemIconTextGap) {
                QuickAddIcon(kind: item.iconKind, color: OrdoColor.textSecondary)

                Text(item.title)
                    .font(OrdoFont.quickAddItem)
                    .foregroundStyle(OrdoColor.textPrimary)

                Spacer(minLength: OrdoSpacing.s)

                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textTertiary)
                }
            }
            .padding(.leading, OrdoMotion.QuickAdd.menuItemLeading)
            .padding(.trailing, OrdoMotion.QuickAdd.menuItemTrailing)
            .frame(height: OrdoMotion.QuickAdd.menuItemHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(OrdoQuickAddItemStyle())
        .accessibilityLabel(item.title)
    }

    /// 菜单项(规范 §5.2:菜单仍是 4 项;「新建标题」只在项目视图里出现)。
    private var menuItems: [QuickAddItem] {
        QuickAddItem.menuItems(in: shell.selection.kind)
    }

    // MARK: 手势状态

    private func beginPress() {
        isPressed = true
        didLongPress = false
        longPressTask?.cancel()
        longPressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(OrdoMotion.QuickAdd.holdDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            didLongPress = true
            openMenu()
        }
    }

    private func cancelLongPressIntent() {
        longPressTask?.cancel()
        longPressTask = nil
    }

    private func endPress() {
        isPressed = false
        cancelLongPressIntent()
        if didLongPress {
            // 长按只负责展开菜单;松手不触发单击行为
            didLongPress = false
            return
        }
        if isMenuOpen {
            // 菜单展开中单击 → 收起菜单,按钮转回 0°(规范 §5.2)
            closeMenu()
        } else {
            shell.requestComposer = true
        }
    }

    // MARK: 菜单开关

    private func openMenu() {
        guard !isMenuOpen else { return }
        revealedItems = 0
        withAnimation(OrdoMotion.resolved(OrdoMotion.QuickAdd.menuIn, reduceMotion: reduceMotion)) {
            isMenuOpen = true
        }
        Task { @MainActor in
            for index in menuItems.indices {
                if index > 0 {
                    // 每个菜单项比上一项晚 40ms(规范 §5.2:逐个错位 40ms)。
                    try? await Task.sleep(nanoseconds: UInt64(OrdoMotion.QuickAdd.itemStagger * 1_000_000_000))
                }
                guard !Task.isCancelled, isMenuOpen else { return }
                withAnimation(OrdoMotion.resolved(OrdoMotion.QuickAdd.menuIn, reduceMotion: reduceMotion)) {
                    revealedItems = index + 1
                }
            }
        }
    }

    private func closeMenu() {
        withAnimation(OrdoMotion.resolved(OrdoMotion.QuickAdd.menuOut, reduceMotion: reduceMotion)) {
            isMenuOpen = false
            revealedItems = 0
        }
    }

    private func perform(_ item: QuickAddItem) {
        closeMenu()
        switch item {
        case .todo:
            shell.requestComposer = true
        case .project:
            createProject()
        case .area:
            createArea()
        case .heading:
            createHeading()
        }
    }

    // MARK: 动作

    private func createProject() {
        let areaId: String? = shell.selection.kind == .area ? shell.selection.id : nil
        let name = "新项目 \(environmentProjectCount + 1)"
        let project = shell.createProject(name: name, areaId: areaId)
        shell.open(.project(project.id))
    }

    private func createArea() {
        let name = "新区域 \(environmentAreaCount + 1)"
        _ = shell.createArea(name: name)
    }

    private func createHeading() {
        guard let projectId = shell.selection.id else { return }
        let name = "新标题 \(environmentHeadingCount(projectId: projectId) + 1)"
        _ = shell.createHeading(projectId: projectId, name: name)
    }

    // MARK: 计数(仅用于默认命名,取自当前快照)

    private var environmentProjectCount: Int { shell.counts.projects.count }
    private var environmentAreaCount: Int { shell.snapshotAreaCount }
    private func environmentHeadingCount(projectId: String) -> Int {
        shell.headingsCount(projectId: projectId)
    }
}

// MARK: - 菜单条目按下态(规范 §5.2:条目 radius 7,按下底 rowSelected)

/// 条目按下时铺一层 `rowSelected` 底色,圆角取 §5.2 的 **7**;
/// 松手即回到透明(移动端没有 hover,只表达按下)。
struct OrdoQuickAddItemStyle: ButtonStyle {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: OrdoRadius.quickAddItem, style: .continuous)
                    .fill(configuration.isPressed ? OrdoColor.rowSelected : Color.clear)
            )
            .animation(
                OrdoMotion.resolved(OrdoMotion.fastEase, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}
