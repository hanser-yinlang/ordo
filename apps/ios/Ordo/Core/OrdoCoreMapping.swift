//
//  OrdoCoreMapping.swift
//  Ordo
//
//  Kotlin(shared/core)⇄ Swift 值类型的映射。全部函数为 `nonisolated static`,
//  可从任意执行器调用。**字段清单已与真实 Kotlin data class 核对。**
//
//  ┌──────────────────────────── 真实 Kotlin 定义 ────────────────────────────┐
//  │ data class Area(id, name, color: String?=null, order: Int, archived,     │
//  │                 updatedAt: Long, deleted)                                │
//  │ data class Heading(id, projectId, name, order, archived, collapsed: Bool,│
//  │                    updatedAt, deleted)                                   │
//  │ data class Project(id, name, areaId?, note, when, date?, deadline?,      │
//  │                    tags, order, status, completedAt?, repeat?, createdAt,│
//  │                    updatedAt, deleted)   ← 无 headings 字段              │
//  │ data class Todo(id, title, note, when, date?, reminder?, deadline?, tags,│
//  │                 checklist, projectId?, areaId?, headingId?, repeat?,     │
//  │                 order, status, createdAt, updatedAt, completedAt?, deleted)│
//  │ data class Tag(id, name, color, updatedAt, deleted)                      │
//  │ data class ChecklistItem(id, title, done)                                │
//  │ data class RepeatRule(freq, interval, mode)                              │
//  │ data class OrdoSnapshot(schemaVersion, serverSeq, areas, projects,       │
//  │                         headings(扁平), todos, tags)                    │
//  │ sealed class ListQuery: Inbox/Today/Upcoming/Anytime/Someday/Logbook     │
//  │                         ProjectScope(id)/AreaScope(id)                   │
//  │                         TagScope(name, includeCompleted)/Search(text)    │
//  │ data class ListSection(title, subtitle?, kind, todos, headingId?)        │
//  │ data class SidebarCounts(inbox…logbook, projects, projectProgress, tags) │
//  │ data class NlpResult(cleanTitle, when?, date?, reminder?, tags)          │
//  │ object OpCodec(encode/decodeOps · encode/decodeSnapshot · tombstones)    │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  说明:Kotlin data class 的默认参数**不会**导出到 Swift,因此构造 Kotlin 对象时
//  必须传满所有参数(顺序与声明一致)。枚举统一走 `companion.fromWire(...)` / `.wire`,
//  不依赖 ObjC 枚举导出名。
//

import Foundation
import OrdoCore

extension OrdoCoreMapping {

    // MARK: - 枚举

    nonisolated static func map(when value: OrdoWhen) -> When {
        When.companion.fromWire(value: value.rawValue)
    }

    nonisolated static func map(when value: When?) -> OrdoWhen? {
        guard let value else { return nil }
        return OrdoWhen(rawValue: value.wire)
    }

    nonisolated static func map(status value: OrdoStatus) -> Status {
        Status.companion.fromWire(value: value.rawValue)
    }

    nonisolated static func map(status value: Status) -> OrdoStatus {
        OrdoStatus(rawValue: value.wire) ?? .open
    }

    nonisolated static func map(freq value: OrdoRepeatFreq) -> RepeatFreq {
        RepeatFreq.companion.fromWire(value: value.rawValue)
    }

    nonisolated static func map(freq value: RepeatFreq) -> OrdoRepeatFreq {
        OrdoRepeatFreq(rawValue: value.wire) ?? .daily
    }

    nonisolated static func map(mode value: OrdoRepeatMode) -> RepeatMode {
        RepeatMode.companion.fromWire(value: value.rawValue)
    }

    nonisolated static func map(mode value: RepeatMode) -> OrdoRepeatMode {
        OrdoRepeatMode(rawValue: value.wire) ?? .fixed
    }

