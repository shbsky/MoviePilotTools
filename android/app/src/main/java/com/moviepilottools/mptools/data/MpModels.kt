package com.moviepilottools.mptools.data

import kotlin.math.roundToInt

import kotlinx.serialization.Serializable
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.UUID

/** MoviePilot 服务器。与下载器一样支持多地址自动切换。 */
@Serializable
data class MpServer(
    val id: String = UUID.randomUUID().toString(),
    val name: String = "MoviePilot",
    val endpoints: List<Endpoint> = emptyList(),
    /** API Token（MP 设置 → 系统 → API Token），可调用全部接口 */
    val apiToken: String = "",
    /** 可选：填了才能用「渐进式搜索」和更细的用户态能力 */
    val username: String = "",
    val password: String = "",
    val endpointMode: EndpointMode = EndpointMode.AUTO,
    val pinnedEndpointIndex: Int = 0
) {
    val displayName: String get() = name.ifBlank { "MoviePilot" }
    val activeEndpoints: List<Endpoint> get() = endpoints.filter { it.enabled && it.isValid }
    val hasLogin: Boolean get() = username.isNotBlank() && password.isNotBlank()
    val isValid: Boolean get() = activeEndpoints.isNotEmpty() && apiToken.isNotBlank()
}

/** MP 返回的影视条目 */
data class MpMedia(
    val mediaId: String,
    val source: String,
    val type: String,
    val title: String,
    val year: String,
    val season: Int?,
    val tmdbId: Int?,
    val doubanId: String?,
    val bangumiId: Int?,
    val posterUrl: String,
    val backdropUrl: String,
    val overview: String,
    val vote: Double,
    val genres: List<String>,
    val directors: List<String>,
    val cast: List<String>,
    val releaseDate: String,
    val category: String
) {
    val isTV: Boolean get() = type.equals("tv", true) || type == "电视剧"
    val typeLabel: String get() = if (isTV) "剧集" else "电影"
    val yearLabel: String get() = year.ifBlank { releaseDate.take(4) }

    /** 资源搜索用的 mediaid，MP 需要「来源:ID」格式 */
    val searchKey: String
        get() = when {
            mediaId.contains(":") -> mediaId
            tmdbId != null && tmdbId > 0 -> "tmdb:$tmdbId"
            !doubanId.isNullOrBlank() -> "douban:$doubanId"
            bangumiId != null && bangumiId > 0 -> "bangumi:$bangumiId"
            else -> mediaId
        }
}

