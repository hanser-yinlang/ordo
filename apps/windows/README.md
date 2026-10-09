# Ordo · Windows 桌面端(Compose Multiplatform Desktop)

> 本模块消费冻结的共享核心 `:shared:core` —— 业务规则(数据模型、派生清单、中文 NLP、重复、同步合并)全部来自核心,本模块只负责 **UI / 本地存储 / 网络 / 系统集成**。

---

## 1. 技术栈

| 层 | 选型 |
|---|---|
| 语言 | Kotlin 2.4.20(JVM 21) |
| UI | Compose Multiplatform Desktop 1.12.1 |
| 本地存储 | JSON 文件仓储(`%APPDATA%\Ordo`,原子写入 + 损坏自愈) |
| 网络 | Ktor 3.6 CIO(HTTP + WebSocket) |
| 系统集成 | `java.awt.SystemTray` 托盘 + 到点提醒气泡;注册表读取系统深浅色与"减弱动态效果" |
| 测试 | JUnit4 + Compose `ImageComposeScene` 离屏渲染 |

## 2. 运行与打包

```powershell
$env:JAVA_HOME="<JDK 21>"
gradle :apps:windows:run                       # 直接运行
gradle :apps:windows:test                      # 单元测试 + 界面渲染冒烟(38 个用例)
gradle :apps:windows:createDistributable       # 免安装目录(app-image)
gradle :apps:windows:packageDistributionForCurrentOS   # MSI + EXE(Compose 插件自动下载 WiX 3.11)
gradle :apps:windows:packageMsi                # 只打 MSI
```

### 打包产物(本机实测)

| 产物 | 路径 | 大小 |
|---|---|---|
| 免安装目录 | `build/compose/binaries/main/app/Ordo/Ordo.exe`(+ `app/`、`runtime/`) | 启动器 0.5 MB,整目录 164.7 MB |
| 单文件 EXE | `build/compose/binaries/main/exe/Ordo-1.0.0.exe` | 99.8 MB |
| MSI 安装包 | `build/compose/binaries/main/msi/Ordo-1.0.0.msi` | 99.1 MB |

`packageDistributionForCurrentOS` **不需要手工安装 WiX**:Compose Gradle 插件会先跑 `:downloadWix` / `:unzipWix`
把 WiX 3.11 二进制下到 Gradle 缓存(`wix311-binaries.zip`),再交给 `jpackage`。若企业网络禁用该下载,
可预先装 WiX Toolset v3.14 并把 `bin` 加进 `PATH`,或只打免安装目录(不需要 WiX)。

### 产物自检(可复现)

```powershell
$exe = "build\compose\binaries\main\app\Ordo\Ordo.exe"
& $exe --version                                   # → Ordo 1.0.0 · windows-desktop · Compose Multiplatform(退出码 0)
& $exe --data-dir=D:\OrdoTest --selftest=$env:TEMP\ordo.txt   # 起真实界面,把状态写进报告后自动退出
Get-Content $env:TEMP\ordo.txt
# step=data-dir dir=D:\OrdoTest
# step=engine ready todos=37
# step=network-ready headless=false
# step=window showing=true waitedMs=254 size=1180x760 at=370,136
# step=done ok=true
```

数据目录可用 `--data-dir=<路径>` 或 JVM 参数 `-Dordo.dataDir=` 覆盖(便携部署 / 自动化测试)。

窗口:**最小 480×640**(04-UI规范 §3),关闭(或托盘退出)时把**尺寸与位置**写入 `kv.json`,下次启动恢复;
记忆的位置若已不在任何屏幕内(拔掉外接显示器),自动回落到居中。深链可直接拉起某个清单:
`Ordo.exe ordo://today`、`ordo://project/<id>`、`ordo://todo/<id>`。

## 3. 目录结构

