package com.moviepilottools.mptools.data

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs

private val UNITS = arrayOf("B", "KB", "MB", "GB", "TB", "PB")

/** 1024 进制，和 iOS 版 ByteCountFormatter(countStyle = .binary) 对齐 */
fun formatBytes(bytes: Long): String {
    if (bytes <= 0) return "0 B"
    var value = bytes.toDouble()
    var unit = 0
    while (value >= 1024.0 && unit < UNITS.size - 1) {
        value /= 1024.0
        unit++
    }
    return if (unit == 0) {
        "${value.toLong()} B"
    } else {
        String.format(Locale.US, "%.2f %s", value, UNITS[unit])
    }
}

/** 存储容量：>=100 不保留小数，>=10 留 1 位，其余 2 位（照抄原版 formatStorageSize） */
fun formatStorageSize(bytes: Long): String {
    if (bytes <= 0) return "0 B"
    val gb = 1024.0 * 1024 * 1024
    val tb = gb * 1024
    val pb = tb * 1024
    val value = bytes.toDouble()
    return when {
        value >= pb -> fixedByMagnitude(value / pb, "PB")
        value >= tb -> fixedByMagnitude(value / tb, "TB")
        else -> formatBytes(bytes)
    }
}

private fun fixedByMagnitude(value: Double, unit: String): String {
    val decimals = when {
        value >= 100 -> 0
        value >= 10 -> 1
        else -> 2
    }
    return String.format(Locale.US, "%.${decimals}f %s", value, unit)
}

fun formatSpeed(bytesPerSecond: Long): String = "${formatBytes(bytesPerSecond)}/s"

/**
 * 种子名常是「[字幕组] The.Silent.Storm.2026.S01.2160p.60fps...」这种无空格长串，
 * Compose 默认按词断行会把整串推到下一行，导致首行只剩几个字。
 * 在每个字符后插入零宽空格（U+200B）制造合法断点，效果等同鸿蒙的 WordBreak.BREAK_ALL。
 * 只用于显示：徽章识别 / 内容描述 / 搜索仍用原 name，不受影响。
 */
fun breakableName(name: String): String {
    if (name.length < 12) return name
    val sb = StringBuilder(name.length * 2)
    for (ch in name) {
        sb.append(ch)
        sb.append('\u200B')
    }
    return sb.toString()
}

fun formatRatio(ratio: Double): String = String.format(Locale.US, "%.2f", ratio)

fun formatPercent(progress: Double): String = "${(progress * 100).toInt()}%"

/** 20天21小时1分 这种中文时长 */
fun formatDurationCN(seconds: Long): String {
    if (seconds <= 0) return "0分"
    val totalMinutes = seconds / 60
    val days = totalMinutes / (24 * 60)
    val hours = (totalMinutes % (24 * 60)) / 60
    val minutes = totalMinutes % 60
    return buildString {
        if (days > 0) append("${days}天")
        if (hours > 0) append("${hours}小时")
        append("${minutes}分")
    }
}

fun formatDateTime(epochMillis: Long): String {
    if (epochMillis <= 0) return "--"
    return SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(epochMillis))
}

/** 解析 "DEAD TO RIGHTS 2025 2160p WEB-DL H.265" 里的分辨率标签 */
fun extractResolutionBadge(title: String): ResolutionBadge? {
    val upper = title.uppercase(Locale.US)
    return when {
        Regex("\\b(4320P|8K)\\b").containsMatchIn(upper) -> ResolutionBadge("8K", 0xFFAF52DE)
        Regex("\\b(2160P|4K|UHD)\\b").containsMatchIn(upper) -> ResolutionBadge("4K", 0xFFAF52DE)
        Regex("\\b1440P\\b").containsMatchIn(upper) -> ResolutionBadge("1440p", 0xFF5856D6)
        Regex("\\b1080P\\b").containsMatchIn(upper) -> ResolutionBadge("1080p", 0xFF0A84FF)
        Regex("\\b720P\\b").containsMatchIn(upper) -> ResolutionBadge("720p", 0xFF34C759)
        Regex("\\b576P\\b").containsMatchIn(upper) -> ResolutionBadge("576p", 0xFF8E8E93)
        Regex("\\b480P\\b").containsMatchIn(upper) -> ResolutionBadge("480p", 0xFF8E8E93)
        else -> null
    }
}

/** tracker 地址只留域名，跟截图里 🔗 后面一致 */fun trackerHostOf(raw: String): String {
    if (raw.isBlank()) return ""
    return raw
        .substringAfter("://", raw)
        .substringBefore("/")
        .substringBefore("?")
        .substringAfter("@")
        .removeSuffix("/")
}

fun percentColor(progress: Double, status: TorrentStatus): Long = when {
    status == TorrentStatus.ERROR -> 0xFFFF3B30
    progress >= 0.9999 -> 0xFF34C759
    else -> 0xFF0A84FF
}

fun humanEta(seconds: Long): String {
    if (seconds <= 0 || seconds >= 8640000L) return "∞"
    val h = seconds / 3600
    val m = (seconds % 3600) / 60
    val s = seconds % 60
    return when {
        h > 0 -> "${h}h ${m}m"
        m > 0 -> "${m}m ${s}s"
        else -> "${abs(s)}s"
    }
}

/** 相对时间：刚刚 / 12 分钟前 / 3 小时前 / 2 天前 / 日期 */
fun formatRelativeTime(epochMillis: Long): String {
    if (epochMillis <= 0) return "--"
    val diff = System.currentTimeMillis() - epochMillis
    if (diff < 0) return formatDateTime(epochMillis).take(16)
    val minutes = diff / 60000
    return when {
        minutes < 1 -> "刚刚"
        minutes < 60 -> "${minutes} 分钟前"
        minutes < 60 * 24 -> "${minutes / 60} 小时前"
        minutes < 60 * 24 * 7 -> "${minutes / (60 * 24)} 天前"
        else -> SimpleDateFormat("MM-dd HH:mm", Locale.US).format(Date(epochMillis))
    }
}
