import { Endpoint, EndpointMode, parseEndpoints } from '../model/Models';
import { MusicLibraryStats, MusicPlaylist, MusicSong } from '../model/MusicModels';
import { EndpointResolver } from './EndpointResolver';
import { ApiException, Reply, get, postJson, del, TimeoutTier } from './HttpClient';
import { TokenVault, TokenCached } from '../data/TokenVault';
import { parseJsonObject, parseJsonArray, jStr, jNum, jBool, jArr, jObj } from '../common/AppConstants';

/**
 * Songloft 音乐服务客户端（对应安卓 net/SongloftClient.kt）。
 *
 * 协议（从 Songloft 前端 bundle 里逆出来的，不是猜的）：
 *  1. POST /api/v1/auth/login  body {username,password}
 *     → {access_token, refresh_token, expires_in, token_type}
 *  2. 之后所有请求 Authorization: Bearer <access_token>；媒体地址则用 ?access_token=xxx
 *     查询参数（Songloft 自己的播放器就是这么拼的）
 *  3. GET /api/v1/songs?limit&offset&keyword  → {items:[...], total}
 *     GET /api/v1/playlists?limit&offset
 *     GET /api/v1/playlists/{id}/songs?limit&offset
 *     GET /api/v1/songs/stats  → {total_songs, artist_count, album_count, ...}
 */

/** 服务端内建「收藏」歌单（labels: built_in），重装恢复后 id 也固定为 1 */
const FAVORITE_PLAYLIST_ID: number = 1;

export class SongPage {
  songs: MusicSong[] = [];
  total: number = 0;

  constructor(songs: MusicSong[] = [], total: number = 0) {
    this.songs = songs;
    this.total = total;
  }
}

/** 全局登录会话（对应安卓 object SongloftSession） */
export class SongloftSession {
  private static base: string = '';
  private static token: string = '';
  private static expiresAt: number = 0;
  /** 登录被限流后的冷却截止时间（毫秒时间戳），期间不再尝试登录 */
  private static blockedUntil: number = 0;
  private static lastError: string = '';
  /** 连续被限流的次数，用来做指数退避 */
  private static blockCount: number = 0;

  static getToken(): string {
    return SongloftSession.token;
  }

  static getBase(): string {
    return SongloftSession.base;
  }

  static currentLastError(): string {
    return SongloftSession.lastError;
  }

  /** 剩余冷却秒数，0 = 不在冷却 */
  static cooldownLeft(): number {
    const left: number = SongloftSession.blockedUntil - Date.now();
    return left <= 0 ? 0 : Math.max(Math.trunc(left / 1000), 1);
  }

  static cooldownMessage(): string {
    const left: number = SongloftSession.cooldownLeft();
    if (left <= 0) {
      return 'Songloft 限制登录频率，请稍后再试';
    }
    return `Songloft 限制登录频率，请等 ${left} 秒后再点「保存」（不是账号密码的问题）`;
  }

  /**
   * token 是否还能用。
   * 允许传多个候选地址：同一台服务的内网 IP 和公网域名指向同一个后端，
   * 在家登录拿到的 token 出门换成域名访问也应该继续有效（登录接口有限流，重登很容易撞冷却）。
   */
  static matches(candidateBases: string[]): boolean {
    if (SongloftSession.token.length === 0) {
      return false;
    }
    if (SongloftSession.expiresAt > 0 && Date.now() >= SongloftSession.expiresAt - 60000) {
      return false;
    }
    if (candidateBases.length === 0) {
      return true;
    }
    for (const c of candidateBases) {
      if (SongloftSession.base.toLowerCase() === c.trim().toLowerCase()) {
        return true;
      }
    }
    return false;
  }

  static update(base: string, token: string, expiresAt: number): void {
    SongloftSession.base = base.replace(/\/+$/g, '');
    SongloftSession.token = token;
    SongloftSession.expiresAt = expiresAt;
    SongloftSession.blockedUntil = 0;
    SongloftSession.lastError = '';
    SongloftSession.blockCount = 0;
    // 存下来，冷启动就不用再登一次（Songloft 登录接口有频率限制）
    try {
      TokenVault.saveSongloft(SongloftSession.base, token, expiresAt);
    } catch (err) {
      // 忽略持久化失败
    }
  }

