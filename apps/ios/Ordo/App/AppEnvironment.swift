//
//  AppEnvironment.swift
//  Ordo
//
//  组合根(composition root):把 KMP 引擎、本地存储、同步、提醒、自然语言解析装配到一起,
//  并以 `@Observable` 暴露给 SwiftUI。
//
//  数据流(契约 §7.1「本地优先」):
//    用户操作 → engine(写本地 + 产出 op)→ 立即刷新 snapshot → SwiftUI 重绘
//                                          ↘ SyncCoordinator 异步 push
//    远端 ops → engine.applyRemote(契约 §7.3 合并)→ snapshot 变化 → 重绘 + 提醒重排期
//
//  登录门禁与目录隔离(契约 §7.6.3 / §7.6.4):
//    RootView 先读会话(`OrdoAuthService.restore()`)→ 有会话才打开
//    `Application Support/Ordo/<userDataDirName(userId)>/Ordo.store`;
//    换账号 = 换目录,两个账号**永不共用**同一份本地数据。
//    退出登录只清会话(见 `signOut()`),目录原样保留。
//
//  存储降级:SwiftData 容器创建失败时退回 `OrdoMemoryStorage`,并在状态栏提示(storageNotice)。
//

import Foundation
import Observation
import SwiftUI
import UserNotifications

@MainActor
@Observable
public final class AppEnvironment {

    // MARK: 依赖

    public let storage: OrdoStorageProtocol
    public let engine: OrdoEngineProtocol
    /// 令牌 / 设备标识(会话宿主)。
    public let tokenStore: OrdoAccountTokenStore
    /// 登录态与三个入口(登录 / 注册 / 游客)。
    public let auth: OrdoAuthService
    public let parser: OrdoNaturalLanguageParser
    public let clock: OrdoClock
    public let reminders: ReminderScheduler
    /// 日程数据源注入点(契约 §2.8 只读日历)。
    /// 默认 `OrdoEnvironmentAgendaProvider`(EventKit → 示例回退);
    /// 测试 / 预览可换成 `OrdoSampleAgendaProvider` / `OrdoEmptyAgendaProvider` / 自定义实现。
    public let agenda: OrdoAgendaProviding
    public private(set) var sync: SyncCoordinator?
    public private(set) var realtime: OrdoRealtimeClient?
    /// 本账号的本地数据目录(契约 §7.6.3;`nil` = 内存模式,未落盘)。
    public let userDataDirectory: URL?

    /// 当前会话(契约 §7.6.1)。直接读 `auth`,避免两处状态不一致。
    public var session: OrdoSessionRecord? { auth.session }

    public var authAPI: OrdoAuthAPI { auth.authAPI }

    // MARK: 状态

    public private(set) var snapshot: OrdoSnapshot = .empty
    public private(set) var counts: OrdoSidebarCounts = .zero
    public private(set) var isReady = false
    /// 存储降级提示(nil 表示一切正常)。
    public private(set) var storageNotice: String?
    public private(set) var calendarEvents: [OrdoCalendarEvent] = []
    /// 当前日程的来源:`.calendar` = 系统日历(EventKit 只读),`.sample` = 示例回退。
    public private(set) var agendaSource: OrdoAgendaSource = .sample
    public var toasts: [OrdoToast] = []
    public private(set) var notificationAuthorized: Bool = false

    private var subscription: OrdoSubscription?
    private var notificationDelegate: OrdoNotificationDelegate?

    // MARK: 初始化

    public init(
        storage: OrdoStorageProtocol,
        engine: OrdoEngineProtocol,
        tokenStore: OrdoAccountTokenStore,
        auth: OrdoAuthService,
        parser: OrdoNaturalLanguageParser,
        reminders: ReminderScheduler,
        clock: OrdoClock,
        userDataDirectory: URL? = nil,
        storageNotice: String? = nil,
        agenda: OrdoAgendaProviding = OrdoEnvironmentAgendaProvider()
    ) {
        self.storage = storage
        self.engine = engine
        self.tokenStore = tokenStore
        self.auth = auth
        self.parser = parser
        self.reminders = reminders
        self.clock = clock
        self.userDataDirectory = userDataDirectory
        self.storageNotice = storageNotice
        self.agenda = agenda
    }

