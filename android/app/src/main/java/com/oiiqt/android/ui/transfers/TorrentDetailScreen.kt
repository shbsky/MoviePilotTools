package com.oiiqt.android.ui.transfers

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.compose.AsyncImagePainter
import com.oiiqt.android.data.TorrentStatus
import com.oiiqt.android.data.TorrentTask
import com.oiiqt.android.data.extractResolutionBadge
import com.oiiqt.android.data.formatBytes
import com.oiiqt.android.data.formatDateTime
import com.oiiqt.android.data.formatDurationCN
import com.oiiqt.android.data.formatPercent
import com.oiiqt.android.data.formatStorageSize
import com.oiiqt.android.ui.components.DividerLine
import com.oiiqt.android.ui.components.OiiDialog
import com.oiiqt.android.ui.components.PageHeader
import com.oiiqt.android.ui.components.TinyPill
import com.oiiqt.android.ui.moviepilot.posterFallback
import com.oiiqt.android.ui.theme.LocalOiiColors
import com.oiiqt.android.ui.theme.Metrics
import com.oiiqt.android.ui.theme.Palette
import com.oiiqt.android.vm.TorrentAction
import java.util.Locale

/**
 * 任务详情（v1.0.13：弹窗 → 整页）。
 *
 * 用户要求：详情、种子操作这类「只读/浏览」的面板改回全屏页面，
 * 只有真正改数据的地方（重命名 / 保存位置 / 限速 / 分享率 / Tracker）继续用弹窗。
 *
 * 版式：
 * 1. 顶栏 = 圆形返回钮 + 「任务详情」+ 下载器名（与站点详情页同一套）；
 * 2. 海报缩到 62×86，状态 / 进度 / 服务器挤成一行，省下的高度全给明细；
 * 3. 内容整体可滚（小屏也能看完），暂停 / 校验 / 删除放在「数据简报」**之前**，先看见按钮；
 * 4. 明细块从「凹下去的页面底色」改成卡片色——整页底色是 background，再用 background 就糊成一片。
 */