/** 一条候选资源（对应 MP 的 torrent_info） */
data class MpResource(
    val key: String = UUID.randomUUID().toString(),
    val siteName: String,
    val title: String,
    val description: String,
    val pageUrl: String,
    val sizeBytes: Long,
    val seeders: Int,
    val peers: Int,
    val grabs: Int,
    val pubDateText: String,
    val pubDateMs: Long,
    val downloadFactor: Double,
    val uploadFactor: Double,
    val hitAndRun: Boolean,
    val labels: List<String>,
    /**
     * MP 的「剩余免费时间」（TorrentInfo.freedate_diff），网页上单独一个绿色标签，
     * 形如 `1天23小时12分钟`。以前没解析这个字段，免费种子只能显示「免费」，
     * 时长全靠猜 description，基本猜不到（用户反馈「免费时长标签没加上」）。
     */
    val freeTimeDiff: String = "",
    /**
     * 免费截止时间（`TorrentInfo.freedate`，形如 `2026-11-23 19:35:00`）。
     *
     * 部分站点只给截止时间、`freedate_diff` 是空的，
     * 结果卡片上「免费」后面光秃秃的，而站点网页写着「限时1时20分」。
     * 服务端不给现成时长，就自己按截止时间算一次兜底。
     */
    val freeDate: String = "",
    /** 原始 torrent_info JSON，投递时原样回传，MP 才能拿到 enclosure / site_cookie */
    val rawJson: String
) {
    val isFree: Boolean get() = downloadFactor <= 0.0
    val isDoubleUp: Boolean get() = uploadFactor > 1.0

    /**
     * 促销文案（对齐 MP 前端）。
     * 以前 0.01~0.5 一律压成「折扣」，看不出是 50% 还是 30%；
     * 现在按倍率如实算：0.5 → `50%`、0 → `免费`、上传 2 倍 → `2X`（可与免费叠加）。
     */
    val promotionLabel: String
        get() = buildList {
            if (downloadFactor <= 0.0) {
                add("免费")
            } else if (downloadFactor < 1.0) {
                val pct = (downloadFactor * 100).roundToInt()
                if (pct in 1..99) add("$pct%")
            }
            if (uploadFactor > 1.0) {
                add(if (uploadFactor % 1.0 == 0.0) "${uploadFactor.toInt()}X" else "${uploadFactor}X")
            }
        }.joinToString(" ")

    /** 促销档次（筛选用）：免费 / 折扣 / 2X */
    val promotionTier: String
        get() = when {
            downloadFactor <= 0.0 -> "免费"
            downloadFactor < 1.0 -> "折扣"
            uploadFactor > 1.0 -> "2X"
            else -> "无促销"
        }

    /**
     * 制作组（小组名）：取标题**最后一个连字符**后的 token。
     *
     * `...2160p WEB-DL.H265 AAC-CSWEB`     → CSWEB
     * `...DTS-HD.MA.2.0-FULLBRUTALITY`     → FULLBRUTALITY（前面的 DTS-HD 不误判）
     * `Spider-Man.2002.1080p.x264-SPARKS`  → SPARKS（中间连字符不误判）
     * `...H.265-10bit`                     → 空（命中黑名单）
     */
    val group: String
        get() {
            val t = title.trim()
            val i = t.lastIndexOf('-')
            if (i <= 0 || i >= t.length - 1) return ""
            var g = t.substring(i + 1).trim()
            // 发布组常写成「发布者@制作组」（BiVerse@ADWeb、KKYY@CHDBits、AOC@BiVerse），
            // @ 前面是发布者 / 站点前缀，真正的小组名取 @ 之后那一段
            val at = g.lastIndexOf('@')
            if (at in 0 until g.length - 1) {
                g = g.substring(at + 1).trim()
            }
            // 站点标题常把小组和中文描述连在一起，例如：
            //  KILL BILL ... DTS-HD MA 5.1-DIY@TTG ⑤音频 粤语简繁中字
            // 只取小组 token（@ 之后的第一段），空格 / 中文 / 括号都算分隔，
            // 否则整段因含空格被判无效，标签里就看不到 TTG 了。
            val cut = g.indexOfFirst { it.isWhitespace() || it in "（(【[" || it in '\u4e00'..'\u9fa5' }
            if (cut > 0) g = g.substring(0, cut).trim()
            if (g.length !in 3..24) return ""
            if (g.any { it.isWhitespace() }) return ""
            if (g.all { it.isDigit() }) return ""
            if (Regex("^[0-9]{3,4}[pi]$", RegexOption.IGNORE_CASE).matches(g)) return ""
            if (Regex("^(x264|x265|h264|h265|avc|hevc|aac|ac3|eac3|dd|ddp|dts|truehd|atmos|hdr|sdr|dv|web|dl|webdl|bluray|remux|10bit|8bit)$",
                    RegexOption.IGNORE_CASE).matches(g)) return ""
            return g
        }

    /** 效果 / 字幕类标签（MP labels 去掉分辨率、来源、编码后剩下的） */
    val extraLabels: List<String>
        get() = labels.map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
            .filterNot { l ->
                Regex("(?i)(2160p|4k|uhd|1080[pi]|720[pi]|480[pi]|blu-?ray|bdrip|bdmv|web-?dl|webrip|hdtv|remux|h\\.?26[45]|x\\.?26[45]|hevc|avc|av1)")
                    .containsMatchIn(l)
            }

    /**
     * 卡片上的完整标签序列（对齐 MP 搜索结果）：
     * 禁转类 → H&R → MP labels（中字/国语/特效…）→ 分辨率 → 来源 → 制作组 → 促销。
     * 分辨率/来源若已被 labels 覆盖就不重复；最多 7 个，防卡片撑爆。
     */
    /**
     * 免费剩余时长（纯文本，如 `1小时20分钟` / `1天23小时12分钟`），拿不到返回空串。
     *
     * 四级兜底，缺哪级往下走：
     * 1. MP 直接给的 `freedate_diff`（网页那个绿色标签，多数站点走这条）；
     * 2. 自己按 `freedate` 截止时间算 —— **部分站点只给截止时间、diff 是空的**，
     *    以前这里就断了，「免费」后面什么都没有（用户反馈「网站有时长、App 没有」）；
     * 3. labels 里带的「剩余时间：X」（个别站在 label 文本里给）；
     * 4. description 开头的时长（服务端解析器偶尔把它当正文抓下来）。
     */
    val freeRemainingText: String
        get() {
            val diff = freeTimeDiff.trim()
            if (diff.any { it.isDigit() }) return diff
            val byDate = freeDateRemaining
            if (byDate.isNotEmpty()) return byDate
            for (l in labels) {
                val t = l.trim()
                if (t.contains("剩余") && t.any { it.isDigit() }) {
                    val cut = listOf(t.indexOf('：'), t.indexOf(':')).filter { it >= 0 }.minOrNull() ?: -1
                    return if (cut >= 0) t.substring(cut + 1).trim() else t
                }
            }
            val m = Regex("^(\\d+\\s*[天日])?\\s*(\\d+\\s*(?:小时|时))?\\s*(\\d+\\s*(?:分钟|分))?")
                .find(description.trim()) ?: return ""
            val t = m.value.trim()
            if (t.isEmpty() || !t.any { it.isDigit() }) return ""
            if (!Regex("[天日时分钟]").containsMatchIn(t)) return ""
            return t
        }

    /**
     * 按 [freeDate] 截止时间算剩余时长。
     *
     * MP 返回的是不带时区的本地时间（`2026-11-23 19:35:00`），按本机时区解；
     * 解析不出来、或已经过期（≤1 分钟）一律返回空，宁可少显示也不显示错的时间。
     */
    private val freeDateRemaining: String
        get() {
            val raw = freeDate.trim()
            if (raw.isEmpty()) return ""
            // 有的站点把「限时1时20分」原样塞进 freedate（不是时间戳），
            // 这种直接用文案，别去解析日期（日期串里不会有 天/时/分 这些字）
            val asText = raw.removePrefix("限时").removePrefix("剩余时间：").trim()
            if (asText.any { it.isDigit() } && Regex("[天日时分钟]").containsMatchIn(asText)) {
                return asText
            }
            val iso = raw.replace(' ', 'T')
            var ms = 0L
            for (pattern in arrayOf(
                "yyyy-MM-dd'T'HH:mm:ssXXX",
                "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy-MM-dd'T'HH:mm",
                "yyyy-MM-dd"
            )) {
                val v = runCatching { SimpleDateFormat(pattern, Locale.US).parse(iso)?.time ?: 0L }
                    .getOrDefault(0L)
                if (v > 0L) {
                    ms = v
                    break
                }
            }
            if (ms <= 0L) return ""
            val left = ms - System.currentTimeMillis()
            if (left <= 60_000L) return ""
            val mins = (left / 60_000L).toInt()
            val days = mins / 1440
            val hours = mins % 1440 / 60
            val rest = mins % 60
            val out = StringBuilder()
            if (days > 0) out.append(days).append("天")
            if (hours > 0) out.append(hours).append("小时")
            if (rest > 0 || out.isEmpty()) out.append(rest).append("分钟")
            return out.toString()
        }

    /** 带「剩余时间：」前缀的完整文案（个别页面还在用它） */
    val freeTimeLabel: String
        get() {
            val t = freeRemainingText
            return if (t.isEmpty()) "" else "剩余时间：$t"
        }

    /** 只取时长本身，并把「小时/分钟」压成「时/分」，供紧凑标签使用 */
    val freeTimeShort: String
        get() = freeRemainingText.replace("小时", "时").replace("分钟", "分").replace(" ", "").trim()

    /** 是否免费：倍率为 0，或站点 labels 里给了「免费」 */
    val isFreeLike: Boolean
        get() = downloadFactor <= 0.0 || labels.any { it.contains("免费") }

    fun badges(): List<String> {
        val out = mutableListOf<String>()
        fun add(v: String) {
            val t = v.trim()
            if (t.isEmpty()) return
            if (out.any { it.equals(t, ignoreCase = true) }) return
            out.add(t)
        }
        // 用户要求：**免费 / 免费时长永远排最前面**，一眼看到还能白嫖多久（对齐 MP 网页）。
        // 时长按 freeRemainingText 四级兜底（freedate_diff → freedate 自算 → labels → description），
        // 站点只给截止时间时也能算出「还剩多久」。
        val duration = freeRemainingText
        if (isFreeLike) {
            add("免费")
            if (duration.isNotEmpty()) add(duration)
        } else {
            add(promotionLabel)
        }

        // 核心原则：**优先原样展示 MP labels**（官方 / 国语 / 中字 / 禁转…），
        // 这是 MP 网页版给用户看的标签，App 不再自作主张过滤或重排，保证和网页一致。
        // 特判三处：纯「免费」和「剩余时间：X」跳过——上面已经统一放到最前面；
        // 小组名跳过——部分站点把制作组当普通标签塞进 labels 且排在前面，
        // 而项目约定「小组永远排最后」，所以这里剔掉，交给下面 add(group) 统一补在末尾。
        val groupName = group
        labels.forEach { l ->
            val t = l.trim()
            if (t == "免费" || (t.contains("剩余") && t.any { it.isDigit() })) return@forEach
            if (groupName.isNotEmpty() && t.equals(groupName, ignoreCase = true)) return@forEach
            add(t)
        }
        // H&R 兜底：MP labels 没给时补上。
        if (hitAndRun) add("H&R")
        // 分辨率 / 来源：labels 已经覆盖就不重复加。
        if (resolution != "其他" && out.none { s ->
                Regex("(?i)(4k|2160p|uhd|1080[pi]|720[pi]|480p)").containsMatchIn(s)
            }) add(resolution)
        if (quality != "其他" && out.none { s ->
                Regex("(?i)(blu-?ray|bdrip|bdmv|web-?dl|webrip|hdtv|remux)").containsMatchIn(s)
            }) add(quality)
        // 制作组（如 TTG）按用户要求放到最后。
        add(group)
        // 上限放宽到 12：MP 网页一条种子常有 8~10 个标签，8 个会把官方/免费时长挤掉。
        return out.take(12)
    }

    /**
     * 副标题：站点 description 优先（站点种子页那一行）。
     * MP 的搜索接口通常不返回 description，只有 browse 接口才带，所以为空时用
     * 「小组 · 来源 · 编码」兜底，别让卡片留一条空白。
     */
    val subtitle: String
        get() {
            val d = description.trim()
            if (d.isNotEmpty()) return d
            return listOf(group, quality.takeIf { it != "其他" } ?: "", codec.takeIf { it != "其他" } ?: "")
                .filter { it.isNotEmpty() }
                .joinToString(" · ")
        }

    val resolution: String
        get() = when {
            Regex("(?i)(2160p|4k|uhd)").containsMatchIn(title) -> "4K"
            Regex("(?i)1080[pi]").containsMatchIn(title) -> "1080p"
            Regex("(?i)720[pi]").containsMatchIn(title) -> "720p"
            Regex("(?i)480[pi]").containsMatchIn(title) -> "480p"
            else -> "其他"
        }

    val quality: String
        get() = when {
            Regex("(?i)remux").containsMatchIn(title) -> "REMUX"
            Regex("(?i)blu-?ray|bdrip|bdmv").containsMatchIn(title) -> "BluRay"
            Regex("(?i)web-?dl").containsMatchIn(title) -> "WEB-DL"
            Regex("(?i)webrip").containsMatchIn(title) -> "WEBRip"
            Regex("(?i)hdtv").containsMatchIn(title) -> "HDTV"
            else -> "其他"
        }

    val codec: String
        get() = when {
            Regex("(?i)(h\\.?265|x\\.?265|hevc)").containsMatchIn(title) -> "H.265"
            Regex("(?i)(h\\.?264|x\\.?264|avc)").containsMatchIn(title) -> "H.264"
            Regex("(?i)av1").containsMatchIn(title) -> "AV1"
            else -> "其他"
        }
}

