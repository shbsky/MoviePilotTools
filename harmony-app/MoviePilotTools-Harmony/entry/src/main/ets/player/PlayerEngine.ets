import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MusicSong, PlaybackState } from '../model/MusicModels';
import { ObservableStore } from '../vm/StoreBase';
import { logError, logInfo, logSeek, logWarn } from '../common/AppConstants';
import { BackgroundAudioManager } from './BackgroundAudioManager';

/**
 * 音乐播放引擎（对应安卓 player/MusicPlayer.kt + MusicEngine，内核换成 AVPlayer）。
 *
 * 进程级单例：切标签页/页面重建都复用同一个实例，播放不断。
 * 队列/循环模式/进度由这里管；Songloft 相对地址由 urlResolver 补成带 token 的绝对地址。
 * 播放模式四档：0 顺序（列表结束即停）、1 单曲循环、2 列表循环、3 随机。
 */
export class PlayerEngine extends ObservableStore {
  private static inst: PlayerEngine | null = null;

  static getInstance(): PlayerEngine {
    if (PlayerEngine.inst === null) {
      PlayerEngine.inst = new PlayerEngine();
    }
    return PlayerEngine.inst;
  }

  state: PlaybackState = new PlaybackState();
  /** 由 ViewModel 注入：把相对地址补成带 token 的绝对地址 */
  urlResolver: (song: MusicSong) => string = (song: MusicSong): string => song.streamUrl;
  /** 由 ViewModel 注入：起播前刷新登录态（token 过期自动重登），避免流地址 401 */
  prepareLoad: () => Promise<void> = (): Promise<void> => new Promise<void>((resolve: () => void) => {
    resolve();
  });

  private queue: MusicSong[] = [];
  private index: number = 0;
  private avp: media.AVPlayer | null = null;
  private ticker: number = -1;
  private loadGen: number = 0;
  /** 当前正在装载的代号：状态回调里用它判断事件属于哪次装载 */
  private pendingGen: number = 0;
  /** seek 目标锚点（ms）：seek 缓冲期间进度显示锚在这里，播放位置追上后解除 */
  private pendingSeekMs: number = -1;
  /** seek 发起时刻：锚点超过 2 秒没被追上就放弃（seek 实际没生效 → 走硬 seek） */
  private pendingSeekAt: number = 0;
  /** 装载后要先跳到的位置（-1 = 正常从头播）：硬 seek / 断点续播用 */
  private startAtMs: number = -1;
  /** prepared 后等 seekDone 的超时定时器 */
  private seekWaitTimer: number = -1;
  /** 最近一次用户主动 seek 的目标与时刻：用于识别「seek 后异常立刻 completed」 */
  private lastSeekTargetMs: number = -1;
  private lastSeekAt: number = 0;
  /** completed 是否已处理：stateChange 回调与 ticker 兜底可能重复触发，只认第一次 */
  private completedHandled: boolean = false;
  /** ticker 连续命中「已经到尾部」的次数，满 2 次（约 1 秒）才判定播完 */
  private endHits: number = 0;
  /**
   * 上一次收尾判定的播放位置：用来识别「贴到尾部后进度不再前进」。
   * 播放器内部跑到 EOF 时 currentTime 可能被重置成 0，光看「进度是否贴尾」
   * 会漏判 —— 这是之前锁屏播完停住没被抓到的原因之一。
   */
  private lastTickPosMs: number = -1;

  private constructor() {
    super();
  }

  private commit(s: PlaybackState): void {
    this.state = s;
    this.notify();
  }

