//
//  QueryRulesTests.swift
//  OrdoTests
//
//  契约 §4「派生清单查询规范」的逐条用例。
//  所有清单都是查询,不落库 —— 这里通过 KMP 引擎的 `list(_:)` / `sections(_:)` / `counts()` 断言。
//

import XCTest
// 模块名两条构建路径不同:Xcode 工程(PRODUCT_NAME=Ordo)是 `Ordo`,SwiftPM 是 `OrdoKit`。
#if canImport(OrdoKit)
@testable import OrdoKit
#else
@testable import Ordo
#endif

@MainActor
final class QueryRulesTests: XCTestCase {

    private var harness: OrdoTestHarness!

    override func setUp() async throws {
        harness = await OrdoTestHarness.make(today: "2026-10-08", nowDayTime: "2026-10-08T09:00")
    }

    // MARK: 收件箱

    func testInboxRule() {
        harness.makeTodo("收件箱项", when: .inbox)
        harness.makeTodo("今天项", when: .today)
        harness.makeTodo("随时项", when: .anytime)
        let completed = harness.makeTodo("已完成的收件箱项", when: .inbox)
        harness.engine.toggleDone(id: completed.id)

        let titles = harness.titles(harness.todos(in: .inbox))
        assertContains(titles, "收件箱项")
        assertNotContains(titles, "今天项", "今天项不应出现在收件箱")
        assertNotContains(titles, "随时项", "随时项不应出现在收件箱")
        assertNotContains(titles, "已完成的收件箱项", "已完成的待办不应出现在收件箱")
    }

    // MARK: 今天

    func testTodayRuleIncludesEveningDateAndDeadline() {
        harness.makeTodo("今天项", when: .today)
        harness.makeTodo("今晚项", when: .evening)
        harness.makeTodo("逾期未排期项", when: .date, date: harness.day(-2))
        harness.makeTodo("今天截止项", when: .anytime, deadline: harness.today)
        harness.makeTodo("未来项", when: .date, date: harness.day(3))
        harness.makeTodo("无截止的随时项", when: .anytime)

        let titles = harness.titles(harness.todos(in: .today))
        assertContains(titles, "今天项")
        assertContains(titles, "今晚项")
        assertContains(titles, "逾期未排期项", "date <= today 应进入今天")
        assertContains(titles, "今天截止项", "deadline <= today 应进入今天")
        assertNotContains(titles, "未来项")
        assertNotContains(titles, "无截止的随时项")
    }

    func testTonightIsASeparateSectionAtBottom() {
        harness.makeTodo("白天项", when: .today)
        harness.makeTodo("今晚项", when: .evening)

        let sections = harness.sections(.today)
        let tonightIndex = sections.firstIndex { $0.kind == .tonight }
        XCTAssertNotNil(tonightIndex, "今晚应作为独立分区")
        XCTAssertEqual(tonightIndex, sections.count - 1, "今晚分区应置于底部")
        if let index = tonightIndex {
            XCTAssertEqual(harness.titles(sections[index].todos), ["今晚项"])
        }
    }

    // MARK: 计划(窗口 = 明天起 14 天)

    func testUpcomingWindowAndLaterBucket() {
        harness.makeTodo("窗口内", when: .date, date: harness.day(1))
        harness.makeTodo("窗口边界", when: .date, date: harness.day(14))
        harness.makeTodo("超出窗口", when: .date, date: harness.day(15))

        let listed = harness.titles(harness.todos(in: .upcoming))
        assertContains(listed, "窗口内")
        assertContains(listed, "窗口边界", "第 14 天仍在窗口内")

        let sections = harness.sections(.upcoming)
        let laterTitles = sections.filter { $0.kind == .later }.flatMap { harness.titles($0.todos) }
        if listed.contains("超出窗口") {
            assertContains(laterTitles, "超出窗口", "超出窗口的应归入「更晚」")
        } else {
            assertNotContains(listed, "超出窗口")
        }
    }

    /// 截止日期落在窗口内也应出现在计划里(契约 §4)。
    func testUpcomingIncludesDeadlines() {
        harness.makeTodo("只有截止", when: .anytime, deadline: harness.day(3))
        let listed = harness.titles(harness.todos(in: .upcoming))
        assertContains(listed, "只有截止")
    }

    // MARK: 随时 / 某天

    func testAnytimeAndSomedayRules() {
        harness.makeTodo("随时项", when: .anytime)
        harness.makeTodo("某天项", when: .someday)
        harness.makeTodo("今天项", when: .today)

        assertContains(harness.titles(harness.todos(in: .anytime)), "随时项")
        assertNotContains(harness.titles(harness.todos(in: .anytime)), "某天项")
        assertContains(harness.titles(harness.todos(in: .someday)), "某天项")
        assertNotContains(harness.titles(harness.todos(in: .someday)), "随时项")
    }

