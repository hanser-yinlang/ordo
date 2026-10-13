# 02 · 系统架构设计(SAD)

> **变更(2026-10-13)**:iOS 端已按要求**整体移除**(apps/ios 与共享核心的 Apple 目标一并删除),
> 涉及 iOS 的描述仅作历史记录;云同步也已从客户端移除 —— 当前为 **Windows / Android / 鸿蒙三端纯本地应用**。

| 项 | 内容 |
|---|---|
| 系统 | Ordo(序)多端个人任务管理器 |
| 版本 | v1.0(2026-10-08) |
| 关联 | [03 契约](03-数据模型与同步协议.md) · [04 UI 规范](04-UI设计规范.md) |
| 架构风格 | **共享核心 + 原生 UI(Share-Core / Thin-Client)**,本地优先(Local-First),事件驱动同步 |

---

## 1. 架构总览

### 1.1 系统上下文

```
                    ┌──────────────────────────────────────────┐
                    │            用户(单人多设备)               │
                    └───────┬──────────┬──────────┬────────────┘
                            │          │          │
                   ┌────────▼───┐ ┌────▼─────┐ ┌──▼────────┐ ┌──────────────┐
                   │  Android   │ │   iOS    │ │  Windows  │ │   鸿蒙        │
                   │ Kotlin +   │ │ Swift +  │ │ Kotlin +  │ │ ArkTS +      │
                   │ Compose    │ │ SwiftUI  │ │ Compose   │ │ ArkUI        │
                   └─────┬──────┘ └────┬─────┘ └─────┬─────┘ └──────┬───────┘
                         │             │             │              │
                ┌────────▼─────────────▼─────────────▼──┐           │
                │   KMP 共享核心 shared/core             │    ArkTS 契约实现
                │   模型 · 查询 · NLP · 重复 · 同步 · 存储抽象│    (同一契约,独立实现)
                └────────────────┬──────────────────────┘           │
                                 │  HTTPS + WSS(契约 §7)            │
                                 └──────────────┬───────────────────┘
                                                ▼
                                 ┌──────────────────────────────┐
                                 │   Ordo Sync(自研后端)         │
                                 │   Fastify · PostgreSQL · WS  │
                                 │   增量同步 · Fastlane · 认证   │
                                 └──────────────────────────────┘
                                        设备本地:SQLite / SwiftData / RDB / JSON
```

### 1.2 容器职责

| 容器 | 技术 | 职责 | 不负责 |
|---|---|---|---|
| 共享核心 `shared/core` | Kotlin Multiplatform | 数据模型、派生清单、NLP、重复引擎、同步合并、存储接口 | UI、网络实现、系统能力 |
| Android 端 | Kotlin + Jetpack Compose | UI/导航、SQLite 存储、Ktor 网络、WorkManager 提醒 | 业务规则(来自核心) |
| iOS 端 | Swift + SwiftUI | UI/导航、SwiftData 存储、URLSession 网络、本地通知 | 业务规则(来自核心,经 XCFramework) |
| 鸿蒙端 | ArkTS + ArkUI | UI/导航、RelationalStore、`@ohos.net` 网络、reminderAgent | 业务规则(ArkTS 按契约重写) |
| Windows 端 | Kotlin + Compose Desktop | UI/导航、文件仓储、Ktor 网络、托盘通知 | 业务规则(来自核心) |
| 后端 `server` | TypeScript + Fastify + PostgreSQL | 认证、增量同步、快照、实时推送、Fastlane 提醒 | 业务规则解释(只做 LWW/并集等存储侧校验) |

### 1.3 关键架构决策(为什么这样分层)

> 完整 ADR 见 §6。三条核心原则:

1. **本地优先**:任何写操作先落本地库并立刻返回 UI,网络只是复制通道 → 离线可用、交互零延迟。
2. **契约先行**:四端与后端只通过 `docs/03` 的字段/接口/规则耦合;鸿蒙端无法复用 Kotlin 二进制,因此**用同一份契约独立实现**,并由契约测试对齐。
3. **薄客户端**:客户端不解释业务规则(清单筛选、NLP、重复)以外的同步语义,冲突合并规则在客户端与服务端各实现一次但必须逐条一致。

---

## 2. 共享核心设计(KMP)

### 2.1 模块划分与依赖方向

```
shared/core/src/commonMain/kotlin/com/ordo/core/
├── model/        Entities.kt(实体与枚举) · Op.kt(同步操作/墓碑)      ← 无依赖
├── util/         OrdoDate(纯 Kotlin 日期引擎) · Ids(UUID/ULID) · OrdoJson
├── platform/     PlatformTime(expect)                                ← 仅 jvm/android/ios actual
├── nlp/          NaturalDateParser(契约 §5)
├── repeat/       RepeatEngine(契约 §6)
├── query/        ListQuery · QueryEngine(契约 §4)
├── storage/      OrdoStorage(接口) · InMemoryStorage · OpCodec
├── store/        OrdoEngine(门面:写操作 + applyRemote + outbox)
├── sync/         SyncApi(DTO/接口) · SyncEngine(push/pull/快照) · RealtimeChannel
└── seed/         SeedData(演示数据)

依赖方向(严格单向,禁止反向引用):
   model ← util ← { nlp, repeat, query, storage } ← store ← sync
                                  ↑
                            platform(仅 util 使用)
```

