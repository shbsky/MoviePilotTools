package com.moviepilottools.mptools.data

import android.content.Context
import com.moviepilottools.mptools.net.ApiException
import com.moviepilottools.mptools.net.QBittorrentClient
import com.moviepilottools.mptools.net.RssFetcher
import com.moviepilottools.mptools.net.TransmissionClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File

/**
 * RSS 源与条目的本地仓库。
 * - 源配置（含 API Key/Headers）随主配置一起加密落盘；
 * - 条目只存标题/链接/体积，放在独立的明文 JSON，避免加密大文件拖慢每次保存。
 */
class RssRepository(context: Context) {

    private val store = ConfigStore(context)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val itemFile = File(context.filesDir, "rss_items.json")
    private val itemLock = Any()

    data class RefreshOutcome(
        val sourceId: String,
        val sourceName: String,
        val fetched: Int = 0,
        val newCount: Int = 0,
        val pushed: List<String> = emptyList(),
        val failed: List<String> = emptyList(),
        val error: String? = null
    )

    // ---------- 源 ----------

    fun loadSources(): List<RssSource> = store.load().rssSources

    fun saveSources(sources: List<RssSource>) {
        val current = store.load()
        store.save(current.copy(rssSources = sources))
    }

    fun loadServers(): List<ServerConfig> = store.load().servers

    fun loadSettings(): AppSettings = store.load().settings

    // ---------- 条目 ----------

    fun loadItems(): List<RssItemRecord> = synchronized(itemLock) {
        if (!itemFile.exists()) return emptyList()
        runCatching {
            json.decodeFromString<List<RssItemRecord>>(itemFile.readText())
        }.getOrElse { emptyList() }
    }

    fun saveItems(items: List<RssItemRecord>) = synchronized(itemLock) {
        runCatching {
            itemFile.parentFile?.mkdirs()
            itemFile.writeText(
                json.encodeToString(kotlinx.serialization.builtins.ListSerializer(RssItemRecord.serializer()), items)
            )
        }
    }

    fun clearItems(sourceId: String? = null) {
        if (sourceId == null) {
            saveItems(emptyList())
        } else {
            saveItems(loadItems().filterNot { it.sourceId == sourceId })
        }
    }

    fun markDownloaded(itemId: String, success: Boolean, error: String = "") {
        val items = loadItems().map {
            if (it.id == itemId) it.copy(downloaded = success, error = error) else it
        }
        saveItems(items)
    }

    // ---------- 刷新 ----------

    suspend fun refreshSource(
        source: RssSource,
        servers: List<ServerConfig> = loadServers()
    ): RefreshOutcome = withContext(Dispatchers.IO) {
        if (!source.enabled) return@withContext RefreshOutcome(source.id, source.name, error = "源已停用")

        val fetched = try {
            RssFetcher.fetch(source)
        } catch (e: Exception) {
            return@withContext RefreshOutcome(
                source.id, source.name,
                error = e.message ?: e.javaClass.simpleName
            )
        }

        val existing = loadItems().filter { it.sourceId == source.id }
        val byLink = existing.associateBy { it.link }
        val byTitle = existing.associateBy { it.title }

        val created = mutableListOf<RssItemRecord>()
        val touched = mutableListOf<RssItemRecord>()

        for (item in fetched) {
            if (byLink.containsKey(item.link)) continue
            val sameTitle = byTitle[item.title]
            if (sameTitle != null && sameTitle.link != item.link) {
                // 同标题换了下载链（站内重发/换种），视为新资源重新推送
                touched += sameTitle.copy(link = item.link, downloaded = false, seenAt = System.currentTimeMillis())
            } else if (sameTitle == null) {
                val matched = RssRuleEngine.matches(item, source)
                created += item.copy(matched = matched)
            }
        }

        val serversNow = servers
        val pushed = mutableListOf<String>()
        val failed = mutableListOf<String>()
        val downloadedIds = mutableSetOf<String>()

        if (source.autoDownload) {
            for (item in created.filter { it.matched }) {
                val result = push(source, serversNow, listOf(item.link))
                if (result.isSuccess) {
                    pushed += item.title
                    downloadedIds += item.id
                } else {
                    failed += "${item.title}：${result.exceptionOrNull()?.message ?: "推送失败"}"
                }
            }
        }

        val touchedIds = touched.map { it.id }.toSet()
        val merged = (existing.map { old ->
            when {
                touchedIds.contains(old.id) -> touched.first { it.id == old.id }
                downloadedIds.contains(old.id) -> old.copy(downloaded = true)
                else -> old
            }
        } + created.mapNotNull { item ->
            if (downloadedIds.contains(item.id)) item.copy(downloaded = true) else item
        }).sortedByDescending { it.pubDate }

        // 单源最多保留 400 条，避免条目表无限膨胀
        val trimmed = merged.take(MAX_PER_SOURCE)
        val others = loadItems().filterNot { it.sourceId == source.id }
        saveItems((others + trimmed).sortedByDescending { it.pubDate }.take(MAX_TOTAL))

        RefreshOutcome(
            sourceId = source.id,
            sourceName = source.name,
            fetched = fetched.size,
            newCount = created.size,
            pushed = pushed,
            failed = failed
        )
    }

    suspend fun refreshAll(sources: List<RssSource> = loadSources()): List<RefreshOutcome> =
        withContext(Dispatchers.IO) {
            val servers = loadServers()
            val outcomes = mutableListOf<RefreshOutcome>()
            for (source in sources.filter { it.enabled }) {
                val outcome = refreshSource(source, servers)
                outcomes += outcome
                if (outcome.error == null) {
                    saveSourceTimestamp(source.id)
                }
            }
            outcomes
        }

    private fun saveSourceTimestamp(sourceId: String) {
        val sources = loadSources().map {
            if (it.id == sourceId) it.copy(lastUpdated = System.currentTimeMillis()) else it
        }
        saveSources(sources)
    }

    private suspend fun push(
        source: RssSource,
        servers: List<ServerConfig>,
        urls: List<String>
    ): Result<Unit> {
        val server = source.targetServerId?.let { id -> servers.firstOrNull { it.id == id } }
            ?: servers.firstOrNull()
            ?: return Result.failure(ApiException("尚未配置任何下载器服务器"))

        return runCatching {
            when (server.type) {
                ServerType.QBITTORRENT -> QBittorrentClient(server).addTorrents(
                    urls = urls,
                    savePath = source.savePath,
                    category = source.category,
                    paused = source.addPaused,
                    firstLastPiecePriority = source.priority > 0
                )

                ServerType.TRANSMISSION -> TransmissionClient(server).addTorrents(
                    urls = urls,
                    savePath = source.savePath,
                    paused = source.addPaused
                )
            }
        }
    }

    /** 手动推送单条（源详情页用） */
    suspend fun pushItem(source: RssSource, item: RssItemRecord): Result<Unit> =
        withContext(Dispatchers.IO) {
            val result = push(source, loadServers(), listOf(item.link))
            markDownloaded(item.id, result.isSuccess, result.exceptionOrNull()?.message.orEmpty())
            result
        }

    companion object {
        private const val MAX_PER_SOURCE = 400
        private const val MAX_TOTAL = 3000
    }
}
