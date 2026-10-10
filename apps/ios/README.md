# 序 Ordo · iOS 端(Ordo.xcodeproj)

> 契约:[`docs/03-数据模型与同步协议.md`](../../docs/03-数据模型与同步协议.md)(FROZEN v1)· [`docs/04-UI设计规范.md`](../../docs/04-UI设计规范.md)(ordo-ds@1.0.0)
> 交互参照:Web 原型 [`things-clone/`](../../../things-clone/)(仅作交互参照;命名、配色、图标全部按 04 号文档的 Ordo 品牌实现)

> ## ⚠️ 当前状态:源码就绪,**未经编译**
>
> 本工程的开发机是 **Windows 11(仅有 JDK 21 + Gradle 8.14 + Node/pnpm)**,没有 macOS / Xcode,
> **全部 Swift 代码一次都没有编译过**。这不是"懒得编译",而是环境上无法完成 —— 已实测的证据:
>
> | 探测 | 结果 |
> |---|---|
> | `swiftc` / `xcodebuild` | 不存在(Windows 无 Apple 工具链) |
> | `gradlew :shared:core:tasks --all` 中搜索 `xcframework` / `iosArm64` | **0 命中** —— KMP 的 Apple 目标在 `if (HostManager.hostIsMac)` 内,Windows 上不注册 |
> | 工程 `import` 的 Apple 专属模块 | SwiftUI · SwiftData · EventKit · UIKit · AppIntents · UserNotifications · CoreGraphics · Network · Observation —— Swift for Windows 均不提供 |
>
> 因此 macOS 上的编译是**必须由 Mac 执行的一步**,已固化为 `tools/verify_ios.sh`(一条命令);
> Windows 侧能把关的部分已全部自动化(见 §6 的 `preflight.py`)。
>
> 已完成的是:结构自检 + 编译前预检 + 与 `shared/core` 真实 Kotlin 源码的逐条交叉核对。

iOS 端是**纯展示 + 系统集成层**:所有业务规则(派生清单、字段不变量、NLP、重复规则、冲突合并)
都由 KMP 共享核心 `shared/core`(包 `com.ordo.core`)实现,Swift 侧通过 `OrdoCoreBridge` 包装为
`@Observable` 状态,**不复制任何业务规则**。

> **桥接层已与真实 Kotlin 源码逐条核对**(`shared/core/src/commonMain/kotlin/com/ordo/core/**`),
> 不再依赖接口假设。核对结论见 §2.1,可复现的交叉核对脚本见 `tools/check_ios_sources.py`
> (它的清单**直接从 Kotlin 源码动态提取**,核心一变,缺什么立刻报出来)。

```
apps/ios/
├── Ordo.xcodeproj/                  # 生成的 Xcode 工程 + 共享 Scheme
├── project.yml                      # XcodeGen 等价描述(推荐日常使用)
├── Package.swift                    # SwiftPM:声明对二进制目标 OrdoCore 的依赖
├── Config/
│   ├── Info.plist                   # ordo:// 深链、ATS 本地例外、通知与日历权限说明
│   └── Ordo.entitlements            # aps-environment、associated-domains
├── tools/
│   ├── gen_xcodeproj.py             # 生成 project.pbxproj + scheme,并做结构校验
│   ├── check_ios_sources.py         # 交付自检:结构/占位符/契约字段/Kotlin 交叉核对/写入范围
│   ├── preflight.py                 # **编译前预检(任意平台可跑)**:配置/pbxproj/桥接符号/Swift 风险
│   ├── mac_onboarding.sh            # **刚拿到 Mac 的第一条命令**:环境自检(Xcode/JDK/wrapper)→ 编译
│   ├── verify_ios.sh                # **macOS 一条命令跑通**:探测任务名 → XCFramework → 构建 → 测试 → 自检
│   └── ci-ios-job.yml               # 修正版 macOS CI job(供根目录 .github/workflows/ci.yml 合并)
├── Ordo/
│   ├── App/            OrdoApp(登录门禁 + 深链)· AppEnvironment(组合根)· DeepLink
│   ├── Auth/           **OrdoAuthService(会话/登录/注册/游客/升级)**· LoginView(§5.1)· LoginModel
│   ├── Core/           OrdoModel(契约 §2 值类型)· OrdoEngineProtocol · **OrdoCoreBridge(KMP 桥)**
│   │                   · OrdoCoreMapping · OrdoPayloadCoding · OrdoAPIProtocols · OrdoStorageProtocol
│   │                   · **OrdoSession(§7.6 会话模型/门禁)**· **OrdoSessionBridge(会话 + 按用户分目录的 KMP 桥)**
│   │                   · OrdoNaturalLanguage · OrdoDateFormatter · OrdoJSONValue
│   ├── Data/           SwiftDataStorage(@ModelActor,契约 §8;每账号一个目录)
│   │                   · **EventKitAgenda(只读系统日历)**· SeedData(示例日程)
│   ├── Net/            OrdoHTTPClient(401 重放)· AuthApi(+guest/upgrade)· URLSessionSyncApi · RealtimeClient
│   ├── Sync/           SyncCoordinator(30s / 场景切换 / 网络恢复)
│   ├── Notifications/  ReminderScheduler(UNUserNotificationCenter + 应用内兜底)
│   ├── DesignSystem/   OrdoColor · OrdoFont · OrdoSpacing · OrdoRadius · OrdoMotion(含 §5.1~§5.4 令牌)
│   ├── Shell/          OrdoShellView · SidebarView · StatusBarView(§5.3 刷新控件)· ShellViewModel
│   │                   · **RefreshControlModel(刷新状态机,可单测)**
│   ├── Lists/          ListScreenView(长按拖拽)· TodoRowView · **LongPressDrag(§5.4 手势 + 状态机)**
│   │                   · CheckboxView · MetaPillView · GroupHeaderView · AgendaSectionView · SwipeActions
│   ├── Detail/         TodoDetailView(+ 全屏 TodoDetailScreen)
│   ├── Schedule/       ScheduleSheet(排期 + 提醒,含 NLP 输入)
│   ├── Search/         FastFindView(快找)
│   ├── QuickAdd/       QuickAddButton(§5.2 单一快加号 + 长按 400ms 菜单)
│   ├── Settings/       SettingsView(当前账号 + 退出登录 + 游客升级)
│   ├── Common/         EmptyStateView · OrdoToast · ProgressRingView · MarkdownNoteView
│   ├── Intents/        OrdoAppIntents(App Intents / 快捷指令,按当前账号目录落库)
│   └── Resources/      Assets.xcassets(AccentColor 与设计令牌一致)
└── OrdoTests/          OrdoTestSupport · NlpParsingTests · QueryRulesTests · RepeatEngineTests · SyncMergeTests
                        · **SessionAndGateTests(§7.6)**· **InteractionStateTests(§5.2~§5.4)**
```

---

## 1. 在 macOS 上 5 步跑通(必读)

> **最快的路径:一条命令。** 在 macOS 上(任意目录)执行:
>
> ```bash
> bash apps/ios/tools/mac_onboarding.sh      # 刚拿到的 Mac:环境自检 → 编译
> ```
>
> 它会先自检系统/Xcode 16+/JDK/模拟器机型/wrapper 可执行位,通过后再交给 `verify_ios.sh`:
> ① 探测 `:shared:core` 的 XCFramework 任务名(**不写死任务名**)→ ② 生成 XCFramework
> → ③ `xcodebuild build` → ④ `xcodebuild test` → ⑤ 跑三个自检脚本,最后汇总失败步骤。
> 可选参数:`mac_onboarding.sh --setup-only`(只查环境)、`verify_ios.sh --build-only`(只到构建)、
> `verify_ios.sh --no-tests`(跳过测试)。
>
> 下面的 5 步是它们内部做的事,需要用 Xcode 手工调试时按步执行。

> 命令中的 `<repo>` 一律指仓库根目录(即包含 `gradlew` / `settings.gradle.kts` 的那一层)。
> **仓库已提交 Gradle Wrapper** —— `gradlew`(Unix)/ `gradlew.bat`(Windows),Gradle **8.14**;
> 因此**不需要**再手工 `gradle wrapper`,所有 Gradle 命令都在**仓库根目录**用 `./gradlew` 执行。

