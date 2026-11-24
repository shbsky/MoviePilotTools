import { Endpoint, ServerConfig, ServerSnapshot, ServerType, TorrentStatus,
  TorrentTask, TorrentFetchResult, AddTorrentOptions, TrackerEntry } from '../model/Models';
import { basicAuth, postJson, TimeoutTier, ApiException, Reply } from './HttpClient';
import { EndpointResolver, EndpointProbe } from './EndpointResolver';
import { trackerHostOf } from '../common/Format';
import { parseJsonObject, parseJsonArray, jRawArr, jStr, jNum, jBool } from '../common/AppConstants';

/**
 * Transmission RPC 客户端（对应安卓 net/TransmissionClient.kt）：
 * 会话 ID 获取与 409 重试、可配 rpcPath、任务/统计。
 */

interface RpcPayload {
  method: string;
  arguments?: Record<string, Object>;
}

const TORRENT_FIELDS: string[] = [
  'id', 'hashString', 'name', 'percentDone', 'totalSize', 'downloadedEver', 'uploadedEver',
  'rateDownload', 'rateUpload', 'status', 'eta', 'uploadRatio', 'peersSendingToUs',
  'peersGettingFromUs', 'peersConnected', 'trackerStats', 'downloadDir', 'labels',
  'addedDate', 'doneDate', 'secondsSeeding', 'error', 'errorString', 'isFinished',
  'sequentialDownload', 'recheckProgress',
  'downloadLimit', 'downloadLimitMode', 'uploadLimit', 'uploadLimitMode',
  'seedRatioMode', 'seedRatioLimit'
];

export class TransmissionClient {
  private readonly server: ServerConfig;
  private sessionIds: Map<string, string> = new Map();

  constructor(server: ServerConfig) {
    this.server = server;
  }

  private rpcUrl(endpoint: Endpoint): string {
    let path: string = this.server.rpcPath.trim();
    if (path.length === 0) {
      path = '/transmission/rpc';
    }
    let base: string = endpoint.display();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    return `${base}/${path}`;
  }

  private authHeader(): Record<string, string> {
    if (this.server.username.trim().length === 0) {
      return {};
    }
    const out: Record<string, string> = {
      'Authorization': basicAuth(this.server.username, this.server.password)
    };
    return out;
  }

  private probe: EndpointProbe = async (endpoint: Endpoint): Promise<boolean> => {
    try {
      const payload: RpcPayload = { method: 'session-get' };
      const res: Reply = await postJson(this.rpcUrl(endpoint), JSON.stringify(payload),
        this.authHeader(), TimeoutTier.PROBE);
      return res.code >= 200 && res.code < 500;
    } catch (err) {
      return false;
    }
  };

  /** POST JSON-RPC，自动处理 409 + X-Transmission-Session-Id */
  private async rpc(endpoint: Endpoint, method: string,
    args: Record<string, Object> | null = null): Promise<Record<string, Object>> {
    let attempt: number = 0;
    while (attempt < 3) {
      const payload: RpcPayload = { method: method };
      if (args !== null) {
        payload.arguments = args;
      }
      const headers: Record<string, string> = this.authHeader();
      const sid: string | undefined = this.sessionIds.get(endpoint.hostKey());
      if (sid !== undefined) {
        headers['X-Transmission-Session-Id'] = sid;
      }
      const res: Reply =
        await postJson(this.rpcUrl(endpoint), JSON.stringify(payload), headers);

      if (res.code === 409) {
        const newId: string = res.headers['x-transmission-session-id'] ?? '';
        if (newId.trim().length === 0) {
          throw new ApiException('Transmission 未返回会话 ID');
        }
        this.sessionIds.set(endpoint.hostKey(), newId);
        attempt++;
        continue;
      }
      if (res.code === 401) {
        throw new ApiException('认证失败，请检查用户名密码', 401);
      }
      if (!res.isSuccessful()) {
        throw new ApiException(`RPC 失败 HTTP ${res.code}`, res.code);
      }
      const json: Record<string, Object> | null = parseJsonObject(res.body);
      if (json === null) {
        throw new ApiException('Transmission 返回了无法解析的内容');
      }
      const resultText: string = jStr(json, ['result']);
      if (resultText !== 'success') {
        throw new ApiException(`Transmission 返回错误：${resultText}`);
      }
      const argsObj: Record<string, Object> | null = parseJsonObject(JSON.stringify(json['arguments'] ?? {}));
      if (argsObj !== null) {
        return argsObj;
      }
      return {} as Record<string, Object>;
    }
    throw new ApiException('Transmission 会话协商失败');
  }

