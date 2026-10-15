package com.ordo.desktop.app

import com.ordo.core.store.OrdoEngine
import com.ordo.desktop.data.JsonFileStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * 「清空本地数据 → 重启应用 → 应重新播种演示数据」的回归用例(三个入口各一条)。
 *
 * 用户反馈:设置里点「清空本地数据」后重启应用,界面是空的,只有再点一次「重置为示例数据」
 * 才看得到演示数据 —— 即清空数据没有把应用退回「全新安装」的状态。
 *
 * 三条路必须都对:
 * 1. **真重启**:进程退出后重新打开(新引擎 + 新窗口);
 * 2. **托盘常驻**:Windows 默认「关闭窗口 = 最小化到托盘」,进程没死,关窗再打开走的是
 *    `Main.kt` 的 `showOrOpenWindow()` → [OrdoViewModel.onAppActivated](用户口径里这也是"重启应用");
 * 3. **反例**:用户自己把待办逐条删光(不是"清空本地数据")—— 下次唤起**不能**给他塞回演示数据。
 */
class ClearDataReseedTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun scope() = CoroutineScope(Dispatchers.Unconfined)

    @Test
    fun `清空本地数据后重启应用会重新播种演示数据`() {
        val dir = tmp.newFolder("ordo")

        // 本次进程的第一个窗口负责播种(与 Main.kt 的 isFirst 一致)
        val storage1 = JsonFileStorage(dir)
        val session1 = OrdoViewModel(OrdoEngine(storage1), storage1, scope(), seedDemoData = true)
        assertTrue("首次启动就该有演示数据", session1.state.value.flatTodos.isNotEmpty())

        // 用户在设置里点「清空本地数据」
        session1.clearAllData()
        assertTrue("清空后当前会话是空的", session1.state.value.flatTodos.isEmpty())
        session1.dispose()

        // 重启应用:新的引擎 + 新的第一个窗口
        val storage2 = JsonFileStorage(dir)
        val engine2 = OrdoEngine(storage2)
        val session2 = OrdoViewModel(engine2, storage2, scope(), seedDemoData = true)
        assertTrue(
            "清空本地数据后重启应用应重新播种演示数据,而不是让用户去点「重置为示例数据」",
            engine2.snapshot.todos.isNotEmpty()
        )
        session2.dispose()
    }

    @Test
    fun `托盘常驻时清空数据后再唤起会补种演示数据`() {
        // 用户的真实路径:Windows 默认「关闭窗口 = 最小化到托盘」,进程还活着。
        // 关窗再打开不会重建 ViewModel,播种判定必须由 onAppActivated() 补上。
        val dir = tmp.newFolder("ordo")
        val storage = JsonFileStorage(dir)
        val session = OrdoViewModel(OrdoEngine(storage), storage, scope(), seedDemoData = true)
        session.clearAllData()
        assertTrue("清空后当前会话是空的", session.state.value.flatTodos.isEmpty())

        session.onAppActivated()
        assertTrue(
            "从托盘重新唤起时必须补种演示数据(用户口径里这就是「重启应用」)",
            session.state.value.flatTodos.isNotEmpty()
        )
        session.dispose()
    }

    @Test
    fun `用户自己删空待办后再唤起不会复活演示数据`() {
        // 反例:用户是"清理完了",不是"刚装好" —— 播种标记还在,就不许复活
        val dir = tmp.newFolder("ordo")
        val storage = JsonFileStorage(dir)
        val session = OrdoViewModel(OrdoEngine(storage), storage, scope(), seedDemoData = true)
        session.state.value.flatTodos.map { it.id }.forEach { session.deleteTodo(it) }
        assertTrue("用户自己删空后应当是空的", session.state.value.flatTodos.isEmpty())

        session.onAppActivated()
        assertTrue("用户自己删空的数据不能被演示数据复活", session.state.value.flatTodos.isEmpty())
        session.dispose()
    }
}
