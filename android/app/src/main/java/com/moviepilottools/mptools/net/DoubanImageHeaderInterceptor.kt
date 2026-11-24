package com.moviepilottools.mptools.net

import okhttp3.Interceptor
import okhttp3.Response

/**
 * 给豆瓣图床（*.doubanio.com）补齐防盗链所需的请求头。
 *
 * 实测（2026-11）：
 *  - 不带 Referer：HTTP 418，响应体 0 字节
 *  - 带 `Referer: https://movie.douban.com/`：HTTP 200，正常返回图片
 */
class DoubanImageHeaderInterceptor : Interceptor {

    private val userAgent =
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/124.0.0.0 Mobile Safari/537.36"

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (!request.url.host.lowercase().contains("doubanio.com")) {
            return chain.proceed(request)
        }

        val patched = request.newBuilder()
            .header("Referer", PosterUrl.DOUBAN_REFERER)
            .header("User-Agent", userAgent)
            // 不放 avif：低版本 Android 解码不了，webp 已经够用
            .header("Accept", "image/webp,image/apng,image/*,*/*;q=0.8")
            .build()

        return chain.proceed(patched)
    }
}
