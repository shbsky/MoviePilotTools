package com.oiiqt.android.ui.settings

import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.ShowChart
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.oiiqt.android.ui.components.ElevatedCard
import com.oiiqt.android.ui.components.OiiAlertDialog
import com.oiiqt.android.data.AppSettings
import com.oiiqt.android.data.MpServer
import com.oiiqt.android.data.ServerConfig
import com.oiiqt.android.net.ApkUpdater
import com.oiiqt.android.net.UpdateChecker
import com.oiiqt.android.ui.components.BasicField
import com.oiiqt.android.ui.components.BasicFieldMulti
import com.oiiqt.android.ui.components.DividerLine
import com.oiiqt.android.ui.components.FieldLabel
import com.oiiqt.android.ui.components.SelectablePill
import com.oiiqt.android.ui.components.ServerBadge
import com.oiiqt.android.ui.theme.LocalOiiColors
import com.oiiqt.android.ui.theme.Metrics
import com.oiiqt.android.ui.theme.Palette
import com.oiiqt.android.vm.UiState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.io.File
import java.util.Locale

@Composable
fun SettingsScreen(
    state: UiState,
    onOpenServers: () -> Unit,
    onOpenMpServers: () -> Unit,
    mpServers: List<MpServer>,
    mpActiveId: String?,
    onProbeMp: suspend (MpServer) -> Boolean,
    onSettingsChange: (AppSettings) -> Unit,
    onOpenTerms: () -> Unit
) {
    val colors = LocalOiiColors.current
    var dialog by remember { mutableStateOf<String?>(null) }
    val mpActiveName = mpServers.firstOrNull { it.id == mpActiveId }?.displayName

    // 状态卡的「已连接 x/y 台服务器」统计的是 MoviePilot，不是下载器。
    // -1 = 正在逐台探测，此时只显示总数，避免把「未知」说成「已连接」。
    var mpOnline by remember { mutableStateOf(-1) }
    val mpKeys = mpServers.joinToString(",") { it.id }
    LaunchedEffect(mpKeys) {
        if (mpServers.isEmpty()) {
            mpOnline = 0
            return@LaunchedEffect
        }
        mpOnline = -1
        var ok = 0
        for (server in mpServers) {
            if (onProbeMp(server)) ok++
        }
        mpOnline = ok
    }

    // 「关于」里的应用更新：只有用户点的时候才请求 GitHub，不做后台轮询
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var updateChecking by remember { mutableStateOf(false) }
    var updateResult by remember { mutableStateOf<UpdateChecker.Result?>(null) }
    var updateError by remember { mutableStateOf<String?>(null) }

    // 应用内更新：下载 → 请求安装权限 → 拉起系统安装器，全程不离开应用
    var installState by remember { mutableStateOf<InstallUi?>(null) }
    var downloadJob by remember { mutableStateOf<Job?>(null) }
    val mainHandler = remember { Handler(Looper.getMainLooper()) }

    fun startDownload(result: UpdateChecker.Result) {
        val apkUrl = result.apkUrl
        // 该 Release 没传 apk（只有源码包）时退回浏览器，避免点了没反应
        if (apkUrl.isNullOrBlank()) {
            openUrl(context, result.releaseUrl)
            return
        }
        updateResult = null
        downloadJob?.cancel()
        installState = InstallUi.Downloading(0L, result.apkSize)
        downloadJob = scope.launch {
            runCatching {
                ApkUpdater.cleanup(context)
                ApkUpdater.download(
                    context = context,
                    url = apkUrl,
                    fileName = result.apkName ?: "MoviePilotTools.apk"
                ) { progress ->
                    // 进度回调在网络线程，转到主线程再写 Compose 状态；
                    // 已取消/已结束的下载不再回写，避免弹窗被迟到回调重新拉起
                    mainHandler.post {
                        if (installState is InstallUi.Downloading) {
                            installState = InstallUi.Downloading(progress.downloaded, progress.total)
                        }
                    }
                }
            }.onSuccess { file ->
                installState = null
                when {
                    !ApkUpdater.canInstallPackages(context) ->
                        installState = InstallUi.NeedPermission(file)
                    !ApkUpdater.install(context, file) ->
                        installState = InstallUi.Failed("系统没有响应安装请求", result.releaseUrl)
                }
            }.onFailure { error ->
                if (error is CancellationException) return@onFailure
                installState = InstallUi.Failed(
                    error.message ?: "下载失败，请稍后重试",
                    result.releaseUrl
                )
            }
        }
    }

    // 用户从「允许安装未知应用」设置页返回后自动接着装，不用再点一次
    val activity = context as? ComponentActivity
    DisposableEffect(activity, installState) {
        val waiting = installState as? InstallUi.NeedPermission
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME && waiting != null &&
                ApkUpdater.canInstallPackages(context) && ApkUpdater.install(context, waiting.file)
            ) {
                installState = null
            }
        }
        if (waiting != null) activity?.lifecycle?.addObserver(observer)
        onDispose { activity?.lifecycle?.removeObserver(observer) }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(colors.background)
            .verticalScroll(rememberScrollState())
            // 只留左右：底部避让交给**末尾的 Spacer(88.dp)**。
            // 这里若再加 padding(bottom)，会和末尾 Spacer 叠加成 176dp ——
            // 之前「滚到底空白太多」就是这个原因；而且 padding 会裁剪滚动内容，
            // 内容就没法从悬浮底栏下面穿过去。
            .padding(start = Metrics.pagePadding, end = Metrics.pagePadding)
    ) {
        Spacer(Modifier.height(14.dp))
        Text(
            "设置",
            fontSize = 32.sp,
            fontWeight = FontWeight.Bold,
            color = colors.textPrimary
        )
        Spacer(Modifier.height(16.dp))

        // 状态卡也做成玻璃悬浮卡，和下面几个分组、以及仪表盘的卡片同一套语言
        ElevatedCard(modifier = Modifier.fillMaxWidth(), padding = 14.dp, corner = 18.dp) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { dialog = "about" },
                verticalAlignment = Alignment.CenterVertically
            ) {
            Box(
                Modifier
                    .size(34.dp)
                    .clip(RoundedCornerShape(9.dp))
                    .background(Palette.green.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Rounded.Dns, null, tint = Palette.green, modifier = Modifier.size(19.dp))
            }
            Spacer(Modifier.width(11.dp))
            Column(Modifier.weight(1f)) {
                Text("MoviePilotTools", fontSize = 15.sp, fontWeight = FontWeight.Medium, color = colors.textPrimary)
                Text(
                    when {
                        mpServers.isEmpty() -> "尚未配置服务器"
                        mpOnline < 0 -> "${mpServers.size} 台服务器"
                        else -> "已连接 $mpOnline/${mpServers.size} 台服务器"
                    },
                    fontSize = 12.sp,
                    color = colors.textSecondary
                )
            }
            // 只做状态展示：配置入口统一收在下面的「资源管理」里，避免和「下载器设置」重复
            Box(
                Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .background(Palette.green.copy(alpha = 0.12f))
                    .padding(horizontal = 8.dp, vertical = 3.dp)
            ) {
                Text("运行中", fontSize = 10.sp, color = Palette.green)
            }
                Spacer(Modifier.width(4.dp))
                Icon(Icons.Rounded.ChevronRight, null, tint = colors.textSecondary, modifier = Modifier.size(15.dp))
            }
        }

        Spacer(Modifier.height(20.dp))
        GroupLabel("资源管理")
        // 分组改成玻璃悬浮卡（外层承影 + 内层渐变，padding 0 因为行自带 14dp）
        ElevatedCard(modifier = Modifier.fillMaxWidth(), padding = 0.dp, corner = 18.dp) {
            SettingsRow(
                icon = Icons.Rounded.Dns,
                tint = Palette.purple,
                title = "下载器设置",
                value = "${state.servers.size} 台",
                onClick = onOpenServers
            )
            DividerLine(Modifier.padding(start = 48.dp))
            SettingsRow(
                icon = Icons.Rounded.Movie,
                tint = Palette.blue,
                title = "MoviePilot",
                value = when {
                    mpServers.isEmpty() -> "未配置"
                    else -> mpActiveName ?: "${mpServers.size} 个"
                },
                onClick = onOpenMpServers
            )
            DividerLine(Modifier.padding(start = 48.dp))
            SettingsRow(
                icon = Icons.Rounded.LibraryMusic,
                tint = Palette.pink,
                title = "音乐服务（Songloft）",
                value = state.settings.musicUrl.let {
                    if (it.isBlank()) "未接入 Songloft"
                    else com.oiiqt.android.data.summarizeEndpoints(it)
                },
                onClick = { dialog = "music" }
            )
            DividerLine(Modifier.padding(start = 48.dp))
            SettingsRow(
                icon = Icons.Rounded.Refresh,
                tint = Palette.blue,
                title = "下载器刷新频率",
                value = "${state.settings.refreshSeconds}秒",
                onClick = { dialog = "refresh" }
            )
        }

        Spacer(Modifier.height(20.dp))
        GroupLabel("应用设置")
        // 分组改成玻璃悬浮卡（外层承影 + 内层渐变，padding 0 因为行自带 14dp）
        ElevatedCard(modifier = Modifier.fillMaxWidth(), padding = 0.dp, corner = 18.dp) {
            SettingsRow(
                icon = Icons.Rounded.Settings,
                tint = Palette.indigo,
                title = "外观主题",
                value = when (state.settings.theme) {
                    "light" -> "浅色"
                    "dark" -> "深色"
                    else -> "跟随系统"
                },
                onClick = { dialog = "theme" }
            )
            DividerLine(Modifier.padding(start = 48.dp))
            SettingsRow(
                icon = Icons.Rounded.Settings,
                tint = Palette.blue,
                title = "字体大小",
                value = "${(state.settings.fontScale * 100).toInt()}%",
                onClick = { dialog = "font" }
            )
        }

        Spacer(Modifier.height(20.dp))
        GroupLabel("仪表盘定制")
        // 分组改成玻璃悬浮卡（外层承影 + 内层渐变，padding 0 因为行自带 14dp）
        ElevatedCard(modifier = Modifier.fillMaxWidth(), padding = 0.dp, corner = 18.dp) {
            ToggleRow(
                icon = Icons.Rounded.GridView,
                tint = Palette.blue,
                title = "流量监控",
                checked = state.settings.showModuleTraffic,
                onChange = { onSettingsChange(state.settings.copy(showModuleTraffic = it)) }
            )
            DividerLine(Modifier.padding(start = 48.dp))
            ToggleRow(
                icon = Icons.Rounded.Movie,
                tint = Palette.purple,
                title = "媒体库",
                checked = state.settings.showModuleMedia,
                onChange = { onSettingsChange(state.settings.copy(showModuleMedia = it)) }
            )
            DividerLine(Modifier.padding(start = 48.dp))
            ToggleRow(
                icon = Icons.Rounded.GridView,
                tint = Palette.orange,
                title = "数据聚合",
                checked = state.settings.showModuleAssets,
                onChange = { onSettingsChange(state.settings.copy(showModuleAssets = it)) }
            )
            DividerLine(Modifier.padding(start = 48.dp))
            ToggleRow(
                icon = Icons.Rounded.GridView,
                tint = Palette.green,
                title = "服务器状态",
                checked = state.settings.showModuleServers,
                onChange = { onSettingsChange(state.settings.copy(showModuleServers = it)) }
            )
        }

        Spacer(Modifier.height(20.dp))
        GroupLabel("关于")
        // 分组改成玻璃悬浮卡（外层承影 + 内层渐变，padding 0 因为行自带 14dp）
        ElevatedCard(modifier = Modifier.fillMaxWidth(), padding = 0.dp, corner = 18.dp) {
            Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("版本", fontSize = 15.sp, color = colors.textPrimary, modifier = Modifier.weight(1f))
                Text(
                    "${com.oiiqt.android.BuildConfig.VERSION_NAME}（${com.oiiqt.android.BuildConfig.VERSION_CODE}）",
                    fontSize = 13.sp,
                    color = colors.textSecondary
                )
            }
            DividerLine(Modifier.padding(start = 14.dp))
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable(enabled = !updateChecking) {
                        scope.launch {
                            downloadJob?.cancel()
                            downloadJob = null
                            installState = null
                            updateChecking = true
                            updateError = null
                            updateResult = null
                            runCatching {
                                UpdateChecker.check(com.oiiqt.android.BuildConfig.VERSION_NAME)
                            }.onSuccess { updateResult = it }
                                .onFailure { updateError = it.message ?: "检查更新失败" }
                            updateChecking = false
                        }
                    }
                    .padding(14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("应用更新", fontSize = 15.sp, color = colors.textPrimary, modifier = Modifier.weight(1f))
                Text(
                    if (updateChecking) "检查中…" else "v${com.oiiqt.android.BuildConfig.VERSION_NAME}",
                    fontSize = 13.sp,
                    color = colors.textSecondary
                )
                Spacer(Modifier.width(4.dp))
                Icon(
                    Icons.Rounded.ChevronRight,
                    null,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(15.dp)
                )
            }
            DividerLine(Modifier.padding(start = 14.dp))
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { openUrl(context, UpdateChecker.PROJECT_URL) }
                    .padding(14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("项目地址", fontSize = 15.sp, color = colors.textPrimary, modifier = Modifier.weight(1f))
                Text("GitHub", fontSize = 13.sp, color = colors.textSecondary)
                Spacer(Modifier.width(4.dp))
                Icon(
                    Icons.Rounded.ChevronRight,
                    null,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(15.dp)
                )
            }
            DividerLine(Modifier.padding(start = 14.dp))
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onOpenTerms)
                    .padding(14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("用户协议", fontSize = 15.sp, color = colors.textPrimary, modifier = Modifier.weight(1f))
                Text("免责声明", fontSize = 13.sp, color = colors.textSecondary)
                Spacer(Modifier.width(4.dp))
                Icon(
                    Icons.Rounded.ChevronRight,
                    null,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(15.dp)
                )
            }
        }

        // 底部留白对齐仪表盘（LazyColumn contentPadding.bottom = 88dp）：
        // 原来 120dp，滚到底时「用户协议」和胶囊之间空出一大块，像列表断了。
        Spacer(Modifier.height(88.dp))
    }

    when (dialog) {
        "about" -> AboutDialog(
            serverCount = state.servers.size,
            onlineCount = state.onlineCount,
            mpCount = mpServers.size,
            onDismiss = { dialog = null }
        )
        "refresh" -> ChoiceDialog(
            title = "下载器刷新频率",
            options = listOf(2, 3, 5, 10, 30, 60),
            current = state.settings.refreshSeconds,
            labelOf = { "$it 秒" },
            onDismiss = { dialog = null },
            onPick = { onSettingsChange(state.settings.copy(refreshSeconds = it)); dialog = null }
        )
        "theme" -> ChoiceDialog(
            title = "外观主题",
            options = listOf("system", "light", "dark"),
            current = state.settings.theme,
            labelOf = { when (it) { "light" -> "浅色"; "dark" -> "深色"; else -> "跟随系统" } },
            onDismiss = { dialog = null },
            onPick = { onSettingsChange(state.settings.copy(theme = it)); dialog = null }
        )
        "font" -> ChoiceDialog(
            title = "字体大小",
            options = listOf(0.9f, 1.0f, 1.1f, 1.2f),
            current = state.settings.fontScale,
            labelOf = { "${(it * 100).toInt()}%" },
            onDismiss = { dialog = null },
            onPick = { onSettingsChange(state.settings.copy(fontScale = it)); dialog = null }
        )
        "music" -> MusicServerDialog(
            url = state.settings.musicUrl,
            user = state.settings.musicUser,
            pass = state.settings.musicPass,
            onDismiss = { dialog = null },
            onSave = { url, user, pass ->
                onSettingsChange(
                    state.settings.copy(musicUrl = url, musicUser = user, musicPass = pass)
                )
                dialog = null
            }
        )
    }

    // 应用更新结果：有新版本给「立即更新」，走应用内下载 + 安装
    updateResult?.let { result ->
        val latest = result.latestVersion.ifBlank { "未知" }
        val current = com.oiiqt.android.BuildConfig.VERSION_NAME
        OiiAlertDialog(
            onDismissRequest = { updateResult = null },
            title = { Text(if (result.hasUpdate) "发现新版本" else "已是最新版本", fontSize = 17.sp) },
            text = {
                Text(
                    if (result.hasUpdate) "最新版本 v$latest，当前安装 v$current。\n\n点「立即更新」会自动下载并安装，覆盖升级后数据不会丢。"
                    else "当前 v$current 已经是最新版本。",
                    fontSize = 13.sp,
                    color = colors.textPrimary,
                    lineHeight = 20.sp
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        if (result.hasUpdate) startDownload(result) else updateResult = null
                    }
                ) { Text(if (result.hasUpdate) "立即更新" else "好的") }
            },
            dismissButton = if (result.hasUpdate) {
                { TextButton(onClick = { updateResult = null }) { Text("稍后") } }
            } else null
        )
    }

    // 下载中：只有取消，进度实时刷新
    (installState as? InstallUi.Downloading)?.let { downloading ->
        val fraction = downloading.fraction
        OiiAlertDialog(
            onDismissRequest = {
                downloadJob?.cancel()
                downloadJob = null
                installState = null
            },
            title = { Text("正在下载更新", fontSize = 17.sp) },
            text = {
                Column {
                    Text(
                        if (fraction != null) {
                            "${(fraction * 100).toInt()}%　${formatSize(downloading.downloaded)} / ${formatSize(downloading.total)}"
                        } else {
                            "已下载 ${formatSize(downloading.downloaded)}"
                        },
                        fontSize = 13.sp,
                        color = colors.textPrimary
                    )
                    Spacer(Modifier.height(10.dp))
                    if (fraction != null) {
                        LinearProgressIndicator(
                            progress = { fraction },
                            modifier = Modifier.fillMaxWidth(),
                            color = colors.accent,
                            trackColor = colors.separator
                        )
                    } else {
                        LinearProgressIndicator(
                            modifier = Modifier.fillMaxWidth(),
                            color = colors.accent,
                            trackColor = colors.separator
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        downloadJob?.cancel()
                        downloadJob = null
                        installState = null
                    }
                ) { Text("取消") }
            }
        )
    }

    // 首次装未知来源应用：引导去开开关，回来自动继续
    (installState as? InstallUi.NeedPermission)?.let {
        OiiAlertDialog(
            onDismissRequest = { installState = null },
            title = { Text("需要允许安装应用", fontSize = 17.sp) },
            text = {
                Text(
                    "系统要求先允许本应用安装其他来源的安装包。\n\n点「去设置」打开开关，返回后会自动继续安装。",
                    fontSize = 13.sp,
                    color = colors.textPrimary,
                    lineHeight = 20.sp
                )
            },
            confirmButton = {
                TextButton(onClick = { ApkUpdater.openInstallPermission(context) }) { Text("去设置") }
            },
            dismissButton = {
                TextButton(onClick = { installState = null }) { Text("取消") }
            }
        )
    }

    (installState as? InstallUi.Failed)?.let { failed ->
        OiiAlertDialog(
            onDismissRequest = { installState = null },
            title = { Text("更新失败", fontSize = 17.sp) },
            text = {
                Text(
                    "${failed.message}\n\n也可以到 GitHub Releases 页面手动下载安装包。",
                    fontSize = 13.sp,
                    color = colors.textPrimary,
                    lineHeight = 20.sp
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        installState = null
                        openUrl(context, failed.releaseUrl)
                    }
                ) { Text("去网页下载") }
            },
            dismissButton = {
                TextButton(onClick = { installState = null }) { Text("关闭") }
            }
        )
    }

    updateError?.let { message ->
        OiiAlertDialog(
            onDismissRequest = { updateError = null },
            title = { Text("检查更新失败", fontSize = 17.sp) },
            text = { Text(message, fontSize = 13.sp, color = colors.textPrimary) },
            confirmButton = { TextButton(onClick = { updateError = null }) { Text("好的") } }
        )
    }
}

