package com.oiiqt.android.net

import android.util.Xml
import com.oiiqt.android.data.RssItemRecord
import com.oiiqt.android.data.RssSource
import okhttp3.Request
import org.xmlpull.v1.XmlPullParser
import java.io.StringReader
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * RSS 抓取与解析。兼容：
 * - RSS 2.0（NexusPHP 系 PT 站主流）、RDF/RSS 1.0、Atom
 * - 体积来自 enclosure@length、<size>、或描述里的「大小：1.2 GB」
 * - NexusPHP 的 details.php 详情链接会自动改写成带 passkey 的下载链接
 */
object RssFetcher {

    private val client by lazy {
        OkHttpClientLazy.holder
    }

    private const val UA =
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36"

    fun fetch(source: RssSource): List<RssItemRecord> {
        val url = source.url.trim()
        require(url.startsWith("http://") || url.startsWith("https://")) { "RSS 地址必须以 http(s):// 开头" }

        val builder = Request.Builder().url(url).get()
            .header("User-Agent", UA)
            .header("Accept", "application/rss+xml, application/xml, text/xml, */*")
        if (source.apiKey.isNotBlank()) {
            builder.header("x-api-key", source.apiKey.trim())
        }
        source.headers.forEach { header ->
            if (header.key.isNotBlank()) builder.header(header.key.trim(), header.value.trim())
        }

        client.newCall(builder.build()).execute().use { response ->
            if (!response.isSuccessful) {
                throw ApiException("HTTP ${response.code}${if (response.code == 401 || response.code == 403) "（站点认证失败，检查 API Key / Headers）" else ""}")
            }
            val bytes = response.body?.bytes() ?: throw ApiException("响应为空")
            val text = decode(bytes)
            if (text.isBlank()) throw ApiException("RSS 内容为空")
            val items = parse(text, source)
            if (items.isEmpty() && !text.contains("<item", true) && !text.contains("<entry", true)) {
                throw ApiException("不是有效的 RSS 内容（可能被登录页拦截）")
            }
            return items
        }
    }

    private fun decode(bytes: ByteArray): String {
        val head = String(bytes, 0, minOf(bytes.size, 200), Charsets.ISO_8859_1)
        val declared = Regex("encoding=[\"']([A-Za-z0-9_-]+)[\"']").find(head)?.groupValues?.get(1)
        val charset = when {
            declared == null -> Charsets.UTF_8
            declared.equals("gb2312", true) || declared.equals("gbk", true) || declared.equals("gb18030", true) ->
                runCatching { charset("GB18030") }.getOrDefault(Charsets.UTF_8)

            else -> runCatching { charset(declared) }.getOrDefault(Charsets.UTF_8)
        }
        return String(bytes, charset).removePrefix("\uFEFF")
    }

    // ---------- 解析 ----------

    private class Builder {
        var title = ""
        var link = ""
        var enclosureUrl = ""
        var sizeBytes = 0L
        var pubDateText = ""
        var description = ""
        var guid = ""
    }

