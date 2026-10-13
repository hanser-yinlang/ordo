# 序 Ordo · Android 端（apps/android）

> 契约来源：[03 · 数据模型与同步协议](../../docs/03-数据模型与同步协议.md) · [04 · UI 设计规范](../../docs/04-UI设计规范.md)（FROZEN v1）
> 业务核心：KMP `shared:core`（**只调用、不修改**）· 交互参照：`things-clone/`（Web 原型，仅复用信息架构；名称/图标/配色一律按 04 文档的 Ordo 品牌）
> **v1.3 产品决策：不再需要登录** —— 启动即进主界面，云同步走**后台静默匿名会话**（无登录界面、无账号管理）。
> 规模：58 个 Kotlin 文件（44 主 + 14 测试）· 12 个测试类 / **129 个用例**（本机 `assembleDebug` + `testDebugUnitTest` 真实执行通过，见 §7.5）

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
./gradlew :apps:android:app:testDebugUnitTest    # 跑纯逻辑单测（NLP / 查询 / 重复 / 同步合并 / 项目完成 / 快加浮层 / 刷新控件 / 快加菜单 / 静默会话 / 数据目录）
./gradlew :apps:android:app:installDebug         # 安装到设备
```

产物：`apps/android/app/build/outputs/apk/debug/app-debug.apk`

### 1.3 运行配置

- **服务器地址是隐藏覆盖**（v1.3 起设置页没有输入框）：网络层固定读引导库 kv `ordo.serverUrl`，
  缺省值 `https://api.ordo.app`（`SqliteStorage.DEFAULT_SERVER_URL`）**不变**。本地联调改法见 §1.5。
- 深链：`ordo://list/today`、`ordo://todo/{id}`、`ordo://project/{id}`；点提醒通知即走 `ordo://todo/{id}`。
- 首次启动由 `OrdoEngine.seedDemoData()` 写入示例数据；「设置 → 数据 → 重置为示例数据」可恢复。

### 1.4 启动流程（v1.3：没有登录界面）

```
App 启动（OrdoApp.onCreate → ServiceLocator.init）
  ├─ 读引导库会话 session
  │    ├─ 有且未过期            → 挂 <userId> 账号目录，直接进主界面，后台静默 refresh + sync
  │    ├─ 有但 accessToken 过期 → 先 refresh
  │    │      ├─ 成功           → 用新会话进主界面
  │    │      ├─ 401（服务端否认）→ 静默 POST /v1/auth/guest 重建匿名账号后继续
  │    │      └─ 网络不可达/5xx  → 按"暂时同步不上"处理：离线继续用旧会话与旧目录
  │    └─ 无 / 残缺             → 先挂**临时工作区** filesDir/local-<deviceId>/（离线可用），
  │                              同时后台静默 guest 建匿名账号（1s→2s→…→60s 退避重试）
  └─ 匿名账号到手 → 认领（改名）临时工作区 → 挂 <userId> 目录 → 起实时通道 → 通知界面补一次同步
```

- **不阻塞启动、不弹任何界面**：网络不可达时照常进主界面（本地数据可读可写），后台退避重试直到拿到会话。
- **同步中遇 401**：`SyncScheduler` 判为 `NOT_LOGGED_IN` → 界面层静默调用
  `ServiceLocator.ensureAnonymousSession(replaceExisting = true)` 重建匿名会话，绝不出现登录页。
- **本地数据**：仍是 `filesDir/<userId>/ordo.db`（契约 §7.6.3 逐账号隔离），**不做任何旧数据迁移**；
  唯一的新动作是"认领"：首启离线期间写在 `filesDir/local-<deviceId>/` 的数据，在拿到匿名账号后
  **改名**为目标账号目录（幂等；目标已存在或源不存在时不动）。
- 引导库 `filesDir/ordo-bootstrap.db`（会话 / 设备标识 / 服务器地址）**必须保留**：读会话本身需要一份
  不属于任何账号的存储，`deviceId` 也必须跨账号稳定；去掉它会造成"先有 userId 才能读 session、
  先有 session 才知道 userId"的循环依赖，不是简化。

### 1.5 服务器地址的隐藏覆盖（本地联调）

v1.3 删除了设置页的服务器地址输入框，改成**只读 kv 的隐藏覆盖**（默认值不变）。三种改法：

1. **改默认值后重新构建**（最省事，推荐）：改 `data/SqliteStorage.kt` 里的
   `const val DEFAULT_SERVER_URL = "https://api.ordo.app"` → 本地后端地址，重新 `assembleDebug`。
