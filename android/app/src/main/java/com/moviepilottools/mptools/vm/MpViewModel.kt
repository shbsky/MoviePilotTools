package com.moviepilottools.mptools.vm

import android.app.Application
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.moviepilottools.mptools.data.ConfigStore
import com.moviepilottools.mptools.data.CpuSample
import com.moviepilottools.mptools.data.HeroCache
import com.moviepilottools.mptools.data.toHeroCacheItem
import com.moviepilottools.mptools.data.toMpMedia
import com.moviepilottools.mptools.data.MpDiscoverChannel
import com.moviepilottools.mptools.data.MpDownloader
import com.moviepilottools.mptools.data.MpDownloaderInfo
import com.moviepilottools.mptools.data.MpMedia
import com.moviepilottools.mptools.data.MpMemoryInfo
import com.moviepilottools.mptools.data.MpResource
import com.moviepilottools.mptools.data.MpSavePath
import com.moviepilottools.mptools.data.MpServer
import com.moviepilottools.mptools.data.MpSite
import com.moviepilottools.mptools.data.MpSiteCategory
import com.moviepilottools.mptools.data.MpSiteUserData
import com.moviepilottools.mptools.data.MpStatistic
import com.moviepilottools.mptools.data.MpStorage
import com.moviepilottools.mptools.data.MpSubscribe
import com.moviepilottools.mptools.data.MpSystemInfo
import com.moviepilottools.mptools.data.MemorySample
import com.moviepilottools.mptools.data.ResourceFilter
import com.moviepilottools.mptools.data.SiteSort
import com.moviepilottools.mptools.net.ApiException
import com.moviepilottools.mptools.net.EndpointResolver
import com.moviepilottools.mptools.net.MediaPosterResolver
import com.moviepilottools.mptools.net.MoviePilotClient
import com.moviepilottools.mptools.net.SiteIconStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

object MpChannels {
    val all = listOf(
        MpDiscoverChannel("douban_showing", "豆瓣热映", "正在上映", "douban_showing"),
        MpDiscoverChannel("douban_movie_hot", "热门电影", "豆瓣实时热门", "douban_movie_hot"),
        MpDiscoverChannel("douban_tv_hot", "热门剧集", "豆瓣实时热门", "douban_tv_hot"),
        MpDiscoverChannel("douban_movies", "豆瓣电影", "按评价排序", "douban_movies", "sort=R"),
        MpDiscoverChannel("douban_tvs", "豆瓣剧集", "按评价排序", "douban_tvs", "sort=R"),
        MpDiscoverChannel("douban_movie_top250", "TOP250", "豆瓣电影榜", "douban_movie_top250"),
        MpDiscoverChannel("douban_tv_weekly_chinese", "华语口碑", "每周口碑榜", "douban_tv_weekly_chinese"),
        MpDiscoverChannel("douban_tv_weekly_global", "全球口碑", "每周口碑榜", "douban_tv_weekly_global"),
        MpDiscoverChannel("douban_tv_animation", "番剧", "豆瓣动画榜", "douban_tv_animation"),
        MpDiscoverChannel("tmdb_trending", "TMDB 趋势", "本周流行", "tmdb_trending"),
        MpDiscoverChannel("tmdb_movies", "TMDB 电影", "按热度", "tmdb_movies", "sort_by=popularity.desc"),
        MpDiscoverChannel("tmdb_tvs", "TMDB 剧集", "按热度", "tmdb_tvs", "sort_by=popularity.desc")
    )
}

/**
 * 「站点」标签页的全部状态。
 *
 * 全部收在一个字段里而不是往 [MpUiState] 里加十几个散字段：那个 data class 有 40 多处
 * `state.copy(...)`，每加一个字段就多一个漏掉的机会，漏一次就是「某个操作之后状态莫名清空」
 * 这种很难复现的 bug。放在一个字段里，只要不整体覆盖它就不会丢。
 */
data class MpSiteState(
    // ---- 站点列表 ----
    val sites: List<MpSite> = emptyList(),
    /** siteId → 个人数据（MP 按 domain 返回，这里已按站点对好） */
    val userData: Map<Int, MpSiteUserData> = emptyMap(),
    val loading: Boolean = false,
    val loaded: Boolean = false,
    val error: String? = null,
    /** 403/401：当前 API Token 不是管理员，站点接口一律拒绝 */
    val permissionDenied: Boolean = false,
    /** 404：MP 版本太老，没有站点接口 */
    val degraded: Boolean = false,

    // ---- 站点详情（种子浏览） ----
    val openSite: MpSite? = null,
    val searchInput: String = "",
    /** 已提交的关键词（和输入框分开，避免边打字边发请求） */
    val keyword: String = "",
    val categories: List<MpSiteCategory> = emptyList(),
    /**
     * 当前选中的分类。**单选**：点一个换一个，再点同一个＝退回「全部」。
     *
     * 之前做成最多选 3 个的多选，一是和 MP 网页版的交互不一致（用户会以为点第二个是替换），
     * 二是站点索引器对 `cat` 基本只认单值，传逗号拼接的多值反而更容易被忽略。
     */
    val selectedCats: List<String> = emptyList(),
    /** 客户端排序（MP 接口没有排序参数） */
    val sort: SiteSort = SiteSort.LATEST,
    /**
     * 「全部」第一页的种子 key 集合。
     *
     * 用来判断站点到底有没有真的按 `cat` 过滤：选分类后回来的第一页如果和这份完全一致，
     * 说明 MP/站点忽略了 cat 参数（不少站点索引器不支持分类），UI 要如实告诉用户
     * 「这只是全部种子」，别让人以为筛选生效了。
     */
    val allPageKeys: Set<String> = emptySet(),
    /** 选了分类但站点没过滤 → 提示用户该站不支持分类筛选 */
    val catIgnored: Boolean = false,
    val torrents: List<MpResource> = emptyList(),
    /** 资源 key → 海报地址（识别是异步的，卡片先出、图后补） */
    val posters: Map<String, String> = emptyMap(),
    val browsing: Boolean = false,
    /** 已经等了多少秒（站点浏览可能 5~30s，要告诉用户不是在卡死） */
    val elapsedSeconds: Int = 0,
    val browseError: String? = null,
    val page: Int = 0,
    val hasMore: Boolean = true,
    /**
     * 连续几页「返回了内容但没带来新种子」。
     *
     * 不少 PT 站对越界的 page 会照旧返回首页那批种子，光看「返回非空」会一直翻下去，
     * 连续 3 次没长进就认定到底，别让列表无限转圈。
     */
    val stalledPages: Int = 0,
    /** 识别接口连续失败后整站关掉海报，别让翻页一直挂着请求 */
    val postersDisabled: Boolean = false
) {
    val totalSeeding: Int get() = userData.values.sumOf { it.seeding }
    val totalUpload: Long get() = userData.values.sumOf { it.upload }
    val totalDownload: Long get() = userData.values.sumOf { it.download }
    val hasAnyUserData: Boolean get() = userData.isNotEmpty()

    /** 列表实际展示的顺序（排序是纯客户端的，不改动 [torrents] 本身，翻页合并逻辑才不会被排序搅乱） */
    val sortedTorrents: List<MpResource> get() = sort.apply(torrents)

    /** 分类没选时 cat 为空，那「全部」就是选中态 */
    val isAllCategories: Boolean get() = selectedCats.isEmpty()
}

/**
 * 「订阅活动 / 文件统计」这类只读信息的展示载体：一个弹窗装下，不往主状态里塞十几个字段。
 */
data class SubscribePanel(
    val title: String,
    val loading: Boolean = false,
    val lines: List<String> = emptyList(),
    val error: String? = null
)

/**
 * 仪表盘实时数据的聚合状态。
 *
 * 单独装一个字段，避免 MpUiState 那几十处 copy() 漏更新。
 * 失败时只改写错误文案、保留上一次数值和曲线（stale-on-error）。
 */
data class DashboardLiveState(
    val downloader: MpDownloaderInfo = MpDownloaderInfo(),
    val speedError: String? = null,
    val lastSpeedAt: Long = 0L,
    val cpu: Float = Float.NaN,
    val cpuSamples: List<CpuSample> = emptyList(),
    val memory: MpMemoryInfo? = null,
    val memorySamples: List<MemorySample> = emptyList(),
    val system: MpSystemInfo? = null,
    val systemDenied: Boolean = false,
    val systemError: String? = null
) {
    /** CPU 最近 N 分钟均值；窗口内没样本时返回 NaN。 */
    fun cpuAverage(windowMs: Long, nowMs: Long = System.currentTimeMillis()): Float {
        val inWindow = cpuSamples.filter { nowMs - it.atMs <= windowMs }
        if (inWindow.isEmpty()) return Float.NaN
        return (inWindow.sumOf { it.value.toDouble() } / inWindow.size).toFloat()
    }
}