/** 用系统浏览器打开链接；设备上没有浏览器时静默失败，不阻塞 UI */
private fun openUrl(context: android.content.Context, url: String) {
    runCatching {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }
}

/** 应用内更新的三个阶段：下载中 / 等安装权限 / 失败兜底 */
private sealed interface InstallUi {
    data class Downloading(val downloaded: Long, val total: Long) : InstallUi {
        /** 总长度未知时给 null，UI 走不确定进度条 */
        val fraction: Float?
            get() = if (total > 0) (downloaded.toFloat() / total).coerceIn(0f, 1f) else null
    }

    data class NeedPermission(val file: File) : InstallUi
    data class Failed(val message: String, val releaseUrl: String) : InstallUi
}

private fun formatSize(bytes: Long): String {
    if (bytes <= 0) return "0 MB"
    val mb = bytes / 1024.0 / 1024.0
    return if (mb >= 1) String.format(Locale.US, "%.1f MB", mb) else "${(bytes + 1023) / 1024} KB"
}

@Composable
private fun GroupLabel(text: String) {
    val colors = LocalOiiColors.current
    Text(
        text,
        fontSize = 12.sp,
        color = colors.textSecondary,
        modifier = Modifier.padding(start = 4.dp, bottom = 8.dp)
    )
}