**设计要点**

- 不依赖 `kotlinx-datetime`:日期用纯 Kotlin 实现(Hinnant 算法),避免多端 API 漂移,四端结果逐位一致。
- 仅两个 `expect/actual`(`nowMillis` / `utcOffsetMillis`),其余全部 common 代码。
- 所有实体 `@Serializable`,JSON 即传输格式即本地存储字段名,消除"模型-存储-协议"三套映射。
- 时间注入:`OrdoClock` 可注入固定时钟,使核心规则 100% 可确定性测试。

### 2.2 写操作数据流(以"勾选完成"为例)

```
UI 事件
  │  engine.complete(id)
  ▼
OrdoEngine ──①改内存快照 ──②storage.saveSnapshot ──③产出 Op 入 outbox ──④notifyListeners
  │                                                                        │
  │                                                                        ▼
  │                                                           四端各自的 UI 重组(Compose/SwiftUI/ArkUI)
  ▼
SyncEngine.syncOnce()  ──push(outbox)──►  服务端(幂等 op_id + LWW)
        ▲                                        │
        └────────── pull / WS ops ◄───────────────┘
```

### 2.3 平台目标矩阵

| 目标 | 启用条件 | 用途 |
|---|---|---|
| `jvm()` | 始终 | Windows 桌面端、共享核心单元测试 |
| `androidTarget()` | 存在 `ANDROID_HOME`/`local.properties` | Android 端 |
| `iosX64/iosArm64/iosSimulatorArm64` + `OrdoCore.framework` | 主机为 macOS | iOS 端(XCFramework) |

> 该条件化设计使**没有 Android SDK / 非 macOS 的环境也能构建核心并跑全部测试**,CI 中按需开启对应目标。

---

## 3. 客户端分层(四端统一)

```
┌─────────────────────────────────────────────────────────────┐
│ 表现层 UI        Compose / SwiftUI / ArkUI                   │
│   侧栏 · 清单 · 详情卡片 · 排期面板 · 快找 · 快加号 · 设置        │
├─────────────────────────────────────────────────────────────┤
│ 状态层           ViewModel / ObservableObject / @State       │
│   UiState(当前路由 + 列表分组 + 选中项 + 主题)                  │
│   仅做"把快照映射成界面状态",不含业务规则                          │
├─────────────────────────────────────────────────────────────┤
│ 领域层           OrdoEngine(共享核心)/ ArkTS OrdoEngine        │
│   写操作 API · 派生清单 · NLP · 重复 · 冲突合并                   │
├─────────────────────────────────────────────────────────────┤
│ 数据层           OrdoStorage 实现 + outbox + tombstones + kv   │
│   Android: SQLiteOpenHelper · iOS: SwiftData ·              │
│   鸿蒙: RelationalStore · Windows: JSON 文件仓储               │
├─────────────────────────────────────────────────────────────┤
│ 网络层           SyncApi 实现 + RealtimeChannel               │
│   Ktor / URLSession / @ohos.net.http + WebSocket            │
├─────────────────────────────────────────────────────────────┤
│ 系统集成层        提醒调度 · 深链 · 主题 · 无障碍 · 分享/导出        │
│   WorkManager / UNNotification / reminderAgent / 托盘通知     │
└─────────────────────────────────────────────────────────────┘
```

**状态管理约定**:UI 只读 `UiState`;所有变更调用领域层方法;领域层变更后通过订阅回调触发 UI 重组(单向数据流)。

---

## 4. 同步架构

### 4.1 时序(多设备一致性)

```
设备 A                      服务端                        设备 B
  │  ① 本地写 + outbox                                       │
  │  ② POST /v1/sync/push {ops}                              │
  │ ─────────────────────────►│                              │
  │                           │ ③ 幂等校验(op_id 唯一)        │
  │                           │ ④ LWW 比较 clientTs          │
  │                           │ ⑤ 追加 ops(serverSeq++)      │
  │                           │ ⑥ 更新 reminders 索引         │
  │  ◄── 200 {serverSeq, accepted, ops[]}                    │
  │  ⑦ 应用远端 ops + 清空已 ack 的 outbox                     │
  │                           │ ⑧ WS 推送 {type:"ops"}        │
  │                           │ ────────────────────────────►│
  │                           │                              │ ⑨ 应用 ops → UI 更新
  │                           │ ⑩ 快车道:每 1s 扫描未来 60s 提醒 │
  │                           │ ── {type:"reminder"} ───────►│ ⑪ 本地通知
```

### 4.2 冲突处理位置与职责

| 规则 | 服务端 | 客户端 |
|---|---|---|
| 幂等(op_id) | ✅ 唯一索引 | 生成 ULID,重试不换 id |
| LWW(clientTs) | ✅ 决定是否落库 | ✅ 决定是否应用远端 op |
| 完成不可回滚 | ✅ 存储侧校验 | ✅ 合并侧校验 |
| 标签并集 / 清单项合并 | 存储合并 | 合并后落本地 |
| 墓碑 | ✅ 保留 30 天 | ✅ 本地墓碑集合防复活 |

