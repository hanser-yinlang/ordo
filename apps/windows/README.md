# Ordo · Windows 桌面端(Compose Multiplatform Desktop)

> 本模块消费冻结的共享核心 `:shared:core` —— 业务规则(数据模型、派生清单、中文 NLP、重复、同步合并)全部来自核心,本模块只负责 **UI / 本地存储 / 网络 / 系统集成**。

---

## 1. 技术栈

| 层 | 选型 |
|---|---|
| 语言 | Kotlin 2.4.20(JVM 21) |
| UI | Compose Multiplatform Desktop 1.12.1 |
| 本地存储 | JSON 文件仓储(`%APPDATA%\Ordo\<userId>\`,按账号隔离 + 原子写入 + 损坏自愈;会话住在 `%APPDATA%\Ordo\kv.json`) |
| 网络 | Ktor 3.6 CIO(HTTP + WebSocket) |
| 系统集成 | `java.awt.SystemTray` 托盘 + 到点提醒气泡;注册表读取系统深浅色与"减弱动态效果" |
| 测试 | JUnit4 + Compose `ImageComposeScene` 离屏渲染 |

## 2. 运行与打包

```powershell
$env:JAVA_HOME="<JDK 21>"
gradle :apps:windows:run                       # 直接运行
gradle :apps:windows:test                      # 单元测试 + 界面渲染冒烟(198 个用例)
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
& $exe --data-dir=D:\OrdoTest --selftest=$env:TEMP\ordo.txt   # 起真实界面(含第二个窗口),写报告后自动退出
Get-Content $env:TEMP\ordo.txt
# +62ms   step=lock result=Acquired held=true count=1        ← 单实例锁拿到且真的持有
# +1808ms step=windows count=1 visible=1 ids=1
# +1885ms step=window showing=true waitedMs=367 size=1180x760 at=370,136
# +2324ms step=forwarded route=…Logbook branch=reuse-window  ← 第二个实例转交的深链(复用已有窗口)
# +4316ms step=second-window requested route=inbox
# +4399ms step=windows count=2 visible=2 ids=1/2             ← 多窗口真的起来了
# +7821ms step=first-window route=…Logbook
# +10913ms step=done ok=true
```

跨进程深链转交的完整验证(两个实例):

```powershell
# 终端 A:先起"运行中的实例"(自检模式,约 11 秒后自行退出)
& $exe --data-dir=D:\OrdoTest --selftest=$env:TEMP\ordo.txt
# 终端 B:再起第二个实例,带深链 —— 它会在 0.5 秒内退出并把链接转交出去
& $exe --data-dir=D:\OrdoTest ordo://logbook     # → Ordo 已在运行,已把链接转交给它
```

数据**基目录**可用 `--data-dir=<路径>` 或 JVM 参数 `-Dordo.dataDir=` 覆盖(便携部署 / 自动化测试);
账号子目录 `\<userId>\` 仍然照加 —— 隔离是契约 §7.6.3 的硬约束,任何开关都不能把它关掉。

**登录门禁**(契约 §7.6.4 / 04-UI规范 §5.1):启动先读 `kv["ordo.session"]` ——
无会话 → 登录页(登录 / 注册 / **以游客身份继续** 三个入口,住在独立的登录窗口里);有会话 → 主界面并后台静默 refresh,
过期且刷新失败才回登录页(保留该账号的数据目录)。**游客与正式账号体验对等**:同样拿服务端令牌、同样多端同步。
「设置 → 账号与同步」显示当前账号(邮箱或"游客")与本地目录,并提供**退出登录**(只清会话、保留目录)。

窗口:**最小 480×640**(04-UI规范 §3),尺寸与位置**随时**(700ms 合并)写入 `kv.json`,下次启动恢复;
记忆的位置若已不在任何屏幕内(拔掉外接显示器),自动回落到居中。深链可直接拉起某个清单:
`Ordo.exe ordo://today`、`ordo://project/<id>`、`ordo://todo/<id>`。

**多窗口**(04-UI规范 §3「支持多窗口,每窗口独立路由」):`Ctrl+Shift+N` 或「设置 → 窗口 → 新建窗口」开新窗口;
每个窗口一份视图模型,路由 / 选中 / 浮层互不干扰,但共享同一个引擎 —— 任一窗口的改动会即时出现在其它窗口。

**托盘常驻**:默认关闭窗口只是把窗口藏起来(引擎、提醒、同步继续跑),托盘菜单「打开 Ordo」把它叫回来、
「退出」才真正结束;可在「设置 → 关闭窗口」改成"直接退出"。

**单实例锁**:`.ordo.lock` 是进程级文件锁(进程级强引用 + 3 次重试,避免瞬时 IO 抖动被误判),
进程结束后由系统释放,不会留下僵尸锁;不同数据目录(便携版)可同时开多份。
环境问题(权限 / IO)不会把用户挡在门外:此时返回 `Unavailable` 并照常启动。

## 3. 目录结构

```
apps/windows/src/main/kotlin/com/ordo/desktop/
├── Main.kt                    应用入口:单实例锁 + 登录门禁 + 多窗口 + 托盘常驻 + 全局快捷键 + 窗口尺寸位置记忆 + --version/--selftest
├── app/                       OrdoViewModel(状态,一窗口一份)、UiState、OrdoRoute(路由)
│                              · SessionGate.kt:登录门禁状态机(§7.6.4 四端一致)· AccountInfo(邮箱 / 游客 + 目录名)
│                              · LoginState.kt:登录页状态与 LoginController(登录 / 注册 / 游客登录)
│                              · SharedSelection.kt:多窗口"跟随选中"总线
├── data/JsonFileStorage.kt    OrdoStorage 实现(snapshot/outbox/tombstones/kv 四个文件)
├── data/UserDataDirs.kt       本地数据目录口径:%APPDATA%\Ordo\<userId>\(契约 §7.6.3 硬约束,一个账号一个目录)
├── net/OrdoNet.kt             KtorSyncApi · KtorAuthApi(含 guest / upgrade)· KtorRealtimeChannel · TokenStore(会话真源)· OrdoHttp
├── sync/SyncCoordinator.kt    周期 30s + 写操作后 2s 防抖 + 登录态切换 + 上次错误留存 + 多窗口广播
├── sync/SyncDiagnostics.kt    「同步诊断」数据源:待推送条数 / 最后 serverSeq / 上次错误 / outbox 前 10 条
├── system/                    TrayNotifications + ReminderScheduler · DeepLink · DeepLinkInbox(跨进程深链转交)
│                              · WindowsTheme · AutoStart(开机自启)· ProtocolRegistration(ordo:// 协议)· SingleInstanceLock
└── ui/
    ├── theme/                 设计令牌(OrdoTokens)与主题(浅/深)
    ├── auth/LoginView.kt      登录页(§5.1:400 宽卡片 / 浮动标签 / 显示隐藏口令 / 提交转圈 / 错误抖动)
    ├── shell/                 OrdoApp(三栏骨架 + 确认浮层)· OrdoGateHost(无会话→登录页)· Sidebar
    │                          · StatusBar + StatusBarRefresh(§5.3 刷新控件状态机:旋转 / success / danger)
    ├── list/                  ListPane(大标题/日程/分组 + 拖拽排序浮层 + 行内输入框与"滚到可见")· TodoRow(38dp 行 + 圆形复选框 + 拖拽手柄)
    │                          · ReorderMath(插入位/指示线/顺序拼接的纯计算)· ListReorderState(拖拽运行时状态)
    │                          · LiftPointerMapper(行抬起 scale 1.02 时的指针位移还原)
    ├── detail/DetailCard.kt   详情卡片(标题/备注/何时/截止/提醒/重复/移动/标签/清单)
    ├── schedule/              ScheduleSheet(排期面板 280 + 月历 + 中文 NLP 输入)
    ├── search/FastFind.kt     快找浮层(Ctrl+K,↑↓/Enter/Esc)
    ├── quickadd/QuickAdd.kt   快加号(§5.2:只保留一个 56dp 蓝「+」,单击开输入行 / 长按 400ms 展开菜单并旋转 45°)
    ├── settings/              设置浮层(外观与启动/深链协议/账号与同步/同步诊断/数据/快捷键)
    └── common/                Widgets(文本框/按钮/复选框/进度环/Toast/Markdown 备注)· OrdoConfirmDialog(二次确认)
                               · LongPress.kt(长按 400ms + 6px 容差的统一手势,快加号与拖拽共用)
```

## 5. 长按拖拽(04-UI规范 §5.4「统一为独立手势」)

- **长按 400ms 才进入拖拽**:在待办行上按住 400ms 后行抬起(scale 1.02 + 12dp 投影 + 背景转 `surface`),
  之后拖动即可排序;在这之前**移动 <6px 视为点击**,"打开详情"不会被抢走。
- **手柄仍是可见提示**:待办行悬浮(或选中)时右侧出现日历按钮与拖拽手柄(`DragIndicator`,28×28);
  手柄上按下**无需长按**直接拖(手柄会吃掉这次按下,行级长按随之作废,同一行不会被拖两次)。
- **实时指示**:拖动中在插入位画一条 2dp 主色指示线(左端圆点),并有一个跟随指针的"提起来的行"浮出卡片;
  被拖行本身降到 55% 透明度。
- **松手落库**:按分组内的行中点算出插入位 → 把新顺序拼回**整表**顺序 → 一次 `vm.reorder(ids)` → 共享核心
  `OrdoEngine.reorderTodos` 密集重写 `order` 并逐条进 outbox,重启后顺序不变;**位置未变则不写库**。
- **抬起后的坐标还原**:行被 scale 后行内指针坐标同样被缩放,`LiftPointerMapper` 以"按下那一刻"为基准还原位移
  —— 否则落点会随拖动距离线性偏掉 2%(实测差 9px,表现是"想往下拖两格只落一格")。
- **不误开详情**:长按成立后由手势独占指针(consume),行的 clickable 因事件被消费而自动取消;拖动中另外显式跳过 `onOpen`。
- **Esc 取消**:拖动中按 Esc 只取消拖动(`UiState.dragActive` + `dragCancelToken`),不会顺手关掉详情/浮层;松手位置不变则不写 outbox。
- **适用范围**:今天 / 收件箱 / 计划 / **随时 / 某天** / 项目 / 区域清单共用同一个列表容器,都能拖;
  日志簿(按完成时间)、标签与搜索(按更新时间)不提供手柄,因为那里的顺序与 `order` 无关。
- **顺序来源**:`order` 排序**完全由共享核心给出**(`QueryEngine.byManualOrder()` 已覆盖随时 / 某天),
  本端只消费 `engine.sections(query)`,不做任何二次排序 —— 端上不再存在口径漂移的可能。

## 6. 快捷键(04-UI规范 §6 桌面列)

| 快捷键 | 作用 |
|---|---|
| `Ctrl + N` | 新建待办(输入框支持中文自然语言) |
| `Ctrl + Shift + N` | 新建窗口(多窗口,每窗口独立路由) |
| `Ctrl + K` | 快找 |
| `Ctrl + R` | 立即同步(等同于点状态栏右侧的刷新控件) |
| `Ctrl + D` | 外观:自动 → 浅色 → 深色 |
| `1` – `6` | 收件箱 / 今天 / 计划 / 随时 / 某天 / 日志簿 |
| `↑ ↓` | 移动选中行 |
| `Enter` | 打开详情卡片 |
| `Space` | 切换完成状态 |
| `Delete` | 删除选中待办 |
| `Esc` | 关闭浮层 / 详情;取消长按拖拽;删除确认中取消确认 |
| 长按 400ms 后拖动 | 待办行排序(或按住行尾手柄直接拖,无需长按) |

文本输入获得焦点时,无修饰键的快捷键自动让路(`OrdoInputFocus`)。`Ctrl+N` 打开行内输入框后会自动聚焦,
输入为空时 `Esc` 直接关闭且不会留下空待办。

**破坏性操作二次确认**:项目 / 区域 / 标题的删除按钮只发出请求(`UiState.confirm`),弹出确认框后才落库;
`Esc` 与点击遮罩都算取消。删除一律是契约 §3 的软删除 + 墓碑,并作为 op 进 outbox 同步到其它端。

## 6.1 新建待办的入口:为什么输入框留在列表顶部,而不是搬到加号旁边

右下角快加号、`Ctrl+N`、标题栏加号、分组「+」**共用同一条请求链路** `OrdoViewModel.openComposer()`:
它把 `composerOpen = true` 并让 `composerFocusToken` 自增。列表侧观察到令牌变化就做两件事 ——
**请求键盘焦点**(`ComposerRow` 的 `SideEffect`)与**把输入行滚到可见处**(`ListPane`,160ms 滚到内容顶端)。
令牌在"已经打开"时也会自增,所以**在输入框本来就开着的情况下再点加号同样有可见反馈**,不再是空操作。

关于"滚到可见处 vs 改成贴近 FAB 的浮层",本端选择 **保留列表顶部的行内输入框 + 滚到可见处**,理由:

1. **输入框的位置本身就是"这条待办会落在哪"的说明**。它渲染在当前清单内容的最上方,
   紧挨着项目卡片 / 标题分组 —— 在项目里新建、在某标题下新建时,"属于谁"一眼可见。
   搬到右下角浮层后,这个上下文提示会消失,用户更难判断 `Enter` 之后东西去了哪儿。
2. **浮层会遮住它自己的入口**。FAB 与快加号菜单就住在右下角,输入行贴过去必然和菜单互相遮挡。
3. 需求里的两个硬条件("打开时聚焦""已打开时再点也要有反馈")与方案无关,两条都能满足;
   而"列表很长 / 已滚到底部"这一条,输入行固定在内容顶端,所以"滚到它"就是滚到 `0`,
   一次动画必然可见 —— 不需要额外的可见性计算。

实现要点:`ListPane` 把 `ScrollState` 提为可注入参数(仅测试注入),滚到可见用 `animateScrollTo(0)`;
聚焦用**组合期**的 `SideEffect` 而不是 `LaunchedEffect + withFrameNanos` —— 焦点节点在施加阶段就已挂上树,
不必等下一帧,离屏渲染与真实窗口行为一致。`OrdoTextField` 的 `cursorBrush` 已是主色,拿到焦点后光标可见,
外层再补一圈主色描边作为"焦点在这里"的强化反馈(`UiState.composerFocused`)。

## 7. 数据与同步

- **本地优先**:所有写操作先落 `%APPDATA%\Ordo\<userId>\snapshot.json`,界面立即刷新;网络只是复制通道。
- **按账号隔离**(契约 §7.6.3 硬约束):`%APPDATA%\Ordo\kv.json` 只放**与账号无关**的引导信息(会话 `ordo.session`、服务端地址、单实例锁与深链信箱所在位置);账号数据一律在 `%APPDATA%\Ordo\<userId>\`。退出登录只清会话,目录原样保留。
- `outbox.json` 保存待推送 Op(opId 幂等),`tombstones.json` 防删除复活,`kv.json` 存 deviceId / lastServerSeq / 窗口尺寸位置 / 外观偏好 / 开机自启 / 托盘偏好。
- 同步触发:启动后每 30 秒、写操作后 2 秒防抖、登录成功后立即一次、**状态栏刷新控件 / `Ctrl+R`** 立即一次;同步结果广播给**每个窗口**的状态栏。
- **刷新控件**(04-UI规范 §5.3):状态栏右侧是「28dp 刷新图标 + 文字」;同步中图标每圈 900ms 连续旋转 + 「同步中…」,
  成功停转并短暂转 success 色(320ms)+「已同步」,1.4s 后回到常态;失败常驻 danger 色 +「同步失败，点击重试」。
  同步中与结束后的 1.4s 内按钮禁用(防重复触发)。
- 服务端地址默认 `http://127.0.0.1:8080`(与本仓库 `server/.env.example` 的 `PORT=8080` 一致),可在「设置 → 账号与同步」改为其它后端。
- **同步诊断**(设置页):待推送条数(=`outbox.json` 条数)、最后 serverSeq(kv `ordo.lastServerSeq`)、上次错误
  (最近一次同步结果,成功即清空)以及 outbox 前 10 条的 `entity / opId / clientTs`;超过 10 条会提示总数。
- **开机自启**(设置页开关):`AutoStart` 抽象,真实实现走 `reg.exe` 写
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 `Ordo` 值;所有注册表调用都包在 `runCatching` 里,
  拿不到 exe 路径(开发态 `gradle run`)或策略禁用时退化为"不可用",不会影响主界面。测试用 `InMemoryAutoStart` 与注入的
  `CommandRunner`,并有一条只读用例真实查询注册表。
- **`ordo://` 协议注册**(04-UI规范 §7):首次启动自动写当前用户注册表
  `HKCU\Software\Classes\ordo`(默认值 + `URL Protocol` 标记 + `shell\open\command` = `"<exe>" "%1"`),
  不需要管理员权限;失败不影响启动,设置页可手动重试。注册后浏览器点击 `ordo://today` 直接拉起应用。
- **深链跨进程转交**:已经有实例在跑时,新进程拿不到单实例锁,于是把链接写进数据目录的 `.ordo.inbox/`
  (先写 `.tmp` 再原子改名),运行中的实例每 500ms 轮询消费 → **复用已有窗口**导航到目标清单 / 选中目标待办
  (一个窗口都没有才新建,不会因为一条链接多开窗口),新进程自己立刻退出。
  没带链接时(用户又双击了一次图标)只发一条"唤出窗口"请求,把已有窗口提到最前。
  用文件而不是命名管道 / 本地 socket:前者要 JNI,后者要占端口,文件转交零依赖且可单测。
- **多窗口跟随选中**(设置页开关,默认开):任一窗口打开某条待办,其它窗口**如果正好显示这条**就把它高亮,
  不改动对方路由 —— 既满足"每窗口独立路由",又能在多窗口下快速定位同一条内容。

## 8. 测试(本机可跑,198 个用例)

```
SessionGateTest         14 个:会话读写与过期时刻换算 / 游客标记与展示名 / 无会话→登录页 / 有会话→主界面并静默刷新 /
                              过期刷新失败才回登录页且提示保留目录 / 未过期刷新失败仍留主界面 /
                              退出登录只清会话、目录与数据仍在 / 目录名一对一且不带出路径分隔符
LoginControllerTest     12 个:登录成功写会话并回调 / 注册走 register / 游客登录与正式登录同一条链路 /
                              游客失败不写会话 / 本地校验(邮箱格式、注册口令 ≥8)/ 错误码翻译成人话 /
                              提交中禁用且不重复提交 / 模式与口令可见性 / 服务器地址落 kv / 回登录页清空表单
UserDataDirsTest         7 个:一账号一目录 / 两个账号的数据文件互相看不见 / 目录名防御性清洗 /
                              退出登录保留目录 / --data-dir 与系统属性只覆盖基目录
LongPressDetectorTest   12 个:400ms 前抬起=点击 / 满 400ms=长按 / 松手恰好在阈值上算长按 /
                              400ms 前移动 >6px 不再是点击 / 6px 内仍是点击 / 容差边界 /
                              长按之后的移动不再取消 / 剩余时间驱动定时器 / 取消语义
LiftPointerMapperTest    5 个:行抬起 scale 1.02 后的指针位移还原(回归"拖两格只落一格")
RefreshControlTest       8 个:idle 可点 / 同步中旋转且禁用 / 成功后 320ms success 色 + 1.4s 防抖 /
                              失败常驻 danger 可重试 / 重复状态不重置计时 / 旋转一圈 900ms
QuickAddRefactorTest     8 个:56dp / 源码级断言"折叠箭头已删除且有且只有一个圆形按钮" / 单击与长按的分支 /
                              旋转 45° 与按压 0.96、长按到位 1.06 / 离屏单击开输入行 / 离屏长按 400ms 开菜单再单击收起
LongPressDragTest        5 个:长按 400ms 后拖动写回顺序 / 400ms 前移动 >6px 不进入拖拽 /
                              按下就抬起仍是点击(打开详情)/ Esc 取消不写库 / 手柄免长按直接拖且行级长按作废
GateAndRefreshRenderTest 9 个:无会话渲染登录页(三个入口文案)/ 有会话渲染主界面 / 登录页与注册态·错误抖动渲染 /
                              登录门禁截图、快加号菜单展开截图、刷新控件旋转中截图 / 设置页账号展示与退出登录
JsonFileStorageTest    10 个:快照往返 / 损坏自愈 / outbox 幂等与清理 / 墓碑 / kv / 引擎落盘与重启 / 原子写
ReorderTest             8 个:插入位与指示线计算 / 同分组下移与上移 / 整表顺序拼接 / 不产生空写 /
                              收件箱与今天清单"拖拽 → reorder → 重启引擎"顺序不变
AnytimeOrderTest        5 个:随时/某天"拖拽 → 显示顺序立刻跟随 → 重启仍保持" / 核心 order+createdAt 兜底 /
                              视图模型分组与核心输出逐字段一致(守住"端上不二次排序")
ConfirmDeleteTest       8 个:项目·区域·标题"请求 → 确认"才落库 / 取消与 Esc 不落库 / 删除进 outbox /
                              删除后从侧栏与清单消失
ProjectCompletionTest   7 个:还有未完成待办时拒绝且文案带真实条数 / canceled 不阻塞 /
                              待办全完成但标题未归档时允许完成 + 标题自动归档 + 每个标题一条 Op /
                              完成后进日志簿、不再出现完成入口(契约 §2.2 v1.1)
ComposerFocusTest      11 个:打开即请求焦点(令牌 + 计数)/ 已打开时重复点击重新请求聚焦且不丢状态 /
                              列表滚到底部点加号会滚回输入行 / 离屏场景真实指针点击后输入框真的拿到键盘焦点 /
                              空输入 Esc 关闭且不产生空待办
AutoStartTest           9 个:内存实现 / HKCU Run 键 add·delete·query 参数 / 缺 exe 路径不触注册表 /
                              命令失败与异常退化 / 路径加引号 / 真实注册表只读冒烟
ProtocolRegistrarTest   7 个:ordo 协议三条 reg add 的参数与键路径 / 查询判定 / 缺 exe 路径不触注册表 /
                              异常退化 / 真实注册表只读冒烟
SingleInstanceLockTest  6 个:第二个实例被告知已在运行 / GC 后不丢锁 / 锁文件位置与内容 /
                              不同数据目录互不影响 / 目录自动创建 / 环境问题返回 Unavailable(不挡用户)
DeepLinkTest            8 个:固定清单与未知路由(回落今天,不抛异常)/ 项目·区域·标签·待办·搜索 /
                              非 ordo 参数忽略 / 大小写 / safeParse / key↔解析互逆 / 固定清单无空元素 + 并发解析
DeepLinkInboxTest      10 个:第二实例写入→运行实例消费并清空 / 无深链不写文件 / 只要求唤出窗口 /
                              多链接按序 / 忽略其它参数 / 非法内容丢弃 / 残留 .tmp 清理 / 目录自动创建 /
                              与 DeepLink 解析一致 / 未知链接不让运行实例崩溃
MultiWindowTest        14 个:两窗口独立路由 / 任一窗口写入其它窗口刷新 / 同步结果广播与 dispose 退订 /
                              托盘偏好持久化 / 新建窗口回调 / 不重新播种演示数据 / 窗口标题 /
                              跟随选中(开启联动、清单里没有则不打扰、关掉后不联动、dispose 后不联动)
SyncDiagnosticsTest     4 个:待推送条数与 serverSeq / outbox 明细截断到 10 条 / 上次错误透传 / 只读不写
RenderSmokeTest         8 个:离屏渲染「今天」与「深色+快加号」PNG、派生清单与计数、中文 NLP 新建、
                              拖拽指示线渲染、设置页(开机自启 + 同步诊断)渲染、删除确认框渲染、
                              真实指针事件驱动"按住手柄 → 拖到第三行 → 松手"并断言顺序写回引擎
ProjectCompletionRenderTest 3 个:项目卡片"可完成(标题未归档)"与"不可完成(写明条数)"两种状态渲染、
                              完成前后画面确实不同、点开加号后输入行在列表顶部且带焦点描边
```

> 离屏渲染的一个坑(本轮踩到并写进断言):`ImageComposeScene.render()` **不带参数**时帧时钟恒为 0,
> `withFrameNanos` / 动画永远停在第 0 帧。依赖时间的断言(如 160ms 的滚动动画)必须自己喂帧
> —— 见 `ComposerFocusTest.settleAnimation()`。也正因如此,焦点请求改成了**组合期**的 `SideEffect`,
> 不再依赖"下一帧"(真实窗口与离屏场景行为一致)。

离屏渲染产物(`build/reports/`,1440×900,可用于设计走查与回归对比):

| 文件 | 内容 |
|---|---|
| `ordo-login.png` | **登录页**(§5.1:400 宽卡片、浮动标签、显示/隐藏口令、主按钮 + 「以游客身份继续」+ 底部注册链接) |
| `ordo-quickadd-menu.png` | **重构后的快加号**(§5.2:只剩一个 56dp 蓝「+」,菜单从左上方展开,按钮旋转 45° 变「×」) |
| `ordo-refresh-syncing.png` | **刷新按钮旋转中**(§5.3:状态栏右侧图标 + 「同步中…」;整窗视图) |
| `ordo-refresh-control.png` | 同上,状态栏放大视图(760×56),便于看清 28dp 图标与文案 |
| `ordo-today.png` | 浅色「今天」主界面 |
| `ordo-dark-quickadd.png` | 深色 + 快加号菜单 |
| `ordo-drag-reorder.png` | 拖拽中:插入指示线 + 跟随指针的浮出行 + 被拖行变淡(行已抬起 scale 1.02 + 12dp 投影) |
| `ordo-confirm-delete.png` | 删除项目的二次确认框 |
| `ordo-settings-sync.png` | 设置页:开机自启 / 关闭窗口 / 新建窗口 / ordo:// 协议 / 账号与同步 / 同步诊断 |
| `ordo-project-completable.png` | 项目卡片**可完成**态:14 项全部结束、两个标题尚未归档,仍显示「完成项目」 |
| `ordo-project-blocked.png` | 项目卡片**不可完成**态:按钮直接写「还有 1 项未完成的待办」 |
| `ordo-project-blocked-toast.png` | 点下去后的提示条:与按钮同源的「还有 1 项未完成的待办」 |
| `ordo-project-done.png` | 完成之后:按钮变「重新打开」,标题已自动归档 |
| `ordo-composer-focused.png` | 点开右下角加号:输入行在列表顶部、主色描边 + 光标(真的拿到了焦点) |

## 9. 已知限制

- **登录后才能用**:无会话时只能停在登录页(独立的小窗口);游客登录同样需要服务端可达(`/v1/auth/guest`),
  服务端不可达时登录页会明确提示"无法连接服务器"(不会静默失败,也不会假装已登录)。
- 打包自检 `--selftest` 在新目录下会停在**登录页**(门禁优先于主界面):报告里能看到 `step=gate stage=LOGIN`、
  `step=login-window`、`step=window showing=true` 与 `step=done ok=true`(窗口照常自检并自动退出);
  主界面 / 多窗口 / 深链导航类的自检需要已有会话(自动化里可预置 `<data-dir>\kv.json` 的 `ordo.session`)。
- 深链转交是**文件轮询**(`.ordo.inbox`,500ms),最坏有半秒延迟;同一秒内的多个链接按写入顺序依次消费。
- 多窗口共享同一个数据目录与引擎;「跟随选中」只高亮不改路由,没有"把另一个窗口切到同一条待办"的能力(规范只要求独立路由)。
- 托盘常驻期间"退出"只在托盘右键菜单里;若直接结束进程(任务管理器),未落盘的窗口位置最多丢失 700ms 内的改动。
- 单实例锁在极端环境(目录不可写 / 权限受限)下会退化为 `Unavailable` 并放行启动,此时理论上可同时跑两份
  (宁可少一层保护,也不把用户挡在门外);该情形会在 stderr 打一行说明。
- Markdown 备注为轻量渲染(标题/列表/加粗/行内代码/链接),不含表格与图片。
- 长按 400ms 与 6px 容差的手感**只在离屏场景里用真实指针事件验证过**(阈值与坐标换算有逐条单测),
  真实鼠标 / 触控板的手感需要人工确认一次。
- 游客升级为正式账号(`/v1/auth/upgrade`,userId 与数据不变)已在 `KtorAuthApi` 实现并可直接调用,
  但**界面上还没有入口**(本轮四项需求未要求;设置页只展示当前账号与退出登录)。

## 10. 需要共享核心新增/调整的 API

1. ~~`QueryEngine.sections()` 的随时 / 某天分支按 `order` 排序~~ —— **核心已实现**:
   `QueryEngine.byManualOrder()` = `sortedWith(compareBy({ it.order }, { it.createdAt }))`,已覆盖随时与某天的
   `list()` 与 `sections()`;本端随之删除了 §5 提到的本地适配层,并由 `AnytimeOrderTest` 守住"端上不再二次排序"。
2. (可选)按作用域重排的 `reorderTodos(ids, scope)` 或 `moveTodo(id, beforeId)`:
   现接口是按传入下标密集重写 `order`,视图层必须传入整表顺序才能避免跨分组 order 重叠;
   有了作用域版就能只传被拖分组。

## 11. 本轮修掉的三个真问题(冒烟验证发现的)

| 现象 | 根因 | 修复 |
|---|---|---|
| `Ordo.exe ordo://logbook` 直接崩(`NullPointerException` in `OrdoRoute.fromKey`) | `OrdoRoute.fixed` 用**静态初始化字段**装的嵌套 `object` 列表,首次访问路径与类初始化交叉时读到 null 元素 | `fixed` 改为计算属性 + `listOfNotNull`;`fromKey` 改成显式 `when` 匹配,未知 key 回落「今天」;`DeepLink.safeParse` 吞掉解析异常;新增 `DeepLinkTest`(含并发解析用例) |
| 托盘常驻后"再双击图标"只弹一个模态框、脚本里会一直挂着 | 第二个实例走 `notifyAlreadyRunning()` 的模态对话框,主线程返回但 JVM 被 AWT 线程拖住 | 第二个实例改为**转交链接 / 请求唤出窗口**后立即退出(0.4s);仅在连 inbox 都写不进去时才退回对话框 |
| 单实例锁有时形同虚设(第二个实例也拿到锁) | 锁失败被 `runCatching` 一律吞成"已有实例",且瞬时 IO 抖动会误判 | `SingleInstanceLock.acquire` 区分 `Acquired / AlreadyRunning / Unavailable`,重试 3 次,进程级强引用锁对象(防 GC 释放),`GC` 与 `Unavailable` 都有单测;`--selftest` 报告 `step=lock ...` 可直接核对 |

## 12. 第二轮修掉的两个真问题(用户实机试用反馈)

| 现象 | 根因(端侧,核心已按契约 §2.2 v1.1 修好) | 修复 |
|---|---|---|
| 项目卡片显示「剩 0 项未完成 / 进度 100%」,点「完成项目」却被拒(提示还提"标题") | ① 按钮 `enabled` 仍带旧规则的标题判据 `sections.all { kind != HEADING \|\| todos.isEmpty() }`,而它读的是"当前清单可见分组",与全局口径不同源;② Toast 还是旧文案「还有未完成的待办或标题」 | 新增 `ProjectCardState`(由视图模型按核心计数填好 `openCount` / `totalCount`),按钮可用性、按钮文案、Toast 三处**同源**;不可完成时按钮直接显示「还有 N 项未完成的待办」,点下去提示逐字一致;完成后按钮变「重新打开」,标题由核心自动归档 |
| 右下角蓝色加号"点了没反应" | `OrdoFab { vm.openComposer() }` 只把 `composerOpen = true`:输入行在**列表内容最顶端**,既不抢键盘焦点也不滚动过去;用户那一行本来就开着 → 彻底的空操作 | `openComposer()` 每次调用都自增 `composerFocusToken`(含已打开时);`ComposerRow` 在 `SideEffect` 里请求焦点,`ListPane` 在令牌变化时 `animateScrollTo(0)` 把输入行滚到可见处;`UiState.composerFocused` 回报焦点实况并点亮主色描边(方案取舍见 §6.1) |

**给四端的一条口径提醒**:契约 §2.2 v1.1 下 `completeProject` 返回 false 的**唯一**原因是
"该项目下还有 `status == OPEN` 的待办"。端上任何"能不能完成"的判断都应该直接用核心计数
(`SidebarCounts.projects[id]`),不要自己再拼 heading 条件 —— 本端这两处 bug 都是那么来的。

**共享核心**:本轮未改 `ordo/shared/**`,也未改文档与其它端。


