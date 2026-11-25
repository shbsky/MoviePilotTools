import { MusicLibraryStats, MusicPlaylist, MusicSong, MusicUiState, PlaybackState } from '../model/MusicModels';
import { SongloftClient, SongloftSession, SongPage } from '../net/SongloftClient';
import { PlayerEngine } from '../player/PlayerEngine';
import { CastController, CastState } from '../player/CastController';
import { BackgroundAudioManager, MediaCommandHandler } from '../player/BackgroundAudioManager';
import { DlnaDevice } from '../net/DlnaClient';
import { ObservableStore, ToastHub } from './StoreBase';
import { ConfigStore } from '../data/ConfigStore';
import { PersistedState, AppSettings } from '../model/Settings';
import { logInfo, logWarn } from '../common/AppConstants';

/**
 * 锁屏卡/通知栏媒体命令 → VM 操作的路由器（对应架构 §6 第 3 步）。
 * 与 VM 的操作方法保持同一套路由：投送中命令操作音箱（CastController），
 * 否则操作本机（PlayerEngine）。
 * ArkTS 不允许接口字面量，这里用实现类；注册在 MusicViewModel 构造器里。
 */
class MediaCommandRouter implements MediaCommandHandler {
  private vm: MusicViewModel;

  constructor(vm: MusicViewModel) {
    this.vm = vm;
  }

  onPlay(): void {
    this.vm.resumePlayback();
  }

  onPause(): void {
    this.vm.pausePlayback();
  }

  onNext(): void {
    this.vm.next();
  }

  onPrevious(): void {
    this.vm.previous();
  }

  onSeek(positionMs: number): void {
    this.vm.seekTo(positionMs);
  }
}

/**
 * 音乐页 ViewModel（对应安卓 vm/MusicViewModel.kt）：
 * 管 Songloft 的登录态、歌曲/歌单列表、分页与搜索、收藏；
 * 播放交给 PlayerEngine（App 级单例，切标签页不会断）。
 * T07 接入投送后，「正在播」取本机与投送的合并态。
 */
export class MusicViewModel extends ObservableStore {
  private static inst: MusicViewModel | null = null;

  static getInstance(): MusicViewModel {
    if (MusicViewModel.inst === null) {
      MusicViewModel.inst = new MusicViewModel();
    }
    return MusicViewModel.inst;
  }

  state: MusicUiState = new MusicUiState();
  private engine: PlayerEngine = PlayerEngine.getInstance();
  private cast: CastController = CastController.getInstance();
  private client: SongloftClient | null = null;
  private configKey: string = '';
  private pageSize: number = 60;
  private loadGeneration: number = 0;
  private pagedQuery: string = '';

  private constructor() {
    super();
    // 播放器状态变化也驱动音乐页刷新（迷你条/播放页），
    // 同时把「本机 + 投送」合并态同步进 AVSession（锁屏/通知栏媒体卡）。
    // 合并态保证投送中卡片 current 取的是投送队列当前曲（架构 §6）。
    const onPlaybackChanged = (): void => {
      BackgroundAudioManager.sync(this.playback());
      this.notify();
    };
    this.engine.subscribe(onPlaybackChanged);
    // 投送状态变化同样驱动刷新（合并后的播放态包含投送进度）
    this.cast.subscribe(onPlaybackChanged);

    // 锁屏卡/通知栏媒体命令路由（实现类见文件顶部 MediaCommandRouter）
    BackgroundAudioManager.setCommandHandler(new MediaCommandRouter(this));
  }

  private commit(s: MusicUiState): void {
    this.state = s;
    this.notify();
  }

  /** 是否正在投送（投送中点歌/播放键都操作音箱而不是本机） */
  private casting(): boolean {
    return this.cast.state.casting();
  }

  /**
   * 界面真正该显示的播放状态：**本机播放和投送合并成一路**（对应安卓 merge()）。
   *
   * 投送是音箱自己在放，本机播放器是暂停的；如果界面还读本机状态，
   * 就会出现「点了黄昏，底下还写着上一首、列表也还是上一首红色」的错位。
   */
  playback(): PlaybackState {
    const local: PlaybackState = this.engine.state;
    const cs: CastState = this.cast.state;
    const device: DlnaDevice | null = cs.active;
    if (device === null) {
      const plain: PlaybackState = local.copy();
      plain.castingTo = null;
      return plain;
    }
    const song: MusicSong | null =
      cs.index >= 0 && cs.index < cs.queue.length ? cs.queue[cs.index] : local.current;
    const merged: PlaybackState = new PlaybackState();
    merged.current = song;
    merged.isPlaying = cs.playing;
    merged.positionMs = cs.positionMs;
    merged.durationMs = cs.durationMs > 0
      ? cs.durationMs
      : (song !== null ? song.durationSeconds * 1000 : 0);
    merged.hasPrevious = cs.hasPrevious();
    merged.hasNext = cs.hasNext();
    merged.volume = cs.volume >= 0 ? cs.volume / 100 : local.volume;
    merged.repeatMode = local.repeatMode;
    merged.castingTo = device.name;
    merged.error = null;
    return merged;
  }

