package com.oiiqt.android.ui.sites

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oiiqt.android.data.MpResource
import com.oiiqt.android.data.MpSavePath
import com.oiiqt.android.data.formatStorageSize
import com.oiiqt.android.ui.components.BasicField
import com.oiiqt.android.ui.components.OiiDialog
import com.oiiqt.android.ui.components.SelectablePill
import com.oiiqt.android.ui.theme.LocalOiiColors
import com.oiiqt.android.ui.theme.Palette

/**
 * 站点种子的投递弹窗（v1.0.11：底部半屏面板 → 居中弹窗）。
 *
 * 路径三档：
 * - **自动**（返回 null）：由 MoviePilot 按识别结果 + 下载目录规则自己挑
 * - **已配置目录**：来自 `GET api/v1/download/paths`，提交时传目录的 save_path（或别名）
 * - **手动输入**：支持 `rclone:/MP`、`smb:/server/share/Movies` 这类 URI
 */
@Composable
fun SiteDownloadSheet(
    resource: MpResource,
    downloaders: List<String>,
    savePaths: List<MpSavePath>,
    defaultDownloader: String?,
    defaultSavePath: String?,
    submitting: Boolean,
    error: String?,
    done: String?,
    onDismiss: () -> Unit,
    onConfirm: (String?, String?) -> Unit
) {
    val colors = LocalOiiColors.current

    // 上次选的是不在列表里的路径 → 当作手动输入回填
    val initialManual = defaultSavePath != null && savePaths.none { it.savePath == defaultSavePath }
    var downloader by remember { mutableStateOf(defaultDownloader) }
    var presetPath by remember { mutableStateOf(if (initialManual) null else defaultSavePath) }
    var manualMode by remember { mutableStateOf(initialManual) }
    var manual by remember { mutableStateOf(if (initialManual) defaultSavePath.orEmpty() else "") }

    val effectivePath = if (manualMode) manual.trim().ifBlank { null } else presetPath
    val canConfirm = !submitting && (!manualMode || manual.isNotBlank())

    if (done != null) {
        // 成功态：不关弹窗，直接把结果摆出来（以前只有一闪而过的 toast，用户根本不知道成没成）
        OiiDialog(
            title = "已推送到 MoviePilot",
            subtitle = done,
            confirmText = "完成",
            cancelText = null,
            maxHeight = 200.dp,
            onDismiss = onDismiss,
            onConfirm = onDismiss
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(34.dp)
                        .clip(CircleShape)
                        .background(Palette.green.copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        Icons.Rounded.CheckCircle,
                        null,
                        tint = Palette.green,
                        modifier = Modifier.size(20.dp)
                    )
                }
                Spacer(Modifier.width(10.dp))
                Text(
                    "MP 收到后会交给下载器建任务，一般 2~5 秒，去下载器页就能看到。",
                    fontSize = 11.5.sp,
                    color = colors.textSecondary,
                    lineHeight = 17.sp
                )
            }
        }
        return
    }

    OiiDialog(
        title = "投递到下载器",
        subtitle = resource.title,
        confirmText = when {
            submitting -> "正在投递…"
            error != null -> "重试"
            else -> "确认下载"
        },
        confirmEnabled = canConfirm,
        busy = submitting,
        maxHeight = 320.dp,
        onDismiss = onDismiss,
        onConfirm = { onConfirm(downloader, effectivePath) }
    ) {
        Text(
            "${resource.siteName} · ${formatStorageSize(resource.sizeBytes)} · ${resource.seeders} 个做种",
            fontSize = 11.sp,
            color = colors.textSecondary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            lineHeight = 16.sp
        )

        if (downloaders.size > 1) {
            Text(
                "下载器",
                fontSize = 12.sp,
                color = colors.textSecondary,
                modifier = Modifier.padding(top = 14.dp)
            )
            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.padding(top = 6.dp)
            ) {
                // 「默认」= 不指定，交给 MP（它会按站点绑定的下载器或全局默认来选）
                item(key = "__default_downloader__") {
                    SelectablePill(
                        text = "默认",
                        selected = downloader == null,
                        onClick = { downloader = null }
                    )
                }
                items(downloaders) { name ->
                    SelectablePill(
                        text = name,
                        selected = downloader == name,
                        onClick = { downloader = name }
                    )
                }
            }
        }

        Text(
            "保存路径",
            fontSize = 12.sp,
            color = colors.textSecondary,
            modifier = Modifier.padding(top = 14.dp)
        )
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(top = 6.dp)
        ) {
            item(key = "__auto__") {
                SelectablePill(
                    text = "自动",
                    selected = presetPath == null && !manualMode,
                    onClick = {
                        presetPath = null
                        manualMode = false
                    }
                )
            }
            items(savePaths) { path ->
                SelectablePill(
                    text = path.name,
                    selected = presetPath == path.savePath && !manualMode,
                    onClick = {
                        presetPath = path.savePath
                        manualMode = false
                    }
                )
            }
            item(key = "__manual__") {
                SelectablePill(
                    text = "手动输入",
                    selected = manualMode,
                    onClick = { manualMode = true }
                )
            }
        }

        val currentPreset = savePaths.firstOrNull { it.savePath == presetPath }
        if (currentPreset != null && !manualMode && currentPreset.name != currentPreset.savePath) {
            Spacer(Modifier.height(6.dp))
            Text(
                currentPreset.savePath,
                fontSize = 10.5.sp,
                color = colors.textSecondary,
                lineHeight = 15.sp
            )
        }

        if (manualMode) {
            Spacer(Modifier.height(8.dp))
            BasicField(
                value = manual,
                placeholder = "例如 rclone:/MP 或 /downloads/电影",
                onChange = { manual = it }
            )
        }

        // 失败原因就在弹窗里显示（toast 会飘走，用户回头根本查不到为什么没推上去）
        if (error != null) {
            Spacer(Modifier.height(12.dp))
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(Palette.red.copy(alpha = 0.10f))
                    .padding(horizontal = 11.dp, vertical = 9.dp)
            ) {
                Text(
                    "推送失败",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    color = Palette.red
                )
                Spacer(Modifier.height(3.dp))
                Text(error, fontSize = 11.sp, color = colors.textPrimary, lineHeight = 16.sp)
            }
        }

        Spacer(Modifier.height(10.dp))
        Text(
            when {
                manualMode && manual.isBlank() ->
                    "手动路径不能为空，或改回「自动」由 MoviePilot 选择目录。"
                else ->
                    "「自动」= 由 MoviePilot 按识别结果选择目录；路径由 MP 校验，写错会直接返回错误原因。"
            },
            fontSize = 10.sp,
            color = colors.textSecondary,
            lineHeight = 15.sp
        )
    }
}