**前置条件**

| 项 | 版本 | 说明 |
|---|---|---|
| macOS | 14 Sonoma 或更高 | Kotlin/Native 的 Apple 目标只能在 macOS 上编译(`build.gradle.kts` 里 iOS 目标包在 `if (HostManager.hostIsMac)` 中) |
| Xcode | **16.0+** | Swift 6 语言模式、`@Observable`、SwiftData |
| 模拟器 | iOS **17.0+** | 理由与 iOS 16 回退方案见 §5 已知偏差 1 |
| JDK | 17+ | 构建 KMP 核心(Kotlin 工具链固定 `jvmToolchain(21)`,用 IDE 时会自动下载) |
| Python | 3.9+ | 仅用于重新生成 `project.pbxproj` 与跑自检,可选 |

### 步骤 0:确认部署目标与权限键(30 秒)

- `project.yml` / `project.pbxproj` 的 `IPHONEOS_DEPLOYMENT_TARGET = 17.0`;
- `Config/Info.plist` 里有 `NSCalendarsFullAccessUsageDescription`(iOS 17+ 只读日历)与
  `NSCalendarsUsageDescription`(iOS 16 回退路径),另有 `OrdoNotificationPermissionExplanation`(自定义展示键)。
  日历**只读**:全工程不存在 `EKEventStore.save/remove`,权限也不需要 entitlement。

### 步骤 1:生成 KMP 的 XCFramework

```bash
cd <repo>                       # ← 仓库根目录(有 gradlew 的那一层)
./gradlew :shared:core:assembleXCFramework
```

**任务名以本机探测为准**(KMP 会按 framework 的 `baseName` 生成任务名,不同版本/DSL 写法可能不同):

```bash
cd <repo>
./gradlew :shared:core:tasks --all | grep -i xcframework
```

- 若列表里出现 `assembleOrdoCoreXCFramework`(因为 `baseName = "OrdoCore"`),**优先用它**:
  `./gradlew :shared:core:assembleOrdoCoreXCFramework`;
- 若只出现 `assembleXCFramework`,就用上面那条通用任务(与根 `README.md`、`docs/08` 的写法一致);
- 任务名两者都不在 → 说明 iOS 目标没启用,先确认确实在 macOS 上(`HostManager.hostIsMac`),
  再检查 `shared/core/build.gradle.kts` 的 `iosX64()/iosArm64()/iosSimulatorArm64()` 三个目标是否生效。

产物默认在 `shared/core/build/XCFrameworks/release/OrdoCore.xcframework`。
若路径不同,把绝对路径告诉 `Package.swift`:

```bash
export ORDO_CORE_XCFRAMEWORK=/abs/path/to/OrdoCore.xcframework
```

> ⚠️ 在 Windows/Linux 上这些任务**不存在**(iOS 目标被 `hostIsMac` 关掉),
> 这正是本工程无法在 Windows 编译 Swift 的根本原因。

### 步骤 2:打开工程

```bash
cd <repo>/apps/ios
open Ordo.xcodeproj                        # 方式 A:直接用仓库里的 pbxproj
# 或
xcodegen generate && open Ordo.xcodeproj   # 方式 B:由 project.yml 重新生成
```

工程内置一个 **Run Script 阶段**(`Build KMP OrdoCore framework`),在编译 Swift 之前执行:

```bash
cd "$SRCROOT/../../shared/core" && ./gradlew :shared:core:embedAndSignAppleFrameworkForXcode
```

> 该脚本依赖**仓库根目录的 wrapper**:Gradle 会向父目录查找 `gradlew`,因此从 `shared/core`
> 出发也能定位到根 wrapper;若你的环境报「找不到 gradlew」,把脚本改成
> `cd "$SRCROOT/../.." && ./gradlew :shared:core:embedAndSignAppleFrameworkForXcode` 即可。
>
> 由于 `isStatic = true`(静态 framework),链接即可、无需嵌入。
> 若该任务在你的环境不可用,退路是:把 `OrdoCore.xcframework` 拖进
> **Frameworks, Libraries, and Embedded Content** 并选择 *Embed & Sign*。

### 步骤 3:选择模拟器并运行

```bash
cd <repo>/apps/ios
xcodebuild -project Ordo.xcodeproj -scheme Ordo \
           -destination 'platform=iOS Simulator,name=iPhone 16' build
```

或在 Xcode 中选择 `Ordo` scheme → 任意 iOS 17+ 模拟器 → ⌘R。

### 步骤 4:跑单元测试

```bash
cd <repo>/apps/ios
xcodebuild test -project Ordo.xcodeproj -scheme Ordo \
                -destination 'platform=iOS Simulator,name=iPhone 16'
```

测试覆盖契约 §4 / §5 / §6 / §7.3 / §7.6 与 UI 规范 §5.2~§5.4 的状态机,业务规则部分全部
**通过 `OrdoCoreBridge` 驱动 KMP 核心**(见 §6);会话/门禁/交互状态机部分用纯 Swift 状态机与桩实现驱动。
新增的两个文件:`OrdoTests/SessionAndGateTests.swift`(会话读写与游客标记 / §7.6.4 门禁 / 目录名隔离 /
登录表单)/ `OrdoTests/InteractionStateTests.swift`(长按 400ms 与 6pt 阈值 / 刷新状态机 / §5.1~§5.4 令牌)。

> 模拟器上的「日历」默认是空的,因此 `OrdoEnvironmentAgendaProvider` 会回退示例日程 ——
> 这是**预期行为**(见 §5 已知偏差 4);要看到真实日历,在模拟器里往「日历」App 添加一条今天的日程,
> 并在首次启动时允许日历权限。通知权限同理:拒绝后提醒走应用内横幅(见 §5 已知偏差 8)。

### 步骤 5:重新生成工程 / 自检

```bash
cd <repo>/apps/ios
python3 tools/preflight.py              # 编译前预检(配置/pbxproj/桥接符号/Swift 风险,34 项)
python3 tools/gen_xcodeproj.py          # 生成并校验 pbxproj + scheme
python3 tools/gen_xcodeproj.py --check  # 只校验
python3 tools/check_ios_sources.py      # 交付自检(含与 Kotlin 源码的动态交叉核对)

cd <repo> && python3 tools/check-encoding.py   # 确认没有「乱码但能编译」的中文损坏
```

> ⚠️ **新增/删除 `.swift` 文件后必须重跑 `gen_xcodeproj.py`**,否则新文件不会进入编译目标
> (生成器按文件路径派生稳定 ID,重复生成不产生无意义 diff;`preflight.py` 会顺带核对
> 「每个 .swift 都已纳入工程」)。
>
> ⚠️ **不要**用 Windows PowerShell 5.1 的 `Get-Content -Raw` + `Set-Content -Encoding UTF8`
> 改写含中文的源码:它会把 UTF-8 当 GBK 往返,中文变乱码而**照样编译通过**。
> 改完统一跑 `python tools/check-encoding.py`(在仓库根目录)。

### 步骤 6(可选):让 CI 替你在 macOS 上编译

仓库已有 `.github/workflows/ci.yml`,其中 `ios` job 正是 `macos-14` runner 上的
「生成 XCFramework → `xcodebuild build`」,但**默认关闭**(带 `if: vars.ENABLE_IOS_CI == 'true'`)。

把它打开即可获得真实编译反馈(无需自备 Mac):

1. 推到 GitHub(仓库 → `main` 分支);
2. 仓库 **Settings → Secrets and variables → Actions → Variables** 新建变量
   `ENABLE_IOS_CI = true`;
3. 之后每次 push / PR 都会在 macOS runner 上真实编译 iOS 工程,日志直接指出首个编译错误。

> 注意:该 job 用的是通用任务名 `assembleXCFramework`;若你的 KMP 版本只注册了
> `assembleOrdoCoreXCFramework`,把它改成 `bash apps/ios/tools/verify_ios.sh --build-only`
> 更稳妥(脚本会自己探测任务名)。
> **已备好修正版 job**:`tools/ci-ios-job.yml`,可直接替换根 `ci.yml` 的 `ios:` 段
> (修掉了任务名硬编码与模拟器机型硬编码两处风险)。