  /** App 启动时调用一次：读配置并恢复会话 */
  bootstrap(): void {
    // 冷启动先恢复上次登录的 token，避免每次打开都要重登（登录接口有限流）
    SongloftSession.restoreFromVault();
    const persisted: PersistedState = ConfigStore.getInstance().load();
    const settings: AppSettings = persisted.settings;
    this.configure(settings.musicUrl, settings.musicUser, settings.musicPass);
    logInfo('MusicViewModel', `bootstrap: configured=${this.state.configured}`);
  }

  // ------------------------------------------------------------ 配置

  /** 设置页改了地址/账号后由界面调用；同配置不重复拉数据 */
  configure(url: string, user: string, pass: string): void {
    const key: string = `${url}|${user}|${pass}`;
    if (key === this.configKey) {
      return;
    }
    this.configKey = key;
    this.loadGeneration++;

    const candidate: SongloftClient = new SongloftClient(url, user, pass);
    if (!candidate.isConfigured()) {
      this.client = null;
      SongloftSession.reset();
      const s: MusicUiState = new MusicUiState();
      s.configured = false;
      this.commit(s);
      return;
    }
    this.client = candidate;
    this.engine.urlResolver = (song: MusicSong): string => candidate.playableUrl(song);
    // 起播前先刷新登录态：token 过期自动重登，避免流地址 401（「播放操作失败」的根因）
    this.engine.prepareLoad = (): Promise<void> => candidate.ensureFreshToken();
    const s: MusicUiState = this.state.copy();
    s.configured = true;
    s.serverLabel = candidate.label();
    s.loading = true;
    s.error = '';
    s.songs = [];
    s.playlists = [];
    s.stats = null;
    s.playlist = null;
    s.playlistSongs = [];
    this.commit(s);
    this.load(true);
  }

  refresh(): void {
    if (this.client === null) {
      return;
    }
    this.load(true);
  }

  // ------------------------------------------------------------ 拉数据

  private async load(force: boolean): Promise<void> {
    const client: SongloftClient | null = this.client;
    if (client === null) {
      return;
    }
    this.loadGeneration++;
    const gen: number = this.loadGeneration;
    this.pagedQuery = '';
    const s: MusicUiState = this.state.copy();
    s.loading = true;
    s.error = '';
    this.commit(s);

    // 三个请求并发，但任何一个失败都不能让整页崩掉：每个各自 catch
    const songsP: Promise<SongPage | null> =
      client.songs('', 0, this.pageSize).catch((e: Error): SongPage | null => null);
    const playlistsP: Promise<MusicPlaylist[]> =
      client.playlists().catch((e: Error): MusicPlaylist[] => []);
    const statsP: Promise<MusicLibraryStats | null> =
      client.stats().catch((e: Error): MusicLibraryStats | null => null);
    const favP: Promise<Set<number>> =
      client.favoriteIds().catch((e: Error): Set<number> => new Set<number>());

    const page: SongPage | null = await songsP;
    const playlists: MusicPlaylist[] = await playlistsP;
    const stats: MusicLibraryStats | null = await statsP;
    const favorites: Set<number> = await favP;
    if (gen !== this.loadGeneration) {
      return;
    }
    const s2: MusicUiState = this.state.copy();
    s2.loading = false;
    s2.playlists = playlists;
    s2.stats = stats;
    if (favorites.size > 0) {
      s2.favoriteIds = favorites;
    }
    if (page === null) {
      // 主请求失败：报错但保留歌单/统计等次要数据
      s2.error = MusicViewModel.friendly(SongloftSession.currentLastError());
    } else {
      s2.error = '';
      s2.songs = page.songs;
      s2.total = page.total;
    }
    this.commit(s2);
  }

