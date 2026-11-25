import { Endpoint, ServerConfig, ServerSnapshot, ServerType, TorrentStatus,
  TorrentTask, TorrentFetchResult, AddTorrentOptions, TrackerEntry } from '../model/Models';
import { get, postForm, postBytes, buildMultipart, TimeoutTier, ApiException, Reply } from './HttpClient';
import { EndpointResolver, EndpointProbe } from './EndpointResolver';
import { trackerHostOf } from '../common/Format';
import { parseJsonArray, parseJsonObject, jStr, jNum, jBool, logDebug } from '../common/AppConstants';

/**
 * qBittorrent 协议客户端（对应安卓 net/QBittorrentClient.kt）：
 * 登录（Cookie 或 API Key Bearer 双通道）、任务增删改查/暂停/继续/校验/汇报。
 */
export class QBittorrentClient {
  private readonly server: ServerConfig;
  private authHeaders: Map<string, string> = new Map();

  constructor(server: ServerConfig) {
    this.server = server;
  }

  private async withEndpoint(probe: EndpointProbe, block: (ep: Endpoint) => Promise<void>): Promise<void> {
    const endpoint: Endpoint = await EndpointResolver.resolve(this.server, probe);
    try {
      await block(endpoint);
    } catch (e) {
      const err: Error = e as Error;
      // 地址切换：清掉缓存，换下一个候选再试一次
      EndpointResolver.invalidate(this.server.id);
      const retry: Endpoint = await EndpointResolver.resolve(this.server, probe);
      if (retry.hostKey() === endpoint.hostKey()) {
        throw err;
      }
      await block(retry);
    }
  }

  private probe: EndpointProbe = async (endpoint: Endpoint): Promise<boolean> => {
    try {
      const headers: Record<string, string> = { 'Referer': endpoint.display() };
      const res: Reply = await get(endpoint.url('api/v2/app/webapiVersion'), headers, TimeoutTier.PROBE);
      return res.code >= 200 && res.code < 500;
    } catch (err) {
      return false;
    }
  };

  private async ensureLogin(endpoint: Endpoint): Promise<void> {
    const key: string = endpoint.hostKey();
    if (this.authHeaders.has(key)) {
      return;
    }
    if (this.server.useApiKey && this.server.apiKey.trim().length > 0) {
      this.authHeaders.set(key, `Bearer ${this.server.apiKey}`);
      return;
    }
    const form: Record<string, string> = {
      'username': this.server.username,
      'password': this.server.password
    };
    const headers: Record<string, string> = {
      'Referer': endpoint.display(),
      'Origin': endpoint.display()
    };
    const res: Reply = await postForm(endpoint.url('api/v2/auth/login'), form, headers);
    const okLogin: boolean = res.code >= 200 && res.code < 300 &&
      res.body.toLowerCase().indexOf('fails') < 0;
    if (!okLogin) {
      if (res.code === 403) {
        throw new ApiException('登录被拒绝：用户名或密码错误，或 IP 被临时封禁', 403);
      }
      throw new ApiException(`登录失败 HTTP ${res.code}`, res.code);
    }
    this.authHeaders.set(key, '');
    logDebug('QB', `登录成功 ${key}`);
  }

  private headersFor(endpoint: Endpoint): Record<string, string> {
    const auth: string = this.authHeaders.get(endpoint.hostKey()) ?? '';
    const base: Record<string, string> = {
      'Referer': endpoint.display(),
      'Accept': 'application/json'
    };
    if (auth.startsWith('Bearer ')) {
      base['Authorization'] = auth;
    }
    return base;
  }

