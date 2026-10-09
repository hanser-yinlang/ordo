# 序 Ordo · Android 端（apps/android）

> 契约来源：[03 · 数据模型与同步协议](../../docs/03-数据模型与同步协议.md) · [04 · UI 设计规范](../../docs/04-UI设计规范.md)（FROZEN v1）
> 业务核心：KMP `shared:core`（**只调用、不修改**）· 交互参照：`things-clone/`（Web 原型，仅复用信息架构；名称/图标/配色一律按 04 文档的 Ordo 品牌）
> 规模：40 个 Kotlin 文件 / 约 7.1k 行 · 4 个测试类（60 个用例，本机已真实编译并执行通过）· 合入主控的 `tools/contract-check.mjs` 全部适用项通过

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
./gradlew :apps:android:app:testDebugUnitTest    # 跑 4 个测试类（NLP / 查询 / 重复 / 同步合并）
./gradlew :apps:android:app:installDebug         # 安装到设备
```

产物：`apps/android/app/build/outputs/apk/debug/app-debug.apk`

### 1.3 运行配置

- 服务器默认 `https://api.ordo.app`（`SqliteStorage.DEFAULT_SERVER_URL`），可在「设置 → 账号 → 服务器地址」改成本地后端；模拟器访问宿主机用 `http://10.0.2.2:<port>`。
- 深链：`ordo://list/today`、`ordo://todo/{id}`、`ordo://project/{id}`；点提醒通知即走 `ordo://todo/{id}`。
- 首次启动由 `OrdoEngine.seedDemoData()` 写入示例数据；「设置 → 数据 → 重置为示例数据」可恢复。

## 2. 工程结构