data class MpUiState(
    val servers: List<MpServer> = emptyList(),
    val activeServerId: String? = null,
    val channel: MpDiscoverChannel = MpChannels.all.first(),
    val items: List<MpMedia> = emptyList(),
    val page: Int = 1,
    val loading: Boolean = false,
    val loadingMore: Boolean = false,
    val hasMore: Boolean = true,
    val error: String? = null,
    val toast: String? = null,

    // 搜索
    val searchQuery: String = "",
    val searchResults: List<MpMedia> = emptyList(),
    val searching: Boolean = false,
    val searchActive: Boolean = false,

    // 详情
    val detail: MpMedia? = null,
    val detailLoading: Boolean = false,
    val credits: List<MoviePilotClient.Person> = emptyList(),

    // 资源
    val resources: List<MpResource> = emptyList(),
    val resourcesLoading: Boolean = false,
    val resourceError: String? = null,
    /** 是否已经手动发起过搜索：用来区分「还没搜」和「搜了但没结果」 */
    val resourceSearched: Boolean = false,
    val searchStage: String = "",
    val filter: ResourceFilter = ResourceFilter(),
    val downloaders: List<MpDownloader> = emptyList(),
    val savePaths: List<MpSavePath> = emptyList(),
    /** 上次投递用的下载器 / 保存路径，下次打开面板默认选中（null = 自动） */
    val lastDownloader: String? = null,
    val lastSavePath: String? = null,
    /**
     * 投递结果（面板就地显示，不靠一闪而过的 toast）。
     *
     * 以前提交完只发一个 toast 就关面板，用户根本不知道到底推没推成功 —— 现在面板留在原地，
     * 先转圈「正在提交」，回来再切成「已推送 / 失败原因」。
     */
    val downloadSubmitting: Boolean = false,
    val downloadError: String? = null,
    val downloadDone: String? = null,

    // 订阅
    val subscribes: List<MpSubscribe> = emptyList(),
    val subscribesLoading: Boolean = false,
    /** 订阅设置里的「优先级规则组」选项（MP 的过滤规则组名称） */
    val subscribeRuleGroups: List<String> = emptyList(),
    /**
     * MP 系统设置里勾选的「订阅站点」id；null = 这台 MP 没这项设置（不限制），
     * 空集合 = 用户一个都没勾。编辑订阅的站点选择器只列这一批。
     */
    val rssSiteIds: Set<Int>? = null,
    /** 订阅活动 / 文件统计弹窗内容；null = 没打开 */
    val subscribePanel: SubscribePanel? = null,

    // 仪表盘媒体库统计（电影/电视剧/剧集/用户）
    val stats: MpStatistic? = null,
    val statsLoading: Boolean = false,
    val statsError: String? = null,

    // 仪表盘「剩余空间」：优先用 MP 的存储数据（已按物理盘去重）
    val storage: MpStorage? = null,

    // 仪表盘实时速率 / CPU / 内存 / 系统信息
    val live: DashboardLiveState = DashboardLiveState(),

    // 首屏 Hero 海报轮播：独立于「发现/探索」分页，互不污染
    val heroPosters: List<MpMedia> = emptyList(),
    val heroLoading: Boolean = false,

    // 站点（只读同步 MP）
    val site: MpSiteState = MpSiteState()
) {
    val server: MpServer? get() = servers.firstOrNull { it.id == activeServerId }

    val filteredResources: List<MpResource> get() = filter.apply(resources)

    fun isSubscribed(media: MpMedia?): Boolean {
        if (media == null) return false
        return subscribes.any { sub ->
            sub.name.equals(media.title, ignoreCase = true) &&
                (media.season == null || sub.season == null || sub.season == media.season)
        }
    }

    val sites: List<String> get() = resources.map { it.siteName }.distinct().sorted()
    val resolutions: List<String>
        get() = resources.map { it.resolution }.distinct().sortedBy { listOf("4K", "1080p", "720p", "480p", "其他").indexOf(it) }
    val qualities: List<String> get() = resources.map { it.quality }.distinct().sorted()
    val codecs: List<String> get() = resources.map { it.codec }.distinct().sorted()

    /** 效果 / 字幕标签（中字、国语、特效…），按出现次数从多到少排 */
    val subtitles: List<String>
        get() = resources.flatMap { it.extraLabels }
            .groupingBy { it }.eachCount()
            .entries.sortedByDescending { it.value }
            .map { it.key }

    /** 制作组（小组名），空名丢掉 */
    val groups: List<String> get() = resources.map { it.group }.filter { it.isNotEmpty() }.distinct().sorted()

    /** 促销档次：免费 / 折扣 / 2X，固定顺序 */
    val promotions: List<String>
        get() {
            val seen = resources.map { it.promotionTier }.filter { it != "无促销" }.toSet()
            return listOf("免费", "折扣", "2X").filter { it in seen }
        }
}

class MpViewModel(application: Application) : AndroidViewModel(application) {

    private companion object {
        /**
         * 单次站点浏览最多等多久。
         *
         * OkHttp 的 slowClient 是 180 秒 callTimeout，但真实经验是：超过 2 分半的站点
         * 基本就是抓不到（Cookie 失效 / Cloudflare 拦截 / 站点挂了），继续干等只会让用户
         * 以为 App 卡死。到点自己收手并给出可执行的下一步。
         */
        const val SITE_BROWSE_TIMEOUT_SECONDS = 150
    }

    private val TAG = "MoviePilot"
    private val store = ConfigStore(application)
    private var persisted = store.load()

    var state by mutableStateOf(
        MpUiState(
            servers = persisted.mpServers,
            activeServerId = persisted.activeMpServerId ?: persisted.mpServers.firstOrNull()?.id
        )
    )
        private set

    private var statsJob: Job? = null
    private var statsTimerJob: Job? = null
    private var statsRetryJob: Job? = null

    // ---- 仪表盘实时数据轮询 ----
    private var liveTickerJob: Job? = null
    private val livePollJobs = HashMap<String, Job>()
    private val liveNextAt = HashMap<String, Long>()
    private val liveFailStreak = HashMap<String, Int>()
    private val liveInFlight = HashSet<String>()
    private val liveStopped = HashSet<String>()

    private var siteJob: Job? = null
    private var browseJob: Job? = null
    private var browseTicker: Job? = null
    /** 识别接口连续「一条都没成功」的次数，达到 3 次就关掉整站海报 */
    private var posterFailStreak = 0

    init {
        // 首屏 Hero：先从缓存还原（首帧即有图），再联网刷新
        restoreHeroFromCache()
        if (state.server != null) {
            loadDiscover(refresh = true)
            loadSubscribes(silent = true)
            loadStats()
            loadHeroPosters()
        }
        startStatsTimer()
        startLiveTicker()
    }

    /**
     * 拉媒体库统计给仪表盘用。
     *
     * MP 的接口不便宜（要遍历每个媒体库），所以只在切服务器、进 App、定时 5 分钟时拉，
     * 失败就保留上一次的数字，不清空。
     *
     * [clearError] 为 true 时先抹掉上一次的失败提示——解锁回到 App 时用，
     * 避免用户一睁眼就看到几分钟前息屏期间那条连接失败。
     */
    fun loadStats(clearError: Boolean = false) {
        if (clearError && state.statsError != null) {
            state = state.copy(statsError = null)
        }
        val client = client() ?: run {
            statsRetryJob?.cancel()
            statsRetryJob = null
            state = state.copy(stats = null, statsError = null, statsLoading = false, storage = null)
            return
        }
        // 用 job 是否还活着判断在途请求，不能只看 statsLoading：
        // 切服务器时旧任务被 cancel，statsLoading 会永久停在 true，之后就再也不刷新了
        if (statsJob?.isActive == true) return
        statsRetryJob?.cancel()
        statsRetryJob = null
        statsJob = viewModelScope.launch {
            state = state.copy(statsLoading = true)
            // 存储空间单独拉：它比遍历媒体库便宜得多，statistic 失败也不该拖累它
            val storage = runCatching { client.storage() }.getOrNull()
            state = state.copy(storage = storage ?: state.storage)
            val result = runCatching { client.statistic() }
            applyStats(result)
            if (result.isFailure) scheduleStatsRetry()
        }
    }

    private fun applyStats(result: Result<MpStatistic>) {
        result
            .onSuccess {
                state = state.copy(stats = it, statsLoading = false, statsError = null)
            }
            .onFailure {
                state = state.copy(statsLoading = false, statsError = humanizeStatsError(it))
            }
    }

