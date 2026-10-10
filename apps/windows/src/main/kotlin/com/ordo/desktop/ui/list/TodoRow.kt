package com.ordo.desktop.ui.list

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ordo.core.model.Status
import com.ordo.core.model.Todo
import com.ordo.desktop.ui.common.MetaPill
import com.ordo.desktop.ui.common.OrdoCheckbox
import com.ordo.desktop.ui.common.OrdoChip
import com.ordo.desktop.ui.common.OrdoFormat
import com.ordo.desktop.ui.common.OrdoIconButton
import com.ordo.desktop.ui.common.OrdoIcons
import com.ordo.desktop.ui.common.HoverRow
import com.ordo.desktop.ui.common.detectPressGesture
import com.ordo.desktop.ui.common.plainPreview
import com.ordo.desktop.ui.theme.OrdoMotion
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSize
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.motionMillis
import com.ordo.desktop.ui.theme.ordoColors

/**
 * 待办行(04-UI规范 §4):高 38,左侧 20 圆形复选框,标题 15/22,元信息行 13/18。
 * 悬浮时右侧出现"安排时间"按钮与拖拽手柄;完成动效见 §5。
 *
 * **长按拖拽**(04-UI规范 §5.4):在行上按住 400ms 进入拖拽(移动 <6px 视为点击,不抢"打开详情");
 * 行尾手柄仍然保留,作为"这一行可拖"的可见提示,并且**在手柄上按下可直接拖**(无需长按)。
 */
@Composable
fun TodoRow(
    todo: Todo,
    selected: Boolean,
    showWhen: Boolean,
    completing: Boolean,
    onToggle: () -> Unit,
    onOpen: () -> Unit,
    onSchedule: () -> Unit,
    onOpenTag: (String) -> Unit,
    modifier: Modifier = Modifier,
    onRestore: (() -> Unit)? = null,
    showCompletion: Boolean = false,
    highlighted: Boolean = false,
    dragHandle: RowDragHandle? = null
) {
    val colors = ordoColors
    val closed = todo.status.isClosed
    val fading = completing || closed
    val dragging = dragHandle?.dragging == true
    // 行在窗口中的纵坐标:长按成立时用它把"指针位置"换算成内容坐标
    val anchor = remember { DragAnchor() }
    // 拖动中行被 scale 1.02,行内指针坐标同样被缩放 —— 位移必须按比例还原,见 LiftPointerMapper
    val lift = remember { LiftPointerMapper() }
    val density = LocalDensity.current
    var held by remember { mutableStateOf(false) }

    val titleColor by animateColorAsState(
        targetValue = if (fading) colors.textTertiary else colors.textPrimary,
        animationSpec = tween(motionMillis(OrdoMotion.BASE)),
        label = "todoTitleColor"
    )

    HoverRow(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = OrdoSize.rowHeight)
            .alpha(if (dragging) 0.55f else 1f)
            // 抬起(§5.4 进入拖拽):scale 1.02 + 12dp 投影 + 背景转 surface
            .graphicsLayer {
                if (dragging) {
                    scaleX = LiftPointerMapper.LIFT_SCALE
                    scaleY = LiftPointerMapper.LIFT_SCALE
                    shadowElevation = with(density) { LIFT_SHADOW.toPx() }
                    shape = RoundedCornerShape(OrdoRadius.row)
                    clip = false
                }
            }
            .background(if (dragging) colors.surface else Color.Transparent, RoundedCornerShape(OrdoRadius.row))
            // 行占位登记:拖拽时据此算插入位(窗口坐标 → 内容坐标)。
            // 拖动中行被缩放过,positionInRoot 会带上缩放后的偏移 —— 那时不能再登记,否则落点会漂。
            .onGloballyPositioned { coords ->
                val top = coords.positionInRoot().y
                anchor.rootY = top
                anchor.height = coords.size.height.toFloat()
                if (!dragging) dragHandle?.register(top, coords.size.height.toFloat())
            },
        selected = selected || highlighted || dragging,
        // 拖动中不打开详情(松开手柄才算一次拖拽,普通点击行为不变)
        onClick = { if (!dragging) onOpen() },
        gestureModifier = if (dragHandle != null) {
            // 长按 400ms → 进入拖拽;手柄上的按下走自己的手势(无需长按,见 DragHandle)
            Modifier.pointerInput(dragHandle.todoId) {
                val latest = dragHandle
                detectPressGesture(
                    onArmedChange = { armed -> held = armed },
                    onLongPress = { position ->
                        // 长按成立那一刻行还没被缩放:两个基准值都是精确的
                        val startRootY = anchor.rootY + position.y
                        latest.begin(startRootY)
                        lift.begin(startRootY, position.y)
                    },
                    onMoveAfterLongPress = { position -> latest.move(lift.rootYOf(position.y)) },
                    onReleaseAfterLongPress = { latest.end() }
                    // 点击交给外层 clickable(打开详情),这里不处理
                )
            }
        } else {
            Modifier
        }
    ) { hovered ->
        Row(
            Modifier.fillMaxWidth().padding(horizontal = OrdoSpace.s, vertical = 4.dp),
            verticalAlignment = Alignment.Top
        ) {
            Spacer(Modifier.width(2.dp))
            OrdoCheckbox(
                checked = closed || completing,
                canceled = todo.status == Status.CANCELED,
                onClick = onToggle,
                modifier = Modifier.padding(top = 2.dp)
            )
            Spacer(Modifier.width(OrdoSpace.s))
            Column(Modifier.weight(1f)) {
                Text(
                    text = todo.title.ifBlank { "(无标题)" },
                    style = OrdoType.body,
                    color = titleColor,
                    textDecoration = if (fading) TextDecoration.LineThrough else null,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
                val preview = plainPreview(todo.note)
                if (preview.isNotEmpty() && !closed) {
                    Text(
                        text = preview,
                        style = OrdoType.caption,
                        color = colors.textTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                MetaRow(todo, showWhen, showCompletion, onOpenTag)
            }
            if (hovered || selected || dragging || held) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (onRestore != null) {
                        OrdoIconButton(OrdoIcons.Restore, "恢复为未完成", onRestore, size = 28.dp, iconSize = 15.dp)
                    }
                    OrdoIconButton(OrdoIcons.Calendar, "安排时间", onSchedule, size = 28.dp, iconSize = 15.dp)
                    if (dragHandle != null) DragHandle(dragHandle)
                }
            }
        }
    }
}

