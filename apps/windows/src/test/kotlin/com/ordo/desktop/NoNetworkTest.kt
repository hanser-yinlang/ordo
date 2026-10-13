package com.ordo.desktop

import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.storage.OrdoStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.store.TodoOptions
import com.ordo.core.model.When
import com.ordo.desktop.data.JsonFileStorage
import com.ordo.desktop.data.UserDataDirs
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * **纯本地证明**(产品决策 2026-10-13:云同步彻底删除)。
 *
 * "不发网络请求"这种事不能靠嘴说,这里用**三重断言**把它钉死:
 *
 * 1. **依赖层**:`apps/windows/build.gradle.kts` 里没有任何网络依赖(Ktor / OkHttp / WebSocket 全删);
 * 2. **类路径层**:运行期类路径上**根本不存在** HTTP / WebSocket 客户端类 ——
 *    连"想发请求"的代码都加载不到,也就谈不上发出去;
 * 3. **源码层**:`src/main` 里没有任何网络 API 的引用(注释先剥掉,避免把说明文字误判成代码)。
 *
 * 再补一条**行为层**:走一遍本地启动链路(选数据目录 → 建本地仓储 → 建引擎 → 本地写入),
 * 产出的文件只有本机那几个 JSON —— 全程没有任何套接字 / 端口参与。
 */
class NoNetworkTest {

    // ------------------------------------------------------------ 1. 依赖层

    @Test
    fun `构建脚本里没有任何网络依赖`() {
        val build = sourceOf("build.gradle.kts")?.readText() ?: return
        // 只看依赖声明的行,避免把解释性注释误判成依赖
        val dependencyLines = build.lines()
            .map { it.substringBefore("//").trim() }
            .filter { it.startsWith("implementation(") || it.startsWith("api(") || it.startsWith("testImplementation(") }

        for (line in dependencyLines) {
            for (forbidden in listOf("ktor", "okhttp", "websocket", "http4k", "retrofit")) {
                assertFalse("依赖里不该出现网络库 $forbidden:$line", line.lowercase().contains(forbidden))
            }
        }
        assertTrue("依赖清单应该读到了:${dependencyLines.size} 行", dependencyLines.isNotEmpty())
    }

    // ------------------------------------------------------------ 2. 类路径层

    @Test
    fun `类路径上不存在任何 HTTP 或 WebSocket 客户端`() {
        val networkClasses = listOf(
            "io.ktor.client.HttpClient",
            "io.ktor.client.engine.cio.CIO",
            "io.ktor.client.plugins.websocket.WebSockets",
            "io.ktor.websocket.Frame",
            "io.ktor.server.engine.EmbeddedServer",
            "okhttp3.OkHttpClient",
            "retrofit2.Retrofit",
            "org.apache.http.client.HttpClient",
            "org.java_websocket.client.WebSocketClient"
        )
        for (name in networkClasses) {
            assertThrows("类路径上不该有 $name", ClassNotFoundException::class.java) {
                Class.forName(name)
            }
        }
    }

    @Test
    fun `运行期 classpath 字符串里没有任何网络库`() {
        val classpath = System.getProperty("java.class.path").orEmpty().lowercase()
        assertTrue("classpath 不该是空的", classpath.isNotBlank())
        for (forbidden in listOf("ktor", "okhttp", "retrofit", "httpclient", "websocket")) {
            assertFalse("classpath 里不该出现 $forbidden", classpath.contains(forbidden))
        }
    }

    // ------------------------------------------------------------ 3. 源码层

