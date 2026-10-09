package com.ordo.desktop.ui.list

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * 拖拽排序的运行时状态(列表容器持有,列表内所有分组共用)。
 *
 * 坐标系有两套,换算只在这里做一次:
 *  - **窗口坐标**(`rootY`):指针事件、`onGloballyPositioned` 给出的值;
 *  - **内容坐标**(`contentY`):滚动内容自身的纵坐标,行占位与指示线都用它,
 *    换算公式 `contentY = rootY - 视口顶部 + 已滚动量`。
 *
 * 行占位登记用普通 [MutableMap](只在布局回调里写、在指针回调/绘制里读),避免把布局阶段的状态写入快照系统。
 */
@Stable
class ListReorderState {

    /** 滚动视口在窗口中的顶部 Y(由列表容器在布局回调里写入) */
    var viewportTop: Float = 0f

    /** 滚动视口高度,用于拖到边缘时自动滚动 */
    var viewportHeight: Float = 0f

    /** 当前滚动量(由容器用 snapshotFlow 同步) */
    var scrollOffset by mutableStateOf(0f)

    /** 正在被拖动的待办 id;null = 没有拖拽 */
    var draggedId by mutableStateOf<String?>(null)
        private set

    /** 被拖行所属分组(列表里的分组序号) */
    var sectionIndex by mutableStateOf(-1)
        private set

    /** 被拖行在分组内的原始下标 */
    var startIndex by mutableStateOf(-1)
        private set

    /** 指针当前位置(内容坐标),指示线由它实时算出 */
    var pointerContentY by mutableStateOf(0f)
        private set

    private val spans = mutableMapOf<String, Row>()

    val active: Boolean get() = draggedId != null

    /** 窗口坐标 → 内容坐标 */
    fun contentYOf(rootY: Float): Float = rootY - viewportTop + scrollOffset

    /** 内容坐标 → 窗口坐标(指针事件用的是窗口坐标) */
    fun rootYOf(contentY: Float): Float = contentY + viewportTop - scrollOffset

    /** 登记一行(内容坐标) */
    fun register(id: String, section: Int, index: Int, contentTop: Float, height: Float) {
        spans[id] = Row(id, section, index, contentTop, height)
    }

    /** 某一分组内、按显示顺序排列的行占位 */
    fun spansOf(section: Int): List<ReorderMath.Span> =
        spans.values.asSequence()
            .filter { it.section == section }
            .sortedBy { it.index }
            .map { ReorderMath.Span(it.id, it.top, it.height) }
            .toList()

    fun spanOf(id: String): ReorderMath.Span? =
        spans[id]?.let { ReorderMath.Span(it.id, it.top, it.height) }

    fun begin(id: String, section: Int, index: Int, pointerContentY: Float) {
        draggedId = id
        sectionIndex = section
        startIndex = index
        this.pointerContentY = pointerContentY
    }

    fun moveTo(pointerContentY: Float) {
        if (active) this.pointerContentY = pointerContentY
    }

    fun cancel() {
        draggedId = null
        sectionIndex = -1
        startIndex = -1
    }

    /** 当前落点(以被拖行所属分组为范围);未在拖动时返回 null */
    fun drop(): ReorderMath.Drop? {
        val id = draggedId ?: return null
        return ReorderMath.resolveDrop(pointerContentY, spansOf(sectionIndex), id)
    }

    /** 指示线在内容坐标系中的 Y;未在拖动时返回 null */
    fun indicatorY(): Float? {
        if (!active) return null
        val rows = spansOf(sectionIndex)
        if (rows.isEmpty()) return null
        return ReorderMath.indicatorY(pointerContentY, rows)
    }

    private data class Row(
        val id: String,
        val section: Int,
        val index: Int,
        val top: Float,
        val height: Float
    )
}

/**
 * 交给 [TodoRow] 的拖拽句柄描述。
 *
 * 行只负责「登记自己的位置」与「把指针位置转发回来」,顺序怎么算、要不要落库由列表容器决定。
 */
class RowDragHandle(
    val todoId: String,
    private val state: ListReorderState,
    private val sectionIndex: Int,
    private val index: Int,
    private val onEnd: () -> Unit,
    private val onCancel: () -> Unit
) {
    /** 本行是否正被拖动(读取 [ListReorderState.draggedId],拖动开始/结束会触发重组) */
    val dragging: Boolean get() = state.draggedId == todoId

    /** 行在窗口中的位置 → 内容坐标并登记(布局回调里调用) */
    fun register(rootY: Float, height: Float) {
        state.register(todoId, sectionIndex, index, state.contentYOf(rootY), height)
    }

    fun begin(pointerRootY: Float) = state.begin(todoId, sectionIndex, index, state.contentYOf(pointerRootY))

    fun move(pointerRootY: Float) = state.moveTo(state.contentYOf(pointerRootY))

    fun end() = onEnd()

    fun cancel() = onCancel()
}
