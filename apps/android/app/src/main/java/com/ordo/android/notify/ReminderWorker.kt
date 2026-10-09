package com.ordo.android.notify

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.ordo.android.di.ServiceLocator
import com.ordo.core.util.OrdoJson
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.concurrent.TimeUnit

/**
 * 提醒工作器：
 *   1) 扫描本地 pending 提醒，到点发系统通知（点击深链 ordo://todo/{id}）
 *   2) 为「下一个即将到点的提醒」排一次性任务，实现准点触发
 *   3) 另有 15 分钟周期任务兜底（进程被杀 / 重启后仍能补发）
 *
 * reminder 字段格式固定为 "YYYY-MM-DDTHH:mm"（契约 §2 顶部）。
 */
class ReminderWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val storage = ServiceLocator.storage
        val notifier = Notifier(applicationContext)
        notifier.ensureChannel()

        val now = System.currentTimeMillis()
        val fired = readFiredMap()
        var changed = false

        val todos = runCatching { storage.reminderTodos() }.getOrDefault(emptyList())
        todos.forEach { todo ->
            val at = todo.reminder
            if (at.isNullOrBlank()) return@forEach
            if (fired[todo.id] == at) return@forEach
            val millis = parseReminderMillis(at) ?: return@forEach
            val due = millis <= now + LOOKAHEAD_MILLIS && millis >= now - GRACE_MILLIS
            if (!due) return@forEach
            notifier.notifyReminder(todo.id, todo.title, at)
            fired[todo.id] = at
            changed = true
        }

        if (changed) saveFiredMap(fired)
        scheduleNextRun(applicationContext)
        return Result.success()
    }

    /* ----------------------------- 触发计划 ----------------------------- */

    companion object {
        const val UNIQUE_PERIODIC = "ordo-reminders-periodic"
        const val UNIQUE_NEXT = "ordo-reminders-next"
        const val INTERVAL_MINUTES = 15L
        const val LOOKAHEAD_MILLIS = 60_000L
        const val GRACE_MILLIS = 10 * 60_000L
        private const val KEY_FIRED = "firedReminders"

        /** 应用启动时调用：注册周期兜底任务 + 排下一个准点任务 */
        fun bootstrap(context: Context) {
            val periodic = PeriodicWorkRequestBuilder<ReminderWorker>(INTERVAL_MINUTES, TimeUnit.MINUTES)
                .build()
            runCatching {
                WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                    UNIQUE_PERIODIC,
                    ExistingPeriodicWorkPolicy.KEEP,
                    periodic,
                )
            }
            scheduleNextRun(context)
        }

        /** 为最早的未来提醒排一次性任务（准点触发） */
        fun scheduleNextRun(context: Context) {
            val scope = ServiceLocator.applicationScope
            scope.launch {
                val now = System.currentTimeMillis()
                val next = runCatching { ServiceLocator.storage.reminderTodos() }
                    .getOrDefault(emptyList())
                    .mapNotNull { todo ->
                        todo.reminder?.let { parseReminderMillis(it) }
                    }
                    .filter { it > now }
                    .minOrNull()
                    ?: return@launch

                val delayMillis = (next - now).coerceAtLeast(1_000L)
                val request = OneTimeWorkRequestBuilder<ReminderWorker>()
                    .setInitialDelay(delayMillis, TimeUnit.MILLISECONDS)
                    .build()
                runCatching {
                    WorkManager.getInstance(context).enqueueUniqueWork(
                        UNIQUE_NEXT,
                        ExistingWorkPolicy.REPLACE,
                        request,
                    )
                }
            }
        }

        /** "YYYY-MM-DDTHH:mm" → epoch millis（本地时区） */
        fun parseReminderMillis(value: String): Long? = runCatching {
            LocalDateTime.parse(value.trim()).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        }.getOrNull()
    }

    /* --------------------------- 已发记录（kv） --------------------------- */

    private suspend fun readFiredMap(): MutableMap<String, String> {
        val raw = runCatching { ServiceLocator.storage.kvGet(KEY_FIRED) }.getOrNull()
        if (raw.isNullOrBlank()) return mutableMapOf()
        return runCatching {
            OrdoJson.instance.parseToJsonElement(raw).jsonObject
                .mapValues { (_, value) -> value.jsonPrimitive.content }
                .toMutableMap()
        }.getOrDefault(mutableMapOf())
    }

    private suspend fun saveFiredMap(map: MutableMap<String, String>) {
        val json = buildJsonObject {
            map.forEach { (key, value) -> put(key, JsonPrimitive(value)) }
        }.toString()
        runCatching { ServiceLocator.storage.kvSet(KEY_FIRED, json) }
    }
}