    /**
     * 失败后 15s / 30s / 60s 各补一次。
     *
     * 原来失败只能等下一个 5 分钟，而失败最常发生在「息屏一晚上刚解锁、Wi-Fi 还在握手」
     * 这种几秒钟的窗口里，结果就是那条红字要挂好几分钟才消，看着像永远消不掉。
     */
    private fun scheduleStatsRetry() {
        if (statsRetryJob?.isActive == true) return
        statsRetryJob = viewModelScope.launch {
            var waitMs = 15_000L
            repeat(3) {
                delay(waitMs)
                waitMs *= 2
                val client = client() ?: return@launch
                if (statsJob?.isActive == true) return@launch
                state = state.copy(statsLoading = true)
                val result = runCatching { client.statistic() }
                applyStats(result)
                if (result.isSuccess) return@launch
            }
        }
    }

    /**
     * OkHttp 的原始错误长这样：
     * `failed to connect to /192.168.1.5 (port 3000) from /192.168.1.90 (port 45572) after 6000ms`
     * 直接摊在仪表盘上没人看得懂，转成人话。
     */
    private fun humanizeStatsError(err: Throwable): String {
        val msg = err.message.orEmpty().trim()
        val target = Regex("""failed to connect to /?(\d{1,3}(?:\.\d{1,3}){3}) \(port (\d+)\)""").find(msg)
        if (target != null) {
            return "连不上 ${target.groupValues[1]}:${target.groupValues[2]}，检查手机与服务器是否在同一网络"
        }
        if (msg.contains("Unable to resolve host", true)) return "服务器地址解析失败，检查域名是否正确"
        if (msg.contains("timed out", true) || msg.contains("timeout", true)) return "连接超时，稍后自动重试"
        return msg.ifBlank { "连接失败" }
    }

    /** 进前台（含解锁后回到 App）：恢复轮询并立刻重拉一次，别让用户先看到旧错误 */
    fun onForeground() {
        startStatsTimer()
        // 回前台立刻重拉实时数据：息屏期间的到期时间已经没意义了
        liveNextAt.keys.forEach { liveNextAt[it] = 0L }
        startLiveTicker()
        if (state.server != null) {
            loadStats(clearError = true)
            loadHeroPosters(force = true)
        }
    }

    /** 退后台：停掉轮询。息屏时 Wi-Fi 常被系统挂起，继续轮询只会刷出一堆假的连接失败 */
    fun onBackground() {
        statsTimerJob?.cancel()
        statsTimerJob = null
        statsRetryJob?.cancel()
        statsRetryJob = null
        stopLivePolling(clearState = false)
    }

    private fun startStatsTimer() {
        if (statsTimerJob?.isActive == true) return
        // 媒体库数量变得慢，5 分钟对一次就够，不用跟着下载器刷新
        statsTimerJob = viewModelScope.launch {
            while (isActive) {
                delay(300_000L)
                if (state.server != null) loadStats()
            }
        }
    }

    // ---------- 仪表盘实时数据（速率 / CPU / 内存 / 系统） ----------

    /**
     * 不用四个 timer 各跑各的：一个 1 秒心跳检查各项到期时间，
     * 每项自己记下次轮询点和失败退避。切服务器 / 息屏时统一停掉，避免旧服务器的数据串台。
     */
    private fun startLiveTicker() {
        if (liveTickerJob?.isActive == true) return
        liveTickerJob = viewModelScope.launch {
            while (isActive) {
                delay(1_000L)
                if (state.server == null) continue
                val now = System.currentTimeMillis()

                if ("speed" !in liveStopped && now >= (liveNextAt["speed"] ?: 0L)) {
                    pollLive(
                        key = "speed",
                        intervalMs = 5_000L,
                        call = { it.dashboardDownloader() },
                        onSuccess = { info ->
                            state = state.copy(
                                live = state.live.copy(
                                    downloader = info,
                                    speedError = null,
                                    lastSpeedAt = System.currentTimeMillis()
                                )
                            )
                        },
                        onFailure = { message, _ ->
                            state = state.copy(live = state.live.copy(speedError = message))
                        }
                    )
                }

                if ("cpu" !in liveStopped && now >= (liveNextAt["cpu"] ?: 0L)) {
                    pollLive(
                        key = "cpu",
                        intervalMs = 5_000L,
                        call = { it.dashboardCpu() },
                        onSuccess = { value ->
                            if (!value.isNaN()) {
                                val sample = CpuSample(System.currentTimeMillis(), value)
                                state = state.copy(
                                    live = state.live.copy(
                                        cpu = value,
                                        // 保留 15 分钟窗口（1m/5m/15m 均值用），图表只取最后 30 点
                                        cpuSamples = (state.live.cpuSamples + sample).takeLast(180)
                                    )
                                )
                            }
                        },
                        onFailure = { _, _ -> Unit }
                    )
                }

                if ("memory" !in liveStopped && now >= (liveNextAt["memory"] ?: 0L)) {
                    pollLive(
                        key = "memory",
                        intervalMs = 10_000L,
                        call = { it.dashboardMemory() },
                        onSuccess = { info ->
                            val sample = MemorySample(
                                atMs = System.currentTimeMillis(),
                                used = info.used,
                                cached = info.cached,
                                available = info.available
                            )
                            state = state.copy(
                                live = state.live.copy(
                                    memory = info,
                                    memorySamples = (state.live.memorySamples + sample).takeLast(30)
                                )
                            )
                        },
                        onFailure = { _, _ -> Unit }
                    )
                }

                if ("system" !in liveStopped && now >= (liveNextAt["system"] ?: 0L)) {
                    pollLive(
                        key = "system",
                        intervalMs = 60_000L,
                        call = { it.dashboardSystem() },
                        onSuccess = { info ->
                            state = state.copy(
                                live = state.live.copy(
                                    system = info,
                                    systemDenied = false,
                                    systemError = null
                                )
                            )
                        },
                        onFailure = { message, error ->
                            val code = (error as? ApiException)?.code
                            val denied = code == 401 || code == 403
                            state = state.copy(
                                live = state.live.copy(
                                    systemDenied = denied,
                                    systemError = if (denied) null else message
                                )
                            )
                        }
                    )
                }
            }
        }
    }

    /** 单项请求：in-flight 守卫 + 指数退避（最多 8 倍）+ stale-on-error。 */
    private fun <T> pollLive(
        key: String,
        intervalMs: Long,
        call: suspend (MoviePilotClient) -> T,
        onSuccess: (T) -> Unit,
        onFailure: (String, Throwable) -> Unit
    ) {
        if (!liveInFlight.add(key)) return
        val client = client() ?: run {
            liveInFlight.remove(key)
            return
        }
        livePollJobs[key]?.cancel()
        livePollJobs[key] = viewModelScope.launch {
            val result = runCatching { call(client) }
            result.onSuccess(onSuccess)
            var denied = false
            result.onFailure { error ->
                denied = (error as? ApiException)?.code.let { it == 401 || it == 403 }
                onFailure(humanizeStatsError(error), error)
            }
            liveInFlight.remove(key)
            if (denied) {
                // 认证失败不是网络抖动，重试一万次也不会变好，直接停这一项
                liveStopped.add(key)
                return@launch
            }
            val streak = if (result.isSuccess) 0 else (liveFailStreak[key] ?: 0) + 1
            liveFailStreak[key] = streak
            val backoff = if (streak <= 1) 1 else minOf(8, 1 shl (streak - 1))
            liveNextAt[key] = System.currentTimeMillis() + intervalMs * backoff
        }
    }

    private fun stopLivePolling(clearState: Boolean) {
        liveTickerJob?.cancel()
        liveTickerJob = null
        livePollJobs.values.forEach { it.cancel() }
        livePollJobs.clear()
        liveInFlight.clear()
        liveNextAt.clear()
        liveFailStreak.clear()
        liveStopped.clear()
        if (clearState) state = state.copy(live = DashboardLiveState())
    }

    /** 切服务器 / 增删服务器：旧采样必须全部作废，否则会把 A 机器的曲线画到 B 机器上。 */
    private fun resetLive() = stopLivePolling(clearState = true)

    override fun onCleared() {
        stopLivePolling(clearState = false)
        super.onCleared()
    }

    private fun client(): MoviePilotClient? = state.server?.let { MoviePilotClient(it) }

    // ---------- 首屏 Hero 海报轮播 ----------
    // 独立于「发现/探索」的 items/channel/page：这里直接调 recommend 拿海报，
    // 绝不碰那套分页状态，避免把 MoviePilot 页的片单冲掉。图片本身由 Coil 磁盘缓存负责。

    private var heroLoadedKey: String? = null

    /** 从持久化缓存还原海报——开 App 首帧即有图，弱网/离线不空白。 */
    private fun restoreHeroFromCache() {
        val cache: HeroCache = persisted.heroCache ?: return
        if (cache.items.isEmpty()) return
        state = state.copy(heroPosters = cache.items.map { it.toMpMedia() })
    }

