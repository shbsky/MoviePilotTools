package com.oiiqt.android.ui.dashboard

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.SwapHoriz
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.LiveTv
import androidx.compose.material.icons.rounded.Memory
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.ShowChart
import androidx.compose.material.icons.rounded.Subscriptions
import androidx.compose.material.icons.rounded.Storage
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oiiqt.android.data.ServerConfig
import com.oiiqt.android.data.ServerSnapshot
import com.oiiqt.android.data.ServerType
import com.oiiqt.android.data.MpStatistic
import com.oiiqt.android.data.MpStorage
import com.oiiqt.android.data.formatBytes
import com.oiiqt.android.data.formatStorageSize
import com.oiiqt.android.ui.components.Dot
import com.oiiqt.android.ui.components.IconValue
import com.oiiqt.android.ui.components.LineSeries
import com.oiiqt.android.ui.components.MultiLineChart
import com.oiiqt.android.ui.components.ElevatedCard
import com.oiiqt.android.ui.components.SectionHeader
import com.oiiqt.android.ui.components.ServerBadge
import com.oiiqt.android.ui.components.StatTile
import com.oiiqt.android.ui.theme.LocalOiiColors
import com.oiiqt.android.ui.theme.Metrics
import com.oiiqt.android.ui.theme.Palette
import com.oiiqt.android.vm.DashboardLiveState
import com.oiiqt.android.vm.UiState
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun DashboardScreen(
    state: UiState,
    onSelectServer: (String?) -> Unit,
    onOpenServers: () -> Unit,
    onOpenServerTasks: (String) -> Unit = {},
    onOpenMpServers: () -> Unit = {},
    /** MoviePilot 仪表盘的媒体库统计（电影/电视剧/剧集/用户） */
    mpStats: MpStatistic? = null,
    mpConfigured: Boolean = false,
    mpLoading: Boolean = false,
    mpError: String? = null,
    /** MoviePilot 上报的存储空间；有值时「剩余空间」以它为准（已按物理盘去重） */
    mpStorage: MpStorage? = null,
    /** MP 仪表盘实时速率 / CPU / 内存 / 系统信息（本地轮询采样） */
    mpLive: DashboardLiveState = DashboardLiveState(),
    /** 首屏 Hero 海报轮播片单（来自 MP 推荐，已缓存）；空则由原渐变卡降级 */
    heroPosters: List<com.oiiqt.android.data.MpMedia> = emptyList(),
    /** 点海报卡右上详情按钮 */
    onOpenHeroDetail: (com.oiiqt.android.data.MpMedia) -> Unit = {}
) {
    val colors = LocalOiiColors.current
    // 「系统信息」默认展开：展开后是 CPU / 内存 / 系统三张独立卡片，用户可手动收起
    var systemExpanded by remember { mutableStateOf(true) }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = Metrics.pagePadding,
            end = Metrics.pagePadding,
            top = 8.dp,
            // 底栏改成了浮层（真背景模糊需要它在内容之上），必须留出胶囊高度，
            // 否则最后一张卡会躲在玻璃底下；112dp 留得过多（视觉上空白太大），收到 88dp
            bottom = 88.dp
        ),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        // 首屏 Hero：有 MP 推荐海报就轮播，否则降级为原渐变卡（保留速度/在线/服务器下拉）
        item {
            if (heroPosters.isNotEmpty()) {
                HeroCarousel(items = heroPosters, onOpenDetail = onOpenHeroDetail)
            } else {
                HeroCard(state, onSelectServer, onOpenServers)
            }
        }

        if (state.settings.showModuleTraffic) {
            item {
                SectionHeader("实时速率") {
                    Text(
                        when {
                            !mpConfigured -> "未接入 MoviePilot"
                            mpLive.speedError != null -> "上次刷新失败"
                            mpLive.lastSpeedAt <= 0 -> "正在连接…"
                            // MP 服务端没配下载目录 / 下载器采样为空时（五项全 0）改用下载器直连数据
                            mpDownloaderReady(mpLive) -> "来自 MoviePilot"
                            else -> "来自下载器"
                        },
                        fontSize = 11.sp,
                        color = colors.textSecondary
                    )
                }
            }
            item {
                RealtimeSpeedCard(
                    live = mpLive,
                    localDownloadSpeed = state.totalDownloadSpeed,
                    localUploadSpeed = state.totalUploadSpeed,
                    localDownloaded = state.totalDownloaded,
                    localUploaded = state.totalUploaded,
                    // 剩余空间兜底与「存储空间」瓦片同序：MP 挂载盘 → 下载器 free_space（去重）
                    localFreeSpace = mpStorage?.takeUnless { it.isEmpty }?.free ?: state.totalFreeSpace
                )
            }
        }

        if (state.settings.showModuleMedia) {
            item {
                SectionHeader("媒体库") {
                    Text(
                        when {
                            mpLoading && mpStats != null -> "更新中…"
                            !mpConfigured -> "未接入 MoviePilot"
                            else -> "来自 MoviePilot"
                        },
                        fontSize = 11.sp,
                        color = colors.textSecondary
                    )
                }
            }
            item {
                MediaLibraryCard(
                    stats = mpStats,
                    configured = mpConfigured,
                    loading = mpLoading,
                    error = mpError,
                    onOpenSettings = onOpenMpServers
                )
            }
        }

        if (state.settings.showModuleAssets) {
        item { SectionHeader("数据聚合") }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.cardGap)) {
                StatTile(
                    modifier = Modifier.weight(1f),
                    icon = Icons.Rounded.Check,
                    iconTint = Palette.green,
                    value = state.totalSeeding.toString(),
                    unit = "个",
                    caption = "做种总数"
                )
                StatTile(
                    modifier = Modifier.weight(1f),
                    icon = Icons.Rounded.ArrowDownward,
                    iconTint = Palette.blue,
                    value = state.totalDownloading.toString(),
                    unit = "个",
                    caption = "正在下载"
                )
            }
        }
        item {
            // 存储瓦片比带宽瓦片多出「已使用 / 进度条 / 可用·总容量」三行，
            // 用 IntrinsicSize.Max + fillMaxHeight 让两块等高，避免左边那张卡缺一截
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(IntrinsicSize.Max),
                horizontalArrangement = Arrangement.spacedBy(Metrics.cardGap)
            ) {
                StatTile(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight(),
                    icon = Icons.Rounded.SwapHoriz,
                    iconTint = Palette.orange,
                    value = formatBytes(state.totalBandwidth),
                    unit = "/s",
                    caption = "实时总带宽"
                )
                StorageTile(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight(),
                    storage = mpStorage,
                    fallbackFree = state.totalFreeSpace
                )
            }
        }
        }

        if (state.settings.showModuleServers) {
        item { SectionHeader("下载服务器状态") }
        if (state.servers.isEmpty()) {
            item {
                ElevatedCard(Modifier.fillMaxWidth(), padding = 18.dp) {
                    Text("还没有添加下载器", fontSize = 15.sp, color = colors.textSecondary)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "点这里添加 qBittorrent 或 Transmission",
                        fontSize = 14.sp,
                        color = colors.accent,
                        modifier = Modifier.clickable { onOpenServers() }
                    )
                }
            }
        } else {
            val servers = state.servers.filter { it.id in state.snapshots.keys || state.snapshots.isEmpty() }
            val rows = servers.chunked(2)
            rows.forEach { rowServers ->
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(Metrics.cardGap)) {
                        rowServers.forEach { server ->
                            ServerStatusTile(
                                modifier = Modifier.weight(1f),
                                server = server,
                                snapshot = state.snapshots[server.id],
                                onClick = { onOpenServerTasks(server.id) }
                            )
                        }
                        if (rowServers.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }
        }
        }

        // 「系统信息」（CPU / 内存 / 系统）归「设置 → 仪表盘定制 → 服务器状态」管。
        // 原来只判 mpConfigured，开关拨了没反应 —— 用户反馈「服务器状态按钮还没关联动作」。
        if (mpConfigured && state.settings.showModuleServers) {
            item {
                SystemInfoHeader(expanded = systemExpanded) { systemExpanded = !systemExpanded }
            }
            if (systemExpanded) {
                item { CpuUsageCard(mpLive) }
                item { MemoryUsageCard(mpLive) }
                item { SystemDetailCard(mpLive) }
            }
        }
    }
}

