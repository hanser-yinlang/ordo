//
//  SwiftDataStorage.swift
//  Ordo
//
//  契约 §8「客户端存储」的 iOS 实现(SwiftData)。
//
//  · 实体表字段名与契约 §2 完全一致(id/title/note/when/date/reminder/deadline/tags/
//    checklist/projectId/areaId/headingId/repeat/order/status/createdAt/updatedAt/
//    completedAt/deleted 等)。`repeat` 是 Swift 关键字,故用反引号声明,列名仍为 `repeat`。
//  · 另有本地表:outbox(opId PK, payload, createdAt)、tombstones(entity, entityId,
//    deletedAt, clientTs)、kv(key, value)。
//  · 采用 `@ModelActor`:所有读写在自己的执行器上串行执行,天然满足 Swift 6 并发要求;
//    对外以 async 方法暴露,与契约 §8 的「本地优先」一致(UI 不等待落盘)。
//
//  ⚠️ 部署目标:SwiftData 需要 iOS 17+,而 §7 平台映射表写的是「iOS 16+」。
//     本工程取 iOS 17.0(见 README「已知偏差」);如需支持 16,
//     只需替换本文件为 JSON/SQLite 仓储,协议层 `OrdoStorageProtocol` 无需改动。
//

import Foundation
import SwiftData

// MARK: - SwiftData 实体

@Model
final class SDTodo {
    @Attribute(.unique) var id: String
    var title: String
    var note: String
    /// 契约字段 `when`,存 OrdoWhen.rawValue。
    var when: String
    var date: String?
    var reminder: String?
    var deadline: String?
    var tags: [String]
    var checklist: [OrdoChecklistItem]
    var projectId: String?
    var areaId: String?
    var headingId: String?
    var order: Int
    /// 契约字段 `status`,存 OrdoStatus.rawValue。
    var status: String
    var createdAt: Int64
    var updatedAt: Int64
    var completedAt: Int64?
    var deleted: Bool
    /// 契约字段名为 `repeat`(Swift 关键字,用反引号)。
    var `repeat`: OrdoRepeatRule?

    init(
        id: String,
        title: String,
        note: String,
        when: String,
        date: String?,
        reminder: String?,
        deadline: String?,
        tags: [String],
        checklist: [OrdoChecklistItem],
        projectId: String?,
        areaId: String?,
        headingId: String?,
        order: Int,
        status: String,
        createdAt: Int64,
        updatedAt: Int64,
        completedAt: Int64?,
        deleted: Bool,
        repeatRule: OrdoRepeatRule?
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
        self.`repeat` = repeatRule
    }

    convenience init(_ todo: OrdoTodo) {
        self.init(
            id: todo.id,
            title: todo.title,
            note: todo.note,
            when: todo.when.rawValue,
            date: todo.date,
            reminder: todo.reminder,
            deadline: todo.deadline,
            tags: todo.tags,
            checklist: todo.checklist,
            projectId: todo.projectId,
            areaId: todo.areaId,
            headingId: todo.headingId,
            order: todo.order,
            status: todo.status.rawValue,
            createdAt: todo.createdAt,
            updatedAt: todo.updatedAt,
            completedAt: todo.completedAt,
            deleted: todo.deleted,
            repeatRule: todo.repeatRule
        )
    }

    func apply(_ todo: OrdoTodo) {
        title = todo.title
        note = todo.note
        when = todo.when.rawValue
        date = todo.date
        reminder = todo.reminder
        deadline = todo.deadline
        tags = todo.tags
        checklist = todo.checklist
        projectId = todo.projectId
        areaId = todo.areaId
        headingId = todo.headingId
        order = todo.order
        status = todo.status.rawValue
        createdAt = todo.createdAt
        updatedAt = todo.updatedAt
        completedAt = todo.completedAt
        deleted = todo.deleted
        `repeat` = todo.repeatRule
    }

    var value: OrdoTodo {
        OrdoTodo(
            id: id,
            title: title,
            note: note,
            when: OrdoWhen(rawValue: when) ?? .inbox,
            date: date,
            reminder: reminder,
            deadline: deadline,
            tags: tags,
            checklist: checklist,
            projectId: projectId,
            areaId: areaId,
            headingId: headingId,
            order: order,
            status: OrdoStatus(rawValue: status) ?? .open,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: completedAt,
            deleted: deleted,
            repeatRule: `repeat`
        )
    }
}