    /**
     * 服务器就绪 / 切换时调用：先还原缓存，再联网刷新（每台 server 一次）。
     * 切到新服务器但缓存还是旧的 → 先清掉旧片单，避免显示别的服务器的海报。
     */
    fun loadHeroPosters(force: Boolean = false) {
        val server = state.server
        if (server == null || !server.isValid) return
        val key = server.id
        if (!force && key == heroLoadedKey && state.heroPosters.isNotEmpty()) return
        heroLoadedKey = key
        // 缓存不是这台服务器的 → 清掉旧图
        if (persisted.heroCache?.serverKey != key && !force) {
            state = state.copy(heroPosters = emptyList())
        }
        val client = MoviePilotClient(server)
        viewModelScope.launch {
            state = state.copy(heroLoading = true)
            val result = runCatching { client.recommend(MpChannels.all.first(), 1, 20) }.getOrNull()
            if (result != null) {
                // 优先挑有 backdrop 的横图；不够就用全部，最多 8 张
                val wide = result.filter { it.backdropUrl.isNotBlank() }
                val picked = (wide.ifEmpty { result }).take(8)
                if (picked.isNotEmpty()) {
                    state = state.copy(heroPosters = picked, heroLoading = false)
                    saveHeroCache(key, picked)
                    return@launch
                }
            }
            // 失败 / 空结果：保留旧图（stale-on-error），首帧缓存还在就不清空
            state = state.copy(heroLoading = false)
        }
    }

    /** 片单落盘（精简字段），下次开 App 首帧直接命中。 */
    private fun saveHeroCache(serverKey: String, items: List<MpMedia>) {
        persisted = persisted.copy(
            heroCache = HeroCache(
                serverKey = serverKey,
                fetchedAt = System.currentTimeMillis(),
                items = items.map { it.toHeroCacheItem() }
            )
        )
        store.save(persisted)
    }

    // ---------- 服务器 ----------

    fun upsertServer(server: MpServer) {
        val servers = state.servers.toMutableList()
        val index = servers.indexOfFirst { it.id == server.id }
        if (index >= 0) servers[index] = server else servers.add(server)
        persist(servers = servers, activeId = if (state.activeServerId == null) server.id else state.activeServerId)
        EndpointResolver.invalidate(server.id)
        resetSiteState()
        resetLive()
        loadDiscover(refresh = true)
        loadStats()
        loadHeroPosters(force = true)
        if (state.server != null) startLiveTicker()
    }

    fun deleteServer(id: String) {
        val servers = state.servers.filterNot { it.id == id }
        persist(servers = servers, activeId = state.activeServerId?.takeIf { it != id })
        EndpointResolver.invalidate(id)
        resetSiteState()
        resetLive()
        state = state.copy(detail = null, resources = emptyList())
        if (state.server != null) startLiveTicker()
    }

    fun selectServer(id: String?) {
        persist(servers = state.servers, activeId = id)
        state = state.copy(
            items = emptyList(),
            page = 1,
            hasMore = true,
            detail = null,
            resources = emptyList()
        )
        resetSiteState()
        resetLive()
        if (id != null) {
            loadDiscover(refresh = true)
            loadSubscribes(silent = true)
            loadStats()
            loadHeroPosters(force = true)
            startLiveTicker()
        } else {
            state = state.copy(stats = null, heroPosters = emptyList())
        }
    }

    private fun persist(servers: List<MpServer>, activeId: String?) {
        persisted = persisted.copy(mpServers = servers, activeMpServerId = activeId)
        store.save(persisted)
        state = state.copy(servers = servers, activeServerId = activeId)
    }

    /**
     * 从备份恢复后重建服务器列表。配置已由调用方写盘，这里只读回来：
     * 清掉旧的连接状态与海报缓存，重新探测新服务器。
     */
    fun reloadFromStore() {
        persisted = store.load()
        val servers = persisted.mpServers
        val activeId = persisted.activeMpServerId ?: servers.firstOrNull()?.id
        state = state.copy(
            servers = servers,
            activeServerId = activeId,
            stats = null,
            heroPosters = emptyList(),
            detail = null,
            searchResults = emptyList(),
            resources = emptyList()
        )
        if (servers.isNotEmpty()) {
            loadStats()
            loadHeroPosters(force = true)
            startLiveTicker()
        }
    }

    // ---------- 发现 ----------

    fun selectChannel(channel: MpDiscoverChannel) {
        if (state.channel.key == channel.key && state.items.isNotEmpty()) return
        state = state.copy(channel = channel, items = emptyList(), page = 1, hasMore = true, error = null)
        loadDiscover(refresh = true)
    }

    fun loadDiscover(refresh: Boolean = false) {
        val client = client() ?: return
        if (state.loading || state.loadingMore) return
        val nextPage = if (refresh) 1 else state.page + 1
        if (!refresh && !state.hasMore) return

        state = if (refresh) {
            state.copy(loading = true, error = null)
        } else {
            state.copy(loadingMore = true)
        }

        viewModelScope.launch {
            runCatching { client.recommend(state.channel, nextPage) }
                .onSuccess { list ->
                    val merged = if (refresh) list else (state.items + list).distinctBy { it.mediaId + it.season }
                    state = state.copy(
                        items = merged,
                        page = nextPage,
                        hasMore = list.size >= 20,
                        loading = false,
                        loadingMore = false,
                        error = null
                    )
                }
                .onFailure { error ->
                    state = state.copy(
                        loading = false,
                        loadingMore = false,
                        error = error.message ?: "加载失败"
                    )
                }
        }
    }

    // ---------- 搜索 ----------

    fun startSearch() {
        state = state.copy(searchActive = true)
    }

    fun exitSearch() {
        state = state.copy(searchActive = false, searchResults = emptyList(), searchQuery = "")
    }

    fun updateSearchQuery(text: String) {
        state = state.copy(searchQuery = text)
    }

    fun search() {
        val client = client() ?: return
        val keyword = state.searchQuery.trim()
        if (keyword.isEmpty()) return
        state = state.copy(searching = true)
        viewModelScope.launch {
            runCatching { client.searchMedia(keyword) }
                .onSuccess { list ->
                    state = state.copy(
                        searchResults = list.distinctBy { it.mediaId },
                        searching = false
                    )
                    if (list.isEmpty()) state = state.copy(toast = "没有搜到「$keyword」")
                }
                .onFailure {
                    state = state.copy(searching = false, toast = it.message ?: "搜索失败")
                }
        }
    }

    // ---------- 详情 ----------

    fun openDetail(media: MpMedia) {
        state = state.copy(
            detail = media,
            detailLoading = true,
            resources = emptyList(),
            resourceError = null,
            resourceSearched = false,
            filter = ResourceFilter(),
            credits = emptyList()
        )
        val client = client() ?: return
        viewModelScope.launch {
            val detail = runCatching { client.mediaDetail(media) }.getOrDefault(media)
            val credits = runCatching { client.credits(detail) }.getOrDefault(emptyList())
            state = state.copy(detail = detail, detailLoading = false, credits = credits)
        }
        // 只拉简介，不自动搜站点：用户想看资源时自己点「搜资源」
    }

    fun closeDetail() {
        state = state.copy(detail = null, resources = emptyList(), resourceError = null)
    }

    fun searchResources() {
        val client = client() ?: return
        val media = state.detail ?: return
        if (state.resourcesLoading) return

        state = state.copy(
            resourcesLoading = true,
            resourceSearched = true,
            resourceError = null,
            searchStage = "正在向各站点发起搜索…"
        )
        viewModelScope.launch {
            runCatching {
                client.searchResources(media) { batch, stage ->
                    state = state.copy(
                        resources = batch,
                        searchStage = stage.ifBlank { "已返回 ${batch.size} 个候选资源…" }
                    )
                }
            }.onSuccess { list ->
                state = state.copy(
                    resources = list,
                    resourcesLoading = false,
                    searchStage = "",
                    resourceError = if (list.isEmpty()) "未搜索到资源（检查 MoviePilot 的站点是否可用）" else null
                )
            }.onFailure { error ->
                state = state.copy(
                    resourcesLoading = false,
                    searchStage = "",
                    resourceError = error.message ?: "搜索失败"
                )
            }
        }
    }

    fun updateFilter(filter: ResourceFilter) {
        state = state.copy(filter = filter)
    }

    // ---------- 投递 ----------

    fun loadDownloadOptions() {
        val client = client() ?: return
        viewModelScope.launch {
            val downloaders = runCatching { client.downloaders() }.getOrDefault(emptyList())
            val paths = runCatching { client.savePaths() }.getOrDefault(emptyList())
            state = state.copy(downloaders = downloaders, savePaths = paths)
        }
    }

