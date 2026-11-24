package com.moviepilottools.mptools.ui.sites

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.FilterList
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.compose.AsyncImagePainter
import com.moviepilottools.mptools.data.MpResource
import com.moviepilottools.mptools.data.MpSavePath
import com.moviepilottools.mptools.data.MpSite
import com.moviepilottools.mptools.data.MpSiteUserData
import com.moviepilottools.mptools.data.SiteSort
import com.moviepilottools.mptools.data.formatRelativeTime
import com.moviepilottools.mptools.data.formatStorageSize
import com.moviepilottools.mptools.ui.components.OiiCard
import com.moviepilottools.mptools.ui.components.SelectablePill
import com.moviepilottools.mptools.ui.components.softShadow
import com.moviepilottools.mptools.ui.components.TinyPill
import com.moviepilottools.mptools.ui.moviepilot.posterFallback
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Metrics
import com.moviepilottools.mptools.ui.theme.Palette
import com.moviepilottools.mptools.vm.MpSiteState
import com.moviepilottools.mptools.vm.MpViewModel
import java.util.Locale

/**
 * 站点详情：分类 chips + 单列种子列表（左侧小海报，照 PT Mate 的版式）。
 *
 * 种子接口是同步阻塞的（MP 真的去爬站点网页），慢站点 5~30 秒，所以：
 * 首屏没数据时显示「已等待 Ns + 取消」，翻页时只在底部转圈，列表不被清空。
 */
