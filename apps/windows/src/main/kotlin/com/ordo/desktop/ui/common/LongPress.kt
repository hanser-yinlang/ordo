package com.ordo.desktop.ui.common

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import kotlin.math.hypot
import kotlinx.coroutines.withTimeoutOrNull

/**
 * 长按手势的统一参数(04-UI规范 §5.2 快加号 / §5.4 长按拖拽)。
 *
 * 两处用的是**同一套阈值**:按住 400ms 才算长按;在这之前移动超过 6px 就不再是"点击",
 * 长按也随之取消(把指针让给滚动等其它手势)。
 */
object LongPressSpec {

    /** 长按阈值(毫秒) */
    const val HOLD_MILLIS = 400L

    /** 移动容差(px):小于它视为点击,不进入拖拽 */
    const val MOVE_TOLERANCE_PX = 6f
}

/** 一次"按下 → (移动)→ 抬起"的判定结果 */
enum class PressOutcome {
    /** 还在按下状态:既没到 400ms,也没抬起 */
    PENDING,

    /** 抬起时仍满足"未到 400ms 且移动 <6px"→ 点击 */
    CLICK,

    /** 按住满 400ms → 长按成立 */
    LONG_PRESS,

    /** 移动超过容差(在长按成立之前)→ 这次按下既不是点击也不是长按 */
    CANCELLED
}

/**
 * 长按判定器(纯逻辑,时间从外面喂进来,因此可以逐毫秒断言)。
 *
 * 状态迁移:
 * ```
 * down ──tick(≥400ms)──► LONG_PRESS ──up──► LONG_PRESS(由拖拽收尾,不再算点击)
 *   │                        ▲
 *   ├─ move(>6px) ──► CANCELLED
 *   └─ up(<400ms 且移动<6px) ──► CLICK
 * ```
 */
class LongPressDetector(
    private val holdMillis: Long = LongPressSpec.HOLD_MILLIS,
    private val tolerancePx: Float = LongPressSpec.MOVE_TOLERANCE_PX
) {

    var outcome: PressOutcome = PressOutcome.PENDING
        private set

    private var downX = 0f
    private var downY = 0f
    private var downAt = 0L

    /** 按下的瞬间 */
    fun down(x: Float, y: Float, nowMillis: Long) {
        downX = x
        downY = y
        downAt = nowMillis
        outcome = PressOutcome.PENDING
    }

    /** 距离长按成立还差多少毫秒(≤0 表示已经到点) */
    fun remainingMillis(nowMillis: Long): Long =
        if (outcome == PressOutcome.PENDING) (holdMillis - (nowMillis - downAt)).coerceAtLeast(0L) else 0L

    /** 时间推进:到点且没被取消 → 长按成立(界面每帧 / 测试直接调用) */
    fun tick(nowMillis: Long): PressOutcome {
        if (outcome == PressOutcome.PENDING && nowMillis - downAt >= holdMillis) {
            outcome = PressOutcome.LONG_PRESS
        }
        return outcome
    }

    /**
     * 指针移动。
     *
     * 长按成立**之前**越过容差 → [PressOutcome.CANCELLED](这次按下作废,不抢滚动);
     * 长按成立**之后**的移动是拖拽本身,不再改变判定。
     */
    fun move(x: Float, y: Float, nowMillis: Long): PressOutcome {
        if (outcome == PressOutcome.PENDING) {
            val distance = hypot(x - downX, y - downY)
            if (distance > tolerancePx) {
                outcome = PressOutcome.CANCELLED
            } else {
                tick(nowMillis)
            }
        }
        return outcome
    }

    /**
     * 抬起。
     *
     * 未到 400ms 且移动一直小于容差 → [PressOutcome.CLICK];
     * 已经长按成立 → 仍然是 [PressOutcome.LONG_PRESS](由调用方按拖拽收尾,不再触发点击)。
     */
    fun up(nowMillis: Long): PressOutcome {
        if (outcome == PressOutcome.PENDING) {
            tick(nowMillis)
            if (outcome == PressOutcome.PENDING) outcome = PressOutcome.CLICK
        }
        return outcome
    }

    /** 被系统取消(指针被抢走 / 窗口失焦) */
    fun cancel(): PressOutcome {
        if (outcome == PressOutcome.PENDING) outcome = PressOutcome.CANCELLED
        return outcome
    }

    /** 本次按下累计移动距离(供测试与调试展示) */
    fun distanceFrom(x: Float, y: Float): Float = hypot(x - downX, y - downY)
}

