# Ordo(序)· 多端个人任务管理器

> 把今天理清楚 · *Make today clear.*
> 共享核心一次实现,四端原生体验:Android · iOS · 鸿蒙 · Windows,配自研同步后端。

---

## 1. 这是什么

一套**可上架级别**的多端待办应用工程:业务规则(数据模型、派生清单、中文自然语言解析、重复规则、同步合并)只写一遍,放在 Kotlin Multiplatform 共享核心里;四端各自用平台原生技术栈实现界面与系统集成;后端提供账号、增量同步、实时推送与提醒快车道(Fastlane)。

## 2. 仓库地图

```
ordo/
├── docs/                     ← 工程文档(00–10),契约以 03/04 为准
├── shared/core/              ← KMP 共享核心(唯一业务实现,含 69 个单元测试)
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
| 共享核心 `shared/core` | ✅ **已编译 + 69 个单元测试全绿**(含 v1.2 会话层 8 条) | JDK 21 + Gradle 8.14 实跑 |
| **登录体系(五端一致)** | ✅ **启动登录门禁 + 游客登录 + 邮箱验证码登录 + 数据按 userId 隔离**(契约 §7.6 / §7.6.5) | 后端 174 用例(含游客/升级/验证码);真库 125 项断言;主管黑盒端到端 25 项 |
| Windows 桌面端 | ✅ **已编译 + 234 个测试全绿 + MSI/EXE 打包成功** | `gradlew :apps:windows:test`(27 类,含登录页 / 快加号菜单 / 刷新中 / **验证码登录** 离屏截图);`packageDistributionForCurrentOS` → MSI 99.3 MB |
| 后端 `server` | ✅ **构建 + 174 个测试 + 10 项冒烟 + 24 项游客冒烟全绿 + 真实 PostgreSQL 125 项断言全过** | `pnpm test`;`scripts/verify-guest-smoke.ps1`;真库 `127.0.0.1:55432` |
| Android 端 | ✅ **已编译 + APK(debug 15.15 MB / **已签名** release 2.17 MB)+ 135 个测试全绿** | `gradlew :apps:android:app:assembleDebug :apps:android:app:testDebugUnitTest`(本机无设备,未做真机) |
| 鸿蒙端 | ✅ **已编译 + HAP 产出 + ArkTS 0 错误 + 宿主 134 用例全绿 + 模拟器 `aa test` 134/134** | `hvigorw assembleHap` → `entry-default-unsigned.hap` 1.4 MB;`python apps/harmony/_qa/build-harness.py`;`hdc shell aa test …` |
| iOS 端 | 📦 源码就绪 + 契约交叉核对 0 缺失 + 预检 34 项通过 | **本机无 macOS,未编译**;`bash apps/ios/tools/verify_ios.sh` 在 macOS/CI 上一条命令跑通 |

**合计**:约 520 个文件 / 9 万行源码与文档;**612 个应用用例(核心 69 + Windows 234 + Android 135 + 后端 174)全部通过**,另有**鸿蒙宿主 134 用例 + 模拟器设备端 `aa test` 134 用例**、**真实 PostgreSQL 125 项断言**与**主管黑盒端到端 25 项**;契约一致性检查 39 项 × 6 个代码库全部通过;编码扫描 511 个文件零问题 —— 详见 [09 交付与验收报告](docs/09-交付与验收报告.md) 与 [10 环境安装与构建指南](docs/10-环境安装与构建指南.md)。

> 环境实情:本仓库的开发机为 Windows(仅有 JDK 21 + Gradle 8.14 + Node/pnpm)。凡标注"未编译"的端,均已在对应 README 给出目标环境的完整构建步骤,并用自动检查器逐条核对了契约字段/规则。

## 4. 五分钟上手

### 4.1 跑共享核心与全部单元测试(任何平台)

```powershell
$env:JAVA_HOME="<JDK 21 路径>"
gradle :shared:core:jvmTest        # 或 .\gradlew
```
预期:5 个测试类 / 69 个用例全部通过。

### 4.2 跑后端

```bash
cd server
pnpm install
pnpm test          # 内存仓储,无需数据库(143 用例)
pnpm dev           # 启动服务(默认 8787)
```
接真实 PostgreSQL:`export DATABASE_URL=postgres://user:pass@host:5432/ordo && pnpm migrate && pnpm start`。
真库回归:`node --import tsx scripts/pg-real-verify.mts`(94 项断言);游客链路冒烟:`powershell -NoProfile -File scripts/verify-guest-smoke.ps1 -DatabaseUrl $env:DATABASE_URL`(24 项)。

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

- **iOS 无法在本机编译**(无 macOS/Xcode):改动经契约交叉核对(0 缺失)与预检 34 项通过,新增 XCTest 未执行,需在 macOS 上 `bash apps/ios/tools/verify_ios.sh`(本轮已修掉"测试目标模块名写错导致必然失败"的既有阻塞)。
- **Android 本机没有可用设备/模拟器**:验证码链路只到编译 + 135 个单元测试;且清单未允许明文 HTTP(targetSdk 36),连本机 `http://` 后端需先加 debug-only 明文放行或让后端上 HTTPS。
- **鸿蒙已在模拟器上做设备端验证**(`aa test` 134/134、unsigned HAP 可直接装模拟器),但**真机**(需华为证书)与手感/帧率仍未走查;`_qa` 宿主是 Hypium 垫片。
- **真实邮件通道未接入**:验证码默认走 `console` 开发通道(可选 `http` 通用网关),拿到 SMTP/网关凭据后配置 `ORDO_MAIL_TRANSPORT=http` + `ORDO_MAIL_HTTP_URL/TOKEN` 即可,无需改代码。
- 多设备真实同步联调未做(单机真实 PostgreSQL 125 项断言与黑盒端到端 25 项已过)。
- 生产环境必须设置 `ORDO_CODE_PEPPER`(缺省拒绝启动),否则验证码哈希强度不足。
- 日历集成为只读演示数据,系统日历接入在二期。
- 提醒在 MVP 为本地通知;后台被杀时的可靠投递依赖各平台机制,已列入风险 R-06。
- 团队协作、Web 端、端到端加密为明确非目标(见章程 §1.2)。

## 7. 贡献约定(摘要)

1. 任何字段/接口/行为变更 → 先改 `docs/03`,再改代码。
2. 只改自己工作包目录,跨端改动由架构师在集成阶段完成。
3. 提交信息用 Conventional Commits,并在 `Refs:` 中引用契约条款或需求 ID。
4. 合并前填写 `docs/05` 的契约一致性检查表。

完整规范见 [08 工程规范与协作流程](docs/08-工程规范与协作流程.md)。
