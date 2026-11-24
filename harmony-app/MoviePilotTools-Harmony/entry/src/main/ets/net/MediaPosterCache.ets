import { MoviePilotClient } from './MoviePilotClient';

/**
 * 种子标题 → 海报地址（对应安卓 net/MediaPosterResolver.kt）。
 *
 * 站点浏览接口只给文字，没有任何图片字段，海报只能靠 MP 的识别接口反查。
 * 一屏几十条就是几十次请求，所以这里做三件事：
 *  1. 归一化标题当 key：同一部片的不同清晰度/压制组共享一张海报，请求量能降 80%；
 *  2. 内存 LRU + 负缓存：成功的存地址，失败的也记一笔，翻回来不重试；
 *  3. 并发 3：MP 内部要查 TMDB/豆瓣，开太多互相拖慢还容易被限流。
 */

const CAPACITY: number = 400;
const CONCURRENCY: number = 3;

const BRACKETS: RegExp = /[\[\(【（][^\]\)】）]*[\]\)】）]/g;
const TECHNICAL: RegExp = new RegExp(
  '(2160p|1080p|1080i|720p|480p|4k|uhd|web-?dl|webrip|web|blu-?ray|bdrip|bdmv|remux|' +
    'hdtv|hdtvrip|dvdrip|h\\.?264|h\\.?265|x\\.?264|x\\.?265|hevc|avc|av1|aac|ac3|eac3|' +
    'dts|truehd|ddp|atmos|flac|10bit|8bit|hdr10\\+?|hdr|dovi|dv|sdr|repack|proper|' +
    'internal|limited|remastered|60fps|hq)', 'gi');
const SEASON: RegExp = new RegExp(
  '(s\\d{1,2}(e\\d{1,3})?|e\\d{1,3}|第[一二三四五六七八九十\\d]+季|season\\s*\\d+|' +
    'season\\s*\\d+\\s*complete)', 'gi');
const GROUP_SUFFIX: RegExp = /[-@][A-Za-z0-9@._]{2,}$/g;
const COLLECTION: RegExp = /(合集|全集|complete|collection)/gi;

export class PosterRequest {
  key: string = '';
  title: string = '';

  constructor(key: string, title: string) {
    this.key = key;
    this.title = title;
  }
}

export class MediaPosterCache {
  private static hits: Map<string, string> = new Map();
  private static misses: Set<string> = new Set();
  private static running: number = 0;
  private static queue: Array<() => void> = [];

  /**
   * 归一化成缓存键。
   * 例：`[FREE] Ace of the Diamond S02E19 1080p FriDay WEB-DL AAC2.0 H.264-MWeb`
   * → `ace of the diamond friday`
   * 年份保留（`电影名 2019`），否则同名新旧两版会共用一张海报。
   */
  static titleKey(raw: string): string {
    let text: string = raw.trim();
    if (text.length === 0) {
      return '';
    }
    text = text.replace(BRACKETS, ' ');
    text = text.replace(TECHNICAL, ' ');
    text = text.replace(SEASON, ' ');
    text = text.replace(COLLECTION, ' ');
    text = text.replace(GROUP_SUFFIX, ' ');
    text = text.replace(/_/g, ' ').replace(/\./g, ' ');
    text = text.replace(/[-—/|:]+/g, ' ');
    text = text.replace(/\s+/g, ' ').trim().toLowerCase();
    return text.length > 48 ? text.substring(0, 48).trim() : text;
  }

  static cached(key: string): string {
    const v: string | undefined = MediaPosterCache.hits.get(key);
    return v === undefined ? '' : v;
  }

  /** 已经问过 MP 了（成功或失败都算），不必再发请求 */
  static isResolved(key: string): boolean {
    return MediaPosterCache.hits.has(key) || MediaPosterCache.misses.has(key);
  }

  static clear(): void {
    MediaPosterCache.hits.clear();
    MediaPosterCache.misses.clear();
  }

  /** 单条查询（详情页用）：命中缓存立刻返回，否则发一次请求 */
  static async resolveOne(client: MoviePilotClient, title: string): Promise<string> {
    const key: string = MediaPosterCache.titleKey(title);
    if (key.length === 0) {
      return '';
    }
    if (MediaPosterCache.isResolved(key)) {
      return MediaPosterCache.cached(key);
    }
    let url: string = '';
    try {
      const raw: string | null = await client.sitePoster(title);
      url = raw === null ? '' : raw;
    } catch (e) {
      url = '';
    }
    if (url.length > 0) {
      MediaPosterCache.remember(key, url);
    } else {
      MediaPosterCache.misses.add(key);
    }
    return url;
  }

  /**
   * 批量解析，返回「本次真正拿到」的 key → 海报地址（已命中的不返回，调用方自己查缓存）。
   * 调用方负责按 key 去重。
   */
  static async resolve(client: MoviePilotClient, requests: PosterRequest[]): Promise<Map<string, string>> {
    const out: Map<string, string> = new Map();
    const jobs: Promise<void>[] = [];
    for (const req of requests) {
      jobs.push(MediaPosterCache.resolveInto(client, req, out));
    }
    await Promise.all(jobs);
    return out;
  }

  private static async resolveInto(client: MoviePilotClient, req: PosterRequest,
    out: Map<string, string>): Promise<void> {
    await MediaPosterCache.acquire();
    try {
      if (MediaPosterCache.isResolved(req.key)) {
        const hit: string = MediaPosterCache.cached(req.key);
        if (hit.length > 0) {
          out.set(req.key, hit);
        }
        return;
      }
      let url: string = '';
      try {
        const raw: string | null = await client.sitePoster(req.title);
        url = raw === null ? '' : raw;
      } catch (e) {
        url = '';
      }
      if (url.length > 0) {
        MediaPosterCache.remember(req.key, url);
        out.set(req.key, url);
      } else {
        MediaPosterCache.misses.add(req.key);
      }
    } finally {
      MediaPosterCache.release();
    }
  }

  private static remember(key: string, url: string): void {
    if (!MediaPosterCache.hits.has(key) && MediaPosterCache.hits.size >= CAPACITY) {
      // 简单淘汰：清掉最老的一批（保留最近 3/4），够用且不会无限涨
      const drop: number = Math.floor(CAPACITY / 4);
      const keys: string[] = [];
      MediaPosterCache.hits.forEach((v: string, k: string): void => {
        keys.push(k);
      });
      for (let i = 0; i < drop && i < keys.length; i++) {
        MediaPosterCache.hits.delete(keys[i]);
      }
    }
    MediaPosterCache.hits.set(key, url);
  }

  private static acquire(): Promise<void> {
    if (MediaPosterCache.running < CONCURRENCY) {
      MediaPosterCache.running++;
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void): void => {
      MediaPosterCache.queue.push((): void => {
        MediaPosterCache.running++;
        resolve();
      });
    });
  }

  private static release(): void {
    MediaPosterCache.running--;
    const next: (() => void) | undefined = MediaPosterCache.queue.shift();
    if (next !== undefined) {
      next();
    }
  }
}
