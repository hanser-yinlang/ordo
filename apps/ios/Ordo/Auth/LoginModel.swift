//
//  LoginModel.swift
//  Ordo
//
//  UI 规范 §5.1 / §5.1.1 登录页的**纯状态机**(不 import SwiftUI,便于在 XCTest 里逐条断言):
//    · 两种模式(登录 / 注册)与两种登录方式(口令 / 邮箱验证码,契约 §7.6.5);
//    · 三个入口(登录 / 注册 / 以游客身份继续)+ 验证码行(获取验证码 / 倒计时 / 自动提交);
//    · 输入校验(邮箱形状 + 口令 ≥ 8 + 6 位数字验证码,契约 §9 / §7.6.5);
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

// MARK: - 登录方式(UI 规范 §5.1.1)

/// 登录卡片内的**同级切换**:口令登录 ↔ 邮箱验证码登录(契约 §7.6.5,免密登录)。
///
/// 只影响登录模式;注册模式必须带口令(注册时第二行恒为口令,见 `effectiveMethod`)。
public enum OrdoLoginMethod: String, CaseIterable, Sendable {
    case password
    case emailCode

    /// 分段控件文案(规范 §5.1.1:「口令登录 | 验证码登录」)。
    public var title: String {
        switch self {
        case .password: return "口令登录"
        case .emailCode: return "验证码登录"
        }
    }

    /// 第二行浮动标签(规范 §5.1.1:验证码输入有可读标签「验证码」)。
    public var secondaryFieldTitle: String {
        switch self {
        case .password: return "口令(至少 \(OrdoLoginForm.minimumPasswordLength) 位)"
        case .emailCode: return "验证码(\(OrdoLoginForm.codeLength) 位数字)"
        }
    }
}

// MARK: - 邮箱验证码登录的客户端策略(契约 §7.6.5)

/// 免密登录的时间常量。
///
/// 单点定义:`OrdoAuthService` 解析限流错误的 `details.retryAfterSec` 与 `OrdoLoginForm`
/// 跑重发倒计时共用这里,避免 60s 兜底与上限在多处各写一遍。
public enum OrdoEmailCodePolicy {

    /// 重发倒计时的兜底值(秒):服务端没给 `details.retryAfterSec` 时使用(契约默认 **60**)。
    public static let defaultRetryAfterSeconds: Int64 = 60

    /// 重发倒计时的上限(秒)。契约 §7.6.5 最大的限流窗口是「同一邮箱每小时 ≤ 5 条」,
    /// 因此 1 小时足够;夹取可避免异常响应把「获取验证码」永久冻住。
    public static let maximumRetryAfterSeconds: Int64 = 3600
}

// MARK: - 表单状态机

/// 登录页表单(值类型:视图用 `@State` 持有,测试直接构造断言)。
public struct OrdoLoginForm: Equatable, Sendable {

    /// 契约 §9:口令最小长度 8。
    public static let minimumPasswordLength = 8
    /// 契约 §7.6.5:验证码为 **6 位数字**。
    public static let codeLength = 6

    public var mode: OrdoLoginMode = .login
    /// 登录方式(规范 §5.1.1);注册模式下由 `effectiveMethod` 强制为口令。
    public var method: OrdoLoginMethod = .password
    public var email: String = ""
    public var password: String = ""
    /// 6 位数字验证码(只接受数字;写入请走 `updateEmailCode(_:)`)。
    public var emailCode: String = ""
    /// 口令显示/隐藏(规范 §5.1:「带显示/隐藏切换」)。
    public var isPasswordVisible: Bool = false
    /// 提交中:主按钮禁用 + 转圈,输入框与游客按钮一并禁用(规范 §5.1「动效与状态」)。
    public private(set) var isSubmitting: Bool = false
    /// 「获取验证码」请求中(与主按钮的提交中互相独立)。
    public private(set) var isRequestingCode: Bool = false
    /// 重发倒计时剩余秒数(规范 §5.1.1:按响应 `retryAfter` 显示「Ns 后重发」并置灰)。
    public private(set) var countdownRemaining: Int = 0
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

    /// 当前真正生效的登录方式:注册必须有口令,因此注册模式下第二行恒为口令。
    public var effectiveMethod: OrdoLoginMethod {
        mode == .register ? .password : method
    }

    /// 邮箱形状是否已合法(`canRequestCode` 与主按钮共用)。
    public var isEmailValid: Bool {
        Self.looksLikeEmail(normalizedEmail)
    }

    /// 验证码是否已满 6 位(视图据此**自动提交**)。
    public var isCodeComplete: Bool {
        emailCode.count == Self.codeLength
    }

    public mutating func toggleMode() {
        mode = mode.toggled
        // 切换模式时清掉上一模式的错误,避免用户以为新表单也失败了。
        errorMessage = nil
    }

