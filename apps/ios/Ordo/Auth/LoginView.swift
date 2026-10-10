//
//  LoginView.swift
//  Ordo
//
//  登录页(UI 规范 §5.1 + 契约 §7.6)。
//
//  布局(整屏居中卡片,宽 400,高自适应,radius 16 + 12dp 投影;画布 = canvas + 极淡品牌光晕 ≤6%):
//    1. 品牌区:56 应用图标 + 「Ordo」(24/32 · 600)+ 「把今天理清楚」
//    2. 输入区:邮箱、口令(**带显示/隐藏切换**),浮动标签(聚焦时标签上移 12px 并转 accent)
//    3. 主按钮:高 44、radius 10、accent 填充;提交中禁用 + 16dp 转圈
//    4. 次要入口:「以游客身份继续」(`surface` 底 + hairline 描边,**不是**灰色小字)
//    5. 底部一行居中文本链接:登录态「还没有账号?注册」,注册态「已有账号?登录」
//    错误区:主按钮下方固定预留 20 高度;失败时 danger 文案 + 左右抖动(振幅 6px,320ms,衰减两次)
//
//  动效:进入 fade + 上移 12px(220ms);聚焦边框 120ms;主按钮按压 0.98(90ms);
//        提交中输入框与游客按钮一并禁用;登录成功由 RootView 做卡片淡出 → 主界面淡入。
//  硬约束:三个入口同时存在且游客与正式登录**体验对等**;触控目标 ≥44;错误不只靠颜色表达。
//

import SwiftUI

public struct LoginView: View {

    private let auth: OrdoAuthService
    /// 登录成功(会话已落盘)后由 RootView 打开主界面。
    private let onAuthenticated: (OrdoSessionRecord) -> Void

    @State private var form = OrdoLoginForm()
    @State private var appeared = false
    @State private var shakeTrigger: CGFloat = 0
    @FocusState private var focusedField: Field?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(auth: OrdoAuthService, onAuthenticated: @escaping (OrdoSessionRecord) -> Void) {
        self.auth = auth
        self.onAuthenticated = onAuthenticated
    }

    /// 两个输入框(浮动标签需要知道自己这一格是否聚焦)。
    public enum Field: Hashable {
        case email
        case password
    }

    public var body: some View {
        ZStack {
            OrdoColor.canvas.ignoresSafeArea()
            brandGlow

            ScrollView {
                card
                    .frame(maxWidth: OrdoMotion.Login.cardWidth)
                    .padding(.horizontal, OrdoSpacing.l)
                    .padding(.vertical, OrdoSpacing.xxl)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : OrdoMotion.Login.enterOffset)
        .onAppear {
            // 进入登录页:fade + 上移 12px,220ms。
            if let notice = auth.lastError {
                form.showMessage(notice)
            }
            withAnimation(OrdoMotion.resolved(OrdoMotion.Login.enter, reduceMotion: reduceMotion)) {
                appeared = true
            }
        }
    }

    // MARK: 背景光晕(透明度 ≤6%,不喧宾夺主)

    private var brandGlow: some View {
        RadialGradient(
            colors: [OrdoColor.accent.opacity(0.06), OrdoColor.accent.opacity(0)],
            center: .top,
            startRadius: 0,
            endRadius: 460
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: 卡片

    private var card: some View {
        VStack(spacing: OrdoSpacing.xl) {
            brand

            VStack(spacing: OrdoSpacing.m) {
                emailField
                passwordField
            }

            VStack(spacing: OrdoSpacing.s) {
                primaryButton
                errorArea
                guestButton
            }

            switchModeLink
        }
        .padding(.horizontal, OrdoSpacing.xl)
        .padding(.vertical, OrdoSpacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: OrdoRadius.loginCard, style: .continuous)
                .fill(OrdoColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrdoRadius.loginCard, style: .continuous)
                .stroke(OrdoColor.hairline, lineWidth: 1)
        )
        .ordoCardElevation()
        .modifier(OrdoShakeEffect(animatableData: shakeTrigger))
        .onChange(of: form.shakeToken) { _, _ in
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: OrdoMotion.Login.shakeDuration)) {
                shakeTrigger += 1
            }
        }
    }

