package com.ordo.desktop.ui.quickadd

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathNode
import androidx.compose.ui.graphics.vector.VectorGroup
import androidx.compose.ui.graphics.vector.VectorNode
import androidx.compose.ui.graphics.vector.VectorPath
import androidx.compose.ui.unit.dp
import com.ordo.desktop.ui.common.OrdoIcons
import com.ordo.desktop.ui.common.OrdoMenuIcons
import com.ordo.desktop.ui.theme.OrdoType
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * 快加号菜单的图标与面板规格(04-UI规范 §5.2「菜单项图标」)。
 *
 * 这一层不看截图、不点鼠标,直接断言**矢量本身**:形状节点、描边宽度、viewBox 与面板尺寸常量。
 * 这样"新建项目必须用 H 而不是文件夹""新建标题必须与 H 可区分""面板最小宽 ≥208 / 条目高 ≥44"
 * 都是可复算的事实,而不是只能靠眼睛。
 */
class QuickAddMenuIconsTest {

    private val all: List<ImageVector> =
        listOf(OrdoMenuIcons.Todo, OrdoMenuIcons.Project, OrdoMenuIcons.Area, OrdoMenuIcons.Heading)

    // ------------------------------------------------------------ 形状:四个图标各就各位

    @Test
    fun `四个菜单图标互不相同,新建项目不再复用文件夹图标`() {
        assertEquals("四个菜单项要有四个不同的图标", 4, all.toSet().size)
        assertEquals(4, all.map { it.name }.toSet().size)
        assertNotSame("新建项目必须换掉 OrdoIcons.Area(它现在是文件夹)", OrdoIcons.Area, OrdoMenuIcons.Project)
        assertNotSame("项目与区域不能是同一个图标", OrdoMenuIcons.Project, OrdoMenuIcons.Area)
        assertNotSame("标题必须与 H 区分", OrdoMenuIcons.Heading, OrdoMenuIcons.Project)
        assertNotSame(OrdoMenuIcons.Todo, OrdoMenuIcons.Project)
    }

    @Test
    fun `四个图标都是 20x20 viewBox 的矢量`() {
        for (icon in all) {
            assertEquals("§5.2:20×20 viewBox —— ${icon.name}", 20f, icon.viewportWidth, 0f)
            assertEquals("§5.2:20×20 viewBox —— ${icon.name}", 20f, icon.viewportHeight, 0f)
            assertEquals(20.dp, icon.defaultWidth)
            assertEquals(20.dp, icon.defaultHeight)
            assertTrue("必须有真实路径:${icon.name}", pathsOf(icon).isNotEmpty())
        }
    }

    @Test
    fun `新建待办是两条 2_1 粗圆头直线交叉的加号`() {
        val path = singlePath(OrdoMenuIcons.Todo)

        // §5.2 表:`(4,10)-(16,10)` 与 `(10,4)-(10,16)`,stroke 2.1 圆头
        assertEquals(
            "竖线 (10,4)-(10,16) + 横线 (4,10)-(16,10)",
            listOf(
                listOf(PathNode.MoveTo(10f, 4f), PathNode.VerticalTo(16f)),
                listOf(PathNode.MoveTo(4f, 10f), PathNode.HorizontalTo(16f))
            ),
            subpathsOf(path)
        )
        assertEquals(2.1f, path.strokeLineWidth, 0.001f)
        assertEquals("圆头", StrokeCap.Round, path.strokeLineCap)
        assertNull("只描边不填充", path.fill)
        assertBlackStroke(path)
    }

    @Test
    fun `新建项目是 H_两竖加中间一横`() {
        val path = singlePath(OrdoMenuIcons.Project)

        // §5.2 表:两竖 x=5/x=15(y 4→16)+ 中间一横 y=10(x 5→15),stroke 1.7 圆头
        assertEquals(
            "两竖 + 一横",
            listOf(
                listOf(PathNode.MoveTo(5f, 4f), PathNode.VerticalTo(16f)),
                listOf(PathNode.MoveTo(15f, 4f), PathNode.VerticalTo(16f)),
                listOf(PathNode.MoveTo(5f, 10f), PathNode.HorizontalTo(15f))
            ),
            subpathsOf(path)
        )
        assertEquals(1.7f, path.strokeLineWidth, 0.001f)
        assertEquals(StrokeCap.Round, path.strokeLineCap)
        assertBlackStroke(path)
    }