  /** 被限流：把下一次自动登录推迟一段时间（连续触发就指数加长） */
  static markBlocked(seconds: number, message: string): void {
    SongloftSession.blockCount = Math.min(SongloftSession.blockCount + 1, 5);
    const backoff: number = seconds > 0 ? seconds
      : Math.min(30 * (1 << (SongloftSession.blockCount - 1)), 600);
    SongloftSession.blockedUntil = Date.now() + backoff * 1000;
    SongloftSession.lastError = message.length > 0 ? message : '登录尝试过于频繁';
  }

  static reportError(message: string): void {
    SongloftSession.lastError = message;
  }

  /** 进程刚起来时调用：把上次存下的 token 装回去（只有未过期才恢复） */
  static restoreFromVault(): boolean {
    let cached: TokenCached | null = null;
    try {
      cached = TokenVault.loadSongloft();
    } catch (err) {
      return false;
    }
    if (cached === null) {
      return false;
    }
    if (cached.expiresAt > 0 && Date.now() >= cached.expiresAt - 60000) {
      return false;
    }
    SongloftSession.base = cached.base.replace(/\/+$/g, '');
    SongloftSession.token = cached.token;
    SongloftSession.expiresAt = cached.expiresAt;
    return true;
  }

  static reset(): void {
    SongloftSession.base = '';
    SongloftSession.token = '';
    SongloftSession.expiresAt = 0;
    SongloftSession.blockedUntil = 0;
    SongloftSession.lastError = '';
    try {
      TokenVault.clearSongloft();
    } catch (err) {
      // 忽略
    }
  }
}

function enc(value: string): string {
  return encodeURIComponent(value);
}

export class SongloftClient {
  /** 一行一个地址：内网 IP + 公网域名，连之前先探测，谁通就用谁 */
  private endpoints: Endpoint[];
  private username: string;
  private password: string;
  private resolved: string = '';
  /** 本实例是否已经强制重登过（防止 401 风暴） */
  private forceReloginUsed: boolean = false;

  constructor(rawBaseUrl: string, username: string, password: string) {
    this.endpoints = parseEndpoints(rawBaseUrl);
    this.username = username;
    this.password = password;
  }

  isConfigured(): boolean {
    return this.endpoints.length > 0 && this.username.trim().length > 0;
  }

  label(): string {
    let base: string = this.resolved.length > 0 ? this.resolved :
      (this.endpoints.length > 0 ? this.endpoints[0].display() : '');
    const proto: number = base.indexOf('://');
    if (proto >= 0) {
      base = base.substring(proto + 3);
    }
    return base.replace(/\/+$/g, '');
  }

  /** 当前配置里的所有候选地址（会话 token 在这些地址上通用） */
  private bases(): string[] {
    const out: string[] = [];
    for (const ep of this.endpoints) {
      out.push(ep.display().replace(/\/+$/g, ''));
    }
    return out;
  }

  /** 本实例的选路缓存 key：配置变了就换 key，避免设置页测试污染正在用的配置 */
  private cacheKey(): string {
    const keys: string[] = [];
    for (const ep of this.endpoints) {
      keys.push(ep.hostKey());
    }
    return `songloft:${keys.join(',')}`;
  }

  /** 单地址探测：2xx/3xx、401、403 都说明对面是 Songloft（401=服务在但要登录） */
  private probeEndpoint(ep: Endpoint): Promise<boolean> {
    return get(ep.url('/api/v1/songs?limit=1'), {}, TimeoutTier.PROBE)
      .then((reply: Reply): boolean =>
        (reply.code >= 200 && reply.code <= 399) || reply.code === 401 || reply.code === 403)
      .catch((): boolean => false);
  }

  /**
   * 实际在用的地址：统一走 EndpointResolver（内网优先 / 并发探测 / 网络切换清缓存）。
   * 解决了以前串行探测「第一个地址回错误码也算通」「切到流量还死守内网 IP」的问题 ——
   * 这也是「同时填域名和 IP 就连不上，删掉内网才行」的根因。
   */
  private async probeBase(): Promise<string> {
    if (this.endpoints.length === 0) {
      return '';
    }
    const chosen: Endpoint | null = await EndpointResolver.resolveAny(
      this.cacheKey(), this.endpoints, EndpointMode.AUTO, -1,
      (ep: Endpoint): Promise<boolean> => this.probeEndpoint(ep));
    const value: string = chosen !== null ? chosen.display() : this.endpoints[0].display();
    this.resolved = value;
    return value;
  }