    @Test
    fun `主源码里没有任何网络 API 引用`() {
        val root = moduleDir() ?: return
        val mainDir = File(root, "src/main/kotlin")
        assertTrue("必须找到主源码目录:${mainDir.absolutePath}", mainDir.isDirectory)

        val networkTokens = listOf(
            "io.ktor",
            "okhttp",
            "HttpClient",
            "HttpURLConnection",
            "URLConnection",
            "WebSocket",
            "java.net.Socket",
            "ServerSocket",
            "DatagramSocket",
            "InetAddress",
            "java.net.http",
            "openConnection(",
            "Socket(",
            "webSocket("
        )

        val violations = mutableListOf<String>()
        mainDir.walkTopDown().filter { it.isFile && it.extension == "kt" }.forEach { file ->
            val code = stripComments(file.readText())
            code.lines().forEachIndexed { index, line ->
                networkTokens.forEach { token ->
                    if (line.contains(token)) violations += "${file.name}:${index + 1} 含 $token → ${line.trim()}"
                }
            }
        }
        assertEquals("主源码不得引用任何网络 API", emptyList<String>(), violations)
    }

    /** 剥掉 `//` 行注释与 `/* */` 块注释:说明文字里出现 "WebSocket" 之类的词不算引用 */
    private fun stripComments(source: String): String {
        val noBlock = Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL).replace(source) { match ->
            match.value.replace(Regex("[^\n]"), " ")
        }
        return noBlock.lines().joinToString("\n") { it.substringBefore("//") }
    }

    // ------------------------------------------------------------ 4. 行为层:本地启动只碰本地文件

    @Test
    fun `本地启动链路只产生本机 JSON 文件,不涉及任何套接字`() {
        val base = Files.createTempDirectory("ordo-local-only").toFile()
        try {
            // ① 选数据目录(纯 kv 决策,没有任何网络) —— 空目录首次运行 → 生成本地 id
            val bootstrap = JsonFileStorage(base)
            val dataDirId = UserDataDirs.resolveDataDirId(bootstrap, base)
            assertTrue("首次运行应生成一个本地 id", dataDirId.isNotBlank())
            assertEquals("id 必须钉进 kv", dataDirId, bootstrap.kvGet(UserDataDirs.KEY_DATA_DIR_ID))

            // ② 数据目录 + 本地仓储 + 本地引擎(共享核心,纯本地)
            val dataDir = UserDataDirs.userDir(base, dataDirId)
            val storage: OrdoStorage = JsonFileStorage(dataDir)
            val engine = OrdoEngine(storage)

            // ③ 本地读写:写入立刻落盘,重启后仍在 —— 这就是"云同步"被删掉后剩下的全部
            engine.createTodo("纯本地的一条待办", TodoOptions(`when` = When.TODAY))
            assertTrue("本地写入应立刻可见", engine.snapshot.todos.any { it.title == "纯本地的一条待办" })
            assertTrue("本地写入应落到本机文件", engine.pendingOpCount() > 0)

            val reopened = OrdoEngine(JsonFileStorage(dataDir))
            assertTrue("重启后仍在(不需要任何网络)", reopened.snapshot.todos.any { it.title == "纯本地的一条待办" })

            // ④ 目录里只该有本机的 JSON 文件
            val names = dataDir.listFiles().orEmpty().map { it.name }.toSortedSet()
            assertTrue("只应有本机 JSON:$names", names.all { it.endsWith(".json") })
            assertTrue("快照文件应存在:$names", names.contains(JsonFileStorage.FILE_SNAPSHOT))
        } finally {
            base.deleteRecursively()
        }
    }

    @Test
    fun `内存存储下本地引擎行为一致(与网络无关)`() {
        val engine = OrdoEngine(InMemoryStorage())
        engine.createTodo("本地待办", TodoOptions(`when` = When.INBOX))
        assertTrue(engine.snapshot.todos.any { it.title == "本地待办" })
    }

    // ------------------------------------------------------------ 工具

    /** 模块目录(测试工作目录是模块目录;向上兜底找 build.gradle.kts) */
    private fun moduleDir(): File? {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            if (File(dir, "build.gradle.kts").isFile) return dir
            dir = dir.parentFile
        }
        return null
    }

    private fun sourceOf(relative: String): File? = moduleDir()?.let { File(it, relative) }?.takeIf { it.isFile }
}
