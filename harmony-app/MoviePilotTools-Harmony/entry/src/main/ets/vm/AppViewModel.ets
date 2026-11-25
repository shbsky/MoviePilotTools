import { util } from '@kit.ArkTS';
import { AppEnv, logInfo, logWarn, jNum } from '../common/AppConstants';
import { ConfigStore } from '../data/ConfigStore';
import { TrafficLedger } from '../data/TrafficLedger';
import { ServerConfig, ServerSnapshot, ServerType, TorrentStatus,
  TorrentTask, TrackerEntry } from '../model/Models';
import { AppSettings, PersistedState } from '../model/Settings';
import { QBittorrentClient } from '../net/QBittorrentClient';
import { TransmissionClient } from '../net/TransmissionClient';
import { EndpointResolver } from '../net/EndpointResolver';
import { TorrentFetchResult, AddTorrentOptions } from '../model/Models';
import { getBinary } from '../net/HttpClient';
import { ObservableStore, ToastHub } from './StoreBase';

/**
 * 下载器域 VM（对应安卓 vm/AppViewModel.kt）：
 * 服务器 CRUD、端点探测、轮询刷新（可配间隔）、ServerSnapshot 汇总、
 * 任务列表状态、任务六操作、设置项写入。纯 TS 单例，与页面生命周期解耦。
 */

export class AppState {
  servers: ServerConfig[] = [];
  activeServerId: string | null = null;
  settings: AppSettings = new AppSettings();
  tasks: TorrentTask[] = [];
  snapshots: Map<string, ServerSnapshot> = new Map<string, ServerSnapshot>();
  isRefreshing: boolean = false;
  lastRefreshAt: number = 0;
  /**
   * 这批数据是「什么时候开始抓的」。用来判断一份快照是新是旧：
   * 用户在刷新途中点了开关，这一轮抓回来的还是点击前的状态，不能拿它否定用户的点击。
   */
  lastRefreshStartedAt: number = 0;
  /** 上次新增下载用的保存位置（下次进新增页默认带出） */
  lastSavePath: string = '';

  activeTasks(): TorrentTask[] {
    if (this.activeServerId === null) {
      return this.tasks;
    }
    const out: TorrentTask[] = [];
    for (const t of this.tasks) {
      if (t.serverId === this.activeServerId) {
        out.push(t);
      }
    }
    return out;
  }

  visibleSnapshots(): ServerSnapshot[] {
    if (this.activeServerId === null) {
      const out: ServerSnapshot[] = [];
      this.snapshots.forEach((v: ServerSnapshot): void => {
        out.push(v);
      });
      return out;
    }
    const one: ServerSnapshot | undefined = this.snapshots.get(this.activeServerId);
    if (one === undefined) {
      return [];
    }
    return [one];
  }

  snapshotOf(serverId: string): ServerSnapshot | null {
    const s: ServerSnapshot | undefined = this.snapshots.get(serverId);
    return s === undefined ? null : s;
  }

  serverById(id: string): ServerConfig | null {
    for (const s of this.servers) {
      if (s.id === id) {
        return s;
      }
    }
    return null;
  }

  private onlineVisible(): ServerSnapshot[] {
    const out: ServerSnapshot[] = [];
    for (const s of this.visibleSnapshots()) {
      if (s.online) {
        out.push(s);
      }
    }
    return out;
  }

  totalSeeding(): number {
    let n: number = 0;
    for (const s of this.onlineVisible()) {
      n += s.seedingCount;
    }
    return n;
  }

  totalDownloading(): number {
    let n: number = 0;
    for (const s of this.onlineVisible()) {
      n += s.downloadingCount;
    }
    return n;
  }

  totalBandwidth(): number {
    let n: number = 0;
    for (const s of this.onlineVisible()) {
      n += s.downloadSpeed + s.uploadSpeed;
    }
    return n;
  }

  /** 全站下载速率（MP 仪表盘拿不到数据时，仪表盘实时速率卡用它兜底） */
  totalDownloadSpeed(): number {
    let n: number = 0;
    for (const s of this.onlineVisible()) {
      n += s.downloadSpeed;
    }
    return n;
  }

  totalUploadSpeed(): number {
    let n: number = 0;
    for (const s of this.onlineVisible()) {
      n += s.uploadSpeed;
    }
    return n;
  }

  /**
   * 任务列表累计量之和（最后一级兜底）。
   *
   * 快照里的 totalDownloaded/totalUploaded 依赖 qB 的 `sync/maindata → server_state.alltime_dl`
   * 或 TR 的 `session-stats.cumulative-stats`；这两个请求失败/被反代缓存时快照就是 0，
   * 但 `torrents/info` 本来就是同一个响应里读的，任务一定在。所以再加一层「按任务求和」，
   * 保证只要任务列表有数，卡片就不会是 0 B。
   * 口径说明：这是「当前列表内任务的累计」，删种会变小，仅用于展示，不参与流量基线。
   */
  sumTaskDownloaded(): number {
    let n: number = 0;
    for (const t of this.activeTasks()) {
      n += t.downloaded;
    }
    return n;
  }

