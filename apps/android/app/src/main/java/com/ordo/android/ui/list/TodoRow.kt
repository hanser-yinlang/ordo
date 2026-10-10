package com.ordo.android.ui.list

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.ordo.android.R
import com.ordo.android.ui.common.MetaPill
import com.ordo.android.ui.common.MetaTone
import com.ordo.android.ui.common.OrdoCheckbox
import com.ordo.android.ui.common.OrdoIconButton
import com.ordo.android.ui.common.OrdoIconKind
import com.ordo.android.ui.common.TagChip
import com.ordo.android.ui.gesture.LongPressDragState
import com.ordo.android.ui.gesture.OrdoGesture
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoMotion
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.TodoRowUi
import com.ordo.core.model.Status
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.roundToInt

/**
 * 待办行（04 文档 §4 / §5.4）。
 *
 * 手势分工（统一为"长按后拖动"这一件事）：
 *  - 点击（<6px 位移）→ 打开详情；右滑 → 排期；左滑 → 删除；
 *  - **长按 400ms** → 行抬起（scale 1.02 + 12dp 投影 + 背景 surface）→ 拖动排序；
 *  - 拖动中 BackHandler 取消：行回原位，不写库。
 *
 * 判定逻辑全部来自 [LongPressDragState]（纯状态机，可 JVM 单测）。
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
    /* ---------- 长按拖拽（UI §5.4） ---------- */
    lifted: Boolean = false,
    dragging: Boolean = false,
    dragOffsetY: Float = 0f,
    dragShiftY: Float = 0f,
    sectionIndex: Int = 0,
    rowIndex: Int = 0,
    onDragStart: (sectionIndex: Int, rowIndex: Int, rowHeightPx: Float) -> Unit = { _, _, _ -> },
    onDragMove: (deltaY: Float) -> Unit = {},
    onDragEnd: () -> Unit = {},
    onDragCancel: () -> Unit = {},
) {
    val colors = OrdoTheme.colors
    var offsetX by remember(row.id) { mutableFloatStateOf(0f) }
    var completing by remember(row.id) { mutableStateOf(false) }
    var rowHeightPx by remember(row.id) { mutableFloatStateOf(0f) }
    val drag = remember(row.id) { LongPressDragState() }

    val done = row.status != Status.OPEN
    val alpha by animateFloatAsState(
        targetValue = if (completing) 0f else if (done) 0.72f else 1f,
        animationSpec = tween(if (completing) OrdoMotion.COLLAPSE_DURATION else OrdoMotion.BASE, easing = OrdoMotion.easing),
        label = "row-alpha",
    )

    // 抬起进度：0 = 常态，1 = 已抬起（scale 1.02 + 12dp 投影 + surface 底 + alpha 0.55）
    val lift by animateFloatAsState(
        targetValue = if (lifted || dragging) 1f else 0f,
        animationSpec = tween(OrdoGesture.DRAG_SHIFT_MILLIS, easing = OrdoMotion.easing),
        label = "row-lift",
    )
    // 让位位移：其余行在 120ms 内让开一个行高
    val shift by animateFloatAsState(
        targetValue = dragShiftY,
        animationSpec = tween(OrdoGesture.DRAG_SHIFT_MILLIS, easing = OrdoMotion.easing),
        label = "row-shift",
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
            .offset { IntOffset(0, (dragOffsetY + shift).roundToInt()) }
            .graphicsLayer {
                scaleX = 1f + (OrdoGesture.DRAG_LIFT_SCALE - 1f) * lift
                scaleY = 1f + (OrdoGesture.DRAG_LIFT_SCALE - 1f) * lift
                shadowElevation = 12.dp.toPx() * lift
                shape = RoundedCornerShape(OrdoRadius.row)
                this.alpha = 1f - (1f - OrdoGesture.DRAG_ALPHA) * lift
            }
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(
                when {
                    lifted || dragging -> colors.surface
                    selected -> colors.accentSoft
                    else -> colors.canvas
                },
            )
            .onSizeChanged { rowHeightPx = it.height.toFloat() },
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
                /* 左右滑：排期 / 删除（与长按拖拽互不抢占：位移一超过 6px 就不再算点击） */
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
                /* 点击 / 长按 400ms 拖拽：一个手势只归一方 */
                .pointerInput(row.id) {
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        if (down.isConsumed) {
                            // 子控件（复选框 / 标签 / 图标按钮）已经处理这一次按下：
                            // 直接结束本次手势（awaitEachGesture 会等所有指针抬起再进入下一轮）
                            return@awaitEachGesture
                        }
                        drag.onPressDown(rowIndex)

                        // 第一阶段：400ms 内等抬起 → 点击；超时 → 抬起进入拖拽
                        val releasedInTime: Boolean? = withTimeoutOrNull(OrdoGesture.LONG_PRESS_MILLIS) {
                            while (true) {
                                val event = awaitPointerEvent()
                                val change = event.changes.firstOrNull { it.id == down.id } ?: continue
                                val delta = change.position - change.previousPosition
                                drag.onMove(delta.y)
                                if (!change.pressed) break
                            }
                            true
                        }

                        if (releasedInTime != null) {
                            when (drag.onRelease()) {
                                // 位移 <6px 才算点击：不抢走"打开详情"
                                LongPressDragState.Release.Click -> onOpen()
                                else -> Unit
                            }
                            return@awaitEachGesture
                        }

                        // 第二阶段：长按到点 → 行抬起，继续跟手；松手落库
                        if (drag.onLongPressElapsed()) {
                            onDragStart(sectionIndex, rowIndex, rowHeightPx)
                        }
                        var moved = false
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: continue
                            val delta = change.position - change.previousPosition
                            if (change.pressed) {
                                drag.onMove(delta.y)
                                if (drag.dragging) {
                                    if (!moved) {
                                        drag.onDragStarted()
                                        moved = true
                                    }
                                    change.consume()   // 拖拽期间不让列表跟着滚
                                    onDragMove(delta.y)
                                }
                            } else {
                                change.consume()
                                break
                            }
                        }
                        when (drag.onRelease()) {
                            is LongPressDragState.Release.Drop -> onDragEnd()
                            LongPressDragState.Release.Canceled -> onDragCancel()
                            else -> onDragCancel()
                        }
                    }
                }
                .semantics {
                    role = Role.Button
                    onClick(label = row.title) { onOpen(); true }
                }
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

/** 拖拽插入指示线（UI §5.4：2dp accent，左端 4dp 圆点） */
@Composable
fun DragIndicator(modifier: Modifier = Modifier) {
    val colors = OrdoTheme.colors
    Row(
        modifier
            .fillMaxWidth()
            .padding(horizontal = OrdoSpace.xs, vertical = 1.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .width(4.dp)
                .height(4.dp)
                .clip(RoundedCornerShape(OrdoRadius.pill))
                .background(colors.accent),
        )
        Spacer(Modifier.width(OrdoSpace.xs))
        Box(
            Modifier
                .weight(1f)
                .height(OrdoGesture.DRAG_INDICATOR_DP.dp)
                .background(colors.accent),
        )
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
