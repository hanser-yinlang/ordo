//
//  EmailCodeLoginTests.swift
//  OrdoTests
//
//  契约 §7.6.5 / UI 规范 §5.1.1「邮箱验证码登录(免密登录)」的用例:
//    · DTO:202 响应的字段名与契约默认值(300 / 60)、`devCode` 只在回显时出现、
//      请求体线格式与 Kotlin `EmailCodeRequest` / `EmailCodeLoginRequest` 一致;
//    · 表单状态机:方式切换保留邮箱与两种凭据、注册恒用口令、6 位码校验、
//      只收 ASCII 数字、满 6 位才可提交;
//    · 获取验证码:邮箱形状门槛、请求中互斥、按成功体顶层 `retryAfter` 起倒计时;
//    · 倒计时:逐秒递减、归零恢复、归零不变负数、失败不丢倒计时、
//      限流错误体 `details.retryAfterSec`(含 60s 兜底与上限夹取);
//    · `devCode` 仅在开发模式回显时自动填入(生产路径不得依赖);
//    · 四个 `error.details.reason` → 中文文案(规范 §5.1.1 冻结四条);
//    · 服务层:请求带对邮箱、验证码登录落会话、失败回中文提示。
//
//  ⚠️ 本机(Windows)没有 macOS/Swift 工具链,这些用例**无法运行**;
//     请在 macOS 上执行 `bash apps/ios/tools/verify_ios.sh`(或 Xcode 里跑 OrdoTests 目标)。
//     本文件只覆盖纯 Swift 状态机与 DTO,不依赖 `OrdoCore`(KMP),因此不需要先编 XCFramework。
//

import Foundation
import XCTest
// 模块名两条构建路径不同:Xcode 工程(PRODUCT_NAME=Ordo)是 `Ordo`,SwiftPM 是 `OrdoKit`。
#if canImport(OrdoKit)
@testable import OrdoKit
#else
@testable import Ordo
#endif

// MARK: - DTO(契约 §7.6.5)

final class OrdoEmailCodeDTOTests: XCTestCase {

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// 服务端 `202 {sent, expiresIn, retryAfter}`:三个字段都按契约值解出,`devCode` 缺省为 nil。
    func testCodeSentDecodesContractFields() throws {
        let data = try jsonData(["sent": true, "expiresIn": 300, "retryAfter": 60])
        let sent = try JSONDecoder().decode(OrdoEmailCodeSent.self, from: data)
        XCTAssertTrue(sent.sent)
        XCTAssertEqual(sent.expiresIn, 300)
        XCTAssertEqual(sent.retryAfter, 60)
        XCTAssertNil(sent.devCode, "生产环境不回显验证码")
    }

    /// 开发模式回显:额外带 `devCode` 时必须能解出(仅本地联调用,生产路径不得依赖)。
    func testCodeSentDecodesDevCodeWhenEchoed() throws {
        let data = try jsonData([
            "sent": true, "expiresIn": 300, "retryAfter": 60, "devCode": "123456",
        ])
        let sent = try JSONDecoder().decode(OrdoEmailCodeSent.self, from: data)
        XCTAssertEqual(sent.devCode, "123456")
    }

    /// 老服务端少回字段时不整条解码失败,回落到契约默认值(300 / 60 / true)。
    func testCodeSentFallsBackToContractDefaults() throws {
        let data = try jsonData([:])
        let sent = try JSONDecoder().decode(OrdoEmailCodeSent.self, from: data)
        XCTAssertTrue(sent.sent)
        XCTAssertEqual(sent.expiresIn, 300)
        XCTAssertEqual(sent.retryAfter, OrdoEmailCodePolicy.defaultRetryAfterSeconds)
        XCTAssertNil(sent.devCode)
        // 契约 §7.6.5 的两个不变量:6 位码、最短重发间隔 60s。
        XCTAssertEqual(OrdoLoginForm.codeLength, 6)
        XCTAssertEqual(OrdoEmailCodePolicy.defaultRetryAfterSeconds, 60)
    }

