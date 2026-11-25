import { preferences } from '@kit.ArkData';
import { AppEnv, PREF_TOKENS, KEY_SONGLOFT, logWarn } from '../common/AppConstants';
import { CryptoBox } from './CryptoBox';

/**
 * 令牌保管箱（对应安卓 data/TokenVault.kt）：把 Songloft 的 access_token 加密存本机。
 *
 * 为什么要持久化：Songloft 服务端对登录接口有频率限制（连续登录几次就返回
 * 「登录尝试过于频繁，请稍后再试」）。存下 token 后，只要没到期就直接复用。
 */
export class TokenVault {
  private static prefs: preferences.Preferences | null = null;
  private static SEP: string = '\u0001';

  private static ensurePrefs(): preferences.Preferences | null {
    if (!AppEnv.hasContext()) {
      return null;
    }
    if (TokenVault.prefs === null) {
      TokenVault.prefs = preferences.getPreferencesSync(AppEnv.context(), { name: PREF_TOKENS });
    }
    return TokenVault.prefs;
  }

  static saveSongloft(base: string, token: string, expiresAt: number): void {
    const store: preferences.Preferences | null = TokenVault.ensurePrefs();
    if (store === null) {
      return;
    }
    try {
      const plain: string = [base, token, String(expiresAt)].join(TokenVault.SEP);
      store.putSync(KEY_SONGLOFT, CryptoBox.encrypt(plain));
      store.flushSync();
    } catch (err) {
      logWarn('TokenVault', '加密不可用，跳过令牌持久化');
    }
  }

  static loadSongloft(): TokenCached | null {
    const store: preferences.Preferences | null = TokenVault.ensurePrefs();
    if (store === null) {
      return null;
    }
    const raw: string = store.getSync(KEY_SONGLOFT, '') as string;
    if (typeof raw !== 'string' || raw.length === 0) {
      return null;
    }
    let plain: string = raw;
    try {
      plain = CryptoBox.decrypt(raw);
    } catch (err) {
      plain = raw;
    }
    const parts: string[] = plain.split(TokenVault.SEP);
    if (parts.length !== 3) {
      return null;
    }
    const expiresAt: number = parseInt(parts[2], 10);
    if (parts[0].trim().length === 0 || parts[1].trim().length === 0) {
      return null;
    }
    return new TokenCached(parts[0], parts[1], isNaN(expiresAt) ? 0 : expiresAt);
  }

  static clearSongloft(): void {
    const store: preferences.Preferences | null = TokenVault.ensurePrefs();
    if (store === null) {
      return;
    }
    store.deleteSync(KEY_SONGLOFT);
    store.flushSync();
  }
}

export class TokenCached {
  readonly base: string;
  readonly token: string;
  readonly expiresAt: number;

  constructor(base: string, token: string, expiresAt: number) {
    this.base = base;
    this.token = token;
    this.expiresAt = expiresAt;
  }
}