```
apps/android/
├── README.md
└── app/
    ├── build.gradle.kts                compileSdk 36 / minSdk 26 / Compose(BOM) / BuildConfig 常量
    ├── proguard-rules.pro              保留 core 公开面、Ktor、Worker
    └── src/
        ├── main/AndroidManifest.xml (39)   权限(INTERNET/POST_NOTIFICATIONS/RECEIVE_BOOT_COMPLETED/ACCESS_NETWORK_STATE) + ordo:// 深链
        ├── main/res/                       strings(202 行中文文案) / colors / themes + values-night / 自适应图标 / 通知图标
        └── main/java/com/ordo/android/
            ├── OrdoApp.kt (14)                         Application：装配 + 通知渠道 + 提醒任务
            ├── MainActivity.kt (84)                    单 Activity + 深链解析 + 通知权限 + 前后台同步钩子
            ├── di/ServiceLocator.kt (89)               手工装配（OrdoEngine / Ktor / Scheduler / Realtime）
            ├── data/
            │   ├── SqliteStorage.kt (283)               OrdoStorage 实现（原生 SQLite：entities/outbox/tombstones/kv）
            │   ├── SeedData.kt (20)                    示例数据入口（内容来自 core，避免两份数据）
            │   ├── SettingsStore.kt (34)               DataStore：外观 / 服务器地址 / 上次同步
            │   └── ModelExt.kt (15)                    `when` 反引号访问（单点适配）
            ├── net/
            │   ├── HttpClientFactory.kt (43)           OkHttp 引擎 + 统一请求头 + 超时 + WebSocket
            │   ├── Dto.kt (75)                         统一请求头 / 错误模型解析 / WS 帧
            │   ├── AuthApi.kt (69)                     OrdoAuthApi : core AuthApi（含 logout/refreshSaved）
            │   ├── KtorSyncApi.kt (104)                KtorSyncApi : core SyncApi（401 自动 refresh 重放一次）
            │   ├── RealtimeClient.kt (116)             RealtimeClient : core RealtimeChannel（指数退避重连）
            │   ├── OrdoErrors.kt (33)                  契约 §7.4 错误码全集与应对策略
            │   └── TokenStore.kt (32)                  kv 里的令牌（deviceId/lastServerSeq 由 core 维护）
            ├── sync/SyncScheduler.kt (147)             前台 30s + 回前台 + 网络恢复；SYNC_SEQ_GAP 自动全量重同步
            ├── notify/Notifier.kt (70)                 ordo_reminders 渠道 + 深链 PendingIntent
            ├── notify/ReminderWorker.kt (123)          准点一次性任务 + 15 分钟周期兜底 + 已发记录
            ├── vm/UiState.kt (173) / OrdoViewModel.kt (707)   单向数据流，写操作全部经 OrdoEngine
            ├── nav/Routes.kt (33) / OrdoNavHost.kt (61)       路由 ↔ 派生清单
            └── ui/
                ├── theme/Tokens.kt (186) / Theme.kt (97)      04 文档 §2 令牌 + 浅深色 + 减弱动态效果
                ├── common/OrdoIcons.kt (277)                  29 个自绘图标（不依赖图标扩展包、不用他人资产）
                ├── common/Components.kt (528)                 复选框/进度环/胶囊/浮层/Toast/Markdown 预览
                ├── common/OrdoFormatter.kt (85)               日期词汇走 core 的 OrdoDate，界面文案走 strings.xml
                ├── shell/OrdoShell.kt (261) / Sidebar.kt (299) 三栏骨架 + 侧栏（计数/进度环/标签）+ 状态栏 + 浮层
                ├── list/ListScreen.kt (291) / TodoRow.kt (243) 大标题/分组/38dp 行/滑动操作/完成动效
                ├── detail/DetailCard.kt (365)                 标题/备注 Markdown/何时/截止/提醒/重复/移动/标签/清单
                ├── schedule/ScheduleSheet.kt (234)            自然语言 + 快捷项 + 提醒 + 月历 + 清除
                ├── search/FastFind.kt (223)                   快找浮层（↑↓/Enter/Esc）+ 搜索页
                ├── quickadd/QuickAdd.kt (196)                 快加号 / 长按菜单 / 新建输入
                └── settings/SettingsScreen.kt (213)           外观 / 数据 / 账号 / 关于
        └── test/java/com/ordo/android/
            ├── FakeStorage.kt (37)     测试设施（固定时钟 + 引擎工厂；内存仓储已由 core 的 InMemoryStorage 取代）
            ├── NlpParsingTest.kt (179) 契约 §5 逐条（今天/今晚/明天/大后天/N天后/N周后/N个月后/绝对日期/星期/周末/某天/时间/标签/综合）
            ├── QueryRulesTest.kt (223) 契约 §4 边界（收件箱/今天含逾期/今晚分区/14 天窗口与「更晚」/某天/日志簿/标签开关/进度/搜索/计数/演示数据规模）
            ├── RepeatEngineTest.kt (117) 契约 §6（fixed/afterCompletion/月末溢出/每年/新实例字段/清单重置/取消重复）
            └── SyncMergeTest.kt (140)   契约 §7.3（LWW/完成不回滚/标签并集/删除墓碑/发件箱 ack/快照替换）
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
| 快加号 | `ui/quickadd/QuickAdd.kt` | 单击新建（NLP 解析日期/时间/标签）、长按菜单（待办/项目/区域） |
| 路由 | `nav/Routes.kt`、`OrdoNavHost.kt` | inbox/today/upcoming/anytime/someday/logbook/project/{id}/area/{id}/tag/{name}/search |
| 本地存储(SQLite) | `data/SqliteStorage.kt` | 实体按 **JSON 快照整行**存放(`entities(entity,id,payload,updated_at,deleted)`),与服务端 `entities` 表同构(架构 ADR-004);字段名与契约 §2 永远一致,无需映射代码,契约加字段也不用迁移;outbox 主键 `op_id` 天然幂等;kv 存 schemaVersion/serverSeq/令牌 |
| Ktor 同步 + 401 重放 | `net/KtorSyncApi.kt`、`AuthApi.kt` | 3 个同步端点 + 认证 4 端点 + 设备注册；DTO 直接复用 core 的 `@Serializable` 定义 |
| WebSocket 实时通道 | `net/RealtimeClient.kt` | hello/ops/reminder/ping；上行 subscribe/ack/pong；退避 1s→2s→…→60s |
| 同步调度 | `sync/SyncScheduler.kt` | 三个触发源；动作委托 `SyncEngine(engine, api).syncOnce()`；错误码分流（SEQ_GAP→全量、AUTH→登录态、RATE_LIMITED→退避） |
| 提醒 | `notify/Notifier.kt`、`ReminderWorker.kt` | `ordo_reminders` 渠道；准点一次性任务 + 15 分钟周期兜底；点击深链打开待办 |
| 深链 | `AndroidManifest.xml`、`MainActivity.kt` | `ordo://` scheme，`Routes.fromDeepLink` 解析 |
| 单元测试 | `src/test/**` | 4 个测试类，全部只依赖 `shared:core`，不依赖 Android 框架；用 `FixedOrdoClock` 固定"今天"，断言完全确定 |

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
| 演示数据 | `engine.seedDemoData(force)` | 首次启动写入；设置里「重置为示例数据」传 `force = true` |

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

