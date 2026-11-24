import { EndpointMode, Endpoint, endpointFromJson, newUuid } from './Models';
import { jStr, jNum, jBool } from '../common/AppConstants';

/**
 * MoviePilot 数据模型，移植安卓 data/MpModels.kt。
 * MpChannels 频道表与流式搜索辅助在 T04 批次补全。
 */

/** MoviePilot 服务器。与下载器一样支持多地址自动切换。 */
export class MpServer {
  id: string = newUuid();
  name: string = 'MoviePilot';
  endpoints: Endpoint[] = [];
  /** API Token（MP 设置 → 系统 → API Token），可调用全部接口 */
  apiToken: string = '';
  /** 可选：填了才能用「渐进式搜索」和更细的用户态能力 */
  username: string = '';
  password: string = '';
  endpointMode: EndpointMode = EndpointMode.AUTO;
  pinnedEndpointIndex: number = 0;

  displayName(): string {
    return this.name.trim().length > 0 ? this.name : 'MoviePilot';
  }

  activeEndpoints(): Endpoint[] {
    const out: Endpoint[] = [];
    for (const ep of this.endpoints) {
      if (ep.enabled && ep.isValid()) {
        out.push(ep);
      }
    }
    return out;
  }

  hasLogin(): boolean {
    return this.username.trim().length > 0 && this.password.trim().length > 0;
  }

  isValid(): boolean {
    return this.activeEndpoints().length > 0 && this.apiToken.trim().length > 0;
  }
}

export function mpServerFromJson(o: Record<string, Object>): MpServer {
  const m: MpServer = new MpServer();
  m.id = jStr(o, ['id'], newUuid());
  m.name = jStr(o, ['name'], 'MoviePilot');
  const eps: Endpoint[] = [];
  const raw: Object | undefined = o['endpoints'];
  if (raw !== undefined && Array.isArray(raw)) {
    const arr: Array<Object> = raw as Array<Object>;
    for (const item of arr) {
      if (item !== null && item !== undefined && typeof item === 'object' && !Array.isArray(item)) {
        eps.push(endpointFromJson(item as Record<string, Object>));
      }
    }
  }
  m.endpoints = eps;
  m.apiToken = jStr(o, ['apiToken', 'api_token']);
  m.username = jStr(o, ['username']);
  m.password = jStr(o, ['password']);
  m.endpointMode = Math.trunc(jNum(o, ['endpointMode', 'endpoint_mode'], 0)) === 1
    ? EndpointMode.MANUAL : EndpointMode.AUTO;
  m.pinnedEndpointIndex = Math.trunc(jNum(o, ['pinnedEndpointIndex', 'pinned_endpoint_index'], 0));
  return m;
}

/** MP 返回的影视条目 */
export class MpMedia {
  mediaId: string = '';
  source: string = '';
  type: string = '';
  title: string = '';
  year: string = '';
  season: number = -1;
  tmdbId: number = -1;
  doubanId: string = '';
  bangumiId: number = -1;
  posterUrl: string = '';
  backdropUrl: string = '';
  overview: string = '';
  vote: number = 0;
  genres: string[] = [];
  directors: string[] = [];
  cast: string[] = [];
  releaseDate: string = '';
  category: string = '';

  isTV(): boolean {
    const t: string = this.type.toLowerCase();
    return t === 'tv' || this.type === '电视剧';
  }

  typeLabel(): string {
    return this.isTV() ? '剧集' : '电影';
  }

  yearLabel(): string {
    return this.year.trim().length > 0 ? this.year : this.releaseDate.substring(0, 4);
  }

  /** 资源搜索用的 mediaid，MP 需要「来源:ID」格式 */
  searchKey(): string {
    if (this.mediaId.indexOf(':') >= 0) {
      return this.mediaId;
    }
    if (this.tmdbId > 0) {
      return `tmdb:${this.tmdbId}`;
    }
    if (this.doubanId.trim().length > 0) {
      return `douban:${this.doubanId}`;
    }
    if (this.bangumiId > 0) {
      return `bangumi:${this.bangumiId}`;
    }
    return this.mediaId;
  }
}

