package com.moviepilottools.mptools.ui.transfers

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.ArrowCircleDown
import androidx.compose.material.icons.rounded.ArrowCircleUp
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.AutoMode
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Campaign
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Checklist
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.CloudDownload
import androidx.compose.material.icons.rounded.CloudUpload
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.DoneAll
import androidx.compose.material.icons.rounded.DriveFileMove
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.FactCheck
import androidx.compose.material.icons.rounded.FilterList
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Groups
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Menu
import androidx.compose.material.icons.rounded.PauseCircleOutline
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.SwapHoriz
import androidx.compose.material.icons.rounded.SwapVert
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineBreak
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.moviepilottools.mptools.data.ServerConfig
import com.moviepilottools.mptools.data.ServerSnapshot
import com.moviepilottools.mptools.data.ServerType
import com.moviepilottools.mptools.data.TorrentStatus
import com.moviepilottools.mptools.data.TorrentTask
import com.moviepilottools.mptools.data.formatBytes
import com.moviepilottools.mptools.data.formatPercent
import com.moviepilottools.mptools.data.formatRatio
import com.moviepilottools.mptools.data.formatStorageSize
import com.moviepilottools.mptools.data.humanEta
import com.moviepilottools.mptools.ui.components.EmptyHint
import com.moviepilottools.mptools.ui.components.OiiDialog
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.Metrics
import com.moviepilottools.mptools.ui.theme.Palette
import com.moviepilottools.mptools.vm.BatchAction
import com.moviepilottools.mptools.vm.StatusFilter
import com.moviepilottools.mptools.vm.TaskEditMode
import com.moviepilottools.mptools.vm.TorrentAction
import com.moviepilottools.mptools.vm.UiState
import com.moviepilottools.mptools.vm.matches
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 排序维度：和参考客户端底部第二个按钮弹出的面板一致 */
enum class SortMode(val label: String) {
    ADDED("添加时间"),
    NAME("种子名称"),
    SIZE("文件大小"),
    PROGRESS("完成进度"),
    STATUS("种子状态"),
    DL_SPEED("下载速度"),
    UL_SPEED("上传速度"),
    RATIO("分享比率")
}

/**
 * 下载器任务页（点仪表盘的下载器卡片进来）。
 *
 * 布局照参考客户端：左边汉堡开侧边栏（下载器信息 + 状态筛选 + 配置 + 返回），
 * 顶栏三个按钮分别是批量操作、备用限速、退出；右下角 + 新增下载、再下面是排序。
 *
 * 服务器是**固定**的（[serverId]）：不改全局 activeServerId，看这台机器不会影响别处。
 */
