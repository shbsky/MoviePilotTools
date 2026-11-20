package com.oiiqt.android.net

import com.oiiqt.android.data.Endpoint
import com.oiiqt.android.data.ServerConfig
import com.oiiqt.android.data.ServerSnapshot
import com.oiiqt.android.data.ServerType
import com.oiiqt.android.data.TorrentStatus
import com.oiiqt.android.data.TorrentTask
import com.oiiqt.android.data.TrackerEntry
import com.oiiqt.android.data.trackerHostOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

class TransmissionClient(private val server: ServerConfig) {

    private val sessionIds = ConcurrentHashMap<String, String>()

    private fun rpcUrl(endpoint: Endpoint): String {
        val path = server.rpcPath.ifBlank { "/transmission/rpc" }
        return endpoint.display.trimEnd('/') + "/" + path.trimStart('/')
    }

    private fun authHeader(): Map<String, String> {
        if (server.username.isBlank()) return emptyMap()
        val token = android.util.Base64.encodeToString(
            "${server.username}:${server.password}".toByteArray(), android.util.Base64.NO_WRAP
        )
        return mapOf("Authorization" to "Basic $token")
    }

    private suspend fun probe(endpoint: Endpoint): Boolean = withContext(Dispatchers.IO) {
        runCatching {
            val payload = JSONObject().put("method", "session-get").toString()
            val request = Request.Builder()
                .url(rpcUrl(endpoint))
                .post(payload.toRequestBody(Net.JSON))
                .apply { authHeader().forEach { (k, v) -> header(k, v) } }
                .build()
            Net.probeClient.newCall(request).execute().use { it.code in 200..499 }
        }.getOrDefault(false)
    }

    /** POST JSON-RPC，自动处理 409 + X-Transmission-Session-Id */
    private suspend fun rpc(endpoint: Endpoint, method: String, arguments: JSONObject? = null): JSONObject =
        withContext(Dispatchers.IO) {
            var attempt = 0
            while (attempt < 3) {
                val payload = JSONObject().put("method", method)
                if (arguments != null) payload.put("arguments", arguments)

                val builder = Request.Builder()
                    .url(rpcUrl(endpoint))
                    .post(payload.toString().toRequestBody(Net.JSON))
                authHeader().forEach { (k, v) -> builder.header(k, v) }
                sessionIds[endpoint.hostKey()]?.let { builder.header("X-Transmission-Session-Id", it) }

                val response = Net.client.newCall(builder.build()).execute()
                response.use { res ->
                    if (res.code == 409) {
                        val newId = res.header("X-Transmission-Session-Id")
                        if (newId.isNullOrBlank()) throw ApiException("Transmission 未返回会话 ID")
                        sessionIds[endpoint.hostKey()] = newId
                        attempt++
                        return@use null
                    }
                    if (res.code == 401) throw ApiException("认证失败，请检查用户名密码")
                    if (!res.isSuccessful) throw ApiException("RPC 失败 HTTP ${res.code}")
                    val body = res.body?.string().orEmpty()
                    val json = JSONObject(body)
                    if (json.optString("result") != "success") {
                        throw ApiException("Transmission 返回错误：${json.optString("result")}")
                    }
                    return@use json.optJSONObject("arguments") ?: JSONObject()
                }?.let { return@withContext it }
            }
            throw ApiException("Transmission 会话协商失败")
        }

    suspend fun fetchAll(): Pair<List<TorrentTask>, ServerSnapshot> = withContext(Dispatchers.IO) {
        var endpoint = EndpointResolver.resolve(server) { probe(it) }
        try {
            pull(endpoint)
        } catch (e: Exception) {
            EndpointResolver.invalidate(server.id)
            val retry = EndpointResolver.resolve(server) { probe(it) }
            if (retry.hostKey() == endpoint.hostKey()) throw e
            endpoint = retry
            pull(endpoint)
        }
    }