enum class ResourceSortField(val label: String) {
    RELEVANCE("默认"),
    SEEDERS("做种数"),
    PUBLISH_TIME("发布时间"),
    SIZE("文件大小"),
    SITE("站点")
}

/**
 * 资源筛选。
 *
 * 四组标签都是多选：空集合代表「全部」，选中多个时取并集（命中任一即保留）。
 * 筛选没有「应用」这一步——UI 每次点选都直接回写，列表实时跟着变。
 */
data class ResourceFilter(
    val sites: Set<String> = emptySet(),
    val resolutions: Set<String> = emptySet(),
    val qualities: Set<String> = emptySet(),
    val codecs: Set<String> = emptySet(),
    /** 效果 / 字幕标签（中字、国语、特效…）：命中任意一个即通过 */
    val subtitles: Set<String> = emptySet(),
    /** 制作组（小组名） */
    val groups: Set<String> = emptySet(),
    /** 促销档次：免费 / 折扣 / 2X */
    val promotions: Set<String> = emptySet(),
    val promotionOnly: Boolean = false,
    val hideHitAndRun: Boolean = false,
    val sortField: ResourceSortField = ResourceSortField.RELEVANCE,
    val descending: Boolean = true
) {
    val activeCount: Int
        get() = sites.size + resolutions.size + qualities.size + codecs.size +
            subtitles.size + groups.size + promotions.size +
            (if (promotionOnly) 1 else 0) + (if (hideHitAndRun) 1 else 0)

    /** 清空全部筛选项，只保留排序（重置按钮用） */
    fun cleared(): ResourceFilter = ResourceFilter(sortField = sortField, descending = descending)

    fun apply(list: List<MpResource>): List<MpResource> {
        val filtered = list.filter { item ->
            (sites.isEmpty() || item.siteName in sites) &&
                (resolutions.isEmpty() || item.resolution in resolutions) &&
                (qualities.isEmpty() || item.quality in qualities) &&
                (codecs.isEmpty() || item.codec in codecs) &&
                (subtitles.isEmpty() || item.extraLabels.any { it in subtitles }) &&
                (groups.isEmpty() || item.group in groups) &&
                (promotions.isEmpty() || item.promotionTier in promotions) &&
                (!promotionOnly || item.isFree) &&
                (!hideHitAndRun || !item.hitAndRun)
        }
        val sorted = when (sortField) {
            ResourceSortField.RELEVANCE -> filtered
            ResourceSortField.SEEDERS -> filtered.sortedBy { it.seeders }
            ResourceSortField.PUBLISH_TIME -> filtered.sortedBy { it.pubDateMs }
            ResourceSortField.SIZE -> filtered.sortedBy { it.sizeBytes }
            ResourceSortField.SITE -> filtered.sortedBy { it.siteName.lowercase() }
        }
        return if (descending && sortField != ResourceSortField.RELEVANCE) sorted.reversed() else sorted
    }
}

