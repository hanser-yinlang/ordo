/**
 * Ordo · 应用入口 Ability(Stage 模型)
 * 职责:
 *  - 创建/销毁窗口,加载 pages/Index
 *  - 解析 ordo:// 深链(冷启动 want.uri 与热启动 onNewWant),写入 AppStorage 供页面消费
 *  - 日志遵守契约 §9:不打印令牌、口令、备注正文
 */

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x0D01;
const TAG: string = 'Ordo';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    this.consumeDeepLink(want);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err: BusinessError): void => {
      if (err !== null && err.code !== 0) {
        hilog.error(DOMAIN, TAG, 'loadContent 失败 code=%{public}d', err.code);
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent 成功');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }

  /** 热启动:再次收到 ordo:// 深链时更新 AppStorage 并递增序号,驱动页面消费 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onNewWant');
    this.consumeDeepLink(want);
  }

  private consumeDeepLink(want: Want): void {
    const uri: string | undefined = want.uri;
    if (uri === undefined || uri === null || uri.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>('ordo.deepLink', uri);
    const seq: number | undefined = AppStorage.get<number>('ordo.deepLinkSeq');
    const next: number = seq === undefined ? 1 : seq + 1;
    AppStorage.setOrCreate<number>('ordo.deepLinkSeq', next);
    // 只记录 scheme 与路径,不打印查询参数内容(可能包含待办标题)
    const pathOnly: string = uri.indexOf('?') >= 0 ? uri.substring(0, uri.indexOf('?')) : uri;
    hilog.info(DOMAIN, TAG, 'deep link: %{public}s', pathOnly);
  }
}
