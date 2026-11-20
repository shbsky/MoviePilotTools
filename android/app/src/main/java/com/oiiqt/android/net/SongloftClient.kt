package com.oiiqt.android.net

import com.oiiqt.android.data.Endpoint
import com.oiiqt.android.data.MusicLibraryStats
import com.oiiqt.android.data.MusicPlaylist
import com.oiiqt.android.data.MusicSong
import com.oiiqt.android.data.TokenVault
import com.oiiqt.android.data.parseEndpoints
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Songloft 音乐服务客户端。
 *
 * 协议（从 Songloft 前端 bundle 里逆出来的，不是猜的）：
 *  1. `POST /api/v1/auth/login`  body `{username,password}`
 *     → `{access_token, refresh_token, expires_in, token_type}`
 *  2. 之后所有请求 `Authorization: Bearer <access_token>`；媒体地址则用 `?access_token=xxx`
 *     查询参数（Songloft 自己的播放器就是这么拼的）
 *  3. `GET /api/v1/songs?limit&offset&keyword`  → `{items:[...], total}`
 *     `GET /api/v1/playlists?limit&offset`      → `{items:[...], total}`
 *     `GET /api/v1/playlists/{id}/songs?limit&offset`
 *     `GET /api/v1/songs/stats`                 → `{total_songs, artist_count, album_count, ...}`
 *
 * 歌曲字段：id / title / artist / album / duration(秒) / url / cover_url / format / bit_rate / is_video
 */