```
apps/windows/src/main/kotlin/com/ordo/desktop/
├── Main.kt                    应用入口:装配存储/引擎/同步/托盘 + 全局快捷键 + 窗口尺寸位置记忆 + --version/--selftest
├── app/                       OrdoViewModel(状态)、UiState、OrdoRoute(路由)
├── data/JsonFileStorage.kt    OrdoStorage 实现(snapshot/outbox/tombstones/kv 四个文件)
├── net/OrdoNet.kt             KtorSyncApi · KtorAuthApi · KtorRealtimeChannel · OrdoHttp
├── sync/SyncCoordinator.kt    周期 30s + 写操作后 2s 防抖 + 登录态切换 + 上次错误留存
├── sync/SyncDiagnostics.kt    「同步诊断」数据源:待推送条数 / 最后 serverSeq / 上次错误 / outbox 前 10 条
├── system/                    TrayNotifications + ReminderScheduler · DeepLink · WindowsTheme · AutoStart(开机自启)
└── ui/
    ├── theme/                 设计令牌(OrdoTokens)与主题(浅/深)
    ├── shell/                 OrdoApp(三栏骨架)· Sidebar · StatusBar
    ├── list/                  ListPane(大标题/日程/分组 + 拖拽排序浮层)· TodoRow(38dp 行 + 圆形复选框 + 拖拽手柄)
    │                          · ReorderMath(插入位/指示线/顺序拼接的纯计算)· ListReorderState(拖拽运行时状态)
    ├── detail/DetailCard.kt   详情卡片(标题/备注/何时/截止/提醒/重复/移动/标签/清单)
    ├── schedule/              ScheduleSheet(排期面板 280 + 月历 + 中文 NLP 输入)
    ├── search/FastFind.kt     快找浮层(Ctrl+K,↑↓/Enter/Esc)
    ├── quickadd/QuickAdd.kt   快加号(52dp,长按菜单:待办/项目/区域/标题)
    ├── settings/              设置浮层(外观与启动/账号与同步/同步诊断/数据/快捷键)
    └── common/                Widgets(文本框/按钮/复选框/进度环/Toast/Markdown 备注)
```

## 5. 拖拽排序(04-UI规范 §6「拖拽排序 = 鼠标拖拽」)

- **手柄**:待办行悬浮(或选中)时右侧出现日历按钮与拖拽手柄(`DragIndicator`,28×28);按住手柄上下拖动。
- **实时指示**:拖动中在插入位画一条 2dp 主色指示线(左端圆点),并有一个跟随指针的"提起来的行"浮出卡片;
  被拖行本身降到 55% 透明度。
- **松手落库**:按分组内的行中点算出插入位 → 把新顺序拼回**整表**顺序 → 一次 `vm.reorder(ids)` → 共享核心
  `OrdoEngine.reorderTodos` 密集重写 `order` 并逐条进 outbox,重启后顺序不变。
- **不误开详情**:拖动一旦越过触摸阈值就会消费指针事件,行的 clickable 自动取消;另外拖动中显式跳过 `onOpen`。
- **Esc 取消**:拖动中按 Esc 只取消拖动(`UiState.dragActive` + `dragCancelToken`),不会顺手关掉详情/浮层;松手位置不变则不写 outbox。
- **适用范围**:今天 / 收件箱 / 计划 / 随时 / 某天 / 收件箱 / 项目 / 区域清单共用同一个列表容器;
  日志簿(按完成时间)、标签与搜索(按更新时间)不提供手柄,因为那里的顺序与 `order` 无关。

## 6. 快捷键(04-UI规范 §6 桌面列)

| 快捷键 | 作用 |
|---|---|
| `Ctrl + N` | 新建待办(输入框支持中文自然语言) |
| `Ctrl + K` | 快找 |
| `Ctrl + D` | 外观:自动 → 浅色 → 深色 |
| `1` – `6` | 收件箱 / 今天 / 计划 / 随时 / 某天 / 日志簿 |
| `↑ ↓` | 移动选中行 |
| `Enter` | 打开详情卡片 |
| `Space` | 切换完成状态 |
| `Delete` | 删除选中待办 |
| `Esc` | 关闭浮层 / 详情;拖动中取消拖动 |
| 拖拽手柄 | 按住行尾手柄上下拖动排序 |

文本输入获得焦点时,无修饰键的快捷键自动让路(`OrdoInputFocus`)。`Ctrl+N` 打开行内输入框后会自动聚焦
(等首帧布局完成再请求焦点),输入为空时 `Esc` 直接关闭且不会留下空待办。

## 7. 数据与同步

- **本地优先**:所有写操作先落 `%APPDATA%\Ordo\snapshot.json`,界面立即刷新;网络只是复制通道。
- `outbox.json` 保存待推送 Op(opId 幂等),`tombstones.json` 防删除复活,`kv.json` 存 deviceId / lastServerSeq / 令牌 / 窗口尺寸位置 / 外观偏好 / 开机自启。
- 同步触发:启动后每 30 秒、写操作后 2 秒防抖、登录成功后立即一次。
- 服务端地址默认 `http://127.0.0.1:8080`(与本仓库 `server/.env.example` 的 `PORT=8080` 一致),可在「设置 → 账号与同步」改为其它后端。
- **同步诊断**(设置页):待推送条数(=`outbox.json` 条数)、最后 serverSeq(kv `ordo.lastServerSeq`)、上次错误
  (最近一次同步结果,成功即清空)以及 outbox 前 10 条的 `entity / opId / clientTs`;超过 10 条会提示总数。
