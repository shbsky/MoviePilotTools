package com.moviepilottools.mptools.vm

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.moviepilottools.mptools.data.AppSettings
import com.moviepilottools.mptools.data.ConfigStore
import com.moviepilottools.mptools.data.PersistedState
import com.moviepilottools.mptools.data.ServerConfig
import com.moviepilottools.mptools.data.ServerSnapshot
import com.moviepilottools.mptools.data.ServerType
import com.moviepilottools.mptools.data.TorrentStatus
import com.moviepilottools.mptools.data.TorrentTask
import com.moviepilottools.mptools.data.TrackerEntry
import com.moviepilottools.mptools.data.TrafficLedger
import com.moviepilottools.mptools.net.ApiException
import com.moviepilottools.mptools.net.EndpointResolver
import com.moviepilottools.mptools.net.Net
import com.moviepilottools.mptools.net.QBittorrentClient
import com.moviepilottools.mptools.net.TransmissionClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * 「Tracker 列表」弹窗的状态。
 *
 * [taskKey] 用来判断异步结果是不是还属于当前打开的任务 —— 用户可能已经关了弹窗
 * 或换了一个种子，这时旧请求回来不能把列表覆盖掉。
 */
data class TrackerState(
    val taskKey: String = "",
    val items: List<TrackerEntry> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
    /** 正在提交改 / 增 / 删，按钮要禁用避免重复提交 */
    val busy: Boolean = false
)

data class UiState(
    val servers: List<ServerConfig> = emptyList(),
    val activeServerId: String? = null,
    val settings: AppSettings = AppSettings(),
    val tasks: List<TorrentTask> = emptyList(),
    val snapshots: Map<String, ServerSnapshot> = emptyMap(),
    val isRefreshing: Boolean = false,
    val lastRefreshAt: Long = 0L,
    val toast: String? = null,
    /** 新增下载页的提交状态（转圈 / 成功 / 失败原因） */
    val addTorrent: AddTorrentState = AddTorrentState(),
    /** 各下载器的分类 / 标签清单（qb 独有；tr 没有这两个概念，一直为空） */
    val categories: Map<String, List<String>> = emptyMap(),
    val tags: Map<String, List<String>> = emptyMap(),
    /** 全部服务器口径的今日/本月流量（来自下载器累计计数器的本地账本） */
    val trafficAll: TrafficLedger.Totals = TrafficLedger.Totals(),
    /** 单台服务器口径的今日/本月流量（切到某台机器时页面跟着变） */
    val trafficByServer: Map<String, TrafficLedger.Totals> = emptyMap(),
    /** Tracker 列表弹窗的状态（哪个任务 / 条目 / 加载与报错） */
    val trackers: TrackerState = TrackerState()
) {
    /** 当前口径下的今日 / 本月流量 */
    val traffic: TrafficLedger.Totals
        get() = if (activeServerId == null) trafficAll
        else trafficByServer[activeServerId] ?: TrafficLedger.Totals()

    val activeTasks: List<TorrentTask>
        get() = if (activeServerId == null) tasks else tasks.filter { it.serverId == activeServerId }

    val visibleSnapshots: List<ServerSnapshot>
        get() = if (activeServerId == null) snapshots.values.toList()
        else listOfNotNull(snapshots[activeServerId])

    val totalSeeding: Int get() = visibleSnapshots.filter { it.online }.sumOf { it.seedingCount }
    val totalDownloading: Int get() = visibleSnapshots.filter { it.online }.sumOf { it.downloadingCount }
    val totalBandwidth: Long
        get() = visibleSnapshots.filter { it.online }.sumOf { it.downloadSpeed + it.uploadSpeed }
    /** 全站下载速率（MP 仪表盘拿不到数据时，仪表盘实时速率卡用它兜底） */
    val totalDownloadSpeed: Long
        get() = visibleSnapshots.filter { it.online }.sumOf { it.downloadSpeed }
    val totalUploadSpeed: Long
        get() = visibleSnapshots.filter { it.online }.sumOf { it.uploadSpeed }
    /** 各下载器累计下载量之和（口径与 MP 的 downloader.download_size 一致：不去重） */
    val totalDownloaded: Long
        get() = visibleSnapshots.filter { it.online }.sumOf { it.totalDownloaded }
    val totalUploaded: Long
        get() = visibleSnapshots.filter { it.online }.sumOf { it.totalUploaded }
    /**
     * 「剩余空间」总量（跨下载器实例聚合）。
     *
     * 修复背景：每个实例上报的 freeSpace 都是「其默认下载目录所在磁盘」的剩余容量
     * （qB 取 sync/maindata 的 server_state.free_space_on_disk，tr 取 session-get 的
     * download-dir-free-space）。当 qb 与 tr 部署在同一台机器、同一块磁盘时，两个实例
     * 上报的其实是同一份剩余空间；原来的 `sumOf { it.freeSpace }` 会把它算两遍，
     * 导致仪表盘「剩余空间」偏大甚至翻倍。
     *
     * 去重策略：以「主机地址」作为「可能共享同一块物理磁盘」的分组键。ServerSnapshot 本身
     * 没有下载目录/磁盘设备号，唯一能反映物理位置的是 ServerConfig.endpoints 里的 host；
     * 同一台主机上的多个下载器通常共用同一块下载盘。把共享任意 host 的在线实例归为一组
     * （并查集连通合并，兼容「一个实例配置了多个入口地址」的情况），每组只保留一个代表值
     * （取组内最大值：容忍两次 RPC 之间的写入漂移，以及某实例本次拉取失败返回 0），
     * 再把各组代表值相加 —— 不同主机/不同磁盘仍分别累加，不做全局一刀切取最大值。
     *
     * 局限（现有字段无法可靠识别磁盘归属，故采取「宁可少算也不翻倍」的保守取舍）：
     * 1) 同一台主机若挂了多块磁盘、且不同下载器分别使用，会被合并成一组而只计最大的一块，
     *    少算其余盘；要精确区分需 Client 把下载目录/挂载点写进 ServerSnapshot，超出本次最小变更范围。
     * 2) 同一台主机若两个实例填了不同形式的地址（如一个内网 IP、一个域名，或 IP 与 IPv6），
     *    host 字符串不同则无法归并，仍可能重复累加；建议同机实例填写一致的 host。
     * 3) 不同主机挂载同一块网络盘（NFS/SMB）时 host 不同，同样无法识别，会重复累加。
     * 4) 未采用「按 freeSpace 数值判重」：两次请求之间磁盘仍在写入，数值不严格相等；
     *    不同磁盘也可能恰好剩余相近，漏判/误判都高。
     *
     * 单实例时分组只有一组、代表值即该实例原值，显示与修复前一致；离线实例不计入。
     */
    val totalFreeSpace: Long
        get() {
            val online = visibleSnapshots.filter { it.online }
            if (online.isEmpty()) return 0L

            // 实例 -> 规范化后的主机地址集合；取不到配置时退化为 serverId，保证不会被误并。
            val hostSets: List<Set<String>> = online.map { snapshot ->
                val config = servers.firstOrNull { it.id == snapshot.serverId }
                val hosts: Set<String> = config?.activeEndpoints
                    ?.map { it.normalized().host.trim().lowercase() }
                    ?.filter { it.isNotEmpty() }
                    ?.toSet()
                    .orEmpty()
                hosts.ifEmpty { setOf("server:${snapshot.serverId}") }
            }

            // 并查集：共享任意 host 的在线实例归为同一组（视为可能共享同一块磁盘）。
            val parent = IntArray(online.size) { it }

            fun find(x: Int): Int {
                var root = x
                while (parent[root] != root) root = parent[root]
                var cur = x
                while (parent[cur] != cur) {
                    val next = parent[cur]
                    parent[cur] = root
                    cur = next
                }
                return root
            }

            fun union(a: Int, b: Int) {
                val rootA = find(a)
                val rootB = find(b)
                if (rootA != rootB) parent[rootB] = rootA
            }

            val hostOwner = HashMap<String, Int>()
            for (index in online.indices) {
                for (host in hostSets[index]) {
                    val first = hostOwner[host]
                    if (first == null) hostOwner[host] = index else union(first, index)
                }
            }

            // 每组只计一份（组内最大值），再把各组代表值相加。
            val maxByGroup = HashMap<Int, Long>()
            for (index in online.indices) {
                val root = find(index)
                val value = online[index].freeSpace
                val current = maxByGroup[root]
                if (current == null || value > current) maxByGroup[root] = value
            }
            return maxByGroup.values.sum()
        }
    val downloadSpeed: Long get() = activeTasks.sumOf { it.downloadSpeed }
    val uploadSpeed: Long get() = activeTasks.sumOf { it.uploadSpeed }
    val onlineCount: Int get() = snapshots.values.count { it.online }
    val hasAnyConfigured: Boolean get() = servers.isNotEmpty()
}

