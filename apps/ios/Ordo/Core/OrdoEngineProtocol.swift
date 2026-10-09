//
//  OrdoEngineProtocol.swift
//  Ordo
//
//  iOS 侧对 KMP `com.ordo.core.OrdoEngine` 的 Swift 协议镜像。
//
//  ⚠️ 本文件与 `OrdoCoreBridge.swift` 的方法清单**逐条对应** `shared/core` 的
//     `store/OrdoEngine.kt`(已在交付前与真实 Kotlin 源码核对过):
//
//  ┌────────────────────────────────────────────────────────────────────────────┐
//  │ Kotlin(com.ordo.core.store.OrdoEngine)          →  Swift(本文件)           │
//  ├────────────────────────────────────────────────────────────────────────────┤
//  │ OrdoEngine(storage, clock, uuid, deviceId)      →  OrdoCoreBridge.make(...) │
//  │ snapshot: OrdoSnapshot                          →  snapshot                │
//  │ schemaVersion: Int                              →  schemaVersion           │
//  │ deviceId: String                                →  deviceId                │
//  │ subscribe(listener): () -> Unit                 →  subscribe(_:)           │
//  │ list(query) / sections(query) / counts()        →  同名                     │
//  │ headingsOf(projectId) / projectProgress(id)     →  同名                     │
//  │ todo(id) / project(id) / area(id)               →  同名                     │
//  │ createTodo(title, opts): Todo                   →  createTodo(title:options:)│
//  │ updateTodo(id, mutate: (Todo) -> Todo)          →  updateTodo(id:mutate:)   │
//  │ setTitle/setNote/setWhen/setDeadline/setReminder/setRepeat → 同名           │
//  │ moveTodo/addTag/removeTag                       →  同名                     │
//  │ addChecklistItem/setChecklistItemTitle/         →  同名                     │
//  │   toggleChecklistItem/removeChecklistItem                                   │
//  │ duplicateTodo(id): Todo?                        →  duplicateTodo(id:)       │
//  │ toggleDone(id) / complete(id, canceled) / reopen(id) / deleteTodo(id)       │
//  │ reorderTodos(ids)                               →  同名                     │
//  │ createProject(name, areaId, headingNames)       →  同名                     │
//  │ updateProject/renameProject/setProjectNote/setProjectWhen/moveProject       │
//  │ completeProject(id): Boolean / reopenProject / deleteProject                │
//  │ createHeading(projectId, name, order) / updateHeading / renameHeading        │
//  │ toggleHeadingCollapsed / archiveHeading(id): Boolean / deleteHeading         │
//  │ createArea(name) / renameArea / deleteArea      →  同名                     │
//  │ ensureTag(name, now) / tags()                   →  同名                     │
//  │ pendingOps() / pendingOpCount()                 →  同名                     │
//  │ lastServerSeq() / setLastServerSeq(seq) / ackOps(opIds)                     │
//  │ applyRemote(ops): Int / replaceWithRemote(snapshot)                         │
//  │ seedDemoData(force): Boolean / clearAll()       →  同名                     │
//  └────────────────────────────────────────────────────────────────────────────┘
//
//  并发约定:引擎只在主线程(MainActor)被驱动,与 SwiftUI 状态更新同域;
//  `subscribe` 的回调统一在主线程投递。跨线程的持久化由 `OrdoStorageProtocol`(async)承担,
//  中间由 `OrdoCoreStorageMirror` 做「同步镜像 + 异步写回」。
//

import Foundation

/// 订阅句柄。Kotlin `subscribe` 返回 `() -> Unit`(取消函数),桥接层包装成本协议。
public protocol OrdoSubscription: AnyObject, Sendable {
    func cancel()
}

/// 新建待办的可选参数。
///
/// ⚠️ 与 Kotlin `store.TodoOptions` **逐字段一致**(注意:其中**没有** reminder / deadline ——
/// 契约 §5 的提醒由标题里的时间片段解析得到,截止日期用 `setDeadline` 设置):
/// ```kotlin
/// data class TodoOptions(
///     val `when`: When? = null, val date: String? = null,
///     val projectId: String? = null, val areaId: String? = null, val headingId: String? = null,
///     val tags: List<String> = emptyList(), val note: String = "", val insertAtTop: Boolean = false
/// )
/// ```
public struct OrdoTodoOptions: Hashable, Sendable {
    public var when: OrdoWhen?
    public var date: String?
    public var projectId: String?
    public var areaId: String?
    public var headingId: String?
    public var tags: [String]
    public var note: String
    /// 置顶插入(列表按 order 升序时插到最前)。
    public var insertAtTop: Bool

