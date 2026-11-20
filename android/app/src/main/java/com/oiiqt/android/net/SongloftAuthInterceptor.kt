package com.oiiqt.android.net

import okhttp3.Interceptor
import okhttp3.Response

/**
 * 给 Songloft 媒体/封面请求补 `Authorization: Bearer <token>`。
 *
 * 图片走 Coil 自己的 OkHttpClient、音频走 MediaPlayer，都不经过 SongloftClient 的实例，
 * 这里按「host + port 一致」判定，只对当前配置的那台 Songloft 生效，不影响其它请求。
 */
class SongloftAuthInterceptor : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (request.header("Authorization") != null) return chain.proceed(request)

        val token = SongloftSession.token
        if (token.isBlank()) return chain.proceed(request)

        val hostPort = SongloftSession.hostPort() ?: return chain.proceed(request)
        val sameHost = request.url.host.equals(hostPort.first, ignoreCase = true) &&
            request.url.port == hostPort.second
        if (!sameHost) return chain.proceed(request)

        return chain.proceed(
            request.newBuilder().header("Authorization", "Bearer $token").build()
        )
    }
}
