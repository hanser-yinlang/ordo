//
//  EventKitAgenda.swift
//  Ordo
//
//  系统日历接入(契约 §2.8):CalendarEvent **只读、设备本地、不参与同步**。
//
//  数据流:
//    EventKit(EKEventStore)──只读查询──▶ OrdoCalendarEvent ──▶ AppEnvironment.calendarEvents
//                                                                    │
//                                                       Lists/AgendaSectionView(「今天」清单顶部)
//
//  严格边界(契约 §2.8 + §9「日历事件仅本地读取,不上传」):
//  · 本文件**只读** EventKit:不调用 `save` / `remove` / `commit`,全工程不存在写入日历的代码路径;
//  · 读到的日程不进 KMP 核心、不进 outbox、不进 SwiftData 的实体表 —— 只活在内存里供当天渲染;
//  · 权限被拒 / 设备上没有任何日程时,由 `OrdoEnvironmentAgendaProvider` 回退到示例数据,
//    保证「今天」清单顶部的日程区块永远有内容可展示,且不弹出任何错误。
//
//  注入点:`OrdoAgendaProviding` 是纯 Swift 协议(不 import EventKit),
//  因此预览、单元测试与未来的实现替换(如鸿蒙/桌面端日历、只读 ICS 订阅)都只需换一个实例。
//

import EventKit
import Foundation

// MARK: - 抽象

/// 日程来源(用于 UI 区分真实日历与示例回退)。
/// `rawValue` 是纯展示信息,**不进同步、不进本地库**(契约 §2.8)。
public enum OrdoAgendaSource: String, Sendable {
    /// 来自系统日历(EventKit 只读)。
    case calendar
    /// 示例日程(无权限或当天无日程时的静默回退)。
    case sample
}

/// 日程数据源。实现必须是 `Sendable`(会被 `AppEnvironment` 在启动时调用)。
public protocol OrdoAgendaProviding: Sendable {
    /// 当前授权状态是否允许读取日程。
    func currentAuthorization() async -> Bool
    /// 需要时发起权限请求;返回是否拿到读取权限。
    func requestAuthorization() async -> Bool
    /// 取某一天(`YYYY-MM-DD`)的日程,按开始时间升序。
    func events(on day: String) async -> [OrdoCalendarEvent]
    /// 取某一天的日程并标注来源。
    func eventsWithSource(on day: String) async -> (events: [OrdoCalendarEvent], source: OrdoAgendaSource)
}

public extension OrdoAgendaProviding {
    /// 默认实现:能读到就认为来自系统日历(具体实现可覆写以获得更精确的来源)。
    func eventsWithSource(on day: String) async -> (events: [OrdoCalendarEvent], source: OrdoAgendaSource) {
        guard await currentAuthorization() else { return ([], .sample) }
        return (await events(on: day), .calendar)
    }
}

// MARK: - EventKit 实现

/// 系统日历(`EKEventStore`)的只读实现。
///
/// 全程 `@MainActor`:EventKit 的 `EKEventStore` / `EKEvent` 不是 `Sendable`,
/// 跨 actor 传递会触发 Swift 6 严格并发错误;放在主执行器上即可完全避免,
/// 且查询范围只有「一天」,不存在可感知的主线程阻塞。
@MainActor
public final class OrdoEventKitAgendaProvider: OrdoAgendaProviding {

    private let store: EKEventStore
    private let fallback: OrdoAgendaProviding
    private let calendar: Calendar

    /// - Parameters:
    ///   - store: 便于测试注入;默认新建一个 `EKEventStore`。
    ///   - fallback: 无权限或无数据时使用的数据源(默认示例日程)。
    public init(
        store: EKEventStore = EKEventStore(),
        fallback: OrdoAgendaProviding = OrdoSampleAgendaProvider(),
        calendar: Calendar = .current
    ) {
        self.store = store
        self.fallback = fallback
        self.calendar = calendar
    }

    // MARK: 权限