class SongloftClient(
    rawBaseUrl: String,
    private val username: String,
    private val password: String
) {

    /** 一行一个地址：内网 IP + 公网域名，连之前先探测，谁通就用谁 */
    private val endpoints: List<Endpoint> = parseEndpoints(rawBaseUrl)

    @Volatile
    private var resolved: String = ""

    /** 实际在用的地址（探测后才知道） */
    private fun base(): String {
        val cached = resolved
        if (cached.isNotEmpty()) return cached
        // 探测在阻塞线程里做（本类的接口都在 IO 上跑），失败先用第一条
        val chosen = endpoints.mapNotNull { endpoint ->
            val ok = runCatching {
                Net.probeClient.newCall(Request.Builder().url(endpoint.url("/api/v1/songs?limit=1")).build())
                    .execute().use { it.code in 200..399 || it.code == 401 || it.code == 403 }
            }.getOrDefault(false)
            if (ok) endpoint else null
        }.firstOrNull() ?: endpoints.firstOrNull()
        val value = chosen?.display.orEmpty()
        resolved = value
        return value
    }

    private fun invalidateBase() {
        resolved = ""
    }

    /**
     * 地址轮换：这个地址连不上就换下一个（内网 → 外网域名）。
     *
     * 只对**网络层**失败重试；业务错误（401/404）不换地址，否则会把问题藏起来。
     */
    private fun <T> rotating(block: () -> T): T {
        val count = endpoints.size.coerceAtLeast(1)
        var last: Exception? = null
        repeat(count) {
            try {
                return block()
            } catch (e: java.io.IOException) {
                last = e
                invalidateBase()
            }
        }
        throw last ?: ApiException("连不上 Songloft，检查地址和网络")
    }

    val isConfigured: Boolean get() = endpoints.isNotEmpty() && username.isNotBlank()

    fun label(): String =
        (resolved.ifEmpty { endpoints.firstOrNull()?.display ?: "" })
            .substringAfter("://").trimEnd('/')

    /** 当前配置里的所有候选地址（会话 token 在这些地址上通用） */
    private fun bases(): List<String> = endpoints.map { it.display.trimEnd('/') }

    private val http: OkHttpClient = Net.client.newBuilder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(25, TimeUnit.SECONDS)
        .callTimeout(35, TimeUnit.SECONDS)
        .build()

    /** 本实例是否已经强制重登过（防止 401 风暴） */
    @Volatile
    private var forceReloginUsed = false

    // ---------------------------------------------------------------- 账号

    /** 登录并写入全局会话（图片/音频请求靠它补 token） */
    private fun login(): String {
        if (base().isEmpty()) throw ApiException("还没填 Songloft 地址（设置 → 音乐服务）")
        if (username.isBlank()) throw ApiException("还没填 Songloft 账号")

        val payload = JSONObject()
            .put("username", username)
            .put("password", password)
            .toString()
        // 登录也要能换地址：内网不通（在外面用流量）就自动走公网域名
        val loginResponse = rotating {
            val request = Request.Builder()
                .url(url("/api/v1/auth/login"))
                .post(payload.toRequestBody(JSON))
                .build()
            http.newCall(request).execute()
        }

        loginResponse.use { res ->
            val body = res.body?.string().orEmpty()
            val json = runCatching { JSONObject(body) }.getOrNull()
                ?: throw ApiException(
                    if (body.trimStart().startsWith("<"))
                        "登录返回的是网页而不是数据，地址可能少填端口或指到了别的服务"
                    else "登录返回异常（HTTP ${res.code}）"
                )
            if (!res.isSuccessful) {
                val message = json.optString("error").ifBlank { json.optString("detail") }
                // Songloft 对登录接口有频率限制：短时间内多次登录会返回
                // 「登录尝试过于频繁，请稍后再试」。这里记下来并进入冷却，
                // 否则用户连续打开几次 App 就会一直撞限流。
                val limited = res.code == 429 ||
                    message.contains("频繁") ||
                    message.contains("too many", true) ||
                    message.contains("rate limit", true)
                if (limited) {
                    // 服务端限流是递增惩罚，固定 60 秒会越撞越久 —— 用指数退避。
                    // 优先采信服务端给的 Retry-After。
                    val retryAfter = res.header("Retry-After")?.trim()?.toLongOrNull()
                    SongloftSession.markBlocked(
                        seconds = retryAfter?.coerceIn(30L, 900L),
                        message = message
                    )
                    throw ApiException(SongloftSession.cooldownMessage(), res.code)
                }
                throw ApiException(
                    when {
                        message.contains("密码") || message.contains("credentials") -> "账号或密码不对"
                        res.code == 401 -> "账号或密码不对"
                        message.isNotBlank() -> message
                        else -> "登录失败（HTTP ${res.code}）"
                    },
                    res.code
                )
            }
            val token = json.optString("access_token")
            if (token.isBlank()) throw ApiException("登录成功但没返回 access_token，服务端版本可能不匹配")
            val expiresIn = json.optLong("expires_in", 0L)
            SongloftSession.update(
                base = base(),
                token = token,
                expiresAt = if (expiresIn > 0) System.currentTimeMillis() + expiresIn * 1000L else 0L
            )
            return token
        }
    }

    private val loginLock = Any()

    private fun ensureToken(force: Boolean = false): String {
        val blockedUntil = SongloftSession.blockedUntil
        if (System.currentTimeMillis() < blockedUntil) {
            throw ApiException(SongloftSession.cooldownMessage())
        }
        val reused = SongloftSession.takeIf { !force && it.matches(bases()) }
        if (reused != null) return reused.token
        // 首次进入音乐页会并发拉歌曲/歌单/统计，这里只让一个线程真登录
        synchronized(loginLock) {
            val again = SongloftSession.takeIf { !force && it.matches(bases()) }
            if (again != null) return again.token
            return login()
        }
    }

    // ---------------------------------------------------------------- 接口

    suspend fun test(): String = withContext(Dispatchers.IO) {
        ensureToken(force = true)
        val stats = runCatching { statsBlocking() }.getOrNull()
        if (stats == null) "登录成功" else "登录成功 · 音乐库 ${stats.totalSongs} 首 / ${stats.artistCount} 位歌手"
    }

    suspend fun songs(keyword: String = "", offset: Int = 0, limit: Int = 50): SongPage =
        withContext(Dispatchers.IO) {
            val query = buildString {
                append("limit=$limit&offset=$offset")
                if (keyword.isNotBlank()) append("&keyword=${enc(keyword)}")
            }
            val json = get("/api/v1/songs?$query")
            parseSongs(json)
        }

    suspend fun playlists(limit: Int = 40, offset: Int = 0): List<MusicPlaylist> =
        withContext(Dispatchers.IO) {
            val json = get("/api/v1/playlists?limit=$limit&offset=$offset")
            val array = json.arrayOf("items", "data", "playlists", "list")
            if (array == null) emptyList() else buildList {
                for (i in 0 until array.length()) {
                    val obj = array.optJSONObject(i) ?: continue
                    add(parsePlaylist(obj))
                }
            }
        }

    suspend fun playlistSongs(id: Long, offset: Int = 0, limit: Int = 200): SongPage =
        withContext(Dispatchers.IO) {
            val json = get("/api/v1/playlists/$id/songs?limit=$limit&offset=$offset")
            parseSongs(json)
        }

    // ---------------------------------------------------------------- 收藏
    // Songloft 的「收藏」就是服务端内建歌单（labels 含 built_in，id 固定 1），
    // 收藏/取消收藏 = 往这个歌单里加/删歌。

    /** 全量收藏歌曲 id（翻页拿完，用于列表红心标记） */
    suspend fun favoriteIds(): Set<Long> = withContext(Dispatchers.IO) {
        val ids = LinkedHashSet<Long>()
        var offset = 0
        while (true) {
            val page = parseSongs(get("/api/v1/playlists/$FAVORITE_PLAYLIST_ID/songs?limit=200&offset=$offset"))
            ids += page.songs.map { it.id }
            if (page.songs.isEmpty() || ids.size >= page.total) break
            offset += page.songs.size
        }
        ids
    }

    /** @return true = 服务端已生效（失败返回 false，由调用方回滚乐观更新） */
    suspend fun setFavorite(songId: Long, favorite: Boolean): Boolean =
        withContext(Dispatchers.IO) {
            runCatching {
                if (favorite) {
                    val payload = JSONObject().put("song_ids", JSONArray().put(songId)).toString()
                    send("/api/v1/playlists/$FAVORITE_PLAYLIST_ID/songs", "POST", payload)
                } else {
                    send("/api/v1/playlists/$FAVORITE_PLAYLIST_ID/songs/$songId", "DELETE", null)
                }
                true
            }.getOrDefault(false)
        }

    suspend fun stats(): MusicLibraryStats = withContext(Dispatchers.IO) { statsBlocking() }

    private fun statsBlocking(): MusicLibraryStats {
        val json = get("/api/v1/songs/stats")
        return MusicLibraryStats(
            totalSongs = json.intOf("total_songs", "totalSongs", "total"),
            artistCount = json.intOf("artist_count", "artistCount"),
            albumCount = json.intOf("album_count", "albumCount"),
            totalDuration = json.longOf("total_duration", "totalDuration")
        )
    }

    // ---------------------------------------------------------------- 解析

    private fun parseSongs(json: JSONObject): SongPage {
        val array = json.arrayOf("items", "songs", "data", "list") ?: JSONArray()
        val songs = buildList {
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                runCatching { add(parseSong(obj)) }.getOrNull()
            }
        }
        val total = json.intOf("total", "count").takeIf { it > 0 } ?: songs.size
        return SongPage(songs, total)
    }

    private fun parseSong(obj: JSONObject): MusicSong {
        val durationRaw = obj.optDouble("duration", 0.0)
        // 后端存的是秒；万一某版本给了毫秒，按 >10000 判断并换算
        val seconds = when {
            durationRaw <= 0 -> 0
            durationRaw > 10_000 -> (durationRaw / 1000).toInt()
            else -> durationRaw.toInt()
        }
        val url = absolute(obj.strOf("url", "stream_url", "streamUrl", "src"))
        return MusicSong(
            id = obj.longOf("id"),
            title = obj.strOf("title", "name").ifBlank { "未知曲目" },
            artist = artistOf(obj),
            album = obj.strOf("album", "album_name", "albumName"),
            durationSeconds = seconds,
            streamUrl = url,
            coverUrl = coverOf(obj),
            format = obj.strOf("format", "ext"),
            bitRate = obj.intOf("bit_rate", "bitRate"),
            isVideo = obj.boolOf("is_video", "isVideo")
        )
    }

    /** artist 可能是字符串，也可能是 {name:...} 或 [{artist:{name:...}}] */
    private fun artistOf(obj: JSONObject): String {
        val direct = obj.opt("artist") ?: obj.opt("artists") ?: return ""
        when (direct) {
            is String -> return direct
            is JSONObject -> return direct.optString("name")
            is JSONArray -> {
                val names = buildList {
                    for (i in 0 until direct.length()) {
                        when (val item = direct.opt(i)) {
                            is String -> add(item)
                            is JSONObject -> {
                                val nested = item.optJSONObject("artist") ?: item
                                val name = nested.optString("name")
                                if (name.isNotBlank()) add(name)
                            }
                        }
                    }
                }
                return names.distinct().joinToString(" / ")
            }
        }
        return ""
    }

    private fun coverOf(obj: JSONObject): String {
        val raw = obj.strOf(
            "cover_url", "coverUrl", "cover", "pic", "artwork", "image",
            "cover_path", "coverPath", "album_cover", "albumCover"
        )
        if (raw.isNotBlank()) return withToken(absolute(raw))
        // 少数版本把封面挂在 album 对象里：{album: {cover_url: "/..."}}
        val nested = obj.optJSONObject("album") ?: obj.optJSONObject("cover")
        val inner = nested?.strOf("cover_url", "coverUrl", "cover", "pic", "url", "path").orEmpty()
        return if (inner.isBlank()) "" else withToken(absolute(inner))
    }

    private fun parsePlaylist(obj: JSONObject): MusicPlaylist = MusicPlaylist(
        id = obj.longOf("id"),
        name = obj.strOf("name", "title").ifBlank { "未命名歌单" },
        description = obj.strOf("description", "desc"),
        songCount = obj.intOf("song_count", "songCount", "total", "count"),
        coverUrl = obj.strOf("cover_url", "coverUrl").let { if (it.isBlank()) "" else withToken(absolute(it)) },
        type = obj.strOf("type")
    )

    // ---------------------------------------------------------------- 工具

    private fun absolute(raw: String): String {
        val value = raw.trim()
        if (value.isEmpty()) return ""
        return when {
            value.startsWith("http://") || value.startsWith("https://") -> value
            value.startsWith("/") -> base() + value
            else -> base() + "/" + value
        }
    }

    /** 媒体地址补 access_token（Songloft 自己就这么拼，Coil/MediaPlayer 拿不到请求头也没关系） */
    fun withToken(url: String): String {
        val token = SongloftSession.takeIf { it.matches(bases()) }?.token.orEmpty()
        if (token.isBlank() || url.isBlank()) return url
        if (url.contains("access_token=")) return url
        val sep = if (url.contains("?")) "&" else "?"
        return "$url$sep" + "access_token=" + enc(token)
    }

    /** 真正用于播放的地址：绝对化 + 带 token */
    fun playableUrl(song: MusicSong): String = withToken(song.streamUrl)

    private fun get(path: String): JSONObject = rotating { getOnce(path) }

    private fun getOnce(path: String): JSONObject {
        var response = http.newCall(build(path, ensureToken())).execute()
        // 只允许一次强制重登：如果 token 本身没问题而接口一直 401，
        // 反复强制登录只会把服务端打成限流。
        if (response.code == 401 && !forceReloginUsed) {
            forceReloginUsed = true
            response.close()
            response = http.newCall(build(path, ensureToken(force = true))).execute()
        }
        response.use { res ->
            val body = res.body?.string().orEmpty()
            val json = runCatching { JSONObject(body) }.getOrElse {
                // 少数接口可能直接返回数组，这里兜一下
                if (body.trimStart().startsWith("[")) {
                    JSONObject().put("items", JSONArray(body))
                } else {
                    throw ApiException(
                        if (body.trimStart().startsWith("<"))
                            "返回的是网页而不是数据，检查地址（子路径/端口）"
                        else "Songloft 返回的不是 JSON（HTTP ${res.code}）",
                        res.code
                    )
                }
            }
            if (!res.isSuccessful) {
                val message = json.optString("error").ifBlank { json.optString("detail") }
                throw ApiException(
                    message.ifBlank {
                        if (res.code == 401) "登录已失效，请重新保存一次账号" else "请求失败（HTTP ${res.code}）"
                    },
                    res.code
                )
            }
            return json
        }
    }

    private fun build(path: String, bearer: String): Request = Request.Builder()
        .url(url(path))
        .header("Authorization", "Bearer $bearer")
        .get()
        .build()

    /** POST/DELETE 通用请求（收藏用），401 时重登一次再试 */
    private fun send(path: String, method: String, body: String?): JSONObject {
        fun request(bearer: String): Request {
            val builder = Request.Builder().url(url(path)).header("Authorization", "Bearer $bearer")
            if (method == "POST") builder.post((body ?: "").toRequestBody(JSON)) else builder.delete()
            return builder.build()
        }
        var response = rotating { http.newCall(request(ensureToken())).execute() }
        if (response.code == 401 && !forceReloginUsed) {
            forceReloginUsed = true
            response.close()
            response = rotating { http.newCall(request(ensureToken(force = true))).execute() }
        }
        response.use { res ->
            val text = res.body?.string().orEmpty()
            if (!res.isSuccessful) throw ApiException("收藏操作失败（HTTP ${res.code}）", res.code)
            return runCatching { JSONObject(text) }.getOrElse { JSONObject() }
        }
    }

    private fun url(path: String): String =
        base() + (if (path.startsWith("/")) path else "/$path")

    private fun enc(value: String): String = java.net.URLEncoder.encode(value, "UTF-8")

    data class SongPage(val songs: List<MusicSong>, val total: Int)

    private companion object {
        val JSON = "application/json; charset=utf-8".toMediaType()

        /** 服务端内建「收藏」歌单（labels: built_in），重装恢复后 id 也固定为 1 */
        const val FAVORITE_PLAYLIST_ID = 1L
    }
}

