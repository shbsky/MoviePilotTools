package com.oiiqt.android.ui.sites

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Download
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.compose.AsyncImagePainter
import com.oiiqt.android.data.MpResource
import com.oiiqt.android.data.formatRelativeTime
import com.oiiqt.android.data.formatStorageSize
import com.oiiqt.android.ui.components.ElevatedCard
import com.oiiqt.android.ui.components.TinyPill
import com.oiiqt.android.ui.moviepilot.posterFallback
import com.oiiqt.android.ui.theme.LocalOiiColors
import com.oiiqt.android.ui.theme.Metrics
import com.oiiqt.android.ui.theme.Palette
import com.oiiqt.android.vm.MpViewModel

/**
 * 站点种子的全屏详情页。
 *
 * v1.0.20 起和 MP 搜索结果页统一：站点接口本身只有标题/简介/体积几个文字字段，
 * 所以进页面时用种子标题去 MP 识别一次（[onLoadTorrentMedia]），
 * 拿到中文标题、类型、评分、简介、演职员，版式与 `MediaDetailScreen` 对齐：
 * 海报 + 信息 → 种子数据 → 简介 → 演职员，卡片全部用悬浮卡。
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SiteTorrentDetailScreen(
    resource: MpResource,
    poster: String?,
    siteName: String,
    onLoadTorrentMedia: suspend (String) -> MpViewModel.TorrentMediaInfo,
    onBack: () -> Unit,
    onDownload: () -> Unit,
    onOpenUrl: () -> Unit
) {
    val colors = LocalOiiColors.current
    BackHandler(onBack = onBack)
    var posterFailed by remember(poster) { mutableStateOf(false) }
    var expandOverview by remember { mutableStateOf(true) }
    var info by remember(resource.key) { mutableStateOf(MpViewModel.TorrentMediaInfo()) }

    // 进页面识别一次：拿到 MP 侧的标题 / 简介 / 演职员。失败就整页退回站点数据，不挡渲染
    LaunchedEffect(resource.key) {
        info = runCatching { onLoadTorrentMedia(resource.title) }
            .getOrDefault(MpViewModel.TorrentMediaInfo())
    }

    val mp = info.media
    val displayTitle = mp?.title?.takeIf { it.isNotBlank() } ?: resource.title
    val posterUrl = mp?.posterUrl?.takeIf { it.isNotBlank() } ?: poster
    val metaLine = listOfNotNull(
        mp?.yearLabel?.takeIf { it.isNotBlank() } ?: resource.pubDateText.take(4).takeIf { it.isNotBlank() },
        mp?.typeLabel
    ).joinToString(" · ")
    val overview = mp?.overview?.takeIf { it.isNotBlank() } ?: resource.description.trim()
    val fromSite = mp?.overview.isNullOrBlank()

    Column(
        Modifier
            .fillMaxSize()
            .background(colors.background)
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 6.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack, modifier = Modifier.size(38.dp)) {
                Icon(
                    Icons.Rounded.ArrowBack,
                    contentDescription = "返回",
                    tint = colors.textPrimary,
                    modifier = Modifier.size(20.dp)
                )
            }
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    "种子详情",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.textPrimary
                )
                Text(
                    siteName,
                    fontSize = 11.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            // 右侧占位，标题才是真正居中（和鸿蒙版一致）
            Spacer(Modifier.width(38.dp))
        }

        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Metrics.pagePadding)
        ) {
            // ---- 海报 + 信息（对应 MP 详情页顶部那一段） ----
            Row(Modifier.fillMaxWidth()) {
                Poster(resource.title, posterUrl, posterFailed) { posterFailed = true }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        displayTitle,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.textPrimary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                    Spacer(Modifier.height(4.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            metaLine,
                            fontSize = 11.sp,
                            color = colors.textSecondary
                        )
                        if ((mp?.vote ?: 0.0) > 0.0) {
                            Spacer(Modifier.width(6.dp))
                            Text(
                                String.format(java.util.Locale.US, "★ %.1f", mp?.vote),
                                fontSize = 11.sp,
                                color = Color(0xFFFF9500)
                            )
                        }
                    }
                    if (!mp?.genres.isNullOrEmpty()) {
                        Spacer(Modifier.height(6.dp))
                        Text(
                            mp?.genres?.take(4)?.joinToString(" / ") ?: "",
                            fontSize = 11.sp,
                            color = colors.textSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    if (!mp?.directors.isNullOrEmpty()) {
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "导演：${mp?.directors?.take(2)?.joinToString("、")}",
                            fontSize = 11.sp,
                            color = colors.textSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    if (!mp?.cast.isNullOrEmpty()) {
                        Spacer(Modifier.height(2.dp))
                        Text(
                            "主演：${mp?.cast?.take(3)?.joinToString("、")}",
                            fontSize = 11.sp,
                            color = colors.textSecondary,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                    // 规格标签：促销 / 分辨率 / 来源 / 制作组 …（和列表卡片同一套 badges）
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        badgesOf(resource).forEach { (text, tint) ->
                            TinyPill(text, tint.copy(alpha = 0.15f), tint)
                        }
                    }
                }
            }

            Spacer(Modifier.height(14.dp))
            // ---- 种子数据（站点页独有） ----
            TorrentInfoCard(resource, siteName)

            if (overview.isNotBlank()) {
                Spacer(Modifier.height(12.dp))
                ElevatedCard(
                    modifier = Modifier.fillMaxWidth(),
                    padding = 13.dp,
                    subtle = true,
                    corner = 18.dp
                ) {
                    Text(
                        "简介",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.textPrimary
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        overview,
                        fontSize = 12.sp,
                        color = colors.textSecondary,
                        lineHeight = 19.sp,
                        maxLines = if (expandOverview) Int.MAX_VALUE else 4,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        if (expandOverview) "收起" else "展开",
                        fontSize = 11.sp,
                        color = Palette.blue,
                        modifier = Modifier.padding(top = 4.dp).clickable { expandOverview = !expandOverview }
                    )
                    if (fromSite) {
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "MP 未识别到该种子，简介由站点提供。",
                            fontSize = 10.sp,
                            color = colors.textSecondary.copy(alpha = 0.7f)
                        )
                    }
                }
            }

            if (info.creditNames.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                ElevatedCard(
                    modifier = Modifier.fillMaxWidth(),
                    padding = 13.dp,
                    subtle = true,
                    corner = 18.dp
                ) {
                    Text(
                        "演职员",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.textPrimary
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        info.creditNames.take(12).joinToString("、"),
                        fontSize = 11.sp,
                        color = colors.textSecondary,
                        lineHeight = 17.sp
                    )
                }
            }

            Spacer(Modifier.height(24.dp))
        }

        BottomBar(
            hasUrl = resource.pageUrl.isNotBlank(),
            onDownload = onDownload,
            onOpenUrl = onOpenUrl
        )
    }
}

@Composable
private fun Poster(
    title: String,
    poster: String?,
    failed: Boolean,
    onFail: () -> Unit
) {
    Box(
        Modifier
            .width(96.dp)
            .aspectRatio(0.68f)
            .clip(RoundedCornerShape(10.dp))
            .background(posterFallback(title))
    ) {
        if (!poster.isNullOrBlank() && !failed) {
            AsyncImage(
                model = poster,
                contentDescription = title,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
                onState = { state ->
                    if (state is AsyncImagePainter.State.Error) onFail()
                }
            )
        } else {
            Text(
                title.take(1).uppercase(),
                color = Color.White.copy(alpha = 0.9f),
                fontSize = 30.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.align(Alignment.Center)
            )
        }
    }
}

/** 种子本身的数据：做种/下载中/完成 + 体积/发布/站点。站点页独有，MP 搜索页没有。 */
@Composable
private fun TorrentInfoCard(resource: MpResource, siteName: String) {
    val colors = LocalOiiColors.current
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        padding = 14.dp,
        subtle = true,
        corner = 18.dp
    ) {
        Row(Modifier.fillMaxWidth()) {
            InfoCell("做种", "${resource.seeders}", Palette.green, Modifier.weight(1f))
            InfoCell("下载中", "${resource.peers}", colors.textPrimary, Modifier.weight(1f))
            InfoCell("完成", "${resource.grabs}", colors.textPrimary, Modifier.weight(1f))
        }
        Spacer(Modifier.height(12.dp))
        Box(
            Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(colors.separator)
        )
        Spacer(Modifier.height(10.dp))
        MetaRow("体积", formatStorageSize(resource.sizeBytes))
        MetaRow("发布", formatRelativeTime(resource.pubDateMs))
        MetaRow("站点", siteName)
        MetaRow("种子名", resource.title)
    }
}

