package com.moviepilottools.mptools.data

import kotlinx.serialization.Serializable
import java.util.UUID

/** 自定义请求头，用于需要 x-api-key / Cookie / Authorization 的站点 */
@Serializable
data class HeaderPair(
    val key: String = "",
    val value: String = ""
)

/**
 * 一条 RSS 订阅源。规则全部挂在源上（与 iOS 原版一致）：
 * 命中的条目在自动下载开启时直接推给指定下载器。
 */
@Serializable
data class RssSource(
    val id: String = UUID.randomUUID().toString(),
    val name: String = "",
    val url: String = "",
    val enabled: Boolean = true,
    val autoDownload: Boolean = false,
    /** 站点 API Key（部分站点需要 x-api-key 请求头） */
    val apiKey: String = "",
    val headers: List<HeaderPair> = emptyList(),
    val faviconUrl: String = "",
    val includeKeywords: List<String> = emptyList(),
    val excludeKeywords: List<String> = emptyList(),
    val minSizeGB: Double? = null,
    val maxSizeGB: Double? = null,
    /** 例：01-12 / S01E01-E10 / 01 02 03 / 01-12; 15 */
    val episodeFilter: String = "",
    val savePath: String = "",
    val category: String = "",
    val addPaused: Boolean = false,
    /** -1 低 / 0 默认 / 1 高 */
    val priority: Int = 0,
    /** null = 自动选择服务器 */
    val targetServerId: String? = null,
    val lastUpdated: Long = 0L,
    val lastError: String = ""
) {
    val hasRules: Boolean
        get() = includeKeywords.isNotEmpty() ||
            excludeKeywords.isNotEmpty() ||
            minSizeGB != null ||
            maxSizeGB != null ||
            episodeFilter.isNotBlank()

    val ruleSummary: String
        get() = buildList {
            if (includeKeywords.isNotEmpty()) add("含 ${includeKeywords.joinToString("/")}")
            if (excludeKeywords.isNotEmpty()) add("排 ${excludeKeywords.joinToString("/")}")
            minSizeGB?.let { add("≥${trimNum(it)}G") }
            maxSizeGB?.let { add("≤${trimNum(it)}G") }
            if (episodeFilter.isNotBlank()) add("集 $episodeFilter")
        }.joinToString(" · ").ifBlank { "无规则（全部推送）" }

    /** favicon 兜底：优先用户填的，其次按 host 猜，最后用站点默认图标 */
    val resolvedFavicon: String
        get() {
            if (faviconUrl.isNotBlank()) return faviconUrl
            val lower = url.lowercase()
            val host = runCatching { java.net.URI(url).host }.getOrNull() ?: return ""
            if (host.isBlank()) return ""
            val scheme = if (lower.startsWith("https")) "https" else "http"
            return "$scheme://$host/favicon.ico"
        }

    private fun trimNum(v: Double): String =
        if (v % 1.0 == 0.0) v.toInt().toString() else v.toString()
}

/** 从 RSS 里解析出来的一条种子 */
@Serializable
data class RssItemRecord(
    val id: String = UUID.randomUUID().toString(),
    val sourceId: String = "",
    val title: String = "",
    val link: String = "",
    val pubDate: Long = 0L,
    /** 0 表示 RSS 没给体积，此时体积规则不参与判断 */
    val sizeBytes: Long = 0L,
    val downloaded: Boolean = false,
    val seenAt: Long = System.currentTimeMillis(),
    /** 命中规则的时间，用于「全部条目」里高亮 */
    val matched: Boolean = false,
    val error: String = ""
)
