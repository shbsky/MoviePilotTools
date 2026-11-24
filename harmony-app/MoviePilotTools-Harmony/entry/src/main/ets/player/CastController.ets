import { MusicSong } from '../model/MusicModels';
import { DlnaClient, DlnaDevice, DlnaTransport } from '../net/DlnaClient';
import { get, TimeoutTier } from '../net/HttpClient';
import { ObservableStore } from '../vm/StoreBase';
import { BackgroundAudioManager } from './BackgroundAudioManager';
import { logWarn } from '../common/AppConstants';

/**
 * DLNA 投送状态机（单例，对应安卓 vm/CastController.kt）。
 *
 * 投送是「音箱自己去拉流」，所以一旦 SetAVTransportURI + Play 成功，本机就不用再管音频了。
 * 但 DLNA 的 AVTransport 没有队列概念（一次只有一条 URI），所以「连播」由这里做：
 * 每 2.5 秒轮询音箱的 TransportState，一首放完（PLAYING → STOPPED）就自己推下一首。
 *
 * 一旦有了投送目标（active），点歌就不再走本机扬声器，而是直接投给音箱 ——
 * 这就是「点一下就播」的关键。
 */
export class CastState {
  scanning: boolean = false;
  scanned: boolean = false;
  devices: DlnaDevice[] = [];
  /** 当前投送目标，null = 没在投送 */
  active: DlnaDevice | null = null;
  title: string = '';
  busy: boolean = false;
  message: string | null = null;
  /** 投送队列（点歌时的整张列表），支持自动连播 */
  queue: MusicSong[] = [];
  index: number = -1;
  /** 播放模式：0 顺序 / 1 单曲循环 / 2 列表循环 / 3 随机 */
  repeatMode: number = 0;
  playing: boolean = true;
  /** 音箱音量 0..100，-1 = 未知 */
  volume: number = -1;
  volumeSupported: boolean = false;
  /** 播放进度（毫秒）：轮询音箱时校准，播放中由本地计时器平滑推进 */
  positionMs: number = 0;
  durationMs: number = 0;

  casting(): boolean {
    return this.active !== null;
  }

  progressText(): string {
    if (this.queue.length === 0 || this.index < 0) {
      return '';
    }
    return `${this.index + 1}/${this.queue.length}`;
  }

  hasNext(): boolean {
    return this.index >= 0 && this.queue.length > 1 &&
      (this.index < this.queue.length - 1 || this.repeatMode === 2 || this.repeatMode === 3);
  }

  hasPrevious(): boolean {
    return this.index > 0;
  }

  copy(): CastState {
    const c: CastState = new CastState();
    c.scanning = this.scanning;
    c.scanned = this.scanned;
    c.devices = this.devices;
    c.active = this.active;
    c.title = this.title;
    c.busy = this.busy;
    c.message = this.message;
    c.queue = this.queue;
    c.index = this.index;
    c.repeatMode = this.repeatMode;
    c.playing = this.playing;
    c.volume = this.volume;
    c.volumeSupported = this.volumeSupported;
    c.positionMs = this.positionMs;
    c.durationMs = this.durationMs;
    return c;
  }
}

export class CastController extends ObservableStore {
  private static inst: CastController | null = null;

  static getInstance(): CastController {
    if (CastController.inst === null) {
      CastController.inst = new CastController();
    }
    return CastController.inst;
  }

  state: CastState = new CastState();

  /** 本地进度推进间隔 */
  private static readonly TICK_MS: number = 500;
  /** 每 5 个 tick（2.5 秒）真的查一次音箱 */
  private static readonly POLL_TICKS: number = 5;

