package com.ordo.desktop.ui.list

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 拖动中的指针坐标换算(04-UI规范 §5.4「行抬起 scale 1.02」)。
 *
 * 回归的是一个**真实踩到的坑**:行被抬起后整体 scale 1.02,行内指针节点收到的局部坐标
 * 也被同一比例缩小,于是"局部坐标 + 行的窗口坐标"这种朴素换算会随拖动距离线性偏掉 ——
 * 实测拖到第三行时落点少 9px(2% × 468px),表现是"想往下拖两格只落一格"。
 */
class LiftPointerMapperTest {

    private fun mapper() = LiftPointerMapper()

    @Test
    fun `未开始时不换算位移`() {
        val mapper = mapper()
        assertFalse(mapper.started)
        assertEquals(0f, mapper.rootYOf(500f), 0.001f)
    }

    @Test
    fun `基准点本身保持不动`() {
        val mapper = mapper()
        mapper.begin(rootY = 281f, localY = 14f)

        assertTrue(mapper.started)
        assertEquals(281f, mapper.rootYOf(14f), 0.001f)
    }

    @Test
    fun `拖动中的位移按抬起比例还原`() {
        val mapper = mapper()
        mapper.begin(rootY = 281f, localY = 14f)

        // 真实测量值:窗口坐标 749 的手柄内部坐标为 473.13(被 1.02 缩放后的结果)
        // 朴素换算会得到 267 + 473.13 = 740.13(少 9px),这里必须还原成 749。
        assertEquals(749f, mapper.rootYOf(473.13f), 0.5f)
    }

    @Test
    fun `还原比例就是 1_02`() {
        assertEquals(1.02f, LiftPointerMapper.LIFT_SCALE, 0.0001f)

        val mapper = mapper()
        mapper.begin(rootY = 0f, localY = 0f)
        assertEquals(102f, mapper.rootYOf(100f), 0.001f)
    }

    @Test
    fun `向上拖同样被还原`() {
        val mapper = mapper()
        mapper.begin(rootY = 500f, localY = 20f)

        // 局部坐标小了 20(对应窗口位移 -20.4)
        assertEquals(479.6f, mapper.rootYOf(0f), 0.001f)
    }
}