  private invalidateBase(): void {
    this.resolved = '';
    EndpointResolver.invalidate(this.cacheKey());
  }

  /**
   * 地址轮换：这个地址连不上就换下一个（内网 → 外网域名）。
   * 只对网络层失败重试；业务错误（401/404）不换地址，否则会把问题藏起来。
   */
  private async rotating<T>(block: () => Promise<T>): Promise<T> {
    const count: number = Math.max(this.endpoints.length, 1);
    let last: ApiException = new ApiException('连不上 Songloft，检查地址和网络');
    for (let i = 0; i < count; i++) {
      try {
        return await block();
      } catch (e) {
        const err: Error = e as Error;
        // 网络层失败（没有 HTTP 状态码）才轮换地址
        if (err instanceof ApiException && (err as ApiException).code > 0) {
          throw err;
        }
        last = err instanceof ApiException ? err as ApiException : new ApiException(err.message);
        this.invalidateBase();
      }
    }
    throw last;
  }

  // ---------------------------------------------------------------- 账号

  /** 登录并写入全局会话（图片/音频请求靠它补 token） */
  private async login(): Promise<string> {
    const base: string = await this.probeBase();
    if (base.length === 0) {
      throw new ApiException('还没填 Songloft 地址（设置 → 音乐服务）');
    }
    if (this.username.trim().length === 0) {
      throw new ApiException('还没填 Songloft 账号');
    }
    const payload: Record<string, Object> = {
      'username': this.username as Object,
      'password': this.password as Object
    };
    // 登录也要能换地址：内网不通（在外面用流量）就自动走公网域名
    const res: Reply = await this.rotating<Reply>(async (): Promise<Reply> =>
      postJson(this.url('/api/v1/auth/login'), JSON.stringify(payload)));

    const body: string = res.body;
    const json: Record<string, Object> | null = parseJsonObject(body);
    if (json === null) {
      throw new ApiException(body.trimStart().startsWith('<')
        ? '登录返回的是网页而不是数据，地址可能少填端口或指到了别的服务'
        : `登录返回异常（HTTP ${res.code}）`);
    }
    if (!res.isSuccessful()) {
      let message: string = jStr(json, ['error']);
      if (message.length === 0) {
        message = jStr(json, ['detail']);
      }
      // Songloft 对登录接口有频率限制：短时间内多次登录会返回
      // 「登录尝试过于频繁，请稍后再试」。这里记下来并进入冷却。
      const limited: boolean = res.code === 429 ||
        message.includes('频繁') ||
        message.toLowerCase().includes('too many') ||
        message.toLowerCase().includes('rate limit');
      if (limited) {
        // 服务端限流是递增惩罚 —— 用指数退避，优先采信 Retry-After。
        let retryAfter: number = 0;
        const ra: string | undefined = res.headers['retry-after'];
        if (ra !== undefined) {
          const parsed: number = parseInt(ra.trim(), 10);
          if (!isNaN(parsed)) {
            retryAfter = Math.min(Math.max(parsed, 30), 900);
          }
        }
        SongloftSession.markBlocked(retryAfter, message);
        throw new ApiException(SongloftSession.cooldownMessage(), res.code);
      }
      if (message.includes('密码') || message.includes('credentials') || res.code === 401) {
        throw new ApiException('账号或密码不对', res.code);
      }
      throw new ApiException(message.length > 0 ? message : `登录失败（HTTP ${res.code}）`, res.code);
    }
    const token: string = jStr(json, ['access_token']);
    if (token.length === 0) {
      throw new ApiException('登录成功但没返回 access_token，服务端版本可能不匹配');
    }
    const expiresIn: number = jNum(json, ['expires_in']);
    const currentBase: string = await this.probeBase();
    SongloftSession.update(currentBase, token,
      expiresIn > 0 ? Date.now() + expiresIn * 1000 : 0);
    return token;
  }

  private async ensureToken(force: boolean = false): Promise<string> {
    if (SongloftSession.cooldownLeft() > 0) {
      throw new ApiException(SongloftSession.cooldownMessage());
    }
    if (!force && SongloftSession.matches(this.bases())) {
      return SongloftSession.getToken();
    }
    return await this.login();
  }

  // ---------------------------------------------------------------- 接口

