import { util } from '@kit.ArkTS';
import { jStr, jNum, jBool } from '../common/AppConstants';

/**
 * 核心数据模型，1:1 移植安卓 data/Models.kt。
 * 派生属性按 ArkTS 约定写成方法（架构 §8 共享约定）。
 */

export enum ServerType {
  QBITTORRENT,
  TRANSMISSION
}

export function serverTypeLabel(t: ServerType): string {
  return t === ServerType.QBITTORRENT ? 'qBittorrent' : 'Transmission';
}

export function serverTypeShortLabel(t: ServerType): string {
  return t === ServerType.QBITTORRENT ? 'qb' : 'tr';
}

export function serverTypeFromIndex(i: number): ServerType {
  return i === 1 ? ServerType.TRANSMISSION : ServerType.QBITTORRENT;
}

export function newUuid(): string {
  return util.generateRandomUUID(true);
}

export function blankUuid(): string {
  return '00000000-0000-0000-0000-000000000000';
}

/**
 * 同一台服务器可以有多个入口地址，App 会按网络环境自动挑一个能通的。
 */
export class Endpoint {
  host: string = '';
  port: number = 8080;
  https: boolean = false;
  /** 反向代理子路径，例如 /qb */
  basePath: string = '';
  /** 备注：家里内网 / 外网域名 */
  label: string = '';
  enabled: boolean = true;

  constructor(host: string = '', port: number = 8080, https: boolean = false,
    basePath: string = '', label: string = '', enabled: boolean = true) {
    this.host = host;
    this.port = port;
    this.https = https;
    this.basePath = basePath;
    this.label = label;
    this.enabled = enabled;
  }

  /** 端口留空（0）视为「协议默认端口」 */
  isValid(): boolean {
    return this.host.trim().length > 0 && (this.port === 0 || (this.port >= 1 && this.port <= 65535));
  }

  /**
   * 这条地址是不是「局域网地址」。
   *
   * 只做字面判断，不发任何请求：IPv4 私有段 / 回环 / 链路本地、IPv6 唯一本地或链路本地，
   * 以及不带点的主机名（NAS 主机名）、localhost、*.local / *.lan / *.home.arpa。
   * 公网域名（ddns、反代域名）一律算外网。
   *
   * 用途：连上 WiFi/有线时，先只探内网这几条；通了就直接用，不再和公网域名抢谁先响应。
   */
  isLanHost(): boolean {
    const h: string = this.host.trim().toLowerCase();
    if (h.length === 0) {
      return false;
    }
    if (h === 'localhost' || h === '::1') {
      return true;
    }
    // IPv4 字面量
    const v4: string[] = h.split('.');
    if (v4.length === 4 && v4.every((p: string): boolean => /^\d{1,3}$/.test(p))) {
      const a: number = Number.parseInt(v4[0], 10);
      const b: number = Number.parseInt(v4[1], 10);
      if (a === 10 || a === 127) {
        return true;
      }
      if (a === 192 && b === 168) {
        return true;
      }
      if (a === 172 && b >= 16 && b <= 31) {
        return true;
      }
      if (a === 169 && b === 254) {
        return true;
      }
      return false;
    }
    // IPv6 字面量（带不带方括号都算）：链路本地 fe80:: / 唯一本地 fc00::7
    const v6: string = h.startsWith('[') ? h.substring(1, h.indexOf(']')) : h;
    if (v6.indexOf(':') >= 0) {
      return v6.startsWith('fe80') || v6.startsWith('fc') || v6.startsWith('fd');
    }
    // 主机名：没有点的是内网短名（nas / fnos），常见内网后缀也认
    if (h.indexOf('.') < 0) {
      return true;
    }
    return h.endsWith('.local') || h.endsWith('.lan') || h.endsWith('.home.arpa') ||
      h.endsWith('.localdomain');
  }

  effectivePort(): number {
    if (this.port >= 1 && this.port <= 65535) {
      return this.port;
    }
    return this.https ? 443 : 80;
  }

  display(): string {
    let out: string = this.https ? 'https://' : 'http://';
    out += this.host;
    if (this.port >= 1 && this.port <= 65535) {
      const defaultPort: number = this.https ? 443 : 80;
      if (this.port !== defaultPort) {
        out += `:${this.port}`;
      }
    }
    if (this.basePath.trim().length > 0) {
      let p: string = this.basePath;
      while (p.endsWith('/')) {
        p = p.substring(0, p.length - 1);
      }
      out += p;
    }
    return out;
  }