    /// Kotlin `SectionKind` 的枚举取值(SCREAMING_SNAKE)显式映射。
    /// Kotlin 侧只有 PLAIN / PLAIN_TODAY / TONIGHT / DAY / HEADING / LATER / COMPLETION_DAY
    /// (`.agenda` 是 iOS 本地的只读日程区块,由 Swift 自行合成)。
    nonisolated static func map(sectionKind value: SectionKind) -> OrdoSectionKind {
        switch value.name {
        case "TONIGHT": return .tonight
        case "DAY": return .day
        case "LATER": return .later
        case "HEADING": return .heading
        case "COMPLETION_DAY": return .completedDay
        case "PLAIN_TODAY": return .plainToday
        default: return .plain
        }
    }

    // MARK: - 叶子类型

    nonisolated static func map(checklistItem value: ChecklistItem) -> OrdoChecklistItem {
        OrdoChecklistItem(id: value.id, title: value.title, done: value.done)
    }

    nonisolated static func map(checklistItem value: OrdoChecklistItem) -> ChecklistItem {
        ChecklistItem(id: value.id, title: value.title, done: value.done)
    }

    nonisolated static func map(repeatRule value: RepeatRule) -> OrdoRepeatRule {
        OrdoRepeatRule(
            freq: map(freq: value.freq),
            interval: Int(value.interval),
            mode: map(mode: value.mode)
        )
    }

    nonisolated static func map(repeatRule value: OrdoRepeatRule) -> RepeatRule {
        RepeatRule(
            freq: map(freq: value.freq),
            interval: Int32(value.interval),
            mode: map(mode: value.mode)
        )
    }

    // MARK: - 实体:Kotlin → Swift

    nonisolated static func map(area value: Area) -> OrdoArea {
        OrdoArea(
            id: value.id,
            name: value.name,
            // Kotlin 侧 color 可空,Swift 模型按契约 §2.1 用非空字符串
            color: value.color ?? OrdoPalette.defaultAreaColor,
            order: Int(value.order),
            archived: value.archived,
            updatedAt: value.updatedAt,
            deleted: value.deleted
        )
    }

    nonisolated static func map(heading value: Heading) -> OrdoHeading {
        OrdoHeading(
            id: value.id,
            projectId: value.projectId,
            name: value.name,
            order: Int(value.order),
            archived: value.archived,
            collapsed: value.collapsed
        )
    }

    /// 注意:Kotlin `Project` **不含 headings**;headings 由快照的扁平列表换算,
    /// 因此这里必须显式传入(`OrdoProject.headings` 是 Swift 侧的嵌套表达,对齐契约 §2.2 的 JSON 形状)。
    nonisolated static func map(project value: Project, headings: [OrdoHeading]) -> OrdoProject {
        OrdoProject(
            id: value.id,
            areaId: value.areaId,
            name: value.name,
            note: value.note,
            when: map(when: value.`when`) ?? .anytime,
            date: value.date,
            deadline: value.deadline,
            tags: value.tags,
            headings: headings.sorted { $0.order < $1.order },
            order: Int(value.order),
            status: map(status: value.status),
            completedAt: value.completedAt?.int64Value,
            repeatRule: value.`repeat`.map(map(repeatRule:)),
            createdAt: value.createdAt,
            updatedAt: value.updatedAt,
            deleted: value.deleted
        )
    }

    nonisolated static func map(todo value: Todo) -> OrdoTodo {
        OrdoTodo(
            id: value.id,
            title: value.title,
            note: value.note,
            when: map(when: value.`when`) ?? .inbox,
            date: value.date,
            reminder: value.reminder,
            deadline: value.deadline,
            tags: value.tags,
            checklist: value.checklist.map(map(checklistItem:)),
            projectId: value.projectId,
            areaId: value.areaId,
            headingId: value.headingId,
            order: Int(value.order),
            status: map(status: value.status),
            createdAt: value.createdAt,
            updatedAt: value.updatedAt,
            completedAt: value.completedAt?.int64Value,
            deleted: value.deleted,
            repeatRule: value.`repeat`.map(map(repeatRule:))
        )
    }

