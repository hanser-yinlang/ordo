package com.ordo.core.util

import kotlin.random.Random

/** ID 工具:实体用 UUID v4,Op 用 ULID(单调可排序,见契约 §7.2) */
object Ids {

    private const val CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    fun uuid(): String {
        val bytes = ByteArray(16)
        Random.nextBytes(bytes)
        bytes[6] = ((bytes[6].toInt() and 0x0F) or 0x40).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3F) or 0x80).toByte()
        val hex = StringBuilder(36)
        for (i in 0 until 16) {
            if (i == 4 || i == 6 || i == 8 || i == 10) hex.append('-')
            val v = bytes[i].toInt() and 0xFF
            hex.append(HEX[v ushr 4]).append(HEX[v and 0x0F])
        }
        return hex.toString()
    }

    private val HEX = "0123456789abcdef".toCharArray()

    /** ULID:48 位时间戳 + 80 位随机,26 字符 Crockford Base32 */
    fun ulid(nowMillis: Long = OrdoDate.nowMillis()): String {
        val time = nowMillis and 0xFFFFFFFFFFFFL
        val chars = CharArray(26)
        var t = time
        for (i in 9 downTo 0) {
            chars[i] = CROCKFORD[(t and 0x1F).toInt()]
            t = t ushr 5
        }
        for (i in 10 until 26) {
            chars[i] = CROCKFORD[Random.nextInt(32)]
        }
        return String(chars)
    }
}
