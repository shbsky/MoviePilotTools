package com.moviepilottools.mptools.ui.moviepilot

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.CloudDownload
import androidx.compose.material.icons.rounded.FilterList
import androidx.compose.material.icons.rounded.ManageSearch
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.compose.AsyncImagePainter
import com.moviepilottools.mptools.data.MpMedia
import com.moviepilottools.mptools.data.MpResource
import com.moviepilottools.mptools.data.ResourceFilter
import com.moviepilottools.mptools.data.ResourceSortField
import com.moviepilottools.mptools.data.formatBytes
import com.moviepilottools.mptools.data.formatRelativeTime
import com.moviepilottools.mptools.ui.components.ElevatedCard
import com.moviepilottools.mptools.ui.components.EmptyHint
import com.moviepilottools.mptools.ui.components.OiiCard
import com.moviepilottools.mptools.ui.components.SelectablePill
import com.moviepilottools.mptools.ui.components.TinyPill
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Metrics
import com.moviepilottools.mptools.ui.theme.Palette
import com.moviepilottools.mptools.vm.MpUiState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MediaDetailScreen(
    state: MpUiState,
    onBack: () -> Unit,
    onSearchResources: () -> Unit,
    onUpdateFilter: (ResourceFilter) -> Unit,
    onDownload: (MpResource, String?, String?) -> Unit,
    onLoadDownloadOptions: () -> Unit,
    onSubscribe: (MpMedia?, Int?) -> Unit,
    onOpenServers: () -> Unit
) {
    val colors = LocalMptColors.current
    val media = state.detail ?: return
    var expandOverview by remember { mutableStateOf(true) }
    var posterFailed by remember(media.posterUrl) { mutableStateOf(false) }
    var showFilter by remember { mutableStateOf(false) }
    var showSort by remember { mutableStateOf(false) }
    var downloadTarget by remember { mutableStateOf<MpResource?>(null) }

    val filtered = state.filteredResources
    val subscribed = state.isSubscribed(media)
    // 演职员：MP 的 credits 优先；拿不到时退回详情自带的导演 + 主演，
    // 保证这一块不会整块消失（鸿蒙端同款逻辑）
    val creditNames: List<String> = if (state.credits.isNotEmpty()) {
        state.credits.map { it.name }.filter { it.isNotBlank() }.distinct()
    } else {
        (media.directors + media.cast).filter { it.isNotBlank() }.distinct()
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize().background(colors.background),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = Metrics.pagePadding, end = Metrics.pagePadding,
            top = 8.dp, bottom = 110.dp
        ),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Rounded.ArrowBack, null,
                    tint = colors.textPrimary,
                    modifier = Modifier.size(22.dp).clickable { onBack() }
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    media.title,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }

        // 海报 + 基本信息
        item {
            Row {
                Box(
                    Modifier
                        .width(96.dp)
                        .aspectRatio(0.68f)
                        .clip(RoundedCornerShape(10.dp))
                        .background(posterFallback(media.title))
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
                            color = Color.White,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                            maxLines = 4,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.align(Alignment.Center).padding(6.dp)
                        )
                    }
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(media.title, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
                    Spacer(Modifier.height(4.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            listOfNotNull(
                                media.yearLabel.takeIf { it.isNotBlank() },
                                media.typeLabel
                            ).joinToString(" · "),
                            fontSize = 11.sp,
                            color = colors.textSecondary
                        )
                        if (media.vote > 0) {
                            Spacer(Modifier.width(6.dp))
                            Text(
                                String.format(java.util.Locale.US, "★ %.1f", media.vote),
                                fontSize = 11.sp,
                                color = Color(0xFFFF9500)
                            )
                        }
                    }
                    if (media.genres.isNotEmpty()) {
                        Spacer(Modifier.height(6.dp))
                        Text(
                            media.genres.take(4).joinToString(" / "),
                            fontSize = 11.sp,
                            color = colors.textSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    if (media.directors.isNotEmpty()) {
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "导演：${media.directors.take(2).joinToString("、")}",
                            fontSize = 11.sp,
                            color = colors.textSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    if (media.cast.isNotEmpty()) {
                        Spacer(Modifier.height(2.dp))
                        Text(
                            "主演：${media.cast.take(3).joinToString("、")}",
                            fontSize = 11.sp,
                            color = colors.textSecondary,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(
                            Modifier
                                .clip(RoundedCornerShape(10.dp))
                                .background(
                                    if (subscribed) Palette.green.copy(alpha = 0.14f)
                                    else Palette.blue
                                )
                                .clickable(enabled = !subscribed) { onSubscribe(media, media.season) }
                                .padding(horizontal = 12.dp, vertical = 7.dp)
                        ) {
                            Text(
                                if (subscribed) "已订阅" else "订阅",
                                fontSize = 12.sp,
                                color = if (subscribed) Palette.green else Color.White
                            )
                        }
                        Box(
                            Modifier
                                .clip(RoundedCornerShape(10.dp))
                                .background(Palette.blue.copy(alpha = 0.12f))
                                .clickable { onSearchResources() }
                                .padding(horizontal = 12.dp, vertical = 7.dp)
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    Icons.Rounded.Refresh, null,
                                    tint = Palette.blue,
                                    modifier = Modifier.size(12.dp)
                                )
                                Spacer(Modifier.width(4.dp))
                                Text(
                                    when {
                                        state.resourcesLoading -> "搜索中"
                                        state.resourceSearched -> "重新搜索"
                                        else -> "搜资源"
                                    },
                                    fontSize = 12.sp, color = Palette.blue
                                )
                            }
                        }
                    }
                }
            }
        }

        if (media.overview.isNotBlank()) {
            item {
                ElevatedCard(
                    modifier = Modifier.fillMaxWidth(),
                    padding = 13.dp,
                    subtle = true,
                    corner = 18.dp
                ) {
                    Text(
                        media.overview,
                        fontSize = 12.sp,
                        color = colors.textSecondary,
                        lineHeight = 18.sp,
                        maxLines = if (expandOverview) Int.MAX_VALUE else 4,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        if (expandOverview) "收起" else "展开",
                        fontSize = 11.sp,
                        color = Palette.blue,
                        modifier = Modifier.padding(top = 4.dp).clickable { expandOverview = !expandOverview }
                    )
                }
            }
        }

        if (creditNames.isNotEmpty()) {
            item {
                ElevatedCard(
                    modifier = Modifier.fillMaxWidth(),
                    padding = 13.dp,
                    subtle = true,
                    corner = 18.dp
                ) {
                    Text("演职员", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        creditNames.take(12).joinToString("、"),
                        fontSize = 11.sp,
                        color = colors.textSecondary,
                        lineHeight = 17.sp
                    )
                }
            }
        }

        // 资源区标题
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("候选资源", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
                Spacer(Modifier.width(6.dp))
                Text(
                    if (state.resources.isEmpty()) "" else "${filtered.size}/${state.resources.size}",
                    fontSize = 11.sp,
                    color = colors.textSecondary
                )
                Spacer(Modifier.weight(1f))
                // 还没搜过时不显示排序/筛选，避免空列表上一堆没用的控件
                if (state.resourceSearched) {
                Box {
                    Row(
                        Modifier
                            .clip(RoundedCornerShape(10.dp))
                            .background(colors.card)
                            .clickable { showSort = true }
                            .padding(horizontal = 9.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(state.filter.sortField.label, fontSize = 11.sp, color = colors.textPrimary)
                        Text(if (state.filter.descending) " ↓" else " ↑", fontSize = 11.sp, color = colors.textSecondary)
                    }
                    DropdownMenu(expanded = showSort, onDismissRequest = { showSort = false }) {
                        ResourceSortField.entries.forEach { field ->
                            DropdownMenuItem(
                                text = { Text(field.label, fontSize = 13.sp) },
                                onClick = {
                                    showSort = false
                                    onUpdateFilter(
                                        state.filter.copy(
                                            sortField = field,
                                            descending = if (state.filter.sortField == field) !state.filter.descending else true
                                        )
                                    )
                                }
                            )
                        }
                    }
                }
                Spacer(Modifier.width(8.dp))
                Row(
                    Modifier
                        .clip(RoundedCornerShape(10.dp))
                        .background(
                            if (state.filter.activeCount > 0) Palette.blue.copy(alpha = 0.14f) else colors.card
                        )
                        .clickable { showFilter = true }
                        .padding(horizontal = 9.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        Icons.Rounded.FilterList, null,
                        tint = if (state.filter.activeCount > 0) Palette.blue else colors.textSecondary,
                        modifier = Modifier.size(13.dp)
                    )
                    if (state.filter.activeCount > 0) {
                        Spacer(Modifier.width(3.dp))
                        Text("${state.filter.activeCount}", fontSize = 11.sp, color = Palette.blue)
                    }
                }
                }
            }
        }

        if (state.resourcesLoading) {
            item {
                Column(Modifier.fillMaxWidth().padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = Palette.blue, strokeWidth = 2.5.dp, modifier = Modifier.size(28.dp))
                    Spacer(Modifier.height(10.dp))
                    Text(
                        state.searchStage.ifBlank { "正在向各站点发起搜索…" },
                        fontSize = 12.sp,
                        color = colors.textSecondary
                    )
                    if (state.resources.isNotEmpty()) {
                        Spacer(Modifier.height(4.dp))
                        Text("已返回 ${state.resources.size} 个", fontSize = 11.sp, color = Palette.green)
                    }
                    Spacer(Modifier.height(6.dp))
                    Text("站点多时可能要几十秒，可以边等边看", fontSize = 10.sp, color = colors.textSecondary)
                }
            }
        }

        // 只看了简介、还没点「搜资源」时的占位提示（不再自动搜站点）
        if (!state.resourcesLoading && !state.resourceSearched && state.resources.isEmpty() && state.resourceError == null) {
            item {
                Column(
                    Modifier.fillMaxWidth().padding(vertical = 26.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Icon(
                        Icons.Rounded.ManageSearch, null,
                        tint = colors.textSecondary.copy(alpha = 0.55f),
                        modifier = Modifier.size(30.dp)
                    )
                    Spacer(Modifier.height(10.dp))
                    Text("还没搜索资源", fontSize = 13.sp, color = colors.textPrimary)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "想找片源时，点上面的「搜资源」再开始搜索。",
                        fontSize = 11.sp,
                        color = colors.textSecondary
                    )
                }
            }
        }

        state.resourceError?.let { message ->
            item {
                OiiCard(modifier = Modifier.fillMaxWidth()) {
                    Text(message, fontSize = 12.sp, color = Palette.red, lineHeight = 18.sp)
                    if (state.server?.hasLogin != true) {
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "提示：MP 只填 API Token 时用的是阻塞式搜索，要等所有站点搜完才出结果；填上 MP 用户名密码可以改成边搜边显示。",
                            fontSize = 11.sp,
                            color = colors.textSecondary,
                            lineHeight = 17.sp
                        )
                    }
                }
            }
        }

        if (!state.resourcesLoading && filtered.isEmpty() && state.resourceError == null && state.resources.isNotEmpty()) {
            item { EmptyHint("当前筛选条件下没有资源，试试放宽条件") }
        }

        items(filtered.size) { index ->
            val resource = filtered[index]
            ResourceRow(resource = resource, onDownload = {
                downloadTarget = resource
                onLoadDownloadOptions()
            })
        }
    }

    if (showFilter) {
        FilterSheet(
            filter = state.filter,
            sites = state.sites,
            resolutions = state.resolutions,
            qualities = state.qualities,
            codecs = state.codecs,
            subtitles = state.subtitles,
            groups = state.groups,
            promotions = state.promotions,
            matched = filtered.size,
            total = state.resources.size,
            onDismiss = { showFilter = false },
            // 点选即回写，列表在弹层后面实时刷新；弹层保持打开，方便连续多选
            onChange = { onUpdateFilter(it) }
        )
    }

    downloadTarget?.let { target ->
        DownloadSheet(
            resource = target,
            downloaders = state.downloaders.map { it.name },
            savePaths = state.savePaths.map { it.savePath },
            defaultDownloader = state.downloaders.firstOrNull()?.name,
            defaultSavePath = state.savePaths.firstOrNull()?.savePath,
            onDismiss = { downloadTarget = null },
            onConfirm = { downloader, savePath ->
                onDownload(target, downloader, savePath)
                downloadTarget = null
            }
        )
    }
}