class AppViewModel(application: Application) : AndroidViewModel(application) {

    private val store = ConfigStore(application)
    private var persisted: PersistedState = store.load()
    /** 今日 / 本月流量账本（下载器累计计数器的差值，本地持久化） */
    private val trafficLedger = TrafficLedger(application)

    var state by mutableStateOf(
        UiState(
            servers = persisted.servers,
            activeServerId = persisted.activeServerId,
            settings = persisted.settings
        )
    )
        private set

    private var refreshJob: Job? = null
    private val refreshMutex = Mutex()
    /** 备用限速切换请求在飞时为 true，挡住连点（连点会切过去又切回来） */
    private var altSpeedBusy = false

    init {
        if (state.servers.isNotEmpty()) {
            startAutoRefresh()
        }
    }

    // ---------- 配置 ----------

    fun upsertServer(config: ServerConfig) {
        val existing = state.servers.indexOfFirst { it.id == config.id }
        val servers = if (existing >= 0) {
            state.servers.toMutableList().also { it[existing] = config }
        } else {
            state.servers + config
        }
        commit(servers = servers)
        EndpointResolver.invalidate(config.id)
        refreshNow()
    }

    fun deleteServer(id: String) {
        commit(
            servers = state.servers.filterNot { it.id == id },
            activeServerId = state.activeServerId?.takeIf { it != id }
        )
        EndpointResolver.invalidate(id)
    }