@Composable
fun SiteDetailScreen(
    site: MpSiteState,
    downloaders: List<String>,
    savePaths: List<MpSavePath>,
    lastDownloader: String?,
    lastSavePath: String?,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onSearchInput: (String) -> Unit,
    onSubmitSearch: () -> Unit,
    onToggleCategory: (String) -> Unit,
    onClearCategories: () -> Unit,
    onSortChange: (SiteSort) -> Unit,
    onLoadMore: () -> Unit,
    onCancelBrowse: () -> Unit,
    onLoadDownloadOptions: () -> Unit,
    downloadSubmitting: Boolean,
    downloadError: String?,
    downloadDone: String?,
    onClearDownloadResult: () -> Unit,
    onDownload: (MpResource, String?, String?) -> Unit,
    onLoadIcon: suspend (Int) -> Any?,
    /** 种子详情页的 MP 侧内容（识别 → 详情 → 演职员），失败返回空即可 */
    onLoadTorrentMedia: suspend (String) -> MpViewModel.TorrentMediaInfo = { MpViewModel.TorrentMediaInfo() }
) {
    val colors = LocalMptColors.current
    val current = site.openSite
    var detail by remember { mutableStateOf<MpResource?>(null) }
    var downloadTarget by remember { mutableStateOf<MpResource?>(null) }
    val uriHandler = LocalUriHandler.current

    if (current == null) {
        Box(Modifier.fillMaxSize().background(colors.background), contentAlignment = Alignment.Center) {
            Text("站点已关闭", fontSize = 13.sp, color = colors.textSecondary)
        }
        return
    }

    Box(Modifier.fillMaxSize()) {
    Column(
        Modifier
            .fillMaxSize()
            .background(colors.background)
    ) {
        Header(
            site = current,
            onBack = onBack,
            onRefresh = onRefresh,
            onLoadIcon = onLoadIcon
        )

        // 该站账号数据（MP 抓取的，不是实时）。没有就一句话带过，不占版面。
        // 站点数据项多（等级/分享率/上传/下载/做种/魔力/更新时间），一行放不下会被截成「魔力 77…」，
        // 所以给两行 —— 宁可多占 14dp，也别让用户看不到自己的数据。
        val userData = site.userData[current.id]
        Text(
            text = userData?.let { accountLine(it) } ?: "该站暂无账号数据（MP 未抓取或 Cookie 失效）",
            fontSize = 10.5.sp,
            color = colors.textSecondary,
            maxLines = 2,
            lineHeight = 15.sp,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Metrics.pagePadding)
                .padding(bottom = 2.dp)
        )

        SearchField(
            query = site.searchInput,
            onQueryChange = onSearchInput,
            onSubmit = onSubmitSearch
        )

        if (site.categories.isNotEmpty()) {
            LazyRow(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp),
                contentPadding = PaddingValues(horizontal = Metrics.pagePadding),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                item(key = "all") {
                    SelectablePill("全部", site.isAllCategories) {
                        if (!site.isAllCategories) onClearCategories()
                    }
                }
                itemsIndexed(
                    site.categories,
                    // 兜底再带上 index：万一 MP 又给出两个同 cat 的分类，也不能撞 key 崩掉
                    key = { index, category -> "cat-$index-${category.value}" }
                ) { _, category ->
                    // 单选：点谁就只看谁，再点一次退回「全部」
                    SelectablePill(category.label, category.value in site.selectedCats) {
                        onToggleCategory(category.value)
                    }
                }
            }
            // 站点索引器不支持 cat 时，筛选点了也不会变 —— 如实说明，别让用户以为筛选生效了
            if (site.catIgnored && !site.browsing) {
                Text(
                    text = "该站点没有按分类过滤（MP 侧忽略了 cat 参数），下面仍然是全部种子。",
                    fontSize = 10.sp,
                    color = Palette.orange,
                    lineHeight = 14.sp,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = Metrics.pagePadding)
                        .padding(top = 6.dp)
                )
            }
        }

        if (site.torrents.isNotEmpty() || !site.browsing) {
            SortRow(
                count = site.torrents.size,
                hasMore = site.hasMore,
                sort = site.sort,
                onSortChange = onSortChange
            )
        }

        Spacer(Modifier.height(6.dp))

        when {
            // 首屏等待：告诉用户在动，并且能取消（切站点会触发 MP 侧流控，不能干等）
            site.browsing && site.torrents.isEmpty() -> {
                WaitingBlock(
                    seconds = site.elapsedSeconds,
                    onCancel = onCancelBrowse
                )
                Spacer(Modifier.height(10.dp))
                // 骨架屏：空白页会让人以为「这个站什么都没有」，先画出卡片的形状
                SkeletonRows()
            }

            site.torrents.isEmpty() && site.browseError != null -> ErrorBlock(
                message = site.browseError,
                onRetry = onRefresh
            )

            site.torrents.isEmpty() -> Box(
                Modifier.fillMaxWidth().padding(vertical = 48.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    when {
                        site.keyword.isNotBlank() -> "没有匹配「${site.keyword}」的种子"
                        site.selectedCats.isNotEmpty() -> "这个分类下没有种子"
                        else -> "这个站点还没有种子"
                    },
                    fontSize = 13.sp,
                    color = colors.textSecondary
                )
            }

            else -> LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    start = Metrics.pagePadding,
                    end = Metrics.pagePadding,
                    bottom = 110.dp
                ),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(site.sortedTorrents, key = { it.key }) { resource ->
                    TorrentRow(
                        resource = resource,
                        poster = site.posters[resource.key],
                        onClick = { detail = resource },
                        onLongClick = {
                            onClearDownloadResult()
                            onLoadDownloadOptions()
                            downloadTarget = resource
                        }
                    )
                }
                if (site.hasMore) {
                    item(key = "footer") {
                        // 列表到底自动翻页；用 size 做 key，避免每次重组都发请求
                        if (!site.browsing) {
                            LaunchedEffect(site.torrents.size) { onLoadMore() }
                        }
                        Row(
                            Modifier.fillMaxWidth().padding(vertical = 14.dp),
                            horizontalArrangement = Arrangement.Center,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            CircularProgressIndicator(
                                color = Palette.blue,
                                strokeWidth = 1.5.dp,
                                modifier = Modifier.size(14.dp)
                            )
                            Spacer(Modifier.width(8.dp))
                            Text("正在加载更多…", fontSize = 12.sp, color = colors.textSecondary)
                        }
                    }
                } else if (site.torrents.isNotEmpty()) {
                    item(key = "end") {
                        // MP 没有「总数」接口，翻到空页才知道到底，这里告诉用户已经翻完了
                        Text(
                            "已到站点最后一页 · 共 ${site.torrents.size} 条",
                            fontSize = 11.sp,
                            color = colors.textSecondary.copy(alpha = 0.75f),
                            textAlign = TextAlign.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 16.dp)
                        )
                    }
                }
            }
        }
    }

        // 全屏详情盖在列表上方：列表保持组合，返回时滚动位置不丢
        detail?.let { resource ->
            SiteTorrentDetailScreen(
                resource = resource,
                poster = site.posters[resource.key],
                siteName = current.name,
                onLoadTorrentMedia = onLoadTorrentMedia,
                onBack = { detail = null },
                onDownload = {
                    onClearDownloadResult()
                    onLoadDownloadOptions()
                    downloadTarget = resource
                },
                onOpenUrl = {
                    if (resource.pageUrl.isNotBlank()) {
                        runCatching { uriHandler.openUri(resource.pageUrl) }
                    }
                }
            )
        }

        // 投递面板放最后，保证盖在详情页之上
        downloadTarget?.let { target ->
            SiteDownloadSheet(
                resource = target,
                downloaders = downloaders,
                savePaths = savePaths,
                defaultDownloader = lastDownloader,
                defaultSavePath = lastSavePath,
                submitting = downloadSubmitting,
                error = downloadError,
                done = downloadDone,
                onDismiss = {
                    downloadTarget = null
                    onClearDownloadResult()
                },
                onConfirm = { downloader, savePath ->
                    // 不关面板：就地显示「正在提交 → 已推送 / 失败」，用户才知道到底成没成
                    onDownload(target, downloader, savePath)
                }
            )
        }
    }
}

