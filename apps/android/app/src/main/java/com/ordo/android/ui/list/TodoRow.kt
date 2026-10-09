package com.ordo.android.ui.list

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.ordo.android.R
import com.ordo.android.ui.common.MetaPill
import com.ordo.android.ui.common.MetaTone
import com.ordo.android.ui.common.OrdoCheckbox
import com.ordo.android.ui.common.OrdoIcon
import com.ordo.android.ui.common.OrdoIconButton
import com.ordo.android.ui.common.OrdoIconKind
import com.ordo.android.ui.common.TagChip
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoMotion
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.TodoRowUi
import com.ordo.core.model.Status
import kotlin.math.roundToInt

/**
 * 待办行（04 文档 §4）：
 *   高 38 · 圆形复选框 20 · 标题 15/22 · 元信息 13/18
 *   手势（§6 Android）：右滑 → 排期；左滑 → 删除；点击 → 打开详情
 *   完成动效（§5）：0ms 按压 → 80ms 填充 → 160ms 对勾 → 240ms 变灰 → 700ms 收起
 */
@Composable
fun TodoRow(
    row: TodoRowUi,
    selected: Boolean,
    showCompletedMeta: Boolean,
    onOpen: () -> Unit,
    onToggle: () -> Unit,
    onSchedule: () -> Unit,
    onDelete: () -> Unit,
    onTagClick: (String) -> Unit,
    showRestore: Boolean = false,
    onRestore: () -> Unit = {},
) {
    val colors = OrdoTheme.colors
    var offsetX by remember(row.id) { mutableFloatStateOf(0f) }
    var completing by remember(row.id) { mutableStateOf(false) }

    val done = row.status != Status.OPEN
    val alpha by animateFloatAsState(
        targetValue = if (completing) 0f else if (done) 0.72f else 1f,
        animationSpec = tween(if (completing) OrdoMotion.COLLAPSE_DURATION else OrdoMotion.BASE, easing = OrdoMotion.easing),
        label = "row-alpha",
    )

    // 完成后停留再交给引擎处理（引擎会把它移入日志簿）
    LaunchedEffect(completing) {
        if (completing) {
            kotlinx.coroutines.delay(OrdoMotion.COLLAPSE_START.toLong())
            onToggle()
            completing = false
        }
    }

    Box(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(if (selected) colors.accentSoft else colors.canvas),
    ) {
        /* 滑动背景提示 */
        Row(
            Modifier
                .matchParentSize()
                .padding(horizontal = OrdoSpace.l),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            if (offsetX > 4f) {
                MetaPill(text = stringResource(R.string.row_schedule_desc), icon = OrdoIconKind.Upcoming, tone = MetaTone.ACCENT)
            }
            if (offsetX < -4f) {
                MetaPill(text = stringResource(R.string.detail_delete), icon = OrdoIconKind.Trash, tone = MetaTone.DANGER)
            }
        }

        Row(
            Modifier
                .offset { IntOffset(offsetX.roundToInt(), 0) }
                .alpha(alpha)
                .pointerInput(row.id) {
                    detectHorizontalDragGestures(
                        onDragEnd = {
                            when {
                                offsetX > SWIPE_THRESHOLD -> onSchedule()
                                offsetX < -SWIPE_THRESHOLD -> onDelete()
                            }
                            offsetX = 0f
                        },
                        onDragCancel = { offsetX = 0f },
                        onHorizontalDrag = { _, delta -> offsetX += delta },
                    )
                }
                .clickable(onClick = onOpen)
                .padding(horizontal = OrdoSpace.xs, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OrdoCheckbox(
                checked = done || completing,
                canceled = row.status == Status.CANCELED,
                contentDescription = stringResource(R.string.row_checkbox_desc, row.title),
                onToggle = { completing = true },
            )
            Spacer(Modifier.width(OrdoSpace.xs))
            Column(
                Modifier
                    .weight(1f)
                    .heightIn(min = OrdoLayout.rowHeight)
                    .padding(vertical = OrdoSpace.xs),
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    text = row.title,
                    style = OrdoTheme.type.body,
                    color = if (done) colors.textTertiary else colors.textPrimary,
                    textDecoration = if (done) TextDecoration.LineThrough else null,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                if (row.notePreview.isNotBlank()) {
                    Text(
                        text = row.notePreview,
                        style = OrdoTheme.type.caption,
                        color = colors.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                MetaRow(row = row, showCompletedMeta = showCompletedMeta, onTagClick = onTagClick)
            }
            if (showRestore) {
                OrdoIconButton(
                    kind = OrdoIconKind.Repeat,
                    contentDescription = stringResource(R.string.row_restore_desc),
                    onClick = onRestore,
                    size = 32.dp,
                    iconSize = 16.dp,
                    tint = colors.accent,
                )
            }
            OrdoIconButton(
                kind = OrdoIconKind.Upcoming,
                contentDescription = stringResource(R.string.row_schedule_desc),
                onClick = onSchedule,
                size = 32.dp,
                iconSize = 16.dp,
                tint = colors.textTertiary,
            )
        }
    }
}

@Composable
private fun MetaRow(
    row: TodoRowUi,
    showCompletedMeta: Boolean,
    onTagClick: (String) -> Unit,
) {
    val hasMeta = row.tags.isNotEmpty() || row.reminderLabel != null || row.deadlineLabel != null ||
        row.checklistTotal > 0 || row.hasNote || row.repeat || (showCompletedMeta && row.completedAtLabel != null) ||
        row.whenLabel != null
    if (!hasMeta) return
    Row(
        Modifier.padding(top = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        row.whenLabel?.let { label ->
            MetaPill(text = label, icon = OrdoIconKind.Upcoming, tone = MetaTone.ACCENT)
            Spacer(Modifier.width(6.dp))
        }
        row.reminderLabel?.let { label ->
            MetaPill(
                text = label,
                icon = OrdoIconKind.Bell,
                tone = if (row.reminderPast) MetaTone.DANGER else MetaTone.NORMAL,
            )
            Spacer(Modifier.width(6.dp))
        }
        row.deadlineLabel?.let { label ->
            MetaPill(
                text = label,
                icon = OrdoIconKind.Flag,
                tone = if (row.deadlineOverdue) MetaTone.DANGER else MetaTone.NORMAL,
            )
            Spacer(Modifier.width(6.dp))
        }
        if (row.checklistTotal > 0) {
            MetaPill(
                text = stringResource(R.string.row_checklist_progress, row.checklistDone, row.checklistTotal),
                icon = OrdoIconKind.Checklist,
            )
            Spacer(Modifier.width(6.dp))
        }
        if (row.hasNote) {
            MetaPill(text = "", icon = OrdoIconKind.Note)
            Spacer(Modifier.width(6.dp))
        }
        if (row.repeat) {
            MetaPill(text = "", icon = OrdoIconKind.Repeat)
            Spacer(Modifier.width(6.dp))
        }
        if (showCompletedMeta && row.completedAtLabel != null) {
            MetaPill(text = row.completedAtLabel, icon = OrdoIconKind.Logbook)
            Spacer(Modifier.width(6.dp))
        }
        row.tags.forEach { tag ->
            TagChip(name = tag, onClick = { onTagClick(tag) })
            Spacer(Modifier.width(4.dp))
        }
    }
}

private const val SWIPE_THRESHOLD = 72f
