package com.moviepilottools.mptools.net

/**
 * 海报地址归一化。
 *
 * MoviePilot 返回的 poster 字段有三种形态：
 *  1. 完整地址：`https://img9.doubanio.com/view/photo/...`（豆瓣源最常见）
 *  2. 相对路径：`/p2912345.jpg`（TMDB 源的 poster_path）
 *  3. MP 自己的接口：`/api/v1/media/xxx/image`
 *
 * 老逻辑把所有非 http 开头的一律拼成 `image.tmdb.org/t/p/w500`，
 * 结果豆瓣的 `/view/photo/...` 被拼成 `image.tmdb.org/t/p/w500/view/photo/...`，
 * 必然 404/418，海报全空。这里按 iOS 版（DoubanImageURLNormalizer +
 * MoviePilotDiscoveryViewModel.completedPosterURLString）的规则对齐。
 */
object PosterUrl {

    private const val TMDB_BASE = "https://image.tmdb.org/t/p/w500"
    private const val DOUBAN_BASE = "https://img9.doubanio.com"

    /** 豆瓣图床必须带的请求头（详见 DoubanImageHeaderInterceptor） */
    const val DOUBAN_REFERER = "https://movie.douban.com/"

    /**
     * @param raw   MP 返回的原始 poster / poster_path / backdrop_path
     * @param source MP 的 media_source：douban / tmdb / bangumi …
     * @param mediaServerBase 当前选中的 MP 地址，用于还原 `/api/...` 相对路径
     */
    fun normalize(raw: String, source: String? = null, mediaServerBase: String? = null): String {
        val value = raw.trim()
        if (value.isEmpty()) return ""

        val lower = value.lowercase()

        // 1) 已是完整地址：只把豆瓣的 http 升级成 https
        if (lower.startsWith("http://")) {
            return if (lower.contains("doubanio.com") || lower.contains("douban.com")) {
                "https://" + value.substring(7)
            } else {
                value
            }
        }
        if (lower.startsWith("https://")) return value

        // 2) 协议相对
        if (value.startsWith("//")) return "https:$value"

        // 3) 缺协议的豆瓣绝对地址
        if (lower.contains("doubanio.com")) return "https://" + value.trim('/')

        val path = if (value.startsWith("/")) value else "/$value"
        val normalizedSource = source?.lowercase().orEmpty()

        // 4) MP 自己的接口要走服务器地址，不能塞给 TMDB
        if (path.startsWith("/api/")) {
            val base = mediaServerBase?.trim()?.trimEnd('/')
            return if (!base.isNullOrEmpty()) "$base$path" else path
        }

        // 5) 豆瓣路径：/view/photo/s_ratio_poster/public/p2912xxx.jpg
        if (normalizedSource == "douban" || lower.contains("douban")) {
            return DOUBAN_BASE + path
        }

        // 6) TMDB 相对路径
        if (normalizedSource == "tmdb" || normalizedSource == "themoviedb") {
            return TMDB_BASE + path
        }

        // 7) 来源未知（订阅、老接口）：TMDB 的相对路径最常见，兜底它
        return TMDB_BASE + path
    }

    fun isDouban(url: String): Boolean {
        val host = runCatching { java.net.URI(url).host }.getOrNull()?.lowercase() ?: return false
        return host.contains("doubanio.com")
    }
}