    /// 组装整个应用(登录成功后的启动路径)。
    ///
    /// 步骤:打开**该 userId 专属**的本地库 → 预加载存储镜像 → 构造 KMP 引擎
    /// → 首次运行写入演示数据 → 订阅 → 构造同步与提醒。
    ///
    /// - Parameters:
    ///   - auth: 已完成登录鉴权的服务(提供会话 / 令牌 / 网络层)。
    ///   - session: 当前会话;决定本地数据目录(契约 §7.6.3 硬约束)。
    public static func bootstrap(
        auth: OrdoAuthService,
        session: OrdoSessionRecord,
        apiBaseURL: URL = OrdoAPIEnvironment.default.baseURL,
        useInMemoryStorage: Bool = false,
        seedIfEmpty: Bool = true
    ) async -> AppEnvironment {
        let clock = OrdoSystemClock()
        let uuid = OrdoDefaultUUIDProvider()
        let tokenStore = auth.tokenStore

        // 1) 本地存储:该账号专属目录(契约 §7.6.3)
        var notice: String?
        var storage: OrdoStorageProtocol
        var directory: URL?
        do {
            if useInMemoryStorage {
                storage = OrdoMemoryStorage()
            } else {
                let userDirectory = try OrdoAppDirectories.userDirectory(userId: session.userId)
                directory = userDirectory
                let container = try SwiftDataStorage.makeContainer(directory: userDirectory)
                storage = SwiftDataStorage(container: container)
            }
        } catch {
            storage = OrdoMemoryStorage()
            notice = "本地数据库不可用,已切换为内存模式(退出后数据不保留)"
        }

        // 2) 记录 schemaVersion(契约 §8 迁移入口)
        try? await storage.kvSetInt(OrdoKVKey.schemaVersion, value: Int64(OrdoSchema.version))

        // 3) KMP 引擎(内部会同步读取镜像中的快照/outbox/墓碑/kv)
        //    deviceId 用**设备级**值(根目录 kv),保证 HTTP 头与 op.deviceId 一致(契约 §7.6.1)。
        let deviceId = await tokenStore.currentDeviceId()
        let engine = await OrdoCoreBridge.make(storage: storage, clock: clock, uuid: uuid, deviceId: deviceId)

        // 4) 首次运行写入演示数据(由 KMP 核心提供,四端一致)
        if seedIfEmpty, engine.snapshot.todos.isEmpty, engine.snapshot.projects.isEmpty {
            _ = engine.seedDemoData(force: false)
            await engine.flushStorage()
        }

        // 5) 网络 / 实时通道(令牌来自会话)
        let httpClient = OrdoHTTPClient(
            environment: OrdoAPIEnvironment(baseURL: apiBaseURL),
            tokenStore: tokenStore,
            deviceIdentity: tokenStore
        )
        await httpClient.setRefresher(auth.tokenRefresher)
        let syncAPI = URLSessionSyncApi(client: httpClient)
        let realtime = OrdoRealtimeClient(
            configuration: OrdoRealtimeClient.Configuration(baseURL: apiBaseURL, deviceId: deviceId),
            tokenProvider: { [tokenStore] in
                await tokenStore.load()?.accessToken
            }
        )

        // 6) 提醒
        let reminders = ReminderScheduler(clock: clock)

        let environment = AppEnvironment(
            storage: storage,
            engine: engine,
            tokenStore: tokenStore,
            auth: auth,
            parser: OrdoCoreNaturalLanguageParser(),
            reminders: reminders,
            clock: clock,
            userDataDirectory: directory,
            storageNotice: notice,
            agenda: OrdoEnvironmentAgendaProvider()
        )
        environment.realtime = realtime

        // 6.5) 今日日程(只读;契约 §2.8)—— 授权被拒时静默回退示例数据
        await environment.refreshAgenda()

        // 7) 同步协调器
        let coordinator = SyncCoordinator(
            engine: engine,
            storage: storage,
            tokenStore: tokenStore,
            syncAPI: syncAPI,
            realtime: realtime,
            clock: clock,
            onReminder: { [weak environment] todoId, title, at in
                Task { @MainActor in
                    await environment?.reminders.deliverFastlane(todoId: todoId, title: title, at: at)
                }
            }
        )
        coordinator.onSnapshotRequiresReschedule = { [weak environment] in
            environment?.rescheduleReminders()
        }
        // 令牌被服务端判定失效(401 且 refresh 失败)→ 清会话回登录页,但**保留本地目录**
        coordinator.onAuthExpired = { [weak environment] in
            await environment?.handleAuthExpired()
        }
        environment.sync = coordinator

        return environment
    }

