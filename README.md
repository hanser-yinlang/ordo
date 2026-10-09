# Ordo(序)· 多端个人任务管理器

> 把今天理清楚 · *Make today clear.*
> 共享核心一次实现,四端原生体验:Android · iOS · 鸿蒙 · Windows,配自研同步后端。

---

## 1. 这是什么

一套**可上架级别**的多端待办应用工程:业务规则(数据模型、派生清单、中文自然语言解析、重复规则、同步合并)只写一遍,放在 Kotlin Multiplatform 共享核心里;四端各自用平台原生技术栈实现界面与系统集成;后端提供账号、增量同步、实时推送与提醒快车道(Fastlane)。

## 2. 仓库地图

```
ordo/
├── docs/                     ← 工程文档(00–08),契约以 03/04 为准
├── shared/core/              ← KMP 共享核心(唯一业务实现,含 53 个单元测试)
├── apps/
│   ├── android/              ← Kotlin + Jetpack Compose
│   ├── ios/                  ← Swift + SwiftUI + SwiftData(消费 XCFramework)
│   ├── harmony/              ← ArkTS + ArkUI(按契约独立实现核心)
│   └── windows/              ← Kotlin + Compose Desktop
├── server/                   ← TypeScript + Fastify + PostgreSQL + WebSocket
├── tools/                    ← 契约检查 / 一键验证 / Android 无 SDK 验证 / 编码扫描
├── gradle/libs.versions.toml ← 版本唯一来源
└── settings.gradle.kts       ← 条件化模块注册(无 SDK 环境也能构建核心)
```

| 文档 | 内容 |
|---|---|
| [00 项目章程](docs/00-项目章程与治理.md) | 目标、范围、里程碑、治理机制 |
| [01 PRD](docs/01-产品需求文档-PRD.md) | 功能清单、验收标准、用户旅程 |
| [02 架构设计](docs/02-系统架构设计-SAD.md) | 分层、数据流、ADR、非功能设计 |
| [03 数据模型与同步协议](docs/03-数据模型与同步协议.md) | **契约(唯一事实来源)** |
| [04 UI 设计规范](docs/04-UI设计规范.md) | 品牌、令牌、组件、动效、快捷键 |
| [05 测试与验收计划](docs/05-测试与验收计划.md) | 用例矩阵、契约检查表、准出标准 |
| [06 迭代计划](docs/06-迭代计划与排期.md) | 12 周排期、RACI、里程碑实测 |
| [07 风险合规与安全](docs/07-风险合规与安全.md) | 风险登记册、IP 边界、威胁模型 |
| [08 工程规范](docs/08-工程规范与协作流程.md) | 分支、评审、CI、发布 |
| [09 交付与验收报告](docs/09-交付与验收报告.md) | **本批交付清单、验证证据、遗留问题** |
| [10 环境安装与构建指南](docs/10-环境安装与构建指南.md) | **本机装了什么、命令怎么跑、版本为什么这么锁、踩过的坑** |

## 3. 当前状态(诚实版)

| 模块 | 状态 | 验证方式 |
|---|---|---|
| 共享核心 `shared/core` | ✅ **已编译 + 57 个单元测试全绿** | JDK 21 + Gradle 8.14 实跑 |
| Windows 桌面端 | ✅ **已编译 + 38 个测试全绿 + MSI/EXE 打包成功** | `gradlew :apps:windows:test`;`packageDistributionForCurrentOS` → MSI 99.1 MB |
| 后端 `server` | ✅ **构建 + 128 个测试 + 10 项端到端冒烟全绿 + 真实 PostgreSQL 53 项断言全过** | `pnpm test`;pg-mem 真实执行迁移 SQL;真库 `127.0.0.1:55432` |
| Android 端 | ✅ **已编译 + APK 产出 + 60 个测试全绿** | `gradlew :apps:android:app:assembleDebug` → `app-debug.apk` 15.7 MB |
| 鸿蒙端 | ✅ **已编译 + HAP 产出 + ArkTS 告警清零** | `hvigorw assembleHap` → `entry-default-unsigned.hap` 1.10 MB |
| iOS 端 | 📦 源码就绪 + 预检 34 项通过 | **本机无 macOS,未编译**;`bash apps/ios/tools/verify_ios.sh` 在 macOS/CI 上一条命令跑通 |