  private async ensurePlayer(): Promise<media.AVPlayer | null> {
    // 每次装载都用全新实例：AVPlayer 出过错误会掉 idle 态，老实例 reset→url→prepare
    // 存在竞态（reset 异步落地时 url 赋值被吞，prepare 报「state is idle」），复用不可靠
    const old: media.AVPlayer | null = this.avp;
    this.avp = null;
    if (old !== null) {
      try {
        await old.release();
      } catch (err) {
        // 老实例可能已释放，忽略
      }
    }
    try {
      const avp: media.AVPlayer = await media.createAVPlayer();
      avp.on('stateChange', (state: media.AVPlayerState): void => {
        // 只处理当前实例的回调，老实例的迟到的 released 事件不认
        if (this.avp !== avp) {
          return;
        }
        this.onStateChange(avp, state);
      });
      avp.on('error', (err: BusinessError): void => {
        if (this.avp !== avp) {
          return;
        }
        logError('PlayerEngine', `avplayer error: ${err.code} ${err.message}`);
        this.fail(this.describeError(err.code, err.message));
      });
      // 音频焦点中断：不注册这个监听时，系统会自己把 AVPlayer 暂停（锁屏、来电、
      // 系统提示音、别的 App 抢焦点都会触发），App 完全不知情 —— 表现就是
      // 「放着放着就停了」。这里接管：中断来时同步成暂停态，中断结束要求恢复就续播。
      avp.on('audioInterrupt', (info: audio.InterruptEvent): void => {
        if (this.avp !== avp) {
          return;
        }
        const hint: audio.InterruptHint = info.hintType;
        logWarn('PlayerEngine',
          `audioInterrupt event=${info.eventType} hint=${hint} force=${info.forceType}`);
        if (info.eventType === audio.InterruptType.INTERRUPT_TYPE_BEGIN) {
          if (hint === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
            hint === audio.InterruptHint.INTERRUPT_HINT_STOP) {
            this.stopTicker();
            const s0: PlaybackState = this.state.copy();
            s0.isPlaying = false;
            this.commit(s0);
          }
        } else if (info.eventType === audio.InterruptType.INTERRUPT_TYPE_END &&
          hint === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
          logWarn('PlayerEngine', '音频焦点恢复，自动续播');
          avp.play().catch((err: BusinessError): void => {
            logWarn('PlayerEngine', `恢复播放失败: ${err.message}`);
          });
        }
      });
      // 进度心跳（播放器 native 定时器触发）：锁屏/后台时 JS 的 setInterval 可能
      // 被挂起，这条事件仍然会到。用它做「播完没切歌」的第二道收尾判定。
      avp.on('timeUpdate', (timeMs: number): void => {
        if (this.avp !== avp) {
          return;
        }
        if (this.pendingSeekMs >= 0 || this.completedHandled) {
          return;
        }
        const dur: number = avp.duration > 0 ? avp.duration : this.state.durationMs;
        this.checkEnd(avp, timeMs, dur);
      });
      // seek 生效的唯一可信信号：系统在 seek 完成时回调
      avp.on('seekDone', (timeMs: number): void => {
        if (this.avp !== avp) {
          return;
        }
        logInfo('PlayerEngine', `seekDone -> ${timeMs}ms`);
        logSeek(`seekDone -> ${timeMs}`);
        this.clearSeekWait();
        this.pendingSeekMs = -1;
        this.pendingSeekAt = 0;
        const s: PlaybackState = this.state.copy();
        s.positionMs = timeMs;
        this.commit(s);
        if (this.startAtMs >= 0) {
          // 硬 seek：到位后再起播
          this.startAtMs = -1;
          avp.play().catch((err: BusinessError): void => {
            if (this.avp === avp) {
              this.fail(this.describeError(err.code, err.message));
            }
          });
        }
      });
      this.avp = avp;
      logInfo('PlayerEngine', 'AVPlayer 已创建');
      return avp;
    } catch (err) {
      logError('PlayerEngine', `createAVPlayer 失败: ${err}`);
      return null;
    }
  }

