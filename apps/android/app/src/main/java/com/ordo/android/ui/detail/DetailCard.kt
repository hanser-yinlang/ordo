package com.ordo.android.ui.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
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
import com.ordo.android.ui.common.MarkdownPreview
import com.ordo.android.ui.common.MetaPill
import com.ordo.android.ui.common.MetaTone
import com.ordo.android.ui.common.OrdoButton
import com.ordo.android.ui.common.OrdoCheckbox
import com.ordo.android.ui.common.OrdoDivider
import com.ordo.android.ui.common.OrdoIcon
import com.ordo.android.ui.common.OrdoIconButton
import com.ordo.android.ui.common.OrdoIconKind
import com.ordo.android.ui.common.OrdoTextField
import com.ordo.android.ui.common.TagChip
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.DetailUi
import com.ordo.android.vm.OrdoViewModel
import com.ordo.android.vm.UiState
import com.ordo.core.model.RepeatFreq

/**
 * 详情卡片（04 文档 §4）：白纸感、圆角 14、内边距 16、标题输入 20/26、
 * 备注 Markdown 预览、字段区为可点胶囊按钮（何时 / 截止 / 提醒 / 重复 / 移动到 / 标签 / 清单）。
 */
@Composable
fun DetailCard(
    state: UiState,
    vm: OrdoViewModel,
    expanded: Boolean,
    onClose: () -> Unit,
) {
    val detail = state.detail ?: return
    val colors = OrdoTheme.colors

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OrdoRadius.card))
            .background(colors.surface)
            .verticalScroll(rememberScrollState())
            .padding(OrdoSpace.l),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = stringResource(R.string.detail_title_hint),
                style = OrdoTheme.type.micro,
                color = colors.textTertiary,
                modifier = Modifier.weight(1f),
            )
            OrdoIconButton(
                kind = OrdoIconKind.Close,
                contentDescription = stringResource(R.string.detail_close),
                onClick = onClose,
            )
        }

        OrdoTextField(
            value = detail.title,
            onValueChange = { vm.updateTitle(detail.id, it) },
            placeholder = stringResource(R.string.detail_title_hint),
            textStyle = OrdoTheme.type.title,
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(Modifier.height(OrdoSpace.m))

        OrdoTextField(
            value = detail.note,
            onValueChange = { vm.updateNote(detail.id, it) },
            placeholder = stringResource(R.string.detail_note_hint),
            singleLine = false,
            textStyle = OrdoTheme.type.body,
            modifier = Modifier.fillMaxWidth(),
        )
        if (detail.note.isNotBlank()) {
            Spacer(Modifier.height(OrdoSpace.s))
            Text(
                text = stringResource(R.string.detail_markdown_preview),
                style = OrdoTheme.type.micro,
                color = colors.textTertiary,
            )
            Spacer(Modifier.height(OrdoSpace.xs))
            MarkdownPreview(text = detail.note, modifier = Modifier.fillMaxWidth())
        }

        Spacer(Modifier.height(OrdoSpace.m))
        OrdoDivider()
        Spacer(Modifier.height(OrdoSpace.m))

        FieldRow(
            icon = OrdoIconKind.Upcoming,
            label = stringResource(R.string.detail_when, detail.whenLabel),
            accent = detail.whenValue == com.ordo.core.model.When.TODAY || detail.whenValue == com.ordo.core.model.When.EVENING,
            onClick = { vm.openSchedule(detail.id, false) },
        )
        FieldRow(
            icon = OrdoIconKind.Flag,
            label = detail.deadlineLabel?.let { stringResource(R.string.detail_deadline, it) }
                ?: stringResource(R.string.detail_deadline_empty),
            danger = detail.deadlineOverdue,
            onClick = { vm.openSchedule(detail.id, true) },
        )
        FieldRow(
            icon = OrdoIconKind.Bell,
            label = detail.reminderLabel?.let { stringResource(R.string.detail_reminder, it) }
                ?: stringResource(R.string.detail_reminder_empty),
            danger = detail.reminderPast,
            onClick = { vm.openSchedule(detail.id, false) },
        )
        RepeatField(detail = detail, vm = vm)
        MoveField(state = state, detail = detail, vm = vm)

        Spacer(Modifier.height(OrdoSpace.s))
        TagsField(detail = detail, vm = vm)

        Spacer(Modifier.height(OrdoSpace.s))
        ChecklistField(detail = detail, vm = vm)

        Spacer(Modifier.height(OrdoSpace.l))
        Row(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)) {
            OrdoButton(
                label = stringResource(R.string.detail_duplicate),
                onClick = { vm.duplicateTodo(detail.id) },
            )
            OrdoButton(
                label = stringResource(R.string.detail_delete),
                onClick = { vm.deleteTodo(detail.id) },
                danger = true,
            )
            Spacer(Modifier.weight(1f))
            if (expanded) {
                OrdoButton(label = stringResource(R.string.detail_close), onClick = onClose)
            }
        }
    }
}

@Composable
private fun FieldRow(
    icon: OrdoIconKind,
    label: String,
    onClick: () -> Unit,
    accent: Boolean = false,
    danger: Boolean = false,
) {
    val colors = OrdoTheme.colors
    val tint = when {
        danger -> colors.danger
        accent -> colors.accent
        else -> colors.textSecondary
    }
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OrdoRadius.row))
            .clickable(onClick = onClick)
            .padding(horizontal = OrdoSpace.s, vertical = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OrdoIcon(kind = icon, size = 16.dp, tint = tint)
        Spacer(Modifier.width(OrdoSpace.s))
        Text(text = label, style = OrdoTheme.type.body, color = colors.textPrimary)
    }
}

