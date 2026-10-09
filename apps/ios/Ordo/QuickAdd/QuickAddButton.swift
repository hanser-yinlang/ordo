//
//  QuickAddButton.swift
//  Ordo
//
//  快加号(设计规范 §1.2「QuickAdd」/ §4「快加号」)。
//
//  规格:直径 52,`accent.primary` 底 + 白色加号,阴影 `elev.sheet`;
//        按住展开菜单(新建待办 / 项目 / 区域 / 标题)。
//  交互:单击 = 在当前清单新建待办(打开行内输入框);
//        长按 = 菜单;在项目内额外提供「新建标题」。
//

import SwiftUI

public struct QuickAddButton: View {

    private let shell: ShellViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false

    public init(shell: ShellViewModel) {
        self.shell = shell
    }

    public var body: some View {
        Button {
            shell.requestComposer = true
        } label: {
            ZStack {
                Circle()
                    .fill(OrdoColor.accent)
                    .frame(width: OrdoSpacing.quickAddDiameter, height: OrdoSpacing.quickAddDiameter)
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(isPressed ? 0.94 : 1)
            .ordoQuickAddElevation()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                shell.requestComposer = true
            } label: {
                Label("新建待办", systemImage: "plus.circle")
            }

            Button {
                createProject()
            } label: {
                Label("新建项目", systemImage: "circle.dashed")
            }

            Button {
                createArea()
            } label: {
                Label("新建区域", systemImage: "square.grid.2x2")
            }

            if shell.selection.kind == .project {
                Button {
                    createHeading()
                } label: {
                    Label("新建标题", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(OrdoMotion.resolved(OrdoMotion.fastEase, reduceMotion: reduceMotion)) { isPressed = true }
                }
                .onEnded { _ in
                    withAnimation(OrdoMotion.resolved(OrdoMotion.fastEase, reduceMotion: reduceMotion)) { isPressed = false }
                }
        )
        .accessibilityLabel("快加号:新建待办")
        .accessibilityHint("长按可选择新建项目、区域或标题")
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
