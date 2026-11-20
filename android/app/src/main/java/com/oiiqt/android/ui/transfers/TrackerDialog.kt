package com.oiiqt.android.ui.transfers

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Public
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oiiqt.android.data.TorrentTask
import com.oiiqt.android.data.TrackerEntry
import com.oiiqt.android.ui.components.OiiDialog
import com.oiiqt.android.ui.theme.LocalOiiColors
import com.oiiqt.android.ui.theme.Palette
import com.oiiqt.android.vm.TrackerState

/**
 * 种子操作弹窗的第二级：Tracker 列表。
 *
 * 结构对齐 MoviePilot「编辑Tracker」那张卡：一条一条列出来，点某条进编辑（URL 可改），
 * 底部可以「添加 Tracker」。qB 的 DHT / PEX / LSD 伪 Tracker 也列出来，但标灰、不可点，
 * 免得用户改了发现没效果。
 */
@Composable
fun TrackerListDialog(
    task: TorrentTask,
    state: TrackerState,
    onReload: () -> Unit,
    onEdit: (TrackerEntry, String) -> Unit,
    onAdd: (String) -> Unit,
    onRemove: (TrackerEntry) -> Unit,
    onClose: () -> Unit
) {
    val colors = LocalOiiColors.current
    // 编哪一条；adding = 新增态。两者都不为 null/false 时本弹窗整体让位给编辑弹窗
    var editing by remember(task.id) { mutableStateOf<TrackerEntry?>(null) }
    var adding by remember(task.id) { mutableStateOf(false) }
    var input by remember(task.id) { mutableStateOf("") }

    if (editing != null || adding) {
        val entry = editing
        TrackerEditDialog(
            title = if (adding) "添加 Tracker" else "编辑 Tracker",
            subtitle = task.name,
            value = input,
            busy = state.busy,
            onValueChange = { input = it },
            canDelete = entry != null && !entry.special && !state.busy,
            onDelete = {
                entry?.let(onRemove)
                editing = null
                input = ""
            },
            onCancel = {
                editing = null
                adding = false
                input = ""
            },
            onSave = {
                if (entry != null) onEdit(entry, input) else onAdd(input)
                editing = null
                adding = false
                input = ""
            }
        )
        return
    }

    val realCount = state.items.count { !it.special }

    OiiDialog(
        title = "Tracker 列表",
        subtitle = task.name,
        confirmText = "关闭",
        cancelText = null,
        maxHeight = 400.dp,
        onDismiss = onClose,
        onConfirm = onClose
    ) {
        // 概览行：条数 + 刷新
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (state.loading) "正在读取…" else "共 $realCount 条 Tracker",
                fontSize = 11.sp,
                color = colors.textSecondary,
                modifier = Modifier.weight(1f)
            )
            Text(
                "刷新",
                fontSize = 12.sp,
                color = colors.accent,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable(enabled = !state.busy) { onReload() }
                    .padding(horizontal = 6.dp, vertical = 2.dp)
            )
        }

        if (state.error != null) {
            Spacer(Modifier.height(8.dp))
            Text(state.error, fontSize = 11.5.sp, color = Palette.red, lineHeight = 16.sp)
        }

        if (state.items.isEmpty() && !state.loading) {
            Spacer(Modifier.height(12.dp))
            Text(
                "这个种子还没有 Tracker。可以点下面「添加 Tracker」手动补一条。",
                fontSize = 12.sp,
                color = colors.textSecondary,
                lineHeight = 17.sp
            )
        }

        if (state.items.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(colors.background)
            ) {
                state.items.forEachIndexed { index, entry ->
                    if (index > 0) {
                        Box(
                            Modifier
                                .padding(start = 34.dp)
                                .fillMaxWidth()
                                .height(0.6.dp)
                                .background(colors.separator)
                        )
                    }
                    TrackerRow(
                        entry = entry,
                        enabled = !entry.special && !state.busy,
                        onClick = {
                            input = entry.url
                            editing = entry
                        }
                    )
                }
            }
        }

        Spacer(Modifier.height(10.dp))
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(colors.background)
                .clickable(enabled = !state.busy) {
                    input = ""
                    adding = true
                }
                .padding(horizontal = 12.dp, vertical = 13.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(Icons.Rounded.Add, null, tint = Palette.blue, modifier = Modifier.size(19.dp))
            Spacer(Modifier.width(13.dp))
            Text("添加 Tracker", fontSize = 14.sp, color = colors.textPrimary)
        }
    }
}

