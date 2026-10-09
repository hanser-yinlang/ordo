package com.ordo.core.repeat

import com.ordo.core.model.RepeatFreq
import com.ordo.core.model.RepeatMode
import com.ordo.core.model.RepeatRule
import com.ordo.core.model.Status
import com.ordo.core.model.Todo
import com.ordo.core.util.OrdoDate

/**
 * 重复规则引擎(契约 §6)。
 *
 * 完成一个带 repeat 的待办时:原实例标记完成,并生成下一次实例。
 * `fixed` 基于原日期递推;`afterCompletion` 基于实际完成日递推。
 */
object RepeatEngine {

    /** 计算下一次发生的日期 */
    fun nextDate(rule: RepeatRule, baseDate: String, interval: Int = rule.interval): String {
        val step = interval.coerceAtLeast(1)
        return when (rule.freq) {
            RepeatFreq.DAILY -> OrdoDate.plusDays(baseDate, step)
            RepeatFreq.WEEKLY -> OrdoDate.plusDays(baseDate, 7 * step)
            RepeatFreq.MONTHLY -> OrdoDate.plusMonths(baseDate, step)
            RepeatFreq.YEARLY -> OrdoDate.plusYears(baseDate, step)
        }
    }

    /**
     * 依据原待办与完成时间生成下一次实例;不需要重复时返回 null。
     * @param newId 新实例 id(由调用方提供,便于测试注入)
     */
    fun spawnNext(todo: Todo, completedAtMillis: Long, newId: String, utcOffsetMillis: Long): Todo? {
        val rule = todo.repeat ?: return null
        val completionDay = OrdoDate.isoFromLocalMillis(completedAtMillis + utcOffsetMillis)
        val base = when (rule.mode) {
            RepeatMode.AFTER_COMPLETION -> completionDay
            RepeatMode.FIXED -> todo.date
                ?: OrdoDate.datePartOf(todo.reminder)
                ?: completionDay
        }
        val next = nextDate(rule, base)
        return todo.copy(
            id = newId,
            status = Status.OPEN,
            completedAt = null,
            createdAt = completedAtMillis,
            updatedAt = completedAtMillis,
            date = next,
            `when` = com.ordo.core.model.When.DATE,
            reminder = todo.reminder?.let { rem ->
                OrdoDate.timePartOf(rem)?.let { time -> OrdoDate.dateTime(next, time) }
            },
            checklist = todo.checklist.map { it.copy(done = false) }
        )
    }
}
