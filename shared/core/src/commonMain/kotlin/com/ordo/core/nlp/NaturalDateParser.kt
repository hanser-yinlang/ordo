package com.ordo.core.nlp

import com.ordo.core.model.When
import com.ordo.core.util.OrdoDate

/** 解析结果(契约 §5) */
data class NlpResult(
    /** 去掉日期/时间/标签片段后的干净标题 */
    val cleanTitle: String,
    val `when`: When?,
    val date: String?,
    /** `YYYY-MM-DDTHH:mm`,由"时间片段 + 日期(缺省今天)"组合而成 */
    val reminder: String?,
    val tags: List<String>
)

/**
 * 中文自然语言解析器(契约 §5)。
 *
 * 优先级:绝对日期 > 相对月 > 相对周 > 相对天 > 关键词(今晚 > 今天 > 明天 …)> 时间。
 * 纯函数:输入文本与"今天/当前时刻",输出结构;便于四端与测试使用同一套行为。
 */
object NaturalDateParser {

    private val TAG_RE = Regex("#([^\\s#]+)")
    private val ABS_FULL_RE = Regex("(\\d{4})[-/.](\\d{1,2})[-/.](\\d{1,2})")
    private val ABS_MD_CN_RE = Regex("(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*[日号]")
    private val ABS_MD_SLASH_RE = Regex("(?:^|[^\\d])(\\d{1,2})[/-](\\d{1,2})(?![\\d])")
    private val N_MONTH_RE = Regex("(\\d{1,3})\\s*个?\\s*月\\s*(?:之?后|以后|后)")
    private val N_WEEK_RE = Regex("(\\d{1,3})\\s*(?:个)?\\s*(?:星期|周|礼拜)\\s*(?:之?后|以后|后)")
    private val N_DAY_RE = Regex("(\\d{1,3})\\s*天\\s*(?:之?后|以后|后)")
    private val NEXT_N_WEEK_RE = Regex("(下+)(?:周|星期|礼拜)([一二三四五六日天])")
    private val THIS_WEEK_RE = Regex("(?:这|本)?(?:周|星期|礼拜)([一二三四五六日天])")
    private val NEXT_WEEK_RE = Regex("(下周|下个?星期|下个?礼拜)(?![一二三四五六日天])")
    private val WEEKEND_RE = Regex("(这个?周末|本周末|周末)")
    private val TONIGHT_RE = Regex("(今天晚上|今晚|今夜晚些时候|今晚稍后)")
    private val TODAY_RE = Regex("(今天|今日)")
    private val TOMORROW_RE = Regex("(明天|明日)")
    private val DAY_AFTER_RE = Regex("(后天)")
    private val THREE_DAYS_RE = Regex("(大后天)")
    private val SOMEDAY_RE = Regex("(某天|将来某天|有空再说)")

    private val TIME_HM_RE = Regex("(\\d{1,2})\\s*[:：]\\s*(\\d{2})")
    private val TIME_CN_RE = Regex("(\\d{1,2})\\s*[点時时]\\s*(半|\\d{1,2}\\s*分?)?")
    private val TIME_AMPM_RE = Regex("(\\d{1,2})\\s*(am|pm|AM|PM)")
    private val PERIOD_RE = Regex("(凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|夜里|夜晚)\\s*$")

    private val WEEKDAY_MAP = mapOf(
        '一' to 1, '二' to 2, '三' to 3, '四' to 4, '五' to 5, '六' to 6, '日' to 0, '天' to 0
    )

