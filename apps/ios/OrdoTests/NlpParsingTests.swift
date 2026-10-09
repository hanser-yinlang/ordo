//
//  NlpParsingTests.swift
//  OrdoTests
//
//  契约 §5「中文自然语言解析规范(NLP v1)」的逐条用例。
//
//  解析器由 KMP `NaturalDateParser` 提供(经 `OrdoCoreNaturalLanguageParser` 桥接),
//  Swift 侧只断言输出,不复制规则。
//

import XCTest
@testable import OrdoKit

@MainActor
final class NlpParsingTests: XCTestCase {

    private var harness: OrdoTestHarness!

    /// 固定「今天」为 2026-10-08(周四),消除运行日期的干扰。
    private let fixedToday = "2026-10-08"

    override func setUp() async throws {
        harness = await OrdoTestHarness.make(today: fixedToday, nowDayTime: "2026-10-08T09:00")
    }

    private func parse(_ input: String) -> OrdoParsedInput {
        harness.parser.parse(input, today: fixedToday, now: "2026-10-08T09:00")
    }

    // MARK: §5 关键词日期

    func testTodayKeywords() {
        for text in ["今天 写周报", "今日写周报"] {
            let result = parse(text)
            XCTAssertEqual(result.when, .today, "「\(text)」应解析为今天")
            XCTAssertEqual(result.cleanTitle, "写周报")
        }
    }

    func testEveningKeywords() {
        for text in ["今晚 读书", "今天晚上读书"] {
            let result = parse(text)
            XCTAssertEqual(result.when, .evening, "「\(text)」应解析为今晚")
            XCTAssertEqual(result.cleanTitle, "读书")
        }
    }

    func testRelativeDays() {
        let cases: [(String, Int)] = [
            ("明天 交报告", 1),
            ("明日交报告", 1),
            ("后天 交报告", 2),
            ("大后天 交报告", 3),
            ("3天后 交报告", 3)
        ]
        for (text, offset) in cases {
            let result = parse(text)
            XCTAssertEqual(result.when, .date, "「\(text)」应解析为具体日期")
            XCTAssertEqual(result.date, harness.day(offset), "「\(text)」日期应为 +\(offset) 天")
            XCTAssertEqual(result.cleanTitle, "交报告")
        }
    }

    func testRelativeWeeks() {
        for text in ["2周后 复盘", "2个星期后 复盘"] {
            let result = parse(text)
            XCTAssertEqual(result.when, .date)
            XCTAssertEqual(result.date, harness.day(14), "「\(text)」应为 +14 天")
        }
    }

    func testRelativeMonths() {
        let result = parse("3个月后 体检")
        XCTAssertEqual(result.when, .date)
        // 2026-10-08 + 3 个月 = 2027-01-08
        XCTAssertEqual(result.date, "2027-01-08")
    }

    // MARK: §5 绝对日期

    func testAbsoluteDates() {
        let cases: [(String, String)] = [
            ("2026-10-09 交报告", "2026-10-09"),
            ("10月9日 交报告", "2026-10-09"),
            ("10月9号 交报告", "2026-10-09"),
            ("10/9 交报告", "2026-10-09")
        ]
        for (text, expected) in cases {
            let result = parse(text)
            XCTAssertEqual(result.when, .date, "「\(text)」应为具体日期")
            XCTAssertEqual(result.date, expected, "「\(text)」日期不符")
        }
    }

    /// 绝对日期优先级高于相对天(§5 冲突优先级)。
    func testAbsoluteDateBeatsRelativeDay() {
        let result = parse("明天 2026-12-25 圣诞")
        XCTAssertEqual(result.date, "2026-12-25", "绝对日期应优先于「明天」")
    }

    // MARK: §5 星期与周末

    func testWeekdayRules() {
        // 2026-10-08 是周四;「周五」= 10-09(本周内未过)
        XCTAssertEqual(parse("周五 开会").date, "2026-10-09")
        // 「周二」已过 → 下周二 10-13
        XCTAssertEqual(parse("周二 开会").date, "2026-10-13")
        // 「下周五」→ 10-16
        XCTAssertEqual(parse("下周五 开会").date, "2026-10-16")
        // 「下下周三」→ 10-21
        XCTAssertEqual(parse("下下周三 开会").date, "2026-10-21")
    }

    func testWeekendRule() {
        // 最近的周六 = 2026-10-10
        for text in ["周末 爬山", "本周末爬山", "这个周末爬山"] {
            XCTAssertEqual(parse(text).date, "2026-10-10", "「\(text)」应为最近的周六")
        }
    }

    // MARK: §5 暂缓

