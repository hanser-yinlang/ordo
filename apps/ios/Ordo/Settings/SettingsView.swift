//
//  SettingsView.swift
//  Ordo
//
//  设置(设计规范 §2.1 外观 / §4 状态 / §7 平台映射 / §8 无障碍)。
//
//  分区:外观 · 通知 · 同步与账号 · 数据 · 快捷键 · 关于。
//  「同步与账号」显示**当前账号**(邮箱或「游客」)、账号类型、userId、本地数据目录与退出登录
//  (契约 §7.6.3:退出只清会话、保留目录);游客额外提供「升级为正式账号」。
//  所有文案为简体中文;通知权限说明与 Info.plist 的 NSUserNotificationUsageDescription 一致。
//

import SwiftUI

public struct SettingsView: View {

    private let shell: ShellViewModel
    private let environment: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @State private var upgradeEmail = ""
    @State private var upgradePassword = ""
    @State private var isUpgrading = false
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

    // MARK: 同步与账号(契约 §7.6)

    private var syncSection: some View {
        section("同步与账号") {
            HStack {
                Text("状态")
                    .font(OrdoFont.body)
                Spacer()
                Text(shell.syncLabel)
                    .font(OrdoFont.caption)
                    .foregroundStyle(shell.syncIsProblem ? OrdoColor.danger : OrdoColor.textSecondary)
            }

            if let session = environment.session {
                HStack {
                    Text("当前账号")
                        .font(OrdoFont.body)
                    Spacer()
                    Text(session.displayName())
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textSecondary)
                }

                HStack {
                    Text("账号类型")
                        .font(OrdoFont.body)
                    Spacer()
                    Text(session.isGuest ? "游客(数据同样云端同步)" : "正式账号")
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textSecondary)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("userId")
                        .font(OrdoFont.body)
                    Spacer()
                    Text(session.userId)
                        .font(OrdoFont.micro)
                        .foregroundStyle(OrdoColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // 契约 §7.6.3 硬约束的可核对证据:每个账号一个目录,换账号必然换目录。
                HStack(alignment: .firstTextBaseline) {
                    Text("本地数据目录")
                        .font(OrdoFont.body)
                    Spacer()
                    Text(environment.userDataDirectory?.lastPathComponent ?? "内存模式(未落盘)")
                        .font(OrdoFont.micro)
                        .foregroundStyle(OrdoColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: OrdoSpacing.m) {
                    Button("立即同步") {
                        Task { await environment.sync?.syncNow(reason: "手动") }
                    }
                    .font(OrdoFont.captionEmphasis)
                    .foregroundStyle(OrdoColor.accent)
                    .buttonStyle(.plain)

                    Button("退出登录") {
                        Task { await environment.signOut() }
                    }
                    .font(OrdoFont.captionEmphasis)
                    .foregroundStyle(OrdoColor.danger)
                    .buttonStyle(.plain)
                }

                Text("退出登录只清除登录态,本地数据目录会保留;下次同一账号登录时数据仍在(离线可用)。")
                    .font(OrdoFont.micro)
                    .foregroundStyle(OrdoColor.textTertiary)

                if session.isGuest {
                    upgradeForm
                }
            } else {
                Text("当前没有登录会话。回到登录页可以选择登录、注册或以游客身份继续。")
                    .font(OrdoFont.caption)
                    .foregroundStyle(OrdoColor.textSecondary)
            }

            Text("服务端地址:\(OrdoAPIEnvironment.default.baseURL.absoluteString)")
                .font(OrdoFont.micro)
                .foregroundStyle(OrdoColor.textTertiary)
        }
    }

    /// 游客 → 正式账号(契约 §7.6.2:`userId` 与数据不变,只补邮箱口令)。
    private var upgradeForm: some View {
        VStack(alignment: .leading, spacing: OrdoSpacing.s) {
            Text("升级为正式账号")
                .font(OrdoFont.captionEmphasis)
                .foregroundStyle(OrdoColor.textPrimary)

            TextField("邮箱", text: $upgradeEmail)
                .textFieldStyle(.plain)
                .font(OrdoFont.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .padding(OrdoSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: OrdoRadius.field, style: .continuous)
                        .fill(OrdoColor.canvas)
                )
                .accessibilityLabel("升级邮箱")

            SecureField("口令(至少 8 位)", text: $upgradePassword)
                .textFieldStyle(.plain)
                .font(OrdoFont.body)
                .padding(OrdoSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: OrdoRadius.field, style: .continuous)
                        .fill(OrdoColor.canvas)
                )
                .accessibilityLabel("升级口令")

            Button("升级") { upgrade() }
                .font(OrdoFont.captionEmphasis)
                .foregroundStyle(.white)
                .padding(.horizontal, OrdoSpacing.m)
                .padding(.vertical, OrdoSpacing.xs)
                .background(Capsule().fill(OrdoColor.accent))
                .buttonStyle(.plain)
                .disabled(isUpgrading)

            Text("升级后 userId 与全部数据不变,只是补上邮箱口令,可在其他设备登录。")
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

    // MARK: 动作

    /// 契约 §7.6.2:游客升级为正式账号。邮箱被占用时服务端返回 `AUTH_EMAIL_TAKEN`。
    private func upgrade() {
        let email = upgradeEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OrdoLoginForm.looksLikeEmail(email), upgradePassword.count >= OrdoLoginForm.minimumPasswordLength else {
            environment.toast("请输入有效邮箱,口令至少 \(OrdoLoginForm.minimumPasswordLength) 位", kind: .failure)
            return
        }
        isUpgrading = true
        Task {
            defer { isUpgrading = false }
            do {
                let session = try await environment.auth.upgrade(email: email, password: upgradePassword)
                environment.toast("已升级为正式账号:\(session.displayName())", kind: .success)
                upgradePassword = ""
            } catch let error as OrdoAPIError {
                environment.toast(error.localizedHint, kind: .failure)
            } catch {
                environment.toast(error.localizedDescription, kind: .failure)
            }
        }
    }
}
