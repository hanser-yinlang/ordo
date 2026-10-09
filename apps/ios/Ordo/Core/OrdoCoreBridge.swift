//
//  OrdoCoreBridge.swift
//  Ordo
//
//  KMP `shared/core`(包 `com.ordo.core`)→ Swift 的唯一桥接层。
//  **已与真实 Kotlin 源码逐条核对**(shared/core/src/commonMain/kotlin/com/ordo/core/**)。
//
//  ─────────────────────────────────────────────────────────────────────────
//  已核对事实(不再是假设)
//  ─────────────────────────────────────────────────────────────────────────
//  ✓ 框架 baseName = `OrdoCore`(`build.gradle.kts`: target.binaries.framework { baseName = "OrdoCore"; isStatic = true })
//  ✓ 引擎签名:`class OrdoEngine(storage: OrdoStorage, clock: OrdoClock = SystemOrdoClock,
//                               uuid: () -> String = { Ids.uuid() }, deviceId: String = …)`
//    → Kotlin 默认参数不会导出到 ObjC,因此 Swift 必须**传满四个参数**。
//  ✓ `subscribe(listener: (OrdoSnapshot) -> Unit): () -> Unit` —— 返回的是取消函数,不是对象。
//  ✓ `updateTodo(id, mutate: (Todo) -> Todo)` —— mutate **返回新的 Todo**(data class 不可变)。
//  ✓ `createTodo(title, opts: TodoOptions): Todo` —— 非空;`TodoOptions` 无 reminder/deadline。
//  ✓ `OrdoStorage` 的 9 个方法是**同步**的(非 suspend),因此 Swift 侧用
//    `OrdoCoreStorageMirror`(同步内存镜像 + 异步写回 SwiftData)实现。
//  ✓ `Op.payload: JsonElement?`(kotlinx.serialization)—— Swift 无法直接构造 JsonElement,
//    因此 op / tombstone / snapshot 一律走 `OpCodec` 的 **JSON 文本** 通道:
//      `OpCodec.encodeOps(ops)` / `decodeOps(raw)` / `encodeSnapshot` / `decodeSnapshot`
//      / `encodeTombstones` / `decodeTombstones`。
//  ✓ 枚举取值是 INBOX / OPEN / DAILY / FIXED / UPSERT … 且都带 `wire` 属性,
//    因此统一用 `X.companion.fromWire(...)` 与 `value.wire` 互转,不依赖 ObjC 枚举导出名。
//  ✓ `ListQuery` 是 **sealed class**(`Inbox`/`Today`/… 为 object,`ProjectScope(id)` 等为 data class),
//    不是 (kind,id,text) 结构体。
//  ✓ `OrdoSnapshot` 的 headings 是**扁平列表**(Project 内不含 headings,与契约 §2.2 的 JSON 形状不同);
//    桥接层负责「扁平 ⇄ 嵌套」的换算。
//  ✓ `ListSection(title, subtitle, kind, todos, headingId)` —— 没有 id/date/collapsed,需在 Swift 侧合成。
//  ✓ `SidebarCounts(inbox…logbook, projects, projectProgress, tags)` —— **没有 areas 映射**。
//
//  仍然存在的少量不确定项(仅影响命名,不影响结构):
//    A1 ObjC 导出后嵌套 object 的访问形式(`ListQuery.Inbox.shared`)与 data class 初始化器标签;
//       若 Xcode 报「找不到成员」,按报错提示微调本文件的构造调用即可(**只改本文件**)。
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import OrdoCore

// MARK: - 订阅句柄

/// 包装 Kotlin `subscribe` 返回的取消函数(`() -> Unit`)。
public final class OrdoCoreCancellable: OrdoSubscription, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelClosure: (() -> Void)?

    public init(_ cancel: @escaping () -> Void) {
        self.cancelClosure = cancel
    }

    public func cancel() {
        lock.lock()
        let closure = cancelClosure
        cancelClosure = nil
        lock.unlock()
        closure?()
    }

    deinit { cancel() }
}

// MARK: - 引擎桥

/// KMP `OrdoEngine` 的 Swift 包装。
/// 所有写操作先落到 KMP 核心(内部改快照 → 写存储 → 产出 op),再通知 SwiftUI。
@MainActor
public final class OrdoCoreBridge: OrdoEngineProtocol {

