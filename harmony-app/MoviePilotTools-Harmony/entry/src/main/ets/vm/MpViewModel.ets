import { MpServer, MpMedia, MpResource, MpDownloader, MpDownloaderInfo, MpSavePath, MpSubscribe,
  MpStatistic, MpDiscoverChannel, ResourceFilter, MP_CHANNELS, MpStorage, MpMemoryInfo, MpSystemInfo,
  CpuSample, MemorySample } from '../model/MpModels';
import { MpSite, MpSiteUserData, MpSiteCategory, SiteSort } from '../model/MpSiteModels';
import { MoviePilotClient, Person } from '../net/MoviePilotClient';
import { SiteIconStore, SiteIcon } from '../net/SiteIconStore';
import { MediaPosterCache, PosterRequest } from '../net/MediaPosterCache';
import { ApiException } from '../net/HttpClient';
import { EndpointResolver } from '../net/EndpointResolver';
import { ObservableStore, ToastHub } from './StoreBase';
import { ConfigStore } from '../data/ConfigStore';
import { PersistedState, HeroCache, HeroCacheItem } from '../model/Settings';
import { Endpoint } from '../model/Models';
import { logInfo, logWarn, logSeek, jStr, jNum, jBool, jObj, jArr } from '../common/AppConstants';

/**
 * MoviePilot 视图模型（对应安卓 vm/MpViewModel.kt）：
 * 发现频道分页瀑布、搜索、详情、跨站资源搜索（流式批次回调）、投递、订阅管理。
 * App 级单例；状态按「不可变快照」更新（与 AppViewModel 同一套约定），
 * 页面订阅后在回调里把 VM 的最新快照赋给 @State。
 */
/**
 * 站点种子详情页的 MP 侧内容（对应安卓 MpViewModel.TorrentMediaInfo）：
 * 识别出的媒体 + 演职员名单。识别失败时两者都为空，页面退回站点数据。
 */
export class TorrentMediaInfo {
  media: MpMedia | null = null;
  creditNames: string[] = [];

  constructor(media: MpMedia | null = null, names: string[] = []) {
    this.media = media;
    this.creditNames = names;
  }
}

/**
 * 「站点」页的全部状态。
 *
 * 全部收在一个字段里而不是往 MpState 里加十几个散字段：那个类有 30 多处 copy()，
 * 每加一个字段就多一个漏掉的机会，漏一次就是「某个操作之后状态莫名清空」这种很难复现的 bug。
 * 放在一个字段里，只要不整体覆盖它就不会丢。
 */
export class MpSiteState {
  // ---- 站点列表 ----
  sites: MpSite[] = [];
  /** siteId → 个人数据（MP 按 domain 返回，这里已按站点对好） */
  userData: Map<number, MpSiteUserData> = new Map();
  loading: boolean = false;
  loaded: boolean = false;
  error: string = '';
  /** 403/401：当前 API Token 不是管理员，站点接口一律拒绝 */
  permissionDenied: boolean = false;
  /** 404：MP 版本太老，没有站点接口 */
  degraded: boolean = false;

  // ---- 站点详情（种子浏览） ----
  openSite: MpSite | null = null;
  searchInput: string = '';
  /** 已提交的关键词（和输入框分开，避免边打字边发请求） */
  keyword: string = '';
  categories: MpSiteCategory[] = [];
  /** 当前选中的分类，**单选**：点一个换一个，再点同一个 = 退回全部 */
  selectedCat: string = '';
  sort: SiteSort = SiteSort.LATEST;
  /** 「全部」第一页的种子 key，用来判断站点到底有没有真的按 cat 过滤 */
  allPageKeys: string[] = [];
  /** 选了分类但站点没过滤 → UI 如实提示该站不支持分类筛选 */
  catIgnored: boolean = false;
  torrents: MpResource[] = [];
  /** 资源 key → 海报地址（识别是异步的，卡片先出、图后补） */
  posters: Map<string, string> = new Map();
  browsing: boolean = false;
  /** 已经等了多少秒（站点浏览可能 5~30s，要告诉用户不是在卡死） */
  elapsedSeconds: number = 0;
  browseError: string = '';
  page: number = 0;
  hasMore: boolean = true;
  /** 连续几页没有新增（站点对越界 page 回落首页时防止无限翻页） */
  stalledPages: number = 0;
  /** 海报识别连续失败批次数，连续 3 批就彻底关掉 */
  postersDisabled: boolean = false;

  copy(): MpSiteState {
    const c: MpSiteState = new MpSiteState();
    c.sites = this.sites;
    c.userData = this.userData;
    c.loading = this.loading;
    c.loaded = this.loaded;
    c.error = this.error;
    c.permissionDenied = this.permissionDenied;
    c.degraded = this.degraded;
    c.openSite = this.openSite;
    c.searchInput = this.searchInput;
    c.keyword = this.keyword;
    c.categories = this.categories;
    c.selectedCat = this.selectedCat;
    c.sort = this.sort;
    c.allPageKeys = this.allPageKeys;
    c.catIgnored = this.catIgnored;
    c.torrents = this.torrents;
    c.posters = this.posters;
    c.browsing = this.browsing;
    c.elapsedSeconds = this.elapsedSeconds;
    c.browseError = this.browseError;
    c.page = this.page;
    c.hasMore = this.hasMore;
    c.stalledPages = this.stalledPages;
    c.postersDisabled = this.postersDisabled;
    return c;
  }

  userDataOf(siteId: number): MpSiteUserData | null {
    const v: MpSiteUserData | undefined = this.userData.get(siteId);
    return v === undefined ? null : v;
  }

  /** 展示顺序：客户端排序，只作用于已经翻下来的那几页 */
  sortedTorrents(): MpResource[] {
    const out: MpResource[] = this.torrents.slice(0);
    const s: SiteSort = this.sort;
    out.sort((a: MpResource, b: MpResource): number => {
      if (s === SiteSort.SIZE) {
        return b.sizeBytes - a.sizeBytes;
      }
      if (s === SiteSort.SEEDERS) {
        return b.seeders - a.seeders;
      }
      if (s === SiteSort.GRABS) {
        return b.grabs - a.grabs;
      }
      return b.pubDateMs - a.pubDateMs;
    });
    return out;
  }

  posterOf(resource: MpResource): string {
    const v: string | undefined = this.posters.get(resource.key);
    return v === undefined ? '' : v;
  }
}

/** 订阅活动 / 文件统计弹窗内容 */
export class SubscribePanel {
  title: string = '';
  loading: boolean = false;
  lines: string[] = [];
  error: string = '';

  constructor(title: string = '') {
    this.title = title;
  }
}

/**
 * 仪表盘实时数据（速率 / CPU / 内存 / 系统）。
 * 单独一个字段，避免 MpState.copy() 三十多处漏更新；失败只改错误文案、保留旧曲线。
 */
export class DashboardLiveState {
  downloader: MpDownloaderInfo = new MpDownloaderInfo();
  speedError: string = '';
  lastSpeedAt: number = 0;
  cpu: number = NaN;
  cpuSamples: CpuSample[] = [];
  memory: MpMemoryInfo | null = null;
  memorySamples: MemorySample[] = [];
  system: MpSystemInfo | null = null;
  systemDenied: boolean = false;
  systemError: string = '';

  copy(): DashboardLiveState {
    const c: DashboardLiveState = new DashboardLiveState();
    c.downloader = this.downloader;
    c.speedError = this.speedError;
    c.lastSpeedAt = this.lastSpeedAt;
    c.cpu = this.cpu;
    c.cpuSamples = this.cpuSamples;
    c.memory = this.memory;
    c.memorySamples = this.memorySamples;
    c.system = this.system;
    c.systemDenied = this.systemDenied;
    c.systemError = this.systemError;
    return c;
  }

  cpuAverage(windowMs: number, nowMs: number = Date.now()): number {
    let sum: number = 0;
    let count: number = 0;
    for (const s of this.cpuSamples) {
      if (nowMs - s.atMs <= windowMs) {
        sum += s.value;
        count++;
      }
    }
    return count === 0 ? NaN : sum / count;
  }
}

export class MpState {
  servers: MpServer[] = [];
  activeServerId: string | null = null;
  channel: MpDiscoverChannel = MP_CHANNELS[0];
  items: MpMedia[] = [];
  page: number = 1;
  loading: boolean = false;
  loadingMore: boolean = false;
  hasMore: boolean = true;
  error: string = '';

  // 搜索
  searchQuery: string = '';
  searchResults: MpMedia[] = [];
  searching: boolean = false;
  searchActive: boolean = false;

  // 详情
  detail: MpMedia | null = null;
  detailLoading: boolean = false;
  credits: Person[] = [];

  // 资源
  resources: MpResource[] = [];
  resourcesLoading: boolean = false;
  resourceError: string = '';
  /** 是否已经手动发起过搜索：用来区分「还没搜」和「搜了但没结果」 */
  resourceSearched: boolean = false;
  searchStage: string = '';
  filter: ResourceFilter = new ResourceFilter();
  downloaders: MpDownloader[] = [];
  savePaths: MpSavePath[] = [];

  // 订阅
  subscribes: MpSubscribe[] = [];
  subscribesLoading: boolean = false;
  /** 订阅设置里的「优先级规则组」选项 */
  subscribeRuleGroups: string[] = [];
  /** MP 系统设置里勾选的订阅站点 id；null = 这台 MP 没这项设置（不限制） */
  rssSiteIds: number[] | null = null;
  /** 订阅活动 / 文件统计弹窗；null = 没打开 */
  subscribePanel: SubscribePanel | null = null;