    /// 请求体的 JSON 键名是跨端契约的一部分(核心 Kotlin DTO 同名)。
    func testRequestWireKeys() throws {
        let codeBody = try OrdoJSON.encode(OrdoEmailCodeRequest(email: "a@ordo.app"))
        let codeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: codeBody) as? [String: Any]
        )
        XCTAssertEqual(codeObject.count, 1)
        XCTAssertEqual(codeObject["email"] as? String, "a@ordo.app")

        let loginBody = try OrdoJSON.encode(
            OrdoEmailCodeLoginRequest(email: "a@ordo.app", code: "123456", deviceName: "iPhone")
        )
        let loginObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: loginBody) as? [String: Any]
        )
        XCTAssertEqual(loginObject["email"] as? String, "a@ordo.app")
        XCTAssertEqual(loginObject["code"] as? String, "123456")
        XCTAssertEqual(loginObject["deviceName"] as? String, "iPhone")
        XCTAssertEqual(loginObject["platform"] as? String, "ios/1.0.0")
        XCTAssertNil(loginObject["deviceId"], "deviceId 为 nil 时不应出现在 JSON 里")
    }

    /// 契约 §7.6.5 的两条平台路径:显式传 deviceId 时要带上。
    func testLoginRequestKeepsExplicitDeviceId() throws {
        let body = try OrdoJSON.encode(
            OrdoEmailCodeLoginRequest(
                email: "a@ordo.app",
                code: "123456",
                deviceId: "dev-9",
                deviceName: "iPhone"
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["deviceId"] as? String, "dev-9")
    }
}

// MARK: - 登录表单:验证码方式(UI 规范 §5.1.1)

final class OrdoEmailCodeFormTests: XCTestCase {

    /// 造一个已切到验证码方式的表单。
    private func codeForm(email: String = "a@ordo.app", code: String = "") -> OrdoLoginForm {
        var form = OrdoLoginForm()
        form.selectMethod(.emailCode)
        form.email = email
        form.updateEmailCode(code)
        return form
    }

    /// 方式切换保留已输入邮箱,且口令与验证码互不清空对方(规范 §5.1.1)。
    func testMethodSwitchKeepsEmailAndBothCredentials() {
        var form = OrdoLoginForm()
        form.email = "a@ordo.app"
        form.password = "password8"
        form.selectMethod(.emailCode)
        form.updateEmailCode("654321")

        XCTAssertEqual(form.method, .emailCode)
        XCTAssertEqual(form.email, "a@ordo.app")
        XCTAssertEqual(form.password, "password8")
        XCTAssertEqual(form.emailCode, "654321")

        form.selectMethod(.password)
        XCTAssertEqual(form.method, .password)
        XCTAssertEqual(form.email, "a@ordo.app")
        XCTAssertEqual(form.password, "password8")
        XCTAssertEqual(form.emailCode, "654321", "切回口令方式不应清空验证码")
    }

    /// 两种方式的可见文案(规范 §5.1.1:同级切换,不藏进二级页面)。
    func testMethodTitlesAndFieldTitles() {
        XCTAssertEqual(OrdoLoginMethod.allCases.count, 2)
        XCTAssertEqual(OrdoLoginMethod.password.title, "口令登录")
        XCTAssertEqual(OrdoLoginMethod.emailCode.title, "验证码登录")
        XCTAssertEqual(OrdoLoginMethod.password.secondaryFieldTitle, "口令(至少 8 位)")
        XCTAssertEqual(OrdoLoginMethod.emailCode.secondaryFieldTitle, "验证码(6 位数字)")
    }

