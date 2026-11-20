package com.oiiqt.android.ui.transfers

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oiiqt.android.data.ServerConfig
import com.oiiqt.android.data.ServerSnapshot
import com.oiiqt.android.data.formatBytes
import com.oiiqt.android.data.formatStorageSize
import com.oiiqt.android.ui.components.Dot
import com.oiiqt.android.ui.components.OiiCard
import com.oiiqt.android.ui.components.ServerBadge
import com.oiiqt.android.ui.theme.LocalOiiColors
import com.oiiqt.android.ui.theme.Palette
import java.util.Locale

/**
 * 下载器状态卡：进了某台下载器的任务页后，先把这台机器的关键数字摊在顶上。
 *
 * 和仪表盘那张小卡片的口径完全一致（都来自 [ServerSnapshot]，即同一次 RPC 的结果），
 * 所以这里显示的速度/做种/空间应当和仪表盘、qB 网页三处对得上。
 * 仪表盘那张卡是为了「扫一眼」，这张是为了「进来确认」，所以铺成 2×2 而不是两行小字。
 */
@Composable
fun DownloaderStatusCard(
    server: ServerConfig,
    snapshot: ServerSnapshot?,
    taskCount: Int,
    modifier: Modifier = Modifier
) {
    val colors = LocalOiiColors.current
    val online = snapshot?.online == true

    OiiCard(modifier = modifier.fillMaxWidth(), padding = 14.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ServerBadge(server.type, 22)
            Spacer(Modifier.width(8.dp))
            Text(
                server.displayName,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
            Dot(
                when {
                    snapshot == null -> Palette.orange
                    online -> Palette.green
                    else -> Palette.red
                },
                8
            )
            Spacer(Modifier.width(5.dp))
            Text(
                when {
                    snapshot == null -> "连接中"
                    online -> "在线"
                    else -> "离线"
                },
                fontSize = 11.sp,
                color = colors.textSecondary
            )
            if (online && snapshot != null && snapshot.appVersion.isNotBlank()) {
                Spacer(Modifier.width(8.dp))
                Text(
                    snapshot.appVersion.take(14),
                    fontSize = 11.sp,
                    color = colors.textSecondary
                )
            }
        }

        Spacer(Modifier.height(12.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Metric(
                label = "下载速度",
                value = formatBytes(snapshot?.downloadSpeed ?: 0) + "/s",
                tint = Palette.blue,
                modifier = Modifier.weight(1f)
            )
            Metric(
                label = "上传速度",
                value = formatBytes(snapshot?.uploadSpeed ?: 0) + "/s",
                tint = Palette.green,
                modifier = Modifier.weight(1f)
            )
        }
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Metric(
                label = "剩余空间",
                value = if ((snapshot?.freeSpace ?: 0) > 0) {
                    formatStorageSize(snapshot?.freeSpace ?: 0)
                } else {
                    "--"
                },
                tint = colors.textPrimary,
                modifier = Modifier.weight(1f)
            )
            Metric(
                label = "做种 / 下载中",
                value = "${snapshot?.seedingCount ?: 0} / ${snapshot?.downloadingCount ?: 0}",
                tint = colors.textPrimary,
                modifier = Modifier.weight(1f)
            )
        }
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Metric(
                label = "分享率",
                value = String.format(Locale.US, "%.2f", snapshot?.ratio ?: 0.0),
                tint = if ((snapshot?.ratio ?: 0.0) >= 1.0) Palette.green
                else if ((snapshot?.ratio ?: 0.0) > 0.0) Palette.orange
                else colors.textSecondary,
                modifier = Modifier.weight(1f)
            )
            Metric(
                label = "做种体积 · 任务",
                value = "${formatStorageSize(snapshot?.seedingSize ?: 0)} · $taskCount",
                tint = colors.textPrimary,
                modifier = Modifier.weight(1f)
            )
        }

        if (!online && snapshot?.error != null) {
            Spacer(Modifier.height(10.dp))
            Text(
                snapshot.error,
                fontSize = 11.sp,
                color = Palette.red,
                lineHeight = 16.sp
            )
        } else if (snapshot != null && snapshot.endpointLabel.isNotBlank()) {
            Spacer(Modifier.height(8.dp))
            Text(
                snapshot.endpointLabel,
                fontSize = 11.sp,
                color = colors.textSecondary.copy(alpha = 0.8f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
private fun Metric(
    label: String,
    value: String,
    tint: Color,
    modifier: Modifier = Modifier
) {
    val colors = LocalOiiColors.current
    Column(modifier = modifier) {
        Text(
            value,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            color = tint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
        Spacer(Modifier.height(2.dp))
        Text(label, fontSize = 11.sp, color = colors.textSecondary, maxLines = 1)
    }
}
