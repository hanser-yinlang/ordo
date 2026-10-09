//
//  ReminderScheduler.swift
//  Ordo
//
//  系统集成:UNUserNotificationCenter(契约 §7.5 Fastlane + 设计规范 §7 平台映射)。
//
//  职责:
//  - 申请通知权限;被拒绝时**降级为应用内提醒**(横幅 + 角标),而不是静默丢弃;
//  - 按 `todo.reminder`(契约 §2.4,`YYYY-MM-DDTHH:mm`)排期本地通知;
//  - 通知点击 → 打开 `ordo://todo/<id>` 深链,直达对应待办详情;
//  - 收到实时通道的 `reminder`(Fastlane:服务端在未来 60 秒内扫描到点)时立即投递;
//  - 待办被完成/删除/改期后重新排期(整体 diff,不做全量取消重建)。
//
//  「提醒已触发」的本地记录(去重 + 角标):
//  · 通知真正投递(或在 App 前台被 `willPresent` 展示)后,把
//    `fired[todoId] = 提醒时间点` 记进 kv(`ordo.reminder.fired`),并清理 30 天前的条目;
//  · 同一条待办、同一个提醒时间点**只登记一次** —— `reschedule` 每次都会调用,因此必须有这条记录,
//    否则每次快照变化都会重复弹横幅;
//  · 记录同时驱动应用内角标(`unreadReminderCount`),进入「今天」或调用 `markAllRead()` 后
//    以 `lastReadAt` 为界清零(冷启动后不会把看过的提醒再算一遍)。
//

import Foundation
import UserNotifications

/// 通知类别与动作标识。
/// 放在文件作用域(而非 `ReminderScheduler` 内部),避免全局 actor 隔离带来的
/// 「非隔离上下文无法访问」问题 —— 这些常量需要被 `UNUserNotificationCenterDelegate` 使用。
public enum OrdoNotificationCategory {
    public static let todo = "ORDO_TODO_REMINDER"
    public static let actionComplete = "ORDO_ACTION_COMPLETE"
    public static let actionSnooze = "ORDO_ACTION_SNOOZE_10"
    public static let actionOpen = "ORDO_ACTION_OPEN"
}

/// 通知 `userInfo` 的键。
public enum OrdoNotificationUserInfo {
    public static let todoId = "todoId"
    public static let url = "deepLink"
}

/// 「提醒已触发」记录的持久化形状(kv `ordo.reminder.fired`)。
///
/// · `fired`:`todoId → 提醒时间点(YYYY-MM-DDTHH:mm)`,用于**去重**(同一时间点只提醒一次);
/// · `lastReadAt`:用户最后一次「已查看全部提醒」的时刻(epoch millis),用于**角标**。
///
/// 只存本机、不进同步(它既不是实体也不是 op,契约 §7.2 的 outbox 不会有它)。
struct FiredRecord: Codable {
    var fired: [String: String]
    var lastReadAt: Int64
}

@MainActor
public final class ReminderScheduler {

    /// 兼容别名(内部沿用较短的写法)。
    public typealias Category = OrdoNotificationCategory
    public typealias DeepLinkKey = OrdoNotificationUserInfo

    private let center: UNUserNotificationCenter
    private let clock: OrdoClock
    private var scheduled: [String: String] = [:]
    public private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// 通知动作回调(由 AppEnvironment 注入:完成 / 稍后提醒 10 分钟)。
    public var onAction: (@MainActor (String, String) -> Void)?

    // MARK: 应用内兜底(权限被拒 / App 在前台)

    /// 应用内提醒回调(由 `AppEnvironment` 注入:弹 Toast 横幅 + 更新角标)。
    /// 参数为 `(标题, 提醒时间点)`。
    public var onInAppReminder: (@MainActor (String, String) -> Void)?
    /// 当前应用内已触发、未被用户查看的提醒数(角标)。
    public private(set) var unreadReminderCount: Int = 0
    /// 最近一次应用内提醒的触发原因(设置页/调试展示用)。
    public private(set) var lastInAppReason: InAppReason = .permissionDenied
    /// 「已触发」记录的读写通道(由 `AppEnvironment` 注入,复用 `OrdoStorageProtocol.kv*`)。
    /// 未注入时退化为「进程内记录」:功能仍可用,只是冷启动后不再记得。
    public var firedRecordReader: (@MainActor (String) async -> String?)?
    public var firedRecordWriter: (@MainActor (String, String?) async -> Void)?
    /// App 是否在前台(由 `AppEnvironment.handleScenePhase` 维护)。
    /// 前台时系统通知会被 `willPresent` 接管,同样走应用内横幅,保证用户一定看得到。
    private var isForeground = false