2. **直接写引导库 kv**（不改代码，走的就是"仍读 kv"这条机制）：kv 表结构是 `kv(k TEXT PRIMARY KEY, v TEXT)`，
   键名 `serverUrl`，库文件 `filesDir/ordo-bootstrap.db`（设备上即 `/data/data/com.ordo.android/files/ordo-bootstrap.db`）：
   ```bash
   # 模拟器（debug 包可 run-as）
   adb shell run-as com.ordo.android sqlite3 files/ordo-bootstrap.db \
     "insert or replace into kv(k,v) values('serverUrl','http://10.0.2.2:8787');"
   # 设备上没有 sqlite3 时：拉到本地改完再推回
   adb exec-out run-as com.ordo.android cat files/ordo-bootstrap.db > ordo-bootstrap.db
   sqlite3 ordo-bootstrap.db "insert or replace into kv(k,v) values('serverUrl','http://10.0.2.2:8787');"
   adb push ordo-bootstrap.db /data/local/tmp/ && adb shell run-as com.ordo.android cp /data/local/tmp/ordo-bootstrap.db files/ordo-bootstrap.db
   ```
   改完**重启 App** 生效（`TokenStore.serverUrl()` 每次请求都会读 kv）。
3. **程序化写入口**（供将来的开发者工具调用）：`TokenStore.saveServerUrl(url)`。

