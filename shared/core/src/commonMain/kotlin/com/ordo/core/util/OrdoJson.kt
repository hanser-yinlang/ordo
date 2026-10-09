package com.ordo.core.util

import kotlinx.serialization.json.Json

/** 全局 JSON 配置:四端与后端保持一致的序列化行为 */
object OrdoJson {
    val instance: Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
        prettyPrint = false
    }

    val pretty: Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
        prettyPrint = true
    }
}
