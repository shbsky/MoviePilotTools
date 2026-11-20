import { AppTheme, Palette, Metrics, withAlpha } from '../../common/Theme';
import { formatDurationMs } from '../../common/Format';
import { logSeek } from '../../common/AppConstants';
import { MusicSong, PlaybackState } from '../../model/MusicModels';
import { MusicViewModel } from '../../vm/MusicViewModel';
import { ThinProgress } from '../components/Common';

/**
 * 播放条组件（对应安卓 ui/music/PlayerBars.kt）：
 * MiniPlayerBar —— 底部迷你条（常驻所有标签页底部）；NowPlayingPage —— 全屏播放页。
 * 状态全部来自 MusicViewModel.playback()（本机/投送合并态）。
 */

/** 没有封面 / 封面加载失败时的占位：淡渐变 + 音符 */
@Component
struct CoverFallback {
  @Consume('oiiTheme') theme: AppTheme;
  iconSize: number = 16;

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 135,
          colors: [[withAlpha(Palette.pink, 0x38), 0.0], [withAlpha(Palette.indigo, 0x2E), 1.0]]
        })
      Text('♪')
        .fontSize(this.iconSize)
        .fontColor(withAlpha(this.theme.colors.textSecondary, 0xCC))
    }
    .width('100%')
    .height('100%')
  }
}

/** 底部迷你播放条：常驻在所有标签页底部（正在播放时） */
@Component
export struct MiniPlayerBar {
  @Consume('oiiTheme') theme: AppTheme;
  private vm: MusicViewModel = MusicViewModel.getInstance();
  @Prop playback: PlaybackState = new PlaybackState();
  @Prop onOpenTarget: string = 'nowPlaying';

  build() {
    if (this.playback.current !== null) {
      Column() {
        // 进度细条
        ThinProgress({ progress: this.playback.progress(), color: Palette.pink, heightVp: 2 })
        Row() {
          // 封面
          Stack() {
            if ((this.playback.current as MusicSong).coverUrl.length > 0) {
              Image((this.playback.current as MusicSong).coverUrl)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .draggable(false)
            } else {
              CoverFallback({ iconSize: 16 })
            }
          }
          .width(36)
          .height(36)
          .borderRadius(8)
          .clip(true)

          Blank().width(9)
          Column() {
            Text((this.playback.current as MusicSong).title)
              .fontSize(this.theme.fs(13))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.colors.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.playback.castingTo !== null
              ? `投送到 ${this.playback.castingTo}`
              : ((this.playback.current as MusicSong).artist.length > 0
                ? (this.playback.current as MusicSong).artist : '未知歌手'))
              .fontSize(this.theme.fs(10))
              .fontColor(this.playback.castingTo !== null
                ? Palette.blue : this.theme.colors.textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          if (this.playback.isPlaying) {
            SymbolGlyph($r('sys.symbol.pause_fill'))
              .fontSize(17)
              .fontColor([this.theme.colors.textPrimary])
              .padding(4)
              .onClick((): void => {
                this.vm.togglePlay();
              })
          } else {
            SymbolGlyph($r('sys.symbol.play_fill'))
              .fontSize(17)
              .fontColor([this.theme.colors.textPrimary])
              .padding(4)
              .onClick((): void => {
                this.vm.togglePlay();
              })
          }
          Blank().width(14)
          SymbolGlyph($r('sys.symbol.forward_end_fill'))
            .fontSize(17)
            .fontColor([this.playback.hasNext
              ? this.theme.colors.textPrimary : this.theme.colors.textSecondary])
            .padding(4)
            .onClick((): void => {
              this.vm.next();
            })
          Blank().width(10)
          Text('✕')
            .fontSize(14)
            .fontColor(this.theme.colors.textSecondary)
            .padding(4)
            .onClick((): void => {
              this.vm.quitPlayback();
            })
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 7, bottom: 7 })
        .alignItems(VerticalAlign.Center)
      }
      .width('calc(100% - 24vp)')
      .margin({ left: Metrics.pagePadding, right: Metrics.pagePadding })
      .borderRadius(14)
      .backgroundColor(this.theme.colors.card)
      .clip(true)
      .onClick((): void => {
        // 打开全屏播放页（由宿主页面处理路由；这里通过 AppStorage 信号）
        AppStorage.setOrCreate('openNowPlaying', true);
      })
    }
  }
}