/** MP 下载器 */
data class MpDownloader(val name: String, val type: String)

/** MP 保存路径 */
data class MpSavePath(val name: String, val savePath: String, val storage: String)

/** MP 订阅（与网页端同一份数据） */
data class MpSubscribe(
    val id: Int,
    val name: String,
    val year: String,
    val type: String,
    val season: Int?,
    val posterUrl: String,
    val vote: Double,
    val totalEpisode: Int,
    val lackEpisode: Int,
    val completedEpisode: Int?,
    val state: String,
    val lastUpdate: String,
    val sites: List<Int>,
    val downloader: String,
    val bestVersion: Boolean,
    val savePath: String,
    // ---- 订阅设置（编辑弹窗用；v2.9 的更新接口是整条覆盖，所以身份字段也要一起回传） ----
    val keyword: String = "",
    val quality: String = "",
    val resolution: String = "",
    val effect: String = "",
    /** 定时搜索间隔（小时）；null = 跟随系统 */
    val searchInterval: Int? = null,
    val include: String = "",
    val exclude: String = "",
    val filterGroups: List<String> = emptyList(),
    val mediaCategory: String = "",
    val customWords: String = "",
    val searchImdbId: Boolean = false,
    val tmdbId: Int? = null,
    val doubanId: String = "",
    val bangumiId: Int? = null,
    /** MP 里存的原始 poster / backdrop 路径；v2.9 的更新是整条覆盖，得原样回传才不会被改坏 */
    val posterRaw: String = "",
    val backdropRaw: String = "",
    val description: String = "",
    val startEpisode: Int = 0,
    /** v3 的媒体身份，用于「媒体详情」直接按身份打开 */
    val mediaSource: String = "",
    val mediaIdRaw: String = ""
) {
    val stateLabel: String
        get() = when (state.uppercase()) {
            "R" -> "订阅中"
            "P" -> "已暂停"
            "S" -> "已停止"
            "N" -> "新建"
            else -> state
        }

    val progressText: String
        get() {
            if (type != "电视剧") return "电影"
            val total = totalEpisode
            if (total <= 0) return "集数未知"
            val done = completedEpisode ?: (total - lackEpisode).coerceAtLeast(0)
            return "$done / $total 集"
        }

    val progress: Float
        get() {
            if (totalEpisode <= 0) return 0f
            val done = completedEpisode ?: (totalEpisode - lackEpisode).coerceAtLeast(0)
            return (done.toFloat() / totalEpisode).coerceIn(0f, 1f)
        }
}

