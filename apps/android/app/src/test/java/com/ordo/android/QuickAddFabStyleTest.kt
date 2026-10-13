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
 * 快加号视觉（UI §5.2 v1.5：亮蓝填充 + 同色柔光 + 浮在状态栏之上）的纯逻辑与源码级验收。
 *
 * 覆盖：① 颜色/柔光令牌；② "FAB 底边距 ≥ 状态栏高度 + 柔光厚度"的布局断言；
 * ③ 柔和光必须用径向渐变（**禁止**退回 `shadow(ambientColor/spotColor)` 这类彩色阴影，
 *    Windows/Skia 上实测不渲染，两端实现要一致）。
 *
 * ⚠ 本机没有 Android 设备/模拟器：这里只能保证"令牌与实现方式"，**不能**替代真机目视核对。
 */
class QuickAddFabStyleTest {

    /* ------------------------- ① 颜色 / 柔光令牌 ------------------------- */

    @Test
    fun `FAB填充是亮蓝且浅深色主题同色`() {
        assertEquals("§5.2 v1.5 指定 #0A84FF", Color(0xFF0A84FF), OrdoFabTokens.fill)
        assertEquals("浅色主题用同一填充色", Color(0xFF0A84FF), OrdoLightColors.fab)
        assertEquals("深色主题用同一填充色", Color(0xFF0A84FF), OrdoDarkColors.fab)
    }

    @Test
    fun `柔光是同色半透明_浅色三成五深色四成五`() {
        assertEquals("浅色柔光透明度", 0.35f, OrdoFabTokens.GLOW_ALPHA_LIGHT, 0.0001f)
        assertEquals("深色柔光透明度", 0.45f, OrdoFabTokens.GLOW_ALPHA_DARK, 0.0001f)

        // Color 内部按 8 位量化，取值比较留一点余量
        assertEquals("浅色柔光 = 填充色 + 35% 透明度", 0.35f, OrdoLightColors.fabGlow.alpha, 0.01f)
        assertEquals("深色柔光 = 填充色 + 45% 透明度", 0.45f, OrdoDarkColors.fabGlow.alpha, 0.01f)
        assertEquals("柔光红通道与填充一致", OrdoFabTokens.fill.red, OrdoLightColors.fabGlow.red, 0.01f)
        assertEquals("柔光绿通道与填充一致", OrdoFabTokens.fill.green, OrdoLightColors.fabGlow.green, 0.01f)
        assertEquals("柔光蓝通道与填充一致", OrdoFabTokens.fill.blue, OrdoLightColors.fabGlow.blue, 0.01f)
        assertTrue("柔光必须是半透明（不能是不透明色块）", OrdoLightColors.fabGlow.alpha < 1f)
    }

    @Test
    fun `柔光厚度是24dp_状态栏高度按StatusBar实测44dp`() {
        assertEquals(24f, OrdoLayout.fabGlow.value, 0.001f)
        assertEquals("StatusBar composable 用 touchTarget = 44dp", 44f, OrdoLayout.statusBar.value, 0.001f)
        assertEquals("StatusBar 高度必须等于触控目标高度", OrdoLayout.touchTarget.value, OrdoLayout.statusBar.value, 0.001f)
        assertTrue("柔光厚度必须 > 0，否则没有光晕", OrdoLayout.fabGlow.value > 0f)
    }

    /* --------------------------- ② 布局断言 --------------------------- */

    @Test
    fun `窗口坐标下FAB底边距等于状态栏高度加柔光厚度`() {
        assertEquals(
            "fabBottomInset = statusBar + fabGlow",
            OrdoLayout.statusBar + OrdoLayout.fabGlow,
            OrdoLayout.fabBottomInset,
        )
        assertEquals(68f, OrdoLayout.fabBottomInset.value, 0.001f)
    }

    @Test
    fun `FAB底边距不小于状态栏高度加柔光厚度`() {
        assertTrue(
            "按钮连同柔光必须整体浮在状态栏之上（≥ 状态栏高度 + 柔光厚度）",
            OrdoLayout.fabBottomInset.value >= OrdoLayout.statusBar.value + OrdoLayout.fabGlow.value,
        )
    }

    @Test
    fun `内容区局部底边距等于窗口规则减去状态栏`() {
        assertEquals(
            "内容区底边本身就是状态栏顶边，所以局部只要让出柔光厚度",
            OrdoLayout.fabGlow,
            OrdoLayout.fabContentInset,
        )
        assertEquals(
            "局部底边距 + 状态栏 = 窗口坐标下的完整规则",
            OrdoLayout.fabBottomInset,
            OrdoLayout.fabContentInset + OrdoLayout.statusBar,
        )
        assertTrue("局部底边距至少要让出柔光厚度（否则柔光会盖到状态栏）", OrdoLayout.fabContentInset.value >= OrdoLayout.fabGlow.value)
    }

    /* ------------------------ ③ 源码级实现方式断言 ------------------------ */

    @Test
    fun `柔光用径向渐变绘制`() {
        val source = TestSource.read("java/com/ordo/android/ui/quickadd/QuickAdd.kt")

        assertTrue("必须用 Brush.radialGradient", source.contains("Brush.radialGradient"))
        assertTrue("渐变必须真的画上去（background(brush)）", source.contains("background(") && source.contains("brush = "))
        assertTrue("柔光颜色必须来自令牌 colors.fabGlow", source.contains("colors.fabGlow"))
        assertTrue("FAB 填充必须用新令牌 colors.fab（不再是 accent）", source.contains("background(colors.fab)"))
    }

    @Test
    fun `禁止退回彩色阴影实现柔光`() {
        // 只看代码：注释里为了说明"不要用 ambientColor/spotColor" 会包含这些词
        val code = TestSource.readCode("java/com/ordo/android/ui/quickadd/QuickAdd.kt")

        assertFalse("不得使用 shadow(ambientColor=…)", code.contains("ambientColor"))
        assertFalse("不得使用 shadow(spotColor=…)", code.contains("spotColor"))
        assertFalse("不得用带颜色的 shadow 做柔光", code.contains("color = colors.fab"))
    }

    @Test
    fun `柔光用requiredSize溢出按钮边界且不参与布局`() {
        val source = TestSource.read("java/com/ordo/android/ui/quickadd/QuickAdd.kt")

        assertTrue("柔光必须用 requiredSize 溢出边界（否则会把按钮往屏里推 24dp）", source.contains("requiredSize("))
        assertTrue(
            "柔光尺寸 = 按钮 + 两侧柔光厚度",
            source.contains("OrdoLayout.fabSize + OrdoLayout.fabGlow * 2"),
        )
        assertTrue("按钮本体的尺寸仍固定为 fabSize", source.contains(".size(OrdoLayout.fabSize)"))
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
