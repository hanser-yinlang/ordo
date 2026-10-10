package com.ordo.desktop.ui.shell

import com.ordo.desktop.app.SyncStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 刷新控件状态机(04-UI规范 §5.3「必须有可见效果」)。
 *
 * 旧实现只有文字变化,用户不知道刷没刷;新规范要求"图标 + 文字"并且四个阶段各有明确表现:
 * idle 可点 / syncing 连续旋转且禁用 / success 短暂 success 色后复位 / error 常驻 danger 可重试。
 */
class RefreshControlTest {

    private fun model() = RefreshControlModel()

    @Test
    fun `常态是可点的同步入口`() {
        val visual = model().visual(0L)

        assertEquals("同步", visual.label)
        assertEquals(RefreshTone.NEUTRAL, visual.tone)
        assertFalse(visual.spinning)
        assertTrue("常态必须能点", visual.enabled)
    }

    @Test
    fun `同步中图标连续旋转,按钮禁用`() {
        val m = model()
        m.onStatusChanged(SyncStatus.SYNCING, 1_000L)

        val visual = m.visual(1_000L)
        assertEquals("同步中…", visual.label)
        assertEquals(RefreshTone.ACCENT, visual.tone)
        assertTrue("同步中必须一直转", visual.spinning)
        assertFalse("同步中禁用,防止重复触发", visual.enabled)
        assertTrue("旋转期间要持续跑帧", m.needsFrames(1_000L))
        assertFalse(m.canTrigger(1_000L))
    }

    @Test
    fun `成功后 320ms 是 success 色,1_4s 内保持禁用,之后复位`() {
        val m = model()
        m.onStatusChanged(SyncStatus.SYNCING, 0L)
        m.onStatusChanged(SyncStatus.SYNCED, 100L)

        val flash = m.visual(100L)
        assertEquals("已同步", flash.label)
        assertEquals(RefreshTone.SUCCESS, flash.tone)
        assertFalse("刚结束还在防抖期", flash.enabled)
        assertFalse("成功之后不再旋转", flash.spinning)

        assertEquals("320ms 之内仍然是 success 色", RefreshTone.SUCCESS, m.visual(419L).tone)
        assertEquals("超过 320ms 回到常态色", RefreshTone.NEUTRAL, m.visual(420L).tone)
        assertEquals("文字保留已同步", "已同步", m.visual(800L).label)

        assertTrue("防抖期内还要继续跑帧", m.needsFrames(1_000L))
        assertFalse(m.canTrigger(1_000L))
        assertTrue("1.4s 后恢复可点", m.canTrigger(100L + RefreshControlModel.SETTLE_MILLIS))
        assertFalse("复位后不再需要跑帧", m.needsFrames(100L + RefreshControlModel.SETTLE_MILLIS))
    }

    @Test
    fun `失败常驻 danger 文案并且可以立刻重试`() {
        val m = model()
        m.onStatusChanged(SyncStatus.SYNCING, 0L)
        m.onStatusChanged(SyncStatus.OFFLINE, 50L)

        val visual = m.visual(60_000L)
        assertEquals("同步失败，点击重试", visual.label)
        assertEquals(RefreshTone.DANGER, visual.tone)
        assertFalse(visual.spinning)
        assertTrue("失败后必须能重试", visual.enabled)
        assertFalse("失败是静态状态,不需要一直跑帧", m.needsFrames(60_000L))
    }

    @Test
    fun `ERROR 与 OFFLINE 同样给出重试入口`() {
        val m = model()
        m.onStatusChanged(SyncStatus.ERROR, 0L)
        assertEquals("同步失败，点击重试", m.visual(0L).label)
        assertTrue(m.canTrigger(0L))
    }

    @Test
    fun `旋转一圈 900ms`() {
        assertEquals(900, RefreshControlModel.SPIN_PERIOD_MILLIS)
        assertEquals(900, RefreshControlModel().spinPeriodMillis)
    }

    @Test
    fun `重复喂同一个状态不会重置计时`() {
        val m = model()
        m.onStatusChanged(SyncStatus.SYNCED, 0L)
        m.onStatusChanged(SyncStatus.SYNCED, 1_300L)

        // 状态没变 → 计时从第一次成功开始算,1.4s 到点即可点
        assertTrue(m.canTrigger(RefreshControlModel.SETTLE_MILLIS))
        assertEquals(RefreshTone.NEUTRAL, m.visual(RefreshControlModel.SETTLE_MILLIS).tone)
    }

    @Test
    fun `从失败重试会回到同步中`() {
        val m = model()
        m.onStatusChanged(SyncStatus.OFFLINE, 0L)
        assertTrue(m.canTrigger(0L))

        m.onStatusChanged(SyncStatus.SYNCING, 10L)

        assertTrue(m.visual(10L).spinning)
        assertFalse(m.canTrigger(10L))
    }
}