  /** 拼出完整请求地址，path 形如 "api/v2/torrents/info" */
  url(path: string): string {
    let base: string = this.display();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    let p: string = path;
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    return `${base}/${p}`;
  }

  /** 探测/缓存用的唯一键，端口留空时按实际生效端口区分 */
  hostKey(): string {
    return `${this.host.toLowerCase()}:${this.effectivePort()}:${this.https ? 1 : 0}:${this.basePath}`;
  }

  /**
   * 把用户可能整段粘贴的地址拆开：`https://mp.example.com:3000/mp/` →
   * host=mp.example.com、port=3000、https=true、basePath=/mp。
   */
  normalized(): Endpoint {
    let raw: string = this.host.trim();
    const lower: string = raw.toLowerCase();
    let secure: boolean = this.https;
    let path: string = this.basePath.trim();
    let parsedPort: number = this.port;

    if (lower.startsWith('https://')) {
      secure = true;
      raw = raw.substring(8);
    } else if (lower.startsWith('http://')) {
      secure = false;
      raw = raw.substring(7);
    }
    while (raw.endsWith('/')) {
      raw = raw.substring(0, raw.length - 1);
    }

    const slash: number = raw.indexOf('/');
    if (slash >= 0) {
      if (path.length === 0) {
        path = raw.substring(slash);
      }
      raw = raw.substring(0, slash);
    }

    // 只把「最后一个冒号且在 ] 之后」当成端口，避免把 IPv6 拆坏
    const colon: number = raw.lastIndexOf(':');
    if (colon > 0 && raw.indexOf(']') < colon) {
      const maybePort: number = parseInt(raw.substring(colon + 1), 10);
      if (!isNaN(maybePort) && maybePort >= 1 && maybePort <= 65535) {
        parsedPort = maybePort;
        raw = raw.substring(0, colon);
      }
    }

    return new Endpoint(raw.trim(), parsedPort, secure, path.trim(), this.label, this.enabled);
  }
}

export function endpointFromJson(o: Record<string, Object>): Endpoint {
  const ep: Endpoint = new Endpoint(
    jStr(o, ['host']),
    Math.trunc(jNum(o, ['port'], 8080)),
    jBool(o, ['https']),
    jStr(o, ['basePath', 'base_path']),
    jStr(o, ['label']),
    jBool(o, ['enabled'], true)
  );
  return ep.normalized();
}

export enum EndpointMode {
  /** 并发探测，自动选最快的可用地址 */
  AUTO,
  /** 固定使用 pinnedEndpointIndex */
  MANUAL
}

/**
 * 把一个输入框里的多行地址拆成端点列表。
 * 空行和以 # 开头的注释行会被忽略，hostKey 去重。
 */
export function parseEndpoints(text: string): Endpoint[] {
  const out: Endpoint[] = [];
  const seen: Set<string> = new Set<string>();
  const lines: string[] = text.split('\n');
  for (const rawLine of lines) {
    const line: string = rawLine.trim();
    if (line.length === 0 || line.startsWith('#')) {
      continue;
    }
    const ep: Endpoint = new Endpoint(line, 0).normalized();
    if (!ep.isValid()) {
      continue;
    }
    const key: string = ep.hostKey();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    out.push(ep);
  }
  return out;
}

/** 设置页右侧那行摘要：第一条地址 + 还有几条 */
export function summarizeEndpoints(text: string): string {
  const list: Endpoint[] = parseEndpoints(text);
  if (list.length === 0) {
    return '未配置';
  }
  const firstDisplay: string = list[0].display();
  const proto: number = firstDisplay.indexOf('://');
  const first: string = proto >= 0 ? firstDisplay.substring(proto + 3) : firstDisplay;
  if (list.length <= 1) {
    return first;
  }
  return `${first} +${list.length - 1}`;
}

export class ServerConfig {
  id: string = newUuid();
  name: string = '';
  type: ServerType = ServerType.QBITTORRENT;
  endpoints: Endpoint[] = [];
  username: string = '';
  password: string = '';
  /** qBittorrent 5.2+ 的 API Key，走 Bearer 认证，不需要用户名 */
  apiKey: string = '';
  useApiKey: boolean = false;
  rpcPath: string = '/transmission/rpc';
  endpointMode: EndpointMode = EndpointMode.AUTO;
  pinnedEndpointIndex: number = 0;
  hidden: boolean = false;