    public init(
        when: OrdoWhen? = nil,
        date: String? = nil,
        projectId: String? = nil,
        areaId: String? = nil,
        headingId: String? = nil,
        tags: [String] = [],
        note: String = "",
        insertAtTop: Bool = false
    ) {
        self.when = when
        self.date = date
        self.projectId = projectId
        self.areaId = areaId
        self.headingId = headingId
        self.tags = tags
        self.note = note
        self.insertAtTop = insertAtTop
    }

    public static let none = OrdoTodoOptions()
}

/// 业务核心门面。所有派生清单、字段不变量、NLP、重复规则、冲突合并都由 KMP 核心实现,
/// iOS 侧只负责调用与展示(不在 Swift 中复制业务规则)。
@MainActor
public protocol OrdoEngineProtocol: AnyObject {

    // MARK: 状态

    /// 当前完整快照(契约 §2)。
    var snapshot: OrdoSnapshot { get }
    /// 契约 §8 的 schemaVersion。
    var schemaVersion: Int { get }
    /// 本机设备标识(引擎写入 kv `ordo.deviceId`)。
    var deviceId: String { get }

    /// 订阅变更;返回的句柄用于取消订阅。
    func subscribe(_ listener: @escaping @Sendable (OrdoSnapshot) -> Void) -> OrdoSubscription

    // MARK: 只读查询(契约 §4)

    func list(_ query: OrdoListQuery) -> [OrdoTodo]
    func sections(_ query: OrdoListQuery) -> [OrdoListSection]
    func counts() -> OrdoSidebarCounts
    func headingsOf(projectId: String) -> [OrdoHeading]
    /// 项目进度 0…1(无子项时为 0)。
    func projectProgress(projectId: String) -> Double
    func todo(id: String) -> OrdoTodo?
    func project(id: String) -> OrdoProject?
    func area(id: String) -> OrdoArea?

    // MARK: 待办写操作

    /// 标题会先经过中文 NLP 解析(契约 §5),因此 `title` 可直接写「明天 18:00 交报告 #重要」。
    @discardableResult
    func createTodo(title: String, options: OrdoTodoOptions) -> OrdoTodo

    /// 局部更新:Kotlin 侧签名为 `updateTodo(id, mutate: (Todo) -> Todo)`,
    /// 桥接层先取出值类型副本、跑闭包、再回写成新的 Kotlin 对象。
    func updateTodo(id: String, mutate: (inout OrdoTodo) -> Void)

    func setTitle(id: String, title: String)
    func setNote(id: String, note: String)
    func setWhen(id: String, when: OrdoWhen, date: String?)
    func setDeadline(id: String, date: String?)
    func setReminder(id: String, reminder: String?)
    func setRepeat(id: String, rule: OrdoRepeatRule?)
    func moveTodo(id: String, projectId: String?, areaId: String?, headingId: String?)

    func addTag(id: String, tag: String)
    func removeTag(id: String, tag: String)

    func addChecklistItem(todoId: String, title: String)
    func setChecklistItemTitle(todoId: String, itemId: String, title: String)
    func toggleChecklistItem(todoId: String, itemId: String)
    func removeChecklistItem(todoId: String, itemId: String)

    @discardableResult
    func duplicateTodo(id: String) -> OrdoTodo?

    func toggleDone(id: String)
    /// `canceled == true` 表示取消(契约 §2 的 Status.canceled)。
    func complete(id: String, canceled: Bool)
    func reopen(id: String)
    func deleteTodo(id: String)
    func reorderTodos(ids: [String])

    // MARK: 容器写操作

    @discardableResult
    func createProject(name: String, areaId: String?, headingNames: [String]) -> OrdoProject
    /// Kotlin:`updateProject(id, mutate: (Project) -> Project)`。
    func updateProject(id: String, mutate: (inout OrdoProject) -> Void)
    func renameProject(id: String, name: String)
    func setProjectNote(id: String, note: String)
    func setProjectWhen(id: String, when: OrdoWhen, date: String?)
    func moveProject(id: String, areaId: String?)
    /// 契约 §2.2 硬约束:仅在全部子待办已结束且全部标题已归档时才能完成,返回是否成功。
    @discardableResult
    func completeProject(id: String) -> Bool
    func reopenProject(id: String)
    func deleteProject(id: String)