    @Test
    fun `新建标题是三横线,与 H 在结构上就不同`() {
        val heading = singlePath(OrdoMenuIcons.Heading)
        val project = singlePath(OrdoMenuIcons.Project)

        // §5.2 表:三条横线 y=5/10/15(x 4.5→15.5),stroke 1.7 圆头
        assertEquals(
            "三条等长横线 y=5/10/15",
            listOf(
                listOf(PathNode.MoveTo(4.5f, 5f), PathNode.HorizontalTo(15.5f)),
                listOf(PathNode.MoveTo(4.5f, 10f), PathNode.HorizontalTo(15.5f)),
                listOf(PathNode.MoveTo(4.5f, 15f), PathNode.HorizontalTo(15.5f))
            ),
            subpathsOf(heading)
        )
        assertEquals("≡ 不该有任何竖线", 0, heading.pathData.count { it is PathNode.VerticalTo })
        assertEquals("H 必须有两条竖线", 2, project.pathData.count { it is PathNode.VerticalTo })
        assertEquals("两者描边同档,区别只在结构", 1.7f, heading.strokeLineWidth, 0.001f)
        assertEquals(StrokeCap.Round, heading.strokeLineCap)
    }

    @Test
    fun `新建区域是 14x14 圆角 4 的方框加中心实心点`() {
        val area = pathsOf(OrdoMenuIcons.Area)
        assertEquals("一个描边方框 + 一个实心点", 2, area.size)

        // §5.2 表:rect(3,3,14,14) rx=4、stroke 1.5 + circle(10,10) r=2.6 实心
        val box = area.first { it.stroke != null }
        assertEquals(1.5f, box.strokeLineWidth, 0.001f)
        assertEquals("方框就该是这 10 个节点", 10, box.pathData.size)
        assertEquals("从 (7,3) 起笔", PathNode.MoveTo(7f, 3f), box.pathData.first())
        assertEquals(
            "四条边落在 x=3/17、y=3/17 上",
            listOf(
                PathNode.LineTo(13f, 3f),
                PathNode.LineTo(17f, 13f),
                PathNode.LineTo(7f, 17f),
                PathNode.LineTo(3f, 7f)
            ),
            box.pathData.filterIsInstance<PathNode.LineTo>()
        )
        assertEquals("四个角都是真圆弧(对应 SVG rx=4)", 4, arcsOf(box))
        assertEquals("必须闭合", 1, box.pathData.count { it is PathNode.Close })
        assertBlackStroke(box)

        val dot = area.first { it.fill != null }
        assertTrue("中心点必须是实心圆(两段半圆)", arcsOf(dot) >= 2)
        assertEquals("圆心 (10,10) 起于顶点 y=7.4", PathNode.MoveTo(10f, 7.4f), dot.pathData.first())
        assertNull("实心点不描边", dot.stroke)
        assertEquals("实心点画成黑色,由 Icon(tint) 上色", Color.Black, (dot.fill as SolidColor).value)
    }

    @Test
    fun `图标本身不带颜色语义,由主题令牌上色`() {
        // §5.2 硬约束:颜色一律走 accent / textSecondary,不引入参照原型的蓝色
        for (icon in all) {
            for (path in pathsOf(icon)) {
                path.stroke?.let {
                    assertEquals("描边画成黑色,由 Icon(tint) 上色:${icon.name}", Color.Black, (it as SolidColor).value)
                }
                path.fill?.let {
                    assertEquals("填充画成黑色,由 Icon(tint) 上色:${icon.name}", Color.Black, (it as SolidColor).value)
                }
            }
        }
    }

    // ------------------------------------------------------------ 面板与条目规格

    @Test
    fun `面板与条目尺寸就是 §5_2 的数字`() {
        assertEquals(208.dp, QuickAddMenuSpec.MIN_WIDTH)
        assertTrue("最小宽 ≥208", QuickAddMenuSpec.MIN_WIDTH.value >= 208f)
        assertEquals(12.dp, QuickAddMenuSpec.PANEL_RADIUS)
        assertEquals("1px hairline", 1.dp, QuickAddMenuSpec.HAIRLINE)
        assertEquals(5.dp, QuickAddMenuSpec.PANEL_PADDING)

        assertTrue("条目高 ≥44", QuickAddMenuSpec.ITEM_HEIGHT.value >= 44f)
        assertEquals(7.dp, QuickAddMenuSpec.ITEM_RADIUS)
        assertEquals("左内边距 9", 9.dp, QuickAddMenuSpec.ITEM_PADDING)
        assertEquals("图标↔文字 8", 8.dp, QuickAddMenuSpec.ICON_TEXT_GAP)
        assertEquals("图标 16dp(原型 .pop-item .ico)", 16.dp, QuickAddMenuSpec.ICON_SIZE)
    }

    @Test
    fun `条目标签字号 13_5,介于 caption 与 body 之间`() {
        assertEquals(13.5f, OrdoType.menuItem.fontSize.value, 0.001f)
        assertTrue(
            "必须在 caption(13)与 body(15)之间",
            OrdoType.menuItem.fontSize.value > OrdoType.caption.fontSize.value &&
                OrdoType.menuItem.fontSize.value < OrdoType.body.fontSize.value
        )
    }

