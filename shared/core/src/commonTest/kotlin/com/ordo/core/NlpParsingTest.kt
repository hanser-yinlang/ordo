package com.ordo.core

import com.ordo.core.model.When
import com.ordo.core.nlp.NaturalDateParser
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 中文自然语言解析测试 —— 逐条覆盖契约 §5。
 * 固定"今天"= 2026-10-08(周四),使断言与运行环境无关。
 */
class NlpParsingTest {

    private val today = "2026-10-08" // 周四
    private val now = "14:30"

    private fun parse(text: String) = NaturalDateParser.parse(text, today, now)

    @Test
    fun tomorrowWithTime() {
        val r = parse("明天 18:00 交季度报告 #重要")
        assertEquals("交季度报告", r.cleanTitle)
        assertEquals(When.DATE, r.`when`)
        assertEquals("2026-10-09", r.date)
        assertEquals("2026-10-09T18:00", r.reminder)
        assertEquals(listOf("重要"), r.tags)
    }

    @Test
    fun tonight() {
        val r = parse("今晚 读书")
        assertEquals(When.EVENING, r.`when`)
        assertNull(r.date)
        assertEquals("读书", r.cleanTitle)
    }

    @Test
    fun todayKeyword() {
        val r = parse("今天 写周报")
        assertEquals(When.TODAY, r.`when`)
        assertEquals("写周报", r.cleanTitle)
    }

    @Test
    fun dayAfterTomorrow() {
        assertEquals("2026-10-10", parse("后天 交材料").date)
        assertEquals("2026-10-11", parse("大后天 交材料").date)
    }

    @Test
    fun nDaysLater() {
        val r = parse("3天后 交作业")
        assertEquals("2026-10-11", r.date)
        assertEquals("交作业", r.cleanTitle)
    }

    @Test
    fun thisWeekFriday() {
        // 今天是周四,周五即明天
        assertEquals("2026-10-09", parse("周五 开会").date)
    }

    @Test
    fun nextWeekFriday() {
        assertEquals("2026-10-16", parse("下周五 复盘").date)
    }

    @Test
    fun absoluteChineseDate() {
        // 8月1日 已过 → 顺延到明年
        assertEquals("2027-08-01", parse("8月1日 交房租").date)
        assertEquals("2026-12-25", parse("12月25日 圣诞").date)
    }

    @Test
    fun absoluteISODate() {
        val r = parse("2026-11-03 体检")
        assertEquals("2026-11-03", r.date)
        assertEquals("体检", r.cleanTitle)
    }

    @Test
    fun monthOffset() {
        assertEquals("2026-11-08", parse("1个月后 体检").date)
        assertEquals("2026-10-22", parse("2周后 交方案").date)
    }

    @Test
    fun eveningTime() {
        val r = parse("晚上8点 给妈妈打电话")
        assertEquals("给妈妈打电话", r.cleanTitle)
        assertEquals(When.TODAY, r.`when`)
        assertEquals("2026-10-08T20:00", r.reminder)
    }

    @Test
    fun afternoonHalfPast() {
        val r = parse("下午3点半 开会")
        assertEquals("2026-10-08T15:30", r.reminder)
        assertEquals("开会", r.cleanTitle)
    }

    @Test
    fun plainClockTime() {
        val r = parse("18:00 交报告")
        assertEquals(When.TODAY, r.`when`)
        assertEquals("2026-10-08T18:00", r.reminder)
        assertEquals("交报告", r.cleanTitle)
    }

    @Test
    fun someday() {
        val r = parse("某天 学一门乐器")
        assertEquals(When.SOMEDAY, r.`when`)
        assertEquals("学一门乐器", r.cleanTitle)
    }

    @Test
    fun weekend() {
        // 2026-10-10 是周六
        assertEquals("2026-10-10", parse("周末 去爬山").date)
    }

    @Test
    fun multipleTags() {
        val r = parse("准备评审材料 #重要 #深度工作")
        assertEquals(setOf("重要", "深度工作"), r.tags.toSet())
        assertEquals("准备评审材料", r.cleanTitle)
    }

    @Test
    fun noDateNoTime() {
        val r = parse("写周报")
        assertNull(r.`when`)
        assertNull(r.reminder)
        assertEquals("写周报", r.cleanTitle)
        assertTrue(r.tags.isEmpty())
    }

    @Test
    fun timeWithoutDateGoesToToday() {
        val r = parse("明天 09:30 站会")
        assertEquals("2026-10-09T09:30", r.reminder)
        assertEquals(When.DATE, r.`when`)
    }
}