    fun parse(
        input: String,
        today: String = OrdoDate.todayISO(),
        nowTime: String = OrdoDate.nowHHmm()
    ): NlpResult {
        val text = input
        val cuts = ArrayList<String>()
        val tags = ArrayList<String>()

        // 1) 标签
        TAG_RE.findAll(text).forEach { m ->
            val name = m.groupValues[1]
            if (name.isNotEmpty() && !tags.contains(name)) tags.add(name)
            cuts.add(m.value)
        }

        // 2) 时间(提醒)
        val timeMatch = matchTime(text)
        if (timeMatch != null) cuts.addAll(timeMatch.cutFragments)

        // 3) 日期(按优先级)
        val dateMatch = matchDate(text, today)
        if (dateMatch != null) cuts.addAll(dateMatch.cutFragments)

        // 4) 组合 `when` / date / reminder
        var `when`: When? = dateMatch?.`when`
        var date: String? = dateMatch?.date
        var reminder: String? = null

        if (timeMatch != null) {
            val base = `when`?.let { if (it == When.DATE) (date ?: today) else today } ?: today
            reminder = OrdoDate.dateTime(base, timeMatch.time)
            if (`when` == null || `when` == When.INBOX || `when` == When.ANYTIME || `when` == When.SOMEDAY) {
                `when` = When.TODAY
                date = null
            }
        }

        // 5) 清理标题
        var clean = text
        cuts.forEach { fragment ->
            if (fragment.isNotEmpty()) clean = clean.replace(fragment, " ")
        }
        clean = clean.replace(Regex("\\s{2,}"), " ")
            .trim()
            .trim(',', '，', '、', ':', '：', '-', ';', ';')

        return NlpResult(clean, `when`, date, reminder, tags)
    }

    // ---------------------------------------------------------------- 时间

    private class TimeMatch(val time: String, val cutFragments: List<String>)

    private fun matchTime(text: String): TimeMatch? {
        var matched: String? = null
        var hour = -1
        var minute = 0

        val hm = TIME_HM_RE.find(text)
        val cn = TIME_CN_RE.find(text)
        val ampm = TIME_AMPM_RE.find(text)

        when {
            hm != null -> {
                matched = hm.value
                hour = hm.groupValues[1].toIntOrNull() ?: return null
                minute = hm.groupValues[2].toIntOrNull() ?: 0
            }
            cn != null -> {
                matched = cn.value
                hour = cn.groupValues[1].toIntOrNull() ?: return null
                val suffix = cn.groupValues[2].trim()
                minute = when {
                    suffix == "半" -> 30
                    suffix.isEmpty() -> 0
                    else -> suffix.filter { it.isDigit() }.toIntOrNull() ?: 0
                }
            }
            ampm != null -> {
                matched = ampm.value
                val raw = ampm.groupValues[1].toIntOrNull() ?: return null
                hour = raw % 12
                if (ampm.groupValues[2].lowercase() == "pm") hour += 12
            }
        }
        if (matched == null || hour < 0) return null

        val fragments = arrayListOf(matched)
        val at = text.indexOf(matched)
        if (at > 0) {
            val before = text.substring(0, at)
            val period = PERIOD_RE.find(before)
            if (period != null) {
                val word = period.groupValues[1]
                fragments.add(word)
                when {
                    word == "中午" && hour < 12 -> hour = 12
                    word == "凌晨" && hour == 12 -> hour = 0
                    (word == "下午" || word == "傍晚" || word == "晚上" || word == "夜里" || word == "夜晚") && hour < 12 -> hour += 12
                }
            }
        }
        if (hour !in 0..23 || minute !in 0..59) return null
        return TimeMatch(OrdoDate.formatTime(hour, minute), fragments)
    }

    // ---------------------------------------------------------------- 日期

    private class DateMatch(val `when`: When, val date: String?, val cutFragments: List<String>)