    /// 拆掉本环境(换账号 / 退回登录页时调用):停同步、取消引擎订阅。
    public func shutdown() async {
        sync?.stop()
        subscription?.cancel()
        subscription = nil
        isReady = false
    }

    // MARK: 生命周期

    public func start() async {
        subscription = engine.subscribe { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }
        apply(engine.snapshot)
        counts = engine.counts()
        isReady = true

        installReminderChannels()
        reminders.setForeground(true)
        reminders.registerCategories()
        notificationAuthorized = await reminders.refreshAuthorizationOnly()
        // 权限被拒不是错误:提醒改为应用内横幅 + 角标(见 ReminderScheduler),
        // 因此这里不弹失败提示,只在设置页如实说明(与 permissionDeniedHint 一致)。
        rescheduleReminders()

        notificationDelegate = OrdoNotificationDelegate(environment: self)
        await notificationDelegate?.install()

        await sync?.start()
    }

    public func handleScenePhase(isActive: Bool) async {
        await sync?.handleScenePhaseChange(isActive: isActive)
        reminders.setForeground(isActive)
        if isActive {
            rescheduleReminders()
            await refreshAgenda()
        }
    }

    private func apply(_ snapshot: OrdoSnapshot) {
        self.snapshot = snapshot
        counts = engine.counts()
    }

    // MARK: 提醒

    public func rescheduleReminders() {
        let snapshot = self.snapshot
        Task { [reminders] in
            await reminders.reschedule(snapshot: snapshot)
        }
    }

    // MARK: 今日日程(契约 §2.8,只读)

    /// 重新读取今日日程。权限被拒或当天无日程时由数据源自行回退示例数据(见 `OrdoAgendaProviding`)。
    ///
    /// 该方法是唯一写入 `calendarEvents` 的入口,日程**不进** KMP 核心、**不进** outbox/SwiftData,
    /// 因此不存在任何「日历数据被上传」的代码路径(契约 §9)。
    public func refreshAgenda() async {
        let day = OrdoDateFormatter.shared.today()
        let result = await agenda.eventsWithSource(on: day)
        calendarEvents = result.events
        agendaSource = result.source
    }

    /// 通知点击 → 深链(由 `OrdoNotificationDelegate` 调用)。
    public func handleNotificationDeepLink(_ url: String) {
        notificationDeepLink = url
    }

    // MARK: 应用内兜底提醒(权限被拒 / App 前台)

    /// 装配提醒的读写通道与应用内回调(在 `start()` 之前调用一次)。
    ///
    /// 「提醒已触发」记录写在 kv 表(键 `ordo.reminder.fired`),与同步数据完全隔离:
    /// 它只是本机的去重依据与角标来源,**不进 outbox、不上传**(契约 §7.2 只同步实体 op)。
    private func installReminderChannels() {
        reminders.firedRecordReader = { [storage] key in
            (try? await storage.kvGet(key)) ?? nil
        }
        reminders.firedRecordWriter = { [storage] key, value in
            try? await storage.kvSet(key, value: value)
        }
        reminders.onInAppReminder = { [weak self] title, at in
            guard let self else { return }
            let time = at.isEmpty ? "" : " · \(OrdoDateFormatter.shared.reminderLabel(at))"
            self.toast("提醒:\(title)\(time)", kind: .info)
        }
    }

