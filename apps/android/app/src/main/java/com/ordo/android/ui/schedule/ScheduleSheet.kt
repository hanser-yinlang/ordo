package com.ordo.android.ui.schedule

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ordo.android.R
import com.ordo.android.ui.common.OrdoDivider
import com.ordo.android.ui.common.OrdoIcon
import com.ordo.android.ui.common.OrdoIconButton
import com.ordo.android.ui.common.OrdoIconKind
import com.ordo.android.ui.common.OrdoOverlay
import com.ordo.android.ui.common.OrdoPopoverPanel
import com.ordo.android.ui.common.OrdoTextField
import com.ordo.android.ui.common.rememberLastState
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.OrdoViewModel
import com.ordo.android.vm.UiState
import com.ordo.core.model.When
import java.time.LocalDate
import java.time.YearMonth

/**
 * 排期面板（04 文档 §4「排期面板」）：
 *   浮层宽 280 · 上部自然语言输入 · 中部快捷项(今天/今晚/明天/本周末/某天)
 *   下部月历 · 底部危险色「清除」。提醒也在同一处完成（对应「一处完成何时做/何时提醒」）。
 */
@Composable
fun ScheduleSheet(state: UiState, vm: OrdoViewModel) {
    // 宿主无条件组合：被 `if (打开)` 包住时关闭就是整棵子树被移除，退场（§5.5 的 140ms）没有机会播。
    // 退场途中 closeSchedule() 已清空 scheduleTarget，实时状态读不出面板内容，于是记住"最近一次打开"
    // 的那份快照（UiState 是不可变数据类），画面停在关闭前那一帧上。
    val lastOpen = rememberLastState<UiState>()
    if (state.scheduleTarget != null) lastOpen.value = state
    OrdoOverlay(visible = state.scheduleTarget != null, onDismiss = vm::closeSchedule) {
        lastOpen.value?.let { SchedulePanel(state = it, vm = vm) }
    }
}

/** 面板本体：只由 [ScheduleSheet] 的宿主调用，遮罩与 pop-in 都在宿主那边 */
@Composable
private fun SchedulePanel(state: UiState, vm: OrdoViewModel) {
    val target = state.scheduleTarget ?: return
    val colors = OrdoTheme.colors
    var draft by remember { mutableStateOf("") }
    var month by remember { mutableStateOf(YearMonth.now()) }

    OrdoPopoverPanel {
        OrdoTextField(
            value = draft,
            onValueChange = { draft = it },
            placeholder = stringResource(R.string.schedule_nl_hint),
            modifier = Modifier.fillMaxWidth(),
            onSubmit = { vm.applyNaturalLanguage(draft) },
        )
        Spacer(Modifier.height(OrdoSpace.s))
        OrdoDivider()
        Spacer(Modifier.height(OrdoSpace.s))

        if (!target.forDeadline) {
            QuickItem(OrdoIconKind.Today, stringResource(R.string.date_today)) { vm.applySchedule(When.TODAY) }
            QuickItem(OrdoIconKind.Moon, stringResource(R.string.section_tonight)) { vm.applyScheduleTonight() }
            QuickItem(OrdoIconKind.Upcoming, stringResource(R.string.schedule_tomorrow)) { vm.applyScheduleTomorrow() }
            QuickItem(OrdoIconKind.Upcoming, stringResource(R.string.schedule_weekend)) { vm.applyScheduleWeekend() }
            QuickItem(OrdoIconKind.Someday, stringResource(R.string.nav_someday)) { vm.applyScheduleSomeday() }

            Spacer(Modifier.height(OrdoSpace.s))
            OrdoDivider()
            Spacer(Modifier.height(OrdoSpace.s))
            Text(
                text = stringResource(R.string.schedule_reminder_title),
                style = OrdoTheme.type.micro,
                color = colors.textTertiary,
            )
            Spacer(Modifier.height(OrdoSpace.xs))
            QuickItem(OrdoIconKind.Bell, "09:00") { vm.setReminderAt(target.todoId, "09:00") }
            QuickItem(OrdoIconKind.Bell, "18:00") { vm.setReminderAt(target.todoId, "18:00") }
            QuickItem(OrdoIconKind.Bell, stringResource(R.string.date_tomorrow) + " 09:00") {
                vm.setReminderAt(target.todoId, "09:00", tomorrow = true)
            }
            QuickItem(OrdoIconKind.Close, stringResource(R.string.schedule_reminder_clear)) {
                vm.clearReminder(target.todoId)
            }
        }

        Spacer(Modifier.height(OrdoSpace.s))
        OrdoDivider()
        Spacer(Modifier.height(OrdoSpace.s))

        Text(
            text = if (target.forDeadline) {
                stringResource(R.string.schedule_deadline_title)
            } else {
                stringResource(R.string.schedule_pick_date)
            },
            style = OrdoTheme.type.micro,
            color = colors.textTertiary,
        )
        Spacer(Modifier.height(OrdoSpace.xs))
        CalendarGrid(
            month = month,
            onPrev = { month = month.minusMonths(1) },
            onNext = { month = month.plusMonths(1) },
            onPick = { date -> vm.applyScheduleDate(date) },
        )

        Spacer(Modifier.height(OrdoSpace.s))
        OrdoDivider()
        Spacer(Modifier.height(OrdoSpace.xs))
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(OrdoRadius.row))
                .clickable { vm.clearScheduleTarget() }
                .padding(vertical = OrdoSpace.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OrdoIcon(OrdoIconKind.Close, size = 16.dp, tint = colors.danger)
            Spacer(Modifier.width(OrdoSpace.s))
            Text(
                text = if (target.forDeadline) {
                    stringResource(R.string.schedule_clear_deadline)
                } else {
                    stringResource(R.string.schedule_clear)
                },
                style = OrdoTheme.type.body,
                color = colors.danger,
            )
        }
    }
}