  /** 正在推流，别让轮询重复触发下一首 */
  private pushing: boolean = false;
  /** 监控循环代数：+1 即终止旧循环 */
  private monitorGen: number = 0;
  /** 上次推流的时刻：推完 4 秒内不判定「这首放完了」，否则音箱还没切过来会连推两首 */
  private lastPushAt: number = 0;
  /** 最近一次成功推给音箱的流地址：轮询时拿音箱的 CurrentURI 跟它比 */
  private lastPushedUrl: string = '';
  /**
   * 最近一次成功推的曲目本地时长：接管兜底用它和音箱报的时长比。
   * 不能用 state.durationMs —— 那个每轮被音箱校准覆盖，首轮之后就失效了。
   */
  private lastLocalDurationMs: number = 0;
  /** 上一次推流失败的曲目和时刻：防止「放完了 → 推失败 → 再判完成 → 再推」死循环 */
  private lastFailIndex: number = -1;
  private lastFailAt: number = 0;
  /** 音量防抖定时器 */
  private volumeTimer: number = -1;

  private urlFor: (song: MusicSong) => string = (song: MusicSong): string => song.streamUrl;
  private mimeFor: (song: MusicSong) => string = (_song: MusicSong): string => 'audio/mpeg';

  /** 播放模式：0 顺序 / 1 单曲循环 / 2 列表循环 / 3 随机（和 PlayerEngine 的 repeatMode 同一套值） */
  private repeatMode: number = 0;

  private constructor() {
    super();
  }