@Composable
private fun SettingsRow(
    icon: ImageVector,
    tint: Color,
    title: String,
    value: String,
    onClick: () -> Unit
) {
    val colors = LocalOiiColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(24.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(tint.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(15.dp))
        }
        Spacer(Modifier.width(10.dp))
        Text(title, fontSize = 15.sp, color = colors.textPrimary, modifier = Modifier.weight(1f))
        Text(value, fontSize = 13.sp, color = colors.textSecondary)
        Spacer(Modifier.width(4.dp))
        Icon(Icons.Rounded.ChevronRight, null, tint = colors.textSecondary, modifier = Modifier.size(15.dp))
    }
}

@Composable
private fun ToggleRow(
    icon: ImageVector,
    tint: Color,
    title: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit
) {
    val colors = LocalOiiColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(24.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(tint.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(15.dp))
        }
        Spacer(Modifier.width(10.dp))
        Text(title, fontSize = 15.sp, color = colors.textPrimary, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange, modifier = Modifier.height(26.dp))
    }
}

@Composable
private fun <T> ChoiceDialog(
    title: String,
    options: List<T>,
    current: T,
    labelOf: (T) -> String,
    onDismiss: () -> Unit,
    onPick: (T) -> Unit
) {
    val colors = LocalOiiColors.current
    OiiAlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, fontSize = 17.sp) },
        text = {
            Column {
                options.forEach { option ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(9.dp))
                            .clickable { onPick(option) }
                            .padding(vertical = 11.dp, horizontal = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            labelOf(option),
                            fontSize = 15.sp,
                            color = if (option == current) colors.accent else colors.textPrimary,
                            modifier = Modifier.weight(1f)
                        )
                        if (option == current) {
                            Box(
                                Modifier.size(7.dp).clip(CircleShape).background(colors.accent)
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("关闭") }
        }
    )
}

