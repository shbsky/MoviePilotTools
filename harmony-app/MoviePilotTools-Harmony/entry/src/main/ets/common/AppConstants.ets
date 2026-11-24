import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/**
 * 全局共享常量 + JSON 安全解析工具 + 运行环境。
 * 对应安卓版散落各处的常量收拢（架构 §2 common/AppConstants.ets）。
 */

// ---------- 日志 ----------

// 注意：domain 必须用应用域 0x0000（0x0001 会被系统当作保留域，app 日志被丢弃，抓不到）
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG_PREFIX: string = 'MPtools.';

export function logDebug(tag: string, msg: string): void {
  hilog.debug(LOG_DOMAIN, LOG_TAG_PREFIX + tag, '%{public}s', msg);
}

export function logInfo(tag: string, msg: string): void {
  hilog.info(LOG_DOMAIN, LOG_TAG_PREFIX + tag, '%{public}s', msg);
}

export function logWarn(tag: string, msg: string): void {
  hilog.warn(LOG_DOMAIN, LOG_TAG_PREFIX + tag, '%{public}s', msg);
  appendFileLog(`W/${tag} ${msg}`);
}

export function logError(tag: string, msg: string): void {
  hilog.error(LOG_DOMAIN, LOG_TAG_PREFIX + tag, '%{public}s', msg);
  appendFileLog(`E/${tag} ${msg}`);
}

// ---------- 落盘调试日志（release 包 hilog 抓不到，排查播放/seek/接口问题时用） ----------

let debugLogPath: string = '';

export function attachDebugLog(filesDir: string): void {
  debugLogPath = filesDir + '/debug.log';
}