    /// 同级切换登录方式(规范 §5.1.1:保留已输入邮箱;口令与验证码互不清空对方)。
    public mutating func selectMethod(_ value: OrdoLoginMethod) {
        guard method != value else { return }
        method = value
        errorMessage = nil
    }

    public mutating func togglePasswordVisibility() {
        isPasswordVisible.toggle()
    }

    /// 验证码输入:只保留数字并截断到 6 位(规范 §5.1.1「只接受数字」)。
    public mutating func updateEmailCode(_ raw: String) {
        emailCode = Self.sanitizeCode(raw)
    }

    /// 验证码清洗:只保留 `0-9` 并截断到 6 位。
    ///
    /// 用逐字符 `"0"..."9"` 判定而不是 `isNumber`,避免把全角/阿拉伯-印度数字放进来。
    public static func sanitizeCode(_ raw: String) -> String {
        String(raw.filter { $0 >= "0" && $0 <= "9" }.prefix(codeLength))
    }

    // MARK: 校验

    /// 校验提示(nil = 可以提交)。
    public func validationMessage() -> String? {
        let value = normalizedEmail
        guard !value.isEmpty else { return "请输入邮箱" }
        guard Self.looksLikeEmail(value) else { return "邮箱格式不正确" }
        if effectiveMethod == .emailCode {
            guard isCodeComplete else { return "请输入 \(Self.codeLength) 位验证码" }
            return nil
        }
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

    /// 「获取验证码」是否可点:邮箱形状合法、既未在提交也未在请求中、且倒计时已归零。
    public var canRequestCode: Bool {
        !isSubmitting && !isRequestingCode && countdownRemaining == 0 && isEmailValid
    }

    /// 三个入口(含游客)是否可点:提交中一律禁用。
    public var canUseSecondaryEntries: Bool {
        !isSubmitting
    }

    /// 倒计时按钮文案(规范 §5.1.1:归零恢复「获取验证码」;倒计时状态不只靠颜色,文字里带秒数)。
    public var requestCodeTitle: String {
        countdownRemaining > 0 ? "\(countdownRemaining)s 后重发" : "获取验证码"
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

    /// 「获取验证码」:只需邮箱合法且不在倒计时里;校验不过就地报错并抖动。
    public mutating func beginCodeRequest() -> Bool {
        guard !isRequestingCode, !isSubmitting else { return false }
        let value = normalizedEmail
        guard !value.isEmpty else {
            fail("请输入邮箱")
            return false
        }
        guard isEmailValid else {
            fail("邮箱格式不正确")
            return false
        }
        guard countdownRemaining == 0 else { return false }
        isRequestingCode = true
        errorMessage = nil
        return true
    }

    public mutating func finishSubmission() {
        isSubmitting = false
    }

    /// 验证码请求受理成功(契约 §7.6.5 的 `202` 响应):
    /// 按 `retryAfter` 起倒计时,并**仅在开发模式**把 `devCode` 自动填入(生产恒为 nil,不依赖)。
    public mutating func applyCodeSent(_ sent: OrdoEmailCodeSent) {
        isRequestingCode = false
        errorMessage = nil
        beginCountdown(seconds: sent.retryAfter)
        if let dev = sent.devCode, !dev.isEmpty {
            updateEmailCode(dev)
        }
    }

    /// 失败:写入文案并请求一次抖动(规范 §5.1:错误不靠颜色单独表达,同时给文字)。
    public mutating func fail(_ message: String) {
        isSubmitting = false
        errorMessage = message
        shakeToken += 1
    }

    /// 「获取验证码」失败:结束请求中 + 抖动,但**不动**已输入的验证码与既有倒计时
    /// (规范 §5.1.1:倒计时不因一次失败而丢失)。
    public mutating func failCodeRequest(_ message: String) {
        isRequestingCode = false
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

    // MARK: 倒计时(规范 §5.1.1)

    /// 开始(或重置)重发倒计时。`seconds ≤ 0` 视为不设限(立即可重发);
    /// 超过 `OrdoEmailCodePolicy.maximumRetryAfterSeconds` 时夹取(防止按钮被异常响应冻住)。
    public mutating func beginCountdown(seconds: Int64) {
        let bounded = min(max(0, seconds), OrdoEmailCodePolicy.maximumRetryAfterSeconds)
        countdownRemaining = Int(clamping: bounded)
    }

    /// 服务端在 429 里给了新的 `retryAfterSec` 时采用它(规范 §5.1.1;`nil` = 保持现状)。
    public mutating func applyRetryAfter(_ seconds: Int64?) {
        guard let seconds, seconds > 0 else { return }
        beginCountdown(seconds: seconds)
    }

    /// 视图每秒调用一次(`.task(id: countdownRemaining)` 驱动),归零后按钮恢复可点。
    public mutating func tickCountdown() {
        guard countdownRemaining > 0 else { return }
        countdownRemaining -= 1
    }
}