---

## 2. 桥接层设计(Kotlin → Swift)

`Ordo/Core/OrdoCoreBridge.swift` 是**全工程唯一引用 KMP 符号的文件**(连同 `OrdoCoreMapping.swift` 的类型映射)。
其余 Swift 代码只依赖纯 Swift 协议(`OrdoEngineProtocol` / `OrdoStorageProtocol` / `OrdoSyncAPI` / `OrdoAuthAPI`)。

### 2.1 与真实 Kotlin 源码的核对结论

| # | Kotlin 事实(`shared/core/**`) | Swift 处理 |
|---|---|---|
| 1 | `binaries.framework { baseName = "OrdoCore"; isStatic = true }` | `import OrdoCore` |
| 2 | `OrdoEngine(storage, clock, uuid: () -> String, deviceId: String)` | Kotlin 默认参数不导出到 ObjC → Swift 侧**传满四个参数**(`OrdoCoreBridge.make(...)`) |
| 3 | `subscribe(listener): () -> Unit` | 返回的取消函数包装为 `OrdoCoreCancellable` |
| 4 | `updateTodo(id, mutate: (Todo) -> Todo)` | Swift 面 `(inout OrdoTodo) -> Void`,桥内「取值 → 跑闭包 → 回写成新 Kotlin 对象」 |
| 5 | `createTodo(title, opts: TodoOptions): Todo`,**非空**;`TodoOptions` 无 reminder/deadline | `OrdoTodoOptions` 与之逐字段一致;提醒改由标题的时间片段解析,截止用 `setDeadline` |
| 6 | 枚举取值是 `INBOX/OPEN/DAILY/FIXED/UPSERT…` 且都带 `wire` | 统一 `X.companion.fromWire(...)` / `value.wire` 互转,不依赖 ObjC 枚举导出名 |
| 7 | `ListQuery` 是 **sealed class**(`Inbox` 为 object,`ProjectScope(id)` 为 data class) | 桥内 switch 到具体子类(非 `(kind,id,text)` 结构体) |
| 8 | `OrdoSnapshot.headings` 是**扁平列表**,Project 内**不含** headings | Swift 面按契约 §2.2 回填成嵌套形状;wire JSON 仍输出扁平 + 项目内冗余(核心 `ignoreUnknownKeys=true` 会忽略) |
| 9 | `ListSection(title, subtitle, kind, todos, headingId)`;无 id/date/collapsed | Swift 侧合成稳定 id(优先 `headingId`,否则 `kind:title`) |
| 10 | `SidebarCounts(inbox…logbook, projects, projectProgress, tags)`;**没有区域计数** | `OrdoSidebarCounts` 同步调整;侧栏区域行不再显示数字(避免在 Swift 侧重实现区域查询) |
| 11 | `OrdoStorage` 的 9 个方法是**同步**的(非 suspend) | `OrdoCoreStorageMirror`:同步内存镜像 + 异步写回 SwiftData(见 §2.3) |
| 12 | `Op.payload: JsonElement?`(kotlinx.serialization) | 不尝试从 Swift 构造 `JsonElement`,op/tombstone/snapshot 一律走 `OpCodec` 的 **JSON 文本**通道 |
| 13 | `NaturalDateParser.parse(input, today, nowTime): NlpResult` | `OrdoCoreNaturalLanguageParser`(object → `.shared`) |
| 14 | `OrdoClock { fun nowMillis(): Long }`(与 Swift 标准库 `Clock` 同名) | 模块限定名 `OrdoCore.OrdoClock` + `OrdoCoreClockAdapter` |
| 15 | `OrdoEngine` 构造参数 **4 个**(`storage` / `clock` / `uuid` / `deviceId`)| 全部可见:`OrdoCoreBridge.make(storage:clock:uuid:deviceId:)` 传满 |
| 16 | `OrdoEngine` 公开属性 **2 个**(`snapshot` / `schemaVersion`),`deviceId` 是构造参数 | `OrdoEngineProtocol` 用 `var snapshot` / `var schemaVersion` / `var deviceId` 声明 |
| 17 | `OrdoEngine` 公开方法 **59 个** | 全部映射到 `OrdoEngineProtocol` + `OrdoCoreBridge`(自检脚本动态断言 0 缺失) |
| 18 | `OrdoEngine.reorderTodos(ids: List<String>)` 把**下标直接写成 `order`**;`order` 以 `(when, projectId, headingId)` 为作用域 | 桥接层原样透传;iOS 侧提交「同容器完整序列」,并在 `AppEnvironment.reorderTodos` 里拒绝跨容器提交(见 §3.3) |
| 19 | 契约 §7.3.6:远端**空标题 upsert** 与本地 `setTitle(id, "")` 都走删除(写墓碑 + `deleted=true`) | 桥接层**不做补偿**,原样调用;`OrdoTests/SyncMergeTests` 直接断言该行为(4 条用例) |

**仍然存在的少量不确定项**(仅影响个别成员命名,不影响结构):ObjC 导出后
`ListQuery.Inbox.shared` 这类嵌套 object 的访问形式、以及 data class 初始化器的标签拼写。
若 Xcode 报「找不到成员」,按报错提示微调 **`OrdoCoreBridge.swift` / `OrdoCoreMapping.swift` 两个文件**即可,
其余代码不受影响(完整清单见 §5「首次编译风险清单」)。

### 2.2 类型映射

| Kotlin | Swift | 备注 |
|---|---|---|
| `Area/Project/Heading/Todo/ChecklistItem/Tag/RepeatRule` | `OrdoArea/OrdoProject/…` | 字段名与契约 §2 一致 |
| `Area.color: String?` | `OrdoArea.color: String` | 空值回落到 `OrdoPalette.defaultAreaColor` |
| `When/Status/RepeatFreq/RepeatMode/EntityType/OpType` | `OrdoWhen/OrdoStatus/…` | 按 `wire` 字符串映射 |
| `SectionKind` | `OrdoSectionKind` | 显式 switch(含 `PLAIN_TODAY → .plainToday`);`.agenda` 是 iOS 本地只读日程 |
| `OrdoSnapshot/ListQuery/ListSection/SidebarCounts` | `OrdoSnapshot/OrdoListQuery/OrdoListSection/OrdoSidebarCounts` | 名称遮蔽时用模块限定名 `OrdoCore.X` |
| `Op/Tombstone` | `OrdoOp/OrdoTombstone` | JSON 文本通道(`OpCodec`) |
| `Long/Int/Int?` | `Int64/Int32→Int/KotlinLong?` | 显式转换 |
| `Map<String, Int>` | `[String: Int]` | 通过 `KotlinInt.int32Value` 解包 |

### 2.3 存储:同步镜像 + 异步写回

Kotlin 的 `OrdoStorage` 是**同步接口**(引擎构造时直接 `loadSnapshot()`/`loadOutbox()`/`loadTombstones()`),
而 iOS 的持久层是 SwiftData 的 `@ModelActor`(async)。因此桥接层插入一层
`OrdoCoreStorageMirror`:

```
KMP OrdoEngine ──(同步 9 方法)──▶ OrdoCoreStorageMirror ──(async, 串行队列)──▶ SwiftDataStorage
                                        │
                                        └─ 内存镜像:snapshot JSON / outbox JSON / tombstones JSON / kv
```

- **预加载**:`OrdoCoreBridge.make(...)` 先 `await OrdoCoreStorageMirror.preload(from:)` 把
  SwiftData(或内存)里的快照、outbox、墓碑、kv 读进镜像,再构造 Kotlin 引擎;
- **写回**:引擎每次 `saveSnapshot` / `appendOutbox` / `clearOutbox` / `saveTombstones` / `kvSet`
  先更新镜像(同步返回、零阻塞),再由专用串行队列异步写 SwiftData;
- **序列化**:快照与 op 复用 Kotlin `OpCodec`(`encodeSnapshot/decodeSnapshot/encodeOps/decodeOps/encodeTombstones`),
  保证与四端完全一致的 JSON 形状;
- `flushStorage()` 用于等待写回排空(测试与进入后台前调用)。

