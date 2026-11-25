import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

/**
 * 本地备份文件格式（与安卓 BackupManager.kt 完全一致，可互相恢复）：
 *
 * ```
 * MPTBACKUP1
 * <BASE64 payload>
 * ```
 *
 * payload 两种：
 * - 密码为空：`BASE64(UTF-8(JSON))`，明文。
 * - 密码非空：`BASE64(salt[16] + iv[12] + AES-GCM(ciphertext+tag))`，
 *   密钥 = PBKDF2-HMAC-SHA256(password, salt, 120000, 32byte)。
 */
export class BackupManager {
  private static readonly HEADER: string = 'MPTBACKUP1';
  private static readonly ITERATIONS: number = 120000;
  private static readonly KEY_LEN: number = 32;
  private static readonly SALT_LEN: number = 16;
  private static readonly IV_LEN: number = 12;
  private static readonly TAG_LEN: number = 16;
  static readonly FILE_EXTENSION: string = 'mptbak';

  private static b64(): util.Base64Helper {
    return new util.Base64Helper();
  }

  private static randomBytes(len: number): Uint8Array {
    const rand: cryptoFramework.Random = cryptoFramework.createRandom();
    return rand.generateRandomSync(len).data;
  }

  private static deriveKey(password: string, salt: Uint8Array): cryptoFramework.SymKey {
    const kdf: cryptoFramework.Kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
    const spec: cryptoFramework.PBKDF2Spec = {
      password: password,
      salt: salt,
      iterations: BackupManager.ITERATIONS,
      keySize: BackupManager.KEY_LEN,
      algName: 'PBKDF2|SHA256'
    };
    const keyBytes: Uint8Array = kdf.generateSecretSync(spec).data;
    const gen: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
    return gen.convertKeySync({ data: keyBytes });
  }

  private static gcmParams(iv: Uint8Array, tag: Uint8Array): cryptoFramework.GcmParamsSpec {
    const spec: cryptoFramework.GcmParamsSpec = {
      iv: { data: iv },
      aad: { data: new Uint8Array(0) },
      authTag: { data: tag },
      algName: 'GcmParamsSpec'
    };
    return spec;
  }

  /** 把配置 JSON 包装成备份文件内容。password 为空 = 明文。 */
  static wrap(plainJson: string, password: string): string {
    let payload: Uint8Array;
    if (password.length === 0) {
      payload = new util.TextEncoder().encodeInto(plainJson);
    } else {
      const salt: Uint8Array = BackupManager.randomBytes(BackupManager.SALT_LEN);
      const iv: Uint8Array = BackupManager.randomBytes(BackupManager.IV_LEN);
      const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
      const placeholder: Uint8Array = new Uint8Array(BackupManager.TAG_LEN);
      cipher.initSync(
        cryptoFramework.CryptoMode.ENCRYPT_MODE,
        BackupManager.deriveKey(password, salt),
        BackupManager.gcmParams(iv, placeholder)
      );
      const plainBytes: Uint8Array = new util.TextEncoder().encodeInto(plainJson);
      const out: cryptoFramework.DataBlob = cipher.doFinalSync({ data: plainBytes });
      const cipherLen: number = out.data.length - BackupManager.TAG_LEN;
      payload = new Uint8Array(salt.length + iv.length + out.data.length);
      payload.set(salt, 0);
      payload.set(iv, salt.length);
      payload.set(out.data.subarray(0, cipherLen), salt.length + iv.length);
      payload.set(out.data.subarray(cipherLen), salt.length + iv.length + cipherLen);
    }
    return BackupManager.HEADER + '\n' + BackupManager.b64().encodeToStringSync(payload) + '\n';
  }

  /** 从备份文件内容还原配置 JSON。密码错误/文件损坏会抛 Error。 */
  static unwrap(text: string, password: string): string {
    const lines: string[] = text.trim().split('\n');
    if (lines.length === 0 || lines[0].trim() !== BackupManager.HEADER) {
      throw new Error('不是 MoviePilotTools 备份文件');
    }
    const payload: string = lines.length > 1 ? lines[1].trim() : '';
    if (payload.length === 0) {
      throw new Error('备份文件缺少数据段');
    }
    let bytes: Uint8Array;
    try {
      bytes = BackupManager.b64().decodeSync(payload);
    } catch (err) {
      throw new Error('备份文件编码损坏');
    }

    // 明文：payload 第一个字节是 '{'
    if (bytes.length > 0 && bytes[0] === '{'.charCodeAt(0)) {
      return BackupManager.decodeUtf8(bytes);
    }

    if (password.length === 0) {
      throw new Error('这份备份已加密，请输入密码');
    }
    const min: number = BackupManager.SALT_LEN + BackupManager.IV_LEN + BackupManager.TAG_LEN;
    if (bytes.length < min) {
      throw new Error('备份文件数据不完整');
    }
    const salt: Uint8Array = bytes.slice(0, BackupManager.SALT_LEN);
    const iv: Uint8Array = bytes.slice(BackupManager.SALT_LEN, BackupManager.SALT_LEN + BackupManager.IV_LEN);
    // 密文尾部是 GCM tag：必须切出来当 authTag 传，data 只给纯密文。
    // 原来把 tag 留在 data 里、authTag 传全零 → 加密备份在鸿蒙端永远解不开。
    const tag: Uint8Array = bytes.slice(bytes.length - BackupManager.TAG_LEN);
    const encrypted: Uint8Array = bytes.slice(
      BackupManager.SALT_LEN + BackupManager.IV_LEN, bytes.length - BackupManager.TAG_LEN
    );
    try {
      const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
      cipher.initSync(
        cryptoFramework.CryptoMode.DECRYPT_MODE,
        BackupManager.deriveKey(password, salt),
        BackupManager.gcmParams(iv, tag)
      );
      const out: cryptoFramework.DataBlob = cipher.doFinalSync({ data: encrypted });
      return BackupManager.decodeUtf8(out.data);
    } catch (err) {
      throw new Error('解密失败：密码错误或文件损坏');
    }
  }

  private static decodeUtf8(bytes: Uint8Array): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeWithStream(bytes);
  }
}
