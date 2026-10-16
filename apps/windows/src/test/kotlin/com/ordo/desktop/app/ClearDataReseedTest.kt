package com.ordo.desktop.app

import com.ordo.core.store.OrdoEngine
import com.ordo.desktop.data.JsonFileStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

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
 *
 * 第二批需求(v1.8)在此基础上加了「清除演示数据」:内容同样清空,但**钉住播种标记** →
 * 清完重开不再出现演示数据,且只能靠「重置为示例数据」显式找回。本文件的用例把两个入口
 * (「清空本地数据」会补种 /「清除演示数据」不会补种)与它们的接线一起钉住。
 */
class ClearDataReseedTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun scope() = CoroutineScope(Dispatchers.Unconfined)

    /** 从测试工作目录往上找仓库根,再读 `apps/windows/<relativePath>`(与 OrdoMotionContractTest 同款) */
    private fun source(relativePath: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "apps/windows/$relativePath")
            if (candidate.isFile) return candidate.readText(Charsets.UTF_8)
            dir = dir.parentFile
        }
        error("找不到 apps/windows/$relativePath(工作目录 ${System.getProperty("user.dir")})")
    }

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

    @Test
    fun `清除演示数据后重启应用不会重新播种`() {
        val dir = tmp.newFolder("ordo")

        val storage1 = JsonFileStorage(dir)
        val session1 = OrdoViewModel(OrdoEngine(storage1), storage1, scope(), seedDemoData = true)
        assertTrue("首次启动就该有演示数据", session1.state.value.flatTodos.isNotEmpty())

        // 走真实接线:点按钮只弹确认,确认后才清库
        session1.requestClearDemoData()
        assertTrue("只点按钮不该已经清库", session1.state.value.flatTodos.isNotEmpty())
        session1.confirmDelete()
        assertTrue("确认后当前会话是空的", session1.state.value.flatTodos.isEmpty())
        session1.dispose()

        // 「重新打开应用」:新的引擎 + 新的第一个窗口
        val storage2 = JsonFileStorage(dir)
        val engine2 = OrdoEngine(storage2)
        val session2 = OrdoViewModel(engine2, storage2, scope(), seedDemoData = true)
        assertTrue(
            "清除演示数据后重启应用不该再出现演示数据(用户明确要求)",
            session2.state.value.flatTodos.isEmpty()
        )
        assertTrue("引擎快照也要是空的", engine2.snapshot.todos.isEmpty())
        session2.dispose()
    }

    @Test
    fun `托盘常驻时清除演示数据后再唤起不会播种`() {
        val dir = tmp.newFolder("ordo")
        val storage = JsonFileStorage(dir)
        val session = OrdoViewModel(OrdoEngine(storage), storage, scope(), seedDemoData = true)

        session.requestClearDemoData()
        session.confirmDelete()
        assertTrue("确认后当前会话是空的", session.state.value.flatTodos.isEmpty())

        session.onAppActivated()
        assertTrue("托盘唤回也不许把演示数据塞回来", session.state.value.flatTodos.isEmpty())
        session.dispose()
    }

    @Test
    fun `清空本地数据与清除演示数据的差别只在播种标记`() {
        // 两条路都从"全新安装 + 有演示数据"出发,都清空,都重启 —— 唯一变量是播种标记留不留。
        val cleared = tmp.newFolder("ordo-clear-all")
        val s1 = JsonFileStorage(cleared)
        val session1 = OrdoViewModel(OrdoEngine(s1), s1, scope(), seedDemoData = true)
        session1.requestClearAll()
        session1.confirmDelete()
        assertTrue("清空后当前会话是空的", session1.state.value.flatTodos.isEmpty())
        session1.dispose()
        val engine1 = OrdoEngine(JsonFileStorage(cleared))
        val restarted1 = OrdoViewModel(engine1, JsonFileStorage(cleared), scope(), seedDemoData = true)
        assertTrue("「清空本地数据」后重启应重新播种", engine1.snapshot.todos.isNotEmpty())
        restarted1.dispose()

        val demoCleared = tmp.newFolder("ordo-clear-demo")
        val s2 = JsonFileStorage(demoCleared)
        val session2 = OrdoViewModel(OrdoEngine(s2), s2, scope(), seedDemoData = true)
        session2.requestClearDemoData()
        session2.confirmDelete()
        assertTrue("清除后当前会话是空的", session2.state.value.flatTodos.isEmpty())
        session2.dispose()
        val engine2 = OrdoEngine(JsonFileStorage(demoCleared))
        val restarted2 = OrdoViewModel(engine2, JsonFileStorage(demoCleared), scope(), seedDemoData = true)
        assertTrue("「清除演示数据」后重启不该再播种", engine2.snapshot.todos.isEmpty())
        restarted2.dispose()
    }

    @Test
    fun `清除演示数据后仍可显式重置为示例数据`() {
        // "不再自动出现"不等于"永远找不回":设置页的「重置为示例数据」是显式入口
        val dir = tmp.newFolder("ordo")
        val storage = JsonFileStorage(dir)
        val session = OrdoViewModel(OrdoEngine(storage), storage, scope(), seedDemoData = true)

        session.clearDemoData()
        assertTrue("清除后应当是空的", session.state.value.flatTodos.isEmpty())

        session.resetDemoData()
        assertTrue("显式重置必须能把示例数据找回来", session.state.value.flatTodos.isNotEmpty())

        session.onAppActivated()
        assertTrue("重置之后,托盘唤回也不该把示例数据抹掉", session.state.value.flatTodos.isNotEmpty())
        session.dispose()
    }

    @Test
    fun `设置页的两个清空入口接在确认框与引擎上`() {
        // 源码级接线:设置页按钮 → 确认框(ConfirmKind)→ 引擎。界面行为由像素/手工验证,
        // 这里只钉"有没有接上",防止有人改了设置页却忘了把新入口连到 vm(v1.7 的 standard 残留同款教训)。
        val settings = source("src/main/kotlin/com/ordo/desktop/ui/settings/SettingsView.kt")
        assertTrue("设置页必须调用 requestClearAll()", settings.contains("vm.requestClearAll()"))
        assertTrue("设置页必须有「清除演示数据」入口", settings.contains("vm.requestClearDemoData()"))
        assertTrue("按钮文案要写清是「清除演示数据」", settings.contains("\"清除演示数据\""))

        val ui = source("src/main/kotlin/com/ordo/desktop/app/UiState.kt")
        assertTrue("确认种类要含 CLEAR_ALL", ui.contains("CLEAR_ALL"))
        assertTrue("确认种类要含 CLEAR_DEMO", ui.contains("CLEAR_DEMO"))
        assertTrue("清空类确认按钮不能沿用「删除」", ui.contains("\"确认清除\""))

        val vm = source("src/main/kotlin/com/ordo/desktop/app/OrdoViewModel.kt")
        assertTrue(
            "确认框确认后必须落到 clearDemoData()",
            vm.contains("ConfirmKind.CLEAR_DEMO -> clearDemoData()")
        )
        assertTrue(
            "确认框确认后必须落到 clearAllData()",
            vm.contains("ConfirmKind.CLEAR_ALL -> clearAllData()")
        )
        assertTrue("引擎的 clearDemoData 必须被调用", vm.contains("engine.clearDemoData()"))

        val shell = source("src/main/kotlin/com/ordo/desktop/ui/shell/OrdoApp.kt")
        assertTrue("确认框要带上按类型区分的按钮文案", shell.contains("confirmText = request.confirmText"))
    }
}
