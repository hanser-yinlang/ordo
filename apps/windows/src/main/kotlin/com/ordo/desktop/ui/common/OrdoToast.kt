package com.ordo.desktop.ui.common

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.ordo.desktop.app.ToastMessage
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.ordoColors
import kotlinx.coroutines.delay

/** 提示条(§4:底部居中,圆角 pill,2.4s 自动消失) */
@Composable
fun OrdoToastHost(message: ToastMessage?, onDismiss: (Long) -> Unit) {
    val colors = ordoColors
    LaunchedEffect(message?.id) {
        val current = message ?: return@LaunchedEffect
        delay(2_400)
        onDismiss(current.id)
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        AnimatedVisibility(
            visible = message != null,
            enter = fadeIn() + slideInVertically { it / 2 },
            exit = fadeOut() + slideOutVertically { it / 2 }
        ) {
            val shape = RoundedCornerShape(OrdoRadius.pill)
            Box(
                Modifier
                    .padding(bottom = 56.dp)
                    .clip(shape)
                    .background(colors.textPrimary, shape)
                    .padding(horizontal = OrdoSpace.l, vertical = 10.dp)
            ) {
                Text(message?.text ?: "", style = OrdoType.caption, color = colors.canvas)
            }
        }
    }
}