/** 逐个探测地址，返回「地址 → 是否连得上」；只探 TCP/HTTP 可达，不校验账号 */
private suspend fun probeAddresses(text: String, path: String): List<Pair<String, Boolean>> =
    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
        com.oiiqt.android.data.parseEndpoints(text).map { endpoint ->
            val ok = runCatching {
                com.oiiqt.android.net.Net.probeClient
                    .newCall(okhttp3.Request.Builder().url(endpoint.url(path)).build())
                    .execute().use { it.code in 200..499 }
            }.getOrDefault(false)
            endpoint.display to ok
        }
    }

@Composable
private fun AddressChecks(results: List<Pair<String, Boolean>>) {
    if (results.isEmpty()) return
    val colors = LocalOiiColors.current
    Column(Modifier.padding(top = 8.dp)) {
        results.forEach { (display, ok) ->
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 1.dp)) {
                Text(
                    if (ok) "✓" else "✕",
                    fontSize = 11.sp,
                    color = if (ok) Palette.green else Palette.red
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    display.substringAfter("://"),
                    fontSize = 11.sp,
                    color = if (ok) colors.textPrimary else colors.textSecondary
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    if (ok) "可用" else "连不上",
                    fontSize = 10.sp,
                    color = if (ok) Palette.green else colors.textSecondary
                )
            }
        }
    }
}