  loadMore(): void {
    const client: SongloftClient | null = this.client;
    if (client === null) {
      return;
    }
    const current: MusicUiState = this.state;
    if (current.playlist !== null || current.loading || current.loadingMore) {
      return;
    }
    if (current.songs.length >= current.total) {
      return;
    }
    const gen: number = ++this.loadGeneration;
    const offset: number = current.songs.length;
    const keyword: string = this.pagedQuery;
    const s: MusicUiState = this.state.copy();
    s.loadingMore = true;
    this.commit(s);
    client.songs(keyword, offset, this.pageSize).then((page: SongPage): void => {
      if (gen !== this.loadGeneration) {
        return;
      }
      const merged: MusicSong[] = MusicViewModel.distinctSongs(
        this.state.songs.concat(page.songs));
      const s2: MusicUiState = this.state.copy();
      s2.loadingMore = false;
      s2.songs = merged;
      s2.total = Math.max(page.total, merged.length);
      this.commit(s2);
    }).catch((e: Error): void => {
      if (gen !== this.loadGeneration) {
        return;
      }
      const s2: MusicUiState = this.state.copy();
      s2.loadingMore = false;
      this.commit(s2);
    });
  }

  private static distinctSongs(list: MusicSong[]): MusicSong[] {
    const seen: Set<number> = new Set<number>();
    const out: MusicSong[] = [];
    for (const s of list) {
      if (!seen.has(s.id)) {
        seen.add(s.id);
        out.push(s);
      }
    }
    return out;
  }

  // ------------------------------------------------------------ 搜索

  startSearch(): void {
    const s: MusicUiState = this.state.copy();
    s.searchActive = true;
    s.playlist = null;
    this.commit(s);
  }

  exitSearch(): void {
    const s: MusicUiState = this.state.copy();
    s.searchActive = false;
    s.query = '';
    this.commit(s);
    this.load(true);
  }

  search(keyword: string): void {
    const client: SongloftClient | null = this.client;
    if (client === null) {
      return;
    }
    const trimmed: string = keyword.trim();
    this.loadGeneration++;
    const gen: number = this.loadGeneration;
    this.pagedQuery = trimmed;
    const s: MusicUiState = this.state.copy();
    s.query = trimmed;
    s.loading = true;
    s.error = '';
    s.playlist = null;
    this.commit(s);
    client.songs(trimmed, 0, this.pageSize).then((page: SongPage): void => {
      if (gen !== this.loadGeneration) {
        return;
      }
      const s2: MusicUiState = this.state.copy();
      s2.loading = false;
      s2.songs = page.songs;
      s2.total = page.total;
      this.commit(s2);
    }).catch((e: Error): void => {
      if (gen !== this.loadGeneration) {
        return;
      }
      const s2: MusicUiState = this.state.copy();
      s2.loading = false;
      s2.error = MusicViewModel.friendly(e.message);
      this.commit(s2);
    });
  }

  // ------------------------------------------------------------ 歌单

  openPlaylist(playlist: MusicPlaylist): void {
    const client: SongloftClient | null = this.client;
    if (client === null) {
      return;
    }
    this.loadGeneration++;
    const gen: number = this.loadGeneration;
    const s: MusicUiState = this.state.copy();
    s.playlist = playlist;
    s.playlistSongs = [];
    s.playlistLoading = true;
    s.searchActive = false;
    s.query = '';
    this.commit(s);
    client.playlistSongs(playlist.id).then((page: SongPage): void => {
      if (gen !== this.loadGeneration) {
        return;
      }
      const s2: MusicUiState = this.state.copy();
      s2.playlistSongs = page.songs;
      s2.playlistLoading = false;
      this.commit(s2);
    }).catch((e: Error): void => {
      if (gen !== this.loadGeneration) {
        return;
      }
      const s2: MusicUiState = this.state.copy();
      s2.playlistLoading = false;
      ToastHub.getInstance().show(MusicViewModel.friendly(e.message));
      this.commit(s2);
    });
  }

  closePlaylist(): void {
    const s: MusicUiState = this.state.copy();
    s.playlist = null;
    s.playlistSongs = [];
    this.commit(s);
  }

  // ------------------------------------------------------------ 播放