    fun download(resource: MpResource, downloader: String?, savePath: String?) {
        if (state.downloadSubmitting) return
        val client = client()
        if (client == null) {
            state = state.copy(
                downloadSubmitting = false,
                downloadDone = null,
                downloadError = "还没有配置 MoviePilot 服务器"
            )
            return
        }
        viewModelScope.launch {
            // 记住这次的选择（选了「自动」就记成 null，下次默认还是自动）
            state = state.copy(
                downloadSubmitting = true,
                downloadDone = null,
                downloadError = null,
                lastDownloader = downloader,
                lastSavePath = savePath
            )
            runCatching { withContext(Dispatchers.IO) { client.addDownload(resource, downloader, savePath) } }
                .onSuccess { downloadId ->
                    val target = downloader?.trim()?.takeIf { it.isNotEmpty() }
                        ?: "MoviePilot 默认下载器"
                    state = state.copy(
                        downloadSubmitting = false,
                        downloadDone = buildString {
                            append("已推送到 ").append(target)
                            if (downloadId.isNotBlank()) append("（任务 ").append(downloadId).append("）")
                        },
                        toast = "已提交到 MoviePilot"
                    )
                }
                .onFailure { error ->
                    state = state.copy(
                        downloadSubmitting = false,
                        downloadError = humanizeDownloadError(error)
                    )
                }
        }
    }

    /** 关掉投递面板时清结果，避免下一次打开还挂着上一次的「已推送」 */
    fun clearDownloadResult() {
        if (state.downloadSubmitting) return
        if (state.downloadDone == null && state.downloadError == null) return
        state = state.copy(downloadDone = null, downloadError = null)
    }

    private fun humanizeDownloadError(error: Throwable): String {
        val raw = error.message?.takeIf { it.isNotBlank() } ?: "未知错误"
        return when {
            error is java.net.SocketTimeoutException ->
                "提交超时：MP 没有在 3 分钟内响应，任务可能已经在下载器里建好了，先去下载器确认一下"
            raw.contains("timeout", ignoreCase = true) ->
                "提交超时：任务可能已经在下载器里建好了，先去下载器确认一下"
            raw.contains("Failed to connect", ignoreCase = true) ||
                raw.contains("Connection refused", ignoreCase = true) ->
                "连不上 MoviePilot：$raw"
            else -> raw
        }
    }

    // ---------- 订阅 ----------

    fun loadSubscribes(silent: Boolean = false) {
        val client = client()
        if (client == null) {
            // 以前这里直接 return：没配服务器 / 没填 Token 时列表空着、也没有任何提示，
            // 看起来就是「获取不到 MP 的订阅信息」。改成把原因说出来。
            state = state.copy(subscribesLoading = false, subscribes = emptyList())
            if (!silent) state = state.copy(toast = "未配置 MoviePilot：请到「设置 → MoviePilot」填地址和 API Token")
            return
        }
        if (!silent) state = state.copy(subscribesLoading = true)
        viewModelScope.launch {
            runCatching { client.subscribes() }
                .onSuccess { state = state.copy(subscribes = it, subscribesLoading = false) }
                .onFailure {
                    state = state.copy(
                        subscribesLoading = false,
                        // 静默刷新失败也要说：否则列表停在空/旧数据，用户完全无从判断
                        toast = "订阅加载失败：${it.message}"
                    )
                }
        }
    }

    fun subscribe(media: MpMedia?, season: Int? = null) {
        val client = client() ?: return
        val target = media ?: return
        viewModelScope.launch {
            state = state.copy(toast = "正在订阅…")
            runCatching { client.subscribe(target, season) }
                .onSuccess { message ->
                    state = state.copy(toast = message)
                    loadSubscribes(silent = true)
                }
                .onFailure { state = state.copy(toast = "订阅失败：${it.message}") }
        }
    }

    fun deleteSubscribe(id: Int) {
        val client = client() ?: return
        viewModelScope.launch {
            runCatching { client.deleteSubscribe(id) }
                .onSuccess {
                    state = state.copy(toast = "已删除订阅")
                    loadSubscribes(silent = true)
                }
                .onFailure { state = state.copy(toast = "删除失败：${it.message}") }
        }
    }

    fun toggleSubscribeState(subscribe: MpSubscribe) {
        val client = client() ?: return
        val next = if (subscribe.state.uppercase() == "R") "S" else "R"
        viewModelScope.launch {
            runCatching { client.updateSubscribeState(subscribe.id, next) }
                .onSuccess {
                    state = state.copy(toast = if (next == "R") "已恢复订阅" else "已暂停订阅")
                    loadSubscribes(silent = true)
                }
                .onFailure { state = state.copy(toast = "操作失败：${it.message}") }
        }
    }

    /**
     * 打开订阅设置前把选项备齐：下载器、保存路径、订阅站点、过滤规则组。
     *
     * 只补缺的，不重复拉：站点列表在「站点」页已经加载过就复用，避免每次点设置都打一遍 MP。
     */
    fun loadSubscribeOptions() {
        val client = client() ?: return
        viewModelScope.launch {
            if (state.downloaders.isEmpty()) {
                runCatching { withContext(Dispatchers.IO) { client.downloaders() } }
                    .onSuccess { list -> if (list.isNotEmpty()) state = state.copy(downloaders = list) }
            }
            if (state.savePaths.isEmpty()) {
                runCatching { withContext(Dispatchers.IO) { client.savePaths() } }
                    .onSuccess { list -> if (list.isNotEmpty()) state = state.copy(savePaths = list) }
            }
            if (state.site.sites.isEmpty()) {
                runCatching { withContext(Dispatchers.IO) { client.sites() } }
                    .onSuccess { list -> state = state.copy(site = state.site.copy(sites = list)) }
            }
            if (state.subscribeRuleGroups.isEmpty()) {
                runCatching { withContext(Dispatchers.IO) { client.ruleGroups() } }
                    .onSuccess { list -> state = state.copy(subscribeRuleGroups = list) }
            }
            if (state.rssSiteIds == null) {
                runCatching { withContext(Dispatchers.IO) { client.rssSiteIds() } }
                    .onSuccess { ids -> if (ids != null) state = state.copy(rssSiteIds = ids) }
            }
        }
    }

    /** 保存订阅设置；[onResult] 回主线程告诉界面该不该关弹窗 */
    fun saveSubscribe(sub: MpSubscribe, onResult: (Boolean) -> Unit) {
        val client = client() ?: return onResult(false)
        viewModelScope.launch {
            state = state.copy(toast = "正在保存订阅设置…")
            runCatching { withContext(Dispatchers.IO) { client.updateSubscribe(sub) } }
                .onSuccess {
                    state = state.copy(toast = "订阅设置已保存")
                    // 本地先落地一份，再静默刷新。只靠刷新的话网慢时列表还是旧值，
                    // 用户会认为「保存没生效」（站点取消勾选后尤其明显）。
                    applySavedSubscribe(sub)
                    loadSubscribes(silent = true)
                    onResult(true)
                }
                .onFailure {
                    state = state.copy(toast = "保存失败：${it.message}")
                    onResult(false)
                }
        }
    }

    /** 把刚保存的值就地写回列表里的那条订阅（只覆盖用户可编辑的字段） */
    private fun applySavedSubscribe(sub: MpSubscribe) {
        val list = state.subscribes.toMutableList()
        val index = list.indexOfFirst { it.id == sub.id }
        if (index < 0) return
        val editable = list[index].copy(
            keyword = sub.keyword,
            quality = sub.quality,
            resolution = sub.resolution,
            effect = sub.effect,
            sites = sub.sites,
            searchInterval = sub.searchInterval,
            downloader = sub.downloader,
            savePath = sub.savePath,
            bestVersion = sub.bestVersion,
            searchImdbId = sub.searchImdbId,
            include = sub.include,
            exclude = sub.exclude,
            filterGroups = sub.filterGroups,
            mediaCategory = sub.mediaCategory,
            customWords = sub.customWords
        )
        list[index] = editable
        state = state.copy(subscribes = list)
    }

    /** 立即搜索这一条订阅 */
    fun searchSubscribeNow(sub: MpSubscribe) {
        val client = client() ?: return
        viewModelScope.launch {
            state = state.copy(toast = "正在搜索《${sub.name}》…")
            runCatching { withContext(Dispatchers.IO) { client.searchSubscribe(sub.id) } }
                .onSuccess { state = state.copy(toast = it) }
                .onFailure { state = state.copy(toast = "搜索失败：${it.message}") }
        }
    }

