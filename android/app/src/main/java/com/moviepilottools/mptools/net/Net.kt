package com.moviepilottools.mptools.net

import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** 内存 CookieJar：qBittorrent 登录后的 SID 需要跨请求保持 */
internal class MemoryCookieJar : CookieJar {
    private val store = ConcurrentHashMap<String, MutableList<Cookie>>()

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        if (cookies.isEmpty()) return
        val bucket = store.getOrPut(url.host) { mutableListOf() }
        synchronized(bucket) {
            cookies.forEach { cookie ->
                bucket.removeAll { it.name == cookie.name && it.path == cookie.path }
                bucket.add(cookie)
            }
        }
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val bucket = store[url.host] ?: return emptyList()
        val now = System.currentTimeMillis()
        synchronized(bucket) {
            bucket.removeAll { it.expiresAt < now }
            return bucket.filter { it.matches(url) }
        }
    }

    fun clear() = store.clear()
}

object Net {
    private val cookieJar = MemoryCookieJar()

    @Volatile
    private var configured: OkHttpClient? = null

    val client: OkHttpClient
        get() = configured ?: synchronized(this) {
            configured ?: OkHttpClient.Builder()
                .cookieJar(cookieJar)
                .addInterceptor(SongloftAuthInterceptor())
                .connectTimeout(6, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .writeTimeout(30, TimeUnit.SECONDS)
                .callTimeout(45, TimeUnit.SECONDS)
                .retryOnConnectionFailure(true)
                .followRedirects(true)
                .build()
                .also { configured = it }
        }

    /** MoviePilot 资源搜索是同步阻塞的，单独一个长超时客户端 */
    val slowClient: OkHttpClient by lazy {
        client.newBuilder()
            .readTimeout(130, TimeUnit.SECONDS)
            .callTimeout(180, TimeUnit.SECONDS)
            .build()
    }

    val probeClient: OkHttpClient by lazy {
        client.newBuilder()
            .connectTimeout(2500, TimeUnit.MILLISECONDS)
            .readTimeout(2500, TimeUnit.MILLISECONDS)
            .callTimeout(3000, TimeUnit.MILLISECONDS)
            .build()
    }

    /**
     * 海报识别用：8 秒还没回来就当失败。
     *
     * 站点列表一屏几十条，每条都要问一次 MP「这个标题是哪部片」；MP 内部要查 TMDB/豆瓣，
     * 慢的时候 10 秒以上。列表不能等它 —— 超时直接落渐变占位，用户翻页不受影响。
     */
    val posterClient: OkHttpClient by lazy {
        client.newBuilder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(8, TimeUnit.SECONDS)
            .callTimeout(9, TimeUnit.SECONDS)
            .build()
    }

    val JSON = "application/json; charset=utf-8".toMediaType()
    val FORM = "application/x-www-form-urlencoded; charset=utf-8".toMediaType()

    fun get(url: String, headers: Map<String, String> = emptyMap(), slow: Boolean = false): Response {
        val builder = Request.Builder().url(url).get()
        headers.forEach { (k, v) -> builder.header(k, v) }
        return (if (slow) slowClient else client).newCall(builder.build()).execute()
    }

    fun post(
        url: String,
        body: RequestBody,
        headers: Map<String, String> = emptyMap(),
        slow: Boolean = false
    ): Response {
        val builder = Request.Builder().url(url).post(body)
        headers.forEach { (k, v) -> builder.header(k, v) }
        return (if (slow) slowClient else client).newCall(builder.build()).execute()
    }

    fun postForm(url: String, form: Map<String, String>, headers: Map<String, String> = emptyMap()): Response {
        val encoded = form.entries.joinToString("&") { (k, v) ->
            "${java.net.URLEncoder.encode(k, "UTF-8")}=${java.net.URLEncoder.encode(v, "UTF-8")}"
        }
        return post(url, encoded.toRequestBody(FORM), headers)
    }
}

class ApiException(message: String, val code: Int? = null) : Exception(message)