/**
 * 「按下 → 400ms 长按 / 抬起即点击」的手势(快加号与待办行共用)。
 *
 * 与 `detectTapGestures(onLongPress = …)` 的区别:阈值是我们自己的 400ms 常量,
 * 并且长按成立后**由本手势独占指针**(consume),这样:
 *  - 外层的 `clickable` 会因为事件被消费而取消点击(长按拖完一行不会顺手打开详情);
 *  - 父级滚动容器也不会在拖拽过程中跟着滚(自动滚动由列表自己按边缘触发)。
 *
 * @param onLongPress 按住满 400ms 时触发,参数是**最后一次已知的指针位置**(相对本节点)
 * @param onMoveAfterLongPress 长按成立后的拖动回调(相对本节点的位置)
 * @param onReleaseAfterLongPress 长按成立后抬起
 */
suspend fun PointerInputScope.detectPressGesture(
    holdMillis: Long = LongPressSpec.HOLD_MILLIS,
    tolerancePx: Float = LongPressSpec.MOVE_TOLERANCE_PX,
    onPressedChange: (Boolean) -> Unit = {},
    onArmedChange: (Boolean) -> Unit = {},
    onLongPress: (Offset) -> Unit,
    onMoveAfterLongPress: (Offset) -> Unit = {},
    onReleaseAfterLongPress: () -> Unit = {},
    onClick: () -> Unit = {}
) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        // 按下已被更内层的手势吃掉(例如行尾拖拽手柄)→ 本次按下不参与长按判定
        if (down.isConsumed) return@awaitEachGesture
        val detector = LongPressDetector(holdMillis, tolerancePx)
        var lastPosition = down.position
        detector.down(down.position.x, down.position.y, nowOf())
        onPressedChange(true)
        var armed = false
        try {
            while (true) {
                val event = if (armed) {
                    awaitPointerEvent()
                } else {
                    withTimeoutOrNull(detector.remainingMillis(nowOf())) { awaitPointerEvent() }
                }
                if (event == null) {
                    // 时间到:长按成立(指针仍然按着,后续交给拖拽)
                    if (detector.tick(nowOf()) == PressOutcome.LONG_PRESS) {
                        armed = true
                        onArmedChange(true)
                        onLongPress(lastPosition)
                    }
                    continue
                }
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                val now = nowOf()
                val outcome = detector.move(change.position.x, change.position.y, now)
                if (!change.changedToUpIgnoreConsumed()) lastPosition = change.position
                if (change.changedToUpIgnoreConsumed()) {
                    when (detector.up(now)) {
                        PressOutcome.CLICK -> onClick()
                        PressOutcome.LONG_PRESS -> onReleaseAfterLongPress()
                        else -> Unit
                    }
                    break
                }
                if (armed) {
                    onMoveAfterLongPress(change.position)
                    change.consume()
                } else if (outcome == PressOutcome.CANCELLED || change.isConsumed) {
                    // 移出容差 / 事件已被别的处理器消费:这次按下作废
                    detector.cancel()
                    break
                }
            }
        } finally {
            onPressedChange(false)
            onArmedChange(false)
        }
    }
}

/** 单调时钟:长按阈值按真实时间计算(手势本身就是实时的) */
private fun nowOf(): Long = System.nanoTime() / 1_000_000L
