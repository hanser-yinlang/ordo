package com.ordo.desktop.ui.quickadd

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.ordo.desktop.ui.theme.OrdoDarkPalette
import com.ordo.desktop.ui.theme.OrdoLightPalette
import com.ordo.desktop.ui.theme.OrdoSize
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 右下角快加号按钮的**外观与动效**回归(2026-10-13 用户指定对齐参照原型)。
 *
 * 用户给的两张图钉死了两件事:
 * 1. 收起态是一枚**亮蓝**(#0A84FF)圆形按钮 + 白色圆头「+」,四周有一圈柔光;
 * 2. 点击后按钮**弹性旋转 45° 变成「×」**,菜单带着缩放/上滑/错位淡入出现。
 *
 * 这里把颜色、光晕、图标来源与动效的**存在性**都断言住 —— 光靠肉眼看截图容易被后续改动悄悄改回去。
 */
class QuickAddFabLookTest {

    private fun sourceOf(name: String): String? {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, "apps/windows/src/main/kotlin/com/ordo/desktop/ui/quickadd/$name")
            if (candidate.exists()) return candidate.readText()
            dir = dir.parentFile
        }
        return null
    }

    // ------------------------------------------------------------ 颜色令牌

    @Test
    fun `按钮填充是参照原型的亮蓝 0A84FF`() {
        assertEquals("浅色主题按钮色", Color(0xFF0A84FF), OrdoLightPalette.fab)
        assertEquals("深色主题按钮色", Color(0xFF0A84FF), OrdoDarkPalette.fab)
    }

    @Test
    fun `按钮的光晕半透明且与填充同源`() {
        for ((name, p) in listOf("light" to OrdoLightPalette, "dark" to OrdoDarkPalette)) {
            assertTrue("$name 光晕必须半透明(否则会盖住按钮)", p.fabGlow.alpha > 0f && p.fabGlow.alpha < 1f)
            assertEquals("$name 光晕红通道与填充一致", p.fab.red, p.fabGlow.red)
            assertEquals("$name 光晕绿通道与填充一致", p.fab.green, p.fabGlow.green)
            assertEquals("$name 光晕蓝通道与填充一致", p.fab.blue, p.fabGlow.blue)
        }
        assertEquals("浅色光晕 = #0A84FF @35%", Color(0x590A84FF), OrdoLightPalette.fabGlow)
        assertEquals("深色光晕 = #0A84FF @45%", Color(0x730A84FF), OrdoDarkPalette.fabGlow)
    }

    @Test
    fun `按钮直径与光晕厚度仍是设计令牌`() {
        assertEquals(56.dp, OrdoSize.fab)
        assertEquals("光晕厚度由令牌给出(参照原型量得 ≈ 按钮半径)", 24.dp, OrdoSize.fabGlow)
    }

    @Test
    fun `按钮图标尺寸是 22dp`() {
        assertEquals(22.dp, QuickAddVisual.ICON_SIZE)
    }

    // ------------------------------------------------------------ 源码级:外观 + 动效

    @Test
    fun `按钮用 fab 令牌填充,光晕是显式径向渐变`() {
        val src = sourceOf("QuickAdd.kt") ?: return
        assertTrue("填充必须走 colors.fab 令牌", src.contains("colors.fab"))
        // Compose Desktop 不渲染彩色阴影:必须自己画径向渐变,否则光晕根本不出现
        assertTrue("光晕要用 Brush.radialGradient 画", src.contains("Brush.radialGradient"))
        assertTrue("渐变颜色取 fabGlow 令牌", src.contains("colors.fabGlow"))
        assertTrue("光晕厚度取 OrdoSize.fabGlow", src.contains("OrdoSize.fabGlow"))
        assertFalse(
            "不要依赖彩色阴影(桌面端不生效)",
            src.contains("ambientColor = ") || src.contains("spotColor = ")
        )
    }

    @Test
    fun `按钮里的白色加号与菜单同一套圆头几何`() {
        val src = sourceOf("QuickAdd.kt") ?: return
        assertTrue("按钮图标应为菜单同款圆头「+」(OrdoMenuIcons.Todo)", src.contains("imageVector = OrdoMenuIcons.Todo"))
        assertTrue("图标必须是白色", src.contains("tint = Color.White"))
        assertTrue("展开时旋转 45°", src.contains("rotate(rotation)"))
    }

    @Test
    fun `旋转是有界缓动,菜单在动效里缩放加滑入`() {
        val src = sourceOf("QuickAdd.kt") ?: return
        // 用 spring 会让离屏场景里的动画永不收敛(后续输入事件得不到处理),因此用有界 tween + 缓动曲线
        assertFalse("旋转不要用无界 spring", src.contains("animationSpec = spring("))
        assertTrue("旋转用 tween + FastOutSlowInEasing", src.contains("FastOutSlowInEasing"))
        assertTrue("菜单进入带缩放", src.contains("scaleIn(") && src.contains("transformOrigin = TransformOrigin(1f, 1f)"))
        assertTrue("菜单进入带上滑", src.contains("slideInVertically"))
        assertTrue("菜单退出带上滑", src.contains("slideOutVertically"))
        assertTrue("菜单项错位淡入仍保留", src.contains("StaggeredItem"))
    }
}