@Composable
private fun HeroCard(
    state: UiState,
    onSelectServer: (String?) -> Unit,
    onOpenServers: () -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    val colors = LocalOiiColors.current
    val isDark = colors.isDark
    val activeName = state.servers.firstOrNull { it.id == state.activeServerId }?.displayName ?: "全部服务器"

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(158.dp)
            // 抬升阴影放在 clip 之前，否则会被圆角裁掉，卡片就「贴」在背景上了
            .shadow(
                elevation = 14.dp,
                shape = RoundedCornerShape(22.dp),
                ambientColor = Color.Black.copy(alpha = if (isDark) 0.50f else 0.22f),
                spotColor = Color.Black.copy(alpha = if (isDark) 0.50f else 0.22f)
            )
            .clip(RoundedCornerShape(22.dp))
            .background(
                Brush.linearGradient(
                    listOf(Color(0xFF1B3A6B), Color(0xFF0A84FF), Color(0xFF5E5CE6))
                )
            )
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(18.dp),
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "MoviePilotTools",
                    color = Color.White,
                    fontSize = 19.sp,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1
                )
                Spacer(Modifier.width(6.dp))
                Text("Android", color = Color.White.copy(alpha = 0.7f), fontSize = 10.sp)
                Spacer(Modifier.weight(1f))
                Box {
                    Row(
                        modifier = Modifier
                            .clip(RoundedCornerShape(14.dp))
                            .background(Color.White.copy(alpha = 0.18f))
                            .clickable { expanded = true }
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(activeName, color = Color.White, fontSize = 12.sp, maxLines = 1)
                        Icon(
                            Icons.Rounded.ExpandMore,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                    DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                        DropdownMenuItem(
                            text = { Text("全部服务器") },
                            onClick = { expanded = false; onSelectServer(null) }
                        )
                        state.servers.forEach { server ->
                            DropdownMenuItem(
                                text = { Text(server.displayName) },
                                onClick = { expanded = false; onSelectServer(server.id) }
                            )
                        }
                        DropdownMenuItem(
                            text = { Text("管理服务器…") },
                            onClick = { expanded = false; onOpenServers() }
                        )
                    }
                }
            }

            Row(verticalAlignment = Alignment.Bottom) {
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Dot(if (state.onlineCount > 0) Palette.green else Palette.red, 7)
                        Spacer(Modifier.width(6.dp))
                        Text(
                            "${state.onlineCount}/${state.servers.size} 台在线",
                            color = Color.White.copy(alpha = 0.85f),
                            fontSize = 12.sp
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(
                            formatBytes(state.downloadSpeed),
                            color = Color.White,
                            fontSize = 26.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text("/s ↓", color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp)
                        Spacer(Modifier.width(14.dp))
                        Text(
                            formatBytes(state.uploadSpeed),
                            color = Color.White,
                            fontSize = 26.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text("/s ↑", color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp)
                    }
                }
                if (state.lastRefreshAt > 0) {
                    Text(
                        SimpleDateFormat("HH:mm:ss", Locale.US).format(Date(state.lastRefreshAt)),
                        color = Color.White.copy(alpha = 0.6f),
                        fontSize = 11.sp
                    )
                }
            }
        }
    }
}

