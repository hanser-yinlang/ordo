package com.ordo.desktop.ui.common

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * 快加号菜单的四个前导图标(04-UI规范 §5.2「菜单项图标(v1.3 对齐参照原型,四端一致)」)。
 *
 * **几何与线宽以 §5.2 的表为准**,数值取自参照原型 `things-clone` 的 `i-plus` / `i-heading` / `i-area`
 * 的原始定义(同为 20×20 viewBox),所以下面的坐标是可逐点核对的,不是随手画的:
 *
 * | 本项目 | 参照原型 symbol | §5.2 规定的几何 |
 * |---|---|---|
 * | [Todo] | `#i-plus` | 两条直线 `(4,10)-(16,10)`、`(10,4)-(10,16)`,stroke 2.1 圆头 |
 * | [Project] | `#i-heading` | 两竖 `x=5`/`x=15`(y 4→16)+ 中间一横 `y=10`(x 5→15),stroke 1.7 圆头 |
 * | [Area] | `#i-area` | 方框 `rect(3,3,14,14) rx=4`(stroke 1.5)+ 中心 `circle(10,10) r=2.6` 实心 |
 * | [Heading] | —(Ordo 自有项) | 三横线 `y=5/10/15`(x 4.5→15.5),stroke 1.7 圆头 |
 *
 * 三条硬约束:
 * 1. **矢量绘制**,不新增任何位图资源(与 `OrdoIcons` 里那些 Material 图标一样进 `ImageVector`);
 * 2. 图标**不带颜色语义**:一律画成黑色,由调用方用 `Icon(tint = …)` 上主题令牌 —— §5.2 要求
 *    菜单项图标只走 `textSecondary`、FAB 与选中态走 `accent.primary`,**不引入参照原型的蓝色**;
 * 3. 渲染尺寸由调用方给([com.ordo.desktop.ui.quickadd.QuickAddMenuSpec.ICON_SIZE] = 16dp),
 *    与参照原型 `.pop-item .ico { width:16px; height:16px }` 一致(20 单位画进 16dp,描边等比缩到 ×0.8)。
 */
object OrdoMenuIcons {

    /** §5.2:＋ 的 stroke = 2.1 */
    private const val PLUS_STROKE = 2.1f

    /** §5.2:H 与 ≡ 的 stroke = 1.7 */
    private const val HEADING_STROKE = 1.7f

    /** §5.2:区域方框的 stroke = 1.5 */
    private const val AREA_STROKE = 1.5f

    /** 新建待办:＋(`(4,10)-(16,10)` 与 `(10,4)-(10,16)`,stroke 2.1 圆头) */
    val Todo: ImageVector = ImageVector.Builder(
        name = "OrdoMenuTodo",
        defaultWidth = 20.dp,
        defaultHeight = 20.dp,
        viewportWidth = 20f,
        viewportHeight = 20f
    ).apply {
        strokePath(PLUS_STROKE) {
            moveTo(10f, 4f)
            verticalLineTo(16f)
            moveTo(4f, 10f)
            horizontalLineTo(16f)
        }
    }.build()

    /** 新建项目:H(两竖 `x=5`/`x=15` y 4→16 + 一横 `y=10` x 5→15,stroke 1.7 圆头) */
    val Project: ImageVector = ImageVector.Builder(
        name = "OrdoMenuProject",
        defaultWidth = 20.dp,
        defaultHeight = 20.dp,
        viewportWidth = 20f,
        viewportHeight = 20f
    ).apply {
        strokePath(HEADING_STROKE) {
            moveTo(5f, 4f)
            verticalLineTo(16f)
            moveTo(15f, 4f)
            verticalLineTo(16f)
            moveTo(5f, 10f)
            horizontalLineTo(15f)
        }
    }.build()

    /**
     * 新建区域:圆角方框 + 中心点(方框 `rect(3,3,14,14) rx=4` stroke 1.5;中心 `circle(10,10) r=2.6` 实心)。
     *
     * 方框的四个角用 `A 4 4 0 0 1` 的圆弧(与 SVG `rx=4` 等价),不是用二次曲线糊出来的。
     */
    val Area: ImageVector = ImageVector.Builder(
        name = "OrdoMenuArea",
        defaultWidth = 20.dp,
        defaultHeight = 20.dp,
        viewportWidth = 20f,
        viewportHeight = 20f
    ).apply {
        strokePath(AREA_STROKE) {
            moveTo(7f, 3f)
            lineTo(13f, 3f)
            arcToRelative(4f, 4f, 0f, isMoreThanHalf = false, isPositiveArc = true, dx1 = 4f, dy1 = 4f)
            lineTo(17f, 13f)
            arcToRelative(4f, 4f, 0f, isMoreThanHalf = false, isPositiveArc = true, dx1 = -4f, dy1 = 4f)
            lineTo(7f, 17f)
            arcToRelative(4f, 4f, 0f, isMoreThanHalf = false, isPositiveArc = true, dx1 = -4f, dy1 = -4f)
            lineTo(3f, 7f)
            arcToRelative(4f, 4f, 0f, isMoreThanHalf = false, isPositiveArc = true, dx1 = 4f, dy1 = -4f)
            close()
        }
        path(fill = SolidColor(Color.Black)) {
            // 中心 r2.6 实心点(从顶点起两个半圆)
            moveTo(10f, 7.4f)
            arcToRelative(2.6f, 2.6f, 0f, isMoreThanHalf = true, isPositiveArc = true, dx1 = 0f, dy1 = 5.2f)
            arcToRelative(2.6f, 2.6f, 0f, isMoreThanHalf = true, isPositiveArc = true, dx1 = 0f, dy1 = -5.2f)
            close()
        }
    }.build()

    /**
     * 新建标题:三横线(≡,`y=5/10/15` x 4.5→15.5,stroke 1.7 圆头)。
     *
     * 参照原型没有这一项(它借用 H 表示标题);Ordo 用**纯横线**与 [Project] 的 H 区分:
     * 三条等长横线、**没有任何竖线**,16dp 下也不会与 H 混淆。
     */
    val Heading: ImageVector = ImageVector.Builder(
        name = "OrdoMenuHeading",
        defaultWidth = 20.dp,
        defaultHeight = 20.dp,
        viewportWidth = 20f,
        viewportHeight = 20f
    ).apply {
        strokePath(HEADING_STROKE) {
            moveTo(4.5f, 5f)
            horizontalLineTo(15.5f)
            moveTo(4.5f, 10f)
            horizontalLineTo(15.5f)
            moveTo(4.5f, 15f)
            horizontalLineTo(15.5f)
        }
    }.build()

    /** 只描边、不填充的路径:圆头 + 圆角连接(与参照原型 `stroke-linecap="round"` 一致) */
    private fun ImageVector.Builder.strokePath(
        width: Float,
        block: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit
    ) = path(
        fill = null,
        stroke = SolidColor(Color.Black),
        strokeLineWidth = width,
        strokeLineCap = StrokeCap.Round,
        strokeLineJoin = StrokeJoin.Round,
        pathBuilder = block
    )
}
