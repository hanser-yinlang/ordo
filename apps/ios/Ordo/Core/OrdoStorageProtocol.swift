//
//  OrdoStorageProtocol.swift
//  Ordo
//
//  本地存储契约(契约 §8「客户端」)。
//
//  表字段名与契约 §2 完全一致;另加本地表 `outbox` / `tombstones` / `kv`。
//  iOS 实现为 `Data/SwiftDataStorage.swift`(SwiftData,`@ModelActor`)。
//
//  为什么是 async:`@ModelActor` 隔离 + KMP 侧 `OrdoStorage` 的 suspend 语义;
//  引擎在 MainActor 上同步调用,持久化通过内部 async 通道完成(本地优先:UI 不等待落盘)。
//

import Foundation

/// 本地快照 + 本地元数据。
public struct OrdoStorageSnapshot: Sendable {
    public var snapshot: OrdoSnapshot
    public var lastServerSeq: Int64
    public var tombstones: [OrdoTombstone]
    public var outboxCount: Int
    /// kv 中记录的 schemaVersion(契约 §8「迁移」)。
    public var schemaVersion: Int

    public init(
        snapshot: OrdoSnapshot,
        lastServerSeq: Int64 = 0,
        tombstones: [OrdoTombstone] = [],
        outboxCount: Int = 0,
        schemaVersion: Int = OrdoSchema.version
    ) {
        self.snapshot = snapshot
        self.lastServerSeq = lastServerSeq
        self.tombstones = tombstones
        self.outboxCount = outboxCount
        self.schemaVersion = schemaVersion
    }
}

/// 契约版本常量。
public enum OrdoSchema {
    /// 契约 §头部:`schemaVersion = 1`。
    public static let version = 1
    /// HTTP 头 `X-Ordo-Schema`。
    public static let headerName = "X-Ordo-Schema"
}

/// kv 表的键名(契约 §8)。
public enum OrdoKVKey {
    public static let lastServerSeq = "lastServerSeq"
    public static let deviceId = "deviceId"
    public static let accessToken = "accessToken"
    public static let refreshToken = "refreshToken"
    public static let tokenExpiry = "tokenExpiry"
    public static let userEmail = "userEmail"
    public static let schemaVersion = "schemaVersion"
    public static let themePreference = "themePreference"
    public static let lastSyncAt = "lastSyncAt"
    public static let seeded = "seeded"
}

/// 本地存储门面。方法均为 async,由 SwiftData 的 `@ModelActor` 实现。
public protocol OrdoStorageProtocol: AnyObject, Sendable {

    // MARK: 实体读写

    /// 一次性读出全部未删除实体(启动路径)。
    func loadSnapshot() async throws -> OrdoSnapshot

    /// 批量 upsert(字段名与契约 §2 一致)。
    func upsert(
        areas: [OrdoArea],
        projects: [OrdoProject],
        todos: [OrdoTodo],
        tags: [OrdoTag]
    ) async throws

    /// 软删除标记落库(契约 §3:一律软删除)。
    func markDeleted(entity: OrdoEntityKind, entityId: String, updatedAt: Int64) async throws

    /// 物理清空(仅用于「重置示例数据」)。
    func resetAll() async throws

    // MARK: outbox(契约 §7.1)

    func outboxAppend(_ ops: [OrdoOp]) async throws
    func outboxAll() async throws -> [OrdoOp]
    func outboxRemove(opIds: [String]) async throws
    func outboxCount() async throws -> Int

    // MARK: tombstones(契约 §7.3.5)

    func tombstoneAdd(_ tombstones: [OrdoTombstone]) async throws
    func tombstoneAll() async throws -> [OrdoTombstone]
    /// 用给定集合整体替换墓碑(Kotlin 侧 `saveTombstones(list)` 的语义)。
    func tombstoneReplace(_ tombstones: [OrdoTombstone]) async throws
    /// 墓碑保留 30 天。
    func tombstonePrune(before: Int64) async throws

    // MARK: kv

    func kvGet(_ key: String) async throws -> String?
    func kvSet(_ key: String, value: String?) async throws
    /// 一次性读出全部键值(引擎构造前预加载镜像用)。
    func kvAll() async throws -> [String: String]
    func kvInt(_ key: String) async throws -> Int64
    func kvSetInt(_ key: String, value: Int64) async throws
}

public extension OrdoStorageProtocol {
    func upsert(_ snapshot: OrdoSnapshot) async throws {
        try await upsert(areas: snapshot.areas, projects: snapshot.projects, todos: snapshot.todos, tags: snapshot.tags)
    }

    func kvInt(_ key: String) async throws -> Int64 {
        guard let raw = try await kvGet(key) else { return 0 }
        return Int64(raw) ?? 0
    }

    func kvSetInt(_ key: String, value: Int64) async throws {
        try await kvSet(key, value: String(value))
    }