@Composable
private fun Header(
    site: MpSite,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onLoadIcon: suspend (Int) -> Any?
) {
    val colors = LocalMptColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.pagePadding, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(34.dp)
                .clip(CircleShape)
                .background(colors.card)
                .clickable(onClick = onBack),
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.Rounded.ArrowBack, null, tint = colors.textPrimary, modifier = Modifier.size(19.dp))
        }
        Spacer(Modifier.width(10.dp))
        SiteAvatar(site = site, onLoadIcon = onLoadIcon, size = 30.dp, corner = 9.dp)
        Spacer(Modifier.width(9.dp))
        Column(Modifier.weight(1f)) {
            Text(
                site.name,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (site.displayDomain.isNotBlank()) {
                Text(
                    site.displayDomain,
                    fontSize = 11.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
        IconButton(onClick = onRefresh, modifier = Modifier.size(34.dp)) {
            Icon(Icons.Rounded.Refresh, null, tint = colors.textPrimary, modifier = Modifier.size(19.dp))
        }
    }
}

@Composable
private fun SearchField(query: String, onQueryChange: (String) -> Unit, onSubmit: () -> Unit) {
    val colors = LocalMptColors.current
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.pagePadding)
            .height(38.dp)
            .clip(RoundedCornerShape(11.dp))
            .background(colors.card),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Spacer(Modifier.width(11.dp))
        Icon(Icons.Rounded.Search, null, tint = colors.textSecondary, modifier = Modifier.size(17.dp))
        Spacer(Modifier.width(7.dp))
        Box(Modifier.weight(1f)) {
            if (query.isEmpty()) {
                Text("搜索这个站点…", fontSize = 14.sp, color = colors.textSecondary)
            }
            BasicTextField(
                value = query,
                onValueChange = onQueryChange,
                singleLine = true,
                textStyle = TextStyle(fontSize = 14.sp, color = colors.textPrimary),
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                    imeAction = androidx.compose.ui.text.input.ImeAction.Search
                ),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(
                    // 搜完就收键盘，结果列表要能整屏看
                    onSearch = {
                        focusManager.clearFocus()
                        keyboard?.hide()
                        onSubmit()
                    }
                ),
                modifier = Modifier.fillMaxWidth()
            )
        }
        if (query.isNotEmpty()) {
            Icon(
                Icons.Rounded.Close,
                null,
                tint = colors.textSecondary,
                modifier = Modifier
                    .size(16.dp)
                    .clickable {
                        onQueryChange("")
                        onSubmit()
                    }
            )
            Spacer(Modifier.width(6.dp))
        }
        Text(
            "搜索",
            fontSize = 12.sp,
            color = colors.accent,
            modifier = Modifier
                .clickable { onSubmit() }
                .padding(horizontal = 8.dp, vertical = 4.dp)
        )
        Spacer(Modifier.width(4.dp))
    }
}

@Composable
private fun WaitingBlock(seconds: Int, onCancel: () -> Unit) {
    val colors = LocalMptColors.current
    OiiCard(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.pagePadding),
        padding = 18.dp
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(
                color = Palette.blue,
                strokeWidth = 2.dp,
                modifier = Modifier.size(18.dp)
            )
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    "正在浏览站点…",
                    fontSize = 14.sp,
                    color = colors.textPrimary
                )
                Spacer(Modifier.height(3.dp))
                Text(
                    when {
                        seconds >= 60 -> "已等待 ${seconds}s，这站几乎肯定抓不到了，建议取消换个站"
                        seconds >= 25 -> "已等待 ${seconds}s，慢站首次抓取要 30~90 秒，可以再等等"
                        seconds >= 3 -> "已等待 ${seconds}s，站点越快出得越快"
                        else -> "已等待 ${seconds}s"
                    },
                    fontSize = 11.sp,
                    color = if (seconds >= 60) Palette.orange else colors.textSecondary,
                    lineHeight = 15.sp
                )
            }
            Text(
                "取消",
                fontSize = 13.sp,
                color = colors.accent,
                modifier = Modifier
                    .clickable(onClick = onCancel)
                    .padding(horizontal = 6.dp, vertical = 4.dp)
            )
        }
    }
}

