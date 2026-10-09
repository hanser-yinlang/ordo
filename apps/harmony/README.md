# Ordo(序)· 鸿蒙端(HarmonyOS NEXT / Stage 模型 / ArkTS)

> 契约来源:`ordo/docs/03-数据模型与同步协议.md`(FROZEN v1)与 `ordo/docs/04-UI设计规范.md`(ordo-ds@1.0.0)
> 状态:**已在本机 DevEco Studio 26.0.0.821 + HarmonyOS SDK 26.0.0(API 26)上编译通过**,
> `assembleHap` 与 ohosTest 编译均 BUILD SUCCESSFUL、**ArkTS 告警 0**(见 §3「本机构建」与 §8「编译告警」)。
> 尚未签名、未上真机(见 §3.3 签名配置缺失)。

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
   └── core/sync/**                    §7:SyncApi(HTTP) · SyncEngine · RealtimeClient(WS)
```

- **本地优先**:所有写操作先改内存并立即 `bump()` 通知 UI,再异步落库与入 outbox(契约 §7.1)。
- **单一事实来源**:`Project.headings` 为规范存放处,`headings` 表单独持久化,装载时装配。
- **无循环依赖**:`OpSink`/`OpSource` 两个接口把引擎与同步引擎解耦;`RealtimeCallbacks` 由
  `NoopRealtimeCallbacks` 占位、构造完成后再 `setCallbacks()` 注入真正的桥。
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
│       │       │   ├── sync/SyncApi|SyncEngine|RealtimeClient|SyncTypes.ets   §7 同步
│       │       │   ├── storage/OrdoStore|RelationalStore|MemoryStore.ets      §8 存储
│       │       │   ├── notify/ReminderAgent.ets         reminderAgentManager 到点提醒
│       │       │   ├── deeplink/DeepLink.ets            ordo:// 解析
│       │       │   ├── util/{DateUtil,Ids}.ets          日期与 ULID
│       │       │   └── SeedData.ets                     中文示例数据
│       │       ├── theme/Tokens.ets                     04 §2 设计令牌(深浅两套)
│       │       ├── viewmodel/AppStore.ets               @Observed 视图模型 + 派生缓存 + 账号状态
│       │       ├── viewmodel/ReorderMath.ets            拖拽排序纯计算(容器键 / 落点 / 是否开放)
│       │       ├── view/{Sidebar,ListPage,DetailCard,ScheduleSheet,FastFindSheet,QuickAddButton}.ets
│       │       ├── view/list/RowModel.ets               行模型 + 行指纹 + 行级差量(纯逻辑)
│       │       ├── view/list/RowDataSource.ets          LazyForEach 数据源(BasicDataSource)
│       │       ├── view/list/TodoRow.ets                待办行组件(按行指纹重渲染)
│       │       ├── view/list/SwipeActionBar.ets         左右滑动作区按钮
│       │       ├── view/LoginPage.ets                   登录/注册浮层(LoginSheet)+ 独立页(LoginPage)
│       │       ├── view/Common/{ProgressRing,EmptyState,OrdoToast}.ets
│       │       └── pages/{Index,SettingsPage}.ets
│       └── ohosTest/                  Hypium 六组用例 + 测试 Ability
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
cd C:\Users\admin\Desktop\WeChat\ordo\apps\harmony
& "$deveco\tools\node\node.exe" "$deveco\tools\hvigor\bin\hvigorw.js" --mode module -p product=default assembleHap --no-daemon
```

实测输出(2026-10-09):

```
> hvigor Finished :entry:assembleHap...
> hvigor BUILD SUCCESSFUL in 1 s 403 ms
33 tasks in total: 15 executed, 18 up-to-date
```

产物:`entry/build/default/outputs/default/entry-default-unsigned.hap`(约 1.05 MB / 1074 KB)。

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

### 3.3 签名配置缺失(当前无法上真机 / 模拟器)

- 工程**故意留空 `signingConfigs`**(`build-profile.json5`),以免把本机证书路径提交进仓库;
  因此当前产物是 **unsigned HAP**,`hdc install` 会因签名校验失败,
  hvigor 也会提示 `WARN: No signingConfig found for product default`。
- 本机 `%USERPROFILE%\.ohos\config` 下**没有**任何调试证书(已确认),所以现在**不能**签名,也不能跑 Hypium。
- 补齐签名的两条路(都需要华为开发者账号):
  1. **自动签名(推荐)**:DevEco Studio → `File > Project Structure > Signing Configs` →
     登录华为账号 → 勾选 **Automatically generate signature**。此操作会生成
     `%USERPROFILE%\.ohos\config\openharmony\default_*.p12/.cer/.p7b` 并自动回填 `signingConfigs`
     (**不要把这些路径提交进仓库**)。
  2. **手动签名**:在 AppGallery Connect 申请调试证书 + Profile,再用 SDK 自带的
     `<DevEco>\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar` 对
     `entry-default-unsigned.hap` 签名。
- 签名完成后:`hdc install entry-default-signed.hap`,或 DevEco 里直接 `Run 'entry'`。

### 3.4 无设备时如何跑测试

#### 3.4.1 本机逻辑测试宿主(无需设备,已跑通 82/82)

Hypium 用例在设备上跑需要签名,而本机没有证书。但**六组用例只依赖纯逻辑模块**
(`core/` 下除 `RelationalStore` / `RealtimeClient` / `SyncApi` / `ReminderAgent` 之外的模块,
外加 `viewmodel/ReorderMath.ets`、`view/list/RowModel.ets`,全部不含 `@ohos`/`@kit` 依赖),
断言也只用到 `describe` / `it` / `expect` + `assertEqual|assertTrue|assertFalse`。
因此工程内提供了一套**本机宿主**,用 DevEco 自带的 tsc 编译后由 Node 真正执行:

```powershell
cd C:\Users\admin\Desktop\WeChat\ordo\apps\harmony
python _qa\build-harness.py
```

它做四件事:

1. 把纯逻辑核心模块与 `ohosTest` 的六组用例复制到 `_qa/node-harness/src`,并去掉 `.ets` 后缀;
2. 用一个 Hypium 垫片(`_qa/node-harness/src/hypium-shim.ts`)实现 `describe/it/expect` 与断言,
   **真正 await 异步用例**(`async (done) => …` 形态,不会在断言执行前误判通过);
3. 把时钟冻结到 **2026-10-08**(`freeze-clock.ts`)—— 用例注释明确写着"固定今天为 2026-10-08",
   但 `DateUtil.todayISO()` 一类路径仍会读系统时间,不冻结就会跨天假失败;
4. `tsc`(strict + noImplicitAny + strictNullChecks)编译 → Node 运行 → 汇总,退出码 0 = 全通过。

实测结果:

```
describe 块: 6      用例总数: 82      通过: 82      失败: 0
RESULT: ALL PASSED
```

> 第三轮新增两组用例:`RowModel.test.ets`(行序列等价性 / 行键稳定性 / 差量分类 / 拖拽开关)、
> `ReorderMath.test.ets`(容器键 / 落点 / 跨容器拒绝)。`view/list/RowDataSource.ets` 用到 ArkUI 的
> `IDataSource`/`DataChangeListener` 声明,不进这个宿主;它的**通知时序**由 `_qa/row-perf-harness.mjs`
> 直接执行真实实现来验证(§7.3)。

定位说明:**这是本机快速回归,不替代设备上的权威 Hypium 测试**。
垫片只覆盖用例实际用到的 API;`RelationalStore`(RDB 真机存储)与 WebSocket 相关路径不在覆盖范围内。

#### 3.4.2 测试代码的编译验证

```powershell
& "$deveco\tools\node\node.exe" "$deveco\tools\hvigor\bin\hvigorw.js" `
  --mode module -p module=entry@ohosTest -p product=default assembleHap --no-daemon
# 实测:BUILD SUCCESSFUL,ArkTS WARN 0 / ERROR 0
```

#### 3.4.3 设备上跑权威 Hypium

1. 启动模拟器:DevEco Studio → `Device Manager` → 选中已部署的 **Pura X View**
   (HarmonyOS 7.0.0 / API 26.0.0,x86_64)→ Start;或 USB 连真机并开启「开发者模式 + USB 调试」。
2. 确认设备可见:`hdc list targets` 应列出设备号(DevEco 的 Device Manager 也会显示)。
3. 右键 `entry/src/ohosTest` → **Run 'OhosTest'**;
   或在选定 `entry` 模块的运行配置里把 Test 类型切到 `OhosTest` 后运行。
4. 用例清单(`entry/src/ohosTest/ets/test/`):`NaturalDateParser.test.ets`(中文 NLP)、
   `ListQuery.test.ets`(派生清单)、`RepeatEngine.test.ets`(重复引擎与月末溢出)、
   `SyncMerge.test.ets`(§7.3 合并规则)。
5. 结果在 DevEco 的 Test 面板与 `<DevEco>\...\log` 中查看。

> **两个前置条件**(缺一不可,都需要人工操作):
> 1. **签名**(§3.3)—— 否则测试 HAP 无法安装,`Run 'OhosTest'` 会在安装阶段失败。
> 2. **模拟器许可证** —— 本机 `Emulator.exe -license` 显示还有 2 份协议待接受。
>    首次启动模拟器时 DevEco 会弹出协议,需要**用户本人**点击同意
>    (这是与华为之间的法律协议,不应由工具代签)。命令行等价形式:`Emulator.exe -license accept`。

### 3.5 真机 / 模拟器运行

1. **打开工程**:DevEco Studio → `File > Open` → 选择 `ordo/apps/harmony`(注意是这一层,不是仓库根)。
2. **同步依赖**:首次打开会自动 `hvigor` 同步;若提示缺少 `@ohos/hypium`,执行
   `File > Sync and Refresh Project`。
3. **配置签名**:见 §3.3。
4. **构建**:`Build > Build Hap(s)/APP(s) > Build Hap(s)`,产物在 `entry/build/default/outputs/default/`。
5. **运行**:选中 `entry` 模块 → `Run 'entry'`。
6. **深链自测**(可选):
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
| §2.4 `order` / 04 §6 拖拽排序 | 同容器完整序列整批重写 `order = 下标` | `OrdoEngine.reorderTodos(ids)` / `viewmodel/ReorderMath.ets`(容器键与落点)/ `RowModel.diffRows`(行级差量) |
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
| §7.4 HTTP 接口 | 9 个端点 + 请求头 + 401 重放 | `core/sync/SyncApi.ets`(health/register/login/refresh/logout/snapshot/push/pull) |
| §7.4 限制与错误码 | ≤500 ops / ≤256KB / ≤1000 pull;10 个错误码 | `Entities.ets` 常量 + `SyncTypes.errorText` + `SyncApi.push` 超限处理 |
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
| §4 快加号(直径 52,长按展开菜单) | `view/QuickAddButton.ets` |
| §4 提示条(底部居中 pill,2.4s) | `Common/OrdoToast.ets`;带「撤销」动作时停留 4s(见 §7.3 的删除可撤销) |
| §5 完成动效 | `view/list/TodoRow.ets`(透明度/动画)+ `OrdoMotion` 常量;`Common/ProgressRing` 100% 脉冲 |
| §6 手势:右滑完成 / 左滑删除 + 排期 | `ListPage.todoItem` 的 `ListItem.swipeAction`:start = 完成(绿 `state.success`),end = 排期 + 删除(危险色 `state.danger`);删除后可撤销 |
| §6 手势:长按拖拽排序 | `ListItem.onDragStart/onDrop` → `ReorderMath.movedOrder` → `AppStore.reorderTodos(ids)` → `OrdoEngine.reorderTodos`(《04》§6「鸿蒙 = 长按拖拽」) |
| §6 键盘与手势(其余鸿蒙列) | 设置页列出映射;点击行展开、点击复选框完成、长按快加号出菜单 |
| §7 平台映射(RelationalStore / reminderAgentManager / ordo://) | `RelationalStore.ets` / `ReminderAgent.ets` / `module.json5` skills |
| §8 无障碍 | 所有可点元素 ≥44vp(`OrdoSize.minTouchTarget`)、滑动动作区宽 72vp、状态不只靠颜色(逾期同时有图标+红色) |

## 6. 账号与服务器地址

### 6.1 入口与形态

| 入口 | 位置 | 说明 |
|---|---|---|
| 设置 → 同步 → 「登录 / 注册」 | `pages/SettingsPage.ets`(`SettingsSheet`) | 未登录时显示绿色按钮,点击后关设置、开登录浮层 |
| 主界面浮层 | `pages/Index.ets`(`store.loginOpen`) | 居中遮罩浮层,复用 `LoginSheet` |
| 自动弹出 | `AppStore` 的 `sync.setListener` | 同步返回 `AUTH_REQUIRED` 时自动 `loginOpen = true` |
| 独立页 | `view/LoginPage.ets`(`@Entry LoginPage`,`main_pages.json` 注册) | 便于以后做深链直达登录 |

### 6.2 交互与状态

| 能力 | 实现 |
|---|---|
| 登录 / 注册切换 | `LoginSheet.modeChip` 分段控件,`store.login/register` |
| 邮箱 + 口令 | `TextInput` + `InputType.Email` / `InputType.Password`;提交前校验邮箱形态与口令 ≥6 位 |
| 服务器地址 | 折叠区「服务器地址」可改,`store.setBaseUrl()` 写 kv 并热切换 `SyncApi.baseUrl` 与 WS 地址 |
| 服务器探活 | `setBaseUrl` 保存后立即 `syncNow()` 一次,失败走错误码提示 |
| 错误提示 | 一律 `SYNC 错误码 → errorText()`(契约 §7.4),UI 不硬编码错误文案 |
| 成功动作 | 令牌写 kv(`accessToken`/`refreshToken`)、邮箱写 kv、`onTokensUpdated()` 重连 WS、清示例数据、`resyncSnapshot()` + `syncNow()` |
| 退出登录 | 设置页「退出登录」→ `logout()`:服务端 logout + 清 kv 令牌 + 断开 WS,**本地数据保留** |
| 防重复提交 | `store.loginBusy` 期间按钮禁用并显示「请稍候…」 |

### 6.3 AppStore 新增的对外成员

`loginOpen` / `loginBusy` / `loginError` / `loginPrefersRegister` / `baseUrl`,
方法 `openLogin(preferRegister)` / `closeLogin()` / `isSignedIn()` / `login(email, pwd)` /
`register(email, pwd)` / `logout()` / `setBaseUrl(url)` / `serverText()` / `accountText()`。

> 首次登录会 `persistAll(空)` 清掉首次安装写入的示例数据,避免把演示内容推到用户账号里;
> 随后先 `resyncSnapshot()` 拉服务端全量,再 `syncNow()` 推送本地 op(契约 §7.4)。

## 7. 性能优化:写放大与局部刷新

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
| 长按拖拽 | `onDragStart/onDrop` → `movedOrder` → `reorderTodos(ids)` | 与 iOS `movedOrder` 同形(先移除再插入);落点规则见下 |
| 提交的序列 | **同一容器内的完整可见序列**(界面顺序),核心按 `ids[i].order = i` 整批落库 | 与 iOS `AppEnvironment.reorderTodos(ids:)`、桌上端 `ReorderMath.applySectionOrder` 同一契约 |
| 容器 = | `(when, projectId, headingId)`(`ReorderMath.containerKeyOf`),与 `OrdoEngine.nextOrder` 的作用域一致 | 三端同口径;跨容器拖拽直接拒绝并提示 |
| 开放拖拽的清单 | 今天 / 收件箱 / 随时 / 某天 / 项目 / 区域;且要求该分区**同容器且 ≥2 行** | iOS `canReorder` 同判据(本端额外开放「今天」,因其排序末位比较键就是 `order`) |

> 落点规则与 iOS 有一处**刻意的差异**:鸿蒙用通用拖拽(`onDragStart/onDrop`),落点最小单位是整行,
> 拿不到"指针是否越过目标行中点"的信息,因此按拖动方向表达意图——向下拖落在目标行**之后**、
> 向上拖落在目标行**之前**(等价于桌上端"指针落在目标行下半部分"的结果)。
> 否则"往下拖一行"会变成空操作(iOS 的 `targetIndex - 1` 在整行落点下就是这个后果)。

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

## 10. 已知限制 / 未完成项

- **未签名 / 未上真机**:本机没有调试证书,产物为 unsigned HAP,`hdc install` 会失败;
  纯逻辑用例可在本机宿主里真实执行(§3.4.1),但**设备上的 Hypium 与真机手势仍未跑过**。
- **未接入真实后端**:`SyncApi` 默认 `https://api.ordo.app`,可在登录页「服务器地址」或设置页改;
  登录/注册 UI 与服务器地址切换已完成(§6),但**尚无可用服务端**做端到端联调。
- **手势与帧率未在设备上实测**:左右滑动作区、长按拖拽、`LazyForEach` 的真实滚动帧率都只在编译与
  纯逻辑层面验证过(§7.3 末尾列了兜底改法);动作区按钮的触摸热区在 44vp 以上,但没有真机手感验证。
- **拖拽落点为整行**:见 §7.4 末尾,通用拖拽拿不到行内中点,所以"向下拖 = 落在目标行之后"是**行级**语义;
  若将来改用 `List.onItemDragStart/onItemDrop`,可以拿到 `insertIndex` 做行内中点细分。
- **拖拽只在同容器生效**:跨分区/跨项目拖动会被拒绝(提示「手动排序只在同一分区/项目内生效」),
  这是契约 `order` 的作用域决定的;混合容器的分区(如「今天」里同时有 `when=today` 与 `when=date` 的行)整体不开放拖拽。
- **长距离拖拽退化为整表 reload**:位移超过 `MAX_SWAPS = 64` 格时,为免一次拖拽发出上百条通知,改发一次 reload
  (≤ 已渲染行数,不会回到 1000 行时代)。
- **日历事件为本地种子数据**:`§2.8` 的 `CalendarEvent` 只读展示,尚未接 `@ohos.calendarManager`。
- **图标为占位图形**:侧栏与元信息使用文本字形(▤ ★ ▦ ≡ ◇ ▣ ⏰ ⚑ ⟳),等设计给出矢量资源后替换为
  `$media:` 资源或 `SymbolGlyph`。
- **撤销窗口 4s**:04 §4 只规定普通提示 2.4s;带「撤销」动作的提示条延长到 4s(样式/位置/圆角不变),
  属本轮为"删除可撤销"补的约定,需契约方确认是否接受。
- **`_qa/`**:构建与自检脚本 + 历史日志,不属于 App 运行时代码,不参与打包。

## 11. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-08 | 首次实现:契约 §2–§7 的 ArkTS 版核心 + ArkUI 界面 + Hypium 四组用例 + 工程脚手架 |
| 2026-10-09 | 环境固化(SDK 26.0.0 / hvigor 6.26.4,§3 本机构建)+ 签名缺失说明;ArkTS 告警 71 → 0(§8);新增登录/注册与服务器地址(§6);本地库写盘改增量 upsert、UI 派生结果加版本缓存(§7);修复 ohosTest 编译(5 ERROR → 0);新增 `_qa/build.ps1`、`_qa/warn-report.ps1` 自检脚本 |
| 2026-10-09 | P0:新增**本机逻辑测试宿主**(§3.4.1),四组 Hypium 用例在本机真实执行 **55/55 通过**;据此修掉 3 个真 bug(`firstOccurrenceOnOrAfter` 边界、`下下周三` 周偏移双重计入、`upcoming` 重复待办被丢弃)与 1 处落后断言(§8.4);`_qa/build-harness.py` + `_qa/node-harness/` |
| 2026-10-09 | 第三轮(鸿蒙端):① 列表渲染改 **`List + LazyForEach` + 行数据源**(§7.3),1000 条待办下"改一行 = 1 行重建、拖拽 = 0 重建";新增 `view/list/{RowModel,RowDataSource,TodoRow,SwipeActionBar}.ets`、`viewmodel/ReorderMath.ets`;② **左右滑手势**(右滑完成 / 左滑删除 + 排期,删除可撤销)与 **长按拖拽排序**(提交同容器完整可见序列,跨容器拒绝)(§7.4);③ 引擎补 `reorderTodos(ids)` / `restoreDeletedTodo(id)`;④ 新增 `_qa/row-perf-harness.mjs`(真实行模型在 Node 上评测,§7.3)+ `RowModel/ReorderMath` 两组 Hypium 用例(宿主内 **82/82 通过**) |
