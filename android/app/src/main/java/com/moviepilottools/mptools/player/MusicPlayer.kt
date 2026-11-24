package com.moviepilottools.mptools.player

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import com.moviepilottools.mptools.data.MusicSong
import com.moviepilottools.mptools.data.PlaybackState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * 音乐播放器（ExoPlayer 内核）。
 *
 * 为什么不用系统 MediaPlayer：Songloft 的本地音乐多是 FLAC，MediaPlayer 播网络 FLAC 流
 * 在小米 12 上直接报 error(1, -2147483648)；ExoPlayer 对 FLAC（含 24bit）/HTTP Range 都稳，
 * 还能自己处理音频焦点。
 *
 * 播放器实体放在 [PlaybackCore]（进程级单例），由 [MusicService] 挂到 MediaSession 上，
 * 所以锁屏/通知栏能控制同一路播放。这里只负责队列、进度和 UI 状态。
 */
class MusicPlayer(private val context: Context) {

    private val appContext: Context = context.applicationContext

    private val audioManager: AudioManager =
        appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private val _state = MutableStateFlow(PlaybackState())
    val state: StateFlow<PlaybackState> = _state.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private var queue: List<MusicSong> = emptyList()
    private var ticker: Job? = null
    private var listenerAttached = false

    /** 由 ViewModel 注入：把相对地址补成带 token 的绝对地址 */
    var urlResolver: (MusicSong) -> String = { it.streamUrl }

    // ------------------------------------------------------------ 对外操作

    fun play(list: List<MusicSong>, startIndex: Int) {
        if (list.isEmpty()) return
        val start = startIndex.coerceIn(0, list.lastIndex)
        // 注意：这里会过滤掉没有地址的曲目，队列必须跟着**一起过滤**。
        // 之前 queue 用原 list、items 用过滤后的 list，一旦前面有坏曲目，
        // 索引就整体错位 —— 点 A 播 B、界面红字和实际声音对不上，就是这么来的。
        val playable = list.mapNotNull { song ->
            val url = urlResolver(song)
            if (url.isBlank()) null else song to mediaItem(song, url)
        }
        if (playable.isEmpty()) {
            fail("这些歌都没有可播放地址")
            return
        }
        val startSong = list[start]
        queue = playable.map { it.first }
        val items = playable.map { it.second }
        val index = queue.indexOfFirst { it.id == startSong.id }.coerceAtLeast(0)
        val exo = ensurePlayer()
        // 播放器可能是刚建的（进程被杀后恢复），把上次的播放模式重新套上去
        applyRepeatMode(_state.value.repeatMode)
        exo.setMediaItems(items, index, 0L)
        exo.prepare()
        exo.playWhenReady = true
        startService()
        syncCurrent()
        startTicker()
    }

    fun toggle() {
        val exo = player ?: return
        if (exo.isPlaying) exo.pause() else exo.play()
    }

    /**
     * 播放模式切换：顺序播放 → 单曲循环 → 列表循环 → 随机播放 → 顺序（四档循环）。
     * @return 新模式，由 ViewModel 同步给投送端 —— DLNA 没有队列概念，
     *         音箱的自动连播是 CastController 自己做的，模式也得那头认。
     */
    fun cycleRepeatMode(): Int {
        val next = (_state.value.repeatMode.coerceIn(0, 3) + 1) % 4
        applyRepeatMode(next)
        return next
    }

    private fun applyRepeatMode(mode: Int) {
        player?.let { exo ->
            exo.repeatMode = when (mode) {
                1 -> Player.REPEAT_MODE_ONE
                2 -> Player.REPEAT_MODE_ALL
                else -> Player.REPEAT_MODE_OFF
            }
            exo.shuffleModeEnabled = mode == 3
        }
        _state.value = _state.value.copy(repeatMode = mode)
    }

    fun resume() {
        val exo = player
        if (exo == null) {
            if (queue.isNotEmpty()) play(queue, 0)
            return
        }
        startService()
        exo.play()
        startTicker()
    }

