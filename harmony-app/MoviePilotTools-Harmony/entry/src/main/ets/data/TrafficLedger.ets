import { preferences } from '@kit.ArkData';
import {
  AppEnv, jNum, jStr, logWarn, parseJsonObject
} from '../common/AppConstants';
import { ServerSnapshot } from '../model/Models';

/**
 * 流量账本（今日 / 本月累计下载、上传）。
 *
 * 为什么要在本地记账：
 * qBittorrent 的 `alltime_dl / alltime_ul`、Transmission 的 `cumulative-stats` 只给
 * 「装机以来的累计值」，两家都没有「今天用了多少 / 这个月用了多少」这种分时段口径
 * （历史版曾接第三方 torrent-traffic-monitor 面板，要额外部一套服务 + 填账号，v1.5.1 已删）。
 *
 * 这里用「累计值的差值」自己算：
 *   - 每次刷新把各服务器当前的累计计数器记下来；
 *   - 跨天 / 跨月时，把「上一次观测到的累计值」当作新周期的起点（baseline）；
 *   - 今日 = 当前累计 − 今日起点，本月 = 当前累计 − 本月起点。
 * 累计计数器在下载器端是持久化的，所以 App 没开的时候流量也照跑，重开一次就对上了。
 *
 * 两个防御：
 *   1. 计数器变小（重装 qB / 换数据目录）→ 基线就地重置，不会出现天文数字；
 *   2. 跨周期时如果上次观测已经是 48 小时（月：7 天）以前，说明中间好久没开 App，
 *      那段流量没法合理归到「今天」，直接把当前值当起点，宁可从 0 起算。
 *
 * 存储：独立 preferences（不含任何账号密码，明文 JSON 即可），每 20 秒最多落一次盘。
 */

const PREF_TRAFFIC: string = 'mpt_traffic';
const KEY_LEDGER: string = 'ledger_v1';
/** 落盘节流：轮询 10 秒一次，没必要每次都写盘 */
const SAVE_INTERVAL_MS: number = 20000;
/** 跨天时「上次观测」超过这个间隔就不再当作今天的起点 */
const DAY_GAP_LIMIT_HOURS: number = 48;
/** 跨月时的同类上限 */
const MONTH_GAP_LIMIT_HOURS: number = 24 * 7;

class Counter {
  id: string = '';
  dl: number = 0;
  ul: number = 0;

  constructor(id: string = '', dl: number = 0, ul: number = 0) {
    this.id = id;
    this.dl = dl;
    this.ul = ul;
  }

  copy(): Counter {
    return new Counter(this.id, this.dl, this.ul);
  }
}

