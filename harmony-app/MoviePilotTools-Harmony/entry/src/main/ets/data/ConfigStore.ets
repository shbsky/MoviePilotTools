import { preferences } from '@kit.ArkData';
import {
  AppEnv, PREF_CONFIG, KEY_STATE, logWarn, logError, parseJsonObject
} from '../common/AppConstants';
import { CryptoBox } from './CryptoBox';
import { PersistedState, persistedStateFromJson } from '../model/Settings';

/**
 * 配置持久化（对应安卓 data/ConfigStore.kt）。
 * 整个 PersistedState JSON 用 AES-256-GCM 加密后 Base64 存进 preferences（key=state_v1）
 * —— 密码/API Key 不落明文盘。密钥不可用时降级为明文并记日志。
 */
export class ConfigStore {
  private static inst: ConfigStore | null = null;

  static getInstance(): ConfigStore {
    if (ConfigStore.inst === null) {
      ConfigStore.inst = new ConfigStore();
    }
    return ConfigStore.inst;
  }

  private prefs: preferences.Preferences | null = null;

  private ensurePrefs(): preferences.Preferences {
    if (this.prefs === null) {
      this.prefs = preferences.getPreferencesSync(AppEnv.context(), { name: PREF_CONFIG });
    }
    return this.prefs;
  }

  load(): PersistedState {
    const raw: string = this.ensurePrefs().getSync(KEY_STATE, '') as string;
    if (typeof raw !== 'string' || raw.length === 0) {
      return new PersistedState();
    }
    let plain: string = raw;
    try {
      plain = CryptoBox.decrypt(raw);
    } catch (err) {
      logWarn('ConfigStore', '解密失败，尝试按明文读取');
      plain = raw;
    }
    const obj: Record<string, Object> | null = parseJsonObject(plain);
    if (obj === null) {
      logError('ConfigStore', '配置解析失败，重置为空配置');
      return new PersistedState();
    }
    try {
      return persistedStateFromJson(obj);
    } catch (err) {
      logError('ConfigStore', `配置映射失败，重置为空配置: ${err}`);
      return new PersistedState();
    }
  }

  save(state: PersistedState): void {
    try {
      const plain: string = JSON.stringify(state);
      let stored: string = plain;
      try {
        stored = CryptoBox.encrypt(plain);
      } catch (err) {
        logWarn('ConfigStore', '加密不可用，降级明文存储');
      }
      const prefs: preferences.Preferences = this.ensurePrefs();
      prefs.putSync(KEY_STATE, stored);
      prefs.flush();
    } catch (err) {
      logError('ConfigStore', `配置保存失败: ${err}`);
    }
  }
}