/** 发现页的一个入口（豆瓣热映 / TMDB 趋势 …） */
data class MpDiscoverChannel(
    val key: String,
    val title: String,
    val subtitle: String,
    /** MP 接口路径（不含前缀） */
    val path: String,
    /** 部分接口需要额外参数 */
    val extraQuery: String = "",
    val supportsPaging: Boolean = true,
    val icon: String = ""
)


/**
 * MoviePilot 仪表盘的媒体库统计（`/api/v1/dashboard/statistic`）。
 *
 * 对应的就是 MP 网页仪表盘「媒体统计」那一块：电影 / 电视剧 / 剧集 / 用户，
 * 以及各自的本月新增。
 */
data class MpStatistic(
    val movies: Int = 0,
    val tvs: Int = 0,
    val episodes: Int = 0,
    val users: Int = 0,
    /** MP 部分版本不返回音乐数量，缺字段时保持 0（仪表盘「音乐」一栏照常显示） */
    val music: Int = 0,
    val moviesThisMonth: Int = 0,
    val tvsThisMonth: Int = 0,
    val episodesThisMonth: Int = 0,
    val musicThisMonth: Int = 0
) {
    val isEmpty: Boolean get() = movies == 0 && tvs == 0 && episodes == 0
}

/**
 * MoviePilot 的存储空间（`/api/v1/dashboard/storage`，单位字节）。
 *
 * 口径是「媒体库目录所在磁盘」的总量与已用，MP 服务端已经按物理盘去重，
 * 不会像各下载器那样把同一块盘算两遍，所以仪表盘「剩余空间」优先用它。
 */
