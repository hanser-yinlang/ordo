/**
 * Ordo · 刷新控件(04-UI设计规范 §5.3「刷新控件(必须有可见效果)」)
 *
 * 规范:
 *  - 状态栏右侧改为**图标 + 文字**:28dp 圆形图标按钮(`OrdoIcons.refresh`)+ 状态文字;
 *  - 同步中:图标**连续旋转**(每圈 900ms,linear,持续到结束)+「同步中…」;
 *  - 成功:停转 + 短暂 success 色 +「已同步」,1.4s 后回常态;
 *  - 失败:danger 色 +「同步失败,点击重试」(常驻直到重试);
 *  - 同步中禁用,结束后 1.4s 内也禁用(防抖)。
 *
 * 状态判定全部在纯逻辑 `viewmodel/RefreshState.ets` 里(可被本机宿主直接跑用例),
 * 本组件只负责把状态画出来。
 *
 * 旋转做法(为什么不用 `iterations: -1` 的一次性无限动画):
 *  同步过程中 AppStore 会因为状态变化频繁触发重渲染;无限循环动画在属性被重设时有中断风险,
 *  于是改成"每 900ms 把目标角度 +360°"的节拍器 —— 目标值单调递增,`.animation` 每次都补一段
 *  900ms linear 的旋转,视觉上是**连续**的,且不受其它重渲染影响。同步结束即停表。
 */

import { OrdoColorTokens, OrdoColors, OrdoFont, OrdoIcons, OrdoMotion, OrdoRadius, OrdoSize, OrdoSpace } from '../../theme/Tokens.ets';

@Component
export struct RefreshControl {
  /** 状态文字(同步中… / 已同步 / 同步失败,点击重试) */
  @Prop label: string = '已同步';
  /** 'normal' | 'success' | 'danger' */
  @Prop tone: string = 'normal';
  /** 是否连续旋转 */
  @Prop @Watch('onSpinningChanged') spinning: boolean = false;
  /** 是否可点击(同步中禁用;成功后 1.4s 内防抖禁用) */
  @Prop canTap: boolean = true;
  /** 无障碍朗读文案(§8:状态不只靠颜色表达) */
  @Prop a11yText: string = '';
  /** 深色模式(与其它组件一样由父层决定) */
  @Prop dark: boolean = false;
  onTap: () => void = (): void => {};

  /** 旋转目标角度:每 900ms +360°,动画补间后看起来是匀速连转 */
  @State private angle: number = 0;
  private timer: number = -1;

  aboutToDisappear(): void {
    this.stopTicker();
  }

  onSpinningChanged(): void {
    if (this.spinning) {
      this.startTicker();
    } else {
      this.stopTicker();
    }
  }

  aboutToAppear(): void {
    if (this.spinning) {
      this.startTicker();
    }
  }

  private startTicker(): void {
    if (this.timer >= 0) {
      return;
    }
    this.timer = setInterval((): void => {
      this.angle = this.angle + 360;
    }, OrdoMotion.spinPerTurn);
  }

  private stopTicker(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private c(): OrdoColorTokens {
    return OrdoColors.of(this.dark);
  }

  /** 图标与文字同色:常态 textSecondary,成功 success,失败 danger(§5.3) */
  private toneColor(): string {
    if (this.tone === 'success') {
      return this.c().stateSuccess;
    }
    if (this.tone === 'danger') {
      return this.c().stateDanger;
    }
    return this.c().textSecondary;
  }

  build() {
    Row({ space: OrdoSpace.xs }) {
      Stack() {
        // 28dp 圆形图标按钮(§5.3)
        Circle()
          .width(OrdoSize.refreshIcon)
          .height(OrdoSize.refreshIcon)
          .fillOpacity(0)
          .stroke(this.c().lineHairline)
          .strokeWidth(1)
        Text(OrdoIcons.refresh)
          .fontSize(16)
          .fontColor(this.toneColor())
          .rotate({ angle: this.angle })
          .animation({
            duration: this.spinning ? OrdoMotion.spinPerTurn : 1,
            curve: Curve.Linear
          })
      }
      .width(OrdoSize.refreshIcon)
      .height(OrdoSize.refreshIcon)

      Text(this.label)
        .fontSize(OrdoFont.micro.size)
        .fontColor(this.toneColor())
    }
    .height(OrdoSize.minTouchTarget)
    .padding({ left: OrdoSpace.xs, right: OrdoSpace.xs })
    .borderRadius(OrdoRadius.pill)
    .opacity(this.canTap ? 1 : 0.6)
    // 同步中禁用 + 成功后 1.4s 防抖(§5.3)
    .enabled(this.canTap)
    .accessibilityText(this.a11yText.length > 0 ? this.a11yText : this.label)
    .onClick((): void => {
      if (!this.canTap) {
        return;
      }
      this.onTap();
    })
  }
}
