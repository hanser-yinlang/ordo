package com.ordo.android.ui.common

import android.content.Context
import com.ordo.android.R
import com.ordo.core.model.RepeatFreq
import com.ordo.core.model.RepeatMode
import com.ordo.core.model.Status
import com.ordo.core.model.Todo
import com.ordo.core.model.When
import com.ordo.core.util.OrdoDate
import java.time.Instant
import java.time.ZoneId

/**
 * 展示格式化。
 *
 * 日期词汇（今天/明天/周三…）一律使用共享核心的 [OrdoDate]，保证四端文案与算法一致；
 * 界面文案（按钮、字段名、分区名）取自 res/values/strings.xml。
 */
class OrdoFormatter(private val context: Context) {

    fun today(): String = OrdoDate.todayISO()

    fun nowLocal(): String = OrdoDate.nowLocalDateTime()

    /** 今天 / 明天 / 后天 / 昨天 / 10月9日 */
    fun shortDate(iso: String?): String? = iso?.takeIf { it.isNotBlank() }?.let { OrdoDate.shortCn(it) }

    /** 今天 · 周四 */
    fun dayLabel(iso: String): String = OrdoDate.dayLabelCn(iso)

    /** 今天 18:00 → "18:00"；明天 09:30 → "明天 09:30" */
    fun reminderLabel(reminder: String?): String? =
        reminder?.takeIf { it.isNotBlank() && OrdoDate.isValidDateTime(it) }?.let { OrdoDate.reminderLabel(it) }

    fun reminderPast(reminder: String?): Boolean =
        !reminder.isNullOrBlank() && OrdoDate.isValidDateTime(reminder) && OrdoDate.isPast(reminder)

    fun whenLabel(`when`: When, date: String?): String = when (`when`) {
        When.INBOX -> context.getString(R.string.nav_inbox)
        When.TODAY -> context.getString(R.string.date_today)
        When.EVENING -> context.getString(R.string.section_tonight)
        When.ANYTIME -> context.getString(R.string.nav_anytime)
        When.SOMEDAY -> context.getString(R.string.nav_someday)
        When.DATE -> shortDate(date) ?: context.getString(R.string.date_today)
    }

    fun repeatLabel(freq: RepeatFreq?, mode: RepeatMode?): String? {
        if (freq == null) return null
        val base = when (freq) {
            RepeatFreq.DAILY -> context.getString(R.string.repeat_daily)
            RepeatFreq.WEEKLY -> context.getString(R.string.repeat_weekly)
            RepeatFreq.MONTHLY -> context.getString(R.string.repeat_monthly)
            RepeatFreq.YEARLY -> context.getString(R.string.repeat_yearly)
        }
        return if (mode == RepeatMode.AFTER_COMPLETION) {
            context.getString(R.string.repeat_after_completion, base)
        } else {
            base
        }
    }

    /** 完成时间："今天 14:05" */
    fun completedLabel(epochMillis: Long?): String? {
        if (epochMillis == null || epochMillis <= 0L) return null
        val local = Instant.ofEpochMilli(epochMillis).atZone(ZoneId.systemDefault())
        val iso = OrdoDate.format(local.year, local.monthValue, local.dayOfMonth)
        val time = OrdoDate.formatTime(local.hour, local.minute)
        return "${OrdoDate.shortCn(iso)} $time"
    }

    /** 逾期（契约 §4：deadline < today → 珊瑚红） */
    fun deadlineOverdue(deadline: String?): Boolean =
        !deadline.isNullOrBlank() && OrdoDate.isValidISO(deadline) && deadline < today()

    /** 项目进度（与 core 的 QueryEngine.projectProgress 同口径：done / (done + open)） */
    fun progress(todos: List<Todo>): Float {
        val done = todos.count { it.status != Status.OPEN }
        val open = todos.count { it.status == Status.OPEN }
        val total = done + open
        return if (total == 0) 0f else done.toFloat() / total.toFloat()
    }

    /** 备注的一行纯文本预览（去掉 Markdown 记号） */
    fun plainPreview(note: String?): String {
        if (note.isNullOrBlank()) return ""
        return note
            .replace(Regex("```[\\s\\S]*?```"), " ")
            .replace(Regex("`([^`]*)`"), "$1")
            .replace(Regex("!?\\[([^\\]]*)\\]\\([^)]*\\)"), "$1")
            .replace(Regex("^\\s{0,3}#{1,6}\\s*", RegexOption.MULTILINE), "")
            .replace(Regex("^\\s{0,3}[-*+]\\s+", RegexOption.MULTILINE), "")
            .replace(Regex("\\*\\*([^*]*)\\*\\*"), "$1")
            .replace(Regex("__([^_]*)__"), "$1")
            .replace(Regex("[*_~]"), "")
            .replace(Regex("\\s+"), " ")
            .trim()
    }
}