    fun selectServer(id: String?) {
        commit(activeServerId = id)
    }

    fun updateSettings(settings: AppSettings) {
        commit(settings = settings)
        restartAutoRefreshIfNeeded()
    }

    fun resetAll() {
        refreshJob?.cancel()
        persisted = PersistedState()
        store.save(persisted)
        state = UiState()
    }

    /**
     * 从备份恢复后重建内存状态。配置已由调用方写盘，这里只读回来：
     * 下载器列表、选中的下载器、设置全部刷新，并重启自动轮询。
     * RSS / MoviePilot 各有自己的 VM，由 MainActivity 分别调用它们的 reload。
     */
    fun reloadFromStore() {
        refreshJob?.cancel()
        persisted = store.load()
        state = UiState(
            servers = persisted.servers,
            activeServerId = persisted.activeServerId,
            settings = persisted.settings
        )
        if (state.servers.isNotEmpty()) {
            startAutoRefresh()
        }
    }

    private fun commit(
        servers: List<ServerConfig> = state.servers,
        activeServerId: String? = state.activeServerId,
        settings: AppSettings = state.settings
    ) {
        // 先读盘上最新整包，再只改自己负责的字段。
        // 曾经直接 copy 启动时的 persisted 快照：MpViewModel 刚存好的 mpServers
        // 会被这里用旧快照整包覆盖掉 —— 「MP 服务器偶发变回未配置」的根因。
        persisted = store.load().copy(
            servers = servers,
            activeServerId = activeServerId,
            settings = settings
        )
        store.save(persisted)
        state = state.copy(servers = servers, activeServerId = activeServerId, settings = settings)
    }

    // ---------- 刷新 ----------

    fun startAutoRefresh() {
        refreshJob?.cancel()
        refreshJob = viewModelScope.launch {
            refreshNow()
            while (isActive) {
                val seconds = state.settings.refreshSeconds.coerceIn(2, 120)
                delay(seconds * 1000L)
                refresh(showSpinner = false)
            }
        }
    }

    private fun restartAutoRefreshIfNeeded() = startAutoRefresh()

    fun stopAutoRefresh() {
        refreshJob?.cancel()
        refreshJob = null
    }

    override fun onCleared() {
        // ViewModel 销毁（App 退到后台被回收 / 进程结束）前把账本落盘，避免最后一段流量丢失
        trafficLedger.flush()
        super.onCleared()
    }

    fun refreshNow() {
        viewModelScope.launch { refresh(showSpinner = true) }
    }

    private suspend fun refresh(showSpinner: Boolean) {
        if (state.servers.isEmpty()) return
        refreshMutex.withLock {
            if (showSpinner) state = state.copy(isRefreshing = true)

            val servers = state.servers
            val tasksCollector = java.util.Collections.synchronizedList(mutableListOf<TorrentTask>())
            val snapshotCollector = java.util.concurrent.ConcurrentHashMap<String, ServerSnapshot>()

            val jobs = servers.map { server ->
                viewModelScope.launch(Dispatchers.IO) {
                    val result = runCatching { fetchServer(server) }
                    result.onSuccess { (tasks, snapshot) ->
                        tasksCollector += tasks
                        val prev = state.snapshots[server.id]
                        // 这轮没读到限速状态就沿用上一轮的显示值（仍算未知，UI 不会拿它纠正颜色），
                        // 避免「那次请求刚好超时」让图标闪一下
                        snapshotCollector[server.id] =
                            if (!snapshot.altSpeedKnown && prev != null && prev.online) {
                                snapshot.copy(altSpeedEnabled = prev.altSpeedEnabled)
                            } else {
                                snapshot
                            }
                    }.onFailure { error ->
                        val prev = state.snapshots[server.id]
                        snapshotCollector[server.id] = ServerSnapshot(
                            serverId = server.id,
                            online = false,
                            error = error.message ?: error.javaClass.simpleName,
                            // 断线时保留上一次读到的限速状态，恢复连接时颜色不用来回跳
                            altSpeedEnabled = prev?.altSpeedEnabled ?: false
                        )
                    }
                }
            }
            jobs.joinAll()

            // 流量账本：先用「全部服务器」的快照记一笔（离线实例也要带上，用来清理已删服务器），
            // 再按「全部 / 单台」两个口径分别算今日 / 本月累计，供仪表盘瓦片直接取用
            val snapMap = snapshotCollector.toMap()
            trafficLedger.record(snapMap)
            val perServer = snapMap.keys.associateWith { listOf(it) }
                .mapValues { (_, ids) -> trafficLedger.totalsFor(ids) }
            val trafficAll = trafficLedger.totalsFor(snapMap.keys)

            val order = state.servers.mapIndexed { index, server -> server.id to index }.toMap()
            state = state.copy(
                tasks = tasksCollector.sortedWith(
                    compareBy<TorrentTask> { order[it.serverId] ?: 0 }.thenByDescending { it.addedAt }
                ),
                snapshots = snapMap,
                trafficAll = trafficAll,
                trafficByServer = perServer,
                isRefreshing = false,
                lastRefreshAt = System.currentTimeMillis()
            )
        }
    }