    private suspend fun pull(endpoint: Endpoint): Pair<List<TorrentTask>, ServerSnapshot> {
        val fields = JSONArray().apply {
            listOf(
                "id", "hashString", "name", "percentDone", "totalSize", "downloadedEver", "uploadedEver",
                "rateDownload", "rateUpload", "status", "eta", "uploadRatio", "peersSendingToUs",
                "peersGettingFromUs", "peersConnected", "trackerStats", "downloadDir", "labels",
                "addedDate", "doneDate", "secondsSeeding", "error", "errorString", "isFinished",
                "sequentialDownload", "recheckProgress",
                "downloadLimit", "downloadLimitEnabled", "uploadLimit", "uploadLimitEnabled",
                "seedRatioMode", "seedRatioLimit"
            ).forEach { put(it) }
        }

        val torrentsArgs = JSONObject()
            .put("fields", fields)
            .put("format", "objects")
        val torrentsResult = rpc(endpoint, "torrent-get", torrentsArgs)
        val array = torrentsResult.optJSONArray("torrents") ?: JSONArray()

        val session = runCatching { rpc(endpoint, "session-get") }.getOrNull()
        val freeSpace = session?.optLong("download-dir-free-space", 0L) ?: 0L
        val version = session?.optString("version").orEmpty()
        val altSpeed = session?.optBoolean("alt-speed-enabled", false) ?: false
        // session-get 失败时不能当成「已关闭」，否则图标会被一次超时刷成常规色
        val altKnown = session != null
        val downloadDir = session?.optString("download-dir").orEmpty()

        // 累计流量用 session-stats 的 cumulative-stats（持久化、不清零），
        // 比「各任务 uploadedEver 求和」稳：删掉一个种子不会让总量掉下来。
        val cumulative = runCatching { rpc(endpoint, "session-stats") }
            .getOrNull()?.optJSONObject("cumulative-stats")
        // 没读到 cumulative-stats 就不能拿任务累计和顶上：口径不同，
        // 一旦把它写进流量账本基线，下次读到全量值会显示成「今天下载了几百 GB」。
        val cumulativeReliable = cumulative != null
            && cumulative.has("downloadedBytes")
            && cumulative.has("uploadedBytes")

        val tasks = ArrayList<TorrentTask>(array.length())
        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: continue
            val errCode = obj.optInt("error", 0)
            val errString = obj.optString("errorString")
            val status = mapStatus(obj.optInt("status", 0), errCode, errString)

            var seeds = 0
            var totalSeeds = 0
            var peers = 0
            var totalPeers = 0
            val trackerStats = obj.optJSONArray("trackerStats")
            if (trackerStats != null && trackerStats.length() > 0) {
                val t = trackerStats.optJSONObject(0)
                if (t != null) {
                    totalSeeds = t.optInt("seederCount", 0).coerceAtLeast(0)
                    totalPeers = t.optInt("leecherCount", 0).coerceAtLeast(0)
                    peers = t.optInt("leechers", 0).coerceAtLeast(0)
                }
            }
            seeds = obj.optInt("peersSendingToUs", 0)
            val trackerHost = trackerStats?.optJSONObject(0)?.optString("host").orEmpty()

            val labelsArray = obj.optJSONArray("labels")
            val labels = buildList {
                if (labelsArray != null) {
                    for (j in 0 until labelsArray.length()) add(labelsArray.optString(j))
                }
            }

            val percent = obj.optDouble("percentDone", 0.0).coerceIn(0.0, 1.0)
            val doneDate = obj.optLong("doneDate", 0L)

            tasks += TorrentTask(
                hash = obj.optString("hashString"),
                serverId = server.id,
                serverType = ServerType.TRANSMISSION,
                name = obj.optString("name"),
                progress = percent,
                size = obj.optLong("totalSize", 0L),
                downloaded = obj.optLong("downloadedEver", 0L),
                uploaded = obj.optLong("uploadedEver", 0L),
                downloadSpeed = obj.optLong("rateDownload", 0L),
                uploadSpeed = obj.optLong("rateUpload", 0L),
                status = status,
                etaSeconds = obj.optLong("eta", 0L).let { if (it < 0 || it >= 8640000L) -1 else it },
                ratio = obj.optDouble("uploadRatio", 0.0),
                numSeeds = seeds,
                totalSeeds = totalSeeds,
                numPeers = obj.optInt("peersGettingFromUs", 0),
                totalPeers = totalPeers,
                category = "",
                tags = labels,
                savePath = obj.optString("downloadDir"),
                trackerHost = trackerHostOf(if (trackerHost.startsWith("http")) trackerHost else "tcp://$trackerHost"),
                addedAt = obj.optLong("addedDate", 0L) * 1000,
                completedAt = if (doneDate > 0) doneDate * 1000 else 0L,
                seedingSeconds = obj.optLong("secondsSeeding", 0L),
                errorMessage = if (status == TorrentStatus.ERROR) errString else "",
                isSequential = obj.optBoolean("sequentialDownload", false),
                // tr 的单位是 KB/s，且另有 enabled 开关；关了就当不限速（App 内部统一 0 = 不限）
                downloadLimit = if (obj.optBoolean("downloadLimitEnabled", false)) {
                    obj.optLong("downloadLimit", 0L) * 1024
                } else 0L,
                uploadLimit = if (obj.optBoolean("uploadLimitEnabled", false)) {
                    obj.optLong("uploadLimit", 0L) * 1024
                } else 0L,
                // tr 的 seedRatioMode：0 全局 / 1 无限 / 2 自定义 → 统一成 -2 / -1 / 0
                ratioMode = when (obj.optInt("seedRatioMode", 0)) {
                    0 -> -2
                    1 -> -1
                    else -> 0
                },
                ratioLimit = obj.optDouble("seedRatioLimit", 0.0)
            )
        }

