import { preferences } from '@kit.ArkData';
import {
  AppEnv, PREF_CONFIG, KEY_STATE, logWarn, logError, parseJsonObject, jArr, jObj
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

  /**
   * 统一序列化口径：安卓用 kotlinx.serialization 把 enum 写成字符串名、
   * 把未设置的体积写成 JSON null；鸿蒙 class 默认 stringify 出的是数字枚举和 -1。
   * 这里做归一化，保证备份两端能互解，本地旧数字格式仍由 load() 兼容读取。
   */
  private serialize(state: PersistedState): string {
    const parsed: Object = JSON.parse(JSON.stringify(state)) as Object;
    const obj: Record<string, Object> = parsed as Record<string, Object>;
    const fix = (raw: Object | undefined, fn: (item: Record<string, Object>) => void): void => {
      if (raw === undefined || !Array.isArray(raw)) {
        return;
      }
      const arr: Object[] = raw as Object[];
      for (const item of arr) {
        if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
          fn(item as Record<string, Object>);
        }
      }
    };
    fix(obj['servers'], (s: Record<string, Object>): void => {
      if (typeof s['type'] === 'number') {
        s['type'] = s['type'] === 1 ? 'TRANSMISSION' : 'QBITTORRENT';
      }
      if (typeof s['endpointMode'] === 'number') {
        s['endpointMode'] = s['endpointMode'] === 1 ? 'MANUAL' : 'AUTO';
      }
    });
    fix(obj['mpServers'], (m: Record<string, Object>): void => {
      if (typeof m['endpointMode'] === 'number') {
        m['endpointMode'] = m['endpointMode'] === 1 ? 'MANUAL' : 'AUTO';
      }
    });
    // -1 是鸿蒙的「未设置」哨兵；安卓那边是 null。重建对象跳过这些字段，
    // 不能用 delete（ArkTS 不支持），省略字段对 kotlinx.serialization 等同 null。
    const rssRaw: Object | undefined = obj['rssSources'];
    if (rssRaw !== undefined && Array.isArray(rssRaw)) {
      const rssArr: Object[] = rssRaw as Object[];
      const normalized: Object[] = [];
      for (const item of rssArr) {
        if (item === null || typeof item !== 'object' || Array.isArray(item)) {
          normalized.push(item);
          continue;
        }
        const src: Record<string, Object> = item as Record<string, Object>;
        const next: Record<string, Object> = {};
        const keys: string[] = Object.keys(src);
        for (const k of keys) {
          if ((k === 'minSizeGB' || k === 'maxSizeGB') && src[k] === -1) {
            continue;
          }
          next[k] = src[k];
        }
        normalized.push(next);
      }
      obj['rssSources'] = normalized as Object;
    }
    return JSON.stringify(obj);
  }

  save(state: PersistedState): void {
    try {
      const plain: string = this.serialize(state);
      let stored: string = plain;
      try {
        stored = CryptoBox.encrypt(plain);
      } catch (err) {
        logWarn('ConfigStore', '加密不可用，降级明文存储');
      }
      const prefs: preferences.Preferences = this.ensurePrefs();
      prefs.putSync(KEY_STATE, stored);
      // flush() 是异步 Promise：用户保存后立即退出被回收时可能丢盘，
      // 表现为「再进 APP 服务器变回未配置」。这里必须同步刷写。
      prefs.flushSync();
    } catch (err) {
      logError('ConfigStore', `配置保存失败: ${err}`);
    }
  }

  /** 导出明文 JSON（给备份用；密码加密由 BackupManager 负责） */
  toJson(state: PersistedState): string {
    return this.serialize(state);
  }

  /**
   * 从备份的明文 JSON 整个替换配置，用本机密钥重新加密落盘。
   * 解析失败返回 false，不改动现有配置。
   */
  restoreFromJson(plain: string): boolean {
    const obj: Record<string, Object> | null = parseJsonObject(plain);
    if (obj === null) {
      logError('ConfigStore', '备份配置解析失败');
      return false;
    }
    // 结构校验：必须是本应用导出的配置结构，拒绝把任意合法 JSON 当备份整包覆盖。
    // 缺字段时用默认值补齐是映射器的固有行为，所以必须在解析前先看字段是否齐全。
    const shapeOk: boolean = jArr(obj, 'servers') !== null
      && jObj(obj, 'settings') !== null
      && (obj['rssSources'] !== undefined || obj['mpServers'] !== undefined
        || obj['activeServerId'] !== undefined);
    if (!shapeOk) {
      logError('ConfigStore', '备份内容不是本应用的配置结构，已拒绝恢复');
      return false;
    }
    try {
      this.save(persistedStateFromJson(obj));
      return true;
    } catch (err) {
      logError('ConfigStore', `备份配置映射失败: ${err}`);
      return false;
    }
  }
}
