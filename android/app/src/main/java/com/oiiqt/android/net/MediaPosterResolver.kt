package com.oiiqt.android.net

import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.util.concurrent.ConcurrentHashMap

/**
 * 种子标题 → 海报地址。
 *
 * 站点浏览接口只给文字（title / description / size / seeders…），没有任何图片字段，
 * 海报只能靠 MP 的识别接口反查。一屏几十条就是几十次请求，所以这里做三件事：
 *
 * 1. **归一化标题做 key**：同一部片的不同清晰度/压制组共享一张海报，请求量能降 80%；
 * 2. **内存 LRU + 负缓存**：成功的存地址，失败的也记一笔（值为 null 的等价物），
 *    翻回来不会重试；容量 400 条够刷十几页；
 * 3. **并发 3**：MP 内部要查 TMDB/豆瓣，开太多反而互相拖慢，还容易被限流。
 *
 * 单条超时由 [Net.posterClient]（8 秒）兜住，超时即当失败，卡片保持渐变占位。
 * 调用方**不要在 Composable 里调**，统一由 ViewModel 批量拉完再回填 state。
 */
object MediaPosterResolver {

    private const val CAPACITY = 400

    private val hits = object : LinkedHashMap<String, String>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?): Boolean =
            size > CAPACITY
    }

    private val misses = object : LinkedHashMap<String, Boolean>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Boolean>?): Boolean =
            size > CAPACITY
    }

    private val lock = Any()
    private val gate = Semaphore(3)

    private val brackets = Regex("""[\[\(【（][^\]\)】）]*[\]\)】）]""")
    private val technical = Regex(
        "(?i)(2160p|1080p|1080i|720p|480p|4k|uhd|web-?dl|webrip|web|blu-?ray|bdrip|bdmv|remux|" +
            "hdtv|hdtvrip|dvdrip|h\\.?264|h\\.?265|x\\.?264|x\\.?265|hevc|avc|av1|aac|ac3|eac3|" +
            "dts|truehd|ddp|atmos|flac|10bit|8bit|hdr10\\+?|hdr|dovi|dv|sdr|repack|proper|" +
            "internal|limited|remastered|60fps|hq)"
    )
    private val season = Regex(
        "(?i)(s\\d{1,2}(e\\d{1,3})?|e\\d{1,3}|第[一二三四五六七八九十\\d]+季|season\\s*\\d+|" +
            "season\\s*\\d+\\s*complete)"
    )
    private val groupSuffix = Regex("""[-@][A-Za-z0-9@._]{2,}$""")
    private val collection = Regex("(?i)(合集|全集|complete|collection)")

    /**
     * 归一化成缓存键。
     *
     * 例：`[FREE] Ace of the Diamond S02E19 1080p FriDay WEB-DL AAC2.0 H.264-MWeb`
     * → `ace of the diamond friday`
     * 年份会保留（`电影名 2019`），否则同名新旧两版会共用一张海报。
     */
    fun titleKey(raw: String): String {
        var text = raw.trim()
        if (text.isEmpty()) return ""
        text = brackets.replace(text, " ")
        text = technical.replace(text, " ")
        text = season.replace(text, " ")
        text = collection.replace(text, " ")
        text = groupSuffix.replace(text, " ")
        text = text.replace('_', ' ').replace('.', ' ')
        text = text.replace(Regex("""[-—/|:]+"""), " ")
        text = text.replace(Regex("""\s+"""), " ").trim().lowercase()
        return if (text.length > 48) text.substring(0, 48).trim() else text
    }

    fun cached(key: String): String? = synchronized(lock) { hits[key] }

    /** 已经问过 MP 了（成功或失败都算），不必再发请求 */
    fun isResolved(key: String): Boolean =
        synchronized(lock) { hits.containsKey(key) || misses.containsKey(key) }

    /**
     * 批量解析，返回「本次真正拿到」的 key → 海报地址（已命中的不返回，调用方自己查缓存）。
     *
     * @param requests key（[titleKey]）与原始标题的配对，调用方负责去重
     */
    suspend fun resolve(
        client: MoviePilotClient,
        requests: List<Pair<String, String>>
    ): Map<String, String> {
        if (requests.isEmpty()) return emptyMap()
        val resolved = ConcurrentHashMap<String, String>()
        coroutineScope {
            requests.forEach { (key, title) ->
                launch {
                    gate.withPermit {
                        if (isResolved(key)) {
                            cached(key)?.let { resolved[key] = it }
                            return@withPermit
                        }
                        val url = runCatching { client.sitePoster(title) }.getOrNull()
                        synchronized(lock) {
                            if (url != null) hits[key] = url else misses[key] = true
                        }
                        if (url != null) resolved[key] = url
                    }
                }
            }
        }
        return resolved
    }

    /** 换 MP 服务器 / 站点时清空，避免把上一台的识别结果串过来 */
    fun clear() {
        synchronized(lock) {
            hits.clear()
            misses.clear()
        }
    }
}