  async test(): Promise<string> {
    await this.ensureToken(true);
    let stats: MusicLibraryStats | null = null;
    try {
      stats = await this.stats();
    } catch (err) {
      stats = null;
    }
    if (stats === null) {
      return '登录成功';
    }
    return `登录成功 · 音乐库 ${stats.totalSongs} 首 / ${stats.artistCount} 位歌手`;
  }

  async songs(keyword: string = '', offset: number = 0, limit: number = 50): Promise<SongPage> {
    let query: string = `limit=${limit}&offset=${offset}`;
    if (keyword.trim().length > 0) {
      query += `&keyword=${enc(keyword)}`;
    }
    const json: Record<string, Object> = await this.get(`/api/v1/songs?${query}`);
    return this.parseSongs(json);
  }

  async playlists(limit: number = 40, offset: number = 0): Promise<MusicPlaylist[]> {
    const json: Record<string, Object> =
      await this.get(`/api/v1/playlists?limit=${limit}&offset=${offset}`);
    const array: Array<Record<string, Object>> | null = this.arrayOf(json, ['items', 'data', 'playlists', 'list']);
    const out: MusicPlaylist[] = [];
    if (array === null) {
      return out;
    }
    for (const obj of array) {
      out.push(this.parsePlaylist(obj));
    }
    return out;
  }

  async playlistSongs(id: number, offset: number = 0, limit: number = 200): Promise<SongPage> {
    const json: Record<string, Object> =
      await this.get(`/api/v1/playlists/${id}/songs?limit=${limit}&offset=${offset}`);
    return this.parseSongs(json);
  }

  // ---------------------------------------------------------------- 收藏

  /** 全量收藏歌曲 id（翻页拿完，用于列表红心标记） */
  async favoriteIds(): Promise<Set<number>> {
    const ids: Set<number> = new Set<number>();
    let offset: number = 0;
    while (true) {
      const page: SongPage = this.parseSongs(
        await this.get(`/api/v1/playlists/${FAVORITE_PLAYLIST_ID}/songs?limit=200&offset=${offset}`));
      for (const s of page.songs) {
        ids.add(s.id);
      }
      if (page.songs.length === 0 || ids.size >= page.total) {
        break;
      }
      offset += page.songs.length;
    }
    return ids;
  }

  /** @return true = 服务端已生效（失败返回 false，由调用方回滚乐观更新） */
  async setFavorite(songId: number, favorite: boolean): Promise<boolean> {
    try {
      if (favorite) {
        const payload: Record<string, Object> = { 'song_ids': [songId] as Object };
        await this.send(`/api/v1/playlists/${FAVORITE_PLAYLIST_ID}/songs`, 'POST',
          JSON.stringify(payload));
      } else {
        await this.send(`/api/v1/playlists/${FAVORITE_PLAYLIST_ID}/songs/${songId}`, 'DELETE', null);
      }
      return true;
    } catch (err) {
      return false;
    }
  }

  async stats(): Promise<MusicLibraryStats> {
    const json: Record<string, Object> = await this.get('/api/v1/songs/stats');
    const st: MusicLibraryStats = new MusicLibraryStats();
    st.totalSongs = Math.trunc(jNum(json, ['total_songs', 'totalSongs', 'total']));
    st.artistCount = Math.trunc(jNum(json, ['artist_count', 'artistCount']));
    st.albumCount = Math.trunc(jNum(json, ['album_count', 'albumCount']));
    st.totalDuration = jNum(json, ['total_duration', 'totalDuration']);
    return st;
  }

  // ---------------------------------------------------------------- 解析

  private arrayOf(obj: Record<string, Object>, keys: string[]): Array<Record<string, Object>> | null {
    for (const key of keys) {
      const arr: Array<Record<string, Object>> | null = jArr(obj, key);
      if (arr !== null) {
        return arr;
      }
    }
    return null;
  }

  private parseSongs(json: Record<string, Object>): SongPage {
    const array: Array<Record<string, Object>> | null =
      this.arrayOf(json, ['items', 'songs', 'data', 'list']);
    const songs: MusicSong[] = [];
    if (array !== null) {
      for (const obj of array) {
        const s: MusicSong | null = this.parseSong(obj);
        if (s !== null) {
          songs.push(s);
        }
      }
    }
    let total: number = Math.trunc(jNum(json, ['total', 'count']));
    if (total <= 0) {
      total = songs.length;
    }
    return new SongPage(songs, total);
  }