/**
 * MP 的 `dashboard/downloader` 是否真的拿到了数据。
 *
 * MP v3.2 的下载器汇总来自 `DashboardChain().downloader_info()`：一旦服务端没配「下载目录」
 * 或下载器采样为空，`sample_downloader()` 会直接 `return DownloaderInfo()` —— 五项**一起**返回 0，
 * 网页那张卡同样是 0。这里只要五项全 0 就判为「MP 没数据」，改用 App 直连下载器的口径。
 */
private fun mpDownloaderReady(live: DashboardLiveState): Boolean = !live.downloader.isEmpty

/**
 * MP 同款「实时速率」卡。
 *
 * 五个字段**逐项**取值：某一项 MP 给了正数就用 MP（与网页口径一致），这一项是 0 就单独退回
 * App 直连下载器/挂载盘的数。不能整卡二选一 —— MP 常回半残数据（速率有值但累计量、剩余空间是 0，
 * 或者反过来），整卡切换会把本来有数的字段也一起变成 0 B（鸿蒙端此前就是这个现象）。
 * 卡内不再重复写「实时速率 / MoviePilot」标题 —— 区块标题就在卡片正上方。
 */
@Composable
private fun RealtimeSpeedCard(
    live: DashboardLiveState,
    localDownloadSpeed: Long,
    localUploadSpeed: Long,
    localDownloaded: Long,
    localUploaded: Long,
    localFreeSpace: Long
) {
    val colors = LocalOiiColors.current
    val info = live.downloader
    val downloadSpeed = if (info.downloadSpeed > 0) info.downloadSpeed else localDownloadSpeed
    val uploadSpeed = if (info.uploadSpeed > 0) info.uploadSpeed else localUploadSpeed
    val downloadSize = if (info.downloadSize > 0) info.downloadSize else localDownloaded
    val uploadSize = if (info.uploadSize > 0) info.uploadSize else localUploaded
    // 剩余空间：MP 只统计「下载目录」所在盘，没配下载目录时就是 0
    val freeSpace = if (info.freeSpace > 0) info.freeSpace else localFreeSpace

    ElevatedCard(Modifier.fillMaxWidth(), padding = 16.dp) {
        Row(Modifier.fillMaxWidth()) {
            Column(Modifier.weight(1f)) {
                Text("下载速率", fontSize = 12.sp, color = colors.textSecondary)
                Spacer(Modifier.height(3.dp))
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(
                        formatBytes(downloadSpeed),
                        fontSize = 24.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Palette.blue,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text("/s", fontSize = 12.sp, color = colors.textSecondary)
                }
            }
            Box(
                Modifier
                    .width(0.5.dp)
                    .height(44.dp)
                    .background(colors.separator)
            )
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text("上传速率", fontSize = 12.sp, color = colors.textSecondary)
                Spacer(Modifier.height(3.dp))
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(
                        formatBytes(uploadSpeed),
                        fontSize = 24.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Palette.green,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text("/s", fontSize = 12.sp, color = colors.textSecondary)
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        Box(Modifier.fillMaxWidth().height(0.5.dp).background(colors.separator))
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth()) {
            SpeedTotalCell("总下载", formatBytes(downloadSize), colors)
            SpeedTotalCell("总上传", formatBytes(uploadSize), colors)
            SpeedTotalCell("剩余空间", formatBytes(freeSpace), colors)
        }
        if (live.speedError != null) {
            Spacer(Modifier.height(6.dp))
            Text("速率刷新失败：${live.speedError}", fontSize = 11.sp, color = Palette.red, maxLines = 2)
        }
    }
}

@Composable
private fun RowScope.SpeedTotalCell(label: String, value: String, colors: com.oiiqt.android.ui.theme.OiiColors) {
    Column(Modifier.weight(1f)) {
        Text(label, fontSize = 10.sp, color = colors.textSecondary, maxLines = 1)
        Spacer(Modifier.height(2.dp))
        Text(
            value,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

/**
 * 默认折叠的「系统信息」标题行。
 *
 * 折叠时只占一行（和其它 SectionHeader 同级），展开后才插入 CPU / 内存 / 系统三张独立卡片，
 * 和 MoviePilot 网页仪表盘一致 —— 不再把所有指标塞进同一张卡里。
 */
@Composable
private fun SystemInfoHeader(expanded: Boolean, onToggle: () -> Unit) {
    val colors = LocalOiiColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable { onToggle() }
            .padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            Icons.Rounded.Dns,
            contentDescription = null,
            tint = Palette.purple,
            modifier = Modifier.size(18.dp)
        )
        Spacer(Modifier.width(8.dp))
        Text("系统信息", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
        Spacer(Modifier.weight(1f))
        Text(if (expanded) "收起" else "展开", fontSize = 12.sp, color = colors.textSecondary)
        Icon(
            if (expanded) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(18.dp)
        )
    }
}

/** CPU 使用率卡（MP 同款：标题行右上百分比 → 面积折线 → 1/5/15 分钟均值）。 */
@Composable
private fun CpuUsageCard(live: DashboardLiveState) {
    val colors = LocalOiiColors.current
    val points = live.cpuSamples.takeLast(30).map { it.value }
    val peak = points.maxOrNull() ?: 0f
    // Y 轴按峰值取整档，14% 的曲线才不会贴着 100% 的底边变成一条直线
    val yMax = percentCeil(peak)

    ElevatedCard(Modifier.fillMaxWidth(), padding = 16.dp) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Rounded.Speed,
                contentDescription = null,
                tint = Palette.blue,
                modifier = Modifier.size(18.dp)
            )
            Spacer(Modifier.width(8.dp))
            Text("CPU 使用率", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
            Spacer(Modifier.weight(1f))
            Text(
                if (live.cpu.isNaN()) "--" else String.format(Locale.US, "%.1f%%", live.cpu),
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary
            )
        }
        Spacer(Modifier.height(10.dp))
        if (points.size >= 2) {
            MultiLineChart(
                series = listOf(LineSeries(points = points, color = Palette.blue, filled = true)),
                yMax = yMax,
                gridLines = 2,
                gridColor = colors.separator,
                yLabels = listOf(cpuTick(yMax), cpuTick(yMax / 2f), "0%"),
                labelColor = colors.textSecondary
            )
        } else {
            Text("正在采集曲线…", fontSize = 11.sp, color = colors.textSecondary)
        }
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
            Text(
                "平均使用",
                fontSize = 11.sp,
                color = colors.textSecondary,
                modifier = Modifier.weight(1f)
            )
            CpuAverageCell("1 分钟", live.cpuAverage(60_000L), colors)
            CpuAverageCell("5 分钟", live.cpuAverage(300_000L), colors)
            CpuAverageCell("15 分钟", live.cpuAverage(900_000L), colors)
        }
    }
}