@Composable
private fun QuickItem(icon: OrdoIconKind, label: String, onClick: () -> Unit) {
    val colors = OrdoTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OrdoRadius.row))
            .clickable(onClick = onClick)
            .padding(vertical = OrdoSpace.s, horizontal = OrdoSpace.xs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OrdoIcon(icon, size = 16.dp, tint = colors.textSecondary)
        Spacer(Modifier.width(OrdoSpace.s))
        Text(text = label, style = OrdoTheme.type.body, color = colors.textPrimary)
    }
}

@Composable
private fun CalendarGrid(
    month: YearMonth,
    onPrev: () -> Unit,
    onNext: () -> Unit,
    onPick: (String) -> Unit,
) {
    val colors = OrdoTheme.colors
    val today = LocalDate.now()
    val firstDay = month.atDay(1)
    val daysInMonth = month.lengthOfMonth()
    val leading = firstDay.dayOfWeek.value - 1
    val weekLabels = listOf(
        R.string.weekday_mon, R.string.weekday_tue, R.string.weekday_wed,
        R.string.weekday_thu, R.string.weekday_fri, R.string.weekday_sat, R.string.weekday_sun,
    )

    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OrdoIconButton(
                kind = OrdoIconKind.ChevronRight,
                contentDescription = stringResource(R.string.schedule_prev_month),
                onClick = onPrev,
                size = 28.dp,
                iconSize = 14.dp,
            )
            Text(
                text = stringResource(R.string.schedule_month_title, month.year, month.monthValue),
                style = OrdoTheme.type.caption,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
            OrdoIconButton(
                kind = OrdoIconKind.ChevronRight,
                contentDescription = stringResource(R.string.schedule_next_month),
                onClick = onNext,
                size = 28.dp,
                iconSize = 14.dp,
            )
        }
        Row(Modifier.fillMaxWidth()) {
            weekLabels.forEach { res ->
                Text(
                    text = stringResource(res),
                    style = OrdoTheme.type.micro,
                    color = colors.textTertiary,
                    modifier = Modifier.weight(1f),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
        Spacer(Modifier.height(OrdoSpace.xs))
        var day = 1
        var cell = 0
        while (day <= daysInMonth) {
            Row(Modifier.fillMaxWidth()) {
                repeat(7) { index ->
                    val dayNumber = day
                    if (cell >= leading && dayNumber <= daysInMonth) {
                        val date = month.atDay(dayNumber)
                        val isToday = date == today
                        Box(
                            Modifier
                                .weight(1f)
                                .height(32.dp)
                                .padding(2.dp)
                                .clip(CircleShape)
                                .background(if (isToday) colors.accentSoft else androidx.compose.ui.graphics.Color.Transparent)
                                .clickable { onPick(date.toString()) },
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = dayNumber.toString(),
                                style = OrdoTheme.type.caption,
                                color = if (isToday) colors.accent else colors.textPrimary,
                            )
                        }
                        day += 1
                    } else {
                        Spacer(Modifier.weight(1f).height(32.dp))
                    }
                    cell += 1
                }
            }
        }
    }
}
