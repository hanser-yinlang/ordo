# Ordo(序)· 鸿蒙端(HarmonyOS NEXT / Stage 模型 / ArkTS)

> 契约来源:`ordo/docs/03-数据模型与同步协议.md`(FROZEN v1)与 `ordo/docs/04-UI设计规范.md`(ordo-ds@1.0.0)
> 状态:**已在本机 DevEco Studio 26.0.0.821 + HarmonyOS SDK 26.0.0(API 26)上编译通过**,
> `assembleHap` 与 ohosTest 编译均 BUILD SUCCESSFUL、**ArkTS 告警 0**(见 §3「本机构建」与 §8「编译告警」)。
> 尚未签名、未上真机(见 §3.3 签名配置缺失)。

## 0. v1.5 变更速览:纯本地、不联网

- **彻底删除云同步**:`core/sync/**`(SyncApi / SyncEngine / RealtimeClient / SyncTypes)、会话与令牌存储、
  outbox push/pull、WebSocket 通道、`AppStore` 里的同步装配与状态**全部移除**;应用变成**纯本地应用**。
- **删除同步 UI**:刷新控件(`RefreshControl`/`RefreshState`)、状态栏同步指示与「同步中 / 已同步 / 同步失败」
  文案、设置页「同步」区块;侧栏底部改为「纯本地」。
- **启动**:读本机稳定工作区标识 → 开本地库 → 本地引擎 → 直接渲染主界面;**不发任何网络请求**。
- **权限**:`module.json5` 已移除 `ohos.permission.INTERNET`(依据见 §6.7)。
- **保留**:本地存储(含 §7.0.1 的 RDB 引号写盘修复)、本地业务引擎与除同步外的全部界面。
- 工作区标识见 §6.1.1;变更记录见 §11。

## 1. 关键架构决策

鸿蒙端**不复用 KMP `shared/core`**:Stage 模型的 ArkTS 运行时无法直接消费 Kotlin/Native 产物。
因此本端把契约 §2(数据模型)、§4(派生清单)、§5(中文 NLP)、§6(重复引擎)、§7(同步协议)
**用强类型 ArkTS 重新实现一遍**,并保持字段名、枚举值、优先级与判定规则与契约逐字一致。

```
UI(ArkUI 声明式)          view/** · pages/** · theme/Tokens.ets
        │  @Observed + @ObjectLink(单向数据流)
视图模型                   viewmodel/AppStore.ets(导航 / 浮层 / 查询门面 / 写入门面 / 派生缓存 / 账号)
        │
业务引擎                   core/store/OrdoEngine.ets(唯一实体读写入口 + §3 不变量 + §7.3 合并)
   ├── core/query/ListQuery.ets        契约 §4 每条规则一个函数
   ├── core/nlp/NaturalDateParser.ets  契约 §5
   ├── core/repeat/RepeatEngine.ets    契约 §6
   ├── core/storage/**                 §8:RelationalStore(RDB) / MemoryStore(测试与降级)
   └── (v1.5 起无 core/sync:纯本地,没有任何网络层)
```

- **本地优先**:所有写操作先改内存并立即 `bump()` 通知 UI,再异步落库(契约 §7.1;v1.5 起没有远端,草稿 op 只作本地记账)。
- **单一事实来源**:`Project.headings` 为规范存放处,`headings` 表单独持久化,装载时装配。
- **无循环依赖**:引擎的合并类型独立在 `core/store/ApplyTypes.ets`,不依赖任何网络模块。
- **渲染驱动**:`AppStore` 标 `@Observed`,任何状态变化 `changeSeq + 1`,子组件用 `@ObjectLink` 重新渲染;
  派生查询另有版本号缓存,避免同一次渲染内重复全量重算(见 §7.2)。

## 2. 目录结构

```
ordo/apps/harmony/
├── build-profile.json5 / oh-package.json5 / hvigorfile.ts     工程级配置
├── hvigor/hvigor-config.json5         hvigor 版本与依赖(hvigor 6.26.4)
├── AppScope/
│   ├── app.json5                     bundleName com.ordo.app,版本 1.0.0
│   └── resources/base/{element/string.json, media/app_icon.png}
├── entry/
│   ├── build-profile.json5 / hvigorfile.ts / oh-package.json5 / obfuscation-rules.txt
│   └── src/
│       ├── main/
│       │   ├── module.json5           权限(INTERNET / NOTIFICATION_CONTROLLER / PUBLISH_AGENT_REMINDER)+ ordo:// skills
│       │   ├── resources/             base|dark|zh_CN|en_US 的 string/color/float + main_pages
│       │   └── ets/
│       │       ├── entryability/EntryAbility.ets        启动 + 深链
│       │       ├── core/                                契约核心(纯 ArkTS,不依赖 UI)
│       │       │   ├── model/Entities.ets               §2 全部实体与枚举 + 克隆器
│       │       │   ├── store/OrdoEngine.ets             §3 不变量 / §7.1 Op 产出 / §7.3 合并
│       │       │   ├── query/ListQuery.ets              §4 派生清单
│       │       │   ├── nlp/NaturalDateParser.ets        §5 中文 NLP
│       │       │   ├── repeat/RepeatEngine.ets          §6 重复引擎
│       │       │   ├── sync/SyncApi|SyncEngine|RealtimeClient|SyncTypes.ets   §7 同步(含 §7.6 guest/upgrade + §7.6.5 邮箱验证码)
│       │       │   ├── session/OrdoSession.ets          §7.6 会话 / 游客 / 按用户目录名(纯逻辑)
│       │       │   ├── storage/OrdoStore|RelationalStore|MemoryStore.ets      §8 存储(账号库 + 应用级库)
│       │       │   ├── notify/ReminderAgent.ets         reminderAgentManager 到点提醒
│       │       │   ├── deeplink/DeepLink.ets            ordo:// 解析
│       │       │   ├── util/{DateUtil,Ids}.ets          日期与 ULID
│       │       │   └── SeedData.ets                     中文示例数据
│       │       ├── theme/Tokens.ets                     04 §2 设计令牌(深浅两套)+ OrdoIcons + 动效常量
│       │       ├── viewmodel/AppStore.ets               @Observed 视图模型 + 派生缓存 + 静默匿名会话
│       │       ├── viewmodel/ReorderMath.ets            拖拽排序纯计算(容器键 / 落点 / 是否开放)
│       │       ├── viewmodel/PressGesture.ets           04 §5.2/§5.4 长按 400ms + 6px 判定 + 落点换算(纯逻辑)
│       │       ├── viewmodel/RefreshState.ets           04 §5.3 刷新控件状态机(纯逻辑)
│       │       ├── viewmodel/SilentAuth.ets             v1.4 静默匿名会话:启动分支 / 退避 / 目录采纳规则(纯逻辑)
│       │       ├── viewmodel/FabMenu.ets                04 §5.2 快加号菜单:图标枚举 / 几何 / 可用性(纯逻辑)
│       │       ├── view/{Sidebar,ListPage,DetailCard,ScheduleSheet,FastFindSheet,QuickAddButton}.ets
│       │       ├── view/list/RowModel.ets               行模型 + 行指纹 + 行级差量 + 拖拽提示折进指纹(纯逻辑)
│       │       ├── view/list/RowDataSource.ets          LazyForEach 数据源(BasicDataSource)
│       │       ├── view/list/TodoRow.ets                待办行组件(按行指纹重渲染;抬起 / 让位 / 指示线)
│       │       ├── view/list/SwipeActionBar.ets         左右滑动作区按钮
│       │       ├── view/Common/{ProgressRing,EmptyState,OrdoToast,RefreshControl,GestureUtil}.ets
│       │       └── pages/{Index,SettingsPage}.ets
│       └── ohosTest/                  Hypium 用例 + 测试 Ability + testrunner(命令行 aa test 入口)
├── _qa/                               构建与自检脚本(非运行时代码,不参与打包)
│   ├── build.ps1                      环境变量 + 构建 + 告警计数包装脚本
│   ├── warn-report.ps1                解析构建日志里的 ArkTS 告警/错误
│   ├── build-harness.py               本机逻辑测试宿主构建器(见 §3.4.1)
│   ├── node-harness/                  宿主源码:Hypium 垫片 + runner + 时钟冻结
│   ├── row-perf-harness.mjs           行级刷新评测:真实 RowModel/RowDataSource 在 Node 上跑(见 §7.3)
│   ├── row-perf-report.{md,json}      评测产物(自动生成)
│   ├── selfcheck.py                   静态自检:ArkTS 禁用语法 / 相对导入 / 符号导出一致性
│   ├── scan_damage.py                 U+FFFD 与中文问号残留扫描
│   ├── repair_encoding.py             GBK 往返损坏的一键还原
│   ├── make_icon.py                   生成 app_icon.png
│   └── build-*.log                    历史构建日志(证据留档)
└── README.md
```

## 3. 本机构建(Windows / 已实测)

### 3.1 环境要求(实测版本,不要降级)

| 项 | 本机实测版本 | 路径 / 说明 |
|---|---|---|
| DevEco Studio | **26.0.0.821** | `C:\Program Files\Huawei\DevEco Studio` |
| HarmonyOS SDK | **26.0.0(API 26)**,`compileSdkVersion 26.0.0.105` | `%DEVECO_SDK_HOME%` = `<DevEco>\sdk`(实际用 `<DevEco>\sdk\default`) |
| hvigor | **6.26.4** | `<DevEco>\tools\hvigor\bin\hvigorw.js` |
| ohpm | 随 DevEco 附带 | `<DevEco>\tools\ohpm\bin` |
| Node.js | **v24.14.1**(DevEco 自带,勿用系统 Node) | `<DevEco>\tools\node\node.exe` |
| JDK | DevEco 自带 jbr | `<DevEco>\jbr\bin` |
| compatibleSdkVersion / targetSdkVersion | **`"26.0.0"`** | `build-profile.json5`;API 26+ 的取值必须是带引号的四段式字符串 |
| 依赖 | `ohpm install` 已执行 | 生成 `oh_modules/`(工程已声明 `@ohos/hypium@1.0.19`) |

> API 26 起 `compatibleSdkVersion` 不再接受 `5.0.0(12)` 之类的旧写法,必须是 `"26.0.0"`。
> `hvigor/hvigor-config.json5` 与 `build-profile.json5` 中的 SDK 版本字段已被工程主管修正,**请勿回退**。

### 3.2 构建命令(可复制执行)

```powershell
$deveco="C:\Program Files\Huawei\DevEco Studio"
$env:DEVECO_SDK_HOME="$deveco\sdk"
$env:PATH="$deveco\jbr\bin;$deveco\tools\node;$deveco\tools\ohpm\bin;$env:PATH"
cd C:\Users\admin\Desktop\Ordo\ordo\apps\harmony
& "$deveco\tools\node\node.exe" "$deveco\tools\hvigor\bin\hvigorw.js" --mode module -p product=default assembleHap --no-daemon
```

实测输出(第五轮 · 2026-10-10 11:26,登录门禁 + 游客 + 按用户隔离 + §5.2/§5.3/§5.4 落地后):

```
> hvigor Finished :entry:default@CompileArkTS... after 7 s 131 ms
> hvigor Finished :entry:default@PackageHap... after 324 ms
> hvigor BUILD SUCCESSFUL in 10 s 19 ms
33 tasks in total: 17 executed, 16 up-to-date
```

产物:`entry/build/default/outputs/default/entry-default-unsigned.hap`(1375.5 KB)。

同一命令在**第六轮**(2026-10-10,新增 §7.6.5 邮箱验证码登录后)的实测:

```
> hvigor Finished :entry:default@CompileArkTS... after 5 s 44 ms
> hvigor BUILD SUCCESSFUL in 8 s 325 ms
33 tasks in total: 17 executed, 16 up-to-date
```

产物:`entry-default-unsigned.hap`(1446.1 KB);ArkTS ERROR 0 / WARN 0,
stderr 里只有既有的 `WARN: No signingConfig found for product default`。

