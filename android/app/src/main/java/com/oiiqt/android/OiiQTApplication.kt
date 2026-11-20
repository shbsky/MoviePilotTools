package com.oiiqt.android

import android.app.Application
import coil.ImageLoader
import coil.ImageLoaderFactory
import com.oiiqt.android.data.TokenVault
import com.oiiqt.android.net.DoubanImageHeaderInterceptor
import com.oiiqt.android.net.Net
import com.oiiqt.android.net.SongloftSession
import java.util.concurrent.TimeUnit

/**
 * 全局 Coil 图片加载器。
 *
 * 豆瓣图床对没有 `Referer: https://movie.douban.com/` 的请求直接返回 **HTTP 418**（0 字节），
 * iOS 版在 CachedAsyncImage 里补了这个头，安卓这边漏掉了 —— 这是 MoviePilot 海报全空的直接原因。
 * 这里统一插一个拦截器，所有 AsyncImage 都会带上正确的请求头。
 *
 * Coil 2.x 会自动发现实现了 ImageLoaderFactory 的 Application，无需手动 setImageLoader。
 */
class OiiQTApplication : Application(), ImageLoaderFactory {

    override fun onCreate() {
        super.onCreate()
        // 令牌保管箱要 Context；顺手把上次存的 Songloft token 装回去，
        // 这样冷启动不用再登一次（它的登录接口有频率限制）。
        TokenVault.attach(this)
        runCatching { SongloftSession.restoreFromVault() }
    }

    override fun newImageLoader(): ImageLoader = ImageLoader.Builder(this)
        .okHttpClient {
            Net.client.newBuilder()
                .addInterceptor(DoubanImageHeaderInterceptor())
                .callTimeout(25, TimeUnit.SECONDS)
                .build()
        }
        .build()
}