/**
 * 等待时的骨架屏。
 *
 * 之前首屏没数据就一片空白，用户会以为「这个站是空的」或者「App 卡了」；
 * 画出三张卡片的轮廓，一眼就知道是在加载。
 */
@Composable
private fun SkeletonRows() {
    val colors = LocalMptColors.current
    val block = colors.separator.copy(alpha = 0.45f)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.pagePadding),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        repeat(3) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(13.dp))
                    .background(colors.card)
                    .padding(9.dp)
            ) {
                Box(
                    Modifier
                        .width(56.dp)
                        .height(84.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(block)
                )
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Box(
                        Modifier
                            .fillMaxWidth(0.92f)
                            .height(11.dp)
                            .clip(RoundedCornerShape(4.dp))
                            .background(block)
                    )
                    Spacer(Modifier.height(6.dp))
                    Box(
                        Modifier
                            .fillMaxWidth(0.62f)
                            .height(11.dp)
                            .clip(RoundedCornerShape(4.dp))
                            .background(block)
                    )
                    Spacer(Modifier.height(10.dp))
                    Box(
                        Modifier
                            .fillMaxWidth(0.45f)
                            .height(9.dp)
                            .clip(RoundedCornerShape(4.dp))
                            .background(block)
                    )
                    Spacer(Modifier.height(12.dp))
                    Box(
                        Modifier
                            .fillMaxWidth(0.7f)
                            .height(9.dp)
                            .clip(RoundedCornerShape(4.dp))
                            .background(block)
                    )
                }
            }
        }
    }
}

/**
 * 分类下面那一行：左边是已加载条数，右边是排序/筛选。
 *
 * MP 网页版「浏览」弹窗右侧那四个选项（最新发布 / 资源大小 / 做种最多 / 下载最多）。
 * MP 的浏览接口没有排序参数，所以这里是纯客户端排序 —— 只对已经翻下来的那几页重排，
 * 不会为了换个顺序再让 MP 去爬一遍站点。
 */
