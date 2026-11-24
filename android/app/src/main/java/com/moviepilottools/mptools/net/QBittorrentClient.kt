package com.moviepilottools.mptools.net

import com.moviepilottools.mptools.data.Endpoint
import com.moviepilottools.mptools.data.ServerConfig
import com.moviepilottools.mptools.data.ServerSnapshot
import com.moviepilottools.mptools.data.ServerType
import com.moviepilottools.mptools.data.TorrentStatus
import com.moviepilottools.mptools.data.TorrentTask
import com.moviepilottools.mptools.data.TrackerEntry
import com.moviepilottools.mptools.data.trackerHostOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

class QBittorrentClient(private val server: ServerConfig) {

    private val authHeaders = mutableMapOf<String, String>()

    private suspend fun withEndpoint(
        probe: suspend (Endpoint) -> Boolean,
        block: suspend (Endpoint) -> Unit
    ) {
        var endpoint = EndpointResolver.resolve(server, probe)
        try {
            block(endpoint)
        } catch (e: Exception) {
            // 地址切换：清掉缓存，换下一个候选再试一次
            EndpointResolver.invalidate(server.id)
            val retry = EndpointResolver.resolve(server, probe)
            if (retry.hostKey() == endpoint.hostKey()) throw e
            endpoint = retry
            block(endpoint)
        }
    }

    private suspend fun probe(endpoint: Endpoint): Boolean = withContext(Dispatchers.IO) {
        runCatching {
            val response = Net.probeClient.newCall(
                okhttp3.Request.Builder()
                    .url(endpoint.url("api/v2/app/webapiVersion"))
                    .header("Referer", endpoint.display)
                    .get()
                    .build()
            ).execute()
            response.use { it.code in 200..499 }
        }.getOrDefault(false)
    }

    private suspend fun ensureLogin(endpoint: Endpoint) = withContext(Dispatchers.IO) {
        val key = endpoint.hostKey()
        if (authHeaders[key] != null) return@withContext

        if (server.useApiKey && server.apiKey.isNotBlank()) {
            authHeaders[key] = "Bearer ${server.apiKey}"
            return@withContext
        }

        val response = Net.postForm(
            endpoint.url("api/v2/auth/login"),
            mapOf("username" to server.username, "password" to server.password),
            mapOf("Referer" to endpoint.display, "Origin" to endpoint.display)
        )
        response.use {
            val body = it.body?.string().orEmpty()
            val ok = it.code in 200..299 && !body.contains("Fails", ignoreCase = true)
            if (!ok) {
                throw ApiException(
                    if (it.code == 403) "登录被拒绝：用户名或密码错误，或 IP 被临时封禁" else "登录失败 HTTP ${it.code}"
                )
            }
        }
        authHeaders[key] = ""
    }

    private fun headersFor(endpoint: Endpoint): Map<String, String> {
        val auth = authHeaders[endpoint.hostKey()] ?: ""
        val base = mutableMapOf("Referer" to endpoint.display, "Accept" to "application/json")
        if (auth.startsWith("Bearer ")) base["Authorization"] = auth
        return base
    }

    /** 一次拉回任务列表 + 服务器状态，失败抛 ApiException */
    suspend fun fetchAll(): Pair<List<TorrentTask>, ServerSnapshot> = withContext(Dispatchers.IO) {
        var tasks: List<TorrentTask> = emptyList()
        var snapshot: ServerSnapshot? = null
        var lastError: Exception? = null

        withEndpoint({ probe(it) }) { endpoint ->
            try {
                ensureLogin(endpoint)
                val torrentsJson = Net.get(endpoint.url("api/v2/torrents/info"), headersFor(endpoint)).use { response ->
                    if (response.code == 403) {
                        authHeaders.remove(endpoint.hostKey())
                        throw ApiException("会话失效（HTTP 403）")
                    }
                    if (!response.isSuccessful) throw ApiException("获取任务失败 HTTP ${response.code}")
                    response.body?.string().orEmpty()
                }

                val syncJson = runCatching {
                    Net.get(endpoint.url("api/v2/sync/maindata?rid=0"), headersFor(endpoint)).use { response ->
                        if (response.isSuccessful) response.body?.string().orEmpty() else ""
                    }
                }.getOrDefault("")

                // 版本号 / 备用限速状态：侧边栏和「仪表」按钮要显示，缺了就只能瞎猜
                val version = runCatching {
                    Net.get(endpoint.url("api/v2/app/version"), headersFor(endpoint)).use { response ->
                        if (response.isSuccessful) response.body?.string().orEmpty().trim() else ""
                    }
                }.getOrDefault("")
                val altRead = runCatching { speedLimitsMode(endpoint) }
                val altSpeed = altRead.getOrDefault(false)
                val altKnown = altRead.isSuccess

                tasks = parseTorrents(torrentsJson)
                snapshot = buildSnapshot(tasks, syncJson, endpoint, version, altSpeed, altKnown)
            } catch (e: Exception) {
                lastError = e
                throw e
            }
        }

        val snap = snapshot ?: throw (lastError ?: ApiException("连接失败"))
        tasks to snap
    }

