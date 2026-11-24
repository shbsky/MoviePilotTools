package com.moviepilottools.mptools.ui.automation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CloudDownload
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.RssFeed
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
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
import com.moviepilottools.mptools.ui.components.OiiAlertDialog
import com.moviepilottools.mptools.data.RssItemRecord
import com.moviepilottools.mptools.data.RssSource
import com.moviepilottools.mptools.data.ServerConfig
import com.moviepilottools.mptools.data.formatBytes
import com.moviepilottools.mptools.data.formatRelativeTime
import com.moviepilottools.mptools.ui.components.DividerLine
import com.moviepilottools.mptools.ui.components.EmptyHint
import com.moviepilottools.mptools.ui.components.OiiCard
import com.moviepilottools.mptools.ui.components.TinyPill
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Metrics
import com.moviepilottools.mptools.ui.theme.Palette
import com.moviepilottools.mptools.vm.RssUiState

private enum class AutomationMode(val label: String) {
    SOURCES("源"),
    ALL_ITEMS("全部条目")
}

@Composable
fun AutomationScreen(
    state: RssUiState,
    servers: List<ServerConfig>,
    presetPaths: List<String>,
    onSaveSource: (RssSource) -> Unit,
    onDeleteSource: (String) -> Unit,
    onToggleSource: (String, Boolean) -> Unit,
    onRefreshSource: (String) -> Unit,
    onRefreshAll: () -> Unit,
    onPushItem: (String, RssItemRecord) -> Unit,
    onTest: suspend (RssSource) -> Result<Pair<Int, List<RssItemRecord>>>
) {
    val colors = LocalMptColors.current
    var mode by remember { mutableStateOf(AutomationMode.SOURCES) }
    var editing by remember { mutableStateOf<RssSource?>(null) }
    var detailId by remember { mutableStateOf<String?>(null) }

    val detail = detailId?.let { id -> state.sources.firstOrNull { it.id == id } }

    if (detail != null) {
        SourceDetailContent(
            source = detail,
            items = state.itemsOf(detail.id),
            refreshing = state.refreshing.contains(detail.id),
            onBack = { detailId = null },
            onRefresh = { onRefreshSource(detail.id) },
            onEdit = { editing = detail },
            onPushItem = { onPushItem(detail.id, it) },
            onDelete = {
                onDeleteSource(detail.id)
                detailId = null
            }
        )
        if (editing != null) {
            SourceEditorSheet(
                initial = editing!!,
                servers = servers,
                presetPaths = presetPaths,
                onDismiss = { editing = null },
                onSave = {
                    onSaveSource(it)
                    editing = null
                },
                onTest = onTest
            )
        }
        return
    }

    Column(Modifier.fillMaxSize().background(colors.background)) {
        // 顶部标题 + 全部刷新
        Row(
            Modifier
                .fillMaxWidth()
                .padding(start = Metrics.pagePadding, end = Metrics.pagePadding, top = 10.dp, bottom = 2.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("自动化 RSS", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = colors.textPrimary)
            Spacer(Modifier.weight(1f))
            Row(
                Modifier
                    .clip(RoundedCornerShape(16.dp))
                    .background(colors.card)
                    .clickable(enabled = !state.refreshingAll) { onRefreshAll() }
                    .padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (state.refreshingAll) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(13.dp),
                        strokeWidth = 2.dp,
                        color = Palette.blue
                    )
                } else {
                    Icon(Icons.Rounded.Refresh, null, tint = Palette.blue, modifier = Modifier.size(14.dp))
                }
                Spacer(Modifier.width(5.dp))
                Text(
                    if (state.refreshingAll) "检查中" else "全部刷新",
                    fontSize = 12.sp,
                    color = Palette.blue
                )
            }
        }

        // 分段切换
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = Metrics.pagePadding, vertical = 8.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(colors.card)
                .padding(3.dp)
        ) {
            AutomationMode.entries.forEach { item ->
                val active = item == mode
                Box(
                    Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(9.dp))
                        .background(if (active) colors.accent else Color.Transparent)
                        .clickable { mode = item }
                        .padding(vertical = 7.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        item.label,
                        fontSize = 13.sp,
                        fontWeight = if (active) FontWeight.Medium else FontWeight.Normal,
                        color = if (active) Color.White else colors.textSecondary
                    )
                }
            }
        }

        when (mode) {
            AutomationMode.SOURCES -> SourcesGrid(
                state = state,
                onOpen = { detailId = it },
                onRefresh = onRefreshSource,
                onEdit = { editing = it },
                onToggle = onToggleSource,
                onAdd = { editing = RssSource() }
            )

            AutomationMode.ALL_ITEMS -> AllItemsList(
                state = state,
                onPush = { sourceId, item -> onPushItem(sourceId, item) }
            )
        }
    }

    if (editing != null) {
        SourceEditorSheet(
            initial = editing!!,
            servers = servers,
            presetPaths = presetPaths,
            onDismiss = { editing = null },
            onSave = {
                onSaveSource(it)
                editing = null
            },
            onTest = onTest
        )
    }
}

