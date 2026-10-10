package com.ordo.android.ui.gesture

import kotlin.math.abs
import kotlin.math.roundToInt

/* ============================================================================
 * 手势规则（UI §5.2 快加号集群 / §5.4 长按拖拽）
 *
 * 与界面无关的判定逻辑全部集中在这里，界面层只负责把指针事件喂进来、
 * 按返回的结论渲染 —— 于是"400ms""<6px""单击 vs 长按"这些硬指标可以跑 JVM 单测。
 * ========================================================================== */

object OrdoGesture {

    /** 长按时长阈值：§5.2 菜单展开、§5.4 进入拖拽，统一 400ms */
    const val LONG_PRESS_MILLIS = 400L

    /** 移动小于该距离视为点击（§5.4：避免抢走"打开详情"） */
    const val TAP_SLOP_PX = 6f

    /** 快加号按压 scale（§5.2：90ms） */
    const val FAB_PRESS_SCALE = 0.96f

    /** 长按到 400ms 时轻微放大并保持（§5.2：提示"可以松手了"） */
    const val FAB_LONG_PRESS_SCALE = 1.06f

    /** 菜单展开时按钮旋转角度（§5.2：「+」变「×」） */
    const val FAB_MENU_ROTATION_DEGREES = 45f

    /** 拖拽抬起：scale 1.02 + 12dp 投影 + 背景转 surface（§5.4） */
    const val DRAG_LIFT_SCALE = 1.02f

    /** 拖拽中被拖行透明度（§5.4） */
    const val DRAG_ALPHA = 0.55f

    /** 插入指示线粗细（§5.4：2dp accent，左端 4dp 圆点） */
    const val DRAG_INDICATOR_DP = 2

    /** 其余行让位时长（§5.4：120ms） */
    const val DRAG_SHIFT_MILLIS = 120
}

/** 一次按下的最终归属 */
enum class FabGesture {
    /** 单击 → 打开行内输入行（菜单已展开时改为收起菜单） */
    CLICK,

    /** 长按 400ms → 展开快捷菜单 */
    MENU,

    /** 位移过大 / 其它 → 两个分支都不触发 */
    IGNORE,
}

/** 菜单已展开时单击的语义 */
enum class FabClickAction { OPEN_COMPOSER, CLOSE_MENU }

/** 快加号（§5.2：只保留一个 FAB，单击 / 长按 400ms 两个分支） */
object QuickAddGesture {

    /**
     * 单击 vs 长按的分支判定。
     *
     * @param holdMillis 按下到抬起的时长
     * @param movedPx 按下期间累计移动距离（像素）
     */
    fun classify(holdMillis: Long, movedPx: Float): FabGesture = when {
        movedPx >= OrdoGesture.TAP_SLOP_PX -> FabGesture.IGNORE
        holdMillis >= OrdoGesture.LONG_PRESS_MILLIS -> FabGesture.MENU
        else -> FabGesture.CLICK
    }

    /** 菜单展开 → 45°，收起 → 0° */
    fun rotationDegrees(menuOpen: Boolean): Float =
        if (menuOpen) OrdoGesture.FAB_MENU_ROTATION_DEGREES else 0f

    /** 按压 → 0.96；长按到点 → 1.06 并保持；否则 1.0 */
    fun scale(pressed: Boolean, longPressReached: Boolean): Float = when {
        longPressReached -> OrdoGesture.FAB_LONG_PRESS_SCALE
        pressed -> OrdoGesture.FAB_PRESS_SCALE
        else -> 1f
    }

    /** 菜单展开中单击 = 收起菜单（**不**打开输入行） */
    fun clickAction(menuOpen: Boolean): FabClickAction =
        if (menuOpen) FabClickAction.CLOSE_MENU else FabClickAction.OPEN_COMPOSER
}

/**
 * 长按拖拽状态机（§5.4）。
 *
 * ```
 * 按下 ──<6px 且 <400ms 抬起 ──▶ 点击（打开详情）
 *   │
 *   ├── ≥6px 且未到 400ms ──▶ 什么也不做（不算点击，也不进拖拽）
 *   │
 *   └── 400ms 到点 ──▶ ARMED（行抬起：scale 1.02 + 12dp 投影）
 *                        │
 *                        └── 继续移动 ──▶ DRAGGING（插入指示线 / 其余行让位）
 *                                          │
 *                                          松手 → 落库（位置未变则不写库）
 *                                          返回键 → 取消，回原位且不写库
 * ```
 */
class LongPressDragState {

