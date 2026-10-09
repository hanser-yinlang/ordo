//
//  GroupHeaderView.swift
//  Ordo
//
//  分组标题(设计规范 §3/§4)。
//
//  · 普通分组:13/18 500,`text.secondary`,右侧计数;
//  · 今晚分区:琥珀色(`accent.tonight`);
//  · 计划中的某一天:标题为「今天 · 周三」这类日期标签;
//  · 项目内的标题(Heading):可折叠、可重命名(重命名入口由项目视图提供)。
//

import SwiftUI

public struct GroupHeaderView: View {

    public var title: String
    public var kind: OrdoSectionKind
    public var count: Int
    public var isCollapsible: Bool
    public var isCollapsed: Bool
    public var onToggle: (() -> Void)?
    public var onAdd: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        title: String,
        kind: OrdoSectionKind = .plain,
        count: Int,
        isCollapsible: Bool = false,
        isCollapsed: Bool = false,
        onToggle: (() -> Void)? = nil,
        onAdd: (() -> Void)? = nil
    ) {
        self.title = title
        self.kind = kind
        self.count = count
        self.isCollapsible = isCollapsible
        self.isCollapsed = isCollapsed
        self.onToggle = onToggle
        self.onAdd = onAdd
    }

    private var tint: Color {
        switch kind {
        case .tonight: return OrdoColor.tonight
        case .agenda: return OrdoColor.textSecondary
        case .later: return OrdoColor.textTertiary
        default: return OrdoColor.textSecondary
        }
    }

    private var font: Font {
        switch kind {
        case .heading: return OrdoFont.bodyEmphasis
        case .day: return OrdoFont.captionEmphasis
        default: return OrdoFont.captionEmphasis
        }
    }

    public var body: some View {
        HStack(spacing: OrdoSpacing.s) {
            if isCollapsible {
                Button {
                    onToggle?()
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OrdoColor.textTertiary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "展开\(title)" : "折叠\(title)")
            }

            Text(title)
                .font(font)
                .foregroundStyle(kind == .heading ? OrdoColor.textPrimary : tint)
                .lineLimit(1)

            Spacer(minLength: OrdoSpacing.s)

            if count > 0 {
                Text("\(count)")
                    .font(OrdoFont.caption)
                    .foregroundStyle(OrdoColor.textSecondary)
                    .monospacedDigit()
            }

            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OrdoColor.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("在\(title)中新建待办")
            }
        }
        .padding(.horizontal, OrdoSpacing.m)
        .padding(.top, kind == .tonight ? OrdoSpacing.m : OrdoSpacing.s)
        .padding(.bottom, OrdoSpacing.xs)
        .animation(reduceMotion ? nil : OrdoMotion.expand, value: isCollapsed)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title),\(count) 项")
    }
}

/// 分区分隔线(计划视图用,规范 §2.1 `line.hairline`)。
public struct OrdoHairline: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(OrdoColor.hairline)
            .frame(height: 1)
    }
}