// ---------- 源列表 ----------

@Composable
private fun SourcesGrid(
    state: RssUiState,
    onOpen: (String) -> Unit,
    onRefresh: (String) -> Unit,
    onEdit: (RssSource) -> Unit,
    onToggle: (String, Boolean) -> Unit,
    onAdd: () -> Unit
) {
    val colors = LocalMptColors.current
    if (state.sources.isEmpty()) {
        Column(
            Modifier.fillMaxSize().padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Box(
                Modifier
                    .size(64.dp)
                    .clip(RoundedCornerShape(20.dp))
                    .background(Palette.blue.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Rounded.RssFeed, null, tint = Palette.blue, modifier = Modifier.size(30.dp))
            }
            Spacer(Modifier.height(16.dp))
            Text("还没有 RSS 源", fontSize = 17.sp, color = colors.textPrimary)
            Spacer(Modifier.height(6.dp))
            Text(
                "添加站点订阅链接（例如 https://your-site.example/rss.php?token=...），\n命中规则的种子会自动推送到下载器。",
                fontSize = 12.sp,
                color = colors.textSecondary,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                lineHeight = 19.sp
            )
            Spacer(Modifier.height(18.dp))
            Row(
                Modifier
                    .clip(RoundedCornerShape(18.dp))
                    .background(Palette.blue)
                    .clickable { onAdd() }
                    .padding(horizontal = 18.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(Icons.Rounded.Add, null, tint = Color.White, modifier = Modifier.size(15.dp))
                Spacer(Modifier.width(5.dp))
                Text("添加 RSS 源", fontSize = 13.sp, color = Color.White)
            }
        }
        return
    }

    LazyVerticalGrid(
        columns = GridCells.Fixed(2),
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = Metrics.pagePadding,
            end = Metrics.pagePadding,
            top = 4.dp,
            bottom = 110.dp
        ),
        horizontalArrangement = Arrangement.spacedBy(Metrics.cardGap),
        verticalArrangement = Arrangement.spacedBy(Metrics.cardGap)
    ) {
        items(state.sources, key = { it.id }) { source ->
            SourceCard(
                source = source,
                unread = state.unreadOf(source.id),
                total = state.itemsOf(source.id).size,
                refreshing = state.refreshing.contains(source.id),
                onOpen = { onOpen(source.id) },
                onRefresh = { onRefresh(source.id) },
                onEdit = { onEdit(source) },
                onToggle = { onToggle(source.id, it) }
            )
        }
        item {
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(150.dp)
                    .clip(RoundedCornerShape(Metrics.tileRadius))
                    .background(colors.card)
                    .border(1.dp, colors.separator, RoundedCornerShape(Metrics.tileRadius))
                    .clickable { onAdd() },
                contentAlignment = Alignment.Center
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Rounded.Add, null, tint = Palette.blue, modifier = Modifier.size(24.dp))
                    Spacer(Modifier.height(6.dp))
                    Text("添加源", fontSize = 12.sp, color = Palette.blue)
                }
            }
        }
    }
}