### 2.4 并发模型

| 层 | 隔离方式 |
|---|---|
| 引擎门面 `OrdoEngineProtocol` | `@MainActor`(与 SwiftUI 同域,写操作后立即刷新快照) |
| 存储镜像 `OrdoCoreStorageMirror` | `@unchecked Sendable` + `NSLock` + 串行 `DispatchQueue` |
| 本地存储 `OrdoStorageProtocol` | `@ModelActor`(`SwiftDataStorage`)/ `actor`(`OrdoMemoryStorage`) |
| 网络 | `actor`(`OrdoHTTPClient` / `URLSessionSyncApi` / `URLSessionAuthApi`) |
| 实时通道 | `actor`(`OrdoRealtimeClient`) |
| 同步协调 | `@MainActor @Observable`(`SyncCoordinator`) |
| 日程(EventKit) | `@MainActor`(`OrdoEventKitAgendaProvider`;`EKEventStore` 非 `Sendable`,放主执行器避免跨 actor 传递) |
| 提醒排期 | `@MainActor`(`ReminderScheduler`) |

### 2.5 系统集成:日历 / 提醒 / 拖拽

#### (1) 只读系统日历(`Data/EventKitAgenda.swift`)

```
EventKit(EKEventStore,只读)──▶ OrdoCalendarEvent ──▶ AppEnvironment.calendarEvents ──▶ AgendaSectionView
        │                              (内存值类型,不进核心/不进 SwiftData)
        └─ 无权限 / 当天无日程 ──▶ OrdoSampleAgendaProvider(示例日程,标题标注「日程 · 示例」)
```

- **注入点**:`OrdoAgendaProviding` 是纯 Swift 协议(不 `import EventKit`),
  `AppEnvironment.agenda` 持有它;默认 `OrdoEnvironmentAgendaProvider`(EventKit → 示例回退),
  预览/测试可用 `OrdoSampleAgendaProvider` / `OrdoEmptyAgendaProvider` 或任意自定义实现替换,**上层无需改动**。
- **权限**:`currentAuthorization()` 先看现状,`notDetermined` 时才弹一次系统面板;
  iOS 17+ 用 `requestFullAccessToEvents()`(需 `NSCalendarsFullAccessUsageDescription`),
  iOS 16 回退 `requestAccess(to: .event)`(需 `NSCalendarsUsageDescription`)——
  两个键都已写进 `Config/Info.plist`。`.writeOnly` 视为**不可读**。
- **只读**:全工程不调用 `EKEventStore.save/remove/commit`,不存在写入路径;
  读到的日程只活在内存里、只查当天窗口,不进 outbox、不进 SwiftData(契约 §2.8 + §9)。
- **被拒时静默回退**:不弹错误、不打断;日程区块顶部标题变成「日程 · 示例」,
  避免用户把示例日程误认为真实日历。

#### (2) 通知被拒 / 前台时的应用内兜底(`Notifications/ReminderScheduler.swift`)

| 场景 | 系统通知 | 应用内兜底 |
|---|---|---|
| 有权限 + App 后台 | ✅ 排期本地通知 / Fastlane 立即投递 | — |
| 有权限 + App **前台** | `willPresent` 会展示,但 Fastlane 路径改为直接走应用内 | ✅ Toast 横幅 + 角标 |
| **无权限**(被拒 / 尚未决定) | ❌ 不排期 | ✅ 到点扫描 → Toast 横幅 + 角标 |

- 兜底入口是 `onInAppReminder` 回调(由 `AppEnvironment` 注入 → 复用现有 `OrdoToast` 机制),
  角标显示在底部状态栏(`StatusBarView`),进入「今天」清单即清零;
- **去重与角标**:kv 表键 `ordo.reminder.fired` 存
  `{"fired":{todoId: 提醒时间点},"lastReadAt":已读时刻}`,同一条待办 + 同一个时间点**只提醒一次**;
  改期后时间点变化 → 允许再次提醒;记录保留 30 天并自动清理,冷启动后仍能防重复;
  角标以 `lastReadAt` 为界计算,因此重开 App 不会把已经看过的提醒再算一遍;
- 权限请求时机:冷启动**只读现状不弹窗**(`refreshAuthorizationOnly()`),
  用户主动点设置页按钮才走 `requestAuthorization()` —— 避免冷启动弹窗打断。

#### (3) 长按拖拽(UI 规范 §5.4,`Lists/LongPressDrag.swift` + `ListScreenView` + `AppEnvironment.reorderTodos`)

- **统一为一件手势**:按下计时 **400ms**;**移动 < 6pt 视为点击**(交给「打开详情」),
  长按到点才「行抬起」(scale 1.02 + 12dp 投影 + 背景转 `surface` + 一次轻微触感);
  已删除原来的 `.onDrag`/`onDrop`(那是与点击并行的第二条路径,与点击互相抢手势);
- **命中测试自己做**:每行用 `ordoRowFrame(id:in:)` 把 frame 汇报到列表坐标空间,
  拖拽中按手指 y 找目标行(行间空隙取最近行),命中行上方画 **2dp 插入线 + 左端 4dp 圆点**;
  被拖行 alpha **0.55**,其余行让位 120ms,列表在拖拽期间 `scrollDisabled`;
- **松手**:位置变了才提交(把该容器内的**完整可见序列**交给核心 `reorderTodos(ids:)`,下标即 `order`),
  行以 160ms spring 回落;**位置未变则不写库**;
- **不与行内控件抢点击**:`simultaneousGesture` 会收到落在复选框 / 排期 / 截止 / 恢复按钮上的触摸,
  因此 `TodoRowView` 把这两块控件的 frame 也上报到同一坐标空间,「点击打开详情」前先用
  `TodoRowView.isControlLocation(_:todoId:frames:)` 排除(否则点复选框会「既完成又展开详情」);
- **取消路径明确**:① `Esc`(`ShellViewModel.cancelActiveDrag()` → 列表消费);
  ② 拖出可视区域上下各 44pt(「拖出窗口」);③ 松手时没有目标行 —— 三者都只回原位、不写库,
  另有 10s 静默兜底复位(手势被系统中断时);
- **只对 `order` 真正生效的视图开放**:收件箱 / 随时 / 某天 / 项目(含标题分区)/ 区域;
  「今天 / 计划 / 日志簿」由日期或完成时间排序(核心不读 `order`),标签视图跨容器聚合 —— 一律不开放拖拽
  (不开放的分区仍保留「点击打开详情」);
- **同一容器**才允许:`order` 在核心中以 `(when, projectId, headingId)` 为作用域连续,
  跨分区拖动会写出互相竞争的 order,因此 `AppEnvironment.reorderTodos` 会拒绝并提示。

**排序持久化的说明(重要)**

1. `order` 是契约 §2.4 的正式字段,由 `reorderTodos` 通过 `persistAndEnqueue` 写进
   **快照 + outbox**:本地立即生效(重启后顺序不变),同时产出一条 `todo` upsert op;
2. 服务端收到 op 后按 LWW 合并(`clientTs` 即本次排序时间),再随 `pull`/WS 下发给其它端;
   因此四端的顺序最终一致,且**排序本身不会丢失**;
3. 冲突语义:并发排序时 `order` 是「后写覆盖」(整数字段没有并集语义),与契约 §7.3.1 的实体级 LWW 一致 ——
   这是明确预期,不做额外补偿;
4. 被拖拽的每条待办都会 `updatedAt = now` 并各产出一条 op;
   契约 §7.4 的限制(单次 push ≤ 500 ops)在小批量排序下不会触及。

### 2.6 登录门禁、会话与「按用户分目录」(契约 §7.6)

```
启动 → OrdoAuthService.restore() 读会话(Application Support/Ordo/session.json)
   ├─ 有且未过期            → 直接进主界面(随后后台静默 refresh)
   ├─ 有但 accessToken 过期 → 先 refresh;失败 → 登录页(只清会话,目录保留)
   └─ 无 / 坏数据           → 登录页:登录 · 注册 · **以游客身份继续**(三入口对等)

有会话 → AppEnvironment.bootstrap(session:) → 打开 Application Support/Ordo/<userDataDirName(userId)>/
                                             的 SwiftData(Ordo.store)→ 装配 KMP 引擎 → 同步
换账号 / 退出登录 → 拆掉当前环境(停同步 + 取消订阅)→ 用新 userId 打开另一个目录
```

