package com.moviepilottools.mptools.ui.sites

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.Dp
import coil.compose.AsyncImage
import com.moviepilottools.mptools.data.MpSite
import com.moviepilottools.mptools.data.MpSiteUserData
import com.moviepilottools.mptools.data.formatBytes
import com.moviepilottools.mptools.data.formatStorageSize
import com.moviepilottools.mptools.net.SiteIconStore
import com.moviepilottools.mptools.ui.components.ElevatedCard
import com.moviepilottools.mptools.ui.components.OiiCard
import com.moviepilottools.mptools.ui.components.SelectablePill
import com.moviepilottools.mptools.ui.components.TinyPill
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Metrics
import com.moviepilottools.mptools.ui.theme.Palette
import com.moviepilottools.mptools.vm.MpSiteState

/**
 * 「站点」标签页：只读展示 MoviePilot 后台配置的站点 + MP 抓到的个人数据。
 *
 * 站点本身不在 App 里增删改 —— 登录、Cookie、分类映射、限流全在 MP 服务端，
 * App 只负责把结果画出来。想加站点就去 MP 后台「设置 → 站点」。
 */
@Composable
fun SiteScreen(
    site: MpSiteState,
    mpConfigured: Boolean,
    onRefresh: () -> Unit,
    onOpenSite: (MpSite) -> Unit,
    onOpenMpServers: () -> Unit,
    onLoadIcon: suspend (Int) -> Any?,
    /** 站点白名单（空 = 全部）；只管显示，不减少 MP 的请求 */
    siteFilter: List<String> = emptyList(),
    onFilterChange: (List<String>) -> Unit = {}
) {
    val colors = LocalMptColors.current
    var showFilter by remember { mutableStateOf(false) }

    // 只渲染白名单里的站；空数组 = 全部
    val visible = remember(site.sites, siteFilter) {
        if (siteFilter.isEmpty()) site.sites else site.sites.filter { it.name in siteFilter }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(colors.background)
    ) {
        Header(
            state = site,
            onRefresh = onRefresh,
            mpConfigured = mpConfigured,
            filterActive = siteFilter.isNotEmpty(),
            visibleCount = visible.size,
            onOpenFilter = { showFilter = true }
        )

        // 错误横幅固定在头部下方。之前塞在 LazyColumn 第一项里，一滚动就看不见，
        // 表现成「站点全都没有账号数据」，用户根本看不到真正原因。
        if (site.error != null && site.sites.isNotEmpty()) {
            ErrorBanner(message = site.error, onRetry = onRefresh)
        }

        when {
            !mpConfigured -> GuideCard(onOpenMpServers)

            site.sites.isEmpty() && site.loading -> LoadingBlock("正在读取站点…")

            site.sites.isEmpty() && site.error != null -> ErrorCard(site.error, onRefresh)

            site.sites.isEmpty() -> Box(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Metrics.pagePadding, vertical = 40.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    "MoviePilot 里还没有配置站点。\n请到 MP 后台「设置 → 站点」添加，本页只做同步展示。",
                    fontSize = 13.sp,
                    color = colors.textSecondary,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    lineHeight = 20.sp
                )
            }

            // 白名单里的站被删光了：别让用户对着空白列表发呆
            visible.isEmpty() -> Box(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Metrics.pagePadding, vertical = 40.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    "筛选后没有站点，点右上「筛选」重新选择。",
                    fontSize = 13.sp,
                    color = colors.textSecondary,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                )
            }

            else -> LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    start = Metrics.pagePadding,
                    end = Metrics.pagePadding,
                    top = 4.dp,
                    bottom = 110.dp
                ),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                items(visible, key = { it.id }) { item ->
                    SiteCard(
                        site = item,
                        data = site.userData[item.id],
                        onClick = { onOpenSite(item) },
                        onLoadIcon = onLoadIcon
                    )
                }
            }
        }
    }

    if (showFilter) {
        SiteFilterSheet(
            sites = site.sites,
            selected = siteFilter,
            onDismiss = { showFilter = false },
            onApply = { onFilterChange(it) }
        )
    }
}

