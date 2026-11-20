import { ServerConfig, serverConfigFromJson } from './Models';
import { RssSource, rssSourceFromJson } from './RssModels';
import { MpServer, mpServerFromJson } from './MpModels';
import { jStr, jNum, jBool, jStrList, jArr, jObj } from '../common/AppConstants';

/**
 * 应用设置与持久化状态形状（对应安卓 data/ConfigStore.kt 的模型部分）。
 */

export class AppSettings {
  refreshSeconds: number = 5;
  rssRefreshMinutes: number = 30;
  theme: string = 'system';
  fontScale: number = 1.0;
  dashboardOrder: string[] = ['liveTraffic', 'globalAssets', 'serverStatus', 'storageAudit', 'recentFinished'];
  hiddenModules: string[] = [];
  hideTracker: boolean = false;
  moviePilotRefreshMinutes: number = 30;
  showModuleTraffic: boolean = true;
  showModuleAssets: boolean = true;
  showModuleServers: boolean = true;
  /** RSS 后台刷新开关（关掉就只在前台检查） */
  rssBackground: boolean = true;
  /** RSS 仅在 WiFi 下刷新 */
  rssWifiOnly: boolean = false;
  /** RSS 仅在充电时刷新 */
  rssChargingOnly: boolean = false;
  /** RSS 自动推送结果通知 */
  rssNotify: boolean = true;
  /** MoviePilot 默认下载器名称，空 = 由 MP 自动选择 */
  mpDefaultDownloader: string = '';
  /** MoviePilot 默认保存路径，空 = 由 MP 自动选择 */
  mpDefaultSavePath: string = '';
  /** 仪表盘「媒体库」模块（数据取自 MoviePilot 仪表盘） */
  showModuleMedia: boolean = true;
  /** Songloft 音乐服务地址，空 = 未接入（音乐页会显示接入引导），支持多行地址 */
  musicUrl: string = '';
  /** Songloft 登录账号 */
  musicUser: string = '';
  /** Songloft 登录密码 */
  musicPass: string = '';
  /**
   * 站点显示白名单（存站点名）。空数组 = 全部站点。
   * 只影响 APP 里「站点」页显示哪些站，以及在某站搜索时是否发起请求；
   * 想真正减少 MP 的站点压力，仍需在 MP 后台停用站点（索引器压根不会请求）。
   */
  mpSiteFilter: string[] = [];
}

export function appSettingsFromJson(o: Record<string, Object>): AppSettings {
  const s: AppSettings = new AppSettings();
  s.refreshSeconds = Math.trunc(jNum(o, ['refreshSeconds', 'refresh_seconds'], 5));
  s.rssRefreshMinutes = Math.trunc(jNum(o, ['rssRefreshMinutes', 'rss_refresh_minutes'], 30));
  s.theme = jStr(o, ['theme'], 'system');
  s.fontScale = jNum(o, ['fontScale', 'font_scale'], 1.0);
  s.dashboardOrder = jStrList(o, ['dashboardOrder', 'dashboard_order'], s.dashboardOrder);
  s.hiddenModules = jStrList(o, ['hiddenModules', 'hidden_modules'], []);
  s.hideTracker = jBool(o, ['hideTracker', 'hide_tracker']);
  s.moviePilotRefreshMinutes =
    Math.trunc(jNum(o, ['moviePilotRefreshMinutes', 'movie_pilot_refresh_minutes'], 30));
  s.showModuleTraffic = jBool(o, ['showModuleTraffic', 'show_module_traffic'], true);
  s.showModuleAssets = jBool(o, ['showModuleAssets', 'show_module_assets'], true);
  s.showModuleServers = jBool(o, ['showModuleServers', 'show_module_servers'], true);
  s.rssBackground = jBool(o, ['rssBackground', 'rss_background'], true);
  s.rssWifiOnly = jBool(o, ['rssWifiOnly', 'rss_wifi_only']);
  s.rssChargingOnly = jBool(o, ['rssChargingOnly', 'rss_charging_only']);
  s.rssNotify = jBool(o, ['rssNotify', 'rss_notify'], true);
  s.mpDefaultDownloader = jStr(o, ['mpDefaultDownloader', 'mp_default_downloader']);
  s.mpDefaultSavePath = jStr(o, ['mpDefaultSavePath', 'mp_default_save_path']);
  s.showModuleMedia = jBool(o, ['showModuleMedia', 'show_module_media'], true);
  s.musicUrl = jStr(o, ['musicUrl', 'music_url']);
  s.musicUser = jStr(o, ['musicUser', 'music_user']);
  s.musicPass = jStr(o, ['musicPass', 'music_pass']);
  s.mpSiteFilter = jStrList(o, ['mpSiteFilter', 'mp_site_filter'], []);
  return s;
}

