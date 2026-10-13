package com.ordo.desktop.system

import com.ordo.core.model.Status
import com.ordo.core.store.OrdoEngine
import com.ordo.core.util.OrdoDate
import com.ordo.core.util.OrdoJson
import com.ordo.core.storage.OrdoStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import java.awt.Color
import java.awt.Font
import java.awt.Graphics2D
import java.awt.MenuItem
import java.awt.PopupMenu
import java.awt.RenderingHints
import java.awt.SystemTray
import java.awt.Toolkit
import java.awt.TrayIcon
import java.awt.event.ActionListener
import java.awt.geom.Ellipse2D
import java.awt.image.BufferedImage

/**
 * 托盘右键菜单的文案与字体选择(纯逻辑,便于单测;不碰 AWT)。
 *
 * **踩过的坑(用户实测截图)**:`java.awt.PopupMenu` 的菜单项用的是 **JVM 的默认 AWT 字体**,
 * 在这台机器上它**显示不了中文** —— 菜单里「打开 Ordo」「退出」全渲染成两个空心方框(豆腐块),
 * 而应用内 Compose 的中文完全正常(两套字体栈各管各的)。
 *
 * 规则:
 * 1. 优先选一个**确实能显示中文**的字体(候选表按 Windows 常见中文字体排序);
 * 2. 一个都选不出来时,**菜单文案退回英文** —— 宁可是英文,也不能给用户看豆腐块。
 */
object TrayMenuSpec {

    /** 候选字体(按"Windows 上最可能存在且字形好看"排序) */
    val CJK_FONT_CANDIDATES: List<String> = listOf(
        "Microsoft YaHei UI",
        "Microsoft YaHei",
        "Microsoft JhengHei UI",
        "SimSun",
        "SimHei",
        "Noto Sans CJK SC",
        "Source Han Sans SC",
        "PingFang SC"
    )

    /** 用哪个字号(与系统菜单接近) */
    const val FONT_SIZE = 12

    /** 中文标签(能显示中文时用) */
    val LABELS_ZH: List<String> = listOf("打开 Ordo", "退出")

    /** 英文兜底标签(选不出中文字体时用) */
    val LABELS_EN: List<String> = listOf("Open Ordo", "Quit")

    /**
     * 从"系统里真实可用的字体族"里挑一个能显示中文的。
     * @param available 系统可用字体族(来自 [java.awt.GraphicsEnvironment],由调用方注入,便于单测)
     * @param canDisplay 该字体族能否显示中文探测字符(AWT 的 `Font(family, PLAIN, 12).canDisplay('打')`)
     */
    fun pickFontFamily(
        available: Set<String>,
        canDisplay: (String) -> Boolean
    ): String? {
        CJK_FONT_CANDIDATES.firstOrNull { it in available && canDisplay(it) }?.let { return it }
        // 候选表里没有:退一步,在系统字体里随便找一个**真能显示中文**的(宁可字形一般,也不能是豆腐块)
        return available.sorted().firstOrNull { canDisplay(it) }
    }

    /** 菜单文案:选得出中文字体就用中文,否则英文 */
    fun labels(cjkFontFamily: String?): List<String> = if (cjkFontFamily != null) LABELS_ZH else LABELS_EN
}

/**
 * 托盘图标 + 到点提醒的系统通知(04-UI规范 §7:系统通知(托盘 + Toast))。
 *
 * - 托盘双击:打开主窗口;右键菜单:打开 Ordo / 退出(文案与字体见 [TrayMenuSpec])。
 * - 提醒到点:调用 [TrayIcon.displayMessage] 弹出系统气泡;双击托盘会跳到最近一次提醒的待办。
 * - 托盘不可用时(极端情况)自动降级为静默,不影响主流程。
 */
