# 序 Ordo · Android 端（apps/android）

> 契约来源：[03 · 数据模型与同步协议](../../docs/03-数据模型与同步协议.md) · [04 · UI 设计规范](../../docs/04-UI设计规范.md)（FROZEN v1）
> 业务核心：KMP `shared:core`（**只调用、不修改**）· 交互参照：`things-clone/`（Web 原型，仅复用信息架构；名称/图标/配色一律按 04 文档的 Ordo 品牌）
> **v1.4 产品决策：彻底删除云同步 —— 本应用是纯本地应用，不联网、不申请 INTERNET 权限。**
> 规模：44 个 Kotlin 文件（33 主 + 11 测试）· 11 个测试类 / **120 个用例**（本机 `assembleDebug` + `assembleRelease` + `testDebugUnitTest` 真实执行通过，见 §7.6/§7.7/§7.8）

## 1. 构建

### 1.1 环境要求

| 项 | 要求 |
|---|---|
| JDK | 17（`compileOptions` 与 `kotlin.compilerOptions.jvmTarget` 均为 17） |
| Android SDK | **compileSdk 36 / targetSdk 36 / minSdk 26** + Build-Tools 36.x |
| Gradle | 由根工程提供（本模块不带 wrapper） |
| IDE | Android Studio（Kotlin 2.4.20 + Compose 编译器插件；**不需要 KSP**） |

### 1.2 命令

```bash
# 在仓库根目录（ordo/）执行
./gradlew :apps:android:app:assembleDebug        # 打 debug 包
./gradlew :apps:android:app:assembleRelease      # 打 release 包（未签名，见 build.gradle.kts）
./gradlew :apps:android:app:testDebugUnitTest    # 跑纯逻辑单测（11 个测试类 / 120 个用例，见 §7.6）
./gradlew :apps:android:app:installDebug         # 安装到设备
```

产物：`apps/android/app/build/outputs/apk/debug/app-debug.apk`

### 1.3 运行配置（纯本地）

- **不联网**：没有服务器地址、没有账号、没有同步；数据全部落在本机 `filesDir/`。
- 深链：`ordo://list/today`、`ordo://todo/{id}`、`ordo://project/{id}`；点提醒通知即走 `ordo://todo/{id}`。
- 首次启动由 `OrdoEngine.seedDemoData(force = false)` 写入示例数据；「设置 → 数据 → 重置为示例数据」可随时恢复（`force = true`）。
- 播种判据是**播种标记**（核心 kv `ordo.seedMark` = `demo`），不是「库文件在不在」：用户自己逐条删空待办不会被演示数据复活；而「设置 → 数据 → 清空本地数据」会把标记一起清掉 → **下次冷启动＝全新安装态，自动重新播种**（用户反馈的 Windows 端 bug，三端同修，见 §7.8）。

### 1.4 启动流程（纯本地，v1.4）

```
App 启动（OrdoApp.onCreate → ServiceLocator.init）
  ├─ 解析本机数据目录 id（契约 §7.6.6）：kv 已钉住 > 磁盘上唯一既有目录 > 新建 local-<16hex>
  ├─ 打开该目录的 SQLite（filesDir/<dirId>/ordo.db），由引擎的播种标记决定要不要写演示数据（首次安装 / 刚清空过 → 写）
  ├─ 起本地提醒（Notifier 渠道 + ReminderWorker）
  └─ 界面：ViewModel 订阅本地引擎 → 直接渲染；**全程不发任何网络请求**
```

- 没有登录、没有会话/令牌、没有同步调度器、没有实时通道；`AuthApi`/`SyncApi` 的 Android 实现已整体删除。
- 设置页只有 外观 / 数据（重置为示例数据 · 清空本地数据）/ 关于。

### 1.5 纯本地的证明方式（4 条，可复现）

```powershell
$apk = "apps/android/app/build/outputs/apk/debug/app-debug.apk"
# ① 代码：不存在任何网络客户端/调用
Select-String -Path "apps/android/app/src/main/**/*.kt" -Pattern "io\.ktor|okhttp|HttpClient|WebSocket|HttpURLConnection|java\.net\.Socket"
# ② 清单：APK 里没有 INTERNET 权限（也没有 ACCESS_NETWORK_STATE 之外的网络相关权限）
& "$env:ANDROID_HOME\build-tools\36.0.0\aapt2.exe" dump permissions $apk
# ③ 依赖：build.gradle.kts 里没有 ktor/okhttp/datastore
Select-String -Path "apps/android/app/build.gradle.kts" -Pattern "ktor|okhttp|datastore"
# ④ 产物：dex 里没有 okhttp / ktor / okio / URLConnection / WebSocket 的类名
Copy-Item $apk "$env:TEMP\o.zip"; Expand-Archive "$env:TEMP\o.zip" "$env:TEMP\o" -Force
Get-ChildItem "$env:TEMP\o" -Filter *.dex | ForEach-Object { [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($_.FullName)) } |
  Select-String -Pattern "okhttp3|io/ktor|okio|URLConnection|WebSocket"
```

**结论**：① 0 处命中；② 权限只有 `POST_NOTIFICATIONS` / `RECEIVE_BOOT_COMPLETED`(WorkManager 另注入
`WAKE_LOCK`/`ACCESS_NETWORK_STATE`/`FOREGROUND_SERVICE`)——**没有 INTERNET**，因此即使将来误引入网络调用，
系统也会直接抛 `SecurityException` 而不是静默联网；③ 依赖里没有网络库（DataStore 也已移除，它经 okio
带进过套接字相关传递依赖）；④ dex 命中为 0（仅剩通用的 `java/net/SocketException` 异常类型字符串）。

模拟器访问宿主机用 `http://10.0.2.2:<port>`。

## 2. 工程结构

