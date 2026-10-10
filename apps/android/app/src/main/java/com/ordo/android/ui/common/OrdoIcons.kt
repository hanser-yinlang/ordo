package com.ordo.android.ui.common

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoTheme

/**
 * Ordo 图标集：全部用 Canvas 自绘（20×20 视框），不依赖 material-icons-extended，
 * 也不使用 Things 的任何图标资产（04 文档 §1.1 合规边界）。
 */
enum class OrdoIconKind {
    Inbox, Today, Upcoming, Anytime, Someday, Logbook,
    Tag, Area, Project, Heading,
    Plus, Search, More, Check, Bell, Flag, Repeat, Note, Checklist,
    ChevronRight, ChevronDown, Close, Trash, Copy, Sun, Moon, Menu, Settings, Handle,
    /** 刷新（UI §5.3：状态栏刷新控件；同步中围绕中心连续旋转） */
    Refresh,
    /*
     * UI §5.2 v1.3「快加号菜单图标对齐参照原型」的三个专用形状。
     * 与上面的 Project（环形 + 点）/ Area（方框 + 点）/ Heading（H）**并存**：
     * 侧栏等处的旧形状不变，只有快加号菜单改用下列形状（项目 = H、区域 = 圆角方框 + 点、标题 = 三横线）。
     */
    /** 新建项目：H（两竖 + 中间一横），stroke 1.7 圆头 */
    LetterH,
    /** 新建区域：14×14 圆角 4 的描边方框 + 中心 2.6 实心点 */
    RoundedSquareDot,
    /** 新建标题：三横线（≡），与 H 可区分的标题线形 */
    TripleLine,
}

@Composable
fun OrdoIcon(
    kind: OrdoIconKind,
    modifier: Modifier = Modifier,
    size: Dp = OrdoLayout.sidebarIconSize,
    tint: Color = OrdoTheme.colors.textSecondary,
    strokeWidth: Float = 1.6f,
) {
    Canvas(modifier = modifier.size(size)) {
        val u = this.size.minDimension / 20f
        val stroke = Stroke(width = strokeWidth * u, cap = StrokeCap.Round, join = StrokeJoin.Round)
        drawIcon(kind, tint, stroke, u)
    }
}

