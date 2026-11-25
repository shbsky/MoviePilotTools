import { util } from '@kit.ArkTS';
import { Endpoint } from '../model/Models';
import {
  MpServer, MpMedia, MpResource, MpDownloader, MpDownloaderInfo, MpSavePath, MpSubscribe,
  MpStatistic, MpDiscoverChannel, MpStorage, MpMemoryInfo, MpSystemInfo
} from '../model/MpModels';
import {
  MpSite, MpSiteUserData, MpSiteCategory, mpSiteFromJson, mpSiteUserDataFromJson, sortSitesForDisplay
} from '../model/MpSiteModels';
import { ApiException, Reply, get, postForm, postJson, putJson, del, requestStream, TimeoutTier,
  orMessage } from './HttpClient';
import { EndpointResolver } from './EndpointResolver';
import { PosterUrl } from './PosterUrl';
import { parseJsonObject, parseJsonArray, jStr, jNum, jBool, jObj, jArr, jStrArr,
  logWarn } from '../common/AppConstants';

/**
 * MoviePilot 客户端（对应安卓 net/MoviePilotClient.kt）。
 *
 * 认证优先级：配了用户名密码 → 登录取 JWT（这样才能用渐进式搜索，MP 用 Cookie 里的
 * resource_token 校验 SSE）；否则用 API Token（`X-API-KEY`，MP 会当作超级用户）。
 */

/** 演职员条目 */
export class Person {
  name: string = '';
  role: string = '';
  avatar: string = '';

  constructor(name: string = '', role: string = '', avatar: string = '') {
    this.name = name;
    this.role = role;
    this.avatar = avatar;
  }
}

/**
 * 媒体身份拆两段（MP v3 起如此）：
 * - v3：路径只放原生 ID，来源走 `media_source`（themoviedb / douban / bangumi）
 * - v1/v2：`tmdb:550` 这种「来源:ID」单段路径
 * source 为 null 表示识别不出来源，只能走老路径。
 */
class MediaIdentity {
  source: string | null = null;
  rawId: string = '';
  legacyKey: string = '';

  constructor(source: string | null, rawId: string, legacyKey: string) {
    this.source = source;
    this.rawId = rawId;
    this.legacyKey = legacyKey;
  }
}

function distinctStrings(input: string[]): string[] {
  const out: string[] = [];
  for (const s of input) {
    if (out.indexOf(s) < 0) {
      out.push(s);
    }
  }
  return out;
}

export class MoviePilotClient {
  private server: MpServer;
  private jwt: string = '';
  private loginTried: boolean = false;
  /** 当前命中的 MP 地址，用于还原 /api/... 这类相对图片路径 */
  private activeBaseUrl: string = '';

  constructor(server: MpServer) {
    this.server = server;
  }

  // ---------- 基础设施 ----------

  /** 多地址自动切换：逐个候选地址尝试，命中后写入选路缓存 */
  private async withEndpoint<T>(block: (ep: Endpoint) => Promise<T>): Promise<T> {
    const endpoints: Endpoint[] = this.server.activeEndpoints();
    if (endpoints.length === 0) {
      let filled: number = 0;
      for (const ep of this.server.endpoints) {
        if (ep.host.trim().length > 0) {
          filled++;
        }
      }
      throw new ApiException(filled === 0
        ? 'MoviePilot 还没配置访问地址'
        : `已填地址但都不合法（共 ${this.server.endpoints.length} 条），检查域名/IP 是否带了空格或多余符号`);
    }

    let lastError: ApiException = new ApiException('MoviePilot 连接失败');
    const ordered: Endpoint[] = EndpointResolver.candidates(
      this.server.id, endpoints, this.server.endpointMode, this.server.pinnedEndpointIndex);
    for (const endpoint of ordered) {
      try {
        this.activeBaseUrl = endpoint.display();
        const value: T = await block(endpoint);
        EndpointResolver.remember(this.server.id, endpoint);
        return value;
      } catch (e) {
        const err: Error = e as Error;
        if (err instanceof ApiException) {
          // 认证类错误说明地址是对的，不必再换地址
          if (err.message.includes('认证失败')) {
            throw err;
          }
          lastError = err as ApiException;
        } else {
          lastError = new ApiException(err.message.length > 0 ? err.message : '网络错误');
        }
        EndpointResolver.invalidate(this.server.id);
      }
    }
    throw lastError;
  }

  private url(endpoint: Endpoint, path: string, query: string[][] = []): string {
    const base: string = endpoint.display().replace(/\/+$/g, '');
    const cleanPath: string = path.replace(/^\/+/g, '');
    const parts: string[] = [];
    for (const kv of query) {
      if (kv.length === 2 && kv[1].trim().length > 0) {
        parts.push(`${encodeURIComponent(kv[0])}=${encodeURIComponent(kv[1])}`);
      }
    }
    if (parts.length === 0) {
      return `${base}/${cleanPath}`;
    }
    return `${base}/${cleanPath}?${parts.join('&')}`;
  }

  private headers(): Record<string, string> {
    const h: Record<string, string> = {};
    if (this.jwt.length > 0) {
      h['Authorization'] = `Bearer ${this.jwt}`;
    } else {
      const token: string = this.server.apiToken.trim();
      if (token.length > 0) {
        h['X-API-KEY'] = token;
        h['apikey'] = token;
      }
    }
    return h;
  }

  /** 有账号密码时登录取 JWT（同时让 MP 把 resource_token 写进 CookieJar，渐进式搜索才可用） */
  private async ensureLogin(): Promise<boolean> {
    if (!this.server.hasLogin()) {
      return false;
    }
    if (this.jwt.length > 0) {
      return true;
    }
    if (this.loginTried) {
      return this.jwt.length > 0;
    }
    this.loginTried = true;
    const endpoints: Endpoint[] = this.server.activeEndpoints();
    if (endpoints.length === 0) {
      return false;
    }
    const form: Record<string, string> = {
      'username': this.server.username,
      'password': this.server.password
    };
    // 逐个地址试：选路命中的不一定是第一个。原来只打 endpoints[0]，
    // 第一条不通时 loginTried 被永久置位，后续所有接口都因无 JWT 报 401。
    for (const ep of endpoints) {
      try {
        const loginUrl: string = this.url(ep, 'api/v1/login/access-token');
        const reply: Reply = await postForm(loginUrl, form);
        if (!reply.isSuccessful()) {
          continue;
        }
        const obj: Record<string, Object> | null = parseJsonObject(reply.body);
        if (obj === null) {
          continue;
        }
        let token: string = jStr(obj, ['access_token']);
        if (token.length === 0) {
          // 部分版本把 token 放在 data.access_token
          const data: Record<string, Object> | null = jObj(obj, 'data');
          if (data !== null) {
            token = jStr(data, ['access_token']);
          }
        }
        if (token.length === 0) {
          continue;
        }
        this.jwt = token;
        return true;
      } catch (e) {
        // 这个地址不通，换下一个
      }
    }
    return false;
  }

  /** 「来源:ID」→ v3 的两段式身份；识别不出来源时 source 为 null（只能走老路径） */
  private mediaIdentity(media: MpMedia): MediaIdentity {
    const key: string = media.searchKey();
    const sep: number = key.indexOf(':');
    if (sep > 0) {
      const prefix: string = key.substring(0, sep).toLowerCase();
      let source: string | null = null;
      if (prefix === 'tmdb' || prefix === 'themoviedb') {
        source = 'themoviedb';
      } else if (prefix === 'douban') {
        source = 'douban';
      } else if (prefix === 'bangumi') {
        source = 'bangumi';
      }
      if (source !== null) {
        return new MediaIdentity(source, key.substring(sep + 1), key);
      }
    }
    return new MediaIdentity(null, key, key);
  }

  /**
   * 判断失败是不是「接口版本不对」：v2 收到 v3 参数会回「未知的媒体ID」，
   * v3 收到 v2 参数会报 422（缺 media_source）/ 404。只有这几种才换拼法重试。
   */
  private isVersionMismatch(message: string): boolean {
    return message.indexOf('未知的媒体ID') >= 0 || message.indexOf('HTTP 422') >= 0 ||
      message.indexOf('HTTP 404') >= 0 || message.indexOf('接口不存在') >= 0;
  }

  private describeError(code: number, body: string): string {
    let detail: string = '';
    const obj: Record<string, Object> | null = parseJsonObject(body);
    if (obj !== null) {
      detail = jStr(obj, ['detail']);
      if (detail.length === 0) {
        // 422 的字段级原因在 data 数组里：[{loc:["cookie","xxx"], msg:"Field required"}]
        const data: Array<Record<string, Object>> | null = jArr(obj, 'data');
        if (data !== null && data.length > 0) {
          const first: Record<string, Object> = data[0];
          const loc: string[] = jStrArr(first, ['loc']);
          const msg: string = jStr(first, ['msg']);
          const field: string = loc.join('.');
          detail = field.length > 0 ? (msg.length > 0 ? `${field} ${msg}` : field) : msg;
        }
      }
      if (detail.length === 0) {
        detail = jStr(obj, ['message']);
      }
    }
    if (code === 401 || code === 403) {
      return detail.length > 0 ? `认证失败（检查 API Token）：${detail}` : '认证失败（检查 API Token）';
    }
    if (code === 404) {
      return '接口不存在（HTTP 404）：核对端口 / 子路径是否正确，或该地址指向的不是 MoviePilot';
    }
    if (code === 422) {
      return detail.length > 0
        ? `参数不被 MP 接受（HTTP 422）：${detail}`
        : '参数不被 MP 接受（HTTP 422）：可能是 MP 版本与 App 不匹配';
    }
    return `HTTP ${code} ${detail.substring(0, 80)}`;
  }

