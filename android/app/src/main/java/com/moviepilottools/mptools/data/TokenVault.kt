package com.moviepilottools.mptools.data

import android.content.Context
import android.content.SharedPreferences
import android.util.Log

/**
 * 令牌保管箱：把 Songloft 的 access_token 加密存本机。
 *
 * 为什么要持久化：Songloft 服务端对登录接口有频率限制（连续登录几次就返回
 * 「登录尝试过于频繁，请稍后再试」）。之前每次冷启动都要重新登录，调试期反复重启
 * 很容易被限流 —— 存下 token 后，只要没到期就直接复用。
 */
object TokenVault {

    private const val PREFS = "mpt_tokens"
    private const val KEY_SONGLOFT = "songloft_session"
    private const val SEP = "\u0001"

    @Volatile
    private var prefs: SharedPreferences? = null

    fun attach(context: Context) {
        if (prefs == null) {
            prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        }
    }

    data class Cached(val base: String, val token: String, val expiresAt: Long)

    fun saveSongloft(base: String, token: String, expiresAt: Long) {
        val store = prefs ?: return
        val plain = listOf(base, token, expiresAt.toString()).joinToString(SEP)
        val stored = runCatching { CryptoBox.encrypt(plain) }.getOrElse {
            Log.w("TokenVault", "加密不可用，跳过令牌持久化")
            return
        }
        store.edit().putString(KEY_SONGLOFT, stored).apply()
    }

    fun loadSongloft(): Cached? {
        val store = prefs ?: return null
        val raw = store.getString(KEY_SONGLOFT, null) ?: return null
        val plain = runCatching { CryptoBox.decrypt(raw) }.getOrElse { raw }
        val parts = plain.split(SEP)
        if (parts.size != 3) return null
        val expiresAt = parts[2].toLongOrNull() ?: 0L
        if (parts[0].isBlank() || parts[1].isBlank()) return null
        return Cached(parts[0], parts[1], expiresAt)
    }

    fun clearSongloft() {
        prefs?.edit()?.remove(KEY_SONGLOFT)?.apply()
    }
}