/** Songloft 音乐服务接入配置（音乐标签页的数据源） */
@Composable
private fun MusicServerDialog(
    url: String,
    user: String,
    pass: String,
    onDismiss: () -> Unit,
    onSave: (String, String, String) -> Unit
) {
    var urlDraft by remember { mutableStateOf(url) }
    var userDraft by remember { mutableStateOf(user) }
    var passDraft by remember { mutableStateOf(pass) }
    var testing by remember { mutableStateOf(false) }
    var checking by remember { mutableStateOf(false) }
    var testMessage by remember { mutableStateOf<String?>(null) }
    var testOk by remember { mutableStateOf(false) }
    var checks by remember { mutableStateOf<List<Pair<String, Boolean>>>(emptyList()) }
    val scope = rememberCoroutineScope()
    val colors = LocalOiiColors.current

    OiiAlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("音乐服务 (Songloft)", fontSize = 17.sp) },
        text = {
            Column(
                Modifier
                    .verticalScroll(rememberScrollState())
                    .imePadding()
            ) {
                Text(
                    "填 Songloft 的地址和登录账号，音乐标签页就能浏览歌曲、歌单并在手机上播放。" +
                        "地址可以填多行（内网 IP + 公网域名），自动挑能通的。",
                    fontSize = 11.sp,
                    color = colors.textSecondary,
                    lineHeight = 16.sp
                )
                Spacer(Modifier.height(12.dp))
                FieldLabel("服务地址（一行一个，可填多条）")
                Spacer(Modifier.height(6.dp))
                BasicFieldMulti(
                    value = urlDraft,
                    placeholder = "192.168.1.10:58091\nmusic.example.com",
                    onChange = { urlDraft = it }
                )
                // 让「可以填多条」这件事看得见：实时告诉用户解析到几个地址
                val parsed = com.oiiqt.android.data.parseEndpoints(urlDraft)
                Spacer(Modifier.height(5.dp))
                Text(
                    if (parsed.isEmpty()) "第一行填内网地址，第二行填公网域名（在外面自动走域名）"
                    else "已填 ${parsed.size} 个地址，连之前会自动选能通的那个",
                    fontSize = 10.sp,
                    color = if (parsed.size > 1) Palette.green else colors.textSecondary,
                    lineHeight = 15.sp
                )
                Spacer(Modifier.height(12.dp))
                FieldLabel("登录账号")
                Spacer(Modifier.height(6.dp))
                BasicField(userDraft, "账号") { userDraft = it.trim() }
                Spacer(Modifier.height(12.dp))
                FieldLabel("登录密码")
                Spacer(Modifier.height(6.dp))
                BasicField(passDraft, "密码", secret = true) { passDraft = it }
                Spacer(Modifier.height(10.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        if (checking) "检测中…" else "检测地址",
                        fontSize = 12.sp,
                        color = Palette.blue,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .clickable(enabled = !checking && urlDraft.isNotBlank()) {
                                checking = true
                                scope.launch {
                                    checks = probeAddresses(urlDraft, "/api/v1/songs?limit=1")
                                    checking = false
                                }
                            }
                            .padding(horizontal = 8.dp, vertical = 5.dp)
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "地址不写 http:// 也行，默认按 http 走",
                        fontSize = 10.sp,
                        color = colors.textSecondary
                    )
                }
                AddressChecks(checks)
                if (testMessage != null) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        testMessage.orEmpty(),
                        fontSize = 11.sp,
                        color = if (testOk) Palette.green else Palette.red,
                        lineHeight = 16.sp
                    )
                }
            }
        },
        confirmButton = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(
                    enabled = !testing && urlDraft.isNotBlank() && userDraft.isNotBlank(),
                    onClick = {
                        testing = true
                        testMessage = "正在登录…"
                        testOk = false
                        scope.launch {
                            runCatching {
                                com.oiiqt.android.net.SongloftClient(urlDraft, userDraft, passDraft).test()
                            }.onSuccess {
                                testOk = true
                                testMessage = it
                            }.onFailure {
                                testOk = false
                                testMessage = it.message ?: "连接失败"
                            }
                            testing = false
                        }
                    }
                ) {
                    Text(if (testing) "测试中…" else "测试")
                }
                TextButton(onClick = { onSave(urlDraft.trim(), userDraft, passDraft) }) { Text("保存") }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
}

