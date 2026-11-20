package com.oiiqt.android.net

import com.oiiqt.android.data.Endpoint
import com.oiiqt.android.data.MpDiscoverChannel
import com.oiiqt.android.data.MpDownloader
import com.oiiqt.android.data.MpDownloaderInfo
import com.oiiqt.android.data.MpMedia
import com.oiiqt.android.data.MpMemoryInfo
import com.oiiqt.android.data.MpResource
import com.oiiqt.android.data.MpSavePath
import com.oiiqt.android.data.MpStatistic
import com.oiiqt.android.data.MpStorage
import com.oiiqt.android.data.MpSystemInfo
import com.oiiqt.android.data.MpServer
import com.oiiqt.android.data.MpSite
import com.oiiqt.android.data.MpSiteCategory
import com.oiiqt.android.data.MpSiteUserData
import com.oiiqt.android.data.MpSubscribe
import com.oiiqt.android.data.sortedForDisplay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * MoviePilot 客户端。
 *
 * 认证优先级：配了用户名密码 → 登录取 JWT（这样才能用渐进式搜索，MP 用 Cookie 里的
 * resource_token 校验 SSE）；否则用 API Token（`X-API-KEY`，MP 会当作超级用户）。
 */
class MoviePilotClient(private val server: MpServer) {

    @Volatile
    private var jwt: String? = null

    @Volatile
    private var loginTried = false

    /** 当前命中的 MP 地址，用于还原 `/api/...` 这类相对图片路径 */
    @Volatile
    private var activeBaseUrl: String? = null

    private val sseClient by lazy {
        Net.client.newBuilder()
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .callTimeout(180, TimeUnit.SECONDS)
            .build()
    }

    // ---------- 基础设施 ----------

    private suspend fun <T> withEndpoint(block: suspend (Endpoint) -> T): T =
        withContext(Dispatchers.IO) {
            val endpoints = server.activeEndpoints
            if (endpoints.isEmpty()) {
                val filled = server.endpoints.count { it.host.isNotBlank() }
                throw ApiException(
                    if (filled == 0) "MoviePilot 还没配置访问地址"
                    else "已填地址但都不合法（共 ${server.endpoints.size} 条），检查域名/IP 是否带了空格或多余符号"
                )
            }

            var lastError: Exception? = null
            val ordered = EndpointResolver.candidates(
                server.id, endpoints, server.endpointMode, server.pinnedEndpointIndex
            )
            for (endpoint in ordered) {
                try {
                    activeBaseUrl = endpoint.display
                    val value = block(endpoint)
                    EndpointResolver.remember(server.id, endpoint)
                    return@withContext value
                } catch (e: ApiException) {
                    // 认证类错误说明地址是对的，不必再换地址
                    if (e.message?.contains("认证失败") == true) throw e
                    lastError = e
                    EndpointResolver.invalidate(server.id)
                } catch (e: Exception) {
                    lastError = e
                    EndpointResolver.invalidate(server.id)
                }
            }
            throw (lastError ?: ApiException("MoviePilot 连接失败"))
        }

    private fun url(endpoint: Endpoint, path: String, query: List<Pair<String, String>> = emptyList()): String {
        val base = endpoint.display.trimEnd('/')
        val cleanPath = path.trimStart('/')
        val qs = query.filter { it.second.isNotBlank() }
            .joinToString("&") { "${enc(it.first)}=${enc(it.second)}" }
        return if (qs.isEmpty()) "$base/$cleanPath" else "$base/$cleanPath?$qs"
    }

    private fun enc(value: String): String = java.net.URLEncoder.encode(value, "UTF-8")

    private fun headers(): Map<String, String> {
        val token = server.apiToken.trim()
        val map = mutableMapOf<String, String>()
        val currentJwt = jwt
        if (currentJwt != null) {
            map["Authorization"] = "Bearer $currentJwt"
        } else if (token.isNotEmpty()) {
            map["X-API-KEY"] = token
            map["apikey"] = token
        }
        return map
    }

    /** 有账号密码时登录取 JWT（同时让 MP 把 resource_token 写进 CookieJar，渐进式搜索才可用） */
    private suspend fun ensureLogin(): Boolean = withContext(Dispatchers.IO) {
        if (!server.hasLogin) return@withContext false
        if (jwt != null) return@withContext true
        if (loginTried) return@withContext jwt != null
        loginTried = true

        return@withContext runCatching {
            val endpoint = server.activeEndpoints.firstOrNull() ?: return@withContext false
            val form = "username=${enc(server.username)}&password=${enc(server.password)}"
            val request = Request.Builder()
                .url(url(endpoint, "api/v1/login/access-token"))
                .post(form.toRequestBody(Net.FORM))
                .build()
            Net.client.newCall(request).execute().use { response ->
                val body = response.body?.string().orEmpty()
                if (!response.isSuccessful) return@use false
                val json = JSONObject(body)
                val token = json.optString("access_token")
                if (token.isBlank()) {
                    // 部分版本把 token 放在 data.access_token
                    json.optJSONObject("data")?.optString("access_token")?.takeIf { it.isNotBlank() }?.let {
                        jwt = it
                        return@use true
                    }
                    return@use false
                }
                jwt = token
                true
            }
        }.getOrDefault(false)
    }

    private fun execute(
        endpoint: Endpoint,
        path: String,
        method: String = "GET",
        query: List<Pair<String, String>> = emptyList(),
        body: JSONObject? = null,
        slow: Boolean = false,
        httpClient: OkHttpClient? = null
    ): Response {
        val builder = Request.Builder().url(url(endpoint, path, query))
        headers().forEach { (k, v) -> builder.header(k, v) }
        if (method == "GET") {
            builder.get()
        } else {
            val payload = (body ?: JSONObject()).toString().toRequestBody(Net.JSON)
            builder.method(method, payload)
        }
        val client = httpClient ?: if (slow) Net.slowClient else Net.client
        return client.newCall(builder.build()).execute()
    }

