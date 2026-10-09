/**
 * Ordo · 滑动手势的动作区按钮(ListItem.swipeAction 的 CustomBuilder 内容)
 *
 * 04-UI规范 §6「切换完成 = 点击复选框 / 右滑」「删除 = 左滑删除」「排期 = 行右滑」:
 *  - 右滑露出左侧动作区:完成,底色 `state.success`(§2.1);
 *  - 左滑露出右侧动作区:删除,底色 `state.danger`,旁边并列排期入口。
 *
 * 用独立组件而不是 `@Builder` 的原因:动作区需要绑定**这一行**的待办 id,
 * 组件化后参数由 LazyForEach 的 itemGenerator 闭包在构造时确定,不依赖 @Builder 的传参形式。
 */

import { OrdoFont, OrdoSize } from '../../theme/Tokens.ets';

@Component
export struct SwipeActionBar {
  /** 图标字形(如 ✓ / ⌫ / ▦) */
  @Prop glyph: string = '';
  /** 文案 */
  @Prop label: string = '';
  /** 底色(令牌值由调用方传入) */
  @Prop bg: string = '';
  /** 动作区宽度 */
  @Prop barWidth: number = OrdoSize.swipeActionWidth;
  onTap: () => void = (): void => {
  };

  build() {
    Column({ space: 2 }) {
      Text(this.glyph)
        .fontSize(OrdoFont.body.size)
        .fontColor('#FFFFFF')
      Text(this.label)
        .fontSize(OrdoFont.micro.size)
        .fontColor('#FFFFFF')
        .maxLines(1)
    }
    .width(this.barWidth)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.bg)
    .onClick(() => {
      this.onTap();
    })
  }
}