/** 内存使用卡（MP 同款：右上百分比 → 已用/总量 → 三序列折线 → 带数值的图例）。 */
@Composable
private fun MemoryUsageCard(live: DashboardLiveState) {
    val colors = LocalOiiColors.current
    val memory = live.memory
    val samples = live.memorySamples

    ElevatedCard(Modifier.fillMaxWidth(), padding = 16.dp) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Rounded.Memory,
                contentDescription = null,
                tint = Palette.orange,
                modifier = Modifier.size(18.dp)
            )
            Spacer(Modifier.width(8.dp))
            Text("内存使用", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
            Spacer(Modifier.weight(1f))
            Text(
                if (memory == null || memory.total <= 0) "--"
                else String.format(Locale.US, "%.1f%%", memory.usage),
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary
            )
        }

        if (memory != null && memory.total > 0) {
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.Bottom) {
                Text(
                    formatBytes(memory.used),
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.textPrimary,
                    maxLines = 1
                )
                Text(
                    " / ${formatBytes(memory.total)}",
                    fontSize = 12.sp,
                    color = colors.textSecondary,
                    maxLines = 1
                )
            }
            Spacer(Modifier.height(8.dp))
            if (samples.size >= 2) {
                // 和 CPU 卡完全同一套画法：画「使用率 %」的面积曲线。
                // 之前画绝对字节（已使用 0.5G / 已缓存 10G / 可用 10G，量程 15G），
                // 蓝线贴着底边、紫绿两条压成直线，等于没有曲线。
                val totalBytes = memory.total.toFloat().coerceAtLeast(1f)
                val usagePoints = samples.map { (it.used / totalBytes * 100f).coerceIn(0f, 100f) }
                val yMax = percentCeil(usagePoints.maxOrNull() ?: 0f)
                MultiLineChart(
                    series = listOf(LineSeries(usagePoints, Palette.blue, filled = true)),
                    yMax = yMax,
                    gridLines = 2,
                    gridColor = colors.separator,
                    yLabels = listOf(cpuTick(yMax), cpuTick(yMax / 2f), "0%"),
                    labelColor = colors.textSecondary
                )
            } else {
                Text("正在采集曲线…", fontSize = 11.sp, color = colors.textSecondary)
            }
            Spacer(Modifier.height(8.dp))
            Row(Modifier.fillMaxWidth()) {
                LegendDot("已使用", formatBytes(memory.used), Palette.blue, colors)
                LegendDot("已缓存", formatBytes(memory.cached), Palette.purple, colors)
                LegendDot("可用", formatBytes(memory.available), Palette.green, colors)
            }
        } else {
            Spacer(Modifier.height(8.dp))
            Text("正在读取…", fontSize = 12.sp, color = colors.textSecondary)
        }
    }
}

