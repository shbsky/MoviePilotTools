import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import {
  AppEnv, PREF_CRYPTO, KEY_CRYPTO_KEY, logWarn, logInfo
} from '../common/AppConstants';

/**
 * AES-256-GCM 加解密（对应安卓 ConfigStore.kt 里的 CryptoBox）。
 *
 * 密钥 32 字节随机生成，Base64 后明文存 preferences（架构 §5 降级方案：
 * NEXT 无 AndroidKeyStore 等价的硬件密钥库，用户决策接受软件级保管）。
 * 密文格式：`enc:` + Base64(iv[12] + cipherText + authTag[16])。
 */
export class CryptoBox {
  private static keyBytes: Uint8Array | null = null;

  private static b64(): util.Base64Helper {
    return new util.Base64Helper();
  }

  private static randomBytes(len: number): Uint8Array {
    const rand: cryptoFramework.Random = cryptoFramework.createRandom();
    const blob: cryptoFramework.DataBlob = rand.generateRandomSync(len);
    return blob.data;
  }

  private static loadOrCreateKey(): Uint8Array {
    if (CryptoBox.keyBytes !== null) {
      return CryptoBox.keyBytes;
    }
    try {
      const prefs: preferences.Preferences =
        preferences.getPreferencesSync(AppEnv.context(), { name: PREF_CRYPTO });
      const stored: string = prefs.getSync(KEY_CRYPTO_KEY, '') as string;
      if (typeof stored === 'string' && stored.startsWith('k:')) {
        const decoded: Uint8Array = CryptoBox.b64().decodeSync(stored.substring(2));
        if (decoded.length === 32) {
          CryptoBox.keyBytes = decoded;
          return CryptoBox.keyBytes;
        }
      }
      const fresh: Uint8Array = CryptoBox.randomBytes(32);
      prefs.putSync(KEY_CRYPTO_KEY, 'k:' + CryptoBox.b64().encodeToStringSync(fresh));
      prefs.flush();
      CryptoBox.keyBytes = fresh;
      logInfo('CryptoBox', '已生成新的配置加密密钥');
      return CryptoBox.keyBytes;
    } catch (err) {
      logWarn('CryptoBox', `密钥初始化失败，使用进程内临时密钥: ${err}`);
      const temp: Uint8Array = CryptoBox.randomBytes(32);
      CryptoBox.keyBytes = temp;
      return temp;
    }
  }

  private static symKey(): cryptoFramework.SymKey {
    const bytes: Uint8Array = CryptoBox.loadOrCreateKey();
    const gen: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
    return gen.convertKeySync({ data: bytes });
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

  static encrypt(plain: string): string {
    const key: cryptoFramework.SymKey = CryptoBox.symKey();
    const iv: Uint8Array = CryptoBox.randomBytes(12);
    // 加密时 authTag 为 16 字节占位，加密完成后从 doFinal 结果尾部截取
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const placeholder: Uint8Array = new Uint8Array(16);
    cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, CryptoBox.gcmParams(iv, placeholder));
    const encoder: util.TextEncoder = new util.TextEncoder();
    const plainBytes: Uint8Array = encoder.encodeInto(plain);
    const out: cryptoFramework.DataBlob =
      cipher.doFinalSync({ data: plainBytes });
    const all: Uint8Array = out.data;
    const cipherLen: number = all.length - 16;
    const combined: Uint8Array = new Uint8Array(12 + cipherLen + 16);
    combined.set(iv, 0);
    combined.set(all.subarray(0, cipherLen), 12);
    combined.set(all.subarray(cipherLen), 12 + cipherLen);
    return 'enc:' + CryptoBox.b64().encodeToStringSync(combined);
  }

  static decrypt(stored: string): string {
    if (!stored.startsWith('enc:')) {
      return stored;
    }
    const combined: Uint8Array = CryptoBox.b64().decodeSync(stored.substring(4));
    if (combined.length < 12 + 16) {
      throw new Error('密文长度异常');
    }
    const iv: Uint8Array = combined.slice(0, 12);
    const tag: Uint8Array = combined.slice(combined.length - 16);
    const payload: Uint8Array = combined.slice(12, combined.length - 16);
    const key: cryptoFramework.SymKey = CryptoBox.symKey();
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, key, CryptoBox.gcmParams(iv, tag));
    const out: cryptoFramework.DataBlob =
      cipher.doFinalSync({ data: payload });
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeWithStream(out.data);
  }
}
