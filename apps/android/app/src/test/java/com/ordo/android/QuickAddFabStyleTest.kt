package com.ordo.android

import androidx.compose.ui.graphics.Color
import com.ordo.android.ui.theme.OrdoDarkColors
import com.ordo.android.ui.theme.OrdoFabTokens
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoLightColors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 快加号视觉（UI §5.2 v1.5：纯色亮蓝圆钮 + 浮在状态栏之上）的纯逻辑与源码级验收。
 *
 * 覆盖：① 颜色令牌与"**不得再有柔光**"；② "FAB 底边距 = 状态栏高度 + 16dp 留白"的布局断言；
 * ③ 纯色实现（**禁止**退回 `shadow(ambientColor/spotColor)` 彩色阴影或径向渐变柔光）。
 *
 * 历史：2026-10-13 之前这里断言"柔光必须用径向渐变"；用户当日要求三端去掉柔光，改为反向断言。
 *
 * ⚠ 本机没有 Android 设备/模拟器：这里只能保证"令牌与实现方式"，**不能**替代真机目视核对。
 */
class QuickAddFabStyleTest {

    /* ------------------------- ① 颜色 / 纯色圆钮令牌 ------------------------- */

    @Test
    fun `FAB填充是亮蓝且浅深色主题同色`() {
        assertEquals("§5.2 v1.5 指定 #0A84FF", Color(0xFF0A84FF), OrdoFabTokens.fill)
        assertEquals("浅色主题用同一填充色", Color(0xFF0A84FF), OrdoLightColors.fab)
        assertEquals("深色主题用同一填充色", Color(0xFF0A84FF), OrdoDarkColors.fab)
    }

    @Test
    fun `按钮不再有柔光`() {
        // 用户 2026-10-13:「三端的蓝色圆按钮都不需要柔光了」→ 柔光令牌与径向渐变层都已删除。
        // 源码级断言(令牌字段本身已不存在,靠反射断言反而更脆):
        val source = TestSource.readCode("java/com/ordo/android/ui/quickadd/QuickAdd.kt")
        assertFalse("不应再有径向渐变柔光", source.contains("radialGradient"))
        assertFalse("不应再引用柔光色令牌", source.contains("fabGlow"))
        assertFalse("不应再有柔光尺寸计算", source.contains("glowTotal") || source.contains("glowRadiusPx"))
        assertTrue("按钮仍是纯色圆钮", source.contains("background(colors.fab)"))
    }

    @Test
    fun `状态栏高度按StatusBar实测44dp且底部留白16dp`() {
        assertEquals("StatusBar composable 用 touchTarget = 44dp", 44f, OrdoLayout.statusBar.value, 0.001f)
        assertEquals("StatusBar 高度必须等于触控目标高度", OrdoLayout.touchTarget.value, OrdoLayout.statusBar.value, 0.001f)
        assertEquals("去掉柔光后,底部留白由 BOTTOM_GAP_DP 给(与 Windows 的 OrdoSpace.l 一致)", 16, OrdoFabTokens.BOTTOM_GAP_DP)
    }

    /* --------------------------- ② 布局断言 --------------------------- */

    @Test
    fun `窗口坐标下FAB底边距等于状态栏高度加留白`() {
        assertEquals(
            "fabBottomInset = statusBar + 留白",
            OrdoLayout.statusBar + OrdoLayout.fabContentInset,
            OrdoLayout.fabBottomInset,
        )
        assertEquals(60f, OrdoLayout.fabBottomInset.value, 0.001f)
    }

    @Test
    fun `FAB底边距不小于状态栏高度加留白`() {
        assertTrue(
            "按钮必须整体浮在状态栏之上(≥ 状态栏高度 + 留白)",
            OrdoLayout.fabBottomInset.value >= OrdoLayout.statusBar.value + OrdoLayout.fabContentInset.value,
        )
    }

    @Test
    fun `内容区局部底边距等于窗口规则减去状态栏`() {
        assertEquals(
            "内容区底边本身就是状态栏顶边,所以局部只要让出留白",
            16f,
            OrdoLayout.fabContentInset.value,
            0.001f,
        )
        assertEquals(
            "局部底边距 + 状态栏 = 窗口坐标下的完整规则",
            OrdoLayout.fabBottomInset,
            OrdoLayout.fabContentInset + OrdoLayout.statusBar,
        )
        assertTrue("留白必须 > 0(否则按钮会贴到状态栏)", OrdoLayout.fabContentInset.value > 0f)
    }

    /* ------------------------ ③ 源码级实现方式断言 ------------------------ */

    @Test
    fun `按钮是纯色填充且不得用彩色阴影`() {
        val code = TestSource.readCode("java/com/ordo/android/ui/quickadd/QuickAdd.kt")

        assertTrue("FAB 填充必须用新令牌 colors.fab（不再是 accent）", code.contains("background(colors.fab)"))
        assertFalse("不得使用 shadow(ambientColor=…)", code.contains("ambientColor"))
        assertFalse("不得使用 shadow(spotColor=…)", code.contains("spotColor"))
        assertFalse("不得用带颜色的 shadow 做柔光", code.contains("color = colors.fab"))
    }

    @Test
    fun `按钮尺寸固定为 fabSize`() {
        val source = TestSource.read("java/com/ordo/android/ui/quickadd/QuickAdd.kt")

        assertTrue("按钮本体的尺寸仍固定为 fabSize", source.contains(".size(OrdoLayout.fabSize)"))
        assertFalse("不再需要 requiredSize 溢出(没有柔光了)", source.contains("requiredSize("))
    }

    @Test
    fun `外壳用的是内容区局部底边距令牌`() {
        val shell = TestSource.readCode("java/com/ordo/android/ui/shell/OrdoShell.kt")

        assertTrue(
            "OrdoShell 必须用 OrdoLayout.fabContentInset（而不是写死的 OrdoSpace.xl）",
            shell.contains("OrdoLayout.fabContentInset"),
        )
        assertFalse(
            "不得再对 FAB 用整圈 OrdoSpace.xl 内边距（底边会只剩 24dp 且与状态栏无推导关系）",
            shell.contains(".padding(OrdoSpace.xl)"),
        )
    }

    @Test
    fun `按钮里的加号是短而粗`() {
        // 2026-10-13 用户给参照图:按钮里的「＋」跨度 ≈21% 按钮直径、笔画 ≈5%(短而粗);
        // 菜单里那枚是长而细(22dp / 2.1),两者刻意不同 —— 别把 FAB 改回菜单那套参数。
        val source = TestSource.readCode("java/com/ordo/android/ui/quickadd/QuickAdd.kt")

        assertTrue("FAB 的「＋」画布应为 20dp", source.contains("size = 20.dp"))
        assertTrue("FAB 的「＋」笔画应为 2.65", source.contains("strokeWidth = 2.65f"))
        assertFalse("FAB 不得回退成长而细的菜单参数(22dp)", source.contains("size = 22.dp"))
        assertFalse("FAB 不得回退成菜单笔画 2.1", source.contains("strokeWidth = 2.1f"))
        val spanRatio = 12.0 / 56.0          // 20dp 画布 × 12/20 跨度 = 12dp
        val strokeRatio = 2.65 / 56.0
        assertTrue("跨度占按钮直径应在 19%~24%:$spanRatio", spanRatio > 0.19 && spanRatio < 0.24)
        assertTrue("笔画占按钮直径应在 4%~6%:$strokeRatio", strokeRatio > 0.04 && strokeRatio < 0.06)
    }
}
