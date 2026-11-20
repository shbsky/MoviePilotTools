package com.oiiqt.android.data

/**
 * RSS 规则引擎，逐条对齐 iOS 原版 `RSSRuleEngine.swift` 的行为：
 * 1) 包含关键词必须全部命中；2) 排除关键词任一命中即淘汰；
 * 3) 体积区间（RSS 未给体积时跳过）；4) 集数过滤（支持范围、空格分隔、分号或）。
 */
object RssRuleEngine {

    fun matches(item: RssItemRecord, source: RssSource): Boolean {
        val title = item.title.lowercase()

        if (source.includeKeywords.isNotEmpty()) {
            for (keyword in source.includeKeywords) {
                val k = keyword.trim().lowercase()
                if (k.isEmpty()) continue
                if (!title.contains(k)) return false
            }
        }

        if (source.excludeKeywords.isNotEmpty()) {
            for (keyword in source.excludeKeywords) {
                val k = keyword.trim().lowercase()
                if (k.isEmpty()) continue
                if (title.contains(k)) return false
            }
        }

        if (item.sizeBytes > 0) {
            val gb = item.sizeBytes / 1024.0 / 1024.0 / 1024.0
            source.minSizeGB?.let { if (gb < it) return false }
            source.maxSizeGB?.let { if (gb > it) return false }
        }

        val filter = source.episodeFilter.trim()
        if (filter.isNotEmpty() && !matchesEpisodeFilter(item.title, filter)) return false

        return true
    }

    /** 命中原因，给「规则预览」用 */
    fun explain(item: RssItemRecord, source: RssSource): String? {
        if (!matches(item, source)) return null
        return buildList {
            if (source.includeKeywords.isNotEmpty()) add("关键词命中")
            if (item.sizeBytes > 0) add(com.oiiqt.android.data.formatBytes(item.sizeBytes))
            if (source.episodeFilter.isNotBlank()) add("集数命中")
        }.joinToString(" · ").ifBlank { "全部满足" }
    }

    // ---------- 集数 ----------

    private data class Marker(val season: Int?, val episode: Int)

    private sealed interface EpisodeRule {
        data class Single(val marker: Marker) : EpisodeRule
        data class Range(val start: Marker, val end: Marker) : EpisodeRule
    }

    private fun matchesEpisodeFilter(title: String, rawFilter: String): Boolean {
        val normalized = rawFilter.replace(Regex("(?i)\\bor\\b"), ";").trim()
        val rules = mutableListOf<EpisodeRule>()

        for (part in normalized.split(";")) {
            val text = part.trim()
            if (text.isEmpty()) continue
            val candidates = if (text.contains("-")) listOf(text) else text.split(Regex("\\s+"))
            for (candidate in candidates) {
                parseEpisodeRule(candidate)?.let { rules += it }
            }
        }

        if (rules.isEmpty()) return true // 规则写错时不改变原有行为

        val marker = extractEpisodeMarker(title) ?: return false
        return rules.any { matches(it, marker) }
    }

    private fun extractEpisodeMarker(title: String): Marker? {
        Regex("(?i)\\bS(\\d{1,2})[ ._-]?E(\\d{1,3})\\b").find(title)?.let { m ->
            val season = m.groupValues[1].toIntOrNull()
            val episode = m.groupValues[2].toIntOrNull()
            if (season != null && episode != null) return Marker(season, episode)
        }
        Regex("(?i)\\bE(?:P)?[ ._-]?(\\d{1,3})\\b").find(title)?.let { m ->
            m.groupValues[1].toIntOrNull()?.let { return Marker(null, it) }
        }
        Regex("(?i)(?:\\s-\\s|\\s)(\\d{1,3})(?=\\s*[\\(\\[]|$)").find(title)?.let { m ->
            m.groupValues[1].toIntOrNull()?.let { return Marker(null, it) }
        }
        return null
    }

    private fun parseEpisodeRule(text: String): EpisodeRule? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.contains("-")) {
            val parts = trimmed.split("-", limit = 2)
            if (parts.size == 2) {
                val start = parseMarker(parts[0], null)
                val end = parseMarker(parts[1], start?.season)
                if (start != null && end != null) return EpisodeRule.Range(start, end)
            }
        }
        val marker = parseMarker(trimmed, null) ?: return null
        return EpisodeRule.Single(marker)
    }

    private fun parseMarker(text: String, inheritedSeason: Int?): Marker? {
        val normalized = text.trim().uppercase()
        if (normalized.isEmpty()) return null
        Regex("^S(\\d{1,2})E(\\d{1,3})$").find(normalized)?.let { m ->
            val season = m.groupValues[1].toIntOrNull()
            val episode = m.groupValues[2].toIntOrNull()
            if (season != null && episode != null) return Marker(season, episode)
        }
        Regex("^E?(\\d{1,3})$").find(normalized)?.let { m ->
            m.groupValues[1].toIntOrNull()?.let { return Marker(inheritedSeason, it) }
        }
        return null
    }

    private fun matches(rule: EpisodeRule, item: Marker): Boolean = when (rule) {
        is EpisodeRule.Single -> {
            val season = rule.marker.season
            (season == null || item.season == season) && item.episode == rule.marker.episode
        }

        is EpisodeRule.Range -> {
            val start = rule.start
            val end = rule.end
            val rangeSeason = start.season ?: end.season
            if (rangeSeason != null && item.season != rangeSeason) {
                false
            } else if (start.season != null && end.season != null && start.season != end.season) {
                false // 暂不支持跨季区间
            } else {
                val lower = minOf(start.episode, end.episode)
                val upper = maxOf(start.episode, end.episode)
                item.episode in lower..upper
            }
        }
    }
}
