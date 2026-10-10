/**
 * Ordo · 邮箱验证码登录用例(契约 §7.6.5 / 04-UI规范 §5.1)
 *
 * 覆盖两块**纯逻辑**(都能在本机宿主里真跑,不需要设备):
 *  1. `viewmodel/EmailCodeState.ets`:60s 倒计时(取响应 retryAfter)、置灰判定、
 *     满 6 位自动提交去重、devCode 回显的容错;
 *  2. `core/sync/SyncTypes.ets` 的 `details.reason` → 中文提示映射(code_invalid /
 *     code_expired / code_attempts_exceeded / code_throttled)。
 */

import { describe, expect, it } from '@ohos/hypium';
import {
  EMAIL_CODE_LENGTH,
  EMAIL_CODE_MAX_RESEND_SECONDS,
  EMAIL_CODE_RESEND_SECONDS,
  EMAIL_CODE_TTL_SECONDS,
  EmailCodeMachine
} from '../../../main/ets/viewmodel/EmailCodeState.ets';
import {
  ERR_AUTH_INVALID_CREDENTIALS,
  ERR_RATE_LIMITED,
  OrdoErrorDetails,
  REASON_CODE_ATTEMPTS_EXCEEDED,
  REASON_CODE_EXPIRED,
  REASON_CODE_INVALID,
  REASON_CODE_THROTTLED,
  errorText,
  errorTextWithReason,
  parseErrorDetails,
  reasonText
} from '../../../main/ets/core/sync/SyncTypes.ets';