@Model
final class SDProject {
    @Attribute(.unique) var id: String
    var areaId: String?
    var name: String
    var note: String
    var when: String
    var date: String?
    var deadline: String?
    var tags: [String]
    var headings: [OrdoHeading]
    var order: Int
    var status: String
    var completedAt: Int64?
    var `repeat`: OrdoRepeatRule?
    var createdAt: Int64
    var updatedAt: Int64
    var deleted: Bool

    init(
        id: String,
        areaId: String?,
        name: String,
        note: String,
        when: String,
        date: String?,
        deadline: String?,
        tags: [String],
        headings: [OrdoHeading],
        order: Int,
        status: String,
        completedAt: Int64?,
        repeatRule: OrdoRepeatRule?,
        createdAt: Int64,
        updatedAt: Int64,
        deleted: Bool
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
        self.`repeat` = repeatRule
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    convenience init(_ project: OrdoProject) {
        self.init(
            id: project.id,
            areaId: project.areaId,
            name: project.name,
            note: project.note,
            when: project.when.rawValue,
            date: project.date,
            deadline: project.deadline,
            tags: project.tags,
            headings: project.headings,
            order: project.order,
            status: project.status.rawValue,
            completedAt: project.completedAt,
            repeatRule: project.repeatRule,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt,
            deleted: project.deleted
        )
    }

    func apply(_ project: OrdoProject) {
        areaId = project.areaId
        name = project.name
        note = project.note
        when = project.when.rawValue
        date = project.date
        deadline = project.deadline
        tags = project.tags
        headings = project.headings
        order = project.order
        status = project.status.rawValue
        completedAt = project.completedAt
        `repeat` = project.repeatRule
        createdAt = project.createdAt
        updatedAt = project.updatedAt
        deleted = project.deleted
    }

    var value: OrdoProject {
        OrdoProject(
            id: id,
            areaId: areaId,
            name: name,
            note: note,
            when: OrdoWhen(rawValue: when) ?? .anytime,
            date: date,
            deadline: deadline,
            tags: tags,
            headings: headings,
            order: order,
            status: OrdoStatus(rawValue: status) ?? .open,
            completedAt: completedAt,
            repeatRule: `repeat`,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deleted: deleted
        )
    }
}

@Model
final class SDArea {
    @Attribute(.unique) var id: String
    var name: String
    var color: String
    var order: Int
    var archived: Bool
    var updatedAt: Int64
    var deleted: Bool

    init(id: String, name: String, color: String, order: Int, archived: Bool, updatedAt: Int64, deleted: Bool) {
        self.id = id
        self.name = name
        self.color = color
        self.order = order
        self.archived = archived
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    convenience init(_ area: OrdoArea) {
        self.init(
            id: area.id,
            name: area.name,
            color: area.color,
            order: area.order,
            archived: area.archived,
            updatedAt: area.updatedAt,
            deleted: area.deleted
        )
    }

    func apply(_ area: OrdoArea) {
        name = area.name
        color = area.color
        order = area.order
        archived = area.archived
        updatedAt = area.updatedAt
        deleted = area.deleted
    }

    var value: OrdoArea {
        OrdoArea(
            id: id,
            name: name,
            color: color,
            order: order,
            archived: archived,
            updatedAt: updatedAt,
            deleted: deleted
        )
    }
}

@Model
final class SDTag {
    @Attribute(.unique) var id: String
    var name: String
    var color: String
    var updatedAt: Int64

    init(id: String, name: String, color: String, updatedAt: Int64) {
        self.id = id
        self.name = name
        self.color = color
        self.updatedAt = updatedAt
    }

    convenience init(_ tag: OrdoTag) {
        self.init(id: tag.id, name: tag.name, color: tag.color, updatedAt: tag.updatedAt)
    }

    func apply(_ tag: OrdoTag) {
        name = tag.name
        color = tag.color
        updatedAt = tag.updatedAt
    }

