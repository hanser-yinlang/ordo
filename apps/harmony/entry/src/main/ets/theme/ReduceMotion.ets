/**
 * Ordo · 系统「减弱动态效果」开关(鸿蒙侧的系统读取层)
 *
 * 系统路径:设置 → 关怀和无障碍 → 高级视觉辅助 → 过渡动画。
 * 本文件只做两件事:启动时**读一次**系统状态、**订阅**后续变化,然后转交给纯逻辑
 * `viewmodel/MotionScale.ets`(它才是所有时长折算的唯一出口,见那里的说明)。
 *
 * 两条官方约束(见 SDK `@ohos.accessibility.d.ts` 的 `onAnimationReduceStateChange` 注释):
 *   - 订阅回调**必须是命名函数**,匿名函数每次注册都会生成新的底层对象,注销时拿不回同一引用(内存泄漏);
 *   - 注册后必须在生命周期结束前 `offAnimationReduceStateChange` 注销,否则可能崩溃。
 * 本组件是 @Entry 常驻页面(进程存续期间不销毁),故订阅只注册一次,随进程回收。
 */
import { accessibility } from '@kit.AccessibilityKit';
import { MotionScale } from '../viewmodel/MotionScale.ets';

/** 系统开关回调:命名函数(不能写成匿名箭头函数,见文件头) */
function onReduceStateChange(on: boolean): void {
  MotionScale.apply(on);
}

export class ReduceMotion {
  private static bound: boolean = false;

  /**
   * 读一次系统状态并订阅后续变化;重复调用无副作用。
   * 设备/形态不支持该能力(抛错)时按"不减弱"处理,不影响任何功能。
   */
  static bind(): void {
    if (ReduceMotion.bound) {
      return;
    }
    ReduceMotion.bound = true;
    try {
      MotionScale.apply(accessibility.isAnimationReduceEnabledSync());
    } catch (e) {
      MotionScale.apply(false);
    }
    try {
      accessibility.onAnimationReduceStateChange(onReduceStateChange);
    } catch (e) {
      MotionScale.apply(false);
    }
  }
}