```
apps/android/
├── README.md
└── app/
    ├── build.gradle.kts                compileSdk 36 / minSdk 26 / Compose(BOM) / BuildConfig 常量
    ├── proguard-rules.pro              保留 core 公开面、Worker
    └── src/
        ├── main/AndroidManifest.xml        权限(POST_NOTIFICATIONS/RECEIVE_BOOT_COMPLETED；**无 INTERNET**) + ordo:// 深链
        ├── main/res/                       strings(中文文案) / colors / themes + values-night / 自适应图标 / 通知图标
        └── main/java/com/ordo/android/
            ├── OrdoApp.kt (14)                         Application：装配 + 通知渠道 + 提醒任务
            ├── MainActivity.kt                        单 Activity + 深链解析 + 通知权限（v1.4 起无同步钩子）
            ├── di/ServiceLocator.kt (143)              手工装配（只有本地：OrdoEngine / 引导库 kv / Notifier）
            ├── data/
            │   ├── SqliteStorage.kt (300)              OrdoStorage 实现（原生 SQLite：entities/outbox/tombstones/kv）
            │   ├── LocalAccount.kt                     本机数据目录 id 的生成与解析（契约 §7.6.6）
            │   ├── UserDataDir.kt                      工作区目录名/路径 + 既有目录扫描
            │   ├── SeedData.kt (20)                    示例数据入口（内容来自 core，避免两份数据）
            │   ├── SettingsStore.kt                    外观模式（存引导库 kv；v1.4 起不再用 DataStore）
            │   └── ModelExt.kt (15)                    `when` 反引号访问（单点适配）
            ├── notify/Notifier.kt (70)                 ordo_reminders 渠道 + 深链 PendingIntent
            ├── notify/ReminderWorker.kt (123)          准点一次性任务 + 15 分钟周期兜底 + 已发记录（纯本地）
            ├── vm/UiState.kt / OrdoViewModel.kt        单向数据流，写操作全部经 OrdoEngine（v1.4 无同步/无会话）
            ├── vm/ComposerState.kt (63)                       快加浮层状态机（纯逻辑：打开/重复点击/关闭/提交）
            ├── vm/ProjectCompletion.kt (93)                   完成项目判定、文案选择与卡片主动作（纯逻辑，契约 §2.2 v1.1）
            ├── nav/Routes.kt (33) / OrdoNavHost.kt (61)       路由 ↔ 派生清单
            └── ui/
                ├── theme/Tokens.kt / Theme.kt                 04 文档 §2 令牌 + 浅深色 + 减弱动态效果
                ├── common/OrdoIcons.kt                        自绘矢量图标（不依赖图标扩展包、不用他人资产）
                ├── common/Components.kt                       复选框/进度环/胶囊/浮层/Toast/输入框/Markdown 预览
                ├── common/OrdoFormatter.kt (85)               日期词汇走 core 的 OrdoDate，界面文案走 strings.xml
                ├── shell/OrdoShell.kt / Sidebar.kt            应用根（直接三栏骨架）+ 侧栏 + 状态栏（v1.4 无同步指示）
                ├── list/ListScreen.kt / TodoRow.kt            大标题/分组/38dp 行/滑动操作/完成动效（无下拉刷新）
                ├── detail/DetailCard.kt (365)                 标题/备注 Markdown/何时/截止/提醒/重复/移动/标签/清单
                ├── schedule/ScheduleSheet.kt (234)            自然语言 + 快捷项 + 提醒 + 月历 + 清除
                ├── search/FastFind.kt (223)                   快找浮层（↑↓/Enter/Esc）+ 搜索页
                ├── quickadd/QuickAdd.kt                       快加号 / 长按菜单（v1.3 图标对齐参照原型）
                └── settings/SettingsScreen.kt                 外观 / 数据（重置为示例数据 · 清空本地数据）/ 关于（**已删除账号/退出登录/服务器地址**）
        └── test/java/com/ordo/android/
            ├── FakeStorage.kt (37)     测试设施（固定时钟 + 引擎工厂；内存仓储已由 core 的 InMemoryStorage 取代）
            ├── TestStrings.kt (42)     只读解析 res/values/strings.xml（文案契约测试，不引入 Robolectric）
            ├── NlpParsingTest.kt (179) 契约 §5 逐条（今天/今晚/明天/大后天/N天后/N周后/N个月后/绝对日期/星期/周末/某天/时间/标签/综合）
            ├── QueryRulesTest.kt (223) 契约 §4 边界（收件箱/今天含逾期/今晚分区/14 天窗口与「更晚」/某天/日志簿/标签开关/进度/搜索/计数/演示数据规模）
            ├── RepeatEngineTest.kt (117) 契约 §6（fixed/afterCompletion/月末溢出/每年/新实例字段/清单重置/取消重复）
            ├── GestureRulesTest.kt 契约 §5.2/§5.4（长按 400ms、位移阈值、菜单与拖拽判定、FAB 几何）
            ├── QuickAddMenuTest.kt 契约 §5.2 v1.3（菜单项顺序/图标形状/文案/排版硬指标）
            ├── LocalAccountTest.kt 契约 §7.6.6（本机目录 id 生成与解析优先级）
            ├── UserDataDirTest.kt 契约 §7.6.3（目录隔离、既有目录扫描）
            ├── ProjectCompletionTest.kt (215) 契约 §2.2 v1.1（拒绝原因与文案带 N/标题未归档也允许完成+自动归档/归档 Op 与完成 Op/已完成态/取消不阻塞/卡片主动作）
            ├── ComposerStateTest.kt (74) 快加浮层（打开状态正确/已打开时再点加号不丢草稿且重新聚焦/空标题不产生待办/关闭再开是新的一轮）
            └── ClearDataReseedTest.kt (115) 清空本地数据（清空后冷启动重新播种 / 不重复播种 / 用户自己删空不复活 / 启动判据与设置页接线的源码级断言）
```

## 3. 功能实现对照

