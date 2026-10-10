//
//  LoginModel.swift
//  Ordo
//
//  UI 规范 §5.1 登录页的**纯状态机**(不 import SwiftUI,便于在 XCTest 里逐条断言):
//    · 两种模式(登录 / 注册)与三个入口(登录 / 注册 / 以游客身份继续);
//    · 输入校验(邮箱形状 + 口令 ≥ 8,契约 §9「口令最小长度 8」);
//    · 提交中禁用、错误抖动计数、口令显隐。
//
//  视图只负责渲染与把事件转发进来(`LoginView.swift`)。
//

import Foundation

// MARK: - 模式

/// 登录页的两种主模式(第三个入口「以游客身份继续」在两种模式下都可用)。
public enum OrdoLoginMode: String, CaseIterable, Sendable {
    case login
    case register

    /// 主按钮文案(规范 §5.1:主按钮文案「登录」/「注册」两种模式切换)。
    public var primaryTitle: String {
        switch self {
        case .login: return "登录"
        case .register: return "注册"
        }
    }

    /// 底部文本链接(登录态显示「还没有账号?注册」,注册态显示「已有账号?登录」)。
    public var switchPrompt: String {
        switch self {
        case .login: return "还没有账号?"
        case .register: return "已有账号?"
        }
    }

    public var switchActionTitle: String {
        switch self {
        case .login: return "注册"
        case .register: return "登录"
        }
    }

    public var toggled: OrdoLoginMode {
        self == .login ? .register : .login
    }
}

// MARK: - 表单状态机

/// 登录页表单(值类型:视图用 `@State` 持有,测试直接构造断言)。
public struct OrdoLoginForm: Equatable, Sendable {

    /// 契约 §9:口令最小长度 8。
    public static let minimumPasswordLength = 8

    public var mode: OrdoLoginMode = .login
    public var email: String = ""
    public var password: String = ""
    /// 口令显示/隐藏(规范 §5.1:「带显示/隐藏切换」)。
    public var isPasswordVisible: Bool = false
    /// 提交中:主按钮禁用 + 转圈,输入框与游客按钮一并禁用(规范 §5.1「动效与状态」)。
    public private(set) var isSubmitting: Bool = false
    /// 错误区文案(主按钮下方固定预留 20 高度)。
    public private(set) var errorMessage: String?
    /// 抖动触发计数:每次失败 +1,视图用 `.onChange` 触发一次左右抖动(振幅 6px,320ms)。
    public private(set) var shakeToken: Int = 0

    public init(mode: OrdoLoginMode = .login) {
        self.mode = mode
    }

    // MARK: 输入

    /// 去掉首尾空白后的邮箱(提交时用这个值)。
    public var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func toggleMode() {
        mode = mode.toggled
        // 切换模式时清掉上一模式的错误,避免用户以为新表单也失败了。
        errorMessage = nil
    }

    public mutating func togglePasswordVisibility() {
        isPasswordVisible.toggle()
    }

    // MARK: 校验

    /// 校验提示(nil = 可以提交)。
    public func validationMessage() -> String? {
        let value = normalizedEmail
        guard !value.isEmpty else { return "请输入邮箱" }
        guard Self.looksLikeEmail(value) else { return "邮箱格式不正确" }
        guard password.count >= Self.minimumPasswordLength else {
            return "口令至少 \(Self.minimumPasswordLength) 位"
        }
        return nil
    }

    /// 极简邮箱形状判定(真正的判定在服务端;这里只拦明显无效的输入)。
    public static func looksLikeEmail(_ value: String) -> Bool {
        guard !value.contains(" ") else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        guard !local.isEmpty, !domain.isEmpty else { return false }
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        return true
    }

    /// 主按钮是否可点:校验通过且不在提交中。
    public var canSubmit: Bool {
        !isSubmitting && validationMessage() == nil
    }

    /// 三个入口(含游客)是否可点:提交中一律禁用。
    public var canUseSecondaryEntries: Bool {
        !isSubmitting
    }

    // MARK: 事件

    /// 点击主按钮 / 游客按钮:校验不过就地显示错误并抖动,不发起请求。
    public mutating func beginSubmission() -> Bool {
        guard !isSubmitting else { return false }
        if let message = validationMessage() {
            fail(message)
            return false
        }
        isSubmitting = true
        errorMessage = nil
        return true
    }

    /// 「以游客身份继续」不需要邮箱口令,因此只检查是否已在提交中。
    public mutating func beginGuestSubmission() -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        errorMessage = nil
        return true
    }

    public mutating func finishSubmission() {
        isSubmitting = false
    }

    /// 失败:写入文案并请求一次抖动(规范 §5.1:错误不靠颜色单独表达,同时给文字)。
    public mutating func fail(_ message: String) {
        isSubmitting = false
        errorMessage = message
        shakeToken += 1
    }

    /// 只写文案、不抖动(用于「登录已过期,请重新登录」这类进入页面就存在的事实说明)。
    public mutating func showMessage(_ message: String) {
        errorMessage = message
    }

    public mutating func clearError() {
        errorMessage = nil
    }
}