    private fun matchDate(text: String, today: String): DateMatch? {
        ABS_FULL_RE.find(text)?.let { m ->
            val iso = OrdoDate.format(
                m.groupValues[1].toInt(),
                m.groupValues[2].toInt(),
                m.groupValues[3].toInt()
            )
            if (OrdoDate.isValidISO(iso)) return DateMatch(When.DATE, iso, listOf(m.value))
        }

        ABS_MD_CN_RE.find(text)?.let { m ->
            val todayYear = OrdoDate.parseISO(today)?.get(0) ?: 1970
            val month = m.groupValues[1].toInt()
            val day = m.groupValues[2].toInt()
            var year = todayYear
            if (month !in 1..12) return@let
            var iso = safeISO(year, month, day) ?: return@let
            if (iso < today) {
                year += 1
                iso = safeISO(year, month, day) ?: return@let
            }
            return DateMatch(When.DATE, iso, listOf(m.value))
        }

        ABS_MD_SLASH_RE.find(text)?.let { m ->
            val todayYear = OrdoDate.parseISO(today)?.get(0) ?: 1970
            val month = m.groupValues[1].toInt()
            val day = m.groupValues[2].toInt()
            if (month !in 1..12) return@let
            var iso = safeISO(todayYear, month, day) ?: return@let
            if (iso < today) iso = safeISO(todayYear + 1, month, day) ?: return@let
            return DateMatch(When.DATE, iso, listOf(m.value.trimStart('/', '-')))
        }

        N_MONTH_RE.find(text)?.let { m ->
            val n = m.groupValues[1].toIntOrNull() ?: return@let
            return DateMatch(When.DATE, OrdoDate.plusMonths(today, n), listOf(m.value))
        }

        N_WEEK_RE.find(text)?.let { m ->
            val n = m.groupValues[1].toIntOrNull() ?: return@let
            return DateMatch(When.DATE, OrdoDate.plusDays(today, n * 7), listOf(m.value))
        }

        N_DAY_RE.find(text)?.let { m ->
            val n = m.groupValues[1].toIntOrNull() ?: return@let
            return DateMatch(When.DATE, OrdoDate.plusDays(today, n), listOf(m.value))
        }

        NEXT_N_WEEK_RE.find(text)?.let { m ->
            val weeks = m.groupValues[1].length + 1
            val target = WEEKDAY_MAP[m.groupValues[2][0]] ?: 1
            return DateMatch(When.DATE, nextWeekday(today, weeks, target), listOf(m.value))
        }

        NEXT_WEEK_RE.find(text)?.let { m ->
            return DateMatch(When.DATE, nextWeekday(today, 2, 1), listOf(m.value))
        }

        WEEKEND_RE.find(text)?.let { m ->
            val dow = OrdoDate.dayOfWeek(today)
            var delta = (6 - dow + 7) % 7
            if (delta == 0) delta = 7
            return DateMatch(When.DATE, OrdoDate.plusDays(today, delta), listOf(m.value))
        }

        THIS_WEEK_RE.find(text)?.let { m ->
            val target = WEEKDAY_MAP[m.groupValues[1][0]] ?: 1
            return DateMatch(When.DATE, nextWeekday(today, 1, target), listOf(m.value))
        }

        TONIGHT_RE.find(text)?.let { m -> return DateMatch(When.EVENING, null, listOf(m.value)) }
        SOMEDAY_RE.find(text)?.let { m -> return DateMatch(When.SOMEDAY, null, listOf(m.value)) }
        TOMORROW_RE.find(text)?.let { m -> return DateMatch(When.DATE, OrdoDate.plusDays(today, 1), listOf(m.value)) }
        // 「大后天」必须早于「后天」判断,否则会被子串抢先匹配成 +2 天
        THREE_DAYS_RE.find(text)?.let { m -> return DateMatch(When.DATE, OrdoDate.plusDays(today, 3), listOf(m.value)) }
        DAY_AFTER_RE.find(text)?.let { m -> return DateMatch(When.DATE, OrdoDate.plusDays(today, 2), listOf(m.value)) }
        TODAY_RE.find(text)?.let { m -> return DateMatch(When.TODAY, null, listOf(m.value)) }

        return null
    }

    private fun safeISO(year: Int, month: Int, day: Int): String? {
        if (month !in 1..12) return null
        if (day !in 1..OrdoDate.daysInMonth(year, month)) return null
        return OrdoDate.format(year, month, day)
    }

    /** weekOffset: 1 = 本周, 2 = 下周;target 0=周日 */
    private fun nextWeekday(today: String, weekOffset: Int, target: Int): String {
        val current = OrdoDate.dayOfWeek(today)
        var delta = (target - current + 7) % 7
        if (weekOffset > 1) {
            delta += (weekOffset - 1) * 7
        } else if (delta == 0) {
            delta = 7
        }
        return OrdoDate.plusDays(today, delta)
    }
}