/** 被拖起时的投影(§5.4:12dp);缩放比例见 [LiftPointerMapper.LIFT_SCALE] */
private val LIFT_SHADOW = 12.dp

/**
 * 行尾拖拽手柄(04-UI规范 §5.4):**这一行可拖**的可见提示。
 *
 * 手柄是"免长按"的入口:在它上面按下即可直接拖动,不必等 400ms;
 * 手势只落在手柄上,所以行级的长按判定不会与它抢(手柄会把按下事件 consume 掉,
 * 行级手势看到已消费的按下直接作废,不会重复 begin 同一行)。
 */
@Composable
private fun DragHandle(handle: RowDragHandle) {
    val colors = ordoColors
    // 手柄在窗口中的位置:指针位移 → 窗口坐标 → 内容坐标(交给列表容器)
    val anchor = remember { DragAnchor() }
    val lift = remember { LiftPointerMapper() }
    val latest = rememberUpdatedState(handle)
    val touchSlop = LocalViewConfiguration.current.touchSlop

    Box(
        Modifier
            .size(28.dp)
            .onGloballyPositioned { anchor.rootY = it.positionInRoot().y }
            .pointerInput(handle.todoId) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    // 手柄自己吃掉这次按下:行级长按据此作废(同一行不会被 begin 两次)
                    down.consume()
                    var dragging = false
                    try {
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            if (change.changedToUpIgnoreConsumed()) {
                                if (dragging) latest.value.end() else latest.value.cancel()
                                break
                            }
                            if (!dragging &&
                                (change.position - down.position).getDistance() > touchSlop
                            ) {
                                dragging = true
                                // 越过阈值这一刻行还没被抬起:基准精确
                                val startRootY = anchor.rootY + down.position.y
                                latest.value.begin(startRootY)
                                lift.begin(startRootY, down.position.y)
                            }
                            if (dragging) {
                                // 抬起后行 scale 1.02:位移要按比例还原,否则落点会差 2%
                                latest.value.move(lift.rootYOf(change.position.y))
                                change.consume()
                            }
                        }
                    } finally {
                        // 兜底:手势协程被取消(行被回收 / 窗口关闭)时不要把拖拽状态留在原地
                        if (latest.value.dragging) latest.value.cancel()
                    }
                }
            },
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = OrdoIcons.Drag,
            contentDescription = "拖动排序(长按行亦可)",
            tint = colors.textTertiary,
            modifier = Modifier.size(15.dp)
        )
    }
}

/** 不参与快照的手柄位置缓存(只在手势回调里读,避免布局阶段写状态) */
private class DragAnchor {
    var rootY: Float = 0f
    var height: Float = 0f
}

@Composable
private fun MetaRow(todo: Todo, showWhen: Boolean, showCompletion: Boolean, onOpenTag: (String) -> Unit) {
    val colors = ordoColors
    val items = mutableListOf<@Composable () -> Unit>()

    if (showWhen) {
        val label = OrdoFormat.whenLabel(todo)
        val highlight = todo.`when` == com.ordo.core.model.When.TODAY ||
            todo.`when` == com.ordo.core.model.When.EVENING
        items.add {
            MetaPill(
                icon = OrdoIcons.Calendar,
                text = label,
                tint = if (highlight) colors.accent else colors.textSecondary
            )
        }
    }
    todo.tags.forEach { tag ->
        items.add { OrdoChip(tag, onClick = { onOpenTag(tag) }) }
    }
    OrdoFormat.checklistLabel(todo)?.let { label ->
        items.add { MetaPill(icon = OrdoIcons.Checklist, text = label, tint = colors.textSecondary) }
    }
    if (todo.note.isNotBlank()) {
        items.add { MetaPill(icon = OrdoIcons.Note, tint = colors.textTertiary) }
    }
    if (todo.repeat != null) {
        items.add { MetaPill(icon = OrdoIcons.Repeat, tint = colors.textSecondary) }
    }
    todo.reminder?.let {
        items.add {
            MetaPill(
                icon = OrdoIcons.Bell,
                text = OrdoFormat.reminderLabel(todo),
                tint = if (OrdoFormat.reminderPast(todo)) colors.danger else colors.textSecondary
            )
        }
    }
    todo.deadline?.let {
        items.add {
            MetaPill(
                icon = OrdoIcons.Flag,
                text = OrdoFormat.deadlineLabel(todo),
                tint = if (OrdoFormat.deadlineOverdue(todo)) colors.danger else colors.textSecondary
            )
        }
    }
    if (showCompletion) {
        OrdoFormat.completedLabel(todo)?.let { label ->
            items.add { MetaPill(icon = OrdoIcons.CheckCircle, text = label, tint = colors.textTertiary) }
        }
    }
    if (items.isEmpty()) return
    Spacer(Modifier.width(0.dp))
    Row(
        Modifier.padding(top = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        items.forEach { it() }
    }
}