@Composable
private fun SortRow(
    count: Int,
    hasMore: Boolean,
    sort: SiteSort,
    onSortChange: (SiteSort) -> Unit
) {
    val colors = LocalMptColors.current
    var menu by remember { mutableStateOf(false) }
    val active = sort != SiteSort.LATEST

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.pagePadding)
            .padding(top = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = if (hasMore) "已加载 $count 条" else "共 $count 条",
            fontSize = 11.sp,
            color = colors.textSecondary,
            modifier = Modifier.weight(1f)
        )
        Box {
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(9.dp))
                    .background(if (active) colors.accent.copy(alpha = 0.12f) else colors.card)
                    .clickable { menu = true }
                    .padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    Icons.Rounded.FilterList,
                    null,
                    tint = if (active) colors.accent else colors.textSecondary,
                    modifier = Modifier.size(13.dp)
                )
                Spacer(Modifier.width(4.dp))
                Text(
                    sort.label,
                    fontSize = 11.sp,
                    color = if (active) colors.accent else colors.textPrimary,
                    maxLines = 1
                )
                Icon(
                    Icons.Rounded.ExpandMore,
                    null,
                    tint = if (active) colors.accent else colors.textSecondary,
                    modifier = Modifier.size(14.dp)
                )
            }
            DropdownMenu(menu, onDismissRequest = { menu = false }) {
                SiteSort.entries.forEach { item ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                item.label,
                                fontSize = 13.sp,
                                color = if (item == sort) colors.accent else colors.textPrimary
                            )
                        },
                        onClick = {
                            menu = false
                            onSortChange(item)
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun ErrorBlock(message: String, onRetry: () -> Unit) {
    val colors = LocalMptColors.current
    OiiCard(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.pagePadding),
        padding = 16.dp
    ) {
        Text("浏览失败", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
        Spacer(Modifier.height(6.dp))
        Text(message, fontSize = 12.sp, color = colors.textSecondary, lineHeight = 18.sp)
        Spacer(Modifier.height(10.dp))
        Text(
            "重试",
            fontSize = 13.sp,
            color = colors.accent,
            modifier = Modifier.clickable(onClick = onRetry)
        )
    }
}

@OptIn(ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)
@Composable
private fun TorrentRow(
    resource: MpResource,
    poster: String?,
    onClick: () -> Unit,
    onLongClick: () -> Unit
) {
    val colors = LocalMptColors.current
    var posterFailed by remember(poster) { mutableStateOf(false) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            // 弱悬浮（仪表盘强度的一半）：先画阴影再 clip，clip 不会裁掉前面的 drawBehind
            .softShadow(13.dp, intensity = 0.5f, isDark = colors.isDark)
            .clip(RoundedCornerShape(13.dp))
            .background(colors.card)
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(9.dp)
    ) {
        Box(
            Modifier
                .width(56.dp)
                .height(84.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(posterFallback(resource.title))
        ) {
            if (!poster.isNullOrBlank() && !posterFailed) {
                AsyncImage(
                    model = poster,
                    contentDescription = resource.title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                    onState = { state ->
                        if (state is AsyncImagePainter.State.Error) posterFailed = true
                    }
                )
            } else {
                Text(
                    resource.title.take(1).uppercase(),
                    color = Color.White.copy(alpha = 0.9f),
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.align(Alignment.Center)
                )
            }
            if (resource.isFree) {
                Box(
                    Modifier
                        .align(Alignment.TopStart)
                        .padding(3.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(Palette.green)
                        .padding(horizontal = 4.dp, vertical = 1.dp)
                ) {
                    Text("FREE", color = Color.White, fontSize = 8.sp, fontWeight = FontWeight.Bold)
                }
            }
        }

        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                resource.title,
                fontSize = 12.5.sp,
                fontWeight = FontWeight.Medium,
                color = colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                lineHeight = 17.sp
            )

            // 标签序列交给 MpResource.badges()（搜索页同一套），
            // 以前这里只取 labels.take(2) 再 take(4)，中字/国语/特效永远显示不全
            val badges = resource.badges().map { it to resourceBadgeTint(it, resource) }
            if (badges.isNotEmpty()) {
                Spacer(Modifier.height(4.dp))
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    badges.forEach { (text, tint) ->
                        TinyPill(text, tint.copy(alpha = 0.15f), tint)
                    }
                }
            }

            val sub = resource.subtitle
            if (sub.isNotBlank()) {
                Spacer(Modifier.height(4.dp))
                Text(
                    sub,
                    fontSize = 11.sp,
                    color = colors.textSecondary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    lineHeight = 15.sp
                )
            }

            Spacer(Modifier.height(5.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Rounded.ArrowUpward,
                    null,
                    tint = Palette.green,
                    modifier = Modifier.size(10.dp)
                )
                Text(" ${resource.seeders}", fontSize = 11.sp, color = colors.textSecondary)
                Spacer(Modifier.width(7.dp))
                Icon(
                    Icons.Rounded.ArrowDownward,
                    null,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(10.dp)
                )
                Text(" ${resource.peers}", fontSize = 11.sp, color = colors.textSecondary)
                Spacer(Modifier.width(9.dp))
                Text(formatStorageSize(resource.sizeBytes), fontSize = 11.sp, color = colors.textSecondary)
                // 发布时间靠右对齐（和鸿蒙一致）：中间用一个 weight 撑开，
                // 右侧时间和卡片右边距对齐，扫一列时不会跟着左侧数字长短跳动
                Spacer(Modifier.weight(1f))
                Text(
                    formatRelativeTime(resource.pubDateMs),
                    fontSize = 11.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
    }
}

/** 站点账号一行摘要：等级 · 分享率 · ↑ · ↓ · 做种 · 魔力 · 更新时间 */
private fun accountLine(data: MpSiteUserData): String = buildString {
    if (data.userLevel.isNotBlank()) append(data.userLevel).append(" · ")
    append("分享率 ").append(data.ratioText)
    append(" · ↑").append(formatStorageSize(data.upload))
    append(" · ↓").append(formatStorageSize(data.download))
    append(" · 做种 ").append(data.seeding)
    if (data.bonus > 0) append(" · 魔力 ").append(bonusText(data.bonus))
    if (data.updatedText.isNotBlank()) append(" · ").append(data.updatedText)
}

private fun bonusText(value: Double): String =
    if (value >= 10_000) String.format(Locale.US, "%.1f万", value / 10_000) else value.toLong().toString()

/** 标签配色：促销橙/免费绿、H&R 红、制作组灰、分辨率薄荷、来源靛、字幕蓝 */
private fun resourceBadgeTint(text: String, r: MpResource): Color = when {
    text.contains("免费") -> Palette.green
    text.contains("%") || Regex("^[0-9.]+X").containsMatchIn(text) -> Palette.orange
    text == "H&R" || text.contains("禁") -> Palette.red
    text == r.group -> Palette.gray
    text == r.resolution -> Palette.mint
    text == r.quality -> Palette.indigo
    else -> Palette.blue
}