/** Hero 轮播海报的精简缓存条目（只存显示需要的字段，不整包 MpMedia 序列化） */
export class HeroCacheItem {
  mediaId: string = '';
  title: string = '';
  year: string = '';
  type: string = '';
  overview: string = '';
  posterUrl: string = '';
  backdropUrl: string = '';
  vote: number = 0;
  genres: string[] = [];
}

/** Hero 轮播缓存：记下是哪个 MP server 的，切服务器后不复用旧图 */
export class HeroCache {
  serverKey: string = '';
  fetchedAt: number = 0;
  items: HeroCacheItem[] = [];
}

export function heroCacheItemFromJson(o: Record<string, Object>): HeroCacheItem {
  const it: HeroCacheItem = new HeroCacheItem();
  it.mediaId = jStr(o, ['mediaId']);
  it.title = jStr(o, ['title']);
  it.year = jStr(o, ['year']);
  it.type = jStr(o, ['type']);
  it.overview = jStr(o, ['overview']);
  it.posterUrl = jStr(o, ['posterUrl']);
  it.backdropUrl = jStr(o, ['backdropUrl']);
  it.vote = jNum(o, ['vote']);
  it.genres = jStrList(o, ['genres'], []);
  return it;
}

export function heroCacheFromJson(o: Record<string, Object>): HeroCache {
  const c: HeroCache = new HeroCache();
  c.serverKey = jStr(o, ['serverKey']);
  c.fetchedAt = jNum(o, ['fetchedAt']);
  const items: HeroCacheItem[] = [];
  const raw: Array<Record<string, Object>> | null = jArr(o, 'items');
  if (raw !== null) {
    for (const io of raw) {
      items.push(heroCacheItemFromJson(io));
    }
  }
  c.items = items;
  return c;
}

export class PersistedState {
  servers: ServerConfig[] = [];
  /** null 表示聚合查看所有服务器 */
  activeServerId: string | null = null;
  settings: AppSettings = new AppSettings();
  rssSources: RssSource[] = [];
  mpServers: MpServer[] = [];
  activeMpServerId: string | null = null;
  /** 首屏 Hero 海报轮播缓存（离线/弱网首屏用）；null = 无缓存 */
  heroCache: HeroCache | null = null;
}

export function persistedStateFromJson(o: Record<string, Object>): PersistedState {
  const st: PersistedState = new PersistedState();

  const servers: ServerConfig[] = [];
  const serverObjs: Array<Record<string, Object>> | null = jArr(o, 'servers');
  if (serverObjs !== null) {
    for (const so of serverObjs) {
      servers.push(serverConfigFromJson(so));
    }
  }
  st.servers = servers;

  const activeId: Object | undefined = o['activeServerId'];
  if (typeof activeId === 'string' && activeId.length > 0) {
    st.activeServerId = activeId;
  } else {
    st.activeServerId = null;
  }

  const settingsObj: Record<string, Object> | null = jObj(o, 'settings');
  st.settings = settingsObj !== null ? appSettingsFromJson(settingsObj) : new AppSettings();

  const rss: RssSource[] = [];
  const rssObjs: Array<Record<string, Object>> | null = jArr(o, 'rssSources');
  if (rssObjs !== null) {
    for (const ro of rssObjs) {
      rss.push(rssSourceFromJson(ro));
    }
  }
  st.rssSources = rss;

  const mp: MpServer[] = [];
  const mpObjs: Array<Record<string, Object>> | null = jArr(o, 'mpServers');
  if (mpObjs !== null) {
    for (const mo of mpObjs) {
      mp.push(mpServerFromJson(mo));
    }
  }
  st.mpServers = mp;

  const activeMpId: Object | undefined = o['activeMpServerId'];
  if (typeof activeMpId === 'string' && activeMpId.length > 0) {
    st.activeMpServerId = activeMpId;
  } else {
    st.activeMpServerId = null;
  }

  // Hero 海报缓存（旧配置无此字段 → null，向后兼容）
  const heroObj: Record<string, Object> | null = jObj(o, 'heroCache');
  st.heroCache = heroObj !== null ? heroCacheFromJson(heroObj) : null;

  return st;
}