/** 系统详情卡：主机名 / 操作系统 / 运行环境 / 版本；API Token 模式下给出说明。 */
@Composable
private fun SystemDetailCard(live: DashboardLiveState) {
    val colors = LocalOiiColors.current
    val system = live.system

    ElevatedCard(Modifier.fillMaxWidth(), padding = 16.dp) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Rounded.Dns,
                contentDescription = null,
                tint = Palette.purple,
                modifier = Modifier.size(18.dp)
            )
            Spacer(Modifier.width(8.dp))
            Text("系统", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
        }
        Spacer(Modifier.height(8.dp))
        when {
            system != null && !system.isEmpty -> {
                InfoLine("主机名", system.hostname, colors)
                InfoLine("操作系统", system.operatingSystem, colors)
                InfoLine("运行环境", system.runtime, colors)
                InfoLine("版本", system.version, colors)
            }
            live.systemDenied -> Text(
                "系统信息需要管理员账号登录（仅 API Token 无权读取）。CPU / 内存不受影响。",
                fontSize = 11.sp,
                color = colors.textSecondary,
                lineHeight = 16.sp
            )
            live.systemError != null -> Text(
                "系统信息读取失败：${live.systemError}",
                fontSize = 11.sp,
                color = Palette.red,
                lineHeight = 16.sp
            )
            else -> Text("正在读取…", fontSize = 11.sp, color = colors.textSecondary)
        }
    }
}