        val seeding = tasks.filter { it.status == TorrentStatus.SEEDING }
        val downloading = tasks.filter { it.status == TorrentStatus.DOWNLOADING || it.status == TorrentStatus.QUEUED }

        val snapshot = ServerSnapshot(
            serverId = server.id,
            online = true,
            downloadSpeed = tasks.sumOf { it.downloadSpeed },
            uploadSpeed = tasks.sumOf { it.uploadSpeed },
            seedingCount = seeding.size,
            downloadingCount = downloading.size,
            seedingSize = seeding.sumOf { it.size },
            totalUploaded = if (cumulativeReliable) cumulative!!.optLong("uploadedBytes", 0L) else 0L,
            totalDownloaded = if (cumulativeReliable) cumulative!!.optLong("downloadedBytes", 0L) else 0L,
            cumulativeReliable = cumulativeReliable,
            freeSpace = freeSpace,
            appVersion = version,
            endpointLabel = endpoint.display,
            altSpeedEnabled = altSpeed,
            altSpeedKnown = altKnown,
            defaultSavePath = downloadDir
        )
        return tasks to snapshot
    }

    private fun mapStatus(status: Int, errorCode: Int, errorString: String): TorrentStatus {
        if (errorCode != 0 || errorString.isNotBlank()) return TorrentStatus.ERROR
        return when (status) {
            0 -> TorrentStatus.PAUSED
            1, 2 -> TorrentStatus.CHECKING
            3, 5 -> TorrentStatus.QUEUED
            4 -> TorrentStatus.DOWNLOADING
            6 -> TorrentStatus.SEEDING
            else -> TorrentStatus.ERROR
        }
    }

    suspend fun pause(hashes: List<String>) = rpcByHashes("torrent-stop", hashes)
    suspend fun resume(hashes: List<String>) = rpcByHashes("torrent-start", hashes)

    /** tr 没有「强制开始」这个开关（队列由 tr 自己的配置决定），等价于继续 */
    suspend fun forceStart(hashes: List<String>) = resume(hashes)
    suspend fun recheck(hashes: List<String>) = rpcByHashes("torrent-verify", hashes)
    suspend fun reannounce(hashes: List<String>) = rpcByHashes("torrent-reannounce", hashes)

    /** 备用（计划）限速：tr 的 alt-speed，对应客户端右上角那个「仪表」按钮 */
    suspend fun setAltSpeed(enabled: Boolean) {
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        rpc(endpoint, "session-set", JSONObject().put("alt-speed-enabled", enabled))
    }

    /** 读当前备用限速状态（session-get），切换前后各读一次才能拿到服务器的真实状态 */
    suspend fun isAltSpeedEnabled(): Boolean {
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        val session = rpc(endpoint, "session-get")
        return session.optBoolean("alt-speed-enabled", false)
    }

    /** 批量改保存位置；move=true 让 tr 把已经下载的文件一起搬过去 */
    suspend fun setLocation(hashes: List<String>, location: String) {
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        rpc(
            endpoint,
            "torrent-set-location",
            JSONObject()
                .put("ids", JSONArray(hashes))
                .put("location", location)
                .put("move", true)
        )
    }

    // ---------- 单任务操作（点种子弹出的那一串菜单用） ----------

    /**
     * 重命名。tr 的 torrent-rename-path 必须给「原路径」：
     * 单文件种子是文件名、多文件种子是顶层文件夹名，两者都等于种子名，
     * 所以这里统一用 [oldPath]（调用方传 task.name）。
     */
    suspend fun rename(hash: String, oldPath: String, newName: String) {
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        rpc(
            endpoint,
            "torrent-rename-path",
            JSONObject()
                .put("ids", JSONArray().put(hash))
                .put("path", oldPath)
                .put("name", newName)
        )
    }

    /** 单任务限速：tr 单位是 KB/s，0 视为关闭限制（下载/上传各一个 enabled 开关） */
    suspend fun setSpeedLimit(hash: String, downloadKb: Long, uploadKb: Long) {
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        val args = JSONObject().put("ids", JSONArray().put(hash))
        args.put("downloadLimitEnabled", downloadKb > 0)
        if (downloadKb > 0) args.put("downloadLimit", downloadKb)
        args.put("uploadLimitEnabled", uploadKb > 0)
        if (uploadKb > 0) args.put("uploadLimit", uploadKb)
        rpc(endpoint, "torrent-set", args)
    }

    /** 分享率：mode 0 全局 / 1 无限 / 2 自定义，自定义时才需要 limit */
    suspend fun setShareRatio(hash: String, mode: Int, limit: Double) {
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        val args = JSONObject()
            .put("ids", JSONArray().put(hash))
            .put("seedRatioMode", mode)
        if (mode == 2) args.put("seedRatioLimit", limit)
        rpc(endpoint, "torrent-set", args)
    }

    /**
     * 单个任务的 Tracker 列表。
     *
     * tr 没有独立的 Tracker 接口，只能从 `torrent-get` 的 trackerStats 里拿；
     * 它也没有 qB 那种 status 枚举，只能按「上次汇报是否成功 + 有无失败文案」推断状态。
     * `id` 要留下来：改 / 删 Tracker 时 tr 用 id 定位，不用 URL。
     */
    suspend fun trackers(hash: String): List<TrackerEntry> {
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        val response = rpc(
            endpoint,
            "torrent-get",
            JSONObject()
                .put("ids", JSONArray().put(hash))
                .put("fields", JSONArray().put("trackerStats"))
        )
        val torrents = response.optJSONArray("torrents") ?: return emptyList()
        val stats = torrents.optJSONObject(0)?.optJSONArray("trackerStats") ?: return emptyList()
        return buildList {
            for (i in 0 until stats.length()) {
                val o = stats.optJSONObject(i) ?: continue
                val url = o.optString("announce").trim()
                if (url.isEmpty()) continue
                val result = o.optString("lastAnnounceResult").trim()
                val ok = o.optBoolean("lastAnnounceSucceeded", false)
                val status = when {
                    ok -> TrackerEntry.Status.WORKING
                    result.isNotEmpty() -> TrackerEntry.Status.NOT_WORKING
                    else -> TrackerEntry.Status.NOT_CONTACTED
                }
                add(
                    TrackerEntry(
                        url = url,
                        status = status,
                        tier = o.optInt("tier", 0),
                        trackerId = o.optInt("id", -1),
                        seeds = o.optInt("seederCount", 0),
                        leeches = o.optInt("leecherCount", 0),
                        peers = o.optInt("lastAnnouncePeerCount", 0),
                        message = if (ok) "" else result
                    )
                )
            }
        }
    }

    /** 改一条 Tracker：tr 用 trackerReplace = [id, 新URL]（两元素数组，不是对象） */
    suspend fun editTracker(hash: String, trackerId: Int, newUrl: String) {
        if (trackerId < 0) throw ApiException("这条 Tracker 没有 id，无法修改")
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        rpc(
            endpoint,
            "torrent-set",
            JSONObject()
                .put("ids", JSONArray().put(hash))
                .put("trackerReplace", JSONArray().put(trackerId).put(newUrl))
        )
    }

    /** 追加 Tracker：tr 用 trackerAdd = ["url1", "url2"] */
    suspend fun addTrackers(hash: String, urls: List<String>) {
        val targets = urls.map { it.trim() }.filter { it.isNotEmpty() }
        if (targets.isEmpty()) return
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        rpc(
            endpoint,
            "torrent-set",
            JSONObject()
                .put("ids", JSONArray().put(hash))
                .put("trackerAdd", JSONArray(targets))
        )
    }

    /** 删除 Tracker：tr 用 trackerRemove = [id...] */
    suspend fun removeTrackers(hash: String, trackerIds: List<Int>) {
        val ids = trackerIds.filter { it >= 0 }
        if (ids.isEmpty()) return
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        rpc(
            endpoint,
            "torrent-set",
            JSONObject()
                .put("ids", JSONArray().put(hash))
                .put("trackerRemove", JSONArray(ids))
        )
    }

    /** 不带 ids = 对全部任务操作（tr 的约定） */
    private suspend fun rpcAll(method: String) {
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        rpc(endpoint, method, JSONObject())
    }

    suspend fun resumeAll() = rpcAll("torrent-start")
    suspend fun pauseAll() = rpcAll("torrent-stop")
    suspend fun recheckAll() = rpcAll("torrent-verify")
    suspend fun reannounceAll() = rpcAll("torrent-reannounce")

    /** 本地选择的 .torrent 文件：tr 走 metainfo（base64），不接受裸文件流 */
    suspend fun addTorrentFile(bytes: ByteArray, savePath: String = "", paused: Boolean = false) {
        if (bytes.isEmpty()) throw ApiException("种子文件是空的")
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        val args = JSONObject()
            .put("metainfo", android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP))
            .put("paused", paused)
        if (savePath.isNotBlank()) args.put("download-dir", savePath)
        rpc(endpoint, "torrent-add", args)
    }

    suspend fun delete(hashes: List<String>, deleteFiles: Boolean) {
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        val args = JSONObject()
            .put("ids", JSONArray(hashes))
            .put("delete-local-data", deleteFiles)
        rpc(endpoint, "torrent-remove", args)
    }

    private suspend fun rpcByHashes(method: String, hashes: List<String>) {
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        val args = JSONObject().put("ids", JSONArray(hashes))
        rpc(endpoint, method, args)
    }

    /** RSS 自动下载用：逐个添加 magnet / http 直链 */
    suspend fun addTorrents(
        urls: List<String>,
        savePath: String = "",
        paused: Boolean = false
    ) {
        val targets = urls.map { it.trim() }.filter { it.isNotEmpty() }
        if (targets.isEmpty()) return
        val endpoint = EndpointResolver.resolve(server) { probe(it) }
        for (url in targets) {
            val args = JSONObject()
                .put("filename", url)
                .put("paused", paused)
            if (savePath.isNotBlank()) args.put("download-dir", savePath)
            rpc(endpoint, "torrent-add", args)
        }
    }
}
