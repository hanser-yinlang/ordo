package com.ordo.desktop.ui.list

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.detectDragGestures
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
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
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
import com.ordo.desktop.ui.common.plainPreview
import com.ordo.desktop.ui.theme.OrdoMotion
import com.ordo.desktop.ui.theme.OrdoSize
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.motionMillis
import com.ordo.desktop.ui.theme.ordoColors

/**
 * 待办行(04-UI规范 §4):高 38,左侧 20 圆形复选框,标题 15/22,元信息行 13/18。
 * 悬浮时右侧出现"安排时间"按钮与拖拽手柄(04-UI规范 §6「拖拽排序 = 鼠标拖拽」);完成动效见 §5。
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
            // 行占位登记:拖拽时据此算插入位(窗口坐标 → 内容坐标)
            .onGloballyPositioned { coords ->
                dragHandle?.register(coords.positionInRoot().y, coords.size.height.toFloat())
            },
        selected = selected || highlighted || dragging,
        // 拖动中不打开详情(松开手柄才算一次拖拽,普通点击行为不变)
        onClick = { if (!dragging) onOpen() }
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
            if (hovered || selected || dragging) {
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

/**
 * 行尾拖拽手柄:按住它移动即可排序。
 *
 * 手势只落在手柄上,因此不会与行的"点击打开详情"抢事件;拖动一旦越过触摸阈值,
 * 行的 clickable 会因为指针被消费而自动取消,不会误开详情。
 */
@Composable
private fun DragHandle(handle: RowDragHandle) {
    val colors = ordoColors
    // 手柄在窗口中的位置:指针位移 → 窗口坐标 → 内容坐标(交给列表容器)
    val anchor = remember { DragAnchor() }
    val latest = rememberUpdatedState(handle)

    Box(
        Modifier
            .size(28.dp)
            .onGloballyPositioned { anchor.rootY = it.positionInRoot().y }
            .pointerInput(handle.todoId) {
                detectDragGestures(
                    onDragStart = { offset -> latest.value.begin(anchor.rootY + offset.y) },
                    onDrag = { change, _ ->
                        change.consume()
                        latest.value.move(anchor.rootY + change.position.y)
                    },
                    onDragEnd = { latest.value.end() },
                    onDragCancel = { latest.value.cancel() }
                )
            },
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = OrdoIcons.Drag,
            contentDescription = "拖动排序",
            tint = colors.textTertiary,
            modifier = Modifier.size(15.dp)
        )
    }
}

/** 不参与快照的手柄位置缓存(只在手势回调里读,避免布局阶段写状态) */
private class DragAnchor {
    var rootY: Float = 0f
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
