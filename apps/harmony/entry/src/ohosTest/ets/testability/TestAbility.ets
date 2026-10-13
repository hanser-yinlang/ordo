/**
 * Ordo · ohosTest 测试 Ability
 * 由 DevEco Studio 的 "Run 'OhosTest'" 触发,使用 Hypium 框架执行 test/List.test.ets 中的四组用例。
 */

import { AbilityConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Hypium } from '@ohos/hypium';
import testsuite from '../test/List.test';

const DOMAIN: number = 0x0D02;
const TAG: string = 'OrdoTest';

/**
 * 把 **UIAbility 上下文**交给设备端用例。
 *
 * 为什么需要:`relationalStore.getRdbStore()` 只接受 ability 上下文,
 * `abilityDelegator.getAppContext()`(应用上下文)会被判为 `Illegal context`;
 * 而真库回归用例(`RelationalStore.test.ets`)必须打开真 SQLite 才有意义。
 */
export class TestContext {
  static ability: common.UIAbilityContext | null = null;
}

export default class TestAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'TestAbility onCreate');
    TestContext.ability = this.context;
    const abilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
    const abilityDelegatorArguments = abilityDelegatorRegistry.getArguments();
    Hypium.hypiumTest(abilityDelegator, abilityDelegatorArguments, testsuite);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'TestAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'TestAbility onWindowStageCreate');
    // loadContent 在 SDK 中带 @throws,必须显式处理(否则 ArkTS 编译告警)
    try {
      windowStage.loadContent('testability/pages/Index', (err: BusinessError): void => {
        if (err !== null && err.code !== 0) {
          hilog.error(DOMAIN, TAG, 'loadContent 失败 code=%{public}d', err.code);
        }
      });
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'loadContent 异常 code=%{public}d', err === null ? 0 : err.code);
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'TestAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'TestAbility onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'TestAbility onBackground');
  }
}