/**
 * 全局登录会话。图片（Coil）和媒体播放请求靠它补 Authorization / access_token，
 * 因为那些请求不经过本类的 OkHttp 实例。
 */
object SongloftSession {
    @Volatile
    var base: String = ""
        private set

    @Volatile
    var token: String = ""
        private set

    @Volatile
    private var expiresAt: Long = 0L

    /** 登录被限流后的冷却截止时间（毫秒时间戳），期间不再尝试登录 */
    @Volatile
    var blockedUntil: Long = 0L
        private set

    /** 上次登录/请求失败的消息，用来在界面上说清原因 */
    @Volatile
    var lastError: String = ""
        private set

    /** 连续被限流的次数，用来做指数退避 */
    @Volatile
    private var blockCount: Int = 0

    /** 剩余冷却秒数，0 = 不在冷却 */
    fun cooldownLeft(): Long {
        val left = blockedUntil - System.currentTimeMillis()
        return if (left <= 0L) 0L else (left / 1000L).coerceAtLeast(1L)
    }

    fun cooldownMessage(): String {
        val left = cooldownLeft()
        return if (left <= 0L) {
            "Songloft 限制登录频率，请稍后再试"
        } else {
            "Songloft 限制登录频率，请等 ${left} 秒后再点「保存」（不是账号密码的问题）"
        }
    }

