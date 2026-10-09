/**
 * Ordo · ohosTest 测试用页面(测试 Ability 的前台页面,展示模块名与用例范围)
 */

@Entry
@Component
struct Index {
  build() {
    Column({ space: 8 }) {
      Text('Ordo 单元测试')
        .fontSize(20)
        .fontWeight(600)
      Text('NaturalDateParser · ListQuery · RepeatEngine · SyncMerge')
        .fontSize(13)
        .fontColor('#7A776F')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#FBFAF7')
  }
}