  sumTaskUploaded(): number {
    let n: number = 0;
    for (const t of this.activeTasks()) {
      n += t.uploaded;
    }
    return n;
  }

  /** 各下载器累计下载量之和（口径与 MP 的 downloader.download_size 一致：不加去重） */
  totalDownloaded(): number {
    let n: number = 0;
    for (const s of this.onlineVisible()) {
      n += s.totalDownloaded;
    }
    return n;
  }

  totalUploaded(): number {
    let n: number = 0;
    for (const s of this.onlineVisible()) {
      n += s.totalUploaded;
    }
    return n;
  }

  totalFreeSpace(): number {
    // 按物理主机去重（BUG-5）：qB 与 TR 常部署在同一台 NAS 的同一块磁盘上，
    // 直接累加所有在线服务器的 freeSpace 会导致总剩余空间翻倍失真
    // （安卓 DashboardScreen.kt 为同逻辑，安卓版不动）。
    // 以服务器首个入口的 host（ip/域名即机器身份，端口无关）分组，
    // 每组取在线服务器 freeSpace 的最大值代表该机磁盘剩余，再跨主机求和。
    // 离线服务器本就不参与（onlineVisible），同主机多实例时自动取在线者。
    // host 为空或取不到配置时退回按 serverId 分组（等效单服务器，行为不变）。
    const perHost: Map<string, number> = new Map<string, number>();
    for (const s of this.onlineVisible()) {
      const server: ServerConfig | null = this.serverById(s.serverId);
      const host: string = (server !== null && server.endpoints.length > 0)
        ? server.endpoints[0].host.trim().toLowerCase()
        : '';
      const key: string = host.length > 0 ? host : `server:${s.serverId}`;
      const cur: number | undefined = perHost.get(key);
      if (cur === undefined || s.freeSpace > cur) {
        perHost.set(key, s.freeSpace);
      }
    }
    let n: number = 0;
    perHost.forEach((v: number): void => {
      n += v;
    });
    return n;
  }

  downloadSpeed(): number {
    let n: number = 0;
    for (const t of this.activeTasks()) {
      n += t.downloadSpeed;
    }
    return n;
  }

  uploadSpeed(): number {
    let n: number = 0;
    for (const t of this.activeTasks()) {
      n += t.uploadSpeed;
    }
    return n;
  }

  onlineCount(): number {
    let n: number = 0;
    this.snapshots.forEach((v: ServerSnapshot): void => {
      if (v.online) {
        n++;
      }
    });
    return n;
  }

  hasAnyConfigured(): boolean {
    return this.servers.length > 0;
  }
}

export enum TorrentAction {
  PAUSE,
  RESUME,
  RECHECK,
  REANNOUNCE,
  DELETE,
  DELETE_WITH_FILES,
  /** qB 独有：强制继续（跳过排队） */
  FORCE_RESUME,
  /** qB 独有：自动种子管理 */
  AUTO_MANAGEMENT_ON,
  /** qB 独有：超级种子模式 */
  SUPER_SEEDING_ON,
  /** 更改保存位置（需要附带目标路径） */
  CHANGE_LOCATION
}

export function torrentActionSuccessText(a: TorrentAction): string {
  switch (a) {
    case TorrentAction.PAUSE:
      return '已暂停';
    case TorrentAction.RESUME:
      return '已继续';
    case TorrentAction.RECHECK:
      return '已开始校验';
    case TorrentAction.REANNOUNCE:
      return '已重新汇报';
    case TorrentAction.DELETE:
      return '已删除任务';
    case TorrentAction.DELETE_WITH_FILES:
      return '已删除任务和文件';
    case TorrentAction.FORCE_RESUME:
      return '已强制继续';
    case TorrentAction.AUTO_MANAGEMENT_ON:
      return '已开启自动种子管理';
    case TorrentAction.SUPER_SEEDING_ON:
      return '已开启超级种子模式';
    case TorrentAction.CHANGE_LOCATION:
      return '已更改保存位置';
    default:
      return '操作完成';
  }
}

/**
 * 状态筛选（与安卓 StatusFilter 逐项对齐）。
 * ACTIVE / CHECKING 追加在末尾，避免改变既有枚举数值（有持久化/传参风险）。
 */
export enum StatusFilter {
  ALL,
  DOWNLOADING,
  SEEDING,
  COMPLETED,
  PAUSED,
  ERROR,
  ACTIVE,
  CHECKING
}

