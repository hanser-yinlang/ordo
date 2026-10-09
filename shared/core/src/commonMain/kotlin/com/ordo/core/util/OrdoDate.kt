package com.ordo.core.util

import com.ordo.core.platform.PlatformTime
import com.ordo.core.platform.SystemOrdoClock
import com.ordo.core.platform.OrdoClock

/**
 * 纯 Kotlin 日期引擎。
 *
 * 约定(与契约 §2 一致):日期 = `YYYY-MM-DD` 字符串,日期时间 = `YYYY-MM-DDTHH:mm`。
 * 实现采用 Howard Hinnant 的 civil-from-days / days-from-civil 算法,四端结果完全一致,无时区库依赖。
 */
object OrdoDate {

    private const val MS_PER_DAY = 86_400_000L
    private val ISO_RE = Regex("^(\\d{4})-(\\d{2})-(\\d{2})$")
    private val DATE_TIME_RE = Regex("^(\\d{4}-\\d{2}-\\d{2})T(\\d{2}):(\\d{2})$")

    // ---------------------------------------------------------------- 基础历法

    fun isLeapYear(year: Int): Boolean =
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0

    fun daysInMonth(year: Int, month: Int): Int = when (month) {
        1, 3, 5, 7, 8, 10, 12 -> 31
        4, 6, 9, 11 -> 30
        2 -> if (isLeapYear(year)) 29 else 28
        else -> 30
    }