| 要求 | 实现位置 | 说明 |
|---|---|---|
| 三栏骨架 + 窄屏抽屉 | `ui/shell/OrdoShell.kt` | ≥1100dp 三栏（详情第三栏）；768–1099dp 侧栏常驻；<768dp 抽屉 + 详情全屏 |
| 侧栏（计数 / 区域 / 项目进度环 / 标签） | `ui/shell/Sidebar.kt` | 全部取自 `engine.counts()` 的 `projects / projectProgress / tags`，与契约 §4 同口径 |
| 列表（大标题 / 分组 / 38dp 行 / 圆形复选框 / 元信息 pill） | `ui/list/ListScreen.kt`、`TodoRow.kt` | 分组的 `kind` 直接用 core 的 `SectionKind`（TONIGHT 用琥珀色、COMPLETION_DAY 显示完成时间） |
| 详情卡片 | `ui/detail/DetailCard.kt` | 标题/备注(Markdown 预览)/何时/截止/提醒/重复/移动/标签/清单，字段均为可点胶囊 |
| 排期面板 | `ui/schedule/ScheduleSheet.kt` | 今天/今晚/明天/本周末/某天 + 提醒快捷 + 月历 + 自然语言输入 + 危险色清除 |
| 快找 | `ui/search/FastFind.kt` | 顶部搜索按钮进入；↑↓/Enter/Esc；结果含待办/项目/区域/标签；标签直达 |
| 快加号 | `ui/quickadd/QuickAdd.kt`、`vm/ComposerState.kt`、`ui/theme/Tokens.kt` | 单击新建（NLP 解析日期/时间/标签）、长按菜单（待办/项目/区域）；打开即聚焦+弹键盘，已打开时再点是"重新聚焦"而不是空操作，返回键/Esc 关闭且不产生空待办。**UI §5.2 v1.5 视觉（2026-10-13 两次修订后的当前实现）**：填充亮蓝 `#0A84FF`（`colors.fab`）+ **纯色、无柔光**（同日用户要求三端去掉柔光，`colors.fabGlow` 令牌与 `radialGradient` 层已删除）；FAB 底边距 = 状态栏实测 44dp + 留白 16dp = 60dp（`OrdoLayout.fabBottomInset` / `fabContentInset`），按钮整体浮在状态栏之上 |
| 项目完成 | `ui/list/ListScreen.kt`、`vm/ProjectCompletion.kt` | 契约 §2.2 v1.1：唯一硬约束是"项目下没有未完成的待办"，标题未归档由引擎自动归档；拒绝文案带 N 且不提「标题」；已完成项目显示「已完成 + 重新打开」而不是「完成项目」 |
| 路由 | `nav/Routes.kt`、`OrdoNavHost.kt` | inbox/today/upcoming/anytime/someday/logbook/project/{id}/area/{id}/tag/{name}/search |
| 本地存储(SQLite) | `data/SqliteStorage.kt`、`data/LocalAccount.kt`、`data/UserDataDir.kt` | 实体按 **JSON 快照整行**存放(`entities(entity,id,payload,updated_at,deleted)`)，字段名与契约 §2 永远一致；outbox 主键 `op_id` 天然幂等；kv 存 schemaVersion / serverSeq / deviceId / 目录 id / 外观。**目录 id 是本机钉住的**（契约 §7.6.6） |
| **纯本地（不联网）** | 全模块 | v1.4：云同步 / 登录 / 会话 / 令牌 / Ktor / WebSocket / 同步 UI 全部删除；**清单里没有 INTERNET 权限**；启动直接读本地 SQLite 渲染（§1.5 有四条可复现的证明命令） |
| 提醒 | `notify/Notifier.kt`、`ReminderWorker.kt` | `ordo_reminders` 渠道；准点一次性任务 + 15 分钟周期兜底；点击深链打开待办（纯本地，无网络约束） |
| 深链 | `AndroidManifest.xml`、`MainActivity.kt` | `ordo://` scheme，`Routes.fromDeepLink` 解析 |
| 单元测试 | `src/test/**` | 11 个测试类 / 120 个用例，全部只依赖 `shared:core`，不依赖 Android 框架；用 `FixedOrdoClock` 固定"今天"，断言完全确定 |

## 4. 设计令牌落地（04 文档 §2）

`ui/theme/Tokens.kt` 逐值实现，命名与文档一致：

- 色彩：`bg.canvas #FBFAF7 / #141416`、`bg.surface #FFFFFF / #1D1D21`、`bg.sidebar #F4F3EF / #191919`、`line.hairline #E7E5DF / #2E2E33`、`text.primary #1C1B19 / #F2F1EE`、`text.secondary #7A776F / #9A968E`、`text.tertiary #A8A49B / #6E6B65`、`accent.primary #5B5BD6 / #7C7CF0`、`accent.tonight #D98324 / #E8A13F`、`state.danger #E5533D / #F2705C`、`state.success #2FA36B / #3FBF83`、`chip.bg/chip.text`、`focus.ring`
- 排版：`display 28/34 600`、`title 20/26 600`、`body 15/22 400`、`caption 13/18 400`、`micro 11/14 500(字距 +0.4)`
- 间距/圆角：`4/8/12/16/24/32`、`row 10 / card 14 / sheet 14 / pill 999`
- 动效：`fast 120 / base 220 / slow 320` + `cubic-bezier(.2,.8,.2,1)`；完成动效按 §5 的 0/80/160/240/700/900ms 时序（`TodoRow` 里 `completing` 状态 → 700ms 后交给引擎）
- 无障碍：触控目标 ≥44dp、`contentDescription` 全覆盖、**减弱动态效果**（读 `ANIMATOR_DURATION_SCALE`）开启后动效归零
- 图标与配色均自绘/自定义，**未使用 Things 的名称、图标、截图与文案**（04 文档 §1.1）

## 5. 与 shared:core 的集成

共享核心（`com.ordo.core.*`）是本模块唯一的业务真相来源，Android 端**只做三件事**：本地库实现、网络实现、UI。

| 契约能力 | core API | Android 端用法 |
|---|---|---|
| 会话与全部写操作 | `OrdoEngine` | `ServiceLocator.engine` 单例；ViewModel 所有写操作经它（本地优先，契约 §7.1） |
| 派生清单 | `engine.list(query)` / `engine.sections(query)` | 路由 → `ListQuery`（`ProjectScope/AreaScope/TagScope(name, includeCompleted)/Search(text)`） |
| 侧栏计数与进度 | `engine.counts()` | `SidebarCountsUi` 单点映射（`vm/OrdoViewModel.kt` 末尾扩展函数） |
| 中文 NLP | `NaturalDateParser.parse(input, today, nowTime)` | 新建待办 / 排期面板直接调用（纯函数，四端一致） |
| 日期与文案 | `OrdoDate.*` | 今天/明天/周三、`reminderLabel`、`isPast`、`normalizeTime` 全部复用 core 实现 |
| 重复规则 | `engine.setRepeat(id, RepeatRule)` + `toggleDone` | 完成时由 core 生成下一次实例（契约 §6） |
| 本地存储 | `OrdoStorage` | `SqliteStorage` 实现(原生 `SQLiteOpenHelper`,零注解处理) |
| 同步 | `SyncEngine(engine, api).syncOnce()/fullResync()` | `KtorSyncApi : SyncApi`；`SyncScheduler` 负责触发与状态 |
| 实时 | `RealtimeChannel` | `RealtimeClient` 实现；`ops` → `engine.applyRemote`，`reminder` → 通知（快车道） |
| 演示数据 | `engine.seedDemoData(force)` | 首次启动写入（`force = false`，且受播种标记 `ordo.seedMark` 守卫）；设置里「重置为示例数据」传 `force = true` 立刻覆盖 |
| 清空本地数据 | `engine.clearAll()` + `vm/OrdoViewModel.clearAllData()` | 实体 / outbox / 墓碑 / **播种标记**全清＝回到全新安装态；设置页「清空本地数据」带两步确认，确认后提示「已清空本地数据」，下次冷启动重新播种（§7.8） |

**为什么不用 Room**:KSP 注解处理器的版本与 Kotlin 编译器版本强耦合(当前 KSP 稳定版落后于 Kotlin 2.4.20),会给"本机无 SDK、需在客户环境首次构建成功"的场景带来不必要风险。改用原生 `SQLiteOpenHelper` 后:构建只需 AGP + Kotlin;同时因为实体以 JSON 整行存放,**契约新增字段无需数据库迁移**。若团队后续希望回到 Room,只需新增一个 `RoomStorage : OrdoStorage` 并替换 `ServiceLocator` 中的一行装配。