  // 仪表盘媒体库统计
  stats: MpStatistic | null = null;
  statsLoading: boolean = false;
  statsError: string = '';
  /** 挂载盘真实容量（来自 MP /dashboard/storage）；null = 没拿到，仪表盘退回下载器剩余空间 */
  storage: MpStorage | null = null;

  /** 仪表盘实时速率 / CPU / 内存 / 系统信息 */
  live: DashboardLiveState = new DashboardLiveState();

  /** 首屏 Hero 海报轮播数据（离线首屏用；来自持久化的 heroCache） */
  heroCache: HeroCache | null = null;

  /** 站点域全部状态（见 MpSiteState 注释：整体一个字段，避免 copy 漏字段） */
  site: MpSiteState = new MpSiteState();

  /** 不可变快照：每次状态变更生成新对象（数组字段按引用共享，整体替换） */
  copy(): MpState {
    const c: MpState = new MpState();
    c.servers = this.servers;
    c.activeServerId = this.activeServerId;
    c.channel = this.channel;
    c.items = this.items;
    c.page = this.page;
    c.loading = this.loading;
    c.loadingMore = this.loadingMore;
    c.hasMore = this.hasMore;
    c.error = this.error;
    c.searchQuery = this.searchQuery;
    c.searchResults = this.searchResults;
    c.searching = this.searching;
    c.searchActive = this.searchActive;
    c.detail = this.detail;
    c.detailLoading = this.detailLoading;
    c.credits = this.credits;
    c.resources = this.resources;
    c.resourcesLoading = this.resourcesLoading;
    c.resourceError = this.resourceError;
    c.resourceSearched = this.resourceSearched;
    c.searchStage = this.searchStage;
    c.filter = this.filter;
    c.downloaders = this.downloaders;
    c.savePaths = this.savePaths;
    c.subscribes = this.subscribes;
    c.subscribesLoading = this.subscribesLoading;
    c.subscribeRuleGroups = this.subscribeRuleGroups;
    c.rssSiteIds = this.rssSiteIds;
    c.subscribePanel = this.subscribePanel;
    c.stats = this.stats;
    c.statsLoading = this.statsLoading;
    c.statsError = this.statsError;
    c.storage = this.storage;
    c.live = this.live;
    c.heroCache = this.heroCache;
    c.site = this.site;
    return c;
  }

  server(): MpServer | null {
    if (this.activeServerId === null) {
      return null;
    }
    for (const s of this.servers) {
      if (s.id === this.activeServerId) {
        return s;
      }
    }
    return null;
  }

  filteredResources(): MpResource[] {
    return this.filter.apply(this.resources);
  }

  isSubscribed(media: MpMedia | null): boolean {
    if (media === null) {
      return false;
    }
    for (const sub of this.subscribes) {
      if (sub.name.toLowerCase() === media.title.toLowerCase() &&
        (media.season <= 0 || sub.season <= 0 || sub.season === media.season)) {
        return true;
      }
    }
    return false;
  }

  sites(): string[] {
    const out: string[] = [];
    for (const r of this.resources) {
      if (out.indexOf(r.siteName) < 0) {
        out.push(r.siteName);
      }
    }
    return out.sort();
  }

  private static resOrder(value: string): number {
    const order: string[] = ['4K', '1080p', '720p', '480p', '其他'];
    const idx: number = order.indexOf(value);
    return idx >= 0 ? idx : order.length;
  }

  resolutions(): string[] {
    const out: string[] = [];
    for (const r of this.resources) {
      if (out.indexOf(r.resolution()) < 0) {
        out.push(r.resolution());
      }
    }
    return out.sort((a: string, b: string): number =>
      MpState.resOrder(a) - MpState.resOrder(b));
  }

  qualities(): string[] {
    const out: string[] = [];
    for (const r of this.resources) {
      if (out.indexOf(r.quality()) < 0) {
        out.push(r.quality());
      }
    }
    return out.sort();
  }

  codecs(): string[] {
    const out: string[] = [];
    for (const r of this.resources) {
      if (out.indexOf(r.codec()) < 0) {
        out.push(r.codec());
      }
    }
    return out.sort();
  }

  /** 效果 / 字幕标签（中字、国语、特效…），按出现次数从多到少排 */
  subtitles(): string[] {
    const values: string[] = [];
    const counts: number[] = [];
    for (const r of this.resources) {
      for (const t of r.extraLabels()) {
        const i: number = values.indexOf(t);
        if (i >= 0) {
          counts[i] = counts[i] + 1;
        } else {
          values.push(t);
          counts.push(1);
        }
      }
    }
    const order: number[] = [];
    for (let i = 0; i < values.length; i++) {
      order.push(i);
    }
    order.sort((a: number, b: number): number => counts[b] - counts[a]);
    const out: string[] = [];
    for (const i of order) {
      out.push(values[i]);
    }
    return out;
  }

  /** 制作组（小组名），有名字的排前面，空的丢掉 */
  groups(): string[] {
    const out: string[] = [];
    for (const r of this.resources) {
      const g: string = r.group();
      if (g.length > 0 && out.indexOf(g) < 0) {
        out.push(g);
      }
    }
    return out.sort();
  }

  /** 促销档次：只看实际出现过的（免费 / 折扣 / 2X），固定顺序 */
  promotions(): string[] {
    const order: string[] = ['免费', '折扣', '2X'];
    const seen: string[] = [];
    for (const r of this.resources) {
      const t: string = r.promotionTier();
      if (t !== '无促销' && seen.indexOf(t) < 0) {
        seen.push(t);
      }
    }
    const out: string[] = [];
    for (const o of order) {
      if (seen.indexOf(o) >= 0) {
        out.push(o);
      }
    }
    return out;
  }
}

/**
 * 站点浏览超时（秒）：MP 的 site/resource 是同步阻塞接口，慢站 43s+ 还没回来也见过。
 * 到点自己收手并给出可执行提示，不让用户干等 130s 的读超时。
 */
const SITE_BROWSE_TIMEOUT_SECONDS: number = 150;

export class MpViewModel extends ObservableStore {
  private static inst: MpViewModel | null = null;

  static getInstance(): MpViewModel {
    if (MpViewModel.inst === null) {
      MpViewModel.inst = new MpViewModel();
    }
    return MpViewModel.inst;
  }

  state: MpState = new MpState();
  private store: ConfigStore = ConfigStore.getInstance();
  private persisted: PersistedState = new PersistedState();
  private statsGeneration: number = 0;
  private statsTimerStarted: boolean = false;
  private statsTimerId: number = -1;
  private statsRetryId: number = -1;
  private statsRetryWait: number = 15000;
  private statsRetryLeft: number = 0;

  // 仪表盘实时数据（速率 5s / CPU 5s / 内存 10s / 系统 60s）
  private liveTickerId: number = -1;
  private liveInFlight: Set<string> = new Set();
  private liveStopped: Set<string> = new Set();
  private liveNextAt: Map<string, number> = new Map();
  private liveFailStreak: Map<string, number> = new Map();

  private constructor() {
    super();
  }

  /** 生成新快照并广播（唯一的状态发布通道） */
  private commit(s: MpState): void {
    this.state = s;
    this.notify();
  }

  /** App 启动时调用一次：恢复服务器配置并拉首屏数据 */
  bootstrap(): void {
    this.persisted = this.store.load();
    const s: MpState = this.state.copy();
    s.servers = this.persisted.mpServers;
    s.activeServerId = this.persisted.activeMpServerId !== null
      ? this.persisted.activeMpServerId
      : (this.persisted.mpServers.length > 0 ? this.persisted.mpServers[0].id : null);
    // 首屏 Hero 海报缓存：先还原给页面，页面立刻有图，再背景刷新
    s.heroCache = this.persisted.heroCache;
    this.commit(s);
    if (s.server() !== null) {
      this.loadDiscover(true);
      this.loadSubscribes(true);
      this.loadStats();
    }
    this.startStatsTimer();
    this.startLiveTicker();
    logInfo('MpViewModel', `bootstrap: ${s.servers.length} 台 MP 服务器`);
  }

  private startStatsTimer(): void {
    if (this.statsTimerStarted) {
      return;
    }
    this.statsTimerStarted = true;
    this.armStatsTimer();
  }

  private armStatsTimer(): void {
    // 媒体库数量变得慢，5 分钟对一次就够，不用跟着下载器刷新
    this.statsTimerId = setTimeout((): void => {
      this.statsTimerId = -1;
      if (this.state.server() !== null) {
        this.loadStats();
      }
      if (this.statsTimerStarted) {
        this.armStatsTimer();
      }
    }, 300000);
  }

  private stopStatsTimer(): void {
    this.statsTimerStarted = false;
    if (this.statsTimerId >= 0) {
      clearTimeout(this.statsTimerId);
      this.statsTimerId = -1;
    }
  }

  /** 进前台（含解锁后回到 App）：恢复轮询并立刻重拉一次，顺带抹掉上次的失败提示 */
  onForeground(): void {
    this.startStatsTimer();
    // 息屏期间的到期时间作废，回前台立刻重拉
    for (const key of this.liveNextAt.keys()) {
      this.liveNextAt.set(key, 0);
    }
    this.startLiveTicker();
    if (this.state.server() !== null) {
      this.loadStats(true);
    }
  }