  private parseSong(obj: Record<string, Object>): MusicSong | null {
    const durationRaw: number = jNum(obj, ['duration']);
    // 后端存的是秒；万一某版本给了毫秒，按 >10000 判断并换算
    let seconds: number = 0;
    if (durationRaw <= 0) {
      seconds = 0;
    } else if (durationRaw > 10000) {
      seconds = Math.trunc(durationRaw / 1000);
    } else {
      seconds = Math.trunc(durationRaw);
    }
    let title: string = jStr(obj, ['title', 'name']);
    if (title.length === 0) {
      title = '未知曲目';
    }
    const s: MusicSong = new MusicSong();
    s.id = Math.trunc(jNum(obj, ['id']));
    s.title = title;
    s.artist = this.artistOf(obj);
    s.album = jStr(obj, ['album', 'album_name', 'albumName']);
    s.durationSeconds = seconds;
    s.streamUrl = this.absolute(jStr(obj, ['url', 'stream_url', 'streamUrl', 'src']));
    s.coverUrl = this.coverOf(obj);
    s.format = jStr(obj, ['format', 'ext']);
    s.bitRate = Math.trunc(jNum(obj, ['bit_rate', 'bitRate']));
    s.isVideo = jBool(obj, ['is_video', 'isVideo']);
    return s.id > 0 ? s : null;
  }

  /** artist 可能是字符串，也可能是 {name:...} 或 [{artist:{name:...}}] */
  private artistOf(obj: Record<string, Object>): string {
    let raw: Object | undefined = obj['artist'];
    if (raw === undefined || raw === null) {
      raw = obj['artists'];
    }
    if (raw === undefined || raw === null) {
      return '';
    }
    if (typeof raw === 'string') {
      return raw as string;
    }
    if (Array.isArray(raw)) {
      const names: string[] = [];
      const arr: Array<Object> = raw as Array<Object>;
      for (const item of arr) {
        if (typeof item === 'string') {
          names.push(item as string);
        } else if (typeof item === 'object' && item !== null) {
          const io: Record<string, Object> = item as Record<string, Object>;
          const nested: Record<string, Object> | null = jObj(io, 'artist');
          const target: Record<string, Object> = nested !== null ? nested : io;
          const name: string = jStr(target, ['name']);
          if (name.length > 0) {
            names.push(name);
          }
        }
      }
      // 去重
      const distinct: string[] = [];
      for (const n of names) {
        if (distinct.indexOf(n) < 0) {
          distinct.push(n);
        }
      }
      return distinct.join(' / ');
    }
    if (typeof raw === 'object') {
      return jStr(raw as Record<string, Object>, ['name']);
    }
    return '';
  }

  private coverOf(obj: Record<string, Object>): string {
    const raw: string = jStr(obj, ['cover_url', 'coverUrl', 'cover', 'pic', 'artwork', 'image',
      'cover_path', 'coverPath', 'album_cover', 'albumCover']);
    if (raw.length > 0) {
      return this.withToken(this.absolute(raw));
    }
    // 少数版本把封面挂在 album 对象里：{album: {cover_url: "/..."}}
    let nested: Record<string, Object> | null = jObj(obj, 'album');
    if (nested === null) {
      nested = jObj(obj, 'cover');
    }
    if (nested === null) {
      return '';
    }
    const inner: string =
      jStr(nested, ['cover_url', 'coverUrl', 'cover', 'pic', 'url', 'path']);
    return inner.length > 0 ? this.withToken(this.absolute(inner)) : '';
  }

  private parsePlaylist(obj: Record<string, Object>): MusicPlaylist {
    const p: MusicPlaylist = new MusicPlaylist();
    p.id = Math.trunc(jNum(obj, ['id']));
    let name: string = jStr(obj, ['name', 'title']);
    if (name.length === 0) {
      name = '未命名歌单';
    }
    p.name = name;
    p.description = jStr(obj, ['description', 'desc']);
    p.songCount = Math.trunc(jNum(obj, ['song_count', 'songCount', 'total', 'count']));
    const cover: string = jStr(obj, ['cover_url', 'coverUrl']);
    p.coverUrl = cover.length > 0 ? this.withToken(this.absolute(cover)) : '';
    p.type = jStr(obj, ['type']);
    return p;
  }

  // ---------------------------------------------------------------- 工具

