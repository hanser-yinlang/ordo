package com.ordo.desktop.system

import com.ordo.desktop.app.OrdoRoute

/**
 * `ordo://` 深链解析(04-UI规范 §7:Windows 走协议注册)。
 *
 * 支持:
 * - `ordo://today` / `ordo://inbox` … 固定清单
 * - `ordo://project/<id>`、`ordo://area/<id>`、`ordo://tag/<名称>`
 * - `ordo://todo/<id>` —— 定位到某条待办并展开详情
 * - `ordo://search?q=关键词`
 *
 * 说明:jpackage 生成的 MSI 不注册自定义协议,注册需安装后手工写入注册表(见 README「已知限制」);
 * 这里实现的是**解析**与**命令行参数**入口,进程被拉起时即可生效。
 */
object DeepLink {

    data class Target(val route: OrdoRoute, val todoId: String? = null)

    private const val SCHEME = "ordo://"

    /** 从命令行参数里挑出第一个 `ordo://` 链接 */
    fun fromArgs(args: Array<String>): Target? = args.firstNotNullOfOrNull { parse(it) }

    fun parse(raw: String?): Target? {
        val value = raw?.trim() ?: return null
        if (!value.startsWith(SCHEME, ignoreCase = true)) return null
        val rest = value.substring(SCHEME.length)
        val path = rest.substringBefore('?')
        val query = rest.substringAfter('?', "")
        val segments = path.split('/').filter { it.isNotBlank() }
        if (segments.isEmpty()) return Target(OrdoRoute.Today)

        return when (segments[0].lowercase()) {
            "todo" -> {
                val id = segments.getOrNull(1) ?: return null
                Target(OrdoRoute.Today, id)
            }
            "project" -> segments.getOrNull(1)?.let { Target(OrdoRoute.Project(it)) }
            "area" -> segments.getOrNull(1)?.let { Target(OrdoRoute.Area(it)) }
            "tag" -> segments.getOrNull(1)?.let { Target(OrdoRoute.Tag(decode(it))) }
            "search" -> {
                val q = queryParam(query, "q")
                if (q.isNullOrBlank()) Target(OrdoRoute.Search("")) else Target(OrdoRoute.Search(q))
            }
            else -> Target(OrdoRoute.fromKey(segments.joinToString("/")))
        }
    }

    private fun queryParam(query: String, key: String): String? =
        query.split('&')
            .map { it.split('=', limit = 2) }
            .firstOrNull { it.size == 2 && it[0] == key }
            ?.let { decode(it[1]) }

    private fun decode(value: String): String =
        runCatching { java.net.URLDecoder.decode(value, "UTF-8") }.getOrDefault(value)
}
