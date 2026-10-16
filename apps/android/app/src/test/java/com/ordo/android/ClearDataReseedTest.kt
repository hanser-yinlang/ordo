package com.ordo.android

import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「清空本地数据」的语义回归（与 Windows 端 `ClearDataReseedTest` 同一套口径）。
 *
 * 背景：Windows 端用户反馈「清除本地数据和演示数据后，重启应用不会重新显示演示数据，
 * 点一下『重置为示例数据』才回来」。根因是播种判据把「库文件在不在」当了替身 ——
 * 清空之后文件还在、内容为空，两个条件都不承认这是全新安装。
 *
 * 现在判据收口到引擎的**播种标记**（`kv[ordo.seedMark]`，见共享核心
 * `OrdoEngine.seedDemoData` / `OrdoEngine.clearAll` / `OrdoEngine.clearDemoData`），于是：
 *  ① 清空 = 连标记一起清掉 → 回到全新安装态，**下次冷启动自动重新播种**；
 *  ② 用户自己逐条删空待办（标记还在）→ 不会被演示数据复活；
 *  ③ 启动路径不再看数据库文件是否存在；
 *  ④ **清除演示数据** = 内容清空但标记钉住 → 重启后演示数据**不会**回来（用户明确要求的那条），
 *     想找回示例数据只能显式点「重置为示例数据」。
 *
 * Android 单测跑在 JVM 上、不引 Robolectric，所以分两层验证：
 *  - 存储层语义：共享核心 + [InMemoryStorage]（与真机 `SqliteStorage` 同一 `OrdoStorage` 接口）；
 *  - App 侧接线：用 [TestSource] 做源码级契约断言（设置页确实挂了按钮、启动确实走引擎判定）。
 *
 * ⚠ 本机没有 Android 设备/模拟器：真机点按手感仍需目视核对，这里只保证语义与接线。
 */
class ClearDataReseedTest {

    /** `OrdoEngine` 私有常量 `SEED_MARK_KEY` 的字面值（跨端同一把键） */
    private val seedMarkKey = "ordo.seedMark"

    private val seedMarkValue = "demo"

    private var idSeq = 0

    /** 同一份存储上再开一个引擎 = 等价于「App 重启后 ServiceLocator.init」 */
    private fun engineOn(storage: InMemoryStorage): OrdoEngine = OrdoEngine(
        storage = storage,
        clock = TestSupport.clock(),
        uuid = { "test-clear-" + idSeq++ },
    )

    /* ------------------------- ① 清空 → 冷启动重新播种 ------------------------- */

    @Test
    fun `清空本地数据后冷启动会重新播种演示数据`() {
        val storage = InMemoryStorage()
        val first = engineOn(storage)

        assertTrue("全新安装应播种", first.seedDemoData(force = false))
        assertTrue("播种后应有待办", first.snapshot.todos.isNotEmpty())
        assertEquals("播种应留下标记", seedMarkValue, storage.kvGet(seedMarkKey))

        first.clearAll()

        assertTrue("清空后库里应为空", first.snapshot.todos.isEmpty())
        assertNull("清空必须连播种标记一起清掉（否则下次启动不会播种）", storage.kvGet(seedMarkKey))

        val second = engineOn(storage)
        assertTrue("清空后冷启动应重新播种", second.seedDemoData(force = false))
        assertTrue("重启后应看到演示数据", second.snapshot.todos.isNotEmpty())
    }

    @Test
    fun `清空后再次冷启动不会重复播种`() {
        val storage = InMemoryStorage()
        engineOn(storage).let {
            it.seedDemoData(force = false)
            it.clearAll()
        }
        val second = engineOn(storage)
        assertTrue("第一次冷启动应播种", second.seedDemoData(force = false))

        val third = engineOn(storage)
        assertFalse("库里有内容时不得再播种（不得覆盖用户数据）", third.seedDemoData(force = false))
    }

    /* --------------------- ② 用户自己删空 → 不得复活 --------------------- */

    @Test
    fun `用户自己逐条删空待办后再启动不会复活演示数据`() {
        val storage = InMemoryStorage()
        val first = engineOn(storage)
        first.seedDemoData(force = false)

        first.snapshot.todos.filter { !it.deleted }.forEach { first.deleteTodo(it.id) }
        assertTrue("逐条删空后应没有未删待办", first.snapshot.todos.none { !it.deleted })
        assertEquals("用户删空不应清掉播种标记", seedMarkValue, storage.kvGet(seedMarkKey))

        val second = engineOn(storage)
        assertFalse("用户自己删空的库不得被演示数据复活", second.seedDemoData(force = false))
        assertTrue("重启后应仍然是空的", second.snapshot.todos.none { !it.deleted })
    }

    /* ------------- ④ 清除演示数据 → 清空且重启不再播种（用户明确要求） ------------- */

    @Test
    fun `清除演示数据后冷启动不会重新播种`() {
        val storage = InMemoryStorage()
        val first = engineOn(storage)
        assertTrue("全新安装应播种", first.seedDemoData(force = false))
        assertTrue("播种后应有待办", first.snapshot.todos.isNotEmpty())

        first.clearDemoData()

        assertTrue("清除演示数据后库里应为空", first.snapshot.todos.isEmpty())
        assertEquals(
            "清除演示数据必须把播种标记**钉住**（这是「重启不再出现演示数据」的全部依据）",
            seedMarkValue,
            storage.kvGet(seedMarkKey),
        )

        val second = engineOn(storage)
        assertFalse("清除演示数据后冷启动不得再播种", second.seedDemoData(force = false))
        assertTrue("重启后应仍是干净的空清单", second.snapshot.todos.none { !it.deleted })
        assertTrue("项目也不该回来", second.snapshot.projects.isEmpty())
    }