    /// 注册模式必须带口令:方式停在验证码时,生效方式也回落为口令(契约 §7.6)。
    func testRegisterModeAlwaysUsesPassword() {
        var form = codeForm(code: "123456")
        form.toggleMode()
        XCTAssertEqual(form.mode, .register)
        XCTAssertEqual(form.effectiveMethod, .password)
        XCTAssertEqual(form.validationMessage(), "口令至少 8 位", "注册不能只凭验证码")
        XCTAssertFalse(form.canSubmit)
        form.password = "password8"
        XCTAssertNil(form.validationMessage())
        XCTAssertTrue(form.canSubmit)
    }

    /// 验证码只收 ASCII 数字:字母/符号/全角数字一律剔除,并截断到 6 位。
    func testCodeAcceptsAsciiDigitsOnly() {
        XCTAssertEqual(OrdoLoginForm.sanitizeCode("12a34b5678"), "123456")
        XCTAssertEqual(OrdoLoginForm.sanitizeCode("１２３"), "", "全角数字不算验证码字符")
        XCTAssertEqual(OrdoLoginForm.sanitizeCode("12 34"), "1234")
        XCTAssertEqual(OrdoLoginForm.sanitizeCode(""), "")
        var form = codeForm()
        form.updateEmailCode("12-34-56")
        XCTAssertEqual(form.emailCode, "123456")
        XCTAssertTrue(form.isCodeComplete)
    }

    /// 校验:邮箱为空 / 形状不对 / 码不足 6 位,逐级给出可读中文(错误不靠颜色表达)。
    func testValidationMessages() {
        var form = codeForm(email: "")
        XCTAssertEqual(form.validationMessage(), "请输入邮箱")
        XCTAssertFalse(form.canSubmit)

        form.email = "not-an-email"
        XCTAssertEqual(form.validationMessage(), "邮箱格式不正确")

        form.email = "a@ordo.app"
        XCTAssertEqual(form.validationMessage(), "请输入 6 位验证码")

        form.updateEmailCode("12345")
        XCTAssertEqual(form.validationMessage(), "请输入 6 位验证码")
        XCTAssertFalse(form.canSubmit)
        XCTAssertFalse(form.isCodeComplete)

        form.updateEmailCode("123456")
        XCTAssertNil(form.validationMessage())
        XCTAssertTrue(form.canSubmit)
        XCTAssertTrue(form.isCodeComplete)
    }

    /// 满 6 位才放行提交(视图的「满 6 位自动提交」走的就是 `beginSubmission` 这条路径)。
    func testBeginSubmissionRequiresSixDigits() {
        var form = codeForm(code: "12345")
        XCTAssertFalse(form.beginSubmission())
        XCTAssertFalse(form.isSubmitting)
        XCTAssertEqual(form.errorMessage, "请输入 6 位验证码")
        XCTAssertEqual(form.shakeToken, 1)

        form.updateEmailCode("123456")
        XCTAssertTrue(form.beginSubmission())
        XCTAssertTrue(form.isSubmitting)
        XCTAssertFalse(form.canSubmit, "提交中主按钮禁用")
        XCTAssertFalse(form.canUseSecondaryEntries, "提交中次要入口一并禁用")
        form.finishSubmission()
        XCTAssertTrue(form.canSubmit)
    }

    /// 方式切换清掉上一方式的错误,但不改动输入。
    func testMethodSwitchClearsError() {
        var form = codeForm(email: "nope")
        XCTAssertFalse(form.beginCodeRequest())
        XCTAssertEqual(form.errorMessage, "邮箱格式不正确")
        form.selectMethod(.password)
        XCTAssertNil(form.errorMessage)
        XCTAssertEqual(form.email, "nope", "切换方式不重置邮箱")
    }

    // MARK: 获取验证码

    /// 「获取验证码」门槛:邮箱形状合法、不在请求中、不在倒计时里。
    func testCanRequestCodeNeedsValidEmail() {
        var form = codeForm(email: "")
        XCTAssertFalse(form.canRequestCode)
        form.email = "nope"
        XCTAssertFalse(form.canRequestCode)
        form.email = "  a@ordo.app  "
        XCTAssertTrue(form.canRequestCode, "首尾空白应先去掉再判定")
    }