    enum class Phase { IDLE, PRESSED, ARMED, DRAGGING }

    var phase: Phase = Phase.IDLE
        private set

    /** 起始槽位（同一分组内的下标） */
    var originIndex: Int = -1
        private set

    /** 当前插入槽位 */
    var targetIndex: Int = -1
        private set

    var movedPx: Float = 0f
        private set

    /** 抬起时是否还算"点击"（<6px） */
    var clickCandidate: Boolean = false
        private set

    /** 行抬起态（长按已触发：scale 1.02 + 投影 + 背景 surface） */
    val lifted: Boolean get() = phase == Phase.ARMED || phase == Phase.DRAGGING

    val dragging: Boolean get() = phase == Phase.DRAGGING

    /** 一次按下的结局 */
    sealed interface Release {
        /** 打开详情 */
        data object Click : Release

        /**
         * 拖拽落点。
         * @param committed 位置是否变化（false = 位置未变，**不写库**）
         */
        data class Drop(val committed: Boolean, val from: Int, val to: Int) : Release

        /** 取消（BackHandler / 手势被系统打断）：回原位，不写库 */
        data object Canceled : Release
    }

    fun onPressDown(index: Int): LongPressDragState {
        phase = Phase.PRESSED
        originIndex = index
        targetIndex = index
        movedPx = 0f
        clickCandidate = true
        return this
    }

    fun onMove(deltaPx: Float) {
        if (phase == Phase.IDLE) return
        movedPx += abs(deltaPx)
        if (movedPx >= OrdoGesture.TAP_SLOP_PX) {
            clickCandidate = false
            if (phase == Phase.ARMED) phase = Phase.DRAGGING
        }
    }

    /** 400ms 长按到点（由界面层的超时回调驱动）：进入抬起态返回 true */
    fun onLongPressElapsed(): Boolean {
        if (phase != Phase.PRESSED) return false
        if (movedPx >= OrdoGesture.TAP_SLOP_PX) {
            clickCandidate = false
            return false
        }
        phase = Phase.ARMED
        clickCandidate = false
        return true
    }

    /** 抬起态下开始拖动 */
    fun onDragStarted(): Boolean {
        if (phase != Phase.ARMED) return false
        phase = Phase.DRAGGING
        return true
    }

    fun onTargetIndex(index: Int) {
        if (phase == Phase.DRAGGING) targetIndex = index
    }

    fun onRelease(): Release = when (phase) {
        Phase.IDLE -> Release.Canceled

        Phase.PRESSED -> {
            val click = clickCandidate
            reset()
            if (click) Release.Click else Release.Canceled
        }

        // 长按已抬起但从未拖动：位置未变 → 不写库，也不打开详情
        Phase.ARMED -> {
            val from = originIndex
            reset()
            Release.Drop(committed = false, from = from, to = from)
        }

        Phase.DRAGGING -> {
            val from = originIndex
            val to = targetIndex
            reset()
            Release.Drop(committed = to != from, from = from, to = to)
        }
    }

    /** BackHandler 取消：回原位，不写库 */
    fun onCancel(): Release {
        reset()
        return Release.Canceled
    }

    private fun reset() {
        phase = Phase.IDLE
        movedPx = 0f
        clickCandidate = false
    }
}

/** 拖拽过程中的插入槽位换算 */
object DragReorder {

    /**
     * 由纵向拖动位移推算插入槽位。
     *
     * @param originIndex 起始槽位
     * @param offsetYPx 相对起始位置的纵向位移（向上为负）
     * @param rowHeightPx 被拖行的实测高度（≤0 时不下发新槽位）
     * @param minIndex 本分组允许的最小槽位（越界即夹紧：不允许跨分组移动）
     * @param maxIndex 本分组允许的最大槽位
     */
    fun targetIndex(
        originIndex: Int,
        offsetYPx: Float,
        rowHeightPx: Float,
        minIndex: Int,
        maxIndex: Int,
    ): Int {
        if (rowHeightPx <= 0f) return originIndex.coerceIn(minIndex, maxIndex)
        val steps = (offsetYPx / rowHeightPx).roundToInt()
        return (originIndex + steps).coerceIn(minIndex, maxIndex)
    }

    /** 其余行需要让位的槽位数（>0 向下让位，<0 向上让位） */
    fun shiftFor(index: Int, from: Int, to: Int): Int = when {
        index == from -> 0
        from < to && index in (from + 1)..to -> -1
        to < from && index in to until from -> 1
        else -> 0
    }
}