**合计**:约 330 个文件 / 6.4 万行源码与文档;**283 个自动化测试用例全部通过**(另有真实 PostgreSQL 53 项断言);契约一致性检查 × 6 个代码库全部通过;编码扫描零问题 —— 详见 [09 交付与验收报告](docs/09-交付与验收报告.md) 与 [10 环境安装与构建指南](docs/10-环境安装与构建指南.md)。

> 环境实情:本仓库的开发机为 Windows(仅有 JDK 21 + Gradle 8.14 + Node/pnpm)。凡标注"未编译"的端,均已在对应 README 给出目标环境的完整构建步骤,并用自动检查器逐条核对了契约字段/规则。

## 4. 五分钟上手

### 4.1 跑共享核心与全部单元测试(任何平台)

```powershell
$env:JAVA_HOME="<JDK 21 路径>"
gradle :shared:core:jvmTest        # 或 .\gradlew
```
预期:4 个测试类 / 53 个用例全部通过。

### 4.2 跑后端

```bash
cd server
pnpm install
pnpm test          # 内存仓储,无需数据库
pnpm dev           # 启动服务(默认 8787)
```
接真实 PostgreSQL:`export DATABASE_URL=postgres://user:pass@host:5432/ordo && pnpm migrate && pnpm start`。

### 4.3 跑 Windows 桌面端

```powershell
gradle :apps:windows:run
# 打包:gradle :apps:windows:packageMsi
```

### 4.4 构建 Android

```bash
export ANDROID_HOME=/path/to/sdk     # 或在 ordo/local.properties 写 sdk.dir
gradle :apps:android:app:assembleDebug
# 也可以直接用 Android Studio 打开 ordo/ 目录
```

### 4.5 构建 iOS(需 macOS)

```bash
./gradlew :shared:core:assembleXCFramework    # 生成 OrdoCore.xcframework
open apps/ios/Ordo.xcodeproj                  # 详见 apps/ios/README.md
```

### 4.6 构建鸿蒙(需 DevEco Studio 5+)

用 DevEco 打开 `apps/harmony/`,选择 API 12+ 的模拟器或真机运行;详见 `apps/harmony/README.md`。

## 5. 设计要点速览

| 主题 | 做法 |
|---|---|
| 本地优先 | 所有写操作先落本地库并立刻刷新界面,网络只是复制通道;离线完全可用 |
| 清单即查询 | 收件箱/今天/计划/随时/某天/日志簿都是同一份数据上的派生查询,不落库 |
| 中文自然语言 | 「明天 18:00 交季度报告 #重要」→ 标题干净、日期正确、提醒生成、标签生效 |
| 冲突处理 | 实体级 LWW + 完成不可回滚 + 标签取并集 + 清单项按 id 合并 + 删除墓碑 |
| 提醒快车道 | 服务端每秒扫描未来 60 秒到期提醒,经 WebSocket 立即下发 |
| 品牌合规 | 自研 Ordo/序 品牌与全套视觉令牌,不使用参考产品的名称、图标与文案 |

## 6. 已知限制

- 本机无法编译 Android/iOS/鸿蒙三端(缺 SDK 与 macOS),已提供构建步骤与静态检查结论。
- 日历集成为只读演示数据,系统日历接入在二期。
- 提醒在 MVP 为本地通知;后台被杀时的可靠投递依赖各平台机制,已列入风险 R-06。
- 团队协作、Web 端、端到端加密为明确非目标(见章程 §1.2)。

## 7. 贡献约定(摘要)

1. 任何字段/接口/行为变更 → 先改 `docs/03`,再改代码。
2. 只改自己工作包目录,跨端改动由架构师在集成阶段完成。
3. 提交信息用 Conventional Commits,并在 `Refs:` 中引用契约条款或需求 ID。
4. 合并前填写 `docs/05` 的契约一致性检查表。

完整规范见 [08 工程规范与协作流程](docs/08-工程规范与协作流程.md)。
