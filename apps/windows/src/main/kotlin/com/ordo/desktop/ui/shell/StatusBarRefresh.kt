package com.ordo.desktop.ui.shell

import com.ordo.desktop.app.SyncStatus

/** 刷新控件的色调(图标与文字同色,§5.3) */
enum class RefreshTone { NEUTRAL, ACCENT, SUCCESS, DANGER }

/**
 * 刷新控件当前应该长什么样(纯值,界面只负责画)。
 *
 * @param label 状态文字:「同步」/「同步中…」/「已同步」/「同步失败，点击重试」
 * @param tone 图标与文字的颜色
 * @param spinning 图标是否连续旋转
 * @param enabled 是否可点击(同步中与结束后的 1.4s 防抖期内禁用)
 */
data class RefreshVisual(
    val label: String,
    val tone: RefreshTone,
    val spinning: Boolean,
    val enabled: Boolean
)

/**
 * 状态栏刷新控件的状态机(04-UI规范 §5.3「必须有可见效果」)。
 *
 * 旧实现只有文字变化,用户感知不到"刷新了没有";新规范要求:
 *
 * | 阶段 | 表现 |
 * |---|---|
 * | 同步中 | 图标**连续旋转**(每圈 900ms,linear,持续到结束)+ 文字「同步中…」 |
 * | 成功 | 停转并短暂转 `success` 色(320ms)+ 文字「已同步」,1.4s 后回到常态 |
 * | 失败 | 图标转 `danger` 色 + 文字「同步失败，点击重试」(常驻,直到重试) |
 *
 * 时间从外面喂进来(帧时钟),因此"320ms 变暗、1.4s 复位、同步中不可点"都能被逐帧断言。
 */
class RefreshControlModel(
    /** 旋转一圈的时长(§5.3:900ms,linear) */
    val spinPeriodMillis: Int = SPIN_PERIOD_MILLIS,
    /** 成功色保持时长(§5.3:320ms) */
    val successFlashMillis: Long = SUCCESS_FLASH_MILLIS,
    /** 结束后保持禁用的防抖时长(§5.3:1.4s) */
    val settleMillis: Long = SETTLE_MILLIS
) {

    private var status: SyncStatus = SyncStatus.LOCAL
    private var changedAtMillis: Long = 0L

    /** 把状态栏的同步状态喂进来(界面在状态变化时调用一次,附上当前时刻) */
    fun onStatusChanged(next: SyncStatus, nowMillis: Long) {
        if (next == status) return
        status = next
        changedAtMillis = nowMillis
    }

    /** 当前应该显示的样子 */
    fun visual(nowMillis: Long): RefreshVisual = when (status) {
        SyncStatus.SYNCING -> RefreshVisual("同步中…", RefreshTone.ACCENT, spinning = true, enabled = false)
        SyncStatus.SYNCED -> {
            val elapsed = nowMillis - changedAtMillis
            RefreshVisual(
                label = "已同步",
                // 成功后 320ms 内是 success 色,之后回到常态色(文字保留「已同步」)
                tone = if (elapsed < successFlashMillis) RefreshTone.SUCCESS else RefreshTone.NEUTRAL,
                spinning = false,
                enabled = elapsed >= settleMillis
            )
        }
        // 离线与失败都给出"点击重试":这是常驻状态,直到用户重试(§5.3)
        SyncStatus.OFFLINE, SyncStatus.ERROR ->
            RefreshVisual("同步失败，点击重试", RefreshTone.DANGER, spinning = false, enabled = true)

        SyncStatus.LOCAL -> RefreshVisual("同步", RefreshTone.NEUTRAL, spinning = false, enabled = true)
    }

    /** 是否还需要继续跑帧循环(旋转 / 成功色 / 防抖期都需要) */
    fun needsFrames(nowMillis: Long): Boolean = when (status) {
        SyncStatus.SYNCING -> true
        SyncStatus.SYNCED -> nowMillis - changedAtMillis < settleMillis
        else -> false
    }

    /** 点击是否生效(同步中与防抖期内一律忽略,防止重复触发) */
    fun canTrigger(nowMillis: Long): Boolean = visual(nowMillis).enabled

    companion object {
        /** 旋转一圈 900ms(§5.3) */
        const val SPIN_PERIOD_MILLIS = 900

        /** 成功色 320ms(§5.3) */
        const val SUCCESS_FLASH_MILLIS = 320L

        /** 结束后 1.4s 内保持禁用(§5.3) */
        const val SETTLE_MILLIS = 1_400L
    }
}
