package com.moviepilottools.mptools.data

import android.util.Base64
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * 本地备份文件格式（安卓 / 鸿蒙共用，可互相恢复）：
 *
 * ```
 * MPTBACKUP1
 * <BASE64 payload>
 * ```
 *
 * payload 两种：
 * - 密码为空：`BASE64(UTF-8(JSON))`，明文，文件里能直接看到配置（含密码/密钥）。
 * - 密码非空：`BASE64(salt[16] + iv[12] + AES-GCM(ciphertext+tag))`，
 *   密钥 = PBKDF2-HMAC-SHA256(password, salt, 120000, 256bit)。
 *
 * 与设备无关：不依赖 AndroidKeyStore / 鸿蒙软件密钥，卸载重装、换机、跨端都能恢复。
 */
object BackupManager {

    private const val HEADER = "MPTBACKUP1"
    private const val ITERATIONS = 120_000
    private const val KEY_BITS = 256
    private const val SALT_LEN = 16
    private const val IV_LEN = 12
    private const val TAG_LEN = 16
    private val random = SecureRandom()

    /** 备份文件后缀，导出和文件选择器都用这个 */
    const val FILE_EXTENSION = "mptbak"

    class BackupException(message: String) : Exception(message)

    /** 把配置 JSON 包装成备份文件内容。password 为空 = 明文（调用方需提示风险）。 */
    fun wrap(plainJson: String, password: String): String {
        val payload: ByteArray = if (password.isEmpty()) {
            plainJson.toByteArray(Charsets.UTF_8)
        } else {
            val salt = ByteArray(SALT_LEN).also { random.nextBytes(it) }
            val iv = ByteArray(IV_LEN).also { random.nextBytes(it) }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.ENCRYPT_MODE,
                deriveKey(password, salt),
                GCMParameterSpec(TAG_LEN * 8, iv)
            )
            val encrypted = cipher.doFinal(plainJson.toByteArray(Charsets.UTF_8))
            val combined = ByteArray(salt.size + iv.size + encrypted.size)
            System.arraycopy(salt, 0, combined, 0, salt.size)
            System.arraycopy(iv, 0, combined, salt.size, iv.size)
            System.arraycopy(encrypted, 0, combined, salt.size + iv.size, encrypted.size)
            combined
        }
        return HEADER + "\n" + Base64.encodeToString(payload, Base64.NO_WRAP) + "\n"
    }

    /** 从备份文件内容还原配置 JSON。密码错误/文件损坏会抛 BackupException。 */
    fun unwrap(text: String, password: String): String {
        // 按行分割并丢掉空行：CRM/Unix 换行混用、文件带 BOM 都能读。
        // 原来 split('\n', '\r') 会把 CRLF 拆出空行，lines[1] 变成空串 → 恢复必失败。
        val lines = text.removePrefix("\uFEFF").trim()
            .lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.toList()
        if (lines.isEmpty() || lines[0] != HEADER) {
            throw BackupException("不是 MoviePilotTools 备份文件")
        }
        val payload = lines.getOrNull(1)
            ?: throw BackupException("备份文件缺少数据段")
        val bytes = try {
            Base64.decode(payload, Base64.NO_WRAP)
        } catch (e: IllegalArgumentException) {
            throw BackupException("备份文件编码损坏")
        }

        // 明文：payload 直接是 UTF-8 JSON
        if (isPlainJson(bytes)) {
            return String(bytes, Charsets.UTF_8)
        }

        // 密文：salt + iv + ciphertext+tag
        if (password.isEmpty()) {
            throw BackupException("这份备份已加密，请输入密码")
        }
        if (bytes.size < SALT_LEN + IV_LEN + TAG_LEN) {
            throw BackupException("备份文件数据不完整")
        }
        val salt = bytes.copyOfRange(0, SALT_LEN)
        val iv = bytes.copyOfRange(SALT_LEN, SALT_LEN + IV_LEN)
        val encrypted = bytes.copyOfRange(SALT_LEN + IV_LEN, bytes.size)
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                deriveKey(password, salt),
                GCMParameterSpec(TAG_LEN * 8, iv)
            )
            String(cipher.doFinal(encrypted), Charsets.UTF_8)
        } catch (e: Exception) {
            throw BackupException("解密失败：密码错误或文件损坏")
        }
    }

    /** 明文 payload 以 `{` 开头；密文第一字节是随机 salt，几乎不可能是 `{`。 */
    private fun isPlainJson(bytes: ByteArray): Boolean =
        bytes.isNotEmpty() && bytes[0] == '{'.code.toByte()

    private fun deriveKey(password: String, salt: ByteArray): SecretKeySpec {
        val spec = PBEKeySpec(
            password.toCharArray(), salt, ITERATIONS, KEY_BITS
        )
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSha256")
        return SecretKeySpec(factory.generateSecret(spec).encoded, "AES")
    }
}