> **注意**:`DEVECO_SDK_HOME` 必须先设置。未设置时 hvigor 直接报
> `ERROR: 00303217 Configuration Error / Invalid value of 'DEVECO_SDK_HOME'`。
> 另外该命令会把 `WARN: No signingConfig found for product default` 写到 stderr,
> 在 PowerShell 里会被包装成 `NativeCommandError` 记录,**这不代表构建失败**——判定成功请只看 stdout 的
> `BUILD SUCCESSFUL`。

**每次改动后只编译、不清缓存**(增量,约 1~12 秒):

```powershell
# 仓库内已提供包装脚本(设置好环境变量 + 统计 ArkTS 告警/错误数)
powershell -NoProfile -ExecutionPolicy Bypass -File _qa\build.ps1                 # assembleHap
powershell -NoProfile -ExecutionPolicy Bypass -File _qa\build.ps1 -Clean          # 先删 entry/build 与 .hvigor/cache 再全量编译
powershell -NoProfile -ExecutionPolicy Bypass -File _qa\build.ps1 -OhosTest       # 编译 ohosTest 测试代码
```

### 3.3 签名配置与"能不能上设备"(第六轮已实测)

- 工程**故意留空 `signingConfigs`**(`build-profile.json5`),以免把本机证书路径提交进仓库;
  hvigor 因此提示 `WARN: No signingConfig found for product default`,产物是 **unsigned HAP**。
- 本机 `%USERPROFILE%\.ohos\config` 下**没有**任何调试证书(第六轮再次确认)。
- **但鸿蒙模拟器接受 unsigned HAP**:第六轮在 `emulator 7.0.0.107(API 26)` 上实测
  `hdc install entry-default-unsigned.hap` → `install bundle successfully`,
  `hdc install entry-ohosTest-unsigned.hap` 同样成功,`aa test` 也能跑完整套用例(见 §3.4.3)。
  所以**"无证书"只挡真机/上架,不挡模拟器**;早期"不能跑 Hypium"的结论据此更正。
- 真机 / 上架仍需签名(两条路,都要华为开发者账号):
  1. **自动签名(推荐)**:DevEco Studio → `File > Project Structure > Signing Configs` →
     登录华为账号 → 勾选 **Automatically generate signature**。此操作会生成
     `%USERPROFILE%\.ohos\config\openharmony\default_*.p12/.cer/.p7b` 并自动回填 `signingConfigs`
     (**不要把这些路径提交进仓库**)。
  2. **手动签名**:在 AppGallery Connect 申请调试证书 + Profile,再用 SDK 自带的
     `<DevEco>\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar` 签名。

### 3.4 跑测试(本机宿主 + 模拟器两条路)

#### 3.4.1 本机逻辑测试宿主(无需设备,已跑通 133/133)

Hypium 用例在设备上跑需要签名,而本机没有证书。但**十二组用例里的十一组只依赖纯逻辑模块**
(`core/` 下除 `RelationalStore` / `RealtimeClient` / `SyncApi` / `ReminderAgent` 之外的模块,
外加 `core/session/OrdoSession.ets`、`viewmodel/ReorderMath.ets`、`viewmodel/PressGesture.ets`、
`viewmodel/RefreshState.ets`、`viewmodel/SilentAuth.ets`、`viewmodel/FabMenu.ets`、
`view/list/RowModel.ets`,全部不含 `@ohos`/`@kit` 依赖;
第 12 组 `RelationalStore.test.ets` 必须连真库,只在设备上跑),
断言也只用到 `describe` / `it` / `expect` + `assertEqual|assertTrue|assertFalse`。
因此工程内提供了一套**本机宿主**,用 DevEco 自带的 tsc 编译后由 Node 真正执行:

```powershell
cd C:\Users\admin\Desktop\Ordo\ordo\apps\harmony
python _qa\build-harness.py
```

> 工程根目录是**从脚本自身位置推导**的(`os.path.dirname(os.path.dirname(__file__))`)。
> 项目从 `Desktop\WeChat\ordo` 迁到 `Desktop\Ordo\ordo` 时,写死的绝对路径会让宿主直接跑不起来
> (`FileNotFoundError`),改成自推导后与仓库位置解耦。

它做四件事:

1. 把纯逻辑核心模块与 `ohosTest` 的用例(设备端真库那组除外)复制到 `_qa/node-harness/src`,并去掉 `.ets` 后缀;
2. 用一个 Hypium 垫片(`_qa/node-harness/src/hypium-shim.ts`)实现 `describe/it/expect` 与断言,
   **真正 await 异步用例**(`async (done) => …` 形态,不会在断言执行前误判通过);
3. 把时钟冻结到 **2026-10-08**(`freeze-clock.ts`)—— 用例注释明确写着"固定今天为 2026-10-08",
   但 `DateUtil.todayISO()` 一类路径仍会读系统时间,不冻结就会跨天假失败;
4. `tsc`(strict + noImplicitAny + strictNullChecks)编译 → Node 运行 → 汇总,退出码 0 = 全通过。

实测结果(第六轮 · 2026-10-10,新增 §7.6.5 邮箱验证码登录 + §5.2 快加号菜单图标):

```
describe 块: 11     用例总数: 133      通过: 133      失败: 0
RESULT: ALL PASSED
```

> 第六轮新增第二组 8 条用例(总数 134 → 142,只增不减):
> `FabMenu.test.ets`(§5.2 v1.3:项目视图 4 项 / 其余视图 3 项、**顺序与文案**、
> **图标枚举 → 形状**映射(plus / projectH / area / heading,并显式断言不再是 `◎ ▣ ▤` 字体字形)、
> `Ctrl+N` 只挂在「新建待办」、**「新建标题」仅项目视图可用**的可用性规则、
> 面板与条目尺寸(≥208 / radius 12 / 高 ≥44 / 左内边距 9 / 图标间距 8 / 条目 radius 7)、
> 20×20 viewBox 的**逐条几何与线宽**)。
>
> **v1.4 移除登录后的用例数变化(如实报数)**:142 → 133 —— 删掉 `EmailCodeState.test.ets` 18 条(验证码登录整套 UI 已移除),新增 `SilentAuth.test.ets` 9 条(启动分支 / **目录标识 §7.6.6** / 退避 / 状态机)。设备端真库那组(`RelationalStore.test.ets`,2 条)不在宿主里跑,故设备端套件应为 133 + 2 = 135。
> `EmailCodeState.test.ets`(§7.6.5:6 位 / 300s / 60s 常量、响应 `retryAfter` 起倒计时、
> 缺值与超大 `retryAfter` 的兜底与夹取、按秒 tick 且到点恢复可点、请求中禁用与"发送中…"文案、
> 只留数字并截到 6 位、满 6 位**只自动提交一次**且失败后可重试、`devCode` 只接受 6 位数字
> (生产无回显时不依赖)、reset 清倒计时与提交记忆;以及 `details.reason` 四个 reason →
> 中文提示、四个提示互不相同、命中 reason 优先于错误码、未命中回落错误码文案、
> **错误体秒数字段名 `details.retryAfterSec`**(用错 `retryAfter` 时取不到秒数 → 回落 60s 兜底)、
> details 缺失 / 非对象 / 字符串秒数 / 负数 / 小数都不抛异常)。
>
> 第五轮新增三组 31 条用例(总数 85 → 116,只增不减):
> `Session.test.ets`(会话往返 / 游客标记 / displayName / 过期语义 / clear 只清会话 /
> 损坏会话降级 / 无 userId 视为未登录 / **目录名清洗与防穿越** / 两个账号目录必不相同)、
> `PressGesture.test.ets`(**400ms 阈值**精确到毫秒、**6px 位移**判点击、长按后未移动仍算点击、
> 取消不提交、落点下标换算与夹边、位置未变不写库)、
> `RefreshState.test.ets`(同步中连续旋转 + 禁用、成功 1.4s 回落、失败常驻 danger、
> 重试回同步中、启动初始 idle 不冒充成功)。
>
> 第三轮新增:`RowModel.test.ets`(行序列等价性 / 行键稳定性 / 差量分类 / 拖拽开关)、
> `ReorderMath.test.ets`(容器键 / 落点 / 跨容器拒绝)。`view/list/RowDataSource.ets` 用到 ArkUI 的
> `IDataSource`/`DataChangeListener` 声明,不进这个宿主;它的**通知时序**由 `_qa/row-perf-harness.mjs`
> 直接执行真实实现来验证(§7.3)。

定位说明:**这是本机快速回归,不替代设备上的权威 Hypium 测试**。
垫片只覆盖用例实际用到的 API;`RelationalStore`(RDB 真机存储)与 WebSocket 相关路径不在覆盖范围内。

#### 3.4.2 测试代码的编译验证

```powershell
& "$deveco\tools\node\node.exe" "$deveco\tools\hvigor\bin\hvigorw.js" `
  --mode module -p module=entry@ohosTest -p product=default assembleHap --no-daemon
# 实测(第六轮 · 2026-10-10,含 testrunner 与验证码用例):BUILD SUCCESSFUL,ArkTS WARN 0 / ERROR 0
# 产物:entry/build/default/outputs/ohosTest/entry-ohosTest-unsigned.hap
```

#### 3.4.3 模拟器上跑权威 Hypium(**已实测 135/135 · v1.4**)

设备:`emulator 7.0.0.107(SP8DEVC00E999R4P11)`,API 26(x86_64),`hdc list targets` = `127.0.0.1:5555 Connected`。

```bash
# 1) 装两个 HAP(模拟器接受 unsigned,见 §3.3)
hdc install entry/build/default/outputs/default/entry-default-unsigned.hap
hdc install entry/build/default/outputs/ohosTest/entry-ohosTest-unsigned.hap
# 2) 命令行跑全部用例(TestRunner 会拉起 TestAbility → Hypium.hypiumTest(testsuite))
hdc shell aa test -b com.ordo.app -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 300000
```

实测输出(第六轮 · 2026-10-10,`_qa/ohostest-device-r7-final.log`):

```
OHOS_REPORT_RESULT: stream=Tests run: 135, Failure: 0, Error: 0, Pass: 135, Ignore: 0   （v1.4:133 宿主用例 + 2 设备端真库用例）
（第六轮 v1.3 时为 136;v1.4 移除验证码登录 18 条、新增静默会话 9 条）
OHOS_REPORT_CODE: 0
TestFinished-ResultCode: 0
TestFinished-ResultMsg: your test finished!!!
```

> **判定要看 `OHOS_REPORT_RESULT` 这一行,不能只看 `TestFinished-ResultCode`**:
> 用例体内抛异常时它计入 `Error`,而 `ResultCode` 仍是 0(第六轮踩过:2 条 Error 却报 0)。
> 本端把"Failure 0 且 Error 0"作为设备端判据。

也可以只用 DevEco 面板:右键 `entry/src/ohosTest` → **Run 'OhosTest'**。
用例清单(`entry/src/ohosTest/ets/test/`,共十一组):`NaturalDateParser.test.ets`(中文 NLP)、
`ListQuery.test.ets`(派生清单)、`RepeatEngine.test.ets`(重复引擎与月末溢出)、
`SyncMerge.test.ets`(§7.3 合并规则)、`RowModel.test.ets`(行序列与差量)、
`ReorderMath.test.ets`(拖拽排序数学)、`Session.test.ets`(契约 §7.6 会话/游客/目录名)、
`PressGesture.test.ets`(04 §5.2/§5.4 长按阈值与拖拽判定)、
`RefreshState.test.ets`(04 §5.3 刷新控件状态机)、
`EmailCodeState.test.ets`(契约 §7.6.5 验证码倒计时 / 自动提交 / reason 文案)、
**`RelationalStore.test.ets`(真 SQLite 写盘:含保留字列名的行能否读回 —— 见 §7.6)**。

> **`RelationalStore.test.ets` 只能在设备上跑**:它刻意用真 `RdbOrdoStore` + SQLite(宿主跑的是
> `MemoryOrdoStore`),所以不在 `_qa` 宿主里;它抓的是"宿主全绿、设备全挂"这一类缺陷(§7.6)。
> 上下文从 `TestAbility` 经 `TestContext.ability` 传给用例:`relationalStore.getRdbStore()`
> 只接受 **UIAbility 上下文**,`abilityDelegator.getAppContext()` 会报 `Illegal context`。
>
> **命令行跑测试需要 `testrunner/OpenHarmonyTestRunner.ets`**(第六轮补):`aa test` 把
> `-s unittest OpenHarmonyTestRunner` 解析成 HAP 内的 `ets/testrunner/OpenHarmonyTestRunner.abc`
> 作为应用入口点,缺了它会以 `Cannot find module ...` 崩掉(`TestFinished-ResultCode: -1` / `App died`);
> DevEco 面板走 TestAbility,不经过它。这也是首次真机跑测试暴露出的工程缺口。
>
> **真机跑测试与宿主的一个环境差异**:宿主把时钟冻结在 2026-10-08(`_qa/node-harness/src/freeze-clock.ts`),
> 而设备上是真实日期。任何把期望日期写死的用例都只在"今天恰好是那天"时通过 ——
> 第六轮真机首跑就抓到一条(`SyncMerge.test.ets` 的
> `invariants_reminder_moves_inbox_to_today_and_aligns_date` 期望 `2026-10-08T18:00`,
> 而引擎按契约把 reminder 日期平移到真实今天),已改为用 `todayISO()` 现算期望值。
> 写新用例时请照此办理:**不要写死日期**。

#### 3.4.4 模拟器 ↔ 真实后端的端到端取证(第六轮 task-7,**对应 v1.3 的验证码登录,该功能已在 v1.4 移除**)

后端:`http://10.189.58.216:8788`(开发模式 `ORDO_MAIL_TRANSPORT=console` + `ORDO_DEV_ECHO_CODE=1`,
真实 PostgreSQL)。驱动方式:`hdc` + `uitest dumpLayout/uiInput` + `snapshot_display`,
脚本 `_qa/hdc-ui.ps1`(按 id/文本定位、点击、输入、截图),日志 `_qa/e2e-r6.log`。

