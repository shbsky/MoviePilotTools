import { newUuid } from './Models';
import { jStr, jNum, jBool, jStrList, jNumArr, pick, parseJsonArray } from '../common/AppConstants';

/**
 * RSS 数据模型（代码级保留，用户决策 b：无页面入口、无后台轮询）。
 * 移植安卓 data/RssModels.kt。
 */

/** 自定义请求头，用于需要 x-api-key / Cookie / Authorization 的站点 */
export class HeaderPair {
  key: string = '';
  value: string = '';

  constructor(key: string = '', value: string = '') {
    this.key = key;
    this.value = value;
  }
}

/**
 * 一条 RSS 订阅源。规则全部挂在源上（与 iOS 原版一致）：
 * 命中的条目在自动下载开启时直接推给指定下载器。
 */
export class RssSource {
  id: string = newUuid();
  name: string = '';
  url: string = '';
  enabled: boolean = true;
  autoDownload: boolean = false;
  /** 站点 API Key（M-Team 这类需要 x-api-key 请求头） */
  apiKey: string = '';
  headers: HeaderPair[] = [];
  faviconUrl: string = '';
  includeKeywords: string[] = [];
  excludeKeywords: string[] = [];
  minSizeGB: number = -1;
  maxSizeGB: number = -1;
  /** 例：01-12 / S01E01-E10 / 01 02 03 / 01-12; 15 */
  episodeFilter: string = '';
  savePath: string = '';
  category: string = '';
  addPaused: boolean = false;
  /** -1 低 / 0 默认 / 1 高 */
  priority: number = 0;
  /** 空 = 自动选择服务器 */
  targetServerId: string = '';
  lastUpdated: number = 0;
  lastError: string = '';

  hasRules(): boolean {
    return this.includeKeywords.length > 0 ||
      this.excludeKeywords.length > 0 ||
      this.minSizeGB >= 0 ||
      this.maxSizeGB >= 0 ||
      this.episodeFilter.trim().length > 0;
  }

  ruleSummary(): string {
    const parts: string[] = [];
    if (this.includeKeywords.length > 0) {
      parts.push(`含 ${this.includeKeywords.join('/')}`);
    }
    if (this.excludeKeywords.length > 0) {
      parts.push(`排 ${this.excludeKeywords.join('/')}`);
    }
    if (this.minSizeGB >= 0) {
      parts.push(`≥${trimNum(this.minSizeGB)}G`);
    }
    if (this.maxSizeGB >= 0) {
      parts.push(`≤${trimNum(this.maxSizeGB)}G`);
    }
    if (this.episodeFilter.trim().length > 0) {
      parts.push(`集 ${this.episodeFilter}`);
    }
    const joined: string = parts.join(' · ');
    return joined.length > 0 ? joined : '无规则（全部推送）';
  }

  /** favicon 兜底：优先用户填的，其次按 host 猜，最后用站点默认图标 */
  resolvedFavicon(): string {
    if (this.faviconUrl.trim().length > 0) {
      return this.faviconUrl;
    }
    const lower: string = this.url.toLowerCase();
    if (lower.indexOf('m-team.cc') >= 0) {
      return 'https://m-team.cc/favicon.ico';
    }
    let rest: string = this.url;
    const proto: number = rest.indexOf('://');
    if (proto < 0) {
      return '';
    }
    rest = rest.substring(proto + 3);
    const slash: number = rest.indexOf('/');
    const host: string = slash >= 0 ? rest.substring(0, slash) : rest;
    if (host.trim().length === 0) {
      return '';
    }
    const scheme: string = lower.startsWith('https') ? 'https' : 'http';
    return `${scheme}://${host}/favicon.ico`;
  }
}

function trimNum(v: number): string {
  if (Math.abs(v - Math.round(v)) < 1e-9) {
    return String(Math.round(v));
  }
  return String(v);
}

/** 从 RSS 里解析出来的一条种子 */
export class RssItemRecord {
  id: string = newUuid();
  sourceId: string = '';
  title: string = '';
  link: string = '';
  pubDate: number = 0;
  /** 0 表示 RSS 没给体积，此时体积规则不参与判断 */
  sizeBytes: number = 0;
  downloaded: boolean = false;
  seenAt: number = Date.now();
  /** 命中规则的时间，用于「全部条目」里高亮 */
  matched: boolean = false;
  error: string = '';
}