    /// 邮箱不合法时点「获取验证码」就地报错并抖动,不发起请求。
    func testBeginCodeRequestRejectsBadEmail() {
        var form = codeForm(email: "")
        XCTAssertFalse(form.beginCodeRequest())
        XCTAssertFalse(form.isRequestingCode)
        XCTAssertEqual(form.errorMessage, "请输入邮箱")
        XCTAssertEqual(form.shakeToken, 1)

        form.email = "nope"
        XCTAssertFalse(form.beginCodeRequest())
        XCTAssertEqual(form.errorMessage, "邮箱格式不正确")
        XCTAssertEqual(form.shakeToken, 2)
    }

    /// 受理成功:按 `retryAfter` 起倒计时,按钮置灰且不可重复点击。
    func testApplyCodeSentStartsCountdown() {
        var form = codeForm()
        XCTAssertTrue(form.beginCodeRequest())
        XCTAssertTrue(form.isRequestingCode)
        XCTAssertFalse(form.canRequestCode, "请求中不得重复点击")

        form.applyCodeSent(OrdoEmailCodeSent(sent: true, expiresIn: 300, retryAfter: 60))
        XCTAssertFalse(form.isRequestingCode)
        XCTAssertEqual(form.countdownRemaining, 60)
        XCTAssertEqual(form.requestCodeTitle, "60s 后重发")
        XCTAssertFalse(form.canRequestCode)
        XCTAssertEqual(form.errorMessage, nil)
    }

    /// 倒计时逐秒递减,归零后恢复「获取验证码」并可再次请求。
    func testCountdownTicksToZeroAndRecovers() {
        var form = codeForm()
        form.applyCodeSent(OrdoEmailCodeSent(retryAfter: 3))
        XCTAssertEqual(form.countdownRemaining, 3)

        form.tickCountdown()
        XCTAssertEqual(form.countdownRemaining, 2)
        XCTAssertEqual(form.requestCodeTitle, "2s 后重发")
        XCTAssertFalse(form.canRequestCode)

        form.tickCountdown()
        form.tickCountdown()
        XCTAssertEqual(form.countdownRemaining, 0)
        XCTAssertEqual(form.requestCodeTitle, "获取验证码")
        XCTAssertTrue(form.canRequestCode)

        form.tickCountdown()
        XCTAssertEqual(form.countdownRemaining, 0, "归零后不得变成负数")
        XCTAssertTrue(form.beginCodeRequest())
    }

    /// `retryAfter = 0` 视为不设限(服务端明确允许立即重发)。
    func testZeroRetryAfterMeansNoCountdown() {
        var form = codeForm()
        form.applyCodeSent(OrdoEmailCodeSent(retryAfter: 0))
        XCTAssertEqual(form.countdownRemaining, 0)
        XCTAssertEqual(form.requestCodeTitle, "获取验证码")
        XCTAssertTrue(form.canRequestCode)
    }

    /// 服务端给了新的 `retryAfterSec` 时采用它;nil / 0 / 负数不改动既有倒计时。
    func testApplyRetryAfterOnlyAcceptsPositive() {
        var form = codeForm()
        form.applyRetryAfter(30)
        XCTAssertEqual(form.countdownRemaining, 30)
        form.applyRetryAfter(nil)
        XCTAssertEqual(form.countdownRemaining, 30)
        form.applyRetryAfter(0)
        XCTAssertEqual(form.countdownRemaining, 30)
        form.applyRetryAfter(-5)
        XCTAssertEqual(form.countdownRemaining, 30)
    }