@Composable
private fun SourceCard(
    source: RssSource,
    unread: Int,
    total: Int,
    refreshing: Boolean,
    onOpen: () -> Unit,
    onRefresh: () -> Unit,
    onEdit: () -> Unit,
    onToggle: (Boolean) -> Unit
) {
    val colors = LocalMptColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.tileRadius))
            .background(colors.card)
            .clickable { onOpen() }
            .padding(12.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Favicon(source)
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    source.name.ifBlank { "未命名源" },
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = if (source.enabled) colors.textPrimary else colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    if (source.lastUpdated > 0) formatRelativeTime(source.lastUpdated) else "未刷新",
                    fontSize = 10.sp,
                    color = colors.textSecondary
                )
            }
            Switch(
                checked = source.enabled,
                onCheckedChange = onToggle
            )
        }

        Spacer(Modifier.height(8.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            if (source.autoDownload) {
                TinyPill("自动", Palette.green.copy(alpha = 0.15f), Palette.green)
            }
            if (unread > 0) {
                TinyPill("$unread 未推送", Palette.blue.copy(alpha = 0.12f), Palette.blue)
            } else {
                TinyPill("$total 条", colors.separator, colors.textSecondary)
            }
        }

        Spacer(Modifier.height(6.dp))
        Text(
            source.ruleSummary,
            fontSize = 11.sp,
            color = colors.textSecondary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            lineHeight = 15.sp
        )

        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (refreshing) {
                CircularProgressIndicator(
                    modifier = Modifier.size(13.dp),
                    strokeWidth = 2.dp,
                    color = Palette.blue
                )
                Spacer(Modifier.width(4.dp))
                Text("刷新中", fontSize = 11.sp, color = Palette.blue)
            } else {
                Icon(
                    Icons.Rounded.Refresh, null,
                    tint = Palette.blue,
                    modifier = Modifier.size(14.dp).clickable { onRefresh() }
                )
                Spacer(Modifier.width(10.dp))
                Icon(
                    Icons.Rounded.Settings, null,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(14.dp).clickable { onEdit() }
                )
            }
        }

        if (source.lastError.isNotBlank()) {
            Spacer(Modifier.height(6.dp))
            Text(
                source.lastError,
                fontSize = 10.sp,
                color = Palette.red,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
private fun Favicon(source: RssSource) {
    val colors = LocalMptColors.current
    val initial = source.name.trim().take(1).ifBlank { "R" }
    Box(
        Modifier.size(28.dp).clip(CircleShape).background(colors.separator),
        contentAlignment = Alignment.Center
    ) {
        Text(initial, fontSize = 13.sp, color = colors.textSecondary)
        val icon = source.resolvedFavicon
        if (icon.isNotBlank()) {
            AsyncImage(
                model = icon,
                contentDescription = null,
                modifier = Modifier.size(28.dp).clip(CircleShape),
                contentScale = ContentScale.Crop
            )
        }
    }
}

// ---------- 全部条目 ----------

@Composable
private fun AllItemsList(state: RssUiState, onPush: (String, RssItemRecord) -> Unit) {
    val items = state.sortedItems
    if (items.isEmpty()) {
        EmptyHint("暂无条目，先添加 RSS 源并刷新一次")
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = Metrics.pagePadding,
            end = Metrics.pagePadding,
            top = 2.dp,
            bottom = 110.dp
        ),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        items(items.size) { index ->
            val item = items[index]
            ItemRow(
                item = item,
                sourceName = state.sourceName(item.sourceId),
                onPush = { onPush(item.sourceId, item) }
            )
        }
    }
}

@Composable
private fun ItemRow(
    item: RssItemRecord,
    sourceName: String,
    onPush: () -> Unit
) {
    val colors = LocalMptColors.current
    OiiCard(modifier = Modifier.fillMaxWidth(), padding = 11.dp) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(
                    item.title,
                    fontSize = 12.5.sp,
                    color = colors.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    lineHeight = 17.sp
                )
                Spacer(Modifier.height(5.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (sourceName.isNotBlank()) {
                        Text(sourceName, fontSize = 10.sp, color = colors.accent)
                        Text(" · ", fontSize = 10.sp, color = colors.textSecondary)
                    }
                    if (item.sizeBytes > 0) {
                        Text(formatBytes(item.sizeBytes), fontSize = 10.sp, color = colors.textSecondary)
                        Text(" · ", fontSize = 10.sp, color = colors.textSecondary)
                    }
                    Text(formatRelativeTime(item.pubDate), fontSize = 10.sp, color = colors.textSecondary)
                }
            }
            Spacer(Modifier.width(8.dp))
            if (item.downloaded) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Check, null, tint = Palette.green, modifier = Modifier.size(13.dp))
                    Spacer(Modifier.width(2.dp))
                    Text("已推送", fontSize = 10.sp, color = Palette.green)
                }
            } else {
                Row(
                    Modifier
                        .clip(RoundedCornerShape(10.dp))
                        .background(Palette.blue.copy(alpha = 0.12f))
                        .clickable { onPush() }
                        .padding(horizontal = 9.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(Icons.Rounded.CloudDownload, null, tint = Palette.blue, modifier = Modifier.size(12.dp))
                    Spacer(Modifier.width(3.dp))
                    Text("推送", fontSize = 11.sp, color = Palette.blue)
                }
            }
        }
    }
}