  displayName(): string {
    return this.name.trim().length > 0 ? this.name : serverTypeLabel(this.type);
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
}

export function serverConfigFromJson(o: Record<string, Object>): ServerConfig {
  const sc: ServerConfig = new ServerConfig();
  sc.id = jStr(o, ['id'], newUuid());
  sc.name = jStr(o, ['name']);
  sc.type = serverTypeFromIndex(Math.trunc(jNum(o, ['type'], 0)));
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
  sc.endpoints = eps;
  sc.username = jStr(o, ['username']);
  sc.password = jStr(o, ['password']);
  sc.apiKey = jStr(o, ['apiKey', 'api_key']);
  sc.useApiKey = jBool(o, ['useApiKey', 'use_api_key']);
  sc.rpcPath = jStr(o, ['rpcPath', 'rpc_path'], '/transmission/rpc');
  sc.endpointMode = Math.trunc(jNum(o, ['endpointMode', 'endpoint_mode'], 0)) === 1
    ? EndpointMode.MANUAL : EndpointMode.AUTO;
  sc.pinnedEndpointIndex = Math.trunc(jNum(o, ['pinnedEndpointIndex', 'pinned_endpoint_index'], 0));
  sc.hidden = jBool(o, ['hidden']);
  return sc;
}

export enum TorrentStatus {
  DOWNLOADING,
  QUEUED,
  SEEDING,
  PAUSED,
  CHECKING,
  ERROR,
  COMPLETED
}

export function torrentStatusLabel(s: TorrentStatus): string {
  switch (s) {
    case TorrentStatus.DOWNLOADING:
      return '下载中';
    case TorrentStatus.QUEUED:
      return '排队中';
    case TorrentStatus.SEEDING:
      return '做种中';
    case TorrentStatus.PAUSED:
      return '已暂停';
    case TorrentStatus.CHECKING:
      return '校验中';
    case TorrentStatus.ERROR:
      return '错误';
    case TorrentStatus.COMPLETED:
      return '已完成';
    default:
      return '未知';
  }
}

/** 中国习惯：做种/完成用绿色，下载用蓝色，错误红色 */
export function torrentStatusAccent(s: TorrentStatus): number {
  switch (s) {
    case TorrentStatus.DOWNLOADING:
      return 0xFF0A84FF;
    case TorrentStatus.QUEUED:
      return 0xFF5E5CE6;
    case TorrentStatus.SEEDING:
      return 0xFF34C759;
    case TorrentStatus.PAUSED:
      return 0xFF8E8E93;
    case TorrentStatus.CHECKING:
      return 0xFFFF9500;
    case TorrentStatus.ERROR:
      return 0xFFFF3B30;
    case TorrentStatus.COMPLETED:
      return 0xFF8E8E93;
    default:
      return 0xFF8E8E93;
  }
}

/** 任务数据形状（JSON 层），TorrentTask 提供派生方法 */
export class TorrentTaskData {
  hash: string = '';
  serverId: string = '';
  serverType: ServerType = ServerType.QBITTORRENT;
  name: string = '';
  progress: number = 0;
  size: number = 0;
  downloaded: number = 0;
  uploaded: number = 0;
  downloadSpeed: number = 0;
  uploadSpeed: number = 0;
  status: TorrentStatus = TorrentStatus.PAUSED;
  etaSeconds: number = 0;
  ratio: number = 0;
  numSeeds: number = 0;
  totalSeeds: number = 0;
  numPeers: number = 0;
  totalPeers: number = 0;
  category: string = '';
  tags: string[] = [];
  savePath: string = '';
  trackerHost: string = '';
  addedAt: number = 0;
  completedAt: number = 0;
  seedingSeconds: number = 0;
  errorMessage: string = '';
  isSequential: boolean = false;
  availability: number = 0;
  /** 单任务限速（统一 bytes/s，0 = 不限） */
  downloadLimit: number = 0;
  uploadLimit: number = 0;
  /** 分享率策略：-2 = 跟随全局，-1 = 无限，>=0 = 自定义比值 */
  ratioMode: number = -2;
  ratioLimit: number = 0;
}

/**
 * 一条 Tracker（qBittorrent / Transmission 归一化后，对应安卓 data/TrackerEntry.kt）。
 *
 * 两家字段完全不同：qB 直接给 status(0~4) / tier / num_*；tr 只有 trackerStats 的
 * lastAnnounceSucceeded + lastAnnounceResult，状态只能推断。这里统一成 5 档。
 */
export class TrackerEntry {
  url: string = '';
  /** 0 已停用 / 1 未联系 / 2 工作中 / 3 更新中 / 4 不工作 / -1 未知 */
  status: number = -1;
  tier: number = 0;
  /** TR 的 tracker id（改 / 删用它定位），qB 恒为 -1 */
  trackerId: number = -1;
  seeds: number = 0;
  leeches: number = 0;
  peers: number = 0;
  message: string = '';

