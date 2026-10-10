package com.ordo.desktop.ui.list

/**
 * 被拖起的行会整体 `scale 1.02`(04-UI规范 §5.4「行抬起」)。
 *
 * 这个缩放**同样作用在指针坐标上**:行内部的指针节点收到的局部坐标被同一比例缩小了,
 * 所以"局部坐标 + 行的窗口坐标"这种朴素换算会随拖动距离线性偏掉 ——
 * 实测拖到第三行时落点差 9px(正好是 2% × 468px),于是"往下拖两格"只落一格。
 *
 * 这里以**按下(长按成立 / 越过触摸阈值)那一刻**为基准做位移换算:
 * 那一刻行还没有被缩放,所以基准值是精确的;之后的位移再按抬起比例还原。
 *
 * ```
 * rootY = startRootY + (localY - startLocalY) × liftScale
 * ```
 */
class LiftPointerMapper(private val liftScale: Float = LIFT_SCALE) {

    /** 基准:按下点(或长按成立点)的窗口坐标 */
    var startRootY: Float = 0f
        private set

    /** 基准:按下点在该指针节点坐标系里的纵向位置 */
    var startLocalY: Float = 0f
        private set

    var started: Boolean = false
        private set

    /** 手势开始时调用一次(此时行尚未缩放,两个值都精确) */
    fun begin(rootY: Float, localY: Float) {
        startRootY = rootY
        startLocalY = localY
        started = true
    }

    /** 拖动中的局部坐标 → 窗口坐标(按抬起比例还原位移) */
    fun rootYOf(localY: Float): Float =
        if (started) startRootY + (localY - startLocalY) * liftScale else startRootY

    fun reset() {
        started = false
    }

    companion object {
        /** 行抬起时的缩放(§5.4) */
        const val LIFT_SCALE = 1.02f
    }
}