| 关注点 | 落地位置 | 说明 |
|---|---|---|
| 会话模型与门禁 | `Core/OrdoSession.swift` | `OrdoSessionRecord`(userId / email? / isGuest / accessToken / refreshToken / expiresAt、`isExpired(nowMillis:)`、`displayName()`)+ `OrdoStartupPlanner`(§7.6.4 纯函数路由) |
| 会话落盘 | `Core/OrdoSessionBridge.swift` | `OrdoCoreSessionStore` 包核心 `OrdoSessionStore`(JSON 形状与清洗规则都在 Kotlin,Swift 只搬值);根目录 `session.json` 由 `OrdoFileKVStorage`(同步写)承载 |
| 目录命名 | `OrdoCoreSessionStore.userDataDirName(_:)` | **直接调核心**(`OrdoSessionStore.companion.userDataDirName`),Swift 侧不复制清洗规则 |
| 令牌宿主 | `OrdoSessionTokenStore` | 令牌只存在会话里(refresh 轮换 = 会话内换令牌);`X-Ordo-Device` 用**设备级** deviceId(根 kv `ordo.deviceId`,与核心 `OrdoEngine.KEY_DEVICE_ID` 同名) |
| 三个入口 | `Auth/OrdoAuthService.swift` + `Auth/LoginView.swift` | 登录 / 注册 / 游客;`AuthApi` 新增 `guest(...)` 与 `upgrade(accessToken:_:)`;游客升级后 **userId 与数据不变**,只补邮箱口令 |
| UI(§5.1) | `Auth/LoginView.swift` + `Auth/LoginModel.swift` | 卡片宽 400 · radius 16 · 浮动标签(聚焦上移 12px 转 accent)· 口令显隐 · 提交中 16dp 转圈并禁用全部入口 · 错误区固定 20 高 + 6px/320ms 衰减抖动 · 进入 fade + 上移 12px 220ms |
| 退出登录 | `AppEnvironment.signOut()` | 只清会话(契约 §7.6.3),**不删**该 userId 的目录;设置页显示当前账号、账号类型、userId 与数据目录名,便于核对「两个账号是否共用目录」 |
| 令牌失效 | `SyncCoordinator.onAuthExpired` → `AppEnvironment.handleAuthExpired()` | 401 且 refresh 失败 → 清会话回登录页(登录页给出「登录已过期,请重新登录」),目录同样保留 |
| App Intents | `Intents/OrdoAppIntents.swift` | 写入器按**当前会话**打开对应账号目录,避免「Siri 记的一条落到别的目录」 |

> 会话为什么放在根目录而不是 `userId` 子目录:启动时必须**先读会话才知道 userId**,
> 放在子目录会形成死循环;根目录只放**设备级**数据(会话 + deviceId),
> 任何实体数据都只落在 `<userId>/` 里,因此不存在「两个账号共用一份数据」的路径。

---

## 3. 已实现的功能对照

| 规范要求 | 实现位置 | 状态 |
|---|---|---|
| **登录门禁:启动必须先登录(登录 / 注册 / 游客三入口)** | `Auth/OrdoAuthService.swift` + `Auth/LoginView.swift` + `Core/OrdoSession.swift` | ✅(契约 §7.6.4,未编译验证) |
| **登录页 §5.1(400 宽卡片 / 浮动标签 / 口令显隐 / 转圈 / 抖动 / 进入动效)** | `Auth/LoginView.swift` + `Auth/LoginModel.swift` | ✅(未编译验证) |
| **本地数据按 userId 隔离(`Application Support/<userId>/`)** | `Core/OrdoSessionBridge.swift`(`OrdoAppDirectories`)+ `Data/SwiftDataStorage.makeUserContainer(userId:)` | ✅(契约 §7.6.3 硬约束) |
| **设置页:当前账号 + 退出登录(只清会话)+ 游客升级** | `Settings/SettingsView.swift` + `AppEnvironment.signOut()` | ✅ |
| 三栏骨架(侧栏 248 + 列表 + 内联详情) | `Shell/OrdoShellView.swift` | ✅ |
| iPhone 抽屉侧栏 + 全屏详情 | `Shell/OrdoShellView.swift`(`compactLayout`) | ✅ |
| 大标题 28/34 + 计数 + 工具按钮 | `Lists/ListScreenView.swift` | ✅ |
| 今日日程只读区块 | `Lists/AgendaSectionView.swift` + `Data/EventKitAgenda.swift` | ✅ 已接 EventKit(只读) |
| 待办行 38pt + 圆形复选框 + 完成动效(0/80/160/240/700/900ms) | `Lists/TodoRowView.swift`、`Lists/CheckboxView.swift` | ✅ |
| 元信息 pill(提醒铃铛 / 逾期珊瑚红 / 清单 2/5) | `Lists/MetaPillView.swift` | ✅ |
| 今晚分区(琥珀色) | `Lists/GroupHeaderView.swift` + `OrdoColor.tonight` | ✅ |
| 详情卡片(标题 / Markdown 备注 / 何时 / 截止 / 提醒 / 重复 / 移动 / 标签 / 清单) | `Detail/TodoDetailView.swift` | ✅ |
| 排期面板(宽 280 + NLP 预览 + 月历 + 危险色清除 + 提醒) | `Schedule/ScheduleSheet.swift` | ✅ |
| 快找(输入 44 / 结果 36 / 高亮 / ↑↓ Enter Esc) | `Search/FastFindView.swift` | ✅ |
| 快加号(§5.2:直径 **56** 单一按钮 + 长按 400ms 菜单 + 展开旋转 45°,已删除独立箭头/系统 contextMenu) | `QuickAdd/QuickAddButton.swift` | ✅(未编译验证) |
| 刷新控件(§5.3:图标连续旋转 900ms/圈 + 已同步 / 同步失败,点击重试 + 1.4s 防抖) | `Shell/StatusBarView.swift` + `Shell/RefreshControlModel.swift` | ✅(未编译验证) |
| 空状态 / 错误态 / 离线态 | `Common/EmptyStateView.swift` + `StatusBarView` | ✅ |
| 深色模式(浅深两套令牌 + 跟随系统) | `DesignSystem/OrdoColor.swift` + 设置页 | ✅ |
| 键盘(⌘N / **⌘R** / ⌘K / 1…6 / ↑↓ / Enter / Space / ⌫ / ⌘⇧D / Esc) | `OrdoShellView.keyboardShortcuts` + `ordoKeyCapture` | ✅ |
| 手势(右滑完成 / 左滑删除) | `Lists/SwipeActions.swift` | ✅ |
| 手势(§5.4 长按 400ms 拖拽排序 → 核心 `reorderTodos`) | `Lists/LongPressDrag.swift` + `Lists/ListScreenView.swift` | ✅(未编译验证) |
| 无障碍(≥44 触控、可读标签、不靠颜色传达状态、Dynamic Type、减弱动效) | 各组件 + `OrdoMotion.resolved(_:reduceMotion:)` | ✅ |
| 本地存储(SwiftData,字段名与契约一致 + outbox/tombstones/kv) | `Data/SwiftDataStorage.swift` | ✅ |
| 同步(30s / 场景切换 / 网络恢复 / WS 退避重连 / 401 重放) | `Sync/SyncCoordinator.swift`、`Net/*` | ✅ |
| 提醒(本地通知 + Fastlane 立即投递 + 到点打开待办) | `Notifications/ReminderScheduler.swift` | ✅ |
| 提醒兜底(无权限 / 前台 → 应用内横幅 + 角标 + 已触发记录去重) | `Notifications/ReminderScheduler.swift` + `Shell/StatusBarView.swift` | ✅ |
| App Intents(新建待办 / 打开清单 / 完成待办) | `Intents/OrdoAppIntents.swift` | ✅ |
| 深链 `ordo://`(+ Universal Links 解析兜底) | `App/DeepLink.swift` | ✅ |
| 单元测试(契约 §4/§5/§6/§7.3 + §7.6 会话/门禁 + §5.2~§5.4 交互状态机) | `OrdoTests/` 7 个文件 | ✅(需 XCFramework 后方可编译运行;本机无 macOS,**未运行**) |