export function rssSourceFromJson(o: Record<string, Object>): RssSource {
  const r: RssSource = new RssSource();
  r.id = jStr(o, ['id'], newUuid());
  r.name = jStr(o, ['name']);
  r.url = jStr(o, ['url']);
  r.enabled = jBool(o, ['enabled'], true);
  r.autoDownload = jBool(o, ['autoDownload', 'auto_download']);
  r.apiKey = jStr(o, ['apiKey', 'api_key']);
  const headerPairs: HeaderPair[] = [];
  const raw: Object | undefined = o['headers'];
  if (raw !== undefined && Array.isArray(raw)) {
    const arr: Array<Object> = raw as Array<Object>;
    for (const item of arr) {
      if (item !== null && item !== undefined && typeof item === 'object' && !Array.isArray(item)) {
        const ho: Record<string, Object> = item as Record<string, Object>;
        headerPairs.push(new HeaderPair(jStr(ho, ['key']), jStr(ho, ['value'])));
      }
    }
  }
  r.headers = headerPairs;
  r.faviconUrl = jStr(o, ['faviconUrl', 'favicon_url']);
  r.includeKeywords = jStrList(o, ['includeKeywords', 'include_keywords'], []);
  r.excludeKeywords = jStrList(o, ['excludeKeywords', 'exclude_keywords'], []);
  const minV: Object | undefined = pick(o, ['minSizeGB', 'min_size_gb']);
  r.minSizeGB = typeof minV === 'number' ? minV : -1;
  const maxV: Object | undefined = pick(o, ['maxSizeGB', 'max_size_gb']);
  r.maxSizeGB = typeof maxV === 'number' ? maxV : -1;
  r.episodeFilter = jStr(o, ['episodeFilter', 'episode_filter']);
  r.savePath = jStr(o, ['savePath', 'save_path']);
  r.category = jStr(o, ['category']);
  r.addPaused = jBool(o, ['addPaused', 'add_paused']);
  r.priority = Math.trunc(jNum(o, ['priority'], 0));
  r.targetServerId = jStr(o, ['targetServerId', 'target_server_id']);
  r.lastUpdated = jNum(o, ['lastUpdated', 'last_updated']);
  r.lastError = jStr(o, ['lastError', 'last_error']);
  return r;
}

export function rssItemRecordFromJson(o: Record<string, Object>): RssItemRecord {
  const r: RssItemRecord = new RssItemRecord();
  r.id = jStr(o, ['id'], newUuid());
  r.sourceId = jStr(o, ['sourceId', 'source_id']);
  r.title = jStr(o, ['title']);
  r.link = jStr(o, ['link']);
  r.pubDate = jNum(o, ['pubDate', 'pub_date']);
  r.sizeBytes = jNum(o, ['sizeBytes', 'size_bytes']);
  r.downloaded = jBool(o, ['downloaded']);
  r.seenAt = jNum(o, ['seenAt', 'seen_at'], Date.now());
  r.matched = jBool(o, ['matched']);
  r.error = jStr(o, ['error']);
  return r;
}

export function rssSourceListToJson(list: RssSource[]): string {
  const arr: Array<Record<string, Object>> = [];
  for (const src of list) {
    const o: Record<string, Object> = {} as Record<string, Object>;
    o['id'] = src.id;
    o['name'] = src.name;
    o['url'] = src.url;
    o['enabled'] = src.enabled;
    o['autoDownload'] = src.autoDownload;
    o['apiKey'] = src.apiKey;
    const hs: Array<Record<string, Object>> = [];
    for (const h of src.headers) {
      const ho: Record<string, Object> = {} as Record<string, Object>;
      ho['key'] = h.key;
      ho['value'] = h.value;
      hs.push(ho);
    }
    o['headers'] = hs;
    o['faviconUrl'] = src.faviconUrl;
    o['includeKeywords'] = src.includeKeywords;
    o['excludeKeywords'] = src.excludeKeywords;
    if (src.minSizeGB >= 0) {
      o['minSizeGB'] = src.minSizeGB;
    }
    if (src.maxSizeGB >= 0) {
      o['maxSizeGB'] = src.maxSizeGB;
    }
    o['episodeFilter'] = src.episodeFilter;
    o['savePath'] = src.savePath;
    o['category'] = src.category;
    o['addPaused'] = src.addPaused;
    o['priority'] = src.priority;
    o['targetServerId'] = src.targetServerId;
    o['lastUpdated'] = src.lastUpdated;
    o['lastError'] = src.lastError;
    arr.push(o);
  }
  return JSON.stringify(arr);
}

export function rssSourceListFromJson(text: string): RssSource[] {
  const out: RssSource[] = [];
  const arr: Array<Record<string, Object>> | null = parseJsonArray(text);
  if (arr !== null) {
    for (const o of arr) {
      out.push(rssSourceFromJson(o));
    }
  }
  return out;
}
