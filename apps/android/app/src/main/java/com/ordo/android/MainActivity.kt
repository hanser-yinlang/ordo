package com.ordo.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ordo.android.nav.Routes
import com.ordo.android.ui.shell.OrdoRoot
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.OrdoViewModel

class MainActivity : ComponentActivity() {

    private val vm: OrdoViewModel by viewModels()

    private var pendingDeepLink by mutableStateOf<String?>(null)

    private val notificationPermission: ActivityResultLauncher<String> =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* 结果不阻断使用 */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 边到边：安全区由 Compose 侧的 WindowInsets 处理
        WindowCompat.setDecorFitsSystemWindows(window, false)
        pendingDeepLink = parseDeepLink(intent)

        setContent {
            val state by vm.state.collectAsStateWithLifecycle()
            OrdoTheme(themeMode = state.themeMode) {
                OrdoRoot(
                    state = state,
                    vm = vm,
                    deepLink = pendingDeepLink,
                    onDeepLinkConsumed = { pendingDeepLink = null },
                )
            }
            RequestNotificationPermission(notificationPermission)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        parseDeepLink(intent)?.let { pendingDeepLink = it }
    }

    override fun onResume() {
        super.onResume()
        // 04 文档 §3 / 契约 §7.1：回到前台触发一次同步
        vm.onAppForeground()
    }

    override fun onPause() {
        vm.onAppBackground()
        super.onPause()
    }

    /** ordo://list/today · ordo://todo/{id} · ordo://project/{id} */
    private fun parseDeepLink(intent: Intent?): String? {
        val data = intent?.data ?: return null
        if (data.scheme != "ordo") return null
        return Routes.fromDeepLink(data.host, data.pathSegments.firstOrNull())
    }
}

@Composable
private fun RequestNotificationPermission(launcher: ActivityResultLauncher<String>) {
    val context = LocalContext.current
    var asked by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        if (asked) return@LaunchedEffect
        asked = true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return@LaunchedEffect
        val granted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
}