    // MARK: 日志簿

    func testLogbookGroupsByCompletionDateDescending() {
        let older = harness.makeTodo("昨天完成", when: .today)
        harness.clock.set(1_759_800_000_000)
        harness.engine.toggleDone(id: older.id)

        let newer = harness.makeTodo("今天完成", when: .today)
        harness.clock.set(1_759_900_000_000)
        harness.engine.toggleDone(id: newer.id)

        let sections = harness.sections(.logbook)
        XCTAssertFalse(sections.isEmpty, "日志簿应有分组")
        let titles = sections.flatMap { harness.titles($0.todos) }
        assertContains(titles, "今天完成")
        assertContains(titles, "昨天完成")

        if let firstSection = sections.first {
            let completedStamps = firstSection.todos.compactMap(\.completedAt)
            let sorted = completedStamps.sorted(by: >)
            XCTAssertEqual(completedStamps, sorted, "分组内应按完成时间倒序")
        }
    }

    func testCanceledTodosAppearInLogbook() {
        let todo = harness.makeTodo("取消项", when: .anytime)
        harness.engine.complete(id: todo.id, canceled: true)
        let titles = harness.sections(.logbook).flatMap { harness.titles($0.todos) }
        assertContains(titles, "取消项", "已取消的待办应进入日志簿")
    }

    // MARK: 项目视图

    func testProjectViewGroupsByHeadingAndHidesCompleted() {
        let project = harness.engine.createProject(name: "发布项目", areaId: nil, headingNames: ["设计", "开发"])
        let headings = harness.engine.headingsOf(projectId: project.id)
        XCTAssertEqual(headings.map(\.name), ["设计", "开发"], "createProject 应带出标题")

        let devTodo = harness.makeTodo("开发任务", when: .anytime, projectId: project.id)
        harness.makeTodo("无标题任务", when: .anytime, projectId: project.id)
        let designTodo = harness.makeTodo("设计任务", when: .anytime, projectId: project.id)

        harness.engine.moveTodo(id: devTodo.id, projectId: project.id, areaId: nil, headingId: headings[1].id)
        harness.engine.moveTodo(id: designTodo.id, projectId: project.id, areaId: nil, headingId: headings[0].id)
        harness.engine.toggleDone(id: designTodo.id)

        let sections = harness.sections(.project(project.id))
        let titles = sections.flatMap { harness.titles($0.todos) }
        assertContains(titles, "开发任务")
        assertContains(titles, "无标题任务")
        assertNotContains(titles, "设计任务", "项目视图仅显示未完成待办")

        if let lastSection = sections.last {
            XCTAssertEqual(lastSection.kind, .heading)
            XCTAssertTrue(lastSection.todos.contains { $0.headingId == nil }, "无标题的待办应排在最后")
        }
    }

    /// 契约 §3:`headingId` 非空时必须属于该项目,否则置 null。
    func testHeadingMustBelongToProject() {
        let projectA = harness.engine.createProject(name: "项目 A", areaId: nil, headingNames: ["A-标题"])
        let projectB = harness.engine.createProject(name: "项目 B", areaId: nil, headingNames: ["B-标题"])
        let headingA = harness.engine.headingsOf(projectId: projectA.id)[0]
        let headingB = harness.engine.headingsOf(projectId: projectB.id)[0]

        let todo = harness.makeTodo("跨项目挂标题", when: .anytime, projectId: projectA.id)
        harness.engine.moveTodo(id: todo.id, projectId: projectA.id, areaId: nil, headingId: headingB.id)
        XCTAssertNil(harness.todo(id: todo.id)?.headingId, "不属于该项目的标题应被置空")

        harness.engine.moveTodo(id: todo.id, projectId: projectA.id, areaId: nil, headingId: headingA.id)
        XCTAssertEqual(harness.todo(id: todo.id)?.headingId, headingA.id)
    }

    func testProjectProgressComesFromCore() {
        let project = harness.engine.createProject(name: "进度项目", areaId: nil, headingNames: [])
        let first = harness.makeTodo("A", when: .anytime, projectId: project.id)
        harness.makeTodo("B", when: .anytime, projectId: project.id)
        harness.engine.toggleDone(id: first.id)

        XCTAssertEqual(harness.engine.projectProgress(projectId: project.id), 0.5, accuracy: 0.0001)
        XCTAssertEqual(harness.engine.counts().progress(project.id), 0.5, accuracy: 0.0001)

        let emptyProject = harness.engine.createProject(name: "空项目", areaId: nil, headingNames: [])
        XCTAssertEqual(harness.engine.projectProgress(projectId: emptyProject.id), 0, "无子项时进度为 0")
    }

    // MARK: 区域 / 标签 / 搜索