  async fetchAll(): Promise<TorrentFetchResult> {
    const endpoint: Endpoint = await EndpointResolver.resolve(this.server, this.probe);
    try {
      return await this.pull(endpoint);
    } catch (e) {
      const err: Error = e as Error;
      EndpointResolver.invalidate(this.server.id);
      const retry: Endpoint = await EndpointResolver.resolve(this.server, this.probe);
      if (retry.hostKey() === endpoint.hostKey()) {
        throw err;
      }
      return await this.pull(retry);
    }
  }

  private async pull(endpoint: Endpoint): Promise<TorrentFetchResult> {
    const torrentsArgs: Record<string, Object> = {} as Record<string, Object>;
    torrentsArgs['fields'] = TORRENT_FIELDS;
    torrentsArgs['format'] = 'objects';
    const torrentsResult: Record<string, Object> =
      await this.rpc(endpoint, 'torrent-get', torrentsArgs);

    const torrentArr: Array<Record<string, Object>> | null =
      parseJsonArray(JSON.stringify(torrentsResult['torrents'] ?? []));
    const rawTorrents: Array<Record<string, Object>> =
      torrentArr !== null ? torrentArr : [];

    let session: Record<string, Object> | null = null;
    try {
      session = await this.rpc(endpoint, 'session-get');
    } catch (err) {
      session = null;
    }
    const freeSpace: number = session !== null
      ? Math.trunc(jNum(session, ['download-dir-free-space', 'downloadDirFreeSpace'], 0)) : 0;
    const version: string = session !== null ? jStr(session, ['version']) : '';
    // 备用限速状态顺手从 session-get 拿（同安卓）；拿不到就标记未知，别当成「已关闭」
    const altSpeed: boolean = session !== null
      ? jBool(session, ['alt-speed-enabled', 'altSpeedEnabled']) : false;
    const altSpeedKnown: boolean = session !== null;

    // 累计流量用 session-stats 的 cumulative-stats（持久化、不清零）
    let cumulative: Record<string, Object> | null = null;
    try {
      const statsResult: Record<string, Object> = await this.rpc(endpoint, 'session-stats');
      const cs: Object | undefined = statsResult['cumulative-stats'];
      if (cs !== undefined && cs !== null && typeof cs === 'object' && !Array.isArray(cs)) {
        cumulative = cs as Record<string, Object>;
      }
    } catch (err) {
      cumulative = null;
    }

    const tasks: TorrentTask[] = [];
    for (const obj of rawTorrents) {
      const errCode: number = Math.trunc(jNum(obj, ['error'], 0));
      const errString: string = jStr(obj, ['errorString', 'error_string']);
      const status: TorrentStatus = this.mapStatus(Math.trunc(jNum(obj, ['status'], 0)), errCode, errString);

      let totalSeeds: number = 0;
      let totalPeers: number = 0;
      const trackerStatsArr: Array<Record<string, Object>> | null =
        parseJsonArray(JSON.stringify(obj['trackerStats'] ?? []));
      let trackerHostRaw: string = '';
      if (trackerStatsArr !== null && trackerStatsArr.length > 0) {
        const t0: Record<string, Object> = trackerStatsArr[0];
        totalSeeds = Math.max(Math.trunc(jNum(t0, ['seederCount'], 0)), 0);
        totalPeers = Math.max(Math.trunc(jNum(t0, ['leecherCount'], 0)), 0);
        trackerHostRaw = jStr(t0, ['host']);
      }
      const seeds: number = Math.trunc(jNum(obj, ['peersSendingToUs'], 0));

      const labels: string[] = [];
      const labelsRaw: Array<Object> | null = jRawArr(obj, 'labels');
      if (labelsRaw !== null) {
        for (const item of labelsRaw) {
          if (typeof item === 'string' && item.length > 0) {
            labels.push(item);
          }
        }
      }

      let progress: number = jNum(obj, ['percentDone'], 0);
      progress = progress < 0 ? 0 : (progress > 1 ? 1 : progress);
      const doneDate: number = jNum(obj, ['doneDate'], 0);

      const t: TorrentTask = new TorrentTask();
      t.hash = jStr(obj, ['hashString']);
      t.serverId = this.server.id;
      t.serverType = ServerType.TRANSMISSION;
      t.name = jStr(obj, ['name']);
      t.progress = progress;
      t.size = Math.trunc(jNum(obj, ['totalSize', 'total_size'], 0));
      t.downloaded = Math.trunc(jNum(obj, ['downloadedEver', 'downloaded_ever'], 0));
      t.uploaded = Math.trunc(jNum(obj, ['uploadedEver', 'uploaded_ever'], 0));
      t.downloadSpeed = Math.trunc(jNum(obj, ['rateDownload', 'rate_download'], 0));
      t.uploadSpeed = Math.trunc(jNum(obj, ['rateUpload', 'rate_upload'], 0));
      t.status = status;
      const eta: number = jNum(obj, ['eta'], 0);
      t.etaSeconds = (eta < 0 || eta >= 8640000) ? -1 : Math.trunc(eta);
      t.ratio = jNum(obj, ['uploadRatio', 'upload_ratio'], 0);
      t.numSeeds = seeds;
      t.totalSeeds = totalSeeds;
      t.numPeers = Math.trunc(jNum(obj, ['peersGettingFromUs'], 0));
      t.totalPeers = totalPeers;
      t.category = '';
      t.tags = labels;
      t.savePath = jStr(obj, ['downloadDir', 'download_dir']);
      t.trackerHost = trackerHostOf(
        trackerHostRaw.startsWith('http') ? trackerHostRaw : `tcp://${trackerHostRaw}`);
      t.addedAt = Math.trunc(jNum(obj, ['addedDate', 'added_date'], 0)) * 1000;
      t.completedAt = doneDate > 0 ? Math.trunc(doneDate) * 1000 : 0;
      t.seedingSeconds = Math.trunc(jNum(obj, ['secondsSeeding', 'seconds_seeding'], 0));
      t.errorMessage = status === TorrentStatus.ERROR ? errString : '';
      t.isSequential = jBool(obj, ['sequentialDownload', 'sequential_download']);
      // 限速：TR 用 Mode=1 表示启用，单位 KB/s，这里统一换成 bytes/s（0 = 不限）
      const dlLimitKb: number = Math.trunc(jNum(obj, ['downloadLimit'], 0));
      const ulLimitKb: number = Math.trunc(jNum(obj, ['uploadLimit'], 0));
      t.downloadLimit = Math.trunc(jNum(obj, ['downloadLimitMode'], 0)) === 1
        ? Math.max(0, dlLimitKb) * 1024 : 0;
      t.uploadLimit = Math.trunc(jNum(obj, ['uploadLimitMode'], 0)) === 1
        ? Math.max(0, ulLimitKb) * 1024 : 0;
      // 分享率：0 = 全局，1 = 无限，2 = 自定义
      const ratioMode: number = Math.trunc(jNum(obj, ['seedRatioMode'], 0));
      if (ratioMode === 1) {
        t.ratioMode = -1;
        t.ratioLimit = 0;
      } else if (ratioMode === 2) {
        const v: number = jNum(obj, ['seedRatioLimit'], 0);
        t.ratioMode = v;
        t.ratioLimit = v;
      } else {
        t.ratioMode = -2;
        t.ratioLimit = 0;
      }
      tasks.push(t);
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
      if (t.status === TorrentStatus.SEEDING) {
        seeding++;
        seedingSize += t.size;
      }
      if (t.status === TorrentStatus.DOWNLOADING || t.status === TorrentStatus.QUEUED) {
        downloading++;
      }
    }

    const cumulativeUp: number =
      cumulative !== null ? Math.trunc(jNum(cumulative, ['uploadedBytes'], 0)) : 0;
    const cumulativeDown: number =
      cumulative !== null ? Math.trunc(jNum(cumulative, ['downloadedBytes'], 0)) : 0;

    const snap: ServerSnapshot = new ServerSnapshot();
    snap.serverId = this.server.id;
    snap.online = true;
    snap.downloadSpeed = sumDl;
    snap.uploadSpeed = sumUl;
    snap.seedingCount = seeding;
    snap.downloadingCount = downloading;
    snap.seedingSize = seedingSize;
    snap.totalUploaded = cumulativeUp > 0 ? cumulativeUp : sumUploaded;
    snap.totalDownloaded = cumulativeDown > 0 ? cumulativeDown : sumDownloaded;
    snap.freeSpace = freeSpace;
    snap.appVersion = version;
    snap.endpointLabel = endpoint.display();
    snap.altSpeedEnabled = altSpeed;
    snap.altSpeedKnown = altSpeedKnown;
    return this.wrap(tasks, snap);
  }

