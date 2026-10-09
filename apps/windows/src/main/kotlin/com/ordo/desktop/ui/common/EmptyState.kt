package com.ordo.desktop.ui.common

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ordo.desktop.ui.theme.OrdoMotion
import com.ordo.desktop.ui.theme.OrdoSize
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.motionMillis
import com.ordo.desktop.ui.theme.ordoColors

/** 空状态(§4:居中插图 64 + 标题 20/26 + 副文案 13/18 + 主按钮) */
@Composable
fun EmptyState(
    title: String,
    subtitle: String? = null,
    icon: ImageVector? = null,
    action: (@Composable () -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    val colors = ordoColors
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(OrdoSpace.s)
        ) {
            if (icon != null) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = colors.textTertiary,
                    modifier = Modifier.size(48.dp)
                )
            }
            Text(title, style = OrdoType.title, color = colors.textSecondary, textAlign = TextAlign.Center)
            if (subtitle != null) {
                Text(
                    subtitle,
                    style = OrdoType.caption,
                    color = colors.textTertiary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = OrdoSpace.xl)
                )
            }
            if (action != null) {
                Spacer(Modifier.height(OrdoSpace.xs))
                action()
            }
        }
    }
}

/** 项目进度环(§4:18×18,底 hairline,进度 accent,线宽 2) */
@Composable
fun ProgressRing(
    progress: Float,
    modifier: Modifier = Modifier,
    size: Dp = OrdoSize.icon,
    strokeWidth: Dp = 2.dp,
    color: androidx.compose.ui.graphics.Color? = null,
    trackColor: androidx.compose.ui.graphics.Color? = null
) {
    val colors = ordoColors
    val animated by animateFloatAsState(
        targetValue = progress.coerceIn(0f, 1f),
        animationSpec = tween(motionMillis(OrdoMotion.BASE)),
        label = "progressRing"
    )
    Canvas(modifier.size(size)) {
        val stroke = strokeWidth.toPx()
        val inset = stroke / 2f
        val arcSize = Size(this.size.width - stroke, this.size.height - stroke)
        drawArc(
            color = trackColor ?: colors.hairline,
            startAngle = 0f,
            sweepAngle = 360f,
            useCenter = false,
            topLeft = Offset(inset, inset),
            size = arcSize,
            style = Stroke(width = stroke)
        )
        if (animated > 0.001f) {
            drawArc(
                color = color ?: colors.accent,
                startAngle = -90f,
                sweepAngle = 360f * animated,
                useCenter = false,
                topLeft = Offset(inset, inset),
                size = arcSize,
                style = Stroke(width = stroke, cap = StrokeCap.Round)
            )
        }
    }
}
