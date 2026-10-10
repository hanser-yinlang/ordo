package com.ordo.desktop.ui.shell

import androidx.compose.runtime.Composable
import com.ordo.desktop.app.GateDecision
import com.ordo.desktop.app.GateStage

/**
 * 登录门禁宿主(契约 §7.6.4 / 04-UI规范 §5.1)。
 *
 * ```
 * 读 session ─┬─ 无 / refresh 失败且已过期 → 登录页(登录 / 注册 / 游客登录)
 *             └─ 有且可用                  → 主界面
 * ```
 *
 * 只做"二选一"的切换,**两个分支都由调用方给**:
 * 桌面端的登录页必须住在一个真实的 [androidx.compose.ui.window.Window] 里
 * (在 `application { }` 作用域直接组合 Text 会因为缺少 `LocalFontFamilyResolver` 直接崩),
 * 所以宿主不替调用方决定用什么容器承载。
 *
 * 之所以做成一个显式宿主(而不是在窗口里散着判断):门禁是**唯一**决定"能不能进主界面"的地方,
 * 主界面侧因此完全不必知道"登录"这件事,退出登录也只需要回到 LOGIN 这一个动作。
 *
 * @param login 登录页(桌面上是一个独立的小窗口)
 * @param main 主界面:只在 [GateStage.MAIN] 时组合 —— 引擎与数据目录因此也只在该账号下才会被创建
 */
@Composable
fun OrdoGateHost(
    decision: GateDecision,
    login: @Composable () -> Unit,
    main: @Composable () -> Unit
) {
    when (decision.stage) {
        GateStage.LOGIN -> login()
        GateStage.MAIN -> main()
    }
}
