//
//  OrdoModel.swift
//  Ordo
//
//  契约 §2「规范数据模型」的 Swift 值类型镜像。
//
//  设计说明:
//  - KMP `shared/core` 导出的 Kotlin 对象是 Objective-C 引用类型,不适合直接驱动 SwiftUI 的差异比较,
//    因此 `OrdoCoreBridge` 会把 Kotlin 模型映射为本文件的 `Sendable` 值类型。
//  - **字段名与契约 §2 完全一致**(id/name/note/when/date/reminder/deadline/tags/checklist/…),
//    保证 SwiftData 实体、JSON 传输格式、四端本地库三者的字段名一一对应。
//  - 全部类型为值类型且 `Sendable`,可安全跨 actor 传递。
//

import Foundation

// MARK: - 枚举(契约 §2 顶部)

/// 待办的「开始」语义,决定它出现在哪个派生清单。
public enum OrdoWhen: String, Codable, CaseIterable, Sendable {
    case inbox
    case today
    case evening
    case anytime
    case someday
    case date

    /// 契约 §3:`when ∈ {inbox, today, evening, anytime, someday}` 时 `date` 必须为 null。
    public var requiresDate: Bool { self == .date }
}

public enum OrdoStatus: String, Codable, CaseIterable, Sendable {
    case open
    case done
    case canceled

    /// 契约 §4:`open(t) = t.status == "open"`。
    public var isOpen: Bool { self == .open }
    /// 是否已进入日志簿。
    public var isClosed: Bool { self != .open }
}

public enum OrdoRepeatFreq: String, Codable, CaseIterable, Sendable {
    case daily
    case weekly
    case monthly
    case yearly
}

public enum OrdoRepeatMode: String, Codable, CaseIterable, Sendable {
    /// 基于原 date 递推(每周一永远是周一)。
    case fixed
    /// 基于实际完成日递推。
    case afterCompletion
}

public enum OrdoEntityKind: String, Codable, CaseIterable, Sendable {
    case todo
    case project
    case area
    case heading
    case tag
}

// MARK: - 值类型

/// 契约 §2.7
public struct OrdoRepeatRule: Codable, Hashable, Sendable {
    public var freq: OrdoRepeatFreq
    public var interval: Int
    public var mode: OrdoRepeatMode

    public init(freq: OrdoRepeatFreq, interval: Int = 1, mode: OrdoRepeatMode = .fixed) {
        self.freq = freq
        self.interval = max(1, interval)
        self.mode = mode
    }
}

/// 契约 §2.5 —— 内嵌于 Todo,不单独同步。
public struct OrdoChecklistItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var done: Bool

    public init(id: String, title: String, done: Bool = false) {
        self.id = id
        self.title = title
        self.done = done
    }
}

/// 契约 §2.1
public struct OrdoArea: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var color: String
    public var order: Int
    public var archived: Bool
    public var updatedAt: Int64
    public var deleted: Bool

    public init(
        id: String,
        name: String,
        color: String = OrdoPalette.defaultAreaColor,
        order: Int = 0,
        archived: Bool = false,
        updatedAt: Int64 = 0,
        deleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.order = order
        self.archived = archived
        self.updatedAt = updatedAt
        self.deleted = deleted
    }
}

/// 契约 §2.3
public struct OrdoHeading: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var projectId: String
    public var name: String
    public var order: Int
    public var archived: Bool
    /// 设备本地 UI 状态,不参与同步(推送时置 nil)。
    public var collapsed: Bool?

    public init(
        id: String,
        projectId: String,
        name: String,
        order: Int = 0,
        archived: Bool = false,
        collapsed: Bool? = false
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.order = order
        self.archived = archived
        self.collapsed = collapsed
    }
}

