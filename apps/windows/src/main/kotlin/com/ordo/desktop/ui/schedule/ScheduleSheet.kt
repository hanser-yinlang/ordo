package com.ordo.desktop.ui.schedule

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.ordo.core.model.Todo
import com.ordo.core.model.When
import com.ordo.core.nlp.NaturalDateParser
import com.ordo.core.util.OrdoDate
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.UiState
import com.ordo.desktop.ui.common.OrdoOverlay
import com.ordo.desktop.ui.common.OrdoTextButton
import com.ordo.desktop.ui.common.OrdoTextField
import com.ordo.desktop.ui.common.rememberLastState
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.ordoColors

/**
 * 排期面板(04-UI规范 §1.2 / §4):一处完成"何时做 / 何时提醒"。
 * 上部自然语言输入 → 中部快捷项 → 下部月历 → 底部危险色"清除"。
 */
@Composable
fun ScheduleSheet(state: UiState, vm: OrdoViewModel) {
    // 宿主无条件组合:被 `if (打开)` 包住时关闭就是整棵子树被移除,退场(§5.5 的 140ms)没有机会播。
    // 退场途中 closeSchedule() 已把 scheduleForDeadline 清成 false,实时状态读不出面板内容,
    // 于是用 rememberLastState 记住"最近一次打开"的那份快照,画面停在关闭前那一帧上。
    val lastOpen = rememberLastState<UiState>()
    if (state.scheduleTargetId != null) lastOpen.value = state
    OrdoOverlay(
        visible = state.scheduleTargetId != null,
        onDismiss = vm::closeSchedule,
        alignment = Alignment.Center
    ) {
        lastOpen.value?.let { SchedulePanel(state = it, vm = vm) }
    }
}

/** 面板本体:只由 [ScheduleSheet] 的宿主调用,遮罩与 pop-in 都在宿主那边 */
@Composable
private fun SchedulePanel(state: UiState, vm: OrdoViewModel) {
    val todoId = state.scheduleTargetId ?: return
    val todo = vm.engine.todo(todoId) ?: return
    val colors = ordoColors
    val forDeadline = state.scheduleForDeadline
    var text by remember(todoId, forDeadline) { mutableStateOf("") }
    val focusRequester = remember { FocusRequester() }
    val today = OrdoDate.todayISO()

    LaunchedEffect(todoId) { focusRequester.requestFocus() }

    // 遮罩由 OrdoOverlay 画;这里只提供居中锚点,点击穿透到宿主的遮罩上
    Box(
        Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            Modifier
                .width(OrdoSpace.scheduleWidth)
                .clip(RoundedCornerShape(OrdoRadius.sheet))
                .background(colors.surface)
                // 吃掉点击,避免冒泡到遮罩
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                .padding(OrdoSpace.m)
        ) {
            Text(
                text = if (forDeadline) "截止日期" else "何时",
                style = OrdoType.micro,
                color = colors.textSecondary
            )
            Spacer(Modifier.height(OrdoSpace.s))
            OrdoTextField(
                value = text,
                onValueChange = { text = it },
                placeholder = if (forDeadline) "试试「周五」「10月20日」" else "试试「明天」「周五」「18:00」",
                textStyle = OrdoType.body,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(OrdoRadius.row))
                    .background(colors.canvas)
                    .padding(horizontal = OrdoSpace.s, vertical = OrdoSpace.s)
                    .focusRequester(focusRequester),
                onEnter = {
                    if (text.isNotBlank()) {
                        applyNaturalLanguage(todo, text, forDeadline, vm)
                        vm.closeSchedule()
                    }
                },
                onEscape = { vm.closeSchedule() }
            )
            Spacer(Modifier.height(OrdoSpace.s))

            if (!forDeadline) {
                QuickItem("今天", OrdoDate.shortCn(today)) { vm.setWhen(todo.id, When.TODAY); vm.closeSchedule() }
                QuickItem("今晚", null) { vm.setWhen(todo.id, When.EVENING); vm.closeSchedule() }
                QuickItem("明天", OrdoDate.shortCn(OrdoDate.plusDays(today, 1))) {
                    vm.setWhen(todo.id, When.DATE, OrdoDate.plusDays(today, 1)); vm.closeSchedule()
                }
                QuickItem("本周末", OrdoDate.shortCn(nextWeekend(today))) {
                    vm.setWhen(todo.id, When.DATE, nextWeekend(today)); vm.closeSchedule()
                }
                QuickItem("某天", null) { vm.setWhen(todo.id, When.SOMEDAY); vm.closeSchedule() }
            } else {
                QuickItem("今天", OrdoDate.shortCn(today)) { vm.setDeadline(todo.id, today); vm.closeSchedule() }
                QuickItem("明天", OrdoDate.shortCn(OrdoDate.plusDays(today, 1))) {
                    vm.setDeadline(todo.id, OrdoDate.plusDays(today, 1)); vm.closeSchedule()
                }
                QuickItem("本周末", OrdoDate.shortCn(nextWeekend(today))) {
                    vm.setDeadline(todo.id, nextWeekend(today)); vm.closeSchedule()
                }
            }

            Spacer(Modifier.height(OrdoSpace.s))
            Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
            Spacer(Modifier.height(OrdoSpace.s))

            MonthCalendar(
                selected = if (forDeadline) todo.deadline else todo.date,
                onPick = { iso ->
                    if (forDeadline) vm.setDeadline(todo.id, iso) else vm.setWhen(todo.id, When.DATE, iso)
                    vm.closeSchedule()
                }
            )

            Spacer(Modifier.height(OrdoSpace.s))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                OrdoTextButton(
                    text = if (forDeadline) "清除截止日期" else "清除时间",
                    onClick = {
                        if (forDeadline) vm.setDeadline(todo.id, null) else vm.setWhen(todo.id, When.ANYTIME)
                        vm.closeSchedule()
                    },
                    danger = true
                )
            }
        }
    }
}