    /** 绑定到具体服务器：换了账号/地址要重新登录 */
    /**
     * token 是否还能用。
     *
     * 允许传多个候选地址：同一台服务的内网 IP 和公网域名指向同一个后端，
     * 在家登录拿到的 token 出门换成域名访问也应该继续有效，不该被当成「换了服务器」重登
     * （Songloft 登录接口有限流，重登很容易撞上冷却）。
     */
    fun matches(candidateBases: List<String>): Boolean {
        if (token.isBlank()) return false
        if (expiresAt > 0L && System.currentTimeMillis() >= expiresAt - 60_000L) return false
        if (candidateBases.isEmpty()) return true
        return candidateBases.any { base.equals(it.trimEnd('/'), ignoreCase = true) }
    }

    fun update(base: String, token: String, expiresAt: Long) {
        this.base = base.trimEnd('/')
        this.token = token
        this.expiresAt = expiresAt
        this.blockedUntil = 0L
        this.lastError = ""
        this.blockCount = 0
        // 存下来，冷启动就不用再登一次（Songloft 登录接口有频率限制）
        runCatching { TokenVault.saveSongloft(this.base, token, expiresAt) }
    }

    /** 被限流：把下一次自动登录推迟一段时间（连续触发就指数加长） */
    fun markBlocked(seconds: Long?, message: String) {
        blockCount = (blockCount + 1).coerceAtMost(5)
        val backoff = seconds ?: (30L shl (blockCount - 1)).coerceAtMost(600L)
        blockedUntil = System.currentTimeMillis() + backoff * 1000L
        lastError = message.ifBlank { "登录尝试过于频繁" }
    }

