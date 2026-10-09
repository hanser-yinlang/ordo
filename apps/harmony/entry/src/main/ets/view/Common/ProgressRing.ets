/**
 * Ordo · 项目进度环(04 §4:18×18,底色 line.hairline,进度 accent.primary,线宽 2)
 * 完成度到达 100% 时播放一次高亮脉冲(04 §5 第 900ms 项)
 */

@Component
export struct ProgressRing {
  /** 0..1 */
  @Prop progress: number = 0;
  @Prop size: number = 18;
  @Prop stroke: number = 2;
  @Prop color: string = '#5B5BD6';
  @Prop trackColor: string = '#E7E5DF';
  /** 由外部递增,用于触发脉冲动效 */
  @Prop pulseSeq: number = 0;
  @State private scale: number = 1;

  build() {
    Stack() {
      Progress({
        value: this.progress * 100,
        total: 100,
        type: ProgressType.Ring
      })
        .width(this.size)
        .height(this.size)
        .color(this.color)
        .backgroundColor(this.trackColor)
        .style({ strokeWidth: this.stroke })
        .scale({ x: this.scale, y: this.scale })
    }
    .width(this.size)
    .height(this.size)
    .onAppear(() => {
      if (this.progress >= 1) {
        this.playPulse();
      }
    })
  }

  private playPulse(): void {
    animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.scale = 1.25;
    });
    animateTo({ duration: 220, delay: 220, curve: Curve.EaseIn }, () => {
      this.scale = 1;
    });
  }
}