    /** 重置订阅（清空已完成集数，重新按缺失集数搜） */
    fun resetSubscribe(sub: MpSubscribe) {
        val client = client() ?: return
        viewModelScope.launch {
            runCatching { withContext(Dispatchers.IO) { client.resetSubscribe(sub.id) } }
                .onSuccess {
                    state = state.copy(toast = "已重置《${sub.name}》")
                    loadSubscribes(silent = true)
                }
                .onFailure { state = state.copy(toast = "重置失败：${it.message}") }
        }
    }

    fun closeSubscribePanel() {
        state = state.copy(subscribePanel = null)
    }

    /**
     * 订阅活动：拉同类型的订阅历史，按名称过滤出这一条的历史记录。
     *
     * MP 的历史接口是按「电影 / 电视剧」整批返回的，没有按订阅 id 的过滤参数，
     * 所以只能客户端筛；同名同年的多季订阅会混在一起，这点和 MP 网页表现一致。
     */
    fun openSubscribeActivity(sub: MpSubscribe) {
        val client = client() ?: return
        state = state.copy(subscribePanel = SubscribePanel(title = "订阅活动 · ${sub.name}", loading = true))
        viewModelScope.launch {
            runCatching { withContext(Dispatchers.IO) { client.subscribeHistory(sub.type) } }
                .onSuccess { items ->
                    val mine = items.filter { it.optString("name").trim() == sub.name.trim() }
                    val lines = if (mine.isEmpty()) emptyList() else mine.map { item ->
                        val whenText = item.optString("last_update").ifBlank { item.optString("date") }
                        val stateText = item.optString("state", "R")
                        val lack = item.optInt("lack_episode", 0)
                        "$whenText · $stateText" + if (lack > 0) " · 缺 $lack 集" else " · 已完成"
                    }
                    state = state.copy(
                        subscribePanel = SubscribePanel(
                            title = "订阅活动 · ${sub.name}",
                            lines = lines.ifEmpty { listOf("暂无活动记录") }
                        )
                    )
                }
                .onFailure {
                    state = state.copy(
                        subscribePanel = SubscribePanel(
                            title = "订阅活动 · ${sub.name}",
                            error = "拉取失败：${it.message}"
                        )
                    )
                }
        }
    }

    /** 文件统计：按集汇总下载中 / 已入库的文件 */
    fun openSubscribeFiles(sub: MpSubscribe) {
        val client = client() ?: return
        state = state.copy(subscribePanel = SubscribePanel(title = "文件统计 · ${sub.name}", loading = true))
        viewModelScope.launch {
            runCatching { withContext(Dispatchers.IO) { client.subscribeFiles(sub.id) } }
                .onSuccess { obj ->
                    val episodes = obj.optJSONObject("episodes")
                    val lines = mutableListOf<String>()
                    var downloaded = 0
                    var inLibrary = 0
                    val keys = mutableListOf<String>()
                    episodes?.keys()?.forEach { keys += it }
                    keys.sortBy { it.toIntOrNull() ?: 0 }
                    for (key in keys) {
                        val ep = episodes?.optJSONObject(key) ?: continue
                        val downloadArr = ep.optJSONArray("download")
                        val libraryArr = ep.optJSONArray("library")
                        val dl = downloadArr?.length() ?: 0
                        val lib = libraryArr?.length() ?: 0
                        if (dl > 0) downloaded++
                        if (lib > 0) inLibrary++
                        val paths = mutableListOf<String>()
                        for (i in 0 until lib) {
                            paths += libraryArr?.optJSONObject(i)?.optString("file_path").orEmpty()
                        }
                        for (i in 0 until dl) {
                            val item = downloadArr?.optJSONObject(i)
                            val title = item?.optString("torrent_title").orEmpty()
                            paths += if (title.isNotBlank()) "下载中：$title" else "下载中"
                        }
                        val head = "第 $key 集" + if (lib > 0) "（已入库）" else ""
                        lines += head
                        paths.filter { it.isNotBlank() }.take(3).forEach { lines += "  $it" }
                    }
                    val summary = if (keys.isEmpty()) {
                        "暂无关联文件"
                    } else {
                        "共 ${keys.size} 集 · 已入库 $inLibrary 集 · 下载中 $downloaded 集"
                    }
                    state = state.copy(
                        subscribePanel = SubscribePanel(
                            title = "文件统计 · ${sub.name}",
                            lines = listOf(summary) + lines
                        )
                    )
                }
                .onFailure {
                    state = state.copy(
                        subscribePanel = SubscribePanel(
                            title = "文件统计 · ${sub.name}",
                            error = "拉取失败：${it.message}"
                        )
                    )
                }
        }
    }

    /** 媒体详情：用订阅里存的媒体身份打开详情页，不用重新搜 */
    fun openSubscribeMedia(sub: MpSubscribe) {
        val source = when (sub.mediaSource.lowercase()) {
            "douban" -> "douban"
            "bangumi" -> "bangumi"
            "themoviedb", "tmdb" -> "tmdb"
            else -> when {
                sub.tmdbId != null -> "tmdb"
                sub.doubanId.isNotBlank() -> "douban"
                sub.bangumiId != null -> "bangumi"
                else -> ""
            }
        }
        val rawId = sub.mediaIdRaw.ifBlank {
            sub.tmdbId?.toString()
                ?: sub.doubanId.ifBlank { sub.bangumiId?.toString().orEmpty() }
        }.substringAfter(':')
        if (source.isBlank() || rawId.isBlank()) {
            state = state.copy(toast = "这条订阅没存媒体身份，打不开详情")
            return
        }
        openDetail(
            MpMedia(
                mediaId = "$source:$rawId",
                source = source,
                type = sub.type.ifBlank { "电影" },
                title = sub.name,
                year = sub.year,
                season = sub.season,
                tmdbId = sub.tmdbId,
                doubanId = sub.doubanId.ifBlank { null },
                bangumiId = sub.bangumiId,
                posterUrl = sub.posterUrl,
                backdropUrl = "",
                overview = sub.description,
                vote = sub.vote,
                genres = emptyList(),
                directors = emptyList(),
                cast = emptyList(),
                releaseDate = sub.year,
                category = sub.mediaCategory
            )
        )
    }

    suspend fun testServer(server: MpServer): Result<String> = withContext(Dispatchers.IO) {
        runCatching { MoviePilotClient(server).testConnection() }
    }

    /**
     * 单条种子按标题反查海报（任务详情页用）。
     *
     * 站点列表是批量解析，任务详情只有一条，直接走同一套 [MediaPosterResolver]：
     * 命中缓存立刻返回；「问过 MP 但没有海报」也返回 null 且不会重复请求。
     * 没配 MP 服务器就只有渐变兜底，不报错。
     */
    suspend fun posterForTitle(title: String): String? {
        val key = MediaPosterResolver.titleKey(title)
        if (key.isBlank()) return null
        MediaPosterResolver.cached(key)?.let { return it }
        if (MediaPosterResolver.isResolved(key)) return null
        val client = state.server?.let { MoviePilotClient(it) } ?: return null
        val url = withContext(Dispatchers.IO) {
            MediaPosterResolver.resolve(client, listOf(key to title))[key]
        } ?: return null
        // MP 给的是 /t/p/original（动辄 1~2MB），详情页只有 92dp 宽，按 w342 取就够清晰
        return url.replace("/t/p/original/", "/t/p/w342/")
    }

    // ---------- 站点（只读同步 MP） ----------

    /**
     * 拉站点列表 + 各站个人数据。
     *
     * 两个接口都要求管理员 token：403 时 banner 提示去换 token，404 时降级成「这个 MP 版本
     * 没有站点接口」。个人数据失败不算致命 —— 站点列表照样显示，只是没有等级/上传量。
     */
    fun loadSites(force: Boolean = false) {
        val client = client()
        if (client == null) {
            state = state.copy(
                site = state.site.copy(
                    loading = false,
                    loaded = false,
                    error = "还没有配置 MoviePilot 服务器"
                )
            )
            return
        }
        if (!force && (state.site.loading || state.site.loaded)) return
        siteJob?.cancel()
        state = state.copy(site = state.site.copy(loading = true, error = null))
        siteJob = viewModelScope.launch {
            val sitesResult = runCatching { withContext(Dispatchers.IO) { client.sites() } }
            val sites = sitesResult.getOrNull()
            if (sites == null) {
                state = state.copy(site = siteErrorState(state.site, sitesResult.exceptionOrNull()))
                return@launch
            }
            val dataResult = runCatching { withContext(Dispatchers.IO) { client.siteUserData() } }
            state = state.copy(
                site = state.site.copy(
                    sites = sites,
                    userData = matchSiteUserData(sites, dataResult.getOrDefault(emptyList())),
                    loading = false,
                    loaded = true,
                    permissionDenied = false,
                    degraded = false,
                    error = dataResult.exceptionOrNull()?.let {
                        "站点个人数据加载失败：${humanizeSiteError(it)}"
                    }
                )
            )
        }
    }