    /// 用户进入「今天」清单 / 点开待办后清空应用内角标。
    public func markRemindersRead(todoId: String? = nil) {
        if let todoId {
            reminders.markRead(todoId: todoId)
        } else {
            reminders.markAllRead()
        }
    }

    /// 待消费的深链(Shell 视图读取后置空)。
    public var notificationDeepLink: String?

    public func handleNotificationAction(identifier: String, todoId: String) {
        switch identifier {
        case OrdoNotificationCategory.actionComplete:
            engine.toggleDone(id: todoId)
            persistCurrentSnapshot()
            toast("已完成", kind: .success)
        case OrdoNotificationCategory.actionSnooze:
            let formatter = OrdoDateFormatter.shared
            let snoozeDate = Date().addingTimeInterval(10 * 60)
            engine.setReminder(id: todoId, reminder: formatter.isoDayTime(snoozeDate))
            persistCurrentSnapshot()
            toast("10 分钟后再提醒", kind: .info)
        default:
            handleNotificationDeepLink(OrdoDeepLink.url(forTodo: todoId))
        }
    }

    // MARK: 查询(转交 KMP 核心)

    public func sections(for query: OrdoListQuery) -> [OrdoListSection] {
        engine.sections(query)
    }

    public func list(for query: OrdoListQuery) -> [OrdoTodo] {
        engine.list(query)
    }

    public func subtitle(for query: OrdoListQuery) -> String {
        switch query.kind {
        case .today:
            let today = OrdoDateFormatter.shared.today()
            return "今天 · \(OrdoDateFormatter.shared.weekday(today))"
        case .upcoming:
            return "未来 14 天 \(counts.upcoming) 项"
        case .anytime:
            return "随时可做 \(counts.anytime) 项"
        case .someday:
            return "以后再说的 \(counts.someday) 项"
        case .logbook:
            return "已完成 \(counts.logbook) 项"
        case .inbox:
            return "未安排的 \(counts.inbox) 项"
        case .project:
            guard let project = snapshot.project(id: query.id) else { return "" }
            let progress = projectProgress(project.id)
            let area = snapshot.area(id: project.areaId)?.name ?? "无区域"
            return "\(area) · 进度 \(Int(progress.fraction * 100))%"
        case .area:
            // 区域没有独立计数(Kotlin `SidebarCounts` 不提供),用当前视图条目数表达。
            let areaName = snapshot.area(id: query.id)?.name ?? "区域"
            let items = engine.list(query).count
            return "\(areaName) · \(items) 项未完成"
        case .tag:
            return "标签 · \(counts.tagCount(query.id ?? "")) 项"
        case .search:
            return "搜索结果"
        }
    }

    public func title(for query: OrdoListQuery) -> String {
        switch query.kind {
        case .project: return snapshot.project(id: query.id)?.name ?? "项目"
        case .area: return snapshot.area(id: query.id)?.name ?? "区域"
        case .tag: return "#\(query.id ?? "")"
        case .search: return "搜索"
        default: return query.kind.displayName
        }
    }

    // MARK: 写操作(全部转交 KMP 核心,随后落盘一次)

    @discardableResult
    public func createTodo(title: String, options: OrdoTodoOptions = .none) -> OrdoTodo {
        let created = engine.createTodo(title: title, options: options)
        persistCurrentSnapshot()
        return created
    }