## 6. 需要在根 `gradle/libs.versions.toml` 中存在的别名

任务给定的别名之外，本模块还需要以下别名（**未写死版本号**）：

| 别名 | 建议坐标 |
|---|---|
| `libs.androidx.compose.bom` | `androidx.compose:compose-bom` |
| `libs.androidx.compose.ui` / `libs.androidx.compose.ui.graphics` | `androidx.compose.ui:ui` / `ui-graphics` |
| `libs.androidx.compose.foundation` / `libs.androidx.compose.material3` | `androidx.compose.foundation:foundation` / `androidx.compose.material3:material3` |
| `libs.androidx.compose.ui.tooling` / `libs.androidx.compose.ui.tooling.preview` | `androidx.compose.ui:ui-tooling` / `ui-tooling-preview` |
| `libs.junit` / `libs.kotlin.test` / `libs.kotlinx.coroutines.test` | `junit:junit:4.13.2` / `org.jetbrains.kotlin:kotlin-test` / `org.jetbrains.kotlinx:kotlinx-coroutines-test` |

本模块**没有**使用 `kotlinx-serialization` 编译期插件：HTTP/WS 实体全部复用 core 里已生成的 `@Serializable` 序列化器（`Op.serializer()` / `PushRequest.serializer()` 等，通过 `OrdoJson.instance` 编解码），因此不需要在本模块再开插件。

## 7. 验证情况与风险点（**重要**）

### 7.1 早期验证（交付环境**没有** Android SDK 时的记录）

> 本节记录的是"没有 SDK、只能用命令行编译器离线验证"阶段的结论，**已由 §7.4 的 Gradle 全量构建取代**；保留它是为了说明哪些结论当时无法验证。

交付环境**没有 Android SDK**，无法执行 `assembleDebug`；但用 DevEco Studio 自带 JBR（JDK）+ Gradle 缓存里的 Kotlin 2.4.20 编译器 + 共享核心编译产物 `shared/core/build/libs/core-jvm.jar`，对**与 Android 框架无关的部分做了真实编译与真实测试执行**：

| 验证项 | 要点 | 结果 |
|---|---|---|
| 测试代码真实编译 | `K2JVMCompiler` + `core-jvm.jar;kotlin-stdlib;kotlinx-serialization-{json,core};junit;hamcrest;coroutines` | ✅ 无错误 |
| 4 个测试类真实执行 | `java -cp … org.junit.runner.JUnitCore …` | ✅ **60 个测试全部通过**（NLP 29 / 查询 15 / 重复 9 / 同步合并 7） |
| 网络与数据辅助层真实编译 | 同上 + Ktor 3.6.0 classpath：`data/ModelExt.kt`、`data/SeedData.kt`、`net/OrdoErrors.kt`、`net/Dto.kt` | ✅ 无错误 |
| 契约一致性 | `node tools/contract-check.mjs`（主控提供） | ✅ **所有适用项通过** |
| 字符串资源交叉检查 | 151 处 `R.string.*` 引用 vs `strings.xml` 184 条 | ✅ 无缺失 |
| 图标枚举交叉检查 | 29 种 `OrdoIconKind` 引用 vs 枚举定义 | ✅ 无缺失 |
| 符号交叉检查 | `engine.*` / `vm.*` / `state.*` 引用 vs 真实源码 | ✅ 无未定义引用 |
| 存储接口一致性 | `storage.*` 调用面 vs `SqliteStorage` 公开方法 | ✅ 全部存在（见下 3.） |
| 越界写入 | 只新增/修改 `apps/android/**` | ✅ 未触碰 `shared/**`、`docs/**`、`server/**`、其它端与根 Gradle 文件 |

**验证过程中发现并修正的问题（3 处，全部为真实缺陷）**：

1. **`TodoOptions` 包名错误（真实编译错误）**：它定义在 `com.ordo.core.store`（`OrdoEngine.kt`），不在 `com.ordo.core.model`。已修正 `vm/OrdoViewModel.kt` 与 3 个测试文件的 import。
2. **一条测试断言与契约语义不符（非 core 缺陷）**：契约 §4 的「窗口 = 明天起 14 天」指**按天分组的窗口**；超出窗口的待办归入「更晚」分组、仍出现在 `list(Upcoming)`。原断言"第 15 天不在 Upcoming 中"错误，已改为断言「DAY 分组只含窗口内日期」+「第 15 天落在 LATER 分组」。
3. **存储层重构后的编译缺口**：本地存储由 Room 改为原生 SQLite 后，`SqliteStorage` 缺少 `ReminderWorker` 依赖的 `reminderTodos()`。已在 `SqliteStorage` 补齐该方法（直接查 `entities` 表中 `entity='todo'` 且 `isOpen && reminder != null` 的行），并清理 `proguard-rules.pro` 里已失效的 Room 规则与不存在的 `net.dto` 保留项。

### 7.2 尚未验证的部分

Lint、真机或模拟器运行、04 文档 §9 的五张基线图截图回归——`assembleDebug` / `testDebugUnitTest` 已在 §7.4 真实执行，不再属于此项。

未覆盖的代码约 4.5k 行：Compose UI（`ui/**`）、`data/SqliteStorage.kt`（需 `android.database`）、Android 胶水（`OrdoApp`、`MainActivity`、`di/ServiceLocator`、`notify/**`、`sync/SyncScheduler`、`net/{AuthApi,KtorSyncApi,RealtimeClient,TokenStore,HttpClientFactory}`）——这部分只做了真实**编译**（`assembleDebug` 通过），没有自动化用例。

### 7.3 已知风险

1. **Compose 版本差异**：`ThemeMode.entries` 需要 Kotlin ≥ 1.9；Compose BOM 已固定在根 `libs.versions.toml`（`composeBom = "2026.09.00"`）。
2. **首次构建**：`compileSdk = 36` / AGP 9.4.1 / Kotlin 2.4.20；需 Android Studio 与 SDK 36。
3. **SQLite 整表写入**：`saveSnapshot` 采用"事务内清表 + 全量重写"，演示与常见规模（数千条）为毫秒级；若单账号上万条，建议改为按实体增量 upsert（`OrdoStorage` 接口不变）。
4. **WorkManager 与单例**：`ReminderWorker` 通过 `ServiceLocator` 取依赖，默认进程内单例；若未来把 Worker 拆到独立进程，需要改为显式注入。
5. **拖拽排序未实现**：04 文档 Android 列要求「长按拖拽」，当前实现是左右滑动（排期/删除）+ 点击详情；`order` 字段与 `engine.reorderTodos(ids)` 已就绪。
6. **未使用实验性 Compose API**：无 `TopAppBar`/`ModalBottomSheet`/`combinedClickable`/`animateItem`；只用 `Text`/`Surface` 级稳定 API 与 Foundation（`BoxWithConstraints`、`detectTapGestures`、`detectHorizontalDragGestures`、`onPreviewKeyEvent` 均为稳定 API）。