---

## 4. 数据流(一次「勾选完成」的旅程)

1. 用户点复选框 → `TodoRowView` 先登记「保留行」,再在 80ms 处调用 `environment.toggleDone(id:)`;
2. `AppEnvironment` → `OrdoCoreBridge.toggleDone` → Kotlin 引擎:
   改内存快照 → `storage.saveSnapshot`(写进镜像)**→ 产出 op 进 outbox → 通知订阅者**;
3. 引擎的 subscribe 回调把新快照投递到主线程 → `AppEnvironment.snapshot` 更新 → SwiftUI 重绘;
4. 写回队列把镜像里的快照 JSON 解码成 `OrdoRemoteSnapshot` 并 `upsert` 到 SwiftData;
5. `SyncCoordinator` 在下一个同步周期(或实时通道事件)把 outbox 里的 op 推给服务端,
   服务端返回 `accepted[]` → `engine.ackOps(accepted)` 清理 outbox。

---

## 5. 已知偏差、限制与首次编译风险

### 5.1 已知偏差

| # | 项 | 说明 |
|---|---|---|
| 1 | **部署目标 iOS 17.0** | 契约 §7 平台映射表写「iOS 16+」,但 SwiftData 与 `@Observable` 需要 iOS 17。**回退 iOS 16 的方案**:把 `Data/SwiftDataStorage.swift` 换成 JSON/SQLite 仓储(实现同一个 `OrdoStorageProtocol`),`IPHONEOS_DEPLOYMENT_TARGET` 改 `16.0`,`@Observable` 换成 `ObservableObject` + `@Published`(或把 `@Observable` 的用法限定在 iOS 17+ 分支);上层与 KMP 桥接层**无需改动**。另外 iOS 16 需要 `NSCalendarsUsageDescription` 走旧 API,该键已就位。 |
| 2 | **未编译验证** | 本工程在 Windows 上编写,没有 macOS/Xcode,因此**未经编译**。已做的静态检查见 §6;真实编译需在 macOS 上执行 §1 的步骤。 |
| 3 | 契约 §7.3.6「标题为空视为删除」 | **已由核心补齐**:远端空标题 upsert 与本地 `setTitle(id, "")` 都写墓碑并置 `deleted`。iOS 侧不做补偿,已在 `SyncMergeTests` 加 4 条断言(空标题 / 纯空白 / 本地清空 / 墓碑防复活)。 |
| 4 | 日历回退时展示示例数据 | 契约 §2.8 的 `CalendarEvent` 只读、本地、不同步。模拟器默认没有日历数据,因此首次启动通常看到的是示例日程,标题会标注「日程 · 示例」;有系统日历权限且当天有日程时自动切换为真实数据。 |
| 5 | 拖拽排序仅限同容器 | 核心的 `order` 以 `(when, projectId, headingId)` 为作用域;「今天 / 计划 / 日志簿 / 标签」不读 `order`,因此不开放拖拽(见 §2.5)。 |
| 6 | 项目内「拖到左边距建标题」未实现 | 快加号菜单提供「新建标题」等价入口。 |
| 7 | 服务端地址默认 `http://127.0.0.1:8787` | 本地开发用;生产需替换为 HTTPS 域名并移除 Info.plist 的 ATS 例外。 |
| 8 | 通知权限被拒时的体验 | 不再是「只在设置页提示」:提醒降级为**应用内横幅 + 状态栏角标**,并用 `ordo.reminder.fired` 记录去重(见 §2.5)。设置页仍会说明如何在系统中重新开启。 |
| 9 | 应用内兜底的触发时机 | 无权限时的到点扫描发生在 `reschedule(snapshot:)`(每次数据变化 / 回到前台都会调用)。若 App 长时间被系统挂起,**不会**有后台任务主动弹出应用内横幅 —— 回到前台的第一次 `reschedule` 会补一次(仍受去重记录约束)。 |
| 10 | 拖拽状态的兜底复位 | 手势力图统一为「长按 400ms 后拖动」,取消路径有:`Esc`(shell 转发)、拖出可视区域上下各 44pt、松手无目标行;另有 **10 秒静默兜底复位**(手势被系统中断时不会有 `onEnded`)。若真机上出现「行停在抬起态」,优先检查 `onChange(of: draggingTodoId)` 的兜底是否被 scenePhase 打断。 |
| 11 | 会话文件的位置 | 契约 §7.6.1 写会话存于 `kv["ordo.session"]`。iOS 侧把它放在**根目录**的 `Application Support/Ordo/session.json`(由 `OrdoFileKVStorage` 这个「只承载 kv」的 `OrdoStorage` 实现承载,键名仍取核心 `OrdoSessionStore.KEY_SESSION`)。原因:启动时必须先读会话才知道 userId,放进入 userId 子目录就是死循环;实体数据仍严格按 `userId` 分目录。 |
| 12 | 自定义长按手势与列表滚动 | 规范 §5.4 要求「长按 400ms 才拖动」,系统 `.onDrag` 无法满足(它同时带来预览与另一套长按判定)。现改为 `DragGesture(minimumDistance: 0)` + `simultaneousGesture`(保证列表照常滚动)+ 拖拽期间 `scrollDisabled`。这组搭配**必须在真机上确认手感**:若出现「拖拽时列表同时滚动」或「点击被吞掉」,把 `simultaneousGesture` 换成 `highPriorityGesture`(前者优先保滚动,后者优先保拖拽)。 |

### 5.2 首次编译风险清单(预计集中报错的地方)

> 全部属于「命名 / 隔离标注」层面,不涉及结构或业务逻辑;按报错提示逐个改即可。
> **修改范围应尽量收敛在 `Ordo/Core/OrdoCoreBridge.swift` 与 `Ordo/Core/OrdoCoreMapping.swift` 两个文件。**