/** 把自然语言解析结果落到待办上(契约 §5) */
private fun applyNaturalLanguage(todo: Todo, raw: String, forDeadline: Boolean, vm: OrdoViewModel) {
    val parsed = NaturalDateParser.parse(raw)
    if (forDeadline) {
        val date = parsed.date ?: if (parsed.`when` == When.TODAY) OrdoDate.todayISO() else null
        if (date != null) vm.setDeadline(todo.id, date)
        return
    }
    when {
        parsed.`when` == When.DATE && parsed.date != null -> vm.setWhen(todo.id, When.DATE, parsed.date)
        parsed.`when` != null -> vm.setWhen(todo.id, parsed.`when`!!)
        parsed.reminder != null -> vm.setWhen(todo.id, When.TODAY)
    }
    parsed.reminder?.let { vm.setReminder(todo.id, it) }
}

private fun nextWeekend(today: String): String {
    val dow = OrdoDate.dayOfWeek(today) // 0 = 周日
    val delta = ((6 - dow + 7) % 7).let { if (it == 0) 7 else it }
    return OrdoDate.plusDays(today, delta)
}

@Composable
private fun QuickItem(label: String, hint: String?, onClick: () -> Unit) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    Row(
        Modifier
            .fillMaxWidth()
            .height(32.dp)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(if (hovered) colors.hover else Color.Transparent, RoundedCornerShape(OrdoRadius.row))
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .padding(horizontal = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, style = OrdoType.body, color = colors.textPrimary)
        Spacer(Modifier.weight(1f))
        if (hint != null) Text(hint, style = OrdoType.caption, color = colors.textTertiary)
    }
}

/** 月历(可翻月;标出今天与当前选中日) */
@Composable
fun MonthCalendar(
    selected: String?,
    onPick: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val colors = ordoColors
    val today = OrdoDate.todayISO()
    var month by remember { mutableStateOf(today.substring(0, 7)) }

    Column(modifier.fillMaxWidth()) {
        val year = month.substring(0, 4).toInt()
        val monthOfYear = month.substring(5, 7).toInt()
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            OrdoTextButton("‹", {
                month = shiftMonth(month, -1)
            })
            Spacer(Modifier.weight(1f))
            Text("$year 年 $monthOfYear 月", style = OrdoType.caption, color = colors.textPrimary)
            Spacer(Modifier.weight(1f))
            OrdoTextButton("›", {
                month = shiftMonth(month, 1)
            })
        }
        Row(Modifier.fillMaxWidth()) {
            OrdoDate.WEEKDAYS.map { it.removePrefix("周") }.forEach { label ->
                Text(
                    text = label,
                    style = OrdoType.micro,
                    color = colors.textTertiary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f).padding(vertical = 4.dp)
                )
            }
        }
        val firstDay = "$month-01"
        val leading = OrdoDate.dayOfWeek(firstDay)
        val daysInMonth = OrdoDate.daysInMonth(year, monthOfYear)
        val cells = leading + daysInMonth
        val rows = (cells + 6) / 7
        for (rowIndex in 0 until rows) {
            Row(Modifier.fillMaxWidth()) {
                for (col in 0 until 7) {
                    val dayNumber = rowIndex * 7 + col - leading + 1
                    if (dayNumber in 1..daysInMonth) {
                        val iso = OrdoDate.format(year, monthOfYear, dayNumber)
                        DayCell(
                            day = dayNumber,
                            isToday = iso == today,
                            isSelected = iso == selected,
                            onClick = { onPick(iso) },
                            modifier = Modifier.weight(1f)
                        )
                    } else {
                        Spacer(Modifier.weight(1f).height(30.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun DayCell(
    day: Int,
    isToday: Boolean,
    isSelected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    Box(
        modifier
            .height(30.dp)
            .padding(2.dp)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(
                when {
                    isSelected -> colors.accent
                    hovered -> colors.hover
                    else -> Color.Transparent
                }
            )
            .clickable(interactionSource = interaction, indication = null, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = day.toString(),
            style = OrdoType.caption,
            color = when {
                isSelected -> Color.White
                isToday -> colors.accent
                else -> colors.textPrimary
            }
        )
    }
}

private fun shiftMonth(month: String, delta: Int): String {
    val year = month.substring(0, 4).toInt()
    val m = month.substring(5, 7).toInt()
    val total = year * 12 + (m - 1) + delta
    val newYear = Math.floorDiv(total, 12)
    val newMonth = Math.floorMod(total, 12) + 1
    return String.format("%04d-%02d", newYear, newMonth)
}