    fun pause() {
        player?.pause()
        stopTicker()
        _state.value = _state.value.copy(isPlaying = false)
    }

    fun next(auto: Boolean = false) {
        val exo = player ?: return
        // 用 seekToNextMediaItem 而不是 index+1 —— 随机播放时 ExoPlayer 的时间线顺序
        // 和播放顺序不一样，按 index 自己加会跳错歌
        if (!exo.hasNextMediaItem()) {
            if (auto) {
                // 播完最后一首就停在结尾，不循环
                stopTicker()
                _state.value = _state.value.copy(isPlaying = false, positionMs = _state.value.durationMs)
            } else {
                exo.seekTo(0, 0L)
                exo.play()
            }
            return
        }
        exo.seekToNextMediaItem()
        exo.play()
        startTicker()
    }

    fun previous() {
        val exo = player ?: return
        // 播放超过 3 秒，上一首先回到开头（跟主流播放器一致）
        if (exo.currentPosition > 3000L) {
            exo.seekTo(0L)
            _state.value = _state.value.copy(positionMs = 0L)
            return
        }
        if (!exo.hasPreviousMediaItem()) {
            exo.seekTo(0L)
            _state.value = _state.value.copy(positionMs = 0L)
            return
        }
        exo.seekToPreviousMediaItem()
        exo.play()
        startTicker()
    }

    fun seekTo(positionMs: Long) {
        val exo = player ?: return
        val duration = exo.duration.takeIf { it > 0 } ?: _state.value.durationMs
        val target = positionMs.coerceIn(0L, duration.coerceAtLeast(0L))
        exo.seekTo(target)
        _state.value = _state.value.copy(positionMs = target)
    }