    /// 输入原文直接建待办:标题里的日期/时间/标签由 KMP 核心的 NLP 解析(契约 §5)。
    @discardableResult
    public func createTodo(fromRawInput raw: String, options: OrdoTodoOptions = .none) -> OrdoTodo {
        let created = engine.createTodo(title: raw, options: options)
        persistCurrentSnapshot()
        return created
    }

    public func updateTodo(id: String, mutate: (inout OrdoTodo) -> Void) {
        engine.updateTodo(id: id, mutate: mutate)
        persistCurrentSnapshot()
    }

    public func toggleDone(id: String) {
        engine.toggleDone(id: id)
        persistCurrentSnapshot()
    }

    public func deleteTodo(id: String) {
        engine.deleteTodo(id: id)
        persistCurrentSnapshot()
        toast("已删除", kind: .info)
    }

    @discardableResult
    public func duplicateTodo(id: String) -> OrdoTodo? {
        let copy = engine.duplicateTodo(id: id)
        persistCurrentSnapshot()
        return copy
    }

    public func setWhen(id: String, when: OrdoWhen, date: String? = nil) {
        engine.setWhen(id: id, when: when, date: date)
        persistCurrentSnapshot()
    }

    public func setDeadline(id: String, date: String?) {
        engine.setDeadline(id: id, date: date)
        persistCurrentSnapshot()
    }

    public func setReminder(id: String, reminder: String?) {
        engine.setReminder(id: id, reminder: reminder)
        persistCurrentSnapshot()
        rescheduleReminders()
    }

    public func setRepeat(id: String, rule: OrdoRepeatRule?) {
        engine.setRepeat(id: id, rule: rule)
        persistCurrentSnapshot()
    }

    public func addChecklistItem(todoId: String, title: String) {
        engine.addChecklistItem(todoId: todoId, title: title)
        persistCurrentSnapshot()
    }

    public func toggleChecklistItem(todoId: String, itemId: String) {
        engine.toggleChecklistItem(todoId: todoId, itemId: itemId)
        persistCurrentSnapshot()
    }

    public func removeChecklistItem(todoId: String, itemId: String) {
        engine.removeChecklistItem(todoId: todoId, itemId: itemId)
        persistCurrentSnapshot()
    }

    public func addTag(todoId: String, tag: String) {
        engine.addTag(id: todoId, tag: tag)
        persistCurrentSnapshot()
    }

    public func removeTag(todoId: String, tag: String) {
        engine.removeTag(id: todoId, tag: tag)
        persistCurrentSnapshot()
    }

    public func moveTodo(id: String, projectId: String?, areaId: String?, headingId: String?) {
        engine.moveTodo(id: id, projectId: projectId, areaId: areaId, headingId: headingId)
        persistCurrentSnapshot()
    }

    // MARK: 拖拽排序(契约 §2.4 的 `order` 字段)

    /// 把一批待办按新顺序写回核心的 `order`。
    ///
    /// **为什么必须整段提交**:核心 `reorderTodos(ids:)` 的语义是
    /// 「`ids[i]` 的 order = i」,它并不知道列表里被隐藏/过滤掉了哪些条目,
    /// 因此 iOS 侧必须提交**同一容器内完整的可见序列**,否则会把未提交的条目挤到数组末尾。
    ///
    /// **为什么限定同一容器**:`order` 只在
    /// `(when, projectId, headingId)` 三元组相同的范围内连续(`OrdoEngine.nextOrder`);
    /// 跨分区/跨项目拖动会写出彼此竞争的 order,因此这里显式拒绝并给出提示。
    ///
    /// - Parameter ids: 同一容器内的**完整**待办序列(拖放后的目标顺序)。
    /// - Returns: 是否成功受理。
    @discardableResult
    public func reorderTodos(ids: [String]) -> Bool {
        let todos = ids.compactMap { snapshot.todo(id: $0) }
        guard todos.count == ids.count, todos.count > 1 else { return false }

        let containers = Set(todos.map(Self.containerKey(for:)))
        guard containers.count == 1 else {
            toast("手动排序只在同一分区/项目内生效", kind: .info)
            return false
        }

        engine.reorderTodos(ids: ids)
        persistCurrentSnapshot()
        return true
    }