| # | 风险点 | 具体症状 | 应对 |
|---|---|---|---|
| 1 | **ObjC 导出的成员名** | `ListQuery.Inbox.shared`、`OpCodec.shared`、`NaturalDateParser.shared`、`When.companion.fromWire(value:)`、`KotlinLong(long:)`、`KotlinInt.int32Value`、`value.``when`` `(Kotlin 关键字属性导出为 `when`)等写法与实际导出名不符 → 「has no member」 | 用 Xcode 的「Jump to Definition」看 `OrdoCore.swiftinterface` 里的真实名字,改 `OrdoCoreMapping.swift` 的调用点。**这是最可能报错的一类。** |
| 2 | **Kotlin data class 初始化器标签** | Kotlin 默认参数不导出到 ObjC/Swift,构造 `Todo(...)` / `Project(...)` / `TodoOptions(...)` 时必须**按声明顺序传满全部参数**;少传或多传都会报「missing argument」 | 对照 `shared/core/**/model/Entities.kt` 与 `store/OrdoEngine.kt` 的参数顺序,补/删参数。 |
| 3 | **`subscribe` 的返回类型** | Kotlin `() -> Unit` 导出为 `() -> Void`,Swift 侧 `OrdoCoreCancellable` 包装;若导出成 `KotlinUnit` 闭包会报类型不匹配 | 按报错调整 `installCoreSubscriptionIfNeeded()` 的闭包签名。 |
| 4 | **SwiftData 的 `repeat` 反引号** | `@Model` 类里字段名 `repeat` 是 Swift 关键字,**必须**写 `` var `repeat`: ... ``;若某处漏掉反引号(例如 `#Predicate` 宏里、生成的 `CodingKeys` 里)会报「expected identifier」。`SwiftDataStorage.swift` 与 `OrdoModel.swift` 都用到该写法。 | 统一保留反引号;`#Predicate` 里若无法使用关键字字段,改成先取全量再在内存中过滤。 |
| 5 | **SwiftData 不支持 `[Codable]` 数组** | `tags: [String]` 可以,但 `checklist: [OrdoChecklistItem]` / `headings: [OrdoHeading]` 这类**自定义 Codable 结构数组**不是 SwiftData 原生支持的类型 → 运行期 `SwiftDataError` 或编译期宏展开失败 | 退路:把这类字段以 JSON `String`/`Data` 存储(加 computed property 做编解码),或声明为 `@Attribute(.transformable)`;`OrdoModel` 已把它们定义为纯值类型,替换成本低。 |
| 6 | **`@ModelActor` 与 Sendable** | Swift 6 严格并发下,`@ModelActor` 生成的 `modelExecutor` / `ModelContainer` 跨 actor 传递可能报「non-Sendable」 | 保持 `SwiftDataStorage` 只在自己的 actor 内访问 `ModelContext`;对外只暴露 `OrdoStorageProtocol` 的值类型方法(现状已如此)。 |
| 7 | **App Intents 的隔离检查** | `AppIntent` / `AppEntity` 在 Swift 6 下要求 `@MainActor` 或显式 `nonisolated`;`OrdoAppIntents.swift` 里对 `AppEnvironment` 的访问可能报「main actor-isolated ... cannot be referenced from a nonisolated context」 | 给 Intent 的 `perform()` 标注 `@MainActor`,或把需要的值先取出来再跨隔离使用。 |
| 8 | **`UNUserNotificationCenter` 代理回调的隔离** | `didReceive` / `willPresent` 不是主线程隔离的,直接触碰 `AppEnvironment`(MainActor)会报错 | 现状已在回调里显式 `await MainActor.run`,并让代理类不标注 `@MainActor`;若仍报错,把闭包体整体包进 `Task { @MainActor in ... }`。 |
| 9 | **`EKEventStore` 的并发** | `EKEventStore` / `EKEvent` 非 `Sendable` | 现状把提供者整体放在 `@MainActor`(`OrdoEventKitAgendaProvider`),不要试图改成 `nonisolated`,否则会连锁报错。 |
| 10 | **会话桥接的 ObjC 导出名** | `OrdoSessionStore.companion.KEY_SESSION`、`OrdoSessionStore.companion.userDataDirName(userId:)`、`OrdoSession(userId:email:isGuest:accessToken:refreshToken:expiresAt:)` 与 `OrdoSessionStore(storage:)` 的导出名若与预期不符 → 「has no member / missing argument」 | 只改 `Ordo/Core/OrdoSessionBridge.swift`(会话键名与目录名都从这里出去);若 `KEY_SESSION` 访问不到,退路是照抄核心常量值 `"ordo.session"` 并在 `OrdoCoreSessionStoreTests.testSessionKeyMatchesContract` 里锁死。 |
| 11 | **`ModelConfiguration(schema:url:)`** | `Data/SwiftDataStorage.makeContainer(directory:)` 用 URL 版初始化器把库放进账号目录;若该初始化器签名不符 → 「extra argument / missing argument 'url'」 | 换成 `ModelConfiguration(schema, url:)` 或先 `setURL`(不同 SDK 版本命名略有差异);协议层不受影响。 |
| 12 | **自定义手势的隔离与并发** | `OrdoLongPressDragModifier` 持有 `@State` 并在 gesture 闭包里改它;`UIImpactFeedbackGenerator` 在 Swift 6 下要求主执行器 | 现状:modifier 的方法都在 `@MainActor` 上下文(视图 body 触发),`OrdoHaptics.lift()` 显式 `@MainActor`;若报「capture of non-Sendable」,把 `OrdoHaptics` 的调用改成 `Task { @MainActor in ... }`。 |
| 13 | **`onChange` 双参数形式** | §5.1~§5.4 的动效大量使用 iOS 17 的双参数 `onChange(of:) { _, new in }` | 部署目标 17.0 已满足;若回退 iOS 16 需改回单参数形式(该提示已由 `preflight.py` 报出)。 |
| 14 | **EventKit 的 API 版本** | `store.events(matching:)` 在 iOS 17 是 **async** 版本,旧签名 `store.events(matching:)`(同步)已被弃用 → 若按旧签名写会报「call can throw but is not marked with try」 | 现状用 `try await store.events(matching: predicate)`;若要兼容 iOS 16,这里需要 `if #available(iOS 17.0, *)` 分支回退到同步版本。`EKEventStore.authorizationStatus(for:)` 仍是同步静态方法(会有弃用警告,非错误)。 |
| 15 | **静态 framework 与模块名** | `import OrdoCore` 找不到模块 | 检查 `FRAMEWORK_SEARCH_PATHS` 是否指到 `xcode-frameworks/$(CONFIGURATION)/$(SDK_NAME)`,以及 `-framework OrdoCore` 是否在 `OTHER_LDFLAGS`。 |
| 16 | **签名 / 团队** | 真机运行需要 `DEVELOPMENT_TEAM` | 在 Xcode 里选自己的 Team;`project.yml` 里的 `DEVELOPMENT_TEAM` 故意留空以便任何人克隆后即可编译(模拟器不需要)。 |
| 17 | **`xcodebuild` 的模拟器名** | `iPhone 16` 在本机不存在时报「Unable to find a device matching the provided destination」 | `verify_ios.sh` 会从 `xcrun simctl list devices available` 自动挑一个可用的 iPhone;手工执行时先 `xcrun simctl list devices available` 确认。 |

---

## 6. 交付自检与验证证据(可复现)

Windows 上没有编译能力,因此交付前跑的是**结构化自检 + 编译前预检 + 与 Kotlin 源码的动态交叉核对**;
能编译的共享核心则**真跑**了一遍编译与单元测试。

### 6.1 Windows 侧(本机实跑)

```bash
# ① 共享核心:真编译 + 55 个单元测试(iOS 桥接层消费的就是这份契约)
cd <repo> && ./gradlew :shared:core:jvmTest --rerun-tasks --no-build-cache --console=plain

# ② 契约一致性(核心/后端/Android/iOS/鸿蒙/Windows 六端矩阵)
node tools/contract-check.mjs

# ③ iOS 编译前预检(配置 / pbxproj / 桥接符号 / Swift 风险)
cd apps/ios && python tools/preflight.py

# ④ iOS 交付自检(结构 / 占位符 / 字段 / Kotlin 动态交叉核对 / 写入范围)
python tools/check_ios_sources.py && python tools/gen_xcodeproj.py --check

# ⑤ 编码扫描(仓库根目录;防「乱码仍能编译」)
cd <repo> && python tools/check-encoding.py
```

| 检查 | 结果 |
|---|---|
| **共享核心真编译 + 单测**(`--rerun-tasks --no-build-cache`) | ✅ **BUILD SUCCESSFUL**(核心 69 用例全绿,含 §7.6 会话 8 例;本轮未重跑,数字取自共享核心交付说明) |
| **契约一致性矩阵**(六端) | ✅ 所有适用项通过(iOS:route / api / store / sec / ui 全 ✓) |
| **`preflight.py` 编译前预检** | ✅ 34 项 / 通过 34 / 未通过 0(3 条非阻断提示) |
| 62 个 Swift 文件、17248 行:剥离注释/字符串后的 `()`/`[]`/`{}` 配平 | ✅ 0 问题 |
| 禁止占位(`fatalError("TODO")` / `TODO` / `FIXME`) | ✅ 0 处 |
| 冻结 API 下限护栏(65 项,防止核心 API 被静默削减) | ✅ 缺失 0 |
| 契约 §2 字段覆盖(70 个字段:Area/Project/Heading/Todo/ChecklistItem/Tag/RepeatRule/Op/Tombstone) | ✅ 缺失 0 |
| 契约枚举取值(15 个:When/Status/RepeatFreq/RepeatMode) | ✅ 缺失 0 |
| **与 `OrdoEngine.kt` 动态交叉核对**:构造参数 4 / 公开方法 59 / 公开属性 2 | ✅ 未覆盖 0 |
| **与 `OrdoStorage.kt` 交叉核对**:9 个接口方法在 `OrdoCoreStorageMirror` 均有实现 | ✅ 缺失 0 |
| `project.pbxproj`:括号配平、ID 唯一、引用完整、55+7 个 Swift 文件全部纳入编译目标 | ✅ 通过 |
| 写入范围:全部文件位于 `apps/ios/**` | ✅ 通过 |
| 外部网络依赖(CDN/第三方 URL) | ✅ 无 |
| 编码扫描 | ✅ `OK: no encoding problems found`(478 个文本文件) |

