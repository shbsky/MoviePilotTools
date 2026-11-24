package com.moviepilottools.mptools

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.Public
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.runtime.CompositionLocalProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect
import dev.chrisbanes.haze.hazeSource
import com.moviepilottools.mptools.data.MpServer
import com.moviepilottools.mptools.data.MpSite
import com.moviepilottools.mptools.data.ServerType
import com.moviepilottools.mptools.data.TorrentTask
import com.moviepilottools.mptools.ui.components.softShadow
import com.moviepilottools.mptools.ui.dashboard.DashboardScreen
import com.moviepilottools.mptools.ui.moviepilot.MpServerEditDialog
import com.moviepilottools.mptools.ui.moviepilot.MpServerListScreen
import com.moviepilottools.mptools.ui.music.MiniPlayerBar
import com.moviepilottools.mptools.ui.music.MusicScreen
import com.moviepilottools.mptools.ui.music.NowPlayingScreen
import com.moviepilottools.mptools.ui.moviepilot.MoviePilotScreen
import com.moviepilottools.mptools.ui.settings.ServerEditDialog
import com.moviepilottools.mptools.ui.settings.ServerListScreen
import com.moviepilottools.mptools.ui.settings.SettingsScreen
import com.moviepilottools.mptools.ui.sites.SiteDetailScreen
import com.moviepilottools.mptools.ui.sites.SiteScreen
import com.moviepilottools.mptools.ui.theme.LocalMptColors
import com.moviepilottools.mptools.ui.theme.OiiTheme
import com.moviepilottools.mptools.ui.theme.Palette
import com.moviepilottools.mptools.ui.transfers.TaskActionsScreen
import com.moviepilottools.mptools.ui.transfers.TaskEditDialog
import com.moviepilottools.mptools.ui.transfers.TrackerListDialog
import com.moviepilottools.mptools.ui.transfers.TorrentAddDialog
import com.moviepilottools.mptools.ui.transfers.TorrentDetailScreen
import com.moviepilottools.mptools.ui.transfers.TransfersScreen
import com.moviepilottools.mptools.vm.AppViewModel
import com.moviepilottools.mptools.vm.BatchAction
import com.moviepilottools.mptools.vm.MpViewModel
import com.moviepilottools.mptools.vm.MusicViewModel
import com.moviepilottools.mptools.vm.TaskEditMode
import com.moviepilottools.mptools.vm.TorrentAction
import com.moviepilottools.mptools.work.RssNotifications
import com.moviepilottools.mptools.work.RssScheduler
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // targetSdk 35 起系统默认让内容画到状态栏/导航栏下面，
        // 不显式声明 edge-to-edge 的话 WindowInsets 全是 0，
        // 页面顶部的标题就会被状态栏图标压住（仪表盘上看得最明显）。
        enableEdgeToEdge()
        setContent {
            val vm: AppViewModel = viewModel()
            val mpVm: MpViewModel = viewModel()
            val musicVm: MusicViewModel = viewModel()
            AppRoot(vm, mpVm, musicVm)
        }
    }
}

private enum class Tab(val label: String, val icon: ImageVector) {
    DASHBOARD("仪表盘", Icons.Rounded.BarChart),
    SITES("站点", Icons.Rounded.Public),
    MUSIC("音乐", Icons.Rounded.LibraryMusic),
    MOVIEPILOT("MoviePilot", Icons.Rounded.Movie),
    SETTINGS("设置", Icons.Rounded.Settings)
}

/**
 * 整页（会把底部标签栏整条盖掉的那种）。
 *
 * 只剩 5 个：任务详情 / 任务编辑 / 新增下载 / 服务器编辑全部变成弹窗，
 * 弹窗叠在页面上、不换页，所以「返回」是逐层关弹窗，而不是一路退到列表。
 */
private sealed interface Overlay {
    /** 点仪表盘的下载器卡片进来：固定这一台，返回回仪表盘 */
    data class Downloader(val serverId: String) : Overlay
    /** 站点详情（种子浏览），从站点标签进 */
    data class SiteDetail(val site: MpSite) : Overlay
    /** 下载器服务器列表（整页）：点添加 / 编辑才弹窗 */
    data object ServerList : Overlay
    /** MoviePilot 服务器列表（整页） */
    data object MpServerList : Overlay
    /** 设置页「用户协议」：纯本地静态文本 */
    data object Terms : Overlay
}

