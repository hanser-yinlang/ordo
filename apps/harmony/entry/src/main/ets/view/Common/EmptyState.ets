/**
 * Ordo · 空状态(04 §4:居中线性插图 64 + 标题 20/26 + 副文案 13/18 + 主按钮)
 */

import { OrdoColorTokens, OrdoFont, OrdoRadius, OrdoSize, OrdoSpace } from '../../theme/Tokens.ets';

@Component
export struct EmptyState {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop actionText: string = '';
  @Prop colors: OrdoColorTokens;
  onAction: () => void = (): void => {
  };

  build() {
    Column({ space: OrdoSpace.m }) {
      // 线性插图:一个开口圆环 + 一条短划线(Ordo 品牌图形)
      Stack() {
        Circle()
          .width(64)
          .height(64)
          .fillOpacity(0)
          .stroke(this.colors.lineHairline)
          .strokeWidth(3)
          .strokeDashArray([150, 40])
          .strokeDashOffset(20)
        Line()
          .width(22)
          .height(3)
          .backgroundColor(this.colors.accentPrimary)
          .borderRadius(2)
          .margin({ left: 20, top: 2 })
      }
      .width(64)
      .height(64)

      Text(this.title)
        .fontSize(OrdoFont.title.size)
        .fontWeight(OrdoFont.title.weight)
        .fontColor(this.colors.textPrimary)
        .textAlign(TextAlign.Center)

      Text(this.subtitle)
        .fontSize(OrdoFont.caption.size)
        .fontColor(this.colors.textSecondary)
        .textAlign(TextAlign.Center)
        .constraintSize({ maxWidth: 320 })

      if (this.actionText.length > 0) {
        Button(this.actionText)
          .height(OrdoSize.minTouchTarget)
          .fontSize(OrdoFont.body.size)
          .fontColor('#FFFFFF')
          .backgroundColor(this.colors.accentPrimary)
          .borderRadius(OrdoRadius.pill)
          .padding({ left: OrdoSpace.xl, right: OrdoSpace.xl })
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .padding({ top: 72, bottom: 72, left: OrdoSpace.xl, right: OrdoSpace.xl })
    .alignItems(HorizontalAlign.Center)
  }
}