  private absolute(raw: string): string {
    const value: string = raw.trim();
    if (value.length === 0) {
      return '';
    }
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    const base: string = this.resolved.length > 0 ? this.resolved : this.endpoints[0].display();
    return value.startsWith('/') ? `${base}${value}` : `${base}/${value}`;
  }

  /** 媒体地址补 access_token（Songloft 自己就这么拼，播放器拿不到请求头也没关系） */
  withToken(url: string): string {
    const token: string = SongloftSession.matches(this.bases()) ? SongloftSession.getToken() : '';
    if (token.length === 0 || url.length === 0) {
      return url;
    }
    if (url.includes('access_token=')) {
      return url;
    }
    const sep: string = url.includes('?') ? '&' : '?';
    return `${url}${sep}access_token=${enc(token)}`;
  }

  /**
   * 确保 access_token 是新的（过期就自动重登）。
   * 播放器拉流走的是查询参数里的 token，拼 URL 前必须先刷新，
   * 否则挂机超过 expires_in 后播放 401（表现为「播放操作失败」）。
   */
  async ensureFreshToken(): Promise<void> {
    await this.ensureToken(false);
  }

  /** 真正用于播放的地址：绝对化 + 带 token */
  playableUrl(song: MusicSong): string {
    return this.withToken(song.streamUrl);
  }

  private async get(path: string): Promise<Record<string, Object>> {
    return await this.rotating<Record<string, Object>>(async (): Promise<Record<string, Object>> =>
      this.getOnce(path));
  }

  private async getOnce(path: string): Promise<Record<string, Object>> {
    let res: Reply = await get(this.url(path), {
      'Authorization': `Bearer ${await this.ensureToken()}`
    });
    // 只允许一次强制重登：如果 token 本身没问题而接口一直 401，
    // 反复强制登录只会把服务端打成限流。
    if (res.code === 401 && !this.forceReloginUsed) {
      this.forceReloginUsed = true;
      res = await get(this.url(path), {
        'Authorization': `Bearer ${await this.ensureToken(true)}`
      });
    }
    let json: Record<string, Object> | null = parseJsonObject(res.body);
    if (json === null) {
      // 少数接口可能直接返回数组，这里兜一下
      const arr: Array<Record<string, Object>> | null = parseJsonArray(res.body);
      if (arr !== null) {
        json = { 'items': arr as Object };
      } else {
        throw new ApiException(res.body.trimStart().startsWith('<')
          ? '返回的是网页而不是数据，检查地址（子路径/端口）'
          : `Songloft 返回的不是 JSON（HTTP ${res.code}）`, res.code);
      }
    }
    if (!res.isSuccessful()) {
      let message: string = jStr(json, ['error']);
      if (message.length === 0) {
        message = jStr(json, ['detail']);
      }
      if (message.length === 0) {
        message = res.code === 401 ? '登录已失效，请重新保存一次账号' : `请求失败（HTTP ${res.code}）`;
      }
      throw new ApiException(message, res.code);
    }
    return json;
  }

  /** POST/DELETE 通用请求（收藏用），401 时重登一次再试 */
  private async send(path: string, method: string, body: string | null): Promise<void> {
    let res: Reply;
    if (method === 'POST') {
      res = await postJson(this.url(path), body !== null ? body : '', {
        'Authorization': `Bearer ${await this.ensureToken()}`
      });
    } else {
      res = await del(this.url(path), {
        'Authorization': `Bearer ${await this.ensureToken()}`
      });
    }
    if (res.code === 401 && !this.forceReloginUsed) {
      this.forceReloginUsed = true;
      const token: string = await this.ensureToken(true);
      if (method === 'POST') {
        res = await postJson(this.url(path), body !== null ? body : '', {
          'Authorization': `Bearer ${token}`
        });
      } else {
        res = await del(this.url(path), { 'Authorization': `Bearer ${token}` });
      }
    }
    if (!res.isSuccessful()) {
      throw new ApiException(`收藏操作失败（HTTP ${res.code}）`, res.code);
    }
  }

  private url(path: string): string {
    // resolved 可能为空（还没探测）：兜底第一条地址
    const base: string = this.resolved.length > 0 ? this.resolved :
      (this.endpoints.length > 0 ? this.endpoints[0].display() : '');
    return base + (path.startsWith('/') ? path : `/${path}`);
  }
}