  /** 一次拉回任务列表 + 服务器状态，失败抛 ApiException */
  async fetchAll(): Promise<TorrentFetchResult> {
    let result: TorrentFetchResult | null = null;
    let lastError: Error | null = null;
    await this.withEndpoint(this.probe, async (endpoint: Endpoint): Promise<void> => {
      try {
        await this.ensureLogin(endpoint);
        const headers: Record<string, string> = this.headersFor(endpoint);
        const torrentsRes: Reply = await get(endpoint.url('api/v2/torrents/info'), headers);
        if (torrentsRes.code === 403) {
          this.authHeaders.delete(endpoint.hostKey());
          throw new ApiException('会话失效（HTTP 403）', 403);
        }
        if (!torrentsRes.isSuccessful()) {
          throw new ApiException(`获取任务失败 HTTP ${torrentsRes.code}`, torrentsRes.code);
        }
        let syncJson: string = '';
        try {
          const syncRes: Reply = await get(endpoint.url('api/v2/sync/maindata?rid=0'), headers);
          if (syncRes.isSuccessful()) {
            syncJson = syncRes.body;
          }
        } catch (err) {
          syncJson = '';
        }
        // 备用限速状态：maindata 里没有，得单独读一次（同安卓）
        let altSpeed: boolean = false;
        let altKnown: boolean = false;
        try {
          // 加时间戳绕开反代/系统缓存：这是「当前状态」接口，绝不能拿到上一轮的结果
          const altRes: Reply = await get(
            endpoint.url(`api/v2/transfer/speedLimitsMode?_=${Date.now()}`), headers);
          if (altRes.isSuccessful()) {
            const altText: string = altRes.body.trim().toLowerCase();
            altSpeed = altText === '1' || altText === 'true';
            altKnown = true;
          }
        } catch (err) {
          // 读失败就标记「未知」，不要写成 false（写了就是误报「已关闭」，图标会乱跳）
          altKnown = false;
        }
        // 版本号：侧边栏顶部徽标要用（安卓 fetchAll 已读，鸿蒙之前漏了）
        let version: string = '';
        try {
          const verRes: Reply = await get(endpoint.url('api/v2/app/version'), headers);
          if (verRes.isSuccessful()) {
            version = verRes.body.trim();
          }
        } catch (err) {
          version = '';
        }
        const tasks: TorrentTask[] = this.parseTorrents(torrentsRes.body);
        const snapshot: ServerSnapshot =
          this.buildSnapshot(tasks, syncJson, endpoint, altSpeed, altKnown, version);
        const r: TorrentFetchResult = new TorrentFetchResult();
        r.tasks = tasks;
        r.snapshot = snapshot;
        result = r;
      } catch (e) {
        const err: Error = e as Error;
        lastError = err;
        throw err;
      }
    });
    if (result !== null) {
      return result;
    }
    throw lastError !== null ? lastError : new ApiException('连接失败');
  }

