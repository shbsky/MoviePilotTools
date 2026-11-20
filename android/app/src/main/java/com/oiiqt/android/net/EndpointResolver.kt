package com.oiiqt.android.net

import com.oiiqt.android.data.Endpoint
import com.oiiqt.android.data.EndpointMode
import com.oiiqt.android.data.ServerConfig
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap

/**
 * 域名 / IP 自动切换的核心。
 *
 * - AUTO：并发探测所有已启用地址，谁先响应就用谁，结果缓存 10 分钟；
 *   「家里直连内网 IP、外面走公网域名」不需要手动干预。
 * - MANUAL：固定用用户选的那条。
 * 请求失败时调用 [invalidate]，下次重新探测。
 */
object EndpointResolver {
    private const val CACHE_TTL_MS = 10 * 60 * 1000L
    private const val PROBE_BUDGET_MS = 3200L

    private data class Cached(val endpoint: Endpoint, val at: Long)

    private val cache = ConcurrentHashMap<String, Cached>()

    fun cachedEndpoint(serverId: String): Endpoint? {
        val hit = cache[serverId] ?: return null
        if (System.currentTimeMillis() - hit.at > CACHE_TTL_MS) return null
        return hit.endpoint
    }

    fun invalidate(serverId: String) {
        cache.remove(serverId)
    }

    fun remember(serverId: String, endpoint: Endpoint) {
        cache[serverId] = Cached(endpoint, System.currentTimeMillis())
    }

    /**
     * 按「缓存优先 / 手动固定」给出候选顺序，供需要逐个尝试的调用方（如 MoviePilot）使用。
     */
    fun candidates(
        serverId: String,
        endpoints: List<Endpoint>,
        mode: EndpointMode,
        pinnedIndex: Int
    ): List<Endpoint> {
        if (endpoints.isEmpty()) return emptyList()
        if (mode == EndpointMode.MANUAL) {
            val pinned = endpoints.getOrNull(pinnedIndex) ?: endpoints.first()
            return listOf(pinned) + endpoints.filter { it.hostKey() != pinned.hostKey() }
        }
        val cached = cachedEndpoint(serverId)?.takeIf { c -> endpoints.any { it.hostKey() == c.hostKey() } }
        return if (cached != null) {
            listOf(cached) + endpoints.filter { it.hostKey() != cached.hostKey() }
        } else {
            endpoints
        }
    }

    suspend fun resolve(server: ServerConfig, probe: suspend (Endpoint) -> Boolean): Endpoint {
        val chosen = resolveAny(
            cacheKey = server.id,
            endpoints = server.activeEndpoints,
            mode = server.endpointMode,
            pinnedIndex = server.pinnedEndpointIndex,
            probe = probe
        )
        return chosen ?: throw ApiException("没有可用的访问地址")
    }

    /**
     * 与 [resolve] 同逻辑，但不依赖 ServerConfig —— 流量统计面板、音乐服务这类
     * 「只有一个多行地址输入框」的轻量服务也走同一套自动检测。
     *
     * 返回 null 表示一个地址都探不通（调用方自己决定报错还是先试第一个）。
     */
    suspend fun resolveAny(
        cacheKey: String,
        endpoints: List<Endpoint>,
        mode: EndpointMode = EndpointMode.AUTO,
        pinnedIndex: Int = 0,
        probe: suspend (Endpoint) -> Boolean
    ): Endpoint? {
        val candidates = endpoints.filter { it.enabled && it.isValid }
        if (candidates.isEmpty()) return null

        if (mode == EndpointMode.MANUAL) {
            val pinned = candidates.getOrNull(pinnedIndex) ?: candidates.first()
            // 固定的地址也要探一下：不通就回退到别的地址，别把用户卡在「连不上」
            if (runCatching { probe(pinned) }.getOrDefault(false)) {
                remember(cacheKey, pinned)
                return pinned
            }
        } else {
            cachedEndpoint(cacheKey)?.let { cached ->
                candidates.firstOrNull { it.hostKey() == cached.hostKey() }?.let { return it }
            }
        }

        val ordered = candidates.sortedBy { if (it.hostKey() == (candidates.getOrNull(pinnedIndex)?.hostKey() ?: "")) 0 else 1 }
        val winner = coroutineScope {
            val result = CompletableDeferred<Endpoint>()
            val jobs = ordered.map { endpoint ->
                launch {
                    val reachable = runCatching { probe(endpoint) }.getOrDefault(false)
                    if (reachable && !result.isCompleted) result.complete(endpoint)
                }
            }
            val found = withTimeoutOrNull(PROBE_BUDGET_MS) { result.await() }
            jobs.forEach { it.cancel() }
            found
        }

        if (winner != null) remember(cacheKey, winner)
        return winner
    }
}
