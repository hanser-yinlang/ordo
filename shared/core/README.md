# shared/core · Ordo 共享核心(Kotlin Multiplatform)

> **业务规则的唯一实现**。Android / Windows 两端直接消费本模块;鸿蒙端因运行时限制,按同一份契约([docs/03](../../docs/03-数据模型与同步协议.md))用 ArkTS 重写,并由 `tools/contract-check.mjs` 对齐。

---

## 1. 目标平台

| 目标 | 启用条件 | 用途 |
|---|---|---|
| `jvm()` | 始终 | Windows 桌面端 + 单元测试(本机可跑) |
| `androidTarget()` | 存在 `ANDROID_HOME` / `ANDROID_SDK_ROOT` / `local.properties` | Android 端 |

条件化设计的目的:**没有 Android SDK 的环境也能构建核心并跑全部测试**。

```bash
gradle :shared:core:jvmTest        # 单元测试
```

## 2. 模块结构

```
src/commonMain/kotlin/com/ordo/core/
├── model/     Entities.kt(契约 §2 全部实体与枚举)· Op.kt(同步操作与墓碑)
├── util/      OrdoDate(纯 Kotlin 日期引擎)· Ids(UUID/ULID)· OrdoJson
├── platform/  PlatformTime(expect/actual:仅"当前毫秒 + 时区偏移"两件事)
├── nlp/       NaturalDateParser(契约 §5 中文自然语言)
├── repeat/    RepeatEngine(契约 §6)
├── query/     ListQuery + QueryEngine(契约 §4 派生清单)
├── storage/   OrdoStorage 接口 + InMemoryStorage + OpCodec
├── store/     OrdoEngine(门面:写操作 / 不变量 / applyRemote / outbox)
├── sync/      SyncApi(DTO)· SyncEngine(push/pull/快照)· RealtimeChannel
└── seed/      SeedData(4 区域 / 5 项目 / 3 标题 / 7 标签 / 34 待办 / 3 日历事件)
```

依赖方向严格单向:`model ← util ← {nlp, repeat, query, storage} ← store ← sync`。

## 3. 设计要点

| 决策 | 原因 |
|---|---|
| 不依赖 `kotlinx-datetime` | 避免其 0.7.x 的 `Instant`/`Clock` 迁移风险;自研日期引擎只有 ~200 行,三端逐位一致且可确定性测试 |
| 只有两个 `expect/actual` | 平台差异被压缩到"当前毫秒 + 时区偏移",其余全是 common 代码 |
| `OrdoClock` 可注入 | 核心规则 100% 可确定性测试(不依赖真实时间) |
| 实体即 JSON 即存储字段 | 消除"模型-存储-协议"三套映射;契约加字段无需数据库迁移 |
| `when` 用反引号 | Kotlin 硬关键字;`todo.\`when\`` 与契约字段名保持完全一致 |

## 4. 主要 API

```kotlin
val engine = OrdoEngine(storage)                       // storage 由各端实现
engine.seedDemoData(force = false)                     // 首次启动写入演示数据
engine.subscribe { snapshot -> /* 界面重组 */ }          // 订阅即可拿到全量快照

// 派生清单(契约 §4)
engine.list(ListQuery.Today)
engine.sections(ListQuery.ProjectScope("p-launch"))
engine.counts()                                        // 侧栏计数与项目进度

// 写操作(全部本地优先,自动产出 Op 进 outbox)
engine.createTodo("明天 18:00 交季度报告 #重要")           // 内部走中文 NLP
engine.setWhen(id, When.DATE, "2026-10-09")
engine.setReminder(id, "2026-10-09T18:00")
engine.toggleDone(id)                                  // 重复待办自动生成下一次
engine.moveTodo(id, projectId = "p-web", areaId = null, headingId = null)

// 同步(契约 §7)
SyncEngine(engine, api).syncOnce()                     // push → 应用捎带 ops → pull 循环
engine.applyRemote(ops)                                // LWW / 完成不回滚 / 标签并集 / 清单合并 / 墓碑
```

## 5. 测试

| 测试类 | 用例 | 覆盖 |
|---|---|---|
| `NlpParsingTest` | 18 | 契约 §5:全部日期/时间/标签写法、标题清理、优先级 |
| `QueryRulesTest` | 17 | 契约 §4 + §3 不变量:六个清单、今晚分区、14 天窗口、项目分组、标签开关、计数一致性、移入项目与设提醒的副作用 |
| `RepeatEngineTest` | 7 | 契约 §6:月末溢出、闰年、fixed/afterCompletion、清单重置、完成后不生成(非重复) |
| `SyncMergeTest` | 11 | 契约 §7.3/§7.4:幂等、LWW、完成不可回滚、标签并集、清单合并、墓碑防复活、outbox ack、快照替换、SyncEngine 往返 |

```bash
gradle :shared:core:jvmTest
# BUILD SUCCESSFUL —— 4 个测试类 / 53 个用例 / 0 失败
```

## 6. 给各端的接入提示

1. 实现 `OrdoStorage`(Android 见 `SqliteStorage`,Windows 见 `JsonFileStorage`)。
2. 在应用启动时构造一次 `OrdoEngine` 并持有;所有写操作都经它,不要绕过写本地库。
3. UI 订阅 `subscribe {}` 或各端包装成 `StateFlow`/`@Observable`;派生清单永远用 `list/sections`,不要自己在 UI 里过滤。
4. 网络实现 `SyncApi`/`RealtimeChannel`,交给 `SyncEngine`;不要在端上重复实现冲突合并。