    fun refreshSites() = loadSites(force = true)

    /**
     * 站点图标：命中内存缓存直接返回，否则去 MP 拉一次（并发由 [SiteIconStore] 限住）。
     * MP 里没有图标的站点会被记住，不再重复请求，UI 降级成首字色块。
     *
     * 不走 state：图标是几十个卡片各自的私事，塞进 MpSiteState 会让整页每次加载一张就重组一次。
     */
    /** 图标请求的 in-flight 表：挂在 viewModelScope 上，UI 滚走取消 await 也不会把请求掐掉 */
    private val iconLoads = HashMap<Int, Deferred<Any?>>()

    /**
     * 站点图标：返回 String（远程地址）或 Bitmap（本地解码好的）。
     *
     * 请求跑在 [viewModelScope]（[iconDeferred]）而不是 Composable 的作用域里，这点很关键：
     * 之前是 LaunchedEffect 里直接请求，卡片一滑出屏幕协程就被取消，
     * `runCatching` 把 CancellationException 当成失败，于是这个站点被永久拉黑 ——
     * 表现就是「滑一遍列表，除了停下来看的那两个，其余站点全都没图标」。
     */
    suspend fun loadSiteIcon(siteId: Int): Any? {
        SiteIconStore.cached(siteId)?.let { return it }
        if (SiteIconStore.isMissing(siteId)) return null
        val deferred = iconDeferred(siteId) ?: return null
        return deferred.await()
    }

    /**
     * 站点种子详情页的「MP 侧内容」：识别标题 → 详情 → 演职员。
     *
     * 站点接口只给文字，简介/类型/导演/主演都没有；这里跑一遍 MP 的三段接口，
     * 让站点页和 MP 搜索结果页显示同一套内容。任何一步失败都降级为空，不影响页面渲染。
     */
    data class TorrentMediaInfo(
        val media: MpMedia? = null,
        val creditNames: List<String> = emptyList()
    )

    suspend fun loadTorrentMedia(title: String): TorrentMediaInfo {
        if (title.isBlank()) return TorrentMediaInfo()
        val client = client() ?: return TorrentMediaInfo()
        // 先走识别接口（MP 自己会清洗发布名）；识别不出来再退回文本搜索第一条
        val found = runCatching { client.recognizeMedia(title) }.getOrNull()
            ?: runCatching { client.searchMedia(title).firstOrNull() }.getOrNull()
            ?: return TorrentMediaInfo()
        val detail = runCatching { client.mediaDetail(found) }.getOrDefault(found)
        val credits = runCatching { client.credits(detail) }.getOrDefault(emptyList())
        val names = if (credits.isNotEmpty()) {
            credits.map { it.name }
        } else {
            detail.directors + detail.cast
        }
        return TorrentMediaInfo(detail, names.filter { it.isNotBlank() }.distinct())
    }

    /**
     * 同一站点只发一次请求，结果写进 [SiteIconStore]。
     *
     * 只有「接口正常答复」才落缓存；超时/连不上这类失败**不**记黑名单，
     * 卡片滚回来时还能再试一次。
     */
    private fun iconDeferred(siteId: Int): Deferred<Any?>? = synchronized(iconLoads) {
        iconLoads[siteId] ?: run {
            val client = client() ?: return@synchronized null
            viewModelScope.async(Dispatchers.IO) {
                SiteIconStore.limited {
                    var failed = false
                    val raw = try {
                        client.siteIcon(siteId)
                    } catch (e: Exception) {
                        failed = true
                        Log.w(TAG, "站点 $siteId 图标请求失败：${e.message}")
                        null
                    }
                    if (failed) {
                        null
                    } else {
                        val model = SiteIconStore.remember(siteId, raw)
                        Log.d(
                            TAG,
                            "站点 $siteId 图标原文 ${raw?.length ?: 0} 字符 → ${SiteIconStore.describe(model)}"
                        )
                        model
                    }
                }
            }.also { d ->
                iconLoads[siteId] = d
                d.invokeOnCompletion {
                    synchronized(iconLoads) {
                        if (iconLoads[siteId] === d) iconLoads.remove(siteId)
                    }
                }
            }
        }
    }

    /** 点开一个站点：先清掉上一个站点的现场，再拉分类 + 第一页种子 */
    fun openSite(site: MpSite) {
        if (!site.isActive) {
            state = state.copy(toast = "该站点在 MoviePilot 里是停用状态，先去 MP 后台启用")
            return
        }
        cancelSiteBrowse()
        posterFailStreak = 0
        state = state.copy(
            site = state.site.copy(
                openSite = site,
                searchInput = "",
                keyword = "",
                categories = emptyList(),
                selectedCats = emptyList(),
                sort = SiteSort.LATEST,
                allPageKeys = emptySet(),
                catIgnored = false,
                torrents = emptyList(),
                posters = emptyMap(),
                browseError = null,
                page = 0,
                hasMore = true,
                elapsedSeconds = 0,
                postersDisabled = false
            )
        )
        loadSiteCategories(site.id)
        loadSitePage(reset = true)
    }

    fun closeSite() {
        cancelSiteBrowse()
        state = state.copy(
            site = state.site.copy(
                openSite = null,
                searchInput = "",
                keyword = "",
                categories = emptyList(),
                selectedCats = emptyList(),
                sort = SiteSort.LATEST,
                allPageKeys = emptySet(),
                catIgnored = false,
                torrents = emptyList(),
                posters = emptyMap(),
                browseError = null,
                page = 0,
                hasMore = true,
                elapsedSeconds = 0
            )
        )
    }

    fun updateSiteSearchInput(text: String) {
        state = state.copy(site = state.site.copy(searchInput = text))
    }

    fun submitSiteSearch() {
        val keyword = state.site.searchInput.trim()
        state = state.copy(
            site = state.site.copy(
                keyword = keyword,
                torrents = emptyList(),
                posters = emptyMap(),
                page = 0,
                hasMore = true,
                catIgnored = false,
                elapsedSeconds = 0
            )
        )
        loadSitePage(reset = true)
    }

    /**
     * 分类**单选**：点没选的 → 只留它；点已选的 → 退回「全部」。
     *
     * 每次换分类都要重新让 MP 去爬站点（`cat` 是服务端参数），所以这里会清空列表并复位分页。
     */
    fun toggleSiteCategory(cat: String) {
        val current = state.site.selectedCats
        val next = if (cat in current) emptyList() else listOf(cat)
        state = state.copy(
            site = state.site.copy(
                selectedCats = next,
                torrents = emptyList(),
                posters = emptyMap(),
                page = 0,
                hasMore = true,
                catIgnored = false,
                elapsedSeconds = 0
            )
        )
        loadSitePage(reset = true)
    }

    /** 换排序：纯客户端重排，不发请求（MP 的浏览接口没有排序参数） */
    fun setSiteSort(sort: SiteSort) {
        if (state.site.sort == sort) return
        state = state.copy(site = state.site.copy(sort = sort))
    }

    /** 「全部」按钮：清掉分类筛选重新浏览 */
    fun clearSiteCategories() {
        if (state.site.selectedCats.isEmpty()) return
        state = state.copy(
            site = state.site.copy(
                selectedCats = emptyList(),
                torrents = emptyList(),
                posters = emptyMap(),
                page = 0,
                hasMore = true,
                catIgnored = false,
                elapsedSeconds = 0
            )
        )
        loadSitePage(reset = true)
    }

    fun refreshSiteTorrents() = loadSitePage(reset = true)

    fun loadMoreSiteTorrents() = loadSitePage(reset = false)

    fun cancelSiteBrowse() {
        browseJob?.cancel()
        browseJob = null
        browseTicker?.cancel()
        browseTicker = null
        if (state.site.browsing) {
            state = state.copy(site = state.site.copy(browsing = false, elapsedSeconds = 0))
        }
    }

    private fun loadSiteCategories(siteId: Int) {
        val client = client() ?: return
        viewModelScope.launch {
            val cats = runCatching {
                withContext(Dispatchers.IO) { client.siteCategories(siteId) }
            }.getOrDefault(emptyList())
                // MP 的 category 配置里，同一个 cat 值可能挂了好几个 desc
                // （例如「电视剧」和「TV剧」都是 TV）。不去重的话 chips 会重复，
                // LazyRow 的 key 直接撞车，一滑动就崩。
                .distinctBy { it.value }
            Log.d(
                TAG,
                "站点 $siteId 分类 ${cats.size} 个：" +
                    cats.take(6).joinToString(" | ") { "${it.id}/" + "${it.cat}/" + it.desc }
            )
            // 期间可能已经切到别的站点，这时结果作废
            if (state.site.openSite?.id == siteId) {
                state = state.copy(site = state.site.copy(categories = cats))
            }
        }
    }