/// 契约 §2.2
public struct OrdoProject: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var areaId: String?
    public var name: String
    public var note: String
    public var when: OrdoWhen
    public var date: String?
    public var deadline: String?
    public var tags: [String]
    public var headings: [OrdoHeading]
    public var order: Int
    public var status: OrdoStatus
    public var completedAt: Int64?
    public var repeatRule: OrdoRepeatRule?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deleted: Bool

    public init(
        id: String,
        areaId: String? = nil,
        name: String,
        note: String = "",
        when: OrdoWhen = .anytime,
        date: String? = nil,
        deadline: String? = nil,
        tags: [String] = [],
        headings: [OrdoHeading] = [],
        order: Int = 0,
        status: OrdoStatus = .open,
        completedAt: Int64? = nil,
        repeatRule: OrdoRepeatRule? = nil,
        createdAt: Int64 = 0,
        updatedAt: Int64 = 0,
        deleted: Bool = false
    ) {
        self.id = id
        self.areaId = areaId
        self.name = name
        self.note = note
        self.when = when
        self.date = date
        self.deadline = deadline
        self.tags = tags
        self.headings = headings
        self.order = order
        self.status = status
        self.completedAt = completedAt
        self.repeatRule = repeatRule
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    private enum CodingKeys: String, CodingKey {
        case id, areaId, name, note, when, date, deadline, tags, headings, order
        case status, completedAt, createdAt, updatedAt, deleted
        /// 契约字段名为 `repeat`;Swift 中 `repeat` 是关键字,故对外仍用 `repeat`,声明侧改名。
        case repeatRule = "repeat"
    }
}

/// 契约 §2.4
public struct OrdoTodo: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var note: String
    public var when: OrdoWhen
    public var date: String?
    public var reminder: String?
    public var deadline: String?
    public var tags: [String]
    public var checklist: [OrdoChecklistItem]
    public var projectId: String?
    public var areaId: String?
    public var headingId: String?
    public var order: Int
    public var status: OrdoStatus
    public var createdAt: Int64
    public var updatedAt: Int64
    public var completedAt: Int64?
    public var deleted: Bool

    /// 契约字段名为 `repeat`;`repeat` 在 Swift 中是关键字,因此属性名用 `repeatRule`,编码键仍为 `repeat`。
    public var repeatRule: OrdoRepeatRule?

    public init(
        id: String,
        title: String,
        note: String = "",
        when: OrdoWhen = .inbox,
        date: String? = nil,
        reminder: String? = nil,
        deadline: String? = nil,
        tags: [String] = [],
        checklist: [OrdoChecklistItem] = [],
        projectId: String? = nil,
        areaId: String? = nil,
        headingId: String? = nil,
        order: Int = 0,
        status: OrdoStatus = .open,
        createdAt: Int64 = 0,
        updatedAt: Int64 = 0,
        completedAt: Int64? = nil,
        deleted: Bool = false,
        repeatRule: OrdoRepeatRule? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.when = when
        self.date = date
        self.reminder = reminder
        self.deadline = deadline
        self.tags = tags
        self.checklist = checklist
        self.projectId = projectId
        self.areaId = areaId
        self.headingId = headingId
        self.order = order
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.deleted = deleted
        self.repeatRule = repeatRule
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, note, when, date, reminder, deadline, tags, checklist
        case projectId, areaId, headingId, order, status, createdAt, updatedAt, completedAt, deleted
        case repeatRule = "repeat"
    }

    // MARK: 展示与统计辅助(纯计算,不改变业务规则)

    /// 清单进度,例如 `2/5`;无清单项时返回 nil。
    public var checklistProgress: String? {
        guard !checklist.isEmpty else { return nil }
        let done = checklist.filter(\.done).count
        return "\(done)/\(checklist.count)"
    }

    public var isRepeating: Bool { repeatRule != nil }
}

/// 契约 §2.6
public struct OrdoTag: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var color: String
    public var updatedAt: Int64

    public init(id: String, name: String, color: String = OrdoPalette.defaultTagColor, updatedAt: Int64 = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.updatedAt = updatedAt
    }
}

