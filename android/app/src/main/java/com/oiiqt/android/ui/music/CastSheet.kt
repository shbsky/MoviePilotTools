package com.oiiqt.android.ui.music

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Cast
import androidx.compose.material.icons.rounded.CastConnected
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.Speaker
import androidx.compose.material.icons.rounded.VolumeDown
import androidx.compose.material.icons.rounded.VolumeUp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oiiqt.android.ui.components.OiiAlertDialog
import com.oiiqt.android.net.dlna.DlnaClient
import com.oiiqt.android.ui.theme.LocalOiiColors
import com.oiiqt.android.ui.theme.Palette
import com.oiiqt.android.vm.CastController

/**
 * 投送弹窗：搜索局域网里的 DLNA 设备、把歌推过去，并且能调音箱音量、切上一首/下一首。
 *
 * 一旦这里选定过设备，回到列表点歌就会直接投给音箱（不用再点这个按钮）。
 */
@Composable
fun CastDialog(
    state: CastController.CastState,
    currentTitle: String,
    onScan: () -> Unit,
    onCast: (DlnaClient.Device) -> Unit,
    onStop: () -> Unit,
    onDismiss: () -> Unit
) {
    val colors = LocalOiiColors.current

    LaunchedEffect(Unit) {
        if (!state.scanned && !state.scanning) onScan()
        if (state.casting) CastController.refreshVolume()
    }

    OiiAlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Cast, null, tint = Palette.blue, modifier = Modifier.size(19.dp))
                Spacer(Modifier.width(8.dp))
                Text("投送到音箱", fontSize = 17.sp)
            }
        },
        text = {
            Column(Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState())) {
                Text(
                    "音箱会自己从 Songloft 拉流播放。选定一次设备后，回列表点歌就自动投给它，整张列表会连播。",
                    fontSize = 11.sp,
                    color = colors.textSecondary,
                    lineHeight = 16.sp
                )

                if (state.casting) {
                    Spacer(Modifier.height(12.dp))
                    CastingPanel(state)
                }

                Spacer(Modifier.height(14.dp))

                when {
                    state.scanning -> Row(
                        Modifier.fillMaxWidth().padding(vertical = 18.dp),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            color = Palette.blue,
                            strokeWidth = 2.dp
                        )
                        Spacer(Modifier.width(10.dp))
                        Text("正在搜索局域网设备…", fontSize = 12.sp, color = colors.textSecondary)
                    }

                    state.devices.isEmpty() -> Text(
                        state.message ?: "没找到设备，点下面「重新搜索」再试一次。",
                        fontSize = 11.sp,
                        color = if (state.message != null) Palette.red else colors.textSecondary,
                        lineHeight = 16.sp
                    )

                    else -> Column {
                        Text(
                            "找到 ${state.devices.size} 台设备，点一台开始投送" +
                                if (currentTitle.isBlank()) "" else "「$currentTitle」",
                            fontSize = 11.sp,
                            color = colors.textSecondary
                        )
                        Spacer(Modifier.height(8.dp))
                        state.devices.forEach { device ->
                            DeviceRow(
                                device = device,
                                selected = state.active?.id == device.id,
                                busy = state.busy,
                                onClick = { onCast(device) }
                            )
                            Spacer(Modifier.height(6.dp))
                        }
                    }
                }

                if (state.message != null && state.devices.isNotEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        state.message.orEmpty(),
                        fontSize = 11.sp,
                        color = if (state.casting) Palette.green else Palette.red,
                        lineHeight = 16.sp
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onScan, enabled = !state.scanning) {
                Text(if (state.scanning) "搜索中…" else "重新搜索")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("关闭") }
        }
    )
}