    /**
     * 拉一页站点种子。
     *
     * page 从 0 开始；MP 没有 total，只能靠「返回空数组」判断到底。
     * 浏览是同步阻塞的（MP 真的去爬站点网页），所以要有一个秒表告诉用户还在跑，
     * 并且切站点时必须 cancel —— MP 对同站有 limit_interval 流控，并发只会互相拖死。
     */
    private fun loadSitePage(reset: Boolean) {
        val client = client() ?: return
        val site = state.site.openSite ?: return
        val current = state.site
        if (!reset && (!current.hasMore || current.browsing)) return

        val nextPage = if (reset) 0 else current.page + 1
        val keyword = current.keyword
        val cats = current.selectedCats

        browseJob?.cancel()
        browseTicker?.cancel()
        state = state.copy(
            site = current.copy(
                browsing = true,
                elapsedSeconds = 0,
                browseError = null,
                page = nextPage
            )
        )
        browseTicker = viewModelScope.launch {
            while (isActive) {
                delay(1000)
                if (!state.site.browsing) break
                val elapsed = state.site.elapsedSeconds + 1
                state = state.copy(site = state.site.copy(elapsedSeconds = elapsed))
                // 站点彻底没响应时不能干等 OkHttp 的 180 秒：超时自己收手，给一句能照着做的话
                if (elapsed >= SITE_BROWSE_TIMEOUT_SECONDS) {
                    browseJob?.cancel()
                    browseJob = null
                    state = state.copy(
                        site = state.site.copy(
                            browsing = false,
                            elapsedSeconds = 0,
                            browseError = "站点 ${SITE_BROWSE_TIMEOUT_SECONDS} 秒没有响应。" +
                                "多半是 MP 抓不到这个站（站点 Cookie 失效、站点被 Cloudflare 拦、或站点本身挂了）：" +
                                "先去 MP 后台「站点」里手动浏览一次，能出种子再回这里重试。"
                        )
                    )
                    break
                }
            }
        }
        browseJob = viewModelScope.launch {
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    client.siteTorrents(site.id, site.name, keyword, cats, nextPage)
                }
            }
            browseTicker?.cancel()
            browseTicker = null
            result
                .onSuccess { list ->
                    val before = state.site
                    val merged = if (reset) {
                        list.distinctBy { it.key }
                    } else {
                        (before.torrents + list).distinctBy { it.key }
                    }
                    // 越界页被站点回落到首页时「返回非空但没新东西」，连续 3 页就收手
                    val stalled =
                        if (reset || merged.size > before.torrents.size) 0 else before.stalledPages + 1
                    // 选了分类，但这一页和「全部」第一页一模一样 → 站点没按 cat 过滤（MP 直接忽略了参数）
                    val pageKeys = list.map { it.key }.toSet()
                    val catIgnored = reset && cats.isNotEmpty() &&
                        before.allPageKeys.isNotEmpty() && pageKeys == before.allPageKeys
                    state = state.copy(
                        site = state.site.copy(
                            torrents = merged,
                            page = nextPage,
                            hasMore = list.isNotEmpty() && stalled < 3,
                            stalledPages = stalled,
                            browsing = false,
                            browseError = null,
                            elapsedSeconds = 0,
                            allPageKeys = if (reset && cats.isEmpty()) pageKeys else before.allPageKeys,
                            catIgnored = catIgnored
                        )
                    )
                    resolveSitePosters(site.id, merged)
                }
                .onFailure { error ->
                    // 自己取消（切站点/换分类/超时）不要报成错误
                    if (error is CancellationException) return@onFailure
                    state = state.copy(
                        site = state.site.copy(
                            browsing = false,
                            browseError = humanizeSiteError(error),
                            elapsedSeconds = 0
                        )
                    )
                }
        }
    }

    /**
     * 给当前页的种子补海报。
     *
     * 只处理「还没问过 MP」的标题（按归一化标题去重），每批最多 18 个，
     * 拿回来的地址增量并进 state.posters，Compose 只会重组有图的那几行。
     */
    private suspend fun resolveSitePosters(siteId: Int, resources: List<MpResource>) {
        if (resources.isEmpty() || state.site.postersDisabled) return
        val client = client() ?: return

        val requests = resources
            .map { MediaPosterResolver.titleKey(it.title) to it.title }
            .filter { it.first.isNotBlank() }
            .distinctBy { it.first }
            .filter { !MediaPosterResolver.isResolved(it.first) }
            .take(18)

        val fetched = if (requests.isEmpty()) emptyMap() else MediaPosterResolver.resolve(client, requests)
        if (state.site.openSite?.id != siteId) return

        val merged = HashMap<String, String>()
        resources.forEach { resource ->
            val key = MediaPosterResolver.titleKey(resource.title)
            val url = fetched[key] ?: MediaPosterResolver.cached(key)
            if (url != null) merged[resource.key] = url
        }
        if (merged.isNotEmpty()) {
            state = state.copy(site = state.site.copy(posters = state.site.posters + merged))
        }

        // 熔断：一整批一条都没成（v2 没有识别接口 / token 权限不足 / 网络断），连续 3 批就彻底关掉
        if (requests.size >= 3 && fetched.isEmpty()) {
            posterFailStreak++
            if (posterFailStreak >= 3) {
                state = state.copy(site = state.site.copy(postersDisabled = true))
            }
        } else if (fetched.isNotEmpty()) {
            posterFailStreak = 0
        }
    }

    /** 切 MP 服务器 / 删服务器时把站点状态整体清掉，避免上一台的站点串到下一台 */
    private fun resetSiteState() {
        siteJob?.cancel()
        siteJob = null
        browseJob?.cancel()
        browseJob = null
        browseTicker?.cancel()
        browseTicker = null
        posterFailStreak = 0
        MediaPosterResolver.clear()
        SiteIconStore.clear()
        // 旧服务器的图标请求可能还在飞，取消掉，否则它们回来会把旧图标写进新缓存
        synchronized(iconLoads) {
            iconLoads.values.forEach { it.cancel() }
            iconLoads.clear()
        }
        state = state.copy(site = MpSiteState())
    }

    private fun siteErrorState(current: MpSiteState, error: Throwable?): MpSiteState {
        val code = (error as? ApiException)?.code
        val denied = code == 401 || code == 403
        val degraded = code == 404
        val message = when {
            denied -> "站点接口需要管理员权限：请在 MoviePilot「设置 → 系统 → API Token」用管理员账号重新生成，再填到本 App"
            degraded -> "当前 MoviePilot 版本没有站点接口（需要 v3.1 以上）"
            else -> humanizeSiteError(error)
        }
        return current.copy(
            loading = false,
            loaded = false,
            error = message,
            permissionDenied = denied,
            degraded = degraded,
            sites = if (denied || degraded) emptyList() else current.sites
        )
    }

    private fun humanizeSiteError(error: Throwable?): String {
        if (error == null) return "未知错误"
        return when ((error as? ApiException)?.code) {
            401, 403 -> "站点接口需要管理员权限（当前 API Token 权限不足）"
            404 -> "当前 MoviePilot 版本没有站点接口（需要 v3.1 以上）"
            else -> humanizeStatsError(error)
        }
    }

    /**
     * MP 的 userdata 只有 domain 没有 site_id，按 domain 对回站点。
     * 两边都可能带 www / 大小写不同，抹平后再比；domain 全对不上时再按站点名兜底
     * （某些版本 domain 存的是 url 而不是索引键）。都匹配不到的站点只是少了个人数据。
     */
    private fun matchSiteUserData(
        sites: List<MpSite>,
        data: List<MpSiteUserData>
    ): Map<Int, MpSiteUserData> {
        if (data.isEmpty()) return emptyMap()
        val byDomain = HashMap<String, MpSiteUserData>()
        val byName = HashMap<String, MpSiteUserData>()
        data.forEach { item ->
            val key = item.domain.trim().lowercase()
                .removePrefix("https://").removePrefix("http://").removePrefix("www.")
                .trimEnd('/')
            if (key.isNotEmpty()) byDomain.putIfAbsent(key, item)
            val nameKey = item.name.trim().lowercase()
            if (nameKey.isNotEmpty()) byName.putIfAbsent(nameKey, item)
        }
        val result = LinkedHashMap<Int, MpSiteUserData>()
        sites.forEach { site ->
            val hit = site.matchKeys.firstNotNullOfOrNull { byDomain[it] }
                ?: byName[site.name.trim().lowercase()]
            if (hit != null) result[site.id] = hit
        }
        return result
    }

    fun consumeToast() {
        state = state.copy(toast = null)
    }
}
