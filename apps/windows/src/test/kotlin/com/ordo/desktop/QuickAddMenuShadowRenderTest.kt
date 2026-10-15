package com.ordo.desktop

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.ui.shell.OrdoApp
import com.ordo.desktop.ui.theme.OrdoSize
import com.ordo.desktop.ui.theme.OrdoSpace
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertTrue
import org.junit.Test
import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import java.io.File
import javax.imageio.ImageIO

/**
 * 快加号菜单面板的**投影**回归(2026-10-14 客户实测反馈)。
 *
 * 反馈原话:「点击蓝色按钮出现的功能,会先是显示正方形的阴影后显示圆角阴影,把这个正方形阴影的动效去掉」。
 *
 * 根因不是 shape,而是 `Modifier.shadow` 在 **alpha < 1 的图层里不画阴影** —— 旧实现用
 * `AnimatedVisibility(fadeIn…)` 淡入,整段入场过渡里面板一点投影都没有(看起来就是一块没有阴影的
 * 方角矩形),直到 alpha 落到 1 的那一帧圆角投影才"啪"地冒出来。修法见 QuickAdd.kt:改成自己驱动
 * graphicsLayer 只动 scale / translationY,alpha 恒为 1。
 *
 * 这个用例逐帧量**面板右缘外的暗度**(投影带):只要入场动效的**每一帧**都带投影,就不可能出现
 * "先方后圆"的两段式;同时按沿高度量外溢宽度,确认投影是**贴着圆角**收进去的(方角会让上沿也外溢);
 * 另外还逐帧定位面板上缘与投影上沿,确认**投影是跟着面板一起动**的(客户要的是去掉方角那一段、
 * 保留圆角投影的动效,而不是把动效整个删掉)。
 *
 * 产物(`<buildDir>/reports/`):`ordo-quickadd-shadow-first-frame.png`(入场第 1 帧)、
 * `ordo-quickadd-shadow-settled.png`(动效走完)。
 */
@OptIn(ExperimentalComposeUiApi::class)
class QuickAddMenuShadowRenderTest {

    private val width = 1440
    private val height = 900

    /** 投影带纵向取样范围用到的面板下缘:底部内边距(statusBar + l)+ 按钮 56 + 两者间距 s */
    private val panelBottom = height -
        (OrdoSize.statusBar.value + OrdoSpace.l.value).toInt() -
        OrdoSize.fab.value.toInt() -
        OrdoSpace.s.value.toInt()

    /** 面板右缘:QuickAdd 的 Column 右内边距 = OrdoSpace.xl(density = 1,dp 值就是像素) */
    private val rightEdge = width - OrdoSpace.xl.value.toInt()

    @Test
    fun `面板从第一帧起就带圆角投影`() {
        val vm = session()
        val scene = ImageComposeScene(width = width, height = height, density = Density(1f)) { OrdoApp(vm) }
        var now = 0L
        repeat(20) { scene.render(now); now += 16_000_000L }

        // 1) 展开:抓入场动效的每一帧
        vm.setQuickAddMenu(true)
        val frames = mutableListOf<Shot>()
        repeat(12) {
            frames += shot(scene, now)
            now += 16_000_000L
        }

        // 2) 让动效走完,取终态(用来判"圆角"并落盘证据)
        repeat(20) { scene.render(now); now += 16_000_000L }
        val settled = shot(scene, now)
        now += 16_000_000L

        // 3) 收起后再量一次同一条带:没有面板时它必须是干净的画布(证明量到的确实是面板的投影)
        vm.setQuickAddMenu(false)
        repeat(20) { scene.render(now); now += 16_000_000L }
        val closed = shot(scene, now)
        scene.close()

        val top = detectPanelTop(settled.image)
        assertTrue("终态画面里应当能定位到菜单面板(白色面板右缘内 ${rightEdge - 5} 列)", top > 0)
        println("[QuickAddMenuShadowRenderTest] 面板上缘 y=$top 下缘 y=$panelBottom 右缘 x=$rightEdge")

        val baseline = closed.bandDarkness(top)
        assertTrue("面板收起时同一条带必须是干净画布,实测暗度=$baseline", baseline < 1f)

        // 每一帧都要有投影 —— 这是本次修复的核心(旧实现前 13 帧暗度为 0,最后一帧才补上)
        frames.forEachIndexed { i, f ->
            val d = f.bandDarkness(top)
            println("  · 入场第 ${i + 1} 帧:面板右缘投影暗度=$d")
            assertTrue("入场第 ${i + 1} 帧面板就必须带投影(否则又是一段「没有阴影的方角矩形」),实测暗度=$d", d > 2f)
        }

        val settledDarkness = settled.bandDarkness(top)
        assertTrue("动效结束后投影仍在,实测=$settledDarkness", settledDarkness > 2f)

        // 投影必须跟着面板一起动(保留"圆角阴影的动效",而不是把动效删掉换成一帧闪现)
        val probeX = rightEdge + 6
        val panelTops = frames.map { detectPanelTop(it.image) }
        val shadowTops = frames.map { it.shadowTopAt(probeX) }
        println("  · 逐帧面板上缘=$panelTops")
        println("  · 逐帧投影上沿=$shadowTops  终态面板上缘=$top 投影上沿=${settled.shadowTopAt(probeX)}")
        assertTrue(
            "入场过程中面板必须在动(第 1 帧上缘应明显低于终态),逐帧上缘=$panelTops 终态=$top",
            panelTops.first() > top + 2
        )
        assertTrue(
            "投影要跟着面板一起上移:第 1 帧投影上沿应低于终态,逐帧=$shadowTops 终态=${settled.shadowTopAt(probeX)}",
            shadowTops.first() > settled.shadowTopAt(probeX) + 2
        )
        frames.forEachIndexed { i, f ->
            val p = f.shadowTopAt(probeX)
            assertTrue(
                "第 ${i + 1} 帧在面板右缘外必须量得到投影(否则该帧的投影缺席),实测投影上沿=$p",
                p > 0 && p < panelBottom
            )
        }

        // 圆角:面板中部投影外溢明显,而紧贴上沿处几乎没有外溢(方角会让上沿一样外溢)
        val midY = (top + panelBottom) / 2
        val bleedMid = settled.bleedRight(midY)
        val bleedTop = settled.bleedRight(top + 2)
        println("  · 外溢宽度:中部 ${bleedMid}px,上沿 ${bleedTop}px")
        assertTrue("中部应当能看到投影外溢,实测=${bleedMid}px", bleedMid >= 6)
        assertTrue(
            "投影要贴着圆角收进去:上沿外溢必须明显小于中部,实测上沿=${bleedTop}px 中部=${bleedMid}px",
            bleedTop <= bleedMid - 4
        )

        save(frames[0].bytes, "ordo-quickadd-shadow-first-frame.png")
        save(settled.bytes, "ordo-quickadd-shadow-settled.png")
    }