/** 一条候选资源（对应 MP 的 torrent_info） */
export class MpResource {
  key: string = newUuid();
  siteName: string = '';
  title: string = '';
  description: string = '';
  pageUrl: string = '';
  sizeBytes: number = 0;
  seeders: number = 0;
  peers: number = 0;
  grabs: number = 0;
  pubDateText: string = '';
  pubDateMs: number = 0;
  downloadFactor: number = 1;
  uploadFactor: number = 1;
  hitAndRun: boolean = false;
  labels: string[] = [];
  /**
   * MP 的「剩余免费时间」（TorrentInfo.freedate_diff），网页上单独一个绿色标签，
   * 形如 `1天23小时12分钟`。以前没解析这个字段，免费种子只能显示「免费」，
   * 时长靠猜 description 基本猜不到（用户反馈「免费时长标签没加上」）。
   */
  freeTimeDiff: string = '';
  /**
   * 免费截止时间（`TorrentInfo.freedate`，形如 `2026-11-23 19:35:00`）。
   *
   * 部分站点只给截止时间、`freedate_diff` 是空的，
   * 结果「免费」后面光秃秃的，而站点网页写着「限时1时20分」。
   * 服务端不给现成时长，就自己按截止时间算一次兜底。
   */
  freeDate: string = '';
  /** 原始 torrent_info JSON，投递时原样回传 */
  rawJson: string = '';

  isFree(): boolean {
    return this.downloadFactor <= 0.0;
  }

  isDoubleUp(): boolean {
    return this.uploadFactor > 1.0;
  }

  /**
   * 促销文案（对齐 MP 前端）：
   * 以前 0.01~0.5 一律压成「折扣」两个字，看不到到底是 50% 还是 30%。
   * 现在按倍率如实算：0.5 → `50%`、0.3 → `30%`、0 → `免费`、上传 2 倍 → `2X`（可叠加）。
   */
  promotionLabel(): string {
    const parts: string[] = [];
    if (this.downloadFactor <= 0) {
      parts.push('免费');
    } else if (this.downloadFactor < 1) {
      const pct: number = Math.round(this.downloadFactor * 100);
      if (pct > 0 && pct < 100) {
        parts.push(`${pct}%`);
      }
    }
    if (this.uploadFactor > 1) {
      const up: number = Math.round(this.uploadFactor * 10) / 10;
      parts.push(`${up}X`);
    }
    return parts.join(' ');
  }

  /** 促销档次（筛选用）：免费 / 折扣 / 2X */
  promotionTier(): string {
    if (this.downloadFactor <= 0) {
      return '免费';
    }
    if (this.downloadFactor < 1) {
      return '折扣';
    }
    if (this.uploadFactor > 1) {
      return '2X';
    }
    return '无促销';
  }

