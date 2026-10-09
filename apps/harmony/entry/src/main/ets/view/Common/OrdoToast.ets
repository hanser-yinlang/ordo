/**
 * Ordo · Toast 提示条(04 §4:底部居中、圆角 pill、2.4s 自动消失;失败类常驻并带"重试")
 *
 * 用法:父组件传 `toastSeq: this.store.toast.seq` 与 `toastText: this.store.toast.text`,
 * seq 变化即触发 @Watch 刷新显示。
 *
 * 动作按钮:`actionText` 非空时在文案右侧显示一个可点动作(左滑删除的「撤销」),
 * 此时停留时间放宽到 4s —— 04 §4 只规定了普通提示的 2.4s,撤销窗口太短会点不到,
 * 故按"可撤销"语义延长(样式、位置、圆角、配色仍与 §4 完全一致)。
 */

import { OrdoFont, OrdoRadius, OrdoSpace } from '../../theme/Tokens.ets';

/** 普通提示停留 2.4s(04 §4) */
const TOAST_MS: number = 2400;
/** 带动作(撤销)的提示停留 4s */
const TOAST_ACTION_MS: number = 4000;

@Component
export struct OrdoToast {
  @Prop @Watch('onToastChanged') toastSeq: number = 0;
  @Prop toastText: string = '';
  /** 失败类提示常驻并显示"重试" */
  @Prop sticky: boolean = false;
  /** 动作文案(空串 = 无动作) */
  @Prop actionText: string = '';
  onAction: () => void = (): void => {
  };
  onRetry: () => void = (): void => {
  };
  @State private visible: boolean = false;
  private timerId: number = -1;

  onToastChanged(): void {
    if (this.toastText.length === 0) {
      return;
    }
    this.visible = true;
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    if (!this.sticky) {
      const stay: number = this.actionText.length > 0 ? TOAST_ACTION_MS : TOAST_MS;
      this.timerId = setTimeout((): void => {
        this.visible = false;
      }, stay);
    }
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  build() {
    Column() {
      if (this.visible && this.toastText.length > 0) {
        Row({ space: OrdoSpace.s }) {
          Text(this.toastText)
            .fontSize(OrdoFont.caption.size)
            .fontColor('#FFFFFF')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.actionText.length > 0) {
            Text(this.actionText)
              .fontSize(OrdoFont.caption.size)
              .fontWeight(500)
              .fontColor('#FFFFFF')
              .decoration({ type: TextDecorationType.Underline, color: '#FFFFFF' })
              .onClick(() => {
                this.visible = false;
                this.onAction();
              })
          }
          if (this.sticky) {
            Text('重试')
              .fontSize(OrdoFont.caption.size)
              .fontWeight(500)
              .fontColor('#FFFFFF')
              .decoration({ type: TextDecorationType.Underline, color: '#FFFFFF' })
              .onClick(() => {
                this.onRetry();
              })
          }
        }
        .padding({ left: OrdoSpace.l, right: OrdoSpace.l, top: OrdoSpace.s, bottom: OrdoSpace.s })
        .backgroundColor('#1C1B19E6')
        .borderRadius(OrdoRadius.pill)
        .constraintSize({ maxWidth: 420 })
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: OrdoSpace.xl })
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