    private let core: OrdoEngine
    private let mirror: OrdoCoreStorageMirror

    private var listeners: [UUID: @Sendable (OrdoSnapshot) -> Void] = [:]
    private var coreCancellable: OrdoCoreCancellable?
    private var cachedSnapshot: OrdoSnapshot = .empty

    /// 由异步工厂创建(必须先预加载本地存储)。
    private init(core: OrdoEngine, mirror: OrdoCoreStorageMirror) {
        self.core = core
        self.mirror = mirror
        self.cachedSnapshot = OrdoCoreMapping.map(snapshot: core.snapshot)
    }

    /// 组装引擎:预加载本地镜像 → 构造 Kotlin 引擎。
    ///
    /// - Parameters:
    ///   - storage: SwiftData(或内存)持久层,异步。
    ///   - clock: 时钟;Kotlin 侧接口为 `nowMillis()`。
    ///   - uuid: 实体 id 生成器(闭包,对应 Kotlin `uuid: () -> String`)。
    ///   - deviceId: 设备标识;为空时沿用核心内 kv 里的既有值或自动生成。
    public static func make(
        storage: OrdoStorageProtocol,
        clock: OrdoClock = OrdoSystemClock(),
        uuid: OrdoUUIDProvider = OrdoDefaultUUIDProvider(),
        deviceId: String? = nil
    ) async -> OrdoCoreBridge {
        let mirror = await OrdoCoreStorageMirror.preload(from: storage)
        let core = OrdoEngine(
            storage: mirror,
            clock: OrdoCoreClockAdapter(clock: clock),
            uuid: { uuid.newEntityId() },
            deviceId: deviceId ?? mirror.existingDeviceId ?? uuid.newDeviceId()
        )
        return OrdoCoreBridge(core: core, mirror: mirror)
    }

    // MARK: 状态

    public var snapshot: OrdoSnapshot { cachedSnapshot }

    public var schemaVersion: Int { Int(core.schemaVersion) }

    public var deviceId: String { core.deviceId }

    public func subscribe(_ listener: @escaping @Sendable (OrdoSnapshot) -> Void) -> OrdoSubscription {
        let token = UUID()
        listeners[token] = listener
        installCoreSubscriptionIfNeeded()
        listener(cachedSnapshot)
        return OrdoCoreCancellable { [weak self] in
            Task { @MainActor in self?.listeners[token] = nil }
        }
    }

    private func installCoreSubscriptionIfNeeded() {
        guard coreCancellable == nil else { return }
        // Kotlin: subscribe(listener: (OrdoSnapshot) -> Unit): () -> Unit
        let cancel: () -> Void = core.subscribe { [weak self] kotlinSnapshot in
            let mapped = OrdoCoreMapping.map(snapshot: kotlinSnapshot)
            Task { @MainActor in self?.deliver(mapped) }
        }
        coreCancellable = OrdoCoreCancellable(cancel)
    }

    private func deliver(_ snapshot: OrdoSnapshot) {
        cachedSnapshot = snapshot
        for listener in listeners.values { listener(snapshot) }
    }

    /// 每次写操作后同步一次快照(不依赖回调时序,保证 UI 立即拿到新状态)。
    private func refreshAndNotify() {
        deliver(OrdoCoreMapping.map(snapshot: core.snapshot))
    }

    // MARK: 只读查询

    public func list(_ query: OrdoListQuery) -> [OrdoTodo] {
        OrdoCoreMapping.map(todos: core.list(query: OrdoCoreMapping.map(query: query)))
    }

    public func sections(_ query: OrdoListQuery) -> [OrdoListSection] {
        OrdoCoreMapping.map(sections: core.sections(query: OrdoCoreMapping.map(query: query)))
    }

    public func counts() -> OrdoSidebarCounts {
        OrdoCoreMapping.map(counts: core.counts())
    }

    public func headingsOf(projectId: String) -> [OrdoHeading] {
        core.headingsOf(projectId: projectId).map(OrdoCoreMapping.map(heading:))
    }

    public func projectProgress(projectId: String) -> Double {
        Double(core.projectProgress(projectId: projectId))
    }

    public func todo(id: String) -> OrdoTodo? {
        core.todo(id: id).map(OrdoCoreMapping.map(todo:))
    }

