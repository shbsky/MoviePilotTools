package com.moviepilottools.mptools.ui.moviepilot

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Subscriptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.TextButton
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.compose.AsyncImagePainter
import com.moviepilottools.mptools.ui.components.OiiAlertDialog
import com.moviepilottools.mptools.data.MpMedia
import com.moviepilottools.mptools.data.MpServer
import com.moviepilottools.mptools.data.MpSubscribe
import com.moviepilottools.mptools.data.ResourceFilter
import com.moviepilottools.mptools.data.ResourceSortField
import com.moviepilottools.mptools.ui.components.BasicField
import com.moviepilottools.mptools.ui.components.EmptyHint
import com.moviepilottools.mptools.ui.components.OiiCard
import com.moviepilottools.mptools.ui.components.SelectablePill
import com.moviepilottools.mptools.ui.components.TinyPill
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Metrics
import com.moviepilottools.mptools.ui.theme.Palette
import com.moviepilottools.mptools.vm.MpChannels
import com.moviepilottools.mptools.vm.MpUiState

@Composable
fun MoviePilotScreen(
    state: MpUiState,
    onSelectChannel: (com.moviepilottools.mptools.data.MpDiscoverChannel) -> Unit,
    onLoadMore: () -> Unit,
    onRefresh: () -> Unit,
    onOpenDetail: (MpMedia) -> Unit,
    onCloseDetail: () -> Unit,
    onStartSearch: () -> Unit,
    onExitSearch: () -> Unit,
    onQueryChange: (String) -> Unit,
    onSearch: () -> Unit,
    onSearchResources: () -> Unit,
    onUpdateFilter: (ResourceFilter) -> Unit,
    onDownload: (com.moviepilottools.mptools.data.MpResource, String?, String?) -> Unit,
    onLoadDownloadOptions: () -> Unit,
    onSubscribe: (MpMedia?, Int?) -> Unit,
    onDeleteSubscribe: (Int) -> Unit,
    onToggleSubscribeState: (MpSubscribe) -> Unit,
    /** 打开订阅设置前先把选项（下载器 / 保存路径 / 站点 / 规则组）备齐 */
    onLoadSubscribeOptions: () -> Unit,
    /** 打开订阅列表时静默刷新一次（MP 网页改过的订阅要能同步过来） */
    onLoadSubscribes: () -> Unit = {},
    onSaveSubscribe: (MpSubscribe, (Boolean) -> Unit) -> Unit,
    onSearchSubscribe: (MpSubscribe) -> Unit,
    onResetSubscribe: (MpSubscribe) -> Unit,
    onOpenSubscribeMedia: (MpSubscribe) -> Unit,
    onSubscribeActivity: (MpSubscribe) -> Unit,
    onSubscribeFiles: (MpSubscribe) -> Unit,
    onCloseSubscribePanel: () -> Unit,
    onOpenServers: () -> Unit,
    onSelectServer: (String?) -> Unit,
    /** 由设置页跳进来时直接打开服务器列表（配置入口统一收在设置里） */
    autoOpenServers: Boolean = false,
    onAutoOpenConsumed: () -> Unit = {},
    /** 从设置页进来的：关掉服务器列表后回设置页，别把用户留在 MP 标签页 */
    returnToSettings: Boolean = false,
    onReturnToSettings: () -> Unit = {},
    onSaveServer: (MpServer) -> Unit,
    onDeleteServer: (String) -> Unit,
    onTestServer: suspend (MpServer) -> Result<String>
) {
    val colors = LocalMptColors.current
    var showServers by remember { mutableStateOf(false) }
    var showSubscribes by remember { mutableStateOf(false) }
    var editingServer by remember { mutableStateOf<MpServer?>(null) }
    /** true = 新增（编辑弹窗没有「已有对象」可传，单开一个标记区分新增 / 编辑） */
    var addingServer by remember { mutableStateOf(false) }
    var editingSub by remember { mutableStateOf<MpSubscribe?>(null) }

    LaunchedEffect(autoOpenServers) {
        if (autoOpenServers) {
            showServers = true
            onAutoOpenConsumed()
        }
    }

    // 关服务器列表：从设置页来的就一并切回设置页
    val closeServers: () -> Unit = {
        showServers = false
        if (returnToSettings) onReturnToSettings()
    }

    // 安卓返回键 / 侧滑手势：逐层回退，而不是直接退出 App。
    // 顺序必须和下面的渲染优先级一致（编辑页 → 服务器列表 → 详情 → 订阅 → 搜索）。
    BackHandler(
        enabled = addingServer || editingServer != null || editingSub != null || showServers ||
            state.detail != null || showSubscribes || state.searchActive
    ) {
        when {
            addingServer -> addingServer = false
            editingServer != null -> editingServer = null
            editingSub != null -> editingSub = null
            showServers -> closeServers()
            state.detail != null -> onCloseDetail()
            showSubscribes -> showSubscribes = false
            state.searchActive -> onExitSearch()
        }
    }

    if (showServers) {
        MpServerListScreen(
            servers = state.servers,
            activeId = state.activeServerId,
            error = state.error.orEmpty(),
            onBack = closeServers,
            onAdd = {
                addingServer = true
                editingServer = null
            },
            onEdit = {
                addingServer = false
                editingServer = it
            }
        )
        // 编辑页改成弹窗后，新增 / 编辑共用一颗：existing 为 null 就是新增
        if (addingServer || editingServer != null) {
            MpServerEditDialog(
                existing = editingServer,
                activeId = state.activeServerId,
                onDismiss = {
                    addingServer = false
                    editingServer = null
                },
                onSave = {
                    onSaveServer(it)
                    addingServer = false
                    editingServer = null
                    closeServers()
                },
                onDelete = {
                    onDeleteServer(it)
                    addingServer = false
                    editingServer = null
                    closeServers()
                },
                onTest = onTestServer,
                // 切换当前服务器收进编辑弹窗（列表行不再放「使用」胶囊）
                onMakeActive = { onSelectServer(it) }
            )
        }
        return
    }

    if (state.detail != null) {
        MediaDetailScreen(
            state = state,
            onBack = onCloseDetail,
            onSearchResources = onSearchResources,
            onUpdateFilter = onUpdateFilter,
            onDownload = onDownload,
            onLoadDownloadOptions = onLoadDownloadOptions,
            onSubscribe = onSubscribe,
            onOpenServers = onOpenServers
        )
        return
    }

    if (showSubscribes) {
        // 用户反馈：在 MP 网页改了订阅，App 里要退出重进才同步。
        // 这里每次打开订阅列表都静默拉一次（有本地值时不清空，只在返回后覆盖）。
        LaunchedEffect(Unit) { onLoadSubscribes() }
        SubscribeListScreen(
            state = state,
            onBack = { showSubscribes = false },
            onDelete = onDeleteSubscribe,
            onToggle = onToggleSubscribeState,
            onEdit = { sub ->
                onLoadSubscribeOptions()
                // 按 id 从当前列表取最新对象：列表项可能还攥着保存前的旧对象，
                // 直接拿它填表单会让人以为「保存没生效」
                editingSub = state.subscribes.firstOrNull { it.id == sub.id } ?: sub
            },
            onSearch = onSearchSubscribe,
            onReset = onResetSubscribe,
            onActivity = onSubscribeActivity,
            onMedia = onOpenSubscribeMedia,
            onFiles = onSubscribeFiles
        )
        editingSub?.let { sub ->
            SubscribeEditSheet(
                sub = sub,
                sites = state.site.sites,
                // 只允许挑 MP 系统设置里勾选过的订阅站点
                allowedSiteIds = state.rssSiteIds,
                downloaders = state.downloaders.map { it.name },
                savePaths = state.savePaths.map { it.savePath },
                ruleGroups = state.subscribeRuleGroups,
                onDismiss = { editingSub = null },
                onSave = { updated, done ->
                    onSaveSubscribe(updated) { ok ->
                        // 用户要求：保存成功后**停留在此页**（不再自动返回上一层）。
                        // 成功后页面上的表单就是刚提交的值；返回时列表已由本地回写 + 静默刷新更新。
                        done(ok)
                    }
                },
                onDelete = {
                    onDeleteSubscribe(sub.id)
                    editingSub = null
                }
            )
        }

        // 订阅活动 / 文件统计：只读信息，一个弹窗装下
        state.subscribePanel?.let { panel ->
            OiiAlertDialog(
                onDismissRequest = onCloseSubscribePanel,
                title = {
                    Text(
                        panel.title,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.textPrimary
                    )
                },
                text = {
                    when {
                        panel.loading -> Text("读取中…", fontSize = 13.sp, color = colors.textSecondary)
                        panel.error != null -> Text(panel.error, fontSize = 13.sp, color = Palette.red)
                        else -> LazyColumn(Modifier.heightIn(max = 420.dp)) {
                            items(panel.lines.size) { index ->
                                Text(
                                    panel.lines[index],
                                    fontSize = 12.sp,
                                    color = colors.textPrimary,
                                    modifier = Modifier.padding(vertical = 3.dp)
                                )
                            }
                        }
                    }
                },
                confirmButton = {
                    TextButton(onClick = onCloseSubscribePanel) { Text("关闭") }
                }
            )
        }
        return
    }

    if (state.searchActive) {
        SearchScreen(
            state = state,
            onBack = onExitSearch,
            onQueryChange = onQueryChange,
            onSearch = onSearch,
            onOpenDetail = onOpenDetail,
            onSubscribe = onSubscribe
        )
        return
    }

    Column(Modifier.fillMaxSize().background(colors.background)) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(start = Metrics.pagePadding, end = Metrics.pagePadding, top = 10.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Text("MoviePilot", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = colors.textPrimary)
                // 配置入口统一在「设置 → MoviePilot」，这里点服务器名也能直达，避免多一个图标按钮
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .clickable { showServers = true }
                        .padding(end = 4.dp)
                ) {
                    Text(
                        state.server?.displayName ?: "未配置服务器",
                        fontSize = 11.sp,
                        color = if (state.server == null) colors.accent else colors.textSecondary
                    )
                    Icon(
                        Icons.Rounded.ChevronRight, null,
                        tint = colors.textSecondary,
                        modifier = Modifier.size(11.dp)
                    )
                }
            }
            Icon(
                Icons.Rounded.Search, null,
                tint = colors.textPrimary,
                modifier = Modifier.size(21.dp).clickable { onStartSearch() }
            )
            Spacer(Modifier.width(16.dp))
            Icon(
                Icons.Rounded.Subscriptions, null,
                tint = colors.textPrimary,
                modifier = Modifier.size(21.dp).clickable { showSubscribes = true }
            )
        }

        if (state.servers.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(
                    Modifier.padding(horizontal = 34.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Box(
                        Modifier
                            .size(64.dp)
                            .clip(RoundedCornerShape(20.dp))
                            .background(Palette.blue.copy(alpha = 0.12f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(Icons.Rounded.Dns, null, tint = Palette.blue, modifier = Modifier.size(30.dp))
                    }
                    Spacer(Modifier.height(16.dp))
                    Text("还没有配置 MoviePilot", fontSize = 17.sp, color = colors.textPrimary)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "填上 MP 的访问地址和 API Token，就能在这里浏览豆瓣/TMDB 榜单、\n跨站点搜资源、一键投递和订阅。",
                        fontSize = 12.sp,
                        color = colors.textSecondary,
                        textAlign = TextAlign.Center,
                        lineHeight = 19.sp
                    )
                    Spacer(Modifier.height(18.dp))
                    Row(
                        Modifier
                            .clip(RoundedCornerShape(18.dp))
                            .background(Palette.blue)
                            .clickable { showServers = true }
                            .padding(horizontal = 18.dp, vertical = 9.dp)
                    ) {
                        Text("添加 MoviePilot", fontSize = 13.sp, color = Color.White)
                    }
                }
            }
            return@Column
        }

        LazyRow(
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Metrics.pagePadding),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(vertical = 6.dp)
        ) {
            items(MpChannels.all.size) { index ->
                val channel = MpChannels.all[index]
                SelectablePill(
                    text = channel.title,
                    selected = state.channel.key == channel.key,
                    onClick = { onSelectChannel(channel) }
                )
            }
        }

        when {
            state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Palette.blue, strokeWidth = 2.5.dp)
            }

            state.error != null && state.items.isEmpty() -> Box(
                Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(state.error ?: "", fontSize = 13.sp, color = Palette.red, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(10.dp))
                    Row(
                        Modifier
                            .clip(RoundedCornerShape(14.dp))
                            .background(colors.card)
                            .clickable { onRefresh() }
                            .padding(horizontal = 14.dp, vertical = 7.dp)
                    ) {
                        Text("重试", fontSize = 12.sp, color = Palette.blue)
                    }
                }
            }

            else -> LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    start = Metrics.pagePadding,
                    end = Metrics.pagePadding,
                    top = 4.dp,
                    bottom = 110.dp
                ),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                items(state.items, key = { it.mediaId + (it.season ?: 0) }) { media ->
                    PosterCard(
                        media = media,
                        onClick = { onOpenDetail(media) },
                        subscribed = state.isSubscribed(media),
                        onSubscribe = { onSubscribe(media, media.season) }
                    )
                }
                if (state.hasMore && state.items.isNotEmpty()) {
                    item {
                        LaunchedEffect(state.items.size) { onLoadMore() }
                        Box(Modifier.fillMaxWidth().height(40.dp), contentAlignment = Alignment.Center) {
                            if (state.loadingMore) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    strokeWidth = 2.dp,
                                    color = Palette.blue
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun PosterCard(
    media: MpMedia,
    onClick: () -> Unit,
    subscribed: Boolean = false,
    onSubscribe: (() -> Unit)? = null
) {
    val colors = LocalMptColors.current
    var posterFailed by remember(media.posterUrl) { mutableStateOf(false) }
    Column(Modifier.clickable { onClick() }) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(0.68f)
                .clip(RoundedCornerShape(10.dp))
                .background(brush = posterFallback(media.title))
        ) {
            if (media.posterUrl.isNotBlank() && !posterFailed) {
                AsyncImage(
                    model = media.posterUrl,
                    contentDescription = media.title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                    onState = { state ->
                        if (state is AsyncImagePainter.State.Error) posterFailed = true
                    }
                )
            }
            if (media.posterUrl.isBlank() || posterFailed) {
                Text(
                    media.title,
                    fontSize = 11.sp,
                    color = Color.White.copy(alpha = 0.9f),
                    textAlign = TextAlign.Center,
                    maxLines = 4,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.align(Alignment.Center).padding(6.dp)
                )
            }
            if (media.vote > 0) {
                Box(
                    Modifier
                        .align(Alignment.TopStart)
                        .padding(5.dp)
                        .clip(RoundedCornerShape(6.dp))
                        .background(Color(0xCC000000))
                        .padding(horizontal = 5.dp, vertical = 2.dp)
                ) {
                    Text(
                        String.format(java.util.Locale.US, "%.1f", media.vote),
                        fontSize = 10.sp,
                        color = Color(0xFFFFD60A),
                        fontWeight = FontWeight.Medium
                    )
                }
            }
            if (media.isTV && media.season != null) {
                Box(
                    Modifier
                        .align(Alignment.BottomEnd)
                        .padding(5.dp)
                        .clip(RoundedCornerShape(6.dp))
                        .background(Color(0xCC000000))
                        .padding(horizontal = 5.dp, vertical = 2.dp)
                ) {
                    Text("S${media.season}", fontSize = 9.sp, color = Color.White)
                }
            }
            if (onSubscribe != null) {
                Box(
                    Modifier
                        .align(Alignment.BottomStart)
                        .padding(5.dp)
                        .clip(RoundedCornerShape(7.dp))
                        .background(if (subscribed) Color(0xE634C759) else Color(0xE6000000))
                        .clickable(enabled = !subscribed) { onSubscribe() }
                        .padding(horizontal = 6.dp, vertical = 3.dp)
                ) {
                    Text(
                        if (subscribed) "已订阅" else "+ 订阅",
                        fontSize = 9.sp,
                        color = Color.White,
                        fontWeight = FontWeight.Medium
                    )
                }
            }
        }
        Spacer(Modifier.height(5.dp))
        Text(
            media.title,
            fontSize = 11.sp,
            color = colors.textPrimary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            lineHeight = 15.sp
        )
    }
}

fun posterFallback(seed: String): Brush {
    val palettes = listOf(
        listOf(Color(0xFF2F6FED), Color(0xFF7B4BF5)),
        listOf(Color(0xFF0EA5A4), Color(0xFF2F6FED)),
        listOf(Color(0xFFF97316), Color(0xFFDB2777)),
        listOf(Color(0xFF6D28D9), Color(0xFF1D4ED8)),
        listOf(Color(0xFF059669), Color(0xFF0891B2))
    )
    val index = (seed.hashCode() and 0x7FFFFFFF) % palettes.size
    return Brush.linearGradient(palettes[index])
}

// ---------- 搜索页 ----------

@Composable
private fun SearchScreen(
    state: MpUiState,
    onBack: () -> Unit,
    onQueryChange: (String) -> Unit,
    onSearch: () -> Unit,
    onOpenDetail: (MpMedia) -> Unit,
    onSubscribe: (MpMedia?, Int?) -> Unit
) {
    val colors = LocalMptColors.current
    Column(Modifier.fillMaxSize().background(colors.background)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Metrics.pagePadding, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                Icons.Rounded.ArrowBack, null,
                tint = colors.textPrimary,
                modifier = Modifier.size(22.dp).clickable { onBack() }
            )
            Spacer(Modifier.width(10.dp))
            Box(Modifier.weight(1f)) {
                BasicField(state.searchQuery, "搜索电影、剧集名称") { onQueryChange(it) }
            }
            Spacer(Modifier.width(8.dp))
            Row(
                Modifier
                    .clip(RoundedCornerShape(10.dp))
                    .background(Palette.blue)
                    .clickable { onSearch() }
                    .padding(horizontal = 12.dp, vertical = 10.dp)
            ) {
                Text("搜索", fontSize = 12.sp, color = Color.White)
            }
        }

        when {
            state.searching -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Palette.blue, strokeWidth = 2.5.dp)
            }

            state.searchResults.isEmpty() -> EmptyHint("输入片名后点搜索")

            else -> LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    start = Metrics.pagePadding, end = Metrics.pagePadding, bottom = 110.dp
                ),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                items(state.searchResults, key = { it.mediaId }) { media ->
                    PosterCard(
                        media = media,
                        onClick = { onOpenDetail(media) },
                        subscribed = state.isSubscribed(media),
                        onSubscribe = { onSubscribe(media, media.season) }
                    )
                }
            }
        }
    }
}