  private wrap(tasks: TorrentTask[], snap: ServerSnapshot): TorrentFetchResult {
    const r: TorrentFetchResult = new TorrentFetchResult();
    r.tasks = tasks;
    r.snapshot = snap;
    return r;
  }

  private mapStatus(status: number, errorCode: number, errorString: string): TorrentStatus {
    if (errorCode !== 0 || errorString.trim().length > 0) {
      return TorrentStatus.ERROR;
    }
    switch (status) {
      case 0:
        return TorrentStatus.PAUSED;
      case 1:
      case 2:
        return TorrentStatus.CHECKING;
      case 3:
      case 5:
        return TorrentStatus.QUEUED;
      case 4:
        return TorrentStatus.DOWNLOADING;
      case 6:
        return TorrentStatus.SEEDING;
      default:
        return TorrentStatus.ERROR;
    }
  }

  pause(hashes: string[]): Promise<void> {
    return this.rpcByHashes('torrent-stop', hashes);
  }

  resume(hashes: string[]): Promise<void> {
    return this.rpcByHashes('torrent-start', hashes);
  }

  recheck(hashes: string[]): Promise<void> {
    return this.rpcByHashes('torrent-verify', hashes);
  }

  reannounce(hashes: string[]): Promise<void> {
    return this.rpcByHashes('torrent-reannounce', hashes);
  }

