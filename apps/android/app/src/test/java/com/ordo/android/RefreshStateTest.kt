package com.ordo.android

import com.ordo.android.sync.RefreshController
import com.ordo.android.sync.RefreshLabel
import com.ordo.android.sync.RefreshPhase
import com.ordo.android.sync.RefreshTone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 刷新控件状态机（UI §5.3）的纯逻辑验收。
 *
 * 用户实测问题：状态栏右侧原来只是一个可点击的**文字**，点了只有文字变化，感知不到"刷新了没有"。
 * 新规范要求：同步中图标连续旋转；成功停转 + success 色 +「已同步」并在 1.4s 后回常态；
 * 失败 danger 色 +「同步失败，点击重试」常驻；同步中与结束后 1.4s 内禁用（防抖）。
 */
class RefreshStateTest {

    private var clock = 1_759_900_000_000L
    private fun controller() = RefreshController { clock }

    @Test
    fun `点击后进入同步中_图标持续旋转且按钮禁用`() {
        val control = controller()

        assertTrue("常态可点", control.onClick())

        val state = control.state.value
        assertEquals(RefreshPhase.SYNCING, state.phase)
        assertEquals(RefreshLabel.SYNCING, state.label)
        assertTrue("同步中图标必须连续旋转", state.spinning)
        assertFalse("同步中按钮禁用（防重复触发）", state.enabled)
        assertEquals(RefreshTone.ACCENT, state.tone)
    }

    @Test
    fun `同步中重复点击是空操作`() {
        val control = controller()
        assertTrue(control.onClick())

        assertFalse("同步中的第二次点击必须被忽略", control.onClick())
        assertFalse(control.requestSync())
        assertEquals(RefreshPhase.SYNCING, control.state.value.phase)
    }

    @Test
    fun `成功后显示已同步并在 1_4 秒防抖窗口内保持禁用`() {
        val control = controller()
        control.onClick()

        control.onSyncFinished(ok = true)

        val success = control.state.value
        assertEquals(RefreshPhase.SUCCESS, success.phase)
        assertEquals(RefreshLabel.SYNCED, success.label)
        assertEquals("成功转 success 色", RefreshTone.SUCCESS, success.tone)
        assertFalse("成功后必须停转", success.spinning)
        assertFalse("结束后 1.4s 内禁用（防抖）", success.enabled)
        assertFalse("防抖窗口内的点击必须被忽略", control.onClick())
        assertEquals(clock, control.lastFinishedAt)
    }

    @Test
    fun `成功态在 1_4 秒后回到常态并解锁`() {
        val control = controller()
        control.onClick()
        control.onSyncFinished(ok = true)

        // 1.4s 后由界面层调用 settle()（时长常量与规范一致）
        clock += RefreshController.SETTLE_MILLIS
        control.settle()

        val idle = control.state.value
        assertEquals(RefreshPhase.IDLE, idle.phase)
        assertEquals("回到常态仍显示「已同步」", RefreshLabel.SYNCED, idle.label)
        assertTrue("防抖窗口结束后可再次点击", idle.enabled)
        assertTrue(control.onClick())
    }

    @Test
    fun `失败常驻危险色文案且可立即重试`() {
        val control = controller()
        control.onClick()

        control.onSyncFinished(ok = false)

        val failed = control.state.value
        assertEquals(RefreshPhase.FAILED, failed.phase)
        assertEquals("失败文案常驻，直到重试", RefreshLabel.FAILED, failed.label)
        assertEquals(RefreshTone.DANGER, failed.tone)
        assertFalse(failed.spinning)
        assertTrue("失败后按钮立即可点（重试）", failed.enabled)
        assertTrue(control.onClick())
        assertEquals(RefreshPhase.SYNCING, control.state.value.phase)
    }

    @Test
    fun `离线不算失败但必须解锁按钮`() {
        val control = controller()
        control.onClick()

        control.onOffline()

        val offline = control.state.value
        assertEquals(RefreshLabel.OFFLINE, offline.label)
        assertEquals(RefreshPhase.IDLE, offline.phase)
        assertTrue(offline.enabled)
    }

    @Test
    fun `还没有会话时禁用且文案为未连接`() {
        val control = controller()

        control.onNotLoggedIn()

        val state = control.state.value
        assertEquals(RefreshLabel.NEVER, state.label)
        assertFalse("还没有会话时点了也没有意义，按钮禁用", state.enabled)
        assertFalse(control.onClick())
        assertEquals(
            "v1.3 已无登录概念：文案必须是「未连接」，不得再出现「未登录」",
            "未连接",
            TestStrings.value("sync_never"),
        )
    }

    @Test
    fun `失败提示不会被后台静默同步抹掉`() {
        val control = controller()
        control.onClick()
        control.onSyncFinished(ok = false)

        control.onIdle()

        assertEquals("前台轮询完成不得覆盖用户的「点击重试」提示", RefreshPhase.FAILED, control.state.value.phase)
        assertEquals(RefreshLabel.FAILED, control.state.value.label)
    }

    @Test
    fun `时序常量符合 UI 规范`() {
        assertEquals("成功态停留 1.4s", 1_400L, RefreshController.SETTLE_MILLIS)
        assertEquals("图标每圈 900ms", 900, RefreshController.ROTATION_PERIOD_MILLIS)
        assertEquals("成功色闪现 320ms", 320, RefreshController.SUCCESS_FLASH_MILLIS)
        assertEquals("28dp 圆形图标按钮", 28, RefreshController.ICON_SIZE_DP)
    }
}