@Composable
fun TransfersScreen(
    state: UiState,
    serverId: String,
    onBack: () -> Unit,
    /** 点任务：交给主框架弹出「种子操作」弹窗（弹窗叠在页面上，不再换页） */
    onOpenActions: (TorrentTask) -> Unit,
    onRefresh: () -> Unit,
    onOpenAdd: () -> Unit,
    onOpenConfig: () -> Unit,
    onBatch: (BatchAction, List<String>, String) -> Unit,
    onToggleAltSpeed: () -> Unit,
    /** 顶栏切换按钮选了另一台下载器 */
    onSwitchServer: (String) -> Unit
) {
    val colors = LocalMptColors.current
    var statusFilter by remember { mutableStateOf(StatusFilter.ALL) }
    var sortMode by remember { mutableStateOf(SortMode.ADDED) }
    var sortAsc by remember { mutableStateOf(false) }
    var drawerOpen by remember { mutableStateOf(false) }
    var batchSheet by remember { mutableStateOf(false) }
    var sortSheet by remember { mutableStateOf(false) }
    var locationDialog by remember { mutableStateOf(false) }
    var deleteDialog by remember { mutableStateOf(false) }

    // 这些弹窗由本页自己管理（不换页），返回键要先关最上面那一个
    BackHandler(enabled = batchSheet || sortSheet || locationDialog || deleteDialog) {
        when {
            deleteDialog -> deleteDialog = false
            locationDialog -> locationDialog = false
            sortSheet -> sortSheet = false
            batchSheet -> batchSheet = false
        }
    }

    val server = state.servers.firstOrNull { it.id == serverId }
    val snapshot = state.snapshots[serverId]
    val source = remember(state.tasks, serverId) {
        state.tasks.filter { it.serverId == serverId }
    }
    val allHashes = remember(source) { source.map { it.hash } }

    val filtered = remember(source, statusFilter, sortMode, sortAsc) {
        val comparator = when (sortMode) {
            SortMode.ADDED -> compareBy<TorrentTask> { it.addedAt }
            SortMode.NAME -> compareBy { it.name.lowercase(Locale.getDefault()) }
            SortMode.SIZE -> compareBy { it.size }
            SortMode.PROGRESS -> compareBy { it.progress }
            SortMode.STATUS -> compareBy { it.status.ordinal }
            SortMode.DL_SPEED -> compareBy { it.downloadSpeed }
            SortMode.UL_SPEED -> compareBy { it.uploadSpeed }
            SortMode.RATIO -> compareBy { it.ratio }
        }
        source
            .filter { it.matches(statusFilter) }
            .sortedWith(if (sortAsc) comparator else comparator.reversed())
    }

    fun runBatch(action: BatchAction, hashes: List<String> = allHashes) {
        onBatch(action, hashes, "")
        batchSheet = false
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(colors.background)
    ) {
        Column(Modifier.fillMaxSize()) {
            DownloaderTopBar(
                title = server?.displayName ?: "下载器",
                online = snapshot?.online == true,
                altSpeed = snapshot?.altSpeedKnown == true && snapshot.altSpeedEnabled,
                servers = state.servers,
                currentServerId = serverId,
                onSwitchServer = onSwitchServer,
                onMenu = { drawerOpen = true },
                onBatch = { batchSheet = true },
                onAltSpeed = onToggleAltSpeed,
                onExit = onBack
            )

            // 顶部汇总：和侧边栏同口径，扫一眼就知道这台机器现在在干什么
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Metrics.pagePadding, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(Icons.Rounded.ArrowDownward, null, tint = Palette.blue, modifier = Modifier.size(12.dp))
                Text(
                    " ${formatBytes(source.sumOf { it.downloadSpeed })}/s",
                    fontSize = 11.5.sp,
                    color = colors.textSecondary
                )
                Spacer(Modifier.width(10.dp))
                Icon(Icons.Rounded.ArrowUpward, null, tint = Palette.green, modifier = Modifier.size(12.dp))
                Text(
                    " ${formatBytes(source.sumOf { it.uploadSpeed })}/s",
                    fontSize = 11.5.sp,
                    color = colors.textSecondary
                )
                Spacer(Modifier.weight(1f))
                Text(
                    "${filtered.size} / ${source.size} 个任务",
                    fontSize = 11.5.sp,
                    color = colors.textSecondary
                )
            }

            if (filtered.isEmpty()) {
                EmptyHint(
                    when {
                        server == null -> "这台下载器已被删除"
                        source.isEmpty() -> "还没有任务，点右下角 + 新增下载"
                        else -> "「${statusFilter.label}」下没有任务"
                    }
                )
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(
                        start = Metrics.pagePadding,
                        end = Metrics.pagePadding,
                        top = 8.dp,
                        bottom = 150.dp
                    ),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    items(filtered, key = { it.id }) { task ->
                        TorrentRow(
                            task = task,
                            // 点任务 = 弹出操作菜单（详情在弹窗里再点进去），和参考客户端一致
                            onClick = { onOpenActions(task) },
                            onLongClick = { onOpenActions(task) }
                        )
                    }
                }
            }
        }

        // 右下角两个悬浮按钮：+ 新增下载 / 排序（横排，和鸿蒙一致）
        Row(
            Modifier
                .align(Alignment.BottomEnd)
                .navigationBarsPadding()
                .padding(end = 18.dp, bottom = 24.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            FloatingButton(
                icon = Icons.Rounded.Add,
                description = "新增下载",
                background = Palette.blue,
                tint = Color.White,
                size = 48,
                onClick = onOpenAdd
            )
            // 排序做成挂在按钮上的菜单（跟鸿蒙 bindMenu 一样），不再用居中弹窗；
            // 按钮在屏幕底部，菜单会自动改到按钮上方展开。
            Box {
                FloatingButton(
                    icon = Icons.Rounded.FilterList,
                    description = "排序",
                    // 深色主题下「卡片色底 + 蓝色图标」几乎糊在背景里（用户反馈看不清）：
                    // 改成描边 + 近白图标，再给它一层投影，浮在列表之上才认得出这是个按钮
                    background = colors.card,
                    tint = if (colors.isDark) colors.textPrimary else colors.accent,
                    size = 48,
                    border = colors.accent.copy(alpha = if (colors.isDark) 0.55f else 0.30f),
                    onClick = { sortSheet = !sortSheet }
                )
                SortMenu(
                    expanded = sortSheet,
                    isQb = server?.type == ServerType.QBITTORRENT,
                    current = sortMode,
                    ascending = sortAsc,
                    onPick = { mode ->
                        if (mode == sortMode) sortAsc = !sortAsc else {
                            sortMode = mode
                            sortAsc = false
                        }
                        sortSheet = false
                    },
                    onDismiss = { sortSheet = false }
                )
            }
        }

        // ---------- 侧边栏 ----------
        AnimatedVisibility(
            visible = drawerOpen,
            enter = fadeIn(),
            exit = fadeOut()
        ) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.4f))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null
                    ) { drawerOpen = false }
            )
        }
        AnimatedVisibility(
            visible = drawerOpen,
            enter = slideInHorizontally(initialOffsetX = { -it }),
            exit = slideOutHorizontally(targetOffsetX = { -it })
        ) {
            DrawerPanel(
                server = server,
                snapshot = snapshot,
                tasks = source,
                statusFilter = statusFilter,
                onSelectFilter = {
                    statusFilter = it
                    drawerOpen = false
                },
                onRefresh = {
                    onRefresh()
                    drawerOpen = false
                },
                onOpenConfig = {
                    drawerOpen = false
                    onOpenConfig()
                },
                onExit = {
                    drawerOpen = false
                    onBack()
                }
            )
        }
    }

    // ---------- 批量操作面板 ----------
    if (batchSheet) {
        BatchDialog(
            isQb = server?.type == ServerType.QBITTORRENT,
            onDismiss = { batchSheet = false },
            onAction = { action ->
                when (action) {
                    BatchAction.DELETE, BatchAction.DELETE_WITH_FILES -> {
                        batchSheet = false
                        deleteDialog = true
                    }

                    BatchAction.CHANGE_LOCATION -> {
                        batchSheet = false
                        locationDialog = true
                    }

                    else -> runBatch(action)
                }
            }
        )
    }

    // ---------- 更改保存位置 ----------
    if (locationDialog) {
        LocationDialog(
            count = allHashes.size,
            initial = snapshot?.defaultSavePath.orEmpty(),
            onDismiss = { locationDialog = false },
            onConfirm = { path ->
                locationDialog = false
                onBatch(BatchAction.CHANGE_LOCATION, allHashes, path)
            }
        )
    }

    // ---------- 批量删除 ----------
    if (deleteDialog) {
        BatchDeleteDialog(
            tasks = source,
            onDismiss = { deleteDialog = false },
            onConfirm = { hashes, deleteFiles ->
                deleteDialog = false
                onBatch(
                    if (deleteFiles) BatchAction.DELETE_WITH_FILES else BatchAction.DELETE,
                    hashes,
                    ""
                )
            }
        )
    }
}