/// 契约 §2.8 —— 只读、设备本地、不参与同步。
public struct OrdoCalendarEvent: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var calendar: String
    public var allDay: Bool

    public init(id: String, title: String, start: Date, end: Date, calendar: String, allDay: Bool = false) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.calendar = calendar
        self.allDay = allDay
    }
}

// MARK: - 快照 / Op / 查询

/// 引擎对外暴露的完整状态(KMP `OrdoSnapshot` 的 Swift 镜像)。
///
/// 注意:Kotlin `OrdoSnapshot` 的 headings 是**扁平列表**,本项目在 Swift 侧按契约 §2.2
/// 回填到各自的项目(`OrdoProject.headings`),并提供 `headings(of:)` 查询。
public struct OrdoSnapshot: Hashable, Sendable {
    /// 契约 §8 的 schemaVersion。
    public var schemaVersion: Int
    /// 已应用的服务端序号(契约 §7.1)。
    public var serverSeq: Int64
    public var areas: [OrdoArea]
    public var projects: [OrdoProject]
    public var todos: [OrdoTodo]
    public var tags: [OrdoTag]

    public init(
        schemaVersion: Int = OrdoSchema.version,
        serverSeq: Int64 = 0,
        areas: [OrdoArea] = [],
        projects: [OrdoProject] = [],
        todos: [OrdoTodo] = [],
        tags: [OrdoTag] = []
    ) {
        self.schemaVersion = schemaVersion
        self.serverSeq = serverSeq
        self.areas = areas
        self.projects = projects
        self.todos = todos
        self.tags = tags
    }

    public static let empty = OrdoSnapshot()

    /// 扁平后的标题列表(项目内嵌 headings 的合集)。
    public var headings: [OrdoHeading] { projects.flatMap(\.headings) }

    public func headings(of projectId: String) -> [OrdoHeading] {
        (projects.first { $0.id == projectId }?.headings ?? []).sorted { $0.order < $1.order }
    }

    public func project(id: String?) -> OrdoProject? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    public func todo(id: String?) -> OrdoTodo? {
        guard let id else { return nil }
        return todos.first { $0.id == id }
    }

    public func area(id: String?) -> OrdoArea? {
        guard let id else { return nil }
        return areas.first { $0.id == id }
    }

    public func heading(id: String?) -> OrdoHeading? {
        guard let id else { return nil }
        return headings.first { $0.id == id }
    }

    public var tagNames: [String] { tags.map(\.name) }
}

public enum OrdoOpType: String, Codable, Sendable {
    case upsert
    case delete
}

/// 契约 §7.2
public struct OrdoOp: Identifiable, Codable, Hashable, Sendable {
    public var opId: String
    public var deviceId: String
    public var entity: OrdoEntityKind
    public var entityId: String
    public var type: OrdoOpType
    /// 实体完整快照的 JSON;`type == .delete` 时为 nil。
    public var payload: OrdoJSONValue?
    public var clientTs: Int64
    public var seq: Int64?

    public var id: String { opId }

    public init(
        opId: String,
        deviceId: String,
        entity: OrdoEntityKind,
        entityId: String,
        type: OrdoOpType,
        payload: OrdoJSONValue? = nil,
        clientTs: Int64,
        seq: Int64? = nil
    ) {
        self.opId = opId
        self.deviceId = deviceId
        self.entity = entity
        self.entityId = entityId
        self.type = type
        self.payload = payload
        self.clientTs = clientTs
        self.seq = seq
    }
}

/// 契约 §7.3.5 墓碑
public struct OrdoTombstone: Codable, Hashable, Sendable {
    public var entity: OrdoEntityKind
    public var entityId: String
    public var deletedAt: Int64
    public var clientTs: Int64

    public init(entity: OrdoEntityKind, entityId: String, deletedAt: Int64, clientTs: Int64) {
        self.entity = entity
        self.entityId = entityId
        self.deletedAt = deletedAt
        self.clientTs = clientTs
    }
}

