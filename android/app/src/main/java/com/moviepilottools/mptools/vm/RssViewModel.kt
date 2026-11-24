package com.moviepilottools.mptools.vm

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.moviepilottools.mptools.data.RssItemRecord
import com.moviepilottools.mptools.data.RssRepository
import com.moviepilottools.mptools.data.RssRuleEngine
import com.moviepilottools.mptools.data.RssSource
import com.moviepilottools.mptools.work.RssScheduler
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class RssUiState(
    val sources: List<RssSource> = emptyList(),
    val items: List<RssItemRecord> = emptyList(),
    val refreshing: Set<String> = emptySet(),
    val refreshingAll: Boolean = false,
    val toast: String? = null
) {
    fun itemsOf(sourceId: String): List<RssItemRecord> = items.filter { it.sourceId == sourceId }

    fun unreadOf(sourceId: String): Int = items.count { it.sourceId == sourceId && !it.downloaded }

    fun matchedOf(sourceId: String): Int = items.count { it.sourceId == sourceId && it.matched }

    val sortedItems: List<RssItemRecord> get() = items.sortedByDescending { it.pubDate }

    fun sourceName(sourceId: String): String =
        sources.firstOrNull { it.id == sourceId }?.name ?: "未知源"
}

class RssViewModel(application: Application) : AndroidViewModel(application) {

    private val repo = RssRepository(application)

    var state by mutableStateOf(RssUiState())
        private set

    init {
        reload()
    }

    fun reload() {
        viewModelScope.launch {
            val sources = withContext(Dispatchers.IO) { repo.loadSources() }
            val items = withContext(Dispatchers.IO) { repo.loadItems() }
            state = state.copy(sources = sources, items = items)
        }
    }

    // ---------- 源 ----------

    fun upsertSource(source: RssSource) {
        val sources = state.sources.toMutableList()
        val index = sources.indexOfFirst { it.id == source.id }
        if (index >= 0) sources[index] = source else sources.add(source)
        persistSources(sources)
    }

    fun deleteSource(id: String) {
        persistSources(state.sources.filterNot { it.id == id })
        viewModelScope.launch(Dispatchers.IO) {
            repo.clearItems(id)
            reload()
        }
    }

    fun toggleSource(id: String, enabled: Boolean) {
        persistSources(state.sources.map { if (it.id == id) it.copy(enabled = enabled) else it })
    }

    private fun persistSources(sources: List<RssSource>) {
        state = state.copy(sources = sources)
        viewModelScope.launch(Dispatchers.IO) { repo.saveSources(sources) }
    }

    // ---------- 刷新 ----------

    fun refreshSource(id: String) {
        val source = state.sources.firstOrNull { it.id == id } ?: return
        if (state.refreshing.contains(id)) return
        state = state.copy(refreshing = state.refreshing + id)
        viewModelScope.launch {
            val outcome = repo.refreshSource(source)
            state = state.copy(
                refreshing = state.refreshing - id,
                toast = when {
                    outcome.error != null -> "${source.name} 刷新失败：${outcome.error}"
                    outcome.pushed.isNotEmpty() -> "${source.name}：推送 ${outcome.pushed.size} 个"
                    outcome.newCount > 0 -> "${source.name}：新增 ${outcome.newCount} 条"
                    else -> "${source.name}：无新条目"
                }
            )
            reload()
            refreshScheduler()
        }
    }

    fun refreshAll() {
        if (state.refreshingAll) return
        val enabled = state.sources.filter { it.enabled }
        if (enabled.isEmpty()) {
            state = state.copy(toast = "还没有启用的 RSS 源")
            return
        }
        state = state.copy(refreshingAll = true, refreshing = enabled.map { it.id }.toSet())
        viewModelScope.launch {
            val outcomes = repo.refreshAll(enabled)
            val pushed = outcomes.sumOf { it.pushed.size }
            val failures = outcomes.filter { it.error != null }
            state = state.copy(
                refreshingAll = false,
                refreshing = emptySet(),
                toast = when {
                    failures.isNotEmpty() -> "${failures.size} 个源失败：${failures.first().error}"
                    pushed > 0 -> "已自动推送 $pushed 个资源"
                    else -> "检查完成，共新增 ${outcomes.sumOf { it.newCount }} 条"
                }
            )
            reload()
            refreshScheduler()
        }
    }

    suspend fun testSource(source: RssSource): Result<Pair<Int, List<RssItemRecord>>> =
        withContext(Dispatchers.IO) {
            runCatching {
                val fetched = com.moviepilottools.mptools.net.RssFetcher.fetch(source)
                fetched.size to fetched.take(5)
            }
        }

    fun pushItem(sourceId: String, item: RssItemRecord) {
        val source = state.sources.firstOrNull { it.id == sourceId } ?: return
        viewModelScope.launch {
            val result = repo.pushItem(source, item)
            state = state.copy(
                toast = result.exceptionOrNull()?.let { "推送失败：${it.message}" } ?: "已推送到下载器"
            )
            reload()
        }
    }

    fun clearItems(sourceId: String? = null) {
        viewModelScope.launch(Dispatchers.IO) {
            repo.clearItems(sourceId)
            reload()
        }
    }

    /** 规则改动后重算已抓条目的命中状态，让预览立刻准确 */
    fun revaluate(source: RssSource) {
        viewModelScope.launch(Dispatchers.IO) {
            val items = repo.loadItems().map {
                if (it.sourceId == source.id) it.copy(matched = RssRuleEngine.matches(it, source)) else it
            }
            repo.saveItems(items)
            withContext(Dispatchers.Main) { reload() }
        }
    }

    fun notifySettingsChanged() = refreshScheduler()

    private fun refreshScheduler() {
        val settings = repo.loadSettings()
        RssScheduler.ensure(getApplication(), settings)
    }

    fun consumeToast() {
        state = state.copy(toast = null)
    }
}
