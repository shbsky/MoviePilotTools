package com.moviepilottools.mptools.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * 版本更新检测：走 GitHub Releases 的公开接口，不需要任何 token。
 *
 * 只有用户主动点「应用更新」时才请求一次，不做后台轮询，
 * 也不会上报任何设备信息（GitHub 侧只会看到一次匿名 GET）。
 */
object UpdateChecker {

    const val PROJECT_URL = "https://github.com/shbsky/MoviePilotTools"
    const val RELEASES_URL = "https://github.com/shbsky/MoviePilotTools/releases"
    private const val LATEST_API = "https://api.github.com/repos/shbsky/MoviePilotTools/releases/latest"

    data class Result(
        /** 归一化后的最新版本号，如 1.0.3 */
        val latestVersion: String,
        /** 该 Release 的网页地址，应用内下载不可用时兜底用浏览器打开 */
        val releaseUrl: String,
        /** 最新版本比当前安装的新 */
        val hasUpdate: Boolean,
        /** Release 里 .apk 资产的直链；该版本没传 apk 时为 null */
        val apkUrl: String? = null,
        /** .apk 资产的文件名，用来给本地文件命名 */
        val apkName: String? = null,
        /** .apk 资产大小（字节），未知为 0 */
        val apkSize: Long = 0L
    )

    private val http = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS)
        .build()

    suspend fun check(currentVersion: String): Result = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(LATEST_API)
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "MoviePilotTools-Android")
            .build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw ApiException(
                    when (response.code) {
                        404 -> "仓库还没有发布任何 Release"
                        403 -> "GitHub 限流了，过几分钟再试"
                        else -> "检查更新失败（HTTP ${response.code}）"
                    }
                )
            }
            val obj = JSONObject(response.body?.string().orEmpty())
            val tag = obj.optString("tag_name").ifBlank { obj.optString("name") }
            val latest = normalize(tag)
            val apk = findApkAsset(obj)
            Result(
                latestVersion = latest,
                releaseUrl = obj.optString("html_url").ifBlank { RELEASES_URL },
                hasUpdate = alwaysNewer(latest, normalize(currentVersion)),
                apkUrl = apk?.downloadUrl,
                apkName = apk?.name,
                apkSize = apk?.size ?: 0L
            )
        }
    }

    private data class ApkAsset(val name: String, val downloadUrl: String, val size: Long)

    /**
     * 从 assets 里挑安装包：优先正式的 android apk，跳过 zip / debug 包。
     * 命名约定见 dist/apk：MoviePilotTools-android-v<版本号>.apk
     */
    private fun findApkAsset(release: JSONObject): ApkAsset? {
        val assets = release.optJSONArray("assets") ?: return null
        val candidates = ArrayList<ApkAsset>(assets.length())
        for (index in 0 until assets.length()) {
            val asset = assets.optJSONObject(index) ?: continue
            val name = asset.optString("name")
            val url = asset.optString("browser_download_url")
            if (!name.endsWith(".apk", ignoreCase = true) || url.isBlank()) continue
            candidates += ApkAsset(name, url, asset.optLong("size"))
        }
        if (candidates.isEmpty()) return null
        // debug 包 applicationId 带 .debug，装不上正式版，除非只有它才用
        return candidates.firstOrNull { !it.name.contains("debug", ignoreCase = true) }
            ?: candidates.first()
    }

    /** 去掉 v 前缀、+187 构建号、-beta 后缀，只留 x.y.z */
    fun normalize(version: String): String =
        version.trim()
            .removePrefix("v")
            .removePrefix("V")
            .substringBefore('+')
            .substringBefore('-')
            .trim()

    /** 逐段比大小，缺的段按 0 补（1.0.2 vs 1.0.2.1 也算新版本） */
    fun alwaysNewer(latest: String, current: String): Boolean {
        val left = latest.split('.').map { it.toIntOrNull() ?: 0 }
        val right = current.split('.').map { it.toIntOrNull() ?: 0 }
        for (index in 0 until maxOf(left.size, right.size)) {
            val a = left.getOrElse(index) { 0 }
            val b = right.getOrElse(index) { 0 }
            if (a != b) return a > b
        }
        return false
    }
}
