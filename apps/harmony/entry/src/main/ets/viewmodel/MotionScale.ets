/**
 * Ordo · 动效时长折算(04 §5 硬要求:开启系统「减弱动态效果」后所有动效降为 0ms 直接切换)
 *
 * 本文件刻意做成**纯逻辑**(不 import 任何 @kit/@ohos),因为:
 *   1. 宿主用例(`_qa/node-harness`)要能直接跑它 —— 读系统开关的那一半在 `theme/ReduceMotion.ets`;
 *   2. 三端同名同值的时长令牌(`theme/Tokens.ets` 的 `OrdoMotion`)保持不变,
 *      "要不要归零"只发生在本文件,便于一个用例覆盖全部过渡。
 *
 * 用法:时长一律写成 `MotionScale.ms(OrdoMotion.popIn)`。
 */
export class MotionScale {
  /** 系统「减弱动态效果」开关(由 `theme/ReduceMotion.ets` 启动时读入并订阅变化) */
  private static reduced: boolean = false;

  /** 供系统订阅回调写入(宿主用例也用它构造两种状态) */
  static apply(on: boolean): void {
    MotionScale.reduced = on;
  }

  static enabled(): boolean {
    return MotionScale.reduced;
  }

  /** 开启「减弱动态效果」时时长归零(§5),否则原样返回 */
  static ms(value: number): number {
    return MotionScale.reduced ? 0 : value;
  }

  /** 复位到默认(不减弱)。仅用例使用,避免组间互相影响。 */
  static reset(): void {
    MotionScale.reduced = false;
  }
}