模拟器访问宿主机用 `http://10.0.2.2:<port>`。

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
            │   ├── AuthApi.kt                          OrdoAuthApi : core AuthApi（v1.3 只用 guest/refresh；其余为实现共享接口所必需）
            │   ├── AuthErrors.kt                       契约 §7.4/§7.6.5 的 details（reason / retryAfterSec）解析
            │   ├── KtorSyncApi.kt (104)                KtorSyncApi : core SyncApi（401 自动 refresh 重放一次）
            │   ├── RealtimeClient.kt (116)             RealtimeClient : core RealtimeChannel（指数退避重连）
            │   ├── OrdoErrors.kt (33)                  契约 §7.4 错误码全集与应对策略
            │   └── TokenStore.kt                       kv 里的会话/令牌 + 服务器地址（v1.3 只由后台静默会话写）
            ├── auth/SilentSession.kt                   静默匿名会话纯逻辑（启动处置 / 401 判定 / 退避序列）
            ├── sync/SyncScheduler.kt (147)             前台 30s + 回前台 + 网络恢复；SYNC_SEQ_GAP 自动全量重同步
            ├── notify/Notifier.kt (70)                 ordo_reminders 渠道 + 深链 PendingIntent
            ├── notify/ReminderWorker.kt (123)          准点一次性任务 + 15 分钟周期兜底 + 已发记录
            ├── vm/UiState.kt / OrdoViewModel.kt        单向数据流，写操作全部经 OrdoEngine（v1.3 起无登录态）
            ├── vm/ComposerState.kt (63)                       快加浮层状态机（纯逻辑：打开/重复点击/关闭/提交）
            ├── vm/ProjectCompletion.kt (93)                   完成项目判定、文案选择与卡片主动作（纯逻辑，契约 §2.2 v1.1）
            ├── nav/Routes.kt (33) / OrdoNavHost.kt (61)       路由 ↔ 派生清单
            └── ui/
                ├── theme/Tokens.kt / Theme.kt                 04 文档 §2 令牌 + 浅深色 + 减弱动态效果
                ├── common/OrdoIcons.kt                        自绘矢量图标（不依赖图标扩展包、不用他人资产）
                ├── common/Components.kt                       复选框/进度环/胶囊/浮层/Toast/输入框/Markdown 预览
                ├── common/OrdoFormatter.kt (85)               日期词汇走 core 的 OrdoDate，界面文案走 strings.xml
                ├── shell/OrdoShell.kt / Sidebar.kt            应用根（v1.3 无登录门禁，直接三栏骨架）+ 侧栏 + 状态栏
                ├── list/ListScreen.kt (291) / TodoRow.kt (243) 大标题/分组/38dp 行/滑动操作/完成动效
                ├── detail/DetailCard.kt (365)                 标题/备注 Markdown/何时/截止/提醒/重复/移动/标签/清单
                ├── schedule/ScheduleSheet.kt (234)            自然语言 + 快捷项 + 提醒 + 月历 + 清除
                ├── search/FastFind.kt (223)                   快找浮层（↑↓/Enter/Esc）+ 搜索页
                ├── quickadd/QuickAdd.kt                       快加号 / 长按菜单（v1.3 图标对齐参照原型）
                └── settings/SettingsScreen.kt                 外观 / 数据 / 关于（**已删除账号/退出登录/服务器地址**）
        └── test/java/com/ordo/android/
            ├── FakeStorage.kt (37)     测试设施（固定时钟 + 引擎工厂；内存仓储已由 core 的 InMemoryStorage 取代）
            ├── TestStrings.kt (42)     只读解析 res/values/strings.xml（文案契约测试，不引入 Robolectric）
            ├── NlpParsingTest.kt (179) 契约 §5 逐条（今天/今晚/明天/大后天/N天后/N周后/N个月后/绝对日期/星期/周末/某天/时间/标签/综合）
            ├── QueryRulesTest.kt (223) 契约 §4 边界（收件箱/今天含逾期/今晚分区/14 天窗口与「更晚」/某天/日志簿/标签开关/进度/搜索/计数/演示数据规模）
            ├── RepeatEngineTest.kt (117) 契约 §6（fixed/afterCompletion/月末溢出/每年/新实例字段/清单重置/取消重复）
            ├── SyncMergeTest.kt (140)   契约 §7.3（LWW/完成不回滚/标签并集/删除墓碑/发件箱 ack/快照替换）
            ├── ProjectCompletionTest.kt (215) 契约 §2.2 v1.1（拒绝原因与文案带 N/标题未归档也允许完成+自动归档/归档 Op 与完成 Op/已完成态/取消不阻塞/卡片主动作）
            └── ComposerStateTest.kt (74) 快加浮层（打开状态正确/已打开时再点加号不丢草稿且重新聚焦/空标题不产生待办/关闭再开是新的一轮）
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
| 快加号 | `ui/quickadd/QuickAdd.kt`、`vm/ComposerState.kt` | 单击新建（NLP 解析日期/时间/标签）、长按菜单（待办/项目/区域）；打开即聚焦+弹键盘，已打开时再点是"重新聚焦"而不是空操作，返回键/Esc 关闭且不产生空待办 |
| 项目完成 | `ui/list/ListScreen.kt`、`vm/ProjectCompletion.kt` | 契约 §2.2 v1.1：唯一硬约束是"项目下没有未完成的待办"，标题未归档由引擎自动归档；拒绝文案带 N 且不提「标题」；已完成项目显示「已完成 + 重新打开」而不是「完成项目」 |
| 路由 | `nav/Routes.kt`、`OrdoNavHost.kt` | inbox/today/upcoming/anytime/someday/logbook/project/{id}/area/{id}/tag/{name}/search |
| 本地存储(SQLite) | `data/SqliteStorage.kt`、`data/LocalAccount.kt`、`data/UserDataDir.kt` | 实体按 **JSON 快照整行**存放(`entities(entity,id,payload,updated_at,deleted)`),与服务端 `entities` 表同构(架构 ADR-004);字段名与契约 §2 永远一致,无需映射代码,契约加字段也不用迁移;outbox 主键 `op_id` 天然幂等;kv 存 schemaVersion/serverSeq/令牌。**目录 id 是本机钉住的**（契约 §7.6.6），不是服务端 userId |
| 静默匿名会话 | `auth/SilentSession.kt`、`di/ServiceLocator.kt`、`vm/OrdoViewModel.kt` | 启动读会话 → 有效直接用 / 过期先 refresh / 否则静默 `POST /v1/auth/guest`；网络不可达也进主界面（离线可用），后台 1s→2s→…→60s 退避重试；同步 401 → 先确认是否真的被否认，是则静默重建匿名会话（本地目录不变） |
| Ktor 同步 + 401 重放 | `net/KtorSyncApi.kt`、`net/AuthApi.kt` | 3 个同步端点 + 认证端点 guest/refresh（v1.3 实际只用到这两个）+ 设备注册；DTO 直接复用 core 的 `@Serializable` 定义 |
| WebSocket 实时通道 | `net/RealtimeClient.kt` | hello/ops/reminder/ping；上行 subscribe/ack/pong；退避 1s→2s→…→60s |
| 同步调度 | `sync/SyncScheduler.kt` | 三个触发源；动作委托 `SyncEngine(engine, api).syncOnce()`；错误码分流（SEQ_GAP→全量、AUTH→静默修复会话、RATE_LIMITED→退避） |
| 提醒 | `notify/Notifier.kt`、`ReminderWorker.kt` | `ordo_reminders` 渠道；准点一次性任务 + 15 分钟周期兜底；点击深链打开待办 |
| 深链 | `AndroidManifest.xml`、`MainActivity.kt` | `ordo://` scheme，`Routes.fromDeepLink` 解析 |
| 单元测试 | `src/test/**` | 12 个测试类 / 129 个用例，全部只依赖 `shared:core`，不依赖 Android 框架；用 `FixedOrdoClock` 固定"今天"，断言完全确定 |

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

## 8. 后续 TODO

1. 长按拖拽排序（`detectDragGesturesAfterLongPress`）+ `engine.reorderTodos`。
2. 系统日历集成（`CalendarContract` 只读查询，替换 `SeedData.events`）。
3. 768–1099dp 档位的「侧栏图标条」形态（当前该档位直接常驻 248dp 侧栏）。
4. 项目改名 / 项目备注 / 标题改名的 UI 入口（core 已提供 `renameProject` / `setProjectNote` / `renameHeading` / `archiveHeading` / `deleteHeading`，当前仅项目完成与新建标题接了 UI）。
5. 真实设备上的对比度实测（04 文档 §2.1）与五张基线图截图回归（§9）。
6. `OrdoErrors.needsUpgrade` 的界面呈现（`VALIDATION_FAILED` 时提示升级客户端）。
7. 真机上人工回归本轮两个修复：项目卡片「完成项目/重新打开」分流、快加号浮层的聚焦/软键盘/返回键/Esc（§7.4）。
