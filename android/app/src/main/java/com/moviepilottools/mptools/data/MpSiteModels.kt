package com.moviepilottools.mptools.data

import java.text.SimpleDateFormat
import java.util.Locale

/**
 * MoviePilot 后台配置的一个站点（`GET api/v1/site/`）。
 *
 * App 里**只读**同步：站点的登录、Cookie、分类映射、限流全在 MP 服务端，
 * 增删改一律去 MP 后台做，这里不提供写入入口。
 */
data class MpSite(
    val id: Int,
    val name: String,
    val domain: String = "",
    val url: String = "",
    /** 优先级，MP 里越小越先搜 */
    val pri: Int = 0,
    val isActive: Boolean = true,
    /** 该站绑定的下载器，空表示用默认 */
    val downloader: String = "",
    val note: String = ""
) {
    /** 展示用域名：优先 domain，空则从 url 里抠 */
    val displayDomain: String
        get() {
            domain.trim().takeIf { it.isNotBlank() }?.let { return it }
            val raw = url.trim()
            if (raw.isEmpty()) return ""
            val noScheme = raw.substringAfter("://", raw)
            return noScheme.substringBefore('/').substringBefore('?')
        }

    val initial: String
        get() = name.trim().take(1).uppercase().ifBlank { "#" }

    /**
     * 与 `SiteUserData.domain` 做匹配用的键。
     *
     * MP 里站点 domain 与 userdata.domain 基本一致，但可能一边带 www、一边大小写不同，
     * 所以统一抹平后再比；匹配不上只会让那张卡少显示个人数据，不会出错。
     */
    val matchKeys: List<String>
        get() {
            val raw = mutableListOf(domain, displayDomain)
            url.trim().takeIf { it.isNotBlank() }?.let { raw += it }
            return raw.map { key ->
                key.trim().lowercase()
                    .removePrefix("https://")
                    .removePrefix("http://")
                    .removePrefix("www.")
                    .trimEnd('/')
            }.filter { it.isNotBlank() }.distinct()
        }
}

/**
 * 站点个人数据（`GET api/v1/site/userdata/latest`）。
 *
 * 这是 MP 服务端定期去站点抓的数据（不是实时），所以带 `updated_*`，
 * 太久没更新时要提示用户 —— 数字可能已经是几天前的了。
 */
data class MpSiteUserData(
    val domain: String = "",
    /** MP 侧的站点名称，域名对不上时拿它做兜底匹配 */
    val name: String = "",
    val username: String = "",
    val userLevel: String = "",
    val joinAt: String = "",
    /** 魔力值 / 积分 */
    val bonus: Double = 0.0,
    val upload: Long = 0,
    val download: Long = 0,
    val ratio: Double = 0.0,
    val seeding: Int = 0,
    val leeching: Int = 0,
    val seedingSize: Long = 0,
    val leechingSize: Long = 0,
    val messageUnread: Int = 0,
    val messageTotal: Int = 0,
    /** 站点抓取失败时 MP 会把原因写在这里（登录失效最常见） */
    val errMsg: String = "",
    val updatedDay: String = "",
    val updatedTime: String = ""
) {
    val hasError: Boolean get() = errMsg.isNotBlank()

    val ratioText: String get() = String.format(Locale.US, "%.2f", ratio)

    /** 数据日期原文里真正能用的那一份 */
    private val stamp: String
        get() = updatedTime.trim().ifBlank { updatedDay.trim() }

    /** 「更新 11-16」；拿不到日期就返回空串，卡片上不占位 */
    val updatedText: String
        get() {
            val raw = stamp
            if (raw.isBlank()) return ""
            val text = raw.replace('T', ' ')
            val monthDay = Regex("""(\d{4})-(\d{2})-(\d{2})""").find(text)
            if (monthDay != null) {
                return "更新 ${monthDay.groupValues[2]}-${monthDay.groupValues[3]}"
            }
            return "更新 ${text.take(10)}"
        }

    /** 距今天数；解析不出来返回 -1（当作「不知道」，不标黄） */
    val staleDays: Int
        get() {
            val raw = stamp
            if (raw.isBlank()) return -1
            val normalized = raw.replace('T', ' ').take(19)
            val patterns = listOf("yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd")
            val time = patterns.firstNotNullOfOrNull { pattern ->
                runCatching {
                    SimpleDateFormat(pattern, Locale.US).parse(normalized)?.time
                }.getOrNull()
            } ?: return -1
            val diff = System.currentTimeMillis() - time
            return (diff / 86_400_000L).toInt().coerceAtLeast(0)
        }

    val isStale: Boolean get() = staleDays > 3
}

/** 站点分类（`GET api/v1/site/category/{id}`）。各站分类完全不同，全部由接口驱动。 */
data class MpSiteCategory(
    /**
     * MP 里的分类标识（数字或文本，比如某些站点的 `419`）。
     *
     * **请求 `cat=` 参数传的必须是它**：MP 的站点索引器拿这个值去拼站点搜索参数。
     * 之前传的是 [cat]（`Movie(電影)` 这种分类组名），站点根本不认，结果永远「这个分类下没有种子」。
     * 用 String 而不是 Int：MP 的分类标识既可能是数字也可能是文本。
     */
    val id: String = "",
    /** 分类组名，只用来展示 */
    val cat: String = "",
    /** 完整分类名，只用来展示 */
    val desc: String = ""
) {
    /** 兜底：把字面量 `"null"` 也当成空（Android 的 optString 会把 JSON null 读成 "null"） */
    private fun String.clean(): String = trim().let { if (it.equals("null", true)) "" else it }

    /** 发给 MP 的值 */
    val value: String get() = id.clean().ifBlank { cat.clean().ifBlank { desc.clean() } }

    /** 给用户看：desc 最具体（`Movie(電影)/SD`），其次 cat */
    val label: String get() = desc.clean().ifBlank { cat.clean().ifBlank { id.clean() } }
}

/**
 * 站点种子列表的排序方式 —— 对齐 MoviePilot 网页版「浏览」弹窗右侧那四个选项。
 *
 * MP 的 `site/resource/{id}` **没有** sort 参数（服务端只按站点默认顺序返回），
 * 所以这里全部是**客户端排序**：只对已经翻下来的那几页生效，不会重新请求站点
 * （重排等于让 MP 再爬一遍站点，几十秒起步，体验反而更差）。
 */
enum class SiteSort(val label: String) {
    LATEST("最新发布"),
    SIZE("资源大小"),
    SEEDERS("做种最多"),
    GRABS("下载最多");

    fun apply(list: List<MpResource>): List<MpResource> = when (this) {
        LATEST -> list.sortedByDescending { it.pubDateMs }
        SIZE -> list.sortedByDescending { it.sizeBytes }
        SEEDERS -> list.sortedByDescending { it.seeders }
        GRABS -> list.sortedByDescending { it.grabs }
    }
}

/** 把站点列表按优先级+名字排好：停用的沉底，同优先级按名字 */
fun List<MpSite>.sortedForDisplay(): List<MpSite> = sortedWith(
    compareByDescending<MpSite> { it.isActive }
        .thenBy { it.pri }
        .thenBy { it.name.lowercase() }
)