### 7.4 本轮修复与真实验证（2026-10-09，本机已装 Android SDK 36）

**触发**：Windows 端实测两个缺陷（「项目完成被拒」「点快加号没有可见反馈」）。Android 端 UI 结构同源，逐个复核结论如下。

| 缺陷 | Android 端是否存在 | 根因 | 修复 |
|---|---|---|---|
| 项目显示 100%/0 项未完成，点「完成项目」却被拒 | **行为已随 core 修复**（`OrdoEngine.completeProject` v1.1 完成时自动归档标题），**但文案与卡片状态仍不一致** | ① 拒绝文案写死为「还有未完成的待办，无法完成项目」：既不带 N，又被复用在「项目本来就是 DONE」这条完全不同的原因上；② 已完成（DONE）的项目仍然显示「完成项目」按钮，点了只会被幂等拒绝并报错误原因 | 新增 `vm/ProjectCompletion.kt`（纯逻辑：`Completed` / `AlreadyDone` / `Blocked(N)` → 文案与参数）；`ListScreen` 按 `project.status` 分流为「完成项目」/「重新打开」并显示已完成胶囊；`strings.xml` 拒绝文案改为 `还有 %1$d 项未完成的待办，无法完成项目`（**不再提「标题」**） |
| 点右下角蓝色加号「没有反应」 | **部分存在**：浮层本身会画出来（它是覆盖层，不在列表内容顶部），但 ① 输入框不聚焦、软键盘不弹 —— `focusRequester` 挂在外层 `Box` 而不是可聚焦的 `BasicTextField` 上，`requestFocus()` 找不到焦点目标；② 已打开时再点加号命中的是遮罩，浮层被**关掉**（快速连点 = 打开又关闭，观感等同「没反应」），草稿同时丢失；③ 返回键不关浮层（直接回退清单/退出应用） | `common/Components.kt` 的 `OrdoTextField` 新增 `focusRequester` 参数并挂到 `BasicTextField`；`ComposerSheet` 用 `LaunchedEffect(composer.focusRequest)` 聚焦 + `keyboard.show()`、卡片 `imePadding()`；`vm/ComposerState.kt`（新，纯逻辑状态机）把「打开/重复点击/关闭/提交」四件事定死；`OrdoShell` 让浮层先画、加号后画（加号永远可点 → 再点一次 = 重新聚焦、不丢草稿）；`BackHandler` + `onPreviewKeyEvent(Esc)` 关闭且不产生空待办 |

顺带修掉**同一根因**的一处：`ui/search/FastFind.kt` 的 `focusRequester` 同样挂在外层 `Box` 上，因此浮层打开后从未拿到焦点，其 `↑↓ / Enter / Esc` 的 `onPreviewKeyEvent` 实际收不到按键（key 事件只沿焦点路径派发）。改走新的 `focusRequester` 参数后按键才真正生效。

真实构建/测试证据（本机 JDK 21 + Android SDK 36 + Gradle 8.14，`--rerun` 强制重跑）：

```powershell
$env:JAVA_HOME="…\_tools\jdk-21.0.12.1+1"; $env:ANDROID_HOME="C:\Users\admin\Android\Sdk"; $env:ANDROID_SDK_ROOT="C:\Users\admin\Android\Sdk"
& "…\_tools\gradle-8.14\bin\gradle.bat" -p ordo :apps:android:app:assembleDebug :apps:android:app:testDebugUnitTest --rerun --console=plain
```

| 验证项 | 结果 |
|---|---|
| `assembleDebug` | ✅ `BUILD SUCCESSFUL`（全量重编译 30s / 增量 6s）；产物 `app-debug.apk` **16,256,801 字节（15.50 MB）** |
| `testDebugUnitTest` | ✅ **71 个用例全绿**（NLP 29 / 查询 15 / 重复 9 / 同步合并 7 / **项目完成 6** / **快加浮层 5**），0 failures / 0 errors |
| APK 内容抽验 | ✅ `resources.arsc` 里是最终文案（`还有 %1$d 项未完成的待办，无法完成项目`、`重新打开`、`已完成`），`classes.dex` 里有新增的 `ProjectCardAction` / `ComposerState` / `ProjectCompletionKt` —— 证明产物确实来自本轮源码 |
| 文案契约测试的**反证**（确认不是空跑） | 临时把旧文案「还有 %1$d 项未完成的待办**或标题**」写回 `strings.xml` → 用例立即 `FAILED`（`71 tests completed, 1 failed`），改回即通过 |
| `python tools/check-encoding.py` | ✅ `OK: no encoding problems found`（扫描 433 个文本文件） |
| 写入范围 | ✅ 本轮只改 `apps/android/**`（`git status` 里其它端的改动属于并行任务，非本轮所为） |

本轮改动文件：`vm/ProjectCompletion.kt`（新）、`vm/ComposerState.kt`（新）、`vm/OrdoViewModel.kt`、`vm/UiState.kt`、`ui/list/ListScreen.kt`、`ui/shell/OrdoShell.kt`、`ui/quickadd/QuickAdd.kt`、`ui/common/Components.kt`、`ui/search/FastFind.kt`、`res/values/strings.xml`；测试：`ProjectCompletionTest.kt`（新）、`ComposerStateTest.kt`（新）、`TestStrings.kt`（新）。

**本轮未覆盖（风险）**：聚焦/软键盘/z 序/返回键这些**交互**只能靠编译 + 纯逻辑单测保证，JVM 单测无法断言 Compose 焦点与 IME 行为；需在真机或模拟器上人工回归一次（见 §8 TODO 第 7 条）。

### 7.5 本轮：移除登录系统 + 静默匿名会话（2026-10-13）

**产品决策**：不再需要登录 → 启动即主界面（`OrdoShell.OrdoRoot` 里已无任何 LOADING/LOGIN 分支），云同步用后台静默匿名会话。

**删除（登录死代码，全部在 `apps/android/**`）**