  private parseTorrents(raw: string): TorrentTask[] {
    const trimmed: string = raw.trim();
    if (trimmed.length === 0) {
      return [];
    }
    const arr: Array<Record<string, Object>> | null = parseJsonArray(trimmed);
    if (arr === null) {
      throw new ApiException('任务列表解析失败');
    }
    const result: TorrentTask[] = [];
    const now: number = Date.now();
    for (const obj of arr) {
      const state: string = jStr(obj, ['state']).toLowerCase();
      const tracker: string = jStr(obj, ['tracker']);
      const tagsRaw: string = jStr(obj, ['tags']);
      const addedOn: number = jNum(obj, ['added_on', 'addedOn'], 0);
      const completionOn: number = jNum(obj, ['completion_on', 'completionOn'], 0);

      const t: TorrentTask = new TorrentTask();
      t.hash = jStr(obj, ['hash']);
      t.serverId = this.server.id;
      t.serverType = ServerType.QBITTORRENT;
      t.name = jStr(obj, ['name']);
      let progress: number = jNum(obj, ['progress'], 0);
      progress = progress < 0 ? 0 : (progress > 1 ? 1 : progress);
      t.progress = progress;
      t.size = Math.trunc(jNum(obj, ['size'], 0));
      t.downloaded = Math.trunc(jNum(obj, ['downloaded'], 0));
      t.uploaded = Math.trunc(jNum(obj, ['uploaded'], 0));
      t.downloadSpeed = Math.trunc(jNum(obj, ['dlspeed', 'dl_speed'], 0));
      t.uploadSpeed = Math.trunc(jNum(obj, ['upspeed', 'up_speed'], 0));
      t.status = this.mapState(state);
      const eta: number = jNum(obj, ['eta'], 0);
      t.etaSeconds = eta >= 8640000 ? -1 : Math.trunc(eta);
      t.ratio = jNum(obj, ['ratio'], 0);
      t.numSeeds = Math.trunc(jNum(obj, ['num_seeds', 'numSeeds'], 0));
      t.totalSeeds = Math.trunc(jNum(obj, ['num_complete', 'numComplete'], 0));
      t.numPeers = Math.trunc(jNum(obj, ['num_leechs', 'numLeechs'], 0));
      t.totalPeers = Math.trunc(jNum(obj, ['num_incomplete', 'numIncomplete'], 0));
      t.category = jStr(obj, ['category']);
      const tags: string[] = [];
      if (tagsRaw.trim().length > 0) {
        const parts: string[] = tagsRaw.split(',');
        for (const p of parts) {
          const s: string = p.trim();
          if (s.length > 0) {
            tags.push(s);
          }
        }
      }
      t.tags = tags;
      t.savePath = jStr(obj, ['save_path', 'savePath']);
      t.trackerHost = trackerHostOf(tracker);
      t.addedAt = addedOn > 0 ? Math.trunc(addedOn) * 1000 : now;
      t.completedAt = completionOn > 0 ? Math.trunc(completionOn) * 1000 : 0;
      t.seedingSeconds = Math.trunc(jNum(obj, ['seeding_time', 'seedingTime'], 0));
      t.errorMessage = t.status === TorrentStatus.ERROR ? state : '';
      t.isSequential = jBool(obj, ['seq_dl', 'seqDl']);
      t.availability = jNum(obj, ['availability'], 0);
      // 限速：qB 用 -1 表示不限，这里统一成 0
      const dlLimit: number = Math.trunc(jNum(obj, ['dl_limit', 'dlLimit'], -1));
      const ulLimit: number = Math.trunc(jNum(obj, ['up_limit', 'upLimit'], -1));
      t.downloadLimit = dlLimit > 0 ? dlLimit : 0;
      t.uploadLimit = ulLimit > 0 ? ulLimit : 0;
      // 分享率：-2 全局 / -1 无限 / >0 自定义
      t.ratioLimit = jNum(obj, ['ratio_limit', 'ratioLimit'], -2);
      t.ratioMode = t.ratioLimit > 0 ? t.ratioLimit : (t.ratioLimit === -1 ? -1 : -2);
      result.push(t);
    }
    return result;
  }

  private buildSnapshot(tasks: TorrentTask[], syncJson: string, endpoint: Endpoint,
    altSpeed: boolean = false, altKnown: boolean = false, version: string = ''): ServerSnapshot {
    let freeSpace: number = 0;
    let allTimeDl: number = 0;
    let allTimeUl: number = 0;
    let dlSpeed: number = 0;
    let upSpeed: number = 0;
    const trimmed: string = syncJson.trim();
    if (trimmed.length > 0) {
      const root: Record<string, Object> | null = parseJsonObject(trimmed);
      if (root !== null) {
        const ss: Record<string, Object> | null = parseJsonObject(JSON.stringify(root['server_state'] ?? {}));
        if (ss !== null) {
          freeSpace = Math.trunc(jNum(ss, ['free_space_on_disk', 'freeSpaceOnDisk'], 0));
          allTimeDl = Math.trunc(jNum(ss, ['alltime_dl', 'alltimeDl'], 0));
          allTimeUl = Math.trunc(jNum(ss, ['alltime_ul', 'alltimeUl'], 0));
          dlSpeed = Math.trunc(jNum(ss, ['dl_info_speed', 'dlInfoSpeed'], 0));
          upSpeed = Math.trunc(jNum(ss, ['up_info_speed', 'upInfoSpeed'], 0));
        }
      }
    }

    let seeding: number = 0;
    let downloading: number = 0;
    let seedingSize: number = 0;
    let sumDl: number = 0;
    let sumUl: number = 0;
    let sumDownloaded: number = 0;
    let sumUploaded: number = 0;
    for (const t of tasks) {
      sumDl += t.downloadSpeed;
      sumUl += t.uploadSpeed;
      sumDownloaded += t.downloaded;
      sumUploaded += t.uploaded;
      if (t.status === TorrentStatus.SEEDING ||
        (t.isFinished() && t.status !== TorrentStatus.PAUSED)) {
        seeding++;
        seedingSize += t.size;
      }
      if (t.status === TorrentStatus.DOWNLOADING || t.status === TorrentStatus.QUEUED) {
        downloading++;
      }
    }

    const snap: ServerSnapshot = new ServerSnapshot();
    snap.serverId = this.server.id;
    snap.online = true;
    snap.downloadSpeed = dlSpeed > 0 ? dlSpeed : sumDl;
    snap.uploadSpeed = upSpeed > 0 ? upSpeed : sumUl;
    snap.seedingCount = seeding;
    snap.downloadingCount = downloading;
    snap.seedingSize = seedingSize;
    snap.totalUploaded = allTimeUl > 0 ? allTimeUl : sumUploaded;
    snap.totalDownloaded = allTimeDl > 0 ? allTimeDl : sumDownloaded;
    snap.freeSpace = freeSpace;
    snap.appVersion = version;
    snap.endpointLabel = endpoint.display();
    snap.altSpeedEnabled = altSpeed;
    snap.altSpeedKnown = altKnown;
    return snap;
  }