export function statusFilterLabel(f: StatusFilter): string {
  switch (f) {
    case StatusFilter.ALL:
      return '全部';
    case StatusFilter.DOWNLOADING:
      return '下载';
    case StatusFilter.PAUSED:
      return '暂停';
    case StatusFilter.SEEDING:
      return '做种';
    case StatusFilter.ACTIVE:
      return '活动';
    case StatusFilter.COMPLETED:
      return '完成';
    case StatusFilter.CHECKING:
      return '检查';
    case StatusFilter.ERROR:
      return '错误';
    default:
      return '全部';
  }
}

export function matchesStatusFilter(task: TorrentTask, filter: StatusFilter): boolean {
  switch (filter) {
    case StatusFilter.ALL:
      return true;
    case StatusFilter.DOWNLOADING:
      return task.status === TorrentStatus.DOWNLOADING || task.status === TorrentStatus.QUEUED;
    case StatusFilter.PAUSED:
      return task.status === TorrentStatus.PAUSED;
    case StatusFilter.SEEDING:
      return task.status === TorrentStatus.SEEDING;
    // 「活动」不是一种状态，而是**此刻真的有上传或下载 byte 在跑**（口径同安卓）
    case StatusFilter.ACTIVE:
      return task.downloadSpeed > 0 || task.uploadSpeed > 0;
    case StatusFilter.COMPLETED:
      return task.isFinished() && task.status !== TorrentStatus.SEEDING;
    case StatusFilter.CHECKING:
      return task.status === TorrentStatus.CHECKING;
    case StatusFilter.ERROR:
      return task.status === TorrentStatus.ERROR;
    default:
      return true;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

export class AppViewModel extends ObservableStore {
  private static inst: AppViewModel | null = null;

  static getInstance(): AppViewModel {
    if (AppViewModel.inst === null) {
      AppViewModel.inst = new AppViewModel();
    }
    return AppViewModel.inst;
  }

  private store: ConfigStore = ConfigStore.getInstance();
  state: AppState = new AppState();

  private loopGen: number = 0;
  private bootstrapped: boolean = false;
  private refreshing: boolean = false;

  private constructor() {
    super();
  }

  /** EntryAbility 加载页面后调用：读配置、起轮询 */
  async bootstrap(): Promise<void> {
    if (this.bootstrapped) {
      return;
    }
    this.bootstrapped = true;
    // 网络一切换（进出 WiFi）就清掉选路缓存，下次请求按新网络重新选内网/公网
    EndpointResolver.installNetworkWatcher();
    try {
      const persisted: PersistedState = this.store.load();
      const s: AppState = new AppState();
      s.servers = persisted.servers;
      s.activeServerId = persisted.activeServerId;
      s.settings = persisted.settings;
      this.state = s;
      this.notify();
      if (persisted.servers.length > 0) {
        this.startAutoRefresh();
      }
      logInfo('AppVM', `配置载入完成：${persisted.servers.length} 台下载器`);
    } catch (err) {
      logWarn('AppVM', `配置载入失败: ${err}`);
    }
  }

  // ---------- 配置 ----------

  upsertServer(config: ServerConfig): void {
    const s: AppState = this.state;
    const servers: ServerConfig[] = [];
    let replaced: boolean = false;
    for (const old of s.servers) {
      if (old.id === config.id) {
        servers.push(config);
        replaced = true;
      } else {
        servers.push(old);
      }
    }
    if (!replaced) {
      servers.push(config);
    }
    this.commit(servers, s.activeServerId, s.settings);
    EndpointResolver.invalidate(config.id);
    this.refreshNow();
  }

  deleteServer(id: string): void {
    const s: AppState = this.state;
    const servers: ServerConfig[] = [];
    for (const old of s.servers) {
      if (old.id !== id) {
        servers.push(old);
      }
    }
    const active: string | null = s.activeServerId !== null && s.activeServerId !== id
      ? s.activeServerId : null;
    this.commit(servers, active, s.settings);
    EndpointResolver.invalidate(id);
  }

  selectServer(id: string | null): void {
    const s: AppState = this.state;
    this.commit(s.servers, id, s.settings);
  }

  updateSettings(settings: AppSettings): void {
    const s: AppState = this.state;
    this.commit(s.servers, s.activeServerId, settings);
    this.restartAutoRefreshIfNeeded();
  }

  resetAll(): void {
    this.stopAutoRefresh();
    this.store.save(new PersistedState());
    this.state = new AppState();
    this.notify();
  }

  /** 从备份恢复后重建内存状态：配置已写盘，这里只读回来并重启轮询 */
  reloadFromStore(): void {
    this.stopAutoRefresh();
    const loaded: PersistedState = this.store.load();
    const s: AppState = new AppState();
    s.servers = loaded.servers;
    s.activeServerId = loaded.activeServerId;
    s.settings = loaded.settings;
    this.state = s;
    this.notify();
    if (s.servers.length > 0) {
      this.startAutoRefresh();
    }
  }

  private commit(servers: ServerConfig[], activeServerId: string | null,
    settings: AppSettings): void {
    // 以盘上最新整包为底，只改自己负责的三个字段。
    // 原来 new PersistedState() 再逐字段拷，既漏了 heroCache，
    // 也会在多 VM 并发保存时用旧快照抹掉别的模块刚写进去的配置。
    const persisted: PersistedState = this.store.load();
    persisted.servers = servers;
    persisted.activeServerId = activeServerId;
    persisted.settings = settings;
    this.store.save(persisted);

    const s: AppState = new AppState();
    s.servers = servers;
    s.activeServerId = activeServerId;
    s.settings = settings;
    s.tasks = this.state.tasks;
    s.snapshots = this.state.snapshots;
    s.isRefreshing = this.state.isRefreshing;
    s.lastRefreshAt = this.state.lastRefreshAt;
    s.lastRefreshStartedAt = this.state.lastRefreshStartedAt;
    s.lastSavePath = this.state.lastSavePath;
    this.state = s;
    this.notify();
  }

  // ---------- 刷新 ----------

  startAutoRefresh(): void {
    this.loopGen++;
    const gen: number = this.loopGen;
    this.autoRefreshLoop(gen);
  }

  private async autoRefreshLoop(gen: number): Promise<void> {
    await this.refresh(true);
    while (gen === this.loopGen && AppEnv.hasContext()) {
      const seconds: number = Math.min(Math.max(this.state.settings.refreshSeconds, 2), 120);
      await sleep(seconds * 1000);
      if (gen !== this.loopGen) {
        return;
      }
      await this.refresh(false);
    }
  }

  private restartAutoRefreshIfNeeded(): void {
    this.startAutoRefresh();
  }

  stopAutoRefresh(): void {
    this.loopGen++;
  }

  /** 前后台切换：后台暂停轮询，回前台立即刷一次并恢复 */
  onForeground(): void {
    logInfo('AppVM', '进入前台，恢复轮询');
    this.startAutoRefresh();
  }

  onBackground(): void {
    logInfo('AppVM', '退到后台，暂停轮询');
    this.stopAutoRefresh();
    // 后台不再轮询，把账本最后一段增量立刻落盘，避免被系统回收时丢掉
    TrafficLedger.getInstance().flush(Date.now());
  }

  refreshNow(): void {
    this.refresh(true);
  }

  private async refresh(showSpinner: boolean): Promise<void> {
    if (this.state.servers.length === 0 || this.refreshing) {
      return;
    }
    this.refreshing = true;
    // 这批数据的抓取起点：用于判断快照是否已经包含「刚刚那次点击」之后的状态
    const startedAt: number = Date.now();
    try {
      if (showSpinner) {
        const pre: AppState = this.cloneState();
        pre.isRefreshing = true;
        this.state = pre;
        this.notify();
      }

      const servers: ServerConfig[] = this.state.servers;
      const tasksCollector: TorrentTask[] = [];
      const snapshotCollector: Map<string, ServerSnapshot> = new Map<string, ServerSnapshot>();

      const jobs: Promise<void>[] = [];
      for (const server of servers) {
        jobs.push(this.fetchServerInto(server, tasksCollector, snapshotCollector));
      }
      await Promise.all(jobs);

      const orderMap: Map<string, number> = new Map<string, number>();
      for (let i = 0; i < servers.length; i++) {
        orderMap.set(servers[i].id, i);
      }
      tasksCollector.sort((a: TorrentTask, b: TorrentTask): number => {
        const ao: number = orderMap.get(a.serverId) ?? 0;
        const bo: number = orderMap.get(b.serverId) ?? 0;
        if (ao !== bo) {
          return ao - bo;
        }
        return b.addedAt - a.addedAt;
      });

      // 流量账本：把这一轮各服务器的累计计数器记下来，算今日 / 本月增量
      // （必须在 notify 之前，仪表盘重绘时读到的是刚更新完的数）
      TrafficLedger.getInstance().record(snapshotCollector, Date.now());

      const s: AppState = this.cloneState();
      s.tasks = tasksCollector;
      s.snapshots = snapshotCollector;
      s.isRefreshing = false;
      s.lastRefreshAt = Date.now();
      s.lastRefreshStartedAt = startedAt;
      this.state = s;
      this.notify();
    } finally {
      this.refreshing = false;
    }
  }

  private cloneState(): AppState {
    const s: AppState = new AppState();
    s.servers = this.state.servers;
    s.activeServerId = this.state.activeServerId;
    s.settings = this.state.settings;
    s.tasks = this.state.tasks;
    s.snapshots = this.state.snapshots;
    s.isRefreshing = this.state.isRefreshing;
    s.lastRefreshAt = this.state.lastRefreshAt;
    s.lastRefreshStartedAt = this.state.lastRefreshStartedAt;
    s.lastSavePath = this.state.lastSavePath;
    return s;
  }

  private async fetchServerInto(server: ServerConfig, tasksCollector: TorrentTask[],
    snapshotCollector: Map<string, ServerSnapshot>): Promise<void> {
    try {
      const result: TorrentFetchResult = await this.fetchServer(server);
      for (const t of result.tasks) {
        tasksCollector.push(t);
      }
      // 这轮没读到备用限速状态时，沿用上一轮的显示值（仍标记为未知，UI 不会拿它纠正颜色），
      // 避免「那次请求刚好超时」让图标闪一下。离线快照同理。
      if (!result.snapshot.altSpeedKnown) {
        const prev: ServerSnapshot | undefined = this.state.snapshots.get(server.id);
        if (prev !== undefined && prev.online) {
          result.snapshot.altSpeedEnabled = prev.altSpeedEnabled;
        }
      }
      snapshotCollector.set(server.id, result.snapshot);
    } catch (err) {
      logWarn('AppVM', `${server.displayName()} 刷新失败: ${err}`);
      const offline: ServerSnapshot = new ServerSnapshot();
      offline.serverId = server.id;
      offline.online = false;
      offline.error = err instanceof Error && err.message.length > 0 ? err.message : '连接失败';
      const prevOff: ServerSnapshot | undefined = this.state.snapshots.get(server.id);
      if (prevOff !== undefined) {
        // 断线时保留上一次读到的限速状态，恢复连接时颜色不用来回跳
        offline.altSpeedEnabled = prevOff.altSpeedEnabled;
      }
      snapshotCollector.set(server.id, offline);
    }
  }

  private async fetchServer(server: ServerConfig): Promise<TorrentFetchResult> {
    if (server.type === ServerType.QBITTORRENT) {
      return await new QBittorrentClient(server).fetchAll();
    }
    return await new TransmissionClient(server).fetchAll();
  }

  // ---------- 操作 ----------

  async performAction(task: TorrentTask, action: TorrentAction): Promise<void> {
    const server: ServerConfig | null = this.state.serverById(task.serverId);
    if (server === null) {
      return;
    }
    const hashes: string[] = [task.hash];
    try {
      if (server.type === ServerType.QBITTORRENT) {
        const client: QBittorrentClient = new QBittorrentClient(server);
        if (action === TorrentAction.PAUSE) {
          await client.pause(hashes);
        } else if (action === TorrentAction.RESUME) {
          await client.resume(hashes);
        } else if (action === TorrentAction.RECHECK) {
          await client.recheck(hashes);
        } else if (action === TorrentAction.REANNOUNCE) {
          await client.reannounce(hashes);
        } else if (action === TorrentAction.DELETE || action === TorrentAction.DELETE_WITH_FILES) {
          await client.delete(hashes, action === TorrentAction.DELETE_WITH_FILES);
        }
      } else {
        const client: TransmissionClient = new TransmissionClient(server);
        if (action === TorrentAction.PAUSE) {
          await client.pause(hashes);
        } else if (action === TorrentAction.RESUME) {
          await client.resume(hashes);
        } else if (action === TorrentAction.RECHECK) {
          await client.recheck(hashes);
        } else if (action === TorrentAction.REANNOUNCE) {
          await client.reannounce(hashes);
        } else if (action === TorrentAction.DELETE || action === TorrentAction.DELETE_WITH_FILES) {
          await client.delete(hashes, action === TorrentAction.DELETE_WITH_FILES);
        }
      }
      ToastHub.getInstance().show(torrentActionSuccessText(action));
      await sleep(400);
      await this.refresh(false);
    } catch (err) {
      const msg: string = err instanceof Error && err.message.length > 0 ? err.message : '操作失败';
      ToastHub.getInstance().show(msg);
    }
  }

  /** 测试连接：成功返回描述文案，失败抛异常 */
  async testConnection(config: ServerConfig): Promise<string> {
    const result: TorrentFetchResult = await this.fetchServer(config);
    return `连接成功，共 ${result.tasks.length} 个任务`;
  }

  // ---------- 单任务 / 批量编辑（对齐安卓 下载器页） ----------

  /** 客户端按服务器缓存：qB 的登录态存在实例里，每次 new 一个会多一次 login 往返 */
  private qbClients: Map<string, QBittorrentClient> = new Map();
  private trClients: Map<string, TransmissionClient> = new Map();

  private qbOf(serverId: string): QBittorrentClient {
    const hit: QBittorrentClient | undefined = this.qbClients.get(serverId);
    if (hit !== undefined) {
      return hit;
    }
    const server: ServerConfig | null = this.state.serverById(serverId);
    if (server === null) {
      throw new Error('服务器不存在');
    }
    const client: QBittorrentClient = new QBittorrentClient(server);
    this.qbClients.set(serverId, client);
    return client;
  }

  private trOf(serverId: string): TransmissionClient {
    const hit: TransmissionClient | undefined = this.trClients.get(serverId);
    if (hit !== undefined) {
      return hit;
    }
    const server: ServerConfig | null = this.state.serverById(serverId);
    if (server === null) {
      throw new Error('服务器不存在');
    }
    const client: TransmissionClient = new TransmissionClient(server);
    this.trClients.set(serverId, client);
    return client;
  }

  private dropClient(serverId: string): void {
    this.qbClients.delete(serverId);
    this.trClients.delete(serverId);
  }

  isQb(task: TorrentTask): boolean {
    return task.serverType === ServerType.QBITTORRENT;
  }

  async renameTask(task: TorrentTask, newName: string): Promise<void> {
    const name: string = newName.trim();
    if (name.length === 0) {
      throw new Error('名称不能为空');
    }
    if (task.serverType === ServerType.QBITTORRENT) {
      await this.qbOf(task.serverId).rename(task.hash, task.name, name);
    } else {
      // TR 的 path 必须是「原路径」：单文件=文件名、多文件=顶层目录名，两者都等于种子名
      await this.trOf(task.serverId).renamePath(task.hash, task.name, name);
    }
    await this.afterEdit('已重命名');
  }

  async setTaskLocation(task: TorrentTask, path: string): Promise<void> {
    const target: string = path.trim();
    if (target.length === 0) {
      throw new Error('保存位置不能为空');
    }
    if (task.serverType === ServerType.QBITTORRENT) {
      await this.qbOf(task.serverId).setLocation([task.hash], target);
    } else {
      await this.trOf(task.serverId).setLocation([task.hash], target);
    }
    await this.afterEdit('已更改保存位置，正在移动文件');
  }

  async setTaskCategory(task: TorrentTask, category: string): Promise<void> {
    await this.qbOf(task.serverId).setCategory([task.hash], category);
    await this.afterEdit('已设置分类');
  }

  /** 标签是**替换**语义：调用方需把原标签合并好再传 */
  async setTaskTags(task: TorrentTask, tags: string[]): Promise<void> {
    await this.qbOf(task.serverId).setTags([task.hash], tags);
    await this.afterEdit('已设置标签');
  }

  async setTaskLimits(task: TorrentTask, downloadBytes: number, uploadBytes: number): Promise<void> {
    if (task.serverType === ServerType.QBITTORRENT) {
      const client: QBittorrentClient = this.qbOf(task.serverId);
      await client.setDownloadLimit([task.hash], downloadBytes);
      await client.setUploadLimit([task.hash], uploadBytes);
    } else {
      await this.trOf(task.serverId).setLimits([task.hash], downloadBytes, uploadBytes);
    }
    await this.afterEdit('已更新限速设置');
  }

  /**
   * 分享率：-2 全局 / -1 无限 / >=0 自定义。
   * qB 的 setShareLimits 必须同时给两个做种时间限制，所以先读回原值再原样传，
   * 否则会顺手把用户的做种时间策略清掉（安卓版踩过这个坑）。
   */
  async setTaskRatio(task: TorrentTask, ratioMode: number, ratioLimit: number): Promise<void> {
    if (task.serverType === ServerType.QBITTORRENT) {
      const client: QBittorrentClient = this.qbOf(task.serverId);
      let seedTime: number = -2;
      let inactiveSeedTime: number = -2;
      try {
        const info: Record<string, Object> | null = await client.torrentInfo(task.hash);
        if (info !== null) {
          seedTime = jNum(info, ['seeding_time_limit', 'seedingTimeLimit'], -2);
          inactiveSeedTime = jNum(info, ['inactive_seeding_time_limit', 'inactiveSeedingTimeLimit'], -2);
        }
      } catch (err) {
        // 读不到就按 -2（跟随全局）传，至少不会把值写成 0
      }
      await client.setShareLimits([task.hash], ratioMode, seedTime, inactiveSeedTime);
    } else {
      await this.trOf(task.serverId).setSeedRatio([task.hash], ratioMode, ratioLimit);
    }
    await this.afterEdit('已更新分享率设置');
  }

  /** 仅 qB：强制继续 */
  async forceStartTask(task: TorrentTask): Promise<void> {
    await this.qbOf(task.serverId).setForceStart([task.hash], true);
    await this.afterEdit('已强制继续');
  }

  /** 仅 qB：自动种子管理 */
  async setAutoManagement(task: TorrentTask, enabled: boolean): Promise<void> {
    await this.qbOf(task.serverId).setAutoManagement([task.hash], enabled);
    await this.afterEdit(enabled ? '已开启自动种子管理' : '已关闭自动种子管理');
  }

  /** 仅 qB：超级种子模式 */
  async setSuperSeeding(task: TorrentTask, enabled: boolean): Promise<void> {
    await this.qbOf(task.serverId).setSuperSeeding([task.hash], enabled);
    await this.afterEdit(enabled ? '已开启超级种子模式' : '已关闭超级种子模式');
  }

  /**
   * 备用限速：读当前状态 → 切换 → **再读一次确认**（qB 的 toggle 接口不返回新状态，同安卓做法）。
   * 不能直接 `return !before`：qB 偶尔会把 toggle 当无效操作吞掉，返回值会和服务器实际状态不符，
   * 顶栏图标就会「亮了但其实没开」。
   */
  async toggleAltSpeed(serverId: string): Promise<boolean> {
    const server: ServerConfig | null = this.state.serverById(serverId);
    if (server === null) {
      throw new Error('服务器不存在');
    }
    if (server.type === ServerType.QBITTORRENT) {
      const client: QBittorrentClient = this.qbOf(serverId);
      const before: boolean = await client.speedLimitsMode();
      await client.toggleSpeedLimitsMode();
      let after: boolean = !before;
      try {
        after = await client.speedLimitsMode();
      } catch (err) {
        // 回读失败就按取反上报（POST 已经 2xx 了），并靠下一轮刷新校正
        return !before;
      }
      if (after === before) {
        throw new Error(`qBittorrent 没有应用切换（服务器仍为${before ? '开启' : '关闭'}）`);
      }
      return after;
    }
    const client: TransmissionClient = this.trOf(serverId);
    const before: boolean = await client.altSpeedEnabled();
    await client.setAltSpeed(!before);
    let after: boolean = !before;
    try {
      after = await client.altSpeedEnabled();
    } catch (err) {
      return !before;
    }
    if (after === before) {
      throw new Error(`Transmission 没有应用切换（服务器仍为${before ? '开启' : '关闭'}）`);
    }
    return after;
  }

  async listCategories(serverId: string): Promise<string[]> {
    try {
      return await this.qbOf(serverId).categories();
    } catch (err) {
      return [];
    }
  }

  async createCategory(serverId: string, name: string, savePath: string): Promise<void> {
    await this.qbOf(serverId).createCategory(name.trim(), savePath.trim());
  }

  async listTags(serverId: string): Promise<string[]> {
    try {
      return await this.qbOf(serverId).tags();
    } catch (err) {
      return [];
    }
  }

  /** 批量操作：暂停 / 继续 / 强制继续 / 校验 / 汇报 / 删除 / 改保存位置 / 自动管理 / 超级种子 */
  async batchAction(serverId: string, action: TorrentAction, hashes: string[],
    location: string = ''): Promise<void> {
    const server: ServerConfig | null = this.state.serverById(serverId);
    if (server === null || hashes.length === 0) {
      return;
    }
    if (server.type === ServerType.QBITTORRENT) {
      const client: QBittorrentClient = this.qbOf(serverId);
      if (action === TorrentAction.PAUSE) {
        await client.pause(hashes);
      } else if (action === TorrentAction.RESUME) {
        await client.resume(hashes);
      } else if (action === TorrentAction.FORCE_RESUME) {
        await client.setForceStart(hashes, true);
      } else if (action === TorrentAction.RECHECK) {
        await client.recheck(hashes);
      } else if (action === TorrentAction.REANNOUNCE) {
        await client.reannounce(hashes);
      } else if (action === TorrentAction.DELETE || action === TorrentAction.DELETE_WITH_FILES) {
        await client.delete(hashes, action === TorrentAction.DELETE_WITH_FILES);
      } else if (action === TorrentAction.CHANGE_LOCATION) {
        await client.setLocation(hashes, location.trim());
      } else if (action === TorrentAction.AUTO_MANAGEMENT_ON) {
        await client.setAutoManagement(hashes, true);
      } else if (action === TorrentAction.SUPER_SEEDING_ON) {
        await client.setSuperSeeding(hashes, true);
      }
    } else {
      const client: TransmissionClient = this.trOf(serverId);
      if (action === TorrentAction.PAUSE) {
        await client.pause(hashes);
      } else if (action === TorrentAction.RESUME) {
        await client.resume(hashes);
      } else if (action === TorrentAction.RECHECK) {
        await client.recheck(hashes);
      } else if (action === TorrentAction.REANNOUNCE) {
        await client.reannounce(hashes);
      } else if (action === TorrentAction.DELETE || action === TorrentAction.DELETE_WITH_FILES) {
        await client.delete(hashes, action === TorrentAction.DELETE_WITH_FILES);
      } else if (action === TorrentAction.CHANGE_LOCATION) {
        await client.setLocation(hashes, location.trim());
      }
      // 强制继续 / 自动管理 / 超级种子是 qB 独有，Transmission 侧忽略
    }
    ToastHub.getInstance().show(torrentActionSuccessText(action));
    await sleep(500);
    await this.refresh(false);
  }

  /** 新增下载：URL / 磁力 */
  async addTorrentByUrl(serverId: string, url: string, opts: AddTorrentOptions): Promise<void> {
    const server: ServerConfig | null = this.state.serverById(serverId);
    if (server === null) {
      throw new Error('服务器不存在');
    }
    if (server.type === ServerType.QBITTORRENT) {
      // 第 5 位是 firstLastPiecePriority，skipChecking 是第 6 位；原来传错位，
      // 勾了「跳过校验」反而变成首末块优先 + 顺序下载，校验照样跑。
      await this.qbOf(serverId).addTorrents([url.trim()], opts.savePath, opts.category, opts.paused,
        false, opts.skipChecking);
    } else {
      await this.trOf(serverId).addTorrents([url.trim()], opts.savePath, opts.paused);
    }
    this.rememberSavePath(opts.savePath);
  }

  /** 新增下载：本地 .torrent 文件 */
  async addTorrentByFile(serverId: string, bytes: ArrayBuffer, fileName: string,
    opts: AddTorrentOptions): Promise<void> {
    const server: ServerConfig | null = this.state.serverById(serverId);
    if (server === null) {
      throw new Error('服务器不存在');
    }
    if (server.type === ServerType.QBITTORRENT) {
      await this.qbOf(serverId).addTorrentFile(bytes, fileName, opts);
    } else {
      const b64: string = new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes));
      await this.trOf(serverId).addTorrentFile(b64, opts);
    }
    this.rememberSavePath(opts.savePath);
  }

  /** 带 Cookie 的 http 直链：App 先抓下 .torrent，再交给下载器（tr/qb 都没有单任务 Cookie 字段） */
  async addTorrentWithCookie(serverId: string, url: string, cookie: string,
    opts: AddTorrentOptions): Promise<void> {
    if (cookie.trim().length === 0) {
      await this.addTorrentByUrl(serverId, url, opts);
      return;
    }
    const headers: Record<string, string> = { 'Cookie': cookie.trim() };
    const binary: ArrayBuffer = await getBinary(url.trim(), headers, 30000);
    const bytes: Uint8Array = new Uint8Array(binary);
    if (bytes.length === 0 || bytes[0] !== 0x64) {
      throw new Error('下载到的不是 .torrent 文件（可能被站点登录页拦截了）');
    }
    await this.addTorrentByFile(serverId, binary, 'download.torrent', opts);
  }

  private rememberSavePath(path: string): void {
    if (path.trim().length === 0) {
      return;
    }
    const s: AppState = this.cloneState();
    s.lastSavePath = path.trim();
    this.state = s;
    this.notify();
  }

  // ---------------- Tracker 列表（查看 / 编辑） ----------------

  /** 拉某个种子的 Tracker 列表；弹窗每次打开、改完都调这里 */
  async loadTrackers(task: TorrentTask): Promise<TrackerEntry[]> {
    if (task.serverType === ServerType.QBITTORRENT) {
      return await this.qbOf(task.serverId).trackers(task.hash);
    }
    return await this.trOf(task.serverId).trackers(task.hash);
  }

  /**
   * 改一条 Tracker 的地址。
   * qB 用「原 URL」定位，tr 用 trackerStats 的 id 定位 —— 两者参数不同，按类型分发。
   * 这里**不**调全局 refresh：Tracker 改动不影响任务列表，重拉 30 个种子纯属浪费，
   * 弹窗自己重新拉一次 Tracker 列表就够了。
   */
  async editTrackerEntry(task: TorrentTask, entry: TrackerEntry, newUrl: string): Promise<void> {
    const url: string = newUrl.trim();
    if (url.length === 0) {
      throw new Error('Tracker 地址不能为空');
    }
    if (task.serverType === ServerType.QBITTORRENT) {
      await this.qbOf(task.serverId).editTracker(task.hash, entry.url, url);
    } else {
      await this.trOf(task.serverId).editTracker(task.hash, entry.trackerId, url);
    }
    ToastHub.getInstance().show('Tracker 已更新');
  }

  /** 追加一条 Tracker */
  async addTrackerEntry(task: TorrentTask, newUrl: string): Promise<void> {
    const url: string = newUrl.trim();
    if (url.length === 0) {
      throw new Error('Tracker 地址不能为空');
    }
    if (task.serverType === ServerType.QBITTORRENT) {
      await this.qbOf(task.serverId).addTrackers(task.hash, [url]);
    } else {
      await this.trOf(task.serverId).addTrackers(task.hash, [url]);
    }
    ToastHub.getInstance().show('已添加 Tracker');
  }

  /** 删掉一条 Tracker */
  async removeTrackerEntry(task: TorrentTask, entry: TrackerEntry): Promise<void> {
    if (task.serverType === ServerType.QBITTORRENT) {
      await this.qbOf(task.serverId).removeTrackers(task.hash, [entry.url]);
    } else {
      await this.trOf(task.serverId).removeTrackers(task.hash, [entry.trackerId]);
    }
    ToastHub.getInstance().show('已删除 Tracker');
  }

  private async afterEdit(message: string): Promise<void> {
    ToastHub.getInstance().show(message);
    await sleep(300);
    await this.refresh(false);
  }
}
