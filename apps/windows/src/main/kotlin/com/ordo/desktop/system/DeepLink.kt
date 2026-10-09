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
 * 两个入口:
 * ① 命令行参数 —— 协议注册([ProtocolRegistrar])后由 Windows 拉起进程时传入;
 * ② 跨进程转交 —— 已有实例在跑时,第二个进程把链接写进 [DeepLinkInbox],由运行中的实例消费。
 */
object DeepLink {

    data class Target(val route: OrdoRoute, val todoId: String? = null)

    private const val SCHEME = "ordo://"

    /** 从命令行参数里挑出第一个 `ordo://` 链接;解析失败一律当作"没有深链",绝不抛异常 */
    fun fromArgs(args: Array<String>): Target? = args.firstNotNullOfOrNull { safeParse(it) }

    /** 解析单个链接:任何异常都退化为 null(外部传来的字符串不可信) */
    fun safeParse(raw: String?): Target? = runCatching { parse(raw) }.getOrNull()

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