    /**
     * 本机播放音量（0f..1f）。
     *
     * 直接改**系统媒体音量**（STREAM_MUSIC），不再用 ExoPlayer 的软件音量：
     * 这样音量键和页面里的音量条是同一个东西，按手机音量键滑块会跟着动，
     * 不会出现「两个音量各调一半」的困惑。
     */
    fun setVolume(value: Float) {
        val volume = value.coerceIn(0f, 1f)
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max > 0) {
            audioManager.setStreamVolume(
                AudioManager.STREAM_MUSIC,
                (volume * max).roundToInt().coerceIn(0, max),
                0
            )
        }
        // 播放器本身不加衰减，音量交给系统
        player?.volume = 1f
        _state.value = _state.value.copy(volume = systemVolume())
    }

    /** 当前系统媒体音量 → 0f..1f */
    private fun systemVolume(): Float {
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return 1f
        val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        return (current.toFloat() / max).coerceIn(0f, 1f)
    }

    fun stop() {
        stopTicker()
        player?.let {
            runCatching { it.pause() }
            runCatching { it.clearMediaItems() }
        }
        queue = emptyList()
        // 播放模式是用户偏好，退出播放不该把它重置回「顺序」
        _state.value = PlaybackState(volume = _state.value.volume, repeatMode = _state.value.repeatMode)
        stopService()
    }

    /**
     * ViewModel 销毁时调用：只停 ticker，不释放播放器、也不取消 scope。
     * 播放器是进程级单例（前台服务还在用），下次进 App 还要在同一实例上继续播。
     */
    fun detach() {
        stopTicker()
    }

    // ------------------------------------------------------------ 内部实现

    private val player: ExoPlayer? get() = PlaybackCore.peek()

    private fun ensurePlayer(): ExoPlayer {
        val exo = PlaybackCore.player(appContext)
        if (!listenerAttached) {
            listenerAttached = true
            exo.addListener(object : Player.Listener {
                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    _state.value = _state.value.copy(isPlaying = isPlaying, error = null)
                    if (isPlaying) startTicker() else stopTicker()
                }

                override fun onPlaybackStateChanged(playbackState: Int) {
                    if (playbackState == Player.STATE_READY) syncCurrent()
                    if (playbackState == Player.STATE_ENDED && !exo.hasNextMediaItem()) {
                        stopTicker()
                        _state.value = _state.value.copy(
                            isPlaying = false,
                            positionMs = _state.value.durationMs
                        )
                    }
                }

                override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                    syncCurrent()
                }

                override fun onPlayerError(error: PlaybackException) {
                    fail(describe(error))
                }

                override fun onVolumeChanged(volume: Float) {
                    // 播放器音量固定 1f，真实音量在系统那侧，这里只同步一次系统值
                    _state.value = _state.value.copy(volume = systemVolume())
                }
            })
            _state.value = _state.value.copy(volume = systemVolume())
        }
        return exo
    }

    /** 锁屏通知要显示歌名/歌手/封面，必须带上 MediaMetadata */
    private fun mediaItem(song: MusicSong, url: String): MediaItem =
        MediaItem.Builder()
            .setUri(url)
            .setMediaId(song.id.toString())
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(song.title)
                    .setArtist(song.artist.ifBlank { "未知歌手" })
                    .setAlbumTitle(song.album.ifBlank { null })
                    .setArtworkUri(song.coverUrl.takeIf { it.isNotBlank() }?.let { android.net.Uri.parse(it) })
                    .build()
            )
            .build()

    /** 拉起前台服务：有了它才有锁屏控制，息屏也不会被系统掐掉 */
    private fun startService() {
        runCatching {
            appContext.startService(Intent(appContext, MusicService::class.java))
        }
    }

    private fun stopService() {
        runCatching { appContext.stopService(Intent(appContext, MusicService::class.java)) }
    }

    private fun syncCurrent() {
        val exo = player ?: return
        val trackIndex = exo.currentMediaItemIndex
        val song = queue.getOrNull(trackIndex)
        val duration = exo.duration.takeIf { it > 0 }
            ?: (song?.durationSeconds?.times(1000L) ?: 0L)
        _state.value = _state.value.copy(
            current = song ?: _state.value.current,
            durationMs = duration,
            positionMs = exo.currentPosition.coerceAtLeast(0L),
            hasPrevious = trackIndex > 0,
            hasNext = trackIndex < exo.mediaItemCount - 1,
            volume = systemVolume(),
            error = null
        )
    }

    private fun startTicker() {
        stopTicker()
        ticker = scope.launch {
            while (isActive) {
                val exo = player
                if (exo != null) {
                    val position = exo.currentPosition.coerceAtLeast(0L)
                    val duration = exo.duration.takeIf { it > 0 } ?: _state.value.durationMs
                    val systemVol = systemVolume()
                    _state.value = _state.value.copy(
                        positionMs = position,
                        durationMs = duration,
                        volume = if (_state.value.volume == systemVol) _state.value.volume else systemVol
                    )
                }
                delay(TICK_MS)
            }
        }
    }

    private fun stopTicker() {
        ticker?.cancel()
        ticker = null
    }

    private fun describe(error: PlaybackException): String = when (error.errorCode) {
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT ->
            "连不上 Songloft（地址/端口不对，或服务没开）"

        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS ->
            "Songloft 拒绝了播放请求，可能登录已过期，去设置里重新保存一次「音乐服务」"

        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED ->
            "这个音频格式解不了（${error.errorCodeName}）"

        else -> "播放失败：${error.errorCodeName}"
    }

    private fun fail(message: String) {
        stopTicker()
        _state.value = _state.value.copy(isPlaying = false, error = message)
    }

    private companion object {
        const val TICK_MS = 500L
    }
}

/**
 * 进程级单例持有者：ViewModel 重建（转屏、返回再进）时复用同一个 [MusicPlayer]，
 * 避免重复给 ExoPlayer 挂监听导致状态翻倍。
 */
object MusicEngine {
    @Volatile
    private var instance: MusicPlayer? = null

    fun player(context: Context): MusicPlayer =
        instance ?: synchronized(this) {
            instance ?: MusicPlayer(context.applicationContext).also { instance = it }
        }

    fun peek(): MusicPlayer? = instance
}