@Composable
private fun TrackerRow(entry: TrackerEntry, enabled: Boolean, onClick: () -> Unit) {
    val colors = LocalOiiColors.current
    val statusColor = when (entry.status) {
        TrackerEntry.Status.WORKING -> Palette.green
        TrackerEntry.Status.UPDATING -> Palette.blue
        TrackerEntry.Status.NOT_WORKING -> Palette.red
        TrackerEntry.Status.DISABLED -> Palette.gray
        else -> Palette.orange
    }

    Row(
        Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(if (entry.special) colors.textSecondary.copy(alpha = 0.4f) else statusColor)
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    entry.host,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = if (entry.special) colors.textSecondary else colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false)
                )
                if (!entry.special) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        entry.statusText,
                        fontSize = 10.sp,
                        color = statusColor
                    )
                }
            }
            Spacer(Modifier.height(2.dp))
            Text(
                entry.url,
                fontSize = 10.sp,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (!entry.special && (entry.seeds > 0 || entry.leeches > 0 || entry.peers > 0)) {
                Spacer(Modifier.height(2.dp))
                Text(
                    "种子 ${entry.seeds} · 用户 ${entry.leeches}" +
                        if (entry.peers > 0) " · 已连 ${entry.peers}" else "",
                    fontSize = 10.sp,
                    color = colors.textSecondary
                )
            }
            if (!entry.special && entry.message.isNotEmpty()) {
                Spacer(Modifier.height(2.dp))
                Text(
                    entry.message,
                    fontSize = 10.sp,
                    color = Palette.red.copy(alpha = 0.85f),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
        if (enabled) {
            Spacer(Modifier.width(8.dp))
            Icon(
                Icons.Rounded.ChevronRight,
                null,
                tint = colors.textSecondary,
                modifier = Modifier.size(16.dp)
            )
        }
    }
}

/** 编辑 / 新增一条 Tracker：URL 是多行的，竖着放才看得全 */
@Composable
private fun TrackerEditDialog(
    title: String,
    subtitle: String,
    value: String,
    busy: Boolean,
    canDelete: Boolean,
    onValueChange: (String) -> Unit,
    onDelete: () -> Unit,
    onCancel: () -> Unit,
    onSave: () -> Unit
) {
    val colors = LocalOiiColors.current
    val shape = RoundedCornerShape(10.dp)

    OiiDialog(
        title = title,
        subtitle = subtitle,
        confirmText = "保存",
        // 编辑态给「取消」：改了一半想退出去，点遮罩不算明显
        cancelText = "取消",
        confirmEnabled = value.trim().isNotEmpty() && !busy,
        busy = busy,
        maxHeight = 300.dp,
        onDismiss = onCancel,
        onConfirm = onSave
    ) {
        Text("Tracker URL", fontSize = 12.sp, color = colors.accent)
        Spacer(Modifier.height(7.dp))
        Box(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 88.dp)
                .clip(shape)
                .background(colors.background)
                .border(1.dp, colors.separator, shape)
                .padding(horizontal = 12.dp, vertical = 10.dp)
        ) {
            if (value.isEmpty()) {
                Text(
                    "https://…/announce.php?passkey=…",
                    fontSize = 13.sp,
                    color = colors.textSecondary
                )
            }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                textStyle = TextStyle(fontSize = 13.sp, color = colors.textPrimary, lineHeight = 19.sp),
                cursorBrush = SolidColor(colors.accent),
                modifier = Modifier.fillMaxWidth()
            )
        }
        Spacer(Modifier.height(6.dp))
        Text(
            "改完保存会立刻向新地址汇报；地址写错这条 Tracker 就会变成「不工作」。",
            fontSize = 10.5.sp,
            color = colors.textSecondary,
            lineHeight = 15.sp
        )

        if (canDelete) {
            Spacer(Modifier.height(14.dp))
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(shape)
                    .background(colors.background)
                    .clickable(onClick = onDelete)
                    .padding(horizontal = 12.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Start
            ) {
                Icon(Icons.Rounded.Delete, null, tint = Palette.red, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(10.dp))
                Text("删除这条 Tracker", fontSize = 13.sp, color = Palette.red)
            }
        }
    }
}