    public func project(id: String) -> OrdoProject? {
        core.project(id: id).map { OrdoCoreMapping.map(project: $0, headings: cachedSnapshot.headings(of: id)) }
    }

    public func area(id: String) -> OrdoArea? {
        core.area(id: id).map(OrdoCoreMapping.map(area:))
    }

    // MARK: 待办写操作

    @discardableResult
    public func createTodo(title: String, options: OrdoTodoOptions) -> OrdoTodo {
        let created = core.createTodo(title: title, opts: OrdoCoreMapping.map(options: options))
        refreshAndNotify()
        return OrdoCoreMapping.map(todo: created)
    }

    public func updateTodo(id: String, mutate: (inout OrdoTodo) -> Void) {
        // Kotlin: updateTodo(id: String, mutate: (Todo) -> Todo)
        core.updateTodo(id: id) { kotlinTodo in
            var value = OrdoCoreMapping.map(todo: kotlinTodo)
            mutate(&value)
            return OrdoCoreMapping.map(todo: value)
        }
        refreshAndNotify()
    }

    public func setTitle(id: String, title: String) {
        core.setTitle(id: id, title: title)
        refreshAndNotify()
    }

    public func setNote(id: String, note: String) {
        core.setNote(id: id, note: note)
        refreshAndNotify()
    }

    public func setWhen(id: String, when: OrdoWhen, date: String?) {
        core.setWhen(id: id, when: OrdoCoreMapping.map(when: when), date: date)
        refreshAndNotify()
    }

    public func setDeadline(id: String, date: String?) {
        core.setDeadline(id: id, date: date)
        refreshAndNotify()
    }

    public func setReminder(id: String, reminder: String?) {
        core.setReminder(id: id, reminder: reminder)
        refreshAndNotify()
    }

    public func setRepeat(id: String, rule: OrdoRepeatRule?) {
        core.setRepeat(id: id, repeat: rule.map(OrdoCoreMapping.map(repeatRule:)))
        refreshAndNotify()
    }

    public func moveTodo(id: String, projectId: String?, areaId: String?, headingId: String?) {
        core.moveTodo(id: id, projectId: projectId, areaId: areaId, headingId: headingId)
        refreshAndNotify()
    }

    public func addTag(id: String, tag: String) {
        core.addTag(id: id, tag: tag)
        refreshAndNotify()
    }

    public func removeTag(id: String, tag: String) {
        core.removeTag(id: id, tag: tag)
        refreshAndNotify()
    }

    public func addChecklistItem(todoId: String, title: String) {
        core.addChecklistItem(todoId: todoId, title: title)
        refreshAndNotify()
    }

    public func setChecklistItemTitle(todoId: String, itemId: String, title: String) {
        core.setChecklistItemTitle(todoId: todoId, itemId: itemId, title: title)
        refreshAndNotify()
    }

    public func toggleChecklistItem(todoId: String, itemId: String) {
        core.toggleChecklistItem(todoId: todoId, itemId: itemId)
        refreshAndNotify()
    }

    public func removeChecklistItem(todoId: String, itemId: String) {
        core.removeChecklistItem(todoId: todoId, itemId: itemId)
        refreshAndNotify()
    }

    @discardableResult
    public func duplicateTodo(id: String) -> OrdoTodo? {
        let copy = core.duplicateTodo(id: id)
        refreshAndNotify()
        return copy.map(OrdoCoreMapping.map(todo:))
    }

    public func toggleDone(id: String) {
        core.toggleDone(id: id)
        refreshAndNotify()
    }

    public func complete(id: String, canceled: Bool) {
        core.complete(id: id, canceled: canceled)
        refreshAndNotify()
    }

    public func reopen(id: String) {
        core.reopen(id: id)
        refreshAndNotify()
    }

    public func deleteTodo(id: String) {
        core.deleteTodo(id: id)
        refreshAndNotify()
    }

    public func reorderTodos(ids: [String]) {
        core.reorderTodos(ids: ids)
        refreshAndNotify()
    }

    // MARK: 容器写操作

    @discardableResult
    public func createProject(name: String, areaId: String?, headingNames: [String]) -> OrdoProject {
        let created = core.createProject(name: name, areaId: areaId, headingNames: headingNames)
        refreshAndNotify()
        return OrdoCoreMapping.map(project: created, headings: cachedSnapshot.headings(of: created.id))
    }