data class MpStorage(
    val total: Long = 0,
    val used: Long = 0
) {
    /** 剩余可用 = 总量 - 已用 */
    val free: Long get() = (total - used).coerceAtLeast(0)

    /** 没拿到有效数据（接口失败或未配置媒体库目录） */
    val isEmpty: Boolean get() = total <= 0
}

/** MP 仪表盘「实时速率」（`/api/v1/dashboard/downloader`），size 为字节，speed 为字节/秒。 */
data class MpDownloaderInfo(
    val downloadSpeed: Long = 0,
    val uploadSpeed: Long = 0,
    val downloadSize: Long = 0,
    val uploadSize: Long = 0,
    val freeSpace: Long = 0
) {
    val isEmpty: Boolean
        get() = downloadSpeed == 0L && uploadSpeed == 0L &&
            downloadSize == 0L && uploadSize == 0L && freeSpace == 0L
}

/** MP 仪表盘内存（`/api/v1/dashboard/memory`），单位字节；usage 是进程占系统内存百分比。 */
data class MpMemoryInfo(
    val total: Long = 0,
    val used: Long = 0,
    val cached: Long = 0,
    val available: Long = 0,
    val usage: Float = 0f
)

/** MP 仪表盘系统信息（`/api/v1/dashboard/system`，仅登录管理员 JWT 可用）。 */
data class MpSystemInfo(
    val hostname: String = "",
    val operatingSystem: String = "",
    val runtime: String = "",
    val version: String = ""
) {
    val isEmpty: Boolean
        get() = hostname.isBlank() && operatingSystem.isBlank() &&
            runtime.isBlank() && version.isBlank()
}

/** 一条本地采样，时间戳用于计算 1m / 5m / 15m 均值。 */
data class CpuSample(val atMs: Long, val value: Float)

/** 内存趋势的一条本地采样（三条序列共用同一时间戳）。 */
data class MemorySample(
    val atMs: Long,
    val used: Long,
    val cached: Long,
    val available: Long
)