/**
 * 站点筛选底栏：多选，空 = 全部。
 * 只影响 App 本地的显示；想减少 MP 在搜索时对站点的请求，需要去 MP 后台停用站点。
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun SiteFilterSheet(
    sites: List<MpSite>,
    selected: List<String>,
    onDismiss: () -> Unit,
    onApply: (List<String>) -> Unit
) {
    val colors = LocalMptColors.current
    var draft by remember { mutableStateOf(selected) }
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
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("选择要显示的站点", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
                    Text(
                        if (draft.isEmpty()) "当前显示全部 ${sites.size} 个站点" else "已选 ${draft.size} 个站点",
                        fontSize = 11.sp,
                        color = colors.textSecondary
                    )
                }
                TextButton(onClick = {
                    onApply(draft)
                    onDismiss()
                }) {
                    Text("完成", color = Palette.blue, fontWeight = FontWeight.Medium)
                }
            }
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp)
            ) {
                SelectablePill("全部", draft.isEmpty()) { draft = emptyList() }
                sites.forEach { s ->
                    val on = s.name in draft
                    SelectablePill(s.name, on) {
                        draft = if (on) draft - s.name else draft + s.name
                    }
                }
            }
            Spacer(Modifier.height(12.dp))
            Text(
                "这里只让列表清爽。想减少 MoviePilot 的站点压力（搜索时不去请求这些站），请到 MP 后台·站点 里停用 —— 索引器压根不会请求停用的站点。",
                fontSize = 10.sp,
                color = colors.textSecondary,
                lineHeight = 15.sp
            )
        }
    }
}

@Composable
private fun Header(
    state: MpSiteState,
    onRefresh: () -> Unit,
    mpConfigured: Boolean,
    filterActive: Boolean,
    visibleCount: Int,
    onOpenFilter: () -> Unit
) {
    val colors = LocalMptColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.pagePadding, vertical = 10.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("站点", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = colors.textPrimary)
            Spacer(Modifier.weight(1f))
            // 站点几十个时列表翻半天，这里只留常用的几个
            Text(
                "筛选",
                fontSize = 12.sp,
                color = if (filterActive) Palette.blue else colors.textSecondary,
                modifier = Modifier
                    .clip(RoundedCornerShape(9.dp))
                    .background(if (filterActive) Palette.blue.copy(alpha = 0.12f) else Color.Transparent)
                    .clickable(onClick = onOpenFilter)
                    .padding(horizontal = 10.dp, vertical = 6.dp)
            )
            IconButton(onClick = onRefresh, modifier = Modifier.size(34.dp)) {
                Icon(Icons.Rounded.Refresh, null, tint = colors.textPrimary, modifier = Modifier.size(19.dp))
            }
        }
        val subtitle = when {
            !mpConfigured -> "还没配置 MoviePilot"
            state.sites.isEmpty() -> if (state.loading) "正在同步…" else "暂无站点"
            else -> buildString {
                if (filterActive) {
                    append("显示 ").append(visibleCount).append("/").append(state.sites.size).append(" 个站点")
                } else {
                    append(state.sites.size).append(" 个站点")
                }
                if (state.hasAnyUserData) {
                    append(" · 做种 ").append(state.totalSeeding)
                    append(" · ↑").append(formatBytes(state.totalUpload))
                    append(" ↓").append(formatBytes(state.totalDownload))
                }
            }
        }
        Spacer(Modifier.height(3.dp))
        Text(subtitle, fontSize = 12.sp, color = colors.textSecondary)
    }
}

@Composable
private fun SiteCard(
    site: MpSite,
    data: MpSiteUserData?,
    onClick: () -> Unit,
    onLoadIcon: suspend (Int) -> Any?
) {
    val colors = LocalMptColors.current
    ElevatedCard(
        // 不能套 .clip()：会把卡片画在圆角外的柔光投影裁掉（悬浮残缺）
        modifier = Modifier
            .fillMaxWidth()
            .alpha(if (site.isActive) 1f else 0.45f)
            .clickable(onClick = onClick),
        padding = 13.dp,
        subtle = true
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SiteAvatar(site, onLoadIcon)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    // 名字先占剩余空间（Row 里带 weight 的子项最后测量），
                    // 右边的等级/未读/箭头按自身宽度先排好，长站名自动省略
                    Text(
                        site.name,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                    if (data != null && data.userLevel.isNotBlank()) {
                        Spacer(Modifier.width(6.dp))
                        TinyPill(
                            data.userLevel.take(10),
                            Palette.purple.copy(alpha = 0.16f),
                            Palette.purple
                        )
                    }
                    if (data != null && data.messageUnread > 0) {
                        Spacer(Modifier.width(4.dp))
                        TinyPill(
                            "${data.messageUnread}",
                            Palette.red.copy(alpha = 0.16f),
                            Palette.red
                        )
                    }
                    Spacer(Modifier.width(4.dp))
                    if (!site.isActive) {
                        TinyPill("未启用", colors.separator, colors.textSecondary)
                    } else {
                        Icon(
                            Icons.Rounded.ChevronRight,
                            null,
                            tint = colors.textSecondary.copy(alpha = 0.5f),
                            modifier = Modifier.size(14.dp)
                        )
                    }
                }

                Spacer(Modifier.height(6.dp))
                if (data == null) {
                    Text(
                        "暂无账号数据（MP 未抓取或 Cookie 失效）",
                        fontSize = 11.sp,
                        color = colors.textSecondary
                    )
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Rounded.ArrowUpward,
                            null,
                            tint = Palette.green,
                            modifier = Modifier.size(11.dp)
                        )
                        Text(
                            " ${formatStorageSize(data.upload)}",
                            fontSize = 11.sp,
                            color = colors.textSecondary
                        )
                        Spacer(Modifier.width(8.dp))
                        Icon(
                            Icons.Rounded.ArrowDownward,
                            null,
                            tint = Palette.blue,
                            modifier = Modifier.size(11.dp)
                        )
                        Text(
                            " ${formatStorageSize(data.download)}",
                            fontSize = 11.sp,
                            color = colors.textSecondary
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(
                            "分享率 ${data.ratioText}",
                            fontSize = 11.sp,
                            color = if (data.ratio < 1.0) Palette.red else Palette.green
                        )
                    }
                    Spacer(Modifier.height(3.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "做种 ${data.seeding} · ${formatStorageSize(data.seedingSize)}",
                            fontSize = 11.sp,
                            color = colors.textSecondary
                        )
                        if (data.updatedText.isNotBlank()) {
                            Spacer(Modifier.width(10.dp))
                            Text(
                                data.updatedText,
                                fontSize = 11.sp,
                                color = if (data.isStale) Palette.orange else colors.textSecondary
                            )
                        }
                    }
                }

                if (site.displayDomain.isNotBlank()) {
                    Spacer(Modifier.height(3.dp))
                    Text(
                        site.displayDomain,
                        fontSize = 11.sp,
                        color = colors.textSecondary.copy(alpha = 0.75f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }

                if (data != null && data.hasError) {
                    Spacer(Modifier.height(5.dp))
                    Text(
                        data.errMsg,
                        fontSize = 11.sp,
                        color = Palette.red,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        lineHeight = 16.sp
                    )
                }
            }
        }
    }
}

/**
 * 站点头像：优先用 MP 里存的真实图标（`site/icon/{id}`），拿不到才退回首字色块。
 *
 * 图标是懒加载的：LazyColumn 只组合可见的卡片，滚出屏幕就不再请求；
 * 拿到的结果由 [SiteIconStore] 内存缓存，滚回来 / 切页再进都不重复拉。
 */