@Composable
private fun RepeatField(detail: DetailUi, vm: OrdoViewModel) {
    var open by remember(detail.id) { mutableStateOf(false) }
    FieldRow(
        icon = OrdoIconKind.Repeat,
        label = detail.repeatLabel?.let { stringResource(R.string.detail_repeat, it) }
            ?: stringResource(R.string.detail_repeat_empty),
        onClick = { open = !open },
    )
    if (open) {
        val options = listOf(
            null to stringResource(R.string.repeat_none),
            RepeatFreq.DAILY to stringResource(R.string.repeat_daily),
            RepeatFreq.WEEKLY to stringResource(R.string.repeat_weekly),
            RepeatFreq.MONTHLY to stringResource(R.string.repeat_monthly),
            RepeatFreq.YEARLY to stringResource(R.string.repeat_yearly),
        )
        Column(Modifier.padding(start = OrdoSpace.xl)) {
            options.forEach { (freq, label) ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable {
                            vm.setRepeat(detail.id, freq)
                            open = false
                        }
                        .padding(vertical = OrdoSpace.s),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = label,
                        style = OrdoTheme.type.caption,
                        color = if (detail.repeatFreq == freq) OrdoTheme.colors.accent else OrdoTheme.colors.textPrimary,
                    )
                    Spacer(Modifier.width(OrdoSpace.s))
                    if (detail.repeatFreq == freq) {
                        OrdoIcon(OrdoIconKind.Check, size = 14.dp, tint = OrdoTheme.colors.accent)
                    }
                }
            }
        }
    }
}

@Composable
private fun MoveField(state: UiState, detail: DetailUi, vm: OrdoViewModel) {
    var open by remember(detail.id) { mutableStateOf(false) }
    FieldRow(
        icon = OrdoIconKind.Area,
        label = detail.projectName?.let { stringResource(R.string.detail_move, it) }
            ?: stringResource(R.string.detail_move_empty),
        onClick = { open = !open },
    )
    if (open) {
        Column(Modifier.padding(start = OrdoSpace.xl)) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable {
                        vm.moveTodo(detail.id, null, null, null)
                        open = false
                    }
                    .padding(vertical = OrdoSpace.s),
            ) {
                Text(
                    text = stringResource(R.string.detail_no_project),
                    style = OrdoTheme.type.caption,
                    color = if (detail.projectId == null) OrdoTheme.colors.accent else OrdoTheme.colors.textPrimary,
                )
            }
            state.areas.forEach { area ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable {
                            vm.moveTodo(detail.id, null, area.id, null)
                            open = false
                        }
                        .padding(vertical = OrdoSpace.s),
                ) {
                    Text(
                        text = area.name,
                        style = OrdoTheme.type.caption,
                        color = OrdoTheme.colors.textSecondary,
                    )
                }
                area.projects.forEach { project ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable {
                                vm.moveTodo(detail.id, project.id, null, null)
                                open = false
                            }
                            .padding(start = OrdoSpace.m, top = OrdoSpace.xs, bottom = OrdoSpace.xs),
                    ) {
                        Text(
                            text = project.name,
                            style = OrdoTheme.type.caption,
                            color = if (detail.projectId == project.id) OrdoTheme.colors.accent else OrdoTheme.colors.textPrimary,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TagsField(detail: DetailUi, vm: OrdoViewModel) {
    var draft by remember(detail.id) { mutableStateOf("") }
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OrdoIcon(kind = OrdoIconKind.Tag, size = 16.dp)
            Spacer(Modifier.width(OrdoSpace.s))
            detail.tags.forEach { tag ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TagChip(name = tag)
                    OrdoIconButton(
                        kind = OrdoIconKind.Close,
                        contentDescription = stringResource(R.string.detail_remove_tag, tag),
                        onClick = { vm.removeTag(detail.id, tag) },
                        size = 28.dp,
                        iconSize = 12.dp,
                    )
                }
            }
        }
        Spacer(Modifier.height(OrdoSpace.xs))
        OrdoTextField(
            value = draft,
            onValueChange = { draft = it },
            placeholder = stringResource(R.string.detail_add_tag),
            modifier = Modifier.fillMaxWidth(),
            onSubmit = {
                vm.addTag(detail.id, draft)
                draft = ""
            },
        )
    }
}

@Composable
private fun ChecklistField(detail: DetailUi, vm: OrdoViewModel) {
    var draft by remember(detail.id) { mutableStateOf("") }
    val colors = OrdoTheme.colors
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OrdoIcon(kind = OrdoIconKind.Checklist, size = 16.dp)
            Spacer(Modifier.width(OrdoSpace.s))
            Text(text = stringResource(R.string.detail_checklist), style = OrdoTheme.type.caption, color = colors.textSecondary)
            if (detail.checklist.isNotEmpty()) {
                Spacer(Modifier.width(OrdoSpace.s))
                MetaPill(
                    text = stringResource(
                        R.string.row_checklist_progress,
                        detail.checklist.count { it.done },
                        detail.checklist.size,
                    ),
                )
            }
        }
        detail.checklist.forEach { item ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                OrdoCheckbox(
                    checked = item.done,
                    contentDescription = item.title,
                    onToggle = { vm.toggleChecklistItem(detail.id, item.id) },
                )
                Text(
                    text = item.title,
                    style = OrdoTheme.type.body,
                    color = if (item.done) colors.textTertiary else colors.textPrimary,
                )
            }
        }
        Spacer(Modifier.height(OrdoSpace.xs))
        OrdoTextField(
            value = draft,
            onValueChange = { draft = it },
            placeholder = stringResource(R.string.detail_add_checklist_item),
            modifier = Modifier.fillMaxWidth(),
            onSubmit = {
                vm.addChecklistItem(detail.id, draft)
                draft = ""
            },
        )
    }
}