- **开机自启**(设置页开关):`AutoStart` 抽象,真实实现走 `reg.exe` 写
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 `Ordo` 值;所有注册表调用都包在 `runCatching` 里,
  拿不到 exe 路径(开发态 `gradle run`)或策略禁用时退化为"不可用",不会影响主界面。测试用 `InMemoryAutoStart` 与注入的
  `CommandRunner`,并有一条只读用例真实查询注册表。

## 8. 测试(本机可跑,38 个用例)

```
JsonFileStorageTest   10 个:快照往返 / 损坏自愈 / outbox 幂等与清理 / 墓碑 / kv / 引擎落盘与重启 / 原子写
ReorderTest            8 个:插入位与指示线计算 / 同分组下移与上移 / 整表顺序拼接 / 不产生空写 /
                             收件箱与今天清单"拖拽 → reorder → 重启引擎"顺序不变
AutoStartTest          9 个:内存实现 / HKCU Run 键 add·delete·query 参数 / 缺 exe 路径不触注册表 /
                             命令失败与异常退化 / 路径加引号 / 真实注册表只读冒烟
SyncDiagnosticsTest    4 个:待推送条数与 serverSeq / outbox 明细截断到 10 条 / 上次错误透传 / 只读不写
RenderSmokeTest        7 个:离屏渲染「今天」与「深色+快加号」PNG、派生清单与计数、中文 NLP 新建、
                             拖拽指示线渲染、设置页(开机自启 + 同步诊断)渲染、
                             真实指针事件驱动"按住手柄 → 拖到第三行 → 松手"并断言顺序写回引擎
```

离屏渲染产物(`build/reports/`,1440×900,可用于设计走查与回归对比):

| 文件 | 内容 |
|---|---|
| `ordo-today.png` | 浅色「今天」主界面 |
| `ordo-dark-quickadd.png` | 深色 + 快加号菜单 |
| `ordo-drag-reorder.png` | 拖拽中:插入指示线 + 跟随指针的浮出行 + 被拖行变淡 |
| `ordo-settings-sync.png` | 设置页:开机自启开关 + 同步诊断(outbox 前 10 条) |

## 9. 已知限制

- 关闭窗口即退出(未做"最小化到托盘常驻");托盘菜单提供「打开 / 退出」。
- `ordo://` 深链已实现**命令行参数解析**;MSI 安装包不会自动注册协议,需安装后手工写入注册表(见主 README)。
- 删除项目/区域是**立即生效且无二次确认**(侧栏悬浮出删除图标),误点无法撤销 —— 这是上一轮就有的交互,建议后续补确认或撤销条。
- 随时 / 某天 / 标签 / 搜索清单:拖拽会把新 `order` 写进 outbox,但这两个清单的**显示顺序**目前由共享核心
  按创建顺序(`QueryEngine.groupByProject` 与 `sections()` 的 `else` 分支未按 `order` 排序)决定,所以松手后行会弹回原位
  (界面会提示"顺序已保存(该清单顺序暂由共享核心派生)")。需要核心补一行排序,详见 §10 的核心 API 请求。
- Markdown 备注为轻量渲染(标题/列表/加粗/行内代码/链接),不含表格与图片。

## 10. 需要共享核心新增/调整的 API(本轮不改核心)

1. **`QueryEngine.sections()` 的随时 / 某天分支按 `order` 排序**(一行改动):
   - `is ListQuery.Anytime -> groupByProject(open().filter { it.\`when\` == When.ANYTIME }.sortedWith(compareBy({ it.order }, { it.createdAt })))`
   - `else -> list(query)...` 中的 Someday 分支同理(或在 `list()` 里给 Anytime/Someday 加同样的 `sortedWith`)。
   这样 §5 的拖拽排序在「随时 / 某天」也能立刻看到效果;目前只有数据落库生效。
2. (可选)按作用域重排的 `reorderTodos(ids, scope)` 或 `moveTodo(id, beforeId)`:
   现接口是按传入下标密集重写 `order`,视图层必须传入整表顺序才能避免跨分组 order 重叠;
   有了作用域版就能只传被拖分组。