class TrayNotifications(
    private val onOpenWindow: () -> Unit,
    private val onQuit: () -> Unit,
    private val onOpenTodo: (String) -> Unit
) {

    private var trayIcon: TrayIcon? = null

    @Volatile
    private var lastNotifiedTodoId: String? = null

    val available: Boolean get() = trayIcon != null

    fun install() {
        if (trayIcon != null) return
        if (!SystemTray.isSupported()) return
        runCatching {
            val image = renderIcon(32)
            val icon = TrayIcon(image, "Ordo(序)")
            icon.isImageAutoSize = true
            icon.addActionListener(
                ActionListener {
                    val todoId = lastNotifiedTodoId
                    if (todoId != null) onOpenTodo(todoId) else onOpenWindow()
                    lastNotifiedTodoId = null
                }
            )
            val menu = PopupMenu()
            // ⚠ 必须显式设字体:AWT 默认字体不保证能显示中文,否则菜单项会渲染成豆腐块(用户实测就是 □□)
            val cjkFamily = runCatching {
                val available = java.awt.GraphicsEnvironment.getLocalGraphicsEnvironment()
                    .availableFontFamilyNames.toSet()
                TrayMenuSpec.pickFontFamily(available) { family ->
                    Font(family, Font.PLAIN, TrayMenuSpec.FONT_SIZE).canDisplay('打')
                }
            }.getOrNull()
            val menuFont = Font(cjkFamily ?: Font.DIALOG, Font.PLAIN, TrayMenuSpec.FONT_SIZE)
            val labels = TrayMenuSpec.labels(cjkFamily)
            menu.add(MenuItem(labels[0]).apply {
                font = menuFont
                addActionListener { onOpenWindow() }
            })
            menu.addSeparator()
            menu.add(MenuItem(labels[1]).apply {
                font = menuFont
                addActionListener { onQuit() }
            })
            icon.popupMenu = menu
            SystemTray.getSystemTray().add(icon)
            trayIcon = icon
        }
    }

    fun remove() {
        val icon = trayIcon ?: return
        runCatching { SystemTray.getSystemTray().remove(icon) }
        trayIcon = null
    }

    /** 弹一条系统通知;点击(双击托盘)会跳到对应待办 */
    fun notify(todoId: String?, title: String, body: String) {
        lastNotifiedTodoId = todoId
        val icon = trayIcon
        if (icon != null) {
            runCatching { icon.displayMessage(title, body, TrayIcon.MessageType.INFO) }
        }
    }

    /** 托盘图标:靛紫圆环 + 向内短划线(品牌 Logo 概念,04-UI规范 §1) */
    private fun renderIcon(size: Int): BufferedImage {
        val image = BufferedImage(size, size, BufferedImage.TYPE_INT_ARGB)
        val g: Graphics2D = image.createGraphics()
        try {
            g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON)
            g.color = Color(0x5B, 0x5B, 0xD6)
            g.fill(Ellipse2D.Float(0f, 0f, size.toFloat(), size.toFloat()))
            g.color = Color.WHITE
            g.stroke = java.awt.BasicStroke(size * 0.11f, java.awt.BasicStroke.CAP_ROUND, java.awt.BasicStroke.JOIN_ROUND)
            val inset = size * 0.28f
            // 开口圆环:留出右上角缺口
            g.drawArc(
                inset.toInt(), inset.toInt(),
                (size - inset * 2).toInt(), (size - inset * 2).toInt(),
                55, 285
            )
            // 向内的短划线
            g.drawLine(
                (size * 0.5f).toInt(), (size * 0.5f).toInt(),
                (size * 0.68f).toInt(), (size * 0.5f).toInt()
            )
        } finally {
            g.dispose()
        }
        return image
    }
}

/**
 * 到点提醒扫描器。
 *
 * 每 [intervalMillis] 扫一次本地快照:凡是 `reminder <= 现在` 且未推送过的开放待办,弹一条系统通知。
 * 同一提醒只投递一次(契约 §7.5 `fired` 语义),记录持久化在 kv 里,重启不会重复打扰。
 */
class ReminderScheduler(
    private val engine: OrdoEngine,
    private val storage: OrdoStorage,
    private val notifier: (todoId: String, title: String, at: String) -> Unit,
    private val scope: CoroutineScope,
    private val intervalMillis: Long = 20_000L
) {

    private val fired: MutableSet<String> = loadFired()

    fun start(): Job = scope.launch {
        while (isActive) {
            runCatching { scan() }
            delay(intervalMillis)
        }
    }

    /** 立即扫描一次;返回本次新触发的数量 */
    fun scan(): Int {
        val now = OrdoDate.nowLocalDateTime()
        var count = 0
        engine.snapshot.todos
            .filter { !it.deleted && it.status == Status.OPEN }
            .forEach { todo ->
                val reminder = todo.reminder ?: return@forEach
                if (reminder > now) return@forEach
                val key = todo.id + "@" + reminder
                if (!fired.add(key)) return@forEach
                notifier(todo.id, todo.title, reminder)
                count++
            }
        if (count > 0) persistFired()
        return count
    }

    private fun loadFired(): MutableSet<String> {
        val raw = storage.kvGet(KEY_FIRED) ?: return mutableSetOf()
        return runCatching {
            OrdoJson.instance.decodeFromString(ListSerializer(String.serializer()), raw).toMutableSet()
        }.getOrElse { mutableSetOf() }
    }

    private fun persistFired() {
        // 只保留最近 500 条,避免无限增长
        val trimmed = fired.toList().takeLast(500).toMutableSet()
        fired.clear()
        fired.addAll(trimmed)
        storage.kvSet(KEY_FIRED, OrdoJson.instance.encodeToString(ListSerializer(String.serializer()), trimmed.toList()))
    }

    companion object {
        const val KEY_FIRED = "ordo.reminder.fired"

        /** 托盘不可用时的兜底:仅打印,不阻塞主流程 */
        fun silentNotifier(): (String, String, String) -> Unit = { todoId, title, at ->
            println("[Ordo 提醒] $at  $title  ($todoId)")
        }

        fun toolkitAvailable(): Boolean = runCatching { !java.awt.GraphicsEnvironment.isHeadless() && Toolkit.getDefaultToolkit() != null }
            .getOrDefault(false)
    }
}

/** 供设置页展示的字体信息(避免误引入外部字体) */
internal fun defaultUiFontName(): String = Font.SANS_SERIF
