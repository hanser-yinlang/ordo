package com.ordo.android.notify

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.content.ContextCompat
import com.ordo.android.MainActivity
import com.ordo.android.R

/**
 * 提醒通知（契约 §7.5 Fastlane / 本地提醒）：渠道 ordo_reminders。
 * 点击通知通过深链 ordo://todo/{id} 打开对应待办。
 */
class Notifier(private val context: Context) {

    fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.notif_channel_name),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = context.getString(R.string.notif_channel_desc)
            enableVibration(true)
        }
        manager.createNotificationChannel(channel)
    }

    fun canNotify(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    /** 到点提醒；返回是否真的发出（无权限时为 false） */
    fun notifyReminder(todoId: String, title: String, at: String): Boolean {
        if (!canNotify()) return false
        ensureChannel()
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false

        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse("ordo://todo/$todoId")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            todoId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = android.app.Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(R.string.notif_title))
            .setContentText(title)
            .setSubText(at)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        manager.notify(todoId.hashCode(), notification)
        return true
    }

    companion object {
        const val CHANNEL_ID = "ordo_reminders"
    }
}