    private suspend fun fetchServer(server: ServerConfig): Pair<List<TorrentTask>, ServerSnapshot> {
        return when (server.type) {
            ServerType.QBITTORRENT -> QBittorrentClient(server).fetchAll()
            ServerType.TRANSMISSION -> TransmissionClient(server).fetchAll()
        }
    }

    // ---------- 操作 ----------

    fun performAction(task: TorrentTask, action: TorrentAction) {
        viewModelScope.launch {
            val server = state.servers.firstOrNull { it.id == task.serverId } ?: return@launch
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    when (server.type) {
                        ServerType.QBITTORRENT -> {
                            val client = QBittorrentClient(server)
                            when (action) {
                                TorrentAction.PAUSE -> client.pause(listOf(task.hash))
                                TorrentAction.RESUME -> client.resume(listOf(task.hash))
                                TorrentAction.RESUME_FORCED -> client.forceStart(listOf(task.hash))
                                TorrentAction.RECHECK -> client.recheck(listOf(task.hash))
                                TorrentAction.REANNOUNCE -> client.reannounce(listOf(task.hash))
                                TorrentAction.DELETE, TorrentAction.DELETE_WITH_FILES ->
                                    client.delete(listOf(task.hash), action == TorrentAction.DELETE_WITH_FILES)
                            }
                        }
                        ServerType.TRANSMISSION -> {
                            val client = TransmissionClient(server)
                            when (action) {
                                TorrentAction.PAUSE -> client.pause(listOf(task.hash))
                                TorrentAction.RESUME -> client.resume(listOf(task.hash))
                                TorrentAction.RESUME_FORCED -> client.forceStart(listOf(task.hash))
                                TorrentAction.RECHECK -> client.recheck(listOf(task.hash))
                                TorrentAction.REANNOUNCE -> client.reannounce(listOf(task.hash))
                                TorrentAction.DELETE, TorrentAction.DELETE_WITH_FILES ->
                                    client.delete(listOf(task.hash), action == TorrentAction.DELETE_WITH_FILES)
                            }
                        }
                    }
                }
            }
            state = state.copy(
                toast = result.exceptionOrNull()?.let { it.message ?: "操作失败" } ?: action.successText
            )
            if (result.isSuccess) {
                delay(400)
                refresh(showSpinner = false)
            }
        }
    }

    // ---------- 下载器页面：批量操作 / 备用限速 / 新增下载 ----------

    /**
     * 批量操作。
     *
     * tr 与 qb 的能力并不对称（qb 多了强制继续 / 自动种子管理 / 超级种子），
     * 菜单里只显示当前下载器支持的那几项，这里按 action 精确转发，不做「假装成功」。
     */
    fun performBatch(
        serverId: String,
        action: BatchAction,
        hashes: List<String>,
        location: String = ""
    ) {
        viewModelScope.launch {
            val server = state.servers.firstOrNull { it.id == serverId } ?: return@launch
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    when (server.type) {
                        ServerType.QBITTORRENT -> {
                            val client = QBittorrentClient(server)
                            when (action) {
                                BatchAction.RESUME_ALL -> client.resume(hashes)
                                BatchAction.PAUSE_ALL -> client.pause(hashes)
                                BatchAction.FORCE_RESUME_ALL -> client.forceStart(hashes)
                                BatchAction.RECHECK_ALL -> client.recheck(hashes)
                                BatchAction.REANNOUNCE_ALL -> client.reannounce(hashes)
                                BatchAction.AUTO_MANAGEMENT_ON -> client.setAutoManagement(hashes, true)
                                BatchAction.AUTO_MANAGEMENT_OFF -> client.setAutoManagement(hashes, false)
                                BatchAction.SUPER_SEEDING_ON -> client.setSuperSeeding(hashes, true)
                                BatchAction.SUPER_SEEDING_OFF -> client.setSuperSeeding(hashes, false)
                                BatchAction.CHANGE_LOCATION -> client.setLocation(hashes, location)
                                BatchAction.DELETE -> client.delete(hashes, false)
                                BatchAction.DELETE_WITH_FILES -> client.delete(hashes, true)
                            }
                        }

                        ServerType.TRANSMISSION -> {
                            val client = TransmissionClient(server)
                            when (action) {
                                BatchAction.RESUME_ALL ->
                                    if (hashes.isEmpty()) client.resumeAll() else client.resume(hashes)

                                BatchAction.PAUSE_ALL ->
                                    if (hashes.isEmpty()) client.pauseAll() else client.pause(hashes)

                                BatchAction.RECHECK_ALL ->
                                    if (hashes.isEmpty()) client.recheckAll() else client.recheck(hashes)

                                BatchAction.REANNOUNCE_ALL ->
                                    if (hashes.isEmpty()) client.reannounceAll() else client.reannounce(hashes)

                                BatchAction.CHANGE_LOCATION -> client.setLocation(hashes, location)
                                BatchAction.DELETE -> client.delete(hashes, false)
                                BatchAction.DELETE_WITH_FILES -> client.delete(hashes, true)
                                // tr 没有这几个概念，菜单不会显示；真被调用就按「继续」处理
                                BatchAction.FORCE_RESUME_ALL -> client.resume(hashes)
                                BatchAction.AUTO_MANAGEMENT_ON,
                                BatchAction.AUTO_MANAGEMENT_OFF,
                                BatchAction.SUPER_SEEDING_ON,
                                BatchAction.SUPER_SEEDING_OFF -> client.resume(hashes)
                            }
                        }
                    }
                }
            }
            state = state.copy(
                toast = result.exceptionOrNull()?.let { humanizeError(it) } ?: action.successText
            )
            if (result.isSuccess) {
                delay(400)
                refresh(showSpinner = false)
            }
        }
    }

    // ---------- 单任务编辑（点种子弹出的操作菜单 → 各级子页面） ----------

    /** 统一的单任务操作执行壳：失败原因走 toast，成功后刷新列表 */
    private fun runTaskOp(task: TorrentTask, successText: String, block: suspend (ServerConfig) -> Unit) {
        viewModelScope.launch {
            val server = state.servers.firstOrNull { it.id == task.serverId } ?: return@launch
            val result = runCatching { withContext(Dispatchers.IO) { block(server) } }
            state = state.copy(
                toast = result.exceptionOrNull()?.let { humanizeError(it) } ?: successText
            )
            if (result.isSuccess) {
                delay(350)
                refresh(showSpinner = false)
            }
        }
    }

    fun renameTask(task: TorrentTask, newName: String) {
        val name = newName.trim()
        if (name.isBlank()) return
        runTaskOp(task, "已重命名") { server ->
            when (server.type) {
                ServerType.QBITTORRENT -> QBittorrentClient(server).rename(task.hash, name)
                // tr 要「原路径」：单文件种子的路径就是文件名，多文件是顶层文件夹名，都等于种子名
                ServerType.TRANSMISSION -> TransmissionClient(server).rename(task.hash, task.name, name)
            }
        }
    }

    fun moveTask(task: TorrentTask, path: String) {
        val target = path.trim()
        if (target.isBlank()) return
        runTaskOp(task, "已更改保存位置") { server ->
            when (server.type) {
                ServerType.QBITTORRENT ->
                    QBittorrentClient(server).setLocation(listOf(task.hash), target)

                ServerType.TRANSMISSION ->
                    TransmissionClient(server).setLocation(listOf(task.hash), target)
            }
        }
    }

    /** [create] 为 true 时先建分类再挂上去（空分类名 = 重置为「无分类」） */
    fun assignCategory(
        task: TorrentTask,
        category: String,
        create: Boolean = false,
        savePath: String = ""
    ) {
        val name = category.trim()
        runTaskOp(
            task,
            if (name.isBlank()) "已重置分类" else "已设为分类「$name」"
        ) { server ->
            if (server.type != ServerType.QBITTORRENT) {
                throw ApiException("Transmission 没有分类这个概念")
            }
            val client = QBittorrentClient(server)
            if (create && name.isNotBlank()) client.createCategory(name, savePath.trim())
            client.setCategory(listOf(task.hash), name)
        }
    }

    /** [append] = 在原有标签后面追加（新增标签页用），否则整体替换 */
    fun assignTags(task: TorrentTask, tags: List<String>, append: Boolean = false) {
        val clean = tags.map { it.trim() }.filter { it.isNotEmpty() }
        val merged = if (append) (task.tags + clean).distinct() else clean
        runTaskOp(task, if (merged.isEmpty()) "已清空标签" else "已更新标签") { server ->
            if (server.type != ServerType.QBITTORRENT) {
                throw ApiException("Transmission 没有标签这个概念")
            }
            QBittorrentClient(server).setTags(listOf(task.hash), merged)
        }
    }

    /** 单任务限速，单位 KB/s，0 = 不限速 */
    fun setTaskSpeedLimit(task: TorrentTask, downloadKb: Long, uploadKb: Long) {
        runTaskOp(task, "已更新限速设置") { server ->
            when (server.type) {
                ServerType.QBITTORRENT -> {
                    val client = QBittorrentClient(server)
                    client.setDownloadLimit(listOf(task.hash), downloadKb * 1024)
                    client.setUploadLimit(listOf(task.hash), uploadKb * 1024)
                }

                ServerType.TRANSMISSION ->
                    TransmissionClient(server).setSpeedLimit(task.hash, downloadKb, uploadKb)
            }
        }
    }

    /** 分享率：mode -2 跟随全局 / -1 无限 / 0 自定义（值为 [ratio]） */
    fun setTaskShareLimit(task: TorrentTask, mode: Int, ratio: Double) {
        runTaskOp(task, "已更新分享率设置") { server ->
            when (server.type) {
                ServerType.QBITTORRENT -> QBittorrentClient(server).setShareLimit(
                    task.hash,
                    when (mode) {
                        -2 -> -2.0
                        -1 -> -1.0
                        else -> ratio
                    }
                )

                ServerType.TRANSMISSION -> TransmissionClient(server).setShareRatio(
                    task.hash,
                    when (mode) {
                        -2 -> 0
                        -1 -> 1
                        else -> 2
                    },
                    ratio
                )
            }
        }
    }

    // ---------------------------------------------------------------- Tracker 列表

    private fun trackerKey(task: TorrentTask): String = "${task.serverId}|${task.hash}"

    /** 打开 Tracker 弹窗：先清空再拉，避免上一颗种子的条目闪一下 */
    fun openTrackers(task: TorrentTask) {
        state = state.copy(trackers = TrackerState(taskKey = trackerKey(task), loading = true))
        reloadTrackers(task)
    }

    /** 关掉弹窗（状态一起清掉，下次打开不会看到旧数据） */
    fun closeTrackers() {
        if (state.trackers.taskKey.isEmpty() && !state.trackers.loading) return
        state = state.copy(trackers = TrackerState())
    }

    /** 重新拉 Tracker 列表：打开弹窗、改完、增删成功后都走这里 */
    fun reloadTrackers(task: TorrentTask) {
        val key = trackerKey(task)
        state = state.copy(trackers = state.trackers.copy(taskKey = key, loading = true, error = null))
        viewModelScope.launch {
            val server = state.servers.firstOrNull { it.id == task.serverId }
            val result = if (server == null) {
                Result.failure(ApiException("服务器不存在"))
            } else {
                runCatching {
                    withContext(Dispatchers.IO) {
                        when (server.type) {
                            ServerType.QBITTORRENT -> QBittorrentClient(server).trackers(task.hash)
                            ServerType.TRANSMISSION -> TransmissionClient(server).trackers(task.hash)
                        }
                    }
                }
            }
            // 弹窗已关 / 已换任务：旧请求回来不能覆盖当前列表
            if (state.trackers.taskKey != key) return@launch
            val current = state.trackers
            state = state.copy(
                trackers = current.copy(
                    // 失败时保留上一次的条目，至少还能看到原来有哪些 Tracker
                    items = result.getOrNull() ?: current.items,
                    loading = false,
                    error = result.exceptionOrNull()?.let { humanizeError(it) }
                )
            )
        }
    }

    /** 改一条 Tracker 的地址（qB 用原 URL 定位，tr 用 tracker id 定位） */
    fun editTracker(task: TorrentTask, entry: TrackerEntry, newUrl: String) {
        val url = newUrl.trim()
        if (url.isEmpty()) {
            state = state.copy(toast = "Tracker 地址不能为空")
            return
        }
        if (url == entry.url) return
        runTrackerOp(task, "Tracker 已更新") { server ->
            when (server.type) {
                ServerType.QBITTORRENT ->
                    QBittorrentClient(server).editTracker(task.hash, entry.url, url)

                ServerType.TRANSMISSION ->
                    TransmissionClient(server).editTracker(task.hash, entry.trackerId, url)
            }
        }
    }

    /** 追加一条 Tracker */
    fun addTracker(task: TorrentTask, newUrl: String) {
        val url = newUrl.trim()
        if (url.isEmpty()) {
            state = state.copy(toast = "Tracker 地址不能为空")
            return
        }
        runTrackerOp(task, "已添加 Tracker") { server ->
            when (server.type) {
                ServerType.QBITTORRENT -> QBittorrentClient(server).addTrackers(task.hash, listOf(url))
                ServerType.TRANSMISSION -> TransmissionClient(server).addTrackers(task.hash, listOf(url))
            }
        }
    }

    /** 删掉一条 Tracker */
    fun removeTracker(task: TorrentTask, entry: TrackerEntry) {
        runTrackerOp(task, "已删除 Tracker") { server ->
            when (server.type) {
                ServerType.QBITTORRENT -> QBittorrentClient(server).removeTrackers(task.hash, listOf(entry.url))
                ServerType.TRANSMISSION -> TransmissionClient(server).removeTrackers(task.hash, listOf(entry.trackerId))
            }
        }
    }

    /** 改 / 增 / 删的统一壳：busy 防重复提交，成功提示后重拉列表 */
    private fun runTrackerOp(
        task: TorrentTask,
        successText: String,
        block: suspend (ServerConfig) -> Unit
    ) {
        if (state.trackers.busy) return
        state = state.copy(trackers = state.trackers.copy(busy = true))
        viewModelScope.launch {
            val server = state.servers.firstOrNull { it.id == task.serverId }
            val result = if (server == null) {
                Result.failure(ApiException("服务器不存在"))
            } else {
                runCatching { withContext(Dispatchers.IO) { block(server) } }
            }
            state = state.copy(
                trackers = state.trackers.copy(busy = false),
                toast = result.exceptionOrNull()?.let { humanizeError(it) } ?: successText
            )
            if (result.isSuccess) reloadTrackers(task)
        }
    }

    /** 拉分类 / 标签清单（qb 才有），分类页和标签页打开时调用 */
    fun loadTaxonomy(serverId: String) {
        val server = state.servers.firstOrNull { it.id == serverId } ?: return
        if (server.type != ServerType.QBITTORRENT) return
        viewModelScope.launch {
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    val client = QBittorrentClient(server)
                    client.categories() to client.tags()
                }
            }
            result.onSuccess { (categories, tags) ->
                state = state.copy(
                    categories = state.categories + (serverId to categories),
                    tags = state.tags + (serverId to tags)
                )
            }
        }
    }

    /** 备用（计划）限速开关，对应右上角那个「仪表」按钮 */
    fun toggleAltSpeed(serverId: String) {
        // 连点会连发两次 toggle（切过去又切回来），还会撞上「服务器状态没变」的判定，直接忽略
        if (altSpeedBusy) return
        altSpeedBusy = true
        viewModelScope.launch {
          try {
            val server = state.servers.firstOrNull { it.id == serverId } ?: return@launch
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    when (server.type) {
                        // qB：客户端内部已经是「切完再读一次」
                        ServerType.QBITTORRENT -> QBittorrentClient(server).toggleAltSpeed()
                        // TR：以前是拿「快照值取反」当目标 —— 快照过期时会一直算成同一个方向，
                        // 每次都 setAltSpeed(true)，于是提示永远是同一句、按钮也关不掉。
                        // 改成「读 → 切 → 再读一次」，返回服务器真实状态（与鸿蒙一致）
                        ServerType.TRANSMISSION -> {
                            val client = TransmissionClient(server)
                            val before = client.isAltSpeedEnabled()
                            client.setAltSpeed(!before)
                            val after = client.isAltSpeedEnabled()
                            // 切完状态没变 = 服务器没真正应用，报错而不是假装成功
                            if (after == before) {
                                throw ApiException("Transmission 没有应用切换（服务器仍为${if (before) "开启" else "关闭"}）")
                            }
                            after
                        }
                    }
                }
            }
            state = state.copy(
                toast = result.exceptionOrNull()?.let { humanizeError(it) }
                    ?: if (result.getOrNull() == true) "已开启备用限速" else "已关闭备用限速"
            )
            if (result.isSuccess) {
                delay(300)
                refresh(showSpinner = false)
            }
          } finally {
            altSpeedBusy = false
          }
        }
    }

    /** 新增下载：URL/磁力 或 本地 .torrent，结果写进 state.addTorrent 给页面显示 */
    fun addTorrent(serverId: String, request: AddTorrentRequest) {
        viewModelScope.launch {
            val server = state.servers.firstOrNull { it.id == serverId } ?: return@launch
            state = state.copy(addTorrent = AddTorrentState(submitting = true))
            val result = runCatching {
                withContext(Dispatchers.IO) { submitAdd(server, request) }
            }
            result
                .onSuccess { count ->
                    state = state.copy(
                        addTorrent = AddTorrentState(
                            done = true,
                            message = if (count > 1) "已添加 $count 个任务" else "已添加 1 个任务"
                        )
                    )
                    refresh(showSpinner = false)
                }
                .onFailure { error ->
                    state = state.copy(addTorrent = AddTorrentState(error = humanizeError(error)))
                }
        }
    }

    fun clearAddTorrentState() {
        state = state.copy(addTorrent = AddTorrentState())
    }

    private suspend fun submitAdd(server: ServerConfig, request: AddTorrentRequest): Int {
        var urls = request.urls
        var bytes = request.fileBytes
        var fileName = request.fileName

        // 站点直链往往要带 Cookie 才给种子。tr/qb 的 RPC 都没有「单任务 Cookie」这个字段，
        // 所以带 Cookie 的 http(s) 链接由 App 自己抓下来，再当成种子文件交给下载器。
        if (bytes == null && urls.isNotEmpty() && request.cookie.isNotBlank()) {
            val fetched = fetchTorrentWithCookie(urls.first(), request.cookie)
            if (fetched != null) {
                bytes = fetched.first
                fileName = fetched.second
                urls = urls.drop(1)
            }
        }

        var count = 0
        when (server.type) {
            ServerType.TRANSMISSION -> {
                val client = TransmissionClient(server)
                bytes?.let {
                    client.addTorrentFile(it, request.savePath)
                    count++
                }
                if (urls.isNotEmpty()) {
                    client.addTorrents(urls, request.savePath)
                    count += urls.size
                }
            }

            ServerType.QBITTORRENT -> {
                val client = QBittorrentClient(server)
                bytes?.let {
                    client.addTorrentFile(
                        bytes = it,
                        fileName = fileName,
                        savePath = request.savePath,
                        rename = request.rename,
                        category = request.category,
                        autoTmm = request.autoTmm,
                        skipHashCheck = request.skipHashCheck
                    )
                    count++
                }
                if (urls.isNotEmpty()) {
                    client.addTorrentUrls(
                        urls = urls,
                        savePath = request.savePath,
                        rename = request.rename,
                        category = request.category,
                        autoTmm = request.autoTmm,
                        skipHashCheck = request.skipHashCheck
                    )
                    count += urls.size
                }
            }
        }
        if (count == 0) throw ApiException("没有可提交的链接或种子文件")
        return count
    }

    /** 带 Cookie 抓 .torrent；返回 null 表示这不是一个能直接下载的种子（退回给下载器自己处理） */
    private fun fetchTorrentWithCookie(url: String, cookie: String): Pair<ByteArray, String>? {
        if (!url.startsWith("http", ignoreCase = true)) return null
        return runCatching {
            val request = okhttp3.Request.Builder()
                .url(url)
                .header("Cookie", cookie)
                .get()
                .build()
            Net.slowClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return null
                val body = response.body?.bytes() ?: return null
                // torrent 是 bencode，第一个字节必定是 'd'
                if (body.isEmpty() || body[0] != 'd'.code.toByte()) return null
                val name = response.request.url.pathSegments.lastOrNull()
                    .orEmpty()
                    .ifBlank { "download.torrent" }
                    .let { if (it.endsWith(".torrent", true)) it else "$it.torrent" }
                body to name
            }
        }.getOrNull()
    }

    private fun humanizeError(error: Throwable): String {
        val raw = error.message ?: error.javaClass.simpleName
        return when {
            raw.contains("timeout", true) -> "连接超时：检查下载器地址/端口是否可达"
            raw.contains("Failed to connect", true) || raw.contains("Connection refused", true) ->
                "连不上下载器：地址或端口不通"
            raw.contains("401", true) || raw.contains("认证失败", true) ->
                "认证失败：用户名或密码不对"
            raw.contains("403", true) -> "被拒绝（403）：可能触发了 qB 的 IP 封禁，或会话已失效"
            else -> raw
        }
    }

    suspend fun testConnection(config: ServerConfig): Result<String> = withContext(Dispatchers.IO) {
        runCatching {
            val tasks = when (config.type) {
                ServerType.QBITTORRENT -> QBittorrentClient(config).fetchAll().first
                ServerType.TRANSMISSION -> TransmissionClient(config).fetchAll().first
            }
            "连接成功，共 ${tasks.size} 个任务"
        }
    }

    fun consumeToast() {
        state = state.copy(toast = null)
    }
}