    fun parse(xml: String, source: RssSource): List<RssItemRecord> {
        val parser = Xml.newPullParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
        parser.setInput(StringReader(xml))

        val result = mutableListOf<RssItemRecord>()
        var current: Builder? = null
        var textBuffer = StringBuilder()
        var inItem = false
        var inEntry = false

        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> {
                    val name = parser.name.lowercase()
                    when (name) {
                        "item" -> {
                            current = Builder()
                            inItem = true
                        }

                        "entry" -> {
                            current = Builder()
                            inEntry = true
                        }

                        "enclosure" -> {
                            val url = parser.getAttributeValue(null, "url").orEmpty()
                            val length = parser.getAttributeValue(null, "length").orEmpty()
                            current?.let {
                                if (url.isNotBlank()) it.enclosureUrl = url
                                val parsed = length.toLongOrNull() ?: 0L
                                if (parsed > 0) it.sizeBytes = parsed
                            }
                        }

                        "link" -> {
                            // Atom 用 href 属性
                            val href = parser.getAttributeValue(null, "href")
                            val rel = parser.getAttributeValue(null, "rel")
                            if (!href.isNullOrBlank()) {
                                current?.let {
                                    if (rel == null || rel == "alternate") {
                                        if (it.link.isBlank()) it.link = href
                                    } else if (rel == "enclosure") {
                                        it.enclosureUrl = href
                                    }
                                }
                            }
                        }
                    }
                    textBuffer = StringBuilder()
                }

                XmlPullParser.TEXT -> {
                    if (current != null) textBuffer.append(parser.text)
                }

                XmlPullParser.END_TAG -> {
                    val name = parser.name.lowercase()
                    val text = textBuffer.toString().trim()
                    val target = current
                    if (target != null) {
                        when (name) {
                            "title" -> if (target.title.isBlank()) target.title = text
                            "link" -> if (text.isNotBlank() && (text.startsWith("http") || text.startsWith("magnet:"))) {
                                target.link = text
                            }
                            "guid" -> target.guid = text
                            "pubdate", "published", "updated", "dc:date", "date" ->
                                if (target.pubDateText.isBlank()) target.pubDateText = text

                            "description", "summary", "content", "content:encoded", "torrent:content" ->
                                if (target.description.isBlank()) target.description = text

                            "size", "contentlength", "torrent:contentlength" -> {
                                val bytes = text.toLongOrNull() ?: parseSizeText(text)
                                if (bytes > 0 && target.sizeBytes == 0L) target.sizeBytes = bytes
                            }

                            "item", "entry" -> {
                                if (target.title.isNotBlank()) {
                                    val finalLink = when {
                                        target.enclosureUrl.isNotBlank() -> target.enclosureUrl
                                        target.link.isNotBlank() -> target.link
                                        target.guid.startsWith("magnet:") -> target.guid
                                        else -> target.guid
                                    }
                                    if (target.sizeBytes == 0L) {
                                        target.sizeBytes = parseSizeFromDescription(target.description)
                                    }
                                    result += RssItemRecord(
                                        sourceId = source.id,
                                        title = target.title,
                                        link = fixLink(finalLink, source.url),
                                        pubDate = parseDate(target.pubDateText),
                                        sizeBytes = target.sizeBytes
                                    )
                                }
                                current = null
                                inItem = false
                                inEntry = false
                            }
                        }
                    }
                    textBuffer = StringBuilder()
                }
            }
            event = parser.next()
        }

        if (inItem || inEntry) {
            // 极端情况：XML 未闭合，按已解析内容兜底
            current?.let { target ->
                if (target.title.isNotBlank() && (target.link.isNotBlank() || target.enclosureUrl.isNotBlank())) {
                    result += RssItemRecord(
                        sourceId = source.id,
                        title = target.title,
                        link = fixLink(target.enclosureUrl.ifBlank { target.link }, source.url),
                        pubDate = parseDate(target.pubDateText),
                        sizeBytes = target.sizeBytes
                    )
                }
            }
        }
        return result
    }

    /** NexusPHP：详情页链接 → 下载链接，并把源里的 passkey 带上 */
    fun fixLink(link: String, sourceUrl: String): String {
        val trimmed = link.trim()
        if (trimmed.isEmpty()) return trimmed
        if (isDownloadLink(trimmed)) return trimmed
        val passkey = runCatching {
            Regex("[?&]passkey=([^&]+)").find(sourceUrl)?.groupValues?.get(1)
        }.getOrNull()

        if (passkey.isNullOrBlank()) return trimmed

        val replaced = trimmed
            .replace("details.php", "download.php")
            .replace("dl.php", "download.php")

        if (!replaced.contains("download.php")) return trimmed

        val withoutHit = Regex("([?&])hit=[^&]*").replace(replaced, "$1").replace("?&", "?")
        if (withoutHit.contains("passkey=")) return withoutHit
        val joiner = if (withoutHit.contains("?")) "&" else "?"
        return "$withoutHit${joiner}passkey=$passkey"
    }

    private fun isDownloadLink(link: String): Boolean =
        link.startsWith("magnet:") ||
            link.contains("download.php") ||
            link.contains("/dl/") ||
            link.endsWith(".torrent", ignoreCase = true)

    private fun parseDate(raw: String): Long {
        val text = raw.trim()
        if (text.isEmpty()) return System.currentTimeMillis()
        val patterns = listOf(
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
            "yyyy-MM-dd HH:mm:ss"
        )
        for (pattern in patterns) {
            val parsed = runCatching {
                SimpleDateFormat(pattern, Locale.US).parse(text)?.time
            }.getOrNull()
            if (parsed != null) return parsed
        }
        return System.currentTimeMillis()
    }

    private fun parseSizeText(text: String): Long {
        val regex = Regex("([\\d.]+)\\s*(TB|TiB|GB|GiB|MB|MiB|KB|KiB|B)", RegexOption.IGNORE_CASE)
        val match = regex.find(text) ?: return 0L
        val value = match.groupValues[1].toDoubleOrNull() ?: return 0L
        return when (match.groupValues[2].uppercase()) {
            "TB", "TIB" -> (value * 1024 * 1024 * 1024 * 1024).toLong()
            "GB", "GIB" -> (value * 1024 * 1024 * 1024).toLong()
            "MB", "MIB" -> (value * 1024 * 1024).toLong()
            "KB", "KIB" -> (value * 1024).toLong()
            else -> value.toLong()
        }
    }

    /** 有的站把体积写在描述里：大小：1.23 GB / Size: 1.23GB */
    private fun parseSizeFromDescription(description: String): Long {
        if (description.isBlank()) return 0L
        val cleaned = description
            .replace("<![CDATA[", " ")
            .replace("]]>", " ")
            .replace(Regex("<[^>]+>"), " ")
            .replace("&nbsp;", " ")
        val regex = Regex("(?:大小|Size|体积)\\s*[:：]?\\s*([\\d.]+)\\s*(TB|TiB|GB|GiB|MB|MiB)", RegexOption.IGNORE_CASE)
        val match = regex.find(cleaned) ?: return 0L
        val value = match.groupValues[1].toDoubleOrNull() ?: return 0L
        return when (match.groupValues[2].uppercase()) {
            "TB", "TIB" -> (value * 1024 * 1024 * 1024 * 1024).toLong()
            "GB", "GIB" -> (value * 1024 * 1024 * 1024).toLong()
            else -> (value * 1024 * 1024).toLong()
        }
    }
}

/** RSS 抓取专用客户端：站点响应可能较慢，单独放宽读超时 */
private object OkHttpClientLazy {
    val holder: okhttp3.OkHttpClient by lazy {
        Net.client.newBuilder()
            .connectTimeout(12, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .callTimeout(45, TimeUnit.SECONDS)
            .build()
    }
}
