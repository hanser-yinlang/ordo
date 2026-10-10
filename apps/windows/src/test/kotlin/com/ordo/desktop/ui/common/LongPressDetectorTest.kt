package com.ordo.desktop.ui.common

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 长按阈值判定(04-UI规范 §5.4 / §5.2 共用同一套参数)。
 *
 * 这是"长按拖拽"与"快加号长按菜单"的公共地基,所以逐毫秒、逐像素地钉住:
 *  - 按住 **400ms** 才算长按;
 *  - 在这之前移动 **≥6px** 就不再是点击,也不进入拖拽(把指针让给滚动);
 *  - 长按成立之后的移动是拖拽本身,**不再取消**任何东西。
 */
class LongPressDetectorTest {

    private fun detector() = LongPressDetector()

    @Test
    fun `400ms 之前抬起就是点击`() {
        val d = detector()
        d.down(x = 10f, y = 10f, nowMillis = 0L)

        assertEquals(PressOutcome.PENDING, d.tick(399L))
        assertEquals(PressOutcome.CLICK, d.up(399L))
    }

    @Test
    fun `按住满 400ms 判定为长按`() {
        val d = detector()
        d.down(0f, 0f, 0L)

        assertEquals(PressOutcome.PENDING, d.tick(399L))
        assertEquals(PressOutcome.LONG_PRESS, d.tick(400L))
    }

    @Test
    fun `松开时刚好到 400ms 也算长按`() {
        val d = detector()
        d.down(0f, 0f, 0L)

        assertEquals(PressOutcome.LONG_PRESS, d.up(400L))
    }

    @Test
    fun `长按成立后抬起不再是点击`() {
        val d = detector()
        d.down(0f, 0f, 0L)
        assertEquals(PressOutcome.LONG_PRESS, d.tick(500L))

        assertEquals("长按之后抬手由拖拽收尾,不能顺手打开详情", PressOutcome.LONG_PRESS, d.up(900L))
    }

    @Test
    fun `400ms 之前移动超过 6px 就不是点击`() {
        val d = detector()
        d.down(0f, 0f, 0L)

        assertEquals(PressOutcome.CANCELLED, d.move(7f, 0f, 100L))
        assertEquals(PressOutcome.CANCELLED, d.up(150L))
    }

    @Test
    fun `移动不超过 6px 仍然算点击`() {
        val d = detector()
        d.down(0f, 0f, 0L)

        // 3-4-5 直角三角形:位移正好 5px,小于 6px 的容差
        assertEquals(PressOutcome.PENDING, d.move(3f, 4f, 100L))
        assertEquals(PressOutcome.CLICK, d.up(300L))
    }

    @Test
    fun `容差边界是 6px`() {
        val d = detector()
        d.down(0f, 0f, 0L)
        assertEquals("正好 6px 还不算越过容差", PressOutcome.PENDING, d.move(6f, 0f, 50L))
        assertEquals(PressOutcome.CANCELLED, d.move(6.5f, 0f, 60L))
    }

    @Test
    fun `长按成立之后的移动不再取消`() {
        val d = detector()
        d.down(0f, 0f, 0L)
        d.tick(400L)

        assertEquals("拖拽就是长按之后的移动", PressOutcome.LONG_PRESS, d.move(120f, 0f, 450L))
        assertEquals(PressOutcome.LONG_PRESS, d.up(500L))
    }

    @Test
    fun `先小幅移动再继续按住,仍然能长按`() {
        val d = detector()
        d.down(0f, 0f, 0L)

        assertEquals(PressOutcome.PENDING, d.move(2f, 2f, 100L))
        assertEquals(PressOutcome.LONG_PRESS, d.tick(400L))
    }

    @Test
    fun `剩余时间用于驱动定时器`() {
        val d = detector()
        d.down(0f, 0f, 1_000L)

        assertEquals(400L, d.remainingMillis(1_000L))
        assertEquals(150L, d.remainingMillis(1_250L))
        assertEquals(0L, d.remainingMillis(1_500L))
        assertEquals("长按成立之后不需要再等待", 0L, d.let { it.tick(1_500L); it.remainingMillis(1_600L) })
    }

    @Test
    fun `被系统取消的按下既不是点击也不是长按`() {
        val d = detector()
        d.down(0f, 0f, 0L)

        assertEquals(PressOutcome.CANCELLED, d.cancel())
        assertEquals(PressOutcome.CANCELLED, d.up(800L))
        assertEquals(PressOutcome.CANCELLED, d.tick(900L))
    }

    @Test
    fun `阈值与容差就是规范里的 400ms 和 6px`() {
        assertEquals(400L, LongPressSpec.HOLD_MILLIS)
        assertEquals(6f, LongPressSpec.MOVE_TOLERANCE_PX, 0.0001f)
        assertTrue(LongPressDetector().let { it.down(0f, 0f, 0L); it.move(6f, 0f, 10L) } == PressOutcome.PENDING)
        assertFalse(LongPressDetector().let { it.down(0f, 0f, 0L); it.move(6.1f, 0f, 10L) } == PressOutcome.PENDING)
    }
}