export default function emailCodeStateTest() {
  describe('EmailCodeState', () => {

    it('constants_match_the_contract', 0, () => {
      // §7.6.5:6 位数字、有效期 300s、再次请求最小间隔 60s
      expect(EMAIL_CODE_LENGTH).assertEqual(6);
      expect(EMAIL_CODE_TTL_SECONDS).assertEqual(300);
      expect(EMAIL_CODE_RESEND_SECONDS).assertEqual(60);
      expect(EMAIL_CODE_MAX_RESEND_SECONDS).assertEqual(3600);
    });

    it('fresh_machine_can_request_immediately', 0, () => {
      const m: EmailCodeMachine = new EmailCodeMachine();
      expect(m.canRequest(0)).assertTrue();
      expect(m.isCountingDown(0)).assertFalse();
      expect(m.remainingSeconds(0)).assertEqual(0);
      expect(m.resendLabel(0)).assertEqual('获取验证码');
      expect(m.expiresInSeconds()).assertEqual(EMAIL_CODE_TTL_SECONDS);
      expect(m.isRequesting()).assertFalse();
    });

    it('accepted_response_starts_a_retry_after_countdown', 0, () => {
      // 202 {sent, expiresIn:300, retryAfter:60}
      const m: EmailCodeMachine = new EmailCodeMachine();
      m.applySent(300, 60, 1000);
      expect(m.isCountingDown(1000)).assertTrue();
      expect(m.remainingSeconds(1000)).assertEqual(60);
      expect(m.canRequest(1000)).assertFalse();
      expect(m.resendLabel(1000)).assertEqual('60s 后重取');
      expect(m.expiresInSeconds()).assertEqual(300);
    });

    it('missing_or_absurd_retry_after_falls_back_and_clamps', 0, () => {
      // 服务端没给 retryAfter(0/负数)→ 按契约 60s;给了个荒唐的大数 → 最多 1 小时,
      // 界面绝不能被永久置灰
      const fallback: EmailCodeMachine = new EmailCodeMachine();
      fallback.applySent(0, 0, 0);
      expect(fallback.remainingSeconds(0)).assertEqual(EMAIL_CODE_RESEND_SECONDS);
      expect(fallback.expiresInSeconds()).assertEqual(EMAIL_CODE_TTL_SECONDS);

      const clamped: EmailCodeMachine = new EmailCodeMachine();
      clamped.applySent(300, 999999, 0);
      expect(clamped.remainingSeconds(0)).assertEqual(EMAIL_CODE_MAX_RESEND_SECONDS);
    });

    it('tick_updates_per_second_and_recovers_at_zero', 0, () => {
      const m: EmailCodeMachine = new EmailCodeMachine();
      m.applySent(300, 60, 0);
      // 不足 1 秒:文案没变,不需要重绘
      expect(m.tick(200)).assertFalse();
      expect(m.remainingSeconds(200)).assertEqual(60);
      // 走到第 1 秒:59s
      expect(m.tick(1000)).assertTrue();
      expect(m.remainingSeconds(1000)).assertEqual(59);
      expect(m.tick(1500)).assertFalse();
      // 冷却结束:恢复可点,且返回一次"变化"让按钮从置灰恢复
      expect(m.tick(60000)).assertTrue();
      expect(m.remainingSeconds(60000)).assertEqual(0);
      expect(m.canRequest(60000)).assertTrue();
      expect(m.resendLabel(60000)).assertEqual('获取验证码');
      expect(m.tick(61000)).assertFalse();
    });

    it('requesting_state_disables_the_button_and_shows_progress_label', 0, () => {
      const m: EmailCodeMachine = new EmailCodeMachine();
      m.beginRequest();
      expect(m.isRequesting()).assertTrue();
      expect(m.canRequest(0)).assertFalse();
      expect(m.resendLabel(0)).assertEqual('发送中…');
      m.endRequest();
      expect(m.canRequest(0)).assertTrue();
      expect(m.resendLabel(0)).assertEqual('获取验证码');
    });

    it('normalize_code_keeps_only_six_digits', 0, () => {
      expect(EmailCodeMachine.normalizeCode('a1b2c3d4e5f6g7')).assertEqual('123456');
      expect(EmailCodeMachine.normalizeCode(' 12 34 ')).assertEqual('1234');
      expect(EmailCodeMachine.normalizeCode('12-34-56')).assertEqual('123456');
      expect(EmailCodeMachine.normalizeCode('')).assertEqual('');
    });

    it('complete_code_requires_exactly_six_digits', 0, () => {
      expect(EmailCodeMachine.isCompleteCode('123456')).assertTrue();
      expect(EmailCodeMachine.isCompleteCode('12345')).assertFalse();
      expect(EmailCodeMachine.isCompleteCode('1234567')).assertFalse();
      expect(EmailCodeMachine.isCompleteCode('12345a')).assertFalse();
      expect(EmailCodeMachine.isCompleteCode('')).assertFalse();
    });

    it('auto_submit_fires_once_per_code', 0, () => {
      const m: EmailCodeMachine = new EmailCodeMachine();
      expect(m.shouldAutoSubmit('123456')).assertTrue();
      m.markSubmitted('123456');
      // 同一验证码不重复提交(避免 onChange 反复触发时连发请求)
      expect(m.shouldAutoSubmit('123456')).assertFalse();
      // 换了验证码就该提交
      expect(m.shouldAutoSubmit('654321')).assertTrue();
      // 提交失败后允许同一串再试
      m.markSubmitFailed();
      expect(m.shouldAutoSubmit('123456')).assertTrue();
      expect(m.lastSubmittedCode()).assertEqual('');
      // 位数不够不提交
      expect(m.shouldAutoSubmit('12345')).assertFalse();
    });

    it('auto_submit_is_blocked_while_requesting', 0, () => {
      const m: EmailCodeMachine = new EmailCodeMachine();
      m.beginRequest();
      expect(m.shouldAutoSubmit('123456')).assertFalse();
      m.endRequest();
      expect(m.shouldAutoSubmit('123456')).assertTrue();
    });

    it('dev_echo_code_is_accepted_only_when_it_is_six_digits', 0, () => {
      // devCode 只在开发模式回显;界面不得依赖它 —— 非法值一律当"没有回显"
      expect(EmailCodeMachine.validDevCode('123456')).assertEqual('123456');
      expect(EmailCodeMachine.validDevCode('12 34 56')).assertEqual('123456');
      expect(EmailCodeMachine.validDevCode('12345')).assertEqual('');
      expect(EmailCodeMachine.validDevCode('abcdef')).assertEqual('');
      expect(EmailCodeMachine.validDevCode('')).assertEqual('');
    });

    it('reset_clears_countdown_and_submit_memory', 0, () => {
      const m: EmailCodeMachine = new EmailCodeMachine();
      m.applySent(600, 60, 0);
      m.markSubmitted('123456');
      m.beginRequest();
      m.reset();
      expect(m.isCountingDown(0)).assertFalse();
      expect(m.canRequest(0)).assertTrue();
      expect(m.resendLabel(0)).assertEqual('获取验证码');
      expect(m.isRequesting()).assertFalse();
      expect(m.shouldAutoSubmit('123456')).assertTrue();
      expect(m.expiresInSeconds()).assertEqual(EMAIL_CODE_TTL_SECONDS);
    });

    it('expires_in_comes_from_the_response', 0, () => {
      const m: EmailCodeMachine = new EmailCodeMachine();
      m.applySent(600, 30, 500);
      expect(m.expiresInSeconds()).assertEqual(600);
      expect(m.remainingSeconds(500)).assertEqual(30);
      expect(m.resendLabel(500)).assertEqual('30s 后重取');
    });
  });

  describe('AuthReasonText', () => {

    it('maps_the_four_code_reasons_to_chinese_hints', 0, () => {
      // §7.6.5:不新增错误码,靠 details.reason 细化提示
      expect(reasonText(REASON_CODE_INVALID)).assertEqual('验证码不正确,请重新输入');
      expect(reasonText(REASON_CODE_EXPIRED)).assertEqual('验证码已过期,请重新获取');
      expect(reasonText(REASON_CODE_ATTEMPTS_EXCEEDED)).assertEqual('验证码错误次数过多已作废,请重新获取');
      expect(reasonText(REASON_CODE_THROTTLED)).assertEqual('请求过于频繁,请稍后再试');
      // 未知 reason(含空串)→ 不编文案,交给错误码兜底
      expect(reasonText('')).assertEqual('');
      expect(reasonText('not_guest')).assertEqual('');
      expect(reasonText('something_new')).assertEqual('');
    });

    it('reason_hints_are_distinct_from_each_other', 0, () => {
      const a: string = reasonText(REASON_CODE_INVALID);
      const b: string = reasonText(REASON_CODE_EXPIRED);
      const c: string = reasonText(REASON_CODE_ATTEMPTS_EXCEEDED);
      const d: string = reasonText(REASON_CODE_THROTTLED);
      expect(a === b).assertFalse();
      expect(a === c).assertFalse();
      expect(a === d).assertFalse();
      expect(b === c).assertFalse();
      expect(b === d).assertFalse();
      expect(c === d).assertFalse();
    });

    it('error_text_prefers_the_reason_and_falls_back_to_the_code', 0, () => {
      // 命中 reason:401 AUTH_INVALID_CREDENTIALS 不再是笼统的"邮箱或密码不正确"
      expect(errorTextWithReason(ERR_AUTH_INVALID_CREDENTIALS, REASON_CODE_EXPIRED))
        .assertEqual(reasonText(REASON_CODE_EXPIRED));
      expect(errorTextWithReason(ERR_AUTH_INVALID_CREDENTIALS, REASON_CODE_ATTEMPTS_EXCEEDED))
        .assertEqual(reasonText(REASON_CODE_ATTEMPTS_EXCEEDED));
      // 429 限流同样按 reason 提示
      expect(errorTextWithReason(ERR_RATE_LIMITED, REASON_CODE_THROTTLED))
        .assertEqual(reasonText(REASON_CODE_THROTTLED));
      // 没命中 reason:回落到 §7.4 的通用文案
      expect(errorTextWithReason(ERR_AUTH_INVALID_CREDENTIALS, ''))
        .assertEqual(errorText(ERR_AUTH_INVALID_CREDENTIALS));
      expect(errorTextWithReason(ERR_RATE_LIMITED, 'unknown_reason'))
        .assertEqual(errorText(ERR_RATE_LIMITED));
    });

    it('error_details_use_retry_after_sec_not_retry_after', 0, () => {
      // 契约 §7.6.5:错误体里是 details.retryAfterSec(**成功响应顶层才是 retryAfter**)
      const details: Object = JSON.parse('{"reason":"code_throttled","retryAfterSec":42}');
      const parsed: OrdoErrorDetails = parseErrorDetails(details);
      expect(parsed.reason).assertEqual(REASON_CODE_THROTTLED);
      expect(parsed.retryAfterSec).assertEqual(42);

      // 用错字段名(拿成功响应的 retryAfter 去解错误体)→ 取不到秒数,必须为 0,
      // 由 AppStore 回落到契约的 60s 兜底
      const wrongName: Object = JSON.parse('{"reason":"code_throttled","retryAfter":42}');
      expect(parseErrorDetails(wrongName).retryAfterSec).assertEqual(0);

      // 拿到 42s 就直接跑 42s 倒计时(夹取逻辑见 EmailCodeState)
      const m: EmailCodeMachine = new EmailCodeMachine();
      m.applySent(0, parsed.retryAfterSec, 0);
      expect(m.remainingSeconds(0)).assertEqual(42);
      expect(m.resendLabel(0)).assertEqual('42s 后重取');
      expect(m.canRequest(0)).assertFalse();
    });

    it('missing_or_malformed_details_never_throw', 0, () => {
      const empty: OrdoErrorDetails = parseErrorDetails(JSON.parse('{}'));
      expect(empty.reason).assertEqual('');
      expect(empty.retryAfterSec).assertEqual(0);
      // 字符串秒数 / 负数 / 小数:只接受正整数秒,小数向下取整
      expect(parseErrorDetails(JSON.parse('{"reason":"code_expired","retryAfterSec":"42"}')).retryAfterSec)
        .assertEqual(0);
      expect(parseErrorDetails(JSON.parse('{"reason":"code_expired","retryAfterSec":-5}')).retryAfterSec)
        .assertEqual(0);
      expect(parseErrorDetails(JSON.parse('{"reason":"code_expired","retryAfterSec":42.9}')).retryAfterSec)
        .assertEqual(42);
      expect(parseErrorDetails(JSON.parse('{"reason":"code_expired","retryAfterSec":42.9}')).reason)
        .assertEqual(REASON_CODE_EXPIRED);
      // 非对象 details(服务端只回字符串)→ 不抛异常,返回空结果
      expect(parseErrorDetails('boom').reason).assertEqual('');
      expect(parseErrorDetails('boom').retryAfterSec).assertEqual(0);
    });
  });
}