/** 仪表盘流量瓦片要用的四个数字 */
export class TrafficTotals {
  dayDownload: number = 0;
  dayUpload: number = 0;
  monthDownload: number = 0;
  monthUpload: number = 0;
  /** 至少有一台服务器参与了统计（否则页面显示「—」而不是 0 B） */
  hasBaseline: boolean = false;
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

function dayKeyOf(ts: number): string {
  const d: Date = new Date(ts);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

function monthKeyOf(ts: number): string {
  const d: Date = new Date(ts);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}`;
}

function cloneCounters(src: Map<string, Counter>): Map<string, Counter> {
  const out: Map<string, Counter> = new Map<string, Counter>();
  src.forEach((v: Counter, k: string): void => {
    out.set(k, v.copy());
  });
  return out;
}

/** 解析 [{id,dl,ul}] */
function countersFromJson(raw: Object | undefined): Map<string, Counter> {
  const out: Map<string, Counter> = new Map<string, Counter>();
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return out;
  }
  const arr: Array<Object> = raw as Array<Object>;
  for (const item of arr) {
    if (item === null || item === undefined || typeof item !== 'object') {
      continue;
    }
    const o: Record<string, Object> = item as Record<string, Object>;
    const id: string = jStr(o, ['id']);
    if (id.length === 0) {
      continue;
    }
    out.set(id, new Counter(id, Math.trunc(jNum(o, ['dl'], 0)), Math.trunc(jNum(o, ['ul'], 0))));
  }
  return out;
}

function countersToJson(src: Map<string, Counter>): Object[] {
  const out: Object[] = [];
  src.forEach((v: Counter): void => {
    const o: Record<string, Object> = {};
    o['id'] = v.id;
    o['dl'] = v.dl;
    o['ul'] = v.ul;
    out.push(o);
  });
  return out;
}

export class TrafficLedger {
  private static inst: TrafficLedger | null = null;

  static getInstance(): TrafficLedger {
    if (TrafficLedger.inst === null) {
      TrafficLedger.inst = new TrafficLedger();
    }
    return TrafficLedger.inst;
  }

  private loaded: boolean = false;
  private day: string = '';
  private month: string = '';
  /** 今日起点（当天第一次观测到的累计值） */
  private base: Map<string, Counter> = new Map<string, Counter>();
  /** 本月起点 */
  private mbase: Map<string, Counter> = new Map<string, Counter>();
  /** 最近一次观测到的累计值 */
  private last: Map<string, Counter> = new Map<string, Counter>();
  private lastAt: number = 0;
  private savedAt: number = 0;
  private dirty: boolean = false;
  private prefs: preferences.Preferences | null = null;

  private ensurePrefs(): preferences.Preferences | null {
    if (this.prefs !== null) {
      return this.prefs;
    }
    try {
      this.prefs = preferences.getPreferencesSync(AppEnv.context(), { name: PREF_TRAFFIC });
      return this.prefs;
    } catch (err) {
      logWarn('TrafficLedger', `打开 preferences 失败: ${err}`);
      return null;
    }
  }

  private ensureLoaded(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    const prefs: preferences.Preferences | null = this.ensurePrefs();
    if (prefs === null) {
      return;
    }
    let raw: string = '';
    try {
      raw = prefs.getSync(KEY_LEDGER, '') as string;
    } catch (err) {
      logWarn('TrafficLedger', `读取账本失败: ${err}`);
      return;
    }
    if (typeof raw !== 'string' || raw.length === 0) {
      return;
    }
    const obj: Record<string, Object> | null = parseJsonObject(raw);
    if (obj === null) {
      return;
    }
    this.day = jStr(obj, ['day']);
    this.month = jStr(obj, ['month']);
    this.lastAt = Math.trunc(jNum(obj, ['lastAt'], 0));
    this.base = countersFromJson(obj['base']);
    this.mbase = countersFromJson(obj['mbase']);
    this.last = countersFromJson(obj['last']);
  }

  /**
   * 每轮刷新调一次：更新基线 / 最近观测，并按需落盘。
   * samples 必须是「全部已配置服务器」的快照（离线也要在里面，用来清理已删除的服务器）。
   */
  record(samples: Map<string, ServerSnapshot>, nowMs: number): void {
    this.ensureLoaded();
    const day: string = dayKeyOf(nowMs);
    const month: string = monthKeyOf(nowMs);
    const gapHours: number = this.lastAt > 0 ? (nowMs - this.lastAt) / 3600000 : 0;

    if (this.day !== day) {
      // 跨天：昨天的最后一个观测值就是今天的起点
      this.base = gapHours > DAY_GAP_LIMIT_HOURS
        ? new Map<string, Counter>() : cloneCounters(this.last);
      this.day = day;
      this.dirty = true;
    }
    if (this.month !== month) {
      this.mbase = gapHours > MONTH_GAP_LIMIT_HOURS
        ? new Map<string, Counter>() : cloneCounters(this.last);
      this.month = month;
      this.dirty = true;
    }

    samples.forEach((snap: ServerSnapshot, id: string): void => {
      if (!snap.online) {
        return;
      }
      const dl: number = Math.trunc(snap.totalDownloaded);
      const ul: number = Math.trunc(snap.totalUploaded);
      // 两个计数器都读不到（老版本下载器 / 接口裁剪）就跳过，不要把 0 当成真值写进基线
      if (dl <= 0 && ul <= 0) {
        return;
      }
      const prev: Counter | undefined = this.last.get(id);
      if (prev !== undefined && (dl < prev.dl || ul < prev.ul)) {
        // 计数器被清零（重装 / 换目录）：基线同步重置，本周期从当前值重新算
        this.base.set(id, new Counter(id, dl, ul));
        this.mbase.set(id, new Counter(id, dl, ul));
      }
      if (!this.base.has(id)) {
        this.base.set(id, new Counter(id, dl, ul));
      }
      if (!this.mbase.has(id)) {
        this.mbase.set(id, new Counter(id, dl, ul));
      }
      const cur: Counter | undefined = this.last.get(id);
      if (cur === undefined || cur.dl !== dl || cur.ul !== ul) {
        this.last.set(id, new Counter(id, dl, ul));
        this.dirty = true;
      }
    });

    // 服务器被删掉：顺手把它的基线清掉，免得以后重加同 id 时串味
    this.prune(this.base, samples);
    this.prune(this.mbase, samples);
    this.prune(this.last, samples);

    this.lastAt = nowMs;
    this.maybeSave(nowMs);
  }

  private prune(map: Map<string, Counter>, samples: Map<string, ServerSnapshot>): void {
    const dead: string[] = [];
    map.forEach((v: Counter, k: string): void => {
      if (!samples.has(k)) {
        dead.push(k);
      }
    });
    for (const k of dead) {
      map.delete(k);
      this.dirty = true;
    }
  }

  /** 取指定服务器集合的今日 / 本月累计（activeServerId 过滤后的口径） */
  totalsFor(ids: string[]): TrafficTotals {
    this.ensureLoaded();
    const out: TrafficTotals = new TrafficTotals();
    for (const id of ids) {
      const cur: Counter | undefined = this.last.get(id);
      if (cur === undefined) {
        continue;
      }
      const dayBase: Counter | undefined = this.base.get(id);
      if (dayBase !== undefined) {
        out.hasBaseline = true;
        const dd: number = cur.dl - dayBase.dl;
        const du: number = cur.ul - dayBase.ul;
        out.dayDownload += dd > 0 ? dd : 0;
        out.dayUpload += du > 0 ? du : 0;
      }
      const monthBase: Counter | undefined = this.mbase.get(id);
      if (monthBase !== undefined) {
        const md: number = cur.dl - monthBase.dl;
        const mu: number = cur.ul - monthBase.ul;
        out.monthDownload += md > 0 ? md : 0;
        out.monthUpload += mu > 0 ? mu : 0;
      }
    }
    return out;
  }

  private maybeSave(nowMs: number): void {
    if (!this.dirty) {
      return;
    }
    if (nowMs - this.savedAt < SAVE_INTERVAL_MS) {
      return;
    }
    this.save(nowMs);
  }

  /** 立即落盘（退到后台时调用，避免最后一段数据丢失） */
  flush(nowMs: number): void {
    if (this.dirty) {
      this.save(nowMs);
    }
  }

  private save(nowMs: number): void {
    const prefs: preferences.Preferences | null = this.ensurePrefs();
    if (prefs === null) {
      return;
    }
    const obj: Record<string, Object> = {};
    obj['day'] = this.day;
    obj['month'] = this.month;
    obj['lastAt'] = this.lastAt;
    obj['base'] = countersToJson(this.base);
    obj['mbase'] = countersToJson(this.mbase);
    obj['last'] = countersToJson(this.last);
    try {
      prefs.putSync(KEY_LEDGER, JSON.stringify(obj));
      prefs.flush();
      this.dirty = false;
      this.savedAt = nowMs;
    } catch (err) {
      logWarn('TrafficLedger', `账本落盘失败: ${err}`);
    }
  }
}
