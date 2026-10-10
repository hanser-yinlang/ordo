/**
 * Ordo · ohosTest 测试运行器(命令行 `hdc shell aa test` 的入口)
 *
 * 为什么需要:`aa test -b <bundle> -m <module> -s unittest OpenHarmonyTestRunner` 要求测试 HAP 里
 * 存在 `ets/testrunner/OpenHarmonyTestRunner.abc` 作为**应用入口点**;DevEco 面板的 "Run 'OhosTest'"
 * 走的是 TestAbility,不经过它。此前工程只有 TestAbility,命令行跑测试会以
 * `Cannot find module '&entry/src/ohosTest/ets/testrunner/OpenHarmonyTestRunner&'` 崩掉
 * (TestFinished-ResultCode: -1 / App died) —— 第六轮在真机上首跑即命中,故补齐这个标准文件。
 *
 * 行为:读取命令行参数(`-m` 模块名)→ 拉起同模块的 TestAbility →
 * TestAbility.onCreate 调用 `Hypium.hypiumTest(...)` 执行 test/List.test.ets 的全部用例,
 * 结果由测试框架回报给 `aa test`(可用 `-s class` 只跑某一组)。
 */

import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'OpenHarmonyTestRunner';
/** `-m` 参数缺失时的兜底模块名(与本模块 module.json5 的 name 一致) */
const DEFAULT_MODULE: string = 'entry_test';

export default class OpenHarmonyTestRunner implements TestRunner {
  constructor() {
  }

  onPrepare(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'OpenHarmonyTestRunner onPrepare');
  }

  onRun(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'OpenHarmonyTestRunner onRun');
    const args: abilityDelegatorRegistry.AbilityDelegatorArgs = abilityDelegatorRegistry.getArguments();
    const delegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
    const passed: string = args.parameters['-m'];
    const moduleName: string = passed === undefined || passed === null || passed.length === 0
      ? DEFAULT_MODULE
      : passed;
    const want: Want = {
      bundleName: args.bundleName,
      abilityName: 'TestAbility',
      moduleName: moduleName
    };
    delegator.startAbility(want, (err: BusinessError): void => {
      const text: string = err === null || err === undefined ? '' : JSON.stringify(err);
      hilog.info(DOMAIN, TAG, 'startAbility result: %{public}s', text);
    });
  }
}
