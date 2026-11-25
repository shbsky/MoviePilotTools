package com.moviepilottools.mptools.vm

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.moviepilottools.mptools.data.MusicPlaylist
import com.moviepilottools.mptools.data.MusicSong
import com.moviepilottools.mptools.data.MusicUiState
import com.moviepilottools.mptools.net.SongloftClient
import com.moviepilottools.mptools.net.SongloftSession
import com.moviepilottools.mptools.player.MusicEngine
import com.moviepilottools.mptools.player.MusicPlayer
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope

/**
 * 音乐页 ViewModel：管 Songloft 的登录态、歌曲/歌单列表、分页与搜索，
 * 播放本身交给 [MusicPlayer]（它活得比这个 Composable 长，切标签页不会断）。
 */
class MusicViewModel(app: Application) : AndroidViewModel(app) {

    init {
        // 投送开始时 CastController 要用它拉前台服务（锁屏保活，见 CastService）
        CastController.setApplicationContext(app)
    }

    private val _state = MutableStateFlow(MusicUiState())
    val state: StateFlow<MusicUiState> = _state.asStateFlow()

    // 播放器是进程级单例（前台服务也用同一个），ViewModel 重建不会断播
    private val player: MusicPlayer = MusicEngine.player(app)
    val playback = player.state

    /**
     * 界面真正该显示的播放状态：**本机播放和投送合并成一路**。
     *
     * 投送是音箱自己在放，本机播放器是暂停的；如果界面还读 [playback]，
     * 就会出现「点了黄昏，底下还写着上一首、列表也还是上一首红色」的错位。
     */
    private val _now = MutableStateFlow(com.moviepilottools.mptools.data.PlaybackState())
    val now: StateFlow<com.moviepilottools.mptools.data.PlaybackState> = _now.asStateFlow()

    init {
        viewModelScope.launch {
            combine(player.state, CastController.state) { local, cast -> merge(local, cast) }
                .collect { _now.value = it }
        }
    }

    private fun merge(
        local: com.moviepilottools.mptools.data.PlaybackState,
        cast: CastController.CastState
    ): com.moviepilottools.mptools.data.PlaybackState {
        val device = cast.active ?: return local.copy(castingTo = null)
        val song = cast.queue.getOrNull(cast.index)
        return com.moviepilottools.mptools.data.PlaybackState(
            current = song ?: local.current,
            isPlaying = cast.playing,
            positionMs = cast.positionMs,
            durationMs = cast.durationMs.takeIf { it > 0L }
                ?: (song?.durationSeconds?.times(1000L) ?: 0L),
            hasPrevious = cast.hasPrevious,
            hasNext = cast.hasNext,
            volume = if (cast.volume >= 0) cast.volume / 100f else local.volume,
            repeatMode = local.repeatMode,
            castingTo = device.name,
            error = null
        )
    }

    private var client: SongloftClient? = null
    private var configKey: String = ""
    private var loadJob: Job? = null
    private var pagingJob: Job? = null

    private val pageSize = 60

    // ------------------------------------------------------------ 配置

    /** 设置页改了地址/账号后由界面调用；同配置不重复拉数据 */
    fun configure(url: String, user: String, pass: String) {
        val key = "$url|$user|$pass"
        if (key == configKey) return
        configKey = key
        loadJob?.cancel()
        pagingJob?.cancel()

        val candidate = SongloftClient(url, user, pass)
        if (!candidate.isConfigured) {
            client = null
            SongloftSession.reset()
            _state.value = MusicUiState(configured = false)
            return
        }
        client = candidate
        player.urlResolver = { song -> candidate.playableUrl(song) }
        _state.value = MusicUiState(configured = true, serverLabel = candidate.label(), loading = true)
        load()
    }

    fun refresh() {
        if (client == null) return
        load(force = true)
    }

    // ------------------------------------------------------------ 拉数据