    @discardableResult
    func createHeading(projectId: String, name: String, order: Int) -> OrdoHeading
    /// Kotlin:`updateHeading(id, mutate: (Heading) -> Heading)`。
    func updateHeading(id: String, mutate: (inout OrdoHeading) -> Void)
    func renameHeading(id: String, name: String)
    func toggleHeadingCollapsed(id: String)
    @discardableResult
    func archiveHeading(id: String) -> Bool
    func deleteHeading(id: String)

    @discardableResult
    func createArea(name: String) -> OrdoArea
    func renameArea(id: String, name: String)
    func deleteArea(id: String)

    @discardableResult
    func ensureTag(name: String) -> OrdoTag
    func tags() -> [OrdoTag]

    // MARK: 同步(契约 §7)

    func pendingOps() -> [OrdoOp]
    func pendingOpCount() -> Int
    func lastServerSeq() -> Int64
    func setLastServerSeq(_ seq: Int64)
    func ackOps(_ opIds: [String])
    /// 应用远端 ops(契约 §7.3 的合并规则在核心内执行),返回应用的条数。
    @discardableResult
    func applyRemote(_ ops: [OrdoOp]) -> Int
    func replaceWithRemote(_ snapshot: OrdoSnapshot)

    // MARK: 维护

    @discardableResult
    func seedDemoData(force: Bool) -> Bool
    func clearAll()
}

// MARK: - 时钟与 id

/// 时钟抽象。对应 Kotlin `platform.OrdoClock`(`fun interface { fun nowMillis(): Long }`)。
public protocol OrdoClock: Sendable {
    /// 当前时间,epoch millis。
    func nowMillis() -> Int64
}

public extension OrdoClock {
    /// 便捷别名(展示层常用)。
    func now() -> Int64 { nowMillis() }
}

/// 系统时钟。
public struct OrdoSystemClock: OrdoClock {
    public init() {}
    public func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// id 生成器。对应 Kotlin `OrdoEngine(uuid: () -> String)`:实体 id 为 UUID v4。
/// `opId`(ULID)由 Kotlin `Ids.ulid()` 生成,Swift 侧只在需要构造测试 op 时使用。
public protocol OrdoUUIDProvider: Sendable {
    func newEntityId() -> String
    func newOpId() -> String
    func newDeviceId() -> String
}

/// 默认 id 生成器。
public struct OrdoDefaultUUIDProvider: OrdoUUIDProvider {
    public init() {}

    public func newEntityId() -> String {
        UUID().uuidString.lowercased()
    }

    public func newDeviceId() -> String {
        "dev_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10)
    }

    public func newOpId() -> String {
        OrdoULID.generate()
    }
}

/// 极简 ULID 生成器(48 位时间戳 + 80 位随机,Base32 Crockford,26 字符)。
/// 与 Kotlin `util.Ids.ulid()` 的格式一致,用于 Swift 侧构造测试/补偿 op。
public enum OrdoULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let lock = NSLock()
    private static var lastRandom: [UInt8] = (0..<10).map { _ in UInt8.random(in: 0...255) }
    private static var lastTimestamp: Int64 = 0

    public static func generate(at timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        lock.lock()
        defer { lock.unlock() }

        if timestamp == lastTimestamp {
            var index = lastRandom.count - 1
            while index >= 0 {
                if lastRandom[index] == 255 {
                    lastRandom[index] = 0
                    index -= 1
                } else {
                    lastRandom[index] += 1
                    break
                }
            }
        } else {
            lastTimestamp = timestamp
            lastRandom = (0..<10).map { _ in UInt8.random(in: 0...255) }
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for shift in stride(from: 40, through: 0, by: -8) {
            bytes.append(UInt8((timestamp >> Int64(shift)) & 0xFF))
        }
        bytes.append(contentsOf: lastRandom)
        return encode(bytes)
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        var result = ""
        result.reserveCapacity(26)
        var bits = 0
        var buffer = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[(buffer >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            result.append(alphabet[(buffer << (5 - bits)) & 0x1F])
        }
        return result
    }
}
