package com.ordo.desktop.ui.list

/**
 * 拖拽排序的**纯计算**部分(契约 §4 / 04-UI规范 §6「拖拽排序 = 鼠标拖拽」)。
 *
 * 这里不依赖 Compose,也不碰引擎:输入「行的纵向位置」与「指针位置」,输出「插入位 / 指示线位置 / 新的 id 顺序」。
 * 真正的落库由 [com.ordo.desktop.app.OrdoViewModel.reorder] → 共享核心 `OrdoEngine.reorderTodos` 完成。
 */
object ReorderMath {

    /** 一行在**内容坐标系**(滚动内容,不含视口偏移)中的纵向占位 */
    data class Span(val id: String, val top: Float, val height: Float) {
        val center: Float get() = top + height / 2f
        val bottom: Float get() = top + height
    }

    /**
     * 指针落在第几个插入位:0 = 第一行之前,[spans].size = 最后一行之后。
     * 以「行中点」为分界,指针越过后半行即视为落到下一格。
     */
    fun insertIndex(pointerY: Float, spans: List<Span>): Int {
        if (spans.isEmpty()) return 0
        var index = 0
        spans.forEach { span -> if (pointerY > span.center) index += 1 }
        return index.coerceIn(0, spans.size)
    }

    /** 插入指示线应画在内容坐标系的哪个 Y:插入位那一行的上沿;落在末尾则画在最后一行的下沿 */
    fun indicatorY(pointerY: Float, spans: List<Span>): Float {
        if (spans.isEmpty()) return pointerY
        val index = insertIndex(pointerY, spans)
        return if (index >= spans.size) spans.last().bottom else spans[index].top
    }

    /**
     * 把 [draggedId] 移动到第 [insertIndex] 个插入位。
     *
     * [insertIndex] 以**含被拖行的原列表**为基准(与 [insertIndex] 的返回值一致):
     * 插入位在被拖行之后时要减去自身占掉的一格,避免"往下拖一格却不生效"。
     */
    fun moveWithin(ids: List<String>, draggedId: String, insertIndex: Int): List<String> {
        val from = ids.indexOf(draggedId)
        if (from < 0) return ids
        val rest = ids.toMutableList().also { it.removeAt(from) }
        val to = (if (insertIndex > from) insertIndex - 1 else insertIndex).coerceIn(0, rest.size)
        rest.add(to, draggedId)
        return rest
    }

    /**
     * 用分组的新顺序替换**整表**顺序,其余分组保持原样。
     *
     * 桌上契约的 `reorderTodos(ids)` 是按"传入顺序"整批重写 `order` 字段,所以视图层的顺序必须带上全清单,
     * 否则其它分组的 order 会与本次写入重叠(契约 §2.1 的 `order` 是待办自身的排序字段)。
     */
    fun applySectionOrder(
        viewIds: List<String>,
        oldSectionIds: List<String>,
        newSectionIds: List<String>
    ): List<String> {
        if (oldSectionIds.isEmpty()) return viewIds
        val inSection = oldSectionIds.toSet()
        val out = ArrayList<String>(viewIds.size)
        var spliced = false
        viewIds.forEach { id ->
            if (id in inSection) {
                if (!spliced) {
                    out.addAll(newSectionIds)
                    spliced = true
                }
            } else {
                out.add(id)
            }
        }
        if (!spliced) out.addAll(newSectionIds)
        return out
    }

    /** 一次拖拽的落点(供 UI 与测试共用) */
    data class Drop(
        val draggedId: String,
        val insertIndex: Int,
        val sectionIds: List<String>,
        val newSectionIds: List<String>
    ) {
        val changed: Boolean get() = sectionIds != newSectionIds
    }

    /** 由「指针内容坐标 + 分组各行占位」得出落点;被拖行不在 [spans] 中时返回 null */
    fun resolveDrop(pointerY: Float, spans: List<Span>, draggedId: String): Drop? {
        if (spans.none { it.id == draggedId }) return null
        val ids = spans.map { it.id }
        val insert = insertIndex(pointerY, spans)
        return Drop(draggedId, insert, ids, moveWithin(ids, draggedId, insert))
    }
}