    private suspend fun requestJson(
        path: String,
        query: List<Pair<String, String>> = emptyList(),
        method: String = "GET",
        body: JSONObject? = null,
        slow: Boolean = false
    ): Any = withEndpoint { endpoint ->
        ensureLogin()
        execute(endpoint, path, method, query, body, slow).use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                // HTTP 状态码要带出来：站点接口靠 403 / 404 区分「token 权限不够」和「MP 版本太老」
                throw ApiException(describeError(response.code, text), response.code)
            }
            if (text.isBlank()) return@withEndpoint JSONObject()
            parseAny(text)
        }
    }

    private fun describeError(code: Int, body: String): String {
        val detail = runCatching {
            val obj = JSONObject(body)
            obj.optString("detail").ifBlank {
                // MP v3 的 422 把具体字段塞在 data 数组里：[{loc:[...], msg:"..."}]
                obj.optJSONArray("data")?.optJSONObject(0)?.let { first ->
                    val field = first.optJSONArray("loc")?.join(",").orEmpty().replace("\"", "")
                    val msg = first.optString("msg")
                    listOf(field, msg).filter { it.isNotBlank() }.joinToString(" ")
                }.orEmpty()
            }.ifBlank { obj.optString("message") }
        }.getOrDefault("")
        return when {
            code == 401 || code == 403 -> "认证失败（检查 API Token）${detail.takeIf { it.isNotBlank() }?.let { "：$it" } ?: ""}"
            code == 404 -> "接口不存在（HTTP 404）：核对端口 / 子路径是否正确，或该地址指向的不是 MoviePilot"
            code == 422 && detail.isNotBlank() -> "请求参数不被接受（HTTP 422）：$detail"
            else -> "HTTP $code ${detail.take(80)}"
        }
    }

    private fun parseAny(text: String): Any {
        val trimmed = text.trim()
        return if (trimmed.startsWith("[")) JSONArray(trimmed) else JSONObject(trimmed)
    }

    /** 原始文本响应（CPU 接口在某些版本直接吐一个裸浮点，不能走 [parseAny]）。 */
    private suspend fun requestText(
        path: String,
        query: List<Pair<String, String>> = emptyList()
    ): String = withEndpoint { endpoint ->
        ensureLogin()
        execute(endpoint, path, query = query).use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw ApiException(describeError(response.code, text), response.code)
            }
            text
        }
    }

    /**
     * 仪表盘通用取数：JWT 接口优先，失败时退 `${name}2?token=`。
     * v2 起外层常套 `{success, message, data}`，这里统一拆到 data。
     */
    private suspend fun dashboardObject(
        name: String,
        tokenFallback: Boolean = true
    ): JSONObject {
        val raw = runCatching { requestJson("api/v1/dashboard/$name") }
            .getOrElse { error ->
                val token = server.apiToken.trim()
                if (!tokenFallback || token.isEmpty()) throw error
                requestJson("api/v1/dashboard/${name}2", listOf("token" to token))
            }
        return when (raw) {
            is JSONObject -> raw.optJSONObject("data") ?: raw
            else -> JSONObject()
        }
    }

    private fun number(obj: JSONObject, vararg keys: String): Long {
        for (key in keys) {
            val value = obj.opt(key)
            if (value is Number) return value.toLong()
            val text = obj.optString(key).trim()
            if (text.isNotBlank()) text.toDoubleOrNull()?.let { return it.toLong() }
        }
        return 0L
    }

    private fun decimal(obj: JSONObject, vararg keys: String): Double {
        for (key in keys) {
            val value = obj.opt(key)
            if (value is Number) return value.toDouble()
            val text = obj.optString(key).trim()
            if (text.isNotBlank()) text.toDoubleOrNull()?.let { return it }
        }
        return 0.0
    }

    // ---------- 仪表盘实时数据 ----------

    /** MP 仪表盘「实时速率」：与网页那张卡同口径，直接读下载器聚合值。 */
    suspend fun dashboardDownloader(): MpDownloaderInfo {
        val obj = dashboardObject("downloader")
        return MpDownloaderInfo(
            downloadSpeed = number(obj, "download_speed", "download", "dl_speed"),
            uploadSpeed = number(obj, "upload_speed", "upload", "ul_speed"),
            downloadSize = number(obj, "download_size", "downloaded", "total_downloaded"),
            uploadSize = number(obj, "upload_size", "uploaded", "total_uploaded"),
            freeSpace = number(obj, "free_space", "free", "free_space_bytes")
        )
    }

    /**
     * CPU 当前百分比。兼容裸浮点、`{data: 12.3}`、`{data:{cpu:12.3}}` 与
     * `{cpu: 12.3}`；解析不出来返回 NaN，由 VM 丢弃这次采样。
     */
    suspend fun dashboardCpu(): Float {
        val text = runCatching { requestText("api/v1/dashboard/cpu") }
            .getOrElse { error ->
                val token = server.apiToken.trim()
                if (token.isEmpty()) throw error
                requestText("api/v1/dashboard/cpu2", listOf("token" to token))
            }
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return Float.NaN
        trimmed.toDoubleOrNull()?.let { return it.coerceIn(0.0, 100.0).toFloat() }
        return runCatching {
            val root = JSONObject(trimmed)
            val data = root.opt("data")
            val value = when (data) {
                is Number -> data.toDouble()
                is String -> data.trim().toDoubleOrNull() ?: Double.NaN
                is JSONObject -> decimal(data, "cpu", "cpu_usage", "usage", "value")
                else -> decimal(root, "cpu", "cpu_usage", "usage", "value")
            }
            if (value.isNaN()) Float.NaN else value.coerceIn(0.0, 100.0).toFloat()
        }.getOrDefault(Float.NaN)
    }

    /** 内存：total/used/cached/available 为字节，usage 为百分比。 */
    suspend fun dashboardMemory(): MpMemoryInfo {
        val obj = dashboardObject("memory")
        return MpMemoryInfo(
            total = number(obj, "total", "total_memory"),
            used = number(obj, "used", "used_memory"),
            cached = number(obj, "cached", "cached_memory"),
            available = number(obj, "available", "available_memory"),
            usage = decimal(obj, "usage", "usage_percent", "percent").coerceIn(0.0, 100.0).toFloat()
        )
    }

    /**
     * 系统信息。MP 没有 `system2?token=` 变体，只有登录管理员 JWT 能读；
     * 仅配 API Token 时这里会抛认证错误，由 VM 转成降级文案，不影响 CPU/内存。
     */
    suspend fun dashboardSystem(): MpSystemInfo {
        val obj = dashboardObject("system", tokenFallback = false)
        return MpSystemInfo(
            hostname = obj.optString("hostname").ifBlank { obj.optString("host") },
            operatingSystem = obj.optString("operating_system")
                .ifBlank { obj.optString("os").ifBlank { obj.optString("platform") } },
            runtime = obj.optString("runtime").ifBlank { obj.optString("python_version") },
            version = obj.optString("version").ifBlank { obj.optString("app_version") }
        )
    }

    // ---------- 仪表盘媒体统计 ----------

    /**
     * 媒体库统计（电影/电视剧/剧集/用户 + 本月新增）。
     *
     * 先走 JWT 的 `dashboard/statistic`；只有 API Token 时退回 `statistic2?token=`。
     * v2 起响应外面套了一层 `{success, data}`，这里统一拆开。
     */
    suspend fun statistic(): MpStatistic {
        val raw = runCatching { requestJson("api/v1/dashboard/statistic") }
            .getOrElse { error ->
                val token = server.apiToken.trim()
                if (token.isEmpty()) throw error
                requestJson("api/v1/dashboard/statistic2", listOf("token" to token))
            }
        val obj = when (raw) {
            is JSONObject -> raw.optJSONObject("data") ?: raw
            else -> JSONObject()
        }
        return MpStatistic(
            movies = obj.optInt("movie_count", 0),
            tvs = obj.optInt("tv_count", 0),
            episodes = obj.optInt("episode_count", 0),
            users = obj.optInt("user_count", 0),
            // 音乐是可选字段：MP 官方统计里没有就保持 0，不影响其它格子
            music = obj.optInt("music_count", 0),
            moviesThisMonth = obj.optInt("movie_count_month", 0),
            tvsThisMonth = obj.optInt("tv_count_month", 0),
            episodesThisMonth = obj.optInt("episode_count_month", 0),
            musicThisMonth = obj.optInt("music_count_month", 0)
        )
    }

    /**
     * 存储空间（`dashboard/storage`，单位字节）。
     *
     * 口径是媒体库目录所在磁盘的 `total_storage` / `used_storage`，MP 服务端已按
     * 物理盘去重，比各下载器自行上报的下载目录剩余更接近真实值。
     * JWT 失败时退回 `storage2?token=`（与 [statistic] 同样的 API Token 降级链）。
     */
    suspend fun storage(): MpStorage {
        val raw = runCatching { requestJson("api/v1/dashboard/storage") }
            .getOrElse { error ->
                val token = server.apiToken.trim()
                if (token.isEmpty()) throw error
                requestJson("api/v1/dashboard/storage2", listOf("token" to token))
            }
        val obj = when (raw) {
            is JSONObject -> raw.optJSONObject("data") ?: raw
            else -> JSONObject()
        }
        // schema 里这两个字段是 float，按 double 读再取整更稳
        val st = MpStorage(
            total = obj.optDouble("total_storage", 0.0).toLong(),
            used = obj.optDouble("used_storage", 0.0).toLong()
        )
        // v2 的 dashboard/storage 只统计「媒体库目录」所在盘：只配了「设置 → 存储 & 目录」
        // 里的存储、没配媒体库目录时它恒为 0。这时改读各存储的实际用量汇总再兜底，
        // 都拿不到才让调用方退回下载器口径。
        if (st.isEmpty) {
            val byUsage = storageFromUsage()
            if (byUsage.total > 0) return byUsage
        }
        return st
    }

    /**
     * v2 兜底：`设置 → 存储 & 目录` 里登记的各存储逐个查实际用量再汇总。
     *
     * - `GET /api/v1/system/setting/Storages` → [{type,name,config}, ...]
     * - `GET /api/v1/storage/usage/{type}` → {total, available}（v3 已移除该接口）
     * 用 type（local/alipan/u115…，纯 ASCII）而不是 name（中文）拼路径：
     * 实测 usage/本地 返回 0，usage/local 才是真值。
     * 同一块盘被多个存储条目指到会重复计数，按 total+available 组合去重。
     */
    private suspend fun storageFromUsage(): MpStorage {
        val token = server.apiToken.trim()
        val q = if (token.isEmpty()) emptyList() else listOf("token" to token)
        val listRaw = runCatching { requestJson("api/v1/system/setting/Storages", q) }
            .getOrNull() ?: return MpStorage()
        val root = listRaw as? JSONObject ?: return MpStorage()
        val holder = root.optJSONObject("data") ?: root
        val arr = holder.optJSONArray("value") ?: return MpStorage()

        var total = 0L
        var available = 0L
        val seen = mutableSetOf<String>()
        var tried = 0
        for (i in 0 until arr.length()) {
            if (tried >= 6) break
            val item = arr.optJSONObject(i) ?: continue
            val type = item.optString("type").trim()
            if (type.isEmpty()) continue
            tried++
            val usageRaw = runCatching { requestJson("api/v1/storage/usage/$type", q) }
                .getOrNull() ?: continue
            val uroot = usageRaw as? JSONObject ?: continue
            val u = uroot.optJSONObject("data") ?: uroot
            val t = u.optDouble("total", 0.0).toLong()
            val a = u.optDouble("available", 0.0).toLong()
            if (t <= 0) continue
            if (seen.add("$t:$a")) {
                total += t
                available += a
            }
        }
        return if (total > 0) {
            MpStorage(total = total, used = (total - available).coerceAtLeast(0))
        } else {
            MpStorage()
        }
    }

    // ---------- 连接测试 ----------
    suspend fun testConnection(): String = withEndpoint { endpoint ->
        ensureLogin()

        // 1) 先确认这个地址上真的有 MoviePilot 的 API。
        //    login/access-token 在 v1/v2 都存在且只接受 POST，用 GET 打它：
        //    405/401/403 都说明路由在（只是方法/鉴权不对），404 才是路径或服务不对。
        var routeOk = false
        execute(endpoint, "api/v1/login/access-token").use { r ->
            if (r.code != 404) routeOk = true
        }
        if (!routeOk) {
            // 某些反代会把 405 吞成 404，用 user/current 再兜一层
            execute(endpoint, "api/v1/user/current").use { r ->
                if (r.code != 404) routeOk = true
            }
        }
        if (!routeOk) {
            throw ApiException(
                "在 ${endpoint.display} 上找不到 MoviePilot 的接口（/api/v1 全部 404）。" +
                    "检查端口和子路径对不对，或者这个地址其实是别的服务。"
            )
        }

        // 2) 版本号：v2 有公开接口 system/global（不带鉴权），v1 没有则留空
        val version = runCatching {
            execute(
                endpoint, "api/v1/system/global", "GET",
                listOf("token" to "moviepilot")
            ).use { r ->
                if (!r.isSuccessful) ""
                else JSONObject(r.body?.string().orEmpty())
                    .optJSONObject("data")?.optString("BACKEND_VERSION").orEmpty()
            }
        }.getOrDefault("")

        // 3) 再用当前用户接口验证 Token 是否真的能过鉴权
        execute(endpoint, "api/v1/user/current").use { response ->
            val body = response.body?.string().orEmpty()
            val trimmed = body.trimStart()
            val jsonLike = trimmed.startsWith("{") || trimmed.startsWith("[")
            when {
                response.isSuccessful && !jsonLike -> throw ApiException(
                    "${endpoint.display} 返回的是网页而不是接口数据，" +
                        "多半是子路径不对（反代把 /api 也交给前端了）。"
                )

                response.isSuccessful -> {
                    val user = runCatching {
                        val obj = JSONObject(body)
                        obj.optString("name").ifBlank { obj.optString("username") }
                    }.getOrDefault("")
                    buildString {
                        append("连接成功 · ").append(endpoint.display)
                        if (version.isNotBlank()) append(" · MoviePilot ").append(version)
                        if (user.isNotBlank()) append(" · 用户 ").append(user)
                    }
                }

                response.code == 401 || response.code == 403 -> throw ApiException(
                    "地址已连通${if (version.isNotBlank()) "（MoviePilot $version）" else ""}，" +
                        "但鉴权失败：API Token 不对或没填。"
                )

                else -> throw ApiException(describeError(response.code, body))
            }
        }
    }

    // ---------- 发现 ----------

    suspend fun recommend(channel: MpDiscoverChannel, page: Int, count: Int = 30): List<MpMedia> {
        val query = mutableListOf("page" to page.toString(), "count" to count.toString())
        if (channel.extraQuery.isNotBlank()) {
            channel.extraQuery.split("&").forEach { pair ->
                val kv = pair.split("=", limit = 2)
                if (kv.size == 2) query += kv[0] to kv[1]
            }
        }
        val result = requestJson("api/v1/recommend/${channel.key}", query)
        val array = extractList(result)
        return array.mapNotNull { parseMedia(it) }
    }

    /** 兼容 {data: [...]}、{data:{items:[...]}} 与裸数组 */
    private fun extractList(result: Any): List<JSONObject> {
        val array = when (result) {
            is JSONArray -> result
            is JSONObject -> {
                val data = result.opt("data")
                when (data) {
                    is JSONArray -> data
                    is JSONObject -> data.optJSONArray("items") ?: data.optJSONArray("list") ?: JSONArray()
                    else -> result.optJSONArray("items") ?: JSONArray()
                }
            }

            else -> JSONArray()
        }
        return (0 until array.length()).mapNotNull { array.optJSONObject(it) }
    }

    // ---------- 搜索 ----------

    suspend fun searchMedia(keyword: String): List<MpMedia> {
        val result = requestJson("api/v1/media/search", listOf("title" to keyword))
        return extractList(result).mapNotNull { parseMedia(it) }
    }

    /**
     * MP v3 把媒体身份拆成了两段：路径里只放原生 ID，来源走 `media_source`
     * （themoviedb / douban / bangumi）；v1/v2 则用 `tmdb:550` 这种「来源:ID」
     * 单段路径。这里统一拆开，调用方按需拼两种 URL。
     */
    private data class MediaIdentity(
        /** v3 的 media_source，识别不出来就是 null（走旧路径） */
        val source: String?,
        /** v3 的路径参数：纯原生 ID */
        val rawId: String,
        /** v1/v2 的 mediaid：来源:ID */
        val legacyKey: String
    )

    private fun mediaIdentity(media: MpMedia): MediaIdentity {
        val key = media.searchKey
        val separator = key.indexOf(':')
        if (separator > 0) {
            val prefix = key.substring(0, separator).lowercase()
            val source = when (prefix) {
                "tmdb", "themoviedb" -> "themoviedb"
                "douban" -> "douban"
                "bangumi" -> "bangumi"
                else -> null
            }
            if (source != null) return MediaIdentity(source, key.substring(separator + 1), key)
        }
        return MediaIdentity(null, key, key)
    }

    /**
     * 判断这次失败是不是「接口版本不对」：v2 收到 v3 参数会回「未知的媒体ID」，
     * v3 收到 v2 参数会报 422（缺 media_source）/ 404（路由改了）。
     * 只有这几种情况才值得换另一种拼法再试一次。
     */
    private fun isVersionMismatch(error: Throwable): Boolean {
        val message = error.message.orEmpty()
        return message.contains("未知的媒体ID") ||
            message.contains("HTTP 422") ||
            message.contains("HTTP 404")
    }

    suspend fun mediaDetail(media: MpMedia): MpMedia {
        val identity = mediaIdentity(media)
        val typeName = if (media.isTV) "电视剧" else "电影"
        val result = if (identity.source != null) {
            runCatching {
                requestJson(
                    "api/v1/media/${identity.rawId}",
                    listOf("media_source" to identity.source, "type_name" to typeName)
                )
            }.getOrElse { error ->
                if (!isVersionMismatch(error)) throw error
                requestJson(
                    "api/v1/media/${identity.legacyKey}",
                    listOf("type_name" to typeName, "title" to media.title, "year" to media.yearLabel)
                )
            }
        } else {
            requestJson(
                "api/v1/media/${identity.legacyKey}",
                listOf("type_name" to typeName, "title" to media.title, "year" to media.yearLabel)
            )
        }
        val obj = when (result) {
            is JSONObject -> result.optJSONObject("data") ?: result
            else -> return media
        }
        return parseMedia(obj) ?: media
    }

    data class Person(val name: String, val role: String, val avatar: String)

    /**
     * credits 接口实际返回 `{cast: [...], crew: [...]}`，extractList 只认数组 / data / items，
     * 直接用它只能拿到空列表 → 详情页「演职员」整块消失（v1.0.16 修复）。
     * 先走标准结构，再兜底把 cast + crew 合并展开。
     */
    private fun creditList(result: Any): List<JSONObject> {
        val direct = extractList(result)
        if (direct.isNotEmpty()) return direct
        val root = result as? JSONObject ?: return emptyList()
        val holder = (root.opt("data") as? JSONObject) ?: root
        val out = mutableListOf<JSONObject>()
        listOf("cast", "crew").forEach { key ->
            val arr = holder.optJSONArray(key) ?: return@forEach
            for (i in 0 until arr.length()) {
                arr.optJSONObject(i)?.let { out.add(it) }
            }
        }
        return out
    }

    suspend fun credits(media: MpMedia): List<Person> {
        val key = media.searchKey
        val parts = key.split(":")
        if (parts.size != 2) return emptyList()
        val source = parts[0]
        val id = parts[1]
        val path = when (source) {
            "tmdb" -> "api/v1/tmdb/credits/$id/${if (media.isTV) "tv" else "movie"}"
            "douban" -> "api/v1/douban/credits/$id/${if (media.isTV) "tv" else "movie"}"
            "bangumi" -> "api/v1/bangumi/credits/$id"
            else -> return emptyList()
        }
        return runCatching {
            val result = requestJson(path)
            creditList(result).mapNotNull { obj ->
                val name = obj.optString("name").ifBlank { obj.optString("title") }
                if (name.isBlank()) null else Person(
                    name = name,
                    role = obj.optString("character").ifBlank { obj.optString("job") },
                    avatar = obj.optString("profile_path").ifBlank { obj.optString("avatar") }
                )
            }
        }.getOrDefault(emptyList())
    }

    // ---------- 资源搜索 ----------

    /**
     * 优先走 SFH 渐进式接口（`search/media/{id}/stream`），站搜完一个回一批；
     * 需要用户名密码登录拿到 resource_token Cookie，否则退回阻塞接口。
     *
     * MP v3 起精确搜索要求把来源单独放进 `media_source`、路径只留原生 ID，
     * 老版本则用 `tmdb:550` 单段路径 —— 这里先按 v3 拼，失败再按老版本重试。
     */
    suspend fun searchResources(
        media: MpMedia,
        onBatch: (List<MpResource>, String) -> Unit = { _, _ -> }
    ): List<MpResource> {
        val identity = mediaIdentity(media)
        val query = mutableListOf(
            "mtype" to if (media.isTV) "电视剧" else "电影",
            "area" to "title",
            "title" to media.title,
            "year" to media.yearLabel
        )
        if (media.isTV && media.season != null && media.season > 0) {
            query += "season" to media.season.toString()
        }
        // v3：来源走 query，路径只留 ID
        val v3Query = identity.source?.let { query + ("media_source" to it) }

        if (server.hasLogin && ensureLogin()) {
            val path: String
            val params: List<Pair<String, String>>
            if (v3Query != null) {
                path = "api/v1/search/media/${identity.rawId}/stream"
                params = v3Query
            } else {
                path = "api/v1/search/media/${identity.legacyKey}/stream"
                params = query
            }
            val streamed = runCatching { searchStream(path, params, onBatch) }.getOrNull()
            if (!streamed.isNullOrEmpty()) return streamed
        }

        if (v3Query != null) {
            val v3 = runCatching {
                searchBlocking("api/v1/search/media/${identity.rawId}", v3Query)
            }
            v3.getOrNull()?.let { return it }
            val error = v3.exceptionOrNull()
            // 只有「版本不匹配」才回退到旧路径；真的没资源/RPC 错误就如实报
            if (error != null && !isVersionMismatch(error)) throw error
        }

        return searchBlocking("api/v1/search/media/${identity.legacyKey}", query)
    }

    private suspend fun searchBlocking(path: String, query: List<Pair<String, String>>): List<MpResource> =
        withEndpoint { endpoint ->
            ensureLogin()
            execute(endpoint, path, query = query, slow = true).use { response ->
                val text = response.body?.string().orEmpty()
                if (!response.isSuccessful) throw ApiException(describeError(response.code, text), response.code)
                val root = runCatching { JSONObject(text) }.getOrNull() ?: return@withEndpoint emptyList()
                if (!root.optBoolean("success", true)) {
                    throw ApiException(root.optString("message").ifBlank { "未搜索到任何资源" })
                }
                extractList(root).mapNotNull { parseResource(it) }
            }
        }

    private suspend fun searchStream(
        path: String,
        query: List<Pair<String, String>>,
        onBatch: (List<MpResource>, String) -> Unit
    ): List<MpResource> = withEndpoint { endpoint ->
        val builder = Request.Builder()
            .url(url(endpoint, path, query))
            .header("Accept", "text/event-stream")
        headers().forEach { (k, v) -> builder.header(k, v) }

        val collected = LinkedHashMap<String, MpResource>()
        var errorMessage = ""

        sseClient.newCall(builder.build()).execute().use { response ->
            if (!response.isSuccessful) throw ApiException(describeError(response.code, ""), response.code)
            val source = response.body?.source() ?: throw ApiException("搜索流为空")
            while (!source.exhausted()) {
                val line = source.readUtf8Line() ?: break
                if (!line.startsWith("data:")) continue
                val payload = line.removePrefix("data:").trim()
                if (payload.isEmpty() || payload == "[DONE]") continue
                val event = runCatching { JSONObject(payload) }.getOrNull() ?: continue
                val type = event.optString("type")

                if (type == "error") {
                    errorMessage = event.optString("message").ifBlank { "搜索失败" }
                    continue
                }

                val items = event.optJSONArray("items") ?: continue
                if (type == "replace") collected.clear()
                var added = 0
                for (i in 0 until items.length()) {
                    val obj = items.optJSONObject(i) ?: continue
                    val resource = parseResource(obj) ?: continue
                    if (collected.put(resource.key, resource) == null) added++
                }
                if (added > 0) onBatch(collected.values.toList(), event.optString("stage"))
                if (type == "done") break
            }
        }

        if (collected.isEmpty() && errorMessage.isNotBlank()) throw ApiException(errorMessage)
        collected.values.toList()
    }

    // ---------- 下载 ----------

    suspend fun downloaders(): List<MpDownloader> {
        val result = requestJson("api/v1/download/clients")
        return extractList(result).mapNotNull { obj ->
            val name = obj.optString("name")
            if (name.isBlank()) null else MpDownloader(name = name, type = obj.optString("type"))
        }
    }

    suspend fun savePaths(): List<MpSavePath> {
        val result = runCatching { requestJson("api/v1/download/paths") }.getOrNull() ?: return emptyList()
        return extractList(result).mapNotNull { obj ->
            val savePath = obj.optString("save_path")
            if (savePath.isBlank()) null else MpSavePath(
                name = obj.optString("name").ifBlank { savePath },
                savePath = savePath,
                storage = obj.optString("storage")
            )
        }
    }

    suspend fun addDownload(resource: MpResource, downloader: String?, savePath: String?): String {
        val torrentIn = runCatching { JSONObject(resource.rawJson) }.getOrNull()
            ?: throw ApiException("资源数据缺失，无法提交")
        val body = JSONObject().put("torrent_in", torrentIn)
        if (!downloader.isNullOrBlank()) body.put("downloader", downloader)
        if (!savePath.isNullOrBlank()) body.put("save_path", savePath)

        val result = requestJson("api/v1/download/add", method = "POST", body = body, slow = true)
        val obj = (result as? JSONObject) ?: JSONObject()
        if (!obj.optBoolean("success", true)) {
            throw ApiException(obj.optString("message").ifBlank { "提交失败" })
        }
        return obj.optJSONObject("data")?.optString("download_id").orEmpty()
    }

    // ---------- 订阅 ----------

    suspend fun subscribes(): List<MpSubscribe> {
        val result = requestJson("api/v1/subscribe/")
        return extractList(result).mapNotNull { obj ->
            val id = obj.optInt("id", 0)
            if (id <= 0) null else MpSubscribe(
                id = id,
                name = obj.str("name"),
                year = obj.str("year"),
                type = obj.str("type"),
                season = obj.optInt("season", 0).takeIf { it > 0 },
                posterUrl = posterUrl(
                    obj.str("poster"),
                    obj.str("media_source").ifBlank { null }
                ),
                vote = obj.optDouble("vote", 0.0),
                totalEpisode = obj.optInt("total_episode", 0),
                lackEpisode = obj.optInt("lack_episode", 0),
                completedEpisode = obj.optInt("completed_episode", -1).takeIf { it >= 0 },
                state = obj.str("state", "R"),
                lastUpdate = obj.str("last_update"),
                sites = runCatching {
                    val arr = obj.optJSONArray("sites") ?: JSONArray()
                    (0 until arr.length()).map { arr.optInt(it) }
                }.getOrDefault(emptyList()),
                downloader = obj.str("downloader"),
                bestVersion = obj.optInt("best_version", 0) == 1,
                savePath = obj.str("save_path"),
                keyword = obj.str("keyword"),
                quality = obj.str("quality"),
                resolution = obj.str("resolution"),
                effect = obj.str("effect"),
                searchInterval = obj.optInt("search_interval", 0).takeIf { it > 0 },
                include = obj.str("include"),
                exclude = obj.str("exclude"),
                filterGroups = runCatching {
                    val arr = obj.optJSONArray("filter_groups") ?: JSONArray()
                    (0 until arr.length()).mapNotNull {
                        arr.optString(it).trim().takeIf { s -> s.isNotEmpty() && !s.equals("null", true) }
                    }
                }.getOrDefault(emptyList()),
                mediaCategory = obj.str("media_category"),
                customWords = obj.str("custom_words"),
                searchImdbId = obj.optInt("search_imdbid", 0) == 1,
                tmdbId = obj.optInt("tmdbid", 0).takeIf { it > 0 },
                doubanId = obj.str("doubanid"),
                bangumiId = obj.optInt("bangumiid", 0).takeIf { it > 0 },
                posterRaw = obj.str("poster"),
                backdropRaw = obj.str("backdrop"),
                description = obj.str("description"),
                startEpisode = obj.optInt("start_episode", 0),
                mediaSource = obj.str("media_source"),
                mediaIdRaw = obj.str("media_id").ifBlank { obj.str("mediaid") }
            )
        }.sortedByDescending { it.lastUpdate }
    }

    /**
     * 保存订阅设置（`PUT api/v1/subscribe/`）。
     *
     * **整条回传，不做“只发改动字段”的小聪明**：v2.9 的更新接口是 `model_dump()` 全量覆盖，
     * 少发 name / year / tmdbid 这些身份字段会被写成 null，订阅直接变成空壳。
     * v3 侧走 `to_public_write_payload()`，poster / vote 这类系统字段会被它自己剔除，多传无害。
     */
    suspend fun updateSubscribe(sub: MpSubscribe) {
        val body = JSONObject()
            .put("id", sub.id)
            .put("name", sub.name)
            .put("year", sub.year)
            .put("type", sub.type)
            .put("keyword", sub.keyword)
            .put("quality", sub.quality)
            .put("resolution", sub.resolution)
            .put("effect", sub.effect)
            .put("include", sub.include)
            .put("exclude", sub.exclude)
            .put("custom_words", sub.customWords)
            .put("media_category", sub.mediaCategory)
            .put("downloader", sub.downloader)
            .put("save_path", sub.savePath)
            .put("best_version", if (sub.bestVersion) 1 else 0)
            .put("search_imdbid", if (sub.searchImdbId) 1 else 0)
            .put("sites", JSONArray(sub.sites))
            .put("filter_groups", JSONArray(sub.filterGroups))
        sub.season?.takeIf { it > 0 }?.let { body.put("season", it) }
        // 下面这些是“原样回传”字段：v2.9 的更新接口整条覆盖，不回传就会被写成空
        if (sub.posterRaw.isNotBlank()) body.put("poster", sub.posterRaw)
        if (sub.backdropRaw.isNotBlank()) body.put("backdrop", sub.backdropRaw)
        if (sub.description.isNotBlank()) body.put("description", sub.description)
        if (sub.vote > 0) body.put("vote", sub.vote)
        if (sub.totalEpisode > 0) body.put("total_episode", sub.totalEpisode)
        if (sub.startEpisode > 0) body.put("start_episode", sub.startEpisode)
        sub.tmdbId?.let { body.put("tmdbid", it) }
        if (sub.doubanId.isNotBlank()) body.put("doubanid", sub.doubanId)
        sub.bangumiId?.let { body.put("bangumiid", it) }
        // 搜索周期：null = 跟随系统，v3 会按 CLEARABLE 字段清掉旧值
        body.put("search_interval", sub.searchInterval ?: JSONObject.NULL)

        val result = requestJson("api/v1/subscribe/", method = "PUT", body = body)
        val obj = (result as? JSONObject) ?: JSONObject()
        if (!obj.optBoolean("success", true)) {
            throw ApiException(obj.optString("message").ifBlank { "保存失败" })
        }
    }

    /** 过滤规则组名称（订阅设置的「优先级规则组」选项）；拿不到就当没配，界面隐藏该行 */
    suspend fun ruleGroups(): List<String> {
        val result = runCatching { requestJson("api/v1/rule/groups") }.getOrNull() ?: return emptyList()
        val root = (result as? JSONObject) ?: return emptyList()
        val holder = (root.optJSONObject("data") ?: root)
        val arr = holder.optJSONArray("rule_groups") ?: holder.optJSONArray("groups") ?: return emptyList()
        return (0 until arr.length()).mapNotNull { index ->
            when (val item = arr.opt(index)) {
                is JSONObject -> item.optString("name").takeIf { it.isNotBlank() }
                is String -> item.takeIf { it.isNotBlank() }
                else -> null
            }
        }.distinct()
    }

    /**
     * MP「系统设置 → 订阅 → 订阅站点」里勾选过的站点 id（配置键 `RssSites`）。
     *
     * 订阅只允许用这些站点，所以编辑订阅的站点选择器只能列这一批，不能把全部站点都摆出来。
     * 返回 `null` 表示这台 MP 没有这项设置（老版本 / 无权限），调用方按「不限制」处理；
     * 返回空集合表示用户明确一个都没勾。
     */
    suspend fun rssSiteIds(): Set<Int>? {
        val result = runCatching { requestJson("api/v1/system/setting/RssSites") }.getOrNull() ?: return null
        val root = (result as? JSONObject) ?: return null
        if (!root.optBoolean("success", true)) return null
        val holder = root.optJSONObject("data") ?: root
        val value = holder.opt("value") ?: return null
        return when (value) {
            is JSONArray -> (0 until value.length())
                .mapNotNull { value.optInt(it, 0).takeIf { id -> id > 0 } }
                .toSet()
            // v2 及更早存的是 "1,2,3" 这样的字符串
            is String -> value.split(",")
                .mapNotNull { it.trim().toIntOrNull()?.takeIf { id -> id > 0 } }
                .toSet()
            is Number -> setOf(value.toInt()).filter { it > 0 }.toSet()
            else -> null
        }
    }

    /**
     * 新增订阅。
     *
     * **一次请求同时带上两套媒体身份**，不猜版本：
     * - `tmdbid` / `doubanid` / `bangumiid`：v1、v2.x 只认这套；
     * - `media_source` + `media_id`：v3 只认这一对，缺一个会回「必须同时提供有效的 media_source 和 media_id」。
     *
     * 两套字段在对方版本的模型里都是「不认识的额外字段」，pydantic 默认忽略，
     * 所以一起发不会互相干扰；v3 认的 `media_source` 取值是 themoviedb / douban / bangumi
     * （传 `tmdb` 这种简写会被枚举校验打成 422，[mediaSourceName] 已归一）。
     *
     * 只有身份被 v3 明确拒绝（缺一半 / 来源不认 / ID 不存在）时，才去掉身份两字段用纯旧字段重试一次。
     */
    suspend fun subscribe(media: MpMedia, season: Int? = null): String {
        val typeName = if (media.isTV) "电视剧" else "电影"
        val targetSeason = (season ?: media.season)?.takeIf { media.isTV && it > 0 }
        val first = runCatching { postSubscribe(subscribeBody(media, typeName, targetSeason, withIdentity = true)) }
        first.getOrNull()?.let { return it }

        val error = first.exceptionOrNull() ?: return "已加入订阅"
        // 业务报错（已订阅、无权限、搜索不到）直接抛给界面，不要瞎重试
        if (!identityRejected(error)) throw error
        return postSubscribe(subscribeBody(media, typeName, targetSeason, withIdentity = false))
    }

    private fun subscribeBody(
        media: MpMedia,
        typeName: String,
        season: Int?,
        withIdentity: Boolean
    ): JSONObject {
        val body = JSONObject()
            .put("name", media.title)
            .put("year", media.yearLabel)
            .put("type", typeName)
        // v1 / v2 的原生 ID 字段
        media.tmdbId?.takeIf { it > 0 }?.let { body.put("tmdbid", it) }
        media.doubanId?.takeIf { it.isNotBlank() }?.let { body.put("doubanid", it) }
        media.bangumiId?.takeIf { it > 0 }?.let { body.put("bangumiid", it) }
        // v3 的媒体身份：详情页已验证可用，订阅沿用同一对，别再自己拼
        if (withIdentity) {
            val identity = mediaIdentity(media)
            val source = identity.source ?: mediaSourceName(media.source)
            if (identity.rawId.isNotBlank()) {
                body.put("media_source", source)
                body.put("media_id", identity.rawId)
            }
        }
        season?.let { body.put("season", it) }
        if (media.posterUrl.isNotBlank()) body.put("poster", media.posterUrl)
        return body
    }

    /** v3 的媒体身份校验没过（缺一半 / 来源不认 / ID 不存在 → 422 或明确文案） */
    private fun identityRejected(error: Throwable): Boolean {
        val message = error.message.orEmpty()
        return message.contains("必须同时提供") ||
            message.contains("未知的媒体ID") ||
            message.contains("HTTP 422")
    }

    private fun mediaSourceName(source: String): String = when (source.lowercase()) {
        "douban" -> "douban"
        "bangumi" -> "bangumi"
        else -> "themoviedb"
    }

    private suspend fun postSubscribe(body: JSONObject): String {
        val result = requestJson("api/v1/subscribe/", method = "POST", body = body)
        val obj = (result as? JSONObject) ?: JSONObject()
        if (!obj.optBoolean("success", true)) {
            throw ApiException(obj.optString("message").ifBlank { "订阅失败" })
        }
        return obj.optString("message").ifBlank { "已加入订阅" }
    }

    suspend fun deleteSubscribe(id: Int) {
        val result = requestJson("api/v1/subscribe/$id", method = "DELETE")
        val obj = (result as? JSONObject) ?: JSONObject()
        if (!obj.optBoolean("success", true)) throw ApiException(obj.optString("message").ifBlank { "删除失败" })
    }

    suspend fun updateSubscribeState(id: Int, state: String) {
        requestJson(
            "api/v1/subscribe/status/$id",
            query = listOf("state" to state),
            method = "PUT"
        )
    }

    /** 立即搜索这一条订阅（`POST api/v1/subscribe/search/{id}`），返回 MP 的提示文案 */
    suspend fun searchSubscribe(id: Int): String {
        val result = requestJson("api/v1/subscribe/search/$id", method = "POST", slow = true)
        val obj = (result as? JSONObject) ?: JSONObject()
        if (!obj.optBoolean("success", true)) {
            throw ApiException(obj.optString("message").ifBlank { "搜索失败" })
        }
        return obj.optString("message").ifBlank { "已开始搜索" }
    }

    /** 重置订阅：清空已完成集数，重新按缺失集数搜（`POST api/v1/subscribe/reset/{id}`） */
    suspend fun resetSubscribe(id: Int): String {
        val result = requestJson("api/v1/subscribe/reset/$id", method = "POST")
        val obj = (result as? JSONObject) ?: JSONObject()
        if (!obj.optBoolean("success", true)) {
            throw ApiException(obj.optString("message").ifBlank { "重置失败" })
        }
        return obj.optString("message").ifBlank { "已重置订阅" }
    }

    /**
     * 订阅相关文件信息（`GET api/v1/subscribe/files/{id}`）。
     *
     * 返回 `{subscribe, episodes: {"1": {download: [...], library: [...]}}}`；不同版本字段可能缺，
     * 所以直接吐原始 JSON，由调用方按需拼文案，别在这里锁死结构。
     */
    suspend fun subscribeFiles(id: Int): JSONObject {
        val result = requestJson("api/v1/subscribe/files/$id", slow = true)
        return (result as? JSONObject) ?: JSONObject()
    }

    /** 订阅历史（`GET api/v1/subscribe/history/{mtype}`），mtype 传「电影」或「电视剧」 */
    suspend fun subscribeHistory(mtype: String, count: Int = 50): List<JSONObject> {
        val result = requestJson(
            "api/v1/subscribe/history/$mtype",
            query = listOf("page" to "1", "count" to count.toString())
        )
        return extractList(result).mapNotNull { it as? JSONObject }
    }

    // ---------- 站点（只读同步 MoviePilot） ----------

    /**
     * 站点列表。
     *
     * v3 的 `/api/v1/site/` 要求 **manage user**（管理员）权限，普通用户 token 会 403；
     * 老版本 MP 没有这个路由，会 404。两种情况都靠 [ApiException.code] 交给 VM 翻译。
     */
    suspend fun sites(): List<MpSite> {
        val result = requestJson("api/v1/site/")
        return extractList(result).mapNotNull { obj ->
            val id = obj.optInt("id", 0)
            val name = obj.optString("name").trim()
            if (id <= 0 || name.isEmpty()) {
                null
            } else {
                MpSite(
                    id = id,
                    name = name,
                    domain = obj.optString("domain"),
                    url = obj.optString("url"),
                    pri = obj.optInt("pri", 0),
                    // 字段缺失时按「启用」处理：MP 里 is_active 恒有值，缺失说明版本差异，
                    // 宁可显示出来也别把用户所有站点都置灰
                    isActive = if (obj.has("is_active")) obj.optBoolean("is_active", true) else true,
                    downloader = obj.optString("downloader"),
                    note = obj.optString("note")
                )
            }
        }.sortedForDisplay()
    }

    /**
     * 所有站点最新个人数据（MP 定时抓取，不是实时）。
     *
     * **不要传 page/count**：MP v3 的 `CompatiblePageParam` 是 `Query(ge = 1)`，
     * 页码从 1 开始，传 `page=0` 会直接 422（之前就是这样导致所有站点都没有数据）。
     * 两个参数都省略时接口返回全量列表，站点数量上百也没问题。
     */
    suspend fun siteUserData(): List<MpSiteUserData> {
        val result = requestJson("api/v1/site/userdata/latest")
        return extractList(result).map { obj ->
            MpSiteUserData(
                domain = obj.optString("domain"),
                name = obj.optString("name"),
                username = obj.optString("username"),
                userLevel = obj.optString("user_level").ifBlank { obj.optString("user_level_name") },
                joinAt = obj.optString("join_at"),
                bonus = obj.optDouble("bonus", 0.0),
                upload = obj.optDouble("upload", 0.0).toLong(),
                download = obj.optDouble("download", 0.0).toLong(),
                ratio = obj.optDouble("ratio", 0.0),
                seeding = obj.optInt("seeding", 0),
                leeching = obj.optInt("leeching", 0),
                seedingSize = obj.optDouble("seeding_size", 0.0).toLong(),
                leechingSize = obj.optDouble("leeching_size", 0.0).toLong(),
                messageUnread = obj.optInt("message_unread", 0),
                messageTotal = obj.optInt("message_total", 0),
                errMsg = obj.optString("err_msg"),
                updatedDay = obj.optString("updated_day"),
                updatedTime = obj.optString("updated_time")
            )
        }
    }

    /** 站点分类；拿不到就返回空（UI 会把分类行整行隐藏，不影响浏览） */
    suspend fun siteCategories(siteId: Int): List<MpSiteCategory> {
        val result = runCatching { requestJson("api/v1/site/category/$siteId") }.getOrNull()
            ?: return emptyList()
        return extractList(result).mapNotNull { obj ->
            val rawId = when (val value = obj.opt("id")) {
                null, JSONObject.NULL -> ""
                is Number -> value.toLong().toString()
                else -> value.toString().trim()
            }
            val cat = obj.optString("cat").trim()
            val desc = obj.optString("desc").trim()
            if (rawId.isEmpty() && cat.isEmpty() && desc.isEmpty()) {
                null
            } else {
                MpSiteCategory(id = rawId, cat = cat, desc = desc)
            }
        }
    }

    /**
     * 站点图标（`GET api/v1/site/icon/{id}`）。
     *
     * MP 侧的表里存的可能是 **http 地址**，也可能是**纯 base64**（没有 `data:` 前缀），
     * 所以这里只把原始字符串交出去，统一由 [SiteIconStore] 决定怎么喂给图片库。
     *
     * 返回值语义要分清（调用方靠它决定「要不要重试」）：
     * - 拿到字符串 → 有图标；
     * - `null` → **MP 明确说这个站没有图标**（`success:false` / 404 / 空内容）；
     * - 抛异常 → 网络或鉴权失败，这是可以重试的，不能当成「没有图标」。
     */
    suspend fun siteIcon(siteId: Int): String? = withEndpoint { endpoint ->
        ensureLogin()
        execute(endpoint, "api/v1/site/icon/$siteId", httpClient = Net.posterClient).use { r ->
            val text = r.body?.string().orEmpty()
            if (r.code == 404) return@withEndpoint null
            if (!r.isSuccessful) throw ApiException(describeError(r.code, text), r.code)
            if (text.isBlank()) return@withEndpoint null
            val root = runCatching { JSONObject(text) }.getOrNull() ?: return@withEndpoint null
            if (root.has("success") && !root.optBoolean("success", false)) return@withEndpoint null
            val holder = (root.opt("data") as? JSONObject) ?: root
            holder.optString("icon").trim().ifBlank { null }
        }
    }

    /**
     * 浏览站点种子（`GET api/v1/site/resource/{id}`）。
     *
     * **同步阻塞**：MP 会真的去打开站点网页抓列表，慢站点 5～30 秒很常见，
     * 所以强制走 [Net.slowClient]（read 130s / call 180s）；page 从 0 开始且没有 count 参数。
     * 站点浏览返回的 torrent 一般不带 `site_name`，用当前站点名兜底，否则筛选/卡片会显示「未知站点」。
     */
    suspend fun siteTorrents(
        siteId: Int,
        siteName: String,
        keyword: String = "",
        cats: List<String> = emptyList(),
        page: Int = 0
    ): List<MpResource> = withEndpoint { endpoint ->
        ensureLogin()
        val query = mutableListOf("page" to page.toString())
        if (keyword.isNotBlank()) query += "keyword" to keyword
        if (cats.isNotEmpty()) query += "cat" to cats.joinToString(",")

        execute(endpoint, "api/v1/site/resource/$siteId", query = query, slow = true).use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw ApiException(describeError(response.code, text), response.code)
            }
            val root = runCatching { parseAny(text) }.getOrNull() ?: return@withEndpoint emptyList()
            extractList(root).mapNotNull { parseResource(it, siteName) }
        }
    }

    /**
     * 把种子标题丢给 MP 识别，取出海报路径（`media_info.poster_path`）。
     *
     * 比拿标题去 TMDB 关键词搜准得多：MP 用的是自己的识别词规则 + 媒体库匹配。
     * 失败一律返回 null（超时 8 秒 / 未识别 / 未配图），UI 落渐变占位，不阻塞列表。
     */
    suspend fun sitePoster(title: String): String? = withEndpoint { endpoint ->
        val response = runCatching {
            ensureLogin()
            execute(
                endpoint,
                "api/v1/media/recognize",
                query = listOf("title" to title),
                httpClient = Net.posterClient
            )
        }.getOrNull() ?: return@withEndpoint null

        response.use { r ->
            val text = r.body?.string().orEmpty()
            if (!r.isSuccessful) return@withEndpoint null
            val root = runCatching { JSONObject(text) }.getOrNull() ?: return@withEndpoint null
            val holder = (root.opt("data") as? JSONObject) ?: root
            val media = holder.optJSONObject("media_info")
                ?: holder.optJSONObject("media")
                ?: return@withEndpoint null
            val path = media.optString("poster_path").ifBlank { media.optString("poster") }
            if (path.isBlank()) return@withEndpoint null
            val source = media.optString("media_source").ifBlank { media.optString("source") }
            PosterUrl.normalize(path, source, activeBaseUrl)
                .replace("/t/p/w500", "/t/p/w185")
        }
    }

    /**
     * 种子标题 → MP 识别出的整条媒体信息。
     *
     * 站点接口只给文字（标题 / 简介 / 体积），海报要靠 recognise 反查；
     * 顺手把 `media_info` 整条解析成 MpMedia，站点种子详情页才能和
     * MP 搜索结果页显示同一套内容（中文标题、类型、简介、演职员）。
     */
    suspend fun recognizeMedia(title: String): MpMedia? = withEndpoint { endpoint ->
        val response = runCatching {
            ensureLogin()
            execute(
                endpoint,
                "api/v1/media/recognize",
                query = listOf("title" to title),
                httpClient = Net.posterClient
            )
        }.getOrNull() ?: return@withEndpoint null

        response.use { r ->
            val text = r.body?.string().orEmpty()
            if (!r.isSuccessful) return@withEndpoint null
            val root = runCatching { JSONObject(text) }.getOrNull() ?: return@withEndpoint null
            val holder = (root.opt("data") as? JSONObject) ?: root
            val media = holder.optJSONObject("media_info")
                ?: holder.optJSONObject("media")
                ?: return@withEndpoint null
            parseMedia(media)
        }
    }

    // ---------- 解析 ----------

    private fun posterUrl(raw: String, source: String? = null): String =
        PosterUrl.normalize(raw, source, activeBaseUrl)

    private fun parseMedia(obj: JSONObject): MpMedia? {
        val title = obj.optString("title").ifBlank { obj.optString("name") }
        if (title.isBlank()) return null

        val rawSource = obj.optString("media_source").ifBlank { obj.optString("source") }
        val source = when (rawSource.lowercase()) {
            "themoviedb", "" -> "tmdb"
            else -> rawSource.lowercase()
        }
        val tmdbId = obj.optInt("tmdb_id", 0).takeIf { it > 0 }
        val doubanId = obj.optString("douban_id").takeIf { it.isNotBlank() }
        val bangumiId = obj.optInt("bangumi_id", 0).takeIf { it > 0 }
        val mediaId = obj.optString("media_id").ifBlank { obj.optString("mediaid") }

        val key = when {
            mediaId.contains(":") -> mediaId
            tmdbId != null -> "tmdb:$tmdbId"
            doubanId != null -> "douban:$doubanId"
            bangumiId != null -> "bangumi:$bangumiId"
            else -> mediaId
        }

        val typeRaw = obj.optString("type")
        val type = when {
            typeRaw.equals("电视剧", true) || typeRaw.equals("tv", true) -> "电视剧"
            else -> "电影"
        }

        return MpMedia(
            mediaId = key,
            source = source,
            type = type,
            title = title,
            year = obj.optString("year").ifBlank { obj.optString("title_year") },
            season = obj.optInt("season", 0).takeIf { it > 0 },
            tmdbId = tmdbId,
            doubanId = doubanId,
            bangumiId = bangumiId,
            posterUrl = posterUrl(obj.optString("poster_path").ifBlank { obj.optString("poster") }, source),
            backdropUrl = posterUrl(obj.optString("backdrop_path"), source),
            overview = obj.optString("overview").ifBlank { obj.optString("description") },
            vote = obj.optDouble("vote_average", 0.0).takeIf { it > 0 }
                ?: obj.optDouble("vote", 0.0),
            genres = stringList(obj, listOf("genres", "genre_names", "genre")),
            directors = stringList(obj, listOf("directors", "director", "director_names")),
            cast = stringList(obj, listOf("actors", "casts", "actor", "cast")),
            releaseDate = obj.optString("release_date").ifBlank { obj.optString("first_air_date") },
            category = obj.optString("category")
        )
    }

    private fun stringList(obj: JSONObject, keys: List<String>): List<String> {
        for (key in keys) {
            val arr = obj.optJSONArray(key)
            if (arr != null) {
                return (0 until arr.length()).mapNotNull { index ->
                    val item = arr.opt(index)
                    when (item) {
                        is String -> item.takeIf { it.isNotBlank() }
                        is JSONObject -> item.optString("name").takeIf { it.isNotBlank() }
                        else -> null
                    }
                }.distinct()
            }
            val single = obj.optString(key)
            if (single.isNotBlank()) {
                return single.split(",", "/", "|", "、").map { it.trim() }.filter { it.isNotEmpty() }
            }
        }
        return emptyList()
    }

    private fun parseResource(obj: JSONObject, fallbackSiteName: String? = null): MpResource? {
        val torrentObj = obj.optJSONObject("torrent_info") ?: obj
        val title = torrentObj.optString("title")
        if (title.isBlank()) return null
        val siteName = torrentObj.optString("site_name").ifBlank {
            torrentObj.optString("site").ifBlank {
                fallbackSiteName?.trim().orEmpty().ifBlank { "未知站点" }
            }
        }
        val sizeRaw = torrentObj.optDouble("size", 0.0)
        val size = if (sizeRaw > 0 && sizeRaw < 1e5) (sizeRaw * 1024 * 1024 * 1024).toLong() else sizeRaw.toLong()
        val pubDate = torrentObj.optString("pubdate").ifBlank { torrentObj.optString("pub_date") }

        return MpResource(
            key = "$siteName|$title|${torrentObj.optLong("size", 0)}",
            siteName = siteName,
            title = title,
            description = cleanTorrentDescription(torrentObj.optString("description")),
            pageUrl = torrentObj.optString("page_url"),
            sizeBytes = size,
            seeders = torrentObj.optInt("seeders", 0),
            peers = torrentObj.optInt("peers", 0),
            grabs = torrentObj.optInt("grabs", 0),
            pubDateText = pubDate,
            pubDateMs = parsePubDate(pubDate),
            downloadFactor = torrentObj.optDouble("downloadvolumefactor", 1.0),
            uploadFactor = torrentObj.optDouble("uploadvolumefactor", 1.0),
            hitAndRun = torrentObj.optBoolean("hit_and_run", false),
            labels = runCatching {
                val arr = torrentObj.optJSONArray("labels") ?: JSONArray()
                (0 until arr.length()).mapNotNull { arr.optString(it).takeIf { s -> s.isNotBlank() } }
            }.getOrDefault(emptyList()),
            rawJson = torrentObj.toString()
        )
    }

    /**
     * 清掉种子描述里被一起抓进来的站点 label 文本。
     *
     * 部分站点（已知 hdfans 红豆饭）种子列表的副标题 HTML 结构和别的站不同，
     * MoviePilot 的解析器会把「剩余时间：」这个 label 节点也当成正文取下来，
     * 结果 App 上每条种子副标题都以「剩余时间：」开头。
     * 服务端改不了，所以 App 侧做一层防御：只剥掉**已知 label 前缀**，
     * 其余内容原样保留，避免误伤正文（比如「类型：纪录片」这种是正文的一部分）。
     */
    private fun cleanTorrentDescription(raw: String): String {
        var text = raw.trim()
        if (text.isEmpty()) return text
        val labelPrefixes = listOf(
            "剩余时间：", "剩余时间:",
            "发布时间：", "发布时间:",
            "副标题：", "副标题:",
            "大小：", "大小:"
        )
        for (prefix in labelPrefixes) {
            if (text.startsWith(prefix)) {
                text = text.removePrefix(prefix).trim()
                break
            }
        }
        return text
    }

    private fun parsePubDate(raw: String): Long {
        if (raw.isBlank()) return System.currentTimeMillis()
        val patterns = listOf(
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "EEE, dd MMM yyyy HH:mm:ss Z"
        )
        for (pattern in patterns) {
            val value = runCatching {
                java.text.SimpleDateFormat(pattern, java.util.Locale.US).parse(raw)?.time
            }.getOrNull()
            if (value != null) return value
        }
        return System.currentTimeMillis()
    }
}

/**
 * org.json 的 `optString` 遇到 JSON null 会返回字符串 "null"，直接显示在界面上就是一行 "null"。
 * MP 的订阅里 keyword / quality / include 这些字段大量使用 null 表示「未设置」，
 * 统一走这里收干净：缺字段、null、空串、字面量 "null" 一律当空。
 */
private fun JSONObject.str(key: String, default: String = ""): String {
    if (!has(key) || isNull(key)) return default
    val raw = optString(key).trim()
    return if (raw.isEmpty() || raw.equals("null", ignoreCase = true)) default else raw
}