/** 全屏播放页（NavDestination 路由 'nowPlaying'，版式参考飞牛音乐） */
@Component
export struct NowPlayingPage {
  @Consume('oiiTheme') theme: AppTheme;
  @Consume('navStack') navStack: NavPathStack;
  private vm: MusicViewModel = MusicViewModel.getInstance();
  @State playback: PlaybackState = new PlaybackState();
  /** 进度拖动中的临时比例（0..1）；<0 = 跟随播放器 */
  @State dragRatio: number = -1;
  /** 进度条实际宽度（vp）：拖动时用触摸坐标自己算比例，不依赖 Slider 的取值语义 */
  @State barW: number = 0;
  /** 最近一次按下/移动的时刻：兜底防止 Up 丢失导致进度条卡在拖动态 */
  private dragTouchAt: number = 0;
  @State showVolume: boolean = false;
  @State volume: number = 1;
  @State favorite: boolean = false;
  /** 封面加载失败 → 走深色渐变占位，白字依然可读 */
  @State coverFailed: boolean = false;
  private lastCoverKey: string = '';
  /** 沉浸式安全区（vp）：全屏页自己铺满系统栏区域，内容再避让 */
  @StorageLink('sysTopSafeVp') topSafeVp: number = 0;
  @StorageLink('sysBottomSafeVp') bottomSafeVp: number = 0;

  private listener: () => void = (): void => {
    this.playback = this.vm.playback();
    // Up 事件偶尔会丢（被手势竞争吃掉）：拖动态久无输入就解除，避免进度条卡死
    if (this.dragRatio >= 0 && this.dragTouchAt > 0 && Date.now() - this.dragTouchAt > 2000) {
      this.dragRatio = -1;
      this.dragTouchAt = 0;
    }
    const song: MusicSong | null = this.playback.current;
    this.favorite = song !== null && this.vm.state.favoriteIds.has(song.id);
    // 换歌/换封面时重置加载失败标记
    const key: string = song !== null
      ? `${(song as MusicSong).id}|${(song as MusicSong).coverUrl}` : '';
    if (key !== this.lastCoverKey) {
      this.lastCoverKey = key;
      this.coverFailed = false;
    }
  };

  aboutToAppear(): void {
    this.vm.subscribe(this.listener);
    this.listener();
    // 通知 Index：播放页全屏态——Navigation 避让 padding 归零，深色背景铺满系统栏区域
    AppStorage.setOrCreate('nowPlayingActive', true);
  }

  aboutToDisappear(): void {
    this.vm.unsubscribe(this.listener);
    this.vm.detachEngine();
    AppStorage.setOrCreate('nowPlayingActive', false);
  }

  private song(): MusicSong | null {
    return this.playback.current;
  }

  private subtitle(): string {
    const s: MusicSong | null = this.song();
    if (s === null) {
      return '';
    }
    const parts: string[] = [];
    if (s.artist.length > 0) {
      parts.push(s.artist);
    }
    if (s.album.length > 0) {
      parts.push(s.album);
    }
    return parts.length > 0 ? parts.join(' · ') : '未知歌手';
  }

  private formatHint(): string {
    const s: MusicSong | null = this.song();
    if (s === null) {
      return '';
    }
    let out: string = '原文件';
    if (s.format.length > 0) {
      out += ` · ${s.format.toUpperCase()}`;
    }
    if (s.bitRate > 0) {
      out += ` · ${s.bitRate} kbps`;
    }
    return out === '原文件' ? '' : out;
  }

