package com.moviepilottools.mptools.ui.music

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CastConnected
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.RepeatOne
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.VolumeDown
import androidx.compose.material.icons.rounded.VolumeMute
import androidx.compose.material.icons.rounded.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImagePainter
import coil.compose.SubcomposeAsyncImage
import coil.compose.SubcomposeAsyncImageContent
import com.moviepilottools.mptools.data.PlaybackState
import com.moviepilottools.mptools.data.formatDurationMs
import com.moviepilottools.mptools.ui.components.ThinProgress
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Metrics
import com.moviepilottools.mptools.ui.theme.Palette
import kotlin.math.max
import kotlin.math.roundToInt

/** 底部迷你播放条：常驻在所有标签页底部（正在播放时） */
@Composable
fun MiniPlayerBar(
    playback: PlaybackState,
    onOpen: () -> Unit,
    onToggle: () -> Unit,
    onNext: () -> Unit,
    onQuit: () -> Unit = {}
) {
    val colors = LocalMptColors.current
    val song = playback.current ?: return

    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.pagePadding, vertical = 4.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(colors.card)
            .clickable(onClick = onOpen)
    ) {
        ThinProgress(
            progress = playback.progress,
            color = Palette.pink,
            modifier = Modifier.fillMaxWidth(),
            height = 2
        )
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(Modifier.size(36.dp).clip(RoundedCornerShape(8.dp)).background(colors.separator)) {
                if (song.coverUrl.isNotBlank()) {
                    SubcomposeAsyncImage(
                        model = song.coverUrl,
                        contentDescription = song.title,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize()
                    ) {
                        when (painter.state) {
                            is AsyncImagePainter.State.Success -> SubcomposeAsyncImageContent()
                            else -> CoverFallback(iconSize = 16.dp)
                        }
                    }
                } else {
                    CoverFallback(iconSize = 16.dp)
                }
            }
            Spacer(Modifier.width(9.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    song.title,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    playback.castingTo?.let { "投送到 $it" } ?: song.artist.ifBlank { "未知歌手" },
                    fontSize = 10.sp,
                    color = if (playback.castingTo != null) Palette.blue else colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Icon(
                if (playback.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                contentDescription = "播放/暂停",
                tint = colors.textPrimary,
                modifier = Modifier.size(22.dp).clickable { onToggle() }
            )
            Spacer(Modifier.width(14.dp))
            Icon(
                Icons.Rounded.SkipNext,
                contentDescription = "下一首",
                tint = if (playback.hasNext) colors.textPrimary else colors.textSecondary,
                modifier = Modifier.size(22.dp).clickable { onNext() }
            )
            Spacer(Modifier.width(10.dp))
            // 关闭：停播放并清掉这条播放条（暂停/播完后它本来会一直挂着）
            Icon(
                Icons.Rounded.Close,
                contentDescription = "关闭播放条",
                tint = colors.textSecondary,
                modifier = Modifier.size(20.dp).clickable { onQuit() }
            )
        }
    }
}

/** 全屏播放页 */
@Composable
fun NowPlayingScreen(
    playback: PlaybackState,
    favorite: Boolean,
    onClose: () -> Unit,
    onToggle: () -> Unit,
    onNext: () -> Unit,
    onPrevious: () -> Unit,
    onSeek: (Long) -> Unit,
    onVolumeChange: (Float) -> Unit = {},
    onToggleFavorite: () -> Unit = {},
    onCycleRepeat: () -> Unit = {}
) {
    val colors = LocalMptColors.current
    val song = playback.current
    var dragValue by remember { mutableStateOf<Float?>(null) }

    // 沉浸模式：有封面时海报铺满整页做背景 + 渐变遮罩，前景全部用白色系（学飞牛/主流播放器）
    val immersive = song?.coverUrl?.isNotBlank() == true
    val fg = if (immersive) androidx.compose.ui.graphics.Color.White else colors.textPrimary
    val fgSec = if (immersive) androidx.compose.ui.graphics.Color.White.copy(alpha = 0.72f) else colors.textSecondary
    val trackColor = if (immersive) androidx.compose.ui.graphics.Color.White.copy(alpha = 0.28f) else colors.separator

    Box(
        Modifier
            .fillMaxSize()
            .background(colors.background)
            // 拦截空白处的点击，防止触摸事件穿透到下面的音乐页（误触设置入口等）
            .pointerInput(Unit) { detectTapGestures { } }
    ) {
        if (song != null && immersive) {
            // 背景海报 + 底部加深的渐变遮罩，保证歌名/进度条/按钮可读
            SubcomposeAsyncImage(
                model = song.coverUrl,
                contentDescription = song.title,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            ) {
                when (painter.state) {
                    is AsyncImagePainter.State.Success -> SubcomposeAsyncImageContent()
                    else -> CoverFallback(iconSize = 72.dp)
                }
            }
            Box(
                Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            listOf(
                                androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.30f),
                                androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.78f)
                            )
                        )
                    )
            )
        }

        Column(
            Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
        ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                Icons.Rounded.KeyboardArrowDown, null,
                tint = fg,
                modifier = Modifier.size(26.dp).clickable { onClose() }
            )
            Spacer(Modifier.weight(1f))
            Text("正在播放", fontSize = 12.sp, color = fgSec)
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.size(26.dp))
        }

        if (song == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("还没有在播放的歌", fontSize = 14.sp, color = colors.textSecondary)
            }
            return@Column
        }

        // 无封面时回退：方形渐变占位卡（有封面时海报已经铺满整页，这里不再重复显示）
        if (!immersive) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .aspectRatio(1f)
            ) {
                CoverFallback(iconSize = 56.dp)
            }
        }

        // 剩余空间全留在海报和歌名之间：歌名/进度条贴着底部五键
        Spacer(Modifier.weight(1f))
        // 歌名/副标题左对齐，右侧收藏心形（参考主流播放器排版）
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 28.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    song.title,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = fg,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    listOfNotNull(song.artist.ifBlank { null }, song.album.ifBlank { null })
                        .joinToString(" · ").ifBlank { "未知歌手" },
                    fontSize = 12.sp,
                    color = fgSec,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                if (playback.castingTo != null) {
                    Spacer(Modifier.height(6.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Rounded.CastConnected, null,
                            tint = Palette.blue,
                            modifier = Modifier.size(13.dp)
                        )
                        Spacer(Modifier.width(5.dp))
                        Text("投送到 ${playback.castingTo}", fontSize = 11.sp, color = Palette.blue)
                    }
                }
            }
            Spacer(Modifier.width(12.dp))
            Icon(
                if (favorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                contentDescription = if (favorite) "取消收藏" else "收藏",
                tint = if (favorite) Palette.pink else fgSec,
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onToggleFavorite)
                    .padding(8.dp)
            )
        }

        // 进度：轨道保持整行宽度（拖动区域越大越好按），
        // 只是把 Material 默认那根 44dp 高的竖条滑块改矮成 22dp 的小竖条。
        Spacer(Modifier.height(16.dp))
        val duration = playback.durationMs.coerceAtLeast(1L)
        val positionMs = ((dragValue ?: playback.progress) * duration).toLong()
        CompactSlider(
            value = dragValue ?: playback.progress,
            onValueChange = { dragValue = it },
            onValueChangeFinished = { ratio ->
                // 时长还没拿到（流刚起、或服务端没给 duration）时不乱跳，
                // 否则会把进度 seek 到一个没有意义的位置
                if (playback.durationMs > 0L) onSeek((ratio * duration).toLong())
                dragValue = null
            },
            inactiveColor = trackColor,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 26.dp)
        )
        // 时间行：两端时间，中间提示这首歌的音频格式（学飞牛音乐：「原文件 · FLAC · 1022 kbps」）
        Box(Modifier.fillMaxWidth().padding(horizontal = 30.dp)) {
            Text(formatDurationMs(positionMs), fontSize = 10.sp, color = fgSec, modifier = Modifier.align(Alignment.CenterStart))
            val formatHint = buildString {
                append("原文件")
                if (song.format.isNotBlank()) append(" · ${song.format.uppercase()}")
                if (song.bitRate > 0) append(" · ${song.bitRate} kbps")
            }
            if (formatHint != "原文件") {
                Text(
                    formatHint,
                    fontSize = 10.sp,
                    color = fgSec.copy(alpha = 0.85f),
                    modifier = Modifier.align(Alignment.Center)
                )
            }
            Text(formatDurationMs(playback.durationMs), fontSize = 10.sp, color = fgSec, modifier = Modifier.align(Alignment.CenterEnd))
        }

        if (playback.error != null) {
            Spacer(Modifier.height(6.dp))
            Text(
                playback.error.orEmpty(),
                fontSize = 11.sp,
                color = Palette.red,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 28.dp)
            )
        }

        // 底部控制条：循环 / 上一首 / 播放暂停 / 下一首 / 音量（整排悬浮在底部上方）
        // 音量条平时收起，点喇叭弹出调节条（拖动调音量，实时显示百分比）。
        // 拖动中不让 ticker 回读重建状态（否则系统音量档位化会把滑块打跳）
        var volumeDragging by remember { mutableStateOf(false) }
        var volume by remember(if (volumeDragging) -1f else playback.volume) { mutableStateOf(playback.volume) }
        var showVolume by remember { mutableStateOf(false) }
        if (showVolume) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 34.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    if (volume <= 0.001f) Icons.Rounded.VolumeMute else Icons.Rounded.VolumeUp,
                    null,
                    tint = fgSec,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(Modifier.width(12.dp))
                CompactSlider(
                    value = volume,
                    onValueChange = {
                        volumeDragging = true
                        volume = it
                        onVolumeChange(it)
                    },
                    onValueChangeFinished = {
                        volumeDragging = false
                        volume = it
                    },
                    inactiveColor = trackColor,
                    height = 30.dp,
                    modifier = Modifier.weight(1f)
                )
                Spacer(Modifier.width(12.dp))
                Text(
                    "${(volume * 100).roundToInt()}",
                    fontSize = 11.sp,
                    color = fgSec
                )
            }
        }
        Row(
            // 底部留足一指宽的空隙（学飞牛：整排悬浮在页面底部上方，不贴边）
            Modifier.fillMaxWidth().padding(start = 34.dp, end = 34.dp, top = 24.dp, bottom = 52.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                when (playback.repeatMode) {
                    1 -> Icons.Rounded.RepeatOne
                    3 -> Icons.Rounded.Shuffle
                    else -> Icons.Rounded.Repeat
                },
                contentDescription = "播放模式：顺序/单曲循环/列表循环/随机",
                tint = if (playback.repeatMode == 0) fgSec else Palette.pink,
                modifier = Modifier.size(24.dp).clickable { onCycleRepeat() }
            )
            Spacer(Modifier.width(28.dp))
            Icon(
                Icons.Rounded.SkipPrevious,
                contentDescription = "上一首",
                tint = if (playback.hasPrevious || playback.positionMs > 3000) fg
                else fgSec,
                modifier = Modifier.size(32.dp).clickable { onPrevious() }
            )
            Spacer(Modifier.width(28.dp))
            Icon(
                if (playback.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                contentDescription = "播放/暂停",
                tint = fg,
                modifier = Modifier.size(46.dp).clickable { onToggle() }
            )
            Spacer(Modifier.width(28.dp))
            Icon(
                Icons.Rounded.SkipNext,
                contentDescription = "下一首",
                tint = if (playback.hasNext) fg else fgSec,
                modifier = Modifier.size(32.dp).clickable { onNext() }
            )
            Spacer(Modifier.width(28.dp))
            Icon(
                Icons.Rounded.VolumeUp,
                contentDescription = "音量调节",
                tint = if (showVolume) Palette.pink else fgSec,
                modifier = Modifier.size(24.dp).clickable { showVolume = !showVolume }
            )
        }
        }
    }
}

