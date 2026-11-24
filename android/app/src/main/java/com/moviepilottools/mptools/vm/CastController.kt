package com.moviepilottools.mptools.vm

import android.content.Context
import com.moviepilottools.mptools.data.MusicSong
import com.moviepilottools.mptools.net.Net
import com.moviepilottools.mptools.net.dlna.DlnaClient
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
import kotlinx.coroutines.withContext
import kotlin.random.Random

/**
 * DLNA 投送状态机（单例）。
 *
 * 投送是「音箱自己去拉流」，所以一旦 SetAVTransportURI + Play 成功，本机就不用再管音频了。
 * 但 DLNA 的 AVTransport 没有队列概念（一次只有一条 URI），所以「连播」由这里做：
 * 每 2.5 秒轮询音箱的 TransportState，一首放完（PLAYING → STOPPED）就自己推下一首。
 *
 * 一旦有了投送目标（[CastState.active]），点歌就不再走本机扬声器，而是直接投给音箱 ——
 * 这就是「点一下就播」的关键。
 */
object CastController {

    data class CastState(
        val scanning: Boolean = false,
        val scanned: Boolean = false,
        val devices: List<DlnaClient.Device> = emptyList(),
        /** 当前投送目标，null = 没在投送 */
        val active: DlnaClient.Device? = null,
        val title: String = "",
        val busy: Boolean = false,
        val message: String? = null,
        /** 投送队列（点歌时的整张列表），支持自动连播 */
        val queue: List<MusicSong> = emptyList(),
        val index: Int = -1,
        /** 播放模式：0 顺序 / 1 单曲循环 / 2 列表循环 / 3 随机 */
        val repeatMode: Int = 0,
        val playing: Boolean = true,
        /** 音箱音量 0..100，-1 = 未知 */
        val volume: Int = -1,
        val volumeSupported: Boolean = false,
        /** 播放进度（毫秒）：轮询音箱时校准，播放中由本地计时器平滑推进 */
        val positionMs: Long = 0L,
        val durationMs: Long = 0L
    ) {
        val casting: Boolean get() = active != null
        val progressText: String
            get() = if (queue.isEmpty() || index < 0) "" else "${index + 1}/${queue.size}"
        val hasNext: Boolean
            get() = index >= 0 && queue.size > 1 &&
                (index < queue.size - 1 || repeatMode == 2 || repeatMode == 3)
        val hasPrevious: Boolean get() = index > 0
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _state = MutableStateFlow(CastState())
    val state: StateFlow<CastState> = _state.asStateFlow()

    /** 本地进度推进间隔 */
    private const val TICK_MS = 500L

    /** 每 5 个 tick（2.5 秒）真的查一次音箱 */
    private const val POLL_TICKS = 5

    private var scanJob: Job? = null
    private var monitorJob: Job? = null

    /** 正在推流，别让轮询重复触发下一首 */
    @Volatile
    private var pushing = false

    /** 上次推流的时刻：推完 4 秒内不判定「这首放完了」，否则音箱还没切过来会连推两首 */
    @Volatile
    private var lastPushAt = 0L

    /** 最近一次成功推给音箱的流地址：轮询时拿音箱的 CurrentURI 跟它比，判断音箱放的还是不是我们的流 */
    @Volatile
    private var lastPushedUrl: String? = null

    /**
     * 最近一次成功推的曲目本地时长（song.durationSeconds * 1000）：
     * 接管兜底用它和音箱报的时长比。不能用 state.durationMs —— 那个每轮被音箱
     * 校准覆盖，首轮之后就和音箱值一样了，兜底永远失效。
     */
    @Volatile
    private var lastLocalDurationMs = 0L

    /** 上一次推流失败的曲目和时刻：防止「放完了 → 推失败 → 再判完成 → 再推」死循环 */
    @Volatile
    private var lastFailIndex = -1
    @Volatile
    private var lastFailAt = 0L

    private var volumeJob: Job? = null

    private var urlFor: (MusicSong) -> String = { it.streamUrl }
    private var mimeFor: (MusicSong) -> String = { "audio/mpeg" }

    /** 播放模式：0 顺序 / 1 单曲循环 / 2 列表循环 / 3 随机（和 MusicPlayer 的 repeatMode 同一套值） */
    @Volatile
    private var repeatMode = 0

    /** ViewModel 切换模式时同步过来，投送端的自动连播按它决定下一首 */
    fun setRepeatMode(mode: Int) {
        repeatMode = mode.coerceIn(0, 3)
        _state.value = _state.value.copy(repeatMode = repeatMode)
    }

    /**
     * 按播放模式算下一首下标；null = 队列结束（该停了）。
     * [manual] = 手动点下一首：单曲循环时仍然往后走，符合主流播放器习惯。
     */
    private fun nextIndex(cur: Int, size: Int, manual: Boolean): Int? {
        if (size <= 0 || cur < 0) return null
        val mode = if (manual && repeatMode == 1) 0 else repeatMode
        return when (mode) {
            1 -> cur                                  // 单曲循环：自动播完重推同一首
            2 -> (cur + 1) % size                    // 列表循环：到尾回第一首
            3 -> if (size == 1) 0 else {            // 随机：不重复抽到当前这首
                var n = cur
                while (n == cur) n = Random.nextInt(size)
                n
            }
            else -> if (cur + 1 < size) cur + 1 else null // 顺序：播完即停
        }
    }

    /** 应用级 Context：拉起 [com.moviepilottools.mptools.player.CastService] 用 */
    private var appContext: android.content.Context? = null

    /** ViewModel 初始化时注入，投送开始时用它拉前台服务保活 */
    fun setApplicationContext(context: android.content.Context) {
        appContext = context.applicationContext
    }

    /**
     * 投送开始时拉起前台服务：锁屏后系统才不会冻结进程，
     * 轮询协程（连播的心跳）才能继续跑。服务自己盯着 [state]，
     * casting=false 时会自动退出，所以这里只管「开」不管「关」。
     */
    private fun startForeground() {
        val context = appContext ?: return
        runCatching {
            androidx.core.content.ContextCompat.startForegroundService(
                context,
                android.content.Intent(context, com.moviepilottools.mptools.player.CastService::class.java)
            )
        }
    }

    // ---------------------------------------------------------------- 发现设备

    /** 搜索局域网里的投送设备（音箱/电视/盒子） */
    fun scan(context: Context) {
        if (_state.value.scanning) return
        scanJob?.cancel()
        _state.value = _state.value.copy(scanning = true, message = null)
        scanJob = scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { DlnaClient.discover(context.applicationContext) }
            }
            result.onSuccess { devices ->
                _state.value = _state.value.copy(
                    scanning = false,
                    scanned = true,
                    devices = devices,
                    message = if (devices.isEmpty())
                        "没找到可投送的设备。确认音箱和手机在同一个 WiFi、且音箱支持 DLNA/UPnP 投送。"
                    else null
                )
            }.onFailure { error ->
                _state.value = _state.value.copy(
                    scanning = false,
                    scanned = true,
                    message = "搜索失败：${error.message ?: "未知错误"}"
                )
            }
        }
    }

    fun stopScan() {
        scanJob?.cancel()
        if (_state.value.scanning) _state.value = _state.value.copy(scanning = false)
    }

    // ---------------------------------------------------------------- 投送

    /**
     * 把整个队列投给设备，从 [startIndex] 开始播。
     *
     * @param urlFor 曲目 → 可播放的绝对地址（Songloft 还要带 access_token）
     * @param mimeFor 曲目 → MIME，音箱靠它选解码器
     */
    fun playQueue(
        device: DlnaClient.Device,
        songs: List<MusicSong>,
        startIndex: Int,
        urlFor: (MusicSong) -> String,
        mimeFor: (MusicSong) -> String
    ) {
        if (songs.isEmpty()) return
        this.urlFor = urlFor
        this.mimeFor = mimeFor
        val index = startIndex.coerceIn(0, songs.lastIndex)

        _state.value = _state.value.copy(
            active = device,
            queue = songs,
            index = index,
            repeatMode = repeatMode,
            busy = true,
            message = null,
            volumeSupported = device.volumeSupported
        )
        scope.launch {
            startForeground()
            push(index)
            _state.value = _state.value.copy(busy = false)
            refreshVolume()
            startMonitor(device)
        }
    }

    /** 只投一首（设备行里点「投送」时用） */
    fun cast(device: DlnaClient.Device, audioUrl: String, title: String, mime: String = "audio/mpeg") {
        if (audioUrl.isBlank()) {
            _state.value = _state.value.copy(message = "这首歌没有可用地址，没法投送")
            return
        }
        _state.value = _state.value.copy(busy = true, message = null)
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                DlnaClient.play(device, audioUrl, title, mime)
            }
            result.onSuccess {
                startForeground()
                lastPushAt = System.currentTimeMillis()
                lastPushedUrl = audioUrl
                _state.value = _state.value.copy(
                    busy = false,
                    active = device,
                    title = title,
                    index = -1,
                    queue = emptyList(),
                    playing = true,
                    volumeSupported = device.volumeSupported,
                    message = "已投送到「${device.name}」"
                )
                refreshVolume()
                startMonitor(device)
            }.onFailure { error ->
                _state.value = _state.value.copy(
                    busy = false,
                    message = "投送失败：${error.message ?: "设备没响应"}"
                )
            }
        }
    }

    /** 下一首（按播放模式：列表循环回开头、随机抽一首、顺序到尾就停） */
    fun next() {
        val current = _state.value
        if (!current.casting) return
        val target = nextIndex(current.index, current.queue.size, manual = true)
        if (target == null) {
            scope.launch { stopCasting() }
            return
        }
        scope.launch { push(target) }
    }

    fun previous() {
        val current = _state.value
        if (!current.casting || !current.hasPrevious) return
        scope.launch { push(current.index - 1) }
    }

    fun togglePause() {
        val current = _state.value
        val device = current.active ?: return
        val resume = !current.playing
        scope.launch {
            withContext(Dispatchers.IO) {
                if (resume) DlnaClient.resume(device) else DlnaClient.pause(device)
            }
            _state.value = _state.value.copy(playing = resume)
        }
    }

    /** 兼容旧调用：暂停/恢复投送 */
    fun togglePause(resume: Boolean) {
        val device = _state.value.active ?: return
        scope.launch {
            withContext(Dispatchers.IO) {
                if (resume) DlnaClient.resume(device) else DlnaClient.pause(device)
            }
            _state.value = _state.value.copy(playing = resume)
        }
    }

    /** 拖动进度条：DLNA 的 Seek 用 REL_TIME（绝对时间点） */
    fun seekTo(positionMs: Long) {
        val current = _state.value
        val device = current.active ?: return
        val target = positionMs.coerceAtLeast(0L)
        _state.value = current.copy(positionMs = target)
        scope.launch {
            withContext(Dispatchers.IO) { runCatching { DlnaClient.seek(device, target) } }
                .onFailure {
                    _state.value = _state.value.copy(message = "这台音箱不支持拖动进度")
                }
        }
    }

    /** 调音箱音量（0..100） */
    fun setVolume(percent: Int) {
        val current = _state.value
        val device = current.active ?: return
        if (!device.volumeSupported) {
            _state.value = current.copy(message = "这台设备不支持 App 调音量，用音箱自己的旋钮")
            return
        }
        val value = percent.coerceIn(0, 100)
        _state.value = current.copy(volume = value)
        // 拖动滑块会连续触发，防抖一下再真的发 SOAP，不然音箱会被刷爆
        volumeJob?.cancel()
        volumeJob = scope.launch {
            delay(120)
            withContext(Dispatchers.IO) { DlnaClient.setVolume(device, value) }
                .onFailure {
                    _state.value = _state.value.copy(message = "调音量失败：${it.message}")
                }
        }
    }

    fun refreshVolume() {
        val current = _state.value
        val device = current.active ?: return
        if (!device.volumeSupported) {
            _state.value = current.copy(volume = -1, volumeSupported = false)
            return
        }
        scope.launch {
            val value = withContext(Dispatchers.IO) { DlnaClient.getVolume(device) }
            if (value != null) _state.value = _state.value.copy(volume = value, volumeSupported = true)
        }
    }

    fun stopCasting() {
        val device = _state.value.active ?: return
        monitorJob?.cancel()
        monitorJob = null
        lastPushedUrl = null
        lastLocalDurationMs = 0L
        _state.value = _state.value.copy(busy = true)
        scope.launch {
            withContext(Dispatchers.IO) { runCatching { DlnaClient.stop(device) } }
            val devices = _state.value.devices
            _state.value = CastState(scanned = true, devices = devices, message = "已停止投送")
        }
    }

    fun clearMessage() {
        if (_state.value.message != null) _state.value = _state.value.copy(message = null)
    }

    // ---------------------------------------------------------------- 内部

    /**
     * 投送前探测流地址：GET 第一字节（Range: bytes=0-0），不下载内容。
     * 返回 null = 服务端正常给流；返回字符串 = 给用户看的失败原因。
     */
    private suspend fun probeStream(url: String): String? = withContext(Dispatchers.IO) {
        runCatching {
            Net.client.newCall(
                okhttp3.Request.Builder()
                    .url(url)
                    .header("Range", "bytes=0-0")
                    .build()
            ).execute().use { res ->
                when {
                    res.isSuccessful -> null
                    res.code == 401 -> "登录已过期（401），去设置里重新保存一次「音乐服务」"
                    res.code == 404 -> "服务端取流失败（404）：曲库里的文件路径失效了，重新扫一次盘"
                    res.code == 500 -> "服务端取流失败（500）：多半是 CUE 分轨指向的整轨文件丢了"
                    else -> "服务端取流失败（HTTP ${res.code}）"
                }
            }
        }.getOrElse { "连不上音乐服务：${it.message ?: "网络错误"}" }
    }

    /**
     * 还原 XML 转义：GetMediaInfo 回来的 CurrentURI 是转义过的原文，比较前先还原。
     * 注意 &amp; 必须最后替换，避免把已经还原出来的 &amp; 又二次还原一遍。
     */
    private fun unescapeXml(s: String): String = s
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")

    /** 比较流地址时忽略 query 串：access_token / 时间戳每次可能不同，只看路径本身 */
    private fun stripQuery(s: String): String = s.substringBefore('?')

    private suspend fun push(index: Int) {
        val current = _state.value
        val device = current.active ?: return
        val song = current.queue.getOrNull(index) ?: return
        val url = urlFor(song)
        if (url.isBlank()) {
            _state.value = current.copy(message = "「${song.title}」没有可播放地址")
            return
        }
        // 投送前先探一下流地址：手机能打开列表不代表服务端真给得出音频
        //（fnOS 重装/挪盘后路径失效 → 404；CUE 分轨的 FILE 指向丢了 → 500）。
        // 不探的话音箱收下 URL 后静音装播，App 这边只会看到假进度。
        val probeFail = probeStream(url)
        if (probeFail != null) {
            lastFailIndex = index
            lastFailAt = System.currentTimeMillis()
            android.util.Log.w("DLNA-Cast", "probe(${song.title}) $probeFail")
            _state.value = current.copy(
                playing = false,
                message = "投送「${song.title}」失败：$probeFail"
            )
            return
        }
        pushing = true
        val result = withContext(Dispatchers.IO) {
            DlnaClient.play(device, url, song.title, mimeFor(song))
        }
        pushing = false
        result.onSuccess {
            lastPushAt = System.currentTimeMillis()
            lastPushedUrl = url
            lastLocalDurationMs = song.durationSeconds * 1000L
            lastFailIndex = -1
            _state.value = _state.value.copy(
                index = index,
                title = song.title,
                playing = true,
                positionMs = 0L,
                durationMs = song.durationSeconds * 1000L,
                message = "正在播放「${song.title}」"
            )
        }.onFailure { error ->
            lastFailIndex = index
            lastFailAt = System.currentTimeMillis()
            android.util.Log.w("DLNA-Cast", "push(${song.title}) 失败: ${error.message}")
            _state.value = _state.value.copy(
                playing = false,
                message = "投送「${song.title}」失败：${error.message ?: "设备没响应"}"
            )
        }
    }

    /**
     * 轮询音箱状态做连播。
     *
     * 每 2.5 秒真的问一次音箱（GetTransportInfo + GetPositionInfo），中间每 0.5 秒本地推进进度条。
     * 三种「这首放完了」的判定，任何一种命中就推下一首：
     *  1. 状态从 PLAYING 掉到 STOPPED / NO_MEDIA_PRESENT；
     *  2. 进度走到接近总时长（部分音箱放完仍报 PLAYING）；
     *  3. 位置连续两次不动且已到结尾。
     * 用户手动暂停（PAUSED_PLAYBACK）不触发下一首。
     */
    private fun startMonitor(device: DlnaClient.Device) {
        monitorJob?.cancel()
        monitorJob = scope.launch {
            var seenPlaying = false
            var tick = 0
            var lastPosition = -1L
            var stalled = 0
            // BUG-1 兜底：音箱报 PLAYING 但 pos=0、dur=0，说明它根本没拉到流
            //（假进度就是这么来的）。连续 6 次（约 15 秒）还在装播就提示。
            var silentStall = 0

            while (isActive) {
                delay(TICK_MS)
                tick++

                val snapshot = _state.value
                if (!snapshot.casting || pushing) continue

                // 进度条平滑推进（真值在下面每 2.5 秒校准一次）
                if (snapshot.playing && snapshot.durationMs > 0L && snapshot.positionMs < snapshot.durationMs) {
                    _state.value = snapshot.copy(
                        positionMs = (snapshot.positionMs + TICK_MS).coerceAtMost(snapshot.durationMs)
                    )
                }

                if (tick % POLL_TICKS != 0) continue

                val info = withContext(Dispatchers.IO) {
                    runCatching { DlnaClient.transport(device) }.getOrNull()
                } ?: continue

                // —— 播放权校验：音箱现在放的还是不是我们推的流？——
                // 用户可能对小爱音箱语音点歌（走音箱自己的通道），这时音箱状态照样报
                // PLAYING，但 CurrentURI 已经不是我们的了。不校验的话，状态翻转会被
                // 误判成「我们这首放完了」，自动把队列下一首推过去抢掉用户点的歌，
                // 本地假进度也会一直走。
                val speakerUri = withContext(Dispatchers.IO) {
                    runCatching { DlnaClient.mediaUri(device) }.getOrNull()
                }
                var mine: Boolean? = when {
                    // 拿不到 URI（接口失败/空串）：无法判断，走下面的时长兜底
                    speakerUri.isNullOrEmpty() -> null
                    else -> stripQuery(unescapeXml(speakerUri)) == stripQuery(lastPushedUrl ?: "")
                }
                // 兜底：部分音箱不回报 CurrentURI，改用时长差异判断 ——
                // 音箱报的时长和本地这首（lastLocalDurationMs，不受音箱校准污染）
                // 对不上（差 3 秒以上）就当是别人在放。
                if (mine == null && info.durationMs > 0L && lastLocalDurationMs > 0L &&
                    kotlin.math.abs(info.durationMs - lastLocalDurationMs) > 3000L
                ) {
                    mine = false
                }

                // 确认音箱在放别人的内容：停掉轮询，绝不再自动推下一首去抢；
                // playing=false 同时让本地假进度停下。
                // 刚推流 6 秒内音箱可能还报着旧 URI，别误杀。
                if (mine == false && System.currentTimeMillis() - lastPushAt > 6000L) {
                    monitorJob = null
                    _state.value = _state.value.copy(
                        playing = false,
                        message = "音箱正在播放其他内容（语音点歌或别的设备接管），已暂停连播"
                    )
                    return@launch
                }

                val state = info.state.uppercase()
                var finished = false

                when {
                    state.startsWith("PLAYING") || state == "TRANSITIONING" -> {
                        seenPlaying = true
                    }
                    state.startsWith("PAUSED") -> {
                        seenPlaying = false
                    }
                    state.startsWith("STOPPED") || state == "NO_MEDIA_PRESENT" -> {
                        if (seenPlaying) {
                            seenPlaying = false
                            finished = true
                        }
                    }
                }

                // 位置校准：音箱报的比本地准，直接覆盖
                val cur = _state.value
                val position = info.positionMs.takeIf { it > 0 } ?: cur.positionMs
                val duration = info.durationMs.takeIf { it > 0 } ?: cur.durationMs
                if (position != lastPosition) stalled = 0 else stalled++
                lastPosition = position

                if (!finished && duration > 0L && position > 0L && position >= duration - 1200L && stalled >= 1) {
                    finished = true
                }

                // 假播放侦测：PLAYING 但没进度没时长，排除刚推流的几秒后连续 15 秒 → 提示
                if (state.startsWith("PLAYING") && position <= 0L && duration <= 0L &&
                    System.currentTimeMillis() - lastPushAt > 6000L
                ) {
                    silentStall++
                    if (silentStall == 6) {
                        _state.value = _state.value.copy(
                            playing = false,
                            message = "音箱一直没拉到流（无进度无时长），可能是格式不支持或曲库文件有问题"
                        )
                    }
                } else {
                    silentStall = 0
                }

                // 刚推完流的那几秒，音箱可能还停留在上一首的 STOPPED，别当成「放完了」
                if (finished && System.currentTimeMillis() - lastPushAt < 4000L) {
                    finished = false
                }

                _state.value = cur.copy(
                    positionMs = position,
                    durationMs = duration,
                    playing = when {
                        state.startsWith("PAUSED") -> false
                        state.startsWith("PLAYING") || state == "TRANSITIONING" -> true
                        else -> cur.playing
                    }
                )

                if (!finished) continue

                val s = _state.value
                // 同一首刚推失败过：别再自动重试，否则会「失败 → 判完成 → 再推」无限循环
                if (lastFailIndex == s.index && System.currentTimeMillis() - lastFailAt < 15_000L) {
                    _state.value = s.copy(playing = false)
                    continue
                }
                when {
                    // 保险：播放权校验没拦住（6 秒窗口期）但音箱确实不在放我们的流，
                    // 只跳过这次 push（state 不动、监控不杀），等窗口过后由上面的
                    // 主校验裁决 —— 避免推流后 4-6 秒音箱还报旧 URI 时被误杀
                    mine == false -> Unit
                    s.queue.isEmpty() -> Unit
                    else -> {
                        val target = nextIndex(s.index, s.queue.size, manual = false)
                        if (target == null) {
                            _state.value = s.copy(playing = false, message = "整张列表已投送完毕")
                        } else {
                            push(target)
                        }
                    }
                }
            }
        }
    }

}