`preflight.py` 覆盖的具体项(34 项):`Info.plist` 可解析性与
`NSCalendarsFullAccessUsageDescription` / `NSCalendarsUsageDescription` / `ordo://` scheme /
ATS 本地例外 / 通知说明键;`Ordo.entitlements` 的 `aps-environment` 与 `associated-domains`
且未误加日历权限;`project.yml` 与 `pbxproj` 的部署目标/Info.plist/entitlements 指向一致;
每个 `.swift` 都已进入工程;**`OrdoEngineProtocol` 的 59 个方法在 `OrdoCoreBridge` 全部实现**、
全工程 40 个 `engine.xxx(` 调用点(去重后)都在协议内;`repeat` 反引号;第三方 URL 扫描。

它给出的 3 条非阻断提示(留给 macOS 首次运行确认):
1. SwiftData 里 `[OrdoChecklistItem]` / `[OrdoHeading]` 属**自定义 Codable 结构数组**,
   是 SwiftData 的易碎点 → 请在 macOS 上跑一次落库往返测试(见 §5.2 第 5 条);
2. 6 处 `onChange` 用了 iOS 17 的双参数形式(部署目标 17.0 已满足;若回退 iOS 16 需改回单参数);
3. 新增/删除 `.swift` 后需重跑 `gen_xcodeproj.py`。

### 6.2 macOS 侧(待执行,一条命令)

```bash
bash apps/ios/tools/verify_ios.sh          # 探测任务名 → XCFramework → build → test → 自检
```

**尚未执行过** —— 本机没有 macOS(`swiftc` / `xcodebuild` 均不存在,
`:shared:core` 在 Windows 上不注册任何 `*XCFramework` 任务)。执行结果请回填到本节。

> ⚠️ Windows 侧的检查**不能替代编译**:Swift 类型检查、SwiftData 宏展开、ObjC 导出的具体成员名、
> App Intents 的隔离标注,都必须在 Xcode 里最终确认 —— 逐条风险见 §5.2。

---

## 7. 与 Web 原型的差异(有意为之)

| 项 | Web 原型 | iOS 端 |
|---|---|---|
| 业务规则位置 | `app.js` 内自实现 | KMP `shared/core`(契约唯一实现) |
| 命名 | Things 语义 | Ordo 命名:快加号 / 排期面板 / 快找 / 今晚 / Ordo Sync |
| 配色 | `#0A84FF` 蓝 | `#5B5BD6` 靛紫(04 文档 §2.1) |
| 存储 | localStorage | SwiftData + outbox/tombstones/kv |
| 同步 | 无 | HTTP 增量 + WebSocket 实时 + Fastlane 提醒 |
| 示例数据 | `app.js` 内置 | KMP 核心 `seedDemoData()`(四端一致) |

---

## 8. 术语对照(契约 §1)

| 中文 | 字段 / 英文 | iOS 类型 |
|---|---|---|
| 区域 | Area | `OrdoArea` |
| 项目 | Project | `OrdoProject` |
| 标题 | Heading | `OrdoHeading` |
| 待办 | Todo | `OrdoTodo` |
| 清单项 | ChecklistItem | `OrdoChecklistItem` |
| 标签 | Tag | `OrdoTag` |
| 何时 | `when` | `OrdoWhen` |
| 截止 | `deadline` | `String?`(`YYYY-MM-DD`) |
| 提醒 | `reminder` | `String?`(`YYYY-MM-DDTHH:mm`) |
| 日志簿 | Logbook | 派生视图(`OrdoListKind.logbook`) |

---

**变更记录**

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-10-08 | 首次交付:iOS 17+ 工程骨架、KMP 桥接层、三栏/抽屉 UI、SwiftData 存储、HTTP+WS 同步、提醒、App Intents、契约测试 |
| 1.0.1 | 2026-10-09 | 桥接层按 `shared/core` 真实源码校正:枚举 `wire`/`fromWire`、sealed `ListQuery`、扁平 headings、同步 `OrdoStorage` + 存储镜像、`OpCodec` JSON 通道、`updateProject/updateHeading`;补充 Kotlin 交叉核对自检 |
| 1.0.2 | 2026-10-09 | ① 自检脚本改为**动态**提取 Kotlin 的构造参数/方法/属性(不再依赖手写清单),并复核 `OrdoEngine` 59 方法 0 缺失;② 契约 §7.3.6(空标题视为删除)已在核心补全,新增 4 条断言;③ 接入 EventKit 只读日历(`Data/EventKitAgenda.swift`,含权限键与静默回退、注入点);④ 通知被拒/前台时降级为应用内横幅 + 角标,并用 `ordo.reminder.fired` 记录去重;⑤ 列表拖拽排序接入核心 `reorderTodos(ids:)`(限同容器,含持久化说明);⑥ README 补齐 macOS 5 步命令、XCFramework 任务名探测、iOS 17 理由与 iOS 16 回退、SwiftData `repeat` 反引号与 `[Codable]` 数组风险清单 |
| 1.0.3 | 2026-10-09 | ① 新增 `tools/verify_ios.sh`:macOS 上一条命令跑通(自动探测 XCFramework 任务名 → 生成 → build → test → 三个自检脚本),带平台守卫与失败汇总;② 新增 `tools/preflight.py`:编译前预检 34 项(配置解析 / entitlements / project.yml 与 pbxproj 一致 / 49+5 个 Swift 文件全部入工程 / 协议 59 方法全实现 / 39 个 engine 调用点在协议内 / `repeat` 反引号 / 第三方 URL),任意平台可跑;③ README 记录**实测**的环境阻塞证据(`gradlew :shared:core:tasks` 中 `*XCFramework` 0 命中、9 个 Apple 专属模块不可用)、共享核心真编译 + 55 单测通过、契约矩阵六端通过,并补充 CI 开启 macOS 编译的步骤 |
| 1.1.0 | 2026-10-10 | 客户试用后的四项要求(契约 v1.2 §7.6 + UI 规范 v1.1 §5.1~§5.4):① **登录门禁 + 游客登录**——`Auth/OrdoAuthService`、`Auth/LoginView`(§5.1 全量:400 宽卡片/浮动标签/口令显隐/提交转圈/错误抖动/进入动效)、`Core/OrdoSession`(会话模型 + §7.6.4 启动路由)、`AuthApi` 新增 `guest`/`upgrade` 与 `UserDto.isGuest`(Swift 侧 `OrdoUser.email` 改可选,匹配服务端游客 `email: null`);② **本地数据按 userId 隔离**(§7.6.3 硬约束)——`Core/OrdoSessionBridge`(`OrdoAppDirectories` + 根目录 `session.json` + `OrdoSessionTokenStore`),SwiftData 容器改 `<userId>/Ordo.store`,设置页显示当前账号/类型/userId/目录并可退出登录(只清会话)+ 游客升级,删除旧的 `Data/TokenStore.swift`;App Intents 也按当前会话目录落库;③ **快加号集群**(§5.2)只留一个 56pt 按钮、长按 400ms 菜单、展开旋转 45°、逐项错位 40ms,删除系统 contextMenu;④ **刷新控件**(§5.3)图标连续旋转 900ms/圈 + 已同步/同步失败(点击重试)+ 1.4s 防抖,`⌘R` 同源;⑤ **长按拖拽**(§5.4)统一为长按 400ms 后拖动(移动 <6pt 视为点击)、行抬起 1.02+12dp 投影+背景 surface、插入线 2dp+4dp 圆点、被拖行 alpha 0.55、取消路径(Esc/拖出可视区/无目标行)明确,删除 `.onDrag`/`.onDrop` 与 `OrdoReorderDropDelegate`;新增 `OrdoTests/SessionAndGateTests`(会话/门禁/目录名/升级)与 `OrdoTests/InteractionStateTests`(长按阈值/刷新状态机/§5.1~§5.4 令牌断言)。**全部为静态核对,未经编译**。 |
