//
//  SidebarView.swift
//  Ordo
//
//  侧栏(设计规范 §3 布局 / §4 组件规格)。
//
//  结构:固定清单(收件箱/今天/计划/随时/某天/日志簿,带计数)
//       → 区域(可折叠,内含项目:18×18 进度环 + 未完成数)
//       → 标签(彩色圆点 + 计数)
//  规格:项高 34、左内边距 12、图标 18、文字 15/22;选中态 = accent 12% 底 + 图标着主色。
//

import SwiftUI

public struct SidebarView: View {

    private let shell: ShellViewModel
    private let environment: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var collapsedAreas: Set<String> = []
    @State private var showsSomedayTags = true

    public init(shell: ShellViewModel, environment: AppEnvironment) {
        self.shell = shell
        self.environment = environment
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 品牌头
            HStack(spacing: OrdoSpacing.s) {
                OrdoLogoMark(size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text("序")
                        .font(OrdoFont.bodyEmphasis)
                        .foregroundStyle(OrdoColor.textPrimary)
                    Text("把今天理清楚")
                        .font(OrdoFont.micro)
                        .foregroundStyle(OrdoColor.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OrdoSpacing.m)
            .padding(.top, OrdoSpacing.m)
            .padding(.bottom, OrdoSpacing.s)

            ScrollView {
                VStack(alignment: .leading, spacing: OrdoSpacing.xs) {
                    pinnedSection
                    areaSection
                    tagSection
                }
                .padding(.horizontal, OrdoSpacing.s)
                .padding(.bottom, OrdoSpacing.xl)
            }

            Spacer(minLength: 0)

            Divider().overlay(OrdoColor.hairline)

            HStack(spacing: OrdoSpacing.xs) {
                Button {
                    shell.isSettingsPresented = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开设置")

                Spacer(minLength: 0)

                Button {
                    shell.isFastFindPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OrdoColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("快找")
            }
            .padding(.horizontal, OrdoSpacing.m)
            .padding(.vertical, OrdoSpacing.s)
        }
    }

    // MARK: 固定清单

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(OrdoListKind.pinnedOrder, id: \.self) { kind in
                sidebarRow(
                    title: kind.displayName,
                    systemImage: kind.systemImage,
                    count: environment.counts.count(for: kind),
                    isSelected: shell.selection.kind == kind && shell.selection.id == nil,
                    tint: kind == .today ? OrdoColor.accent : OrdoColor.textSecondary
                ) {
                    shell.open(OrdoListQuery(kind: kind))
                }
            }
        }
        .padding(.vertical, OrdoSpacing.xs)
    }

    // MARK: 区域与项目

    private var areaSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader(
                title: "区域",
                trailing: {
                    Button {
                        createArea()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OrdoColor.textSecondary)
                    .accessibilityLabel("新建区域")
                }
            )

            ForEach(shell.projectsByArea, id: \.area.id) { group in
                areaRow(area: group.area, projectCount: group.projects.count)
                if !collapsedAreas.contains(group.area.id) {
                    ForEach(group.projects, id: \.id) { project in
                        projectRow(project)
                    }
                    Button {
                        createProject(in: group.area.id)
                    } label: {
                        Text("＋ 新建项目")
                            .font(OrdoFont.caption)
                            .foregroundStyle(OrdoColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, OrdoSpacing.xl)
                    .padding(.vertical, OrdoSpacing.xs)
                    .accessibilityLabel("在\(group.area.name)中新建项目")
                }
            }

            ForEach(shell.inboxProjects, id: \.id) { project in
                projectRow(project)
            }
        }
    }