    private fun load(force: Boolean = false) {
        val client = client ?: return
        loadJob?.cancel()
        _state.value = _state.value.copy(loading = true, error = null)
        loadJob = viewModelScope.launch {
            // 三个请求并发，但**任何一个失败都不能冒泡**：
            // viewModelScope 是主线程作用域，async 子协程的异常会取消父协程并交给
            // 默认 CoroutineExceptionHandler → 主线程未捕获异常 → App 直接闪退。
            // （v1.3.0 就是因为 Songloft 返回「登录过于频繁」把 App 打成闪退循环）
            // supervisorScope + 每个 async 内部 runCatching，双保险。
            supervisorScope {
                val songsDeferred = async { runCatching { client.songs(limit = pageSize, offset = 0) } }
                val playlistsDeferred = async { runCatching { client.playlists() } }
                val statsDeferred = async { runCatching { client.stats() } }
                val favoritesDeferred = async { runCatching { client.favoriteIds() } }

                val songs = songsDeferred.await()
                val playlists = playlistsDeferred.await().getOrDefault(emptyList())
                val stats = statsDeferred.await().getOrNull()
                val favorites = favoritesDeferred.await().getOrNull()

                songs.onSuccess { page ->
                    _state.value = _state.value.copy(
                        loading = false,
                        error = null,
                        songs = page.songs,
                        total = page.total,
                        playlists = playlists,
                        stats = stats,
                        playlistsLoading = false,
                        favoriteIds = favorites ?: _state.value.favoriteIds
                    )
                }.onFailure { error ->
                    SongloftSession.reportError(error.message.orEmpty())
                    _state.value = _state.value.copy(
                        loading = false,
                        error = friendly(error),
                        playlists = playlists,
                        stats = stats,
                        playlistsLoading = false,
                        favoriteIds = favorites ?: _state.value.favoriteIds
                    )
                }
            }
        }
    }

    fun loadMore() {
        val client = client ?: return
        val current = _state.value
        if (current.playlist != null) return
        if (current.loading || current.loadingMore) return
        if (current.songs.size >= current.total) return

        pagingJob?.cancel()
        _state.value = current.copy(loadingMore = true)
        pagingJob = viewModelScope.launch {
            // 搜索结果同样分页：keyword 一起带上，否则关键词命中超过一页时后面找不出来
            runCatching {
                client.songs(
                    keyword = current.query,
                    offset = current.songs.size,
                    limit = pageSize
                )
            }
                .onSuccess { page ->
                    val merged = (_state.value.songs + page.songs).distinctBy { it.id }
                    _state.value = _state.value.copy(
                        loadingMore = false,
                        songs = merged,
                        total = maxOf(page.total, merged.size)
                    )
                }
                .onFailure { _state.value = _state.value.copy(loadingMore = false) }
        }
    }

    // ------------------------------------------------------------ 搜索

    fun startSearch() {
        _state.value = _state.value.copy(searchActive = true, playlist = null)
    }

    fun exitSearch() {
        _state.value = _state.value.copy(searchActive = false, query = "")
        load(force = true)
    }