    private fun parseTorrents(raw: String): List<TorrentTask> {
        if (raw.isBlank()) return emptyList()
        val array = runCatching { JSONArray(raw) }.getOrElse { throw ApiException("任务列表解析失败") }
        val result = ArrayList<TorrentTask>(array.length())
        val now = System.currentTimeMillis()

        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: continue
            val state = obj.optString("state").lowercase()
            val tracker = obj.optString("tracker")
            val tagsRaw = obj.optString("tags")
            val addedOn = obj.optLong("added_on", 0L)
            val completionOn = obj.optLong("completion_on", 0L)

            result += TorrentTask(
                hash = obj.optString("hash"),
                serverId = server.id,
                serverType = ServerType.QBITTORRENT,
                name = obj.optString("name"),
                progress = obj.optDouble("progress", 0.0).coerceIn(0.0, 1.0),
                size = obj.optLong("size", 0L),
                downloaded = obj.optLong("downloaded", 0L),
                uploaded = obj.optLong("uploaded", 0L),
                downloadSpeed = obj.optLong("dlspeed", 0L),
                uploadSpeed = obj.optLong("upspeed", 0L),
                status = mapState(state),
                etaSeconds = obj.optLong("eta", 0L).let { if (it >= 8640000L) -1 else it },
                ratio = obj.optDouble("ratio", 0.0),
                numSeeds = obj.optInt("num_seeds", 0),
                totalSeeds = obj.optInt("num_complete", 0),
                numPeers = obj.optInt("num_leechs", 0),
                totalPeers = obj.optInt("num_incomplete", 0),
                category = obj.optString("category"),
                tags = if (tagsRaw.isBlank()) emptyList()
                else tagsRaw.split(",").map { it.trim() }.filter { it.isNotEmpty() },
                savePath = obj.optString("save_path"),
                trackerHost = trackerHostOf(tracker),
                addedAt = if (addedOn > 0) addedOn * 1000 else now,
                completedAt = if (completionOn > 0) completionOn * 1000 else 0L,
                seedingSeconds = obj.optLong("seeding_time", 0L),
                errorMessage = if (mapState(state) == TorrentStatus.ERROR) state else "",
                isSequential = obj.optBoolean("seq_dl", false),
                availability = obj.optDouble("availability", 0.0),
                // qb 用 -1 表示不限速，App 内部统一成 0
                downloadLimit = obj.optLong("dl_limit", -1L).coerceAtLeast(0L),
                uploadLimit = obj.optLong("up_limit", -1L).coerceAtLeast(0L),
                // qb 的 ratio_limit：-2 全局 / -1 无限 / 其他=自定义值
                ratioMode = when (val mode = obj.optLong("ratio_limit", -2L)) {
                    -2L -> -2
                    -1L -> -1
                    else -> 0
                },
                ratioLimit = obj.optDouble("ratio_limit", 0.0).coerceAtLeast(0.0)
            )
        }
        return result
    }

    private fun buildSnapshot(
        tasks: List<TorrentTask>,
        syncJson: String,
        endpoint: Endpoint,
        version: String = "",
        altSpeed: Boolean = false,
        altKnown: Boolean = false
    ): ServerSnapshot {
        var freeSpace = 0L
        var allTimeDl = 0L
        var allTimeUl = 0L
        // 只有 sync/maindata 的 server_state 真的带回了 alltime_dl/alltime_ul，
        // 这两个数才是「装机以来全量累计」。失败时绝不能用 tasks.sumOf 兜底：
        // 任务累计和会随删种变小，和全量计数器不是一个口径，拿去做流量基线会直接算错。
        var cumulativeReliable = false
        var dlSpeed = 0L
        var upSpeed = 0L
        var defaultSavePath = ""

        if (syncJson.isNotBlank()) {
            val serverState = runCatching { JSONObject(syncJson).optJSONObject("server_state") }.getOrNull()
            if (serverState != null) {
                freeSpace = serverState.optLong("free_space_on_disk", 0L)
                cumulativeReliable = serverState.has("alltime_dl") && serverState.has("alltime_ul")
                if (cumulativeReliable) {
                    allTimeDl = serverState.optLong("alltime_dl", 0L)
                    allTimeUl = serverState.optLong("alltime_ul", 0L)
                }
                dlSpeed = serverState.optLong("dl_info_speed", 0L)
                upSpeed = serverState.optLong("up_info_speed", 0L)
                defaultSavePath = serverState.optString("save_path")
            }
        }

        val seeding = tasks.filter { it.status == TorrentStatus.SEEDING || (it.isFinished && it.status != TorrentStatus.PAUSED) }
        val downloading = tasks.filter { it.status == TorrentStatus.DOWNLOADING || it.status == TorrentStatus.QUEUED }

        return ServerSnapshot(
            serverId = server.id,
            online = true,
            downloadSpeed = if (dlSpeed > 0) dlSpeed else tasks.sumOf { it.downloadSpeed },
            uploadSpeed = if (upSpeed > 0) upSpeed else tasks.sumOf { it.uploadSpeed },
            seedingCount = seeding.size,
            downloadingCount = downloading.size,
            seedingSize = seeding.sumOf { it.size },
            totalUploaded = allTimeUl,
            totalDownloaded = allTimeDl,
            cumulativeReliable = cumulativeReliable,
            freeSpace = freeSpace,
            endpointLabel = endpoint.display,
            appVersion = version,
            altSpeedEnabled = altSpeed,
            altSpeedKnown = altKnown,
            defaultSavePath = defaultSavePath
        )
    }

    private fun mapState(state: String): TorrentStatus = when (state) {
        "metadl", "allocating", "downloading", "dl", "stalleddl", "forceddl", "forcedmetadl" -> TorrentStatus.DOWNLOADING
        "queueddl", "queuedup" -> TorrentStatus.QUEUED
        "uploading", "stalledup", "forcedup", "up" -> TorrentStatus.SEEDING
        "pauseddl", "pausedup", "paused", "stoppeddl", "stoppedup" -> TorrentStatus.PAUSED
        "checkingdl", "checkingup", "checkingresumedata", "moving" -> TorrentStatus.CHECKING
        "error", "missingfiles", "unregistered", "unregisteredtorrent", "unknown" -> TorrentStatus.ERROR
        "completed" -> TorrentStatus.COMPLETED
        else -> TorrentStatus.PAUSED
    }

    // ---------- 操作 ----------

    /** 备用限速：qB 的 speedLimitsMode（"1" = 已开启备用限速；新版本可能返回 "true"） */
    private suspend fun speedLimitsMode(endpoint: Endpoint): Boolean {
        ensureLogin(endpoint)
        // 带时间戳绕开反代/系统缓存：这是「当前状态」接口，绝不能拿到上一轮的结果
        val url = endpoint.url("api/v2/transfer/speedLimitsMode?_=${System.currentTimeMillis()}")
        return Net.get(url, headersFor(endpoint)).use { response ->
            // 不能把错误页当成「0」：那会得出「已关闭」的假结论
            if (!response.isSuccessful) throw ApiException("读取限速状态失败 HTTP ${response.code}")
            val body = response.body?.string().orEmpty().trim().lowercase()
            body == "1" || body == "true"
        }
    }

    suspend fun isAltSpeedEnabled(): Boolean = withContext(Dispatchers.IO) {
        var result = false
        withEndpoint({ probe(it) }) { endpoint -> result = speedLimitsMode(endpoint) }
        result
    }

    /** 切一次备用限速，返回切换后的状态（该接口不返回状态，只能再读一次） */
    suspend fun toggleAltSpeed(): Boolean = withContext(Dispatchers.IO) {
        var enabled = false
        withEndpoint({ probe(it) }) { endpoint ->
            ensureLogin(endpoint)
            val before = speedLimitsMode(endpoint)
            Net.postForm(
                endpoint.url("api/v2/transfer/toggleSpeedLimitsMode"),
                emptyMap(),
                headersFor(endpoint)
            ).use {
                if (!it.isSuccessful) throw ApiException("切换限速失败 HTTP ${it.code}")
            }
            enabled = speedLimitsMode(endpoint)
            // 切完状态没变 = 服务器没真正应用，这时报错，别让图标亮着却什么都没发生
            if (enabled == before) {
                throw ApiException("qBittorrent 没有应用切换（服务器仍为${if (before) "开启" else "关闭"}）")
            }
        }
        enabled
    }

    suspend fun pause(hashes: List<String>) = action("api/v2/torrents/stop", hashes)
    suspend fun resume(hashes: List<String>) = action("api/v2/torrents/start", hashes)
    suspend fun recheck(hashes: List<String>) = action("api/v2/torrents/recheck", hashes)
    suspend fun reannounce(hashes: List<String>) = action("api/v2/torrents/reannounce", hashes)

    /** 全部强制继续（强制开始，忽略队列限制） */
    suspend fun forceStart(hashes: List<String>) = postTorrents(
        "api/v2/torrents/setForceStart",
        mapOf("hashes" to hashes.joinToString("|"), "value" to "true")
    )

    suspend fun setLocation(hashes: List<String>, location: String) = postTorrents(
        "api/v2/torrents/setLocation",
        mapOf("hashes" to hashes.joinToString("|"), "location" to location)
    )

    suspend fun setAutoManagement(hashes: List<String>, enable: Boolean) = postTorrents(
        "api/v2/torrents/setAutoManagement",
        mapOf("hashes" to hashes.joinToString("|"), "enable" to enable.toString())
    )

    suspend fun setSuperSeeding(hashes: List<String>, enable: Boolean) = postTorrents(
        "api/v2/torrents/setSuperSeeding",
        mapOf("hashes" to hashes.joinToString("|"), "value" to enable.toString())
    )

    // ---------- 单任务操作（点种子弹出的那一串菜单用） ----------

    /** 重命名：改种子名（单文件）或顶层文件夹名，qb 会顺带改磁盘上的名字 */
    suspend fun rename(hash: String, newName: String) = postTorrents(
        "api/v2/torrents/rename",
        mapOf("hashes" to hash, "name" to newName)
    )

    suspend fun setCategory(hashes: List<String>, category: String) = postTorrents(
        "api/v2/torrents/setCategory",
        mapOf("hashes" to hashes.joinToString("|"), "category" to category)
    )

    suspend fun createCategory(name: String, savePath: String = "") {
        val form = mutableMapOf("category" to name)
        if (savePath.isNotBlank()) form["savePath"] = savePath
        postTorrents("api/v2/torrents/createCategory", form)
    }

    /** setTags 是「替换」，不是追加 —— 追加要在调用方把原标签一起传进来 */
    suspend fun setTags(hashes: List<String>, tags: List<String>) = postTorrents(
        "api/v2/torrents/setTags",
        mapOf("hashes" to hashes.joinToString("|"), "tags" to tags.joinToString(","))
    )

    /** 单任务限速：limit 单位 bytes/s，0 = 不限速 */
    suspend fun setDownloadLimit(hashes: List<String>, bytesPerSecond: Long) = postTorrents(
        "api/v2/torrents/setDownloadLimit",
        mapOf("hashes" to hashes.joinToString("|"), "limit" to bytesPerSecond.coerceAtLeast(0).toString())
    )

    suspend fun setUploadLimit(hashes: List<String>, bytesPerSecond: Long) = postTorrents(
        "api/v2/torrents/setUploadLimit",
        mapOf("hashes" to hashes.joinToString("|"), "limit" to bytesPerSecond.coerceAtLeast(0).toString())
    )

    /**
     * 分享率限制：setShareLimits 的三个限制都是必填，缺一个 qB 会整体拒绝。
     * 做种时间限制（seedingTimeLimit / inactiveSeedingTimeLimit）先读回任务当前值再原样传，
     * 免得为了改分享率把用户的做种时间策略顺手清掉。
     */
    suspend fun setShareLimit(hash: String, ratioLimit: Double) = withContext(Dispatchers.IO) {
        withEndpoint({ probe(it) }) { endpoint ->
            ensureLogin(endpoint)
            val current = runCatching {
                Net.get(endpoint.url("api/v2/torrents/info?hashes=$hash"), headersFor(endpoint)).use { r ->
                    if (r.isSuccessful) JSONArray(r.body?.string().orEmpty()) else JSONArray()
                }
            }.getOrDefault(JSONArray()).optJSONObject(0)
            val seedingTime = current?.optLong("seeding_time_limit", -2L) ?: -2L
            val inactiveTime = current?.optLong("inactive_seeding_time_limit", -2L) ?: -2L

            Net.postForm(
                endpoint.url("api/v2/torrents/setShareLimits"),
                mapOf(
                    "hashes" to hash,
                    "ratioLimit" to ratioValue(ratioLimit),
                    "seedingTimeLimit" to seedingTime.toString(),
                    "inactiveSeedingTimeLimit" to inactiveTime.toString()
                ),
                headersFor(endpoint)
            ).use {
                if (!it.isSuccessful) throw ApiException("分享率设置失败 HTTP ${it.code}")
            }
        }
    }

    /** 已有分类名列表（列表页要显示，选中当前分类） */
    suspend fun categories(): List<String> = withContext(Dispatchers.IO) {
        var result: List<String> = emptyList()
        withEndpoint({ probe(it) }) { endpoint ->
            ensureLogin(endpoint)
            result = Net.get(endpoint.url("api/v2/torrents/categories"), headersFor(endpoint)).use { r ->
                if (!r.isSuccessful) throw ApiException("获取分类失败 HTTP ${r.code}")
                runCatching { JSONObject(r.body?.string().orEmpty()) }.getOrNull()
                    ?.keys()?.asSequence()?.filter { it.isNotBlank() }?.toList().orEmpty()
            }
        }
        result
    }

    /** 已有标签名列表 */
    suspend fun tags(): List<String> = withContext(Dispatchers.IO) {
        var result: List<String> = emptyList()
        withEndpoint({ probe(it) }) { endpoint ->
            ensureLogin(endpoint)
            result = Net.get(endpoint.url("api/v2/torrents/tags"), headersFor(endpoint)).use { r ->
                if (!r.isSuccessful) throw ApiException("获取标签失败 HTTP ${r.code}")
                val array = runCatching { JSONArray(r.body?.string().orEmpty()) }.getOrNull()
                buildList {
                    if (array != null) {
                        for (i in 0 until array.length()) {
                            val name = array.optString(i).trim()
                            if (name.isNotEmpty()) add(name)
                        }
                    }
                }
            }
        }
        result
    }

    /**
     * 单个任务的 Tracker 列表（`torrents/trackers`）。
     *
     * 返回里除了真 Tracker 还有 DHT / PEX / LSD 三条伪 Tracker（URL 形如 `** [DHT] **`），
     * 这里原样返回、由 [TrackerEntry.special] 标记，UI 只展示不让编辑。
     */
    suspend fun trackers(hash: String): List<TrackerEntry> = withContext(Dispatchers.IO) {
        var result: List<TrackerEntry> = emptyList()
        withEndpoint({ probe(it) }) { endpoint ->
            ensureLogin(endpoint)
            result = Net.get(
                endpoint.url("api/v2/torrents/trackers?hash=${java.net.URLEncoder.encode(hash, "UTF-8")}"),
                headersFor(endpoint)
            ).use { r ->
                if (!r.isSuccessful) throw ApiException("获取 Tracker 失败 HTTP ${r.code}")
                val array = runCatching { JSONArray(r.body?.string().orEmpty()) }.getOrNull()
                buildList {
                    if (array != null) {
                        for (i in 0 until array.length()) {
                            val o = array.optJSONObject(i) ?: continue
                            val url = o.optString("url").trim()
                            if (url.isEmpty()) continue
                            add(
                                TrackerEntry(
                                    url = url,
                                    status = o.optInt("status", TrackerEntry.Status.UNKNOWN),
                                    tier = o.optInt("tier", 0),
                                    seeds = o.optInt("num_seeds", 0),
                                    leeches = o.optInt("num_leeches", 0),
                                    peers = o.optInt("num_peers", 0),
                                    message = o.optString("msg").trim()
                                )
                            )
                        }
                    }
                }
            }
        }
        result
    }

    /** 改一条 Tracker 的地址：origUrl 必须和服务器上的原值一字不差 */
    suspend fun editTracker(hash: String, origUrl: String, newUrl: String) = postTorrents(
        "api/v2/torrents/editTracker",
        mapOf("hash" to hash, "origUrl" to origUrl, "newUrl" to newUrl)
    )

    /** 追加 Tracker（多条用换行分隔），qB 会把它们并进默认 tier */
    suspend fun addTrackers(hash: String, urls: List<String>) = postTorrents(
        "api/v2/torrents/addTrackers",
        mapOf("hash" to hash, "urls" to urls.joinToString("\n"))
    )

    /** 删除 Tracker：qB 这里多条要用 `|` 分隔（不是换行） */
    suspend fun removeTrackers(hash: String, urls: List<String>) = postTorrents(
        "api/v2/torrents/removeTrackers",
        mapOf("hash" to hash, "urls" to urls.joinToString("|"))
    )

    private fun ratioValue(value: Double): String =
        if (value == value.toLong().toDouble()) value.toLong().toString()
        else String.format(java.util.Locale.US, "%.2f", value)

    private suspend fun postTorrents(path: String, form: Map<String, String>) = withContext(Dispatchers.IO) {
        withEndpoint({ probe(it) }) { endpoint ->
            ensureLogin(endpoint)
            Net.postForm(endpoint.url(path), form, headersFor(endpoint)).use {
                if (!it.isSuccessful) throw ApiException("操作失败 HTTP ${it.code}")
            }
        }
    }

    suspend fun delete(hashes: List<String>, deleteFiles: Boolean) = withContext(Dispatchers.IO) {
        var lastError: Exception? = null
        withEndpoint({ probe(it) }) { endpoint ->
            ensureLogin(endpoint)
            val form = mapOf(
                "hashes" to hashes.joinToString("|"),
                "deleteFiles" to deleteFiles.toString()
            )
            val response = Net.postForm(
                endpoint.url("api/v2/torrents/delete"), form, headersFor(endpoint)
            )
            response.use {
                if (!it.isSuccessful) {
                    lastError = ApiException("删除失败 HTTP ${it.code}")
                    throw lastError as ApiException
                }
            }
        }
    }

    private suspend fun action(path: String, hashes: List<String>) = withContext(Dispatchers.IO) {
        withEndpoint({ probe(it) }) { endpoint ->
            ensureLogin(endpoint)
            val response = Net.postForm(
                endpoint.url(path),
                mapOf("hashes" to hashes.joinToString("|")),
                headersFor(endpoint)
            )
            response.use {
                if (!it.isSuccessful) throw ApiException("操作失败 HTTP ${it.code}")
            }
        }
    }

    /**
     * 批量添加种子（RSS 自动下载用）。支持 magnet / http 直链。
     * qB 4.x 用 paused，5.x 改名为 stopped，这里两个都发，老版本会忽略不认识的字段。
     */
    suspend fun addTorrents(
        urls: List<String>,
        savePath: String = "",
        category: String = "",
        paused: Boolean = false,
        firstLastPiecePriority: Boolean = false
    ) = withContext(Dispatchers.IO) {
        val targets = urls.map { it.trim() }.filter { it.isNotEmpty() }
        if (targets.isEmpty()) return@withContext

        withEndpoint({ probe(it) }) { endpoint ->
            ensureLogin(endpoint)
            val form = mutableMapOf(
                "urls" to targets.joinToString("\n"),
                "autoTMM" to "false"
            )
            if (savePath.isNotBlank()) form["savepath"] = savePath
            if (category.isNotBlank()) form["category"] = category
            if (paused) {
                form["paused"] = "true"
                form["stopped"] = "true"
            }
            if (firstLastPiecePriority) {
                form["firstLastPiecePrio"] = "true"
                form["sequentialDownload"] = "true"
            }
            Net.postForm(endpoint.url("api/v2/torrents/add"), form, headersFor(endpoint)).use {
                val body = it.body?.string().orEmpty()
                if (!it.isSuccessful) throw ApiException("添加任务失败 HTTP ${it.code}")
                if (body.contains("Fails", ignoreCase = true)) {
                    throw ApiException("qBittorrent 拒绝该种子（链接可能失效或站点需要登录）")
                }
            }
        }
    }

    /**
     * 新增下载页专用：比 RSS 那条多了重命名 / 自动种子管理 / 跳过哈希校验。
     * 这些在 qB 网页版「新增种子」里都是可选项，下载器设置里也一样。
     */
    suspend fun addTorrentUrls(
        urls: List<String>,
        savePath: String = "",
        rename: String = "",
        category: String = "",
        autoTmm: Boolean = false,
        skipHashCheck: Boolean = false,
        paused: Boolean = false
    ) = withContext(Dispatchers.IO) {
        val targets = urls.map { it.trim() }.filter { it.isNotEmpty() }
        if (targets.isEmpty()) return@withContext

        withEndpoint({ probe(it) }) { endpoint ->
            ensureLogin(endpoint)
            val form = mutableMapOf("urls" to targets.joinToString("\n"), "autoTMM" to autoTmm.toString())
            if (savePath.isNotBlank()) form["savepath"] = savePath
            if (rename.isNotBlank()) form["rename"] = rename
            if (category.isNotBlank()) form["category"] = category
            if (skipHashCheck) form["skip_checking"] = "true"
            if (paused) {
                form["paused"] = "true"
                form["stopped"] = "true"
            }
            Net.postForm(endpoint.url("api/v2/torrents/add"), form, headersFor(endpoint)).use {
                val body = it.body?.string().orEmpty()
                if (!it.isSuccessful) throw ApiException("添加任务失败 HTTP ${it.code}")
                if (body.contains("Fails", ignoreCase = true)) {
                    throw ApiException("qBittorrent 拒绝该种子（链接可能失效或站点需要登录）")
                }
            }
        }
    }

    /**
     * 本地上传 .torrent：qB 只认 multipart 文件字段 `torrents`，
     * 不能像 tr 那样塞 base64，所以这里单独走一次 multipart 请求。
     */
    suspend fun addTorrentFile(
        bytes: ByteArray,
        fileName: String,
        savePath: String = "",
        rename: String = "",
        category: String = "",
        autoTmm: Boolean = false,
        skipHashCheck: Boolean = false
    ) = withContext(Dispatchers.IO) {
        if (bytes.isEmpty()) throw ApiException("种子文件是空的")
        withEndpoint({ probe(it) }) { endpoint ->
            ensureLogin(endpoint)
            val multipart = okhttp3.MultipartBody.Builder()
                .setType(okhttp3.MultipartBody.FORM)
                .addFormDataPart(
                    "torrents",
                    fileName.ifBlank { "upload.torrent" },
                    bytes.toRequestBody("application/x-bittorrent".toMediaType())
                )
                .apply {
                    if (savePath.isNotBlank()) addFormDataPart("savepath", savePath)
                    if (rename.isNotBlank()) addFormDataPart("rename", rename)
                    if (category.isNotBlank()) addFormDataPart("category", category)
                    addFormDataPart("autoTMM", autoTmm.toString())
                    if (skipHashCheck) addFormDataPart("skip_checking", "true")
                }
                .build()
            Net.post(endpoint.url("api/v2/torrents/add"), multipart, headersFor(endpoint)).use {
                val body = it.body?.string().orEmpty()
                if (!it.isSuccessful) throw ApiException("添加任务失败 HTTP ${it.code}")
                if (body.contains("Fails", ignoreCase = true)) throw ApiException("qBittorrent 拒绝该种子文件")
            }
        }
    }
}