    var value: OrdoTag { OrdoTag(id: id, name: name, color: color, updatedAt: updatedAt) }
}

/// 契约 §8:`outbox(opId PK, payload, createdAt)`。
@Model
final class SDOutboxOp {
    @Attribute(.unique) var opId: String
    /// Op 的完整 JSON。
    var payload: Data
    var createdAt: Int64

    init(opId: String, payload: Data, createdAt: Int64) {
        self.opId = opId
        self.payload = payload
        self.createdAt = createdAt
    }
}

/// 契约 §8:`tombstones(entity, entityId, deletedAt)`(契约 §7.3.5 另带 clientTs)。
@Model
final class SDTombstone {
    /// 复合键 `entity:entityId`(SwiftData 单列唯一约束的可行写法)。
    @Attribute(.unique) var key: String
    var entity: String
    var entityId: String
    var deletedAt: Int64
    var clientTs: Int64

    init(entity: String, entityId: String, deletedAt: Int64, clientTs: Int64) {
        self.key = "\(entity):\(entityId)"
        self.entity = entity
        self.entityId = entityId
        self.deletedAt = deletedAt
        self.clientTs = clientTs
    }

    convenience init(_ tombstone: OrdoTombstone) {
        self.init(
            entity: tombstone.entity.rawValue,
            entityId: tombstone.entityId,
            deletedAt: tombstone.deletedAt,
            clientTs: tombstone.clientTs
        )
    }

    var value: OrdoTombstone? {
        guard let kind = OrdoEntityKind(rawValue: entity) else { return nil }
        return OrdoTombstone(entity: kind, entityId: entityId, deletedAt: deletedAt, clientTs: clientTs)
    }
}

/// 契约 §8:`kv(key, value)`。
@Model
final class SDKV {
    @Attribute(.unique) var key: String
    var value: String?

    init(key: String, value: String?) {
        self.key = key
        self.value = value
    }
}

// MARK: - 仓储实现

public enum OrdoStorageError: Error, LocalizedError {
    case containerUnavailable(String)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .containerUnavailable(let reason): return "本地数据库不可用:\(reason)"
        case .encodingFailed(let reason): return "本地数据编码失败:\(reason)"
        }
    }
}