  /** 当前播放顺序的文字说明（飞牛风格：图标行上方左侧展示） */
  /** 底部控制键：系统矢量符号（SymbolGlyph），emoji 在不同机型渲染不可控 */
  @Builder
  CtrlKey(sym: Resource, sizeVp: number, tint: number, onTap: () => void): void {
    SymbolGlyph(sym)
      .fontSize(sizeVp)
      .fontColor([tint])
      .padding(11)
      .onClick((): void => {
        onTap();
      })
  }

  /** 进度条当前比例（拖动中跟手，否则跟播放器） */
  private seekRatio(): number {
    const r: number = this.dragRatio >= 0 ? this.dragRatio : this.playback.progress();
    if (!(r > 0)) {
      return 0;
    }
    return r > 1 ? 1 : r;
  }

  /** 触摸点 x（相对进度条左侧）→ 0..1 比例 */
  private ratioAt(x: number): number {
    if (this.barW <= 1) {
      return 0;
    }
    const r: number = x / this.barW;
    if (!(r > 0)) {
      return 0;
    }
    return r > 1 ? 1 : r;
  }

  /**
   * 自己处理拖动：Slider 在本机型上有两个坑——onChange 的值在拖到中间时也会给成 0/1，
   * 而且 block 到轨道末端会越界。用 onTouch 的组件内坐标除以实测宽度，比例必然等于手指位置。
   */
  private onSeekTouch(event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    const ratio: number = this.ratioAt(event.touches[0].x);
    if (event.type === TouchType.Down || event.type === TouchType.Move) {
      this.dragTouchAt = Date.now();
      this.dragRatio = ratio;
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      const target: number = this.dragRatio >= 0 ? this.dragRatio : ratio;
      this.dragRatio = -1;
      this.dragTouchAt = 0;
      if (this.playback.durationMs > 0) {
        const ms: number = Math.trunc(target * this.playback.durationMs);
        logSeek(`进度条 ${event.type === TouchType.Up ? 'Up' : 'Cancel'} ratio=${target.toFixed(3)} ` +
          `barW=${Math.round(this.barW)} → ${ms}ms / ${this.playback.durationMs}ms`);
        this.vm.seekTo(ms);
      }
    }
  }

  /** 是否用封面海报做整页背景（有封面且没加载失败） */
  private hasCoverBg(): boolean {
    const song: MusicSong | null = this.song();
    return song !== null && (song as MusicSong).coverUrl.length > 0 && !this.coverFailed;
  }

  build() {
    NavDestination() {
      Stack() {
        // 背景层 1：深色渐变底（无封面兜底，保证白色前景始终可读）
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 270,
            colors: [[0xFF3A2E55, 0.0], [0xFF1A1626, 1.0]]
          })

        // 背景层 2：封面海报铺满整页 + 底部加深渐变遮罩
        if (this.hasCoverBg()) {
          Image((this.song() as MusicSong).coverUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .draggable(false)
            .onError((): void => {
              this.coverFailed = true;
            })
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 270,
              colors: [[0x4D000000, 0.0], [0xCC000000, 1.0]]
            })
        }