  /**
   * 制作组（小组名）：取标题**最后一个连字符**后的 token。
   *
   * 样本：
   *  `...2160p WEB-DL.H265 AAC-CSWEB`      → CSWEB
   *  `...DTS-HD.MA.2.0-FULLBRUTALITY`      → FULLBRUTALITY（前面的 DTS-HD 不误判）
   *  `Spider-Man.2002.1080p.x264-SPARKS`   → SPARKS（中间的连字符不误判）
   *  `...H.265-10bit`                      → 空（命中黑名单）
   */
  group(): string {
    const t: string = this.title.trim();
    const i: number = t.lastIndexOf('-');
    if (i <= 0 || i >= t.length - 1) {
      return '';
    }
    let g: string = t.substring(i + 1).trim();
    // 发布组常写成「发布者@制作组」（BiVerse@ADWeb、KKYY@CHDBits、AOC@BiVerse），
    // @ 前面是发布者 / 站点前缀，真正的小组名取 @ 之后那一段。
    const at: number = g.lastIndexOf('@');
    if (at >= 0 && at < g.length - 1) {
      g = g.substring(at + 1).trim();
    }
    // 站点标题常把小组和中文描述连在一起，例如：
    //  KILL BILL ... DTS-HD MA 5.1-DIY@TTG ⑤音频 粤语简繁中字
    // 这时只取小组 token（@ 之后的第一段），空格 / 中文 / 括号都算分隔，
    // 否则后面整段因含空格被判为无效，标签里就看不到 TTG 了。
    const seg: number = g.search(/[\s\u4e00-\u9fa5（(【\[]/);
    if (seg > 0) {
      g = g.substring(0, seg).trim();
    }
    // 小组名一般是 3~24 位、不含空格；-HD / -DV 这种 2 位基本是编码残渣
    if (g.length < 3 || g.length > 24) {
      return '';
    }
    if (/\s/.test(g)) {
      return '';
    }
    if (/^[0-9]+$/.test(g)) {
      return '';
    }
    if (/^[0-9]{3,4}[pi]$/i.test(g)) {
      return '';
    }
    if (/^(x264|x265|h264|h265|avc|hevc|aac|ac3|eac3|dd|ddp|dts|truehd|atmos|hdr|sdr|dv|web|dl|webdl|bluray|remux|10bit|8bit)$/i.test(g)) {
      return '';
    }
    return g;
  }

  /**
   * 效果 / 字幕类标签（MP labels 去掉分辨率、来源、编码之后剩下的）。
   * 典型值：中字、国语、粤语、特效、官方、DIY、HDR、杜比视界…
   */
  extraLabels(): string[] {
    const out: string[] = [];
    for (const raw of this.labels) {
      const text: string = raw.trim();
      if (text.length === 0 || out.indexOf(text) >= 0) {
        continue;
      }
      const low: string = text.toLowerCase();
      if (/(2160p|4k|uhd|1080[pi]|720[pi]|480[pi]|blu-?ray|bdrip|bdmv|web-?dl|webrip|hdtv|remux|h\.?26[45]|x\.?26[45]|hevc|avc|av1)/.test(low)) {
        continue;
      }
      out.push(text);
    }
    return out;
  }

  /** 标签序列里是否已有某个语义（用于避免「2160p」和「4K」重复出现） */
  private hasIn(list: string[], keys: string[]): boolean {
    for (const item of list) {
      const low: string = item.toLowerCase();
      for (const k of keys) {
        if (low.indexOf(k) >= 0) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * 免费剩余时长（纯文本，如 `1小时20分钟` / `1天23小时12分钟`），拿不到返回空串。
   *
   * 四级兜底，缺哪级往下走：
   * 1. MP 直接给的 `freedate_diff`（网页那个绿色标签，多数站点走这条）；
   * 2. 自己按 `freedate` 截止时间算 —— **部分站点只给截止时间、diff 是空的**，
   *    以前这里就断了，「免费」后面什么都没有（用户反馈「网站有时长、App 没有」）；
   * 3. labels 里带的「剩余时间：X」（个别站在 label 文本里给）；
   * 4. description 开头的时长（服务端解析器偶尔把它当正文抓下来）。
   */
  freeRemainingText(): string {
    const diff: string = this.freeTimeDiff.trim();
    if (/[0-9]/.test(diff)) {
      return diff;
    }
    const byDate: string = this.freeDateRemaining();
    if (byDate.length > 0) {
      return byDate;
    }
    for (const l of this.labels) {
      const t: string = l.trim();
      if (t.indexOf('剩余') >= 0 && /[0-9]/.test(t)) {
        const full: number = t.indexOf('：');
        const half: number = t.indexOf(':');
        const cut: number = full >= 0 ? full : half;
        return cut >= 0 ? t.substring(cut + 1).trim() : t;
      }
    }
    const d: string = this.description.trim();
    const m: RegExpMatchArray | null = d.match(/^(\d+\s*[天日])?\s*(\d+\s*(?:小时|时))?\s*(\d+\s*(?:分钟|分))?/);
    if (m === null) {
      return '';
    }
    const t: string = m[0].trim();
    if (t.length === 0 || !/[0-9]/.test(t) || !/[天日时分钟]/.test(t)) {
      return '';
    }
    return t;
  }

  /**
   * 按 [freeDate] 截止时间算剩余时长。
   *
   * MP 返回的是不带时区的本地时间（`2026-11-23 19:35:00`），按本机时区解；
   * 解析不出来、或已经过期（≤1 分钟）一律返回空，宁可少显示也不显示错的时间。
   */
  freeDateRemaining(): string {
    const raw: string = this.freeDate.trim();
    if (raw.length === 0) {
      return '';
    }
    // 有的站点把「限时1时20分」原样塞进 freedate（不是时间戳），
    // 这种直接用文案，别去解析日期（日期串里不会有 天/时/分 这些字）
    let asText: string = raw;
    if (asText.indexOf('限时') === 0) {
      asText = asText.substring(2).trim();
    }
    if (asText.indexOf('剩余时间：') === 0) {
      asText = asText.substring(5).trim();
    }
    if (/[0-9]/.test(asText) && /[天日时分钟]/.test(asText)) {
      return asText;
    }
    const ms: number = Date.parse(raw.replace(' ', 'T'));
    if (isNaN(ms)) {
      return '';
    }
    const left: number = ms - Date.now();
    if (left <= 60000) {
      return '';
    }
    const mins: number = Math.floor(left / 60000);
    const days: number = Math.floor(mins / 1440);
    const hours: number = Math.floor((mins % 1440) / 60);
    const rest: number = mins % 60;
    let out: string = '';
    if (days > 0) {
      out += `${days}天`;
    }
    if (hours > 0) {
      out += `${hours}小时`;
    }
    if (rest > 0 || out.length === 0) {
      out += `${rest}分钟`;
    }
    return out;
  }

  /** 带「剩余时间：」前缀的完整文案（个别页面还在用它） */
  freeTimeLabel(): string {
    const t: string = this.freeRemainingText();
    return t.length > 0 ? `剩余时间：${t}` : '';
  }

  /**
   * 只取时长本身，并把「小时/分钟」压成「时/分」，
   * 供「免费·剩2时9分」这种紧凑标签使用。
   */
  freeTimeShort(): string {
    return this.freeRemainingText()
      .replace(/小时/g, '时')
      .replace(/分钟/g, '分')
      .replace(/ /g, '')
      .trim();
  }

  /** 是否免费（倍率为 0，或站点 labels 里给了「免费」） */
  isFreeLike(): boolean {
    if (this.downloadFactor <= 0) {
      return true;
    }
    for (const l of this.labels) {
      if (l.indexOf('免费') >= 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 卡片上的完整标签序列（对齐 MP 搜索结果）：
   * 优先原样展示 MP labels（官方/国语/中字/禁转…）→ 促销 → H&R → 分辨率 → 来源 →
   * 制作组（最后）。分辨率/来源若已被 labels 覆盖就不重复加。
   *
   * 「免费」和「剩余时间」两条合并成一条 `免费·剩2时9分`：
   * 用户反馈分开看两截、免费没写到期时间，合起来一眼就够。
   */
  badges(): string[] {
    const out: string[] = [];
    const add = (v: string): void => {
      const t: string = v.trim();
      if (t.length === 0) {
        return;
      }
      const low: string = t.toLowerCase();
      for (const x of out) {
        if (x.toLowerCase() === low) {
          return;
        }
      }
      out.push(t);
    };

    // 用户要求：**免费 / 免费时长永远排最前面**，一眼看到还能白嫖多久（对齐 MP 网页）。
    // 时长按 freeRemainingText 四级兜底（freedate_diff → freedate 自算 → labels → description），
    // 站点只给截止时间时也能算出「还剩多久」。
    const duration: string = this.freeRemainingText();
    if (this.isFreeLike()) {
      add('免费');
      if (duration.length > 0) {
        add(duration);
      }
    } else {
      add(this.promotionLabel());
    }

    // 核心原则：**优先原样展示 MP labels**（官方 / 国语 / 中字 / 禁转 …），
    // 这是 MP 网页版给用户看的标签，App 不再自作主张过滤或重排，保证和网页一致。
    // 特判三处：纯「免费」和「剩余时间：X」跳过——上面已经统一放到最前面；
    // 小组名跳过——部分站点把制作组当普通标签塞进 labels 且排在前面，
    // 而项目约定「小组永远排最后」，所以这里剔掉，交给下面 add(group) 统一补在末尾。
    const groupName: string = this.group();
    for (const l of this.labels) {
      const t: string = l.trim();
      if (t === '免费' || (t.indexOf('剩余') >= 0 && /[0-9]/.test(t))) {
        continue;
      }
      if (groupName.length > 0 && t.toLowerCase() === groupName.toLowerCase()) {
        continue;
      }
      add(t);
    }
    // H&R 兜底：MP labels 没给时补上。
    if (this.hitAndRun) {
      add('H&R');
    }
    // 分辨率 / 来源：labels 已经覆盖就不重复加。
    const res: string = this.resolution();
    if (res !== '其他' &&
      !this.hasIn(out, ['4k', '2160p', 'uhd', '1080p', '1080i', '720p', '720i', '480p'])) {
      add(res);
    }
    const q: string = this.quality();
    if (q !== '其他' &&
      !this.hasIn(out, ['blu-ray', 'bluray', 'bdrip', 'bdmv', 'web-dl', 'webdl', 'webrip', 'hdtv', 'remux'])) {
      add(q);
    }
    // 制作组（如 TTG）按用户要求放到最后。
    add(this.group());
    // 上限放宽到 12：MP 网页一条种子常有 8~10 个标签，8 个会把官方/免费时长挤掉。
    return out.slice(0, 12);
  }

  /**
   * 副标题行：优先用站点给的 description（站点种子页那一行）。
   *
   * MP 的搜索接口（search/media）通常不返回 description，只有 browse 接口才带，
   * 所以为空时用「来源 · 编码」兜底，别让卡片留一条空白。
   */
  subtitle(): string {
    const d: string = this.description.trim();
    if (d.length > 0) {
      return d;
    }
    const parts: string[] = [];
    if (this.group().length > 0) {
      parts.push(this.group());
    }
    const q: string = this.quality();
    if (q !== '其他') {
      parts.push(q);
    }
    const c: string = this.codec();
    if (c !== '其他') {
      parts.push(c);
    }
    return parts.join(' · ');
  }

  resolution(): string {
    const t: string = this.title.toLowerCase();
    if (/(2160p|4k|uhd)/.test(t)) {
      return '4K';
    }
    if (/1080[pi]/.test(t)) {
      return '1080p';
    }
    if (/720[pi]/.test(t)) {
      return '720p';
    }
    if (/480[pi]/.test(t)) {
      return '480p';
    }
    return '其他';
  }

  quality(): string {
    const t: string = this.title.toLowerCase();
    if (/remux/.test(t)) {
      return 'REMUX';
    }
    if (/blu-?ray|bdrip|bdmv/.test(t)) {
      return 'BluRay';
    }
    if (/web-?dl/.test(t)) {
      return 'WEB-DL';
    }
    if (/webrip/.test(t)) {
      return 'WEBRip';
    }
    if (/hdtv/.test(t)) {
      return 'HDTV';
    }
    return '其他';
  }

  codec(): string {
    const t: string = this.title.toLowerCase();
    if (/(h\.?265|x\.?265|hevc)/.test(t)) {
      return 'H.265';
    }
    if (/(h\.?264|x\.?264|avc)/.test(t)) {
      return 'H.264';
    }
    if (/av1/.test(t)) {
      return 'AV1';
    }
    return '其他';
  }
}

export enum ResourceSortField {
  RELEVANCE,
  SEEDERS,
  PUBLISH_TIME,
  SIZE,
  SITE
}

export function resourceSortFieldLabel(f: ResourceSortField): string {
  switch (f) {
    case ResourceSortField.RELEVANCE:
      return '默认';
    case ResourceSortField.SEEDERS:
      return '做种数';
    case ResourceSortField.PUBLISH_TIME:
      return '发布时间';
    case ResourceSortField.SIZE:
      return '文件大小';
    case ResourceSortField.SITE:
      return '站点';
    default:
      return '默认';
  }
}

export class ResourceFilter {
  /** 多选：空数组 = 不限（“全部”） */
  site: string[] = [];
  resolution: string[] = [];
  quality: string[] = [];
  codec: string[] = [];
  /** 效果 / 字幕标签（中字、国语、特效…）：命中任意一个即通过 */
  subtitle: string[] = [];
  /** 制作组（小组名） */
  group: string[] = [];
  /** 促销档次：免费 / 折扣 / 2X */
  promotion: string[] = [];
  promotionOnly: boolean = false;
  hideHitAndRun: boolean = false;
  sortField: ResourceSortField = ResourceSortField.RELEVANCE;
  descending: boolean = true;

  activeCount(): number {
    let n: number = 0;
    if (this.site.length > 0) {
      n++;
    }
    if (this.resolution.length > 0) {
      n++;
    }
    if (this.quality.length > 0) {
      n++;
    }
    if (this.codec.length > 0) {
      n++;
    }
    if (this.subtitle.length > 0) {
      n++;
    }
    if (this.group.length > 0) {
      n++;
    }
    if (this.promotion.length > 0) {
      n++;
    }
    if (this.promotionOnly) {
      n++;
    }
    if (this.hideHitAndRun) {
      n++;
    }
    return n;
  }

  apply(list: MpResource[]): MpResource[] {
    const filtered: MpResource[] = [];
    for (const item of list) {
      if (this.site.length > 0 && this.site.indexOf(item.siteName) < 0) {
        continue;
      }
      if (this.resolution.length > 0 && this.resolution.indexOf(item.resolution()) < 0) {
        continue;
      }
      if (this.quality.length > 0 && this.quality.indexOf(item.quality()) < 0) {
        continue;
      }
      if (this.codec.length > 0 && this.codec.indexOf(item.codec()) < 0) {
        continue;
      }
      // 字幕 / 效果：labels 命中任意一个所选标签即可（多选是「或」，和 MP 一致）
      if (this.subtitle.length > 0) {
        let hit: boolean = false;
        const extras: string[] = item.extraLabels();
        for (const s of this.subtitle) {
          if (extras.indexOf(s) >= 0) {
            hit = true;
            break;
          }
        }
        if (!hit) {
          continue;
        }
      }
      if (this.group.length > 0 && this.group.indexOf(item.group()) < 0) {
        continue;
      }
      if (this.promotion.length > 0 && this.promotion.indexOf(item.promotionTier()) < 0) {
        continue;
      }
      if (this.promotionOnly && !item.isFree()) {
        continue;
      }
      if (this.hideHitAndRun && item.hitAndRun) {
        continue;
      }
      filtered.push(item);
    }
    if (this.sortField === ResourceSortField.RELEVANCE) {
      return filtered;
    }
    const sorted: MpResource[] = filtered.slice(0);
    sorted.sort((a: MpResource, b: MpResource): number => {
      let cmp: number = 0;
      if (this.sortField === ResourceSortField.SEEDERS) {
        cmp = a.seeders - b.seeders;
      } else if (this.sortField === ResourceSortField.PUBLISH_TIME) {
        cmp = a.pubDateMs - b.pubDateMs;
      } else if (this.sortField === ResourceSortField.SIZE) {
        cmp = a.sizeBytes - b.sizeBytes;
      } else if (this.sortField === ResourceSortField.SITE) {
        cmp = a.siteName.toLowerCase() < b.siteName.toLowerCase() ? -1 :
          (a.siteName.toLowerCase() > b.siteName.toLowerCase() ? 1 : 0);
      }
      return cmp;
    });
    if (this.descending) {
      sorted.reverse();
    }
    return sorted;
  }
}

/** MP 下载器 */
export class MpDownloader {
  name: string = '';
  type: string = '';

  constructor(name: string = '', type: string = '') {
    this.name = name;
    this.type = type;
  }
}

/** MP 保存路径 */
export class MpSavePath {
  name: string = '';
  savePath: string = '';
  storage: string = '';

  constructor(name: string = '', savePath: string = '', storage: string = '') {
    this.name = name;
    this.savePath = savePath;
    this.storage = storage;
  }
}

/** MP 订阅（与网页端同一份数据） */
export class MpSubscribe {
  id: number = 0;
  name: string = '';
  year: string = '';
  type: string = '';
  season: number = -1;
  posterUrl: string = '';
  vote: number = 0;
  totalEpisode: number = 0;
  lackEpisode: number = 0;
  completedEpisode: number = -1;
  state: string = '';
  lastUpdate: string = '';
  sites: number[] = [];
  downloader: string = '';
  bestVersion: boolean = false;
  savePath: string = '';

  // ---- 订阅设置（与 MP 网页「编辑订阅」一一对应） ----
  /** 搜索关键词，空 = 用订阅名称 */
  keyword: string = '';
  quality: string = '';
  resolution: string = '';
  effect: string = '';
  /** 搜索周期（小时）；<=0 表示跟随系统 */
  searchInterval: number = -1;
  include: string = '';
  exclude: string = '';
  /** 优先级过滤规则组名称 */
  filterGroups: string[] = [];
  mediaCategory: string = '';
  customWords: string = '';
  searchImdbId: boolean = false;

  // 媒体身份（打开详情 / 整条回传时要用，少传会被 v2.9 的整覆盖写空）
  tmdbId: number = 0;
  doubanId: string = '';
  bangumiId: number = 0;
  posterRaw: string = '';
  mediaSource: string = '';
  mediaIdRaw: string = '';

  stateLabel(): string {
    const s: string = this.state.toUpperCase();
    if (s === 'R') {
      return '订阅中';
    }
    if (s === 'P') {
      return '已暂停';
    }
    if (s === 'S') {
      return '已停止';
    }
    if (s === 'N') {
      return '新建';
    }
    return this.state;
  }

  progressText(): string {
    if (this.type !== '电视剧') {
      return '电影';
    }
    if (this.totalEpisode <= 0) {
      return '集数未知';
    }
    const done: number = this.completedEpisode >= 0
      ? this.completedEpisode
      : Math.max(this.totalEpisode - this.lackEpisode, 0);
    return `${done} / ${this.totalEpisode} 集`;
  }

  progress(): number {
    if (this.totalEpisode <= 0) {
      return 0;
    }
    const done: number = this.completedEpisode >= 0
      ? this.completedEpisode
      : Math.max(this.totalEpisode - this.lackEpisode, 0);
    const p: number = done / this.totalEpisode;
    if (p < 0) {
      return 0;
    }
    if (p > 1) {
      return 1;
    }
    return p;
  }
}

/** 发现页的一个入口（豆瓣热映 / TMDB 趋势 …） */
export class MpDiscoverChannel {
  key: string = '';
  title: string = '';
  subtitle: string = '';
  /** MP 接口路径（不含前缀） */
  path: string = '';
  /** 部分接口需要额外参数 */
  extraQuery: string = '';
  supportsPaging: boolean = true;
  icon: string = '';

  constructor(key: string = '', title: string = '', subtitle: string = '', path: string = '',
    extraQuery: string = '', supportsPaging: boolean = true, icon: string = '') {
    this.key = key;
    this.title = title;
    this.subtitle = subtitle;
    this.path = path;
    this.extraQuery = extraQuery;
    this.supportsPaging = supportsPaging;
    this.icon = icon;
  }
}

/**
 * 发现频道表（对应安卓 vm/MpViewModel.kt 的 MpChannels）。
 * key 即 MP 接口路径段：api/v1/recommend/{key}。
 */
export const MP_CHANNELS: MpDiscoverChannel[] = [
  new MpDiscoverChannel('douban_showing', '豆瓣热映', '正在上映', 'douban_showing'),
  new MpDiscoverChannel('douban_movie_hot', '热门电影', '豆瓣实时热门', 'douban_movie_hot'),
  new MpDiscoverChannel('douban_tv_hot', '热门剧集', '豆瓣实时热门', 'douban_tv_hot'),
  new MpDiscoverChannel('douban_movies', '豆瓣电影', '按评价排序', 'douban_movies', 'sort=R'),
  new MpDiscoverChannel('douban_tvs', '豆瓣剧集', '按评价排序', 'douban_tvs', 'sort=R'),
  new MpDiscoverChannel('douban_movie_top250', 'TOP250', '豆瓣电影榜', 'douban_movie_top250'),
  new MpDiscoverChannel('douban_tv_weekly_chinese', '华语口碑', '每周口碑榜', 'douban_tv_weekly_chinese'),
  new MpDiscoverChannel('douban_tv_weekly_global', '全球口碑', '每周口碑榜', 'douban_tv_weekly_global'),
  new MpDiscoverChannel('douban_tv_animation', '番剧', '豆瓣动画榜', 'douban_tv_animation'),
  new MpDiscoverChannel('tmdb_trending', 'TMDB 趋势', '本周流行', 'tmdb_trending'),
  new MpDiscoverChannel('tmdb_movies', 'TMDB 电影', '按热度', 'tmdb_movies', 'sort_by=popularity.desc'),
  new MpDiscoverChannel('tmdb_tvs', 'TMDB 剧集', '按热度', 'tmdb_tvs', 'sort_by=popularity.desc')
];

/**
 * MoviePilot 仪表盘的媒体库统计（`/api/v1/dashboard/statistic`）。
 */
export class MpStatistic {
  movies: number = 0;
  tvs: number = 0;
  episodes: number = 0;
  users: number = 0;
  /** MP 部分版本不返回音乐数量，缺字段时保持 0（仪表盘「音乐」一栏照常显示） */
  music: number = 0;
  moviesThisMonth: number = 0;
  tvsThisMonth: number = 0;
  episodesThisMonth: number = 0;
  musicThisMonth: number = 0;

  isEmpty(): boolean {
    return this.movies === 0 && this.tvs === 0 && this.episodes === 0;
  }
}

/**
 * MoviePilot 本地存储空间（`/api/v1/dashboard/storage`）：
 * 按媒体库实际挂载的盘统计，比从下载器 RPC 读 free_space 更准
 * （下载器可能指向别的目录、同盘多实例还会重复），所以仪表盘优先用这份。
 */
export class MpStorage {
  /** 总容量（字节） */
  totalBytes: number = 0;
  /** 已用（字节） */
  usedBytes: number = 0;

  freeBytes(): number {
    const free: number = this.totalBytes - this.usedBytes;
    return free > 0 ? free : 0;
  }

  isValid(): boolean {
    return this.totalBytes > 0;
  }
}

/** MP 仪表盘「实时速率」（dashboard/downloader）；speed 为字节/秒，size 为字节。 */
export class MpDownloaderInfo {
  downloadSpeed: number = 0;
  uploadSpeed: number = 0;
  downloadSize: number = 0;
  uploadSize: number = 0;
  freeSpace: number = 0;

  /**
   * MP 是否真的没给数据。用「五项都不 > 0」而不是「五项都 === 0」：
   * 字段缺失时解析可能落到 NaN / undefined，`=== 0` 判不出来，会把一份空数据
   * 当成「有数据」，导致卡片整片 0 B 却不走兜底。
   */
  isEmpty(): boolean {
    return !(this.downloadSpeed > 0 || this.uploadSpeed > 0 ||
      this.downloadSize > 0 || this.uploadSize > 0 || this.freeSpace > 0);
  }
}

/** MP 仪表盘内存；usage 是进程占系统内存百分比。 */
export class MpMemoryInfo {
  total: number = 0;
  used: number = 0;
  cached: number = 0;
  available: number = 0;
  usage: number = 0;
}

/** MP 仪表盘系统信息（仅登录管理员 JWT 可读）。 */
export class MpSystemInfo {
  hostname: string = '';
  operatingSystem: string = '';
  runtime: string = '';
  version: string = '';

  isEmpty(): boolean {
    return this.hostname.length === 0 && this.operatingSystem.length === 0 &&
      this.runtime.length === 0 && this.version.length === 0;
  }
}

/** CPU 本地采样；时间戳用于 1m / 5m / 15m 均值。 */
export class CpuSample {
  atMs: number;
  value: number;

  constructor(atMs: number, value: number) {
    this.atMs = atMs;
    this.value = value;
  }
}

/** 内存本地采样；三条序列共用同一时间戳。 */
export class MemorySample {
  atMs: number;
  used: number;
  cached: number;
  available: number;

  constructor(atMs: number, used: number, cached: number, available: number) {
    this.atMs = atMs;
    this.used = used;
    this.cached = cached;
    this.available = available;
  }
}