    private func areaRow(area: OrdoArea, projectCount: Int) -> some View {
        HStack(spacing: OrdoSpacing.s) {
            Button {
                toggle(area.id)
            } label: {
                Image(systemName: collapsedAreas.contains(area.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(OrdoColor.textTertiary)
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsedAreas.contains(area.id) ? "展开\(area.name)" : "折叠\(area.name)")

            Circle()
                .fill(OrdoColor.hex(area.color))
                .frame(width: 8, height: 8)

            Text(area.name)
                .font(OrdoFont.body)
                .foregroundStyle(OrdoColor.textPrimary)
                .lineLimit(1)

            Spacer(minLength: OrdoSpacing.xs)

            // 说明:KMP `SidebarCounts` 不含区域计数,侧栏区域行不显示数字,
            // 避免在 Swift 侧重实现一遍「区域视图」的查询规则。
            Text("\(projectCount)")
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.textTertiary)
                .monospacedDigit()
        }
        .padding(.leading, OrdoSpacing.s)
        .padding(.trailing, OrdoSpacing.m)
        .frame(height: OrdoSpacing.sidebarItemHeight)
        .contentShape(Rectangle())
        .onTapGesture { shell.open(.area(area.id)) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(area.name),\(projectCount) 个项目")
    }

    private func projectRow(_ project: OrdoProject) -> some View {
        // 进度来自 KMP 核心 `projectProgress(projectId:)`,Swift 侧不重算。
        let fraction = environment.counts.progress(project.id)
        let isSelected = shell.selection.kind == .project && shell.selection.id == project.id
        return HStack(spacing: OrdoSpacing.s) {
            ProgressRingView(
                fraction: fraction,
                size: OrdoSpacing.progressRingSize,
                lineWidth: OrdoSpacing.progressRingLineWidth,
                showsPulse: fraction >= 1
            )
            .padding(.leading, 20)

            Text(project.name)
                .font(OrdoFont.body)
                .foregroundStyle(OrdoColor.textPrimary)
                .lineLimit(1)

            Spacer(minLength: OrdoSpacing.xs)

            Text("\(environment.counts.projectCount(project.id))")
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.textSecondary)
                .monospacedDigit()
        }
        .padding(.trailing, OrdoSpacing.m)
        .frame(height: OrdoSpacing.sidebarItemHeight)
        .background(
            RoundedRectangle(cornerRadius: OrdoRadius.row, style: .continuous)
                .fill(isSelected ? OrdoColor.selectionFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { shell.open(.project(project.id)) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.name),进度 \(Int(fraction * 100))%")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: 标签

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader(
                title: "标签",
                trailing: {
                    Button {
                        showsSomedayTags.toggle()
                    } label: {
                        Image(systemName: showsSomedayTags ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OrdoColor.textTertiary)
                    .accessibilityLabel(showsSomedayTags ? "折叠标签" : "展开标签")
                }
            )

            if showsSomedayTags {
                ForEach(shell.tags, id: \.id) { tag in
                    let isSelected = shell.selection.kind == .tag && shell.selection.id == tag.name
                    HStack(spacing: OrdoSpacing.s) {
                        Circle()
                            .fill(OrdoColor.hex(tag.color))
                            .frame(width: 8, height: 8)
                            .padding(.leading, 20)
                        Text(tag.name)
                            .font(OrdoFont.body)
                            .foregroundStyle(OrdoColor.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: OrdoSpacing.xs)
                        Text("\(environment.counts.tagCount(tag.name))")
                            .font(OrdoFont.caption)
                            .foregroundStyle(OrdoColor.textSecondary)
                            .monospacedDigit()
                    }
                    .padding(.trailing, OrdoSpacing.m)
                    .frame(height: OrdoSpacing.sidebarItemHeight)
                    .background(
                        RoundedRectangle(cornerRadius: OrdoRadius.row, style: .continuous)
                            .fill(isSelected ? OrdoColor.selectionFill : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { shell.open(.tag(tag.name)) }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("标签 \(tag.name)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
    }

    // MARK: 通用行

    private func sidebarRow(
        title: String,
        systemImage: String,
        count: Int,
        isSelected: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: OrdoSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .frame(width: OrdoSpacing.sidebarIconSize, height: OrdoSpacing.sidebarIconSize)
                .foregroundStyle(isSelected ? OrdoColor.accent : tint)

            Text(title)
                .font(OrdoFont.body)
                .foregroundStyle(OrdoColor.textPrimary)

            Spacer(minLength: OrdoSpacing.xs)

            Text("\(count)")
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.textSecondary)
                .monospacedDigit()
        }
        .padding(.leading, OrdoSpacing.sidebarItemLeading)
        .padding(.trailing, OrdoSpacing.m)
        .frame(height: OrdoSpacing.sidebarItemHeight)
        .background(
            RoundedRectangle(cornerRadius: OrdoRadius.row, style: .continuous)
                .fill(isSelected ? OrdoColor.selectionFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title),\(count) 项")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: "打开", action)
    }

    private func sectionHeader<Trailing: View>(title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(OrdoFont.micro)
                .tracking(OrdoFont.groupTitleTracking)
                .foregroundStyle(OrdoColor.textSecondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, OrdoSpacing.m)
        .padding(.top, OrdoSpacing.m)
        .padding(.bottom, OrdoSpacing.xs)
    }

    // MARK: 动作

    private func toggle(_ areaId: String) {
        withAnimation(OrdoMotion.resolved(OrdoMotion.expand, reduceMotion: reduceMotion)) {
            if collapsedAreas.contains(areaId) {
                collapsedAreas.remove(areaId)
            } else {
                collapsedAreas.insert(areaId)
            }
        }
    }

    private func createArea() {
        let name = "新区域 \(environment.snapshot.areas.count + 1)"
        _ = environment.createArea(name: name)
        environment.toast("已创建区域:\(name)", kind: .success)
    }

    private func createProject(in areaId: String) {
        let name = "新项目 \(environment.snapshot.projects.count + 1)"
        let project = environment.createProject(name: name, areaId: areaId)
        shell.open(.project(project.id))
    }
}

// MARK: - 品牌标记

/// Logo 概念(规范 §1):一个开口的圆环 + 一条向内的短划线。
public struct OrdoLogoMark: View {
    public var size: CGFloat
    public var tint: Color

    public init(size: CGFloat = 24, tint: Color = OrdoColor.accent) {
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(tint, style: StrokeStyle(lineWidth: max(1.6, size * 0.11), lineCap: .round))
                .rotationEffect(.degrees(-90))
            Capsule()
                .fill(tint)
                .frame(width: size * 0.34, height: max(1.6, size * 0.11))
                .offset(x: -size * 0.12)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
