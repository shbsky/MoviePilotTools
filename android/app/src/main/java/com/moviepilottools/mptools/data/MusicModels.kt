package com.moviepilottools.mptools.data

/**
 * Songloft 音乐服务的本地模型。
 *
 * 服务端字段是 snake_case（`cover_url` / `file_path` / `bit_rate`），这里统一转成 Kotlin 风格，
 * 解析时对大小写两种写法都兼容（见 SongloftClient）。
 */
data class MusicSong(
    val id: Long,
    val title: String,
    val artist: String,
    val album: String,
    val durationSeconds: Int,
    /** 已归一化成绝对地址（相对路径会补上服务器前缀） */
    val streamUrl: String,
    val coverUrl: String,
    val format: String,
    val bitRate: Int,
    val isVideo: Boolean
) {
    val durationText: String
        get() = formatDuration(durationSeconds)
}

data class MusicPlaylist(
    val id: Long,
    val name: String,
    val description: String,
    val songCount: Int,
    val coverUrl: String,
    val type: String
)

data class MusicLibraryStats(
    val totalSongs: Int = 0,
    val artistCount: Int = 0,
    val albumCount: Int = 0,
    val totalDuration: Long = 0L
)

/** 音乐页整体状态 */
data class MusicUiState(
    val configured: Boolean = false,
    val serverLabel: String = "",
    val songs: List<MusicSong> = emptyList(),
    val total: Int = 0,
    val loading: Boolean = false,
    val loadingMore: Boolean = false,
    val error: String? = null,
    val stats: MusicLibraryStats? = null,
    val playlists: List<MusicPlaylist> = emptyList(),
    val playlistsLoading: Boolean = false,
    val searchActive: Boolean = false,
    val query: String = "",
    /** 正在查看的歌单，null = 全部歌曲 */
    val playlist: MusicPlaylist? = null,
    val playlistSongs: List<MusicSong> = emptyList(),
    val playlistLoading: Boolean = false,
    /** 已收藏歌曲 id 集合（服务端内建「收藏」歌单），红心标记用 */
    val favoriteIds: Set<Long> = emptySet(),
    val toast: String? = null
) {
    val visibleSongs: List<MusicSong>
        get() = if (playlist == null) songs else playlistSongs
}

/** 播放器状态（迷你条 + 全屏页都用它） */
data class PlaybackState(
    val current: MusicSong? = null,
    val isPlaying: Boolean = false,
    val positionMs: Long = 0L,
    val durationMs: Long = 0L,
    val hasPrevious: Boolean = false,
    val hasNext: Boolean = false,
    /** 本机播放音量 0f..1f（和系统媒体音量叠加） */
    val volume: Float = 1f,
    /** 播放模式：0 = 顺序（播完即停），1 = 单曲循环，2 = 列表循环，3 = 随机播放 */
    val repeatMode: Int = 0,
    /** 投送目标设备名；null = 本机扬声器 */
    val castingTo: String? = null,
    val error: String? = null
) {
    val progress: Float
        get() = if (durationMs <= 0L) 0f else (positionMs.toFloat() / durationMs).coerceIn(0f, 1f)
}

fun formatDuration(seconds: Int): String {
    if (seconds <= 0) return "--:--"
    val m = seconds / 60
    val s = seconds % 60
    return "%d:%02d".format(m, s)
}

fun formatDurationMs(ms: Long): String = formatDuration((ms / 1000).toInt())