/** Y 轴刻度文字：整数百分比。 */
private fun cpuTick(value: Float): String = String.format(Locale.US, "%.0f%%", value)

/** 百分比曲线取整档（2/5/10/20/50/100），CPU 与内存共用，量程不会每来一个点就重新伸缩。 */
private fun percentCeil(peak: Float): Float = when {
    peak <= 2f -> 2f
    peak <= 5f -> 5f
    peak <= 10f -> 10f
    peak <= 20f -> 20f
    peak <= 50f -> 50f
    else -> 100f
}

@Composable
private fun RowScope.CpuAverageCell(label: String, value: Float, colors: com.oiiqt.android.ui.theme.OiiColors) {
    Column(Modifier.weight(1f)) {
        Text(
            if (value.isNaN()) "--" else String.format(Locale.US, "%.1f%%", value),
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            color = colors.textPrimary,
            maxLines = 1
        )
        Text(label, fontSize = 11.sp, color = colors.textSecondary, maxLines = 1)
    }
}

/** 图例格：色点 + 名称在上、数值在下，三格等宽，长数值也不会把一行挤爆。 */
@Composable
private fun RowScope.LegendDot(
    label: String,
    value: String,
    color: Color,
    colors: com.oiiqt.android.ui.theme.OiiColors
) {
    Column(Modifier.weight(1f)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(6.dp).clip(CircleShape).background(color))
            Spacer(Modifier.width(4.dp))
            Text(label, fontSize = 11.sp, color = colors.textSecondary, maxLines = 1)
        }
        Spacer(Modifier.height(2.dp))
        Text(
            value,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
private fun InfoLine(label: String, value: String, colors: com.oiiqt.android.ui.theme.OiiColors) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Text(label, fontSize = 12.sp, color = colors.textSecondary, modifier = Modifier.width(68.dp))
        Text(
            value.ifBlank { "--" },
            fontSize = 12.sp,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
private fun ServerStatusTile(
    modifier: Modifier,
    server: ServerConfig,
    snapshot: ServerSnapshot?,
    onClick: () -> Unit = {}
) {
    val colors = LocalOiiColors.current
    val online = snapshot?.online == true

    ElevatedCard(
        // 不能再套 .clip()：它会把 ElevatedCard 画在圆角外的柔和投影裁掉，导致悬浮残缺。
        // 点击涟漪改用 clickable 自带的形状裁剪，不影响卡片阴影。
        modifier = modifier.clickable { onClick() },
        padding = 13.dp
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ServerBadge(server.type, 20)
            Spacer(Modifier.width(7.dp))
            Text(
                server.displayName,
                fontSize = 12.sp,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
            Spacer(Modifier.width(6.dp))
            Dot(
                when {
                    snapshot == null -> Palette.orange
                    online -> Palette.green
                    else -> Palette.red
                },
                8
            )
            Spacer(Modifier.width(3.dp))
            // 提示这张卡可以点进去看这台机器的种子
            Icon(
                Icons.Rounded.ChevronRight,
                contentDescription = null,
                tint = colors.textSecondary.copy(alpha = 0.55f),
                modifier = Modifier.size(13.dp)
            )
        }
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            IconValue(Icons.Rounded.ArrowUpward, formatBytes(snapshot?.uploadSpeed ?: 0) + "/s", Palette.green)
            IconValue(Icons.Rounded.ArrowDownward, formatBytes(snapshot?.downloadSpeed ?: 0) + "/s", Palette.blue)
        }
        Spacer(Modifier.height(8.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            IconValue(Icons.Rounded.Storage, formatStorageSize(snapshot?.seedingSize ?: 0), colors.textSecondary)
            IconValue(
                Icons.Rounded.ShowChart,
                String.format(Locale.US, "%.2f", snapshot?.ratio ?: 0.0),
                colors.textSecondary
            )
        }
        if (!online && snapshot?.error != null) {
            Spacer(Modifier.height(8.dp))
            Text(
                snapshot.error,
                fontSize = 11.sp,
                color = Palette.red,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }
        if (online && snapshot != null && snapshot.freeSpace > 0) {
            Spacer(Modifier.height(8.dp))
            Text(
                "剩余 ${formatStorageSize(snapshot.freeSpace)}",
                fontSize = 11.sp,
                color = colors.textSecondary,
                maxLines = 1
            )
        }
    }
}

/**
 * 媒体库统计（电影 / 电视剧 / 剧集 / 用户）。
 *
 * 数据取自 MoviePilot 仪表盘的 `/api/v1/dashboard/statistic`，
 * 也就是 MP 网页「媒体统计」那一块，本机不做任何缓存或推算。
 */
@Composable
private fun MediaLibraryCard(
    stats: MpStatistic?,
    configured: Boolean,
    loading: Boolean,
    error: String?,
    onOpenSettings: () -> Unit
) {
    val colors = LocalOiiColors.current

    if (!configured) {
        ElevatedCard(Modifier.fillMaxWidth()) {
            Row(
                Modifier.fillMaxWidth().clickable(onClick = onOpenSettings),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier
                        .size(30.dp)
                        .clip(RoundedCornerShape(9.dp))
                        .background(Palette.purple.copy(alpha = 0.14f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Rounded.Movie, null, tint = Palette.purple, modifier = Modifier.size(17.dp))
                }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text("还没接入 MoviePilot", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                    Text(
                        "添加 MoviePilot 服务器后，这里会显示电影 / 电视剧 / 剧集数量和本月新增。",
                        fontSize = 11.sp,
                        color = colors.textSecondary,
                        lineHeight = 16.sp
                    )
                }
                Icon(Icons.Rounded.ChevronRight, null, tint = colors.textSecondary, modifier = Modifier.size(15.dp))
            }
        }
        return
    }

    if (stats == null) {
        ElevatedCard(Modifier.fillMaxWidth()) {
            if (loading || error == null) {
                Text("正在读取媒体库…", fontSize = 12.sp, color = colors.textSecondary)
            } else {
                Text("读取媒体库失败", fontSize = 13.sp, color = Palette.red)
                Spacer(Modifier.height(4.dp))
                Text(error, fontSize = 11.sp, color = colors.textSecondary, lineHeight = 16.sp)
            }
        }
        return
    }

    // 2×2「媒体统计」卡：和 MoviePilot 里那张一致（彩色圆图标 + 分类 + 数量 + 本月新增），
    // 原来这里是 4 张独立小卡，既占地方又和 MP 的观感不一样
    ElevatedCard(Modifier.fillMaxWidth(), padding = 14.dp, accent = Palette.purple) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            MediaStatCell(
                modifier = Modifier.weight(1f),
                label = "电影",
                count = stats.movies,
                added = stats.moviesThisMonth,
                color = Palette.purple,
                icon = Icons.Rounded.Movie
            )
            CellDividerV()
            MediaStatCell(
                modifier = Modifier.weight(1f),
                label = "电视剧",
                count = stats.tvs,
                added = stats.tvsThisMonth,
                color = Palette.green,
                icon = Icons.Rounded.LiveTv
            )
        }
        Box(
            Modifier
                .fillMaxWidth()
                .padding(vertical = 2.dp)
                .height(0.5.dp)
                .background(colors.separator)
        )
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            MediaStatCell(
                modifier = Modifier.weight(1f),
                label = "剧集",
                count = stats.episodes,
                added = stats.episodesThisMonth,
                color = Palette.orange,
                icon = Icons.Rounded.Subscriptions
            )
            CellDividerV()
            MediaStatCell(
                modifier = Modifier.weight(1f),
                label = "音乐",
                count = stats.music,
                added = stats.musicThisMonth,
                color = Palette.blue,
                icon = Icons.Rounded.LibraryMusic
            )
        }
        if (error != null) {
            Spacer(Modifier.height(6.dp))
            Text(
                "上次刷新失败：$error",
                fontSize = 10.sp,
                color = Palette.red,
                lineHeight = 14.sp
            )
        }
    }
}