/** 正在投送：设备 / 曲目 / 上一首-暂停-下一首 / 音箱音量 */
@Composable
private fun CastingPanel(state: CastController.CastState) {
    val colors = LocalOiiColors.current

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Palette.blue.copy(alpha = 0.09f))
            .padding(11.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Rounded.CastConnected, null,
                tint = Palette.blue, modifier = Modifier.size(17.dp)
            )
            Spacer(Modifier.width(9.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        state.active?.name ?: "设备",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    if (state.progressText.isNotBlank()) {
                        Spacer(Modifier.width(6.dp))
                        Text(state.progressText, fontSize = 10.sp, color = colors.textSecondary)
                    }
                }
                Text(
                    state.title.ifBlank { "正在投送" },
                    fontSize = 11.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Text(
                "停止",
                fontSize = 12.sp,
                color = Palette.red,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { CastController.stopCasting() }
                    .padding(horizontal = 8.dp, vertical = 4.dp)
            )
        }

        Spacer(Modifier.height(10.dp))
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                Icons.Rounded.SkipPrevious, "上一首",
                tint = if (state.hasPrevious) colors.textPrimary else colors.textSecondary,
                modifier = Modifier
                    .size(26.dp)
                    .clickable(enabled = state.hasPrevious) { CastController.previous() }
            )
            Spacer(Modifier.width(22.dp))
            Box(
                Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(Palette.blue)
                    .clickable { CastController.togglePause() },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    if (state.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                    "播放/暂停",
                    tint = Color.White,
                    modifier = Modifier.size(20.dp)
                )
            }
            Spacer(Modifier.width(22.dp))
            Icon(
                Icons.Rounded.SkipNext, "下一首",
                tint = if (state.hasNext) colors.textPrimary else colors.textSecondary,
                modifier = Modifier
                    .size(26.dp)
                    .clickable(enabled = state.hasNext) { CastController.next() }
            )
        }

        Spacer(Modifier.height(6.dp))
        if (state.volumeSupported && state.volume >= 0) {
            var volume by remember(state.volume) { mutableStateOf(state.volume.toFloat()) }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Rounded.VolumeDown, "音量",
                    tint = colors.textSecondary,
                    modifier = Modifier.size(17.dp)
                )
                Slider(
                    value = volume,
                    onValueChange = { volume = it },
                    onValueChangeFinished = { CastController.setVolume(volume.toInt()) },
                    valueRange = 0f..100f,
                    colors = SliderDefaults.colors(
                        thumbColor = Palette.blue,
                        activeTrackColor = Palette.blue,
                        inactiveTrackColor = colors.separator
                    ),
                    modifier = Modifier.weight(1f).padding(horizontal = 6.dp)
                )
                Text("${volume.toInt()}", fontSize = 11.sp, color = colors.textSecondary)
            }
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Rounded.VolumeUp, null,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(15.dp)
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    "这台设备不支持 App 调音量，用音箱自己的旋钮或遥控器",
                    fontSize = 10.sp,
                    color = colors.textSecondary
                )
            }
        }
    }
}

@Composable
private fun DeviceRow(
    device: DlnaClient.Device,
    selected: Boolean,
    busy: Boolean,
    onClick: () -> Unit
) {
    val colors = LocalOiiColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(11.dp))
            .background(if (selected) Palette.blue.copy(alpha = 0.12f) else colors.background)
            .clickable(enabled = !busy, onClick = onClick)
            .padding(horizontal = 11.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(30.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(Palette.blue.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                if (selected) Icons.Rounded.CastConnected else Icons.Rounded.Speaker,
                null,
                tint = Palette.blue,
                modifier = Modifier.size(16.dp)
            )
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                device.name,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (device.model.isNotBlank() && device.model != device.name) {
                Text(
                    device.model,
                    fontSize = 10.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
        Text(
            when {
                selected -> "投送中"
                busy -> "请稍候"
                else -> "投送"
            },
            fontSize = 12.sp,
            color = when {
                selected -> Palette.green
                busy -> colors.textSecondary
                else -> Palette.blue
            }
        )
    }
}
