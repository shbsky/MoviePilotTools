package com.oiiqt.android.net

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/**
 * 站点图标缓存。
 *
 * MP 的 `site/icon/{id}` 一次只给一个站点的图标，返回的是 **http 地址** 或 **base64**。
 *
 * base64 那种**不能直接拼 `data:` URI 丢给图片库**：MP 库里的 base64 带换行、
 * 也可能没有 mime 头，Coil 解析 data URI 会直接失败（实测几十个站点只有 URL 型那个能显示）。
 * 所以这里自己解码成 Bitmap，顺便按 128px 取样 —— 图标在界面上只有 30~38dp，
 * 原图动辄几百 KB，不解码压缩的话几十个站点能把内存吃掉一大截。
 *
 * 另外两件事：
 * - **并发上限**：请求统一走 [limited]，避免一次几十个 HTTPS 同时起飞；
 * - **只对「确实没有图标」记黑名单**：MP 返回 `success:false` 才算没有；
 *   网络抖动/超时不算，下次滚动还能重试。
 */
object SiteIconStore {

    /** 图标最多缓 128 个，单个已压到 128px，占用可控 */
    private const val MAX_ENTRIES = 128

    /** 解码目标边长：38dp @3x = 114px，留点余量给详情页和不同密度 */
    private const val TARGET_PX = 128

    private val lock = Any()

    /** 值有两种：远程地址（String）或已解码的本地图标（Bitmap） */
    private val cache = object : LinkedHashMap<Int, Any>(32, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Int, Any>?): Boolean =
            size > MAX_ENTRIES
    }

    /** MP 明确答复「没有图标」的站点，本次运行不再请求 */
    private val missing = HashSet<Int>()

    private val semaphore = Semaphore(4)

    /** 已在缓存里就直接给，Composable 第一次组合时用它避免闪一下首字色块 */
    fun cached(siteId: Int): Any? = synchronized(lock) { cache[siteId] }

    /** MP 已经明确说这个站没有图标了 */
    fun isMissing(siteId: Int): Boolean = synchronized(lock) { siteId in missing }

    /** 限流执行一个请求（permit 在调用方协程里排队，不会被 UI 取消弄丢） */
    suspend fun <T> limited(block: suspend () -> T): T = semaphore.withPermit { block() }

    /**
     * 把 MP 给的原始内容收进缓存。
     *
     * **会做 base64 解码，必须在后台线程调用**（调用方是 VM 的 IO 协程）。
     *
     * @param raw `site/icon` 返回的原文（http 地址或 base64），空表示这个站没有图标
     * @return 可直接交给 Coil 的 model（String 或 Bitmap）；解不出图时 null
     */
    fun remember(siteId: Int, raw: String?): Any? {
        if (raw.isNullOrBlank()) {
            synchronized(lock) { missing += siteId }
            return null
        }
        val model = toImageModel(raw)
        synchronized(lock) {
            if (model == null) {
                missing += siteId
            } else {
                cache[siteId] = model
                missing -= siteId
            }
        }
        return model
    }

    /** 退出登录 / 换服务器时清干净，避免把 A 站的图标画到 B 站头上 */
    fun clear() {
        synchronized(lock) {
            cache.clear()
            missing.clear()
        }
    }

    /**
     * http(s) 地址原样交给图片库；base64 自己解码。
     * 解不出来就返回 null（UI 降级成首字色块，不留白块）。
     */
    internal fun toImageModel(raw: String): Any? {
        val text = raw.trim()
        if (text.isEmpty()) return null
        if (text.startsWith("http://", true) || text.startsWith("https://", true)) return text
        return decodeBitmap(text)
    }

    private fun decodeBitmap(text: String): Bitmap? {
        // MP 里存的可能是完整 data URI，也可能只是裸 base64；换行/空格一律去掉
        val payload = if (text.startsWith("data:", true)) text.substringAfter(',', "") else text
        val cleaned = payload.filterNot { it.isWhitespace() }
        if (cleaned.isEmpty()) return null

        val bytes = runCatching {
            Base64.decode(cleaned, Base64.DEFAULT or Base64.NO_WRAP)
        }.getOrNull() ?: return null
        if (bytes.size < 64) return null

        return runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

            val options = BitmapFactory.Options().apply {
                inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, TARGET_PX)
            }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        }.getOrNull()
    }

    private fun sampleSize(width: Int, height: Int, target: Int): Int {
        var sample = 1
        var w = width
        var h = height
        while (w / 2 >= target && h / 2 >= target) {
            w /= 2
            h /= 2
            sample *= 2
        }
        return sample
    }

    /** 调试用：把 model 说成人话，日志里好认 */
    fun describe(model: Any?): String = when (model) {
        null -> "无"
        is Bitmap -> "本地图标 ${model.width}x${model.height}"
        is String -> if (model.length > 40) "URL ${model.take(40)}…" else "URL $model"
        else -> model.toString()
    }
}