已取证的链路(截图在 `_qa/`):

| 步骤 | 结果 | 证据 |
|---|---|---|
| 登录页「服务器设置」改址并保存 | 页脚 host 变为 `10.189.58.216:8788` | `e2e-r6.log`;`e2e-02-code-countdown.jpeg` |
| 点「获取验证码」 | 服务端 202,`devCode` **自动填入** `ordo_login_code`(开发模式) | `e2e-r6.log`(`bounds ordo_login_code … text="460839"`) |
| 满 6 位自动提交 | 进入主界面;种子数据落盘、状态栏「RelationalStore(已持久化)」「已同步」 | `e2e-05-main-ui.jpeg`、`e2e-07-cold-start.jpeg` |
| 设置页账号/目录取证 | 账号 = 该邮箱;**正式账号**(非游客);数据目录名 = userId `afa8672f-…`;服务器地址 = 8788 | `e2e-06-settings.jpeg` + 文本断言 |
| 口令登录同一邮箱(无口令账号) | 被拒:`AUTH_INVALID_CREDENTIALS` → 文案「邮箱或密码不正确」 | `e2e-08-password-rejected.jpeg` |
| 错码 | `details.reason = code_invalid` → 文案「验证码不正确,请重新输入」 | `e2e-09-code-invalid.jpeg` |
| 同一错码反复提交 | `details.reason = code_attempts_exceeded` → 文案「验证码错误次数过多已作废,请重新获取」 | `e2e-r6.log`(第 3 次提交后) |
| 限流(宿主机先占用 60s 窗口,再由应用请求) | 服务端 JSON:`{"error":{"code":"RATE_LIMITED","message":"发送过于频繁,请稍后再试","details":{"reason":"code_throttled","retryAfterSec":60}}}` | `curl` 原文见 §7.6 |
| 冷启动(有会话) | 直接进主界面(§7.6.4 分支 1) | `e2e-07-cold-start.jpeg` |

> **没做完的一段**:429 在**界面里**的文案与 60s 倒计时置灰,没能截到图 ——
> 这台模拟器约 10 分钟崩一次(第六轮崩了 4 次),最后一次 `hdc` 直接 wedge。
> 服务端响应体与 `retryAfterSec:60` 有 curl 原文,客户端映射与倒计时状态机有
> `EmailCodeState.test.ets` 的 18 条用例覆盖,**缺的是那一张 UI 截图**。补齐方式:
> 模拟器稳定时重复上表最后两行的组合(先宿主机占窗口,再应用点「获取验证码」)。

### 3.5 真机 / 模拟器运行

1. **打开工程**:DevEco Studio → `File > Open` → 选择 `ordo/apps/harmony`(注意是这一层,不是仓库根)。
2. **同步依赖**:首次打开会自动 `hvigor` 同步;若提示缺少 `@ohos/hypium`,执行
   `File > Sync and Refresh Project`。
3. **配置签名**:见 §3.3。
4. **构建**:`Build > Build Hap(s)/APP(s) > Build Hap(s)`,产物在 `entry/build/default/outputs/default/`。
5. **运行**:选中 `entry` 模块 → `Run 'entry'`;
   或纯命令行(**模拟器无需签名**,第六轮实测):
   ```bash
   hdc list targets                                     # 期望 127.0.0.1:5555 Connected
   hdc install entry/build/default/outputs/default/entry-default-unsigned.hap
   hdc shell aa force-stop com.ordo.app
   hdc shell aa start -a EntryAbility -b com.ordo.app
   hdc shell snapshot_display -f /data/local/tmp/ordo.jpeg   # 截图取证
   hdc file recv /data/local/tmp/ordo.jpeg _qa/ordo.jpeg
   ```
6. **UI 取证与自动化点击**(第六轮用它验证登录页):
   ```bash
   hdc shell uitest dumpLayout -p /data/local/tmp/layout.json   # 按 .id() 取控件 bounds
   hdc shell uitest uiInput click <x> <y>
   ```
   第六轮实测(1320×2232 屏,`_qa/ordo-login-*.jpeg`):口令模式 / 验证码模式 / 空邮箱点
   「获取验证码」→ 错误区显示「! 请输入有效的邮箱地址」三张截图;
   `ordo_login_get_code` 的 bounds 为 `[902,1069][1170,1201]` = 268×132 px(3 倍密度下正好 44vp,满足 §8)。
7. **深链自测**(可选):
   ```bash
   hdc shell aa start -a EntryAbility -b com.ordo.app -U "ordo://today"
   hdc shell aa start -a EntryAbility -b com.ordo.app -U "ordo://project/<项目id>"
   hdc shell aa start -a EntryAbility -b com.ordo.app -U "ordo://add?title=%E4%B9%B0%E7%89%9B%E5%A5%B6"
   ```

## 4. 契约条款 → ArkTS 文件对照表

| 契约条款 | 内容 | ArkTS 实现 |
|---|---|---|
| §2.1 Area | 区域实体 | `core/model/Entities.ets` · `Area` |
| §2.2 Project | 项目实体 + 完成硬约束 | `Entities.ets` · `Project` / `OrdoEngine.canCompleteProject` |
| §2.3 Heading | 标题实体 + `collapsed` 本地态 | `Entities.ets` · `Heading` / `applyRemoteHeading`(保留本地 collapsed) |
| §2.4 Todo | 待办实体 | `Entities.ets` · `Todo` |
| §2.5 ChecklistItem | 内嵌清单项(≤100) | `Entities.ets` · `ChecklistItem` / `OrdoEngine.addChecklistItem` |
| §2.6 Tag | 标签实体 | `Entities.ets` · `Tag` |
| §2.7 RepeatRule | 重复规则 | `Entities.ets` · `RepeatRule` |
| §2.8 CalendarEvent | 只读日历事件(不同步) | `Entities.ets` · `CalendarEvent` / `AppStore.localEvents` |
| §3 默认值与不变量 | 7 条规则 | `OrdoEngine.normalizeTodo` / `createTodo` / `moveTodo` / `setReminder` |
| §4 收件箱 | `open && when==inbox` | `ListQuery.inbox` |
| §4 今天 | 三条并集 + 今晚分区 + 逾期标记 | `ListQuery.today` / `tonight` / `isInToday` / `isOverdue` |
| §4 计划 | 明天起 14 天 + 重复下一次 + 「更晚」 | `ListQuery.upcoming` / `upcomingWindow` / `UPCOMING_WINDOW_DAYS` |
| §4 随时 / 某天 | `when==anytime` / `when==someday` | `ListQuery.anytime` / `someday` |
| §4 日志簿 | 按 completedAt 倒序分组 | `ListQuery.logbook` |
| §4 项目视图 | heading.order 分组,无标题最后 | `ListQuery.projectGroups` |
| §4 区域视图 | `t.areaId==A \|\| project.areaId==A` | `ListQuery.areaTodos` |
| §4 标签视图 | `tags.contains` + 只看未完成 | `ListQuery.tagTodos` |
| §4 搜索 | 标题/备注包含,未完成优先 + updatedAt 倒序 | `ListQuery.search` / `sortForSearch` |
| §4 项目进度 | `done/(done+open)`,无子项 0 | `ListQuery.projectProgress` |
| §2.4 `order` / 04 §6 拖拽排序 | 同容器完整序列整批重写 `order = 下标` | `OrdoEngine.reorderTodos(ids)` / `viewmodel/PressGesture.ets`(落点下标与半行取整)/ `RowModel.diffRows`(行级差量) |
| §3 软删除的可撤销 | `deleted` 复位为 `false` + LWW 时间戳前移 | `OrdoEngine.restoreDeletedTodo(id)` / `AppStore.deleteTodoWithUndo` + `undoDelete()` |
| §5 NLP | 全部写法 + 优先级 + 时段换算 + 标题清理 | `core/nlp/NaturalDateParser.ets` · `parseNatural` |
| §6 重复引擎 | fixed/afterCompletion + 月末溢出 | `core/repeat/RepeatEngine.ets` · `completeWithRepeat` / `advanceOccurrence` |
| §7.1 本地优先 | outbox + serverSeq | `OrdoEngine.pushOp` / `takePendingOps` / `confirmPushed` / `setLastServerSeq` |
| §7.2 Op 结构 | opId(ULID)/ entity / type / payload / clientTs | `Entities.ets` · `Op` / `core/util/Ids.ets` · `newOpId` |
| §7.3.1 实体级 LWW | clientTs vs updatedAt | `OrdoEngine.applyRemoteTodo` 等 5 个 `applyRemoteX` |
| §7.3.2 完成不可回滚 | 忽略更早的 open | `applyRemoteTodo`(规则 2 分支) |
| §7.3.3 标签并集 | 即使 stale 也并 | `OrdoEngine.unionTags` / `mergeTagsAndChecklist` |
| §7.3.4 清单项合并 | 按 id 合并 | `OrdoEngine.mergeChecklist` |
| §7.3.5 删除墓碑 | 30 天 TTL | `OrdoEngine.recordTombstone` / `findTombstone` / `pruneTombstones` |
| §7.3.6 空标题视为删除 | — | `applyRemoteTodo`(规则 6) / `setTodoTitle` |
| §7.4 HTTP 接口 | 12 个端点 + 请求头 + 401 重放 | `core/sync/SyncApi.ets`(health/register/login/guest/upgrade/**email-code/email-login**/refresh/logout/snapshot/push/pull) |
| §7.4 限制与错误码 | ≤500 ops / ≤256KB / ≤1000 pull;10 个错误码 | `Entities.ets` 常量 + `SyncTypes.errorText` + `SyncApi.push` 超限处理 |
| §7.6.1 会话模型 | `userId/email?/isGuest/accessToken/refreshToken/expiresAt` | `core/session/OrdoSession.ets` · `OrdoSession` / `OrdoSessionHelper.isExpired` / `displayName` |
| §7.6.1 会话存储 | `kv["ordo.session"]` | `OrdoSessionStore`(`KEY_SESSION = 'ordo.session'`),落在**应用级**库(`ordo-meta.db`) |
| §7.6.2 `POST /v1/auth/guest` | `{deviceId?,deviceName,platform}` → 与 register 同构 | `SyncApi.guest()`;`UserDto.isGuest` → `AuthUser.isGuest` |
| §7.6.2 `POST /v1/auth/upgrade` | 需带 Access Token,userId/数据不变 | `SyncApi.upgrade()` + `AppStore.upgradeGuest()` + 设置页「升级为正式账号」 |
| §7.6.2 游客调 login 的引导 | `AUTH_INVALID_CREDENTIALS`(无口令可校验) | `SyncTypes.ERR_AUTH_GUEST_NEEDS_RESTORE` + `errorText()` 引导用「以游客身份继续」 |
| §7.6.3 按 userId 隔离(**硬约束**) | 每账号一份目录、退出登录只清会话 | `OrdoSessionHelper.userDataDirName()` + `RdbOrdoStore(context, dirName, metaOnly)`(RDB `customDir`) |
| §7.6.4 启动流程 | 读会话 → 有/无/过期三分支 | `AppStore.init()` → `enterSession()` / `authPhase` → `pages/Index.ets` 门禁 |
| §7.6.5 `POST /v1/auth/email/code` | `{email}` → 202 `{sent,expiresIn:300,retryAfter:60}` | `SyncApi.requestEmailCode()` + `EmailCodeMachine.applySent()`(倒计时取响应 `retryAfter`) |
| §7.6.5 `POST /v1/auth/email/login` | `{email,code,deviceId?,deviceName,platform}` → 与 register **同构**(未注册邮箱自动建号) | `SyncApi.emailLogin()` → `parseAuth()` → `AppStore.emailCodeLogin()` → `adoptSession()`(同一 userId / 同一份数据) |
| §7.6.5 验证码错误 reason | 不新增错误码,`details.reason` 细化提示 | `SyncTypes.reasonText/errorTextWithReason` + `parseErrorDetails()`(`reason` + `retryAfterSec`) |
| §8 存储 | 8 张表 + 字段名一致 + kv | `core/storage/RelationalStore.ets`(建表 SQL 与字段映射) |
| §7.5 WebSocket | hello/ops/reminder/ping + ack + pong | `core/sync/RealtimeClient.ets` · `dispatch` |
| §7.5 心跳与退避 | 心跳 25s / 超时 10s / 指数退避 | `SyncTypes.RealtimePolicy` + `RealtimeClient.startHeartbeat/scheduleReconnect` |
| §7.5 Fastlane | reminder 即时下发 | `SyncEngine.handleRealtimeReminder` → `AppStore.onFastlaneReminder` → `ReminderAgent.refresh` |
| §8 存储 | 8 张表 + 字段名一致 + kv | `core/storage/RelationalStore.ets`(建表 SQL 与字段映射) |
| §9 安全 | 不打印令牌/口令/备注 | `SyncApi`(无 token 日志)、`EntryAbility`(只打印 scheme+path)、`OrdoEngine`(日志不含正文) |