  /** 退后台：停掉轮询。息屏时 Wi-Fi 常被系统挂起，继续轮询只会刷出一堆假的连接失败 */
  onBackground(): void {
    this.stopStatsTimer();
    this.cancelStatsRetry();
    this.stopLivePolling(false);
  }

  private cancelStatsRetry(): void {
    this.statsRetryLeft = 0;
    if (this.statsRetryId >= 0) {
      clearTimeout(this.statsRetryId);
      this.statsRetryId = -1;
    }
  }

  /** 失败后 15s / 30s / 60s 各补一次，别让一条红字挂到下一个 5 分钟 */
  private scheduleStatsRetry(): void {
    this.cancelStatsRetry();
    this.statsRetryLeft = 3;
    this.statsRetryWait = 15000;
    this.armStatsRetry();
  }

  private armStatsRetry(): void {
    if (this.statsRetryLeft <= 0) {
      return;
    }
    const wait: number = this.statsRetryWait;
    this.statsRetryId = setTimeout((): void => {
      this.statsRetryId = -1;
      this.statsRetryLeft--;
      const client: MoviePilotClient | null = this.client();
      if (client === null) {
        return;
      }
      client.statistic().then((st: MpStatistic): void => {
        const s: MpState = this.state.copy();
        s.stats = st;
        s.statsLoading = false;
        s.statsError = '';
        this.commit(s);
      }).catch((e: Error): void => {
        const s: MpState = this.state.copy();
        s.statsLoading = false;
        s.statsError = this.humanizeStatsError(e);
        this.commit(s);
        this.statsRetryWait = wait * 2;
        this.armStatsRetry();
      });
    }, wait);
  }

  // ---------- 仪表盘实时数据 ----------

  /** 单一 1 秒心跳，每项独立到期时间；比四个 timer 更好管前后台与切服务器。 */
  private startLiveTicker(): void {
    if (this.liveTickerId >= 0) {
      return;
    }
    this.liveTickerId = setInterval((): void => {
      if (this.state.server() === null) {
        return;
      }
      const now: number = Date.now();

      if (!this.liveStopped.has('speed') && now >= (this.liveNextAt.has('speed')
        ? this.liveNextAt.get('speed') as number : 0)) {
        this.pollLive<MpDownloaderInfo>('speed', 5000,
          (c: MoviePilotClient): Promise<MpDownloaderInfo> => c.dashboardDownloader(),
          (info: MpDownloaderInfo): void => {
            const s: MpState = this.state.copy();
            s.live = s.live.copy();
            s.live.downloader = info;
            s.live.speedError = '';
            s.live.lastSpeedAt = Date.now();
            this.commit(s);
          },
          (message: string): void => {
            const s: MpState = this.state.copy();
            s.live = s.live.copy();
            s.live.speedError = message;
            this.commit(s);
          });
      }

      if (!this.liveStopped.has('cpu') && now >= (this.liveNextAt.has('cpu')
        ? this.liveNextAt.get('cpu') as number : 0)) {
        this.pollLive<number>('cpu', 5000,
          (c: MoviePilotClient): Promise<number> => c.dashboardCpu(),
          (value: number): void => {
            if (Number.isNaN(value)) {
              return;
            }
            const sample: CpuSample = new CpuSample(Date.now(), value);
            const s: MpState = this.state.copy();
            s.live = s.live.copy();
            s.live.cpu = value;
            const updated: CpuSample[] = s.live.cpuSamples.concat([sample]);
            s.live.cpuSamples = updated.slice(-180);
            this.commit(s);
          },
          (): void => {});
      }

      if (!this.liveStopped.has('memory') && now >= (this.liveNextAt.has('memory')
        ? this.liveNextAt.get('memory') as number : 0)) {
        this.pollLive<MpMemoryInfo>('memory', 10000,
          (c: MoviePilotClient): Promise<MpMemoryInfo> => c.dashboardMemory(),
          (info: MpMemoryInfo): void => {
            const sample: MemorySample = new MemorySample(
              Date.now(), info.used, info.cached, info.available);
            const s: MpState = this.state.copy();
            s.live = s.live.copy();
            s.live.memory = info;
            const updated: MemorySample[] = s.live.memorySamples.concat([sample]);
            s.live.memorySamples = updated.slice(-30);
            this.commit(s);
          },
          (): void => {});
      }

      if (!this.liveStopped.has('system') && now >= (this.liveNextAt.has('system')
        ? this.liveNextAt.get('system') as number : 0)) {
        this.pollLive<MpSystemInfo>('system', 60000,
          (c: MoviePilotClient): Promise<MpSystemInfo> => c.dashboardSystem(),
          (info: MpSystemInfo): void => {
            const s: MpState = this.state.copy();
            s.live = s.live.copy();
            s.live.system = info;
            s.live.systemDenied = false;
            s.live.systemError = '';
            this.commit(s);
          },
          (message: string, error: Error): void => {
            const denied: boolean = error instanceof ApiException &&
              ((error as ApiException).code === 401 || (error as ApiException).code === 403);
            const s: MpState = this.state.copy();
            s.live = s.live.copy();
            s.live.systemDenied = denied;
            s.live.systemError = denied ? '' : message;
            this.commit(s);
          });
      }
    }, 1000);
  }

  /** 单项请求：in-flight 守卫 + 指数退避（上限 8 倍）+ stale-on-error。 */
  private pollLive<T>(
    key: string,
    intervalMs: number,
    call: (client: MoviePilotClient) => Promise<T>,
    onSuccess: (value: T) => void,
    onFailure: (message: string, error: Error) => void
  ): void {
    if (this.liveInFlight.has(key)) {
      return;
    }
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    this.liveInFlight.add(key);
    call(client).then((value: T): void => {
      onSuccess(value);
      this.finishLivePoll(key, intervalMs, true, false);
    }).catch((e: Error): void => {
      const denied: boolean = e instanceof ApiException &&
        ((e as ApiException).code === 401 || (e as ApiException).code === 403);
      onFailure(this.humanizeStatsError(e), e);
      this.finishLivePoll(key, intervalMs, false, denied);
    });
  }

  private finishLivePoll(key: string, intervalMs: number, success: boolean, denied: boolean): void {
    this.liveInFlight.delete(key);
    if (denied) {
      // 认证失败不是抖动，重试也没用
      this.liveStopped.add(key);
      return;
    }
    const prev: number = this.liveFailStreak.has(key)
      ? this.liveFailStreak.get(key) as number : 0;
    const streak: number = success ? 0 : prev + 1;
    this.liveFailStreak.set(key, streak);
    const backoff: number = streak <= 1 ? 1 : Math.min(8, 1 << (streak - 1));
    this.liveNextAt.set(key, Date.now() + intervalMs * backoff);
  }

  private stopLivePolling(clearState: boolean): void {
    if (this.liveTickerId >= 0) {
      clearInterval(this.liveTickerId);
      this.liveTickerId = -1;
    }
    this.liveInFlight.clear();
    this.liveStopped.clear();
    this.liveNextAt.clear();
    this.liveFailStreak.clear();
    if (clearState) {
      const s: MpState = this.state.copy();
      s.live = new DashboardLiveState();
      this.commit(s);
    }
  }

  /** 切服务器 / 增删服务器：旧采样必须作废，不能把 A 的曲线画到 B 上。 */
  private resetLive(): void {
    this.stopLivePolling(true);
  }

  private client(): MoviePilotClient | null {
    const server: MpServer | null = this.state.server();
    return server !== null ? new MoviePilotClient(server) : null;
  }

  // ---------- 仪表盘媒体统计 ----------