  /**
   * 官方事件驱动模式：url 赋值（idle→initialized）→ initialized 回调里 prepare →
   * prepared 回调里 play。直接在赋值后立刻调 prepare 会撞上状态机异步竞态
   * （报「The current state is idle. Prepare operation only supports stopped/initialized」）。
   */
  private onStateChange(avp: media.AVPlayer, state: media.AVPlayerState): void {
    const gen: number = this.pendingGen;
    // 落盘（logInfo 在 release 包不进文件）：排查「播完不切歌」时，
    // 首先要知道 completed 到底有没有投递过来
    if (state === 'completed' || state === 'stopped' || state === 'error' ||
      state === 'paused' || state === 'playing') {
      logWarn('PlayerEngine',
        `stateChange=${state} gen=${gen}/${this.loadGen} pos=${this.state.positionMs} dur=${this.state.durationMs}`);
    }
    if (state === 'initialized') {
      if (gen !== this.loadGen) {
        return;
      }
      avp.prepare().catch((err: BusinessError): void => {
        if (gen === this.loadGen) {
          this.fail(this.describeError(err.code, err.message));
        }
      });
    } else if (state === 'prepared') {
      if (gen !== this.loadGen) {
        return;
      }
      const song: MusicSong | null = this.queue.length > 0 ? this.queue[this.index] : null;
      const s: PlaybackState = this.state.copy();
      s.durationMs = avp.duration > 0 ? avp.duration : (song !== null ? song.durationSeconds * 1000 : 0);
      this.commit(s);
      if (this.startAtMs > 0) {
        // 硬 seek：prepared 态先跳到目标位置，等 seekDone 回调再起播
        const target: number = this.startAtMs;
        logInfo('PlayerEngine', `prepared → 硬 seek ${target}ms`);
        logSeek(`prepared → 硬 seek ${Math.trunc(target)}`);
        try {
          avp.seek(Math.trunc(target));
        } catch (err) {
          this.startAtMs = -1;
          this.playNow(avp, gen);
          return;
        }
        this.clearSeekWait();
        // 兜底：seekDone 迟迟不来就直接从头播，避免卡住不出声
        this.seekWaitTimer = setTimeout((): void => {
          this.seekWaitTimer = -1;
          if (this.avp === avp && this.startAtMs >= 0) {
            logWarn('PlayerEngine', '硬 seek 超时，改为从头播放');
            logSeek('硬 seek 超时（无 seekDone），从头播放');
            this.startAtMs = -1;
            this.playNow(avp, gen);
          }
        }, 2500);
        return;
      }
      this.playNow(avp, gen);
    } else if (state === 'playing') {
      const s: PlaybackState = this.state.copy();
      s.isPlaying = true;
      s.error = null;
      this.commit(s);
      this.startTicker();
      // 息屏/切后台继续播：申请 AUDIO_PLAYBACK 长时任务
      BackgroundAudioManager.start();
    } else if (state === 'paused') {
      const s: PlaybackState = this.state.copy();
      s.isPlaying = false;
      this.commit(s);
      this.stopTicker();
    } else if (state === 'completed') {
      this.onCompleted();
    } else if (state === 'stopped' || state === 'released') {
      const s: PlaybackState = this.state.copy();
      s.isPlaying = false;
      this.commit(s);
      this.stopTicker();
    }
  }

  private onCompleted(): void {
    if (this.completedHandled) {
      return;
    }
    this.completedHandled = true;
    this.endHits = 0;
    this.lastTickPosMs = -1;
    // 用 logWarn 而不是 logInfo：release 包的 logInfo 不写文件，排查
    // 「播完不切下一首」只能靠这条落盘日志，带上队列长度与当前索引
    logWarn('PlayerEngine',
      `completed: pos=${this.state.positionMs} stateDur=${this.state.durationMs} repeat=${this.state.repeatMode} queue=${this.queue.length} index=${this.index}`);
    logSeek(`completed pos=${this.state.positionMs} dur=${this.state.durationMs}`);
    // 兜底：刚 seek 完就报 completed，且目标离结尾还远 → 是播放器内部跳到了 EOF，
    // 不是真的播完。回到 seek 目标继续播，不要切下一首。
    const dur: number = this.state.durationMs;
    if (this.lastSeekTargetMs >= 0 && Date.now() - this.lastSeekAt < 1500 &&
      dur > 5000 && this.lastSeekTargetMs < dur - 3000) {
      const back: number = this.lastSeekTargetMs;
      const avp0: media.AVPlayer | null = this.avp;
      logWarn('PlayerEngine', `seek 后误报 completed，回到 ${back}ms 继续播`);
      logSeek(`completed 误判 → 回到 ${back}ms`);
      this.lastSeekTargetMs = -1;
      this.lastSeekAt = 0;
      this.pendingSeekMs = back;
      this.pendingSeekAt = Date.now();
      const st: PlaybackState = this.state.copy();
      st.positionMs = back;
      this.commit(st);
      if (avp0 !== null) {
        try {
          avp0.seek(Math.trunc(back));
          avp0.play();
          this.startTicker();
        } catch (err) {
          // 忽略
        }
      }
      // 还要继续播，解锁身份，允许下一次真正播完时再判定
      this.completedHandled = false;
      return;
    }
    this.lastSeekTargetMs = -1;
    this.lastSeekAt = 0;
    this.stopTicker();
    if (this.state.repeatMode === 1 && this.state.current !== null) {
      // 单曲循环：回到开头重播
      const avp: media.AVPlayer | null = this.avp;
      if (avp !== null) {
        try {
          avp.seek(0);
          avp.play();
        } catch (err) {
          // 忽略
        }
      }
      // ticker 在进来时已经停了；播放器从 completed 回到 playing 不一定会再发
      // stateChange 事件，进度条会从此不动，所以这里必须主动重启
      this.startTicker();
      this.completedHandled = false;
      return;
    }
    this.next(true);
  }