/**
 * 只有轨道、没有滑块的进度条 / 音量条。
 *
 * Material3 Slider 默认滑块是 44dp 高的竖条，用户觉得太长；
 * 换成小圆点又不好按，所以直接不画滑块：
 * 轨道统一 12dp（进度条和音量条一样粗），整条 44dp 高都是触摸区，点哪拖哪。
 */
@Composable
private fun CompactSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    onValueChangeFinished: (Float) -> Unit,
    inactiveColor: Color,
    modifier: Modifier = Modifier,
    activeColor: Color = Palette.pink,
    trackHeight: Dp = 12.dp,
    height: Dp = 44.dp
) {
    var widthPx by remember { mutableStateOf(1f) }
    var dragging by remember { mutableStateOf<Float?>(null) }
    val shown = (dragging ?: value).coerceIn(0f, 1f)

    Canvas(
        modifier
            .fillMaxWidth()
            .height(height)
            .onSizeChanged { widthPx = it.width.toFloat().coerceAtLeast(1f) }
            .pointerInput(Unit) {
                detectTapGestures { offset ->
                    val ratio = (offset.x / widthPx).coerceIn(0f, 1f)
                    onValueChange(ratio)
                    onValueChangeFinished(ratio)
                }
            }
            .pointerInput(Unit) {
                detectHorizontalDragGestures(
                    onDragStart = { offset ->
                        val ratio = (offset.x / widthPx).coerceIn(0f, 1f)
                        dragging = ratio
                        onValueChange(ratio)
                    },
                    onDragEnd = {
                        dragging?.let(onValueChangeFinished)
                        dragging = null
                    },
                    onDragCancel = { dragging = null }
                ) { change, _ ->
                    change.consume()
                    val ratio = (change.position.x / widthPx).coerceIn(0f, 1f)
                    dragging = ratio
                    onValueChange(ratio)
                }
            }
    ) {
        val track = trackHeight.toPx()
        val centerY = size.height / 2f
        val inset = track / 2f
        val usable = (size.width - inset * 2f).coerceAtLeast(1f)

        drawRoundRect(
            color = inactiveColor,
            topLeft = Offset(inset, centerY - track / 2f),
            size = Size(usable, track),
            cornerRadius = CornerRadius(track / 2f)
        )
        drawRoundRect(
            color = activeColor,
            topLeft = Offset(inset, centerY - track / 2f),
            size = Size(usable * shown, track),
            cornerRadius = CornerRadius(track / 2f)
        )
        // 不画滑块了：这根竖条在播放页上要么太长太抢眼、要么太短不好按，
        // 干脆只留一条已播放的进度色带。触摸区仍是整块 40dp 高，点哪拖哪都行。
    }
}

/** 没有封面 / 封面加载失败时的占位：淡渐变 + 音符 */
@Composable
private fun CoverFallback(iconSize: Dp) {
    val colors = LocalMptColors.current
    Box(
        Modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(
                    listOf(
                        Palette.pink.copy(alpha = 0.22f),
                        Palette.indigo.copy(alpha = 0.18f)
                    )
                )
            ),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            Icons.Rounded.LibraryMusic, null,
            tint = colors.textSecondary.copy(alpha = 0.8f),
            modifier = Modifier.size(iconSize)
        )
    }
}