  async delete(hashes: string[], deleteFiles: boolean): Promise<void> {
    const endpoint: Endpoint = await EndpointResolver.resolve(this.server, this.probe);
    const args: Record<string, Object> = {} as Record<string, Object>;
    args['ids'] = hashes;
    args['delete-local-data'] = deleteFiles;
    await this.rpc(endpoint, 'torrent-remove', args);
  }

  private async rpcByHashes(method: string, hashes: string[]): Promise<void> {
    const endpoint: Endpoint = await EndpointResolver.resolve(this.server, this.probe);
    const args: Record<string, Object> = {} as Record<string, Object>;
    args['ids'] = hashes;
    await this.rpc(endpoint, method, args);
  }

  /** RSS 自动下载用：逐个添加 magnet / http 直链 */
  async addTorrents(urls: string[], savePath: string = '', paused: boolean = false): Promise<void> {
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
    const endpoint: Endpoint = await EndpointResolver.resolve(this.server, this.probe);
    for (const url of targets) {
      const args: Record<string, Object> = {} as Record<string, Object>;
      args['filename'] = url;
      args['paused'] = paused;
      if (savePath.trim().length > 0) {
        args['download-dir'] = savePath;
      }
      await this.rpc(endpoint, 'torrent-add', args);
    }
  }