  private mapState(state: string): TorrentStatus {
    switch (state) {
      case 'metadl':
      case 'allocating':
      case 'downloading':
      case 'dl':
      case 'stalleddl':
      case 'forceddl':
      case 'forcedmetadl':
        return TorrentStatus.DOWNLOADING;
      case 'queueddl':
      case 'queuedup':
        return TorrentStatus.QUEUED;
      case 'uploading':
      case 'stalledup':
      case 'forcedup':
      case 'up':
        return TorrentStatus.SEEDING;
      case 'pauseddl':
      case 'pausedup':
      case 'paused':
      case 'stoppeddl':
      case 'stoppedup':
        return TorrentStatus.PAUSED;
      case 'checkingdl':
      case 'checkingup':
      case 'checkingresumedata':
      case 'moving':
        return TorrentStatus.CHECKING;
      case 'error':
      case 'missingfiles':
      case 'unregistered':
      case 'unregisteredtorrent':
      case 'unknown':
        return TorrentStatus.ERROR;
      case 'completed':
        return TorrentStatus.COMPLETED;
      default:
        return TorrentStatus.PAUSED;
    }
  }

  // ---------- 操作 ----------

  pause(hashes: string[]): Promise<void> {
    return this.action('api/v2/torrents/stop', hashes);
  }

  resume(hashes: string[]): Promise<void> {
    return this.action('api/v2/torrents/start', hashes);
  }

  recheck(hashes: string[]): Promise<void> {
    return this.action('api/v2/torrents/recheck', hashes);
  }

  reannounce(hashes: string[]): Promise<void> {
    return this.action('api/v2/torrents/reannounce', hashes);
  }

  async delete(hashes: string[], deleteFiles: boolean): Promise<void> {
    await this.withEndpoint(this.probe, async (endpoint: Endpoint): Promise<void> => {
      await this.ensureLogin(endpoint);
      const form: Record<string, string> = {
        'hashes': hashes.join('|'),
        'deleteFiles': deleteFiles ? 'true' : 'false'
      };
      const res: Reply = await postForm(endpoint.url('api/v2/torrents/delete'), form,
        this.headersFor(endpoint));
      if (!res.isSuccessful()) {
        throw new ApiException(`删除失败 HTTP ${res.code}`, res.code);
      }
    });
  }

  private async action(path: string, hashes: string[]): Promise<void> {
    await this.withEndpoint(this.probe, async (endpoint: Endpoint): Promise<void> => {
      await this.ensureLogin(endpoint);
      const form: Record<string, string> = { 'hashes': hashes.join('|') };
      const res: Reply = await postForm(endpoint.url(path), form, this.headersFor(endpoint));
      if (!res.isSuccessful()) {
        throw new ApiException(`操作失败 HTTP ${res.code}`, res.code);
      }
    });
  }

  // ---------- 单任务编辑（重命名 / 保存位置 / 分类 / 标签 / 限速 / 分享率） ----------

  /** 通用表单 POST：自动带 hashes，错误信息带上接口名方便定位 */
  private async formPost(path: string, form: Record<string, string>, label: string,
    hashes: string[] = []): Promise<void> {
    await this.withEndpoint(this.probe, async (endpoint: Endpoint): Promise<void> => {
      await this.ensureLogin(endpoint);
      const body: Record<string, string> = {};
      const keys: string[] = Object.keys(form);
      for (const k of keys) {
        body[k] = form[k];
      }
      if (hashes.length > 0 && body['hashes'] === undefined) {
        body['hashes'] = hashes.join('|');
      }
      const res: Reply = await postForm(endpoint.url(path), body, this.headersFor(endpoint));
      if (!res.isSuccessful()) {
        throw new ApiException(`${label}失败 HTTP ${res.code}`, res.code);
      }
    });
  }