@Composable
private fun AppRoot(vm: AppViewModel, mpVm: MpViewModel, musicVm: MusicViewModel) {
    val state = vm.state
    val musicState by musicVm.state.collectAsState()
    // 本机播放 + 投送合并后的状态：列表高亮、迷你条、全屏页都用它
    val playback by musicVm.now.collectAsState()
    var tab by remember { mutableStateOf(Tab.DASHBOARD) }
    var overlay by remember { mutableStateOf<Overlay?>(null) }
    // 音乐页「去设置」：鸿蒙是直接弹出「音乐服务」配置弹窗，
    // 安卓以前只跳到设置页还得自己找入口，这里用一次性信号把弹窗打开。
    var musicSettingsRequest by remember { mutableStateOf(false) }
    /** 从打开服务器列表之前的页面（下载器侧边栏进来时，返回要回下载器而不是标签页） */
    var serverListFrom by remember { mutableStateOf<Overlay?>(null) }

    /**
     * 玻璃底栏的模糊采样源。
     *
     * Compose 的 `Modifier.blur` 只能模糊自己，做不出「背景透进玻璃」的效果，
     * 所以用 Haze：内容层挂 [hazeSource]，底栏用 [hazeEffect] 采样它再做高斯模糊。
     * 前提是底栏必须**浮在内容之上**（不能再是 Column 里的真实占位），否则背后只有纯色背景、没东西可映射。
     */
    val hazeState = remember { HazeState() }

    // ---- 弹窗层状态（都叠在页面之上，和鸿蒙端的层级一一对应）----
    /** 单任务操作弹窗（父级） */
    var actionTask by remember { mutableStateOf<TorrentTask?>(null) }
    /** 任务详情（子级：打开时把父级藏起来，关掉自然回到父级） */
    var detailTask by remember { mutableStateOf<TorrentTask?>(null) }
    /** 单任务编辑（子级） */
    var editTask by remember { mutableStateOf<Pair<TorrentTask, TaskEditMode>?>(null) }
    /** Tracker 列表（子级：和详情/编辑同级，打开时同样把操作弹窗藏起来） */
    var trackerTask by remember { mutableStateOf<TorrentTask?>(null) }
    var addOpen by remember { mutableStateOf(false) }
    var addServerId by remember { mutableStateOf("") }
    var serverEditOpen by remember { mutableStateOf(false) }
    var serverEditId by remember { mutableStateOf<String?>(null) }
    var mpEditOpen by remember { mutableStateOf(false) }
    var mpEditServer by remember { mutableStateOf<MpServer?>(null) }

    // 打开服务器列表：记住来路，返回时原路回去
    val openServerList: (Overlay?) -> Unit = { from ->
        serverListFrom = from
        overlay = Overlay.ServerList
    }

    // 全屏播放页
    var showNowPlaying by remember { mutableStateOf(false) }
    val context = androidx.compose.ui.platform.LocalContext.current
    val notifLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
    ) { }

    LaunchedEffect(Unit) {
        RssNotifications.ensureChannel(context)
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            val granted = androidx.core.content.ContextCompat.checkSelfPermission(
                context, android.Manifest.permission.POST_NOTIFICATIONS
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (!granted) {
                runCatching {
                    notifLauncher.launch(android.Manifest.permission.POST_NOTIFICATIONS)
                }
            }
        }
    }

    // RSS 模块已下线（标签页换成音乐），把残留的后台任务停掉
    LaunchedEffect(Unit) {
        RssScheduler.cancel(context)
    }

    // 解锁回到 App / 切回前台：立刻重拉一次 MP 媒体库统计，并清掉上次的失败提示。
    // 退到后台则停掉 5 分钟轮询——息屏时 Wi-Fi 会被系统挂起，后台轮询失败只会在
    // 仪表盘上留下一句「上次刷新失败」，等下次真的连通了才消，看起来像永远消不掉。
    val lifecycleOwner = androidx.compose.ui.platform.LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            when (event) {
                androidx.lifecycle.Lifecycle.Event.ON_START -> mpVm.onForeground()
                androidx.lifecycle.Lifecycle.Event.ON_STOP -> mpVm.onBackground()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // Songloft 配置变化时重建客户端并拉数据
    LaunchedEffect(state.settings.musicUrl, state.settings.musicUser, state.settings.musicPass) {
        musicVm.configure(
            state.settings.musicUrl,
            state.settings.musicUser,
            state.settings.musicPass
        )
    }

    val dark = when (state.settings.theme) {
        "dark" -> true
        "light" -> false
        else -> androidx.compose.foundation.isSystemInDarkTheme()
    }

    OiiTheme(darkTheme = dark) {
        val baseDensity = LocalDensity.current
        CompositionLocalProvider(
            LocalDensity provides Density(
                density = baseDensity.density,
                fontScale = baseDensity.fontScale * state.settings.fontScale
            )
        ) {
            val colors = LocalMptColors.current

            LaunchedEffect(state.toast) {
                if (state.toast != null) {
                    delay(2200)
                    vm.consumeToast()
                }
            }

            LaunchedEffect(mpVm.state.toast) {
                if (mpVm.state.toast != null) {
                    delay(2400)
                    mpVm.consumeToast()
                }
            }

            LaunchedEffect(musicState.toast) {
                if (musicState.toast != null) {
                    delay(2400)
                    musicVm.consumeToast()
                }
            }

            // 站点标签懒加载：第一次切过去才拉，之后由页面上的刷新按钮控制
            LaunchedEffect(tab, mpVm.state.server?.id) {
                if (tab == Tab.SITES) mpVm.loadSites()
            }

            // 返回栈：先关最上面的弹窗，再退整页。顺序必须和下面的渲染顺序反过来，
            // 否则会出现「点了返回，底下的页面先跑掉」。
            val dialogOpen = actionTask != null || detailTask != null || editTask != null ||
                trackerTask != null || addOpen || serverEditOpen || mpEditOpen
            BackHandler(enabled = dialogOpen || overlay != null) {
                when {
                    detailTask != null -> detailTask = null
                    editTask != null -> {
                        // 关掉弹窗回到「种子操作」整页（保持 actionTask 不动）
                        editTask = null
                    }

                    trackerTask != null -> {
                        vm.closeTrackers()
                        trackerTask = null
                    }

                    actionTask != null -> actionTask = null
                    addOpen -> {
                        vm.clearAddTorrentState()
                        addOpen = false
                    }

                    serverEditOpen -> serverEditOpen = false
                    mpEditOpen -> {
                        mpEditOpen = false
                        mpEditServer = null
                    }

                    overlay is Overlay.ServerList && serverListFrom != null -> {
                        overlay = serverListFrom
                        serverListFrom = null
                    }

                    overlay != null -> overlay = null
                }
            }

            Box(Modifier.fillMaxSize().background(colors.background)) {
                Column(Modifier.fillMaxSize().statusBarsPadding()) {
                    // 内容层同时是玻璃底栏的采样源：底栏浮在它上面时，
                    // 背后的卡片/列表会被真正模糊进玻璃里（这就是「背景映射到玻璃」）
                    Box(
                        Modifier
                            .weight(1f)
                            .hazeSource(hazeState)
                    ) {
                        when (val current = overlay) {
                            is Overlay.Downloader -> TransfersScreen(
                                state = state,
                                serverId = current.serverId,
                                // 退出按钮 / 系统返回手势：都回到仪表盘那个下载器卡片
                                onBack = {
                                    overlay = null
                                    tab = Tab.DASHBOARD
                                },
                                onOpenActions = { actionTask = it },
                                onRefresh = vm::refreshNow,
                                onOpenAdd = {
                                    vm.clearAddTorrentState()
                                    addServerId = current.serverId
                                    addOpen = true
                                },
                                // 侧边栏「配置」→ 整页的服务器列表（和设置页入口同一套），返回回这台下载器
                                onOpenConfig = { openServerList(Overlay.Downloader(current.serverId)) },
                                onBatch = { action, hashes, location ->
                                    vm.performBatch(current.serverId, action, hashes, location)
                                },
                                onToggleAltSpeed = { vm.toggleAltSpeed(current.serverId) },
                                // 顶栏「切换下载器」：直接换一台看，不用退出去
                                onSwitchServer = { id -> overlay = Overlay.Downloader(id) }
                            )

                            is Overlay.SiteDetail -> SiteDetailScreen(
                                site = mpVm.state.site,
                                downloaders = mpVm.state.downloaders.map { it.name },
                                savePaths = mpVm.state.savePaths,
                                lastDownloader = mpVm.state.lastDownloader,
                                lastSavePath = mpVm.state.lastSavePath,
                                onBack = {
                                    mpVm.closeSite()
                                    overlay = null
                                },
                                onRefresh = mpVm::refreshSiteTorrents,
                                onSearchInput = mpVm::updateSiteSearchInput,
                                onSubmitSearch = mpVm::submitSiteSearch,
                                onToggleCategory = mpVm::toggleSiteCategory,
                                onClearCategories = mpVm::clearSiteCategories,
                                onSortChange = mpVm::setSiteSort,
                                onLoadMore = mpVm::loadMoreSiteTorrents,
                                onCancelBrowse = mpVm::cancelSiteBrowse,
                                onLoadDownloadOptions = mpVm::loadDownloadOptions,
                                downloadSubmitting = mpVm.state.downloadSubmitting,
                                downloadError = mpVm.state.downloadError,
                                downloadDone = mpVm.state.downloadDone,
                                onClearDownloadResult = mpVm::clearDownloadResult,
                                onDownload = { resource, downloader, savePath ->
                                    mpVm.download(resource, downloader, savePath)
                                },
                                onLoadIcon = mpVm::loadSiteIcon,
                                // 种子详情页要 MP 的简介 / 演职员（站点接口只有文字）
                                onLoadTorrentMedia = mpVm::loadTorrentMedia
                            )

                            Overlay.ServerList -> ServerListScreen(
                                state = state,
                                onBack = {
                                    overlay = serverListFrom
                                    serverListFrom = null
                                },
                                onAdd = {
                                    serverEditId = null
                                    serverEditOpen = true
                                },
                                onEdit = {
                                    serverEditId = it
                                    serverEditOpen = true
                                }
                            )

                            Overlay.Terms -> com.moviepilottools.mptools.ui.settings.TermsScreen(
                                onBack = { overlay = null }
                            )

                            Overlay.MpServerList -> MpServerListScreen(
                                servers = mpVm.state.servers,
                                activeId = mpVm.state.activeServerId,
                                error = mpVm.state.error.orEmpty(),
                                onBack = { overlay = null },
                                onAdd = {
                                    mpEditServer = null
                                    mpEditOpen = true
                                },
                                onEdit = {
                                    mpEditServer = it
                                    mpEditOpen = true
                                }
                            )

                            null -> when (tab) {
                                Tab.DASHBOARD -> DashboardScreen(
                                    state = state,
                                    onSelectServer = vm::selectServer,
                                    onOpenServers = { openServerList(null) },
                                    // 点仪表盘的下载器卡片：直接进这台机器的状态页 + 任务列表
                                    onOpenServerTasks = { serverId ->
                                        overlay = Overlay.Downloader(serverId)
                                    },
                                    // 媒体库统计取自 MoviePilot 仪表盘；没配 MP 就显示引导
                                    mpStats = mpVm.state.stats,
                                    mpConfigured = mpVm.state.server != null,
                                    mpLoading = mpVm.state.statsLoading,
                                    mpError = mpVm.state.statsError,
                                    mpStorage = mpVm.state.storage,
                                    // 实时速率 / CPU / 内存 / 系统信息：本地按固定间隔采样 MP 仪表盘
                                    mpLive = mpVm.state.live,
                                    onOpenMpServers = { overlay = Overlay.MpServerList },
                                    // 首屏 Hero 海报轮播：片单来自 MP 推荐（独立缓存，不碰分页状态）
                                    heroPosters = mpVm.state.heroPosters,
                                    onOpenHeroDetail = { media ->
                                        tab = Tab.MOVIEPILOT
                                        mpVm.openDetail(media)
                                    }
                                )

                                Tab.SITES -> SiteScreen(
                                    site = mpVm.state.site,
                                    mpConfigured = mpVm.state.server != null,
                                    onRefresh = mpVm::refreshSites,
                                    onOpenSite = { site ->
                                        mpVm.openSite(site)
                                        overlay = Overlay.SiteDetail(site)
                                    },
                                    onOpenMpServers = { overlay = Overlay.MpServerList },
                                    onLoadIcon = mpVm::loadSiteIcon,
                                    // 站点显示白名单（空 = 全部）：只影响本页显示
                                    siteFilter = state.settings.mpSiteFilter,
                                    onFilterChange = { list ->
                                        vm.updateSettings(state.settings.copy(mpSiteFilter = list))
                                    }
                                )

                                Tab.MUSIC -> MusicScreen(
                                    state = musicState,
                                    playback = playback,
                                    onOpenSettings = {
                                        // 和鸿蒙一致：直接弹出「音乐服务」配置弹窗（不用再自己找入口）
                                        musicSettingsRequest = true
                                        tab = Tab.SETTINGS
                                    },
                                    onRefresh = musicVm::refresh,
                                    onStartSearch = musicVm::startSearch,
                                    onExitSearch = musicVm::exitSearch,
                                    onSearch = musicVm::search,
                                    onPlay = musicVm::playSong,
                                    onPlayAll = musicVm::playAll,
                                    onOpenPlaylist = musicVm::openPlaylist,
                                    onClosePlaylist = musicVm::closePlaylist,
                                    onLoadMore = musicVm::loadMore,
                                    onToggleFavorite = musicVm::toggleFavorite,
                                    onCast = musicVm::castCurrent,
                                    onTogglePlay = musicVm::togglePlay
                                )

                                Tab.MOVIEPILOT -> MoviePilotScreen(
                                    state = mpVm.state,
                                    onSelectChannel = mpVm::selectChannel,
                                    onLoadMore = { mpVm.loadDiscover(false) },
                                    onRefresh = { mpVm.loadDiscover(true) },
                                    onOpenDetail = mpVm::openDetail,
                                    onCloseDetail = mpVm::closeDetail,
                                    onStartSearch = mpVm::startSearch,
                                    onExitSearch = mpVm::exitSearch,
                                    onQueryChange = mpVm::updateSearchQuery,
                                    onSearch = mpVm::search,
                                    onSearchResources = mpVm::searchResources,
                                    onUpdateFilter = mpVm::updateFilter,
                                    onDownload = mpVm::download,
                                    onLoadDownloadOptions = mpVm::loadDownloadOptions,
                                    onSubscribe = mpVm::subscribe,
                                    onDeleteSubscribe = mpVm::deleteSubscribe,
                                    onToggleSubscribeState = mpVm::toggleSubscribeState,
                                    onLoadSubscribeOptions = mpVm::loadSubscribeOptions,
                                    // 每次进订阅列表静默刷新：MP 网页改过的订阅不用退 App 才能同步
                                    onLoadSubscribes = { mpVm.loadSubscribes(silent = true) },
                                    onSaveSubscribe = { sub, onResult -> mpVm.saveSubscribe(sub, onResult) },
                                    onSearchSubscribe = mpVm::searchSubscribeNow,
                                    onResetSubscribe = mpVm::resetSubscribe,
                                    onOpenSubscribeMedia = mpVm::openSubscribeMedia,
                                    onSubscribeActivity = mpVm::openSubscribeActivity,
                                    onSubscribeFiles = mpVm::openSubscribeFiles,
                                    onCloseSubscribePanel = mpVm::closeSubscribePanel,
                                    onOpenServers = { },
                                    onSelectServer = mpVm::selectServer,

                                    onSaveServer = mpVm::upsertServer,
                                    onDeleteServer = mpVm::deleteServer,
                                    onTestServer = mpVm::testServer
                                )

                                Tab.SETTINGS -> SettingsScreen(
                                    state = state,
                                    onOpenServers = { openServerList(null) },
                                    onOpenMpServers = { overlay = Overlay.MpServerList },
                                    mpServers = mpVm.state.servers,
                                    mpActiveId = mpVm.state.activeServerId,
                                    onProbeMp = { mpVm.testServer(it).isSuccess },
                                    onSettingsChange = vm::updateSettings,
                                    onOpenTerms = { overlay = Overlay.Terms },
                                    initialDialog = if (musicSettingsRequest) "music" else null,
                                    onInitialDialogShown = { musicSettingsRequest = false },
                                    onBackupRestored = {
                                        vm.reloadFromStore()
                                        mpVm.reloadFromStore()
                                    }
                                )
                            }
                        }
                    }

                }

                // 底栏浮层：真正叠在内容之上（玻璃才有东西可映射）。
                // 各滚动页因此需要额外的底部留白，避免最后一条被胶囊盖住。
                if (overlay == null) {
                    Column(
                        Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                    ) {
                        // 正在播放时常驻迷你条（切标签页也不断）
                        if (playback.current != null) {
                            MiniPlayerBar(
                                playback = playback,
                                onOpen = { showNowPlaying = true },
                                onToggle = musicVm::togglePlay,
                                onNext = musicVm::next,
                                onQuit = musicVm::quitPlayback
                            )
                        }
                        BottomBar(
                            selected = tab,
                            onSelect = { tab = it },
                            hazeState = hazeState
                        )
                    }
                } else {
                    Box(Modifier.align(Alignment.BottomCenter).navigationBarsPadding())
                }

                // ---------------------------------------------------------------- 弹窗层
                // 渲染顺序 = 层级顺序。
                // 只有「任务详情」是整页，打开时必须把操作页藏掉（否则两个整页叠一起）。
                // 其余二级（重命名 / 保存位置 / 限速 / 分享率 / 分类 / 标签 / Tracker / 删除确认）
                // 都是居中弹窗，**必须让操作页继续在底下当背景** —— 以前这里一起藏掉了，
                // 弹窗背后就露出种子列表（用户反馈：点更改保存位置背景跳回种子列表）。
                if (actionTask != null && detailTask == null) {
                    val task = state.tasks.firstOrNull { it.id == actionTask?.id } ?: actionTask!!
                    TaskActionsScreen(
                        task = task,
                        isQb = task.serverType == ServerType.QBITTORRENT,
                        onBack = { actionTask = null },
                        onOpenDetail = { detailTask = task },
                        onAction = { action ->
                            actionTask = null
                            vm.performAction(task, action)
                        },
                        onAutoManagement = {
                            actionTask = null
                            vm.performBatch(
                                task.serverId,
                                BatchAction.AUTO_MANAGEMENT_ON,
                                listOf(task.hash)
                            )
                        },
                        onEdit = { mode -> editTask = task to mode },
                        onOpenTrackers = {
                            vm.openTrackers(task)
                            trackerTask = task
                        }
                    )
                }

                // Tracker 列表（叠在操作弹窗之上；关掉回到操作弹窗）
                trackerTask?.let { source ->
                    val task = state.tasks.firstOrNull { it.id == source.id } ?: source
                    TrackerListDialog(
                        task = task,
                        state = state.trackers,
                        onReload = { vm.reloadTrackers(task) },
                        onEdit = { entry, newUrl -> vm.editTracker(task, entry, newUrl) },
                        onAdd = { newUrl -> vm.addTracker(task, newUrl) },
                        onRemove = { entry -> vm.removeTracker(task, entry) },
                        onClose = {
                            vm.closeTrackers()
                            trackerTask = null
                        }
                    )
                }

                detailTask?.let { source ->
                    val task = state.tasks.firstOrNull { it.id == source.id } ?: source
                    TorrentDetailScreen(
                        task = task,
                        serverName = state.servers.firstOrNull { it.id == task.serverId }
                            ?.displayName ?: "",
                        onBack = { detailTask = null },
                        onAction = { action ->
                            vm.performAction(task, action)
                            // 删掉之后上一层操作菜单不能挂着已不存在的任务
                            if (action == TorrentAction.DELETE || action == TorrentAction.DELETE_WITH_FILES) {
                                detailTask = null
                                actionTask = null
                            }
                        },
                        loadPoster = mpVm::posterForTitle
                    )
                }

                editTask?.let { (source, mode) ->
                    val task = state.tasks.firstOrNull { it.id == source.id } ?: source
                    TaskEditDialog(
                        task = task,
                        mode = mode,
                        isQb = task.serverType == ServerType.QBITTORRENT,
                        categories = state.categories[task.serverId].orEmpty(),
                        tags = state.tags[task.serverId].orEmpty(),
                        onClose = {
                            // 关掉弹窗回到「种子操作」整页，不要掉回种子列表
                            editTask = null
                        },
                        onLoadTaxonomy = { vm.loadTaxonomy(task.serverId) },
                        onRename = { vm.renameTask(task, it) },
                        onLocation = { vm.moveTask(task, it) },
                        onCategory = { name, create, path ->
                            vm.assignCategory(task, name, create, path)
                        },
                        onTags = { list, append -> vm.assignTags(task, list, append) },
                        onSpeed = { downloadKb, uploadKb ->
                            vm.setTaskSpeedLimit(task, downloadKb, uploadKb)
                        },
                        onShare = { ratioMode, ratio ->
                            vm.setTaskShareLimit(task, ratioMode, ratio)
                        }
                    )
                }

                if (addOpen) {
                    val server = state.servers.firstOrNull { it.id == addServerId }
                    if (server != null) {
                        TorrentAddDialog(
                            server = server,
                            defaultSavePath = state.snapshots[server.id]?.defaultSavePath.orEmpty(),
                            categories = state.categories[server.id].orEmpty(),
                            state = state.addTorrent,
                            onDismiss = {
                                vm.clearAddTorrentState()
                                addOpen = false
                            },
                            onLoadTaxonomy = { vm.loadTaxonomy(server.id) },
                            onSubmit = { request -> vm.addTorrent(server.id, request) },
                            onClearState = vm::clearAddTorrentState,
                            onDone = { addOpen = false }
                        )
                    }
                }

                if (serverEditOpen) {
                    ServerEditDialog(
                        existing = state.servers.firstOrNull { it.id == serverEditId },
                        onDismiss = { serverEditOpen = false },
                        onSave = {
                            vm.upsertServer(it)
                            serverEditOpen = false
                        },
                        onDelete = {
                            vm.deleteServer(it)
                            serverEditOpen = false
                        },
                        onTest = { vm.testConnection(it) }
                    )
                }

                if (mpEditOpen) {
                    MpServerEditDialog(
                        existing = mpEditServer,
                        activeId = mpVm.state.activeServerId,
                        onDismiss = {
                            mpEditOpen = false
                            mpEditServer = null
                        },
                        onSave = {
                            mpVm.upsertServer(it)
                            mpEditOpen = false
                            mpEditServer = null
                        },
                        onDelete = {
                            mpVm.deleteServer(it)
                            mpEditOpen = false
                            mpEditServer = null
                        },
                        onTest = mpVm::testServer,
                        onMakeActive = { mpVm.selectServer(it) }
                    )
                }

                if (showNowPlaying) {
                    BackHandler { showNowPlaying = false }
                    NowPlayingScreen(
                        playback = playback,
                        favorite = (playback.current?.id ?: -1L) in musicState.favoriteIds,
                        onClose = { showNowPlaying = false },
                        onToggle = musicVm::togglePlay,
                        onNext = musicVm::next,
                        onPrevious = musicVm::previous,
                        onSeek = musicVm::seekTo,
                        onVolumeChange = musicVm::setVolume,
                        onToggleFavorite = {
                            playback.current?.let { musicVm.toggleFavorite(it) }
                        },
                        onCycleRepeat = musicVm::cycleRepeatMode
                    )
                }

                (state.toast ?: mpVm.state.toast ?: musicState.toast)?.let { message ->
                    Box(
                        Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = 110.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color(0xEE1C1C1E))
                            .padding(horizontal = 16.dp, vertical = 10.dp)
                    ) {
                        Text(message, color = Color.White, fontSize = 13.sp)
                    }
                }
            }
        }
    }
}

