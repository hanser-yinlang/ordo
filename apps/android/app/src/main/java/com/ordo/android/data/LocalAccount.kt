package com.ordo.android.data

/* ============================================================================
 * 本机数据目录标识（契约 §7.6.6）
 *
 * **本地数据目录标识 = 本机稳定标识，不依赖任何服务端身份**：
 *   ① 首次运行生成并持久化（`local-<16hex>`），此后**永不改变**；
 *   ② 不做数据迁移：升级前已在用的目录继续沿用（磁盘上只有一个既有工作区目录就用它）；
 *   ③ v1.4 起云同步与登录都已删除，因此这里只剩"钉住本机目录"这一件事。
 *
 * 为什么保留"钉住"：目录一旦随外部状态漂移，用户就会看到自己的待办"消失"
 * （旧目录还在磁盘上，界面读的却是新目录）。
 * ========================================================================== */

object LocalAccount {

    /** 引导库 kv 键：钉住的本机数据目录 id（跨会话稳定） */
    const val KEY_LOCAL_ACCOUNT_ID = "ordo.localAccountId"

    /** 本机 id 前缀（与既有的服务端 userId 目录一眼可分，且不会与 uuid 撞名） */
    const val PREFIX = "local-"

    /** 随机段长度（16 位十六进制，与 Windows `resolveDataDirId` 同形态） */
    const val ID_LENGTH = 16

    /**
     * 生成新的本机 id。
     *
     * @param randomHex 随机十六进制串（由调用方提供，便于单测固定；非十六进制字符会被丢弃）
     */
    fun newId(randomHex: String): String {
        val cleaned = randomHex.lowercase()
            .filter { it in '0'..'9' || it in 'a'..'f' }
            .take(ID_LENGTH)
        // 极端情况下随机串被过滤空：右侧补 '0'，绝不让目录名退化成 "local-"
        return PREFIX + cleaned.padEnd(ID_LENGTH, '0')
    }

    /**
     * 解析本机数据目录 id（契约 §7.6.6）。优先级：
     *   ① [pinned]：已经钉在 kv 里的值 —— **永远优先，永不改变**；
     *   ② [existingDirIds] 里**唯一**的一个既有工作区目录 —— 升级时"继续沿用旧目录，不做迁移"；
     *   ③ 返回 null：调用方用 [newId] 生成一个并持久化（真正的首次运行）。
     *
     * 多于一个既有目录时**不猜**（宁可新建空目录，也不把别人的数据当自己的展示）。
     */
    fun resolve(pinned: String?, existingDirIds: List<String>): String? {
        pinned?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
        return existingDirIds.filter { it.isNotBlank() }.distinct().singleOrNull()
    }
}
