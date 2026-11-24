package com.moviepilottools.mptools.ui.music

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Cast
import androidx.compose.material.icons.rounded.CastConnected
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.moviepilottools.mptools.data.MusicPlaylist
import com.moviepilottools.mptools.data.MusicSong
import com.moviepilottools.mptools.data.MusicUiState
import com.moviepilottools.mptools.data.PlaybackState
import com.moviepilottools.mptools.data.formatDuration
import com.moviepilottools.mptools.ui.components.BasicField
import com.moviepilottools.mptools.ui.components.DividerLine
import com.moviepilottools.mptools.ui.components.EmptyHint
import com.moviepilottools.mptools.ui.components.OiiCard
import com.moviepilottools.mptools.ui.components.SectionHeader
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Metrics
import com.moviepilottools.mptools.vm.CastController
import com.moviepilottools.mptools.ui.theme.Palette
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged

/**
 * 音乐（Songloft）：歌曲库 / 歌单 / 搜索 / 本机播放。
 * 播放状态由 MusicViewModel 持有，切标签页不会断。
 */
@Composable
fun MusicScreen(
    state: MusicUiState,
    playback: PlaybackState,
    onOpenSettings: () -> Unit,
    onRefresh: () -> Unit,
    onStartSearch: () -> Unit,
    onExitSearch: () -> Unit,
    onSearch: (String) -> Unit,
    onPlay: (MusicSong) -> Unit,
    onPlayAll: () -> Unit,
    onOpenPlaylist: (MusicPlaylist) -> Unit,
    onClosePlaylist: () -> Unit,
    onLoadMore: () -> Unit,
    onToggleFavorite: (MusicSong) -> Unit,
    onCast: (com.moviepilottools.mptools.net.dlna.DlnaClient.Device) -> Unit,
    onTogglePlay: () -> Unit = {}
) {
    val colors = LocalMptColors.current
    val listState = rememberLazyListState()
    val songs = state.visibleSongs
    val castState by CastController.state.collectAsState()
    var showCast by remember { mutableStateOf(false) }
    val context = LocalContext.current

    // 安卓返回键 / 侧滑手势：专辑(歌单)详情、搜索态先逐层回退，别直接退出 App。
    // MoviePilot 页是分层回退（编辑→列表→详情→订阅→搜索），音乐页只有这两层。
    BackHandler(enabled = state.playlist != null || state.searchActive) {
        if (state.playlist != null) onClosePlaylist() else onExitSearch()
    }

    // 滑到底前 5 条就预取下一页。
    // 关键：layoutInfo 必须在 snapshotFlow 里读才会随滚动更新。之前把它直接放在
    // LaunchedEffect(listState, songs.size, total) 里，滚动时 effect 根本不会重跑，
    // 「全部歌曲」永远只停在第一页（60 首），后面的歌只能靠搜索才找得到。
    LaunchedEffect(listState) {
        snapshotFlow {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: 0
            last to info.totalItemsCount
        }
            .distinctUntilChanged()
            .collect { (lastVisible, totalItems) ->
                if (totalItems > 0 && lastVisible >= totalItems - 5) onLoadMore()
            }
    }

    Column(Modifier.fillMaxSize().background(colors.background)) {
        // ---------------------------------------------------------- 顶部
        Row(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (state.playlist != null) {
                Icon(
                    Icons.Rounded.ArrowBack, null,
                    tint = colors.textPrimary,
                    modifier = Modifier.size(20.dp).clickable { onClosePlaylist() }
                )
                Spacer(Modifier.width(12.dp))
            }
            Column(Modifier.weight(1f)) {
                Text(
                    state.playlist?.name ?: "音乐",
                    fontSize = if (state.playlist != null) 20.sp else 26.sp,
                    fontWeight = FontWeight.Bold,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    when {
                        !state.configured -> "尚未接入 Songloft"
                        state.playlist != null -> "${state.playlist.songCount} 首"
                        state.stats != null -> "${state.stats.totalSongs} 首 · ${state.stats.artistCount} 位歌手"
                        else -> state.serverLabel.ifBlank { "Songloft" }
                    },
                    fontSize = 11.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            if (state.configured) {
                Icon(
                    Icons.Rounded.Search, null,
                    tint = colors.textPrimary,
                    modifier = Modifier.size(21.dp).clickable {
                        if (state.searchActive) onExitSearch() else onStartSearch()
                    }
                )
                Spacer(Modifier.width(16.dp))
                Icon(
                    Icons.Rounded.Refresh, null,
                    tint = colors.textPrimary,
                    modifier = Modifier.size(21.dp).clickable { onRefresh() }
                )
                Spacer(Modifier.width(16.dp))
                // 投送：投送中图标变蓝并换成已连接样式
                Icon(
                    if (castState.casting) Icons.Rounded.CastConnected else Icons.Rounded.Cast, null,
                    tint = if (castState.casting) Palette.blue else colors.textPrimary,
                    modifier = Modifier.size(21.dp).clickable { showCast = true }
                )
            }
        }

        if (state.configured && state.searchActive) {
            SearchBar(
                query = state.query,
                onSearch = onSearch,
                onClose = onExitSearch
            )
        }

        // ---------------------------------------------------------- 主体
        when {
            !state.configured -> ConnectHint(onOpenSettings)

            state.loading && songs.isEmpty() -> Box(
                Modifier.fillMaxWidth().padding(top = 60.dp),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator(color = Palette.pink, strokeWidth = 2.dp, modifier = Modifier.size(24.dp))
            }

            state.error != null && songs.isEmpty() -> ErrorHint(state.error, onRefresh)

            else -> LazyColumn(
                state = listState,
                contentPadding = PaddingValues(bottom = 130.dp)
            ) {
                if (state.playlist == null && !state.searchActive) {
                    if (state.playlists.isNotEmpty()) {
                        item {
                            Spacer(Modifier.height(6.dp))
                            SectionHeader("歌单", trailing = {
                                Text("${state.playlists.size}", fontSize = 12.sp, color = colors.textSecondary)
                            })
                            Spacer(Modifier.height(8.dp))
                            LazyRow(
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                                contentPadding = PaddingValues(horizontal = Metrics.pagePadding)
                            ) {
                                items(state.playlists, key = { it.id }) { playlist ->
                                    PlaylistCard(playlist) { onOpenPlaylist(playlist) }
                                }
                            }
                            Spacer(Modifier.height(18.dp))
                        }
                    }

                    item {
                        SectionHeader(
                            if (state.query.isBlank()) "全部歌曲" else "搜索结果",
                            trailing = {
                                if (songs.isNotEmpty()) {
                                    Row(
                                        Modifier
                                            .clip(RoundedCornerShape(9.dp))
                                            .background(Palette.pink.copy(alpha = 0.12f))
                                            .clickable { onPlayAll() }
                                            .padding(horizontal = 9.dp, vertical = 5.dp),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Icon(
                                            Icons.Rounded.PlayArrow, null,
                                            tint = Palette.pink,
                                            modifier = Modifier.size(13.dp)
                                        )
                                        Spacer(Modifier.width(3.dp))
                                        Text("播放全部", fontSize = 11.sp, color = Palette.pink)
                                    }
                                }
                            }
                        )
                        Spacer(Modifier.height(8.dp))
                    }
                }

                if (songs.isEmpty()) {
                    item { EmptyHint(if (state.query.isBlank()) "音乐库里还没有歌曲" else "没搜到相关歌曲") }
                }

                itemsIndexed(songs, key = { _, song -> song.id }) { index, song ->
                    SongRow(
                        song = song,
                        playing = playback.current?.id == song.id,
                        favorite = song.id in state.favoriteIds,
                        onPlay = { onPlay(song) },
                        onToggleFavorite = { onToggleFavorite(song) }
                    )
                    if (index != songs.lastIndex) DividerLine(Modifier.padding(start = 16.dp + 48.dp + 11.dp))
                }

                if (state.loadingMore) {
                    item {
                        Box(Modifier.fillMaxWidth().padding(vertical = 14.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(
                                color = Palette.pink,
                                strokeWidth = 2.dp,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    }
                } else if (songs.isNotEmpty() && songs.size >= state.total && state.playlist == null) {
                    item {
                        Box(Modifier.fillMaxWidth().padding(vertical = 14.dp), contentAlignment = Alignment.Center) {
                            Text("已经到底了 · 共 ${songs.size} 首", fontSize = 11.sp, color = colors.textSecondary)
                        }
                    }
                }
            }
        }

        if (showCast) {
            CastDialog(
                state = castState,
                currentTitle = playback.current?.title.orEmpty(),
                onScan = { CastController.scan(context) },
                onCast = onCast,
                onStop = { CastController.stopCasting() },
                onDismiss = {
                    showCast = false
                    CastController.clearMessage()
                }
            )
        }
    }
}

@Composable
private fun SearchBar(query: String, onSearch: (String) -> Unit, onClose: () -> Unit) {
    val colors = LocalMptColors.current
    var draft by remember { mutableStateOf(query) }

    // 即时搜索：停止输入 0.4 秒后自动出结果，不用再点搜索按钮；
    // 键盘右下角的「搜索/完成」键也能立即搜。
    LaunchedEffect(draft) {
        if (draft.isBlank()) return@LaunchedEffect
        delay(400)
        onSearch(draft)
    }

    Row(
        Modifier.fillMaxWidth().padding(horizontal = Metrics.pagePadding, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 输入框：带描边和底色，一眼能看出这是能点的输入框
        Row(
            Modifier
                .weight(1f)
                .clip(RoundedCornerShape(10.dp))
                .background(colors.separator.copy(alpha = 0.35f))
                .border(1.dp, colors.accent.copy(alpha = 0.45f), RoundedCornerShape(10.dp))
                .padding(horizontal = 11.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                Icons.Rounded.Search, null,
                tint = colors.textSecondary,
                modifier = Modifier.size(16.dp)
            )
            Spacer(Modifier.width(7.dp))
            Box(Modifier.weight(1f)) {
                BasicField(
                    draft, "搜歌曲 / 歌手 / 专辑",
                    imeAction = ImeAction.Search,
                    onImeAction = { onSearch(draft) }
                ) { draft = it }
            }
            if (draft.isNotEmpty()) {
                Icon(
                    Icons.Rounded.Close, "清空",
                    tint = colors.textSecondary,
                    modifier = Modifier
                        .size(16.dp)
                        .clickable { draft = "" }
                )
            }
        }
        Spacer(Modifier.width(10.dp))
        Icon(
            Icons.Rounded.Close, "退出搜索",
            tint = colors.textSecondary,
            modifier = Modifier
                .size(22.dp)
                .clickable { onClose() }
        )
    }
    Spacer(Modifier.height(6.dp))
}

@Composable
private fun PlaylistCard(playlist: MusicPlaylist, onClick: () -> Unit) {
    val colors = LocalMptColors.current
    Column(
        Modifier.width(104.dp).clickable(onClick = onClick)
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(RoundedCornerShape(12.dp))
                .background(colors.separator)
        ) {
            if (playlist.coverUrl.isNotBlank()) {
                AsyncImage(
                    model = playlist.coverUrl,
                    contentDescription = playlist.name,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize()
                )
            } else {
                Icon(
                    Icons.Rounded.LibraryMusic, null,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(26.dp).align(Alignment.Center)
                )
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(
            playlist.name,
            fontSize = 12.sp,
            color = colors.textPrimary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            lineHeight = 16.sp
        )
        if (playlist.songCount > 0) {
            Text("${playlist.songCount} 首", fontSize = 10.sp, color = colors.textSecondary)
        }
    }
}

@Composable
private fun SongRow(
    song: MusicSong,
    playing: Boolean,
    favorite: Boolean,
    onPlay: () -> Unit,
    onToggleFavorite: () -> Unit
) {
    val colors = LocalMptColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onPlay)
            .padding(horizontal = Metrics.pagePadding, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier.size(48.dp).clip(RoundedCornerShape(9.dp)).background(colors.separator)
        ) {
            if (song.coverUrl.isNotBlank()) {
                AsyncImage(
                    model = song.coverUrl,
                    contentDescription = song.title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize()
                )
            } else {
                Icon(
                    Icons.Rounded.LibraryMusic, null,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(19.dp).align(Alignment.Center)
                )
            }
        }
        Spacer(Modifier.width(11.dp))
        Column(Modifier.weight(1f)) {
            Text(
                song.title,
                fontSize = 14.sp,
                fontWeight = if (playing) FontWeight.SemiBold else FontWeight.Normal,
                color = if (playing) Palette.pink else colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Spacer(Modifier.height(2.dp))
            Text(
                listOfNotNull(
                    song.artist.ifBlank { null },
                    song.album.ifBlank { null }
                ).joinToString(" · ").ifBlank { "未知歌手" },
                fontSize = 11.sp,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        Spacer(Modifier.width(8.dp))
        Icon(
            if (favorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
            contentDescription = if (favorite) "取消收藏" else "收藏",
            tint = if (favorite) Palette.pink else colors.textSecondary,
            modifier = Modifier
                .size(34.dp)
                .clip(CircleShape)
                .clickable(onClick = onToggleFavorite)
                .padding(7.dp)
        )
        Spacer(Modifier.width(4.dp))
        Text(formatDuration(song.durationSeconds), fontSize = 11.sp, color = colors.textSecondary)
    }
}

@Composable
private fun ConnectHint(onOpenSettings: () -> Unit) {
    val colors = LocalMptColors.current
    Box(Modifier.fillMaxWidth().padding(Metrics.pagePadding)) {
        OiiCard(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth().clickable(onClick = onOpenSettings), verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(34.dp)
                        .clip(RoundedCornerShape(9.dp))
                        .background(Palette.pink.copy(alpha = 0.14f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Rounded.LibraryMusic, null, tint = Palette.pink, modifier = Modifier.size(19.dp))
                }
                Spacer(Modifier.width(11.dp))
                Column(Modifier.weight(1f)) {
                    Text("接入 Songloft 音乐库", fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                    Spacer(Modifier.height(2.dp))
                    Text(
                        "设置 → 音乐服务，填 Songloft 地址和账号，这里就能浏览歌曲、歌单并在手机上播放。",
                        fontSize = 11.sp,
                        color = colors.textSecondary,
                        lineHeight = 16.sp
                    )
                }
                Text("去设置", fontSize = 13.sp, color = Palette.pink)
            }
        }
    }
}

@Composable
private fun ErrorHint(message: String, onRetry: () -> Unit) {
    val colors = LocalMptColors.current
    Box(Modifier.fillMaxWidth().padding(Metrics.pagePadding)) {
        OiiCard(Modifier.fillMaxWidth()) {
            Text("连不上音乐服务", fontSize = 14.sp, color = Palette.red)
            Spacer(Modifier.height(4.dp))
            Text(message, fontSize = 11.sp, color = colors.textSecondary, lineHeight = 16.sp)
            Spacer(Modifier.height(10.dp))
            Text(
                "重试",
                fontSize = 13.sp,
                color = Palette.pink,
                modifier = Modifier
                    .clip(RoundedCornerShape(9.dp))
                    .clickable(onClick = onRetry)
                    .padding(horizontal = 10.dp, vertical = 5.dp)
            )
        }
    }
}
