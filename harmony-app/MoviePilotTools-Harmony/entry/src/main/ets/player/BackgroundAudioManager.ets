import { common } from '@kit.AbilityKit';
import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { avSession } from '@kit.AVSessionKit';
import { PlaybackState } from '../model/MusicModels';
import { AppEnv, logError, logInfo, logWarn } from '../common/AppConstants';

/**
 * 媒体命令处理器：AVSession 回调（锁屏卡/通知栏媒体卡的播放控制）转发目标。
 * 由 MusicViewModel 注册 —— 路由逻辑跟 VM 里的操作方法保持一致：
 * 投送中 → CastController（音箱才是真正播放者），否则 → PlayerEngine。
 */
export interface MediaCommandHandler {
  onPlay(): void;
  onPause(): void;
  onNext(): void;
  onPrevious(): void;
  /** positionMs：拖动到的绝对位置（毫秒） */
  onSeek(positionMs: number): void;
}

/**
 * 后台音频保活（对应安卓 player/MusicService.kt 的前台服务角色）：
 * ① 长时任务：播放开始时申请 AUDIO_PLAYBACK，息屏/切后台不被系统掐掉；
 * ② AVSession：进程级创建并随播放态同步元数据/进度，系统据此生成
 *    锁屏封面卡与通知栏媒体卡，卡片按钮命令经 MediaCommandHandler 转发回
 *    PlayerEngine / CastController（ARCHITECTURE.md §6 七步调用链）。
 * 重复申请/释放/激活都是幂等的。
 *
 * 注：设计稿 §6 写的 setAVSessionCallback / setAVSessionActive / AVSessionType.AUDIO
 * 在当前 SDK（API 22）d.ts 里的真实签名是 session.on('play'/…)、session.activate() /
 * deactivate()、type 传字符串字面量 'audio'，本文件以 d.ts 为准。
 */
export class BackgroundAudioManager {
  private static active: boolean = false;
  private static pending: boolean = false;
  /** 进程级 AVSession（'mptools_music'），首次播放时创建，退出时 destroy */
  private static session: avSession.AVSession | null = null;
  /** 防止并发重复 createAVSession 的在途 Promise */
  private static creating: Promise<avSession.AVSession | null> | null = null;
  /** 卡片命令转发目标（MusicViewModel 注册） */
  private static handler: MediaCommandHandler | null = null;
  /** 上次写入卡片的曲目 assetId：换歌才 setAVMetadata，tick 不重复刷 */
  private static lastMetaAssetId: string = '';
  /**
   * 「应该有长时任务」的意图标记：播放/投送开始时置位，彻底停止时清零。
   * 有了它才能在任务失效后自愈 —— active 只表示「此刻系统认不认」，
   * 不表示「该不该有」。
   */
  private static wantAlive: boolean = false;
  /** 自愈节流：sync 每 tick 都跑，不必每次都试着重申请 */
  private static lastHealMs: number = 0;
  /** 当前持有的长时任务类型（系统同一时刻只允许一个，换类型要先释放） */
  private static taskMode: backgroundTaskManager.BackgroundMode | null = null;
  /** 期望的任务类型：本机播放 audioPlayback，投送 dataTransfer */
  private static wantMode: backgroundTaskManager.BackgroundMode =
    backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK;

  static isActive(): boolean {
    return BackgroundAudioManager.active;
  }

  /** 注册/解除媒体命令转发目标（null = 解除） */
  static setCommandHandler(handler: MediaCommandHandler | null): void {
    BackgroundAudioManager.handler = handler;
  }

  /** 申请长时任务（播放开始时调用，异步、可重复调用） */
  static async start(mode: backgroundTaskManager.BackgroundMode =
    backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK): Promise<void> {
    // 先记意图：即使这次申请失败（比如上下文还没就绪），后续 ensureAlive / sync 还能补
    BackgroundAudioManager.wantAlive = true;
    BackgroundAudioManager.wantMode = mode;
    if (!AppEnv.hasContext()) {
      return;
    }
    // AVSession 先于长时任务：HarmonyOS NEXT 对 AUDIO_PLAYBACK 校验存在活跃会话
    await BackgroundAudioManager.ensureSessionAndActivate();
    // 同类型任务已在：幂等返回
    if (BackgroundAudioManager.active && BackgroundAudioManager.taskMode === mode) {
      return;
    }
    if (BackgroundAudioManager.pending) {
      return;
    }
    // 换类型（本机播放 ↔ 投送）：必须先释放旧的，系统同一时刻只允许一个长时任务
    if (BackgroundAudioManager.active) {
      BackgroundAudioManager.active = false;
      BackgroundAudioManager.taskMode = null;
      try {
        await backgroundTaskManager.stopBackgroundRunning(AppEnv.context());
      } catch (err) {
        // 旧任务释放失败不阻塞新申请
      }
    }
    BackgroundAudioManager.pending = true;
    try {
      const ctx: common.UIAbilityContext = AppEnv.context();
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.moviepilottools.mptools',
          abilityName: 'EntryAbility'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(ctx, mode, agent);
      BackgroundAudioManager.active = true;
      BackgroundAudioManager.taskMode = mode;
      const modeName: string = mode === backgroundTaskManager.BackgroundMode.DATA_TRANSFER
        ? 'dataTransfer' : 'audioPlayback';
      logWarn('BgAudio', `长时任务已申请 mode=${modeName}`);
    } catch (err) {
      logWarn('BgAudio', `申请长时任务失败: ${err}`);
    } finally {
      BackgroundAudioManager.pending = false;
    }
  }