    /// 验证码请求失败:结束「请求中」+ 抖动,但不动输入与既有倒计时(规范 §5.1.1)。
    func testFailCodeRequestKeepsCountdownAndInput() {
        var form = codeForm(code: "1234")
        XCTAssertTrue(form.beginCodeRequest())
        XCTAssertTrue(form.isRequestingCode)
        form.applyRetryAfter(20)
        form.failCodeRequest("发送过于频繁,请稍后再试")

        XCTAssertFalse(form.isRequestingCode)
        XCTAssertEqual(form.errorMessage, "发送过于频繁,请稍后再试")
        XCTAssertEqual(form.shakeToken, 1)
        XCTAssertEqual(form.countdownRemaining, 20)
        XCTAssertEqual(form.emailCode, "1234", "失败不应清空用户已输入的验证码")
        XCTAssertFalse(form.canRequestCode)
    }

    /// 倒计时里再点「获取验证码」直接被拦,不产生第二次请求。
    func testCodeRequestBlockedWhileCountingDown() {
        var form = codeForm()
        form.applyCodeSent(OrdoEmailCodeSent(retryAfter: 45))
        XCTAssertFalse(form.canRequestCode)
        XCTAssertFalse(form.beginCodeRequest())
        XCTAssertFalse(form.isRequestingCode)
        XCTAssertEqual(form.shakeToken, 0, "倒计时拦截属于正常禁用,不应抖动报错")
        XCTAssertNil(form.errorMessage)
    }

    /// 登录失败不丢重发倒计时(规范 §5.1.1:失败可立即重发,除非服务端给了新 retryAfter)。
    func testLoginFailureKeepsCountdown() {
        var form = codeForm(code: "123456")
        form.applyCodeSent(OrdoEmailCodeSent(retryAfter: 45))
        XCTAssertTrue(form.beginSubmission())
        form.fail("验证码不正确,请检查后重试")
        XCTAssertEqual(form.errorMessage, "验证码不正确,请检查后重试")
        XCTAssertEqual(form.countdownRemaining, 45, "登录失败不应丢掉重发倒计时")
    }

    // MARK: devCode(仅开发模式)

    /// 开发模式回显 `devCode` 时自动填入;不返回时保持用户输入(生产路径不依赖)。
    func testDevCodeAutoFillOnlyWhenEchoed() {
        var form = codeForm()
        form.updateEmailCode("1111")
        form.applyCodeSent(OrdoEmailCodeSent(retryAfter: 0, devCode: "654321"))
        XCTAssertEqual(form.emailCode, "654321")
        XCTAssertTrue(form.isCodeComplete)

        var second = codeForm()
        second.updateEmailCode("1111")
        second.applyCodeSent(OrdoEmailCodeSent(retryAfter: 0))
        XCTAssertEqual(second.emailCode, "1111", "没有 devCode 时不应改动输入")
    }

    /// 空串 `devCode` 视为未回显。
    func testEmptyDevCodeIsIgnored() {
        var form = codeForm()
        form.applyCodeSent(OrdoEmailCodeSent(retryAfter: 0, devCode: ""))
        XCTAssertEqual(form.emailCode, "")
    }

    /// `devCode` 也走数字清洗与 6 位截断(防御联调数据里夹带空格/连字符)。
    func testDevCodeIsSanitized() {
        var form = codeForm()
        form.applyCodeSent(OrdoEmailCodeSent(retryAfter: 0, devCode: " 65-43-21 "))
        XCTAssertEqual(form.emailCode, "654321")
    }
}

// MARK: - 错误 reason → 中文(契约 §7.6.5 / UI 规范 §5.1.1)

final class OrdoEmailCodeErrorMappingTests: XCTestCase {

    private func apiError(
        code: OrdoAPIErrorCode,
        reason: String?,
        status: Int,
        extraDetails: [String: OrdoJSONValue] = [:]
    ) -> OrdoAPIError {
        var details = extraDetails
        if let reason {
            details["reason"] = OrdoJSONValue.string(reason)
        }
        return OrdoAPIError(
            code: code,
            message: "server",
            httpStatus: status,
            details: details.isEmpty ? nil : details
        )
    }