/** 2×2 网格里的一格：彩色圆图标 + 分类 / 数量 / 本月新增 */
@Composable
private fun MediaStatCell(
    modifier: Modifier,
    label: String,
    count: Int,
    added: Int,
    color: Color,
    icon: androidx.compose.ui.graphics.vector.ImageVector
) {
    val colors = LocalOiiColors.current
    Row(
        modifier.padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(38.dp)
                .clip(CircleShape)
                .background(color),
            contentAlignment = Alignment.Center
        ) {
            Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.width(10.dp))
        Column {
            Text(label, fontSize = 11.sp, color = colors.textSecondary, maxLines = 1)
            Text(
                count.toString(),
                fontSize = 17.sp,
                fontWeight = FontWeight.Bold,
                color = colors.textPrimary,
                maxLines = 1
            )
            Text("+$added 本月新增", fontSize = 10.sp, color = Palette.green, maxLines = 1)
        }
    }
}

@Composable
private fun CellDividerV() {
    val colors = LocalOiiColors.current
    Box(
        Modifier
            .width(0.5.dp)
            .height(40.dp)
            .background(colors.separator)
    )
}

/**
 * 存储空间瓦片（与鸿蒙版 StorageTile 1:1 对齐）：
 * 三条薄荷绿圆角横杠 + 「存储空间」/ 总容量 / 已使用 xx.x% / 进度条 / 可用 X / 总容量 Y。
 * [storage] 为 MP 上报的真实容量（v3 仪表盘，或 v2 的「存储 & 目录」用量汇总）；
 * 拿不到时退化成下载器聚合的空闲空间，和旧版「剩余空间」口径一致。
 */