    private var brand: some View {
        VStack(spacing: OrdoSpacing.s) {
            OrdoLogoMark(size: 56)
            Text("Ordo")
                .font(OrdoFont.loginBrand)
                .foregroundStyle(OrdoColor.textPrimary)
            Text("把今天理清楚")
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ordo,把今天理清楚")
    }

    // MARK: 输入区(浮动标签)

    private var emailField: some View {
        floatingField(
            title: "邮箱",
            text: $form.email,
            kind: .email,
            isSecure: false,
            trailing: { EmptyView() }
        )
        .keyboardType(.emailAddress)
        .textContentType(.username)
    }

    private var passwordField: some View {
        floatingField(
            title: "口令(至少 \(OrdoLoginForm.minimumPasswordLength) 位)",
            text: $form.password,
            kind: .password,
            isSecure: !form.isPasswordVisible,
            trailing: {
                Button {
                    form.togglePasswordVisibility()
                } label: {
                    Image(systemName: form.isPasswordVisible ? "eye.slash" : "eye")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OrdoColor.textSecondary)
                        .frame(width: OrdoSpacing.minTouchTarget, height: OrdoSpacing.minTouchTarget)
                }
                .buttonStyle(.plain)
                .disabled(form.isSubmitting)
                .accessibilityLabel(form.isPasswordVisible ? "隐藏口令" : "显示口令")
            }
        )
        .textContentType(.password)
    }