  loadStats(clearError: boolean = false): void {
    if (clearError && this.state.statsError.length > 0) {
      const sc: MpState = this.state.copy();
      sc.statsError = '';
      this.commit(sc);
    }
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      this.cancelStatsRetry();
      const s0: MpState = this.state.copy();
      s0.stats = null;
      s0.statsError = '';
      s0.statsLoading = false;
      s0.storage = null;
      this.commit(s0);
      return;
    }
    // 容量和媒体数量一起刷：都走 dashboard，用户改了存储目录也能跟着变
    this.loadStorage(client);
    if (this.state.statsLoading) {
      return;
    }
    this.statsGeneration++;
    const gen: number = this.statsGeneration;
    const s: MpState = this.state.copy();
    s.statsLoading = true;
    this.commit(s);
    client.statistic().then((st: MpStatistic): void => {
      if (gen !== this.statsGeneration) {
        return;
      }
      const s2: MpState = this.state.copy();
      s2.stats = st;
      s2.statsLoading = false;
      s2.statsError = '';
      this.commit(s2);
      this.cancelStatsRetry();
    }).catch((e: Error): void => {
      if (gen !== this.statsGeneration) {
        return;
      }
      const s2: MpState = this.state.copy();
      s2.statsLoading = false;
      s2.statsError = this.humanizeStatsError(e);
      this.commit(s2);
      logWarn('MpViewModel', `loadStats: ${e.message}`);
      this.scheduleStatsRetry();
    });
  }

  /**
   * rcp 抛出的原始错误是
   * `failed to connect to /192.168.1.5 (port 3000) from /192.168.1.90 (port 45572) after 6000ms`
   * 这种英文，直接摆在仪表盘上没人看得懂，转成人话（地址取服务器配置里的那条，比解析报错串稳）。
   */
  private humanizeStatsError(err: Error): string {
    const msg: string = err.message.length > 0 ? err.message : '';
    if (msg.indexOf('failed to connect') >= 0 || msg.indexOf('Connection refused') >= 0) {
      const server: MpServer | null = this.state.server();
      const eps: Endpoint[] = server !== null ? server.activeEndpoints() : [];
      const where: string = eps.length > 0 ? `（${eps[0].display()}）` : '';
      return `连不上 MoviePilot${where}，检查手机与服务器是否在同一网络`;
    }
    if (msg.indexOf('Unable to resolve host') >= 0) {
      return '服务器地址解析失败，检查域名是否正确';
    }
    if (msg.indexOf('imeout') >= 0 || msg.indexOf('imed out') >= 0) {
      return '连接超时，稍后自动重试';
    }
    return msg.length > 0 ? msg : '连接失败';
  }

  /** 挂载盘容量：只有超管账号或配了 API Token 才拿得到，拿不到就静默退回下载器口径 */
  private loadStorage(client: MoviePilotClient): void {
    client.storage().then((st: MpStorage): void => {
      if (!st.isValid()) {
        // 接口通了但两个字段都是 0：多见于 MP 没配媒体库目录 / 目录不可读
        logWarn('MpViewModel', `loadStorage: MP 返回 0（total=${st.totalBytes} used=${st.usedBytes}）`);
        return;
      }
      if (this.state.server() === null) {
        return;
      }
      logSeek(`MP 存储 total=${st.totalBytes} used=${st.usedBytes} free=${st.freeBytes()}`);
      const s: MpState = this.state.copy();
      s.storage = st;
      this.commit(s);
    }).catch((e: Error): void => {
      logWarn('MpViewModel', `loadStorage: ${e.message}`);
    });
  }

  // ---------- 服务器 ----------
  upsertServer(server: MpServer): void {
    const servers: MpServer[] = this.state.servers.slice(0);
    let found: boolean = false;
    for (let i = 0; i < servers.length; i++) {
      if (servers[i].id === server.id) {
        servers[i] = server;
        found = true;
        break;
      }
    }
    if (!found) {
      servers.push(server);
    }
    const activeId: string | null = this.state.activeServerId !== null
      ? this.state.activeServerId : server.id;
    this.persist(servers, activeId);
    EndpointResolver.invalidate(server.id);
    this.resetLive();
    this.loadDiscover(true);
    this.loadStats();
    this.startLiveTicker();
  }

  deleteServer(id: string): void {
    if (this.state.activeServerId === id) {
      this.resetSiteState();
    }
    const servers: MpServer[] = [];
    for (const srv of this.state.servers) {
      if (srv.id !== id) {
        servers.push(srv);
      }
    }
    const activeId: string | null =
      this.state.activeServerId !== null && this.state.activeServerId !== id
        ? this.state.activeServerId : null;
    this.persist(servers, activeId);
    EndpointResolver.invalidate(id);
    this.resetLive();
    const s: MpState = this.state.copy();
    s.detail = null;
    s.resources = [];
    this.commit(s);
    this.startLiveTicker();
  }

  selectServer(id: string | null): void {
    // 换服务器前先清站点域状态与缓存，避免上一台的站点/图标/海报串过来
    this.resetSiteState();
    this.persist(this.state.servers.slice(0), id);
    this.resetLive();
    const s: MpState = this.state.copy();
    s.items = [];
    s.page = 1;
    s.hasMore = true;
    s.detail = null;
    s.resources = [];
    s.error = '';
    s.channel = MP_CHANNELS[0];
    this.commit(s);
    if (id !== null) {
      this.loadDiscover(true);
      this.loadSubscribes(true);
      this.loadStats();
      this.startLiveTicker();
    } else {
      const s2: MpState = this.state.copy();
      s2.stats = null;
      this.commit(s2);
    }
  }

  private persist(servers: MpServer[], activeId: string | null): void {
    this.persisted.mpServers = servers;
    this.persisted.activeMpServerId = activeId;
    this.store.save(this.persisted);
    const s: MpState = this.state.copy();
    s.servers = servers;
    s.activeServerId = activeId;
    this.commit(s);
  }

  /** 保存首屏 Hero 海报缓存（只存显示需要的字段，落盘时随 ConfigStore 一起加密） */
  saveHeroCache(serverKey: string, items: MpMedia[]): void {
    const cache: HeroCache = new HeroCache();
    cache.serverKey = serverKey;
    cache.fetchedAt = Date.now();
    const simple: HeroCacheItem[] = [];
    for (const m of items) {
      const it: HeroCacheItem = new HeroCacheItem();
      it.mediaId = m.mediaId;
      it.title = m.title;
      it.year = m.year;
      it.type = m.type;
      it.overview = m.overview;
      it.posterUrl = m.posterUrl;
      it.backdropUrl = m.backdropUrl;
      it.vote = m.vote;
      it.genres = m.genres;
      simple.push(it);
    }
    cache.items = simple;
    this.persisted.heroCache = cache;
    this.store.save(this.persisted);
    const s: MpState = this.state.copy();
    s.heroCache = cache;
    this.commit(s);
  }

  testServer(server: MpServer): Promise<string> {
    return new MoviePilotClient(server).testConnection();
  }

  // ---------- 发现 ----------

  selectChannel(channel: MpDiscoverChannel): void {
    if (this.state.channel.key === channel.key && this.state.items.length > 0) {
      return;
    }
    const s: MpState = this.state.copy();
    s.channel = channel;
    s.items = [];
    s.page = 1;
    s.hasMore = true;
    s.error = '';
    this.commit(s);
    this.loadDiscover(true);
  }

  loadDiscover(refresh: boolean): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null || this.state.loading || this.state.loadingMore) {
      return;
    }
    const nextPage: number = refresh ? 1 : this.state.page + 1;
    if (!refresh && !this.state.hasMore) {
      return;
    }
    const s: MpState = this.state.copy();
    if (refresh) {
      s.loading = true;
      s.error = '';
    } else {
      s.loadingMore = true;
    }
    this.commit(s);

    client.recommend(this.state.channel, nextPage).then((list: MpMedia[]): void => {
      let merged: MpMedia[] = list;
      if (!refresh) {
        merged = this.state.items.slice(0);
        for (const m of list) {
          merged.push(m);
        }
        merged = MpViewModel.distinctMedias(merged);
      }
      const s2: MpState = this.state.copy();
      s2.items = merged;
      s2.page = nextPage;
      s2.hasMore = list.length >= 20;
      s2.loading = false;
      s2.loadingMore = false;
      s2.error = '';
      this.commit(s2);
    }).catch((e: Error): void => {
      const s2: MpState = this.state.copy();
      s2.loading = false;
      s2.loadingMore = false;
      s2.error = e.message.length > 0 ? e.message : '加载失败';
      this.commit(s2);
    });
  }

  private static distinctMedias(list: MpMedia[]): MpMedia[] {
    const seen: Map<string, boolean> = new Map();
    const out: MpMedia[] = [];
    for (const m of list) {
      const k: string = `${m.mediaId}:${m.season}`;
      if (!seen.has(k)) {
        seen.set(k, true);
        out.push(m);
      }
    }
    return out;
  }

  // ---------- 搜索 ----------

  startSearch(): void {
    const s: MpState = this.state.copy();
    s.searchActive = true;
    this.commit(s);
  }

  exitSearch(): void {
    const s: MpState = this.state.copy();
    s.searchActive = false;
    s.searchResults = [];
    s.searchQuery = '';
    this.commit(s);
  }

  updateSearchQuery(text: string): void {
    const s: MpState = this.state.copy();
    s.searchQuery = text;
    this.state = s;
  }

  search(): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    const keyword: string = this.state.searchQuery.trim();
    if (keyword.length === 0) {
      return;
    }
    const s: MpState = this.state.copy();
    s.searching = true;
    this.commit(s);
    client.searchMedia(keyword).then((list: MpMedia[]): void => {
      const s2: MpState = this.state.copy();
      s2.searchResults = list;
      s2.searching = false;
      this.commit(s2);
      if (list.length === 0) {
        ToastHub.getInstance().show(`没有搜到「${keyword}」`);
      }
    }).catch((e: Error): void => {
      const s2: MpState = this.state.copy();
      s2.searching = false;
      this.commit(s2);
      ToastHub.getInstance().show(e.message.length > 0 ? e.message : '搜索失败');
    });
  }

  // ---------- 详情 ----------

  openDetail(media: MpMedia): void {
    const s: MpState = this.state.copy();
    s.detail = media;
    s.detailLoading = true;
    s.resources = [];
    s.resourceError = '';
    s.resourceSearched = false;
    s.filter = new ResourceFilter();
    s.credits = [];
    this.commit(s);
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    // 只拉简介，不自动搜站点：用户想看资源时自己点「搜资源」
    // 详情请求失败也要继续拉演职员（以前一抛错整条链就断，详情页既没有真简介也没有演职员）
    client.mediaDetail(media).catch((e: Error): MpMedia => media).then((detail: MpMedia): Promise<Person[]> => {
      const s2: MpState = this.state.copy();
      s2.detail = detail;
      this.commit(s2);
      return client.credits(detail);
    }).then((credits: Person[]): void => {
      const s2: MpState = this.state.copy();
      s2.credits = credits;
      s2.detailLoading = false;
      this.commit(s2);
    }).catch((e: Error): void => {
      const s2: MpState = this.state.copy();
      s2.detailLoading = false;
      this.commit(s2);
    });
  }

  closeDetail(): void {
    const s: MpState = this.state.copy();
    s.detail = null;
    s.resources = [];
    s.resourceError = '';
    this.commit(s);
  }

  searchResources(): void {
    const client: MoviePilotClient | null = this.client();
    const media: MpMedia | null = this.state.detail;
    if (client === null || media === null || this.state.resourcesLoading) {
      return;
    }
    const s: MpState = this.state.copy();
    s.resourcesLoading = true;
    s.resourceSearched = true;
    s.resourceError = '';
    s.searchStage = '正在向各站点发起搜索…';
    this.commit(s);
    client.searchResources(media, (batch: MpResource[], stage: string): void => {
      const sb: MpState = this.state.copy();
      sb.resources = batch;
      sb.searchStage = stage.length > 0 ? stage : `已返回 ${batch.length} 个候选资源…`;
      this.commit(sb);
    }).then((list: MpResource[]): void => {
      const s2: MpState = this.state.copy();
      s2.resources = list;
      s2.resourcesLoading = false;
      s2.searchStage = '';
      s2.resourceError = list.length === 0
        ? '未搜索到资源（检查 MoviePilot 的站点是否可用）' : '';
      this.commit(s2);
    }).catch((e: Error): void => {
      const s2: MpState = this.state.copy();
      s2.resourcesLoading = false;
      s2.searchStage = '';
      s2.resourceError = e.message.length > 0 ? e.message : '搜索失败';
      this.commit(s2);
    });
  }

  updateFilter(filter: ResourceFilter): void {
    const s: MpState = this.state.copy();
    s.filter = filter;
    this.commit(s);
  }

  // ---------- 投递 ----------

  loadDownloadOptions(): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    const downloadersP: Promise<MpDownloader[]> =
      client.downloaders().catch((e: Error): MpDownloader[] => []);
    downloadersP.then((downloaders: MpDownloader[]): Promise<MpSavePath[]> => {
      return client.savePaths().catch((e: Error): MpSavePath[] => []);
    }).then((paths: MpSavePath[]): void => {
      // downloaders 已经在上一步 resolve，重新取值
      downloadersP.then((downloaders: MpDownloader[]): void => {
        const s: MpState = this.state.copy();
        s.downloaders = downloaders;
        s.savePaths = paths;
        this.commit(s);
      });
    });
  }

  download(resource: MpResource, downloader: string, savePath: string): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    ToastHub.getInstance().show('正在提交…');
    client.addDownload(resource, downloader, savePath).then((id: string): void => {
      ToastHub.getInstance().show('已提交到 MoviePilot，下载器开始下载');
    }).catch((e: Error): void => {
      ToastHub.getInstance().show(e.message.length > 0 ? e.message : '提交失败');
    });
  }

  /**
   * 面板式投递：把结果交回调用方（成功给任务 id，失败抛），
   * 面板里能显示提交中 / 成功 / 失败重试，不再只靠一个 2.4s toast。
   */
  submitDownload(resource: MpResource, downloader: string, savePath: string): Promise<string> {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return Promise.reject(new ApiException('还没有配置 MoviePilot 服务器'));
    }
    return client.addDownload(resource, downloader, savePath);
  }

  // ---------- 站点（只读同步 MP） ----------

  private siteJobGen: number = 0;
  private siteBrowseGen: number = 0;
  private siteTickerId: number = -1;
  private posterFailStreak: number = 0;

  /** 只改站点子状态再整体提交（避免每个方法手写一整份 copy） */
  private commitSite(mutator: (s: MpSiteState) => void): void {
    const outer: MpState = this.state.copy();
    const site: MpSiteState = outer.site.copy();
    mutator(site);
    outer.site = site;
    this.commit(outer);
  }

  /**
   * 拉站点列表 + 各站个人数据。
   *
   * 两个接口都要求管理员 token：403 时提示换 token，404 时降级成「这个 MP 版本没有站点接口」。
   * 个人数据失败不算致命 —— 站点列表照样显示，只是没有等级/上传量。
   */
  loadSites(force: boolean = false): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      this.commitSite((s: MpSiteState): void => {
        s.loading = false;
        s.loaded = false;
        s.error = '还没有配置 MoviePilot 服务器';
      });
      return;
    }
    if (!force && (this.state.site.loading || this.state.site.loaded)) {
      return;
    }
    this.siteJobGen++;
    const gen: number = this.siteJobGen;
    this.commitSite((s: MpSiteState): void => {
      s.loading = true;
      s.error = '';
    });
    client.sites().then((sites: MpSite[]): Promise<MpSiteUserData[]> => {
      if (gen !== this.siteJobGen) {
        return Promise.reject(new Error('stale'));
      }
      this.commitSite((s: MpSiteState): void => {
        s.sites = sites;
        s.permissionDenied = false;
        s.degraded = false;
      });
      // 个人数据失败不影响站点列表
      return client.siteUserData().catch((e: Error): MpSiteUserData[] => {
        if (gen === this.siteJobGen) {
          this.commitSite((s: MpSiteState): void => {
            s.error = `站点个人数据加载失败：${this.humanizeSiteError(e)}`;
          });
        }
        return [];
      });
    }).then((data: MpSiteUserData[]): void => {
      if (gen !== this.siteJobGen) {
        return;
      }
      const mapped: Map<number, MpSiteUserData> = this.matchSiteUserData(this.state.site.sites, data);
      this.commitSite((s: MpSiteState): void => {
        s.userData = mapped;
        s.loading = false;
        s.loaded = true;
      });
      logInfo('MpViewModel', `站点载入完成：${this.state.site.sites.length} 个站点`);
    }).catch((e: Error): void => {
      if (gen !== this.siteJobGen) {
        return;
      }
      const msg: string = this.humanizeSiteError(e);
      const code: number = e instanceof ApiException ? (e as ApiException).code : 0;
      this.commitSite((s: MpSiteState): void => {
        s.loading = false;
        s.error = msg;
        s.permissionDenied = code === 403;
        s.degraded = code === 404;
      });
      logWarn('MpViewModel', `loadSites: ${msg}`);
    });
  }

  refreshSites(): void {
    this.loadSites(true);
  }

  /**
   * MP 按 domain 返回个人数据，这里按站点对齐：
   * 先用 matchKeys 抹平 www/大小写，再退回「站点名精确匹配」兜底。
   */
  private matchSiteUserData(sites: MpSite[], data: MpSiteUserData[]): Map<number, MpSiteUserData> {
    const out: Map<number, MpSiteUserData> = new Map();
    for (const site of sites) {
      const keys: string[] = site.matchKeys();
      let hit: MpSiteUserData | null = null;
      for (const d of data) {
        const domain: string = d.domain.trim().toLowerCase()
          .replace(/^https?:\/\//, '').replace(/^www\./, '').replace(/\/+$/, '');
        if (domain.length > 0 && keys.indexOf(domain) >= 0) {
          hit = d;
          break;
        }
      }
      if (hit === null) {
        for (const d of data) {
          if (d.name.trim().toLowerCase() === site.name.trim().toLowerCase()) {
            hit = d;
            break;
          }
        }
      }
      if (hit !== null) {
        out.set(site.id, hit);
      }
    }
    return out;
  }

  /**
   * 站点图标：命中缓存直接给，否则去 MP 拉一次（并发由 SiteIconStore 限住）。
   * 不往 state 里塞：几十张图标各自触发整页重组没有必要，组件自己 @State 持有即可。
   */
  async loadSiteIcon(siteId: number): Promise<SiteIcon | null> {
    const cached: SiteIcon | null = SiteIconStore.cached(siteId);
    if (cached !== null) {
      return cached;
    }
    if (SiteIconStore.isMissing(siteId)) {
      return null;
    }
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return null;
    }
    return await SiteIconStore.load(siteId, (): Promise<string | null> => client.siteIcon(siteId));
  }

  openSite(site: MpSite): void {
    if (!site.isActive) {
      ToastHub.getInstance().show('该站点在 MoviePilot 里已停用');
      return;
    }
    this.cancelSiteBrowse();
    this.commitSite((s: MpSiteState): void => {
      s.openSite = site;
      s.torrents = [];
      s.posters = new Map();
      s.categories = [];
      s.selectedCat = '';
      s.searchInput = '';
      s.keyword = '';
      s.sort = SiteSort.LATEST;
      s.allPageKeys = [];
      s.catIgnored = false;
      s.page = 0;
      s.hasMore = true;
      s.stalledPages = 0;
      s.browseError = '';
      s.browsing = false;
      s.elapsedSeconds = 0;
    });
    this.loadSiteCategories(site.id);
    this.loadSitePage(true);
  }

  closeSite(): void {
    this.cancelSiteBrowse();
    this.commitSite((s: MpSiteState): void => {
      s.openSite = null;
      s.torrents = [];
      s.posters = new Map();
      s.categories = [];
      s.selectedCat = '';
      s.searchInput = '';
      s.keyword = '';
      s.allPageKeys = [];
      s.catIgnored = false;
      s.page = 0;
      s.hasMore = true;
      s.stalledPages = 0;
      s.browseError = '';
      s.browsing = false;
      s.elapsedSeconds = 0;
    });
  }

  updateSiteSearchInput(text: string): void {
    this.commitSite((s: MpSiteState): void => {
      s.searchInput = text;
    });
  }

  submitSiteSearch(): void {
    const keyword: string = this.state.site.searchInput.trim();
    this.commitSite((s: MpSiteState): void => {
      s.keyword = keyword;
      s.page = 0;
      s.hasMore = true;
      s.stalledPages = 0;
      s.torrents = [];
      s.posters = new Map();
    });
    this.loadSitePage(true);
  }

  /** 分类单选：点同一个 = 取消（回到全部） */
  toggleSiteCategory(value: string): void {
    const next: string = this.state.site.selectedCat === value ? '' : value;
    this.commitSite((s: MpSiteState): void => {
      s.selectedCat = next;
      s.page = 0;
      s.hasMore = true;
      s.stalledPages = 0;
      s.torrents = [];
      s.posters = new Map();
      s.catIgnored = false;
    });
    this.loadSitePage(true);
  }

  clearSiteCategories(): void {
    if (this.state.site.selectedCat.length === 0) {
      return;
    }
    this.commitSite((s: MpSiteState): void => {
      s.selectedCat = '';
      s.page = 0;
      s.hasMore = true;
      s.stalledPages = 0;
      s.torrents = [];
      s.posters = new Map();
      s.catIgnored = false;
    });
    this.loadSitePage(true);
  }

  setSiteSort(sort: SiteSort): void {
    if (this.state.site.sort === sort) {
      return;
    }
    this.commitSite((s: MpSiteState): void => {
      s.sort = sort;
    });
  }

  refreshSiteTorrents(): void {
    this.loadSitePage(true);
  }

  loadMoreSiteTorrents(): void {
    this.loadSitePage(false);
  }

  /** 主动取消（切站点/换分类/离开页面）：让进行中的请求结果作废 */
  cancelSiteBrowse(): void {
    this.siteBrowseGen++;
    this.stopSiteTicker();
    if (this.state.site.browsing) {
      this.commitSite((s: MpSiteState): void => {
        s.browsing = false;
        s.elapsedSeconds = 0;
      });
    }
  }

  private loadSiteCategories(siteId: number): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    client.siteCategories(siteId).then((cats: MpSiteCategory[]): void => {
      const open: MpSite | null = this.state.site.openSite;
      if (open === null || open.id !== siteId) {
        return;
      }
      // MP 的分类里多个共用同一个 cat 组名（DaXiangJiao 402=TV、403=TV Series），
      // 纯 UI 列表用 value 做 key 会撞车（安卓就是在这里闪退的），这里先按 value 去重
      const seen: string[] = [];
      const unique: MpSiteCategory[] = [];
      for (const c of cats) {
        const v: string = c.value();
        if (v.length === 0 || seen.indexOf(v) >= 0) {
          continue;
        }
        seen.push(v);
        unique.push(c);
      }
      this.commitSite((s: MpSiteState): void => {
        s.categories = unique;
      });
      logInfo('MpViewModel', `站点 ${siteId} 分类 ${unique.length} 个`);
    }).catch((e: Error): void => {
      logWarn('MpViewModel', `站点分类加载失败: ${e.message}`);
    });
  }

  private static distinctResources(list: MpResource[]): MpResource[] {
    const seen: string[] = [];
    const out: MpResource[] = [];
    for (const r of list) {
      if (seen.indexOf(r.key) >= 0) {
        continue;
      }
      seen.push(r.key);
      out.push(r);
    }
    return out;
  }

  /** 两个 key 集合是否完全相同（顺序无关），用于判断站点有没有按 cat 过滤 */
  private static sameKeys(a: string[], b: string[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (const k of a) {
      if (b.indexOf(k) < 0) {
        return false;
      }
    }
    return true;
  }

  private stopSiteTicker(): void {
    if (this.siteTickerId >= 0) {
      clearTimeout(this.siteTickerId);
      this.siteTickerId = -1;
    }
  }

  /**
   * 计时器：站点浏览是同步阻塞接口，慢站 30s+ 很常见。
   * 到点自己收手并给一句能照着做的话，不让用户干等 130s 的读超时。
   */
  private startSiteTicker(gen: number): void {
    this.stopSiteTicker();
    const tick = (): void => {
      this.siteTickerId = -1;
      if (gen !== this.siteBrowseGen || !this.state.site.browsing) {
        return;
      }
      const elapsed: number = this.state.site.elapsedSeconds + 1;
      if (elapsed >= SITE_BROWSE_TIMEOUT_SECONDS) {
        // 让进行中的请求结果作废
        this.siteBrowseGen++;
        this.commitSite((s: MpSiteState): void => {
          s.browsing = false;
          s.elapsedSeconds = 0;
          s.browseError = `站点 ${SITE_BROWSE_TIMEOUT_SECONDS} 秒没有响应。` +
            '多半是 MP 抓不到这个站（站点 Cookie 失效、被 Cloudflare 拦、或站点本身挂了）：' +
            '先去 MP 后台「站点」里手动浏览一次，能出种子再回这里重试。';
        });
        return;
      }
      this.commitSite((s: MpSiteState): void => {
        s.elapsedSeconds = elapsed;
      });
      this.siteTickerId = setTimeout(tick, 1000);
    };
    this.siteTickerId = setTimeout(tick, 1000);
  }

  private loadSitePage(reset: boolean): void {
    const client: MoviePilotClient | null = this.client();
    const site: MpSite | null = this.state.site.openSite;
    if (client === null || site === null) {
      return;
    }
    const cur: MpSiteState = this.state.site;
    if (!reset && (!cur.hasMore || cur.browsing)) {
      return;
    }
    const nextPage: number = reset ? 0 : cur.page + 1;
    const keyword: string = cur.keyword;
    const cats: string[] = cur.selectedCat.length > 0 ? [cur.selectedCat] : [];
    this.siteBrowseGen++;
    const gen: number = this.siteBrowseGen;
    this.stopSiteTicker();
    this.commitSite((s: MpSiteState): void => {
      s.browsing = true;
      s.elapsedSeconds = 0;
      s.browseError = '';
      s.page = nextPage;
    });
    this.startSiteTicker(gen);
    client.siteTorrents(site.id, site.name, keyword, cats, nextPage)
      .then((list: MpResource[]): void => {
        if (gen !== this.siteBrowseGen) {
          return;
        }
        this.stopSiteTicker();
        const before: MpSiteState = this.state.site;
        let merged: MpResource[] = list;
        if (!reset) {
          merged = before.torrents.slice(0);
          for (const r of list) {
            merged.push(r);
          }
          merged = MpViewModel.distinctResources(merged);
        }
        // 越界页被站点回落到首页时会「返回非空但没新东西」，连续 3 页就收手
        const stalled: number = (reset || merged.length > before.torrents.length)
          ? 0 : before.stalledPages + 1;
        const pageKeys: string[] = [];
        for (const r of list) {
          pageKeys.push(r.key);
        }
        // 选了分类但这一页和「全部」第一页一模一样 → 站点没按 cat 过滤
        const catIgnored: boolean = reset && cats.length > 0 && before.allPageKeys.length > 0 &&
          MpViewModel.sameKeys(pageKeys, before.allPageKeys);
        const allKeys: string[] = (reset && cats.length === 0) ? pageKeys : before.allPageKeys;
        this.commitSite((s: MpSiteState): void => {
          s.torrents = merged;
          s.page = nextPage;
          s.hasMore = list.length > 0 && stalled < 3;
          s.stalledPages = stalled;
          s.browsing = false;
          s.browseError = '';
          s.elapsedSeconds = 0;
          s.allPageKeys = allKeys;
          s.catIgnored = catIgnored;
        });
        this.resolveSitePosters(site.id, merged);
      })
      .catch((e: Error): void => {
        if (gen !== this.siteBrowseGen) {
          return;
        }
        this.stopSiteTicker();
        this.commitSite((s: MpSiteState): void => {
          s.browsing = false;
          s.elapsedSeconds = 0;
          s.browseError = this.humanizeSiteError(e);
        });
        logWarn('MpViewModel', `站点浏览失败: ${e.message}`);
      });
  }

  /**
   * 给当前页的种子补海报：只处理「还没问过 MP」的标题（按归一化 key 去重），
   * 每批最多 18 个，拿回来的地址增量并进 state.posters，列表只会重绘有图的那几行。
   */
  private resolveSitePosters(siteId: number, resources: MpResource[]): void {
    if (resources.length === 0 || this.state.site.postersDisabled) {
      return;
    }
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    const requests: PosterRequest[] = [];
    const seen: string[] = [];
    for (const r of resources) {
      const key: string = MediaPosterCache.titleKey(r.title);
      if (key.length === 0 || seen.indexOf(key) >= 0 || MediaPosterCache.isResolved(key)) {
        continue;
      }
      seen.push(key);
      requests.push(new PosterRequest(key, r.title));
      if (requests.length >= 18) {
        break;
      }
    }
    if (requests.length === 0) {
      this.applyCachedPosters(siteId, resources);
      return;
    }
    MediaPosterCache.resolve(client, requests).then((fetched: Map<string, string>): void => {
      const open: MpSite | null = this.state.site.openSite;
      if (open === null || open.id !== siteId) {
        return;
      }
      const added: Map<string, string> = new Map();
      for (const r of resources) {
        const key: string = MediaPosterCache.titleKey(r.title);
        let url: string = MediaPosterCache.cached(key);
        if (url.length === 0) {
          const f: string | undefined = fetched.get(key);
          url = f === undefined ? '' : f;
        }
        if (url.length > 0) {
          added.set(r.key, url);
        }
      }
      if (added.size > 0) {
        const merged: Map<string, string> = new Map();
        this.state.site.posters.forEach((v: string, k: string): void => {
          merged.set(k, v);
        });
        added.forEach((v: string, k: string): void => {
          merged.set(k, v);
        });
        this.commitSite((s: MpSiteState): void => {
          s.posters = merged;
        });
      }
      // 熔断：一整批一条都没成（v2 没有识别接口 / token 权限不足 / 网络断），连续 3 批就关掉
      if (requests.length >= 3 && fetched.size === 0) {
        this.posterFailStreak++;
        if (this.posterFailStreak >= 3) {
          this.commitSite((s: MpSiteState): void => {
            s.postersDisabled = true;
          });
          logWarn('MpViewModel', '海报识别连续 3 批全失败，本条会话内不再尝试');
        }
      } else if (fetched.size > 0) {
        this.posterFailStreak = 0;
      }
    });
  }

  private applyCachedPosters(siteId: number, resources: MpResource[]): void {
    const open: MpSite | null = this.state.site.openSite;
    if (open === null || open.id !== siteId) {
      return;
    }
    let changed: boolean = false;
    const merged: Map<string, string> = new Map();
    this.state.site.posters.forEach((v: string, k: string): void => {
      merged.set(k, v);
    });
    for (const r of resources) {
      if (merged.has(r.key)) {
        continue;
      }
      const url: string = MediaPosterCache.cached(MediaPosterCache.titleKey(r.title));
      if (url.length > 0) {
        merged.set(r.key, url);
        changed = true;
      }
    }
    if (changed) {
      this.commitSite((s: MpSiteState): void => {
        s.posters = merged;
      });
    }
  }

  /** 任务详情 / 站点种子详情用：按标题反查一张海报（内部有 LRU + 负缓存） */
  async posterForTitle(title: string): Promise<string> {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return '';
    }
    return await MediaPosterCache.resolveOne(client, title);
  }

  /**
   * 站点种子详情页的「MP 侧内容」：识别标题 → 详情 → 演职员。
   *
   * 站点接口只给文字（标题/简介/体积），简介、类型、导演、主演都没有；
   * 这里跑一遍 MP 的三段接口，让站点页和 MP 搜索结果页显示同一套内容。
   * 任何一步失败都降级为空，不阻塞页面渲染。
   */
  async loadTorrentMedia(title: string): Promise<TorrentMediaInfo> {
    const client: MoviePilotClient | null = this.client();
    if (client === null || title.trim().length === 0) {
      return new TorrentMediaInfo();
    }
    // 先走识别接口（MP 自己会清洗发布名）；识别不出来再退回文本搜索第一条
    let found: MpMedia | null = await client.recognizeMedia(title);
    if (found === null) {
      try {
        const list: MpMedia[] = await client.searchMedia(title);
        found = list.length > 0 ? list[0] : null;
      } catch (e) {
        found = null;
      }
    }
    if (found === null) {
      return new TorrentMediaInfo();
    }
    let detail: MpMedia = found;
    try {
      detail = await client.mediaDetail(found);
    } catch (e) {
      detail = found;
    }
    let credits: Person[] = [];
    try {
      credits = await client.credits(detail);
    } catch (e) {
      credits = [];
    }
    const names: string[] = [];
    if (credits.length > 0) {
      for (const p of credits) {
        if (p.name.length > 0 && names.indexOf(p.name) < 0) {
          names.push(p.name);
        }
      }
    } else {
      const fallback: string[] = detail.directors.concat(detail.cast);
      for (const n of fallback) {
        if (n.length > 0 && names.indexOf(n) < 0) {
          names.push(n);
        }
      }
    }
    return new TorrentMediaInfo(detail, names);
  }

  /** 切 MP 服务器 / 删服务器时把站点状态整体清掉，避免上一台的站点串到下一台 */
  private resetSiteState(): void {
    this.siteJobGen++;
    this.cancelSiteBrowse();
    this.posterFailStreak = 0;
    MediaPosterCache.clear();
    SiteIconStore.clear();
    this.commitSite((s: MpSiteState): void => {
      s.sites = [];
      s.userData = new Map();
      s.loading = false;
      s.loaded = false;
      s.error = '';
      s.permissionDenied = false;
      s.degraded = false;
      s.openSite = null;
      s.torrents = [];
      s.posters = new Map();
      s.categories = [];
      s.selectedCat = '';
      s.searchInput = '';
      s.keyword = '';
      s.allPageKeys = [];
      s.catIgnored = false;
      s.page = 0;
      s.hasMore = true;
      s.stalledPages = 0;
      s.browseError = '';
      s.browsing = false;
      s.elapsedSeconds = 0;
    });
  }

  /** 站点相关错误说人话（403/404 是最常见的两种） */
  private humanizeSiteError(e: Error): string {
    const msg: string = e.message.length > 0 ? e.message : '加载失败';
    const code: number = e instanceof ApiException ? (e as ApiException).code : 0;
    if (code === 403 || msg.indexOf('认证失败') >= 0) {
      return '当前凭据没有管理员权限。站点接口只对 MP 管理员开放：换一个管理员账号，或改用管理员生成的 API Token';
    }
    if (code === 404) {
      return '这个 MoviePilot 版本没有站点接口（需要 v3.1 以上）';
    }
    if (msg.indexOf('超时') >= 0 || msg.indexOf('timeout') >= 0 || msg.indexOf('imeout') >= 0) {
      return '请求超时，站点可能在抓取中被卡住，稍后重试';
    }
    return msg;
  }

  // ---------- 订阅 ----------

  loadSubscribes(silent: boolean): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    if (!silent) {
      const s: MpState = this.state.copy();
      s.subscribesLoading = true;
      this.commit(s);
    }
    client.subscribes().then((list: MpSubscribe[]): void => {
      const s2: MpState = this.state.copy();
      s2.subscribes = list;
      s2.subscribesLoading = false;
      this.commit(s2);
    }).catch((e: Error): void => {
      const s2: MpState = this.state.copy();
      s2.subscribesLoading = false;
      this.commit(s2);
      if (!silent) {
        ToastHub.getInstance().show(`订阅加载失败：${e.message}`);
      }
    });
  }

  subscribeMedia(media: MpMedia | null, season: number): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null || media === null) {
      return;
    }
    ToastHub.getInstance().show('正在订阅…');
    client.subscribe(media, season).then((message: string): void => {
      ToastHub.getInstance().show(message);
      this.loadSubscribes(true);
    }).catch((e: Error): void => {
      ToastHub.getInstance().show(`订阅失败：${e.message}`);
    });
  }

  deleteSubscribe(id: number): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    client.deleteSubscribe(id).then((): void => {
      ToastHub.getInstance().show('已删除订阅');
      this.loadSubscribes(true);
    }).catch((e: Error): void => {
      ToastHub.getInstance().show(`删除失败：${e.message}`);
    });
  }

  toggleSubscribeState(subscribe: MpSubscribe): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    const next: string = subscribe.state.toUpperCase() === 'R' ? 'S' : 'R';
    client.updateSubscribeState(subscribe.id, next).then((): void => {
      ToastHub.getInstance().show(next === 'R' ? '已恢复订阅' : '已暂停订阅');
      this.loadSubscribes(true);
    }).catch((e: Error): void => {
      ToastHub.getInstance().show(`操作失败：${e.message}`);
    });
  }

  /** 打开订阅设置前，把下载器 / 保存路径 / 站点 / 规则组 / 订阅站点范围备齐 */
  loadSubscribeOptions(): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    if (this.state.downloaders.length === 0) {
      client.downloaders().then((list: MpDownloader[]): void => {
        if (list.length === 0) {
          return;
        }
        const s: MpState = this.state.copy();
        s.downloaders = list;
        this.commit(s);
      }).catch((e: Error): void => {
      });
    }
    if (this.state.savePaths.length === 0) {
      client.savePaths().then((list: MpSavePath[]): void => {
        if (list.length === 0) {
          return;
        }
        const s: MpState = this.state.copy();
        s.savePaths = list;
        this.commit(s);
      }).catch((e: Error): void => {
      });
    }
    if (this.state.site.sites.length === 0) {
      client.sites().then((list: MpSite[]): void => {
        this.commitSite((st: MpSiteState): void => {
          st.sites = list;
        });
      }).catch((e: Error): void => {
      });
    }
    if (this.state.subscribeRuleGroups.length === 0) {
      client.ruleGroups().then((list: string[]): void => {
        if (list.length === 0) {
          return;
        }
        const s: MpState = this.state.copy();
        s.subscribeRuleGroups = list;
        this.commit(s);
      }).catch((e: Error): void => {
      });
    }
    if (this.state.rssSiteIds === null) {
      client.rssSiteIds().then((ids: number[] | null): void => {
        if (ids === null) {
          return;
        }
        const s: MpState = this.state.copy();
        s.rssSiteIds = ids;
        this.commit(s);
      }).catch((e: Error): void => {
      });
    }
  }

  /** 保存订阅设置；onResult 告诉界面该不该关页面（ArkTS 里由界面传回调置 flag） */
  saveSubscribe(sub: MpSubscribe, onResult: (ok: boolean) => void): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      onResult(false);
      return;
    }
    ToastHub.getInstance().show('正在保存订阅设置…');
    client.updateSubscribe(sub).then((): void => {
      ToastHub.getInstance().show('订阅设置已保存');
      this.loadSubscribes(true);
      onResult(true);
    }).catch((e: Error): void => {
      ToastHub.getInstance().show(`保存失败：${e.message}`);
      onResult(false);
    });
  }

  /**
   * 保存成功后，把刚提交的值就地写回列表里的那条订阅。
   *
   * 为什么不只靠 [loadSubscribes]：它是异步的，网慢的时候界面还停在旧值，
   * 用户会认为「保存没生效」（历史上多次被这么反馈）。本地先落地一份，
   * 随后那次静默刷新再把服务端的权威数据盖回来。
   */
  applySavedSubscribe(sub: MpSubscribe): void {
    const list: MpSubscribe[] = this.state.subscribes.slice();
    let hit: number = -1;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === sub.id) {
        hit = i;
        break;
      }
    }
    if (hit < 0) {
      return;
    }
    const old: MpSubscribe = list[hit];
    // 只覆盖用户能编辑的字段，展示用字段（海报/集数/状态/更新时间）沿用服务端的
    old.keyword = sub.keyword;
    old.quality = sub.quality;
    old.resolution = sub.resolution;
    old.effect = sub.effect;
    old.sites = sub.sites.slice();
    old.searchInterval = sub.searchInterval;
    old.downloader = sub.downloader;
    old.savePath = sub.savePath;
    old.bestVersion = sub.bestVersion;
    old.searchImdbId = sub.searchImdbId;
    old.include = sub.include;
    old.exclude = sub.exclude;
    old.filterGroups = sub.filterGroups.slice();
    old.mediaCategory = sub.mediaCategory;
    old.customWords = sub.customWords;
    const s: MpState = this.state.copy();
    s.subscribes = list;
    this.commit(s);
  }

  /** 立即搜索这一条订阅 */
  searchSubscribeNow(sub: MpSubscribe): void {    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    ToastHub.getInstance().show(`正在搜索《${sub.name}》…`);
    client.searchSubscribe(sub.id).then((message: string): void => {
      ToastHub.getInstance().show(message);
    }).catch((e: Error): void => {
      ToastHub.getInstance().show(`搜索失败：${e.message}`);
    });
  }

  /** 重置订阅（清空已完成集数） */
  resetSubscribe(sub: MpSubscribe): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    client.resetSubscribe(sub.id).then((): void => {
      ToastHub.getInstance().show(`已重置《${sub.name}》`);
      this.loadSubscribes(true);
    }).catch((e: Error): void => {
      ToastHub.getInstance().show(`重置失败：${e.message}`);
    });
  }

  closeSubscribePanel(): void {
    const s: MpState = this.state.copy();
    s.subscribePanel = null;
    this.commit(s);
  }

  /**
   * 订阅活动：MP 的历史接口只能按「电影 / 电视剧」整批拉，没有按订阅 id 的过滤，
   * 只能客户端按名称筛；同名多季会混在一起，这点和 MP 网页一致。
   */
  openSubscribeActivity(sub: MpSubscribe): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    const title: string = `订阅活动 · ${sub.name}`;
    const loading: MpState = this.state.copy();
    const panel: SubscribePanel = new SubscribePanel(title);
    panel.loading = true;
    loading.subscribePanel = panel;
    this.commit(loading);

    client.subscribeHistory(sub.type).then((items: Object[]): void => {
      const lines: string[] = [];
      for (const raw of items) {
        const item: Record<string, Object> = raw as Record<string, Object>;
        if (jStr(item, ['name']).trim() !== sub.name.trim()) {
          continue;
        }
        const whenText: string = jStr(item, ['last_update']).length > 0
          ? jStr(item, ['last_update']) : jStr(item, ['date']);
        const stateText: string = jStr(item, ['state'], 'R');
        const lack: number = Math.trunc(jNum(item, ['lack_episode'], 0));
        lines.push(`${whenText} · ${stateText}` + (lack > 0 ? ` · 缺 ${lack} 集` : ' · 已完成'));
      }
      const s: MpState = this.state.copy();
      const done: SubscribePanel = new SubscribePanel(title);
      done.lines = lines.length > 0 ? lines : ['暂无活动记录'];
      s.subscribePanel = done;
      this.commit(s);
    }).catch((e: Error): void => {
      const s: MpState = this.state.copy();
      const failed: SubscribePanel = new SubscribePanel(title);
      failed.error = `拉取失败：${e.message}`;
      s.subscribePanel = failed;
      this.commit(s);
    });
  }

  /** 文件统计：按集汇总「已入库 / 下载中」 */
  openSubscribeFiles(sub: MpSubscribe): void {
    const client: MoviePilotClient | null = this.client();
    if (client === null) {
      return;
    }
    const title: string = `文件统计 · ${sub.name}`;
    const loading: MpState = this.state.copy();
    const panel: SubscribePanel = new SubscribePanel(title);
    panel.loading = true;
    loading.subscribePanel = panel;
    this.commit(loading);

    client.subscribeFiles(sub.id).then((result: Object): void => {
      const root: Record<string, Object> = result as Record<string, Object>;
      const eps: Record<string, Object> | null = jObj(root, 'episodes');
      const lines: string[] = [];
      let downloaded: number = 0;
      let inLibrary: number = 0;
      let total: number = 0;
      if (eps !== null) {
        const keys: string[] = Object.keys(eps);
        keys.sort((a: string, b: string): number => {
          const na: number = parseInt(a, 10);
          const nb: number = parseInt(b, 10);
          return (isNaN(na) ? 0 : na) - (isNaN(nb) ? 0 : nb);
        });
        for (const key of keys) {
          const ep: Object | undefined = eps[key];
          if (ep === undefined || ep === null) {
            continue;
          }
          const item: Record<string, Object> = ep as Record<string, Object>;
          const dl: Array<Record<string, Object>> = jArr(item, 'download') ?? [];
          const lib: Array<Record<string, Object>> = jArr(item, 'library') ?? [];
          total++;
          if (dl.length > 0) {
            downloaded++;
          }
          if (lib.length > 0) {
            inLibrary++;
          }
          lines.push(`第 ${key} 集` + (lib.length > 0 ? '（已入库）' : ''));
          let shown: number = 0;
          for (const f of lib) {
            const path: string = jStr(f, ['file_path']);
            if (path.length > 0 && shown < 3) {
              lines.push(`  ${path}`);
              shown++;
            }
          }
          for (const d of dl) {
            if (shown >= 3) {
              break;
            }
            const torrentTitle: string = jStr(d, ['torrent_title']);
            lines.push(torrentTitle.length > 0 ? `  下载中：${torrentTitle}` : '  下载中');
            shown++;
          }
        }
      }
      const summary: string = total === 0
        ? '暂无关联文件'
        : `共 ${total} 集 · 已入库 ${inLibrary} 集 · 下载中 ${downloaded} 集`;

      const s: MpState = this.state.copy();
      const done: SubscribePanel = new SubscribePanel(title);
      const out: string[] = [summary];
      for (const line of lines) {
        out.push(line);
      }
      done.lines = out;
      s.subscribePanel = done;
      this.commit(s);
    }).catch((e: Error): void => {
      const s: MpState = this.state.copy();
      const failed: SubscribePanel = new SubscribePanel(title);
      failed.error = `拉取失败：${e.message}`;
      s.subscribePanel = failed;
      this.commit(s);
    });
  }

  /** 媒体详情：用订阅里存的媒体身份打开详情，不重新搜 */
  openSubscribeMedia(sub: MpSubscribe): void {
    const lower: string = sub.mediaSource.toLowerCase();
    let source: string = '';
    if (lower === 'douban') {
      source = 'douban';
    } else if (lower === 'bangumi') {
      source = 'bangumi';
    } else if (lower === 'themoviedb' || lower === 'tmdb') {
      source = 'tmdb';
    } else if (sub.tmdbId > 0) {
      source = 'tmdb';
    } else if (sub.doubanId.length > 0) {
      source = 'douban';
    } else if (sub.bangumiId > 0) {
      source = 'bangumi';
    }

    let rawId: string = sub.mediaIdRaw;
    if (rawId.length === 0) {
      if (sub.tmdbId > 0) {
        rawId = String(sub.tmdbId);
      } else if (sub.doubanId.length > 0) {
        rawId = sub.doubanId;
      } else if (sub.bangumiId > 0) {
        rawId = String(sub.bangumiId);
      }
    }
    const colon: number = rawId.indexOf(':');
    if (colon >= 0) {
      rawId = rawId.substring(colon + 1);
    }
    if (source.length === 0 || rawId.length === 0) {
      ToastHub.getInstance().show('这条订阅没存媒体身份，打不开详情');
      return;
    }

    const media: MpMedia = new MpMedia();
    media.mediaId = `${source}:${rawId}`;
    media.source = source;
    media.type = sub.type === '电视剧' ? '电视剧' : '电影';
    media.title = sub.name;
    media.year = sub.year;
    media.season = sub.season;
    media.posterUrl = sub.posterUrl;
    if (source === 'tmdb') {
      media.tmdbId = sub.tmdbId > 0 ? sub.tmdbId : parseInt(rawId, 10);
    } else if (source === 'douban') {
      media.doubanId = rawId;
    } else if (source === 'bangumi') {
      media.bangumiId = sub.bangumiId > 0 ? sub.bangumiId : parseInt(rawId, 10);
    }
    this.openDetail(media);
  }
}