    fun search(keyword: String) {
        val client = client ?: return
        val trimmed = keyword.trim()
        _state.value = _state.value.copy(query = trimmed, loading = true, error = null, playlist = null)
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            runCatching { client.songs(keyword = trimmed, limit = pageSize, offset = 0) }
                .onSuccess { page ->
                    _state.value = _state.value.copy(
                        loading = false,
                        songs = page.songs,
                        total = page.total
                    )
                }
                .onFailure { _state.value = _state.value.copy(loading = false, error = friendly(it)) }
        }
    }

    // ------------------------------------------------------------ 歌单

    fun openPlaylist(playlist: MusicPlaylist) {
        val client = client ?: return
        _state.value = _state.value.copy(
            playlist = playlist,
            playlistSongs = emptyList(),
            playlistLoading = true,
            searchActive = false,
            query = ""
        )
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            runCatching { client.playlistSongs(playlist.id) }
                .onSuccess { page ->
                    _state.value = _state.value.copy(
                        playlistSongs = page.songs,
                        playlistLoading = false
                    )
                }
                .onFailure {
                    _state.value = _state.value.copy(
                        playlistLoading = false,
                        toast = friendly(it)
                    )
                }
        }
    }

    fun closePlaylist() {
        _state.value = _state.value.copy(playlist = null, playlistSongs = emptyList())
    }

    // ------------------------------------------------------------ 播放

    /**
     * 点歌。
     *
     * 已经在投送状态时，点歌直接推到音箱（并把它所在的整张列表变成投送队列），
     * 不需要再点右上角的投送按钮 —— 这是「点一下就播」的核心逻辑。
     */
    fun playSong(song: MusicSong) {
        val list = _state.value.visibleSongs.ifEmpty { listOf(song) }
        val index = list.indexOfFirst { it.id == song.id }.coerceAtLeast(0)
        val device = CastController.state.value.active
        if (device != null) {
            castTo(device, list, index)
            showToast("投送到「${device.name}」：${song.title}")
            return
        }
        player.play(list, index)
    }

    fun playAll() {
        val list = _state.value.visibleSongs
        if (list.isEmpty()) return
        val device = CastController.state.value.active
        if (device != null) {
            castTo(device, list, 0)
            showToast("把 ${list.size} 首投送到「${device.name}」")
            return
        }
        player.play(list, 0)
    }

    /** 投送时手机这边要静音，否则两边同时出声 */
    private fun castTo(
        device: com.moviepilottools.mptools.net.dlna.DlnaClient.Device,
        list: List<MusicSong>,
        index: Int
    ) {
        val current = client
        if (current == null) {
            showToast("还没配置 Songloft（设置 → 音乐服务）")
            return
        }
        if (playback.value.isPlaying) player.pause()
        CastController.playQueue(
            device = device,
            songs = list,
            startIndex = index,
            urlFor = { current.playableUrl(it) },
            mimeFor = { mimeOf(it) }
        )
    }

    private val casting: Boolean get() = CastController.state.value.casting

    fun togglePlay() {
        // 投送中：本机没有出声，播放键操作的是音箱
        if (casting) CastController.togglePause() else player.toggle()
    }

    /** 音量（0f..1f）：投送中调的是音箱音量，否则是本机音量 */
    fun setVolume(value: Float) {
        val cast = CastController.state.value
        if (cast.active != null) {
            CastController.setVolume((value.coerceIn(0f, 1f) * 100).toInt())
            return
        }
        player.setVolume(value)
    }

    fun next() {
        if (casting) CastController.next() else player.next()
    }

    fun previous() {
        if (casting) CastController.previous() else player.previous()
    }

    fun seekTo(positionMs: Long) {
        if (casting) CastController.seekTo(positionMs) else player.seekTo(positionMs)
    }

    /**
     * 播放模式四档循环：顺序 → 单曲循环 → 列表循环 → 随机 → 顺序。
     * 本机和投送共用同一套模式：本机交给 ExoPlayer（repeatMode + shuffle），
     * 投送则由 CastController 按模式决定播完一首后推哪首。
     */
    fun cycleRepeatMode() {
        val mode = player.cycleRepeatMode()
        CastController.setRepeatMode(mode)
        showToast(
            when (mode) {
                1 -> "单曲循环"
                2 -> "列表循环"
                3 -> "随机播放"
                else -> "顺序播放"
            }
        )
    }

    fun stopPlayback() {
        if (casting) CastController.stopCasting() else player.stop()
    }

    /**
     * 彻底退出播放：停本机、停投送、清当前曲目与队列。
     *
     * 迷你播放条在各标签页常驻，暂停或播完之后它不会自己消失；
     * 迷你条右侧的 × 调这里，关掉之后底部那条就没了。
     */
    fun quitPlayback() {
        if (casting) CastController.stopCasting()
        player.stop()
    }

    // ------------------------------------------------------------ 投送

    /**
     * 把当前这首推到 DLNA 设备播放。
     *
     * 音频地址必须带 access_token（Songloft 的媒体鉴权走查询参数），
     * 音箱自己去拉这个 URL，所以本机播放器不需要暂停 —— 但为了避免两边同时出声，
     * 这里投送成功后会把本机播放暂停。
     */
    fun castCurrent(device: com.moviepilottools.mptools.net.dlna.DlnaClient.Device) {
        val list = _state.value.visibleSongs
        val cast = CastController.state.value
        // 已经在投送中就以「音箱那首」为准，否则用本机正在播的
        val song = if (cast.casting) cast.queue.getOrNull(cast.index) else playback.value.current
        if (list.isEmpty() && song == null) {
            showToast("先在手机上播一首歌，再点投送")
            return
        }
        // 之前这里有个坑：当前这首不在列表里（切过歌单/搜索过）时 index 会被
        // coerceAtLeast(0) 成 0，结果投出去的是列表第一首，跟界面显示的对不上。
        // 现在把当前这首插到队首，再从头播。
        val found = if (song == null) -1 else list.indexOfFirst { it.id == song.id }
        val queue = when {
            list.isEmpty() -> listOfNotNull(song)
            song == null || found >= 0 -> list
            else -> listOf(song) + list
        }
        val start = if (found >= 0) found else 0
        castTo(device, queue, start)
        showToast("正在投送到「${device.name}」…")
    }

    private fun mimeOf(song: MusicSong): String {
        val mime = when (song.format.lowercase()) {
            "flac" -> "audio/flac"
            "wav" -> "audio/wav"
            "aac", "m4a" -> "audio/mp4"
            "ogg", "opus" -> "audio/ogg"
            else -> "audio/mpeg"
        }
        android.util.Log.i("DLNA-Cast", "mimeOf(${song.title}) format='${song.format}' -> $mime")
        return mime
    }

    // ------------------------------------------------------------ 收藏

    /** 收藏/取消收藏：先乐观更新红心，服务端失败再回滚（收藏 = 内建「收藏」歌单） */
    fun toggleFavorite(song: MusicSong) {
        val client = client ?: return
        val fav = song.id in _state.value.favoriteIds
        _state.value = _state.value.copy(
            favoriteIds = if (fav) _state.value.favoriteIds - song.id else _state.value.favoriteIds + song.id,
            toast = if (fav) "已取消收藏「${song.title}」" else "已收藏「${song.title}」"
        )
        viewModelScope.launch {
            // 网络异常也走回滚，与鸿蒙端的 .catch() 行为一致
            val ok = runCatching { client.setFavorite(song.id, !fav) }.getOrDefault(false)
            if (!ok) {
                val cur = _state.value
                _state.value = cur.copy(
                    favoriteIds = if (fav) cur.favoriteIds + song.id else cur.favoriteIds - song.id,
                    toast = "收藏操作失败，请重试"
                )
            }
        }
    }

    // ------------------------------------------------------------ 杂项

    fun consumeToast() {
        if (_state.value.toast != null) _state.value = _state.value.copy(toast = null)
    }

    fun showToast(message: String) {
        _state.value = _state.value.copy(toast = message)
    }

    private fun friendly(error: Throwable): String {
        val message = error.message?.trim().orEmpty()
        return when {
            message.isBlank() -> "连接 Songloft 失败，检查地址与网络"
            message.contains("Failed to connect", true) ||
                message.contains("timeout", true) ||
                message.contains("timed out", true) -> "连不上 Songloft（地址/端口不对，或服务没开）"
            message.contains("限制登录频率", true) ||
                message.contains("频繁", true) -> message
            else -> message
        }
    }

    override fun onCleared() {
        // 只解绑界面，不释放播放器：前台服务还在播，锁屏控制也要继续用
        player.detach()
        super.onCleared()
    }
}
