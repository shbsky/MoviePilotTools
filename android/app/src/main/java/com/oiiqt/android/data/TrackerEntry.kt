package com.oiiqt.android.data

/**
 * 一条 Tracker（qBittorrent / Transmission 归一化后）。
 *
 * 两家的字段名和状态编码完全不同：
 * - qB `torrents/trackers` 直接给 status(0~4)、tier、num_peers/num_seeds/num_leeches；
 * - tr `torrent-get` 的 trackerStats 给 announce / lastAnnounceSucceeded / seederCount…，
 *   没有 status 字段，只能按「上次汇报是否成功 + 有没有汇报结果文案」推断。
 * 这里统一成 [Status] 的五档，UI 只管按 status 上色。
 */
data class TrackerEntry(
    val url: String,
    val status: Int = Status.UNKNOWN,
    val tier: Int = 0,
    /** Transmission 的 tracker id，改 / 删都要用它；qB 没有这个概念，恒为 -1 */
    val trackerId: Int = -1,
    val seeds: Int = 0,
    val leeches: Int = 0,
    val peers: Int = 0,
    val message: String = ""
) {
    /**
     * qB 会在同一个接口里回 DHT / PEX / LSD 三条伪 Tracker（URL 形如 `** [DHT] **`），
     * 它们不是真 Tracker，改不了也不该出现在编辑列表里。
     */
    val special: Boolean get() = url.startsWith("**")

    val host: String get() = trackerHostOf(url)

    val statusText: String
        get() = when (status) {
            Status.DISABLED -> "已停用"
            Status.NOT_CONTACTED -> "未联系"
            Status.WORKING -> "工作中"
            Status.UPDATING -> "更新中"
            Status.NOT_WORKING -> "不工作"
            else -> "未知"
        }

    object Status {
        const val UNKNOWN = -1
        const val DISABLED = 0
        const val NOT_CONTACTED = 1
        const val WORKING = 2
        const val UPDATING = 3
        const val NOT_WORKING = 4
    }
}