    /// 「提醒已触发」本地记录的 kv 键(`{"fired":{todoId: 提醒时间点},"lastReadAt":…}`)。
    public static let firedRecordKey = "ordo.reminder.fired"
    /// 已触发记录的保留时长(30 天,与墓碑一致)。
    public static let firedRecordRetentionDays = 30

    private var fired: [String: String] = [:]
    /// 用户最后一次「已查看全部提醒」的时刻(epoch millis);用于角标与冷启动后的去重判断。
    private var lastReadAt: Int64 = 0
    private var firedLoaded = false

    public init(center: UNUserNotificationCenter = .current(), clock: OrdoClock = OrdoSystemClock()) {
        self.center = center
        self.clock = clock
    }

    // MARK: 权限

    @discardableResult
    public func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            return granted
        } catch {
            await refreshAuthorizationStatus()
            return false
        }
    }

    public func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// 启动时使用:只读取现状(**不**弹系统授权面板),返回是否已获授权。
    ///
    /// 授权面板由用户主动触发(`AppEnvironment.requestNotificationPermission()`,设置页按钮),
    /// 避免冷启动即弹窗打断用户;未授权期间提醒自动走应用内兜底。
    @discardableResult
    public func refreshAuthorizationOnly() async -> Bool {
        await refreshAuthorizationStatus()
        return authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    /// 通知权限说明(展示在设置页,与 Info.plist 的文案一致)。
    public static let permissionExplanation = "开启通知后,Ordo 会在你设定的提醒时刻提醒你;提醒时间来自每一条待办的「提醒」字段,数据只保存在本机。"
    public static let permissionDeniedHint = "通知权限已关闭,请到「设置 › 通知 › Ordo」中开启。"

    // MARK: 类别注册

    public func registerCategories() {
        let complete = UNNotificationAction(
            identifier: Category.actionComplete,
            title: "标记完成",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: Category.actionSnooze,
            title: "10 分钟后再提醒",
            options: []
        )
        let open = UNNotificationAction(
            identifier: Category.actionOpen,
            title: "打开待办",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Category.todo,
            actions: [complete, snooze, open],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    // MARK: 排期

    /// 按当前快照重新排期(整体 diff:新增/变更的排期,消失的取消)。
    ///
    /// 权限被拒时**不排系统通知**,但仍会扫描到点的本地提醒 → 走应用内兜底(见 `deliverInApp`);
    /// 因此在没有通知权限的设备上,「提醒」功能依然可用,只是展示位置从系统横幅变成应用内横幅。
    public func reschedule(snapshot: OrdoSnapshot) async {
        await refreshAuthorizationStatus()
        await loadFiredRecordsIfNeeded()

        let now = clock.now()
        let nowDate = Date(timeIntervalSince1970: Double(now) / 1000)
        let systemNotificationsEnabled = authorizationStatus == .authorized || authorizationStatus == .provisional
        var desired: [String: String] = [:]
        var dueInApp: [(todo: OrdoTodo, reminder: String)] = []

        for todo in snapshot.todos where !todo.deleted {
            guard todo.status == .open, let reminder = todo.reminder, reminder.count >= 16 else { continue }
            guard let fireDate = fireDate(from: reminder) else { continue }
            if fireDate > nowDate {
                desired[todo.id] = reminder
            } else if !systemNotificationsEnabled {
                // 无通知权限(被拒或尚未决定):到点但还没登记过的提醒 → 应用内补一次
                dueInApp.append((todo, reminder))
            }
        }

        // 1) 取消不再需要的
        let toCancel = scheduled.keys.filter { desired[$0] != scheduled[$0] }
        if !toCancel.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: toCancel.map(identifier(todoId:)))
        }

        // 2) 新增或更新(无权限时不排期,留给应用内兜底)
        if systemNotificationsEnabled {
            for todo in snapshot.todos where desired[todo.id] != nil && desired[todo.id] != scheduled[todo.id] {
                await schedule(todo: todo, fireDate: fireDate(from: todo.reminder ?? ""))
            }
        }

        scheduled = desired

        for item in dueInApp {
            await deliverInApp(todoId: item.todo.id, title: item.todo.title, at: item.reminder, reason: .permissionDenied)
        }

        await updateBadge(openTodayCount: todayCount(snapshot))
    }

    private func schedule(todo: OrdoTodo, fireDate: Date?) async {
        guard let fireDate else { return }
        let content = notificationContent(todoId: todo.id, title: todo.title, body: bodyText(for: todo, fireDate: fireDate))

        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        components.second = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier(todoId: todo.id), content: content, trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            // 排期失败不阻断 UI;下一次 reschedule 会重试。
        }
    }

    /// Fastlane:服务端到点推送 → 立即投递(即使本地排期尚未触发)。
    ///
    /// 投递路径(按优先级):
    /// 1. App 在**前台** → 直接走应用内横幅(`willPresent` 此时才展示系统通知,太晚);
    /// 2. 有通知权限且 `center.add` 成功 → 立即投递的系统通知;
    /// 3. 其余情况(无权限 / 投递抛错)→ 应用内横幅兜底。
    public func deliverFastlane(todoId: String, title: String, at: String) async {
        await refreshAuthorizationStatus()
        await loadFiredRecordsIfNeeded()

        if isForeground {
            await deliverInApp(todoId: todoId, title: title, at: at, reason: .foreground)
            return
        }

        guard authorizationStatus == .authorized || authorizationStatus == .provisional else {
            await deliverInApp(todoId: todoId, title: title, at: at, reason: .permissionDenied)
            return
        }

        let body = at.isEmpty ? "到点了" : "提醒时间:\(OrdoDateFormatter.shared.reminderLabel(at))"
        let content = notificationContent(todoId: todoId, title: title, body: body)
        let request = UNNotificationRequest(
            identifier: identifier(todoId: todoId) + ".fastlane",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            await recordFired(todoId: todoId, reminder: at)
        } catch {
            await deliverInApp(todoId: todoId, title: title, at: at, reason: .permissionDenied)
        }
    }

    public func cancel(todoId: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier(todoId: todoId)])
        scheduled[todoId] = nil
    }

    public func cancelAll() {
        center.removeAllPendingNotificationRequests()
        scheduled.removeAll()
    }

    // MARK: 应用内兜底(权限被拒 / App 在前台)

    /// 应用内提醒的触发原因(仅用于日志与可读性,不影响行为)。
    public enum InAppReason: String, Sendable {
        /// 通知权限被拒。
        case permissionDenied
        /// App 正在前台(系统通知会被前台策略接管,应用内横幅更直接)。
        case foreground
    }

    /// App 前后台状态由 `AppEnvironment.handleScenePhase(isActive:)` 维护。
    public func setForeground(_ value: Bool) {
        isForeground = value
    }

    /// 投递一条应用内提醒:回调给 `AppEnvironment` → Toast 横幅 + 已触发列表/角标。
    ///
    /// 同一条待办、同一个提醒时间点只会回调一次(`fired` 记录去重),
    /// 因此 `reschedule` 被频繁调用也不会重复弹横幅。
    private func deliverInApp(todoId: String, title: String, at: String, reason: InAppReason) async {
        await loadFiredRecordsIfNeeded()
        guard !hasFired(todoId: todoId, reminder: at) else { return }
        await recordFired(todoId: todoId, reminder: at)
        lastInAppReason = reason
        onInAppReminder?(title.isEmpty ? "待办提醒" : title, at)
    }

    /// 用户已查看全部应用内提醒(进入「今天」或点开待办时调用)。
    public func markAllRead() {
        lastReadAt = clock.now()
        unreadReminderCount = 0
        Task { await persistFiredRecord() }
    }

    /// 单条已读(点开某条待办时调用)。
    public func markRead(todoId: String) {
        _ = todoId
        unreadReminderCount = max(0, unreadReminderCount - 1)
    }

    // MARK: 已触发记录(去重 + 角标)

    private func loadFiredRecordsIfNeeded() async {
        guard !firedLoaded else { return }
        firedLoaded = true
        let raw = await readFiredRecord()
        let decoded = decodeFired(raw)
        fired = decoded.fired
        lastReadAt = decoded.lastReadAt
        pruneFired()
        unreadReminderCount = unreadCount()
    }

    /// 记录「已触发」;返回是否为首次登记。
    @discardableResult
    public func recordFired(todoId: String, reminder: String) async -> Bool {
        await loadFiredRecordsIfNeeded()
        guard !hasFired(todoId: todoId, reminder: reminder) else { return false }
        fired[todoId] = reminder
        pruneFired()
        unreadReminderCount = unreadCount()
        await persistFiredRecord()
        return true
    }

    public func hasFired(todoId: String, reminder: String) -> Bool {
        guard let recorded = fired[todoId] else { return false }
        // 提醒时间点未变 → 视为同一次提醒(改期后时间点变化,允许再次提醒)
        return recorded == normalized(reminder)
    }

    /// 清空已触发记录(退出登录 / 重置数据)。
    public func clearFiredRecords() async {
        fired.removeAll()
        lastReadAt = 0
        unreadReminderCount = 0
        await persistFiredRecord()
    }

    /// 已触发但用户尚未查看的条数(应用内角标)。
    ///
    /// 「已读」以**时间点**持久化(`lastReadAt`):提醒时间晚于上次已读时刻 → 仍未读。
    /// 因此冷启动后角标不会把已经看过的提醒再算一遍。
    private func unreadCount() -> Int {
        fired.values.filter { reminder in
            guard let date = fireDate(from: reminder) else { return false }
            return Int64(date.timeIntervalSince1970 * 1000) > lastReadAt
        }.count
    }

    private func normalized(_ reminder: String) -> String {
        String(reminder.prefix(16))
    }

    private func pruneFired() {
        let cutoff = clock.now() - Int64(Self.firedRecordRetentionDays) * 24 * 60 * 60 * 1000
        fired = fired.filter { _, reminder in
            guard let date = fireDate(from: reminder) else { return false }
            return Int64(date.timeIntervalSince1970 * 1000) >= cutoff
        }
    }

    private func decodeFired(_ raw: String?) -> (fired: [String: String], lastReadAt: Int64) {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return ([:], 0) }
        // 当前格式:`{"fired":{…},"lastReadAt":…}`
        if let record = try? JSONDecoder().decode(FiredRecord.self, from: data) {
            return (record.fired, record.lastReadAt)
        }
        // 兼容最初的「裸 map」格式:`{"todoId":"YYYY-MM-DDTHH:mm"}`
        if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            return (legacy, 0)
        }
        return ([:], 0)
    }

    private func encodeFired() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let record = FiredRecord(fired: fired, lastReadAt: lastReadAt)
        guard let data = try? encoder.encode(record), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func readFiredRecord() async -> String? {
        await firedRecordReader?(Self.firedRecordKey)
    }

    private func persistFiredRecord() async {
        let isEmpty = fired.isEmpty && lastReadAt == 0
        await firedRecordWriter?(Self.firedRecordKey, isEmpty ? nil : encodeFired())
    }

    // MARK: 徽标

    public func updateBadge(openTodayCount: Int) async {
        do {
            try await center.setBadgeCount(max(0, openTodayCount))
        } catch {
            // 徽标失败无需打扰用户。
        }
    }

    // MARK: 工具

    private func identifier(todoId: String) -> String { "ordo.reminder.\(todoId)" }

    /// 系统通知内容(本地排期与 Fastlane 共用,保证两者外观一致)。
    private func notificationContent(todoId: String, title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "待办提醒" : title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Category.todo
        content.userInfo = [
            DeepLinkKey.todoId: todoId,
            DeepLinkKey.url: "ordo://todo/\(todoId)"
        ]
        return content
    }

    private func fireDate(from reminder: String) -> Date? {
        OrdoDateFormatter.shared.dateTime(fromISO: reminder)
    }

    private func bodyText(for todo: OrdoTodo, fireDate: Date) -> String {
        var parts: [String] = []
        if let project = todo.projectId { parts.append("项目:\(project)") }
        if let deadline = todo.deadline { parts.append("截止 \(OrdoDateFormatter.shared.shortDate(deadline))") }
        if !todo.tags.isEmpty { parts.append(todo.tags.map { "#\($0)" }.joined(separator: " ")) }
        if parts.isEmpty { parts.append(OrdoDateFormatter.shared.timeLabel(todo.reminder ?? "")) }
        return parts.joined(separator: " · ")
    }

    private func todayCount(_ snapshot: OrdoSnapshot) -> Int {
        let today = OrdoDateFormatter.shared.today()
        return snapshot.todos.filter { todo in
            guard todo.status == .open else { return false }
            if todo.when == .today || todo.when == .evening { return true }
            if todo.when == .date, let date = todo.date, date <= today { return true }
            if let deadline = todo.deadline, deadline <= today { return true }
            return false
        }.count
    }
}

// MARK: - 通知响应解析
//
// 说明:`UNUserNotificationCenterDelegate` 的回调不是主线程隔离的,因此这里把解析函数
// 标记为 `nonisolated static`,让代理可以直接调用(不依赖 `ReminderScheduler` 实例)。

public extension ReminderScheduler {
    /// 从通知响应中解析深链(供 `UNUserNotificationCenterDelegate` 调用)。
    nonisolated static func deepLink(from response: UNNotificationResponse) -> String? {
        let info = response.notification.request.content.userInfo
        if let url = info[OrdoNotificationUserInfo.url] as? String { return url }
        if let todoId = info[OrdoNotificationUserInfo.todoId] as? String { return "ordo://todo/\(todoId)" }
        return nil
    }

    /// 从通知响应中解析动作(完成 / 稍后)。
    nonisolated static func action(from response: UNNotificationResponse) -> (kind: String, todoId: String)? {
        let info = response.notification.request.content.userInfo
        guard let todoId = info[OrdoNotificationUserInfo.todoId] as? String else { return nil }
        return (response.actionIdentifier, todoId)
    }
}