  /**
   * 点歌。
   *
   * 已经在投送状态时，点歌直接推到音箱（并把它所在的整张列表变成投送队列），
   * 不需要再点右上角的投送按钮 —— 这是「点一下就播」的核心逻辑。
   */
  playSong(song: MusicSong): void {
    const list: MusicSong[] = this.state.visibleSongs();
    if (list.length === 0) {
      const single: MusicSong[] = [song];
      if (this.playToCastIfActive(single, 0, song.title)) {
        return;
      }
      this.engine.play(single, 0);
      return;
    }
    let index: number = 0;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === song.id) {
        index = i;
        break;
      }
    }
    if (this.playToCastIfActive(list, index, song.title)) {
      return;
    }
    this.engine.play(list, index);
  }

  playAll(): void {
    const list: MusicSong[] = this.state.visibleSongs();
    if (list.length === 0) {
      return;
    }
    if (this.playToCastIfActive(list, 0, '')) {
      ToastHub.getInstance().show(`把 ${list.length} 首投送到「${(this.cast.state.active as DlnaDevice).name}」`);
      return;
    }
    this.engine.play(list, 0);
  }

  /**
   * 有投送目标时把队列推给它；返回 false = 没在投送，调用方继续走本机播放。
   * 投送时手机这边要暂停本机播放，否则两边同时出声。
   */
  private playToCastIfActive(list: MusicSong[], index: number, songTitle: string): boolean {
    const device: DlnaDevice | null = this.cast.state.active;
    if (device === null) {
      return false;
    }
    this.castTo(device, list, index);
    if (songTitle.length > 0) {
      ToastHub.getInstance().show(`投送到「${device.name}」：${songTitle}`);
    }
    return true;
  }

  /** 投送时手机这边要静音，否则两边同时出声 */
  private castTo(device: DlnaDevice, list: MusicSong[], index: number): void {
    const current: SongloftClient | null = this.client;
    if (current === null) {
      ToastHub.getInstance().show('还没配置 Songloft（设置 → 音乐服务）');
      return;
    }
    if (this.engine.state.isPlaying) {
      this.engine.pause();
    }
    this.cast.playQueue(device, list, index,
      (song: MusicSong): string => current.playableUrl(song),
      (song: MusicSong): string => MusicViewModel.mimeOf(song));
  }

  /**
   * 把当前这首推到 DLNA 设备播放（投送面板里点设备行时用）。
   *
   * 音频地址必须带 access_token（Songloft 的媒体鉴权走查询参数），
   * 音箱自己去拉这个 URL，所以投送成功后会把本机播放暂停，避免两边同时出声。
   */
  castCurrent(device: DlnaDevice): void {
    // 队列优先取「本机正在播的那条队列」：用界面可见列表（visibleSongs）时，
    // 只要当前停在其他歌单/搜索结果里，投出去的就可能只剩这一首，
    // 播完必然停住，看起来像连播坏了。
    const engineQueue: MusicSong[] = this.engine.getQueue();
    const list: MusicSong[] = engineQueue.length > 0 ? engineQueue : this.state.visibleSongs();
    const cs: CastState = this.cast.state;
    // 已经在投送中就以「音箱那首」为准，否则用本机正在播的
    const playing: MusicSong | null = this.playback().current;
    const song: MusicSong | null = cs.casting() && cs.index >= 0 && cs.index < cs.queue.length
      ? cs.queue[cs.index]
      : playing;
    if (list.length === 0 && song === null) {
      ToastHub.getInstance().show('先在手机上播一首歌，再点投送');
      return;
    }
    // 坑：当前这首不在列表里（切过歌单/搜索过）时 index 会被钳成 0，
    // 结果投出去的是列表第一首，跟界面显示的对不上。
    // 现在把当前这首插到队首，再从头播。
    const found: number = song === null ? -1 : list.findIndex((s: MusicSong): boolean => s.id === song.id);
    let queue: MusicSong[];
    let start: number;
    if (list.length === 0 && song !== null) {
      queue = [song];
      start = 0;
    } else if (song === null || found >= 0) {
      queue = list;
      start = Math.max(0, found);
    } else {
      queue = [song as MusicSong].concat(list);
      start = 0;
    }
    this.castTo(device, queue, start);
    ToastHub.getInstance().show(`正在投送到「${device.name}」…`);
  }

  /** 按扩展名猜 MIME，音箱靠它选解码器 */
  private static mimeOf(song: MusicSong): string {
    const format: string = song.format.toLowerCase();
    if (format === 'flac') {
      return 'audio/flac';
    }
    if (format === 'wav') {
      return 'audio/wav';
    }
    if (format === 'aac' || format === 'm4a') {
      return 'audio/mp4';
    }
    if (format === 'ogg' || format === 'opus') {
      return 'audio/ogg';
    }
    return 'audio/mpeg';
  }

  togglePlay(): void {
    // 投送中：本机没有出声，播放键操作的是音箱
    if (this.casting()) {
      this.cast.togglePause();
    } else {
      this.engine.toggle();
    }
  }

  /** 媒体卡「播放」键：投送中且音箱在暂停时恢复，本机则恢复播放 */
  resumePlayback(): void {
    if (this.casting()) {
      if (!this.cast.state.playing) {
        this.cast.togglePause();
      }
    } else {
      this.engine.resume();
    }
  }

  /** 媒体卡「暂停」键：投送中且音箱在播时暂停，本机则暂停 */
  pausePlayback(): void {
    logWarn('MusicViewModel', `媒体卡暂停命令 casting=${this.casting()}`);
    if (this.casting()) {
      if (this.cast.state.playing) {
        this.cast.togglePause();
      }
    } else {
      this.engine.pause();
    }
  }

  setVolume(value: number): void {
    if (this.casting()) {
      // 投送时滑块 0..1 → 音箱音量 0..100
      this.cast.setVolume(Math.round(value * 100));
    } else {
      this.engine.setVolume(value);
    }
  }

  next(): void {
    if (this.casting()) {
      this.cast.next();
    } else {
      this.engine.next(false);
    }
  }

  previous(): void {
    if (this.casting()) {
      this.cast.previous();
    } else {
      this.engine.previous();
    }
  }

  seekTo(positionMs: number): void {
    if (this.casting()) {
      this.cast.seekTo(positionMs);
    } else {
      this.engine.seekTo(positionMs);
    }
  }

  /**
   * 播放模式四档循环：顺序 → 单曲循环 → 列表循环 → 随机 → 顺序。
   * 本机和投送共用同一套模式：本机交给 PlayerEngine，投送由 CastController
   * 按模式决定播完一首后推哪首。
   */
  cycleRepeatMode(): void {
    const mode: number = this.engine.cycleRepeatMode();
    this.cast.setRepeatMode(mode);
    ToastHub.getInstance().show(
      mode === 1 ? '单曲循环' : (mode === 2 ? '列表循环' : (mode === 3 ? '随机播放' : '顺序播放')));
  }

  /** 页面销毁时停进度轮询（不释放播放器） */
  detachEngine(): void {
    this.engine.detach();
  }

  stopPlayback(): void {
    if (this.casting()) {
      this.cast.stopCasting();
    } else {
      this.engine.stop();
    }
  }

  /**
   * 彻底退出播放：停本机、停投送、清当前曲目与队列。
   * 迷你播放条在各标签页常驻，暂停或播完之后它不会自己消失；
   * 迷你条右侧的 × 调这里，关掉之后底部那条就没了。
   */
  quitPlayback(): void {
    if (this.casting()) {
      this.cast.stopCasting();
    }
    this.engine.stop();
  }

  // ------------------------------------------------------------ 收藏

  /** 收藏/取消收藏：先乐观更新红心，服务端失败再回滚（收藏 = 内建「收藏」歌单） */
  toggleFavorite(song: MusicSong): void {
    const client: SongloftClient | null = this.client;
    if (client === null) {
      return;
    }
    const fav: boolean = this.state.favoriteIds.has(song.id);
    const nextIds: Set<number> = new Set<number>(this.state.favoriteIds);
    if (fav) {
      nextIds.delete(song.id);
    } else {
      nextIds.add(song.id);
    }
    const s: MusicUiState = this.state.copy();
    s.favoriteIds = nextIds;
    this.commit(s);
    ToastHub.getInstance().show(fav ? `已取消收藏「${song.title}」` : `已收藏「${song.title}」`);
    // 乐观更新后失败要回滚：服务端返回 false 和网络异常（Promise reject）两条路径都要覆盖，
    // 原来只有 .then()，网络一断 UI 就停在「已收藏」但实际没成功。
    const rollbackFavorite = (): void => {
      const rollback: Set<number> = new Set<number>(this.state.favoriteIds);
      if (fav) {
        rollback.add(song.id);
      } else {
        rollback.delete(song.id);
      }
      const s2: MusicUiState = this.state.copy();
      s2.favoriteIds = rollback;
      this.commit(s2);
      ToastHub.getInstance().show('收藏操作失败，请重试');
    };
    client.setFavorite(song.id, !fav).then((ok: boolean): void => {
      if (!ok) {
        rollbackFavorite();
      }
    }).catch((): void => {
      rollbackFavorite();
    });
  }

  // ------------------------------------------------------------ 杂项

  private static friendly(raw: string): string {
    const message: string = raw.trim();
    if (message.length === 0) {
      return '连接 Songloft 失败，检查地址与网络';
    }
    if (message.includes('Failed to connect') || message.includes('timeout') ||
      message.toLowerCase().includes('timed out')) {
      return '连不上 Songloft（地址/端口不对，或服务没开）';
    }
    return message;
  }
}