// ---------------------------------------------------------------- 顶栏

@Composable
private fun DownloaderTopBar(
    title: String,
    online: Boolean,
    altSpeed: Boolean,
    servers: List<ServerConfig>,
    currentServerId: String,
    onSwitchServer: (String) -> Unit,
    onMenu: () -> Unit,
    onBatch: () -> Unit,
    onAltSpeed: () -> Unit,
    onExit: () -> Unit
) {
    val colors = LocalMptColors.current
    var switchMenu by remember { mutableStateOf(false) }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconButtonBox(onClick = onMenu) {
            Icon(Icons.Rounded.Menu, "菜单", tint = colors.textPrimary, modifier = Modifier.size(21.dp))
        }
        Spacer(Modifier.width(4.dp))
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
            Text(
                title,
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Spacer(Modifier.width(7.dp))
            Box(
                Modifier
                    .size(7.dp)
                    .clip(CircleShape)
                    .background(if (online) Palette.green else Palette.red)
            )
        }

        // 切换下载器：多台机器时不用再退回仪表盘
        if (servers.size > 1) {
            Box {
                IconButtonBox(onClick = { switchMenu = true }) {
                    Icon(
                        Icons.Rounded.SwapHoriz,
                        "切换下载器",
                        tint = colors.textPrimary,
                        modifier = Modifier.size(21.dp)
                    )
                }
                DropdownMenu(
                    expanded = switchMenu,
                    onDismissRequest = { switchMenu = false },
                    containerColor = colors.card
                ) {
                    servers.forEach { item ->
                        val active = item.id == currentServerId
                        DropdownMenuItem(
                            text = {
                                Text(
                                    "${item.displayName} · ${item.type.shortLabel.uppercase()}",
                                    fontSize = 14.sp,
                                    color = if (active) colors.accent else colors.textPrimary
                                )
                            },
                            trailingIcon = {
                                if (active) {
                                    Icon(
                                        Icons.Rounded.Check,
                                        null,
                                        tint = colors.accent,
                                        modifier = Modifier.size(16.dp)
                                    )
                                }
                            },
                            onClick = {
                                switchMenu = false
                                if (!active) onSwitchServer(item.id)
                            }
                        )
                    }
                }
            }
        }

        IconButtonBox(onClick = onBatch) {
            Icon(Icons.Rounded.Checklist, "批量操作", tint = colors.textPrimary, modifier = Modifier.size(21.dp))
        }
        IconButtonBox(onClick = onAltSpeed) {
            Icon(
                Icons.Rounded.Speed,
                "备用限速",
                tint = if (altSpeed) Palette.orange else colors.textPrimary,
                modifier = Modifier.size(21.dp)
            )
        }
        IconButtonBox(onClick = onExit) {
            Icon(Icons.Rounded.Close, "退出", tint = colors.textPrimary, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun IconButtonBox(onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(
        Modifier
            .size(38.dp)
            .clip(CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        content()
    }
}

// ---------------------------------------------------------------- 任务卡片

// 各类 Unicode 行终止符：qB/TR 的 \r\n、部分源混进来的 U+000B / U+0085 / U+2028 / U+2029，
// 在 Compose 里都算硬换行。统一压成单个空格再渲染。
private val NAME_LINE_BREAKS = Regex("[\\r\\n\\u000B\\u000C\\u0085\\u2028\\u2029]+")
// 种子名几乎都是「[中文名].Let's.Go.2026.S01.2160p.WEB-DL...」这种点号连成的超长串，
// 中间没有一个空格。安卓默认按「词」断行（BREAK_STRATEGY_SIMPLE/HIGH_QUALITY 都不拆词），
// 于是整串被推到第二行，第一行只剩中文名 + 一大片空白。
// 在点 / 横杠 / 下划线 / 括号后面补一个零宽空格，制造断行机会，第一行就能填满再折行。
private val NAME_BREAKERS = Regex("([._\\-\\[\\]()]+)")
private fun String.asSingleLineName(): String =
    NAME_LINE_BREAKS.replace(this, " ").trim().replace(NAME_BREAKERS, "\$1\u200B")

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TorrentRow(
    task: TorrentTask,
    onClick: () -> Unit,
    onLongClick: () -> Unit
) {
    val colors = LocalMptColors.current
    val tint = Color(task.status.accentArgb)
    // 卡片做成「浮起来」的观感：小圆角 + 投影 + 极淡描边（深色主题里投影几乎看不见，靠描边兜底）
    val shape = RoundedCornerShape(8.dp)

    Column(
        Modifier
            .fillMaxWidth()
            .shadow(3.dp, shape)
            .clip(shape)
            .background(colors.card)
            .border(0.5.dp, colors.separator.copy(alpha = 0.55f), shape)
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(horizontal = 11.dp, vertical = 9.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                statusGlyph(task.status),
                null,
                tint = tint,
                modifier = Modifier.size(15.dp)
            )
            Spacer(Modifier.width(5.dp))
            Text(
                task.status.label,
                fontSize = 11.5.sp,
                fontWeight = FontWeight.Medium,
                color = tint
            )
            if (task.trackerHost.isNotBlank()) {
                Spacer(Modifier.width(7.dp))
                Text(
                    task.trackerHost,
                    fontSize = 10.5.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
            } else {
                Spacer(Modifier.weight(1f))
            }
            Spacer(Modifier.width(8.dp))
            Text(
                if (task.progress >= 0.9999) shortTime(task.addedAt) else "↓ ${humanEta(task.etaSeconds)}",
                fontSize = 11.sp,
                color = colors.textSecondary,
                maxLines = 1
            )
            Spacer(Modifier.width(7.dp))
            Text(
                formatPercent(task.progress),
                fontSize = 11.5.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (task.progress >= 0.9999) Palette.green else tint,
                maxLines = 1
            )
        }

        Spacer(Modifier.height(5.dp))
        // 种子名是「[中文名].Let's.Go.2026.S01.2160p.WEB-DL...」这种点号连成的长串，中间没有空格。
        // 安卓按词断行会把整串推到第二行，第一行只剩中文名 + 一大片空白。asSingleLineName()
        // 在点号后补零宽空格制造断行机会，配合 LineBreak.Simple 逐字符填满整行再折行。
        Text(
            task.name.asSingleLineName(),
            fontSize = 13.5.sp,
            color = colors.textPrimary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            lineHeight = 18.sp,
            style = TextStyle(lineBreak = LineBreak.Simple)
        )
        if (task.status == TorrentStatus.ERROR && task.errorMessage.isNotBlank()) {
            Spacer(Modifier.height(3.dp))
            Text(
                task.errorMessage,
                fontSize = 10.5.sp,
                color = Palette.red,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }

        Spacer(Modifier.height(7.dp))
        Row(Modifier.fillMaxWidth()) {
            // 第一列：上/下行速度
            Column(Modifier.weight(1.15f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                MetricLine(Icons.Rounded.ArrowDownward, Palette.blue, "${formatBytes(task.downloadSpeed)}/s")
                MetricLine(Icons.Rounded.ArrowUpward, Palette.green, "${formatBytes(task.uploadSpeed)}/s")
            }
            // 第二列：连接到的 peer / 种子
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                MetricLine(Icons.Rounded.Person, colors.textSecondary, "${task.numPeers}/${task.totalPeers}")
                MetricLine(Icons.Rounded.Groups, colors.textSecondary, "${task.numSeeds}/${task.totalSeeds}")
            }
            // 第三列：体积 / 分享率
            Column(Modifier.weight(0.95f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                MetricLine(Icons.Rounded.Folder, colors.textSecondary, formatStorageSize(task.size))
                MetricLine(Icons.Rounded.Link, colors.textSecondary, formatRatio(task.ratio))
            }
        }
    }
}

@Composable
private fun MetricLine(icon: ImageVector, tint: Color, text: String) {
    val colors = LocalMptColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(11.dp))
        Spacer(Modifier.width(4.dp))
        Text(
            text,
            fontSize = 10.5.sp,
            color = colors.textSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

private fun statusGlyph(status: TorrentStatus): ImageVector = when (status) {
    TorrentStatus.DOWNLOADING -> Icons.Rounded.ArrowCircleDown
    TorrentStatus.QUEUED -> Icons.Rounded.ArrowCircleDown
    TorrentStatus.SEEDING -> Icons.Rounded.ArrowCircleUp
    TorrentStatus.PAUSED -> Icons.Rounded.PauseCircleOutline
    TorrentStatus.CHECKING -> Icons.Rounded.Sync
    TorrentStatus.ERROR -> Icons.Rounded.ErrorOutline
    TorrentStatus.COMPLETED -> Icons.Rounded.CheckCircle
}

/** 参考客户端右上角那个 HH:mm:ss，用「添加时间」代替没有的直接时长 */
private fun shortTime(epochMillis: Long): String =
    if (epochMillis <= 0) "--" else SimpleDateFormat("HH:mm:ss", Locale.US).format(Date(epochMillis))

// ---------------------------------------------------------------- 侧边栏

@Composable
private fun DrawerPanel(
    server: ServerConfig?,
    snapshot: ServerSnapshot?,
    tasks: List<TorrentTask>,
    statusFilter: StatusFilter,
    onSelectFilter: (StatusFilter) -> Unit,
    onRefresh: () -> Unit,
    onOpenConfig: () -> Unit,
    onExit: () -> Unit
) {
    val colors = LocalMptColors.current
    val isQb = server?.type == ServerType.QBITTORRENT
    val version = snapshot?.appVersion.orEmpty()
    val totalSize = tasks.sumOf { it.size }
    val seeding = tasks.count { it.status == TorrentStatus.SEEDING }
    val downloading = tasks.count {
        it.status == TorrentStatus.DOWNLOADING || it.status == TorrentStatus.QUEUED
    }
    // 快照为 0 时用本机任务速度兜底，避免「有上传但抽屉一直 0 B/s」
    val drawerDownSpeed = if ((snapshot?.downloadSpeed ?: 0) > 0) snapshot!!.downloadSpeed
                          else tasks.sumOf { it.downloadSpeed }
    val drawerUpSpeed = if ((snapshot?.uploadSpeed ?: 0) > 0) snapshot!!.uploadSpeed
                        else tasks.sumOf { it.uploadSpeed }

    Column(
        Modifier
            .fillMaxHeight()
            .width(302.dp)
            .background(colors.card)
    ) {
        Column(Modifier.padding(horizontal = 16.dp).padding(top = 18.dp)) {
            // 版本 + 名称 + 在线状态
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    buildString {
                        append(if (isQb) "QB" else "TR")
                        // tr 的版本号后面常带一串 commit（4.0.6 (38c1649)），只取前面的版本
                        if (version.isNotBlank()) append(" ").append(version.substringBefore(" ").take(12))
                    },
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.accent
                )
                Spacer(Modifier.weight(1f))
                Text(
                    if (snapshot?.online == true) "ONLINE" else "OFFLINE",
                    fontSize = 10.5.sp,
                    fontWeight = FontWeight.Medium,
                    color = if (snapshot?.online == true) Palette.green else Palette.red
                )
            }
            Spacer(Modifier.height(3.dp))
            Text(
                if (isQb) "qBittorrent" else "Transmission",
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary
            )
            Spacer(Modifier.height(8.dp))

            DrawerInfoLine(Icons.Rounded.Link, snapshot?.endpointLabel ?: "未连接")
            if (server != null) {
                DrawerInfoLine(
                    Icons.Rounded.Person,
                    if (server.useApiKey && isQb) "API Key" else server.username.ifBlank { "未设置用户名" }
                )
            }
            DrawerInfoLine(Icons.Rounded.Folder, formatStorageSize(totalSize))

            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                DrawerStat("↓", formatBytes(drawerDownSpeed) + "/s", Palette.blue)
                DrawerStat("↑", formatBytes(drawerUpSpeed) + "/s", Palette.green)
            }
            Spacer(Modifier.height(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                DrawerStat("做种", "$seeding", Palette.green)
                DrawerStat("下载", "$downloading", Palette.blue)
                DrawerStat(
                    "分享率",
                    String.format(Locale.US, "%.2f", snapshot?.ratio ?: 0.0),
                    colors.textPrimary
                )
            }
        }

        Spacer(Modifier.height(14.dp))
        Box(Modifier.fillMaxWidth().height(0.6.dp).background(colors.separator))

        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
        ) {
            // 每行之间一条细横线（末行不画，避免和下面的分组分隔线叠在一起）
            StatusFilter.entries.forEachIndexed { index, filter ->
                DrawerRow(
                    icon = statusIcon(filter),
                    tint = statusTint(filter),
                    label = filter.label,
                    selected = filter == statusFilter,
                    trailing = {
                        if (filter == statusFilter) {
                            Box(
                                Modifier
                                    .size(17.dp)
                                    .clip(CircleShape)
                                    .background(colors.accent),
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(Icons.Rounded.Check, null, tint = Color.White, modifier = Modifier.size(12.dp))
                            }
                        }
                    },
                    onClick = { onSelectFilter(filter) }
                )
                if (index < StatusFilter.entries.lastIndex) {
                    Box(Modifier.fillMaxWidth().height(0.6.dp).background(colors.separator))
                }
            }

            Box(Modifier.fillMaxWidth().height(0.6.dp).background(colors.separator))
            DrawerRow(
                icon = Icons.Rounded.Refresh,
                tint = Palette.blue,
                label = "刷新",
                onClick = onRefresh
            )
            Box(Modifier.fillMaxWidth().height(0.6.dp).background(colors.separator))
            DrawerRow(
                icon = Icons.Rounded.Settings,
                tint = Palette.indigo,
                label = "配置",
                trailing = {
                    Icon(
                        Icons.Rounded.ChevronRight,
                        null,
                        tint = colors.textSecondary,
                        modifier = Modifier.size(16.dp)
                    )
                },
                onClick = onOpenConfig
            )
            Box(Modifier.fillMaxWidth().height(0.6.dp).background(colors.separator))
            DrawerRow(
                icon = Icons.Rounded.ArrowBack,
                tint = Palette.orange,
                label = "返回",
                onClick = onExit
            )
            Spacer(Modifier.height(14.dp))
        }
    }
}

@Composable
private fun DrawerInfoLine(icon: ImageVector, text: String) {
    val colors = LocalMptColors.current
    Row(
        Modifier.padding(vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, null, tint = colors.textSecondary, modifier = Modifier.size(13.dp))
        Spacer(Modifier.width(7.dp))
        Text(
            text,
            fontSize = 11.5.sp,
            color = colors.textSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
private fun DrawerStat(label: String, value: String, tint: Color) {
    val colors = LocalMptColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontSize = 10.5.sp, color = colors.textSecondary)
        Spacer(Modifier.width(4.dp))
        Text(value, fontSize = 11.5.sp, fontWeight = FontWeight.Medium, color = tint)
    }
}

@Composable
private fun DrawerRow(
    icon: ImageVector,
    tint: Color,
    label: String,
    selected: Boolean = false,
    trailing: (@Composable () -> Unit)? = null,
    onClick: () -> Unit
) {
    val colors = LocalMptColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(13.dp))
        Text(
            label,
            fontSize = 14.sp,
            color = if (selected) colors.accent else colors.textPrimary,
            fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal,
            modifier = Modifier.weight(1f)
        )
        trailing?.invoke()
    }
}

private fun statusIcon(filter: StatusFilter): ImageVector = when (filter) {
    StatusFilter.ALL -> Icons.Rounded.DoneAll
    StatusFilter.DOWNLOADING -> Icons.Rounded.CloudDownload
    StatusFilter.PAUSED -> Icons.Rounded.PauseCircleOutline
    StatusFilter.SEEDING -> Icons.Rounded.CloudUpload
    StatusFilter.ACTIVE -> Icons.Rounded.SwapVert
    StatusFilter.COMPLETED -> Icons.Rounded.CheckCircle
    StatusFilter.CHECKING -> Icons.Rounded.FactCheck
    StatusFilter.ERROR -> Icons.Rounded.ErrorOutline
}

private fun statusTint(filter: StatusFilter): Color = when (filter) {
    StatusFilter.ALL -> Color(0xFF0A84FF)
    StatusFilter.DOWNLOADING -> Color(0xFF0A84FF)
    StatusFilter.PAUSED -> Color(0xFFAF52DE)
    StatusFilter.SEEDING -> Color(0xFF34C759)
    StatusFilter.ACTIVE -> Color(0xFF30B0C7)
    StatusFilter.COMPLETED -> Color(0xFF34C759)
    StatusFilter.CHECKING -> Color(0xFFFF9500)
    StatusFilter.ERROR -> Color(0xFFFF3B30)
}

// ---------------------------------------------------------------- 批量操作面板

private data class BatchItem(
    val action: BatchAction,
    val label: String,
    val icon: ImageVector,
    val tint: Color,
    val arrow: Boolean = false
)

@Composable
private fun BatchDialog(
    isQb: Boolean,
    onDismiss: () -> Unit,
    onAction: (BatchAction) -> Unit
) {
    val colors = LocalMptColors.current
    val items = remember(isQb) {
        buildList {
            add(BatchItem(BatchAction.RESUME_ALL, "全部继续", Icons.Rounded.PlayArrow, Palette.indigo))
            add(BatchItem(BatchAction.PAUSE_ALL, "全部暂停", Icons.Rounded.PauseCircleOutline, Palette.indigo))
            if (isQb) {
                add(
                    BatchItem(
                        BatchAction.FORCE_RESUME_ALL,
                        "全部强制继续",
                        Icons.Rounded.Bolt,
                        Palette.green
                    )
                )
            }
            add(
                BatchItem(
                    BatchAction.CHANGE_LOCATION,
                    "更改保存位置",
                    Icons.Rounded.DriveFileMove,
                    Palette.orange,
                    arrow = true
                )
            )
            if (isQb) {
                add(
                    BatchItem(
                        BatchAction.AUTO_MANAGEMENT_ON,
                        "自动种子管理",
                        Icons.Rounded.AutoMode,
                        Palette.purple
                    )
                )
                add(
                    BatchItem(
                        BatchAction.SUPER_SEEDING_ON,
                        "超级种子模式",
                        Icons.Rounded.Speed,
                        Palette.green
                    )
                )
            }
            add(BatchItem(BatchAction.RECHECK_ALL, "重新校验", Icons.Rounded.FactCheck, Palette.green))
            add(BatchItem(BatchAction.REANNOUNCE_ALL, "重新汇报", Icons.Rounded.Campaign, Palette.orange))
            // 高危动作永远排最后（用户要求：凡是高危操作都放最底部）
            add(BatchItem(BatchAction.DELETE, "批量删除", Icons.Rounded.Delete, Palette.red))
        }
    }

    OiiDialog(
        title = "批量操作",
        subtitle = "对这台下载器的全部任务生效",
        confirmText = "关闭",
        cancelText = null,
        maxHeight = 400.dp,
        onDismiss = onDismiss,
        onConfirm = onDismiss
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(colors.background)
        ) {
            items.forEachIndexed { index, item ->
                if (index > 0) {
                    Box(
                        Modifier
                            .padding(start = 45.dp)
                            .fillMaxWidth()
                            .height(0.6.dp)
                            .background(colors.separator)
                    )
                }
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { onAction(item.action) }
                        .padding(horizontal = 12.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(item.icon, null, tint = item.tint, modifier = Modifier.size(19.dp))
                    Spacer(Modifier.width(13.dp))
                    Text(
                        item.label,
                        fontSize = 14.sp,
                        color = colors.textPrimary,
                        modifier = Modifier.weight(1f)
                    )
                    if (item.arrow) {
                        Icon(
                            Icons.Rounded.ChevronRight,
                            null,
                            tint = colors.textSecondary,
                            modifier = Modifier.size(17.dp)
                        )
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- 排序菜单
// 挂在排序按钮上方（按钮在屏幕底部，Material 的 DropdownMenu 会自动改到上方展开），
// 和鸿蒙的 bindMenu 一样：点一次选中、再点同一个切换升降序，不再用居中弹窗。

@Composable
private fun SortMenu(
    expanded: Boolean,
    isQb: Boolean,
    current: SortMode,
    ascending: Boolean,
    onPick: (SortMode) -> Unit,
    onDismiss: () -> Unit
) {
    val colors = LocalMptColors.current
    val modes = remember(isQb) {
        SortMode.entries.filter { isQb || it != SortMode.RATIO }
    }
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
        modifier = Modifier.width(180.dp),
        // 菜单右边缘贴着排序按钮右边缘（按钮 48dp），和鸿蒙弹出位置一致
        offset = DpOffset(x = (-132).dp, y = 0.dp),
        containerColor = colors.card
    ) {
        modes.forEach { mode ->
            val selected = mode == current
            val label = if (selected) {
                "${mode.label}${if (ascending) "（升序 ↑）" else "（降序 ↓）"}"
            } else mode.label
            DropdownMenuItem(
                text = {
                    Text(
                        label,
                        fontSize = 14.sp,
                        color = if (selected) colors.accent else colors.textPrimary
                    )
                },
                onClick = { onPick(mode) }
            )
        }
    }
}

// ---------------------------------------------------------------- 单任务操作菜单见 TaskActionsScreen.kt

// ---------------------------------------------------------------- 对话框

@Composable
private fun LocationDialog(
    count: Int,
    initial: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit
) {
    val colors = LocalMptColors.current
    var path by remember { mutableStateOf(initial) }

    OiiDialog(
        title = "更改保存位置",
        subtitle = "对当前 $count 个任务生效",
        confirmText = "确定",
        confirmEnabled = path.isNotBlank(),
        maxHeight = 240.dp,
        onDismiss = onDismiss,
        onConfirm = { if (path.isNotBlank()) onConfirm(path.trim()) }
    ) {
        Text(
            "已下载的文件会被移动（tr 的 move=true / qb 的 setLocation）",
            fontSize = 11.5.sp,
            color = colors.textSecondary,
            lineHeight = 17.sp
        )
        Spacer(Modifier.height(10.dp))
        DialogInput(value = path, placeholder = "/video/tv", onChange = { path = it })
    }
}

@Composable
private fun BatchDeleteDialog(
    tasks: List<TorrentTask>,
    onDismiss: () -> Unit,
    onConfirm: (List<String>, Boolean) -> Unit
) {
    val colors = LocalMptColors.current
    val checked = remember(tasks) { mutableStateMapOf<String, Boolean>().apply { tasks.forEach { put(it.id, true) } } }
    var deleteFiles by remember { mutableStateOf(false) }
    val selected = tasks.filter { checked[it.id] == true }

    OiiDialog(
        title = "批量删除",
        subtitle = "共 ${tasks.size} 个任务，可逐个取消勾选",
        confirmText = if (deleteFiles) "删除任务和文件" else "删除任务",
        confirmEnabled = selected.isNotEmpty(),
        destructive = true,
        maxHeight = 400.dp,
        onDismiss = onDismiss,
        onConfirm = { onConfirm(selected.map { it.hash }, deleteFiles) }
    ) {
        // 这里不能用 LazyColumn：PoiDialog 的内容区已经是 verticalScroll，
        // 竖向可滚组件套竖向可滚组件在 Compose 里会直接抛异常（无限高度约束）。
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                "已选 ${selected.size} / ${tasks.size}",
                fontSize = 11.sp,
                color = colors.textSecondary,
                modifier = Modifier.weight(1f)
            )
            Text(
                if (selected.size == tasks.size) "取消全选" else "全选",
                fontSize = 12.sp,
                color = colors.accent,
                modifier = Modifier.clickable {
                    val target = selected.size != tasks.size
                    tasks.forEach { checked[it.id] = target }
                }
            )
        }
        Spacer(Modifier.height(6.dp))
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(colors.background)
                .padding(horizontal = 10.dp, vertical = 2.dp)
        ) {
            tasks.forEach { task ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { checked[task.id] = !(checked[task.id] ?: false) }
                        .padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    CheckMark(checked[task.id] == true)
                    Spacer(Modifier.width(9.dp))
                    Text(
                        task.name.asSingleLineName(),
                        fontSize = 12.sp,
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(
            Modifier
                .fillMaxWidth()
                .clickable { deleteFiles = !deleteFiles }
                .padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            CheckMark(deleteFiles)
            Spacer(Modifier.width(9.dp))
            Text(
                "同时删除已下载的文件",
                fontSize = 12.sp,
                color = if (deleteFiles) Palette.red else colors.textPrimary
            )
        }
    }
}

@Composable
private fun CheckMark(checked: Boolean) {
    val colors = LocalMptColors.current
    Box(
        Modifier
            .size(18.dp)
            .clip(RoundedCornerShape(5.dp))
            .background(if (checked) colors.accent else Color.Transparent)
            .border(
                1.2.dp,
                if (checked) colors.accent else colors.textSecondary.copy(alpha = 0.45f),
                RoundedCornerShape(5.dp)
            ),
        contentAlignment = Alignment.Center
    ) {
        if (checked) {
            Icon(Icons.Rounded.Check, null, tint = Color.White, modifier = Modifier.size(13.dp))
        }
    }
}

@Composable
private fun DialogInput(value: String, placeholder: String, onChange: (String) -> Unit) {
    val colors = LocalMptColors.current
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val shape = RoundedCornerShape(10.dp)
    Box(
        Modifier
            .fillMaxWidth()
            .height(42.dp)
            .clip(shape)
            .background(colors.background)
            .border(1.dp, colors.separator, shape)
            .padding(horizontal = 11.dp),
        contentAlignment = Alignment.CenterStart
    ) {
        if (value.isEmpty()) {
            Text(placeholder, fontSize = 13.sp, color = colors.textSecondary)
        }
        BasicTextField(
            value = value,
            onValueChange = onChange,
            singleLine = true,
            textStyle = TextStyle(fontSize = 13.sp, color = colors.textPrimary),
            cursorBrush = SolidColor(colors.accent),
            // 改名 / 改路径这类弹窗也要有「完成」键，否则键盘收不回去
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(
                onDone = {
                    focusManager.clearFocus()
                    keyboard?.hide()
                }
            ),
            modifier = Modifier.fillMaxWidth()
        )
    }
}

// ---------------------------------------------------------------- 悬浮按钮

@Composable
private fun FloatingButton(
    icon: ImageVector,
    description: String,
    background: Color,
    tint: Color,
    size: Int,
    border: Color? = null,
    onClick: () -> Unit
) {
    Box(
        Modifier
            .size(size.dp)
            // 浮在列表上：给投影 + 可选描边，深色主题下才不会和下面的卡片糊成一片
            .shadow(6.dp, CircleShape)
            .clip(CircleShape)
            .background(background)
            .then(
                if (border == null) Modifier
                else Modifier.border(1.dp, border, CircleShape)
            )
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, description, tint = tint, modifier = Modifier.size((size * 0.45f).dp))
    }
}