        Column() {
          // 顶部：收起（⌄ 字形部分机型没有，改用系统符号 chevron_down）
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(22)
              .fontColor([0xFFFFFFFF])
              .padding(8)
              .onClick((): void => {
                this.navStack.pop();
              })
            Blank()
            Text('正在播放')
              .fontSize(this.theme.fs(12))
              .fontColor(0xB8FFFFFF)
            Blank()
            Text(' ')
              .fontSize(24)
              .padding(6)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 6 + this.topSafeVp, bottom: 6 })
          .alignItems(VerticalAlign.Center)

          if (this.song() === null) {
            Column() {
              Text('还没有在播放的歌')
                .fontSize(this.theme.fs(14))
                .fontColor(0xFFFFFFFF)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            Blank().layoutWeight(3)

            // 大封面卡（飞牛式：居中大图，无封面时渐变占位）
            Stack() {
              if (this.hasCoverBg()) {
                Image((this.song() as MusicSong).coverUrl)
                  .width('100%')
                  .height('100%')
                  .objectFit(ImageFit.Cover)
                  .draggable(false)
                  .onError((): void => {
                    this.coverFailed = true;
                  })
              } else {
                Column() {
                  Text('♪')
                    .fontSize(54)
                    .fontColor(0x99FFFFFF)
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .linearGradient({
                  angle: 135,
                  colors: [[0x66AF52DE, 0.0], [0x665E5CE6, 1.0]]
                })
              }
            }
            .width('68%')
            .aspectRatio(1)
            .borderRadius(20)
            .clip(true)
            .alignContent(Alignment.Center)
            .shadow({
              radius: 28,
              color: 0x66000000,
              offsetX: 0,
              offsetY: 10
            })

            Blank().layoutWeight(2)

            // 歌名 / 副标题 + 收藏
            Row() {
              Column() {
                Text((this.song() as MusicSong).title)
                  .fontSize(this.theme.fs(20))
                  .fontWeight(FontWeight.Bold)
                  .fontColor(0xFFFFFFFF)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Blank().height(6)
                Text(this.subtitle())
                  .fontSize(this.theme.fs(12))
                  .fontColor(0xB8FFFFFF)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.playback.castingTo !== null) {
                  Blank().height(6)
                  Text(`投送到 ${this.playback.castingTo}`)
                    .fontSize(this.theme.fs(11))
                    .fontColor(Palette.blue)
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Blank().width(12)
              Text(this.favorite ? '❤️' : '🤍')
                .fontSize(20)
                .padding(6)
                .onClick((): void => {
                  if (this.song() !== null) {
                    this.vm.toggleFavorite(this.song() as MusicSong);
                  }
                })
            }
            .width('100%')
            .padding({ left: 28, right: 28 })
            .alignItems(VerticalAlign.Center)

            // 进度条（自绘轨道 + 自算坐标，见 onSeekTouch 注释）
            Blank().height(16)
            Stack({ alignContent: Alignment.Center }) {
              // 轨道底（垂直方向由 Stack 居中，不要再加 margin-top，否则偏移会算两遍）
              Row()
                .width('100%')
                .height(8)
                .borderRadius(4)
                .backgroundColor(0x47FFFFFF)
              // 已播放部分：包一层全宽 Row 让它从左边起画
              Row() {
                Row()
                  .width(`${this.seekRatio() * 100}%`)
                  .height(8)
                  .borderRadius(4)
                  .backgroundColor(Palette.pink)
              }
              .width('100%')
              .height(8)
              .justifyContent(FlexAlign.Start)
              // 滑块：先被 Stack 居中，再按比例横向平移（中心对齐到比例位置）
              Circle()
                .width(16)
                .height(16)
                .fill(Palette.pink)
                .offset({ x: (this.seekRatio() - 0.5) * this.barW })
            }
            .width('calc(100% - 52vp)')
            .height(28)
            .margin({ left: 26, right: 26 })
            .clip(false)
            .onAreaChange((oldArea: Area, newArea: Area): void => {
              const w: number = Number(newArea.width);
              if (w > 0 && Math.abs(w - this.barW) > 0.5) {
                this.barW = w;
              }
            })
            .onTouch((event: TouchEvent): void => {
              this.onSeekTouch(event);
            })

            // 时间行：两端时间 + 中间格式提示（Row 三段式，互不重叠）
            Row() {
              Text(formatDurationMs(this.displayPositionMs()))
                .fontSize(this.theme.fs(10))
                .fontColor(0xB8FFFFFF)
                .width(46)
              Text(this.formatHint())
                .fontSize(this.theme.fs(10))
                .fontColor(0x9EFFFFFF)
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(formatDurationMs(this.playback.durationMs))
                .fontSize(this.theme.fs(10))
                .fontColor(0xB8FFFFFF)
                .width(46)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .padding({ left: 26, right: 26 })
            .alignItems(VerticalAlign.Center)

            if (this.playback.error !== null && this.playback.error !== '') {
              Blank().height(6)
              Text(this.playback.error !== null ? this.playback.error : '')
                .fontSize(this.theme.fs(11))
                .fontColor(Palette.red)
                .textAlign(TextAlign.Center)
                .width('100%')
                .padding({ left: 28, right: 28 })
            }

            // 音量条（点喇叭展开）
            if (this.showVolume) {
              Row() {
                if (this.volume <= 0.001) {
                  SymbolGlyph($r('sys.symbol.speaker_slash_fill'))
                    .fontSize(15)
                    .fontColor([0xB8FFFFFF])
                } else {
                  SymbolGlyph($r('sys.symbol.speaker_wave_2_fill'))
                    .fontSize(15)
                    .fontColor([0xB8FFFFFF])
                }
                Blank().width(12)
                Slider({
                  value: this.volume,
                  min: 0,
                  max: 1,
                  step: 0.01,
                  style: SliderStyle.OutSet
                })
                  .selectedColor(Palette.pink)
                  .trackColor(0x47FFFFFF)
                  .blockSize({ width: 14, height: 14 })
                  .layoutWeight(1)
                  .onChange((value: number, mode: SliderChangeMode): void => {
                    this.volume = value;
                    this.vm.setVolume(value);
                  })
                Blank().width(12)
                Text(String(Math.round(this.volume * 100)))
                  .fontSize(this.theme.fs(11))
                  .fontColor(0xB8FFFFFF)
              }
              .width('100%')
              .padding({ left: 34, right: 34 })
              .alignItems(VerticalAlign.Center)
              .margin({ top: 10 })
            }

            // （播放模式文字行已按用户要求移除，只保留图标态）

            // 底部控制条（参考飞牛/安卓版）：系统矢量图标，五键均匀分布，命中区 ≥44vp
            Row() {
              // 循环/随机（三态符号）
              if (this.playback.repeatMode === 1) {
                this.CtrlKey($r('sys.symbol.repeat_1'), 24,
                  Palette.pink, (): void => {
                    this.vm.cycleRepeatMode();
                  })
              } else if (this.playback.repeatMode === 3) {
                this.CtrlKey($r('sys.symbol.shuffle'), 24,
                  Palette.pink, (): void => {
                    this.vm.cycleRepeatMode();
                  })
              } else {
                this.CtrlKey($r('sys.symbol.repeat'), 24,
                  this.playback.repeatMode === 2 ? Palette.pink : 0xB8FFFFFF,
                  (): void => {
                    this.vm.cycleRepeatMode();
                  })
              }
              this.CtrlKey($r('sys.symbol.backward_end_fill'), 28,
                0xFFFFFFFF, (): void => {
                  this.vm.previous();
                })
              // 播放/暂停（主键更大）
              if (this.playback.isPlaying) {
                this.CtrlKey($r('sys.symbol.pause_fill'), 40,
                  0xFFFFFFFF, (): void => {
                    this.vm.togglePlay();
                  })
              } else {
                this.CtrlKey($r('sys.symbol.play_fill'), 40,
                  0xFFFFFFFF, (): void => {
                    this.vm.togglePlay();
                  })
              }
              this.CtrlKey($r('sys.symbol.forward_end_fill'), 28,
                this.playback.hasNext ? 0xFFFFFFFF : 0xB8FFFFFF, (): void => {
                  this.vm.next();
                })
              this.CtrlKey(this.showVolume
                ? $r('sys.symbol.speaker_wave_3_fill') : $r('sys.symbol.speaker_wave_2_fill'), 24,
                this.showVolume ? Palette.pink : 0xB8FFFFFF, (): void => {
                  this.showVolume = !this.showVolume;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 26, right: 26, top: 22, bottom: 52 + this.bottomSafeVp })
            .alignItems(VerticalAlign.Center)
          }
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    // 音量浮层开着时，返回键先收音量条，不直接退出全屏播放页
    .onBackPressed((): boolean => {
      if (this.showVolume) {
        this.showVolume = false;
        return true;
      }
      return false;
    })
  }

  /** 拖动进度条时显示拖到的位置，平时显示实际进度 */
  private displayPositionMs(): number {
    if (this.dragRatio >= 0) {
      return Math.trunc(this.dragRatio * this.playback.durationMs);
    }
    return this.playback.positionMs;
  }
}