enum class TorrentAction(val successText: String) {
    PAUSE("已暂停"),
    RESUME("已继续"),
    /** qb 的强制开始（忽略队列限制）；tr 没有这个概念，按普通继续处理 */
    RESUME_FORCED("已强制继续"),
    RECHECK("已开始校验"),
    REANNOUNCE("已重新汇报"),
    DELETE("已删除任务"),
    DELETE_WITH_FILES("已删除任务和文件")
}

/** 下载器页面「批量操作」菜单里的动作；tr 不支持的那几项不会出现在菜单里 */
enum class BatchAction(val successText: String) {
    RESUME_ALL("已全部继续"),
    PAUSE_ALL("已全部暂停"),
    FORCE_RESUME_ALL("已全部强制继续"),
    RECHECK_ALL("已开始全部校验"),
    REANNOUNCE_ALL("已全部重新汇报"),
    AUTO_MANAGEMENT_ON("已开启自动种子管理"),
    AUTO_MANAGEMENT_OFF("已关闭自动种子管理"),
    SUPER_SEEDING_ON("已开启超级种子模式"),
    SUPER_SEEDING_OFF("已关闭超级种子模式"),
    CHANGE_LOCATION("已更改保存位置"),
    DELETE("已删除任务"),
    DELETE_WITH_FILES("已删除任务和文件")
}

