/**
 * Ordo · 减弱动态效果折算用例(04 §5 硬要求 / §5.5 过渡动效)
 *
 * §5 原文:「**必须遵守系统的"减弱动态效果"设置**:开启后所有动效降为 0ms 直接切换。」
 * 鸿蒙侧的实现拆成两半:系统读取(`theme/ReduceMotion.ets`,依赖 @kit.AccessibilityKit,
 * 只能在设备/编译期验证)+ 纯逻辑折算(`viewmodel/MotionScale.ets`,本组用例直接覆盖)。
 *
 * 这组用例钉住三件事:
 *  1. 默认(不减弱)时**一个时长都不许被改**(`ms` 恒等);
 *  2. 开启后 §5.5 的每个过渡时长都归零(浮层入/退、页面淡入、抽屉、清单展开、详情栏、主界面淡入);
 *  3. 鸿蒙端的令牌值与三端契约同值、缓动同一条曲线(与 Windows/Android 的契约用例对齐)。
 */

import { describe, expect, it } from '@ohos/hypium';
import { MotionScale } from '../../../main/ets/viewmodel/MotionScale.ets';
import { OrdoMotion } from '../../../main/ets/theme/Tokens.ets';

/** §5.5 全部过渡时长(鸿蒙端令牌) */
const TRANSITIONS: number[] = [
  OrdoMotion.popIn,
  OrdoMotion.popOut,
  OrdoMotion.pageFade,
  OrdoMotion.sidebarCollapse,
  OrdoMotion.checklistExpand,
  OrdoMotion.detailRise,
  OrdoMotion.mainFadeIn
];

export default function registerMotionScaleTests(): void {
  describe('MotionScale', () => {
    it('durations_are_untouched_while_reduce_motion_is_off', 0, () => {
      MotionScale.reset();
      expect(MotionScale.enabled()).assertFalse();
      for (let i = 0; i < TRANSITIONS.length; i++) {
        expect(MotionScale.ms(TRANSITIONS[i])).assertEqual(TRANSITIONS[i]);
      }
      // 0 时长也要原样返回,不能变成负数或 NaN
      expect(MotionScale.ms(0)).assertEqual(0);
    });

    it('every_transition_collapses_to_zero_when_reduce_motion_is_on', 0, () => {
      MotionScale.apply(true);
      expect(MotionScale.enabled()).assertTrue();
      for (let i = 0; i < TRANSITIONS.length; i++) {
        expect(MotionScale.ms(TRANSITIONS[i])).assertEqual(0);
      }
    });

    it('turning_it_back_off_restores_the_original_durations', 0, () => {
      MotionScale.apply(true);
      expect(MotionScale.ms(OrdoMotion.popIn)).assertEqual(0);
      MotionScale.apply(false);
      expect(MotionScale.enabled()).assertFalse();
      expect(MotionScale.ms(OrdoMotion.popIn)).assertEqual(OrdoMotion.popIn);
      MotionScale.reset();
    });

    it('harmony_tokens_match_the_three_platform_contract', 0, () => {
      // §5「其他」+ §5.5 v1.7:三端同名同值(Windows/Android 的契约用例钉同一组数)
      expect(OrdoMotion.popIn).assertEqual(280);
      expect(OrdoMotion.popOut).assertEqual(200);
      expect(OrdoMotion.pageFade).assertEqual(240);
      expect(OrdoMotion.sidebarCollapse).assertEqual(260);
      expect(OrdoMotion.checklistExpand).assertEqual(220);
      expect(OrdoMotion.detailRise).assertEqual(280);
      // §2.3 的基础时长与缓动
      expect(OrdoMotion.fast).assertEqual(120);
      expect(OrdoMotion.base).assertEqual(220);
      expect(OrdoMotion.slow).assertEqual(320);
      expect(OrdoMotion.easingStandard).assertEqual('cubic-bezier(0.2, 0.8, 0.2, 1)');
      // §5.5 过渡用「柔起长滑」的曲线:起步过猛的 standard 只留给既有动效
      expect(OrdoMotion.easingEnter).assertEqual('cubic-bezier(0.2, 0, 0, 1)');
    });

    it('scale_never_multiplies_or_clamps_a_duration', 0, () => {
      // 折算只有两个档位:原值 或 0。防止以后有人改成"乘系数/夹取"而悄悄改变时序。
      MotionScale.apply(false);
      expect(MotionScale.ms(1)).assertEqual(1);
      expect(MotionScale.ms(900)).assertEqual(900);
      MotionScale.apply(true);
      expect(MotionScale.ms(1)).assertEqual(0);
      expect(MotionScale.ms(900)).assertEqual(0);
      MotionScale.reset();
    });
  });
}