    fun reportError(message: String) {
        lastError = message
    }

    /**
     * 进程刚起来时调用：把上次存下的 token 装回去。
     * 只有未过期才恢复，避免拿一个必然 401 的旧 token 去撞接口。
     */
    fun restoreFromVault(): Boolean {
        val cached = runCatching { TokenVault.loadSongloft() }.getOrNull() ?: return false
        val expiry = cached.expiresAt
        if (expiry > 0L && System.currentTimeMillis() >= expiry - 60_000L) return false
        base = cached.base.trimEnd('/')
        token = cached.token
        expiresAt = expiry
        return true
    }

    fun reset() {
        base = ""
        token = ""
        expiresAt = 0L
        blockedUntil = 0L
        lastError = ""
        runCatching { TokenVault.clearSongloft() }
    }

    fun hostPort(): Pair<String, Int>? {
        if (base.isBlank()) return null
        return runCatching {
            val uri = java.net.URI(base)
            val host = uri.host ?: return null
            val port = when {
                uri.port > 0 -> uri.port
                uri.scheme.equals("https", true) -> 443
                else -> 80
            }
            host to port
        }.getOrNull()
    }
}

// ------------------------------------------------------------------ JSON 取值helper
// 服务端字段命名在版本间有过变动（snake_case / camelCase 混用），这里两种都试一遍。