/** 标签配色：促销橙/免费绿、H&R 红、制作组灰、分辨率紫、来源靛、字幕/效果蓝 */
private fun resourceBadgeTint(text: String, r: MpResource): Color = when {
    text.contains("免费") -> Palette.green
    text.contains("%") || Regex("^[0-9.]+X").containsMatchIn(text) -> Palette.orange
    text == "H&R" || text.contains("禁") -> Palette.red
    text == r.group -> Palette.gray
    text == r.resolution -> Palette.purple
    text == r.quality -> Palette.indigo
    else -> Palette.blue
}

@Composable
private fun ResourceRow(resource: MpResource, onDownload: () -> Unit) {
    val colors = LocalMptColors.current
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        padding = 13.dp,
        subtle = true,
        corner = 18.dp
    ) {
        Text(
            resource.title,
            fontSize = 12.sp,
            color = colors.textPrimary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            lineHeight = 17.sp
        )
        Spacer(Modifier.height(6.dp))
        // 标签行（对齐 MP 搜索结果）：
        // MP labels（中字/国语/特效…）→ 分辨率 → 来源 → 制作组 → 促销/免费，
        // 顺序由 MpResource.badges() 统一给出，这里只负责画。
        FlowRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            TinyPill(resource.siteName, Palette.blue.copy(alpha = 0.12f), Palette.blue)
            resource.badges().forEach { text ->
                val tint = resourceBadgeTint(text, resource)
                TinyPill(text, tint.copy(alpha = 0.12f), tint)
            }
        }
        // 副标题：站点 description 优先，搜索接口不给时用「小组·来源·编码」兜底
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
        Spacer(Modifier.height(6.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(formatBytes(resource.sizeBytes), fontSize = 11.sp, color = colors.textSecondary)
            Text(" · 种 ${resource.seeders}", fontSize = 11.sp, color = Palette.green)
            Text(" · 下 ${resource.peers}", fontSize = 11.sp, color = colors.textSecondary)
            if (resource.pubDateMs > 0) {
                Text(" · ${formatRelativeTime(resource.pubDateMs)}", fontSize = 11.sp, color = colors.textSecondary)
            }
            Spacer(Modifier.weight(1f))
            Row(
                Modifier
                    .clip(RoundedCornerShape(10.dp))
                    .background(Palette.blue)
                    .clickable { onDownload() }
                    .padding(horizontal = 11.dp, vertical = 5.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(Icons.Rounded.CloudDownload, null, tint = Color.White, modifier = Modifier.size(12.dp))
                Spacer(Modifier.width(3.dp))
                Text("下载", fontSize = 11.sp, color = Color.White)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FilterSheet(
    filter: ResourceFilter,
    sites: List<String>,
    resolutions: List<String>,
    qualities: List<String>,
    codecs: List<String>,
    subtitles: List<String>,
    groups: List<String>,
    promotions: List<String>,
    matched: Int,
    total: Int,
    onDismiss: () -> Unit,
    onChange: (ResourceFilter) -> Unit
) {
    val colors = LocalMptColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.background
    ) {
        // 内容可滚动 + 避开导航栏。
        // 站点 30+ / 制作组 20+ 时整块面板超过一屏，底部两个开关会被切掉点不到。
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("筛选资源", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
                    // 弹层遮住了列表，这里直接回显命中数，点一下就看得见效果
                    Text(
                        "点选即生效 · 命中 $matched/$total",
                        fontSize = 11.sp,
                        color = colors.textSecondary
                    )
                }
                // 没有「应用」按钮：每次点选都已生效；重置只清条件，完成只是收起面板
                TextButton(onClick = { onChange(filter.cleared()) }) {
                    Text(
                        "重置",
                        color = if (filter.activeCount > 0) Palette.blue else colors.textSecondary
                    )
                }
                TextButton(onClick = onDismiss) {
                    Text("完成", color = Palette.blue, fontWeight = FontWeight.Medium)
                }
            }

            FilterGroup("站点", sites, filter.sites) { onChange(filter.copy(sites = it)) }
            FilterGroup("标签", subtitles, filter.subtitles) { onChange(filter.copy(subtitles = it)) }
            FilterGroup("制作组", groups, filter.groups) { onChange(filter.copy(groups = it)) }
            FilterGroup("促销", promotions, filter.promotions) { onChange(filter.copy(promotions = it)) }
            FilterGroup("分辨率", resolutions, filter.resolutions) { onChange(filter.copy(resolutions = it)) }
            FilterGroup("质量", qualities, filter.qualities) { onChange(filter.copy(qualities = it)) }
            FilterGroup("编码", codecs, filter.codecs) { onChange(filter.copy(codecs = it)) }

            Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("只看免费 / 促销", fontSize = 13.sp, color = colors.textPrimary)
                Spacer(Modifier.weight(1f))
                Switch(filter.promotionOnly, { onChange(filter.copy(promotionOnly = it)) })
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("隐藏 H&R", fontSize = 13.sp, color = colors.textPrimary)
                Spacer(Modifier.weight(1f))
                Switch(filter.hideHitAndRun, { onChange(filter.copy(hideHitAndRun = it)) })
            }
        }
    }
}