/**
 * 底部标签栏：玻璃光效悬浮胶囊。
 *
 * 立体感由五层叠出：竖向渐变底（上亮下沉）+ 渐变高光描边（受光边 / 背光边）
 * + 双层柔阴影（抬升投影 + 接触阴影）+ 跟随选中项的青蓝彩色光斑
 * + 选中项凸起小胶囊。全程静态绘制，不开背景模糊：底栏背后是纯色页面，
 * 真模糊看不出差别还费帧，鸿蒙端也有 backgroundBlurStyle 闪退的前科。
 */
@Composable
private fun BottomBar(
    selected: Tab,
    onSelect: (Tab) -> Unit,
    hazeState: HazeState
) {
    val colors = LocalMptColors.current
    val isDark = colors.isDark

    // 光斑中心跟随选中项：用比例而非绝对 dp，任何屏宽都能对准
    val selectedIndex = Tab.entries.indexOf(selected).coerceAtLeast(0)
    val targetFraction = (selectedIndex + 0.5f) / Tab.entries.size
    val glowFraction by animateFloatAsState(
        targetValue = targetFraction,
        animationSpec = tween(260),
        label = "bottomBarGlow"
    )

    // 底子交给 Haze 的模糊。这里几乎不加色，只留一丝「上亮下沉」的厚度感 ——
    // 玻璃要透，靠的是背后的模糊 + 边缘高光，不是往里填颜色。
    val fillTop = if (isDark) Color.White.copy(alpha = 0.05f) else Color.White.copy(alpha = 0.10f)
    val fillBottom = if (isDark) Color.Black.copy(alpha = 0.08f) else Color.White.copy(alpha = 0.00f)
    val rimTop = if (isDark) Color.White.copy(alpha = 0.20f) else Color.White.copy(alpha = 0.95f)
    val rimBottom = if (isDark) Color.Black.copy(alpha = 0.38f) else Color(0xFF8A99B2).copy(alpha = 0.26f)

    Box(
        Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(start = 16.dp, end = 16.dp, top = 6.dp, bottom = 8.dp)
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .softShadow(28.dp, intensity = 1f, isDark = isDark)
                .clip(RoundedCornerShape(28.dp))
                // 真背景模糊：采样底下的内容做高斯模糊 —— 这才是「背景映射到玻璃」的来源。
                // 底栏浮层化（见 AppRoot）之后才有内容可采样，之前它在 Column 里占位、背后是纯色。
                .hazeEffect(state = hazeState) {
                    style = HazeStyle(
                        backgroundColor = Color.Transparent,
                        tints = listOf(
                            HazeTint(
                                // 只给很轻的一层白雾保证文字可读，太重就变成「磨砂板」不透光了
                                if (isDark) Color(0xFF1E1E24).copy(alpha = 0.28f)
                                else Color.White.copy(alpha = 0.16f)
                            )
                        ),
                        blurRadius = 26.dp,
                        noiseFactor = 0.02f
                    )
                }
                .drawBehind {
                    val capsule = Path().apply {
                        addRoundRect(RoundRect(0f, 0f, size.width, size.height, CornerRadius(28.dp.toPx())))
                    }
                    // 1) 竖向渐变底（上亮下沉）
                    drawPath(
                        path = capsule,
                        brush = Brush.verticalGradient(listOf(fillTop, fillBottom))
                    )
                    // 2) 三色玻璃光斑：青 / 蓝 / 紫，中心跟着选中 Tab 平移，铺得比之前大且浓
                    val cx = size.width * glowFraction
                    drawPath(
                        path = capsule,
                        brush = Brush.radialGradient(
                            colors = listOf(
                                Color(0xFF35D6C6).copy(alpha = if (isDark) 0.10f else 0.09f),
                                Color.Transparent
                            ),
                            center = Offset(cx - size.width * 0.20f, size.height * 0.10f),
                            radius = size.width * 0.34f
                        )
                    )
                    drawPath(
                        path = capsule,
                        brush = Brush.radialGradient(
                            colors = listOf(
                                Color(0xFF4A90FF).copy(alpha = if (isDark) 0.11f else 0.10f),
                                Color.Transparent
                            ),
                            center = Offset(cx + size.width * 0.18f, size.height * 0.92f),
                            radius = size.width * 0.32f
                        )
                    )
                    drawPath(
                        path = capsule,
                        brush = Brush.radialGradient(
                            colors = listOf(
                                Color(0xFF9B7BFF).copy(alpha = if (isDark) 0.08f else 0.07f),
                                Color.Transparent
                            ),
                            center = Offset(size.width * 0.5f, 0f),
                            radius = size.width * 0.40f
                        )
                    )
                    // 3) 玻璃边缘：顶亮底暗描边。
                    //    原来这里还有一条「青→蓝→紫」的彩色色散高光线，实测在浅色玻璃上是一条突兀的绿线，
                    //    已去掉 —— 玻璃边缘只保留中性白高光，不再带任何彩度。
                    drawPath(
                        path = capsule,
                        brush = Brush.verticalGradient(listOf(rimTop, Color.Transparent, rimBottom)),
                        style = Stroke(width = 1.2.dp.toPx())
                    )
                }
                .padding(horizontal = 6.dp, vertical = 7.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Tab.entries.forEach { item ->
                val active = item == selected
                val itemShape = RoundedCornerShape(16.dp)
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .then(if (active) Modifier.shadow(
                            elevation = 7.dp,
                            shape = RoundedCornerShape(16.dp),
                            ambientColor = Palette.blue.copy(alpha = if (isDark) 0.40f else 0.24f),
                            spotColor = Palette.blue.copy(alpha = if (isDark) 0.40f else 0.24f)
                        ) else Modifier)
                        .drawBehind {
                            if (active) {
                                val base = Path().apply {
                                    addRoundRect(RoundRect(0f, 0f, size.width, size.height, CornerRadius(16.dp.toPx())))
                                }
                                drawPath(
                                    path = base,
                                    brush = Brush.verticalGradient(
                                        if (isDark) {
                                            listOf(Color(0xFF3A5C86), Color(0xFF26446C))
                                        } else {
                                            listOf(Color.White.copy(alpha = 0.98f), Color(0xFFDCEAFF))
                                        }
                                    )
                                )
                                drawPath(
                                    path = base,
                                    brush = Brush.verticalGradient(
                                        listOf(
                                            if (isDark) Color.White.copy(alpha = 0.22f) else Color.White,
                                            Color.Transparent
                                        )
                                    ),
                                    style = Stroke(width = 0.8.dp.toPx())
                                )
                            }
                        }
                        .clip(itemShape)
                        .clickable { onSelect(item) }
                        .padding(vertical = 5.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Icon(
                        item.icon,
                        contentDescription = item.label,
                        tint = if (active) Palette.blue else colors.textSecondary,
                        modifier = Modifier.size(21.dp)
                    )
                    Spacer(Modifier.height(3.dp))
                    Text(
                        item.label,
                        fontSize = 10.sp,
                        fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
                        color = if (active) Palette.blue else colors.textSecondary
                    )
                }
            }
        }
    }
}
