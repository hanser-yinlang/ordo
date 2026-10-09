/**
 * Ordo · Toast 提示条(04 §4:底部居中、圆角 pill、2.4s 自动消失;失败类常驻并带"重试")
 *
 * 用法:父组件传 `toastSeq: this.store.toast.seq` 与 `toastText: this.store.toast.text`,
 * seq 变化即触发 @Watch 刷新显示。
 */

import { OrdoFont, OrdoRadius, OrdoSpace } from '../../theme/Tokens.ets';

@Component
export struct OrdoToast {
  @Prop @Watch('onToastChanged') toastSeq: number = 0;
  @Prop toastText: string = '';
  /** 失败类提示常驻并显示"重试" */
  @Prop sticky: boolean = false;
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
      this.timerId = setTimeout((): void => {
        this.visible = false;
      }, 2400);
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