| 类别 | 内容 |
|---|---|
| 界面 | `ui/auth/LoginScreen.kt`（整个 `ui/auth/` 目录） |
| 门禁与状态机 | `auth/AuthGate.kt`（`AuthStage`/`AuthMode`/`AuthMethod`/`AuthFieldError`/`SessionGate`）、`auth/EmailCodeLogin.kt` |
| UiState | `AuthUi` 数据类、`UiState.auth`、`UiState.loggedIn`（口令/验证码/提交态/错误抖动等字段一并移除） |
| ViewModel | `logout()`、`setServerUrl()`/`currentServerUrl()`、`enterMain(userId…)` 的目录切换、`onAuthEmailChange` 等全部登录回调、`failWith`/`loginErrorMessage` 等登录文案 |
| 网络 | `OrdoAuthApi.logout()`；`AuthApi` 接口方法仍全部实现（共享接口冻结，不能删），但界面已无入口调用 register/login/upgrade/email-code |
| 设置页 | 「账号 / 退出登录 / 升级为正式账号 / 服务器地址」整块；`SettingsStore.serverUrl`（与 kv 重复的第二份存储） |
| 组件 | `OrdoTextField` 的口令掩码/显示切换 + `keyboardType`/`trailing` 插槽、`OrdoPrimaryButton`/`OrdoSecondaryButton`/`OrdoSpinner`、`OrdoLayout.loginCardWidth` |
| 资源 | `auth_*`(33 条)、`settings_account*`/`settings_logout`/`settings_upgrade`/`settings_email`/`settings_password`/`settings_server*`、`toast_login_*`/`toast_logout`/`toast_upgrade_ok`/`toast_server_saved`、`field_password_*`；`sync_never` 文案由「未登录」改为「未连接」 |
| 用例 | `SessionGateTest`(13)、`EmailCodeLoginTest`(25) 删除；其中与登录无关的目录隔离用例迁入新的 `UserDataDirTest` |

**新增**

- `auth/SilentSession.kt`（纯逻辑）：启动处置 `SessionPlan{UseExisting/RefreshFirst/CreateAnonymous}`、`isSessionDenied`（只有 `AUTH_REQUIRED`/`AUTH_TOKEN_EXPIRED` 才算会话失效）、`errorCodeOf`、`backoffMillis`（1s→2s→…→60s 封顶）。
- `data/LocalAccount.kt`（纯逻辑，契约 §7.6.6）：**本机数据目录 id** 的生成与解析 —— 见下。
- `di/ServiceLocator`：`dataDirId` 钉住 + `ensureAnonymousSession()`（applicationScope 退避重试）+ `session` StateFlow。
- `vm/OrdoViewModel`：`startSilentSession()` / `enterMain(sessionReady, silentRefresh)` / `repairSessionIfDenied()`。
- 用例：`SilentSessionTest`(8)、`LocalAccountTest`(7)、`UserDataDirTest`(5)。

**目录 id 是怎么钉住的（契约 §7.6.6，与 Windows/iOS 同语义）**

1. 引导库 kv 新增键 `ordo.localAccountId`（`LocalAccount.KEY_LOCAL_ACCOUNT_ID`）；`ServiceLocator.dataDirId` 在**首次访问时**解析并**立即写回 kv**，此后进程内与跨进程都不再改变。
2. 解析优先级（`LocalAccount.resolve`，纯函数、可单测）：
   `已钉住的 kv 值` → `升级前会话的 userId`（沿用旧目录，**不做迁移**）→ `磁盘上唯一一个含 ordo.db 的既有目录` → `null`（此时生成 `local-<16hex>`）。
   多于一个既有目录时**不猜**（宁可新建空工作区，也不把别人的数据当自己的展示）。
3. `bindDataDir(dirId)` 只在启动时调用一次；**静默建号 / 401 重建 / 续期都只更新令牌**（`onSessionReady()` 不再 rebind），所以服务端换 userId 时界面读的还是同一个目录 —— 用户看不到待办"消失"。
4. 服务端 `userId` 只用于鉴权与同步（`TokenStore`/`KtorSyncApi`/`RealtimeClient`），不参与任何目录选择。
5. 上一轮实现里的"首启临时目录 + 拿到账号后认领（改名）"已**删除**：既然目录 id 一开始就钉住，就不需要改名，也就不存在改名窗口期的丢数据风险。

真实构建/测试证据（本机 JDK 21 + Android SDK 36 + Gradle 8.14）：

```powershell
$env:JAVA_HOME="…\_tools\jdk-21.0.12.1+1"; $env:ANDROID_HOME="C:\Users\admin\Android\Sdk"; $env:ANDROID_SDK_ROOT="C:\Users\admin\Android\Sdk"
& "…\_tools\gradle-8.14\bin\gradle.bat" -p ordo :apps:android:app:assembleDebug :apps:android:app:testDebugUnitTest --console=plain
```

| 验证项 | 结果 |
|---|---|
| `assembleDebug` | ✅ `BUILD SUCCESSFUL`；产物 `app-debug.apk` **15,906,747 字节（15.17 MB）** —— 比 v1.2 的 16.4 MB 小，登录界面与相关资源确实没进包 |
| `testDebugUnitTest` | ✅ **129 个用例全绿**（NLP 29 / 查询 15 / 手势 17 / 快加菜单 12 / 刷新控件 9 / 重复 9 / **静默会话 8** / 同步合并 7 / **本机目录 id 7** / 项目完成 6 / 快加浮层 5 / **数据目录 5**），0 failures / 0 errors |
| 用例数变化 | 147 → 129（**下降是预期的**：删除 `SessionGateTest` 13 + `EmailCodeLoginTest` 25 = 38；新增静默会话/目录 id/数据目录共 20） |
| `python tools/check-encoding.py` | ✅ `OK: no encoding problems found`（扫描 518 个文本文件） |
| 登录残留检查 | ✅ `Login|登录|logout|account|AuthUi|AuthStage|SessionGate|provisionalUserId|claimProvisional` 全模块 grep 只剩 KDoc/历史注释，无代码引用 |
| 写入范围 | ✅ 只改 `apps/android/**`（`git status` 里其它端的改动属于并行任务） |

**本轮未覆盖（风险）**：真机上的"首启离线 → 联网建号"与"服务端 401 → 重建会话"两条路径只能靠纯逻辑单测 + 编译保证；建议真机回归一次（飞行模式首启写几条待办 → 联网 → 确认待办还在且开始同步）。

### 7.6 本轮：彻底删除云同步 → 纯本地应用（2026-10-13）

**产品决策**：不再需要云同步。Android 端从此是纯本地应用：**不联网、无账号、无会话、无同步 UI**。

**删除清单（全部在 `apps/android/**`）**