## 5. UI 映射(04 号文档)

| 04 条款 | 实现 |
|---|---|
| §1 品牌(序 / Ordo / 开口圆环 + 短划线) | `_qa/make_icon.py` 生成 `app_icon.png`;空状态插图复用同一图形 |
| §2.1 色彩令牌(浅/深) | `theme/Tokens.ets` · `OrdoColors.of(dark)`;同步一份到 `resources/{base,dark}/element/color.json` |
| §2.2 排版令牌 | `OrdoFont.display/title/body/caption/micro` |
| §2.3 间距/圆角/阴影/动效 | `OrdoSpace` / `OrdoRadius` / `OrdoShadow` / `OrdoMotion`(含完成动效 7 个时间点) |
| §3 布局(侧栏 248 + 内容 720 + 状态栏 + 快加号) | `view/Sidebar.ets` / `ListPage.ets` / `OrdoSize` |
| §4 组件(侧栏项 34 / 待办行 38 / 复选框 20 / chip 20 / 空状态 / Toast) | `Sidebar` / `view/list/TodoRow.ets` / `Common/{ProgressRing,EmptyState,OrdoToast}` |
| §4 排期面板(宽 280) | `view/ScheduleSheet.ets` |
| §4 快找浮层(输入 44 / 结果行 36) | `view/FastFindSheet.ets` |
| §4 提示条(底部居中 pill,2.4s) | `Common/OrdoToast.ets`;带「撤销」动作时停留 4s(见 §7.3 的删除可撤销) |
| §5 完成动效 | `view/list/TodoRow.ets`(透明度/动画)+ `OrdoMotion` 常量;`Common/ProgressRing` 100% 脉冲 |
| §5.1 登录页 ❌ **v1.4 已移除** | ~~`view/LoginPage.ets`~~(历史实现,文件已删除)(卡片 400 / 浮动标签 / 口令显示隐藏 / 提交转圈 / 错误抖动 / 进入动效 / 三个入口 / **口令登录 ↔ 验证码登录同级页签**) |
| §5.2 快加号集群 | `view/QuickAddButton.ets`(只保留 56 单按钮;单击开输入行、**长按 400ms** 出菜单、展开旋转 45°、面板 0.9→1 + 菜单项错位 40ms) |
| §5.2 菜单项图标(v1.3 对齐参照原型) | `viewmodel/FabMenu.ets`(图标**枚举** + 20×20 viewBox 几何 + 面板/条目尺寸,纯逻辑、有 8 条宿主用例)+ `view/QuickAddButton.ets#fabIcon()` 用 `Line` / `Rect` / `Circle` **矢量绘制**:待办 ＋(横 4→16@y10 + 竖 10@x 4→16,stroke 2.1)、项目 **H**(两竖 x5/x15 y4→16 + 横 y10,stroke 1.7)、区域 **圆角方框 rect(3,3,14,14) rx4 stroke 1.5 + 中心实心圆 r2.6**、标题 **≡**(y5/10/15,x4.5→15.5,stroke 1.7);**不再用字体字符**(上一轮 '→' 被字体回退渲染成别的形状);FAB 自己的白「+」也改成两条矢量线 |
| §5.3 刷新控件 | `view/Common/RefreshControl.ets` + `viewmodel/RefreshState.ets`(28dp 图标 + 文字;同步中连转 900ms/圈;成功 success `已同步` 1.4s;失败 danger `同步失败,点击重试`) |
| §5.4 长按拖拽 | `viewmodel/PressGesture.ets` + `ListPage` 的长按手势 + `RowModel.applyDragHint`(抬起 1.02 + 投影 + alpha 0.55、插入指示线 2dp + 4dp 圆点、其余行让位 120ms、取消路径) |
| §6 手势:右滑完成 / 左滑删除 + 排期 | `ListPage.todoItem` 的 `ListItem.swipeAction`:start = 完成(绿 `state.success`),end = 排期 + 删除(危险色 `state.danger`);删除后可撤销 |
| §6 手势:长按拖拽排序 | `ListItem.onTouch` → `PressTracker`(400ms / 6px)→ `moveIdToIndex` → `AppStore.reorderTodos(ids)` → `OrdoEngine.reorderTodos`(《04》§6「鸿蒙 = 长按拖拽」) |
| §6 键盘与手势(其余鸿蒙列) | 设置页列出映射;点击行展开、点击复选框完成、长按快加号出菜单 |
| §7 平台映射(RelationalStore / reminderAgentManager / ordo://) | `RelationalStore.ets` / `ReminderAgent.ets` / `module.json5` skills |
| §8 无障碍 | 所有可点元素 ≥44vp(`OrdoSize.minTouchTarget`)、滑动动作区宽 72vp、状态不只靠颜色(逾期同时有图标+红色;刷新失败同时有 `!` 文案与朗读文本) |

## 6. 静默匿名会话与按用户隔离(契约 §7.6)

> **v1.4 产品变更:不再需要登录。**鸿蒙端已整体移除登录界面与门禁 ——
> 删除 `view/LoginPage.ets`(含登录 / 注册 / 游客按钮 / 邮箱验证码两套页签 / 服务器设置面板)、
> `viewmodel/EmailCodeState.ets` 及其用例、`Index.ets` 的 `login` / `entering` 门禁分支、
> 设置页的「账号 / 账号标识 / 升级为正式账号 / 退出登录 / 服务器地址」区块,
> 以及 `SyncApi` 的 `register/login/upgrade/requestEmailCode/emailLogin/logout`。
> **云同步保留** —— 改成下面的"后台静默匿名会话"。

### 6.1 启动流程(§7.6.4 的产品化改造)

`AppStore.init()` 的顺序:**钉目录标识 → 读会话 → 决定走哪条路 → 无论如何都进主界面**。

```
打开应用级库 ordo-meta.db
  ├─ 钉住目录标识(契约 §7.6.6):kv["ordo.localAccountId"] 有则用;没有但有老会话 → 沿用其
  │   userDataDirName(userId)(升级路径,不迁移);都没有 → 生成 local-<16hex> 并写回 kv
  └─ 读 kv["ordo.session"] → 三条分支,**都不阻塞进主界面**:
      ├─ 无会话            → 立刻用目录标识开库进主界面;后台静默 POST /v1/auth/guest 建匿名账号
      │                        ├─ 建好 → 只接令牌(目录**不动**)→ 开始同步
      │                        └─ 失败 → 后台按 2s→4s→8s…上限 60s 退避重试(界面照常可用)
      ├─ 有会话且未过期     → 直接进主界面 + 后台静默 syncNow()
      └─ 有会话但 accessToken 过期 → 先进主界面,后台 refresh:
                                  ├─ 成功 → 补一次增量同步
                                  ├─ 网络不可达 → 留在主界面离线可用(会话与目录都不动)
                                  └─ 服务端拒绝(401) → **静默重建匿名会话**(不再回登录页)
```

- `authPhase` 只有 `booting | ready` 两态:`Index.ets` 未就绪时显示启动过场,`ready` 后主界面首帧透明、下一帧 220ms 淡入。
- **任何路径都不会出现登录界面**,也不会因为网络不可达而卡在启动过场 —— "不阻塞、不弹界面"是硬要求。
- 同步遇 `authRequired`(401)同样走"静默重建匿名会话":清会话与令牌、保留本地目录与数据、重新 `guest`。

### 6.1.1 目录标识 = 本机稳定账号标识(契约 §7.6.6)

**关键点:数据目录不跟服务端 `userId` 走。**没有登录界面之后,"离线首启 → 联网拿会话"与
"同步 401 → 静默重建匿名会话"都会拿到**新的**服务端 userId;目录若跟着它变,用户就会觉得数据丢了。

所以目录标识是**本机生成、持久化、永不随会话改变**的:

| 情形 | 目录标识 | 说明 |
|---|---|---|
| `kv["ordo.localAccountId"]` 已有值 | 直接用 | 钉住之后**任何**会话变化都不动它 |
| 没有该值,但有老会话(从 v1.3 升上来) | `userDataDirName(老会话.userId)` | **升级前已在用的目录继续沿用**,不做迁移;随后写回 kv 钉住 |
| 都没有(全新安装) | `local-<16hex>` | 由 `deviceId + 时间戳` 生成;随后写回 kv 钉住 |

- 判定/生成在 `viewmodel/SilentAuth.ets`:`planAccountDirId(storedId, legacyUserId)`、`newLocalAccountId(seed)`(FNV-1a → 16 hex,同 seed 同结果);
- 实际库仍是 `<databaseDir>/rdb/<目录标识>/ordo.db`(`RdbOrdoStore` 的 `customDir`),**隔离性不变**;
- 服务端不消费该字段;本轮**不做数据迁移**(老目录原样继续用)。
- 宿主用例覆盖:已钉住 → 不随会话变化、升级路径沿用、形态与稳定性(见 `SilentAuth.test.ets`)。

### 6.2 设置页(§5.1 已随登录移除而作废)

设置页保留:外观、数据与存储、本地数据(数据目录 / 库文件 / 同步会话状态)、同步、示例数据、快捷键与手势。
已删除:账号、账号标识、升级为正式账号、退出登录、服务器地址输入框。

### 6.3 按 userId 隔离(§7.6.3 硬约束)

| 项 | 做法 |
|---|---|
| 目录名 | `OrdoSessionHelper.userDataDirName(userId)`:只保留 `[A-Za-z0-9_-]`,其余(含 `.` `/` `\` 空格)替换成 `_`;清洗后为空则退化为 `_`,**绝不返回空串**(空串 = 根目录 = 所有人共用) |
| 账号库 | `new RdbOrdoStore(context, dirName, false)` → `<context.databaseDir>/rdb/<userId>/ordo.db`(RDB `customDir`) |
| 应用级库 | `new RdbOrdoStore(context, '', true)` → `ordo-meta.db`,只建 `kv` 一张表,存会话 / deviceId / baseUrl / 外观 |
| 令牌 | 存**账号库**的 kv(`accessToken`/`refreshToken`),与实体同目录;会话本身存应用级库 |
| 演示数据 | 先 `resyncSnapshot()` 再判断:引擎仍为空才 `persistAll(seed)` 并写 `kv["ordo.seeded"]=1`;**拉不到服务端就不写**,等下次判定(§7.6.3「首次登录且服务端无数据时才写」) |
| 退出登录 | `AppStore.logout()`:服务端 logout → 清账号库令牌 → 清应用级会话 → 停 WS + `ReminderAgent.cancelAll()`;**目录与实体一律保留** |
| 可见性 | 设置页显示账号(游客带「游客」chip)、`userId`、**数据目录名**与**库文件绝对路径** —— 便于当场核对"两个账号没有共用目录" |

> **平台差异(需要在契约里注一句)**:契约 §7.6.3 写的是「鸿蒙 `filesDir/<userId>/`」,
> 而鸿蒙的 ArkData 只允许关系库落在应用沙箱的 `databaseDir` 下(`StoreConfig.customDir` 的语义就是
> `<databaseDir>/rdb/<customDir>/<name>`)。落地为 `<databaseDir>/rdb/<userId>/ordo.db`:
> 同样是**应用私有、按 userId 一份、退出登录不删、两个账号绝不可共用**,
> 差别只是沙箱内那一级父目录由系统指定而不是 `filesDir`。

### 6.4 登录页交互细节(§5.1)

| 规范 | 实现 |
|---|---|
| 卡片 400 宽、radius 16、12dp 投影、画布 + ≤6% 品牌渐变光晕 | `LoginGate` 根容器 `.width(400)` + `linearGradient('#0F5B5BD6' → '#005B5BD6')` |
| 浮动标签:聚焦时上移 12px 并转 accent | 标签 `translate(y: 8/18)` + 11/15 号字 + `border` 转 `accent`(120ms) |
| 口令显示 / 隐藏 | 右侧 44×44 按钮切换 `InputType.Password ↔ Normal`,`showPasswordIcon(false)` 关掉系统自带的眼睛 |
| 提交中禁用 + 16dp 转圈 | `LoadingProgress(16)` 在按钮内;`loginBusy` 期间输入框、主按钮、游客按钮全部禁用 |
| 错误区固定预留 20 高 + 抖动 | `.height(20)` 恒定;失败时 `keyframeAnimateTo` 播放 6/-6/3/-3/0(每段 64ms = 320ms) |
| 触控目标 ≥44、错误不只靠颜色 | 底部链接高 44;错误同时给 `!` 字形与文案 |
| 登录方式同级切换(§7.6.5) | 品牌区下方「口令登录 / 验证码登录」两个等宽页签(各高 44;选中 accent 文字 + 2px 指示条,未选中 `textTertiary`),切换时清错误区不动已填邮箱 |
| 验证码框 | 与口令框同一基线(Stack `Alignment.TopStart` + 固定基线浮动标签 + 画布底 + 发丝描边);`InputType.Number` + `maxLength(6)` + `normalizeCode()`;右侧「获取验证码」点击区 44,倒计时期间文字转 `textTertiary` 且 `enabled(false)` |

### 6.5 AppStore 对外成员(v1.4)

- 状态:`authPhase`(`booting|ready`)/ `session` / `userDir` / `baseUrl` / `silent`(`SilentAuthMachine`)/
  `dragActive` / `dragCancelSeq`
- 方法(会话):`userDirText()` / `dataPathText()` / `serverText()` / `sessionStateText()` / `hasCloudSession()` /
  `setBaseUrl(url)`(隐藏覆盖,见 §6.6)
- 方法(其余):`requestDragCancel()` / `tapRefresh()` / `refreshLabel()` / `refreshTone()` / `refreshSpinning()` /
  `refreshEnabled()` / `refreshA11y()`
- 私有(静默会话):`enterSession()` / `wireSync()` / `tryCreateAnonymousSession()` / `onAnonymousArrived()` /
  `bindTokens()` / `onAnonymousFailed()` / `scheduleAnonymousRetry()` / `silentRebuildAnonymous()` /
  `refreshSessionQuietly()` / `persistRefreshedTokens()` / `provisionalSession()` / `activeDirFor()`

> 演示数据规则(§7.6.3):**先拉服务端快照、确认服务端为空**才写;**离线首启没有令牌**时直接写本地
> (否则首启是个空应用),等匿名会话建好后作为普通本地 op 推上去。

### 6.6 服务器地址:隐藏覆盖(界面无输入框)

v1.4 起设置页不再有「服务器地址」输入框。地址仍从**应用级 kv** 读,优先级:

1. `ordo-meta.db` 的 `kv['baseUrl']`(**覆盖值**;启动时读一次,缺省/空串时回落到 2);
2. 代码里的 `AppStore.DEFAULT_BASE_URL`(默认 `https://api.ordo.app`)。

改法(任选一种):

- **调试入口**:在任意能拿到 `AppStore` 的地方调 `store.setBaseUrl('http://10.189.58.216:8788')` ——
  它会校验 `http(s)://` 形态、写 kv、热切换 `SyncApi` 与实时通道地址并触发一次同步探活(见 `AppStore.setBaseUrl`)。
- **直接改 kv**:应用级库路径可在「设置 → 本地数据 → 库文件」看到(`<databaseDir>/rdb/ordo-meta.db`),
  用 DevEco 的 Device File Browser 取出 → 改 `kv` 表的 `baseUrl` → 放回并重启应用。

两条路都不需要重新打包;生产默认值仍然是 `https://api.ordo.app`。
## 7. 性能优化:写放大与局部刷新

### 7.0 设备端才暴露的两个缺陷(第六轮 task-7,均由模拟器真机验证抓出)

> 共同特征:**宿主全绿、设备全挂**。`_qa` 宿主跑 `MemoryOrdoStore`(纯 JS),设备跑 `RdbOrdoStore`(真 SQLite);
> 冷启动阶段切换则完全没有宿主覆盖。两条都已修 + 加了回归闸门。

#### 7.0.1 `order` / `when` 是 SQL 保留字 → 设备端无法写盘(严重)

**症状**:验证码登录**服务端已成功**(202 拿到 devCode、200 建号成功、WS 已 `101 Switching Protocols`),
但界面报「无法连接服务器」并停在登录页;重启后卡在「序」启动页。

**证据**(`_qa/device-hilog-boot.log`):

```
E C01650/Config: Log:Error(1) errno is:25 near "order": syntax error in
  "INSERT OR REPLACE INTO areas(archived,color,deleted,id,name,order,updatedAt) VALUES (?,?,?,?,?,?,?)".
E C01650/SqliteStatement: PrintInfoForDbError:DbError errCode:27394103 errno:25
```

**根因**:建表 DDL 与 SELECT 列清单都给 `"order"` / `"when"` 加了双引号,唯独
`store.insert(table, ValuesBucket, conflict)` 这条写路径由 SDK 自己拼 SQL、列名原样输出,
`order` 直接触发 SQLite 语法错误。于是 `persistAll(seed)` / 本地新建 / 同步落地**在设备上全部失败**
(`enterSession` 抛异常 → `authPhase` 停在 `login`/`booting`)。

**修法**(方案 A,不改契约列名):`RelationalStore.insertRow()` 改为手写
`INSERT OR REPLACE INTO <table>("col1",…,"order") VALUES(?,…)` + `executeSql(sql, bindArgs)`,
**每个标识符统一加双引号**;`areas/projects/headings/todos/tags/outbox/tombstones/kv` 八处写入共用它
(ConflictResolution 映射成 `INSERT OR REPLACE` / `INSERT OR IGNORE`)。

**回归闸门**:`entry/src/ohosTest/ets/test/RelationalStore.test.ets`(设备端真库)。
红/绿实测:

```
去掉引号(复现修复前):Tests run: 136, Failure: 0, Error: 1, Pass: 135
                        Error in reserved_word_columns_roundtrip_on_real_sqlite,
                        [RdbOrdoStore] 保存区域失败:SQLite: Generic error...
恢复引号(修复后)    :Tests run: 136, Failure: 0, Error: 0, Pass: 136
```

#### 7.0.2 冷启动恢复会话时 `authPhase` 永远停在 `booting`(白屏)

**症状**:有缓存的会话时冷启动,应用一直停在「序」启动页(日志显示 RDB 无错、WS 已连上,即 `enterSession` 已跑完)。

**根因**:`AppStore.init()` 读会话后走 `enterSession(session, true)`,但**没有任何地方把 `authPhase`
从 `booting` 切到 `ready`**(`entering → ready` 只属于"从登录页登录成功"这条路径),
于是 `pages/Index.ets` 永远渲染启动页 —— 违反契约 §7.6.4「有且未过期 → 直接进入主界面」。

**修法**:`init()` 里 `await enterSession(...)` 之后,若阶段仍是 `booting` 就 `setAuthPhase('ready')`
(冷启动没有登录页,不需要 160ms 淡出);并把 `enterSession` 的异常兜成回登录页,避免再次白屏。

**证据**:修复前 `e2e-state.jpeg`(卡在「序」);修复后 `e2e-07-cold-start.jpeg`(直接进主界面)。

### 7.1 本地库写盘:从「清表 + 全量重写」到「增量 upsert」(`core/storage/RelationalStore.ets`)

| | 改前 | 改后 |
|---|---|---|
| 入口 | `OrdoEngine.persistAll` → `store.clearEntities()` + 逐条 `saveX()` | `OrdoEngine.persistAll` → `store.saveSnapshot(snapshot)` |
| 写操作 | 5 张表各一次 `DELETE FROM`,再对**每个实体**发一条 `INSERT ... ON CONFLICT REPLACE` | 先按主键 `IN (...)` **一条语句**删掉快照中已不存在的 id,再只对**新增或有变化**的实体发 upsert |
| 写放大 | O(全部实体);1000 条待办 = 1000 次 INSERT + 5 次全表 DELETE | O(变化实体);稳态下 = 0 次写 |
| 事务 | 无(中途失败会留下「已清空但没写回」的空库) | 整个对账包在 `beginTransaction/commit` 内,失败 `rollBack` 后上抛 |
| 变化检测 | 无(无条件重写) | `JSON.stringify(旧) !== JSON.stringify(新)` |
| 内存实现 | 逐条覆盖 | `MemoryOrdoStore.saveSnapshot()` 同语义实现,保证两端可互换 |

`clearEntities()` 仍保留在 `OrdoStore` 接口中(退出登录/未来清库用),但 `persistAll` 已不再走它。
新增接口只有 `saveSnapshot(snapshot: StorageSnapshot)` 一个,`StorageSnapshot` 定义在
`core/storage/OrdoStore.ets`(`areas` / `projects` / `headings` / `todos` / `tags`)。

### 7.2 UI 派生结果:从「每次渲染重算」到「按版本号缓存」

**问题**:`AppStore` 的派生查询(`currentTodos()` / `counts()` / `todaySections()` / `upcomingGroups()` /
`logbookGroups()` / `tagCountMap()`)被多个组件在**同一次渲染**里各调一次——
`ListPage` 调 `currentTodos()`,`Sidebar` 调 `counts()` × 6 + `tagCountMap()` + `todos()` × 2N,
`headerSubtitle()` 又调 `todaySections()`。每次调用都重新遍历 + 排序 + 过滤全部待办,
1000 条待办时单次重渲染是**十几次 O(n log n) 全量重算**。

| | 改前 | 改后 |
|---|---|---|
| 调用代价 | 每次都 `filter`/`sort` 全量待办 | 版本号未变时**直接返回上次结果**(O(1)) |
| 失效方式 | — | `invalidateDerived()` 只 `deriveRev + 1`(标脏,不立即重算) |
| 重建时点 | — | 下一次读取时惰性重建,一次渲染只付一次重建成本 |
| 失效触发点 | — | 引擎 emit(任何落库)、`afterWrite()`、导航切换(`goList/goProject/goArea/goTag/goSearch`)、`resetToSeedData`、登录成功 |
| 跨天 | 每次现算 `todayISO()` | `cacheToday` 记录计算日,跨天自动整体失效 |
| 当前清单键 | — | `currentTodos()` 另有 `list\|projectId\|areaId\|tagName\|keyword\|showCompleted` 键,键变即重算 |

> 仍然是「整表重建 + 整表重渲染」的粗粒度模型(彻底改成按行增量需要引入
> `@Observed` 的实体级观察或 `LazyForEach` + 数据源,属于后续迭代);
> 本轮消除的是**同一次渲染内的重复计算**与**每次全量重写磁盘**这两个真正的放大点。
> `OrdoEngine.todos()` 返回的是引擎持有的数组本身(不复制),因此缓存不会额外占用内存。
>
> **上一轮遗留的"整表重渲染"已在本轮消除,见 §7.3。**

### 7.3 列表渲染:从「整表重建」到「行级增量刷新」(`view/list/*`)

**问题**:改前 `ListPage` 是 `Scroll + Column + ForEach`,把 `currentTodos()/todaySections()` 直接铺成行:

- `ForEach` **不是懒加载**:首帧把 1000 行全部建成组件树,`Scroll` 还要把它们全部测量/布局;
- ArkUI 文档:*ForEach 非首次渲染时会逐项比较键值* —— 也就是说每次状态变化,框架都要**遍历全部 N 项**才能判断谁变;
- 行与分组标题同属一个 `@Component` 的 build 产物,没有"某一行变了"这个粒度。

**改法**(三个文件,全部在本端 `view/` 层,不碰契约核心):

| 文件 | 职责 |
|---|---|
| `view/list/RowModel.ets` | 数据 → **行序列**(顺序与改前逐行等价)+ 行指纹 `rev` + 行级差量 `diffRows()` |
| `view/list/RowDataSource.ets` | `IDataSource` 实现;按清单键缓存行序列;把差量翻译成 `onDataReloaded/Add/Delete/Move` |
| `view/list/TodoRow.ets` | 待办行独立成组件,由 `@Prop rowRev`(行指纹)驱动重渲染 |

三条**框架硬约束**决定了上面的形状(均出自 ArkUI 官方文档《LazyForEach:数据懒加载》):

1. *"If the first parameter dataSource is re-assigned a value, an exception occurs."*
   → 数据源实例在整个页面生命周期内**只创建一次**,切换清单由 `RowDataSource.sync(清单键, 行序列)` 内部换序列;
2. *"If the key does not change, LazyForEach cannot trigger a re-render."*
   → 行键取 `id@rev`(身份 + 内容指纹):内容变了键才变,`onDataReloaded` 于是**只重建键变了的那几行**,同键的行复用缓存组件;
3. *"Before onDataDelete is called, ensure that the corresponding data has been deleted."*
   → 每条通知都先改自己的数组、再通知;`apply()` 收尾还会逐位比对键,任何记账偏差直接退化为整表 reload。

**改前 / 改后对比**(1000 条待办;数字来自 `_qa/row-perf-harness.mjs`,它把仓库里真实的
`RowModel` / `RowDataSource` 复制到临时目录用 Node 类型擦除**直接执行**,不是估算):

| 指标 | 改前(ForEach + Scroll/Column) | 改后(LazyForEach + RowDataSource) |
|---|---|---|
| 每次状态变化的条目处理量 | 逐项比较键值 **1001 次**(文档口径) | 框架不做全量键比较(**0 次**);只处理收到通知的下标 |
| 首帧创建的行组件数 | **1001 个**(无虚拟化,滚动区外也要建+布局) | **可见区 + cachedCount** 个(800vp 视口 / 46vp 行高 / cachedCount 6 → 24 个) |
| 改一行标题 | 整棵列表子树重算 | **1 次 `reload`,1 行重建**(视口外改动:视口内 0 行重建) |
| 收件箱新增一条 | 整表重算 | **1 次 `add`,0 行重建** |
| 收件箱删除一条 | 整表重算 | **1 次 `delete`,0 行重建** |
| 完成一条(今天,分组计数变) | 整表重算 | **1 次 `reload`,视口内 1 行重建**(行 + 分组标题最多 2 行) |
| 拖拽 1 行(位移 4 格) | — | **4 次 `move`(交换语义),0 行重建** |
| 拖拽 1 行(位移 > 64 格) | — | 退化为 **1 次 `reload`,≤ 已渲染行数** |
| 切换清单 | 整表重算 | **1 次 `reload`**(键值未变的行仍复用组件) |
| 单次行模型重算(1000 条) | — | **0.4 ms/次**(本机 Node 24 实测,20 次均值) |

完整逐场景表(12 个场景 + 每次通知条数 + 一致性校验)在 `_qa/row-perf-report.md`,
由 `node _qa/row-perf-harness.mjs` 生成;脚本结束时会断言"数据源内部行序列 == 行模型",
当前 **0 例不一致**。

**其它配套改动**:

- `AppStore.listKey()` 从私有 `currentKey()` 提升为公开:视图侧用它做数据源缓存键;
- `AppStore` 新增 `reorderTodos(ids)`(两道闸门:每条都能找到、全部同容器)、
  `deleteTodoWithUndo(id)` / `undoDelete()`(左滑删除的"可撤销"兜底);
- `OrdoEngine` 新增 `reorderTodos(ids)`(`ids[i].order = i`,与共享核心 `OrdoEngine.kt:293` 逐字同义)与
  `restoreDeletedTodo(id)`;`pages/Index.ets` 把 `store.changeSeq` 作为 `storeRev` 传给 `ListPage` 触发同步;
- 行高/圆角/令牌不变;`List` 关掉了边缘回弹(`edgeEffect(EdgeEffect.None)`)以贴近改前观感。

> **风险留痕**:手势(swipeAction / 拖拽)与真实滚动帧率**未在设备上验证**(本机无签名无设备)。
> 若真机上出现"行内容滞后",兜底是把 `rev` 折进行键后对该区间发 `onDataReload`(1 行代码,
> 见 `RowModel` 的键值口径注释);`MAX_SWAPS = 64` 的长距离拖拽回退策略亦可在 `RowModel.ets` 调整。

### 7.4 手势语义与另外三端的一致性

| 行为 | 本端实现 | 与其它端的关系 |
|---|---|---|
| 右滑 → 完成 | `swipeAction.start` = 绿色 `state.success` 动作区;`onAction`(滑过阈值松手)与按钮点击都走 `store.toggleDone` | iOS `ordoSwipeActions(leading: .complete)` 同义 |
| 左滑 → 删除 + 排期 | `swipeAction.end` = 排期 + 删除两个 72vp 动作区;删除走"软删除 + 提示条撤销"(04 §6 未规定二次确认,按可撤销实现) | iOS `trailing: .delete` 同义;撤销是本端补的兜底 |
| 长按拖拽 | `ListItem.onTouch` → `PressTracker`(400ms / 6px)→ `moveIdToIndex` → `reorderTodos(ids)` | 与 iOS 长按拖拽同形(先移除再插入);落点规则见下 |
| 提交的序列 | **同一容器内的完整可见序列**(界面顺序),核心按 `ids[i].order = i` 整批落库 | 与 iOS `AppEnvironment.reorderTodos(ids:)`、桌上端 `ReorderMath.applySectionOrder` 同一契约 |
| 容器 = | `(when, projectId, headingId)`(`ReorderMath.containerKeyOf`),与 `OrdoEngine.nextOrder` 的作用域一致 | 三端同口径;跨容器拖拽直接拒绝并提示 |
| 开放拖拽的清单 | 今天 / 收件箱 / 随时 / 某天 / 项目 / 区域;且要求该分区**同容器且 ≥2 行** | iOS `canReorder` 同判据(本端额外开放「今天」,因其排序末位比较键就是 `order`) |

> **第五轮把拖拽入口从"系统通用拖拽"换成了"自己的长按手势"**(§5.4 要求 400ms 阈值、6px 位移判定、
> 拖回原位/返回键取消且不写库)。系统 `draggable/onDragStart/onDrop` 的阈值与取消语义都由系统决定,
> 端上无法满足这三条;现在的落点由位移换算(`dragTargetIndex` 半行取整、上下对称),
> 与 iOS「越过行中点即换位」在语义上等价。

## 8. 编译告警(ArkTS)

### 8.1 修前 / 修后

| 阶段 | ArkTS WARN | ArkTS ERROR | 说明 |
|---|---|---|---|
| 本轮开始(全量 clean 基线) | **71** | 0 | 69 × `RelationalStore.ets` + 1 × `ReminderAgent.ets` + 1 × `Index.ets` |
| 本轮结束(全量 clean) | **0** | 0 | `assembleHap` 为 0;`entry@ohosTest` 也从 5 ERROR + 1 WARN 修到 **0 / 0** |

> hvigor 自身还有 1 条 `WARN: No signingConfig found for product default`,属环境状态而非代码问题,
> 见 §3.3;它不会被计入上表的 ArkTS 告警。

### 8.2 告警分类与处理

| # | 告警 | 数量 | 根因 | 处理 |
|---|---|---|---|---|
| 1 | `Function may throw exceptions. Special handling is required.`(diagnostic **28040**) | 69 | ArkTS 编译器对 SDK 中带 `@throws { BusinessError }` 标注的方法(整套 `relationalStore` API:`getRdbStore`/`executeSql`/`query`/`insert`/`delete`/`getColumnIndex`/`getLong`/`getString`/`isColumnNull`/`goToNextRow`/`beginTransaction`/`commit`/`rollBack`/`rowCount`,以及 `WindowStage.loadContent`)在**调用点**要求显式 `try/catch`。原代码靠 Promise 链 `await` 直接上抛,没有局部 `try/catch`,因此逐处报错 | **真问题,已修**:在 `RelationalStore.ets` 新增「RDB 调用收敛层」,把全部会抛的 RDB API 收敛到十几个私有助手内并统一 `try/catch`,失败包装成 `Error` 后**继续上抛**(因此 `OrdoEngine.safeStore` 与 `AppStore.init` 的降级逻辑行为完全不变);读取循环额外用 `try { while(...) } finally { rs.close() }` 保证结果集一定释放。`TestAbility.ets` 的 `loadContent` 同样加 `try/catch` |
| 2 | `'getContext' has been deprecated.` | 1 | `getContext()` 自 API 18 起废弃 | **真问题,已修**:`pages/Index.ets` 改用 `this.getUIContext().getHostContext()`,与 `@useinstead` 指向的替代 API 一致 |
| 3 | `To use this API, you need to apply for the permissions: ohos.permission.PUBLISH_AGENT_REMINDER` | 1 | `reminderAgentManager.publishReminder` 带 `@permission` 标注,而 `module.json5` 未声明该权限 | **真问题,已修**:`module.json5` 补声明 `ohos.permission.PUBLISH_AGENT_REMINDER`(system_grant,声明即授予),并在 base/zh_CN/en_US 三套 `string.json` 补 `reason_reminder_agent` 说明文案。**不补会在真机上直接发布提醒失败**,不只是告警 |
| 4 | `WARN: No signingConfig found for product default` | 1 | 工程未配置签名证书 | **保留**:属本机环境状态,不是代码问题;提交证书路径进仓库反而会泄露个人信息,见 §3.3 |

### 8.3 为什么把异常「统一包装后再抛」而不是就地 `console.error`

`RelationalStore` 的所有助手统一走 `fail(what, e)` → `throw new Error('[RdbOrdoStore] xxx失败: ...')`:

- **保持原语义**:改造前这些 Promise 会 reject,由 `OrdoEngine.safeStore` 记日志或 `AppStore.init`
  决定是否降级到 `MemoryOrdoStore`;改造后依旧 reject,调用方一行都不用改。
- **信息更全**:统一带上「哪张表 / 哪个列 / 哪个操作」,便于定位(列名是数据库字段名,不含待办正文与令牌,符合契约 §9)。
- **不吞异常**:`closeResultSet` / `rollbackTx` 是唯一的例外——它们只记日志,
  因为「关不上结果集」和「回滚失败」都不应掩盖真正的原始错误。

### 8.4 本机逻辑测试宿主揪出的 4 个缺陷

`python _qa/build-harness.py` 第一次跑就暴露了 55 个用例中的 16 个失败,逐个定性后确认:

| # | 位置 | 现象 | 定性 | 处理 |
|---|---|---|---|---|
| 1 | `core/repeat/RepeatEngine.ets` `firstOccurrenceOnOrAfter` | 循环条件写 `d < fromISO`,当 `fromISO` 当天正好是发生日时会**返回今天** | **真 bug**:§4「计划」窗口是"明天起 14 天",把今天算作"下一次"会让重复待办同时出现在「今天」和「计划」 | 改 `d <= fromISO`。实测 `firstOccurrenceOnOrAfter(weekly, 2026-09-24, 2026-10-08)` 由 `2026-10-08` → `2026-10-15` |
| 2 | `core/nlp/NaturalDateParser.ets` `nextWeekday` + 调用点 | 「下下周三」算出 **2026-10-28**(三周后),契约要求 10-21 | **真 bug**,且是两处叠加:调用点 `m[1].length + 1` 把「下下」当成 3;`nextWeekday` 内部又用 `(weekOffset-1)*7` + 手工顺延,重复计入周偏移 | 调用点改 `m[1].length`;`nextWeekday` 改为「自然向后的最近一次 + (本周内未过则推到下周) + (weekOffset-1) 周」,四个断言(周五/周三/下周五/下下周三)同时成立 |
| 3 | `core/query/ListQuery.ets` `upcoming` | 重复待办完全不进「计划」清单(期望 1 组,实际 0 组) | **真 bug**:把 `t.date`(重复待办的**首次**发生日,通常早已过期)也和"下一次发生日"一起当候选,取最早后判为"今天及更早"整条丢弃 | §4 来源 3 对重复待办只认「下一次发生日」:`if (t.repeat !== null) { 只推 nextDate } else if (when==='date') { 推 t.date }` |
| 4 | `ohosTest/…/SyncMerge.test.ets` L70 | 断言"创建带新标签的待办产出 1 条 op",实际 2 条 | **用例断言落后**(不是产品缺陷):契约 §7.1「每个写操作产出一条 Op」+ §3「标签必须已存在,否则自动创建」→ 自动建标签 + 建待办 = 2 条 op。同一文件 L264 已按 2 断言,前后自相矛盾 | 把断言改为 2,并显式校验顺序(先 `tag` 后 `todo`)。产品代码未改 |

> 另外 12 个失败是宿主自身的问题(垫片没给异步用例传 `done`、时钟未冻结到用例基准日),已在宿主内修正。
> 结论:**这 4 个缺陷在设备上跑 Hypium 之前是发现不了的**(前 3 个只有真正执行断言才会暴露),
> 因此这套宿主不只是"编译验证"的替代品,而是本轮 P0 的主要产出。

## 9. 契约歧义处理(需要契约方确认)

1. **Heading / Tag 的 `deleted` 字段**:§2.3、§2.6 未定义 `deleted`,而 §3 要求"删除一律软删除"。
   本端实现为:从宿主集合移除 + 本地墓碑登记,同步时发 `entity=heading|tag`、`type=delete`、`payload=null` 的 Op,
   与 §7.2 的 delete 语义一致。
2. **软删除实体的 Op 形态**:Area/Project/Todo 有 `deleted` 字段,本端以
   `type=upsert` + `payload.deleted=true` + `updatedAt` 表达软删除(保留 LWW 时间戳),
   同时登记本地墓碑;接收侧对 `type=delete` 与 `deleted=true` **两种形态都做处理**。
3. **`pull` 的 SEQ_GAP 判定**:契约给出错误码但未给算法。本端判定为
   `serverSeq - localSeq > ops.length`,命中则重新拉全量快照后继续增量。
4. **`push.rejected` 的元素形态**:契约只写 `rejected[]`。本端兼容"纯 opId 字符串"与
   `{opId, code, message}` 对象两种形态。
5. **项目完成时 `heading.archived`**:§2.2 要求"所有 heading 已归档"才可完成项目。
   本端 `canCompleteProject` 严格执行,并提供 `archiveHeading`(要求其下无未完成待办)。
6. **`reminder` 与 `date` 的联动**:§3 要求 reminder 日期部分等于 `(when==date ? date : 今天)`。
   因此修改日期时提醒会随之平移;`RepeatEngine` 生成的新实例也把提醒平移到新日期同一时刻。
7. **`filesDir/<userId>/` 在鸿蒙的可落地形式**:ArkData 的 `StoreConfig` 只提供
   `name` + `customDir`,实际路径被限定为 `<context.databaseDir>/rdb/<customDir>/<name>`,
   无法把关系库放到 `filesDir`。本端取 `customDir = userDataDirName(userId)`,
   即 `<databaseDir>/rdb/<userId>/ordo.db` —— 硬约束(每账号一份、互不可见、退出登录不删)完全满足,
   父目录名与文档措辞不同。**请契约方确认是否接受这条平台映射,或把措辞改成"应用私有目录/<userId>/"**。
8. **快加号直径:§4 写 52,§5.2 写 56**:取 §5.2(更新且更具体的那一节,同处还明确"只保留一个圆形按钮"),
   `OrdoSize.quickAdd = 56`。§4 组件表那一行的 52 未同步更新。
9. **§7.6.5 验证码错误体的秒数字段名**:成功响应顶层是 `retryAfter`,**错误体里是
   `details.retryAfterSec`**。本端按此实现(`SyncTypes.parseErrorDetails` + `AppStore` 429 分支);
   契约已补该说明。真机 curl 原文:
   `{"error":{"code":"RATE_LIMITED","message":"发送过于频繁,请稍后再试","details":{"reason":"code_throttled","retryAfterSec":60}}}`。
10. **"同码最多尝试 5 次"的计数口径(请契约方确认)**:实测同一邮箱提交**同一个错码**时,
    第 1~4 次返回 `code_invalid`,**第 5 次**即返回 `code_attempts_exceeded`(即"第 5 次已经超限"，
    与"允许试满 5 次"的字面读法差一次);而连续提交**不同**错码(000001…000005)始终是 `code_invalid`,
    未累计到超限 —— 看起来计数是按"提交的验证码值"而不是"该邮箱的失败次数"。
    客户端两种 reason 都已正确映射,这条只影响文案语义与风控口径,**请服务端确认预期行为**。
11. **错误文案以客户端 reason 映射为准**:`AppStore.authErrorTextOf()` 用
    `errorTextWithReason(code, reason)` 生成中文,**不直接采用服务端 `error.message`**
    (例:服务端 message 是「验证码尝试次数过多,请重新获取」,界面显示的是本端映射的
    「验证码错误次数过多已作废,请重新获取」)。若希望以后端文案为准,请告知,改动点在 `authErrorTextOf`。
9. **"refresh 失败 → 登录页"的边界**:§7.6.4 未区分失败原因。本端把**网络不可达**视为"暂时拿不到新令牌"
   (留在主界面离线可用、状态栏走 §5.3 失败态),只有**服务端明确拒绝**才回登录页。
   否则离线启动会被永久卡在登录页,与 §7.6.3"离线可用"的取向冲突。

## 10. 已知限制 / 未完成项

- **未签名**:本机没有调试证书,产物为 unsigned HAP;**模拟器接受 unsigned**(第六轮实测:两个 HAP 都能装、
  `aa test` 能跑完 **136/136**),但**真机 / 上架仍需签名**(§3.3)。
- **未接入真实后端(生产)**:`SyncApi` 默认 `https://api.ordo.app`,可在登录页「服务器地址」或设置页改。
  第六轮已用**真实开发后端**(`http://10.189.58.216:8788`,真库 + 回显 devCode)跑通验证码登录端到端(§3.4.4);
  但仍**没有生产环境联调**,也**没有真实发信通道**(console 通道 + devCode 回显替代)。
- **登录门禁的设备验证到"页面级"**:`authPhase` 三分支(有会话/无会话/过期)的页面切换、冷启动直达主界面
  与登录页渲染都已在模拟器上截图核对(`_qa/ordo-login-*.jpeg`、`e2e-07-cold-start.jpeg`),
  并用**真实后端账号**完成过验证码登录;淡入淡出与抖动动效的观感仍靠静态核对。
- **手势与帧率未在设备上实测**:左右滑动作区、长按拖拽(400ms/6px)、`LazyForEach` 的真实滚动帧率都只在
  编译与纯逻辑层面验证过;阈值本身有用例钉住(设备上也跑过),但"手感"未验。
- **拖拽跟手靠行键变化**:`LazyForEach` 只在键变化时重建行,所以拖拽位移被折进了行指纹
  (`RowModel.applyDragHint`)。代价是拖动中被拖行会按帧重建,长列表下的帧率未实测;
  若真机上偏卡,兜底是只把「让位行」折进指纹、被拖行改用 `translate` 属性动画。
- **按用户隔离的目录名映射**:契约写 `filesDir/<userId>/`,鸿蒙 ArkData 只允许落在
  `<databaseDir>/rdb/<customDir>/`,故实现为 `<databaseDir>/rdb/<userId>/ordo.db`(§6.3 末尾有说明);
  需要契约方确认这条平台映射。
- **旧版单库数据不做迁移**:第五轮之前只有一个 `ordo.db`(无 customDir),其中的数据不会被迁进新的
  `<userId>/ordo.db`。开发期无真实用户数据,故按"不迁移"处理;上线前若有存量用户需要补迁移脚本。
- **拖拽只在同容器生效**:跨分区/跨项目拖动会被拒绝(提示「手动排序只在同一分区/项目内生效」),
  这是契约 `order` 的作用域决定的;混合容器的分区(如「今天」里同时有 `when=today` 与 `when=date` 的行)整体不开放拖拽。
- **长距离拖拽退化为整表 reload**:位移超过 `MAX_SWAPS = 64` 格时,为免一次拖拽发出上百条通知,改发一次 reload
  (≤ 已渲染行数,不会回到 1000 行时代)。
- **日历事件为本地种子数据**:`§2.8` 的 `CalendarEvent` 只读展示,尚未接 `@ohos.calendarManager`。
- **图标为占位图形**:侧栏与元信息使用文本字形(▤ ★ ▦ ≡ ◇ ▣ ⏰ ⚑ ⟳),刷新控件用 `↻`
  (`OrdoIcons.refresh`)而不是 `SymbolGlyph($r('sys.symbol.…'))`:后者需要额外的符号资源与 API 版本确认,
  本机无设备无法验证渲染结果,故先用字形 + 统一色板(等设计给矢量资源再替换)。
- **撤销窗口 4s**:04 §4 只规定普通提示 2.4s;带「撤销」动作的提示条延长到 4s(样式/位置/圆角不变),
  属"删除可撤销"补的约定,需契约方确认是否接受。
- **`_qa/`**:构建与自检脚本 + 历史日志,不属于 App 运行时代码,不参与打包。
- **本机模拟器不稳定**:`emulator 7.0.0.107` 在这台机器上约 10 分钟自行退出一次(第六轮崩了 4 次,最后一次
  `hdc` 直接 wedge),`uitest dumpLayout` 还会间歇性只返回状态栏空树。UI 取证脚本 `_qa/hdc-ui.ps1`
  因此内置了重试;长链路自动化仍可能被打断,必要时按 §3.4.4 的步骤分批重跑。
- **429 的界面文案与倒计时置灰没截到图**:服务端 429 响应体(`code_throttled` + `retryAfterSec:60`)有 curl 原文,
  客户端 `reasonText('code_throttled')` 与 60s 倒计时/夹取有 18 条宿主用例覆盖,
  但**"应用内点到 429 → 界面出现该文案"这一张 UI 截图缺失**(受上一条不稳定影响)。补齐方式见 §3.4.4 末尾。
- **设备端写盘缺陷已修但仍属"刚修好"**:`RelationalStore.ets` 的保留字缺陷(§7.0.1)与冷启动阶段缺陷(§7.0.2)
  都是第六轮真机才发现的既有问题;修复后有设备端回归用例与截图,但**除本次验证过的路径外,
  其它写盘分支(同步落地 / outbox 清理 / 墓碑)只做了同一 helper 的代码级覆盖**,没有逐一在设备上走过。

## 11. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-08 | 首次实现:契约 §2–§7 的 ArkTS 版核心 + ArkUI 界面 + Hypium 四组用例 + 工程脚手架 |
| 2026-10-09 | 环境固化(SDK 26.0.0 / hvigor 6.26.4,§3 本机构建)+ 签名缺失说明;ArkTS 告警 71 → 0(§8);新增登录/注册与服务器地址(§6);本地库写盘改增量 upsert、UI 派生结果加版本缓存(§7);修复 ohosTest 编译(5 ERROR → 0);新增 `_qa/build.ps1`、`_qa/warn-report.ps1` 自检脚本 |
| 2026-10-09 | P0:新增**本机逻辑测试宿主**(§3.4.1),四组 Hypium 用例在本机真实执行 **55/55 通过**;据此修掉 3 个真 bug(`firstOccurrenceOnOrAfter` 边界、`下下周三` 周偏移双重计入、`upcoming` 重复待办被丢弃)与 1 处落后断言(§8.4);`_qa/build-harness.py` + `_qa/node-harness/` |
| 2026-10-09 | 第三轮(鸿蒙端):① 列表渲染改 **`List + LazyForEach` + 行数据源**(§7.3),1000 条待办下"改一行 = 1 行重建、拖拽 = 0 重建";新增 `view/list/{RowModel,RowDataSource,TodoRow,SwipeActionBar}.ets`、`viewmodel/ReorderMath.ets`;② **左右滑手势**(右滑完成 / 左滑删除 + 排期,删除可撤销)与 **长按拖拽排序**(提交同容器完整可见序列,跨容器拒绝)(§7.4);③ 引擎补 `reorderTodos(ids)` / `restoreDeletedTodo(id)`;④ 新增 `_qa/row-perf-harness.mjs`(真实行模型在 Node 上评测,§7.3)+ `RowModel/ReorderMath` 两组 Hypium 用例(宿主内 **82/82 通过**) |
| 2026-10-10 | **第五轮**:① 契约 §7.6 落地——新增 `core/session/OrdoSession.ets`(会话 / 游客 / `userDataDirName`)、`SyncApi.guest()/upgrade()`、`AuthUser.isGuest`;② §7.6.3 按 userId 隔离:应用级 `ordo-meta.db`(会话/设备/地址/外观)+ 账号级 `<databaseDir>/rdb/<userId>/ordo.db`,设置页显示账号与目录并提供退出登录;③ §5.1 登录门禁:重写 `view/LoginPage.ets`(卡片 400 / 浮动标签 / 口令显示隐藏 / 提交转圈 / 错误抖动 / 进入与淡出淡入 / 游客为同级次要按钮),`pages/Index.ets` 按 `authPhase` 门禁;④ §5.2 快加号:去掉多余元素、直径 56、长按 400ms 出菜单、旋转 45°、面板与菜单项错位动效;⑤ §5.3 刷新控件:新增 `view/Common/RefreshControl.ets` + `viewmodel/RefreshState.ets`(连转 / success 1.4s / danger 常驻);⑥ §5.4 长按拖拽:新增 `viewmodel/PressGesture.ets`,去掉系统通用拖拽,补插入指示线与取消路径(返回键);⑦ 宿主新增三组 31 条用例(**116/116 通过**),并修掉宿主里写死的旧工程路径(`WeChat\ordo` → 自推导) |
| 2026-10-10 | **第六轮 · 邮箱验证码登录(契约 §7.6.5)**:① `SyncApi` 新增 `requestEmailCode(email)`(`POST /v1/auth/email/code`,202 `{sent,expiresIn,retryAfter,devCode}`)与 `emailLogin(email, code, deviceId, deviceName)`(`POST /v1/auth/email/login`,与 register/login/guest 同构,复用 `parseAuth`);② 错误细化:`SyncTypes` 新增 `reasonText / errorTextWithReason / parseErrorDetails`(`details.reason` + **错误体的 `details.retryAfterSec`**,不新增错误码),`OrdoApiError` 带上 `reason / retryAfterSec`;③ `AppStore` 新增 `requestEmailCode(email)`(按响应 `retryAfter` 起倒计时;429 时优先用 `details.retryAfterSec`,兜底 60s,夹取 1 小时)与 `emailCodeLogin(email, code, deviceId)`(校验 6 位 → `adoptSession`,未注册邮箱自动建号);④ 新增纯逻辑 `viewmodel/EmailCodeState.ets`(`EmailCodeMachine`:倒计时 / 置灰 / 满 6 位自动提交去重 / `devCode` 容错,不依赖 ArkUI);⑤ `view/LoginPage.ets` 新增「口令登录 / 验证码登录」同级页签与验证码框(沿用浮动标签 / 发丝描边 / 错误抖动基线,右侧「获取验证码」点击区 44,`devCode` 自动填入),并补 `ordo_login_tab_* / ordo_login_get_code` 测试 id;⑥ 宿主新增一组 18 条用例(**134/134 通过**),`assembleHap` 与 ohosTest 两个 HAP 均 BUILD SUCCESSFUL、ArkTS ERROR 0 |
| 2026-10-10 | **第六轮 · 模拟器验证(首次真机跑测试)**:① 补齐 `ohosTest/ets/testrunner/OpenHarmonyTestRunner.ets` —— 此前 `aa test` 因缺该入口点直接 `App died`(ResultCode -1),DevEco 面板走 TestAbility 所以一直没暴露;② 模拟器(`emulator 7.0.0.107` / API 26)实测:`hdc install` unsigned HAP 成功(更正 §3.3 旧结论),`aa test -b com.ordo.app -m entry_test -s unittest OpenHarmonyTestRunner` → **`Tests run: 134, Failure: 0, Error: 0, Pass: 134`,`TestFinished-ResultCode: 0`**;③ 真机首跑抓到一条**写死日期的既有用例**(`SyncMerge.test.ets` 的 `invariants_reminder_moves_inbox_to_today_and_aligns_date` 期望 `2026-10-08T18:00`,而设备真实日期下引擎按契约把 reminder 平移到今天 = `2026-10-10T18:00`),改为用 `todayISO()` 现算期望;④ 用 `uitest dumpLayout` + `snapshot_display` 做了三张真机截图(口令模式 / 验证码模式 / 空邮箱点「获取验证码」的错误态,`_qa/ordo-login-*.jpeg`),并实测「获取验证码」点击区 = 268×132 px(3x 密度 = 44vp,满足 §8) |
| 2026-10-10 | **第六轮 · task-7 模拟器 ↔ 真实后端端到端**:① **修掉两个设备端才暴露的缺陷**——`RelationalStore.insertRow` 的 `order`/`when` 保留字导致真 SQLite 写盘全挂(§7.0.1,严重:本地优先 + 多端同步在设备端完全不可用),`AppStore.init()` 冷启动恢复会话时 `authPhase` 停在 `booting` 导致白屏(§7.0.2,违反 §7.6.4);② 新增设备端真库回归用例 `RelationalStore.test.ets`(第 11 组),并做了**去掉引号 → 1 Error / 恢复 → 0 Error** 的红绿验证;`TestContext` 把 UIAbility 上下文交给用例(RDB 不接受 appContext);③ `uitest` 驱动完成端到端取证(改址 8788 → 获取验证码 202 + devCode 自动填入 → 满 6 位自动提交进主界面 → 设置页账号/目录名/地址 → 口令登录无口令账号被拒 → 错码 / 连错文案),截图 `_qa/e2e-*.jpeg`,日志 `_qa/e2e-r6.log`;④ 设备端 `aa test` 从 134 增至 **136/136 全绿**,并记录"判定要看 `OHOS_REPORT_RESULT`、`ResultCode` 在有 Error 时仍为 0"这一坑 |
| 2026-10-10 | **第六轮 · task-10 快加号菜单图标对齐 §5.2 v1.3**:① 新增纯逻辑 `viewmodel/FabMenu.ets` —— 图标改为**形状枚举**(plus / projectH / area / heading)、20×20 viewBox 的逐条几何与线宽(＋2.1 / H 1.7 / 区域方框 1.5 + r2.6 / ≡ 1.7)、面板与条目尺寸(≥208 / radius 12 / 高 ≥44 / 左内边距 9 / 图标间距 8 / 条目 radius 7)、快捷键只挂「新建待办」、**「新建标题」仅项目视图可用**;② `view/QuickAddButton.ets` 的 4 个图标与 FAB 的白「+」全部改为 `Line`/`Rect`/`Circle` **矢量绘制**(去掉字体字符回退风险),条目按下底 `rowSelected`、快捷键提示右对齐;③ 新增第 12 组 `FabMenu.test.ets` 8 条用例(**宿主 134 → 142 全过**);④ 两个 HAP BUILD SUCCESSFUL、ArkTS ERROR 0;selfcheck 0 问题。设备端复跑与菜单截图**未完成**:该模拟器第 5 次 hdc wedge(install 挂死),按契约方意见如实标注缺图 |
| 2026-10-13 | **v1.4 · 移除登录系统(启动即主界面 + 静默匿名会话)**:① 删除 `view/LoginPage.ets`(登录/注册/游客/验证码/服务器设置面板)、`viewmodel/EmailCodeState.ets` + 其 18 条用例、`Index.ets` 的 login/entering 门禁与 `main_pages.json` 路由,设置页删掉账号/账号标识/升级为正式账号/退出登录/服务器地址;② 新增 `viewmodel/SilentAuth.ets`(启动分支 `planStartup` / **目录标识钉法** `planAccountDirId` + `newLocalAccountId` / 指数退避 + 状态机)与 9 条用例;`AppStore` 改为静默会话:启动**不等网络**、直接开库进主界面,后台静默 `guest`(失败按 2s→4s→…→60s 退避重试),有会话则有效直接用 / 过期后台 refresh,同步遇 401 静默重建匿名会话;③ 目录标识按**契约 §7.6.6** 改为**本机稳定账号 id**:kv `ordo.localAccountId` 首次生成 `local-<16hex>` 并钉住,此后永不随会话重建而改变,升级前老目录(`userDataDirName(userId)`)继续沿用、不做迁移;④ 清理 `SyncApi`(删 register/login/upgrade/email-code/logout,保留 guest/refresh)与 `SyncTypes` 的验证码 reason 文案;⑤ 服务器地址改隐藏覆盖(§6.6);⑥ 门禁:`assembleHap` 与 ohosTest 两个 HAP BUILD SUCCESSFUL / **ArkTS ERROR 0**,宿主 **133/133**(142 → 133:删 18 条验证码用例、增 9 条静默会话用例),selfcheck 0 问题,check-encoding OK;⑦ **RDB 引号写盘修复(§7.0.1)未回退**,设备端真库用例保留;⑧ 真机取证(模拟器 `emulator 7.0.0.107`):`assembleHap` 后 `hdc install` + 启动 → **启动即主界面**(截图 `_qa/v14-boot-main.jpeg`,日志 `_qa/e2e-r6.log`),设置页「本地数据」显示 数据目录 = `local-805e05692b26ba14`(**本机稳定 id**)、同步会话 = `离线可用 · 稍后自动重连`(后端未运行 → 后台退避重试,界面照常可用,截图 `_qa/v14-settings-localdata.jpeg`);`aa test` → **`Tests run: 135, Failure: 0, Error: 0, Pass: 135`**(日志 `_qa/ohostest-device-v14.log`) |