    // ------------------------------------------------------------ 源码级:不删项、不改色、不加位图

    @Test
    fun `四项菜单都在,新建项目与新建标题各自换了图标`() {
        val text = sourceOf(QUICK_ADD)?.readText() ?: return

        for (label in listOf("新建待办", "新建项目", "新建区域", "新建标题")) {
            assertTrue("菜单项不能丢:$label", text.contains("\"$label\""))
        }

        val projectLine = menuItemLine(text, "新建项目")
        assertTrue("新建项目必须用 H 图标:$projectLine", projectLine.contains("OrdoMenuIcons.Project"))
        assertFalse("新建项目不能再用 OrdoIcons.Area:$projectLine", projectLine.contains("OrdoIcons.Area"))

        val areaLine = menuItemLine(text, "新建区域")
        assertTrue("新建区域用圆角方框+中心点:$areaLine", areaLine.contains("OrdoMenuIcons.Area"))

        val headingLine = menuItemLine(text, "新建标题")
        assertTrue("新建标题用三横线:$headingLine", headingLine.contains("OrdoMenuIcons.Heading"))
        assertFalse("新建标题不能借 H:$headingLine", headingLine.contains("OrdoMenuIcons.Project"))
    }

    @Test
    fun `快捷键提示只有新建待办一项`() {
        val text = sourceOf(QUICK_ADD)?.readText() ?: return
        assertEquals("有且只有一处 Ctrl+N", 1, Regex("\"Ctrl\\+N\"").findAll(text).count())
        val todoLine = menuItemLine(text, "新建待办")
        assertTrue("Ctrl+N 挂在新建待办上:$todoLine", todoLine.contains("Ctrl+N"))
        assertTrue("图标走 textSecondary 令牌", text.contains("tint = colors.textSecondary"))
        assertFalse("不得引入参照原型的蓝色", text.contains("0A84FF"))
    }

    /** 菜单项那一行(跳过弹窗标题映射里同名的 "新建项目" 之类) */
    private fun menuItemLine(text: String, label: String): String =
        text.lines().first { it.contains("MenuItem(") && it.contains("\"$label\"") }

    @Test
    fun `图标是矢量绘制,没有新增位图资源`() {
        val text = sourceOf(MENU_ICONS)?.readText() ?: return

        assertTrue("必须用 ImageVector 绘制", text.contains("ImageVector.Builder"))
        for (bitmap in listOf(".png", ".jpg", ".svg", ".webp", "painterResource")) {
            assertFalse("图标不得依赖位图 / 资源文件:$bitmap", text.contains(bitmap))
        }
    }

    private fun sourceOf(relative: String): File? {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        assumeTrue("找不到 $relative,跳过源码级断言", false)
        return null
    }

    // ------------------------------------------------------------ 工具

    private fun pathsOf(icon: ImageVector): List<VectorPath> {
        val out = mutableListOf<VectorPath>()
        fun walk(node: VectorNode) {
            when (node) {
                is VectorPath -> out.add(node)
                is VectorGroup -> node.forEach { walk(it) }
            }
        }
        walk(icon.root)
        return out
    }

    private fun singlePath(icon: ImageVector): VectorPath {
        val found = pathsOf(icon)
        assertEquals("这个图标应该只有一条路径:${icon.name}", 1, found.size)
        return found.first()
    }

    /** 按 `MoveTo` 切出子路径:每条直线/横竖线是一条独立子路径(坐标可逐点核对) */
    private fun subpathsOf(path: VectorPath): List<List<PathNode>> {
        val out = mutableListOf<MutableList<PathNode>>()
        for (node in path.pathData) {
            if (node is PathNode.MoveTo || out.isEmpty()) out.add(mutableListOf(node)) else out.last().add(node)
        }
        return out
    }

    /** 圆弧节点:`arcToRelative` 生成的是 [PathNode.RelativeArcTo],绝对值那支是 [PathNode.ArcTo],两个都算 */
    private fun arcsOf(path: VectorPath): Int =
        path.pathData.count { it is PathNode.ArcTo || it is PathNode.RelativeArcTo }

    private fun assertBlackStroke(path: VectorPath) {
        assertEquals("描边画成黑色,由 Icon(tint) 上色", Color.Black, (path.stroke as SolidColor).value)
    }

    private companion object {
        const val QUICK_ADD = "src/main/kotlin/com/ordo/desktop/ui/quickadd/QuickAdd.kt"
        const val MENU_ICONS = "src/main/kotlin/com/ordo/desktop/ui/common/OrdoMenuIcons.kt"
    }
}