  /** qB 会回 DHT / PEX / LSD 三条伪 Tracker（URL 形如 «** [DHT] **»），不能编辑 */
  special(): boolean {
    return this.url.startsWith('**');
  }

  /** tracker 地址只留域名（与 Format.trackerHostOf 同逻辑；这里不复用是为了避开循环依赖） */
  host(): string {
    if (this.url.trim().length === 0) {
      return '';
    }
    let s: string = this.url;
    const proto: number = s.indexOf('://');
    s = proto >= 0 ? s.substring(proto + 3) : s;
    const slash: number = s.indexOf('/');
    s = slash >= 0 ? s.substring(0, slash) : s;
    const q: number = s.indexOf('?');
    s = q >= 0 ? s.substring(0, q) : s;
    const at: number = s.lastIndexOf('@');
    s = at >= 0 ? s.substring(at + 1) : s;
    return s;
  }

  statusText(): string {
    switch (this.status) {
      case 0:
        return '已停用';
      case 1:
        return '未联系';
      case 2:
        return '工作中';
      case 3:
        return '更新中';
      case 4:
        return '不工作';
      default:
        return '未知';
    }
  }
}

export class TorrentTask extends TorrentTaskData {
  id(): string {
    return `${this.serverId}:${this.hash}`;
  }

  isFinished(): boolean {
    return this.progress >= 0.9999;
  }

  /** 卡片上最多展示 2 个分类/标签 */
  taxonomyTags(): string[] {
    const out: string[] = [];
    if (this.serverType === ServerType.QBITTORRENT && this.category.trim().length > 0) {
      out.push(this.category);
      if (this.tags.length > 0) {
        out.push(this.tags[0]);
      }
    } else {
      for (let i = 0; i < this.tags.length && out.length < 2; i++) {
        out.push(this.tags[i]);
      }
    }
    return out;
  }

  hiddenTaxonomyCount(): number {
    const categoryCount: number =
      (this.serverType === ServerType.QBITTORRENT && this.category.trim().length > 0) ? 1 : 0;
    const hidden: number = categoryCount + this.tags.length - 2;
    return hidden > 0 ? hidden : 0;
  }

  accentColor(): number {
    return torrentStatusAccent(this.status);
  }
}

/** 单台服务器的汇总数据 */
export class ServerSnapshot {
  serverId: string = '';
  online: boolean = false;
  error: string = '';
  downloadSpeed: number = 0;
  uploadSpeed: number = 0;
  seedingCount: number = 0;
  downloadingCount: number = 0;
  seedingSize: number = 0;
  totalUploaded: number = 0;
  totalDownloaded: number = 0;
  freeSpace: number = 0;
  appVersion: string = '';
  endpointLabel: string = '';
  /** 备用限速（alt-speed）是否开启：下载器页顶栏仪表图标靠它着色，刷新即校正（同安卓） */
  altSpeedEnabled: boolean = false;
  /**
   * 本次快照是否**真的读到**了备用限速状态。
   * 读不到（超时 / 接口报错 / 反代抖动）时绝不能当成「已关闭」——否则一次失败的请求
   * 就会把顶栏图标刷成常规色，下一轮又变回橙色，表现就是「颜色经常不对」。
   * 只有 true 的快照才有资格纠正 UI 上的颜色。
   */
  altSpeedKnown: boolean = false;

  ratio(): number {
    if (this.totalDownloaded > 0) {
      return this.totalUploaded / this.totalDownloaded;
    }
    return 0;
  }
}

/** 一次拉回「任务列表 + 服务器状态」的结果（替代安卓 Pair） */
export class TorrentFetchResult {
  tasks: TorrentTask[] = [];
  snapshot: ServerSnapshot = new ServerSnapshot();
}

/** 新增下载的可选参数（qB 与 TR 取交集，各自忽略不支持的字段） */
export class AddTorrentOptions {
  savePath: string = '';
  /** qB 分类 */
  category: string = '';
  /** qB 重命名 */
  rename: string = '';
  paused: boolean = false;
  /** qB 自动种子管理 */
  autoTMM: boolean = false;
  /** qB 跳过哈希校验 */
  skipChecking: boolean = false;
}
