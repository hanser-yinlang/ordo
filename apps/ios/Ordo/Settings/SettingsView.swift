//
//  SettingsView.swift
//  Ordo
//
//  设置(设计规范 §2.1 外观 / §4 状态 / §7 平台映射 / §8 无障碍)。
//
//  分区:外观 · 通知 · 同步 · 数据 · 快捷键 · 关于。
//
//  v1.3 移除项(产品决定:不再需要登录):「账号」区块(当前账号 / 账号类型 / userId / 本地数据目录)、
//  「退出登录」、「升级为正式账号」表单、以及「服务端地址」显示行。
//  服务端地址改为**隐藏覆盖**:读 `UserDefaults` 的 `ordo.apiBaseURL`,默认仍是本机开发地址;
//  改法见 `apps/ios/README.md`(设置页不再提供输入框)。
//
//  所有文案为简体中文;通知权限说明与 Info.plist 的 NSUserNotificationUsageDescription 一致。
//

import SwiftUI

public struct SettingsView: View {

    private let shell: ShellViewModel
    private let environment: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @State private var showsResetConfirm = false

    public init(shell: ShellViewModel, environment: AppEnvironment) {
        self.shell = shell
        self.environment = environment
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OrdoSpacing.xl) {
                    appearanceSection
                    notificationSection
                    syncSection
                    dataSection
                    shortcutsSection
                    aboutSection
                }
                .padding(OrdoSpacing.l)
                .frame(maxWidth: OrdoSpacing.contentMaxWidth, alignment: .leading)
            }
            .background(OrdoColor.canvas)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(OrdoColor.accent)
                }
            }
        }
        .alert("重置为示例数据?", isPresented: $showsResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                Task { await environment.resetToSeedData() }
            }
        } message: {
            Text("当前本地数据会被清空,并恢复为内置示例数据。此操作不可撤销。")
        }
    }

    // MARK: 外观

    private var appearanceSection: some View {
        section("外观") {
            Picker("主题", selection: Binding(
                get: { shell.theme },
                set: { newValue in
                    shell.theme = newValue
                    Task { await environment.setTheme(newValue) }
                }
            )) {
                ForEach(OrdoThemePreference.allCases, id: \.self) { preference in
                    Text(preference.label).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("主题偏好")

            Text("系统开启「减弱动态效果」时,所有动效会降为 0ms 直接切换。")
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.textSecondary)
        }
    }

    // MARK: 通知

    private var notificationSection: some View {
        section("通知") {
            HStack {
                Text("提醒权限")
                    .font(OrdoFont.body)
                Spacer()
                Text(notificationStatusText)
                    .font(OrdoFont.caption)
                    .foregroundStyle(environment.notificationAuthorized ? OrdoColor.success : OrdoColor.danger)
            }
            .accessibilityElement(children: .combine)

            Text(ReminderScheduler.permissionExplanation)
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.textSecondary)

            if !environment.notificationAuthorized {
                Button {
                    Task {
                        environment.requestNotificationPermission()
                    }
                } label: {
                    Text("请求通知权限")
                        .font(OrdoFont.captionEmphasis)
                        .foregroundStyle(OrdoColor.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("请求通知权限")

                Text(ReminderScheduler.permissionDeniedHint)
                    .font(OrdoFont.caption)
                    .foregroundStyle(OrdoColor.textTertiary)
            }
        }
    }

    private var notificationStatusText: String {
        environment.notificationAuthorized ? "已开启" : "未开启"
    }

    // MARK: 同步(v1.3:没有账号,只有静默匿名会话)

    private var syncSection: some View {
        section("同步") {
            HStack {
                Text("状态")
                    .font(OrdoFont.body)
                Spacer()
                Text(shell.syncLabel)
                    .font(OrdoFont.caption)
                    .foregroundStyle(shell.syncIsProblem ? OrdoColor.danger : OrdoColor.textSecondary)
            }

            HStack(spacing: OrdoSpacing.m) {
                Button("立即同步") {
                    Task { await environment.sync?.syncNow(reason: "手动") }
                }
                .font(OrdoFont.captionEmphasis)
                .foregroundStyle(OrdoColor.accent)
                .buttonStyle(.plain)
            }

            Text("云端同步在后台自动进行:首次启动会静默建立一个匿名账号,不需要注册或登录。")
                .font(OrdoFont.micro)
                .foregroundStyle(OrdoColor.textTertiary)

            Text("即使暂时连不上服务器,本地清单也照常可用,联网后会自动同步。")
                .font(OrdoFont.micro)
                .foregroundStyle(OrdoColor.textTertiary)
        }
    }

    // MARK: 数据

    private var dataSection: some View {
        section("数据") {
            HStack {
                Text("本地待办")
                    .font(OrdoFont.body)
                Spacer()
                Text("\(environment.snapshot.todos.count) 条")
                    .font(OrdoFont.caption)
                    .foregroundStyle(OrdoColor.textSecondary)
                    .monospacedDigit()
            }
            HStack {
                Text("待上传变更")
                    .font(OrdoFont.body)
                Spacer()
                Text("\(environment.sync?.pendingCount ?? 0) 条")
                    .font(OrdoFont.caption)
                    .foregroundStyle(OrdoColor.textSecondary)
                    .monospacedDigit()
            }
            HStack {
                Text("数据契约版本")
                    .font(OrdoFont.body)
                Spacer()
                Text("schemaVersion \(OrdoSchema.version)")
                    .font(OrdoFont.caption)
                    .foregroundStyle(OrdoColor.textSecondary)
            }

            if let lastSyncedAt = environment.sync?.lastSyncedAt {
                HStack {
                    Text("上次同步")
                        .font(OrdoFont.body)
                    Spacer()
                    Text(OrdoDateFormatter.shared.reminderLabel(
                        OrdoDateFormatter.shared.isoDayTime(Date(timeIntervalSince1970: Double(lastSyncedAt) / 1000))
                    ))
                    .font(OrdoFont.caption)
                    .foregroundStyle(OrdoColor.textSecondary)
                }
            }

            Button(role: .destructive) {
                showsResetConfirm = true
            } label: {
                Text("重置为示例数据")
                    .font(OrdoFont.captionEmphasis)
                    .foregroundStyle(OrdoColor.danger)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重置为示例数据")
        }
    }

    // MARK: 快捷键

    private var shortcutsSection: some View {
        section("快捷键(外接键盘)") {
            ForEach(Self.shortcuts, id: \.keys) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.keys)
                        .font(OrdoFont.captionEmphasis)
                        .foregroundStyle(OrdoColor.textPrimary)
                        .frame(width: 96, alignment: .leading)
                    Text(item.action)
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textSecondary)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.keys):\(item.action)")
            }
        }
    }

    private static let shortcuts: [(keys: String, action: String)] = [
        ("⌘N", "新建待办"),
        ("⌘K", "快找"),
        ("1…6", "切换收件箱/今天/计划/随时/某天/日志簿"),
        ("↑ ↓", "上下移动选中行"),
        ("Enter", "打开详情"),
        ("Space", "切换完成状态"),
        ("⌫", "删除选中行"),
        ("⌘⇧D", "循环切换外观"),
        ("Esc", "关闭浮层 / 收起详情")
    ]

    // MARK: 关于

    private var aboutSection: some View {
        section("关于") {
            HStack {
                Text("应用")
                    .font(OrdoFont.body)
                Spacer()
                Text("序 Ordo · iOS 1.0.0")
                    .font(OrdoFont.caption)
                    .foregroundStyle(OrdoColor.textSecondary)
            }
            Text("把今天理清楚 · Make today clear.")
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.textSecondary)
            Text("业务核心由 KMP 共享模块 shared/core 提供(契约 §3–§6 的唯一实现),iOS 端只负责展示与系统集成。")
                .font(OrdoFont.micro)
                .foregroundStyle(OrdoColor.textTertiary)
        }
    }

    // MARK: 组件

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: OrdoSpacing.s) {
            Text(title)
                .font(OrdoFont.micro)
                .tracking(OrdoFont.groupTitleTracking)
                .foregroundStyle(OrdoColor.textSecondary)
            VStack(alignment: .leading, spacing: OrdoSpacing.s) {
                content()
            }
            .padding(OrdoSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OrdoRadius.card, style: .continuous)
                    .fill(OrdoColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OrdoRadius.card, style: .continuous)
                    .stroke(OrdoColor.hairline, lineWidth: 1)
            )
        }
    }
}