### 7.1 已完成的真实验证

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

`assembleDebug` / `testDebugUnitTest`（Gradle 全量构建）、Lint、真机或模拟器运行、04 文档 §9 的五张基线图截图回归——均需要 Android SDK，本机不具备。

未覆盖的代码约 4.5k 行：Compose UI（`ui/**`）、`data/SqliteStorage.kt`（需 `android.database`）、Android 胶水（`OrdoApp`、`MainActivity`、`di/ServiceLocator`、`notify/**`、`sync/SyncScheduler`、`net/{AuthApi,KtorSyncApi,RealtimeClient,TokenStore,HttpClientFactory}`）。

### 7.3 已知风险

1. **Compose 版本差异**：`ThemeMode.entries` 需要 Kotlin ≥ 1.9；Compose BOM 已固定在根 `libs.versions.toml`（`composeBom = "2026.09.00"`）。
2. **首次构建**：`compileSdk = 36` / AGP 9.4.1 / Kotlin 2.4.20；需 Android Studio 与 SDK 36。
3. **SQLite 整表写入**：`saveSnapshot` 采用"事务内清表 + 全量重写"，演示与常见规模（数千条）为毫秒级；若单账号上万条，建议改为按实体增量 upsert（`OrdoStorage` 接口不变）。
4. **WorkManager 与单例**：`ReminderWorker` 通过 `ServiceLocator` 取依赖，默认进程内单例；若未来把 Worker 拆到独立进程，需要改为显式注入。
5. **拖拽排序未实现**：04 文档 Android 列要求「长按拖拽」，当前实现是左右滑动（排期/删除）+ 点击详情；`order` 字段与 `engine.reorderTodos(ids)` 已就绪。
6. **未使用实验性 Compose API**：无 `TopAppBar`/`ModalBottomSheet`/`combinedClickable`/`animateItem`；只用 `Text`/`Surface` 级稳定 API 与 Foundation（`BoxWithConstraints`、`detectTapGestures`、`detectHorizontalDragGestures`、`onPreviewKeyEvent` 均为稳定 API）。

## 8. 后续 TODO

1. 长按拖拽排序（`detectDragGesturesAfterLongPress`）+ `engine.reorderTodos`。
2. 系统日历集成（`CalendarContract` 只读查询，替换 `SeedData.events`）。
3. 768–1099dp 档位的「侧栏图标条」形态（当前该档位直接常驻 248dp 侧栏）。
4. 项目改名 / 项目备注 / 标题改名的 UI 入口（core 已提供 `renameProject` / `setProjectNote` / `renameHeading` / `archiveHeading` / `deleteHeading`，当前仅项目完成与新建标题接了 UI）。
5. 真实设备上的对比度实测（04 文档 §2.1）与五张基线图截图回归（§9）。
6. `OrdoErrors.needsUpgrade` 的界面呈现（`VALIDATION_FAILED` 时提示升级客户端）。
