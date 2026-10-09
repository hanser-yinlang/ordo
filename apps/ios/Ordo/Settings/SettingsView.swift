//
//  SettingsView.swift
//  Ordo
//
//  设置(设计规范 §2.1 外观 / §4 状态 / §7 平台映射 / §8 无障碍)。
//
//  分区:外观 · 通知 · 同步与账号 · 数据 · 快捷键 · 关于。
//  所有文案为简体中文;通知权限说明与 Info.plist 的 NSUserNotificationsUsageDescription 一致。
//

import SwiftUI

public struct SettingsView: View {

    private let shell: ShellViewModel
    private let environment: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var showsResetConfirm = false
    @State private var signedInEmail: String?

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
        .task {
            signedInEmail = await environment.currentUserEmail()
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

    // MARK: 同步与账号

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

            if let email = signedInEmail {
                HStack {
                    Text("账号")
                        .font(OrdoFont.body)
                    Spacer()
                    Text(email)
                        .font(OrdoFont.caption)
                        .foregroundStyle(OrdoColor.textSecondary)
                }

                HStack(spacing: OrdoSpacing.m) {
                    Button("立即同步") {
                        Task { await environment.sync?.syncNow(reason: "手动") }
                    }
                    .font(OrdoFont.captionEmphasis)
                    .foregroundStyle(OrdoColor.accent)
                    .buttonStyle(.plain)

                    Button("退出登录") {
                        Task {
                            await environment.signOut()
                            signedInEmail = nil
                        }
                    }
                    .font(OrdoFont.captionEmphasis)
                    .foregroundStyle(OrdoColor.danger)
                    .buttonStyle(.plain)
                }
            } else {
                Text("登录后可在多台设备间同步。数据始终先保存在本机,离线也能正常使用。")
                    .font(OrdoFont.caption)
                    .foregroundStyle(OrdoColor.textSecondary)

                TextField("邮箱", text: $email)
                    .textFieldStyle(.plain)
                    .font(OrdoFont.body)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .padding(OrdoSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: OrdoRadius.field, style: .continuous)
                            .fill(OrdoColor.surface)
                    )
                    .accessibilityLabel("邮箱")

                SecureField("密码(至少 8 位)", text: $password)
                    .textFieldStyle(.plain)
                    .font(OrdoFont.body)
                    .padding(OrdoSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: OrdoRadius.field, style: .continuous)
                            .fill(OrdoColor.surface)
                    )
                    .accessibilityLabel("密码")

                HStack(spacing: OrdoSpacing.m) {
                    Button("登录") { authenticate(register: false) }
                        .font(OrdoFont.captionEmphasis)
                        .foregroundStyle(.white)
                        .padding(.horizontal, OrdoSpacing.m)
                        .padding(.vertical, OrdoSpacing.xs)
                        .background(Capsule().fill(OrdoColor.accent))
                        .buttonStyle(.plain)
                        .disabled(isWorking)

                    Button("注册") { authenticate(register: true) }
                        .font(OrdoFont.captionEmphasis)
                        .foregroundStyle(OrdoColor.accent)
                        .buttonStyle(.plain)
                        .disabled(isWorking)

                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            Text("服务端地址:\(OrdoAPIEnvironment.default.baseURL.absoluteString)")
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

    private func authenticate(register: Bool) {
        guard let api = environment.authAPI else { return }
        guard !email.isEmpty, password.count >= 8 else {
            environment.toast("请输入邮箱,密码至少 8 位", kind: .failure)
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let deviceName = await environment.deviceName()
                let session = register
                    ? try await api.register(email: email, password: password, deviceName: deviceName)
                    : try await api.login(email: email, password: password, deviceName: deviceName)
                await environment.handleSignedIn(session)
                signedInEmail = session.user.email
                environment.toast(register ? "注册成功,已开始同步" : "登录成功", kind: .success)
            } catch let error as OrdoAPIError {
                environment.toast(error.localizedHint, kind: .failure)
            } catch {
                environment.toast(error.localizedDescription, kind: .failure)
            }
        }
    }
}