@Composable
internal fun SiteAvatar(
    site: MpSite,
    onLoadIcon: suspend (Int) -> Any?,
    size: Dp = 38.dp,
    corner: Dp = 11.dp
) {
    // model 有两种：远程 URL（String）或已经解码好的 Bitmap（MP 给的是 base64 那种）
    var iconModel by remember(site.id) { mutableStateOf(SiteIconStore.cached(site.id)) }
    // URL 型图标可能被站点防盗链挡住（403/超时），失败就退回首字，不留白块
    var iconFailed by remember(site.id) { mutableStateOf(false) }

    LaunchedEffect(site.id) {
        if (iconModel == null) iconModel = onLoadIcon(site.id)
    }

    val model = iconModel
    if (model != null && !iconFailed) {
        AsyncImage(
            model = model,
            contentDescription = site.name,
            contentScale = ContentScale.Crop,
            onError = { iconFailed = true },
            modifier = Modifier
                .size(size)
                .clip(RoundedCornerShape(corner))
                .background(Color.White)
        )
    } else {
        // 没有图标（或图标还没到）：按站名取色的首字块，保证列表不会空一块
        val hue = ((site.name.hashCode() ushr 3 and 0xFF).toFloat() / 255f * 300f + 20f) % 360f
        Box(
            Modifier
                .size(size)
                .clip(RoundedCornerShape(corner))
                .background(Color.hsv(hue, 0.45f, 0.62f)),
            contentAlignment = Alignment.Center
        ) {
            Text(
                site.initial,
                color = Color.White,
                fontSize = (size.value * 0.45f).sp,
                fontWeight = FontWeight.Bold
            )
        }
    }
}