  // ------------------------------------------------------------ 对外操作

  async play(list: MusicSong[], startIndex: number): Promise<void> {
    if (list.length === 0) {
      return;
    }
    // 注意：这里会过滤掉没有地址的曲目，队列必须跟着**一起过滤**，否则索引错位
    const playable: MusicSong[] = [];
    for (const song of list) {
      if (this.urlResolver(song).length > 0) {
        playable.push(song);
      }
    }
    if (playable.length === 0) {
      this.fail('这些歌都没有可播放地址');
      return;
    }
    const startSong: MusicSong = list[Math.min(Math.max(startIndex, 0), list.length - 1)];
    this.queue = playable;
    let index: number = 0;
    for (let i = 0; i < playable.length; i++) {
      if (playable[i].id === startSong.id) {
        index = i;
        break;
      }
    }
    // 起播前就把 AVSession 建好：媒体卡（锁屏/控制中心/灵动胶囊）不用等首帧出声
    BackgroundAudioManager.start();
    await this.loadAt(index);
  }

  async toggle(): Promise<void> {
    const avp: media.AVPlayer | null = this.avp;
    if (avp === null) {
      // 播放器被系统回收后重新起播
      if (this.queue.length > 0) {
        await this.loadAt(this.index);
      }
      return;
    }
    // 上一首失败留下的错误态：播放器内部可能已 idle，直接重装载（地址重算、token 刷新）
    if (this.state.error !== null && this.state.error !== '') {
      if (this.queue.length > 0) {
        await this.loadAt(this.index);
      }
      return;
    }
    try {
      if (this.state.isPlaying) {
        await avp.pause();
      } else {
        await avp.play();
      }
    } catch (err) {
      // play() 抛异常多半是播放器处于错误态（上一首拉流失败/token 过期留下来的），
      // 重新装载当前曲（地址会重算、token 会刷新），而不是只弹「播放操作失败」
      if (this.queue.length > 0) {
        await this.loadAt(this.index);
      } else {
        this.fail('播放操作失败');
      }
    }
  }

  /** 播放模式四档循环：顺序 → 单曲循环 → 列表循环 → 随机 → 顺序。返回新模式 */
  cycleRepeatMode(): number {
    const next: number = (Math.min(Math.max(this.state.repeatMode, 0), 3) + 1) % 4;
    const s: PlaybackState = this.state.copy();
    s.repeatMode = next;
    this.commit(s);
    return next;
  }

  async resume(): Promise<void> {
    const avp: media.AVPlayer | null = this.avp;
    if (avp === null) {
      if (this.queue.length > 0) {
        await this.loadAt(this.index);
      }
      return;
    }
    try {
      await avp.play();
      this.startTicker();
    } catch (err) {
      // 忽略
    }
  }