private fun DrawScope.drawIcon(
    kind: OrdoIconKind,
    tint: Color,
    stroke: Stroke,
    u: Float,
) {
    fun line(x1: Float, y1: Float, x2: Float, y2: Float) =
        drawLine(tint, Offset(x1 * u, y1 * u), Offset(x2 * u, y2 * u), stroke.width, stroke.cap)

    fun path(build: Path.() -> Unit) {
        val p = Path().apply { build() }
        drawPath(p, tint, style = stroke)
    }

    fun pathFilled(build: Path.() -> Unit) {
        val p = Path().apply { build() }
        drawPath(p, tint)
    }

    fun dot(x: Float, y: Float, r: Float = 1.2f) =
        drawCircle(tint, r * u, Offset(x * u, y * u))

    when (kind) {
        OrdoIconKind.Inbox -> {
            path {
                moveTo(3 * u, 11.5f * u); lineTo(5 * u, 4 * u); lineTo(15 * u, 4 * u)
                lineTo(17 * u, 11.5f * u); lineTo(17 * u, 16 * u); lineTo(3 * u, 16 * u); close()
            }
            path {
                moveTo(3 * u, 11.5f * u); lineTo(6.5f * u, 11.5f * u); lineTo(7.5f * u, 13.5f * u)
                lineTo(12.5f * u, 13.5f * u); lineTo(13.5f * u, 11.5f * u); lineTo(17 * u, 11.5f * u)
            }
        }

        OrdoIconKind.Today -> {
            // 开口圆环 + 向内短划线（Ordo 品牌图形，04 文档 §1）
            drawArc(
                color = tint,
                startAngle = -60f,
                sweepAngle = 300f,
                useCenter = false,
                topLeft = Offset(3 * u, 3 * u),
                size = Size(14 * u, 14 * u),
                style = stroke,
            )
            line(7.5f, 10f, 13f, 10f)
        }

        OrdoIconKind.Upcoming -> {
            path {
                moveTo(4 * u, 6 * u); lineTo(16 * u, 6 * u); lineTo(16 * u, 17 * u)
                lineTo(4 * u, 17 * u); close()
            }
            line(4f, 9f, 16f, 9f)
            line(7f, 3.5f, 7f, 6.5f)
            line(13f, 3.5f, 13f, 6.5f)
            dot(7.5f, 12.5f, 1f); dot(12.5f, 12.5f, 1f)
        }

        OrdoIconKind.Anytime -> {
            line(3.5f, 6.5f, 16.5f, 6.5f)
            line(3.5f, 10f, 16.5f, 10f)
            line(3.5f, 13.5f, 11f, 13.5f)
            dot(15.5f, 15f, 1.6f)
        }

        OrdoIconKind.Someday -> {
            path {
                moveTo(3.5f, 7 * u); lineTo(16.5f * u, 7 * u); lineTo(16.5f * u, 16.5f * u)
                lineTo(3.5f * u, 16.5f * u); close()
            }
            line(3f, 10.5f, 7.5f, 10.5f); line(12.5f, 10.5f, 17f, 10.5f)
            line(8f, 4f, 12f, 4f); line(10f, 4f, 10f, 7f)
        }

        OrdoIconKind.Logbook -> {
            path {
                moveTo(5 * u, 3.5f * u); lineTo(14 * u, 3.5f * u); lineTo(14 * u, 16.5f * u)
                lineTo(6.5f * u, 16.5f * u)
            }
            path {
                moveTo(6.5f * u, 16.5f * u); lineTo(14 * u, 16.5f * u)
            }
            line(6.5f, 3.5f, 6.5f, 16.5f)
            line(9f, 7.5f, 12.5f, 7.5f)
            line(9f, 10.5f, 12.5f, 10.5f)
        }

        OrdoIconKind.Tag -> {
            path {
                moveTo(10.4f * u, 3 * u); lineTo(16 * u, 3 * u); lineTo(16 * u, 8.6f * u)
                lineTo(9.4f * u, 15.2f * u); lineTo(4.8f * u, 10.6f * u); close()
            }
            dot(13.2f, 5.8f, 1.2f)
        }

        OrdoIconKind.Area -> {
            path {
                moveTo(5 * u, 3.5f * u); lineTo(15 * u, 3.5f * u); lineTo(15 * u, 16.5f * u)
                lineTo(5 * u, 16.5f * u); close()
            }
            dot(10f, 10f, 2.4f)
        }

        OrdoIconKind.Project -> {
            drawArc(
                color = tint,
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = Offset(4 * u, 4 * u),
                size = Size(12 * u, 12 * u),
                style = stroke,
            )
            dot(10f, 10f, 2f)
        }

        OrdoIconKind.Heading -> {
            line(6f, 4f, 6f, 16f)
            line(14f, 4f, 14f, 16f)
            line(6f, 10f, 14f, 10f)
        }

        OrdoIconKind.Plus -> {
            // UI §5.2 v1.3：几何以规范表为准（取自参照原型 i-plus）——(4,10)-(16,10)、(10,4)-(10,16)
            line(10f, 4f, 10f, 16f)
            line(4f, 10f, 16f, 10f)
        }

        OrdoIconKind.Search -> {
            drawCircle(tint, 5.2f * u, Offset(9 * u, 9 * u), style = stroke)
            line(13f, 13f, 17f, 17f)
        }

        OrdoIconKind.More -> {
            dot(5f, 10f, 1.4f); dot(10f, 10f, 1.4f); dot(15f, 10f, 1.4f)
        }

        OrdoIconKind.Check -> {
            path {
                moveTo(5 * u, 10.6f * u); lineTo(8.3f * u, 13.9f * u); lineTo(15 * u, 6.6f * u)
            }
        }

        OrdoIconKind.Bell -> {
            path {
                moveTo(10 * u, 3 * u)
                cubicTo(7.5f * u, 3 * u, 5.6f * u, 4.9f * u, 5.6f * u, 7.4f * u)
                lineTo(5.6f * u, 11f * u)
                lineTo(4.2f * u, 13.6f * u)
                lineTo(15.8f * u, 13.6f * u)
                lineTo(14.4f * u, 11f * u)
                lineTo(14.4f * u, 7.4f * u)
                cubicTo(14.4f * u, 4.9f * u, 12.5f * u, 3 * u, 10 * u, 3 * u)
                close()
            }
            path {
                moveTo(8.2f * u, 16 * u)
                cubicTo(8.6f * u, 17.4f * u, 11.4f * u, 17.4f * u, 11.8f * u, 16 * u)
            }
        }

        OrdoIconKind.Flag -> {
            line(6f, 3.5f, 6f, 16.5f)
            path {
                moveTo(6 * u, 4.5f * u); lineTo(14.5f * u, 4.5f * u); lineTo(12.9f * u, 7.5f * u)
                lineTo(14.5f * u, 10.5f * u); lineTo(6 * u, 10.5f * u)
            }
        }

        OrdoIconKind.Repeat -> {
            path {
                moveTo(5 * u, 8.5f * u)
                cubicTo(5.6f * u, 5.6f * u, 8.2f * u, 4 * u, 11f * u, 4.4f * u)
                cubicTo(13f * u, 4.7f * u, 14.6f * u, 6f * u, 15.2f * u, 7.8f * u)
            }
            path {
                moveTo(15 * u, 11.5f * u)
                cubicTo(14.4f * u, 14.4f * u, 11.8f * u, 16 * u, 9f * u, 15.6f * u)
                cubicTo(7f * u, 15.3f * u, 5.4f * u, 14f * u, 4.8f * u, 12.2f * u)
            }
            path { moveTo(15.4f * u, 4.6f * u); lineTo(15.4f * u, 7.9f * u); lineTo(12.1f * u, 7.9f * u) }
            path { moveTo(4.6f * u, 15.4f * u); lineTo(4.6f * u, 12.1f * u); lineTo(7.9f * u, 12.1f * u) }
        }

        OrdoIconKind.Note -> {
            line(4.5f, 5f, 15.5f, 5f)
            line(4.5f, 9f, 15.5f, 9f)
            line(4.5f, 13f, 11f, 13f)
        }

        OrdoIconKind.Checklist -> {
            path { moveTo(3.8f * u, 6f * u); lineTo(5.2f * u, 7.4f * u); lineTo(7.6f * u, 4.8f * u) }
            path { moveTo(3.8f * u, 14f * u); lineTo(5.2f * u, 15.4f * u); lineTo(7.6f * u, 12.8f * u) }
            line(10f, 6f, 16.5f, 6f)
            line(10f, 14f, 16.5f, 14f)
        }

        OrdoIconKind.ChevronRight -> path {
            moveTo(8 * u, 5.5f * u); lineTo(12.5f * u, 10f * u); lineTo(8 * u, 14.5f * u)
        }

        OrdoIconKind.ChevronDown -> path {
            moveTo(5.5f * u, 8 * u); lineTo(10f * u, 12.5f * u); lineTo(14.5f * u, 8 * u)
        }

        OrdoIconKind.Close -> {
            line(5.5f, 5.5f, 14.5f, 14.5f)
            line(14.5f, 5.5f, 5.5f, 14.5f)
        }

        OrdoIconKind.Trash -> {
            line(4.5f, 6f, 15.5f, 6f)
            line(8f, 6f, 8f, 4.2f); line(12f, 6f, 12f, 4.2f); line(8f, 4.2f, 12f, 4.2f)
            path {
                moveTo(6.2f * u, 6 * u); lineTo(7 * u, 15.6f * u); lineTo(13 * u, 15.6f * u)
                lineTo(13.8f * u, 6 * u)
            }
        }

        OrdoIconKind.Copy -> {
            path {
                moveTo(7 * u, 7 * u); lineTo(16 * u, 7 * u); lineTo(16 * u, 16 * u); lineTo(7 * u, 16 * u); close()
            }
            path {
                moveTo(13 * u, 7 * u); lineTo(13 * u, 4.5f * u); lineTo(4 * u, 4.5f * u)
                lineTo(4 * u, 13.5f * u); lineTo(7 * u, 13.5f * u)
            }
        }

        OrdoIconKind.Sun -> {
            drawCircle(tint, 3.4f * u, Offset(10 * u, 10 * u), style = stroke)
            line(10f, 2.5f, 10f, 4.5f); line(10f, 15.5f, 10f, 17.5f)
            line(2.5f, 10f, 4.5f, 10f); line(15.5f, 10f, 17.5f, 10f)
            line(4.7f, 4.7f, 6.1f, 6.1f); line(13.9f, 13.9f, 15.3f, 15.3f)
            line(15.3f, 4.7f, 13.9f, 6.1f); line(6.1f, 13.9f, 4.7f, 15.3f)
        }

        OrdoIconKind.Moon -> path {
            moveTo(15.5f * u, 12.4f * u)
            cubicTo(14.9f * u, 12.7f * u, 14.2f * u, 12.9f * u, 13.4f * u, 12.9f * u)
            cubicTo(10.2f * u, 12.9f * u, 7.6f * u, 10.3f * u, 7.6f * u, 7.1f * u)
            cubicTo(7.6f * u, 6.2f * u, 7.8f * u, 5.4f * u, 8.2f * u, 4.7f * u)
            cubicTo(5.4f * u, 5.5f * u, 3.4f * u, 8.1f * u, 3.4f * u, 11.2f * u)
            cubicTo(3.4f * u, 14.9f * u, 6.4f * u, 17.9f * u, 10.1f * u, 17.9f * u)
            cubicTo(12.7f * u, 17.9f * u, 15f * u, 16.5f * u, 16.2f * u, 14.3f * u)
            cubicTo(16.1f * u, 13.7f * u, 15.8f * u, 13f * u, 15.5f * u, 12.4f * u)
            close()
        }

        OrdoIconKind.Menu -> {
            line(3.5f, 6f, 16.5f, 6f)
            line(3.5f, 10f, 16.5f, 10f)
            line(3.5f, 14f, 16.5f, 14f)
        }

        OrdoIconKind.Settings -> {
            drawCircle(tint, 2.6f * u, Offset(10 * u, 10 * u), style = stroke)
            line(10f, 2.6f, 10f, 4.6f); line(10f, 15.4f, 10f, 17.4f)
            line(2.6f, 10f, 4.6f, 10f); line(15.4f, 10f, 17.4f, 10f)
            line(4.8f, 4.8f, 6.2f, 6.2f); line(13.8f, 13.8f, 15.2f, 15.2f)
        }

        OrdoIconKind.Handle -> {
            dot(7.6f, 5.4f, 1.1f); dot(12.4f, 5.4f, 1.1f)
            dot(7.6f, 10f, 1.1f); dot(12.4f, 10f, 1.1f)
            dot(7.6f, 14.6f, 1.1f); dot(12.4f, 14.6f, 1.1f)
        }

        /** 刷新（UI §5.3）：一个不闭合的圆环 + 右上的箭头；旋转由调用方施加 */
        OrdoIconKind.Refresh -> {
            drawArc(
                color = tint,
                startAngle = 35f,
                sweepAngle = 285f,
                useCenter = false,
                topLeft = Offset(3.4f * u, 3.4f * u),
                size = Size(13.2f * u, 13.2f * u),
                style = stroke,
            )
            path {
                moveTo(15.9f * u, 3.4f * u)
                lineTo(16.3f * u, 7.6f * u)
                lineTo(12.2f * u, 6.6f * u)
            }
        }

        /* ---------- UI §5.2 v1.3：快加号菜单的三个专用形状（矢量绘制，无位图） ---------- */

        /** 新建项目：H —— 两竖 x=5/x=15（y 4→16）+ 中间一横 y=10（x 5→15），stroke 1.7 圆头（§5.2 表） */
        OrdoIconKind.LetterH -> {
            line(5f, 4f, 5f, 16f)
            line(15f, 4f, 15f, 16f)
            line(5f, 10f, 15f, 10f)
        }

        /** 新建区域：方框 rect(3,3,14,14) rx=4（stroke 1.5）+ 中心 circle(10,10) r=2.6 实心（§5.2 表） */
        OrdoIconKind.RoundedSquareDot -> {
            drawRoundRect(
                color = tint,
                topLeft = Offset(3f * u, 3f * u),
                size = Size(14f * u, 14f * u),
                cornerRadius = CornerRadius(4f * u, 4f * u),
                style = stroke,
            )
            dot(10f, 10f, 2.6f)
        }

        /** 新建标题：三条横线 y=5/10/15（x 4.5→15.5），stroke 1.7 圆头（§5.2 表） */
        OrdoIconKind.TripleLine -> {
            line(4.5f, 5f, 15.5f, 5f)
            line(4.5f, 10f, 15.5f, 10f)
            line(4.5f, 15f, 15.5f, 15f)
        }
    }
}