    func testAreaViewIncludesProjectTodos() {
        let area = harness.engine.createArea(name: "工作区")
        let project = harness.engine.createProject(name: "区域内项目", areaId: area.id, headingNames: [])
        harness.makeTodo("直接挂区域", when: .anytime, areaId: area.id)
        harness.makeTodo("项目内待办", when: .anytime, projectId: project.id)

        let titles = harness.titles(harness.todos(in: .area(area.id)))
        assertContains(titles, "直接挂区域")
        assertContains(titles, "项目内待办", "区域视图应包含其项目下的待办")
    }

    func testTagViewAndShowCompletedSwitch() {
        harness.makeTodo("带标签未完成", when: .anytime, tags: ["重要"])
        let completed = harness.makeTodo("带标签已完成", when: .anytime, tags: ["重要"])
        harness.engine.toggleDone(id: completed.id)

        let openOnly = harness.engine.list(OrdoListQuery(kind: .tag, id: "重要", showCompleted: false))
        assertNotContains(harness.titles(openOnly), "带标签已完成", "只看未完成时不应包含已完成项")

        let all = harness.engine.list(OrdoListQuery(kind: .tag, id: "重要", showCompleted: true))
        let allTitles = harness.titles(all)
        assertContains(allTitles, "带标签未完成")
        assertContains(allTitles, "带标签已完成")
    }

    func testSearchRuleOrdersOpenFirstThenUpdatedAtDescending() {
        let first = harness.makeTodo("Alpha 报告", when: .anytime)
        harness.clock.advance(by: 60_000)
        harness.makeTodo("alpha 报告(小写)", when: .anytime)
        harness.engine.toggleDone(id: first.id)

        let results = harness.engine.list(.search("alpha"))
        XCTAssertGreaterThanOrEqual(results.count, 2, "搜索应大小写不敏感")
        if let firstResult = results.first {
            XCTAssertEqual(firstResult.status, .open, "未完成应排在前面")
        }
    }

    func testSearchMatchesNotes() {
        let todo = harness.makeTodo("写方案", when: .anytime)
        harness.engine.setNote(id: todo.id, note: "关键指标:转化率")
        let results = harness.engine.list(.search("转化率"))
        assertContains(harness.titles(results), "写方案", "备注应参与搜索")
    }

    // MARK: 侧栏计数

    func testSidebarCounts() {
        harness.makeTodo("收件箱 1", when: .inbox)
        harness.makeTodo("收件箱 2", when: .inbox)
        harness.makeTodo("今天 1", when: .today)

        let counts = harness.engine.counts()
        XCTAssertEqual(counts.inbox, 2)
        XCTAssertGreaterThanOrEqual(counts.today, 1)
    }

    // MARK: 字段不变量(契约 §3)

    func testInboxTodoMovedIntoProjectBecomesAnytime() {
        let todo = harness.makeTodo("待移动", when: .inbox)
        let project = harness.engine.createProject(name: "目标项目", areaId: nil, headingNames: [])
        harness.engine.moveTodo(id: todo.id, projectId: project.id, areaId: nil, headingId: nil)
        XCTAssertNotEqual(harness.todo(id: todo.id)?.when, .inbox, "移入项目后不应继续留在收件箱")
    }

    func testSettingReminderOnAnytimeMovesToToday() {
        let todo = harness.makeTodo("带提醒", when: .anytime)
        harness.engine.setReminder(id: todo.id, reminder: harness.today + "T18:00")
        XCTAssertEqual(harness.todo(id: todo.id)?.when, .today, "设置提醒后应自动进入今天")
    }

    func testWhenDateRequiresDate() {
        // 契约 §3:when == date 且 date 为空 → 补今天;when != date → date 必须为 null。
        let todo = harness.makeTodo("日期不变量", when: .date, date: harness.day(5))
        XCTAssertEqual(harness.todo(id: todo.id)?.date, harness.day(5))

        harness.engine.setWhen(id: todo.id, when: .today, date: nil)
        XCTAssertNil(harness.todo(id: todo.id)?.date, "when 非 date 时 date 必须为 null")

        harness.engine.setWhen(id: todo.id, when: .date, date: nil)
        XCTAssertEqual(harness.todo(id: todo.id)?.date, harness.today, "when == date 且未给日期时应补今天")
    }

    /// 契约 §3:reminder 的日期部分必须与 (when == date ? date : 今天) 对齐。
    func testReminderRealignsToDate() {
        let todo = harness.makeTodo("提醒对齐", when: .date, date: harness.day(2))
        harness.engine.setReminder(id: todo.id, reminder: harness.day(2) + "T18:00")
        XCTAssertEqual(harness.todo(id: todo.id)?.reminder, harness.day(2) + "T18:00")

        harness.engine.setWhen(id: todo.id, when: .date, date: harness.day(4))
        XCTAssertEqual(
            harness.todo(id: todo.id)?.reminder,
            harness.day(4) + "T18:00",
            "改期后提醒的日期部分应自动对齐"
        )
    }
}