// ---------- 源详情 ----------

@Composable
private fun SourceDetailContent(
    source: RssSource,
    items: List<RssItemRecord>,
    refreshing: Boolean,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onEdit: () -> Unit,
    onPushItem: (RssItemRecord) -> Unit,
    onDelete: () -> Unit
) {
    val colors = LocalMptColors.current
    var confirmDelete by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(colors.background)) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = Metrics.pagePadding, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                Icons.Rounded.ArrowBack, null,
                tint = colors.textPrimary,
                modifier = Modifier.size(22.dp).clickable { onBack() }
            )
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    source.name.ifBlank { "未命名源" },
                    fontSize = 18.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    "${items.size} 条 · 未推送 ${items.count { !it.downloaded }}",
                    fontSize = 11.sp,
                    color = colors.textSecondary
                )
            }
            Icon(
                Icons.Rounded.Refresh, null,
                tint = Palette.blue,
                modifier = Modifier.size(20.dp).clickable(enabled = !refreshing) { onRefresh() }
            )
            Spacer(Modifier.width(14.dp))
            Icon(
                Icons.Rounded.Edit, null,
                tint = colors.textSecondary,
                modifier = Modifier.size(19.dp).clickable { onEdit() }
            )
            Spacer(Modifier.width(14.dp))
            Icon(
                Icons.Rounded.Delete, null,
                tint = Palette.red,
                modifier = Modifier.size(19.dp).clickable { confirmDelete = true }
            )
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = Metrics.pagePadding,
                end = Metrics.pagePadding,
                top = 2.dp,
                bottom = 30.dp
            ),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            item {
                OiiCard(modifier = Modifier.fillMaxWidth(), padding = 12.dp) {
                    Text(source.ruleSummary, fontSize = 12.sp, color = colors.textSecondary, lineHeight = 17.sp)
                    Spacer(Modifier.height(6.dp))
                    DividerLine()
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "保存路径：${source.savePath.ifBlank { "跟随下载器默认" }}",
                        fontSize = 11.sp,
                        color = colors.textSecondary
                    )
                    if (source.lastError.isNotBlank()) {
                        Text(source.lastError, fontSize = 11.sp, color = Palette.red)
                    }
                }
            }
            items(items.size) { index ->
                val item = items[index]
                ItemRow(item = item, sourceName = "", onPush = { onPushItem(item) })
            }
            if (items.isEmpty()) {
                item { EmptyHint("还没有条目，点右上角刷新") }
            }
        }
    }

    if (confirmDelete) {
        OiiAlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("删除这个 RSS 源？") },
            text = { Text("源配置和已抓取的条目都会删除，已推送的下载任务不受影响。") },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    confirmDelete = false
                    onDelete()
                }) { Text("删除", color = Palette.red) }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { confirmDelete = false }) { Text("取消") }
            }
        )
    }
}
