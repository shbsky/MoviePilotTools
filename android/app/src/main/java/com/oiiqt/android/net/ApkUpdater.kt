package com.oiiqt.android.net

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import androidx.core.content.FileProvider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * 应用内更新：把 GitHub Release 里的 .apk 直接下到应用私有目录，再交给系统安装器。
 *
 * 全程不打开浏览器、不申请存储权限（落在 getExternalFilesDir 或 filesDir 下，
 * 通过 FileProvider 授权给安装器读）。安装仍由系统弹窗确认，这是 Android 的硬性要求——
 * 应用不能静默安装自己的新版本，必须用户点一次「安装」。
 */
object ApkUpdater {

    /** 单次下载最长等待，超过就换源 */
    private val DOWNLOAD_TIMEOUT_SECONDS = 25L

    /**
     * 国内直连 objects.githubusercontent.com 经常几十 KB/s 甚至直接断，
     * 直连失败时按顺序换镜像重试（镜像只是前缀拼接，不改 URL 其余部分）。
     */
    private val MIRRORS = listOf(
        "",
        "https://ghfast.top/",
        "https://gh-proxy.com/"
    )

    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(DOWNLOAD_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .build()

    data class Progress(val downloaded: Long, val total: Long) {
        /** 0f..1f；总长度未知时返回 -1f，UI 用不确定进度条 */
        val fraction: Float
            get() = if (total > 0) (downloaded.toFloat() / total).coerceIn(0f, 1f) else -1f
    }

    /** 下载目录：优先外部私有目录（不占内部空间），没有外部存储就退回内部私有目录 */
    fun downloadDir(context: Context): File {
        val base = context.getExternalFilesDir(null) ?: context.filesDir
        return File(base, "update").apply { mkdirs() }
    }

    /** 清掉上次下载的残包，避免 .part / 旧 apk 堆积 */
    fun cleanup(context: Context) {
        runCatching {
            downloadDir(context).listFiles()?.forEach { it.delete() }
        }
    }

    /**
     * 下载 apk 到私有目录并校验。返回可直接安装的 File。
     * [onProgress] 在网络线程回调，UI 侧自己切主线程。
     */
    suspend fun download(
        context: Context,
        url: String,
        fileName: String,
        onProgress: (Progress) -> Unit
    ): File = withContext(Dispatchers.IO) {
        val dest = File(downloadDir(context), fileName.ifBlank { "update.apk" })
        var lastError: Throwable? = null

        for (mirror in MIRRORS) {
            // 镜像只对 GitHub 域名有意义，其它源（自建 OSS 等）直接原样请求
            if (mirror.isNotEmpty() && !url.startsWith("https://github.com/")) break
            try {
                fetch(mirror + url, dest, onProgress)
                verify(context, dest)
                return@withContext dest
            } catch (c: CancellationException) {
                dest.delete()
                throw c
            } catch (t: Throwable) {
                dest.delete()
                File(dest.parentFile, dest.name + ".part").delete()
                lastError = t
            }
        }
        throw IOException(lastError?.message ?: "下载失败，请稍后重试")
    }

    private fun fetch(url: String, dest: File, onProgress: (Progress) -> Unit) {
        val request = Request.Builder()
            .url(url)
            .header("User-Agent", "MoviePilotTools-Android")
            .header("Accept", "application/octet-stream")
            .build()

        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("下载失败（HTTP ${response.code}）")
            val body = response.body ?: throw IOException("服务器没有返回内容")
            val total = body.contentLength().takeIf { it > 0 }
                ?: response.header("Content-Length")?.toLongOrNull()
                ?: -1L

            val part = File(dest.parentFile, dest.name + ".part")
            var downloaded = 0L
            var lastEmit = 0L

            body.byteStream().use { input ->
                FileOutputStream(part).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        downloaded += read
                        val now = SystemClock.elapsedRealtime()
                        // 限流回调，避免每个 64K 都触发一次重组
                        if (now - lastEmit >= 120) {
                            lastEmit = now
                            onProgress(Progress(downloaded, total))
                        }
                    }
                    output.flush()
                }
            }
            onProgress(Progress(downloaded, if (total > 0) total else downloaded))

            if (total > 0 && downloaded != total) {
                part.delete()
                throw IOException("下载不完整（$downloaded/$total 字节）")
            }
            if (dest.exists()) dest.delete()
            if (!part.renameTo(dest)) {
                part.copyTo(dest, overwrite = true)
                part.delete()
            }
        }
    }

    /** 校验拿到的是不是能装的 apk：解析不出包信息说明镜像吐了错误页/被截断 */
    private fun verify(context: Context, file: File) {
        if (!file.exists() || file.length() < 1024 * 512) {
            throw IOException("下载到的文件不完整")
        }
        val info = context.packageManager.getPackageArchiveInfo(file.absolutePath, 0)
            ?: throw IOException("下载到的文件不是有效的安装包")
        if (info.packageName != context.packageName) {
            throw IOException("安装包包名不匹配（${info.packageName}），请到 GitHub 手动下载")
        }
    }

    /** Android 8 起装未知来源应用要单独开关，各 ROM 都有，只是默认关 */
    fun canInstallPackages(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || context.packageManager.canRequestPackageInstalls()

    /** 跳到「允许安装未知应用」开关；个别 ROM 没这页面就退到应用详情 */
    fun openInstallPermission(context: Context) {
        val packageUri = Uri.parse("package:${context.packageName}")
        runCatching {
            context.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, packageUri)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }.onFailure {
            runCatching {
                context.startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }
        }
    }

    /** 交给系统安装器；FileProvider 授权一次性读权限，不需要存储权限 */
    fun install(context: Context, file: File): Boolean = runCatching {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(intent)
    }.isSuccess
}
