package com.moviepilottools.mptools.data

import kotlinx.serialization.Serializable
import java.util.UUID

enum class ServerType(val label: String) {
    QBITTORRENT("qBittorrent"),
    TRANSMISSION("Transmission");

    val shortLabel: String get() = if (this == QBITTORRENT) "qb" else "tr"
}

/** 同一台服务器可以有多个入口地址，App 会按网络环境自动挑一个能通的。 */
@Serializable
data class Endpoint(
    val host: String = "",
    val port: Int = 8080,
    val https: Boolean = false,
    /** 反向代理子路径，例如 /qb */
    val basePath: String = "",
    /** 备注：家里内网 / 外网域名 */
    val label: String = "",
    val enabled: Boolean = true
) {
    /** 端口留空（0）视为「协议默认端口」：https 走 443、http 走 80。 */
    val isValid: Boolean get() = host.isNotBlank() && (port == 0 || port in 1..65535)

    val effectivePort: Int get() = if (port in 1..65535) port else if (https) 443 else 80

    val display: String
        get() = buildString {
            append(if (https) "https://" else "http://")
            append(host)
            if (port in 1..65535) {
                val defaultPort = if (https) 443 else 80
                if (port != defaultPort) append(":").append(port)
            }
            if (basePath.isNotBlank()) append(basePath.trimEnd('/'))
        }

    /**
     * 把用户可能整段粘贴的地址拆开：`https://mp.example.com:3000/mp/` →
     * host=mp.example.com、port=3000、https=true、basePath=/mp。
     */
    fun normalized(): Endpoint {
        var raw = host.trim()
        val lower = raw.lowercase()
        var secure = https
        var path = basePath.trim()
        var parsedPort = port

        when {
            lower.startsWith("https://") -> { secure = true; raw = raw.substring(8) }
            lower.startsWith("http://") -> { secure = false; raw = raw.substring(7) }
        }
        raw = raw.trimEnd('/')

        val slash = raw.indexOf('/')
        if (slash >= 0) {
            if (path.isBlank()) path = raw.substring(slash)
            raw = raw.substring(0, slash)
        }

        // 只把「最后一个冒号且在 ] 之后」当成端口，避免把 IPv6 拆坏
        val colon = raw.lastIndexOf(':')
        if (colon > 0 && raw.indexOf(']') < colon) {
            val maybePort = raw.substring(colon + 1).toIntOrNull()
            if (maybePort != null && maybePort in 1..65535) {
                parsedPort = maybePort
                raw = raw.substring(0, colon)
            }
        }

        return copy(host = raw.trim(), port = parsedPort, https = secure, basePath = path.trim())
    }

    /** 拼出完整请求地址，path 形如 "api/v2/torrents/info" */
    fun url(path: String): String {
        val base = display.trimEnd('/')
        val p = path.trimStart('/')
        return "$base/$p"
    }

    /** 探测/缓存用的唯一键，端口留空时按实际生效端口区分 */
    fun hostKey(): String = "${host.lowercase()}:${effectivePort}:$https:$basePath"

    /**
     * 这条地址是不是「局域网地址」（纯字面判断，不发请求）：
     * IPv4 私有段 / 回环 / 链路本地、IPv6 唯一本地、不带点的主机名、*.local/.lan 等算内网；
     * 公网域名（ddns / 反代）算外网。连上 WiFi 时优先探内网这几条。
     */
    val isLanHost: Boolean
        get() {
            val h = host.trim().lowercase()
            if (h.isEmpty()) return false
            if (h == "localhost" || h == "::1") return true
            // IPv6 字面量（链路本地 fe80 / 唯一本地 fc00::7）
            if (h.startsWith("[")) {
                val v6 = h.removePrefix("[").substringBefore("]")
                return v6.startsWith("fe80") || v6.startsWith("fc") || v6.startsWith("fd")
            }
            val v4 = h.split(".")
            if (v4.size == 4 && v4.all { it.toIntOrNull() in 0..255 }) {
                val a = v4[0].toIntOrNull() ?: return false
                val b = v4[1].toIntOrNull() ?: return false
                return a == 10 || a == 127 || (a == 192 && b == 168) ||
                    (a == 172 && b in 16..31) || (a == 169 && b == 254)
            }
            if (!h.contains('.')) return true
            return h.endsWith(".local") || h.endsWith(".lan") ||
                h.endsWith(".home.arpa") || h.endsWith(".localdomain")
        }
}

enum class EndpointMode {
    /** 并发探测，自动选最快的可用地址 */
    AUTO,
    /** 固定使用 pinnedEndpointIndex */
    MANUAL
}

/**
 * 把一个输入框里的多行地址拆成端点列表。
 *
 * 设置页里「流量统计面板 / 音乐服务」都只给一个多行输入框：一行内网 IP、一行公网域名，
 * App 每次连之前先探测，谁通就用谁 —— 在家走内网、在外面走域名，不用手动切。
 * 空行和以 # 开头的注释行会被忽略。
 */
fun parseEndpoints(text: String): List<Endpoint> =
    text.lineSequence()
        .map { it.trim() }
        .filter { it.isNotEmpty() && !it.startsWith("#") }
        .map { raw -> Endpoint(host = raw, port = 0).normalized() }
        .filter { it.isValid }
        .distinctBy { it.hostKey() }
        .toList()

/** 设置页右侧那行摘要：第一条地址 + 还有几条 */
fun summarizeEndpoints(text: String): String {
    val list = parseEndpoints(text)
    if (list.isEmpty()) return "未配置"
    val first = list.first().display.substringAfter("://")
    return if (list.size <= 1) first else "$first +${list.size - 1}"
}