    /// iOS 17 起日历权限拆分为「完整访问」与「仅写入」:
    /// 我们只需要读,因此要求 `.fullAccess`;`.writeOnly` 与 `.denied` 一律视为不可用。
    public func currentAuthorization() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .authorized { return true }              // iOS 16 及更早的「已授权」
        if #available(iOS 17.0, *) { return status == .fullAccess }
        return false
    }

    public func requestAuthorization() async -> Bool {
        if await currentAuthorization() { return true }
        if #available(iOS 17.0, *) {
            // Info.plist 必须提供 NSCalendarsFullAccessUsageDescription,否则该调用直接失败。
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            return granted
        } else {
            // iOS 16 回退路径:旧 API + NSCalendarsUsageDescription(见 README §1 步骤 0)。
            return (try? await store.requestAccess(to: .event)) ?? false
        }
    }

    // MARK: 查询

    public func events(on day: String) async -> [OrdoCalendarEvent] {
        guard await currentAuthorization() else { return await fallback.events(on: day) }
        guard let start = OrdoDateFormatter.shared.date(fromISO: day) else { return [] }
        let dayStart = calendar.startOfDay(for: start)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        // 只查这一天的窗口,范围最小化(不读取整天以外的任何日程)。
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        // iOS 17+ 提供异步版本,避免同步查询阻塞主线程;失败时回退示例数据。
        let matched: [EKEvent]
        do {
            matched = try await store.events(matching: predicate)
        } catch {
            return await fallback.events(on: day)
        }
        guard !matched.isEmpty else { return await fallback.events(on: day) }

        return matched
            .map { event in
                OrdoCalendarEvent(
                    id: event.eventIdentifier ?? event.calendarItemIdentifier,
                    title: event.title ?? "(无标题)",
                    start: event.startDate,
                    end: event.endDate,
                    // 契约 §2.8 的 `calendar` 是展示名;未知日历回落到「日历」而不是空串。
                    calendar: event.calendar?.title ?? "日历",
                    allDay: event.isAllDay
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// 实时权限状态(设置页展示用,不触发授权面板)。
    public func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }
}

// MARK: - 示例数据源(无权限 / 无日程时的静默回退)

/// 固定示例日程(契约 §2.8:仅用于展示,不来自任何真实日历,不上传)。
public struct OrdoSampleAgendaProvider: OrdoAgendaProviding {

    private let today: @Sendable () -> String

    public init(today: @escaping @Sendable () -> String = { OrdoDateFormatter.shared.today() }) {
        self.today = today
    }

    public func currentAuthorization() async -> Bool { true }

    public func requestAuthorization() async -> Bool { true }

    public func events(on day: String) async -> [OrdoCalendarEvent] {
        let resolved = day.isEmpty ? today() : day
        return OrdoSeedData.calendarEvents(today: resolved)
    }

    public func eventsWithSource(on day: String) async -> (events: [OrdoCalendarEvent], source: OrdoAgendaSource) {
        (await events(on: day), .sample)
    }
}

/// 空数据源(预览「今天没有任何日程」的状态)。
public struct OrdoEmptyAgendaProvider: OrdoAgendaProviding {
    public init() {}
    public func currentAuthorization() async -> Bool { false }
    public func requestAuthorization() async -> Bool { false }
    public func events(on day: String) async -> [OrdoCalendarEvent] { [] }
    public func eventsWithSource(on day: String) async -> (events: [OrdoCalendarEvent], source: OrdoAgendaSource) {
        ([], .sample)
    }
}

// MARK: - 组合:EventKit →(回退)→ 示例

/// `AppEnvironment` 默认使用的日程数据源。
///
/// 行为:
/// 1. 冷启动先问 EventKit 是否有权限;未决定时弹一次系统授权面板;
/// 2. 有权限就返回当天的真实日程;无权限**不报错、不提示**,直接回退示例数据;
/// 3. 有权限但当天确实没有日程时,同样回退示例数据,保证区块不空。
public struct OrdoEnvironmentAgendaProvider: OrdoAgendaProviding {

    private let primary: OrdoAgendaProviding
    private let fallback: OrdoAgendaProviding

    public init(
        primary: OrdoAgendaProviding = OrdoEventKitAgendaProvider(),
        fallback: OrdoAgendaProviding = OrdoSampleAgendaProvider()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func currentAuthorization() async -> Bool {
        await primary.currentAuthorization()
    }

    public func requestAuthorization() async -> Bool {
        await primary.requestAuthorization()
    }

    /// 返回日程与来源:命中真实日历才是 `.calendar`,否则是示例回退(UI 据此展示「示例」标记)。
    public func eventsWithSource(on day: String) async -> (events: [OrdoCalendarEvent], source: OrdoAgendaSource) {
        let granted = await primary.currentAuthorization() ? true : await primary.requestAuthorization()
        guard granted else { return (await fallback.events(on: day), .sample) }
        let live = await primary.events(on: day)
        if live.isEmpty { return (await fallback.events(on: day), .sample) }
        return (live, .calendar)
    }

    public func events(on day: String) async -> [OrdoCalendarEvent] {
        await eventsWithSource(on: day).events
    }
}