    @Test
    fun `清空本地数据与清除演示数据只差播种标记`() {
        val cleared = InMemoryStorage()
        engineOn(cleared).let {
            it.seedDemoData(force = false)
            it.clearAll()
        }
        val demoCleared = InMemoryStorage()
        engineOn(demoCleared).let {
            it.seedDemoData(force = false)
            it.clearDemoData()
        }

        assertNull("清空本地数据：标记一起清掉（下次启动回到全新安装态）", cleared.kvGet(seedMarkKey))
        assertEquals("清除演示数据：内容一样清空，但标记留下", seedMarkValue, demoCleared.kvGet(seedMarkKey))
    }

    @Test
    fun `清除演示数据后仍可显式找回示例数据`() {
        val storage = InMemoryStorage()
        val engine = engineOn(storage)
        engine.seedDemoData(force = false)
        engine.clearDemoData()

        assertFalse("重启不会再自动播种", engineOn(storage).seedDemoData(force = false))
        assertTrue("「重置为示例数据」仍能显式找回", engine.seedDemoData(force = true))
        assertTrue("找回后应有内容", engine.snapshot.todos.isNotEmpty())
        assertEquals("找回后标记仍在", seedMarkValue, storage.kvGet(seedMarkKey))
    }

    /* ------------------------- ③ App 侧接线（源码级） ------------------------- */

    @Test
    fun `启动播种判据交给引擎而不是数据库文件是否存在`() {
        val code = TestSource.readCode("java/com/ordo/android/di/ServiceLocator.kt")
        assertTrue("启动必须走引擎的播种判定", code.contains("seedDemoData(force = false)"))
        assertTrue("启动要开启播种判定", code.contains("bindDataDir(dirId, seedIfEmpty = true)"))
        assertFalse(
            "不得再拿数据库文件存在性当判据（清空后文件还在）",
            code.contains("dbFileFor(appContext.filesDir, dirId).exists()"),
        )
        assertFalse("不得再自己判空快照", code.contains("loadSnapshot() == null"))
    }

    @Test
    fun `设置页挂了清空本地数据且先确认再执行`() {
        val screen = TestSource.readCode("java/com/ordo/android/ui/settings/SettingsScreen.kt")
        assertTrue("设置页应有「清空本地数据」按钮", screen.contains("R.string.settings_clear"))
        assertTrue("点击应走 ViewModel", screen.contains("vm.clearAllData()"))
        assertTrue("破坏性操作要先两步确认", screen.contains("ConfirmStrip"))

        val strings = TestSource.read("res/values/strings.xml")
        assertTrue("按钮文案", strings.contains("settings_clear"))
        assertTrue("确认文案要点明「下次启动回到全新安装状态」", strings.contains("settings_clear_confirm"))
        assertTrue("清空后要有提示条文案", strings.contains("toast_cleared"))

        val vm = TestSource.readCode("java/com/ordo/android/vm/OrdoViewModel.kt")
        assertTrue("清空应调核心 clearAll", vm.contains("engine.clearAll()"))
        assertTrue("清空后应提示", vm.contains("R.string.toast_cleared"))
    }

    @Test
    fun `设置页挂了清除演示数据且先确认再执行`() {
        val screen = TestSource.readCode("java/com/ordo/android/ui/settings/SettingsScreen.kt")
        assertTrue("设置页应有「清除演示数据」按钮", screen.contains("R.string.settings_clear_demo"))
        assertTrue("点击应走 ViewModel", screen.contains("vm.clearDemoData()"))
        assertTrue("破坏性操作要先两步确认", screen.contains("confirmClearDemo"))

        val strings = TestSource.read("res/values/strings.xml")
        assertTrue("按钮文案", strings.contains("settings_clear_demo"))
        assertTrue("确认文案要点明「重启不会再出现演示数据」", strings.contains("settings_clear_demo_confirm"))
        assertTrue("确认文案要给出找回路径", strings.contains("重置为示例数据"))
        assertTrue("清除后要有提示条文案", strings.contains("toast_demo_cleared"))

        val vm = TestSource.readCode("java/com/ordo/android/vm/OrdoViewModel.kt")
        assertTrue("清除演示数据应调核心 clearDemoData", vm.contains("engine.clearDemoData()"))
        assertTrue("清除后应提示", vm.contains("R.string.toast_demo_cleared"))
    }

    @Test
    fun `清空只删库里的数据不动工作区目录`() {
        // 与 Windows 端一致：清空 ≠ 卸载。/data/data/<pkg>/files/<工作区 id>/ordo.db 与 id 都保留，
        // 下次启动仍在同一工作区（纯本地应用，清空只影响本机这一份）。
        val code = TestSource.readCode("java/com/ordo/android/vm/OrdoViewModel.kt")
        assertTrue("清空走的是核心的 clearAll", code.contains("engine.clearAll()"))
        assertFalse("清空不得删目录/搬目录", code.contains("deleteRecursively("))
        assertFalse("清空不得改绑定", code.contains("unbindDataDir()"))
    }
}