    /// 规范 §5.1.1 冻结的四条文案。
    func testFourReasonsMapToChinese() {
        XCTAssertEqual(OrdoAuthService.codeHint(forReason: "code_invalid"), "验证码不正确,请检查后重试")
        XCTAssertEqual(OrdoAuthService.codeHint(forReason: "code_expired"), "验证码已过期,请重新获取")
        XCTAssertEqual(
            OrdoAuthService.codeHint(forReason: "code_attempts_exceeded"),
            "尝试次数过多,请重新获取验证码"
        )
        XCTAssertEqual(OrdoAuthService.codeHint(forReason: "code_throttled"), "发送过于频繁,请稍后再试")
    }

    /// 发信通道失败(契约 §7.6.5:500 `INTERNAL` / `mail_failed`)也给中文。
    func testMailFailedReason() {
        XCTAssertEqual(OrdoAuthService.codeHint(forReason: "mail_failed"), "验证码发送失败,请稍后再试")
    }

    /// 未知 / 缺失 reason 返回 nil,由调用方回退到按 `code` 的通用提示(前向兼容)。
    func testUnknownReasonReturnsNil() {
        XCTAssertNil(OrdoAuthService.codeHint(forReason: nil))
        XCTAssertNil(OrdoAuthService.codeHint(forReason: ""))
        XCTAssertNil(OrdoAuthService.codeHint(forReason: "not_guest"))
    }

    /// `hint(for:)` 优先看 reason:同一个 `AUTH_INVALID_CREDENTIALS`,
    /// 验证码模式下不能再说「邮箱或密码不正确」。
    func testHintPrefersDetailsReason() {
        XCTAssertEqual(
            OrdoAuthService.hint(for: apiError(code: .authInvalidCredentials, reason: "code_invalid", status: 401)),
            "验证码不正确,请检查后重试"
        )
        XCTAssertEqual(
            OrdoAuthService.hint(for: apiError(code: .authInvalidCredentials, reason: "code_expired", status: 401)),
            "验证码已过期,请重新获取"
        )
        XCTAssertEqual(
            OrdoAuthService.hint(
                for: apiError(code: .authInvalidCredentials, reason: "code_attempts_exceeded", status: 401)
            ),
            "尝试次数过多,请重新获取验证码"
        )
        XCTAssertEqual(
            OrdoAuthService.hint(for: apiError(code: .rateLimited, reason: "code_throttled", status: 429)),
            "发送过于频繁,请稍后再试"
        )
        XCTAssertEqual(
            OrdoAuthService.hint(for: apiError(code: .internal, reason: "mail_failed", status: 500)),
            "验证码发送失败,请稍后再试"
        )
    }

    /// 没有 reason 时保持原有行为(口令登录与游客路径的提示不能被改坏)。
    func testHintWithoutReasonKeepsLegacyBehaviour() {
        XCTAssertEqual(
            OrdoAuthService.hint(for: OrdoAPIError(code: .authInvalidCredentials, message: "bad")),
            "邮箱或密码不正确"
        )
        XCTAssertEqual(
            OrdoAuthService.hint(for: OrdoAPIError(code: .rateLimited, message: "slow")),
            "操作过于频繁,请稍后再试"
        )
        XCTAssertEqual(
            OrdoAuthService.hint(for: OrdoAPIError(code: .validationFailed, message: "bad input")),
            "请填写有效的邮箱,口令至少 8 位"
        )
    }

    // MARK: 限流重发秒数(契约 §7.6.5:错误体里是 `details.retryAfterSec`)

    /// 字段名必须读 `retryAfterSec`(不是成功体顶层的 `retryAfter`)。
    func testThrottleReadsRetryAfterSec() {
        let error = apiError(
            code: .rateLimited,
            reason: "code_throttled",
            status: 429,
            extraDetails: ["retryAfterSec": .int(42)]
        )
        XCTAssertEqual(OrdoAuthService.retryAfterSeconds(from: error), 42)

        // 只给了成功体的字段名 `retryAfter` 时应视为「服务端没给」→ 回落到 60s。
        let legacyName = apiError(
            code: .rateLimited,
            reason: "code_throttled",
            status: 429,
            extraDetails: ["retryAfter": .int(42)]
        )
        XCTAssertEqual(
            OrdoAuthService.retryAfterSeconds(from: legacyName),
            60,
            "错误体必须用 retryAfterSec;同名但语义不同的 retryAfter 不得被误读"
        )
    }