  private async requestJson(path: string, query: string[][] = [], method: string = 'GET',
    body: Record<string, Object> | null = null, slow: boolean = false): Promise<Object> {
    return await this.withEndpoint<Object>(async (endpoint: Endpoint): Promise<Object> => {
      await this.ensureLogin();
      const requestUrl: string = this.url(endpoint, path, query);
      const tier: number = slow ? TimeoutTier.SLOW : TimeoutTier.NORMAL;
      let reply: Reply;
      if (method === 'GET') {
        reply = await get(requestUrl, this.headers(), tier);
      } else if (method === 'PUT') {
        reply = await putJson(requestUrl, JSON.stringify(body === null ? {} : body), this.headers(), tier);
      } else if (method === 'DELETE') {
        reply = await del(requestUrl, this.headers(), tier);
      } else {
        reply = await postJson(requestUrl, JSON.stringify(body === null ? {} : body), this.headers(), tier);
      }
      if (!reply.isSuccessful()) {
        throw new ApiException(this.describeError(reply.code, reply.body), reply.code);
      }
      if (reply.body.trim().length === 0) {
        const empty1: Record<string, Object> = {};
        return empty1;
      }
      const obj: Record<string, Object> | null = parseJsonObject(reply.body);
      if (obj !== null) {
        return obj;
      }
      const arr: Array<Record<string, Object>> | null = parseJsonArray(reply.body);
      if (arr !== null) {
        return arr;
      }
      const empty2: Record<string, Object> = {};
      return empty2;
    });
  }

  /** 兼容 {data: [...]}、{data:{items:[...]}} 与裸数组 */
  private listFrom(result: Object): Array<Record<string, Object>> {
    if (Array.isArray(result)) {
      return result as Array<Record<string, Object>>;
    }
    const obj: Record<string, Object> = result as Record<string, Object>;
    const data: Object | undefined = obj['data'];
    if (data !== undefined && data !== null) {
      if (Array.isArray(data)) {
        return data as Array<Record<string, Object>>;
      }
      if (typeof data === 'object') {
        const d: Record<string, Object> = data as Record<string, Object>;
        const items: Array<Record<string, Object>> | null = jArr(d, 'items');
        if (items !== null) {
          return items;
        }
        const list: Array<Record<string, Object>> | null = jArr(d, 'list');
        if (list !== null) {
          return list;
        }
        return [];
      }
    }
    const top: Array<Record<string, Object>> | null = jArr(obj, 'items');
    return top !== null ? top : [];
  }

  /** 原始文本响应（CPU 接口某些版本直接吐裸浮点，不能按 JSON 对象解析）。 */
  private async requestText(path: string, query: string[][] = []): Promise<string> {
    return await this.withEndpoint<string>(async (endpoint: Endpoint): Promise<string> => {
      await this.ensureLogin();
      const reply: Reply = await get(this.url(endpoint, path, query), this.headers(), TimeoutTier.NORMAL);
      if (!reply.isSuccessful()) {
        throw new ApiException(this.describeError(reply.code, reply.body), reply.code);
      }
      return reply.body;
    });
  }

  /** 仪表盘通用取数：JWT 优先，失败退 `${name}2?token=`；统一拆 {success,data}。 */
  private async dashboardObject(name: string, tokenFallback: boolean = true): Promise<Record<string, Object>> {
    let raw: Object;
    try {
      raw = await this.requestJson(`api/v1/dashboard/${name}`);
    } catch (e) {
      const token: string = this.server.apiToken.trim();
      if (!tokenFallback || token.length === 0) {
        throw e as Error;
      }
      raw = await this.requestJson(`api/v1/dashboard/${name}2`, [['token', token]]);
    }
    if (!Array.isArray(raw)) {
      const obj: Record<string, Object> = raw as Record<string, Object>;
      const data: Record<string, Object> | null = jObj(obj, 'data');
      return data !== null ? data : obj;
    }
    const empty: Record<string, Object> = {};
    return empty;
  }

  private num(obj: Record<string, Object>, keys: string[]): number {
    return Math.trunc(jNum(obj, keys));
  }

  private dec(obj: Record<string, Object>, keys: string[]): number {
    return jNum(obj, keys);
  }

  /** MP 仪表盘「实时速率」：与网页那张卡同口径。 */
  async dashboardDownloader(): Promise<MpDownloaderInfo> {
    const obj: Record<string, Object> = await this.dashboardObject('downloader');
    const info: MpDownloaderInfo = new MpDownloaderInfo();
    info.downloadSpeed = this.num(obj, ['download_speed', 'download', 'dl_speed']);
    info.uploadSpeed = this.num(obj, ['upload_speed', 'upload', 'ul_speed']);
    info.downloadSize = this.num(obj, ['download_size', 'downloaded', 'total_downloaded']);
    info.uploadSize = this.num(obj, ['upload_size', 'uploaded', 'total_uploaded']);
    info.freeSpace = this.num(obj, ['free_space', 'free', 'free_space_bytes']);
    if (info.isEmpty()) {
      // MP 服务端没配下载目录 / 下载器采样为空时，它会直接回一份全 0 的 DownloaderInfo，
      // 网页那张卡也一样是 0。把原始返回留一条日志，排查时不用再猜。
      logWarn('MoviePilot',
        `dashboard/downloader 五项全 0，raw=${JSON.stringify(obj).substring(0, 200)}`);
    }
    return info;
  }