  // ---------- 单任务编辑 ----------

  private async rpcWithArgs(method: string, args: Record<string, Object>): Promise<void> {
    const endpoint: Endpoint = await EndpointResolver.resolve(this.server, this.probe);
    await this.rpc(endpoint, method, args);
  }

  /** 更改保存位置并移动已有文件（move=true 才是真搬，否则只改记录） */
  setLocation(hashes: string[], location: string): Promise<void> {
    const args: Record<string, Object> = {} as Record<string, Object>;
    args['ids'] = hashes;
    args['location'] = location.trim();
    args['move'] = true;
    return this.rpcWithArgs('torrent-set-location', args);
  }

  /**
   * 重命名：**必须给原路径 path** —— 单文件是文件名，多文件是顶层目录名，
   * 两者都等于种子名，所以调用方直接传 task.name 即可。
   */
  renamePath(hash: string, path: string, name: string): Promise<void> {
    const args: Record<string, Object> = {} as Record<string, Object>;
    args['ids'] = [hash];
    args['path'] = path;
    args['name'] = name.trim();
    return this.rpcWithArgs('torrent-rename-path', args);
  }

  /** 单位 bytes/s，0 = 不限（TR 内部是 KB/s + Enabled 开关） */
  setLimits(hashes: string[], downloadBytes: number, uploadBytes: number): Promise<void> {
    const args: Record<string, Object> = {} as Record<string, Object>;
    args['ids'] = hashes;
    args['downloadLimit'] = Math.trunc(Math.max(0, downloadBytes) / 1024);
    args['downloadLimitEnabled'] = downloadBytes > 0;
    args['uploadLimit'] = Math.trunc(Math.max(0, uploadBytes) / 1024);
    args['uploadLimitEnabled'] = uploadBytes > 0;
    return this.rpcWithArgs('torrent-set', args);
  }

  /** ratioMode：-2 全局 / -1 无限 / >=0 自定义（TR: 0 全局、1 无限、2 自定义） */
  setSeedRatio(hashes: string[], ratioMode: number, ratioLimit: number): Promise<void> {
    const args: Record<string, Object> = {} as Record<string, Object>;
    args['ids'] = hashes;
    if (ratioMode < 0) {
      args['seedRatioMode'] = ratioMode === -1 ? 1 : 0;
      args['seedRatioLimit'] = 0;
    } else {
      args['seedRatioMode'] = 2;
      args['seedRatioLimit'] = ratioLimit;
    }
    return this.rpcWithArgs('torrent-set', args);
  }

  // ---------- Tracker 列表（查看 / 编辑） ----------

  /**
   * 单个任务的 Tracker 列表。
   * tr 没有独立接口，只能从 torrent-get 的 trackerStats 拿；它也没有 qB 那种 status，
   * 只能按「上次汇报是否成功 + 有没有失败文案」推断状态。
   * trackerStats 的 `id` 要留着：改 / 删 Tracker 时 tr 用 id 定位，不用 URL。
   */
  async trackers(hash: string): Promise<TrackerEntry[]> {
    const endpoint: Endpoint = await EndpointResolver.resolve(this.server, this.probe);
    const args: Record<string, Object> = {} as Record<string, Object>;
    args['ids'] = [hash];
    args['fields'] = ['trackerStats'];
    const result: Record<string, Object> = await this.rpc(endpoint, 'torrent-get', args);
    const torrentArr: Array<Record<string, Object>> | null =
      parseJsonArray(JSON.stringify(result['torrents'] ?? []));
    const out: TrackerEntry[] = [];
    if (torrentArr === null || torrentArr.length === 0) {
      return out;
    }
    const stats: Array<Record<string, Object>> | null =
      parseJsonArray(JSON.stringify(torrentArr[0]['trackerStats'] ?? []));
    if (stats === null) {
      return out;
    }
    for (const o of stats) {
      const url: string = jStr(o, ['announce']).trim();
      if (url.length === 0) {
        continue;
      }
      const ok: boolean = jBool(o, ['lastAnnounceSucceeded'], false);
      const message: string = jStr(o, ['lastAnnounceResult']).trim();
      const e: TrackerEntry = new TrackerEntry();
      e.url = url;
      // 2 工作中 / 4 不工作 / 1 未联系（与 qB 的状态码对齐，UI 一套配色）
      e.status = ok ? 2 : (message.length > 0 ? 4 : 1);
      e.tier = Math.trunc(jNum(o, ['tier'], 0));
      e.trackerId = Math.trunc(jNum(o, ['id'], -1));
      e.seeds = Math.trunc(jNum(o, ['seederCount'], 0));
      e.leeches = Math.trunc(jNum(o, ['leecherCount'], 0));
      e.peers = Math.trunc(jNum(o, ['lastAnnouncePeerCount'], 0));
      e.message = ok ? '' : message;
      out.push(e);
    }
    return out;
  }