@Composable
fun StorageTile(
    modifier: Modifier = Modifier,
    storage: MpStorage?,
    fallbackFree: Long
) {
    val colors = LocalOiiColors.current
    val hasMp = storage != null && !storage.isEmpty
    val total = if (hasMp) storage!!.total else 0L
    val used = if (hasMp) storage!!.used else 0L
    val free = if (hasMp) storage!!.free else fallbackFree
    val ratio = if (hasMp && total > 0) (used.toDouble() / total).coerceIn(0.0, 1.0) else 0.0
    val percent = String.format(java.util.Locale.US, "%.1f", ratio * 100)

    ElevatedCard(modifier = modifier, padding = 14.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // 安卓不再用 Icons.Rounded.Storage（那条是系统字体里的形态，跟鸿蒙自绘的三条横杠对不上），
            // 直接画三条圆角横杠，两端像素级一致
            Column(
                verticalArrangement = Arrangement.spacedBy(3.dp),
                modifier = Modifier.padding(top = 2.dp)
            ) {
                repeat(3) {
                    Box(
                        Modifier
                            .width(19.dp)
                            .height(4.dp)
                            .clip(RoundedCornerShape(2.dp))
                            .background(Palette.mint)
                    )
                }
            }
            Spacer(Modifier.width(7.dp))
            Text("存储空间", fontSize = 12.sp, color = colors.textSecondary)
        }
        Spacer(Modifier.height(10.dp))
        Text(
            formatStorageSize(if (hasMp) total else free),
            fontSize = 22.sp,
            fontWeight = FontWeight.SemiBold,
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
        if (hasMp) {
            Spacer(Modifier.height(4.dp))
            Text(
                "已使用 $percent%",
                fontSize = 12.sp,
                color = colors.textSecondary,
                maxLines = 1
            )
            Spacer(Modifier.height(6.dp))
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(5.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(Palette.mint.copy(alpha = 0.15f))
            ) {
                Box(
                    Modifier
                        .fillMaxWidth(ratio.toFloat())
                        .height(5.dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(Palette.mint)
                )
            }
            Spacer(Modifier.height(6.dp))
            Text(
                "可用 ${formatStorageSize(free)} / 总容量 ${formatStorageSize(total)}",
                fontSize = 10.sp,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        } else {
            Spacer(Modifier.height(6.dp))
            Text(
                "剩余空间",
                fontSize = 12.sp,
                color = colors.textSecondary,
                maxLines = 1
            )
        }
    }
}