### 4.3 失败与重试

| 场景 | 行为 |
|---|---|
| 网络不可用 | outbox 保留,指数退避重试(1s→2s→4s→…→5min 封顶) |
| 401 令牌过期 | 自动 refresh 并重放一次;refresh 失败 → 转登录态但**保留本地数据** |
| 409/seq 缺口 | 触发全量快照重建(`fullResync`) |
| 单 op 过大/非法 | 服务端 rejected 返回,客户端出队并记日志(不阻塞其它 op) |

---

## 5. 后端架构

### 5.1 分层

```
HTTP 路由(校验 zod)  ──►  服务层(auth / sync / realtime / reminders)
                                   │
                         仓储接口 Repository
                          ├── PgRepository(生产,PostgreSQL)
                          └── MemoryRepository(开发与测试)
                                   │
                      Postgres: users · devices · refresh_tokens
                                entities · ops · reminders
```

### 5.2 关键索引与扩展性

- `ops(user_id, server_seq)` 支撑增量拉取;`ops.op_id` 唯一索引保证幂等。
- `entities(user_id, entity, entity_id)` 唯一索引 + `payload jsonb`,避免为每类实体建表。
- `reminders(user_id, at) where fired = false` 部分索引支撑快车道扫描。
- 水平扩展:serverSeq 每用户单调递增,天然可按键分片;WS 连接层可独立扩容并用 Redis Pub/Sub 广播(二期)。
- 容量目标:单实例 5k 并发 WS 连接、10k op/s 写入(内存仓储下测试口径)。

---

## 6. 架构决策记录(ADR)

| ID | 决策 | 备选 | 理由 | 代价 |
|---|---|---|---|---|
| ADR-001 | 共享核心用 KMP,UI 各端原生 | Flutter 一套 UI / 四端全原生 | 业务规则只写一遍;UI 保留平台体验;鸿蒙用契约对齐 | 需维护 iOS 桥接层 |
| ADR-002 | 鸿蒙端不复用 KMP,ArkTS 重写核心 | 等 KMP 支持 ArkTS 运行时 | 当前无官方互操作路径 | 一套逻辑两份实现,靠契约测试对齐 |
| ADR-003 | 核心不依赖 kotlinx-datetime | 直接用 kotlinx-datetime | 避免 0.7.x 的 Instant/Clock API 迁移风险 | 自研日期引擎需自测(已覆盖闰年/月末) |
| ADR-004 | 统一 `payload jsonb` 存实体 | 每实体一张表 | 同步协议天然以实体为单位;迁移成本低 | 失去部分数据库级约束 |
| ADR-005 | 客户端本地库不强制同构(Room/SwiftData/RDB/文件) | 统一 SQLDelight | 尊重平台原生栈与团队熟悉度 | 存储层四份实现,但接口统一 |
| ADR-006 | 冲突用 LWW + 字段级特例 | CRDT | 实现与调试成本低,符合个人任务场景 | 极端并发下可能丢一次标题修改 |
| ADR-007 | 提醒走独立 Fastlane 通道 | 复用批量同步 | 提醒是时间敏感数据,延迟直接影响体验 | 服务端多一个扫描循环与索引 |
| ADR-008 | 条件化 Gradle 目标 | 固定全平台目标 | 无 SDK/非 macOS 环境也能构建与测试核心 | 构建脚本分支增加,需文档说明 |

---

## 7. 非功能设计

| 维度 | 设计 |
|---|---|
| 性能 | 查询在内存快照上执行,O(n) 扫描 + 预分组;3000 条量级毫秒级;UI 只重组受影响分组 |
| 一致性 | 单一数据源(快照)+ 派生视图;禁止 UI 侧缓存业务状态 |
| 可测试性 | 时钟/ID/网络全部可注入;核心规则纯函数化 |
| 可观测性 | 客户端:同步结果与错误码写入本地日志;服务端:结构化日志 + `/v1/health` |
| 安全 | 见契约 §9;令牌最小化存储,日志脱敏 |
| 可维护性 | 契约单一事实来源;字段名三处同名(模型/存储/协议) |
| 可移植性 | Windows 端可整体切换到其它 JVM 桌面环境;核心可复用到未来的 Web(Wasm)目标 |

---

## 8. 演进路线(二期及以后)

1. **Watch / Vision 端**:以共享核心 + 轻量 UI 快速补齐。
2. **端到端加密**:payload 层加密,服务端只存密文(需处理冲突可见性)。
3. **Web 端**:KMP 的 wasmJs 目标 + Compose for Web,复用同一核心。
4. **团队协作**:引入共享清单与权限模型(需重新设计同步冲突域)。
5. **附件与富文本备注**:对象存储 + 增量上传。

---

**变更记录**

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-08 | 首次发布:总览、共享核心、客户端分层、同步、后端、ADR、非功能设计 |