  /** 改一条 Tracker：tr 用 trackerReplace = [id, 新URL]（两元素数组，不是对象） */
  editTracker(hash: string, trackerId: number, newUrl: string): Promise<void> {
    if (trackerId < 0) {
      throw new ApiException('这条 Tracker 没有 id，无法修改');
    }
    const args: Record<string, Object> = {} as Record<string, Object>;
    args['ids'] = [hash];
    args['trackerReplace'] = [trackerId, newUrl];
    return this.rpcWithArgs('torrent-set', args);
  }

  /** 追加 Tracker：tr 用 trackerAdd = ["url1", …] */
  addTrackers(hash: string, urls: string[]): Promise<void> {
    const targets: string[] = [];
    for (const u of urls) {
      const t: string = u.trim();
      if (t.length > 0) {
        targets.push(t);
      }
    }
    if (targets.length === 0) {
      return Promise.resolve();
    }
    const args: Record<string, Object> = {} as Record<string, Object>;
    args['ids'] = [hash];
    args['trackerAdd'] = targets;
    return this.rpcWithArgs('torrent-set', args);
  }

  /** 删除 Tracker：tr 用 trackerRemove = [id…] */
  removeTrackers(hash: string, trackerIds: number[]): Promise<void> {
    const ids: number[] = [];
    for (const id of trackerIds) {
      if (id >= 0) {
        ids.push(id);
      }
    }
    if (ids.length === 0) {
      return Promise.resolve();
    }
    const args: Record<string, Object> = {} as Record<string, Object>;
    args['ids'] = [hash];
    args['trackerRemove'] = ids;
    return this.rpcWithArgs('torrent-set', args);
  }

  /** 备用限速（alt-speed）总开关 */
  setAltSpeed(enabled: boolean): Promise<void> {
    const args: Record<string, Object> = {} as Record<string, Object>;
    args['alt-speed-enabled'] = enabled;
    return this.rpcWithArgs('session-set', args);
  }

  async altSpeedEnabled(): Promise<boolean> {
    const endpoint: Endpoint = await EndpointResolver.resolve(this.server, this.probe);
    const session: Record<string, Object> = await this.rpc(endpoint, 'session-get');
    return jBool(session, ['alt-speed-enabled', 'altSpeedEnabled']);
  }

  /** 备注：TR 的 RPC **没有**单任务 Cookie 字段，带 Cookie 的 http 直链由 App 先抓 .torrent 再交给它 */

  /** 本地 .torrent 文件：TR 收 base64 的 metainfo，比 qB 的 multipart 省事 */
  async addTorrentFile(base64Metainfo: string, opts: AddTorrentOptions): Promise<void> {
    const args: Record<string, Object> = {} as Record<string, Object>;
    args['metainfo'] = base64Metainfo;
    args['paused'] = opts.paused;
    if (opts.savePath.trim().length > 0) {
      args['download-dir'] = opts.savePath.trim();
    }
    if (opts.rename.trim().length > 0) {
      // 含中文的文件名：TR 5.x 支持 filename 覆盖
      args['filename'] = opts.rename.trim();
    }
    await this.rpcWithArgs('torrent-add', args);
  }
}