    /// Kotlin:`updateProject(id, mutate: (Project) -> Project)`
    public func updateProject(id: String, mutate: (inout OrdoProject) -> Void) {
        let headings = cachedSnapshot.headings(of: id)
        core.updateProject(id: id) { kotlinProject in
            var value = OrdoCoreMapping.map(project: kotlinProject, headings: headings)
            mutate(&value)
            return OrdoCoreMapping.map(project: value)
        }
        refreshAndNotify()
    }

    public func renameProject(id: String, name: String) {
        core.renameProject(id: id, name: name)
        refreshAndNotify()
    }

    public func setProjectNote(id: String, note: String) {
        core.setProjectNote(id: id, note: note)
        refreshAndNotify()
    }

    public func setProjectWhen(id: String, when: OrdoWhen, date: String?) {
        core.setProjectWhen(id: id, when: OrdoCoreMapping.map(when: when), date: date)
        refreshAndNotify()
    }

    public func moveProject(id: String, areaId: String?) {
        core.moveProject(id: id, areaId: areaId)
        refreshAndNotify()
    }

    @discardableResult
    public func completeProject(id: String) -> Bool {
        let ok = core.completeProject(id: id)
        refreshAndNotify()
        return ok
    }

    public func reopenProject(id: String) {
        core.reopenProject(id: id)
        refreshAndNotify()
    }

    public func deleteProject(id: String) {
        core.deleteProject(id: id)
        refreshAndNotify()
    }

    @discardableResult
    public func createHeading(projectId: String, name: String, order: Int) -> OrdoHeading {
        let created = core.createHeading(projectId: projectId, name: name, order: Int32(order))
        refreshAndNotify()
        return OrdoCoreMapping.map(heading: created)
    }

    /// Kotlin:`updateHeading(id, mutate: (Heading) -> Heading)`
    public func updateHeading(id: String, mutate: (inout OrdoHeading) -> Void) {
        core.updateHeading(id: id) { kotlinHeading in
            var value = OrdoCoreMapping.map(heading: kotlinHeading)
            mutate(&value)
            return OrdoCoreMapping.map(heading: value)
        }
        refreshAndNotify()
    }

    public func renameHeading(id: String, name: String) {
        core.renameHeading(id: id, name: name)
        refreshAndNotify()
    }

    public func toggleHeadingCollapsed(id: String) {
        core.toggleHeadingCollapsed(id: id)
        refreshAndNotify()
    }

    @discardableResult
    public func archiveHeading(id: String) -> Bool {
        let ok = core.archiveHeading(id: id)
        refreshAndNotify()
        return ok
    }

    public func deleteHeading(id: String) {
        core.deleteHeading(id: id)
        refreshAndNotify()
    }

    @discardableResult
    public func createArea(name: String) -> OrdoArea {
        let created = core.createArea(name: name)
        refreshAndNotify()
        return OrdoCoreMapping.map(area: created)
    }

    public func renameArea(id: String, name: String) {
        core.renameArea(id: id, name: name)
        refreshAndNotify()
    }

    public func deleteArea(id: String) {
        core.deleteArea(id: id)
        refreshAndNotify()
    }

    @discardableResult
    public func ensureTag(name: String) -> OrdoTag {
        let tag = core.ensureTag(name: name)
        refreshAndNotify()
        return OrdoCoreMapping.map(tag: tag)
    }

    public func tags() -> [OrdoTag] {
        core.tags().map(OrdoCoreMapping.map(tag:))
    }

    // MARK: 同步(契约 §7)

    /// op 通过 `OpCodec` 的 JSON 文本通道往来,避免在 Swift 侧构造 kotlinx `JsonElement`。
    public func pendingOps() -> [OrdoOp] {
        let json = OpCodec.shared.encodeOps(ops: core.pendingOps())
        return OrdoCoreMapping.decodeOps(json: json)
    }

    public func pendingOpCount() -> Int { Int(core.pendingOpCount()) }

    public func lastServerSeq() -> Int64 { core.lastServerSeq() }

    public func setLastServerSeq(_ seq: Int64) {
        core.setLastServerSeq(seq: seq)
    }

    public func ackOps(_ opIds: [String]) {
        core.ackOps(opIds: opIds)
    }