/// SwiftData 仓储(契约 §8)。
@ModelActor
public actor SwiftDataStorage: OrdoStorageProtocol {

    public static func schema() -> Schema {
        Schema([
            SDTodo.self,
            SDProject.self,
            SDArea.self,
            SDTag.self,
            SDOutboxOp.self,
            SDTombstone.self,
            SDKV.self
        ])
    }

    /// 创建容器。磁盘不可用时由调用方降级到 `OrdoMemoryStorage`。
    ///
    /// - Parameter directory: **该账号专属**的数据目录(契约 §7.6.3)。
    ///   传入时存储文件为 `<directory>/Ordo.store`,因此两个账号的本地数据物理隔离;
    ///   为 `nil` 时退回系统默认位置(仅用于预览/测试)。
    public static func makeContainer(
        inMemory: Bool = false,
        directory: URL? = nil,
        fileName: String = OrdoSessionDirectory.storeFileName
    ) throws -> ModelContainer {
        let schema = schema()
        guard !inMemory, let directory else {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
            return try ModelContainer(for: schema, configurations: [configuration])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent(fileName, isDirectory: false)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// 按 userId 打开本地库(契约 §7.6.3 硬约束:一个账号一个目录,绝不复用)。
    public static func makeUserContainer(userId: String) throws -> ModelContainer {
        let directory = try OrdoAppDirectories.userDirectory(userId: userId)
        return try makeContainer(directory: directory)
    }

    public init(container: ModelContainer) {
        self.init(modelContainer: container)
    }

    // MARK: 实体读写

    public func loadSnapshot() async throws -> OrdoSnapshot {
        let todos = try modelContext.fetch(FetchDescriptor<SDTodo>()).filter { !$0.deleted }.map(\.value)
        let projects = try modelContext.fetch(FetchDescriptor<SDProject>()).filter { !$0.deleted }.map(\.value)
        let areas = try modelContext.fetch(FetchDescriptor<SDArea>()).filter { !$0.deleted }.map(\.value)
        let tags = try modelContext.fetch(FetchDescriptor<SDTag>()).map(\.value)
        return OrdoSnapshot(
            areas: areas.sorted { $0.order < $1.order },
            projects: projects.sorted { $0.order < $1.order },
            todos: todos.sorted { $0.order < $1.order },
            tags: tags.sorted { $0.name < $1.name }
        )
    }

    public func upsert(
        areas: [OrdoArea],
        projects: [OrdoProject],
        todos: [OrdoTodo],
        tags: [OrdoTag]
    ) async throws {
        try upsertAreas(areas)
        try upsertProjects(projects)
        try upsertTodos(todos)
        try upsertTags(tags)
        try modelContext.save()
    }

    private func upsertAreas(_ items: [OrdoArea]) throws {
        guard !items.isEmpty else { return }
        var index = indexByID(try modelContext.fetch(FetchDescriptor<SDArea>()))
        for item in items {
            if let row = index[item.id] {
                row.apply(item)
            } else {
                let row = SDArea(item)
                modelContext.insert(row)
                index[item.id] = row
            }
        }
    }

    private func upsertProjects(_ items: [OrdoProject]) throws {
        guard !items.isEmpty else { return }
        var index = indexByID(try modelContext.fetch(FetchDescriptor<SDProject>()))
        for item in items {
            if let row = index[item.id] {
                row.apply(item)
            } else {
                let row = SDProject(item)
                modelContext.insert(row)
                index[item.id] = row
            }
        }
    }

    private func upsertTodos(_ items: [OrdoTodo]) throws {
        guard !items.isEmpty else { return }
        var index = indexByID(try modelContext.fetch(FetchDescriptor<SDTodo>()))
        for item in items {
            if let row = index[item.id] {
                row.apply(item)
            } else {
                let row = SDTodo(item)
                modelContext.insert(row)
                index[item.id] = row
            }
        }
    }

    private func upsertTags(_ items: [OrdoTag]) throws {
        guard !items.isEmpty else { return }
        var index: [String: SDTag] = [:]
        for row in try modelContext.fetch(FetchDescriptor<SDTag>()) { index[row.name] = row }
        for item in items {
            if let row = index[item.name] {
                row.apply(item)
            } else {
                let row = SDTag(item)
                modelContext.insert(row)
                index[item.name] = row
            }
        }
    }

    /// 手写索引构建:避免 `Dictionary(uniqueKeysWithValues:)` 在重复主键上直接崩溃。
    private func indexByID<T: PersistentModel>(_ rows: [T]) -> [String: T] {
        var index: [String: T] = [:]
        for row in rows {
            switch row {
            case let todo as SDTodo: index[todo.id] = row
            case let project as SDProject: index[project.id] = row
            case let area as SDArea: index[area.id] = row
            default: break
            }
        }
        return index
    }

    public func markDeleted(entity: OrdoEntityKind, entityId: String, updatedAt: Int64) async throws {
        switch entity {
        case .todo:
            if let row = try fetchTodo(entityId) {
                row.deleted = true
                row.updatedAt = updatedAt
            }
        case .project:
            if let row = try fetchProject(entityId) {
                row.deleted = true
                row.updatedAt = updatedAt
            }
        case .area:
            if let row = try fetchArea(entityId) {
                row.deleted = true
                row.updatedAt = updatedAt
            }
        case .heading:
            // Heading 内嵌在 Project 中,整体更新该项目。
            let projects = try modelContext.fetch(FetchDescriptor<SDProject>())
            for row in projects where row.headings.contains(where: { $0.id == entityId }) {
                row.headings.removeAll { $0.id == entityId }
                row.updatedAt = updatedAt
            }
        case .tag:
            let tags = try modelContext.fetch(FetchDescriptor<SDTag>())
            for row in tags where row.id == entityId || row.name == entityId {
                modelContext.delete(row)
            }
        }
        try modelContext.save()
    }

    public func resetAll() async throws {
        try modelContext.delete(model: SDTodo.self)
        try modelContext.delete(model: SDProject.self)
        try modelContext.delete(model: SDArea.self)
        try modelContext.delete(model: SDTag.self)
        try modelContext.delete(model: SDOutboxOp.self)
        try modelContext.delete(model: SDTombstone.self)
        try modelContext.delete(model: SDKV.self)
        try modelContext.save()
    }

    private func fetchTodo(_ id: String) throws -> SDTodo? {
        var descriptor = FetchDescriptor<SDTodo>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchProject(_ id: String) throws -> SDProject? {
        var descriptor = FetchDescriptor<SDProject>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchArea(_ id: String) throws -> SDArea? {
        var descriptor = FetchDescriptor<SDArea>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    // MARK: outbox

    public func outboxAppend(_ ops: [OrdoOp]) async throws {
        guard !ops.isEmpty else { return }
        let existing = Set(try modelContext.fetch(FetchDescriptor<SDOutboxOp>()).map(\.opId))
        for op in ops where !existing.contains(op.opId) {
            let data: Data
            do {
                data = try JSONEncoder().encode(op)
            } catch {
                throw OrdoStorageError.encodingFailed(error.localizedDescription)
            }
            modelContext.insert(SDOutboxOp(opId: op.opId, payload: data, createdAt: op.clientTs))
        }
        try modelContext.save()
    }

    public func outboxAll() async throws -> [OrdoOp] {
        let rows = try modelContext.fetch(FetchDescriptor<SDOutboxOp>(sortBy: [SortDescriptor(\.createdAt)]))
        let decoder = JSONDecoder()
        return rows.compactMap { row in
            do {
                return try decoder.decode(OrdoOp.self, from: row.payload)
            } catch {
                // 解码失败的脏数据直接丢弃,避免阻塞整个同步队列。
                modelContext.delete(row)
                return nil
            }
        }
    }

    public func outboxRemove(opIds: [String]) async throws {
        guard !opIds.isEmpty else { return }
        let removing = Set(opIds)
        let rows = try modelContext.fetch(FetchDescriptor<SDOutboxOp>())
        for row in rows where removing.contains(row.opId) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    public func outboxCount() async throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<SDOutboxOp>())
    }

    // MARK: tombstones

    public func tombstoneAdd(_ tombstones: [OrdoTombstone]) async throws {
        guard !tombstones.isEmpty else { return }
        let existing = Set(try modelContext.fetch(FetchDescriptor<SDTombstone>()).map(\.key))
        for item in tombstones where !existing.contains("\(item.entity.rawValue):\(item.entityId)") {
            modelContext.insert(SDTombstone(item))
        }
        try modelContext.save()
    }

    public func tombstoneAll() async throws -> [OrdoTombstone] {
        try modelContext.fetch(FetchDescriptor<SDTombstone>()).compactMap(\.value)
    }

    /// 整体替换(Kotlin `saveTombstones(list)` 的语义:以传入集合为准)。
    public func tombstoneReplace(_ tombstones: [OrdoTombstone]) async throws {
        let desired = Dictionary(
            tombstones.map { ("\($0.entity.rawValue):\($0.entityId)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let rows = try modelContext.fetch(FetchDescriptor<SDTombstone>())
        var existing = Set<String>()
        for row in rows {
            if desired[row.key] == nil {
                modelContext.delete(row)
            } else {
                existing.insert(row.key)
            }
        }
        for (key, item) in desired where !existing.contains(key) {
            modelContext.insert(SDTombstone(item))
        }
        try modelContext.save()
    }

    public func tombstonePrune(before: Int64) async throws {
        let rows = try modelContext.fetch(FetchDescriptor<SDTombstone>())
        for row in rows where row.deletedAt < before {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    // MARK: kv

    public func kvGet(_ key: String) async throws -> String? {
        var descriptor = FetchDescriptor<SDKV>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.value
    }

    public func kvSet(_ key: String, value: String?) async throws {
        var descriptor = FetchDescriptor<SDKV>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let row = try modelContext.fetch(descriptor).first {
            if let value {
                row.value = value
            } else {
                modelContext.delete(row)
            }
        } else if let value {
            modelContext.insert(SDKV(key: key, value: value))
        }
        try modelContext.save()
    }

    public func kvAll() async throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try modelContext.fetch(FetchDescriptor<SDKV>()) {
            if let value = row.value { result[row.key] = value }
        }
        return result
    }
}
