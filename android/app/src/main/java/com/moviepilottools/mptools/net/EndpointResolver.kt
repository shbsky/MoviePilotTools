package com.moviepilottools.mptools.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import com.moviepilottools.mptools.data.Endpoint
import com.moviepilottools.mptools.data.EndpointMode
import com.moviepilottools.mptools.data.ServerConfig
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap

/**
 * 域名 / IP 自动切换的核心（与鸿蒙 EndpointResolver 对齐）。
 *
 * - AUTO：连上 WiFi / 有线时先只探内网地址（短预算），通了就用；否则并发探测全部，谁先响应用谁；
 *   结果缓存 10 分钟，网络切换时清空。
 * - MANUAL：固定用用户选的那条，探测失败就回退。
 * 请求失败时调用 [invalidate]，下次重新探测。
 */
object EndpointResolver {
    private const val CACHE_TTL_MS = 10 * 60 * 1000L
    private const val PROBE_BUDGET_MS = 3200L
    private const val LAN_PROBE_BUDGET_MS = 1200L

    private data class Cached(val endpoint: Endpoint, val at: Long)

    private val cache = ConcurrentHashMap<String, Cached>()

    /** 当前是否在局域网（WiFi / 有线）。查询失败一律按 true 处理：多探一次内网无副作用 */
    @Volatile
    private var lanCached: Boolean = true

    @Volatile
    private var lanCheckedAt: Long = 0L

    private var netCallback: ConnectivityManager.NetworkCallback? = null
    private var watching = false

    /** 应用启动时调用一次：网络切换时清空选路缓存，避免「回到家还连着公网域名」 */
    fun installNetworkWatcher(context: Context) {
        if (watching) return
        watching = true
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            private fun changed() {
                cache.clear()
                lanCheckedAt = 0L
            }

            override fun onAvailable(network: Network) = changed()
            override fun onLost(network: Network) = changed()
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = changed()
        }
        try {
            cm.registerDefaultNetworkCallback(cb)
            netCallback = cb
        } catch (_: Exception) {
        }
    }

    fun deviceOnLan(context: Context): Boolean {
        val now = System.currentTimeMillis()
        if (now - lanCheckedAt < 3000L) return lanCached
        var onLan = true
        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            val net = cm?.activeNetwork
            val caps = net?.let { cm?.getNetworkCapabilities(it) }
            onLan = caps != null &&
                (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
        } catch (_: Exception) {
            onLan = true
        }
        lanCached = onLan
        lanCheckedAt = now
        return onLan
    }

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

        // 内网优先：有局域网候选时，先用短预算只探内网，通了就定它，
        // 不让公网域名抢「谁先响应」；内网不通（在外面）再并发探测全部。
        val lanEps = ordered.filter { it.isLanHost }
        if (lanEps.isNotEmpty()) {
            val lanWinner = coroutineScope {
                val result = CompletableDeferred<Endpoint>()
                val jobs = lanEps.map { endpoint ->
                    launch {
                        if (runCatching { probe(endpoint) }.getOrDefault(false) && !result.isCompleted) {
                            result.complete(endpoint)
                        }
                    }
                }
                val found = withTimeoutOrNull(LAN_PROBE_BUDGET_MS) { result.await() }
                jobs.forEach { it.cancel() }
                found
            }
            if (lanWinner != null) {
                remember(cacheKey, lanWinner)
                return lanWinner
            }
        }

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

    /** 同步版：给 OkHttp 同步调用方（如 SongloftClient）用，逻辑与 resolveAny 一致 */
    fun resolveAnySync(
        cacheKey: String,
        endpoints: List<Endpoint>,
        probe: (Endpoint) -> Boolean
    ): Endpoint? {
        val candidates = endpoints.filter { it.enabled && it.isValid }
        if (candidates.isEmpty()) return null
        cachedEndpoint(cacheKey)?.let { cached ->
            candidates.firstOrNull { it.hostKey() == cached.hostKey() }?.let { return it }
        }
        val lanEps = candidates.filter { it.isLanHost }
        if (lanEps.isNotEmpty()) {
            for (ep in lanEps) {
                if (runCatching { probe(ep) }.getOrDefault(false)) {
                    remember(cacheKey, ep)
                    return ep
                }
            }
        }
        for (ep in candidates) {
            if (runCatching { probe(ep) }.getOrDefault(false)) {
                remember(cacheKey, ep)
                return ep
            }
        }
        return null
    }
}
