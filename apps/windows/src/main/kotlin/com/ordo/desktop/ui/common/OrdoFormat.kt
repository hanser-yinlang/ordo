package com.ordo.desktop.ui.common

import com.ordo.core.model.RepeatFreq
import com.ordo.core.model.RepeatRule
import com.ordo.core.model.Status
import com.ordo.core.model.Todo
import com.ordo.core.model.When
import com.ordo.core.util.OrdoDate

/** 列表与详情共用的文案格式化(与 03-契约 §2 的字段语义一致) */
object OrdoFormat {

    fun whenLabel(todo: Todo): String = whenLabelOf(todo.`when`, todo.date)

    fun whenLabelOf(value: When, date: String?): String = when (value) {
        When.INBOX -> "收件箱"
        When.TODAY -> "今天"
        When.EVENING -> "今晚"
        When.ANYTIME -> "随时"
        When.SOMEDAY -> "某天"
        When.DATE -> date?.let { OrdoDate.shortCn(it) } ?: "今天"
    }

    fun repeatLabel(rule: RepeatRule?): String? {
        rule ?: return null
        val unit = when (rule.freq) {
            RepeatFreq.DAILY -> "天"
            RepeatFreq.WEEKLY -> "周"
            RepeatFreq.MONTHLY -> "月"
            RepeatFreq.YEARLY -> "年"
        }
        return if (rule.interval <= 1) "每$unit" else "每 ${rule.interval} $unit"
    }

    fun deadlineLabel(todo: Todo): String? {
        val deadline = todo.deadline ?: return null
        return OrdoDate.shortCn(deadline)
    }

    fun deadlineOverdue(todo: Todo): Boolean {
        val deadline = todo.deadline ?: return false
        return todo.status == Status.OPEN && deadline < OrdoDate.todayISO()
    }

    fun reminderLabel(todo: Todo): String? {
        val reminder = todo.reminder ?: return null
        return OrdoDate.reminderLabel(reminder)
    }

    fun reminderPast(todo: Todo): Boolean {
        val reminder = todo.reminder ?: return false
        return todo.status == Status.OPEN && OrdoDate.isPast(reminder)
    }

    /** 「今天 14:30」/「10月9日 09:00」 */
    fun completedLabel(todo: Todo): String? {
        val millis = todo.completedAt ?: return null
        val day = OrdoDate.isoFromLocalMillis(millis + com.ordo.core.platform.PlatformTime.utcOffsetMillis())
        return OrdoDate.shortCn(day) + " " + formatCompletedTime(millis)
    }

    /** epoch millis → HH:mm(本地) */
    fun formatCompletedTime(millis: Long): String {
        val local = millis + com.ordo.core.platform.PlatformTime.utcOffsetMillis()
        val minutesOfDay = Math.floorMod(local, 86_400_000L) / 60_000L
        return OrdoDate.formatTime((minutesOfDay / 60).toInt(), (minutesOfDay % 60).toInt())
    }

    /** 日程事件的 "HH:mm" */
    fun timeOf(dateTime: String?): String = OrdoDate.timePartOf(dateTime) ?: "--:--"

    fun checklistLabel(todo: Todo): String? = todo.checklistLabel

    fun statusLabel(todo: Todo): String = when (todo.status) {
        Status.OPEN -> "未完成"
        Status.DONE -> "已完成"
        Status.CANCELED -> "已取消"
    }
}