| 类别 | 内容 |
|---|---|
| 网络包 | `net/` 整包：`HttpClientFactory`、`Dto`（请求头/错误模型/WS 帧）、`AuthApi`、`AuthErrors`、`KtorSyncApi`、`RealtimeClient`、`OrdoErrors`、`TokenStore` |
| 同步包 | `sync/` 整包：`SyncScheduler`（含网络恢复回调、WorkManager 同步触发）、`RefreshController`（刷新控件状态机） |
| 会话 | `auth/SilentSession.kt`；`ServiceLocator` 里的 `sessions`/`tokens`/`authApi`/`syncApi`/`realtime`/`scheduler`/`ensureAnonymousSession`/`session` 流/`startRealtime` |
| 同步 UI | 状态栏刷新控件与同步文字（`OrdoShell.RefreshControl`）、列表下拉刷新（`PullToRefreshBox`）、设置页「立即同步」、`UiState.syncState`/`UiState.refresh`、`OrdoViewModel.refresh/syncNow/applySyncState/onAppForeground/onAppBackground`、`MainActivity` 的前后台同步钩子 |
| 依赖 | `ktor-client-okhttp` / `ktor-client-content-negotiation` / `ktor-client-websockets` / `ktor-serialization-kotlinx-json`；**DataStore 也删除**（它经 okio 带进套接字相关传递依赖，外观设置改存引导库 kv） |
| 权限 | `INTERNET`、`ACCESS_NETWORK_STATE`（后者由 WorkManager 另行注入，见 §1.5） |
| 资源 | `sync_*`(5+5 条)、`refresh_desc`、`settings_sync_now`、`toast_sync_*`、`toast_local_dir_failed` |
| 用例 | `RefreshStateTest`(9)、`SyncMergeTest`(7)、`SilentSessionTest`(8) 删除；`LocalAccountTest` 收敛为纯本机语义（7→6） |
| 其它 | `SqliteStorage` 的 `KEY_ACCESS_TOKEN/KEY_REFRESH_TOKEN/KEY_USER_EMAIL/KEY_SERVER_URL/DEFAULT_SERVER_URL`；`SettingsStore.lastSyncAt`；`UserDataDir` 不再引用共享的 sync 包（目录名清洗规则逐字内联，保证老目录仍可解析） |

**保留**：本地 SQLite 存储与 `OrdoEngine` 全部本地能力、三栏界面、快加号、排期、快找、提醒（WorkManager 仅用于本地提醒）、深链、契约 §7.6.6 的"本机钉住目录 id"。

真实构建/测试证据（JDK 21 + Android SDK 36 + Gradle 8.14）：

| 验证项 | 结果 |
|---|---|
| `assembleDebug` + `testDebugUnitTest` | ✅ `BUILD SUCCESSFUL`；**9 个测试类 / 104 个用例全绿**，0 failures / 0 errors |
| 用例数变化 | 129 → 104（**如实下降**：删 24 条同步/会话用例、`LocalAccountTest` 收敛 -1） |
| APK | ✅ `app-debug.apk` **15,758,950 字节（15.03 MB）**（v1.3 为 15.9 MB） |
| 无网络证明 | ✅ §1.5 四条：代码 0 处网络调用 / APK 权限无 INTERNET（`aapt2 dump permissions`）/ 依赖无 ktor·okhttp·datastore / dex 无 okhttp·ktor·okio·URLConnection·WebSocket 类名 |
| `python tools/check-encoding.py` | ✅ `OK: no encoding problems found` |
| 写入范围 | ✅ 只改 `apps/android/**` |

**本轮未覆盖（风险）**：真机/模拟器运行（本机没有设备）——"不联网"是从权限与产物层面证明的，未做抓包实测；
另外 `ACCESS_NETWORK_STATE`/`WAKE_LOCK`/`FOREGROUND_SERVICE` 由 `androidx.work` 注入（本地提醒用），
它们不授予任何联网能力，故保留。

### 7.7 本轮：快加号对齐 §5.2 v1.5（亮蓝 + 柔光 + 浮在状态栏之上，2026-10-13）

> **⚠ 本节记录的是 2026-10-13 上午的方案，当天下午已被用户推翻**：三端去掉柔光 —— `colors.fabGlow` 令牌、`radialGradient` 层、`requiredSize` 溢出全部删除，底边距规则改为「状态栏实测 44 + 留白 16 = 60dp」（`OrdoFabTokens` / `OrdoLayout.fabBottomInset`）。
> 现在的实现以 §3 表格与 `QuickAddFabStyleTest` 为准；本节保留作为历史，以及「为什么不用彩色阴影（`ambientColor`/`spotColor`）」的论证。

**改了什么**

| 项 | 之前 | 现在 |
|---|---|---|
| 填充色 | `colors.accent`（靛紫 #5B5BD6） | `colors.fab` = **#0A84FF**（浅/深色同一色值） |
| 柔光 | 无（只有灰阶 elevation 阴影） | **径向渐变**柔光 24dp，`colors.fabGlow`（同色，浅 35% / 深 45%） |
| 柔光实现 | — | `Brush.radialGradient` + `Modifier.background(brush)`；**不用** `shadow(ambientColor/spotColor)`（Windows/Skia 实测彩色阴影不渲染，两端统一用渐变） |
| 布局 | 柔光若用普通尺寸会把按钮往里推 | 柔光用 `requiredSize` **溢出按钮边界、不参与布局** |
| 位置 | `align(BottomEnd).padding(OrdoSpace.xl)`（整圈 24dp） | `padding(end = OrdoSpace.xl, bottom = OrdoLayout.fabContentInset)`；窗口坐标下的规则是 `statusBar(44) + fabGlow(24) = 68dp`，因此按钮连同柔光整体浮在状态栏之上（柔光下缘正好落在状态栏顶边） |
| 交互 | 单击 = 新建待办、长按 = 菜单 | **不变**（图 2 的 Ctrl+N 是桌面端交互，移动端保留"点 = 新建"） |

**令牌（`ui/theme/Tokens.kt`）**

- `OrdoFabTokens.fill = #0A84FF`；`GLOW_ALPHA_LIGHT = 0.35`；`GLOW_ALPHA_DARK = 0.45`；`GLOW_THICKNESS_DP = 24`；`STATUS_BAR_DP = 44`；`BOTTOM_INSET_DP = 68`
- `OrdoColors.fab` / `OrdoColors.fabGlow`（浅/深各一份）
- `OrdoLayout.fabGlow = 24.dp`、`OrdoLayout.statusBar = 44.dp`（= `touchTarget`，StatusBar composable 的实测高度）、
  `OrdoLayout.fabBottomInset = 68.dp`、`OrdoLayout.fabContentInset = 24.dp`

> **为什么外壳用的是 `fabContentInset` 而不是 `fabBottomInset`**：Android 的 FAB 挂在内容区（`Column` 里的 `Box(weight=1f)`）内，
> 而 App 状态栏是它的**下一个**兄弟节点 —— 内容区底边本身就是状态栏顶边，所以窗口规则 `statusBar + fabGlow`
> 落到内容区只剩 `fabGlow`；两者相加仍等于 68dp（顺序上也与宽屏三栏一致，不会压到详情列）。