/// 派生清单的种类(契约 §4)。
public enum OrdoListKind: String, Codable, CaseIterable, Sendable {
    case inbox
    case today
    case upcoming
    case anytime
    case someday
    case logbook
    case project
    case area
    case tag
    case search

    /// 侧栏固定清单的展示顺序与标题(通用词,非任何第三方品牌用词)。
    public static let pinnedOrder: [OrdoListKind] = [.inbox, .today, .upcoming, .anytime, .someday, .logbook]

    public var displayName: String {
        switch self {
        case .inbox: return "收件箱"
        case .today: return "今天"
        case .upcoming: return "计划"
        case .anytime: return "随时"
        case .someday: return "某天"
        case .logbook: return "日志簿"
        case .project: return "项目"
        case .area: return "区域"
        case .tag: return "标签"
        case .search: return "搜索"
        }
    }

    public var systemImage: String {
        switch self {
        case .inbox: return "tray"
        case .today: return "star"
        case .upcoming: return "calendar"
        case .anytime: return "square.stack.3d.up"
        case .someday: return "archivebox"
        case .logbook: return "book.closed"
        case .project: return "circle.dashed"
        case .area: return "square.grid.2x2"
        case .tag: return "tag"
        case .search: return "magnifyingglass"
        }
    }
}

/// 一个派生清单的查询描述。
public struct OrdoListQuery: Hashable, Sendable, Identifiable {
    public var kind: OrdoListKind
    /// project / area 的 id,或 tag 名称。
    public var id: String?
    /// 搜索关键字(kind == .search 时使用)。
    public var text: String?
    /// 标签视图的「只看未完成」开关。
    public var showCompleted: Bool

    public init(kind: OrdoListKind, id: String? = nil, text: String? = nil, showCompleted: Bool = false) {
        self.kind = kind
        self.id = id
        self.text = text
        self.showCompleted = showCompleted
    }

    public static let inbox = OrdoListQuery(kind: .inbox)
    public static let today = OrdoListQuery(kind: .today)
    public static let upcoming = OrdoListQuery(kind: .upcoming)
    public static let anytime = OrdoListQuery(kind: .anytime)
    public static let someday = OrdoListQuery(kind: .someday)
    public static let logbook = OrdoListQuery(kind: .logbook)

    public static func project(_ id: String) -> OrdoListQuery { OrdoListQuery(kind: .project, id: id) }
    public static func area(_ id: String) -> OrdoListQuery { OrdoListQuery(kind: .area, id: id) }
    public static func tag(_ name: String, showCompleted: Bool = false) -> OrdoListQuery {
        OrdoListQuery(kind: .tag, id: name, showCompleted: showCompleted)
    }
    public static func search(_ text: String) -> OrdoListQuery { OrdoListQuery(kind: .search, text: text) }

    public var stableIdentifier: String {
        switch kind {
        case .project, .area, .tag: return "\(kind.rawValue):\(id ?? "")"
        case .search: return "search:\(text ?? "")"
        default: return kind.rawValue
        }
    }
}

public enum OrdoSectionKind: String, Codable, Sendable {
    /// 普通分组(随时/某天/标签)
    case plain
    /// 今天的主列表(Kotlin `SectionKind.PLAIN_TODAY`)
    case plainToday
    /// iOS 本地的只读日程区块(契约 §2.8;Kotlin 核心不产出该分区)
    case agenda
    /// 今晚分区(琥珀色)
    case tonight
    /// 计划中的某一天
    case day
    /// 计划窗口之外的「更晚」
    case later
    /// 项目内的标题(Heading)
    case heading
    /// 日志簿按完成日期的分组
    case completedDay
}