  private async getText(path: string): Promise<Reply> {
    let out: Reply | null = null;
    await this.withEndpoint(this.probe, async (endpoint: Endpoint): Promise<void> => {
      await this.ensureLogin(endpoint);
      out = await get(endpoint.url(path), this.headersFor(endpoint));
    });
    if (out === null) {
      throw new ApiException('请求失败');
    }
    return out as Reply;
  }

  /** 强制继续（force start）：走的就是 setForceStart，与普通继续不同 */
  setForceStart(hashes: string[], value: boolean): Promise<void> {
    return this.formPost('api/v2/torrents/setForceStart', { 'value': value ? 'true' : 'false' },
      '强制继续', hashes);
  }

  setLocation(hashes: string[], location: string): Promise<void> {
    return this.formPost('api/v2/torrents/setLocation', { 'location': location }, '更改保存位置', hashes);
  }

  /** 重命名：oldPath 必须是「原路径」（单文件=文件名，多文件=顶层目录名） */
  rename(hash: string, oldPath: string, newPath: string): Promise<void> {
    return this.formPost('api/v2/torrents/rename',
      { 'hash': hash, 'oldPath': oldPath, 'newPath': newPath }, '重命名');
  }

  setCategory(hashes: string[], category: string): Promise<void> {
    return this.formPost('api/v2/torrents/setCategory', { 'category': category }, '设置分类', hashes);
  }

  createCategory(name: string, savePath: string): Promise<void> {
    const form: Record<string, string> = { 'category': name };
    if (savePath.trim().length > 0) {
      form['savePath'] = savePath.trim();
    }
    return this.formPost('api/v2/torrents/createCategory', form, '创建分类');
  }

  /** 注意是**替换**语义：追加标签要由调用方把原标签合并进来再传 */
  setTags(hashes: string[], tags: string[]): Promise<void> {
    return this.formPost('api/v2/torrents/setTags', { 'tags': tags.join(',') }, '设置标签', hashes);
  }

  /** 单位 bytes/s，0 = 不限 */
  setDownloadLimit(hashes: string[], bytesPerSecond: number): Promise<void> {
    return this.formPost('api/v2/torrents/setDownloadLimit',
      { 'limit': `${Math.max(0, Math.trunc(bytesPerSecond))}` }, '下载限速', hashes);
  }

  setUploadLimit(hashes: string[], bytesPerSecond: number): Promise<void> {
    return this.formPost('api/v2/torrents/setUploadLimit',
      { 'limit': `${Math.max(0, Math.trunc(bytesPerSecond))}` }, '上传限速', hashes);
  }

  /**
   * 分享率：ratioLimit -2 = 全局、-1 = 无限、>0 = 自定义。
   * seedingTimeLimit / inactiveSeedingTimeLimit 是**必填**，传错会顺手把用户的做种时间策略清掉，
   * 所以调用方要先 GET torrents/info 读回原值再原样传。
   */
  setShareLimits(hashes: string[], ratioLimit: number, seedingTimeLimit: number,
    inactiveSeedingTimeLimit: number): Promise<void> {
    return this.formPost('api/v2/torrents/setShareLimits', {
      'ratioLimit': `${ratioLimit}`,
      'seedingTimeLimit': `${Math.trunc(seedingTimeLimit)}`,
      'inactiveSeedingTimeLimit': `${Math.trunc(inactiveSeedingTimeLimit)}`
    }, '分享率设置', hashes);
  }

  setAutoManagement(hashes: string[], enabled: boolean): Promise<void> {
    return this.formPost('api/v2/torrents/setAutoManagement',
      { 'enable': enabled ? 'true' : 'false' }, '自动种子管理', hashes);
  }

  setSuperSeeding(hashes: string[], enabled: boolean): Promise<void> {
    return this.formPost('api/v2/torrents/setSuperSeeding',
      { 'value': enabled ? 'true' : 'false' }, '超级种子模式', hashes);
  }

  // ---------- Tracker 列表（查看 / 编辑） ----------