/**
 * 顶部状态卡的详情弹窗。
 *
 * 原版 iOS 这里是「Pro 已激活」的内购状态卡，安卓版是免费开源的，
 * 换成对实际使用有用的运行概况：版本、连接数、支持的服务。
 */
@Composable
private fun AboutDialog(
    serverCount: Int,
    onlineCount: Int,
    mpCount: Int,
    onDismiss: () -> Unit
) {
    val colors = LocalOiiColors.current
    OiiAlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("MoviePilotTools", fontSize = 17.sp) },
        text = {
            Column {
                Text(
                    "版本 ${com.oiiqt.android.BuildConfig.VERSION_NAME}（${com.oiiqt.android.BuildConfig.VERSION_CODE}）",
                    fontSize = 12.sp,
                    color = colors.textPrimary
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    "Kotlin · Jetpack Compose · Media3",
                    fontSize = 11.sp,
                    color = colors.textSecondary
                )
                Spacer(Modifier.height(14.dp))
                AboutRow("下载器", "$onlineCount/$serverCount 台在线")
                AboutRow("MoviePilot", if (mpCount == 0) "未配置" else "$mpCount 个服务器")
                AboutRow("流量统计", "取自下载器累计计数器")
                AboutRow("音乐", "Songloft · 支持 DLNA 投送")
                Spacer(Modifier.height(12.dp))
                Text(
                    "免费开源，没有任何内购或 Pro 限制。数据全部留在本机，只有连你的下载器和服务器时才走网络。",
                    fontSize = 10.sp,
                    color = colors.textSecondary,
                    lineHeight = 15.sp
                )
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("关闭") } }
    )
}

@Composable
private fun AboutRow(label: String, value: String) {
    val colors = LocalOiiColors.current
    Row(Modifier.fillMaxWidth().padding(vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontSize = 12.sp, color = colors.textSecondary, modifier = Modifier.weight(1f))
        Text(value, fontSize = 12.sp, color = colors.textPrimary)
    }
}