private fun JSONObject.strOf(vararg keys: String): String {
    for (key in keys) {
        if (!has(key) || isNull(key)) continue
        val value = opt(key)
        if (value is String && value.isNotBlank()) return value
    }
    return ""
}

private fun JSONObject.intOf(vararg keys: String): Int {
    for (key in keys) {
        if (!has(key) || isNull(key)) continue
        when (val value = opt(key)) {
            is Number -> return value.toInt()
            is String -> value.trim().toIntOrNull()?.let { return it }
        }
    }
    return 0
}

private fun JSONObject.longOf(vararg keys: String): Long {
    for (key in keys) {
        if (!has(key) || isNull(key)) continue
        when (val value = opt(key)) {
            is Number -> return value.toLong()
            is String -> value.trim().toLongOrNull()?.let { return it }
        }
    }
    return 0L
}

private fun JSONObject.boolOf(vararg keys: String): Boolean {
    for (key in keys) {
        if (!has(key) || isNull(key)) continue
        when (val value = opt(key)) {
            is Boolean -> return value
            is Number -> return value.toInt() != 0
            is String -> if (value.equals("true", true) || value == "1") return true
        }
    }
    return false
}

private fun JSONObject.arrayOf(vararg keys: String): JSONArray? {
    for (key in keys) {
        val array = optJSONArray(key)
        if (array != null) return array
    }
    return null
}