    @discardableResult
    public func applyRemote(_ ops: [OrdoOp]) -> Int {
        guard !ops.isEmpty else { return 0 }
        let json = OrdoCoreMapping.encodeOps(ops)
        let kotlinOps = OpCodec.shared.decodeOps(raw: json)
        let applied = Int(core.applyRemote(ops: kotlinOps))
        refreshAndNotify()
        return applied
    }

    public func replaceWithRemote(_ snapshot: OrdoSnapshot) {
        let json = OrdoCoreMapping.encodeSnapshot(snapshot)
        guard let kotlinSnapshot = OpCodec.shared.decodeSnapshot(raw: json) else { return }
        core.replaceWithRemote(snapshot: kotlinSnapshot)
        refreshAndNotify()
    }

    // MARK: 维护

    @discardableResult
    public func seedDemoData(force: Bool) -> Bool {
        let seeded = core.seedDemoData(force: force)
        refreshAndNotify()
        return seeded
    }

    public func clearAll() {
        core.clearAll()
        refreshAndNotify()
    }

    // MARK: 供 App 层使用的持久化协调

    /// 等待所有异步写回落盘(测试与后台切换前调用)。
    public func flushStorage() async {
        await mirror.flush()
    }
}

// MARK: - 自然语言解析桥

/// KMP `nlp.NaturalDateParser`(object)的 Swift 包装。
public struct OrdoCoreNaturalLanguageParser: OrdoNaturalLanguageParser {
    public init() {}

    /// Kotlin:`NaturalDateParser.parse(input: String, today: String = …, nowTime: String = …): NlpResult`
    public func parse(_ input: String, today: String, now: String) -> OrdoParsedInput {
        let result = NaturalDateParser.shared.parse(input: input, today: today, nowTime: now)
        return OrdoParsedInput(
            cleanTitle: result.cleanTitle,
            when: OrdoWhen(rawValue: result.`when`?.wire ?? ""),
            date: result.date,
            reminder: result.reminder,
            tags: result.tags
        )
    }
}

// MARK: - Kotlin 接口适配器

/// Kotlin `Clock` 适配器。
/// 注意:Kotlin 侧接口是 `platform.OrdoClock { fun nowMillis(): Long }`,
/// 而 Swift 标准库也有同名 `Clock` 协议,因此必须写模块限定名 `OrdoCore.OrdoClock`。
public final class OrdoCoreClockAdapter: NSObject, OrdoCore.OrdoClock, @unchecked Sendable {
    private let clock: OrdoClock

    public init(clock: OrdoClock) {
        self.clock = clock
    }

    public func nowMillis() -> Int64 { clock.nowMillis() }
}

/// 把 Swift 的 `OrdoStorageProtocol`(async)适配成 Kotlin `OrdoStorage`(9 个同步方法)。
///
/// 设计:内存镜像 + 异步写回(契约 §7.1「本地优先」)。
/// - Kotlin 引擎在构造函数里就调用 `loadSnapshot()` / `loadOutbox()` / `loadTombstones()`,
///   因此这些数据必须在构造引擎前**预加载**好(`preload(from:)`);
/// - 之后每次 `saveSnapshot` / `appendOutbox` / `clearOutbox` / `saveTombstones` / `kvSet`
///   先更新内存镜像(同步返回,零阻塞),再把变更异步写回 SwiftData。
///
/// 快照与 op 的序列化复用 Kotlin `OpCodec`(encodeSnapshot/decodeSnapshot/encodeOps/decodeOps),
/// 保证与四端完全一致的 JSON 形状。
public final class OrdoCoreStorageMirror: NSObject, OrdoStorage, @unchecked Sendable {

    private let backing: OrdoStorageProtocol
    private let writeQueue = DispatchQueue(label: "com.ordo.storage.writeback", qos: .utility)
    private let lock = NSLock()

    private var snapshotJSON: String?
    private var outboxJSON: String
    private var tombstonesJSON: String
    private var kv: [String: String]

    /// 引擎构造时会写入 deviceId,这里保留引擎生成前的既有值以便复用。
    public private(set) var existingDeviceId: String?

    private init(
        backing: OrdoStorageProtocol,
        snapshotJSON: String?,
        outboxJSON: String,
        tombstonesJSON: String,
        kv: [String: String]
    ) {
        self.backing = backing
        self.snapshotJSON = snapshotJSON
        self.outboxJSON = outboxJSON
        self.tombstonesJSON = tombstonesJSON
        self.kv = kv
        self.existingDeviceId = kv["ordo.deviceId"]
        super.init()
    }