  /**
   * 投送专用长时任务：类型换成 DATA_TRANSFER。
   *
   * 投送时手机没有音频输出，AUDIO_PLAYBACK 会被系统判「空转」并在 60 秒后回收
   * （实测日志 CONTINUOUS_TASK: HandleOnContinuousTaskStop），进程随即冻结，
   * CastController 的 500ms 轮询停摆 —— 表现就是「一首放完就停」。
   *
   * 曾经试过用静音/低幅音频流撑住 AUDIO_PLAYBACK，但系统会检测「持续写静音数据」
   * （WriteMuteDataSysEvent）并冻结进程；写非零载波虽然能绕过检测，手机却会真的出声。
   * DATA_TRANSFER 属于数据传输类长时任务，系统不校验音频流，手机完全静默。
   */
  static async startCast(): Promise<void> {
    await BackgroundAudioManager.start(backgroundTaskManager.BackgroundMode.DATA_TRANSFER);
  }

  /** 释放长时任务（播放彻底停止/投送停止时调用，异步、可重复调用） */
  static async stop(): Promise<void> {
    BackgroundAudioManager.wantAlive = false;
    BackgroundAudioManager.taskMode = null;
    if (!BackgroundAudioManager.active) {
      // 没申请过长时任务也可能激活过会话（任务申请失败的兜底），照样停卡片
      await BackgroundAudioManager.deactivateSession();
      return;
    }
    BackgroundAudioManager.active = false;
    if (!AppEnv.hasContext()) {
      return;
    }
    await BackgroundAudioManager.deactivateSession();
    try {
      await backgroundTaskManager.stopBackgroundRunning(AppEnv.context());
      logWarn('BgAudio', '后台音频长时任务已释放');
    } catch (err) {
      logError('BgAudio', `释放长时任务失败: ${err}`);
    }
  }

  /**
   * 退到后台时兜底：意图还在但长时任务没生效（首次申请早于前台、或被系统回收）
   * 就再申请一次。已经 active 时什么也不做，可重复调用。
   */
  static async ensureAlive(): Promise<void> {
    if (!BackgroundAudioManager.wantAlive || BackgroundAudioManager.active) {
      return;
    }
    logWarn('BgAudio', '退后台时长时任务未生效，补申请一次');
    await BackgroundAudioManager.start(BackgroundAudioManager.wantMode);
  }

  /** 应用退出（EntryAbility.onDestroy）：销毁会话，回收系统侧媒体卡资源 */
  static async destroy(): Promise<void> {
    BackgroundAudioManager.wantAlive = false;
    const session: avSession.AVSession | null = BackgroundAudioManager.session;
    BackgroundAudioManager.session = null;
    BackgroundAudioManager.lastMetaAssetId = '';
    BackgroundAudioManager.handler = null;
    if (session === null) {
      return;
    }
    try {
      await session.destroy();
      logInfo('BgAudio', 'AVSession 已销毁');
    } catch (err) {
      logWarn('BgAudio', `销毁 AVSession 失败: ${err}`);
    }
  }