    /** 1970-01-01 起的天数(Hinnant days_from_civil) */
    fun epochDayOf(year: Int, month: Int, day: Int): Long {
        var y = year.toLong()
        val m = month.toLong()
        val d = day.toLong()
        if (m <= 2) y -= 1
        val era = (if (y >= 0) y else y - 399) / 400
        val yoe = y - era * 400
        val doy = (153 * (if (m > 2) m - 3 else m + 9) + 2) / 5 + d - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /** epoch 天数还原为 (year, month, day) */
    fun civilFromEpochDay(epochDay: Long): IntArray {
        val z = epochDay + 719468
        val era = (if (z >= 0) z else z - 146096) / 146097
        val doe = z - era * 146097
        val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        val y = yoe + era * 400
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        val mp = (5 * doy + 2) / 153
        val d = doy - (153 * mp + 2) / 5 + 1
        val m = if (mp < 10) mp + 3 else mp - 9
        return intArrayOf((y + if (m <= 2) 1 else 0).toInt(), m.toInt(), d.toInt())
    }

    private fun floorMod(a: Long, b: Long): Long = ((a % b) + b) % b

    // ---------------------------------------------------------------- 当前时间

    fun nowMillis(clock: OrdoClock = SystemOrdoClock): Long = clock.nowMillis()

    /** 本地当前时间(epoch 毫秒 + 时区偏移) */
    fun localMillis(clock: OrdoClock = SystemOrdoClock): Long =
        clock.nowMillis() + PlatformTime.utcOffsetMillis()

    fun todayISO(clock: OrdoClock = SystemOrdoClock): String = isoFromLocalMillis(localMillis(clock))

    fun nowHHmm(clock: OrdoClock = SystemOrdoClock): String {
        val local = localMillis(clock)
        val minutesOfDay = floorMod(local, MS_PER_DAY) / 60_000L
        return formatTime(minutesOfDay.toInt() / 60, minutesOfDay.toInt() % 60)
    }

    fun isoFromLocalMillis(localMillis: Long): String {
        val days = Math.floorDiv(localMillis, MS_PER_DAY)
        val c = civilFromEpochDay(days)
        return format(c[0], c[1], c[2])
    }

    // ---------------------------------------------------------------- 解析与格式化

    fun parseISO(iso: String?): IntArray? {
        val m = ISO_RE.matchEntire(iso?.trim() ?: return null) ?: return null
        val y = m.groupValues[1].toInt()
        val mo = m.groupValues[2].toInt()
        val d = m.groupValues[3].toInt()
        if (mo !in 1..12 || d !in 1..daysInMonth(y, mo)) return null
        return intArrayOf(y, mo, d)
    }

    fun isValidISO(iso: String?): Boolean = parseISO(iso) != null

    fun format(year: Int, month: Int, day: Int): String =
        "${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)}"

    fun formatTime(hour: Int, minute: Int): String = "${pad(hour, 2)}:${pad(minute, 2)}"

    private fun pad(value: Int, width: Int): String {
        val s = value.toString()
        return if (s.length >= width) s else "0".repeat(width - s.length) + s
    }

    // ---------------------------------------------------------------- 运算

    fun plusDays(iso: String, days: Int): String {
        val p = parseISO(iso) ?: return iso
        val c = civilFromEpochDay(epochDayOf(p[0], p[1], p[2]) + days)
        return format(c[0], c[1], c[2])
    }

    /** 月份加减;日期溢出时取目标月最后一天(契约 §6) */
    fun plusMonths(iso: String, months: Int): String {
        val p = parseISO(iso) ?: return iso
        val total = p[0] * 12 + (p[1] - 1) + months
        val year = Math.floorDiv(total, 12)
        val month = Math.floorMod(total, 12) + 1
        val day = minOf(p[2], daysInMonth(year, month))
        return format(year, month, day)
    }

    fun plusYears(iso: String, years: Int): String {
        val p = parseISO(iso) ?: return iso
        val year = p[0] + years
        val day = minOf(p[2], daysInMonth(year, p[1]))
        return format(year, p[1], day)
    }

    fun daysBetween(fromISO: String, toISO: String): Int {
        val a = parseISO(fromISO) ?: return 0
        val b = parseISO(toISO) ?: return 0
        return (epochDayOf(b[0], b[1], b[2]) - epochDayOf(a[0], a[1], a[2])).toInt()
    }

    /** 0 = 周日,1 = 周一 … 6 = 周六 */
    fun dayOfWeek(iso: String): Int {
        val p = parseISO(iso) ?: return 0
        return floorMod(epochDayOf(p[0], p[1], p[2]) + 4, 7).toInt()
    }

    fun weekdayCn(iso: String): String = WEEKDAYS[dayOfWeek(iso)]

    val WEEKDAYS = arrayOf("周日", "周一", "周二", "周三", "周四", "周五", "周六")

    /** 今天 / 明天 / 后天 / 昨天 / M月D日(跨年带年份) */
    fun shortCn(iso: String, clock: OrdoClock = SystemOrdoClock): String {
        val today = todayISO(clock)
        return when (iso) {
            today -> "今天"
            plusDays(today, 1) -> "明天"
            plusDays(today, 2) -> "后天"
            plusDays(today, -1) -> "昨天"
            else -> {
                val p = parseISO(iso)
                if (p == null) iso
                else {
                    val todayYear = parseISO(today)?.get(0) ?: p[0]
                    if (p[0] == todayYear) "${p[1]}月${p[2]}日" else "${p[0]}年${p[1]}月${p[2]}日"
                }
            }
        }
    }

    /** 今天 · 周四 / 明天 · 周五 / 10月11日 · 周日 */
    fun dayLabelCn(iso: String, clock: OrdoClock = SystemOrdoClock): String =
        shortCn(iso, clock) + " · " + weekdayCn(iso)

    // ---------------------------------------------------------------- 日期时间

    fun isValidDateTime(value: String?): Boolean =
        DATE_TIME_RE.matchEntire(value?.trim() ?: return false) != null

    fun datePartOf(dateTime: String?): String? =
        DATE_TIME_RE.matchEntire(dateTime?.trim() ?: return null)?.groupValues?.get(1)

    fun timePartOf(dateTime: String?): String? {
        val m = DATE_TIME_RE.matchEntire(dateTime?.trim() ?: return null) ?: return null
        return "${m.groupValues[2]}:${m.groupValues[3]}"
    }

    fun dateTime(dateISO: String, hhmm: String): String = "${dateISO}T$hhmm"

    /** 本地"现在"的 `YYYY-MM-DDTHH:mm`,可直接与 reminder 字符串比较 */
    fun nowLocalDateTime(clock: OrdoClock = SystemOrdoClock): String =
        dateTime(todayISO(clock), nowHHmm(clock))

    /** 提醒是否已过期 */
    fun isPast(dateTime: String, clock: OrdoClock = SystemOrdoClock): Boolean =
        dateTime < nowLocalDateTime(clock)

    /** 提醒展示文案:今天 18:00 → "18:00";明天 09:30 → "明天 09:30" */
    fun reminderLabel(reminder: String, clock: OrdoClock = SystemOrdoClock): String {
        val day = datePartOf(reminder) ?: return reminder
        val time = timePartOf(reminder) ?: return reminder
        val today = todayISO(clock)
        return if (day == today) time else "${shortCn(day, clock)} $time"
    }

    /** 时间字符串规范化:`8:5` → `08:05`,非法返回 null */
    fun normalizeTime(raw: String): String? {
        val m = Regex("^(\\d{1,2})[:：](\\d{1,2})$").matchEntire(raw.trim()) ?: return null
        val h = m.groupValues[1].toInt()
        val mi = m.groupValues[2].toInt()
        if (h !in 0..23 || mi !in 0..59) return null
        return formatTime(h, mi)
    }
}