@Composable
fun TorrentDetailScreen(
    task: TorrentTask,
    serverName: String,
    onBack: () -> Unit,
    onAction: (TorrentAction) -> Unit,
    /** 按标题向 MoviePilot 反查海报；没配 MP 或查不到就返回 null，用渐变兜底 */
    loadPoster: suspend (String) -> String? = { null }
) {
    val colors = LocalOiiColors.current
    var confirmDelete by remember { mutableStateOf(false) }
    var deleteFiles by remember { mutableStateOf(false) }
    val badge = remember(task.name) { extractResolutionBadge(task.name) }
    val statusColor = Color(task.status.accentArgb)

    // 任务名不变就不再重复问 MP（缓存命中是瞬时的，重复调用也只是读内存）
    var poster by remember(task.id) { mutableStateOf<String?>(null) }
    var posterFailed by remember(task.id) { mutableStateOf(false) }
    LaunchedEffect(task.id) {
        if (poster == null) poster = runCatching { loadPoster(task.name) }.getOrNull()
    }

    Box(Modifier.fillMaxSize().background(colors.background)) {
    Column(
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        PageHeader(title = "任务详情", subtitle = serverName, onBack = onBack)

        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Metrics.pagePadding)
                .padding(bottom = 20.dp)
        ) {
        Row {
            Box(
                Modifier
                    .width(62.dp)
                    .height(86.dp)
                    .clip(RoundedCornerShape(9.dp))
                    .background(posterFallback(task.name)),
                contentAlignment = Alignment.Center
            ) {
                if (!poster.isNullOrBlank() && !posterFailed) {
                    AsyncImage(
                        model = poster,
                        contentDescription = task.name,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                        onState = { state ->
                            if (state is AsyncImagePainter.State.Error) posterFailed = true
                        }
                    )
                } else {
                    Text(
                        task.name.take(1).uppercase(),
                        color = Color.White.copy(alpha = 0.9f),
                        fontSize = 26.sp,
                        fontWeight = FontWeight.Bold
                    )
                }
                if (badge != null) {
                    Box(
                        Modifier
                            .align(Alignment.TopStart)
                            .padding(4.dp)
                            .clip(RoundedCornerShape(5.dp))
                            .background(Color(badge.argb))
                            .padding(horizontal = 5.dp, vertical = 1.dp)
                    ) {
                        Text(badge.text, color = Color.White, fontSize = 9.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    breakableName(task.name),
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.textPrimary,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                    lineHeight = 20.sp
                )
                Spacer(Modifier.height(8.dp))
                Row(
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    TinyPill(task.status.label, statusColor.copy(alpha = 0.16f), statusColor)
                    TinyPill(formatPercent(task.progress), colors.separator, colors.textSecondary)
                    TinyPill(serverName, Palette.blue.copy(alpha = 0.14f), Palette.blue)
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    task.trackerHost.ifBlank { "未知 Tracker" },
                    fontSize = 11.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }

        // 操作排放在简报之前：内容再多也先看见按钮
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ActionButton(
                text = if (task.status == TorrentStatus.PAUSED) "继续" else "暂停",
                icon = if (task.status == TorrentStatus.PAUSED) Icons.Rounded.PlayArrow else Icons.Rounded.Pause,
                tint = Palette.blue,
                modifier = Modifier.weight(1f)
            ) {
                onAction(if (task.status == TorrentStatus.PAUSED) TorrentAction.RESUME else TorrentAction.PAUSE)
            }
            ActionButton(
                text = "校验",
                icon = Icons.Rounded.Refresh,
                tint = Palette.orange,
                modifier = Modifier.weight(1f)
            ) { onAction(TorrentAction.RECHECK) }
            ActionButton(
                text = "删除",
                icon = Icons.Rounded.Delete,
                tint = Palette.red,
                modifier = Modifier.weight(1f)
            ) { confirmDelete = true }
        }

        Spacer(Modifier.height(14.dp))
        Text("数据简报", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = colors.textSecondary)
        Spacer(Modifier.height(6.dp))

        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                // 整页底色是 background，明细块要反过来用 card 色才看得出是一块卡
                .background(colors.card)
                .padding(horizontal = 12.dp, vertical = 2.dp)
        ) {
            if (task.taxonomyTags.isNotEmpty() || task.category.isNotBlank()) {
                InfoRow(label = "分类 / 标签") {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.End
                    ) {
                        if (task.category.isNotBlank()) {
                            TinyPill(task.category, Palette.green.copy(alpha = 0.14f), Palette.green)
                        }
                        task.tags.take(3).forEach {
                            TinyPill(it, Palette.purple.copy(alpha = 0.14f), Palette.purple)
                        }
                    }
                }
                DividerLine()
            }

            InfoRow(label = "速率") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.ArrowDownward, null, tint = Palette.blue, modifier = Modifier.size(12.dp))
                    Text(" ${formatBytes(task.downloadSpeed)}/s", fontSize = 12.5.sp, color = colors.textPrimary)
                    Spacer(Modifier.width(10.dp))
                    Icon(Icons.Rounded.ArrowUpward, null, tint = Palette.green, modifier = Modifier.size(12.dp))
                    Text(" ${formatBytes(task.uploadSpeed)}/s", fontSize = 12.5.sp, color = colors.textPrimary)
                }
            }
            DividerLine()

            InfoRow(label = "流量") {
                Text(
                    "↓${formatStorageSize(task.downloaded)}  ↑${formatStorageSize(task.uploaded)}",
                    fontSize = 12.5.sp,
                    color = colors.textPrimary
                )
            }
            DividerLine()

            InfoRow(label = "分享率") {
                Text(
                    String.format(Locale.US, "%.2f", task.ratio),
                    fontSize = 12.5.sp,
                    color = if (task.ratio < 1.0) Palette.red else Palette.green
                )
            }
            DividerLine()

            InfoRow(label = "添加时间") {
                Text(formatDateTime(task.addedAt), fontSize = 12.5.sp, color = colors.textPrimary)
            }
            DividerLine()

            InfoRow(label = "完成时间") {
                Text(
                    if (task.completedAt > 0) formatDateTime(task.completedAt) else "--",
                    fontSize = 12.5.sp,
                    color = colors.textPrimary
                )
            }
            DividerLine()

            InfoRow(label = "保存路径") {
                Text(
                    task.savePath.ifBlank { "--" },
                    fontSize = 12.5.sp,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            DividerLine()

            InfoRow(label = "文件大小") {
                Text(formatStorageSize(task.size), fontSize = 12.5.sp, color = colors.textPrimary)
            }
            DividerLine()

            InfoRow(label = "用户") {
                Text(
                    "${task.numSeeds}/${task.numPeers}",
                    fontSize = 12.5.sp,
                    color = colors.textPrimary
                )
            }
            if (task.seedingSeconds > 0) {
                DividerLine()
                InfoRow(label = "做种时长") {
                    Text(formatDurationCN(task.seedingSeconds), fontSize = 12.5.sp, color = colors.textPrimary)
                }
            }
            if (task.errorMessage.isNotBlank()) {
                DividerLine()
                InfoRow(label = "状态信息") {
                    Text(task.errorMessage, fontSize = 12.5.sp, color = Palette.red, maxLines = 2)
                }
            }
        }
        }
    }
    }

    if (confirmDelete) {
        OiiDialog(
            title = "删除任务",
            confirmText = "删除",
            destructive = true,
            maxHeight = 240.dp,
            onDismiss = { confirmDelete = false },
            onConfirm = {
                confirmDelete = false
                onAction(if (deleteFiles) TorrentAction.DELETE_WITH_FILES else TorrentAction.DELETE)
                onBack()
            }
        ) {
            Text(
                "确定要删除「${task.name.take(40)}」吗？",
                fontSize = 13.sp,
                color = colors.textPrimary,
                lineHeight = 19.sp
            )
            Spacer(Modifier.height(12.dp))
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { deleteFiles = !deleteFiles }
                    .padding(vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                // 自绘小方块在浅色底上几乎看不见，用实线边框 + 打勾的版本
                CheckBoxBox(deleteFiles)
                Spacer(Modifier.width(10.dp))
                Text(
                    "同时删除已下载的文件",
                    fontSize = 14.sp,
                    color = if (deleteFiles) Palette.red else colors.textPrimary
                )
            }
        }
    }
}

@Composable
private fun InfoRow(label: String, value: @Composable () -> Unit) {
    val colors = LocalOiiColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, fontSize = 12.5.sp, color = colors.textSecondary)
        Spacer(Modifier.width(16.dp))
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
            value()
        }
    }
}

/**
 * 种子名常是「[合雨] The.Silent.Storm.2026.S01.2160p.60fps...」这种无空格长串，
 * Compose 默认不敢在单词中间断行，会把整串推到下一行 → 首行只剩两个字符。
 * 在每个字符后插入零宽空格（U+200B），给排版引擎制造合法断点，效果等同鸿蒙的 WordBreak.BREAK_ALL。
 * 只用于显示：徽章识别 / 内容描述 / 搜索仍用原 task.name，不受影响。
 */
private fun breakableName(name: String): String {
    if (name.length < 12) return name
    val sb = StringBuilder(name.length * 2)
    for (ch in name) {
        sb.append(ch)
        sb.append('\u200B')
    }
    return sb.toString()
}

@Composable
private fun ActionButton(
    text: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: Color,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(tint.copy(alpha = 0.12f))
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(5.dp))
        Text(text, color = tint, fontSize = 13.5.sp, fontWeight = FontWeight.Medium)
    }
}