/**
 * 新增下载的表单。
 *
 * `fileBytes` 与 `urls` 二选一：[fileBytes] 来自手机本地选择的 .torrent，
 * [urls] 是磁力/直链（一行一个）。Cookie 只有 http(s) 直链才有意义 ——
 * tr 与 qb 的 RPC 都不接受单任务 Cookie，所以带 Cookie 的直链由 App 先抓到文件再交给下载器。
 */
data class AddTorrentRequest(
    val urls: List<String> = emptyList(),
    val fileBytes: ByteArray? = null,
    val fileName: String = "",
    val savePath: String = "",
    val rename: String = "",
    val cookie: String = "",
    /** qb 的分类名（qb 里已有的分类，空 = 不分类）。tr 没有分类，忽略。 */
    val category: String = "",
    val autoTmm: Boolean = false,
    val skipHashCheck: Boolean = false
)

/** 新增下载页面的提交状态 */
data class AddTorrentState(
    val submitting: Boolean = false,
    val done: Boolean = false,
    val error: String? = null,
    val message: String = ""
)

/** 单任务操作菜单里带箭头的下一级页面 */
enum class TaskEditMode(val title: String) {
    RENAME("重命名"),
    LOCATION("更改保存位置"),
    CATEGORY("分类"),
    TAG("标签"),
    SPEED("限速设置"),
    SHARE("分享率设置")
}

/** 状态筛选 */
enum class StatusFilter(val label: String) {    ALL("全部"),
    DOWNLOADING("下载"),
    PAUSED("暂停"),
    SEEDING("做种"),
    ACTIVE("活动"),
    COMPLETED("完成"),
    CHECKING("检查"),
    ERROR("错误")
}

fun TorrentTask.matches(filter: StatusFilter): Boolean = when (filter) {
    StatusFilter.ALL -> true
    StatusFilter.DOWNLOADING -> status == TorrentStatus.DOWNLOADING || status == TorrentStatus.QUEUED
    StatusFilter.SEEDING -> status == TorrentStatus.SEEDING
    StatusFilter.ACTIVE -> downloadSpeed > 0 || uploadSpeed > 0
    StatusFilter.COMPLETED -> isFinished && status != TorrentStatus.SEEDING
    StatusFilter.PAUSED -> status == TorrentStatus.PAUSED
    StatusFilter.CHECKING -> status == TorrentStatus.CHECKING
    StatusFilter.ERROR -> status == TorrentStatus.ERROR
}

fun ApiException.orMessage(): String = message ?: "未知错误"
