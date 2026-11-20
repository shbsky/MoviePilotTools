package com.oiiqt.android.data

import android.content.Context
import android.util.Base64
import android.util.Log
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

@Serializable
data class AppSettings(
    val refreshSeconds: Int = 5,
    val rssRefreshMinutes: Int = 30,
    val theme: String = "system",
    val fontScale: Float = 1.0f,
    val dashboardOrder: List<String> = listOf(
        "liveTraffic", "globalAssets", "serverStatus", "storageAudit", "recentFinished"
    ),
    val hiddenModules: List<String> = emptyList(),
    val hideTracker: Boolean = false,
    val moviePilotRefreshMinutes: Int = 30,
    val presetPaths: List<String> = listOf("/PT/Seeding"),
    val showModuleTraffic: Boolean = true,
    val showModuleAssets: Boolean = true,
    val showModuleServers: Boolean = true,
    /** RSS 后台刷新开关（关掉就只在前台检查） */
    val rssBackground: Boolean = true,
    /** RSS 仅在 WiFi 下刷新 */
    val rssWifiOnly: Boolean = false,
    /** RSS 仅在充电时刷新 */
    val rssChargingOnly: Boolean = false,
    /** RSS 自动推送结果通知 */
    val rssNotify: Boolean = true,
    /** MoviePilot 默认下载器名称，空 = 由 MP 自动选择 */
    val mpDefaultDownloader: String = "",
    /** MoviePilot 默认保存路径，空 = 由 MP 自动选择 */
    val mpDefaultSavePath: String = "",
    /** 仪表盘「媒体库」模块（数据取自 MoviePilot 仪表盘） */
    val showModuleMedia: Boolean = true,
    /**
     * Songloft 音乐服务地址，空 = 未接入（音乐页会显示接入引导）。
     * 同样支持多行：内网 IP + 公网域名，自动检测。
     */
    val musicUrl: String = "",
    /** Songloft 登录账号 */
    val musicUser: String = "",
    /** Songloft 登录密码 */
    val musicPass: String = "",
    /**
     * 站点显示白名单（存站点名）。空 = 全部站点。
     * 只影响 App 里「站点」页显示哪些站；想真正减少 MP 的站点压力，
     * 仍需在 MP 后台停用站点（索引器压根不会请求）。
     */
    val mpSiteFilter: List<String> = emptyList()
)

@Serializable
data class PersistedState(
    val servers: List<ServerConfig> = emptyList(),
    /** null 表示聚合查看所有服务器 */
    val activeServerId: String? = null,
    val settings: AppSettings = AppSettings(),
    val rssSources: List<RssSource> = emptyList(),
    val mpServers: List<MpServer> = emptyList(),
    val activeMpServerId: String? = null,
    /** 首屏 Hero 海报轮播缓存（离线/弱网首屏用）；null = 无缓存 */
    val heroCache: HeroCache? = null
)

/**
 * 配置持久化。整个 JSON 用 AndroidKeyStore 里的 AES/GCM 密钥加密后 Base64 存进
 * SharedPreferences —— 密码/API Key 不落明文盘。密钥不可用时降级为明文并记日志。
 */
class ConfigStore(context: Context) {

    private val prefs = context.getSharedPreferences("oiiqt_config", Context.MODE_PRIVATE)
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        prettyPrint = false
    }

    fun load(): PersistedState {
        val raw = prefs.getString(KEY_STATE, null) ?: return PersistedState()
        val plain = runCatching { CryptoBox.decrypt(raw) }.getOrElse {
            Log.w(TAG, "解密失败，尝试按明文读取")
            raw
        }
        return runCatching { json.decodeFromString<PersistedState>(plain) }.getOrElse {
            Log.e(TAG, "配置解析失败，重置为空配置", it)
            PersistedState()
        }
    }

    fun save(state: PersistedState) {
        val plain = json.encodeToString(PersistedState.serializer(), state)
        val stored = runCatching { CryptoBox.encrypt(plain) }.getOrElse {
            Log.w(TAG, "加密不可用，降级明文存储")
            plain
        }
        prefs.edit().putString(KEY_STATE, stored).apply()
    }

    private companion object {
        const val TAG = "ConfigStore"
        const val KEY_STATE = "state_v1"
    }
}

internal object CryptoBox {
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val ALIAS = "oiiqt_config_key"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_LENGTH = 12

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }

        val generator = KeyGenerator.getInstance("AES", ANDROID_KEYSTORE)
        generator.init(
            android.security.keystore.KeyGenParameterSpec.Builder(
                ALIAS,
                android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or
                    android.security.keystore.KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        val encrypted = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        val combined = ByteArray(iv.size + encrypted.size)
        System.arraycopy(iv, 0, combined, 0, iv.size)
        System.arraycopy(encrypted, 0, combined, iv.size, encrypted.size)
        return "enc:" + Base64.encodeToString(combined, Base64.NO_WRAP)
    }

    fun decrypt(stored: String): String {
        if (!stored.startsWith("enc:")) return stored
        val combined = Base64.decode(stored.removePrefix("enc:"), Base64.NO_WRAP)
        val iv = combined.copyOfRange(0, IV_LENGTH)
        val payload = combined.copyOfRange(IV_LENGTH, combined.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(payload), Charsets.UTF_8)
    }
}