    nonisolated static func map(tag value: Tag) -> OrdoTag {
        OrdoTag(id: value.id, name: value.name, color: value.color, updatedAt: value.updatedAt)
    }

    nonisolated static func map(todos values: [Todo]) -> [OrdoTodo] {
        values.map(map(todo:))
    }

    // MARK: - 实体:Swift → Kotlin(用于 updateTodo 与 TodoOptions)

    nonisolated static func map(todo value: OrdoTodo) -> Todo {
        Todo(
            id: value.id,
            title: value.title,
            note: value.note,
            when: map(when: value.when),
            date: value.date,
            reminder: value.reminder,
            deadline: value.deadline,
            tags: value.tags,
            checklist: value.checklist.map(map(checklistItem:)),
            projectId: value.projectId,
            areaId: value.areaId,
            headingId: value.headingId,
            `repeat`: value.repeatRule.map(map(repeatRule:)),
            order: Int32(value.order),
            status: map(status: value.status),
            createdAt: value.createdAt,
            updatedAt: value.updatedAt,
            completedAt: value.completedAt.map { KotlinLong(long: $0) },
            deleted: value.deleted
        )
    }

    nonisolated static func map(options value: OrdoTodoOptions) -> TodoOptions {
        TodoOptions(
            when: value.when.map(map(when:)),
            date: value.date,
            projectId: value.projectId,
            areaId: value.areaId,
            headingId: value.headingId,
            tags: value.tags,
            note: value.note,
            insertAtTop: value.insertAtTop
        )
    }

    /// Swift → Kotlin(用于 `updateProject(id, mutate:)` 的回写)。
    /// 注意 Kotlin `Project` 没有 headings 字段,因此嵌套的 headings 不在这里传递
    /// (标题的增删改走 `createHeading` / `updateHeading` / `deleteHeading` / `archiveHeading`)。
    nonisolated static func map(project value: OrdoProject) -> Project {
        Project(
            id: value.id,
            name: value.name,
            areaId: value.areaId,
            note: value.note,
            `when`: map(when: value.when),
            date: value.date,
            deadline: value.deadline,
            tags: value.tags,
            order: Int32(value.order),
            status: map(status: value.status),
            completedAt: value.completedAt.map { KotlinLong(long: $0) },
            `repeat`: value.repeatRule.map(map(repeatRule:)),
            createdAt: value.createdAt,
            updatedAt: value.updatedAt,
            deleted: value.deleted
        )
    }

    /// Swift → Kotlin(用于 `updateHeading(id, mutate:)` 的回写)。
    nonisolated static func map(heading value: OrdoHeading) -> Heading {
        Heading(
            id: value.id,
            projectId: value.projectId,
            name: value.name,
            order: Int32(value.order),
            archived: value.archived,
            collapsed: value.collapsed ?? false
        )
    }

    nonisolated static func map(headings values: [OrdoHeading]) -> [OrdoHeading] { values }

    // MARK: - 快照
    /// Kotlin 快照是**扁平 headings**;这里回填到各自的项目,得到契约 §2.2 的嵌套形状。
    nonisolated static func map(snapshot value: OrdoSnapshot) -> OrdoSnapshot {
        let flatHeadings = value.headings.map(map(heading:))
        let grouped = Dictionary(grouping: flatHeadings, by: \.projectId)
        let projects = value.projects.map { project in
            map(project: project, headings: grouped[project.id] ?? [])
        }
        return OrdoSnapshot(
            areas: value.areas.map(map(area:)).sorted { $0.order < $1.order },
            projects: projects.sorted { $0.order < $1.order },
            todos: value.todos.map(map(todo:)).sorted { $0.order < $1.order },
            tags: value.tags.map(map(tag:)).sorted { $0.name < $1.name }
        )
    }

    /// Swift 嵌套结构 → 契约 §7.4 / Kotlin `OrdoSnapshot` 的扁平 JSON。
    nonisolated static func encodeSnapshot(_ snapshot: OrdoSnapshot) -> String {
        let dto = OrdoRemoteSnapshot(snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(dto), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// JSON 文本 → DTO(用于写回 SwiftData:`dto.merged()` 即得 Swift 快照)。
    nonisolated static func decodeSnapshotDTO(json: String) -> OrdoRemoteSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OrdoRemoteSnapshot.self, from: data)
    }

