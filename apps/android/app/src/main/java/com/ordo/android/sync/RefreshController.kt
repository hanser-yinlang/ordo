package com.ordo.android.sync

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/* ============================================================================
 * 刷新控件状态机（UI §5.3）
 *
 * 用户实测问题：状态栏右侧原来只是一个可点击的**文字**，点了只有文字变化，
 * 完全感知不到"刷新了没有"。新规范：
 *   同步中 → 图标**连续旋转**（每圈 900ms，linear，持续到结束）+ 文字「同步中…」
 *   成功   → 停止旋转 + 图标转 success 色 320ms + 文字「已同步」，1.4s 后回到常态
 *   失败   → 图标 danger 色 + 文字「同步失败，点击重试」（常驻，直到重试）
 *   同步中按钮禁用；结束后 1.4s 内保持禁用（防抖）
 *
 * 这里只做状态转移（纯逻辑，可 JVM 单测）；旋转/变色是界面层按这些常量渲染的。
 * ========================================================================== */

/** 刷新控件的四个阶段 */
enum class RefreshPhase {
    /** 常态：显示最近一次结果（已同步 / 未登录 …） */
    IDLE,

    /** 同步中：图标连续旋转 */
    SYNCING,

    /** 成功：图标 success 色 + 「已同步」，1.4s 后回 [IDLE] */
    SUCCESS,

    /** 失败：图标 danger 色 + 「同步失败，点击重试」，常驻 */
    FAILED,
}

/** 状态栏右侧的文案键（由界面层翻成字符串资源） */
enum class RefreshLabel {
    IDLE,
    SYNCING,
    SYNCED,
    FAILED,
    OFFLINE,
    NEVER,
    UNSYNCED,
}

/**
 * 刷新控件的可渲染状态。
 *
 * @param spinning 图标是否连续旋转（同步中为 true；其余阶段一律停转）
 * @param enabled 按钮是否可点（同步中 + 成功后 1.4s 防抖窗口内为 false）
 */
data class RefreshUiState(
    val phase: RefreshPhase = RefreshPhase.IDLE,
    val label: RefreshLabel = RefreshLabel.IDLE,
    val spinning: Boolean = false,
    val enabled: Boolean = true,
) {
    /** 图标色调语义：由界面层映射到 success / danger / accent / tertiary */
    val tone: RefreshTone
        get() = when (phase) {
            RefreshPhase.SYNCING -> RefreshTone.ACCENT
            RefreshPhase.SUCCESS -> RefreshTone.SUCCESS
            RefreshPhase.FAILED -> RefreshTone.DANGER
            RefreshPhase.IDLE -> when (label) {
                RefreshLabel.FAILED -> RefreshTone.DANGER
                RefreshLabel.SYNCED -> RefreshTone.SUCCESS
                RefreshLabel.SYNCING -> RefreshTone.ACCENT
                else -> RefreshTone.NEUTRAL
            }
        }
}

enum class RefreshTone { NEUTRAL, ACCENT, SUCCESS, DANGER }

/**
 * 刷新控件控制器（单例挂在 ViewModel 上）。
 *
 * [now] 可注入，便于测试防抖窗口；生产用系统时钟。
 */
class RefreshController(
    private val now: () -> Long = { System.currentTimeMillis() },
) {

    private val _state = MutableStateFlow(RefreshUiState())
    val state: StateFlow<RefreshUiState> = _state.asStateFlow()

    /** 上次同步结束的时刻（用于 1.4s 防抖窗口；0 表示尚未同步过） */
    var lastFinishedAt: Long = 0L
        private set

    /** 点击刷新键 / 下拉刷新：同步中或防抖窗口内返回 false（空操作，不重复触发） */
    fun onClick(): Boolean {
        if (!_state.value.enabled) return false
        return requestSync()
    }

    /** 由轮询 / 回前台触发的同步同样走这里，保证状态栏与"立即同步"表现一致 */
    fun requestSync(): Boolean {
        if (_state.value.phase == RefreshPhase.SYNCING) return false
        _state.value = RefreshUiState(
            phase = RefreshPhase.SYNCING,
            label = RefreshLabel.SYNCING,
            spinning = true,
            enabled = false,
        )
        return true
    }

    fun onSyncFinished(ok: Boolean) {
        lastFinishedAt = now()
        _state.value = if (ok) {
            // 成功：图标停转 + success 色 +「已同步」；此后 1.4s 保持禁用（防抖）
            RefreshUiState(
                phase = RefreshPhase.SUCCESS,
                label = RefreshLabel.SYNCED,
                spinning = false,
                enabled = false,
            )
        } else {
            // 失败：常驻 danger +「同步失败，点击重试」，按钮立刻可再点
            RefreshUiState(
                phase = RefreshPhase.FAILED,
                label = RefreshLabel.FAILED,
                spinning = false,
                enabled = true,
            )
        }
    }

    /** 成功态维持 1.4s 后调用：回到常态并解除防抖禁用 */
    fun settle() {
        if (_state.value.phase == RefreshPhase.SUCCESS) {
            _state.value = RefreshUiState(
                phase = RefreshPhase.IDLE,
                label = RefreshLabel.SYNCED,
                spinning = false,
                enabled = true,
            )
        } else if (_state.value.phase == RefreshPhase.IDLE && !_state.value.enabled) {
            _state.value = _state.value.copy(enabled = true)
        }
    }

    /** 同步被上层判定为"离线"（未发出请求）：既不算成功也不算失败，但必须解锁按钮 */
    fun onOffline() {
        lastFinishedAt = now()
        _state.value = RefreshUiState(
            phase = RefreshPhase.IDLE,
            label = RefreshLabel.OFFLINE,
            spinning = false,
            enabled = true,
        )
    }

    /** 未登录：按钮禁用（点了也没有意义） */
    fun onNotLoggedIn() {
        _state.value = RefreshUiState(
            phase = RefreshPhase.IDLE,
            label = RefreshLabel.NEVER,
            spinning = false,
            enabled = false,
        )
    }

    /** 同步由其它来源（前台轮询）静默完成：只在非失败态更新文案，不打断用户的重试提示 */
    fun onIdle() {
        if (_state.value.phase == RefreshPhase.FAILED) return
        _state.value = RefreshUiState(
            phase = RefreshPhase.IDLE,
            label = RefreshLabel.IDLE,
            spinning = false,
            enabled = true,
        )
    }

    companion object {
        /** 成功态停留时长（UI §5.3：1.4s 后回到常态） */
        const val SETTLE_MILLIS = 1_400L

        /** 同步中图标每圈时长（UI §5.3：每圈 900ms，linear） */
        const val ROTATION_PERIOD_MILLIS = 900

        /** 成功色闪现的过渡时长（UI §5.3：320ms） */
        const val SUCCESS_FLASH_MILLIS = 320

        /** 触控目标（UI §5.3：28dp 圆形图标按钮；容器保证 ≥44 触控） */
        const val ICON_SIZE_DP = 28
    }
}
