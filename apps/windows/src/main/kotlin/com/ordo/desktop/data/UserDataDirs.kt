package com.ordo.desktop.data

import com.ordo.core.storage.OrdoStorage
import com.ordo.core.sync.OrdoSessionStore
import java.io.File
import java.util.UUID

/**
 * 本地数据目录的**唯一**计算口径(契约 §7.6.3 硬约束)。
 *
 * ```
 * %APPDATA%\Ordo\<数据目录 id>\     ← 一个数据目录 id 一个目录,绝不共用
 * ```
 *
 * - 目录名一律过 [OrdoSessionStore.userDataDirName] 清洗(服务端 uuid 直接可用,异常字符防御性替换);
 * - `--data-dir=<路径>` / `-Dordo.dataDir=` 只覆盖**基目录**(便携部署、自动化冒烟),
 *   数据目录 id 子目录仍然照加 —— 隔离是硬约束,任何开关都不能把它关掉。
 *
 * **数据目录 id 是"钉住"的**(见 [resolveDataDirId]):不再需要登录之后,首次启动可能还没有会话,
 * 这时就必须先定下一个目录名;若等会话到手再改名,用户刚写的数据就会"看起来消失"。
 */
object UserDataDirs {

    /** 基目录(与账号无关):`%APPDATA%\Ordo`,拿不到 APPDATA 时退回用户目录 */
    fun baseDir(): File = JsonFileStorage.defaultDir()

    /** 某个数据目录 id 的目录:`<base>\<id>` */
    fun userDir(base: File, userId: String): File = File(base, OrdoSessionStore.userDataDirName(userId))

    /** 数据目录 id 的 kv 键(钉住之后永不改写) */
    const val KEY_DATA_DIR_ID = "ordo.dataDirId"

    /**
     * 解析(必要时**钉住**)数据目录 id。规则按优先级如下(契约 §7.6.6:本机稳定标识,不跟服务端走):
     *
     * 1. kv 里已经钉过 → 原样用(**永不变**) —— 会话重建、401、退出登录都不影响它;
     * 2. 没钉过但有会话 → 用该会话的 `userId` 并钉住 —— **老用户升级时目录名与历史行为完全一致,
     *    因此不需要迁移**(v1.3 的目录就叫 `<userId>`);这只是"首次取值",之后同样冻结;
     * 3. 没钉过也没有会话:
     *    a. 基目录下**恰好一个**看起来是本端写过的数据目录(含 `kv.json` / `snapshot.json`)→ 沿用它的名字
     *       —— 覆盖"v1.3 里退出过登录(会话已清)但数据还在"的机器;
     *    b. 否则生成一个本地匿名 id 并钉住(全新安装)。
     *
     * 第 3a 步只在候选**唯一**时才认:多个历史目录时无法判断哪个属于当前用户,宁可新建也不猜。
     *
     * @param baseDir 基目录(`%APPDATA%\Ordo`);为 null 时跳过第 3a 步(只关心"钉住 / 生成"的调用方)
     */
    fun resolveDataDirId(
        storage: OrdoStorage,
        sessionUserId: String?,
        baseDir: File? = null,
        generate: () -> String = { "local-" + UUID.randomUUID().toString().replace("-", "").take(16) }
    ): String {
        storage.kvGet(KEY_DATA_DIR_ID)?.takeIf { it.isNotBlank() }?.let { return it }
        val id = sessionUserId?.takeIf { it.isNotBlank() }
            ?: baseDir?.let { existingDataDirName(it) }
            ?: generate()
        storage.kvSet(KEY_DATA_DIR_ID, id)
        return id
    }

    /**
     * 基目录下**唯一**一个本端写过的数据目录名(升级前用过、会话却已不在的机器)。
     *
     * 判据:是目录、不是隐藏目录(`.ordo.inbox` / `.ordo.lock` 之类),且里面有
     * [JsonFileStorage.FILE_KV] 或 [JsonFileStorage.FILE_SNAPSHOT]。候选不唯一时返回 null(不猜)。
     */
    fun existingDataDirName(baseDir: File): String? {
        val candidates = runCatching {
            baseDir.listFiles().orEmpty()
                .filter { it.isDirectory && !it.name.startsWith(".") }
                .filter { dir ->
                    File(dir, JsonFileStorage.FILE_KV).isFile || File(dir, JsonFileStorage.FILE_SNAPSHOT).isFile
                }
        }.getOrDefault(emptyList())
        return candidates.singleOrNull()?.name
    }

    /**
     * 从命令行 / 系统属性解析基目录。
     *
     * 返回值永远是**基目录**,不是最终数据目录:调用方再用 [userDir] 拼上数据目录 id。
     */
    fun resolveBase(args: Array<String>, property: String? = System.getProperty("ordo.dataDir")): File {
        args.firstOrNull { it.startsWith(DATA_DIR_FLAG) }
            ?.removePrefix(DATA_DIR_FLAG)
            ?.takeIf { it.isNotBlank() }
            ?.let { return File(it) }
        property?.takeIf { it.isNotBlank() }?.let { return File(it) }
        return baseDir()
    }

    /** `--data-dir=<路径>` */
    const val DATA_DIR_FLAG = "--data-dir="
}