  private commit(s: CastState): void {
    this.state = s;
    this.notify();
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: (v: void) => void): void => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }

  /** ViewModel 切换模式时同步过来，投送端的自动连播按它决定下一首 */
  setRepeatMode(mode: number): void {
    this.repeatMode = Math.max(0, Math.min(3, Math.trunc(mode)));
    const s: CastState = this.state.copy();
    s.repeatMode = this.repeatMode;
    this.commit(s);
  }

  /**
   * 按播放模式算下一首下标；null = 队列结束（该停了）。
   * manual = 手动点下一首：单曲循环时仍然往后走，符合主流播放器习惯。
   */
  private nextIndex(cur: number, size: number, manual: boolean): number | null {
    if (size <= 0 || cur < 0) {
      return null;
    }
    const mode: number = manual && this.repeatMode === 1 ? 0 : this.repeatMode;
    if (mode === 1) {
      return cur;
    }
    if (mode === 2) {
      return (cur + 1) % size;
    }
    if (mode === 3) {
      if (size === 1) {
        return 0;
      }
      let n: number = cur;
      while (n === cur) {
        n = Math.floor(Math.random() * size);
      }
      return n;
    }
    return cur + 1 < size ? cur + 1 : null;
  }

  // ---------------------------------------------------------------- 发现设备

  /** 搜索局域网里的投送设备（音箱/电视/盒子） */
  scan(): void {
    if (this.state.scanning) {
      return;
    }
    const s: CastState = this.state.copy();
    s.scanning = true;
    s.message = null;
    this.commit(s);
    DlnaClient.discover(4000).then((devices: DlnaDevice[]): void => {
      const s2: CastState = this.state.copy();
      s2.scanning = false;
      s2.scanned = true;
      s2.devices = devices;
      s2.message = devices.length === 0
        ? '没找到可投送的设备。确认音箱和手机在同一个 WiFi、且音箱支持 DLNA/UPnP 投送。'
        : null;
      this.commit(s2);
    }).catch((e: Error): void => {
      const s2: CastState = this.state.copy();
      s2.scanning = false;
      s2.scanned = true;
      s2.message = `搜索失败：${e.message.length > 0 ? e.message : '未知错误'}`;
      this.commit(s2);
    });
  }

  stopScan(): void {
    if (this.state.scanning) {
      const s: CastState = this.state.copy();
      s.scanning = false;
      this.commit(s);
    }
  }

  // ---------------------------------------------------------------- 投送

  /**
   * 把整个队列投给设备，从 startIndex 开始播。
   *
   * @param urlFor 曲目 → 可播放的绝对地址（Songloft 还要带 access_token）
   * @param mimeFor 曲目 → MIME，音箱靠它选解码器
   */
  playQueue(device: DlnaDevice, songs: MusicSong[], startIndex: number,
    urlFor: (song: MusicSong) => string, mimeFor: (song: MusicSong) => string): void {
    if (songs.length === 0) {
      return;
    }
    this.urlFor = urlFor;
    this.mimeFor = mimeFor;
    const index: number = Math.max(0, Math.min(songs.length - 1, Math.trunc(startIndex)));

    const s: CastState = this.state.copy();
    s.active = device;
    s.queue = songs;
    s.index = index;
    s.repeatMode = this.repeatMode;
    s.busy = true;
    s.message = null;
    s.volumeSupported = device.volumeSupported();
    this.commit(s);
    this.push(index).then((): void => {
      // 队列投送同样要保活：息屏后音箱轮询（连播判定）不能被冻结，
      // AVSession 卡片也要显示投送中的曲目（元数据由 MusicViewModel 合并态同步）
      // 注意用 startCast()：投送时手机无音频输出，AUDIO_PLAYBACK 会被系统回收
      BackgroundAudioManager.startCast();
      const s2: CastState = this.state.copy();
      s2.busy = false;
      this.commit(s2);
      this.refreshVolume();
      this.startMonitor(device);
    });
  }

  /** 只投一首（设备行里点「投送」时用） */
  cast(device: DlnaDevice, audioUrl: string, title: string, mime: string = 'audio/mpeg'): void {
    if (audioUrl.trim().length === 0) {
      const s: CastState = this.state.copy();
      s.message = '这首歌没有可用地址，没法投送';
      this.commit(s);
      return;
    }
    const s: CastState = this.state.copy();
    s.busy = true;
    s.message = null;
    this.commit(s);
    DlnaClient.play(device, audioUrl, title, mime).then((): void => {
      BackgroundAudioManager.startCast();
      this.lastPushAt = Date.now();
      this.lastPushedUrl = audioUrl;
      const s2: CastState = this.state.copy();
      s2.busy = false;
      s2.active = device;
      s2.title = title;
      s2.index = -1;
      s2.queue = [];
      s2.playing = true;
      s2.volumeSupported = device.volumeSupported();
      s2.message = `已投送到「${device.name}」`;
      this.commit(s2);
      this.refreshVolume();
      this.startMonitor(device);
    }).catch((e: Error): void => {
      const s2: CastState = this.state.copy();
      s2.busy = false;
      s2.message = `投送失败：${e.message.length > 0 ? e.message : '设备没响应'}`;
      this.commit(s2);
    });
  }

  /** 下一首（按播放模式：列表循环回开头、随机抽一首、顺序到尾就停） */
  next(): void {
    const current: CastState = this.state;
    if (!current.casting()) {
      return;
    }
    const target: number | null = this.nextIndex(current.index, current.queue.length, true);
    if (target === null) {
      this.stopCasting();
      return;
    }
    this.push(target);
  }

  previous(): void {
    const current: CastState = this.state;
    if (!current.casting() || !current.hasPrevious()) {
      return;
    }
    this.push(current.index - 1);
  }

  togglePause(): void {
    const current: CastState = this.state;
    const device: DlnaDevice | null = current.active;
    if (device === null) {
      return;
    }
    const resume: boolean = !current.playing;
    const op: Promise<void> = resume ? DlnaClient.resume(device) : DlnaClient.pause(device);
    op.then((): void => {
      const s: CastState = this.state.copy();
      s.playing = resume;
      this.commit(s);
    }).catch((_e: Error): void => {
      // 部分音箱 Pause 会报 701，状态以轮询为准
    });
  }

  /** 拖动进度条：DLNA 的 Seek 用 REL_TIME（绝对时间点） */
  seekTo(positionMs: number): void {
    const current: CastState = this.state;
    const device: DlnaDevice | null = current.active;
    if (device === null) {
      return;
    }
    const target: number = Math.max(0, Math.trunc(positionMs));
    const s: CastState = current.copy();
    s.positionMs = target;
    this.commit(s);
    DlnaClient.seek(device, target).catch((_e: Error): void => {
      const s2: CastState = this.state.copy();
      s2.message = '这台音箱不支持拖动进度';
      this.commit(s2);
    });
  }

  /** 调音箱音量（0..100） */
  setVolume(percent: number): void {
    const current: CastState = this.state;
    const device: DlnaDevice | null = current.active;
    if (device === null) {
      return;
    }
    if (!device.volumeSupported()) {
      const s: CastState = current.copy();
      s.message = '这台设备不支持 App 调音量，用音箱自己的旋钮';
      this.commit(s);
      return;
    }
    const value: number = Math.max(0, Math.min(100, Math.trunc(percent)));
    const s: CastState = current.copy();
    s.volume = value;
    this.commit(s);
    // 拖动滑块会连续触发，防抖一下再真的发 SOAP，不然音箱会被刷爆
    if (this.volumeTimer >= 0) {
      clearTimeout(this.volumeTimer);
    }
    this.volumeTimer = setTimeout((): void => {
      this.volumeTimer = -1;
      DlnaClient.setVolume(device, value).catch((e: Error): void => {
        const s2: CastState = this.state.copy();
        s2.message = `调音量失败：${e.message}`;
        this.commit(s2);
      });
    }, 120);
  }

  refreshVolume(): void {
    const current: CastState = this.state;
    const device: DlnaDevice | null = current.active;
    if (device === null) {
      return;
    }
    if (!device.volumeSupported()) {
      const s: CastState = current.copy();
      s.volume = -1;
      s.volumeSupported = false;
      this.commit(s);
      return;
    }
    DlnaClient.getVolume(device).then((value: number): void => {
      if (value >= 0) {
        const s: CastState = this.state.copy();
        s.volume = value;
        s.volumeSupported = true;
        this.commit(s);
      }
    });
  }

  stopCasting(): void {
    const device: DlnaDevice | null = this.state.active;
    if (device === null) {
      return;
    }
    this.monitorGen++;
    this.lastPushedUrl = '';
    this.lastLocalDurationMs = 0;
    const s: CastState = this.state.copy();
    s.busy = true;
    this.commit(s);
    DlnaClient.stop(device).catch((_e: Error): void => {
      // 停不下来也照常退出投送态
    }).then((): void => {
      const devices: DlnaDevice[] = this.state.devices;
      BackgroundAudioManager.stop();
      const fresh: CastState = new CastState();
      fresh.scanned = true;
      fresh.devices = devices;
      fresh.message = '已停止投送';
      this.commit(fresh);
    });
  }

  clearMessage(): void {
    if (this.state.message !== null) {
      const s: CastState = this.state.copy();
      s.message = null;
      this.commit(s);
    }
  }

  // ---------------------------------------------------------------- 内部

  /**
   * 投送前探测流地址：GET 第一字节（Range: bytes=0-0），不下载内容。
   * 返回 null = 服务端正常给流；返回字符串 = 给用户看的失败原因。
   */
  private async probeStream(url: string): Promise<string | null> {
    const headers: Record<string, string> = { 'Range': 'bytes=0-0' };
    let code: number = 0;
    let netMsg: string = '';
    try {
      const reply = await get(url, headers, TimeoutTier.PROBE);
      code = reply.code;
    } catch (err) {
      const e: Error = err as Error;
      netMsg = e.message;
    }
    if (code === 0) {
      return `连不上音乐服务：${netMsg.length > 0 ? netMsg : '网络错误'}`;
    }
    if (code >= 200 && code < 300) {
      return null;
    }
    if (code === 401) {
      return '登录已过期（401），去设置里重新保存一次「音乐服务」';
    }
    if (code === 404) {
      return '服务端取流失败（404）：曲库里的文件路径失效了，重新扫一次盘';
    }
    if (code === 500) {
      return '服务端取流失败（500）：多半是 CUE 分轨指向的整轨文件丢了';
    }
    return `服务端取流失败（HTTP ${code}）`;
  }

  /**
   * 还原 XML 转义用 DlnaClient.unescapeXml（&amp; 最后替换，避免二次还原）。
   * 比较流地址时忽略 query 串：access_token / 时间戳每次可能不同，只看路径本身。
   */
  private static stripQuery(s: string): string {
    const q: number = s.indexOf('?');
    return q >= 0 ? s.substring(0, q) : s;
  }

  private async push(index: number): Promise<void> {
    const current: CastState = this.state;
    const device: DlnaDevice | null = current.active;
    if (device === null || index < 0 || index >= current.queue.length) {
      return;
    }
    const song: MusicSong = current.queue[index];
    const url: string = this.urlFor(song);
    if (url.trim().length === 0) {
      const s: CastState = current.copy();
      s.message = `「${song.title}」没有可播放地址`;
      this.commit(s);
      return;
    }
    // 投送前先探一下流地址：手机能打开列表不代表服务端真给得出音频
    //（fnOS 重装/挪盘后路径失效 → 404；CUE 分轨的 FILE 指向丢了 → 500）。
    // 不探的话音箱收下 URL 后静音装播，App 这边只会看到假进度。
    const probeFail: string | null = await this.probeStream(url);
    if (probeFail !== null) {
      this.lastFailIndex = index;
      this.lastFailAt = Date.now();
      logWarn('DLNA-Cast', `probe(${song.title}) ${probeFail}`);
      const s: CastState = this.state.copy();
      s.playing = false;
      s.message = `投送「${song.title}」失败：${probeFail}`;
      this.commit(s);
      return;
    }
    this.pushing = true;
    try {
      await DlnaClient.play(device, url, song.title, this.mimeFor(song));
    } catch (err) {
      const e: Error = err as Error;
      this.lastFailIndex = index;
      this.lastFailAt = Date.now();
      logWarn('DLNA-Cast', `push(${song.title}) 失败: ${e.message}`);
      const s: CastState = this.state.copy();
      s.playing = false;
      s.message = `投送「${song.title}」失败：${e.message.length > 0 ? e.message : '设备没响应'}`;
      this.commit(s);
      this.pushing = false;
      return;
    }
    this.pushing = false;
    this.lastPushAt = Date.now();
    this.lastPushedUrl = url;
    this.lastLocalDurationMs = song.durationSeconds * 1000;
    this.lastFailIndex = -1;
    // 落盘：投送成功的动作也要有记录，「推了没」是排查连播的核心线索
    logWarn('DLNA-Cast',
      `push 成功 #${index} 共${current.queue.length}首 《${song.title}》 url=${CastController.stripQuery(url)}`);
    const s2: CastState = this.state.copy();
    s2.index = index;
    s2.title = song.title;
    s2.playing = true;
    s2.positionMs = 0;
    s2.durationMs = song.durationSeconds * 1000;
    s2.message = `正在播放「${song.title}」`;
    this.commit(s2);
  }

  /**
   * 轮询音箱状态做连播。
   *
   * 每 2.5 秒真的问一次音箱（GetTransportInfo + GetPositionInfo），中间每 0.5 秒本地推进进度条。
   * 三种「这首放完了」的判定，任何一种命中就推下一首：
   *  1. 状态从 PLAYING 掉到 STOPPED / NO_MEDIA_PRESENT；
   *  2. 进度走到接近总时长且停住（部分音箱放完仍报 PLAYING）；
   *  3. 位置连续不动且已到结尾。
   * 用户手动暂停（PAUSED_PLAYBACK）不触发下一首。
   */
  private startMonitor(device: DlnaDevice): void {
    this.monitorGen++;
    const gen: number = this.monitorGen;
    let seenPlaying: boolean = false;
    let tick: number = 0;
    let lastPosition: number = -1;
    let stalled: number = 0;
    // 兜底：音箱报 PLAYING 但 pos=0、dur=0，说明它根本没拉到流
    //（假进度就是这么来的）。连续 6 次（约 15 秒）还在装播就提示。
    let silentStall: number = 0;

    const loop = async (): Promise<void> => {
      while (gen === this.monitorGen) {
        await CastController.sleep(CastController.TICK_MS);
        tick++;

        // 心跳：每 30 秒落一行。锁屏后如果这条彻底断掉，就说明 JS 定时器
        // 被系统挂起了（投送时手机没有音频输出，进程更容易被冻结）；
        // 如果它还在走，问题就在下面的判定/推流逻辑里。
        if (tick % 60 === 0) {
          const hb: CastState = this.state;
          logWarn('DLNA-Cast',
            `monitor 心跳 tick=${tick} playing=${hb.playing} pos=${hb.positionMs}/${hb.durationMs} idx=${hb.index} queue=${hb.queue.length}`);
        }

        const snapshot: CastState = this.state;
        if (!snapshot.casting() || this.pushing) {
          continue;
        }

        // 进度条平滑推进（真值在下面每 2.5 秒校准一次）
        if (snapshot.playing && snapshot.durationMs > 0 && snapshot.positionMs < snapshot.durationMs) {
          const s: CastState = snapshot.copy();
          s.positionMs = Math.min(snapshot.positionMs + CastController.TICK_MS, snapshot.durationMs);
          this.commit(s);
        }

        if (tick % CastController.POLL_TICKS !== 0) {
          continue;
        }

        let info: DlnaTransport | null = null;
        try {
          info = await DlnaClient.transport(device);
        } catch (err) {
          info = null;
        }
        if (info === null) {
          if (tick % 60 === 0) {
            logWarn('DLNA-Cast', 'monitor: 取音箱状态失败（transport 返回空）');
          }
          continue;
        }

        // —— 播放权校验：音箱现在放的还是不是我们推的流？——
        // 用户可能对小爱音箱语音点歌（走音箱自己的通道），这时音箱状态照样报
        // PLAYING，但 CurrentURI 已经不是我们的了。不校验的话，状态翻转会被
        // 误判成「我们这首放完了」，自动把队列下一首推过去抢掉用户点的歌。
        let speakerUri: string = '';
        try {
          speakerUri = await DlnaClient.mediaUri(device);
        } catch (err) {
          speakerUri = '';
        }
        let mine: boolean | null;
        if (speakerUri.length === 0) {
          // 拿不到 URI（接口失败/空串）：无法判断，走下面的时长兜底
          mine = null;
        } else {
          mine = CastController.stripQuery(DlnaClient.unescapeXml(speakerUri)) ===
            CastController.stripQuery(this.lastPushedUrl);
        }
        // 兜底：部分音箱不回报 CurrentURI，改用时长差异判断 ——
        // 音箱报的时长和本地这首（lastLocalDurationMs，不受音箱校准污染）
        // 对不上（差 3 秒以上）就当是别人在放。
        if (mine === null && info.durationMs > 0 && this.lastLocalDurationMs > 0 &&
          Math.abs(info.durationMs - this.lastLocalDurationMs) > 3000) {
          mine = false;
        }

        // 确认音箱在放别人的内容：停掉轮询，绝不再自动推下一首去抢；
        // playing=false 同时让本地假进度停下。
        // 刚推流 6 秒内音箱可能还报着旧 URI，别误杀。
        if (mine === false && Date.now() - this.lastPushAt > 6000) {
          this.monitorGen++;
          logWarn('DLNA-Cast',
            `音箱在放别的内容 → 停止连播。speaker=${CastController.stripQuery(DlnaClient.unescapeXml(speakerUri))} mine=${CastController.stripQuery(this.lastPushedUrl)}`);
          const s: CastState = this.state.copy();
          s.playing = false;
          s.message = '音箱正在播放其他内容（语音点歌或别的设备接管），已暂停连播';
          this.commit(s);
          return;
        }

        // 每 30 秒记一次真实状态：state/pos/dur/mine 是判断连播为何不继续的四要素
        if (tick % 60 === 0) {
          logWarn('DLNA-Cast',
            `monitor poll state=${info.state} pos=${info.positionMs} dur=${info.durationMs} mine=${mine === null ? '未知' : mine} seenPlaying=${seenPlaying}`);
        }

        const state: string = info.state.toUpperCase();
        let finished: boolean = false;

        if (state.startsWith('PLAYING') || state === 'TRANSITIONING') {
          seenPlaying = true;
        } else if (state.startsWith('PAUSED')) {
          seenPlaying = false;
        } else if (state.startsWith('STOPPED') || state === 'NO_MEDIA_PRESENT') {
          if (seenPlaying) {
            seenPlaying = false;
            finished = true;
          }
        }

        // 位置校准：音箱报的比本地准，直接覆盖
        const cur: CastState = this.state;
        const position: number = info.positionMs > 0 ? info.positionMs : cur.positionMs;
        const duration: number = info.durationMs > 0 ? info.durationMs : cur.durationMs;
        if (position !== lastPosition) {
          stalled = 0;
        } else {
          stalled++;
        }
        lastPosition = position;

        if (!finished && duration > 0 && position > 0 && position >= duration - 1200 && stalled >= 1) {
          finished = true;
        }
        if (finished) {
          logWarn('DLNA-Cast',
            `判定这首播完 state=${info.state} pos=${position} dur=${duration} stalled=${stalled}`);
        }

        // 假播放侦测：PLAYING 但没进度没时长，排除刚推流的几秒后连续 15 秒 → 提示
        if (state.startsWith('PLAYING') && position <= 0 && duration <= 0 &&
          Date.now() - this.lastPushAt > 6000) {
          silentStall++;
          if (silentStall === 6) {
            const s: CastState = this.state.copy();
            s.playing = false;
            s.message = '音箱一直没拉到流（无进度无时长），可能是格式不支持或曲库文件有问题';
            this.commit(s);
          }
        } else {
          silentStall = 0;
        }

        // 刚推完流的那几秒，音箱可能还停留在上一首的 STOPPED，别当成「放完了」
        if (finished && Date.now() - this.lastPushAt < 4000) {
          finished = false;
        }

        const s2: CastState = cur.copy();
        s2.positionMs = position;
        s2.durationMs = duration;
        if (state.startsWith('PAUSED')) {
          s2.playing = false;
        } else if (state.startsWith('PLAYING') || state === 'TRANSITIONING') {
          s2.playing = true;
        }
        this.commit(s2);

        if (!finished) {
          continue;
        }

        const s3: CastState = this.state;
        // 同一首刚推失败过：别再自动重试，否则会「失败 → 判完成 → 再推」无限循环
        if (this.lastFailIndex === s3.index && Date.now() - this.lastFailAt < 15000) {
          const s4: CastState = s3.copy();
          s4.playing = false;
          this.commit(s4);
          continue;
        }
        // 保险：播放权校验没拦住（6 秒窗口期）但音箱确实不在放我们的流，
        // 只跳过这次 push（state 不动、监控不杀），等窗口过后由上面的主校验裁决
        if (mine === false) {
          continue;
        }
        if (s3.queue.length === 0) {
          continue;
        }
        const target: number | null = this.nextIndex(s3.index, s3.queue.length, false);
        if (target === null) {
          const s5: CastState = s3.copy();
          s5.playing = false;
          s5.message = '整张列表已投送完毕';
          this.commit(s5);
        } else {
          logWarn('DLNA-Cast', `播完 → 推下一首 #${target}（当前 #${s3.index}）`);
          await this.push(target);
        }
      }
    };
    loop();
  }
}