  /** 当前队列快照：投送时用同一份队列，保证音箱连播顺序和本机听到的一致 */
  getQueue(): MusicSong[] {
    return this.queue.slice(0);
  }

  async pause(): Promise<void> {
    // 落盘：排查「自己停了」时要能区分是用户/媒体卡按的，还是系统掐的
    logWarn('PlayerEngine',
      `pause() 被调用 isPlaying=${this.state.isPlaying} pos=${this.state.positionMs}`);
    const avp: media.AVPlayer | null = this.avp;
    if (avp !== null) {
      try {
        await avp.pause();
      } catch (err) {
        // 忽略
      }
    }
    this.stopTicker();
    const s: PlaybackState = this.state.copy();
    s.isPlaying = false;
    this.commit(s);
  }

  async next(auto: boolean = false): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    let target: number = -1;
    if (this.state.repeatMode === 3) {
      // 随机：换一首（单首队列除外）
      target = this.queue.length === 1 ? 0 : this.randomOther(this.index);
    } else if (this.index + 1 < this.queue.length) {
      target = this.index + 1;
    } else if (this.state.repeatMode === 2) {
      target = 0;
    } else {
      // 顺序模式：播完最后一首就停在结尾，不循环
      this.stopTicker();
      const s: PlaybackState = this.state.copy();
      s.isPlaying = false;
      if (auto) {
        s.positionMs = s.durationMs;
      }
      this.commit(s);
      return;
    }
    await this.loadAt(target);
  }

  async previous(): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    // 播放超过 3 秒，上一首先回到开头（跟主流播放器一致）
    if (this.state.positionMs > 3000) {
      await this.seekTo(0);
      return;
    }
    if (this.index > 0) {
      await this.loadAt(this.index - 1);
    } else {
      await this.seekTo(0);
    }
  }

  async seekTo(positionMs: number): Promise<void> {
    const avp: media.AVPlayer | null = this.avp;
    if (avp === null) {
      return;
    }
    // 钳制基准优先用播放器自己的真实时长：prepared 阶段流时长可能还没出来，
    // state.durationMs 此时是曲库元数据兜底值——若元数据偏大，拖到后段的目标
    // 会超过真实流长度，AVPlayer 内部钳到 EOF → 立刻 completed → 表现为「拖到后面直接切下一首」
    let realDuration: number = 0;
    try {
      realDuration = avp.duration;
    } catch (err) {
      // 忽略
    }
    const refDuration: number = realDuration > 0 ? realDuration : this.state.durationMs;
    const maxTarget: number = refDuration > 1500 ? refDuration - 1000 : Math.max(refDuration, 0);
    const target: number = Math.min(Math.max(positionMs, 0), maxTarget);
    logInfo('PlayerEngine', `seek -> ${Math.trunc(target)}ms (real=${realDuration} state=${this.state.durationMs})`);
    logSeek(`seek 请求 target=${Math.trunc(target)} real=${realDuration} state=${this.state.durationMs} cur=${this.state.positionMs}`);
    try {
      avp.seek(Math.trunc(target));
      this.lastSeekTargetMs = target;
      this.lastSeekAt = Date.now();
      // seek 后到缓冲生效前，进度显示锚定目标位置，避免 ticker 把滑块拉回旧位置
      this.pendingSeekMs = target;
      this.pendingSeekAt = Date.now();
      const s: PlaybackState = this.state.copy();
      s.positionMs = target;
      if (realDuration > 0 && Math.abs(realDuration - this.state.durationMs) > 500) {
        // 顺手把滑块刻度校正成真实时长
        s.durationMs = realDuration;
      }
      this.commit(s);
    } catch (err) {
      // 忽略
    }
  }

  /** 本机播放音量（0..1），作用于 AVPlayer 软件音量 */
  setVolume(value: number): void {
    const volume: number = Math.min(Math.max(value, 0), 1);
    const avp: media.AVPlayer | null = this.avp;
    if (avp !== null) {
      try {
        avp.setVolume(volume);
      } catch (err) {
        // 忽略
      }
    }
    const s: PlaybackState = this.state.copy();
    s.volume = volume;
    this.commit(s);
  }

  stop(): void {
    this.stopTicker();
    const avp: media.AVPlayer | null = this.avp;
    if (avp !== null) {
      try {
        avp.release();
      } catch (err) {
        // 忽略
      }
      this.avp = null;
    }
    this.queue = [];
    this.index = 0;
    BackgroundAudioManager.stop();
    // 播放模式是用户偏好，退出播放不该把它重置回「顺序」
    const s: PlaybackState = new PlaybackState();
    s.volume = this.state.volume;
    s.repeatMode = this.state.repeatMode;
    this.commit(s);
  }

  /** 页面销毁时调用：只停进度轮询，不释放播放器（App 级单例继续用） */
  detach(): void {
    this.stopTicker();
  }

  // ------------------------------------------------------------ 内部实现

  private async loadAt(index: number, startAtMs: number = -1): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    // 新的一首开始装载：解锁 completed 判定，清掉尾部命中计数与位置记忆
    this.completedHandled = false;
    this.endHits = 0;
    this.lastTickPosMs = -1;
    const target: number = Math.min(Math.max(index, 0), this.queue.length - 1);
    const song: MusicSong = this.queue[target];
    // 先刷新登录态再拼地址：token 过期时旧地址必 401
    await this.prepareLoad();
    const url: string = this.urlResolver(song);
    if (url.length === 0) {
      this.fail('没有可播放地址');
      return;
    }
    this.index = target;
    this.loadGen++;
    this.pendingSeekMs = -1;
    this.pendingSeekAt = 0;
    this.lastSeekTargetMs = -1;
    this.lastSeekAt = 0;
    this.startAtMs = startAtMs;
    this.clearSeekWait();
    const gen: number = this.loadGen;

    const s: PlaybackState = this.state.copy();
    s.current = song;
    s.positionMs = 0;
    s.durationMs = song.durationSeconds * 1000;
    s.hasPrevious = target > 0;
    s.hasNext = target < this.queue.length - 1;
    s.error = null;
    this.commit(s);

    const avp: media.AVPlayer | null = await this.ensurePlayer();
    if (avp === null) {
      this.fail('播放器初始化失败');
      return;
    }
    if (gen !== this.loadGen) {
      return;
    }
    this.pendingGen = gen;
    logInfo('PlayerEngine', `load: ${this.maskUrl(url)}`);
    logSeek(`load #${gen} startAt=${this.startAtMs} url=${this.maskUrl(url)}`);
    try {
      // 只赋 url：prepare/play 在 initialized/prepared 状态回调里接续（见 onStateChange）
      avp.url = url;
    } catch (err) {
      if (gen === this.loadGen) {
        this.fail('播放地址无效，检查服务器地址设置');
      }
    }
  }

  /** 日志里隐藏 token，避免泄露 */
  private maskUrl(url: string): string {
    return url.replace(/([?&])token=[^&]*/, '$1token=***');
  }

  /** 起播（带错误上报，gen 过期则忽略） */
  private playNow(avp: media.AVPlayer, gen: number): void {
    avp.play().catch((err: BusinessError): void => {
      if (gen === this.loadGen) {
        this.fail(this.describeError(err.code, err.message));
      }
    });
  }

  private clearSeekWait(): void {
    if (this.seekWaitTimer >= 0) {
      clearTimeout(this.seekWaitTimer);
      this.seekWaitTimer = -1;
    }
  }

  private randomOther(current: number): number {
    let pick: number = current;
    for (let i = 0; i < 8 && pick === current; i++) {
      pick = Math.floor(Math.random() * this.queue.length);
    }
    return pick;
  }

  /**
   * 收尾判定（ticker 的 setInterval 与 AVPlayer 的 timeUpdate 双通道调用）。
   *
   * 为什么不能只靠 stateChange 的 completed：应用退到后台/锁屏时该事件经常
   * 不投递，进程里没人知道歌已经唱完，队列就不再推进 —— 表现是「一首播完
   * 停在那里」。这里改成三条独立线索，命中任意一条连续两次就收尾：
   *   ① avp.state 已经是 completed —— 同步属性读取，最可靠，不看事件；
   *   ② 进度贴到尾部（duration-1.2s 以内）；
   *   ③ 上一轮已贴尾（duration-3s 以内）且本轮不再前进 —— 处理播完后
   *      currentTime 被重置为 0、② 永远不成立的情况。
   */
  private checkEnd(avp: media.AVPlayer, posMs: number, durMs: number): void {
    if (this.completedHandled || durMs <= 5000) {
      return;
    }
    let atEnd: boolean = avp.state === 'completed';
    if (!atEnd) {
      if (posMs >= durMs - 1200) {
        atEnd = true;
      } else if (this.lastTickPosMs >= durMs - 3000 && posMs <= this.lastTickPosMs) {
        atEnd = true;
      }
    }
    const prev: number = this.lastTickPosMs;
    this.lastTickPosMs = posMs;
    if (!atEnd) {
      this.endHits = 0;
      return;
    }
    this.endHits = this.endHits + 1;
    if (this.endHits < 2) {
      return;
    }
    this.endHits = 0;
    this.lastTickPosMs = -1;
    logWarn('PlayerEngine',
      `判定已播完（state=${avp.state} pos=${posMs} prev=${prev} dur=${durMs}）→ 主动收尾`);
    this.onCompleted();
  }

  private startTicker(): void {
    this.stopTicker();
    this.ticker = setInterval((): void => {
      const avp: media.AVPlayer | null = this.avp;
      if (avp === null) {
        return;
      }
      try {
        // seek 缓冲期间（播放位置还没追上目标）进度锚定在目标位置，防止滑块回跳
        if (this.pendingSeekMs >= 0) {
          if (Math.abs(avp.currentTime - this.pendingSeekMs) < 1200) {
            this.pendingSeekMs = -1;
            this.pendingSeekAt = 0;
          } else if (Date.now() - this.pendingSeekAt > 2000) {
            // 2 秒都没到位：这个流不吃运行中的 seek → 硬 seek（重建播放器，prepared 态跳位）
            const t: number = this.pendingSeekMs;
            this.pendingSeekMs = -1;
            this.pendingSeekAt = 0;
            logWarn('PlayerEngine', `seek 未生效(cur=${avp.currentTime} target=${t})，改为重建播放器硬 seek`);
            logSeek(`运行态 seek 未生效 cur=${avp.currentTime} target=${t} → 硬 seek`);
            this.loadAt(this.index, t);
            return;
          }
        }
        const shownMs: number = this.pendingSeekMs >= 0 ? this.pendingSeekMs : avp.currentTime;
        const s: PlaybackState = this.state.copy();
        s.positionMs = Math.max(shownMs, 0);
        if (avp.duration > 0) {
          s.durationMs = avp.duration;
        }
        this.commit(s);
        // 收尾判定：ticker 与 timeUpdate 双通道共用 checkEnd
        if (this.pendingSeekMs < 0 && (s.isPlaying || avp.state === 'completed')) {
          this.checkEnd(avp, shownMs, s.durationMs);
        }
      } catch (err) {
        // 播放器刚释放时读属性可能抛错，忽略
      }
    }, 500);
  }

  private stopTicker(): void {
    if (this.ticker >= 0) {
      clearInterval(this.ticker);
      this.ticker = -1;
    }
  }

  private describeError(code: number, message: string): string {
    if (message.includes('timeout') || message.includes('connect') ||
      message.includes('network') || message.includes('Network')) {
      return '连不上 Songloft（地址/端口不对，或服务没开）';
    }
    if (message.includes('401') || message.includes('Unauthorized') || code === 5400103) {
      return 'Songloft 拒绝了播放请求，可能登录已过期，去设置里重新保存一次「音乐服务」';
    }
    if (message.includes('unsupported') || message.includes('format')) {
      return '这个音频格式解不了';
    }
    return message.length > 0 ? `播放失败：${message}` : '播放失败';
  }

  private fail(message: string): void {
    this.stopTicker();
    const s: PlaybackState = this.state.copy();
    s.isPlaying = false;
    s.error = message;
    this.commit(s);
  }
}
