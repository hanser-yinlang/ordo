package com.ordo.android

import com.ordo.android.TestSupport.NOW_HHMM
import com.ordo.android.TestSupport.TODAY
import com.ordo.core.model.When
import com.ordo.core.nlp.NaturalDateParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 契约 §5「中文自然语言解析规范」逐条验收。
 *
 * 调用共享核心的 [NaturalDateParser]（纯函数），固定 today = 2026-10-08（周四）、nowTime = 09:00，
 * 因此断言与真实时钟无关。
 */
class NlpParsingTest {

    private fun parse(input: String) = NaturalDateParser.parse(
        input = input,
        today = TODAY,
        nowTime = NOW_HHMM,
    )

    /* ------------------------------- 关键词 ------------------------------- */

    @Test
    fun `今天 → when=today 并清理标题`() {
        val r = parse("今天 写周报")
        assertEquals(When.TODAY, r.`when`)
        assertNull(r.date)
        assertEquals("写周报", r.cleanTitle)
    }

    @Test
    fun `今晚 → when=evening`() {
        val r = parse("今晚 读三章")
        assertEquals(When.EVENING, r.`when`)
        assertEquals("读三章", r.cleanTitle)
    }

    @Test
    fun `今天晚上 也识别为 evening`() {
        assertEquals(When.EVENING, parse("今天晚上 散步").`when`)
    }

    @Test
    fun `明天 → date 为次日`() {
        val r = parse("明天 交报告")
        assertEquals(When.DATE, r.`when`)
        assertEquals("2026-10-09", r.date)
    }

    @Test
    fun `后天 → +2`() {
        assertEquals("2026-10-10", parse("后天 体检").date)
    }

    @Test
    fun `大后天 → +3（不能被子串 后天 抢先匹配）`() {
        assertEquals("2026-10-11", parse("大后天 出差").date)
    }

    /* ------------------------------- 相对日期 ------------------------------- */

    @Test
    fun `3天后 → +3`() {
        assertEquals("2026-10-11", parse("3天后 复盘").date)
    }

    @Test
    fun `2周后 → +14`() {
        assertEquals("2026-10-22", parse("2周后 交房租").date)
    }

    @Test
    fun `1个月后 → 月份 +1`() {
        assertEquals("2026-11-08", parse("1个月后 续费").date)
    }

    /* ------------------------------- 绝对日期 ------------------------------- */

    @Test
    fun `2026-10-09 → 直接采用`() {
        assertEquals("2026-10-09", parse("2026-10-09 上线").date)
    }

    @Test
    fun `10月9日 与 10月9号`() {
        assertEquals("2026-10-09", parse("10月9日 上线").date)
        assertEquals("2026-10-09", parse("10月9号 上线").date)
    }

    @Test
    fun `10-9 → 今年 10 月 9 日`() {
        assertEquals("2026-10-09", parse("10-9 上线").date)
    }

    @Test
    fun `已过去的月日自动顺延到明年`() {
        // 1月5日 在上半年已过 → 2027-01-05
        assertEquals("2027-01-05", parse("1月5日 年会").date)
    }

    /* ------------------------------- 星期 ------------------------------- */

    @Test
    fun `周五 → 本周内的周五（基准日是周四，即次日）`() {
        assertEquals("2026-10-09", parse("周五 交周报").date)
    }

    @Test
    fun `周内已过的星期顺延到下周`() {
        // 基准日周四，「周三」已过 → 下周三 2026-10-14
        assertEquals("2026-10-14", parse("周三 复盘").date)
    }

    @Test
    fun `下周五 → 周偏移 +1`() {
        assertEquals("2026-10-16", parse("下周五 交周报").date)
    }

    @Test
    fun `下下周三 → 周偏移 +2`() {
        // core 语义：下下的周偏移量为 3（"下"的个数 + 1）
        assertEquals("2026-10-28", parse("下下周三 评审").date)
    }

    @Test
    fun `周末 → 最近的周六`() {
        assertEquals("2026-10-10", parse("周末 爬山").date)
    }

    @Test
    fun `某天 → when=someday`() {
        val r = parse("某天 学 Rust")
        assertEquals(When.SOMEDAY, r.`when`)
        assertNull(r.date)
    }

    /* ------------------------------- 时间 / 提醒 ------------------------------- */

    @Test
    fun `18 点整 → 今天 18 点提醒，且 when 提升为 today`() {
        val r = parse("18:00 开会")
        assertEquals(When.TODAY, r.`when`)
        assertNull(r.date)
        assertEquals("2026-10-08T18:00", r.reminder)
        assertEquals("开会", r.cleanTitle)
    }

    @Test
    fun `18点 与 18点半`() {
        assertEquals("2026-10-08T18:00", parse("18点 开会").reminder)
        assertEquals("2026-10-08T18:30", parse("18点半 开会").reminder)
    }

    @Test
    fun `下午3点半 → 15 点 30 分`() {
        assertEquals("2026-10-08T15:30", parse("下午3点半 取快递").reminder)
    }

    @Test
    fun `晚上8点 → 20 点`() {
        assertEquals("2026-10-08T20:00", parse("晚上8点 给妈妈打电话").reminder)
    }

    @Test
    fun `8pm → 20 点`() {
        assertEquals("2026-10-08T20:00", parse("8pm 站会").reminder)
    }

    @Test
    fun `凌晨12点 → 0 点`() {
        assertEquals("2026-10-08T00:00", parse("凌晨12点 值夜班").reminder)
    }

    @Test
    fun `有日期时提醒落在该日期上`() {
        val r = parse("明天 09:30 面试")
        assertEquals(When.DATE, r.`when`)
        assertEquals("2026-10-09", r.date)
        assertEquals("2026-10-09T09:30", r.reminder)
        assertEquals("面试", r.cleanTitle)
    }

    /* ------------------------------- 标签 ------------------------------- */

    @Test
    fun `标签可多个且从标题中移除`() {
        val r = parse("#重要 #紧急 交报告")
        assertTrue(r.tags.contains("重要"))
        assertTrue(r.tags.contains("紧急"))
        assertEquals("交报告", r.cleanTitle)
    }

    /* ------------------------------- 综合 ------------------------------- */

    @Test
    fun `综合用例 明天 18 00 交季度报告 重要`() {
        val r = parse("明天 18:00 交季度报告 #重要")
        assertEquals("交季度报告", r.cleanTitle)
        assertEquals(When.DATE, r.`when`)
        assertEquals("2026-10-09", r.date)
        assertEquals("2026-10-09T18:00", r.reminder)
        assertTrue(r.tags.contains("重要"))
    }

    @Test
    fun `没有日期信息时 when 与 date 都为空`() {
        val r = parse("买牛奶")
        assertNull(r.`when`)
        assertNull(r.date)
        assertNull(r.reminder)
        assertEquals("买牛奶", r.cleanTitle)
    }
}