@Composable
private fun InfoCell(label: String, value: String, valueColor: Color, modifier: Modifier = Modifier) {
    val colors = LocalOiiColors.current
    Column(modifier) {
        Text(
            value,
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
            color = valueColor,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
        Spacer(Modifier.height(2.dp))
        Text(label, fontSize = 11.sp, color = colors.textSecondary)
    }
}

@Composable
private fun MetaRow(label: String, value: String) {
    val colors = LocalOiiColors.current
    Row(Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
        Text(label, fontSize = 11.5.sp, color = colors.textSecondary, modifier = Modifier.width(48.dp))
        Text(
            value,
            fontSize = 11.5.sp,
            color = colors.textPrimary,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )
    }
}

@Composable
private fun BottomBar(hasUrl: Boolean, onDownload: () -> Unit, onOpenUrl: () -> Unit) {
    val colors = LocalOiiColors.current
    // 以前这里是一条整行的 card 色（浅色主题下就是一条白底），压在白卡列表上很割裂；
    // 改成「向上渐隐」：底部是页面背景色，上沿淡出，滚到一半的内容不会硬生生被切断
    Box(
        Modifier
            .fillMaxWidth()
            .background(
                androidx.compose.ui.graphics.Brush.verticalGradient(
                    listOf(Color.Transparent, colors.background, colors.background)
                )
            )
            .navigationBarsPadding()
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (hasUrl) {
                // 次要但明显可点：主色文字 + 淡蓝底 + 淡蓝描边，不用「灰底灰字」伪装成禁用态
                Box(
                    Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(13.dp))
                        .background(colors.accent.copy(alpha = 0.10f))
                        .border(1.dp, colors.accent.copy(alpha = 0.35f), RoundedCornerShape(13.dp))
                        .clickable(onClick = onOpenUrl)
                        .padding(vertical = 13.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        "浏览器打开",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.accent
                    )
                }
            }
            Box(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(13.dp))
                    .background(Palette.blue)
                    .clickable(onClick = onDownload)
                    .padding(vertical = 13.dp),
                contentAlignment = Alignment.Center
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Rounded.Download,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(Modifier.width(5.dp))
                    Text("下载", fontSize = 14.sp, color = Color.White, fontWeight = FontWeight.Medium)
                }
            }
        }
    }
}

/**
 * 促销 + 规格标签，和列表卡片 / 搜索页同一套（v1.0.15 起统一走 MpResource.badges()）。
 * 以前这里 labels 只取前 2 个，中字/国语/特效显示不全。
 */
private fun badgesOf(resource: MpResource): List<Pair<String, Color>> =
    resource.badges().map { it to resourceBadgeTint(it, resource) }

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