    /// 缺字段用 60s 兜底;非正数同样兜底(不能给出 0 或负数倒计时)。
    func testThrottleFallsBackToSixtySeconds() {
        XCTAssertEqual(
            OrdoAuthService.retryAfterSeconds(
                from: apiError(code: .rateLimited, reason: "code_throttled", status: 429)
            ),
            60
        )
        XCTAssertEqual(
            OrdoAuthService.retryAfterSeconds(
                from: apiError(
                    code: .rateLimited,
                    reason: "code_throttled",
                    status: 429,
                    extraDetails: ["retryAfterSec": .int(0)]
                )
            ),
            60
        )
        XCTAssertEqual(
            OrdoAuthService.retryAfterSeconds(
                from: apiError(
                    code: .rateLimited,
                    reason: "code_throttled",
                    status: 429,
                    extraDetails: ["retryAfterSec": .int(-9)]
                )
            ),
            60
        )
    }

    /// 上限夹取:异常大的秒数不得把「获取验证码」按钮永久冻住。
    func testThrottleClampsToMaximum() {
        let error = apiError(
            code: .rateLimited,
            reason: "code_throttled",
            status: 429,
            extraDetails: ["retryAfterSec": .int(999_999)]
        )
        XCTAssertEqual(
            OrdoAuthService.retryAfterSeconds(from: error),
            OrdoEmailCodePolicy.maximumRetryAfterSeconds
        )
        XCTAssertEqual(OrdoEmailCodePolicy.maximumRetryAfterSeconds, 3600)
        XCTAssertEqual(OrdoEmailCodePolicy.defaultRetryAfterSeconds, 60)

        // 夹取同样作用于成功体给出的 retryAfter(表单侧兜底)。
        var form = OrdoLoginForm()
        form.applyCodeSent(OrdoEmailCodeSent(retryAfter: 999_999))
        XCTAssertEqual(form.countdownRemaining, Int(OrdoEmailCodePolicy.maximumRetryAfterSeconds))
    }

    /// 不是限流错误(网络失败 / 校验失败 / 非 API 错误)返回 nil:
    /// 调用方保持既有倒计时,符合规范 §5.1.1「失败可立即重发」。
    func testNonThrottleErrorsReturnNil() {
        XCTAssertNil(
            OrdoAuthService.retryAfterSeconds(
                from: apiError(code: .authInvalidCredentials, reason: "code_invalid", status: 401)
            )
        )
        XCTAssertNil(OrdoAuthService.retryAfterSeconds(from: OrdoAPIError.transport("offline")))
        XCTAssertNil(OrdoAuthService.retryAfterSeconds(from: OrdoJSONError.notAnObject))
        // reason 是 code_throttled 但 code 不是 RATE_LIMITED 时也认(服务端若换了外层码仍可恢复)
        XCTAssertEqual(
            OrdoAuthService.retryAfterSeconds(
                from: apiError(
                    code: .validationFailed,
                    reason: "code_throttled",
                    status: 429,
                    extraDetails: ["retryAfterSec": .int(15)]
                )
            ),
            15
        )
    }
}

// MARK: - 服务层(请求验证码 / 验证码登录)

@MainActor
final class OrdoEmailCodeServiceTests: XCTestCase {