    private inner class Shot(val bytes: ByteArray, val image: BufferedImage) {

        /** 面板右缘外那条投影带的"暗度" = 画布亮度 - 带内最暗值(0~255) */
        fun bandDarkness(panelTop: Int): Float {
            if (panelTop <= 0) return 0f
            val canvas = lum(image, 700, 500)
            var min = 255f
            for (x in rightEdge + 3..rightEdge + 10) {
                for (y in panelTop + 20 until panelBottom - 20) {
                    val l = lum(image, x, y)
                    if (l < min) min = l
                }
            }
            return canvas - min
        }

        /** 某个高度上,紧贴面板右缘往右连续"暗于画布"的像素数 */
        fun bleedRight(y: Int): Int {
            val canvas = lum(image, 700, 500)
            var n = 0
            for (x in rightEdge + 1..minOf(rightEdge + 30, width - 1)) {
                if (canvas - lum(image, x, y) > 2f) n = x - rightEdge else if (n > 0) break
            }
            return n
        }

        /** 某一列上从上往下扫到的第一个"暗于画布"像素 = 投影上沿(量不到返回 -1) */
        fun shadowTopAt(x: Int): Int {
            if (x >= width) return -1
            val canvas = lum(image, 700, 500)
            for (y in 560 until panelBottom) {
                if (canvas - lum(image, x, y) > 2f) return y
            }
            return -1
        }
    }

    private fun session(): OrdoViewModel {
        val storage = InMemoryStorage()
        val engine = OrdoEngine(storage)
        engine.seedDemoData(force = true)
        return OrdoViewModel(engine = engine, storage = storage, scope = CoroutineScope(Dispatchers.Unconfined))
    }

    private fun shot(scene: ImageComposeScene, now: Long): Shot {
        val bytes = scene.render(now).encodeToData()!!.bytes
        assertTrue("截图不应为空", bytes.size > 5_000)
        return Shot(bytes, ImageIO.read(ByteArrayInputStream(bytes)))
    }

    private fun save(bytes: ByteArray, fileName: String) {
        val out = File(System.getProperty("ordo.reportDir") ?: "build/reports").apply { mkdirs() }
        val file = File(out, fileName)
        file.writeBytes(bytes)
        println("  · 已输出截图:${file.absolutePath} (${file.length()} 字节)")
    }

    /** 从上往下扫面板右缘内侧那一列,第一个"面板底色"像素就是面板上缘 */
    private fun detectPanelTop(image: BufferedImage): Int {
        for (y in 400 until panelBottom) {
            if (lum(image, rightEdge - 5, y) > 250f) return y
        }
        return -1
    }

    /** 0(黑)~255(白) */
    private fun lum(image: BufferedImage, x: Int, y: Int): Float {
        val rgb = image.getRGB(x, y)
        return (((rgb shr 16) and 0xFF) + ((rgb shr 8) and 0xFF) + (rgb and 0xFF)) / 3f
    }
}
