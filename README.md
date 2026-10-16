# Ordo(序)· 多端个人任务管理器

> 把今天理清楚 · *Make today clear.*
> 共享核心一次实现,三端原生体验:Android · 鸿蒙 · Windows,配自研同步后端。

---

## 1. 这是什么

一套**可上架级别**的多端待办应用工程:业务规则(数据模型、派生清单、中文自然语言解析、重复规则、同步合并)只写一遍,放在 Kotlin Multiplatform 共享核心里;三端各自用平台原生技术栈实现界面与系统集成;后端提供账号、增量同步、实时推送与提醒快车道(Fastlane)。

## 2. 仓库地图

```
ordo/
├── docs/                     ← 工程文档(00–10),契约以 03/04 为准
├── shared/core/              ← KMP 共享核心(唯一业务实现,含 69 个单元测试;jvm + android 两个目标)
├── apps/
│   ├── android/              ← Kotlin + Jetpack Compose(**纯本地**)
│   ├── harmony/              ← ArkTS + ArkUI(按契约独立实现核心,**纯本地**)
│   └── windows/              ← Kotlin + Compose Desktop(**纯本地**)
├── server/                   ← TypeScript + Fastify + PostgreSQL + WebSocket(**客户端已不再调用**)
├── tools/                    ← 契约检查 / 一键验证 / Android 无 SDK 验证 / 编码扫描
├── gradle/libs.versions.toml ← 版本唯一来源
└── settings.gradle.kts       ← 条件化模块注册(无 SDK 环境也能构建核心)
```

> 三端现已无任何网络请求,数据只存本机。服务端代码保留但客户端不再调用。

| 文档                                   | 内容                             |
| ------------------------------------ | ------------------------------ |
| [00 项目章程](docs/00-项目章程与治理.md)        | 目标、范围、里程碑、治理机制                 |
| [01 PRD](docs/01-产品需求文档-PRD.md)      | 功能清单、验收标准、用户旅程                 |
| [02 架构设计](docs/02-系统架构设计-SAD.md)     | 分层、数据流、ADR、非功能设计               |
| [03 数据模型与同步协议](docs/03-数据模型与同步协议.md) | **契约(唯一事实来源)**                 |
| [04 UI 设计规范](docs/04-UI设计规范.md)      | 品牌、令牌、组件、动效、快捷键                |
| [05 测试与验收计划](docs/05-测试与验收计划.md)     | 用例矩阵、契约检查表、准出标准                |
| [06 迭代计划](docs/06-迭代计划与排期.md)        | 12 周排期、RACI、里程碑实测              |
| [07 风险合规与安全](docs/07-风险合规与安全.md)     | 风险登记册、IP 边界、威胁模型               |
| [08 工程规范](docs/08-工程规范与协作流程.md)      | 分支、评审、CI、发布                    |
| [09 交付与验收报告](docs/09-交付与验收报告.md)     | **本批交付清单、验证证据、遗留问题**           |
| [10 环境安装与构建指南](docs/10-环境安装与构建指南.md) | **本机装了什么、命令怎么跑、版本为什么这么锁、踩过的坑** |

## 3. 当前状态(诚实版)

| 模块                     | 状态                                                               | 验证方式                                                                                      |
| ---------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| 共享核心 `shared/core`     | ✅ **已编译 + 69 个单元测试全绿**(jvm + android 两个目标)                       | JDK 21 + Gradle 8.14 实跑                                                                   |
| **产品形态(2026-10-13 起)** | ✅ **三端纯本地**:无登录、无云同步、无网络请求;数据只存本机                                | Windows 有 `NoNetworkTest`(依赖/类路径/源码/行为四层断言);契约检查器不再要求客户端有网络层                              |
| Windows 桌面端            | ✅ **已编译 + 221 个测试全绿(含 10 条过渡动效用例)+ MSI/EXE 打包成功**             | `gradlew :apps:windows:test`(30 类);`packageDistributionForCurrentOS`                      |
| 后端 `server`            | ✅ **构建 + 174 个测试 + 真库 125 项断言全过**(客户端已不再调用)                      | `pnpm test`;真库 `127.0.0.1:55432`                                                          |
| Android 端              | ✅ **已编译 + APK(debug / 已签名 release)+ 127 个测试全绿(含 7 条过渡动效契约)**   | `gradlew :apps:android:app:assembleDebug :apps:android:app:testDebugUnitTest`(12 类;本机无设备,未做真机) |
| 鸿蒙端                    | ✅ **已编译 + HAP 产出 + ArkTS 0 错误 + 宿主 135 用例全绿(含 5 条减弱动效折算)+ 模拟器 `aa test` 通过** | `_qa/build.ps1`(assembleHap + ohosTest);`python apps/harmony/_qa/build-harness.py`;`hdc shell aa test …`(设备端 136 条为第六轮实测,本机现无设备未重跑) |

**合计**:三端**共 417 个应用用例(核心 69 + Windows 221 + Android 127)全绿**,另有**鸿蒙宿主 135 用例**与**设备端 `aa test`**、后端 **174 用例 + 真实 PostgreSQL 125 项断言**;契约一致性检查 39 项 × **5 个代码库**全部通过;编码扫描零问题 —— 详见 [09 交付与验收报告](docs/09-交付与验收报告.md) 与 [10 环境安装与构建指南](docs/10-环境安装与构建指南.md)。

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

### 4.5 构建鸿蒙(需 DevEco Studio 5+)

用 DevEco 打开 `apps/harmony/`,选择 API 12+ 的模拟器或真机运行;详见 `apps/harmony/README.md`。

## 5. 设计要点速览

| 主题     | 做法                                           |
| ------ | -------------------------------------------- |
| 本地优先   | 所有写操作先落本地库并立刻刷新界面,网络只是复制通道;离线完全可用            |
| 清单即查询  | 收件箱/今天/计划/随时/某天/日志簿都是同一份数据上的派生查询,不落库         |
| 中文自然语言 | 「明天 18:00 交季度报告 #重要」→ 标题干净、日期正确、提醒生成、标签生效    |
| 冲突处理   | 实体级 LWW + 完成不可回滚 + 标签取并集 + 清单项按 id 合并 + 删除墓碑 |
| 提醒快车道  | 服务端每秒扫描未来 60 秒到期提醒,经 WebSocket 立即下发          |
| 品牌合规   | 自研 Ordo/序 品牌与全套视觉令牌,不使用参考产品的名称、图标与文案         |

## 6. 已知限制

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

## 8. 许可证

本项目以 **MIT 许可证**开源,版权归 Ordo Project —— 可自由使用、修改、商用与再分发,只需保留版权与许可声明(全文见 [LICENSE](LICENSE))。

- 第三方依赖的许可证清单与边界见 [07 风险合规与安全](docs/07-风险合规与安全.md) §2.2:全部为 Apache-2.0 / MIT / 平台自带,**不含任何 GPL/AGPL 依赖**。
- 产品名与参考产品的边界(不复制其图标、截图、文案与专有功能名)同样记在 07 §2.1。
- 打包产物里的署名与此保持一致(`© 2026 Ordo Project`,见 `apps/windows/build.gradle.kts` 与 `installer/Ordo.nsi`)。