    private func makeService(
        api: OrdoStubAuthAPI = OrdoStubAuthAPI(),
        now: Int64 = 1_759_900_000_000
    ) throws -> (OrdoAuthService, OrdoMemorySessionStore, OrdoStubAuthAPI) {
        let store = OrdoMemorySessionStore()
        let kv = try OrdoFileKVStorage(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ordo-email-code-\(UUID().uuidString).json")
        )
        let tokens = OrdoSessionTokenStore(sessions: store, kv: kv)
        let service = OrdoAuthService(
            sessionStore: store,
            tokenStore: tokens,
            authAPI: api,
            clock: OrdoFixedClock(millis: now)
        )
        return (service, store, api)
    }

    /// 请求验证码:带对邮箱,并把 `retryAfter` 原样交给调用方去跑倒计时。
    func testRequestEmailCodePassesEmailAndRetryAfter() async throws {
        let (service, _, api) = try makeService()
        api.codeRetryAfter = 60
        let sent = try await service.requestEmailCode(email: "a@ordo.app")
        XCTAssertEqual(api.emailCodeRequests, ["a@ordo.app"])
        XCTAssertEqual(sent.retryAfter, 60)
        XCTAssertEqual(sent.expiresIn, 300)
        XCTAssertNil(sent.devCode)
        XCTAssertNil(service.lastError, "验证码请求成功不应污染门禁错误提示")
    }

    /// 验证码登录成功:会话落盘,`userId` 来自服务端(未注册邮箱自动建号走同一条路径)。
    func testEmailCodeLoginSavesSession() async throws {
        let (service, store, api) = try makeService()
        let record = try await service.loginWithEmailCode(email: "new@ordo.app", code: "123456")

        XCTAssertEqual(api.emailLoginCalls.count, 1)
        XCTAssertEqual(api.emailLoginCalls.first?.email, "new@ordo.app")
        XCTAssertEqual(api.emailLoginCalls.first?.code, "123456")
        XCTAssertEqual(record.userId, "code-login")
        XCTAssertEqual(record.email, "new@ordo.app")
        XCTAssertFalse(record.isGuest, "自动建号是正式账号(is_guest = false)")

        let stored = await store.load()
        XCTAssertEqual(stored?.userId, "code-login")
        XCTAssertEqual(service.session?.accessToken, "access-code-login")
    }

    /// 错码 / 过期 / 超次:失败要能被 UI 读成规范 §5.1.1 的中文文案,且不写会话。
    func testEmailCodeLoginFailureSurfacesReasonHint() async throws {
        let api = OrdoStubAuthAPI()
        api.nextError = OrdoAPIError(
            code: .authInvalidCredentials,
            message: "invalid",
            httpStatus: 401,
            details: ["reason": OrdoJSONValue.string("code_expired")]
        )
        let (service, store, _) = try makeService(api: api)

        do {
            _ = try await service.loginWithEmailCode(email: "a@ordo.app", code: "000000")
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(OrdoAuthService.hint(for: error), "验证码已过期,请重新获取")
        }
        let stored = await store.load()
        XCTAssertNil(stored, "失败不应写入会话")
        XCTAssertEqual(service.lastError, "验证码已过期,请重新获取")
    }

    /// 请求验证码被限流:中文提示 + 错误体里的 `details.retryAfterSec`(契约 §7.6.5)。
    func testRequestEmailCodeFailureSurfacesThrottleHint() async throws {
        let api = OrdoStubAuthAPI()
        api.nextError = OrdoAPIError(
            code: .rateLimited,
            message: "slow down",
            httpStatus: 429,
            details: [
                "reason": OrdoJSONValue.string("code_throttled"),
                "retryAfterSec": OrdoJSONValue.int(42),
            ]
        )
        let (service, _, _) = try makeService(api: api)

        do {
            _ = try await service.requestEmailCode(email: "a@ordo.app")
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(OrdoAuthService.hint(for: error), "发送过于频繁,请稍后再试")
            XCTAssertEqual(OrdoAuthService.retryAfterSeconds(from: error), 42)
        }
        XCTAssertEqual(service.lastError, nil, "验证码请求失败不写门禁错误区")
    }
}
