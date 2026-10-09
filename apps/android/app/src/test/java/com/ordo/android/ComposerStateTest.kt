package com.ordo.android

import com.ordo.android.vm.ComposerState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 实测缺陷「点右下角蓝色加号没有反应」的纯逻辑验收（状态机见 `vm/ComposerState.kt`）。
 *
 * 界面层可测的部分收敛在 [ComposerState] 里：
 *   ① 打开浮层后状态正确（open / target / draft / focusRequest）；
 *   ② 已打开时再点加号**不是空操作**：保留草稿、递增 focusRequest（界面据此重新聚焦+弹键盘）、不改落地目标；
 *   ③ 空标题提交/关闭只关闭浮层、丢弃草稿，**不产生空待办**；
 *   ④ 关闭后再打开是新的一轮（不残留上一轮草稿）。
 *
 * 断言纯粹基于值对象，不依赖 Android 框架（无需 Robolectric）。
 */
class ComposerStateTest {

    @Test
    fun `打开浮层后状态正确`() {
        val opened = ComposerState().opened("project/p1")

        assertTrue(opened.open)
        assertEquals("project/p1", opened.target)
        assertEquals("新开一轮必须是空草稿", "", opened.draft)
        assertEquals("打开即请求一次焦点", 1, opened.focusRequest)
    }

    @Test
    fun `已打开时再点加号不丢草稿 且重新请求焦点`() {
        val typing = ComposerState().opened(null).edited("明天 交季度报告 #重要")
        assertEquals(1, typing.focusRequest)

        val again = typing.opened("area/a9")

        assertTrue("再点加号必须保持打开", again.open)
        assertEquals("再点加号不得清空已输入内容", "明天 交季度报告 #重要", again.draft)
        assertEquals("再点加号必须重新请求焦点（focusRequest 递增）", 2, again.focusRequest)
        assertNull("再点加号不得改掉本轮待办的落地目标", again.target)
    }

    @Test
    fun `空标题提交只关闭浮层 不产生待办`() {
        val blank = ComposerState().opened(null).edited("   ")

        // Empty → ViewModel 只调用 closeComposer()，编译器保证这条路径上不存在 engine.createTodo
        assertEquals(ComposerState.Submission.Empty, blank.submission())

        val closed = blank.closed()
        assertFalse(closed.open)
        assertEquals("关闭后草稿被丢弃", "", closed.draft)
        assertNull("关闭后不再保留落地目标", closed.target)
    }

    @Test
    fun `有内容提交时给出已去首尾空白的标题`() {
        val verdict = ComposerState().opened(null).edited("  交季度报告  ").submission()

        assertEquals(ComposerState.Submission.Create("交季度报告"), verdict)
    }

    @Test
    fun `关闭再打开是新的一轮`() {
        val reopened = ComposerState().opened(null).edited("上一轮草稿").closed().opened(null)

        assertTrue(reopened.open)
        assertEquals("重新打开不得残留上一轮草稿", "", reopened.draft)
        assertEquals("焦点序号继续递增，保证界面一定重新聚焦", 2, reopened.focusRequest)
    }
}