    func testSomedayKeywords() {
        for text in ["某天 学 Rust", "将来某天学 Rust", "有空再说学 Rust"] {
            XCTAssertEqual(parse(text).when, .someday, "「\(text)」应为某天")
        }
    }

    // MARK: §5 时间(提醒)

    func testTimeFormats() {
        let cases: [(String, String)] = [
            ("18:00 交报告", "2026-10-08T18:00"),
            ("18点 交报告", "2026-10-08T18:00"),
            ("18点半 交报告", "2026-10-08T18:30"),
            ("下午3点半 交报告", "2026-10-08T15:30"),
            ("晚上8点 交报告", "2026-10-08T20:00"),
            ("8pm 交报告", "2026-10-08T20:00")
        ]
        for (text, expected) in cases {
            let result = parse(text)
            XCTAssertEqual(result.reminder, expected, "「\(text)」提醒时间不符")
        }
    }

    /// §5:时间无日期信息时 `when = today`。
    func testTimeWithoutDateImpliesToday() {
        let result = parse("18:00 交报告")
        XCTAssertEqual(result.when, .today, "只给时间时应落到今天")
        XCTAssertEqual(result.cleanTitle, "交报告")
    }

    /// 时间 + 日期:提醒的日期部分取解析出的 date。
    func testTimeWithDateUsesParsedDate() {
        let result = parse("明天 18:00 交季度报告")
        XCTAssertEqual(result.when, .date)
        XCTAssertEqual(result.date, "2026-10-09")
        XCTAssertEqual(result.reminder, "2026-10-09T18:00")
        XCTAssertEqual(result.cleanTitle, "交季度报告")
    }

    /// §5 时段换算:凌晨 12 点 → 0 点;中午 → 12 点。
    func testPeriodConversion() {
        XCTAssertEqual(parse("凌晨12点 值班").reminder, "2026-10-08T00:00")
        XCTAssertEqual(parse("中午12点 吃饭").reminder, "2026-10-08T12:00")
        XCTAssertEqual(parse("上午9点 站会").reminder, "2026-10-08T09:00")
    }

    // MARK: §5 标签与清理

    func testTagsAreExtractedAndTitleCleaned() {
        let result = parse("明天 18:00 交季度报告 #重要 #深度工作")
        XCTAssertEqual(Set(result.tags), Set(["重要", "深度工作"]))
        XCTAssertEqual(result.cleanTitle, "交季度报告")
        XCTAssertFalse(result.cleanTitle.contains("#"), "标签应从标题中移除")
    }

    func testTitleCleanupCollapsesWhitespaceAndPunctuation() {
        let result = parse("  明天   交报告 ,  ")
        XCTAssertEqual(result.cleanTitle, "交报告")
    }

    // MARK: §5 冲突优先级

    func testPriorityOrder() {
        // 相对月 > 相对天
        XCTAssertEqual(parse("明天 2个月后 复诊").date, "2026-12-08")
        // 相对周 > 相对天
        XCTAssertEqual(parse("明天 2周后 复诊").date, "2026-10-22")
        // 关键词:今晚 > 今天
        XCTAssertEqual(parse("今天 今晚 读书").when, .evening)
    }

    // MARK: 与引擎联动

    /// 输入 → 待办字段的端到端落库检查(契约 §4 + §5)。
    /// 注意:Kotlin `createTodo(title, opts)` **内部**会先跑一遍 NLP,
    /// 因此这里直接传原文,不预先解析 —— 这正是 App 里快加号的行为。
    func testRawTitleIsParsedByEngine() {
        let created = harness.engine.createTodo(title: "明天 18:00 交季度报告 #重要", options: .none)
        let todo = harness.todo(id: created.id)
        XCTAssertEqual(todo?.title, "交季度报告", "标题里的日期/时间/标签应被剥离")
        XCTAssertEqual(todo?.when, .date)
        XCTAssertEqual(todo?.date, harness.day(1))
        XCTAssertEqual(todo?.reminder, harness.day(1) + "T18:00", "时间片段应生成提醒")
        XCTAssertEqual(todo?.tags, ["重要"])
    }

    /// 解析结果与 TodoOptions 的合并规则:显式 opts 只在标题里没有信息时生效。
    func testExplicitOptionsAreFallbackOnly() {
        let explicit = harness.engine.createTodo(
            title: "写周报",
            options: OrdoTodoOptions(when: .someday)
        )
        XCTAssertEqual(harness.todo(id: explicit.id)?.when, .someday, "标题无日期信息时应采用显式 when")

        let parsed = harness.engine.createTodo(
            title: "明天 写周报",
            options: OrdoTodoOptions(when: .someday)
        )
        XCTAssertEqual(harness.todo(id: parsed.id)?.when, .date, "标题里的日期信息优先于显式 when")
    }
}