@Composable
private fun LoadingBlock(text: String) {
    val colors = LocalMptColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        CircularProgressIndicator(
            color = Palette.blue,
            strokeWidth = 2.dp,
            modifier = Modifier.size(22.dp)
        )
        Spacer(Modifier.height(12.dp))
        Text(text, fontSize = 13.sp, color = colors.textSecondary)
    }
}

/** 固定在头部下方的错误条：不允许随列表滚走 */
@Composable
private fun ErrorBanner(message: String, onRetry: () -> Unit) {
    val colors = LocalMptColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.pagePadding, vertical = 2.dp)
            .clip(RoundedCornerShape(Metrics.tileRadius))
            .background(Palette.orange.copy(alpha = 0.12f))
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(Icons.Rounded.CloudOff, null, tint = Palette.orange, modifier = Modifier.size(15.dp))
        Spacer(Modifier.width(8.dp))
        Text(
            message,
            fontSize = 11.sp,
            color = Palette.orange,
            lineHeight = 16.sp,
            modifier = Modifier.weight(1f)
        )
        Spacer(Modifier.width(8.dp))
        Text(
            "重试",
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = colors.accent,
            modifier = Modifier.clickable(onClick = onRetry)
        )
    }
}

@Composable
private fun ErrorCard(message: String, onRetry: () -> Unit) {
    val colors = LocalMptColors.current
    OiiCard(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.pagePadding),
        padding = 16.dp
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.CloudOff, null, tint = Palette.orange, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("站点读取失败", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
        }
        Spacer(Modifier.height(8.dp))
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

@Composable
private fun GuideCard(onOpenMpServers: () -> Unit) {
    val colors = LocalMptColors.current
    OiiCard(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.pagePadding),
        padding = 16.dp
    ) {
        Text("还没有配置 MoviePilot", fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
        Spacer(Modifier.height(6.dp))
        Text(
            "站点、种子、个人数据都来自 MoviePilot，先把它连上再回来。",
            fontSize = 12.sp,
            color = colors.textSecondary,
            lineHeight = 18.sp
        )
        Spacer(Modifier.height(10.dp))
        Text(
            "去配置 MoviePilot",
            fontSize = 13.sp,
            color = colors.accent,
            modifier = Modifier.clickable(onClick = onOpenMpServers)
        )
    }
}