    /// 排序容器标识:`order` 在核心中以 `(when, projectId, headingId)` 为作用域连续。
    public static func containerKey(for todo: OrdoTodo) -> String {
        "\(todo.when.rawValue)|\(todo.projectId ?? "-")|\(todo.headingId ?? "-")"
    }

    @discardableResult
    public func createProject(name: String, areaId: String? = nil, headingNames: [String] = []) -> OrdoProject {
        let created = engine.createProject(name: name, areaId: areaId, headingNames: headingNames)
        persistCurrentSnapshot()
        return created
    }

    @discardableResult
    public func createArea(name: String) -> OrdoArea {
        let created = engine.createArea(name: name)
        persistCurrentSnapshot()
        return created
    }

    @discardableResult
    public func createHeading(projectId: String, name: String, order: Int = -1) -> OrdoHeading {
        let created = engine.createHeading(projectId: projectId, name: name, order: order)
        persistCurrentSnapshot()
        return created
    }

    /// 完成项目(契约 §2.2 v1.1)。
    ///
    /// **完成判定完全由 KMP 核心给出**(`OrdoEngine.completeProject`),Swift 侧不复制任何规则
    /// —— 尤其**不统计 heading 是否归档**:标题是组织容器而不是工作项,核心在完成项目时
    /// 会自动归档未归档的标题(每个标题一条 Op),因此桥接层无需任何补偿。
    ///
    /// 这里只做两件事:转发调用 + 把**真实原因**翻译成与之一致的提示。
    @discardableResult
    public func completeProject(id: String) -> Bool {
        guard engine.completeProject(id: id) else {
            // 核心返回 false 的原因只有两类(见 OrdoEngine.completeProject):
            // ① 项目下还有 status == open 的待办 —— 唯一与用户操作有关的原因,提示必须给出条数;
            // ② 项目不存在或已完成 —— 状态竞争(例如另一台设备刚完成),与「待办没做完」无关,
            //    因此不能笼统地提示「还有未完成的待办」。
            let open = projectProgress(id).open
            if open > 0 {
                toast("项目还有 \(open) 项未完成的待办", kind: .failure)
            } else if snapshot.project(id: id)?.status == .done {
                toast("项目已经完成", kind: .info)
            } else {
                toast("找不到这个项目", kind: .failure)
            }
            return false
        }
        persistCurrentSnapshot()
        return true
    }

    /// 重新打开已完成的项目(契约 §2.2:状态回到 open,子待办状态不变)。
    /// 侧栏只列 `status == .open` 的项目,因此完成后的项目需要这个显式的回退入口。
    public func reopenProject(id: String) {
        engine.reopenProject(id: id)
        persistCurrentSnapshot()
    }

    /// 项目完成度(比例来自核心 `projectProgress(projectId:)`,Swift 只补充 done/open 展示计数)。
    public func projectProgress(_ projectId: String) -> OrdoProgress {
        let fraction = engine.projectProgress(projectId: projectId)
        let todos = snapshot.todos.filter { $0.projectId == projectId && !$0.deleted }
        return OrdoProgress(
            done: todos.filter { $0.status == .done }.count,
            open: todos.filter { $0.status == .open }.count,
            coreFraction: fraction
        )
    }

    public func headings(of projectId: String) -> [OrdoHeading] {
        engine.headingsOf(projectId: projectId)
    }

    // MARK: 落盘与查询

    /// 本地优先:UI 立即更新;Kotlin 引擎已同步写入存储镜像,这里只等待异步写回落盘。
    private func persistCurrentSnapshot() {
        Task { [engine] in
            await engine.flushStorage()
        }
    }