  /**
   * 单个任务的 Tracker 列表（`torrents/trackers`）。
   * 返回里除了真 Tracker 还有 DHT / PEX / LSD 三条伪条目（URL 形如 «** [DHT] **»），
   * 原样返回、由 TrackerEntry.special() 标记，UI 只展示不让编辑。
   */
  async trackers(hash: string): Promise<TrackerEntry[]> {
    const res: Reply = await this.getText(`api/v2/torrents/trackers?hash=${hash}`);
    const arr: Array<Record<string, Object>> | null = parseJsonArray(res.body);
    const out: TrackerEntry[] = [];
    if (arr === null) {
      return out;
    }
    for (const o of arr) {
      const url: string = jStr(o, ['url']).trim();
      if (url.length === 0) {
        continue;
      }
      const e: TrackerEntry = new TrackerEntry();
      e.url = url;
      e.status = Math.trunc(jNum(o, ['status'], -1));
      e.tier = Math.trunc(jNum(o, ['tier'], 0));
      e.seeds = Math.trunc(jNum(o, ['num_seeds'], 0));
      e.leeches = Math.trunc(jNum(o, ['num_leeches'], 0));
      e.peers = Math.trunc(jNum(o, ['num_peers'], 0));
      e.message = jStr(o, ['msg']).trim();
      out.push(e);
    }
    return out;
  }

  /** 改一条 Tracker：origUrl 必须和服务器上的原值一字不差 */
  editTracker(hash: string, origUrl: string, newUrl: string): Promise<void> {
    return this.formPost('api/v2/torrents/editTracker',
      { 'hash': hash, 'origUrl': origUrl, 'newUrl': newUrl }, '修改 Tracker');
  }

  /** 追加 Tracker（多条用换行分隔，qB 会并进默认 tier） */
  addTrackers(hash: string, urls: string[]): Promise<void> {
    return this.formPost('api/v2/torrents/addTrackers',
      { 'hash': hash, 'urls': urls.join('\n') }, '添加 Tracker');
  }

  /** 删除 Tracker：qB 这里多条要用 `|` 分隔（不是换行） */
  removeTrackers(hash: string, urls: string[]): Promise<void> {
    return this.formPost('api/v2/torrents/removeTrackers',
      { 'hash': hash, 'urls': urls.join('|') }, '删除 Tracker');
  }

  /** 已有分类名（用于新建/选择下拉） */
  async categories(): Promise<string[]> {
    const res: Reply = await this.getText('api/v2/torrents/categories');
    const obj: Record<string, Object> | null = parseJsonObject(res.body);
    if (obj === null) {
      return [];
    }
    const out: string[] = [];
    const keys: string[] = Object.keys(obj);
    for (const k of keys) {
      if (k.trim().length > 0) {
        out.push(k);
      }
    }
    return out.sort();
  }

  async tags(): Promise<string[]> {
    const res: Reply = await this.getText('api/v2/torrents/tags');
    const arr: Array<Record<string, Object>> | null = parseJsonArray(res.body);
    if (arr === null) {
      return [];
    }
    const out: string[] = [];
    for (const item of arr) {
      // v4 返回裸字符串数组，这里兼容 {name: "x"} 形态
      if (typeof item === 'string') {
        out.push(item as string);
      } else {
        const name: string = jStr(item as Record<string, Object>, ['name', 'tag']);
        if (name.length > 0) {
          out.push(name);
        }
      }
    }
    return out.sort();
  }

  /** 备用限速当前是否开启（0=正常，1=备用） */
  /** 备用限速是否开启：qB 返回纯文本，老版本是 "1"/"0"，新版本可能给 "true"/"false"，都认 */
  async speedLimitsMode(): Promise<boolean> {
    // 同样带时间戳，确保读到的是「此刻」的状态
    const res: Reply = await this.getText(`api/v2/transfer/speedLimitsMode?_=${Date.now()}`);
    if (!res.isSuccessful()) {
      // 不能把错误页当成「0」：那会得出「已关闭」的假结论
      throw new ApiException(`读取限速状态失败 HTTP ${res.code}`, res.code);
    }
    const v: string = res.body.trim().toLowerCase();
    return v === '1' || v === 'true';
  }

