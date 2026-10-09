//
//  RepeatEngineTests.swift
//  OrdoTests
//
//  契约 §6「重复规则引擎」的用例。
//
//  完成一个 repeat != null 的待办时:
//    1. 原实例:status=done、completedAt=now、repeat 保留;
//    2. 新实例:复制全部字段,id 重新生成,status=open、completedAt=null、
//       checklist[].done=false、createdAt=now;
//    3. 新 date:fixed → base = 原 date ?? 原 reminder 日期 ?? 今天;
//               afterCompletion → base = 今天;
//               daily +interval 天 / weekly +7×interval / monthly 月份+interval(溢出取当月最后一天)/ yearly 年份+interval。
//

import XCTest
@testable import OrdoKit

@MainActor
final class RepeatEngineTests: XCTestCase {

    private var harness: OrdoTestHarness!

    override func setUp() async throws {
        harness = await OrdoTestHarness.make(today: "2026-10-08", nowDayTime: "2026-10-08T09:00")
    }

    /// 取「完成之后新生成的那条」。
    private func nextInstance(of title: String) -> OrdoTodo? {
        harness.engine.snapshot.todos.first { $0.title == title && $0.status == .open }
    }

    private func complete(_ title: String) {
        guard let todo = harness.engine.snapshot.todos.first(where: { $0.title == title && $0.status == .open }) else {
            return XCTFail("找不到待办「\(title)」")
        }
        harness.engine.toggleDone(id: todo.id)
    }

    // MARK: 原实例与新实例

    func testCompletionKeepsRepeatOnOriginalInstance() {
        harness.makeTodo("每周复盘", when: .date, date: harness.today,
                         repeatRule: OrdoRepeatRule(freq: .weekly, interval: 1, mode: .fixed))
        complete("每周复盘")

        let originals = harness.engine.snapshot.todos.filter { $0.title == "每周复盘" && $0.status == .done }
        XCTAssertEqual(originals.count, 1, "应保留一条已完成的原实例")
        XCTAssertNotNil(originals.first?.completedAt, "原实例应有 completedAt")
        XCTAssertNotNil(originals.first?.repeatRule, "原实例应保留 repeat(用于日志簿展示)")
    }

    func testNewInstanceResetsState() {
        let source = harness.makeTodo("带清单的重复待办", when: .date, date: harness.today,
                                      repeatRule: OrdoRepeatRule(freq: .daily, interval: 1, mode: .fixed))
        harness.engine.addChecklistItem(todoId: source.id, title: "步骤一")
        harness.engine.addChecklistItem(todoId: source.id, title: "步骤二")
        if let item = harness.todo(id: source.id)?.checklist.first {
            harness.engine.toggleChecklistItem(todoId: source.id, itemId: item.id)
        }

        complete("带清单的重复待办")

        guard let next = nextInstance(of: "带清单的重复待办") else {
            return XCTFail("未生成下一次实例")
        }
        XCTAssertNotEqual(next.id, source.id, "新实例必须重新生成 id")
        XCTAssertEqual(next.status, .open)
        XCTAssertNil(next.completedAt, "新实例不应带完成时间")
        XCTAssertTrue(next.checklist.allSatisfy { !$0.done }, "新实例的清单项应全部重置为未完成")
        XCTAssertEqual(next.checklist.count, 2, "清单项应被复制")
    }

    // MARK: fixed 模式

    func testFixedDailyAddsIntervalDays() {
        harness.makeTodo("每日站会", when: .date, date: "2026-10-01",
                         repeatRule: OrdoRepeatRule(freq: .daily, interval: 1, mode: .fixed))
        complete("每日站会")
        XCTAssertEqual(nextInstance(of: "每日站会")?.date, "2026-10-02", "fixed 应基于原 date 递推")
    }

    func testFixedWeeklyAndInterval() {
        harness.makeTodo("每周复盘 2 周", when: .date, date: "2026-10-01",
                         repeatRule: OrdoRepeatRule(freq: .weekly, interval: 2, mode: .fixed))
        complete("每周复盘 2 周")
        XCTAssertEqual(nextInstance(of: "每周复盘 2 周")?.date, "2026-10-15", "weekly 应为 +7×interval 天")
    }

