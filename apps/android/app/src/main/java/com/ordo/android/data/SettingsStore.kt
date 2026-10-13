package com.ordo.android.data

import com.ordo.android.ui.theme.ThemeMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

/**
 * 应用设置（外观模式）。
 *
 * v1.4（纯本地）后用引导库的 kv 承载（原来走 DataStore，但 DataStore 会带进 okio 这一层
 * 与套接字相关的传递依赖；纯本地应用没有必要，因此换成一行 kv）。
 * 服务器地址与"上次同步时刻"已随云同步一起删除，这里只剩外观。
 */
class SettingsStore(private val storage: SqliteStorage) {

    private val _themeMode = MutableStateFlow(readThemeMode())

    /** 外观模式（界面直接 collect；初值即本地已存的值） */
    val themeMode: StateFlow<ThemeMode> = _themeMode.asStateFlow()

    suspend fun setThemeMode(mode: ThemeMode) {
        withContext(Dispatchers.IO) { storage.kvSet(KEY_THEME_MODE, mode.storageKey) }
        _themeMode.value = mode
    }

    private fun readThemeMode(): ThemeMode =
        ThemeMode.fromKey(runCatching { storage.kvGet(KEY_THEME_MODE) }.getOrNull())

    private companion object {
        const val KEY_THEME_MODE = "ordo.themeMode"
    }
}