    private func floatingField<Trailing: View>(
        title: String,
        text: Binding<String>,
        kind: Field,
        isSecure: Bool,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let isFocused = focusedField == kind
        let isFloating = isFocused || !text.wrappedValue.isEmpty

        return HStack(spacing: OrdoSpacing.xs) {
            ZStack(alignment: .leading) {
                Text(title)
                    .font(OrdoFont.caption)
                    .foregroundStyle(isFocused ? OrdoColor.accent : OrdoColor.textSecondary)
                    .offset(y: isFloating ? -12 : 0)
                    .animation(OrdoMotion.resolved(OrdoMotion.Login.focus, reduceMotion: reduceMotion), value: isFloating)
                    .accessibilityHidden(true)

                Group {
                    if isSecure {
                        SecureField("", text: text)
                    } else {
                        TextField("", text: text)
                    }
                }
                .font(OrdoFont.body)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: kind)
                .disabled(form.isSubmitting)
                .offset(y: isFloating ? 6 : 0)
                .animation(OrdoMotion.resolved(OrdoMotion.Login.focus, reduceMotion: reduceMotion), value: isFloating)
                .accessibilityLabel(title)
            }
            .frame(height: 30)

            trailing()
        }
        .padding(.horizontal, OrdoSpacing.m)
        .padding(.vertical, OrdoSpacing.s)
        .background(
            RoundedRectangle(cornerRadius: OrdoRadius.field, style: .continuous)
                .fill(OrdoColor.canvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrdoRadius.field, style: .continuous)
                .stroke(isFocused ? OrdoColor.accent : OrdoColor.hairline, lineWidth: isFocused ? 1.5 : 1)
        )
        .animation(OrdoMotion.resolved(OrdoMotion.Login.focus, reduceMotion: reduceMotion), value: isFocused)
    }

    // MARK: 主按钮

    private var primaryButton: some View {
        Button {
            submit()
        } label: {
            ZStack {
                if form.isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(width: OrdoMotion.Login.spinnerSize, height: OrdoMotion.Login.spinnerSize)
                } else {
                    Text(form.mode.primaryTitle)
                        .font(OrdoFont.bodyEmphasis)
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, minHeight: OrdoRadius.primaryButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: OrdoRadius.primaryButton, style: .continuous)
                    .fill(OrdoColor.accent)
            )
            .opacity(form.isSubmitting ? 0.6 : 1)
        }
        .buttonStyle(OrdoLoginPressStyle())
        .disabled(form.isSubmitting)
        .accessibilityLabel(form.mode.primaryTitle)
        .accessibilityHint(form.mode == .login ? "使用邮箱与口令登录" : "注册新账号")
    }

    // MARK: 错误区(固定预留 20 高度)

    private var errorArea: some View {
        Text(form.errorMessage ?? " ")
            .font(OrdoFont.caption)
            .foregroundStyle(OrdoColor.danger)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(height: OrdoMotion.Login.errorReservedHeight)
            .lineLimit(1)
            .accessibilityLabel(form.errorMessage ?? "")
    }

    // MARK: 次要入口:以游客身份继续(与主按钮同级)

    private var guestButton: some View {
        Button {
            continueAsGuest()
        } label: {
            Text("以游客身份继续")
                .font(OrdoFont.bodyEmphasis)
                .foregroundStyle(OrdoColor.accent)
                .frame(maxWidth: .infinity, minHeight: OrdoRadius.primaryButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: OrdoRadius.primaryButton, style: .continuous)
                        .fill(OrdoColor.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OrdoRadius.primaryButton, style: .continuous)
                        .stroke(OrdoColor.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(OrdoLoginPressStyle())
        .disabled(!form.canUseSecondaryEntries)
        .accessibilityLabel("以游客身份继续")
        .accessibilityHint("创建匿名账号,同样可以多端同步")
    }

    // MARK: 底部模式切换

    private var switchModeLink: some View {
        HStack(spacing: OrdoSpacing.xs) {
            Text(form.mode.switchPrompt)
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.textSecondary)
            Button {
                form.toggleMode()
                form.clearError()
            } label: {
                Text(form.mode.switchActionTitle)
                    .font(OrdoFont.captionEmphasis)
                    .foregroundStyle(OrdoColor.accent)
                    .frame(minHeight: OrdoSpacing.minTouchTarget)
            }
            .buttonStyle(.plain)
            .disabled(form.isSubmitting)
            .accessibilityLabel(form.mode.switchActionTitle)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 动作

    private func submit() {
        guard form.beginSubmission() else { return }
        focusedField = nil
        Task { @MainActor in
            defer { form.finishSubmission() }
            do {
                let session: OrdoSessionRecord
                switch form.mode {
                case .login:
                    session = try await auth.login(email: form.normalizedEmail, password: form.password)
                case .register:
                    session = try await auth.register(email: form.normalizedEmail, password: form.password)
                }
                onAuthenticated(session)
            } catch {
                form.fail(OrdoAuthService.hint(for: error))
            }
        }
    }

    private func continueAsGuest() {
        guard form.beginGuestSubmission() else { return }
        focusedField = nil
        Task { @MainActor in
            defer { form.finishSubmission() }
            do {
                let session = try await auth.continueAsGuest()
                onAuthenticated(session)
            } catch {
                form.fail(OrdoAuthService.hint(for: error))
            }
        }
    }
}

// MARK: - 按压反馈(主按钮 scale → 0.98,90ms)

struct OrdoLoginPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? OrdoMotion.Login.pressScale : 1)
            .animation(OrdoMotion.resolved(OrdoMotion.Login.press, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

// MARK: - 错误抖动(振幅 6px,320ms,衰减两次)

/// `animatableData` 每次失败 +1,`effectValue` 用两次正弦周期 + 线性衰减表达「抖动并衰减」。
struct OrdoShakeEffect: GeometryEffect {
    var travel: CGFloat = OrdoMotion.Login.shakeAmplitude
    var animatableData: CGFloat

    private var cycles: CGFloat { CGFloat(OrdoMotion.Login.shakeCycles) * 2 }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let decay = max(0, 1 - animatableData)
        let offset = travel * sin(animatableData * .pi * cycles) * decay
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}
