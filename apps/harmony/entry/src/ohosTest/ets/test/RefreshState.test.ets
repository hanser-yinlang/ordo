/**
 * Ordo · 刷新控件状态机用例(`viewmodel/RefreshState.ets`)
 *
 * 规范来源:docs/04-UI设计规范.md §5.3。
 * 校验点:
 *  1. 同步中:连续旋转 + 「同步中…」+ 按钮禁用;
 *  2. 成功:idle 后进 success、文案「已同步」、tone = success;
 *  3. 成功态 1.4s 后回落常态;1.4s 内保持禁用(防抖);
 *  4. 失败(offline / error / authRequired):tone = danger、文案「同步失败,点击重试」、常驻不回落;
 *  5. 点击重试立刻回到同步中;启动时的初始 idle 不冒充"成功"。
 */

import { describe, expect, it } from '@ohos/hypium';
import {
  REFRESH_HOLD_MS,
  REFRESH_SPIN_MS,
  RefreshMachine
} from '../../../main/ets/viewmodel/RefreshState.ets';

export default function refreshStateTest() {
  describe('RefreshState', () => {

    it('timing_constants_match_the_spec', 0, () => {
      // §5.3:每圈 900ms;成功 1.4s 后回到常态
      expect(REFRESH_SPIN_MS).assertEqual(900);
      expect(REFRESH_HOLD_MS).assertEqual(1400);
    });

    it('starts_idle_and_tappable', 0, () => {
      const m: RefreshMachine = new RefreshMachine();
      expect(m.getPhase()).assertEqual('idle');
      expect(m.label()).assertEqual('已同步');
      expect(m.tone()).assertEqual('normal');
      expect(m.isSpinning()).assertFalse();
      expect(m.canTap(0)).assertTrue();
    });

    it('initial_idle_does_not_fake_a_success', 0, () => {
      // 启动时 SyncEngine 会先报一次 idle;那不是"刚刚同步成功"
      const m: RefreshMachine = new RefreshMachine();
      m.applySyncPhase('idle', 1000);
      expect(m.getPhase()).assertEqual('idle');
      expect(m.tone()).assertEqual('normal');
    });

    it('syncing_spins_and_disables_the_button', 0, () => {
      const m: RefreshMachine = new RefreshMachine();
      m.applySyncPhase('syncing', 1000);
      expect(m.isSpinning()).assertTrue();
      expect(m.label()).assertEqual('同步中…');
      expect(m.canTap(1000)).assertFalse();
      expect(m.canTap(999999)).assertFalse();
    });

    it('success_shows_label_then_decays_after_1_4s', 0, () => {
      const m: RefreshMachine = new RefreshMachine();
      m.applySyncPhase('syncing', 1000);
      m.applySyncPhase('idle', 2000);
      expect(m.getPhase()).assertEqual('success');
      expect(m.label()).assertEqual('已同步');
      expect(m.tone()).assertEqual('success');
      expect(m.isSpinning()).assertFalse();
      // 1.4s 内保持禁用(防抖)
      expect(m.canTap(2000 + 1399)).assertFalse();
      expect(m.tick(2000 + 1399)).assertFalse();
      // 到点回落常态
      expect(m.tick(2000 + 1400)).assertTrue();
      expect(m.getPhase()).assertEqual('idle');
      expect(m.tone()).assertEqual('normal');
      expect(m.canTap(2000 + 1400)).assertTrue();
    });

    it('failure_is_danger_and_sticky_until_retry', 0, () => {
      const m: RefreshMachine = new RefreshMachine();
      m.applySyncPhase('syncing', 1000);
      m.applySyncPhase('error', 1500);
      expect(m.getPhase()).assertEqual('failed');
      expect(m.label()).assertEqual('同步失败,点击重试');
      expect(m.tone()).assertEqual('danger');
      expect(m.isSpinning()).assertFalse();
      // 失败态常驻:时间再久也不回落
      expect(m.tick(1500 + 100000)).assertFalse();
      expect(m.getPhase()).assertEqual('failed');
      // 且立刻可以重试
      expect(m.canTap(1500)).assertTrue();
      m.beginManual(1500);
      expect(m.getPhase()).assertEqual('syncing');
      expect(m.label()).assertEqual('同步中…');
    });

    it('offline_and_auth_required_are_failures_too', 0, () => {
      const offline: RefreshMachine = new RefreshMachine();
      offline.applySyncPhase('offline', 10);
      expect(offline.getPhase()).assertEqual('failed');
      expect(offline.tone()).assertEqual('danger');

      const auth: RefreshMachine = new RefreshMachine();
      auth.applySyncPhase('authRequired', 10);
      expect(auth.getPhase()).assertEqual('failed');
      expect(auth.label()).assertEqual('同步失败,点击重试');
    });

    it('manual_tap_spins_immediately', 0, () => {
      const m: RefreshMachine = new RefreshMachine();
      m.beginManual(500);
      expect(m.isSpinning()).assertTrue();
      expect(m.canTap(500)).assertFalse();
      // 手动触发后再报 idle 才算成功
      m.applySyncPhase('idle', 900);
      expect(m.getPhase()).assertEqual('success');
    });

    it('reset_clears_previous_account_state', 0, () => {
      // 退出登录 / 会话失效:不能把上一个账号的"已同步"留在界面上
      const m: RefreshMachine = new RefreshMachine();
      m.applySyncPhase('syncing', 0);
      m.applySyncPhase('idle', 100);
      expect(m.getPhase()).assertEqual('success');
      m.reset();
      expect(m.getPhase()).assertEqual('idle');
      expect(m.canTap(100)).assertTrue();
    });

    it('accessibility_text_never_relies_on_color_alone', 0, () => {
      const m: RefreshMachine = new RefreshMachine();
      expect(m.accessibilityText().indexOf('已同步') >= 0).assertTrue();
      m.applySyncPhase('syncing', 0);
      expect(m.accessibilityText().indexOf('正在同步') >= 0).assertTrue();
      m.applySyncPhase('error', 10);
      expect(m.accessibilityText().indexOf('同步失败') >= 0).assertTrue();
    });
  });
}