    /// 重置为演示数据(设置页)。
    /// 使用 KMP 核心自带的演示数据(四端一致),Swift 侧不再维护一份样本。
    public func resetToSeedData() async {
        engine.clearAll()
        _ = engine.seedDemoData(force: true)
        await engine.flushStorage()
        toast("已重置为示例数据", kind: .success)
    }

    // MARK: Toast

    public func toast(_ text: String, kind: OrdoToast.Kind = .info, retry: (@Sendable () -> Void)? = nil) {
        toasts.append(OrdoToast(text: text, kind: kind, retryAction: retry))
    }

    public func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    // MARK: 设置项

    public func setTheme(_ theme: OrdoThemePreference) async {
        try? await storage.kvSet(OrdoKVKey.themePreference, value: theme.rawValue)
    }

    public func storedTheme() async -> OrdoThemePreference {
        let raw = (try? await storage.kvGet(OrdoKVKey.themePreference)) ?? nil
        return OrdoThemePreference(rawValue: raw ?? "") ?? .system
    }

    public func currentUserEmail() async -> String? {
        await tokenStore.userEmail()
    }

    public func isSignedIn() async -> Bool {
        await tokenStore.isSignedIn()
    }

    /// 当前账号是否为游客(契约 §7.6.1)。
    public func isGuest() async -> Bool {
        await tokenStore.userIsGuest()
    }

    public func deviceName() async -> String {
        await tokenStore.deviceName()
    }

    // MARK: 通知权限

    public func requestNotificationPermission() {
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.reminders.requestAuthorization()
            self.notificationAuthorized = granted
            if granted {
                self.rescheduleReminders()
            } else {
                self.toast(ReminderScheduler.permissionDeniedHint, kind: .failure)
            }
        }
    }

    // MARK: 登录 / 登出(契约 §7.6.3 / §7.6.4)

    /// 登录成功后的收尾:把本地已有的数据推上去,或拉取远端快照(契约 §7.1)。
    public func finishSignIn() async {
        await sync?.bootstrapFromRemoteIfEmpty()
    }

    /// 退出登录:只清**会话**(契约 §7.6.3),该 userId 的本地数据目录原样保留,
    /// 下次同一账号登录时数据仍在(离线可用,联网后增量同步)。
    ///
    /// 调用方(RootView)会在 `auth.session` 变为 nil 后拆掉本环境并回到登录页。
    public func signOut() async {
        await auth.signOut()
        await sync?.handleSignedOut()
    }

    /// 令牌被服务端判定失效(401 + refresh 失败):清会话回登录页,但**不删数据目录**。
    public func handleAuthExpired() async {
        await auth.invalidateSession()
        await sync?.handleSignedOut()
    }
}

// MARK: - 主题偏好

public enum OrdoThemePreference: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// 循环切换(对应快捷键 ⌘⇧D,规范 §6)。
    public var next: OrdoThemePreference {
        switch self {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }
}

// MARK: - 通知代理

/// 处理通知点击与动作(标记完成 / 稍后提醒 / 打开待办)。
///
/// 设计说明:`UNUserNotificationCenterDelegate` 的回调在 SDK 中不是主线程隔离的,
/// 因此本类**不标注** `@MainActor`,而是在需要触碰 UI 状态时显式 `await MainActor.run`;
/// `AppEnvironment` 是 `@MainActor` 类型(隐式 `Sendable`),可以安全地被弱引用持有。
public final class OrdoNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    private weak var environment: AppEnvironment?

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// 在主线程把自身安装为通知中心代理。
    public func install() async {
        await MainActor.run {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // 前台也展示横幅,保证 Fastlane 提醒不被静默吞掉。
        [.banner, .sound, .list]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = ReminderScheduler.action(from: response)
        let link = ReminderScheduler.deepLink(from: response)
        await MainActor.run { [weak environment] in
            guard let environment else { return }
            if let action {
                environment.handleNotificationAction(identifier: action.kind, todoId: action.todoId)
            } else if let link {
                environment.handleNotificationDeepLink(link)
            }
        }
    }
}