  toggleSpeedLimitsMode(): Promise<void> {
    return this.formPost('api/v2/transfer/toggleSpeedLimitsMode', {} as Record<string, string>, '切换限速模式');
  }

  /** 读单个任务的完整字段（拿原分享率限制用，避免覆盖用户的做种时间策略） */
  async torrentInfo(hash: string): Promise<Record<string, Object> | null> {
    const res: Reply = await this.getText(`api/v2/torrents/info?hashes=${encodeURIComponent(hash)}`);
    const arr: Array<Record<string, Object>> | null = parseJsonArray(res.body);
    if (arr === null || arr.length === 0) {
      return null;
    }
    return arr[0];
  }

  /** 本地 .torrent 文件上传：qB 只接受 multipart 文件字段，没法塞进表单 */
  async addTorrentFile(bytes: ArrayBuffer, fileName: string, opts: AddTorrentOptions): Promise<void> {
    const fields: Record<string, string> = {
      'autoTMM': opts.autoTMM ? 'true' : 'false'
    };
    if (opts.savePath.trim().length > 0) {
      fields['savepath'] = opts.savePath.trim();
    }
    if (opts.category.trim().length > 0) {
      fields['category'] = opts.category.trim();
    }
    if (opts.rename.trim().length > 0) {
      fields['rename'] = opts.rename.trim();
    }
    if (opts.skipChecking) {
      fields['skip_checking'] = 'true';
    }
    if (opts.paused) {
      // 4.x 用 paused，5.x 改叫 stopped，两个都发，老版本忽略不认识的
      fields['paused'] = 'true';
      fields['stopped'] = 'true';
    }
    const boundary: string = `----mptools${Date.now()}`;
    const body: ArrayBuffer = buildMultipart(boundary, fields, 'torrents',
      fileName.length > 0 ? fileName : 'upload.torrent', bytes);
    await this.withEndpoint(this.probe, async (endpoint: Endpoint): Promise<void> => {
      await this.ensureLogin(endpoint);
      const res: Reply = await postBytes(endpoint.url('api/v2/torrents/add'), body,
        `multipart/form-data; boundary=${boundary}`, this.headersFor(endpoint), TimeoutTier.SLOW);
      if (!res.isSuccessful()) {
        throw new ApiException(`添加种子失败 HTTP ${res.code}`, res.code);
      }
      if (res.body.toLowerCase().indexOf('fails') >= 0) {
        throw new ApiException('qBittorrent 拒绝该种子文件（可能已损坏或已存在）');
      }
    });
  }

  /**
   * 批量添加种子（RSS 自动下载用）。支持 magnet / http 直链。
   * qB 4.x 用 paused，5.x 改名为 stopped，这里两个都发，老版本会忽略不认识的字段。
   */
  async addTorrents(urls: string[], savePath: string = '', category: string = '',
    paused: boolean = false, firstLastPiecePriority: boolean = false,
    skipChecking: boolean = false): Promise<void> {
    const targets: string[] = [];
    for (const u of urls) {
      const t: string = u.trim();
      if (t.length > 0) {
        targets.push(t);
      }
    }
    if (targets.length === 0) {
      return;
    }
    await this.withEndpoint(this.probe, async (endpoint: Endpoint): Promise<void> => {
      await this.ensureLogin(endpoint);
      const form: Record<string, string> = {
        'urls': targets.join('\n'),
        'autoTMM': 'false'
      };
      if (savePath.trim().length > 0) {
        form['savepath'] = savePath;
      }
      if (category.trim().length > 0) {
        form['category'] = category;
      }
      if (paused) {
        form['paused'] = 'true';
        form['stopped'] = 'true';
      }
      if (firstLastPiecePriority) {
        form['firstLastPiecePrio'] = 'true';
        form['sequentialDownload'] = 'true';
      }
      if (skipChecking) {
        form['skip_checking'] = 'true';
      }
      const res: Reply =
        await postForm(endpoint.url('api/v2/torrents/add'), form, this.headersFor(endpoint));
      if (!res.isSuccessful()) {
        throw new ApiException(`添加任务失败 HTTP ${res.code}`, res.code);
      }
      if (res.body.toLowerCase().indexOf('fails') >= 0) {
        throw new ApiException('qBittorrent 拒绝该种子（链接可能失效或站点需要登录）');
      }
    });
  }
}