  /**
   * 把合并后的播放态同步进 AVSession（对应 §6 第 2 步）。
   *
   * MusicViewModel 在本机/投送任一状态变化（含 500ms tick）时调这里，
   * 传入的是「本机 + 投送」的合并态 —— 投送中 current 取的是投送队列当前曲，
   * 卡片显示与真实发声者始终一致（§6 与安卓差异点第 3 条）。
   *
   * 元数据只在换歌时写（assetId 去重）；进度/播放暂停态每次都写。
   * 会话尚未创建（start 还在途）时静默跳过，下个 tick 会补上。
   */
  static async sync(playback: PlaybackState): Promise<void> {
    const session: avSession.AVSession | null = BackgroundAudioManager.session;
    if (session === null) {
      return;
    }
    const song = playback.current;
    if (song !== null) {
      const assetId: string = `${song.id}`;
      if (assetId !== BackgroundAudioManager.lastMetaAssetId) {
        const meta: avSession.AVMetadata = {
          assetId: assetId,
          title: song.title,
          artist: song.artist,
          album: song.album,
          duration: song.durationSeconds * 1000
        };
        if (song.coverUrl.length > 0) {
          meta.mediaImage = song.coverUrl;
        }
        try {
          await session.setAVMetadata(meta);
          BackgroundAudioManager.lastMetaAssetId = assetId;
        } catch (err) {
          logWarn('BgAudio', `setAVMetadata 失败: ${err}`);
        }
      }
    }
    const state: avSession.AVPlaybackState = {
      state: playback.isPlaying
        ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      position: {
        elapsedTime: Math.max(Math.trunc(playback.positionMs), 0),
        updateTime: Date.now()
      },
      duration: Math.max(Math.trunc(playback.durationMs), 0)
    };
    try {
      await session.setAVPlaybackState(state);
    } catch (err) {
      logWarn('BgAudio', `setAVPlaybackState 失败: ${err}`);
    }
    // 自愈：长时任务被系统回收（权限被关 / 资源紧张 / 首次申请时机不对）时，
    // 播放中每 60 秒补申请一次，避免息屏几分钟后突然没声。节流防止刷日志。
    const now: number = Date.now();
    if (BackgroundAudioManager.wantAlive && !BackgroundAudioManager.active &&
      !BackgroundAudioManager.pending && now - BackgroundAudioManager.lastHealMs > 60000) {
      BackgroundAudioManager.lastHealMs = now;
      logWarn('BgAudio', '长时任务已丢失，尝试重新申请');
      BackgroundAudioManager.start(BackgroundAudioManager.wantMode).then((): void => {
      }).catch((): void => {
      });
    }
  }

  // ------------------------------------------------------------ 内部实现

  /** 创建（幂等）并激活 AVSession；注册锁屏卡/通知栏的播放命令回调 */
  private static async ensureSessionAndActivate(): Promise<void> {
    const session: avSession.AVSession | null = await BackgroundAudioManager.ensureSession();
    if (session === null) {
      return;
    }
    try {
      await session.activate();
      logWarn('BgAudio', 'AVSession 已激活（媒体卡可显示）');
    } catch (err) {
      logWarn('BgAudio', `激活 AVSession 失败: ${err}`);
    }
  }

  private static async ensureSession(): Promise<avSession.AVSession | null> {
    if (BackgroundAudioManager.session !== null) {
      return BackgroundAudioManager.session;
    }
    if (!AppEnv.hasContext()) {
      return null;
    }
    if (BackgroundAudioManager.creating !== null) {
      return await BackgroundAudioManager.creating;
    }
    BackgroundAudioManager.creating = (async (): Promise<avSession.AVSession | null> => {
      try {
        // §6 第 1 步：进程级创建一次，切歌/切页复用同一个会话
        const session: avSession.AVSession =
          await avSession.createAVSession(AppEnv.context(), 'mptools_music', 'audio');
        // §6 第 3 步：注册卡片命令回调，转发目标运行时取（注册前已播/未注册都安全）
        session.on('play', (): void => {
          BackgroundAudioManager.dispatch('play');
        });
        session.on('pause', (): void => {
          BackgroundAudioManager.dispatch('pause');
        });
        session.on('playNext', (): void => {
          BackgroundAudioManager.dispatch('next');
        });
        session.on('playPrevious', (): void => {
          BackgroundAudioManager.dispatch('previous');
        });
        session.on('seek', (time: number): void => {
          const handler: MediaCommandHandler | null = BackgroundAudioManager.handler;
          if (handler !== null) {
            handler.onSeek(Math.max(Math.trunc(time), 0));
          }
        });
        BackgroundAudioManager.session = session;
        logWarn('BgAudio', 'AVSession 已创建（audio）');
        return session;
      } catch (err) {
        logWarn('BgAudio', `createAVSession 失败: ${err}`);
        return null;
      } finally {
        BackgroundAudioManager.creating = null;
      }
    })();
    return await BackgroundAudioManager.creating;
  }

  private static async deactivateSession(): Promise<void> {
    const session: avSession.AVSession | null = BackgroundAudioManager.session;
    if (session === null) {
      return;
    }
    try {
      await session.deactivate();
      logInfo('BgAudio', 'AVSession 已停用');
    } catch (err) {
      logWarn('BgAudio', `停用 AVSession 失败: ${err}`);
    }
  }

  /** play/pause/上一首/下一首统一转发（seek 因带参数单独处理） */
  private static dispatch(cmd: 'play' | 'pause' | 'next' | 'previous'): void {
    const handler: MediaCommandHandler | null = BackgroundAudioManager.handler;
    logWarn('BgAudio', `收到媒体卡命令 ${cmd}（handler=${handler !== null ? '已注册' : '未注册'}）`);
    if (handler === null) {
      return;
    }
    if (cmd === 'play') {
      handler.onPlay();
    } else if (cmd === 'pause') {
      handler.onPause();
    } else if (cmd === 'next') {
      handler.onNext();
    } else {
      handler.onPrevious();
    }
  }
}