/// 契约 §4:列表分区。分区标题与副标题只做展示,排序由 KMP 核心给出。
public struct OrdoListSection: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: OrdoSectionKind
    public var title: String
    public var subtitle: String?
    public var todos: [OrdoTodo]
    /// 计划视图里该分区对应的日期(用于「今天 · 周三」这类标题渲染)。
    public var date: String?
    public var collapsed: Bool

    public init(
        id: String,
        kind: OrdoSectionKind,
        title: String,
        subtitle: String? = nil,
        todos: [OrdoTodo] = [],
        date: String? = nil,
        collapsed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.todos = todos
        self.date = date
        self.collapsed = collapsed
    }
}

/// 侧栏计数(KMP `SidebarCounts` 的 Swift 镜像)。
///
/// Kotlin 定义:
/// ```kotlin
/// data class SidebarCounts(
///     val inbox: Int = 0, val today: Int = 0, val upcoming: Int = 0,
///     val anytime: Int = 0, val someday: Int = 0, val logbook: Int = 0,
///     val projects: Map<String, Int> = emptyMap(),
///     val projectProgress: Map<String, Float> = emptyMap(),
///     val tags: Map<String, Int> = emptyMap()
/// )
/// ```
/// 注意:**没有区域(area)计数** —— 侧栏区域行不再显示数字,避免在 Swift 侧重复实现查询规则。
public struct OrdoSidebarCounts: Hashable, Sendable {
    public var inbox: Int
    public var today: Int
    public var upcoming: Int
    public var anytime: Int
    public var someday: Int
    public var logbook: Int
    /// 项目 → 未完成数。
    public var projects: [String: Int]
    /// 项目 → 完成度 0…1(来自核心 `projectProgress`)。
    public var projectProgress: [String: Double]
    public var tags: [String: Int]

    public init(
        inbox: Int = 0,
        today: Int = 0,
        upcoming: Int = 0,
        anytime: Int = 0,
        someday: Int = 0,
        logbook: Int = 0,
        projects: [String: Int] = [:],
        projectProgress: [String: Double] = [:],
        tags: [String: Int] = [:]
    ) {
        self.inbox = inbox
        self.today = today
        self.upcoming = upcoming
        self.anytime = anytime
        self.someday = someday
        self.logbook = logbook
        self.projects = projects
        self.projectProgress = projectProgress
        self.tags = tags
    }

    public static let zero = OrdoSidebarCounts()

    public func count(for kind: OrdoListKind) -> Int {
        switch kind {
        case .inbox: return inbox
        case .today: return today
        case .upcoming: return upcoming
        case .anytime: return anytime
        case .someday: return someday
        case .logbook: return logbook
        case .project, .area, .tag, .search: return 0
        }
    }

    public func projectCount(_ id: String) -> Int { projects[id] ?? 0 }
    public func progress(_ id: String) -> Double { projectProgress[id] ?? 0 }
    public func tagCount(_ name: String) -> Int { tags[name] ?? 0 }
}

/// 项目进度环用:已完成 / 未完成 / 完成度(契约 §4 末行)。
///
/// `coreFraction` 来自 KMP 核心的 `projectProgress(projectId:)`;
/// 它存在时优先使用(避免 Swift 侧重算业务口径),缺失时按 `done/(done+open)` 兜底。
public struct OrdoProgress: Hashable, Sendable {
    public var done: Int
    public var open: Int
    public var coreFraction: Double?

    public init(done: Int, open: Int, coreFraction: Double? = nil) {
        self.done = done
        self.open = open
        self.coreFraction = coreFraction
    }

    public var total: Int { done + open }

    /// 无子项时为 0。
    public var fraction: Double {
        if let coreFraction { return min(max(coreFraction, 0), 1) }
        return total == 0 ? 0 : Double(done) / Double(total)
    }

    public var isComplete: Bool {
        if let coreFraction { return coreFraction >= 1 }
        return total > 0 && open == 0
    }
}

/// 品牌色板中与模型相关的默认值(完整设计令牌见 DesignSystem/OrdoColor.swift)。
public enum OrdoPalette {
    public static let defaultAreaColor = "#5B5BD6"
    public static let defaultTagColor = "#7A776F"
}