function appendFileLog(line: string): void {
  if (debugLogPath.length === 0) {
    return;
  }
  try {
    const f = fs.openSync(debugLogPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
    fs.writeSync(f.fd, `${new Date().toISOString()} ${line}\n`);
    fs.closeSync(f);
  } catch (err) {
    // 忽略
  }
}

export function logSeek(msg: string): void {
  appendFileLog(msg);
}

// ---------- 持久化 key ----------

export const PREF_CONFIG: string = 'mpt_config';
export const KEY_STATE: string = 'state_v1';
export const PREF_TOKENS: string = 'mpt_tokens';
export const KEY_SONGLOFT: string = 'songloft_session';
export const PREF_CRYPTO: string = 'mpt_crypto';
export const KEY_CRYPTO_KEY: string = 'config_key_raw';

// ---------- AppStorage key ----------

export const STORE_THEME_MODE: string = 'themeMode';
export const STORE_FONT_SCALE: string = 'fontScale';
/**
 * 系统当前是否深色（真机系统主题，与用户「跟随系统」设置无关）。
 * EntryAbility 在启动与每次 onConfigurationUpdate / environment 回调时写入，
 * Index 用 @StorageLink 监听——系统切换深浅色时页面立刻重绘（BUG：以前只在启动时读一次）。
 */
export const STORE_SYSTEM_DARK: string = 'systemDark';
export const STORE_DRILL_SERVER: string = 'drillFromDashboard';
export const STORE_CASTING_TO: string = 'castingTo';

// ---------- Toast ----------

export const TOAST_SHORT_MS: number = 2200;
export const TOAST_LONG_MS: number = 2400;

// ---------- 网络超时（毫秒，对齐安卓 Net.kt 三档超时） ----------

export const CONNECT_NORMAL_MS: number = 6000;
export const READ_NORMAL_MS: number = 30000;
export const READ_SLOW_MS: number = 130000;
export const CONNECT_PROBE_MS: number = 2500;
export const READ_PROBE_MS: number = 2500;

// ---------- 刷新频率可选项（秒） ----------

export const REFRESH_OPTIONS: number[] = [2, 3, 5, 10, 30, 60];

// ---------- 运行环境（Ability 上下文持有者） ----------

/**
 * EntryAbility 在 onCreate 时 attach 上下文，
 * ConfigStore / TokenVault / BackgroundAudioManager 等单例从这里取。
 */
export class AppEnv {
  private static ctx: common.UIAbilityContext | null = null;
  private static fg: boolean = false;

  static attach(context: common.UIAbilityContext): void {
    AppEnv.ctx = context;
  }

  static context(): common.UIAbilityContext {
    if (AppEnv.ctx === null) {
      throw new Error('AppEnv 未初始化：EntryAbility.onCreate 未执行');
    }
    return AppEnv.ctx;
  }

  static hasContext(): boolean {
    return AppEnv.ctx !== null;
  }

  static setForeground(fg: boolean): void {
    AppEnv.fg = fg;
  }

  static isForeground(): boolean {
    return AppEnv.fg;
  }
}

// ---------- JSON 安全解析（ArkTS 严格模式：禁 any，全部手写映射） ----------

/** 把 JSON 文本解析成对象；失败或不是对象时返回 null */
export function parseJsonObject(text: string): Record<string, Object> | null {
  try {
    const v: Object = JSON.parse(text) as Object;
    if (v === null || v === undefined || Array.isArray(v)) {
      return null;
    }
    return v as Record<string, Object>;
  } catch (err) {
    return null;
  }
}

/** 把 JSON 文本解析成对象数组；失败或不是数组时返回 null */
export function parseJsonArray(text: string): Array<Record<string, Object>> | null {
  try {
    const v: Object = JSON.parse(text) as Object;
    if (!Array.isArray(v)) {
      return null;
    }
    const out: Array<Record<string, Object>> = [];
    const arr: Array<Object> = v as Array<Object>;
    for (const item of arr) {
      if (item !== null && item !== undefined && !Array.isArray(item) && typeof item === 'object') {
        out.push(item as Record<string, Object>);
      } else {
        out.push({} as Record<string, Object>);
      }
    }
    return out;
  } catch (err) {
    return null;
  }
}

/** 按候选 key 顺序取第一个非空字段（兼容 snake_case / camelCase 服务端字段） */
export function pick(o: Record<string, Object>, keys: string[]): Object | undefined {
  for (const k of keys) {
    const v: Object | undefined = o[k];
    if (v !== undefined && v !== null) {
      return v;
    }
  }
  return undefined;
}

export function jStr(o: Record<string, Object>, keys: string[], def: string = ''): string {
  const v: Object | undefined = pick(o, keys);
  if (typeof v === 'string') {
    return v;
  }
  if (typeof v === 'number' && isFinite(v)) {
    return String(v);
  }
  if (typeof v === 'boolean') {
    return v ? 'true' : 'false';
  }
  return def;
}

export function jNum(o: Record<string, Object>, keys: string[], def: number = 0): number {
  const v: Object | undefined = pick(o, keys);
  if (typeof v === 'number' && isFinite(v)) {
    return v;
  }
  if (typeof v === 'boolean') {
    return v ? 1 : 0;
  }
  if (typeof v === 'string') {
    const n: number = parseFloat(v);
    if (!isNaN(n)) {
      return n;
    }
  }
  return def;
}

export function jBool(o: Record<string, Object>, keys: string[], def: boolean = false): boolean {
  const v: Object | undefined = pick(o, keys);
  if (typeof v === 'boolean') {
    return v;
  }
  if (typeof v === 'number') {
    return v !== 0;
  }
  if (typeof v === 'string') {
    return v === 'true' || v === '1';
  }
  return def;
}

export function jStrArr(o: Record<string, Object>, keys: string[]): string[] {
  const v: Object | undefined = pick(o, keys);
  const out: string[] = [];
  if (v !== undefined && Array.isArray(v)) {
    const arr: Array<Object> = v as Array<Object>;
    for (const item of arr) {
      if (typeof item === 'string') {
        out.push(item);
      } else if (typeof item === 'number') {
        out.push(String(item));
      }
    }
  }
  return out;
}

/** 字符串列表字段，解析失败时返回默认值 */
export function jStrList(o: Record<string, Object>, keys: string[], def: string[]): string[] {
  const v: Object | undefined = pick(o, keys);
  const out: string[] = [];
  if (v !== undefined && Array.isArray(v)) {
    const arr: Array<Object> = v as Array<Object>;
    for (const item of arr) {
      if (typeof item === 'string') {
        out.push(item);
      }
    }
    return out;
  }
  return def;
}

export function jNumArr(o: Record<string, Object>, keys: string[]): number[] {
  const v: Object | undefined = pick(o, keys);
  const out: number[] = [];
  if (v !== undefined && Array.isArray(v)) {
    const arr: Array<Object> = v as Array<Object>;
    for (const item of arr) {
      if (typeof item === 'number' && isFinite(item)) {
        out.push(item);
      }
    }
  }
  return out;
}

export function jObj(o: Record<string, Object>, key: string): Record<string, Object> | null {
  const v: Object | undefined = o[key];
  if (v !== undefined && v !== null && !Array.isArray(v) && typeof v === 'object') {
    return v as Record<string, Object>;
  }
  return null;
}

export function jArr(o: Record<string, Object>, key: string): Array<Record<string, Object>> | null {
  const v: Object | undefined = o[key];
  if (v !== undefined && Array.isArray(v)) {
    const out: Array<Record<string, Object>> = [];
    const arr: Array<Object> = v as Array<Object>;
    for (const item of arr) {
      if (item !== null && item !== undefined && !Array.isArray(item) && typeof item === 'object') {
        out.push(item as Record<string, Object>);
      } else {
        out.push({} as Record<string, Object>);
      }
    }
    return out;
  }
  return null;
}

/** 数组字段原样取（元素可能是混合类型时用） */
export function jRawArr(o: Record<string, Object>, key: string): Array<Object> | null {
  const v: Object | undefined = o[key];
  if (v !== undefined && Array.isArray(v)) {
    return v as Array<Object>;
  }
  return null;
}