    /// 启动时使用:读快照 + 本地元数据。
    func loadStorageSnapshot() async throws -> OrdoStorageSnapshot {
        let snapshot = try await loadSnapshot()
        let seq = try await kvInt(OrdoKVKey.lastServerSeq)
        let tombstones = try await tombstoneAll()
        let outbox = try await outboxCount()
        let schema = Int(try await kvInt(OrdoKVKey.schemaVersion))
        return OrdoStorageSnapshot(
            snapshot: snapshot,
            lastServerSeq: seq,
            tombstones: tombstones,
            outboxCount: outbox,
            schemaVersion: schema == 0 ? OrdoSchema.version : schema
        )
    }
}

/// 内存实现:用于 SwiftUI 预览、单元测试与「存储不可用」降级路径。
/// 与 SwiftData 实现共享同一协议,保证两种实现行为一致。
public actor OrdoMemoryStorage: OrdoStorageProtocol {
    private var areas: [String: OrdoArea] = [:]
    private var projects: [String: OrdoProject] = [:]
    private var todos: [String: OrdoTodo] = [:]
    private var tags: [String: OrdoTag] = [:]
    private var outbox: [OrdoOp] = []
    private var tombstones: [OrdoTombstone] = []
    private var kv: [String: String] = [:]
    private var deletedEntities: Set<String> = []

    public init() {}

    public func loadSnapshot() async throws -> OrdoSnapshot {
        OrdoSnapshot(
            areas: areas.values.filter { !$0.deleted }.sorted { $0.order < $1.order },
            projects: projects.values.filter { !$0.deleted }.sorted { $0.order < $1.order },
            todos: todos.values.filter { !$0.deleted }.sorted { $0.order < $1.order },
            tags: tags.values.sorted { $0.name < $1.name }
        )
    }

    public func upsert(
        areas newAreas: [OrdoArea],
        projects newProjects: [OrdoProject],
        todos newTodos: [OrdoTodo],
        tags newTags: [OrdoTag]
    ) async throws {
        for item in newAreas { areas[item.id] = item }
        for item in newProjects { projects[item.id] = item }
        for item in newTodos { todos[item.id] = item }
        for item in newTags { tags[item.name] = item }
    }

    public func markDeleted(entity: OrdoEntityKind, entityId: String, updatedAt: Int64) async throws {
        deletedEntities.insert("\(entity.rawValue):\(entityId)")
        switch entity {
        case .todo:
            if var item = todos[entityId] {
                item.deleted = true
                item.updatedAt = updatedAt
                todos[entityId] = item
            }
        case .project:
            if var item = projects[entityId] {
                item.deleted = true
                item.updatedAt = updatedAt
                projects[entityId] = item
            }
        case .area:
            if var item = areas[entityId] {
                item.deleted = true
                item.updatedAt = updatedAt
                areas[entityId] = item
            }
        case .heading:
            for (key, var project) in projects {
                guard let index = project.headings.firstIndex(where: { $0.id == entityId }) else { continue }
                project.headings.remove(at: index)
                projects[key] = project
            }
        case .tag:
            tags.removeValue(forKey: entityId)
        }
    }

    public func resetAll() async throws {
        areas.removeAll()
        projects.removeAll()
        todos.removeAll()
        tags.removeAll()
        outbox.removeAll()
        tombstones.removeAll()
        kv.removeAll()
        deletedEntities.removeAll()
    }

    public func outboxAppend(_ ops: [OrdoOp]) async throws {
        let existing = Set(outbox.map(\.opId))
        outbox.append(contentsOf: ops.filter { !existing.contains($0.opId) })
    }

    public func outboxAll() async throws -> [OrdoOp] { outbox }

    public func outboxRemove(opIds: [String]) async throws {
        let removing = Set(opIds)
        outbox.removeAll { removing.contains($0.opId) }
    }

    public func outboxCount() async throws -> Int { outbox.count }

    public func tombstoneAdd(_ items: [OrdoTombstone]) async throws {
        for item in items where !tombstones.contains(where: { $0.entity == item.entity && $0.entityId == item.entityId }) {
            tombstones.append(item)
        }
    }

    public func tombstoneAll() async throws -> [OrdoTombstone] { tombstones }

    public func tombstoneReplace(_ items: [OrdoTombstone]) async throws {
        tombstones = items
    }

    public func tombstonePrune(before: Int64) async throws {
        tombstones.removeAll { $0.deletedAt < before }
    }

    public func kvGet(_ key: String) async throws -> String? { kv[key] }

    public func kvSet(_ key: String, value: String?) async throws {
        if let value { kv[key] = value } else { kv.removeValue(forKey: key) }
    }

    public func kvAll() async throws -> [String: String] { kv }

    // MARK: 测试辅助

    public func allTodos() async -> [OrdoTodo] { Array(todos.values) }
    public func replaceKv(_ dictionary: [String: String]) async { kv = dictionary }
}