  /**
   * CPU 当前百分比。兼容裸浮点、{data:12.3}、{data:{cpu:12.3}}；
   * 解析失败返回 NaN，VM 丢弃这次采样。
   */
  async dashboardCpu(): Promise<number> {
    let text: string;
    try {
      text = await this.requestText('api/v1/dashboard/cpu');
    } catch (e) {
      const token: string = this.server.apiToken.trim();
      if (token.length === 0) {
        throw e as Error;
      }
      text = await this.requestText('api/v1/dashboard/cpu2', [['token', token]]);
    }
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      return NaN;
    }
    const bare: number = Number(trimmed);
    if (!Number.isNaN(bare)) {
      return Math.min(100, Math.max(0, bare));
    }
    const root: Record<string, Object> | null = parseJsonObject(trimmed);
    if (root === null) {
      return NaN;
    }
    const data: Object | undefined = root['data'];
    let value: number = NaN;
    if (typeof data === 'number') {
      value = data;
    } else if (typeof data === 'string') {
      value = Number(data);
    } else if (data !== null && data !== undefined && typeof data === 'object') {
      value = jNum(data as Record<string, Object>, ['cpu', 'cpu_usage', 'usage', 'value']);
    } else {
      value = jNum(root, ['cpu', 'cpu_usage', 'usage', 'value']);
    }
    return Number.isNaN(value) ? NaN : Math.min(100, Math.max(0, value));
  }

  /** 内存：total/used/cached/available 为字节，usage 为百分比。 */
  async dashboardMemory(): Promise<MpMemoryInfo> {
    const obj: Record<string, Object> = await this.dashboardObject('memory');
    const info: MpMemoryInfo = new MpMemoryInfo();
    info.total = this.num(obj, ['total', 'total_memory']);
    info.used = this.num(obj, ['used', 'used_memory']);
    info.cached = this.num(obj, ['cached', 'cached_memory']);
    info.available = this.num(obj, ['available', 'available_memory']);
    const usage: number = this.dec(obj, ['usage', 'usage_percent', 'percent']);
    info.usage = Math.min(100, Math.max(0, usage));
    return info;
  }

  /**
   * 系统信息。MP 没有 system2?token= 变体，只有登录管理员 JWT 可读；
   * 仅配 API Token 时抛认证错误，VM 转成降级文案，不影响 CPU / 内存。
   */
  async dashboardSystem(): Promise<MpSystemInfo> {
    const obj: Record<string, Object> = await this.dashboardObject('system', false);
    const info: MpSystemInfo = new MpSystemInfo();
    info.hostname = jStr(obj, ['hostname', 'host']);
    info.operatingSystem = jStr(obj, ['operating_system', 'os', 'platform']);
    info.runtime = jStr(obj, ['runtime', 'python_version']);
    info.version = jStr(obj, ['version', 'app_version']);
    return info;
  }

  // ---------- 仪表盘媒体统计 ----------

  /**
   * 媒体库统计（电影/电视剧/剧集/用户 + 本月新增）。
   * 先走 JWT 的 dashboard/statistic；只有 API Token 时退回 statistic2?token=。
   * v2 起响应外面套了一层 {success, data}，这里统一拆开。
   */
  async statistic(): Promise<MpStatistic> {
    let raw: Object;
    try {
      raw = await this.requestJson('api/v1/dashboard/statistic');
    } catch (e) {
      const err: Error = e as Error;
      const token: string = this.server.apiToken.trim();
      if (token.length === 0) {
        throw err;
      }
      raw = await this.requestJson('api/v1/dashboard/statistic2', [['token', token]]);
    }
    let obj: Record<string, Object> = {};
    if (!Array.isArray(raw)) {
      const o: Record<string, Object> = raw as Record<string, Object>;
      const data: Record<string, Object> | null = jObj(o, 'data');
      obj = data !== null ? data : o;
    }
    const st: MpStatistic = new MpStatistic();
    st.movies = Math.trunc(jNum(obj, ['movie_count']));
    st.tvs = Math.trunc(jNum(obj, ['tv_count']));
    st.episodes = Math.trunc(jNum(obj, ['episode_count']));
    st.users = Math.trunc(jNum(obj, ['user_count']));
    // 音乐是可选字段：MP 官方统计里没有就保持 0，不影响其它格子
    st.music = Math.trunc(jNum(obj, ['music_count']));
    st.moviesThisMonth = Math.trunc(jNum(obj, ['movie_count_month']));
    st.tvsThisMonth = Math.trunc(jNum(obj, ['tv_count_month']));
    st.episodesThisMonth = Math.trunc(jNum(obj, ['episode_count_month']));
    st.musicThisMonth = Math.trunc(jNum(obj, ['music_count_month']));
    return st;
  }

  /**
   * 本地存储空间（挂载盘的真实剩余）：v2/v3 都是 `/api/v1/dashboard/storage`，
   * 返回 {total_storage, used_storage}（字节，浮点）。
   * JWT 走 storage（v2 要求超管），API Token 走 storage2?token=。
   * 下载器的 free_space 只是它自己那个目录所在的盘，同盘多实例还会重复，
   * 所以仪表盘「剩余空间」优先吃这份。
   */
  async storage(): Promise<MpStorage> {
    const token: string = this.server.apiToken.trim();
    let raw: Object | null = null;
    let lastErr: string = '';
    let via: string = '';

    // 1) API Token 通道（MP 官方给外部程序的 /storage2?token=）
    if (token.length > 0) {
      try {
        raw = await this.requestJson('api/v1/dashboard/storage2', [['token', token]]);
        via = 'storage2(token)';
      } catch (e) {
        lastErr = orMessage(e as Error);
      }
    }
    // 2) 登录态通道（用户名密码登录的 JWT）
    if (raw === null) {
      try {
        raw = await this.requestJson('api/v1/dashboard/storage');
        via = 'storage(jwt)';
      } catch (e) {
        if (lastErr.length === 0) {
          lastErr = orMessage(e as Error);
        }
      }
    }
    if (raw === null) {
      logWarn('MoviePilot', `storage 取不到：${lastErr}`);
      throw new ApiException(lastErr.length > 0 ? lastErr : '存储接口不可用');
    }

    let obj: Record<string, Object> = {};
    if (!Array.isArray(raw)) {
      const o: Record<string, Object> = raw as Record<string, Object>;
      const data: Record<string, Object> | null = jObj(o, 'data');
      obj = data !== null ? data : o;
    }
    const st: MpStorage = new MpStorage();
    st.totalBytes = Math.trunc(jNum(obj, ['total_storage', 'total']));
    st.usedBytes = Math.trunc(jNum(obj, ['used_storage', 'used']));
    // 带上是哪台服务器、走的哪条通道、是不是有登录态，方便区分「服务端算出来就是 0」
    const eps: Endpoint[] = this.server.activeEndpoints();
    const epText: string = eps.length > 0 ? `${eps[0].host}:${eps[0].port}` : '无入口';
    logWarn('MoviePilot',
      `storage [${this.server.displayName()} ${epText} via ${via} login=${this.server.hasLogin()} token=${token.length > 0}] ` +
      `raw=${JSON.stringify(obj).substring(0, 200)} -> total=${st.totalBytes} used=${st.usedBytes}`);

    // v2 的 dashboard/storage 只统计「媒体库目录」所在盘（DirectoryHelper.dirs 里
    // library_storage 非空的那些）。用户只配了「设置 → 存储 & 目录」里的存储、
    // 没配媒体库目录时，这两个字段就恒为 0。这时改读各存储的实际用量汇总。
    if (st.totalBytes <= 0) {
      const byUsage: MpStorage = await this.storageFromUsage(token);
      if (byUsage.totalBytes > 0) {
        logWarn('MoviePilot',
          `storage 改用「存储 & 目录」用量汇总 total=${byUsage.totalBytes} used=${byUsage.usedBytes}`);
        return byUsage;
      }
    }
    return st;
  }

  /**
   * v2 兜底：`设置 → 存储 & 目录` 里登记的各存储逐个查实际用量再汇总。
   *
   * - `GET /api/v1/system/setting/Storages` → [{type,name,config}, ...]
   * - `GET /api/v1/storage/usage/{type}` → {total, available}（v3 已移除该接口）
   * 用 type（local/alipan/u115…，纯 ASCII）而不是 name（中文）拼路径：
   * 实测 usage/本地 返回 0，usage/local 才是真值。
   * 同一块盘被多个存储条目指到会重复计数，按 total+available 组合去重。
   */
  private async storageFromUsage(token: string): Promise<MpStorage> {
    const out: MpStorage = new MpStorage();
    let items: Array<Record<string, Object>> = [];
    try {
      const q: string[][] = token.length > 0 ? [['token', token]] : [];
      const raw: Object = await this.requestJson('api/v1/system/setting/Storages', q);
      const root: Record<string, Object> = raw as Record<string, Object>;
      const data: Record<string, Object> | null = jObj(root, 'data');
      const holder: Record<string, Object> = data !== null ? data : root;
      const arr: Array<Record<string, Object>> | null = jArr(holder, 'value');
      if (arr !== null) {
        items = arr;
      }
    } catch (e) {
      return out;
    }

    let total: number = 0;
    let available: number = 0;
    const seen: string[] = [];
    let tried: number = 0;
    for (const item of items) {
      if (tried >= 6) {
        break;
      }
      const type: string = jStr(item, ['type']);
      if (type.length === 0) {
        continue;
      }
      tried++;
      try {
        const q: string[][] = token.length > 0 ? [['token', token]] : [];
        const raw: Object = await this.requestJson(`api/v1/storage/usage/${type}`, q);
        const root: Record<string, Object> = raw as Record<string, Object>;
        const data: Record<string, Object> | null = jObj(root, 'data');
        const obj: Record<string, Object> = data !== null ? data : root;
        const t: number = jNum(obj, ['total']);
        const a: number = jNum(obj, ['available']);
        if (t > 0) {
          const sig: string = `${Math.trunc(t)}:${Math.trunc(a)}`;
          if (seen.indexOf(sig) < 0) {
            seen.push(sig);
            total += t;
            available += a;
          }
        }
      } catch (e) {
        // 该存储未配置 / v3 没有这个接口，跳过
      }
    }
    if (total > 0) {
      out.totalBytes = Math.trunc(total);
      out.usedBytes = Math.trunc(total - available);
      if (out.usedBytes < 0) {
        out.usedBytes = 0;
      }
    }
    return out;
  }

  // ---------- 连接测试 ----------
  async testConnection(): Promise<string> {
    return await this.withEndpoint<string>(async (endpoint: Endpoint): Promise<string> => {
      await this.ensureLogin();

      // 1) 先确认这个地址上真的有 MoviePilot 的 API。
      //    login/access-token 在 v1/v2 都存在且只接受 POST，用 GET 打它：
      //    405/401/403 都说明路由在（只是方法/鉴权不对），404 才是路径或服务不对。
      let routeOk: boolean = false;
      try {
        const r1: Reply = await get(this.url(endpoint, 'api/v1/login/access-token'), this.headers());
        if (r1.code !== 404) {
          routeOk = true;
        }
      } catch (e) {
        // 网络错误留给后面的主请求报
      }
      if (!routeOk) {
        // 某些反代会把 405 吞成 404，用 user/current 再兜一层
        try {
          const r2: Reply = await get(this.url(endpoint, 'api/v1/user/current'), this.headers());
          if (r2.code !== 404) {
            routeOk = true;
          }
        } catch (e) {
          // 同上
        }
      }
      if (!routeOk) {
        throw new ApiException(
          `在 ${endpoint.display()} 上找不到 MoviePilot 的接口（/api/v1 全部 404）。` +
          '检查端口和子路径对不对，或者这个地址其实是别的服务。');
      }

      // 2) 版本号：v2 有公开接口 system/global（不带鉴权），v1 没有则留空
      let version: string = '';
      try {
        const rv: Reply =
          await get(this.url(endpoint, 'api/v1/system/global', [['token', 'moviepilot']]), this.headers());
        if (rv.isSuccessful()) {
          const g: Record<string, Object> | null = parseJsonObject(rv.body);
          if (g !== null) {
            const d: Record<string, Object> | null = jObj(g, 'data');
            if (d !== null) {
              version = jStr(d, ['BACKEND_VERSION']);
            }
          }
        }
      } catch (e) {
        version = '';
      }

      // 3) 再用当前用户接口验证 Token 是否真的能过鉴权
      const response: Reply = await get(this.url(endpoint, 'api/v1/user/current'), this.headers());
      const body: string = response.body;
      const trimmed: string = body.trimStart();
      const jsonLike: boolean = trimmed.startsWith('{') || trimmed.startsWith('[');
      if (response.isSuccessful() && !jsonLike) {
        throw new ApiException(
          `${endpoint.display()} 返回的是网页而不是接口数据，` +
          '多半是子路径不对（反代把 /api 也交给前端了）。');
      }
      if (response.isSuccessful()) {
        let user: string = '';
        const obj: Record<string, Object> | null = parseJsonObject(body);
        if (obj !== null) {
          user = jStr(obj, ['name']);
          if (user.length === 0) {
            user = jStr(obj, ['username']);
          }
        }
        let out: string = `连接成功 · ${endpoint.display()}`;
        if (version.length > 0) {
          out += ` · MoviePilot ${version}`;
        }
        if (user.length > 0) {
          out += ` · 用户 ${user}`;
        }
        return out;
      }
      if (response.code === 401 || response.code === 403) {
        const vPart: string = version.length > 0 ? `（MoviePilot ${version}）` : '';
        throw new ApiException(`地址已连通${vPart}，但鉴权失败：API Token 不对或没填。`);
      }
      throw new ApiException(this.describeError(response.code, body));
    });
  }

  // ---------- 发现 ----------

  async recommend(channel: MpDiscoverChannel, page: number, count: number = 30): Promise<MpMedia[]> {
    const query: string[][] = [['page', String(page)], ['count', String(count)]];
    if (channel.extraQuery.length > 0) {
      for (const pair of channel.extraQuery.split('&')) {
        const eq: number = pair.indexOf('=');
        if (eq > 0) {
          query.push([pair.substring(0, eq), pair.substring(eq + 1)]);
        }
      }
    }
    const seg: string = channel.path.length > 0 ? channel.path : channel.key;
    const result: Object = await this.requestJson(`api/v1/recommend/${seg}`, query);
    return this.mediasFrom(this.listFrom(result));
  }

  // ---------- 搜索 ----------

  async searchMedia(keyword: string): Promise<MpMedia[]> {
    const result: Object = await this.requestJson('api/v1/media/search', [['title', keyword]]);
    return this.mediasFrom(this.listFrom(result));
  }

  async mediaDetail(media: MpMedia): Promise<MpMedia> {
    const query: string[][] = [
      ['type_name', media.isTV() ? '电视剧' : '电影'],
      ['title', media.title],
      ['year', media.yearLabel()]
    ];
    const identity: MediaIdentity = this.mediaIdentity(media);
    let result: Object;
    if (identity.source !== null) {
      try {
        // 与安卓端统一顺序：先走 v3（路径留原生 ID、来源走 media_source）。
        // 反过来先打 `tmdb:550` 单段路径在 MP v3 上**不会报错**，
        // 而是回一份「识别摘要」（overview 就是 `2026 / 德国 法国 / 科幻 惊悚 / 导演…`
        // 那种拼接串、genres 为空），表现为鸿蒙详情页没有真简介、演职员也空。
        const v3Query: string[][] = query.concat([['media_source', identity.source]]);
        result = await this.requestJson(`api/v1/media/${identity.rawId}`, v3Query);
      } catch (e) {
        const msg: string = orMessage(e as Error);
        if (!this.isVersionMismatch(msg)) {
          throw new ApiException(msg);
        }
        // 老版本不认 v3 参数：退回 `tmdb:550` 单段路径
        result = await this.requestJson(`api/v1/media/${identity.legacyKey}`, query);
      }
    } else {
      result = await this.requestJson(`api/v1/media/${identity.legacyKey}`, query);
    }
    if (Array.isArray(result)) {
      return media;
    }
    const obj: Record<string, Object> = result as Record<string, Object>;
    const data: Record<string, Object> | null = jObj(obj, 'data');
    const target: Record<string, Object> = data !== null ? data : obj;
    const parsed: MpMedia | null = this.parseMedia(target);
    return parsed !== null ? parsed : media;
  }

  /**
   * credits 接口的实际结构是 `{cast: [...], crew: [...]}`（tmdb / douban 都是），
   * 不是统一的 items/data 数组 —— 所以 listFrom 拿到的是空数组，
   * 表现为详情页「演职员」整块消失（已修复）。
   * 这里先把标准结构过一遍，再兜底把 cast + crew 合并展开。
   */
  private creditEntries(result: Object): Array<Record<string, Object>> {
    const direct: Array<Record<string, Object>> = this.listFrom(result);
    if (direct.length > 0) {
      return direct;
    }
    if (Array.isArray(result)) {
      return [];
    }
    const root: Record<string, Object> = result as Record<string, Object>;
    const data: Record<string, Object> | null = jObj(root, 'data');
    const holder: Record<string, Object> = data !== null ? data : root;
    const out: Array<Record<string, Object>> = [];
    const cast: Array<Record<string, Object>> | null = jArr(holder, 'cast');
    if (cast !== null) {
      for (const item of cast) {
        out.push(item);
      }
    }
    const crew: Array<Record<string, Object>> | null = jArr(holder, 'crew');
    if (crew !== null) {
      for (const item of crew) {
        out.push(item);
      }
    }
    return out;
  }

  async credits(media: MpMedia): Promise<Person[]> {
    const key: string = media.searchKey();
    const parts: string[] = key.split(':');
    if (parts.length !== 2) {
      return [];
    }
    const source: string = parts[0];
    const id: string = parts[1];
    let path: string = '';
    if (source === 'tmdb') {
      path = `api/v1/tmdb/credits/${id}/${media.isTV() ? 'tv' : 'movie'}`;
    } else if (source === 'douban') {
      path = `api/v1/douban/credits/${id}/${media.isTV() ? 'tv' : 'movie'}`;
    } else if (source === 'bangumi') {
      path = `api/v1/bangumi/credits/${id}`;
    } else {
      return [];
    }
    try {
      const result: Object = await this.requestJson(path);
      const out: Person[] = [];
      for (const obj of this.creditEntries(result)) {
        let name: string = jStr(obj, ['name']);
        if (name.length === 0) {
          name = jStr(obj, ['title']);
        }
        if (name.length === 0) {
          continue;
        }
        let role: string = jStr(obj, ['character']);
        if (role.length === 0) {
          role = jStr(obj, ['job']);
        }
        let avatar: string = jStr(obj, ['profile_path']);
        if (avatar.length === 0) {
          avatar = jStr(obj, ['avatar']);
        }
        out.push(new Person(name, role, avatar));
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /**
   * 种子标题 → MP 识别出的整条媒体信息（对应安卓 recognizeMedia）。
   *
   * 站点浏览接口只给文字，海报要靠这里反查；顺手把 `media_info` 整条解析成 MpMedia，
   * 站点种子详情页才能和 MP 搜索结果页显示同一套内容（中文标题、类型、简介、演职员）。
   */
  async recognizeMedia(title: string): Promise<MpMedia | null> {
    const text: string = title.trim();
    if (text.length === 0) {
      return null;
    }
    try {
      return await this.withEndpoint<MpMedia | null>(
        async (endpoint: Endpoint): Promise<MpMedia | null> => {
          await this.ensureLogin();
          const reply: Reply = await get(this.url(endpoint, 'api/v1/media/recognize', [['title', text]]),
            this.headers(), TimeoutTier.NORMAL);
          if (!reply.isSuccessful()) {
            return null;
          }
          const root: Record<string, Object> | null = parseJsonObject(reply.body);
          if (root === null) {
            return null;
          }
          const data: Record<string, Object> | null = jObj(root, 'data');
          const holder: Record<string, Object> = data !== null ? data : root;
          let media: Record<string, Object> | null = jObj(holder, 'media_info');
          if (media === null) {
            media = jObj(holder, 'media');
          }
          if (media === null) {
            return null;
          }
          return this.parseMedia(media);
        });
    } catch (e) {
      return null;
    }
  }

  // ---------- 资源搜索 ----------

  /**
   * 优先走 SFH 渐进式接口（search/media/{id}/stream），站搜完一个回一批；
   * 需要用户名密码登录拿到 resource_token Cookie，否则退回阻塞接口。
   *
   * MP v3 起精确搜索要求把来源单独放进 `media_source`、路径只留原生 ID，
   * 老版本则用 `tmdb:550` 这种单段路径 —— 先按 v3 拼，遇到版本不匹配再按老路径重试。
   */
  async searchResources(media: MpMedia,
    onBatch: (list: MpResource[], stage: string) => void): Promise<MpResource[]> {
    const query: string[][] = [
      ['mtype', media.isTV() ? '电视剧' : '电影'],
      ['area', 'title'],
      ['title', media.title],
      ['year', media.yearLabel()]
    ];
    if (media.isTV() && media.season > 0) {
      query.push(['season', String(media.season)]);
    }
    const identity: MediaIdentity = this.mediaIdentity(media);
    // 两套拼法：老版本（v1/v2 及 v3 主流构建）用 `tmdb:550` 单段路径；
    // 部分 v3 构建要求路径只留原生 ID、来源走 media_source。
    const legacyPath: string = `api/v1/search/media/${identity.legacyKey}`;
    const v3Query: string[][] | null = identity.source !== null
      ? query.concat([['media_source', identity.source]]) : null;
    const v3Path: string = `api/v1/search/media/${identity.rawId}`;

    let lastError: string = '';

    // 1) 渐进式（SSE）：能拿到用户名密码才用，站搜完一个回一批
    if (this.server.hasLogin() && await this.ensureLogin()) {
      try {
        const streamed: MpResource[] = await this.searchStream(`${legacyPath}/stream`, query, onBatch);
        if (streamed.length > 0) {
          return streamed;
        }
      } catch (e) {
        lastError = orMessage(e as Error);
        logWarn('MoviePilot', `渐进式搜索失败：${lastError}`);
      }
      if (v3Query !== null && this.isVersionMismatch(lastError)) {
        try {
          const streamed: MpResource[] =
            await this.searchStream(`${v3Path}/stream`, v3Query, onBatch);
          if (streamed.length > 0) {
            return streamed;
          }
        } catch (e) {
          lastError = orMessage(e as Error);
          logWarn('MoviePilot', `v3 渐进式搜索失败：${lastError}`);
        }
      }
    }

    // 2) 阻塞式：先老路径
    try {
      return await this.searchBlocking(legacyPath, query);
    } catch (e) {
      lastError = orMessage(e as Error);
      logWarn('MoviePilot', `精确搜索失败（老路径）：${lastError}`);
      // 真没资源 / 站点报错要如实往上抛，只有「接口版本对不上」才值得换拼法
      if (!this.isVersionMismatch(lastError)) {
        throw new ApiException(lastError);
      }
    }

    // 3) v3 拼法
    if (v3Query !== null) {
      try {
        return await this.searchBlocking(v3Path, v3Query);
      } catch (e) {
        lastError = orMessage(e as Error);
        logWarn('MoviePilot', `精确搜索失败（v3 路径）：${lastError}`);
      }
    }

    // 4) 最后一招：参数最简（某些版本对多余参数敏感，ID 本身已够定位）
    const minimal: string[][] = [['mtype', media.isTV() ? '电视剧' : '电影'], ['area', 'title']];
    if (media.isTV() && media.season > 0) {
      minimal.push(['season', String(media.season)]);
    }
    try {
      return await this.searchBlocking(legacyPath, minimal);
    } catch (e) {
      throw new ApiException(orMessage(e as Error));
    }
  }

  private async searchBlocking(path: string, query: string[][]): Promise<MpResource[]> {
    return await this.withEndpoint<MpResource[]>(async (endpoint: Endpoint): Promise<MpResource[]> => {
      await this.ensureLogin();
      const requestUrl: string = this.url(endpoint, path, query);
      const reply: Reply = await get(requestUrl, this.headers(), TimeoutTier.SLOW);
      if (!reply.isSuccessful()) {
        // 失败时把请求 URL 和原始响应落盘：422 到底是哪个参数不对，一眼能看出来
        logWarn('MoviePilot', `搜索失败 ${reply.code} ${requestUrl}`);
        logWarn('MoviePilot', `响应体：${reply.body.substring(0, 400)}`);
        throw new ApiException(this.describeError(reply.code, reply.body));
      }
      const root: Record<string, Object> | null = parseJsonObject(reply.body);
      if (root === null) {
        return [];
      }
      if (!jBool(root, ['success'], true)) {
        const msg: string = jStr(root, ['message']);
        throw new ApiException(msg.length > 0 ? msg : '未搜索到任何资源');
      }
      return this.resourcesFrom(this.listFrom(root));
    });
  }

  private async searchStream(path: string, query: string[][],
    onBatch: (list: MpResource[], stage: string) => void): Promise<MpResource[]> {
    return await this.withEndpoint<MpResource[]>(async (endpoint: Endpoint): Promise<MpResource[]> => {
      const requestUrl: string = this.url(endpoint, path, query);
      const h: Record<string, string> = this.headers();
      h['Accept'] = 'text/event-stream';

      const collected: Map<string, MpResource> = new Map();
      let errorMessage: string = '';
      let done: boolean = false;
      const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
      let pending: string = '';

      const snapshot = (): MpResource[] => {
        const out: MpResource[] = [];
        collected.forEach((v: MpResource): void => {
          out.push(v);
        });
        return out;
      };

      const handleLine: (line: string) => void = (line: string): void => {
        if (!line.startsWith('data:')) {
          return;
        }
        const payload: string = line.substring(5).trim();
        if (payload.length === 0 || payload === '[DONE]') {
          return;
        }
        const event: Record<string, Object> | null = parseJsonObject(payload);
        if (event === null) {
          return;
        }
        const type: string = jStr(event, ['type']);
        if (type === 'error') {
          const msg: string = jStr(event, ['message']);
          errorMessage = msg.length > 0 ? msg : '搜索失败';
          return;
        }
        const items: Array<Record<string, Object>> | null = jArr(event, 'items');
        if (items === null) {
          return;
        }
        if (type === 'replace') {
          collected.clear();
        }
        let added: number = 0;
        for (const item of items) {
          const resource: MpResource | null = this.parseResource(item);
          if (resource !== null && !collected.has(resource.key)) {
            collected.set(resource.key, resource);
            added++;
          }
        }
        if (added > 0) {
          const stage: string = jStr(event, ['stage']);
          onBatch(snapshot(), stage);
        }
        if (type === 'done') {
          done = true;
        }
      };

      const handleText: (text: string) => void = (text: string): void => {
        pending += text;
        let idx: number = pending.indexOf('\n');
        while (idx >= 0) {
          const line: string = pending.substring(0, idx).replace(/\r$/g, '');
          pending = pending.substring(idx + 1);
          handleLine(line);
          if (done) {
            return;
          }
          idx = pending.indexOf('\n');
        }
      };

      const code: number = await requestStream(requestUrl, h, (chunk: ArrayBuffer): void => {
        if (done) {
          return;
        }
        const bytes: Uint8Array = new Uint8Array(chunk);
        try {
          // stream: true 保留不完整的多字节序列，等下一块补齐
          handleText(decoder.decodeToString(bytes, { stream: true }));
        } catch (err) {
          // 单块解码失败忽略，不影响后续块
        }
      });

      if (code < 200 || code >= 300) {
        throw new ApiException(this.describeError(code, ''));
      }
      if (pending.length > 0) {
        handleLine(pending);
      }
      if (collected.size === 0 && errorMessage.length > 0) {
        throw new ApiException(errorMessage);
      }
      return snapshot();
    });
  }

  // ---------- 下载 ----------

  async downloaders(): Promise<MpDownloader[]> {
    const result: Object = await this.requestJson('api/v1/download/clients');
    const out: MpDownloader[] = [];
    for (const obj of this.listFrom(result)) {
      const name: string = jStr(obj, ['name']);
      if (name.length > 0) {
        out.push(new MpDownloader(name, jStr(obj, ['type'])));
      }
    }
    return out;
  }

  async savePaths(): Promise<MpSavePath[]> {
    let result: Object;
    try {
      result = await this.requestJson('api/v1/download/paths');
    } catch (e) {
      return [];
    }
    const out: MpSavePath[] = [];
    for (const obj of this.listFrom(result)) {
      const savePath: string = jStr(obj, ['save_path']);
      if (savePath.length === 0) {
        continue;
      }
      const name: string = jStr(obj, ['name']);
      out.push(new MpSavePath(name.length > 0 ? name : savePath, savePath, jStr(obj, ['storage'])));
    }
    return out;
  }

  async addDownload(resource: MpResource, downloader: string, savePath: string): Promise<string> {
    const torrentIn: Record<string, Object> | null = parseJsonObject(resource.rawJson);
    if (torrentIn === null) {
      throw new ApiException('资源数据缺失，无法提交');
    }
    const body: Record<string, Object> = { 'torrent_in': torrentIn as Object };
    if (downloader.trim().length > 0) {
      body['downloader'] = downloader as Object;
    }
    if (savePath.trim().length > 0) {
      body['save_path'] = savePath as Object;
    }
    const result: Object = await this.requestJson('api/v1/download/add', [], 'POST', body, true);
    if (Array.isArray(result)) {
      throw new ApiException('提交失败');
    }
    const obj: Record<string, Object> = result as Record<string, Object>;
    if (!jBool(obj, ['success'], true)) {
      const msg: string = jStr(obj, ['message']);
      throw new ApiException(msg.length > 0 ? msg : '提交失败');
    }
    const data: Record<string, Object> | null = jObj(obj, 'data');
    return data !== null ? jStr(data, ['download_id']) : '';
  }

  // ---------- 站点（只读同步 MP） ----------

  /**
   * 站点列表（`GET api/v1/site/`）。要求管理员 token，403 时由 UI 提示换 token。
   * 停用的站点沉底，同优先级按名字排。
   */
  async sites(): Promise<MpSite[]> {
    const result: Object = await this.requestJson('api/v1/site/');
    const out: MpSite[] = [];
    for (const obj of this.listFrom(result)) {
      const site: MpSite | null = mpSiteFromJson(obj);
      if (site !== null) {
        out.push(site);
      }
    }
    return sortSitesForDisplay(out);
  }

  /**
   * 所有站点最新个人数据（MP 定时抓取，不是实时）。
   *
   * **不要传 page/count**：MP v3 的 `CompatiblePageParam` 是 `Query(ge = 1)`，
   * 页码从 1 开始，传 `page=0` 会直接 422（安卓版就这样把所有站点数据搞成空的）。
   * 两个参数都省略 = 返回全量列表，站点上百也没问题。
   */
  async siteUserData(): Promise<MpSiteUserData[]> {
    const result: Object = await this.requestJson('api/v1/site/userdata/latest');
    const out: MpSiteUserData[] = [];
    for (const obj of this.listFrom(result)) {
      out.push(mpSiteUserDataFromJson(obj));
    }
    return out;
  }

  /** 站点分类；拿不到就返回空（UI 把分类行整行隐藏，不影响浏览） */
  async siteCategories(siteId: number): Promise<MpSiteCategory[]> {
    let result: Object;
    try {
      result = await this.requestJson(`api/v1/site/category/${siteId}`);
    } catch (e) {
      return [];
    }
    const out: MpSiteCategory[] = [];
    for (const obj of this.listFrom(result)) {
      // MP 的分类 id 既可能是数字也可能是文本，统一成字符串
      let rawId: string = '';
      const idValue: Object | undefined = obj['id'];
      if (idValue !== undefined && idValue !== null) {
        if (typeof idValue === 'number') {
          rawId = `${Math.trunc(idValue as number)}`;
        } else {
          rawId = `${idValue}`.trim();
        }
      }
      const cat: string = jStr(obj, ['cat']).trim();
      const desc: string = jStr(obj, ['desc']).trim();
      if (rawId.length === 0 && cat.length === 0 && desc.length === 0) {
        continue;
      }
      out.push(new MpSiteCategory(rawId, cat, desc));
    }
    return out;
  }

  /**
   * 站点图标（`GET api/v1/site/icon/{id}`）。
   *
   * MP 表里存的可能是 **http 地址**，也可能是**纯 base64**（无 `data:` 前缀），
   * 所以这里只交原始字符串出去，怎么解码由 SiteIconStore 决定。
   *
   * 返回语义要分清（调用方靠它决定「要不要重试」）：
   * - 字符串 → 有图标；
   * - null → MP 明确说这个站没有图标（success:false / 404 / 空内容）；
   * - 抛异常 → 网络或鉴权失败，可重试，不能当成「没有图标」。
   */
  async siteIcon(siteId: number): Promise<string | null> {
    return await this.withEndpoint<string | null>(async (endpoint: Endpoint): Promise<string | null> => {
      await this.ensureLogin();
      const reply: Reply = await get(this.url(endpoint, `api/v1/site/icon/${siteId}`), this.headers(),
        TimeoutTier.NORMAL);
      if (reply.code === 404) {
        return null;
      }
      if (!reply.isSuccessful()) {
        throw new ApiException(this.describeError(reply.code, reply.body), reply.code);
      }
      const text: string = reply.body.trim();
      if (text.length === 0) {
        return null;
      }
      const root: Record<string, Object> | null = parseJsonObject(text);
      if (root === null) {
        return null;
      }
      if (root['success'] !== undefined && !jBool(root, ['success'], false)) {
        return null;
      }
      const data: Record<string, Object> | null = jObj(root, 'data');
      const holder: Record<string, Object> = data !== null ? data : root;
      const icon: string = jStr(holder, ['icon']).trim();
      return icon.length > 0 ? icon : null;
    });
  }

  /**
   * 浏览站点种子（`GET api/v1/site/resource/{id}`）。
   *
   * **同步阻塞**：MP 会真的去打开站点网页抓列表，慢站点 5~30 秒很常见，
   * 所以强制走慢速档（读 130s）；page 从 0 开始且没有 count 参数。
   * 站点浏览返回的 torrent 一般不带 site_name，用当前站点名兜底。
   */
  async siteTorrents(siteId: number, siteName: string, keyword: string = '',
    cats: string[] = [], page: number = 0): Promise<MpResource[]> {
    const query: string[][] = [['page', `${page}`]];
    if (keyword.trim().length > 0) {
      query.push(['keyword', keyword.trim()]);
    }
    if (cats.length > 0) {
      query.push(['cat', cats.join(',')]);
    }
    const result: Object = await this.requestJson(`api/v1/site/resource/${siteId}`, query, 'GET', null, true);
    const out: MpResource[] = [];
    for (const obj of this.listFrom(result)) {
      const r: MpResource | null = this.parseResource(obj, siteName);
      if (r !== null) {
        out.push(r);
      }
    }
    return out;
  }

  /**
   * 把种子标题交给 MP 识别，取海报路径（`media_info.poster_path`）。
   * 比拿标题去 TMDB 关键词搜准得多（MP 用自己的识别词规则 + 媒体库匹配）。
   * 失败一律返回 null（超时 / 未识别 / 未配图），UI 落渐变占位，不阻塞列表。
   */
  async sitePoster(title: string): Promise<string | null> {
    const text: string = title.trim();
    if (text.length === 0) {
      return null;
    }
    try {
      return await this.withEndpoint<string | null>(async (endpoint: Endpoint): Promise<string | null> => {
        await this.ensureLogin();
        const reply: Reply = await get(this.url(endpoint, 'api/v1/media/recognize', [['title', text]]),
          this.headers(), TimeoutTier.NORMAL);
        if (!reply.isSuccessful()) {
          return null;
        }
        const root: Record<string, Object> | null = parseJsonObject(reply.body);
        if (root === null) {
          return null;
        }
        const data: Record<string, Object> | null = jObj(root, 'data');
        const holder: Record<string, Object> = data !== null ? data : root;
        let media: Record<string, Object> | null = jObj(holder, 'media_info');
        if (media === null) {
          media = jObj(holder, 'media');
        }
        if (media === null) {
          return null;
        }
        let path: string = jStr(media, ['poster_path']);
        if (path.length === 0) {
          path = jStr(media, ['poster']);
        }
        if (path.trim().length === 0) {
          return null;
        }
        let source: string = jStr(media, ['media_source']);
        if (source.length === 0) {
          source = jStr(media, ['source']);
        }
        const url: string = PosterUrl.normalize(path, source, this.activeBaseUrl);
        // MP 给的是 original（动辄 1~2MB），列表/详情用 w185 / w342 足够
        return url.replace('/t/p/original/', '/t/p/w342/').replace('/t/p/w500', '/t/p/w185');
      });
    } catch (e) {
      return null;
    }
  }

  // ---------- 订阅 ----------

  async subscribes(): Promise<MpSubscribe[]> {
    const result: Object = await this.requestJson('api/v1/subscribe/');
    const out: MpSubscribe[] = [];
    for (const obj of this.listFrom(result)) {
      const id: number = Math.trunc(jNum(obj, ['id']));
      if (id <= 0) {
        continue;
      }
      const sub: MpSubscribe = new MpSubscribe();
      sub.id = id;
      sub.name = jStr(obj, ['name']);
      sub.year = jStr(obj, ['year']);
      sub.type = jStr(obj, ['type']);
      const season: number = Math.trunc(jNum(obj, ['season']));
      sub.season = season > 0 ? season : -1;
      sub.posterUrl = PosterUrl.normalize(jStr(obj, ['poster']), jStr(obj, ['media_source']),
        this.activeBaseUrl);
      sub.vote = jNum(obj, ['vote']);
      sub.totalEpisode = Math.trunc(jNum(obj, ['total_episode']));
      sub.lackEpisode = Math.trunc(jNum(obj, ['lack_episode']));
      const completed: number = Math.trunc(jNum(obj, ['completed_episode'], -1));
      sub.completedEpisode = completed >= 0 ? completed : -1;
      sub.state = jStr(obj, ['state'], 'R');
      sub.lastUpdate = jStr(obj, ['last_update']);
      sub.sites = this.numList(obj, 'sites');
      sub.downloader = jStr(obj, ['downloader']);
      sub.bestVersion = Math.trunc(jNum(obj, ['best_version'])) === 1;
      sub.savePath = jStr(obj, ['save_path']);
      // 订阅设置字段：jStr 遇到 JSON null 会返回默认值，不会显示成 "null"
      sub.keyword = jStr(obj, ['keyword']);
      sub.quality = jStr(obj, ['quality']);
      sub.resolution = jStr(obj, ['resolution']);
      sub.effect = jStr(obj, ['effect']);
      const interval: number = Math.trunc(jNum(obj, ['search_interval'], 0));
      sub.searchInterval = interval > 0 ? interval : -1;
      sub.include = jStr(obj, ['include']);
      sub.exclude = jStr(obj, ['exclude']);
      sub.filterGroups = jStrArr(obj, ['filter_groups']);
      sub.mediaCategory = jStr(obj, ['media_category']);
      sub.customWords = jStr(obj, ['custom_words']);
      sub.searchImdbId = Math.trunc(jNum(obj, ['search_imdbid'])) === 1;
      sub.tmdbId = Math.trunc(jNum(obj, ['tmdbid']));
      sub.doubanId = jStr(obj, ['doubanid']);
      sub.bangumiId = Math.trunc(jNum(obj, ['bangumiid']));
      sub.posterRaw = jStr(obj, ['poster']);
      sub.mediaSource = jStr(obj, ['media_source']);
      sub.mediaIdRaw = jStr(obj, ['media_id']).length > 0
        ? jStr(obj, ['media_id']) : jStr(obj, ['mediaid']);
      out.push(sub);
    }
    // lastUpdate 降序
    out.sort((a: MpSubscribe, b: MpSubscribe): number => {
      if (a.lastUpdate === b.lastUpdate) {
        return 0;
      }
      return a.lastUpdate < b.lastUpdate ? 1 : -1;
    });
    return out;
  }

  /**
   * 新增订阅。
   *
   * 两套媒体身份一次发全，不猜版本：
   * - v1 / v2.x：认 tmdbid / doubanid / bangumiid；
   * - v3：只认 `media_source` + `media_id` 这一对（缺一个回「必须同时提供…」）。
   * 对方版本模型里都是不认识的额外字段，会被忽略，所以一起发不会冲突。
   */
  async subscribe(media: MpMedia, season: number): Promise<string> {
    const typeName: string = media.isTV() ? '电视剧' : '电影';
    const targetSeason: number = season > 0 ? season : media.season;
    const seasonValue: number = media.isTV() && targetSeason > 0 ? targetSeason : 0;

    // 一次请求同时带两套媒体身份：v1/v2 认 tmdbid 那套，v3 认 media_source+media_id 那对；
    // 对方版本模型里都是「不认识的额外字段」，会被忽略，所以不会互相干扰。
    const body: Record<string, Object> = this.subscribeBody(media, typeName, seasonValue, true);
    let firstError: string = '';
    try {
      return await this.postSubscribe(body);
    } catch (e) {
      firstError = orMessage(e as Error);
    }
    // 业务报错（已订阅、无权限）直接抛给界面
    if (!this.identityRejected(firstError)) {
      throw new ApiException(firstError);
    }
    // 身份被 v3 明确拒绝：退回只带原生 ID 的老拼法重试一次
    return await this.postSubscribe(this.subscribeBody(media, typeName, seasonValue, false));
  }

  private subscribeBody(media: MpMedia, typeName: string, season: number,
    withIdentity: boolean): Record<string, Object> {
    const body: Record<string, Object> = {
      'name': media.title as Object,
      'year': media.yearLabel() as Object,
      'type': typeName as Object
    };
    if (media.tmdbId > 0) {
      body['tmdbid'] = media.tmdbId as Object;
    }
    if (media.doubanId.length > 0) {
      body['doubanid'] = media.doubanId as Object;
    }
    if (media.bangumiId > 0) {
      body['bangumiid'] = media.bangumiId as Object;
    }
    if (withIdentity) {
      // 详情页用的 media_source + 原生 ID 组合已被 MP 接受，订阅沿用同一对
      const identity: MediaIdentity = this.mediaIdentity(media);
      const source: string = identity.source !== null ? identity.source : this.mediaSourceName(media.source);
      if (identity.rawId.length > 0) {
        body['media_source'] = source as Object;
        body['media_id'] = identity.rawId as Object;
      }
    }
    if (season > 0) {
      body['season'] = season as Object;
    }
    if (media.posterUrl.length > 0) {
      body['poster'] = media.posterUrl as Object;
    }
    return body;
  }

  /** v3 的媒体身份校验没过（缺一半 / 来源不认 / ID 不存在 → 422 或明确文案） */
  private identityRejected(message: string): boolean {
    return message.indexOf('必须同时提供') >= 0 ||
      message.indexOf('未知的媒体ID') >= 0 ||
      message.indexOf('HTTP 422') >= 0;
  }

  private mediaSourceName(source: string): string {
    const lower: string = source.toLowerCase();
    if (lower === 'douban') {
      return 'douban';
    }
    if (lower === 'bangumi') {
      return 'bangumi';
    }
    return 'themoviedb';
  }

  private async postSubscribe(body: Record<string, Object>): Promise<string> {
    const result: Object = await this.requestJson('api/v1/subscribe/', [], 'POST', body);
    if (Array.isArray(result)) {
      return '已加入订阅';
    }
    const obj: Record<string, Object> = result as Record<string, Object>;
    if (!jBool(obj, ['success'], true)) {
      const msg: string = jStr(obj, ['message']);
      throw new ApiException(msg.length > 0 ? msg : '订阅失败');
    }
    const msg2: string = jStr(obj, ['message']);
    return msg2.length > 0 ? msg2 : '已加入订阅';
  }

  async deleteSubscribe(id: number): Promise<void> {
    const result: Object = await this.requestJson(`api/v1/subscribe/${id}`, [], 'DELETE');
    if (Array.isArray(result)) {
      return;
    }
    const obj: Record<string, Object> = result as Record<string, Object>;
    if (!jBool(obj, ['success'], true)) {
      const msg: string = jStr(obj, ['message']);
      throw new ApiException(msg.length > 0 ? msg : '删除失败');
    }
  }

  /**
   * 保存订阅设置（`PUT api/v1/subscribe/`）。
   *
   * 整条回传：v2.9 的更新接口是整条覆盖，只发改动字段会把 name / year / tmdbid 写成 null，
   * 订阅变空壳。v3 走 exclude_unset，多传无副作用。
   */
  async updateSubscribe(sub: MpSubscribe): Promise<void> {
    const body: Record<string, Object> = {
      'id': sub.id as Object,
      'name': sub.name as Object,
      'year': sub.year as Object,
      'type': sub.type as Object,
      'keyword': sub.keyword as Object,
      'quality': sub.quality as Object,
      'resolution': sub.resolution as Object,
      'effect': sub.effect as Object,
      'include': sub.include as Object,
      'exclude': sub.exclude as Object,
      'custom_words': sub.customWords as Object,
      'media_category': sub.mediaCategory as Object,
      'downloader': sub.downloader as Object,
      'save_path': sub.savePath as Object,
      'best_version': (sub.bestVersion ? 1 : 0) as Object,
      'search_imdbid': (sub.searchImdbId ? 1 : 0) as Object,
      'sites': sub.sites as Object,
      'filter_groups': sub.filterGroups as Object
    };
    if (sub.season > 0) {
      body['season'] = sub.season as Object;
    }
    // 恢复「跟随系统」时必须显式发 null，MP 的 CLEARABLE 字段靠它清旧值；
    // ArkTS 的 Record 值类型不收 null，这里用 JSON.parse 拿个编译期是 Object 的 null
    body['search_interval'] = sub.searchInterval > 0
      ? sub.searchInterval as Object
      : JSON.parse('null') as Object;
    if (sub.posterRaw.length > 0) {
      body['poster'] = sub.posterRaw as Object;
    }
    if (sub.tmdbId > 0) {
      body['tmdbid'] = sub.tmdbId as Object;
    }
    if (sub.doubanId.length > 0) {
      body['doubanid'] = sub.doubanId as Object;
    }
    if (sub.bangumiId > 0) {
      body['bangumiid'] = sub.bangumiId as Object;
    }
    const result: Object = await this.requestJson('api/v1/subscribe/', [], 'PUT', body);
    const obj: Record<string, Object> = result as Record<string, Object>;
    if (!jBool(obj, ['success'], true)) {
      const msg: string = jStr(obj, ['message']);
      throw new ApiException(msg.length > 0 ? msg : '保存失败');
    }
  }

  /** 过滤规则组名称（订阅设置的「优先级规则组」选项）；拿不到就当没配 */
  async ruleGroups(): Promise<string[]> {
    try {
      const result: Object = await this.requestJson('api/v1/rule/groups');
      const root: Record<string, Object> = result as Record<string, Object>;
      const data: Object | undefined = root['data'];
      const holder: Record<string, Object> = (data !== undefined && data !== null)
        ? data as Record<string, Object> : root;
      const arr: string[] = jStrArr(holder, ['rule_groups']);
      if (arr.length > 0) {
        return arr;
      }
      return jStrArr(holder, ['groups']);
    } catch (e) {
      return [];
    }
  }

  /**
   * MP「系统设置 → 订阅 → 订阅站点」勾选的站点 id（`RssSites`）。
   *
   * 订阅只允许用这些站点，编辑订阅时不能把全部站点都摆出来。
   * 返回 null = 这台 MP 没有这项设置（老版本 / 无权限），调用方按不限制处理；
   * 返回空数组 = 用户一个都没勾。
   */
  async rssSiteIds(): Promise<number[] | null> {
    try {
      const result: Object = await this.requestJson('api/v1/system/setting/RssSites');
      const root: Record<string, Object> = result as Record<string, Object>;
      if (!jBool(root, ['success'], true)) {
        return null;
      }
      const data: Object | undefined = root['data'];
      const holder: Record<string, Object> = (data !== undefined && data !== null)
        ? data as Record<string, Object> : root;
      const value: Object | undefined = holder['value'];
      if (value === undefined || value === null) {
        return null;
      }
      const out: number[] = [];
      if (Array.isArray(value)) {
        for (const item of value as Array<Object>) {
          if (typeof item === 'number' && item > 0) {
            out.push(item);
          } else if (typeof item === 'string') {
            const n: number = parseInt(item, 10);
            if (!isNaN(n) && n > 0) {
              out.push(n);
            }
          }
        }
        return out;
      }
      if (typeof value === 'string') {
        // v2 及更早存的是 "1,2,3"
        for (const piece of value.split(',')) {
          const n: number = parseInt(piece.trim(), 10);
          if (!isNaN(n) && n > 0) {
            out.push(n);
          }
        }
        return out;
      }
      if (typeof value === 'number' && value > 0) {
        return [value];
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /** 立即搜索这一条订阅 */
  async searchSubscribe(id: number): Promise<string> {
    const result: Object = await this.requestJson(`api/v1/subscribe/search/${id}`, [], 'POST', null, true);
    const obj: Record<string, Object> = result as Record<string, Object>;
    if (!jBool(obj, ['success'], true)) {
      const msg: string = jStr(obj, ['message']);
      throw new ApiException(msg.length > 0 ? msg : '搜索失败');
    }
    const msg2: string = jStr(obj, ['message']);
    return msg2.length > 0 ? msg2 : '已开始搜索';
  }

  /** 重置订阅（清掉已完成集数，重新按缺集搜） */
  async resetSubscribe(id: number): Promise<string> {
    const result: Object = await this.requestJson(`api/v1/subscribe/reset/${id}`, [], 'POST');
    const obj: Record<string, Object> = result as Record<string, Object>;
    if (!jBool(obj, ['success'], true)) {
      const msg: string = jStr(obj, ['message']);
      throw new ApiException(msg.length > 0 ? msg : '重置失败');
    }
    const msg2: string = jStr(obj, ['message']);
    return msg2.length > 0 ? msg2 : '已重置订阅';
  }

  /** 单条订阅的关联文件（下载中 / 已入库），原样返回给上层汇总 */
  async subscribeFiles(id: number): Promise<Object> {
    return await this.requestJson(`api/v1/subscribe/files/${id}`, [], 'GET', null, true);
  }

  /** 订阅历史（按媒体类型整批返回，客户端自己按名称筛） */
  async subscribeHistory(mtype: string): Promise<Object[]> {
    const result: Object = await this.requestJson(`api/v1/subscribe/history/${mtype}`,
      [['page', '1'], ['count', '50']]);
    return this.listFrom(result);
  }

  async updateSubscribeState(id: number, state: string): Promise<void> {
    await this.requestJson(`api/v1/subscribe/status/${id}`, [['state', state]], 'PUT');
  }

  // ---------- 解析 ----------

  private posterUrlOf(raw: string, source: string): string {
    return PosterUrl.normalize(raw, source, this.activeBaseUrl);
  }

  private mediasFrom(list: Array<Record<string, Object>>): MpMedia[] {
    const out: MpMedia[] = [];
    for (const obj of list) {
      const m: MpMedia | null = this.parseMedia(obj);
      if (m !== null) {
        out.push(m);
      }
    }
    return out;
  }

  private parseMedia(obj: Record<string, Object>): MpMedia | null {
    let title: string = jStr(obj, ['title']);
    if (title.length === 0) {
      title = jStr(obj, ['name']);
    }
    if (title.length === 0) {
      return null;
    }

    let rawSource: string = jStr(obj, ['media_source']);
    if (rawSource.length === 0) {
      rawSource = jStr(obj, ['source']);
    }
    const rawLow: string = rawSource.toLowerCase();
    const source: string = (rawLow === 'themoviedb' || rawLow.length === 0) ? 'tmdb' : rawLow;

    const tmdbRaw: number = Math.trunc(jNum(obj, ['tmdb_id']));
    const tmdbId: number = tmdbRaw > 0 ? tmdbRaw : -1;
    const doubanRaw: string = jStr(obj, ['douban_id']);
    const doubanId: string = doubanRaw.length > 0 ? doubanRaw : '';
    const bangumiRaw: number = Math.trunc(jNum(obj, ['bangumi_id']));
    const bangumiId: number = bangumiRaw > 0 ? bangumiRaw : -1;

    let mediaId: string = jStr(obj, ['media_id']);
    if (mediaId.length === 0) {
      mediaId = jStr(obj, ['mediaid']);
    }
    let key: string = mediaId;
    if (mediaId.indexOf(':') >= 0) {
      key = mediaId;
    } else if (tmdbId > 0) {
      key = `tmdb:${tmdbId}`;
    } else if (doubanId.length > 0) {
      key = `douban:${doubanId}`;
    } else if (bangumiId > 0) {
      key = `bangumi:${bangumiId}`;
    }

    const typeRaw: string = jStr(obj, ['type']).toLowerCase();
    const type: string = (typeRaw === '电视剧' || typeRaw === 'tv') ? '电视剧' : '电影';

    const m: MpMedia = new MpMedia();
    m.mediaId = key;
    m.source = source;
    m.type = type;
    m.title = title;
    let year: string = jStr(obj, ['year']);
    if (year.length === 0) {
      year = jStr(obj, ['title_year']);
    }
    m.year = year;
    const seasonRaw: number = Math.trunc(jNum(obj, ['season']));
    m.season = seasonRaw > 0 ? seasonRaw : -1;
    m.tmdbId = tmdbId;
    m.doubanId = doubanId;
    m.bangumiId = bangumiId;
    let poster: string = jStr(obj, ['poster_path']);
    if (poster.length === 0) {
      poster = jStr(obj, ['poster']);
    }
    m.posterUrl = this.posterUrlOf(poster, source);
    m.backdropUrl = this.posterUrlOf(jStr(obj, ['backdrop_path']), source);
    let overview: string = jStr(obj, ['overview']);
    if (overview.length === 0) {
      overview = jStr(obj, ['description']);
    }
    m.overview = overview;
    let vote: number = jNum(obj, ['vote_average']);
    if (vote <= 0) {
      vote = jNum(obj, ['vote']);
    }
    m.vote = vote;
    m.genres = this.stringList(obj, ['genres', 'genre_names', 'genre']);
    m.directors = this.stringList(obj, ['directors', 'director', 'director_names']);
    m.cast = this.stringList(obj, ['actors', 'casts', 'actor', 'cast']);
    let release: string = jStr(obj, ['release_date']);
    if (release.length === 0) {
      release = jStr(obj, ['first_air_date']);
    }
    m.releaseDate = release;
    m.category = jStr(obj, ['category']);
    return m;
  }

  /** genres/actors 等字段兼容：字符串数组、{name} 对象数组、逗号分隔字符串 */
  private stringList(obj: Record<string, Object>, keys: string[]): string[] {
    for (const key of keys) {
      const raw: Object | undefined = obj[key];
      if (raw !== undefined && raw !== null && Array.isArray(raw)) {
        const arr: Array<Object> = raw as Array<Object>;
        const out: string[] = [];
        for (const item of arr) {
          if (typeof item === 'string') {
            const s: string = item as string;
            if (s.trim().length > 0) {
              out.push(s);
            }
          } else if (typeof item === 'object' && item !== null) {
            const io: Record<string, Object> = item as Record<string, Object>;
            const n: string = jStr(io, ['name']);
            if (n.length > 0) {
              out.push(n);
            }
          }
        }
        return distinctStrings(out);
      }
      const single: string = jStr(obj, [key]);
      if (single.trim().length > 0) {
        const parts: string[] = single.split(/[,/|、]/);
        const out: string[] = [];
        for (const p of parts) {
          const t: string = p.trim();
          if (t.length > 0) {
            out.push(t);
          }
        }
        return out;
      }
    }
    return [];
  }

  private numList(obj: Record<string, Object>, key: string): number[] {
    const out: number[] = [];
    const raw: Object | undefined = obj[key];
    if (raw !== undefined && raw !== null && Array.isArray(raw)) {
      const arr: Array<Object> = raw as Array<Object>;
      for (const item of arr) {
        // MP 不同版本可能给 number 或数字字符串，两种都要认，否则订阅 sites 会被解析成空
        if (typeof item === 'number') {
          out.push(Math.trunc(item as number));
        } else if (typeof item === 'string') {
          const n: number = parseInt(item as string, 10);
          if (!isNaN(n)) {
            out.push(n);
          }
        }
      }
    }
    return out;
  }

  private resourcesFrom(list: Array<Record<string, Object>>): MpResource[] {
    const out: MpResource[] = [];
    for (const obj of list) {
      const r: MpResource | null = this.parseResource(obj);
      if (r !== null) {
        out.push(r);
      }
    }
    return out;
  }

  /** @param fallbackSiteName 站点浏览接口返回的 torrent 常不带 site_name，用当前站点名兜底 */
  private parseResource(obj: Record<string, Object>, fallbackSiteName: string = ''): MpResource | null {
    let torrentObj: Record<string, Object> = obj;
    const ti: Record<string, Object> | null = jObj(obj, 'torrent_info');
    if (ti !== null) {
      torrentObj = ti;
    }
    const title: string = jStr(torrentObj, ['title']);
    if (title.length === 0) {
      return null;
    }
    let siteName: string = jStr(torrentObj, ['site_name']);
    if (siteName.length === 0) {
      siteName = jStr(torrentObj, ['site']);
    }
    if (siteName.length === 0) {
      siteName = fallbackSiteName.trim();
    }
    if (siteName.length === 0) {
      siteName = '未知站点';
    }
    const sizeRaw: number = jNum(torrentObj, ['size']);
    // MP 有时给的是 MB 数值：小于 1e5 视为 MB，转字节
    const size: number = (sizeRaw > 0 && sizeRaw < 100000)
      ? Math.trunc(sizeRaw * 1024 * 1024 * 1024) : Math.trunc(sizeRaw);
    let pubDate: string = jStr(torrentObj, ['pubdate']);
    if (pubDate.length === 0) {
      pubDate = jStr(torrentObj, ['pub_date']);
    }

    const r: MpResource = new MpResource();
    r.key = `${siteName}|${title}|${Math.trunc(jNum(torrentObj, ['size']))}`;
    r.siteName = siteName;
    r.title = title;
    r.description = this.cleanTorrentDescription(jStr(torrentObj, ['description']));
    r.pageUrl = jStr(torrentObj, ['page_url']);
    r.sizeBytes = size;
    r.seeders = Math.trunc(jNum(torrentObj, ['seeders']));
    r.peers = Math.trunc(jNum(torrentObj, ['peers']));
    r.grabs = Math.trunc(jNum(torrentObj, ['grabs']));
    r.pubDateText = pubDate;
    r.pubDateMs = this.parsePubDate(pubDate);
    r.downloadFactor = jNum(torrentObj, ['downloadvolumefactor'], 1);
    r.uploadFactor = jNum(torrentObj, ['uploadvolumefactor'], 1);
    r.hitAndRun = jBool(torrentObj, ['hit_and_run']);
    // MP 的「剩余免费时间」：网页上那个绿色时长标签就是它（1天23小时12分钟）
    r.freeTimeDiff = jStr(torrentObj, ['freedate_diff']).trim();
    // 免费截止时间：有的站点 diff 给空、只给这个，App 侧自己算剩余
    r.freeDate = jStr(torrentObj, ['freedate']).trim();
    r.labels = this.stringList(torrentObj, ['labels']);
    r.rawJson = JSON.stringify(torrentObj);
    return r;
  }

  /**
   * 清掉种子描述里被一起抓进来的站点 label 文本。
   *
   * 部分站点（已知 hdfans 红豆饭）种子副标题的 HTML 结构和别的站不同，
   * MoviePilot 解析器会把「剩余时间：」这个 label 节点也当成正文取下来，
   * 结果每条种子副标题都以「剩余时间：」开头。服务端改不了，App 侧做防御：
   * 只剥掉**已知 label 前缀**，正文（如「类型：纪录片」）原样保留。
   */
  private cleanTorrentDescription(raw: string): string {
    let text: string = raw.trim();
    if (text.length === 0) {
      return text;
    }
    const prefixes: string[] = ['剩余时间：', '剩余时间:', '发布时间：', '发布时间:', '副标题：', '副标题:', '大小：', '大小:'];
    for (let i = 0; i < prefixes.length; i++) {
      const p: string = prefixes[i];
      if (text.startsWith(p)) {
        text = text.substring(p.length).trim();
        break;
      }
    }
    return text;
  }

  private parsePubDate(raw: string): number {
    if (raw.trim().length === 0) {
      return Date.now();
    }
    // 兼容 "yyyy-MM-dd HH:mm:ss"（空格换 T）与 RFC1123
    const t: number = Date.parse(raw.replace(' ', 'T'));
    if (!isNaN(t)) {
      return t;
    }
    return Date.now();
  }
}
