package com.ordo.desktop.ui.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ordo.core.model.RepeatFreq
import com.ordo.core.model.RepeatRule
import com.ordo.core.model.Status
import com.ordo.core.model.Todo
import com.ordo.core.model.When
import com.ordo.core.util.OrdoDate
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.UiState
import com.ordo.desktop.ui.common.MarkdownNote
import com.ordo.desktop.ui.common.OrdoCheckbox
import com.ordo.desktop.ui.common.OrdoChip
import com.ordo.desktop.ui.common.OrdoFormat
import com.ordo.desktop.ui.common.OrdoIconButton
import com.ordo.desktop.ui.common.OrdoIcons
import com.ordo.desktop.ui.common.OrdoTextButton
import com.ordo.desktop.ui.common.OrdoTextField
import com.ordo.desktop.ui.schedule.MonthCalendar
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSize
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.ordoColors

private enum class DetailPanel { NONE, DEADLINE, REMINDER, REPEAT, MOVE }

/**
 * 详情卡片(04-UI规范 §4):白纸感,圆角 14,内边距 16;
 * 标题输入 20/26;备注 Markdown 预览;字段区为可点胶囊;内含标签与清单。
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DetailCard(todo: Todo, state: UiState, vm: OrdoViewModel) {
    val colors = ordoColors
    var title by remember(todo.id) { mutableStateOf(todo.title) }
    var note by remember(todo.id) { mutableStateOf(todo.note) }
    var tagDraft by remember(todo.id) { mutableStateOf("") }
    var checklistDraft by remember(todo.id) { mutableStateOf("") }
    var panel by remember(todo.id) { mutableStateOf(DetailPanel.NONE) }

    Column(
        Modifier
            .fillMaxWidth()
            .padding(vertical = OrdoSpace.s)
            .clip(RoundedCornerShape(OrdoRadius.card))
            .background(colors.surface)
            .padding(OrdoSpace.l)
    ) {
        /* —— 标题 —— */
        Row(verticalAlignment = Alignment.CenterVertically) {
            OrdoCheckbox(
                checked = todo.status.isClosed,
                canceled = todo.status == Status.CANCELED,
                onClick = { vm.toggleDone(todo.id) }
            )
            Spacer(Modifier.width(OrdoSpace.m))
            OrdoTextField(
                value = title,
                onValueChange = {
                    title = it
                    if (it.isNotBlank()) vm.setTitle(todo.id, it)
                },
                placeholder = "标题",
                textStyle = OrdoType.title,
                modifier = Modifier.weight(1f),
                onEnter = { if (title.isBlank()) vm.deleteTodo(todo.id) }
            )
        }

        Spacer(Modifier.height(OrdoSpace.m))

        /* —— 备注 —— */
        OrdoTextField(
            value = note,
            onValueChange = {
                note = it
                vm.setNote(todo.id, it)
            },
            placeholder = "备注（支持 # 标题、- 列表、**加粗**、`代码`、[链接](地址)）",
            textStyle = OrdoType.body,
            singleLine = false,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(OrdoRadius.row))
                .background(colors.canvas)
                .padding(OrdoSpace.s)
        )
        if (note.isNotBlank()) {
            Spacer(Modifier.height(OrdoSpace.s))
            MarkdownNote(note, Modifier.fillMaxWidth())
        }

        Spacer(Modifier.height(OrdoSpace.m))

        /* —— 字段胶囊 —— */
        FlowRow(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s),
            verticalArrangement = Arrangement.spacedBy(OrdoSpace.xs)
        ) {
            FieldChip(
                icon = OrdoIcons.Calendar,
                text = "何时：${OrdoFormat.whenLabel(todo)}",
                accent = todo.`when` == When.TODAY || todo.`when` == When.EVENING
            ) { vm.openSchedule(todo.id) }

            FieldChip(
                icon = OrdoIcons.Flag,
                text = todo.deadline?.let { "截止：${OrdoDate.shortCn(it)}" } ?: "截止日期",
                danger = OrdoFormat.deadlineOverdue(todo),
                active = panel == DetailPanel.DEADLINE
            ) { panel = if (panel == DetailPanel.DEADLINE) DetailPanel.NONE else DetailPanel.DEADLINE }

            FieldChip(
                icon = OrdoIcons.Bell,
                text = todo.reminder?.let { "提醒：${OrdoDate.reminderLabel(it)}" } ?: "提醒",
                danger = OrdoFormat.reminderPast(todo),
                active = panel == DetailPanel.REMINDER
            ) { panel = if (panel == DetailPanel.REMINDER) DetailPanel.NONE else DetailPanel.REMINDER }

            FieldChip(
                icon = OrdoIcons.Repeat,
                text = OrdoFormat.repeatLabel(todo.repeat) ?: "重复",
                active = panel == DetailPanel.REPEAT
            ) { panel = if (panel == DetailPanel.REPEAT) DetailPanel.NONE else DetailPanel.REPEAT }

            val projectName = todo.projectId?.let { vm.engine.project(it)?.name }
            FieldChip(
                icon = OrdoIcons.Area,
                text = projectName ?: "移动到…",
                active = panel == DetailPanel.MOVE
            ) { panel = if (panel == DetailPanel.MOVE) DetailPanel.NONE else DetailPanel.MOVE }
        }

        when (panel) {
            DetailPanel.DEADLINE -> InlinePanel {
                MonthCalendar(selected = todo.deadline, onPick = { iso ->
                    vm.setDeadline(todo.id, iso)
                    panel = DetailPanel.NONE
                })
                Spacer(Modifier.height(OrdoSpace.xs))
                OrdoTextButton("清除截止日期", {
                    vm.setDeadline(todo.id, null)
                    panel = DetailPanel.NONE
                }, danger = true)
            }
            DetailPanel.REMINDER -> InlinePanel {
                Row(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)) {
                    OrdoTextButton("今天 09:00", { vm.setReminder(todo.id, todayAt("09:00")); panel = DetailPanel.NONE })
                    OrdoTextButton("今天 18:00", { vm.setReminder(todo.id, todayAt("18:00")); panel = DetailPanel.NONE })
                    OrdoTextButton("明天 09:00", {
                        vm.setReminder(todo.id, OrdoDate.dateTime(OrdoDate.plusDays(OrdoDate.todayISO(), 1), "09:00"))
                        panel = DetailPanel.NONE
                    })
                }
                Spacer(Modifier.height(OrdoSpace.s))
                var time by remember { mutableStateOf("09:00") }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OrdoTextField(
                        value = time,
                        onValueChange = { time = it },
                        placeholder = "HH:mm",
                        textStyle = OrdoType.body,
                        modifier = Modifier
                            .width(90.dp)
                            .clip(RoundedCornerShape(OrdoRadius.row))
                            .background(colors.canvas)
                            .padding(horizontal = OrdoSpace.s, vertical = 6.dp),
                        onEnter = {
                            OrdoDate.normalizeTime(time)?.let { normalized ->
                                vm.setReminder(todo.id, todayAt(normalized))
                                panel = DetailPanel.NONE
                            }
                        }
                    )
                    Spacer(Modifier.width(OrdoSpace.s))
                    OrdoTextButton("设置提醒", {
                        OrdoDate.normalizeTime(time)?.let { normalized ->
                            vm.setReminder(todo.id, todayAt(normalized))
                            panel = DetailPanel.NONE
                        }
                    }, emphasized = true)
                    Spacer(Modifier.width(OrdoSpace.s))
                    OrdoTextButton("清除", { vm.setReminder(todo.id, null); panel = DetailPanel.NONE }, danger = true)
                }
            }
            DetailPanel.REPEAT -> InlinePanel {
                Row(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)) {
                    OrdoTextButton("不重复", { vm.setRepeat(todo.id, null); panel = DetailPanel.NONE })
                    OrdoTextButton("每天", { vm.setRepeat(todo.id, RepeatRule(RepeatFreq.DAILY)); panel = DetailPanel.NONE })
                    OrdoTextButton("每周", { vm.setRepeat(todo.id, RepeatRule(RepeatFreq.WEEKLY)); panel = DetailPanel.NONE })
                    OrdoTextButton("每月", { vm.setRepeat(todo.id, RepeatRule(RepeatFreq.MONTHLY)); panel = DetailPanel.NONE })
                    OrdoTextButton("每年", { vm.setRepeat(todo.id, RepeatRule(RepeatFreq.YEARLY)); panel = DetailPanel.NONE })
                }
            }
            DetailPanel.MOVE -> InlinePanel {
                OrdoTextButton("无项目", { vm.moveTodo(todo.id, null, null); panel = DetailPanel.NONE })
                state.areas.forEach { area ->
                    Spacer(Modifier.height(OrdoSpace.xs))
                    Text(area.name, style = OrdoType.micro, color = colors.textSecondary)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)) {
                        OrdoTextButton("（直接放区域）", {
                            vm.moveTodo(todo.id, null, area.id)
                            panel = DetailPanel.NONE
                        })
                        state.projects.filter { it.areaId == area.id && it.status == Status.OPEN }.forEach { project ->
                            OrdoTextButton(project.name, {
                                vm.moveTodo(todo.id, project.id, null)
                                panel = DetailPanel.NONE
                            })
                        }
                    }
                }
            }
            DetailPanel.NONE -> Unit
        }

        Spacer(Modifier.height(OrdoSpace.m))

        /* —— 标签 —— */
        FlowRow(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s),
            verticalArrangement = Arrangement.spacedBy(OrdoSpace.xs)
        ) {
            todo.tags.forEach { tag ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OrdoChip(tag)
                    OrdoIconButton(
                        OrdoIcons.Close,
                        "移除标签 $tag",
                        { vm.removeTag(todo.id, tag) },
                        size = 20.dp,
                        iconSize = 12.dp
                    )
                }
            }
            OrdoTextField(
                value = tagDraft,
                onValueChange = { tagDraft = it },
                placeholder = "加标签",
                textStyle = OrdoType.caption,
                modifier = Modifier
                    .width(96.dp)
                    .clip(RoundedCornerShape(OrdoRadius.pill))
                    .background(colors.chipBg)
                    .padding(horizontal = OrdoSpace.s, vertical = 3.dp),
                onEnter = {
                    if (tagDraft.isNotBlank()) {
                        vm.addTag(todo.id, tagDraft)
                        tagDraft = ""
                    }
                }
            )
        }

        Spacer(Modifier.height(OrdoSpace.m))
        Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
        Spacer(Modifier.height(OrdoSpace.s))

        /* —— 清单 —— */
        Text("清单", style = OrdoType.micro, color = colors.textSecondary)
        Spacer(Modifier.height(OrdoSpace.xs))
        todo.checklist.forEach { item ->
            Row(
                Modifier.fillMaxWidth().heightIn(min = 30.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OrdoCheckbox(
                    checked = item.done,
                    onClick = { vm.toggleChecklistItem(todo.id, item.id) },
                    size = 16.dp
                )
                Spacer(Modifier.width(OrdoSpace.s))
                var itemTitle by remember(item.id) { mutableStateOf(item.title) }
                OrdoTextField(
                    value = itemTitle,
                    onValueChange = {
                        itemTitle = it
                        vm.setChecklistItemTitle(todo.id, item.id, it)
                    },
                    placeholder = "清单项",
                    textStyle = OrdoType.body,
                    modifier = Modifier.weight(1f),
                    onEnter = { if (itemTitle.isBlank()) vm.removeChecklistItem(todo.id, item.id) }
                )
                OrdoIconButton(OrdoIcons.Close, "删除清单项", { vm.removeChecklistItem(todo.id, item.id) }, size = 22.dp, iconSize = 12.dp)
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OrdoIconButton(OrdoIcons.Add, "添加清单项", { vm.addChecklistItem(todo.id, "") }, size = 24.dp, iconSize = 14.dp)
            OrdoTextField(
                value = checklistDraft,
                onValueChange = { checklistDraft = it },
                placeholder = "新清单项",
                textStyle = OrdoType.caption,
                modifier = Modifier.weight(1f),
                onEnter = {
                    if (checklistDraft.isNotBlank()) {
                        vm.addChecklistItem(todo.id, checklistDraft)
                        checklistDraft = ""
                    }
                }
            )
        }

        Spacer(Modifier.height(OrdoSpace.m))
        Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
        Spacer(Modifier.height(OrdoSpace.s))

        /* —— 底部操作 —— */
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(OrdoFormat.statusLabel(todo), style = OrdoType.caption, color = colors.textSecondary)
            todo.completedAt?.let {
                Spacer(Modifier.width(OrdoSpace.s))
                Text(OrdoFormat.completedLabel(todo) ?: "", style = OrdoType.caption, color = colors.textTertiary)
            }
            Spacer(Modifier.weight(1f))
            OrdoIconButton(OrdoIcons.Copy, "复制", { vm.duplicateTodo(todo.id) })
            OrdoIconButton(OrdoIcons.Delete, "删除", { vm.deleteTodo(todo.id) })
            OrdoTextButton("关闭", { vm.selectTodo(null) })
        }
    }
}

private fun todayAt(time: String): String = OrdoDate.dateTime(OrdoDate.todayISO(), time)

@Composable
private fun InlinePanel(content: @Composable () -> Unit) {
    val colors = ordoColors
    Column(
        Modifier
            .fillMaxWidth()
            .padding(top = OrdoSpace.s)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(colors.canvas)
            .padding(OrdoSpace.m)
    ) {
        content()
    }
}

@Composable
private fun FieldChip(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    text: String,
    accent: Boolean = false,
    danger: Boolean = false,
    active: Boolean = false,
    onClick: () -> Unit
) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val shape = RoundedCornerShape(OrdoRadius.pill)
    val tint = when {
        danger -> colors.danger
        accent -> colors.accent
        else -> colors.textSecondary
    }
    Row(
        Modifier
            .clip(shape)
            .background(if (active || hovered) colors.chipBg else Color.Transparent, shape)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .padding(horizontal = OrdoSpace.s, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(OrdoSize.iconSm))
        Spacer(Modifier.width(4.dp))
        Text(text, style = OrdoType.caption, color = tint, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