/**
 * 一组可多选的标签：选中为并集关系，「全部」= 清空该组。
 * 用 FlowRow 自动换行，站点多的时候不用横向滑着找。
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FilterGroup(
    title: String,
    options: List<String>,
    selected: Set<String>,
    onChange: (Set<String>) -> Unit
) {
    if (options.isEmpty()) return
    Text(title, fontSize = 12.sp, color = LocalMptColors.current.textSecondary, modifier = Modifier.padding(top = 10.dp))
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 6.dp)
    ) {
        SelectablePill(text = "全部", selected = selected.isEmpty(), onClick = { onChange(emptySet()) })
        options.forEach { option ->
            val isOn = option in selected
            SelectablePill(text = option, selected = isOn, onClick = {
                // 单击选中、再点取消
                onChange(if (isOn) selected - option else selected + option)
            })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DownloadSheet(
    resource: MpResource,
    downloaders: List<String>,
    savePaths: List<String>,
    defaultDownloader: String?,
    defaultSavePath: String?,
    onDismiss: () -> Unit,
    onConfirm: (String?, String?) -> Unit
) {
    val colors = LocalMptColors.current
    var downloader by remember { mutableStateOf(defaultDownloader) }
    var savePath by remember { mutableStateOf(defaultSavePath) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.background
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 26.dp)
        ) {
            Text("投递到下载器", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
            Spacer(Modifier.height(6.dp))
            Text(
                resource.title,
                fontSize = 11.sp,
                color = colors.textSecondary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
            Spacer(Modifier.height(4.dp))
            Text(
                "${resource.siteName} · ${formatBytes(resource.sizeBytes)} · ${resource.seeders} 个做种",
                fontSize = 11.sp,
                color = colors.textSecondary
            )

            if (downloaders.isNotEmpty()) {
                Text("下载器", fontSize = 12.sp, color = colors.textSecondary, modifier = Modifier.padding(top = 14.dp))
                androidx.compose.foundation.lazy.LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.padding(top = 6.dp)
                ) {
                    items(downloaders.size) { index ->
                        val name = downloaders[index]
                        SelectablePill(text = name, selected = downloader == name, onClick = { downloader = name })
                    }
                }
            }

            if (savePaths.isNotEmpty()) {
                Text("保存路径", fontSize = 12.sp, color = colors.textSecondary, modifier = Modifier.padding(top = 12.dp))
                androidx.compose.foundation.lazy.LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.padding(top = 6.dp)
                ) {
                    items(savePaths.size) { index ->
                        val path = savePaths[index]
                        SelectablePill(text = path, selected = savePath == path, onClick = { savePath = path })
                    }
                }
            }

            Spacer(Modifier.height(18.dp))
            Box(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(13.dp))
                    .background(Palette.blue)
                    .clickable { onConfirm(downloader, savePath) }
                    .padding(vertical = 13.dp),
                contentAlignment = Alignment.Center
            ) {
                Text("确认下载", fontSize = 14.sp, color = Color.White, fontWeight = FontWeight.Medium)
            }
            Spacer(Modifier.height(8.dp))
            Text(
                "由 MoviePilot 决定投递方式，会带上站点 cookie 与种子原始信息。",
                fontSize = 10.sp,
                color = colors.textSecondary
            )
        }
    }
}