@Serializable
data class ServerConfig(
    val id: String = UUID.randomUUID().toString(),
    val name: String = "",
    val type: ServerType = ServerType.QBITTORRENT,
    val endpoints: List<Endpoint> = emptyList(),
    val username: String = "",
    val password: String = "",
    /** qBittorrent 5.2+ 的 API Key，走 Bearer 认证，不需要用户名 */
    val apiKey: String = "",
    val useApiKey: Boolean = false,
    val rpcPath: String = "/transmission/rpc",
    val endpointMode: EndpointMode = EndpointMode.AUTO,
    val pinnedEndpointIndex: Int = 0,
    val hidden: Boolean = false
) {
    val displayName: String
        get() = name.ifBlank { type.label }

    val activeEndpoints: List<Endpoint>
        get() = endpoints.filter { it.enabled && it.isValid }
}

enum class TorrentStatus(val label: String) {
    DOWNLOADING("下载中"),
    QUEUED("排队中"),
    SEEDING("做种中"),
    PAUSED("已暂停"),
    CHECKING("校验中"),
    ERROR("错误"),
    COMPLETED("已完成");

    /** 中国习惯：做种/完成用绿色，下载用蓝色，错误红色 */
    val accentArgb: Long
        get() = when (this) {
            DOWNLOADING -> 0xFF0A84FF
            QUEUED -> 0xFF5E5CE6
            SEEDING -> 0xFF34C759
            PAUSED -> 0xFF8E8E93
            CHECKING -> 0xFFFF9500
            ERROR -> 0xFFFF3B30
            COMPLETED -> 0xFF8E8E93
        }
}

data class ResolutionBadge(val text: String, val argb: Long)

data class TorrentTask(
    val hash: String,
    val serverId: String,
    val serverType: ServerType,
    val name: String,
    val progress: Double,
    val size: Long,
    val downloaded: Long,
    val uploaded: Long,
    val downloadSpeed: Long,
    val uploadSpeed: Long,
    val status: TorrentStatus,
    val etaSeconds: Long,
    val ratio: Double,
    val numSeeds: Int,
    val totalSeeds: Int,
    val numPeers: Int,
    val totalPeers: Int,
    val category: String,
    val tags: List<String>,
    val savePath: String,
    val trackerHost: String,
    val addedAt: Long,
    val completedAt: Long,
    val seedingSeconds: Long,
    val errorMessage: String,
    val isSequential: Boolean = false,
    val availability: Double = 0.0,
    /** 单任务下载/上传限速（bytes/s，0 = 不限速），来自 tr 的 downloadLimit / qb 的 dl_limit */
    val downloadLimit: Long = 0L,
    val uploadLimit: Long = 0L,
    /**
     * 分享率设置：-2 = 跟随全局、-1 = 无限、0 = 自定义（具体值看 [ratioLimit]）。
     * tr 的 seedRatioMode 是 0/1/2，qb 的 ratio_limit 是 -2/-1/数值，这里统一成一套语义。
     */
    val ratioMode: Int = -2,
    val ratioLimit: Double = 0.0
) {
    val id: String get() = "$serverId:$hash"

    val isFinished: Boolean get() = progress >= 0.9999

    val taxonomyTags: List<String>
        get() = buildList {
            if (serverType == ServerType.QBITTORRENT && category.isNotBlank()) {
                add(category)
                addAll(tags.take(1))
            } else {
                addAll(tags.take(2))
            }
        }.take(2)

    val hiddenTaxonomyCount: Int
        get() {
            val categoryCount = if (serverType == ServerType.QBITTORRENT && category.isNotBlank()) 1 else 0
            return (categoryCount + tags.size - 2).coerceAtLeast(0)
        }
}

/** 单台服务器的汇总数据 */
data class ServerSnapshot(
    val serverId: String,
    val online: Boolean,
    val error: String? = null,
    val downloadSpeed: Long = 0,
    val uploadSpeed: Long = 0,
    val seedingCount: Int = 0,
    val downloadingCount: Int = 0,
    val seedingSize: Long = 0,
    val totalUploaded: Long = 0,
    val totalDownloaded: Long = 0,
    /**
     * 本次快照是否拿到了「下载器全量累计计数器」（qb alltime_dl/ul、tr cumulative-stats）。
     *
     * 流量账本只能拿这种全量计数器做基线；临时失败时退而求其次算出来的「任务累计和」
     * 口径完全不同，一旦拿来当基线，下一次读到全量值就会把装机总流量算成今天/本月。
     */
    val cumulativeReliable: Boolean = false,
    val freeSpace: Long = 0,
    val appVersion: String = "",
    val endpointLabel: String = "",
    /** 备用（计划）限速是否开启：tr 看 session-get 的 alt-speed-enabled，qb 看 speedLimitsMode */
    val altSpeedEnabled: Boolean = false,
    /**
     * 这次快照是否**真的读到**了备用限速状态。读不到（超时 / 接口报错）时不能当成「已关闭」，
     * 否则一次失败请求就会把顶栏图标刷成常规色，下一轮又变回橙色 —— 看起来就是「颜色经常不对」。
     */
    val altSpeedKnown: Boolean = false,
    /** 下载器默认保存目录：新任务页面拿它做默认值，比让用户手打省事 */
    val defaultSavePath: String = ""
) {
    val ratio: Double
        get() = if (totalDownloaded > 0) totalUploaded.toDouble() / totalDownloaded else 0.0
}
