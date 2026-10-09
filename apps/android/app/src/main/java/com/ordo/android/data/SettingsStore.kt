package com.ordo.android.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.ordo.android.ui.theme.ThemeMode
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/** DataStore 实例（进程内单例，由 Application 传入 Context） */
private val Context.ordoDataStore: DataStore<Preferences> by preferencesDataStore(name = "ordo_settings")

/**
 * 应用设置（外观模式、服务器地址）。
 * 契约 §8 的 kv 表用于同步状态与令牌；用户偏好这类纯本地设置走 DataStore。
 */
class SettingsStore(context: Context) {

    private val store = context.applicationContext.ordoDataStore

    private val keyThemeMode = stringPreferencesKey("themeMode")
    private val keyServerUrl = stringPreferencesKey("serverUrl")
    private val keyLastSyncAt = stringPreferencesKey("lastSyncAt")

    val themeMode: Flow<ThemeMode> = store.data.map { ThemeMode.fromKey(it[keyThemeMode]) }

    val serverUrl: Flow<String?> = store.data.map { it[keyServerUrl] }

    val lastSyncAt: Flow<Long> = store.data.map { it[keyLastSyncAt]?.toLongOrNull() ?: 0L }

    suspend fun setThemeMode(mode: ThemeMode) {
        store.edit { it[keyThemeMode] = mode.storageKey }
    }

    suspend fun setServerUrl(url: String) {
        store.edit { it[keyServerUrl] = url.trim().trimEnd('/') }
    }

    suspend fun setLastSyncAt(epochMillis: Long) {
        store.edit { it[keyLastSyncAt] = epochMillis.toString() }
    }
}
