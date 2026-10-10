package com.ordo.desktop.data

import com.ordo.core.sync.OrdoSessionStore
import java.io.File

/**
 * 本地数据目录的**唯一**计算口径(契约 §7.6.3 硬约束)。
 *
 * ```
 * %APPDATA%\Ordo\<userId>\     ← 一个账号一个目录,绝不共用
 * ```
 *
 * - 目录名一律过 [OrdoSessionStore.userDataDirName] 清洗(服务端 uuid 直接可用,异常字符防御性替换);
 * - 退出登录只清 session,目录原样保留(下同);
 * - `--data-dir=<路径>` / `-Dordo.dataDir=` 只覆盖**基目录**(便携部署、自动化冒烟),
 *   账号子目录仍然照加 —— 隔离是硬约束,任何开关都不能把它关掉。
 */
object UserDataDirs {

    /** 基目录(与账号无关):`%APPDATA%\Ordo`,拿不到 APPDATA 时退回用户目录 */
    fun baseDir(): File = JsonFileStorage.defaultDir()

    /** 某个账号的数据目录:`<base>\<userId>` */
    fun userDir(base: File, userId: String): File = File(base, OrdoSessionStore.userDataDirName(userId))

    /**
     * 从命令行 / 系统属性解析基目录。
     *
     * 返回值永远是**基目录**,不是最终数据目录:调用方再用 [userDir] 拼上 userId。
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