// ---------- 订阅列表 ----------

@Composable
private fun SubscribeListScreen(
    state: MpUiState,
    onBack: () -> Unit,
    onDelete: (Int) -> Unit,
    onToggle: (MpSubscribe) -> Unit,
    onEdit: (MpSubscribe) -> Unit,
    onSearch: (MpSubscribe) -> Unit,
    onReset: (MpSubscribe) -> Unit,
    onActivity: (MpSubscribe) -> Unit,
    onMedia: (MpSubscribe) -> Unit,
    onFiles: (MpSubscribe) -> Unit
) {
    val colors = LocalMptColors.current
    // 重置 / 取消订阅都要二次确认：一个会清掉已完成集数，一个会把订阅连记录一起删
    var pendingReset by remember { mutableStateOf<MpSubscribe?>(null) }
    var pendingDelete by remember { mutableStateOf<MpSubscribe?>(null) }
    Column(Modifier.fillMaxSize().background(colors.background)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Metrics.pagePadding, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                Icons.Rounded.ArrowBack, null,
                tint = colors.textPrimary,
                modifier = Modifier.size(22.dp).clickable { onBack() }
            )
            Spacer(Modifier.width(10.dp))
            Text("订阅（与 MP 网页同一份数据）", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
        }

        if (state.subscribes.isEmpty()) {
            EmptyHint(if (state.subscribesLoading) "加载中…" else "还没有订阅，在详情页点「订阅」即可")
            return@Column
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = Metrics.pagePadding, end = Metrics.pagePadding,
                top = 2.dp, bottom = 110.dp
            ),
            verticalArrangement = Arrangement.spacedBy(9.dp)
        ) {
            items(state.subscribes.size) { index ->
                val sub = state.subscribes[index]
                OiiCard(modifier = Modifier.fillMaxWidth(), padding = 11.dp) {
                    // 点整行直接进编辑（用户要求：不用每次去点右上角三个点）；
                    // 右侧「⋮」仍是独立菜单，点它不会触发这里（内层 clickable 先消费事件）
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { onEdit(sub) },
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            Modifier
                                .size(width = 46.dp, height = 66.dp)
                                .clip(RoundedCornerShape(7.dp))
                                .background(posterFallback(sub.name))
                        ) {
                            if (sub.posterUrl.isNotBlank()) {
                                AsyncImage(
                                    model = sub.posterUrl,
                                    contentDescription = null,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize()
                                )
                            }
                        }
                        Spacer(Modifier.width(10.dp))
                        Column(Modifier.weight(1f)) {
                            Text(
                                sub.name + if (sub.season != null && sub.season > 0) " S${sub.season}" else "",
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Medium,
                                color = colors.textPrimary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Spacer(Modifier.height(3.dp))
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                TinyPill(
                                    sub.stateLabel,
                                    if (sub.state.uppercase() == "R") Palette.green.copy(alpha = 0.15f)
                                    else Palette.orange.copy(alpha = 0.15f),
                                    if (sub.state.uppercase() == "R") Palette.green else Palette.orange
                                )
                                Spacer(Modifier.width(5.dp))
                                Text(sub.progressText, fontSize = 10.sp, color = colors.textSecondary)
                                if (sub.bestVersion) {
                                    Spacer(Modifier.width(5.dp))
                                    TinyPill("洗版", Palette.purple.copy(alpha = 0.15f), Palette.purple)
                                }
                            }
                            if (sub.type == "电视剧" && sub.totalEpisode > 0) {
                                Spacer(Modifier.height(5.dp))
                                com.moviepilottools.mptools.ui.components.ThinProgress(
                                    progress = sub.progress,
                                    color = Palette.green
                                )
                            }
                        }
                        Spacer(Modifier.width(6.dp))
                        Box {
                            var menuOpen by remember { mutableStateOf(false) }
                            Icon(
                                Icons.Rounded.MoreVert, "更多操作",
                                tint = colors.textSecondary,
                                modifier = Modifier
                                    .size(20.dp)
                                    .clickable { menuOpen = true }
                            )
                            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                                SubMenuItem("编辑") { menuOpen = false; onEdit(sub) }
                                SubMenuItem("立即搜索") { menuOpen = false; onSearch(sub) }
                                SubMenuItem(if (sub.state.uppercase() == "R") "暂停" else "恢复") {
                                    menuOpen = false; onToggle(sub)
                                }
                                SubMenuItem("重置") { menuOpen = false; pendingReset = sub }
                                SubMenuItem("订阅活动") { menuOpen = false; onActivity(sub) }
                                SubMenuItem("媒体详情") { menuOpen = false; onMedia(sub) }
                                SubMenuItem("文件统计") { menuOpen = false; onFiles(sub) }
                                SubMenuItem("取消订阅", Palette.red) { menuOpen = false; pendingDelete = sub }
                            }
                        }
                    }
                }
            }
        }
    }

    pendingReset?.let { sub ->
        OiiAlertDialog(
            onDismissRequest = { pendingReset = null },
            title = { Text("重置订阅", fontSize = 16.sp) },
            text = {
                Text(
                    "重新开始搜索《${sub.name}》？已完成集数会被清空，已下载的文件不受影响。",
                    fontSize = 13.sp,
                    color = colors.textPrimary
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    pendingReset = null
                    onReset(sub)
                }) { Text("确认重置", color = Palette.orange) }
            },
            dismissButton = {
                TextButton(onClick = { pendingReset = null }) { Text("再想想") }
            }
        )
    }

    pendingDelete?.let { sub ->
        OiiAlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("取消订阅", fontSize = 16.sp) },
            text = {
                Text(
                    "从 MoviePilot 里删除《${sub.name}》这条订阅？已下载的文件不受影响。",
                    fontSize = 13.sp,
                    color = colors.textPrimary
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    pendingDelete = null
                    onDelete(sub.id)
                }) { Text("确认取消", color = Palette.red) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("再想想") }
            }
        )
    }
}

/** 订阅卡片右上角菜单的一行 */
@Composable
private fun SubMenuItem(text: String, color: Color? = null, onClick: () -> Unit) {
    DropdownMenuItem(
        text = {
            Text(
                text,
                fontSize = 13.sp,
                color = color ?: LocalMptColors.current.textPrimary
            )
        },
        onClick = onClick
    )
}