    /// 从异步持久层预加载镜像。
    public static func preload(from storage: OrdoStorageProtocol) async -> OrdoCoreStorageMirror {
        let snapshot: OrdoSnapshot
        let kv: [String: String]
        let outbox: [OrdoOp]
        let tombstones: [OrdoTombstone]
        do {
            let loaded = try await storage.loadStorageSnapshot()
            snapshot = loaded.snapshot
            kv = (try? await storage.kvAll()) ?? [:]
            outbox = (try? await storage.outboxAll()) ?? []
            tombstones = (try? await storage.tombstoneAll()) ?? []
        } catch {
            snapshot = .empty
            kv = [:]
            outbox = []
            tombstones = []
        }

        let snapshotJSON = OrdoCoreMapping.encodeSnapshot(snapshot)
        let outboxJSON = OrdoCoreMapping.encodeOps(outbox)
        let tombstonesJSON = OrdoCoreMapping.encodeTombstones(tombstones)
        return OrdoCoreStorageMirror(
            backing: storage,
            snapshotJSON: snapshotJSON,
            outboxJSON: outboxJSON,
            tombstonesJSON: tombstonesJSON,
            kv: kv
        )
    }

    /// 等待写backlog 排空。
    public func flush() async {
        await withCheckedContinuation { continuation in
            writeQueue.async { continuation.resume() }
        }
    }

    // MARK: Kotlin `OrdoStorage` 的 9 个同步方法

    public func loadSnapshot() -> OrdoCore.OrdoSnapshot? {
        let json = withLock { snapshotJSON }
        guard let json else { return nil }
        return OpCodec.shared.decodeSnapshot(raw: json)
    }

    public func saveSnapshot(snapshot: OrdoCore.OrdoSnapshot) {
        let json = OpCodec.shared.encodeSnapshot(snapshot: snapshot)
        withLock { snapshotJSON = json }
        let backing = self.backing
        writeQueue.async {
            guard let dto = OrdoCoreMapping.decodeSnapshotDTO(json: json) else { return }
            let snapshot = dto.merged()
            Task {
                try? await backing.upsert(
                    areas: snapshot.areas,
                    projects: snapshot.projects,
                    todos: snapshot.todos,
                    tags: snapshot.tags
                )
            }
        }
    }

    public func loadOutbox() -> [OrdoCore.Op] {
        let json = withLock { outboxJSON }
        return OpCodec.shared.decodeOps(raw: json)
    }

    public func appendOutbox(op: OrdoCore.Op) {
        let current = loadOutbox()
        let updated = current + [op]
        let json = OpCodec.shared.encodeOps(ops: updated)
        withLock { outboxJSON = json }
        let backing = self.backing
        let swiftOps = OrdoCoreMapping.decodeOps(json: json)
        writeQueue.async {
            Task { try? await backing.outboxAppend(swiftOps) }
        }
    }

    public func clearOutbox(opIds: [String]) {
        let remaining = loadOutbox().filter { !opIds.contains($0.opId) }
        let json = OpCodec.shared.encodeOps(ops: remaining)
        withLock { outboxJSON = json }
        let backing = self.backing
        writeQueue.async {
            Task { try? await backing.outboxRemove(opIds: opIds) }
        }
    }

    public func loadTombstones() -> [OrdoCore.Tombstone] {
        let json = withLock { tombstonesJSON }
        return OpCodec.shared.decodeTombstones(raw: json)
    }

    public func saveTombstones(list: [OrdoCore.Tombstone]) {
        let json = OpCodec.shared.encodeTombstones(list: list)
        withLock { tombstonesJSON = json }
        let backing = self.backing
        let swiftTombstones = OrdoCoreMapping.decodeTombstones(json: json)
        writeQueue.async {
            Task { try? await backing.tombstoneReplace(swiftTombstones) }
        }
    }

    public func kvGet(key: String) -> String? {
        withLock { kv[key] }
    }

    public func kvSet(key: String, value: String?) {
        withLock {
            if let value { kv[key] = value } else { kv.removeValue(forKey: key) }
        }
        let backing = self.backing
        writeQueue.async {
            Task { try? await backing.kvSet(key, value: value) }
        }
    }

    // MARK: 工具

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
