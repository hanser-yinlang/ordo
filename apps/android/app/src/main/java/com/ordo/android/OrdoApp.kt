package com.ordo.android

import android.app.Application
import com.ordo.android.di.ServiceLocator
import com.ordo.android.notify.Notifier
import com.ordo.android.notify.ReminderWorker

class OrdoApp : Application() {

    override fun onCreate() {
        super.onCreate()
        ServiceLocator.init(this)
        // 通知渠道 + 提醒任务（周期兜底 + 下一个准点任务）
        runCatching { Notifier(this).ensureChannel() }
        runCatching { ReminderWorker.bootstrap(this) }
    }
}