    // MARK: - 查询 / 分区 / 计数

    /// Swift 的 (kind, id, text, showCompleted) → Kotlin 的 sealed class 实例。
    nonisolated static func map(query value: OrdoListQuery) -> OrdoCore.ListQuery {
        switch value.kind {
        case .inbox: return OrdoCore.ListQuery.Inbox.shared
        case .today: return OrdoCore.ListQuery.Today.shared
        case .upcoming: return OrdoCore.ListQuery.Upcoming.shared
        case .anytime: return OrdoCore.ListQuery.Anytime.shared
        case .someday: return OrdoCore.ListQuery.Someday.shared
        case .logbook: return OrdoCore.ListQuery.Logbook.shared
        case .project: return OrdoCore.ListQuery.ProjectScope(id: value.id ?? "")
        case .area: return OrdoCore.ListQuery.AreaScope(id: value.id ?? "")
        case .tag: return OrdoCore.ListQuery.TagScope(name: value.id ?? "", includeCompleted: value.showCompleted)
        case .search: return OrdoCore.ListQuery.Search(text: value.text ?? "")
        }
    }

    /// Kotlin `ListSection` 没有 id/date/collapsed,这里合成稳定 id:
    /// 优先用 headingId(项目内标题分组),否则用 kind + title。
    nonisolated static func map(sections values: [ListSection]) -> [OrdoListSection] {
        values.map { section in
            let kind = map(sectionKind: section.kind)
            let identifier: String
            if let headingId = section.headingId {
                identifier = "heading:\(headingId)"
            } else {
                identifier = "\(kind.rawValue):\(section.title)"
            }
            // subtitle 在 Kotlin 侧承载的是「条目数」字符串;日期分组可从首个待办推导。
            let date = section.todos.first.flatMap { todo -> String? in
                todo.`when` == When.DATE ? todo.date : nil
            }
            return OrdoListSection(
                id: identifier,
                kind: kind,
                title: section.title,
                subtitle: section.subtitle,
                todos: section.todos.map(map(todo:)),
                date: date,
                collapsed: false
            )
        }
    }

    nonisolated static func map(counts value: SidebarCounts) -> OrdoSidebarCounts {
        var progress: [String: Double] = [:]
        for (key, item) in value.projectProgress {
            progress[key] = Double(item.floatValue)
        }
        var projects: [String: Int] = [:]
        for (key, item) in value.projects {
            projects[key] = Int(item.int32Value)
        }
        var tags: [String: Int] = [:]
        for (key, item) in value.tags {
            tags[key] = Int(item.int32Value)
        }
        return OrdoSidebarCounts(
            inbox: Int(value.inbox),
            today: Int(value.today),
            upcoming: Int(value.upcoming),
            anytime: Int(value.anytime),
            someday: Int(value.someday),
            logbook: Int(value.logbook),
            projects: projects,
            projectProgress: progress,
            tags: tags
        )
    }

    // MARK: - Op / Tombstone(JSON 文本通道)

    /// 引擎产出的 op → Swift 值类型。
    nonisolated static func decodeOps(json: String) -> [OrdoOp] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([OrdoOp].self, from: data)) ?? []
    }

    nonisolated static func encodeOps(_ ops: [OrdoOp]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ops), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    nonisolated static func encodeTombstones(_ list: [OrdoTombstone]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(list), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    nonisolated static func decodeTombstones(json: String) -> [OrdoTombstone] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([OrdoTombstone].self, from: data)) ?? []
    }
}

/// 命名空间占位:所有映射函数都在 `extension OrdoCoreMapping` 中实现,
/// 这样调用点写作 `OrdoCoreMapping.map(todo:)`,且全部是 `nonisolated static`(可从任意执行器调用)。
public enum OrdoCoreMapping {}