**用例（新增 `QuickAddFabStyleTest`，10 条）**：颜色/柔光令牌（#0A84FF、35%/45%、同色通道）、柔光厚度与状态栏高度、
`fabBottomInset == statusBar + fabGlow` 且 `≥` 两者之和、`fabContentInset + statusBar == fabBottomInset`、
以及源码级断言（必须 `Brush.radialGradient` / `requiredSize` / `background(colors.fab)`，
**禁止** `ambientColor` / `spotColor` / 带色 shadow；OrdoShell 必须用 `fabContentInset`）。

真实构建/测试证据：

| 验证项 | 结果 |
|---|---|
| `assembleDebug` + `assembleRelease` + `testDebugUnitTest` | ✅ `BUILD SUCCESSFUL`；**10 个测试类 / 114 个用例全绿**（104 → 114，新增 10），0 failures / 0 errors |
| APK | ✅ debug `app-debug.apk` 15,758,950 B（14:59:20）· release `app-release.apk` 1,751,779 B（15:01:12） |
| 产物抽验 | ✅ dex 里含 `OrdoFabTokens`（新令牌类）与 `radialGradient` 引用 —— 证明包确实来自本轮源码 |
| `python tools/check-encoding.py` | ✅ `OK: no encoding problems found` |

**无法验证的部分（诚实标注）**：本机**没有 Android 设备/模拟器**，无法目视核对真实渲染 ——
柔光的实际观感（渐变范围、透明度在浅/深色下的强度）、FAB 与状态栏「本地」文字的最终间距、
以及长按/单击手感都只做了令牌与源码级保证，需在真机上回归一次。

### 7.8 本轮：清空本地数据 + 播种标记（Android 侧，2026-10-14）

**用户需求**：「安卓端和鸿蒙端加一个清除本地数据或者清除演示数据，跟 Windows 端一样的功能。」（Windows 端同日已先做完，本端按同一语义对齐）

**Windows 端暴露、三端同源的 bug**：播种判据把「库文件在不在」当了替身 —— 用户点「清空本地数据」后文件仍在、内容为空，于是重启后既不算全新安装（文件在）、也不会写演示数据，界面一直是空的，还得再点一次「重置为示例数据」。真机观感就是「清空后重启，数据没回来」。

**改法（与 Windows 端逐条对齐）**

| 项 | 位置 | 说明 |
|---|---|---|
| 播种判据收口到引擎 | `OrdoEngine.seedDemoData(force = false)`（`shared:core`，同日改） | 非 force 时要求「库为空 **且** 没播过种」（kv `ordo.seedMark` = `demo`）；`clearAll()` 把标记一起清掉 |
| 启动不再看文件 | `di/ServiceLocator.kt` 的 `init()` → `bindDataDir(dirId, seedIfEmpty = true)` | 删掉 `firstRun = !UserDataDir.dbFileFor(...).exists()`；由 `seedIfEmpty` 触发一次**引擎的**播种判定 |
| 清空入口 | `vm/OrdoViewModel.clearAllData()`（新）+ `ui/settings/SettingsScreen.kt` | 数据区第二个按钮「清空本地数据」（danger）+ 两步确认 `ConfirmStrip`；确认后 `engine.clearAll()` → 刷新界面 → 提示「已清空本地数据」 |
| 文案 | `res/values/strings.xml` | `settings_clear`「清空本地数据」/ `settings_clear_confirm`（点明"下次启动会回到全新安装状态"）/ `toast_cleared`「已清空本地数据」 |
| 语义边界 | 不动目录 | 清空 ≠ 卸载：`filesDir/<dirId>/ordo.db` 与目录 id 都保留，下次启动仍在同一工作区；与 Windows 端「清空只影响本机这一份」一致 |

**两条入口的语义必须严格区分（回归用例守的就是这个）**

- 「重置为示例数据」= 立刻写入演示数据（`force = true`），界面马上有内容；
- 「清空本地数据」= 清空 + 退回全新安装态，**下次冷启动**才重新播种；
- 用户自己逐条删空待办（标记还在）→ 永远不复活。

**用例（新增 `ClearDataReseedTest`，6 条）**：清空后冷启动重新播种 / 清空后再次冷启动不重复播种 / 用户自己逐条删空待办不复活 / 启动判据收口到引擎（源码级：不得再出现 `dbFileFor(...).exists()`、`loadSnapshot() == null`）/ 设置页确实挂了按钮且先确认再执行（含文案契约）/ 清空不动工作区目录。

真实构建/测试证据（JDK 21 + Android SDK 36 + Gradle 8.14，`--rerun` 强制重跑）：

| 验证项 | 结果 |
|---|---|
| `:apps:android:app:testDebugUnitTest` | ✅ `BUILD SUCCESSFUL`；**11 个测试类 / 120 个用例全绿**（114 → 120，新增 6），0 failures / 0 errors |
| 逐类结果（JUnit XML 汇总） | `ClearDataReseedTest` 6 · `NlpParsingTest` 29 · `GestureRulesTest` 17 · `QueryRulesTest` 15 · `QuickAddMenuTest` 12 · `QuickAddFabStyleTest` 10 · `RepeatEngineTest` 9 · `LocalAccountTest` 6 · `ProjectCompletionTest` 6 · `ComposerStateTest` 5 · `UserDataDirTest` 5 |
| 写入范围 | ✅ 只改 `apps/android/**`（`shared:core` 的播种标记属同日三端同修，在 Windows/鸿蒙侧各自记录） |

**无法验证的部分（诚实标注）**：本机**没有 Android 设备/模拟器**，「清空 → 杀进程 → 重开」只能由 JVM 单测模拟（同一份存储上重开引擎＝冷启动路径），按钮手感与真机重启后的观感仍需人工回归一次（见 §8 TODO）。

## 8. 后续 TODO

1. 长按拖拽排序（`detectDragGesturesAfterLongPress`）+ `engine.reorderTodos`。
2. 系统日历集成（`CalendarContract` 只读查询，替换 `SeedData.events`）。
3. 768–1099dp 档位的「侧栏图标条」形态（当前该档位直接常驻 248dp 侧栏）。
4. 项目改名 / 项目备注 / 标题改名的 UI 入口（core 已提供 `renameProject` / `setProjectNote` / `renameHeading` / `archiveHeading` / `deleteHeading`，当前仅项目完成与新建标题接了 UI）。
5. 真实设备上的对比度实测（04 文档 §2.1）与五张基线图截图回归（§9）。
6. `OrdoErrors.needsUpgrade` 的界面呈现（`VALIDATION_FAILED` 时提示升级客户端）。
7. 真机上人工回归本轮两个修复：项目卡片「完成项目/重新打开」分流、快加号浮层的聚焦/软键盘/返回键/Esc（§7.4）。
8. 真机上人工回归「清空本地数据 → 杀进程 → 重开」应重新出现演示数据；「逐条删空 → 重开」不应复活（§7.8）。