    func testFixedMonthlyHandlesMonthOverflow() {
        // 2026-01-31 + 1 个月 → 2026-02-28(取当月最后一天)
        harness.makeTodo("月度账单", when: .date, date: "2026-01-31",
                         repeatRule: OrdoRepeatRule(freq: .monthly, interval: 1, mode: .fixed))
        complete("月度账单")
        XCTAssertEqual(nextInstance(of: "月度账单")?.date, "2026-02-28", "月份溢出应取当月最后一天")
    }

    func testFixedYearly() {
        harness.makeTodo("年度体检", when: .date, date: "2026-03-15",
                         repeatRule: OrdoRepeatRule(freq: .yearly, interval: 1, mode: .fixed))
        complete("年度体检")
        XCTAssertEqual(nextInstance(of: "年度体检")?.date, "2027-03-15")
    }

    /// fixed 模式在「原 date 已过」时仍基于原 date 递推(不是今天)。
    func testFixedIgnoresToday() {
        harness.makeTodo("每月房租", when: .date, date: "2026-09-05",
                         repeatRule: OrdoRepeatRule(freq: .monthly, interval: 1, mode: .fixed))
        complete("每月房租")
        XCTAssertEqual(nextInstance(of: "每月房租")?.date, "2026-10-05", "fixed 不应以完成日为基准")
    }

    // MARK: afterCompletion 模式

    func testAfterCompletionUsesToday() {
        harness.makeTodo("每 3 天浇花", when: .date, date: "2026-09-01",
                         repeatRule: OrdoRepeatRule(freq: .daily, interval: 3, mode: .afterCompletion))
        complete("每 3 天浇花")
        XCTAssertEqual(nextInstance(of: "每 3 天浇花")?.date, harness.day(3), "afterCompletion 应以今天为基准")
    }

    func testAfterCompletionWeekly() {
        harness.makeTodo("每周回顾(完成日)", when: .date, date: "2026-09-01",
                         repeatRule: OrdoRepeatRule(freq: .weekly, interval: 1, mode: .afterCompletion))
        complete("每周回顾(完成日)")
        XCTAssertEqual(nextInstance(of: "每周回顾(完成日)")?.date, harness.day(7))
    }

    // MARK: 边界

    func testNonRepeatingTodoDoesNotSpawnInstance() {
        harness.makeTodo("一次性任务", when: .today)
        complete("一次性任务")
        XCTAssertNil(nextInstance(of: "一次性任务"), "非重复待办不应生成新实例")
    }

    /// 契约 §6:base = 原 date ?? 原 reminder 的日期 ?? 今天。
    /// 给无日期的待办设置重复时,核心会先把它落到具体日期(`setRepeat` 的行为)。
    func testRepeatingTodoWithoutDateUsesTodayAsBase() {
        harness.makeTodo("无日期的重复", when: .today,
                         repeatRule: OrdoRepeatRule(freq: .daily, interval: 1, mode: .fixed))
        complete("无日期的重复")
        XCTAssertEqual(nextInstance(of: "无日期的重复")?.date, harness.day(1))
    }

    func testNextInstanceKeepsTagsAndProject() {
        let project = harness.engine.createProject(name: "重复项目", areaId: nil, headingNames: [])
        harness.makeTodo("项目内重复", when: .date, date: harness.today, tags: ["重要"],
                         projectId: project.id,
                         repeatRule: OrdoRepeatRule(freq: .weekly, interval: 1, mode: .fixed))
        complete("项目内重复")
        let next = nextInstance(of: "项目内重复")
        XCTAssertEqual(next?.projectId, project.id, "新实例应保留项目归属")
        XCTAssertEqual(next?.tags, ["重要"], "新实例应保留标签")
    }

    func testLogbookShowsOriginalOnceCompleted() {
        harness.makeTodo("重复待办进日志", when: .date, date: harness.today,
                         repeatRule: OrdoRepeatRule(freq: .daily, interval: 1, mode: .fixed))
        complete("重复待办进日志")
        let logbook = harness.sections(.logbook).flatMap { harness.titles($0.todos) }
        assertContains(logbook, "重复待办进日志", "原实例应进入日志簿")
    }
}
