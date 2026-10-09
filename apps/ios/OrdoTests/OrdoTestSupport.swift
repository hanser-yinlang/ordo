//
//  OrdoTestSupport.swift
//  OrdoTests
//
//  测试基础设施(已对齐真实 KMP 核心 API):
//  - `OrdoFixedClock`:`OrdoClock.nowMillis()` 可预测;
//  - `OrdoSeededUUIDProvider`:递增实体 id;
//  - `OrdoTestHarness`:内存存储 → 预加载镜像 → `OrdoCoreBridge.make(...)` 组装引擎。
//
//  ⚠️ 这些测试**通过 `OrdoCoreBridge` 驱动 KMP 共享核心**验证契约 §4/§5/§6/§7.3,
//     不在 Swift 侧重复实现业务规则。因此必须先执行:
//        cd shared/core && ./gradlew :shared:core:assembleOrdoCoreXCFramework
//     否则 OrdoCore 模块不存在,测试无法编译(详见 README)。
//

import Foundation
import XCTest
@testable import OrdoKit

// MARK: - 可控时钟与 id

/// 固定时钟:测试里显式推进时间,保证 clientTs / completedAt 可预测。
final class OrdoFixedClock: OrdoClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int64

    init(millis: Int64 = 1_759_900_000_000) {
        self.current = millis
    }

    func nowMillis() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by millis: Int64) {
        lock.lock()
        current += millis
        lock.unlock()
    }

    func set(_ millis: Int64) {
        lock.lock()
        current = millis
        lock.unlock()
    }
}

/// 递增 id,便于断言(实体 id 形如 `id-1`)。
final class OrdoSeededUUIDProvider: OrdoUUIDProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var entityCounter = 0
    private var opCounter = 0

    func newEntityId() -> String {
        lock.lock()
        defer { lock.unlock() }
        entityCounter += 1
        return "id-\(entityCounter)"
    }

    func newOpId() -> String {
        lock.lock()
        defer { lock.unlock() }
        opCounter += 1
        return "op-\(opCounter)"
    }

    func newDeviceId() -> String { "dev-test" }
}

// MARK: - 测试装配

/// 一个测试用例的完整环境(内存存储 + KMP 引擎)。
@MainActor
final class OrdoTestHarness {

    let storage: OrdoMemoryStorage
    let engine: OrdoCoreBridge
    let parser: OrdoNaturalLanguageParser
    let clock: OrdoFixedClock
    let uuid: OrdoSeededUUIDProvider
    let today: String
    let nowDayTime: String

    private init(
        storage: OrdoMemoryStorage,
        engine: OrdoCoreBridge,
        clock: OrdoFixedClock,
        uuid: OrdoSeededUUIDProvider,
        today: String,
        nowDayTime: String
    ) {
        self.storage = storage
        self.engine = engine
        self.parser = OrdoCoreNaturalLanguageParser()
        self.clock = clock
        self.uuid = uuid
        self.today = today
        self.nowDayTime = nowDayTime
    }

    /// 组装(必须先预加载存储镜像,再构造引擎 —— 与 App 的启动路径一致)。
    static func make(today: String = "2026-10-08", nowDayTime: String? = nil) async -> OrdoTestHarness {
        let storage = OrdoMemoryStorage()
        let clock = OrdoFixedClock()
        let uuid = OrdoSeededUUIDProvider()
        let engine = await OrdoCoreBridge.make(storage: storage, clock: clock, uuid: uuid)
        return OrdoTestHarness(
            storage: storage,
            engine: engine,
            clock: clock,
            uuid: uuid,
            today: today,
            nowDayTime: nowDayTime ?? (today + "T09:00")
        )
    }

    /// 相对今天偏移若干天的 ISO 日期。
    func day(_ offset: Int) -> String {
        OrdoSeedData.shift(today, by: offset)
    }

    // MARK: 造数据(全部走核心 API,不在 Swift 侧自造规则)

    /// 新建一条待办。
    /// 注意 Kotlin `TodoOptions` 里没有 reminder / deadline,
    /// 因此它们通过 `setDeadline` / `setReminder` 设置(与 App 的交互路径一致)。
    @discardableResult
    func makeTodo(
        _ title: String,
        when: OrdoWhen = .inbox,
        date: String? = nil,
        deadline: String? = nil,
        reminder: String? = nil,
        tags: [String] = [],
        projectId: String? = nil,
        areaId: String? = nil,
        headingId: String? = nil,
        repeatRule: OrdoRepeatRule? = nil
    ) -> OrdoTodo {
        let created = engine.createTodo(
            title: title,
            options: OrdoTodoOptions(
                when: when,
                date: date,
                projectId: projectId,
                areaId: areaId,
                headingId: headingId,
                tags: tags
            )
        )
        if let deadline { engine.setDeadline(id: created.id, date: deadline) }
        if let reminder { engine.setReminder(id: created.id, reminder: reminder) }
        if let repeatRule { engine.setRepeat(id: created.id, rule: repeatRule) }
        return engine.todo(id: created.id) ?? created
    }

    func todos(in kind: OrdoListKind) -> [OrdoTodo] {
        engine.list(OrdoListQuery(kind: kind))
    }

    func sections(_ kind: OrdoListKind) -> [OrdoListSection] {
        engine.sections(OrdoListQuery(kind: kind))
    }

    func todo(id: String) -> OrdoTodo? {
        engine.todo(id: id)
    }

    func titles(_ list: [OrdoTodo]) -> [String] {
        list.map(\.title)
    }

    /// 等待写回落盘(镜像 → SwiftData;内存实现下用于断言持久化内容)。
    func flush() async {
        await engine.flushStorage()
    }
}

// MARK: - 断言辅助

extension XCTestCase {

    /// 断言集合包含某标题(给出可读失败信息)。
    func assertContains(
        _ titles: [String],
        _ expected: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            titles.contains(expected),
            message.isEmpty ? "期望包含「\(expected)」,实际:\(titles)" : "\(message);实际:\(titles)",
            file: file,
            line: line
        )
    }

    func assertNotContains(
        _ titles: [String],
        _ unexpected: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            titles.contains(unexpected),
            message.isEmpty ? "不应包含「\(unexpected)」,实际:\(titles)" : "\(message);实际:\(titles)",
            file: file,
            line: line
        )
    }
}
