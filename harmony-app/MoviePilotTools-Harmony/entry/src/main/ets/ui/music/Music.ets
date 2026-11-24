import { AppTheme, Palette, Metrics, withAlpha } from '../../common/Theme';
import { formatDuration } from '../../common/Format';
import { MusicLibraryStats, MusicPlaylist, MusicSong, MusicUiState, PlaybackState } from '../../model/MusicModels';
import { MusicViewModel } from '../../vm/MusicViewModel';
import { OiiCard, SectionHeader, DividerLine, EmptyHint } from '../components/Common';
import { CastSheet } from './CastSheet';
import { DlnaDevice } from '../../net/DlnaClient';
import { BackStack } from '../../common/BackStack';

/**
 * 音乐页（对应安卓 ui/music/MusicScreen.kt）：
 * 歌单横滑 → 全部歌曲列表（封面 / 红心 / 时长）；搜索栏、播放全部、加载更多。
 * 播放状态由 MusicViewModel 持有，切标签页不会断。
 */

/** 歌单卡片（横滑） */
@Component
struct PlaylistCard {
  @Consume('oiiTheme') theme: AppTheme;
  playlist: MusicPlaylist = new MusicPlaylist();
  onTap: () => void = (): void => {
  };

  build() {
    Column() {
      Stack() {
        if (this.playlist.coverUrl.length > 0) {
          Image(this.playlist.coverUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else {
          Column() {
            Text('🎼').fontSize(24).fontColor(this.theme.colors.textSecondary)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(this.theme.colors.separator)
        }
      }
      .width('100%')
      .aspectRatio(1)
      .borderRadius(12)
      .clip(true)

      Blank().height(6)
      Text(this.playlist.name)
        .fontSize(12)
        .fontColor(this.theme.colors.textPrimary)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(16)
      if (this.playlist.songCount > 0) {
        Text(`${this.playlist.songCount} 首`)
          .fontSize(10)
          .fontColor(this.theme.colors.textSecondary)
      }
    }
    .width(104)
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      this.onTap();
    })
  }
}

/** 单曲行 */
@Component
struct SongRow {
  @Consume('oiiTheme') theme: AppTheme;
  song: MusicSong = new MusicSong();
  playing: boolean = false;
  favorite: boolean = false;
  onPlay: () => void = (): void => {
  };
  onToggleFavorite: () => void = (): void => {
  };
  @State coverFailed: boolean = false;

  private subtitle(): string {
    const parts: string[] = [];
    if (this.song.artist.length > 0) {
      parts.push(this.song.artist);
    }
    if (this.song.album.length > 0) {
      parts.push(this.song.album);
    }
    return parts.length > 0 ? parts.join(' · ') : '未知歌手';
  }

  build() {
    Row() {
      Stack() {
        if (this.song.coverUrl.length > 0 && !this.coverFailed) {
          Image(this.song.coverUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .draggable(false)
            .onError((): void => {
              this.coverFailed = true;
            })
        } else {
          Column() {
            Text('♪').fontSize(17).fontColor(this.theme.colors.textSecondary)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(this.theme.colors.separator)
        }
      }
      .width(48)
      .height(48)
      .borderRadius(9)
      .clip(true)

      Blank().width(11)
      Column() {
        Text(this.song.title)
          .fontSize(this.theme.fs(14))
          .fontWeight(this.playing ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.playing ? Palette.pink : this.theme.colors.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank().height(2)
        Text(this.subtitle())
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Blank().width(8)
      Text(this.favorite ? '❤️' : '🤍')
        .fontSize(15)
        .padding(5)
        .onClick((): void => {
          this.onToggleFavorite();
        })
      Blank().width(4)
      Text(formatDuration(this.song.durationSeconds))
        .fontSize(this.theme.fs(11))
        .fontColor(this.theme.colors.textSecondary)
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 7, bottom: 7 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.onPlay();
    })
  }
}

@Component
export struct MusicPage {
  @Consume('oiiTheme') theme: AppTheme;
  @Consume('navStack') navStack: NavPathStack;
  private vm: MusicViewModel = MusicViewModel.getInstance();
  @State state: MusicUiState = new MusicUiState();
  @State playback: PlaybackState = new PlaybackState();
  /** 搜索框草稿 */
  @State searchDraft: string = '';
  @State showCast: boolean = false;
  /** 底部悬浮栏避让（Index 统一广播） */
  @StorageLink('bottomInsetVp') bottomInset: number = 72;

  private listener: () => void = (): void => {
    this.state = this.vm.state;
    this.playback = this.vm.playback();
  };

  aboutToAppear(): void {
    this.vm.subscribe(this.listener);
    this.listener();
    BackStack.get().push('music', 2, (): boolean => this.handleBack());
  }

  aboutToDisappear(): void {
    this.vm.unsubscribe(this.listener);
    BackStack.get().remove('music');
    // 离开音乐页时一定要把「面板已打开」广播复位，否则底栏会一直躲着不回来
    this.setShowCast(false);
  }

  /**
   * 开关投送面板，并把状态广播给 Index。
   *
   * 鸿蒙的浮层只能画在自己页面里，而底部胶囊 TabBar / 迷你播放条是 Index 里
   * 排在 Tabs 之后的兄弟节点，永远盖在本页之上 —— 以前面板一打开就被胶囊压住，
   * 最后一行「找到 N 台设备」直接被吃掉。所以打开时让 Index 把这两个元素隐藏
   * （对齐安卓端 CastDialog 全屏对话框的观感）。
   */
  private setShowCast(open: boolean): void {
    this.showCast = open;
    AppStorage.setOrCreate('castSheetOpen', open);
  }

  /** 返回键逐层退：投送面板 → 歌单详情 → 搜索结果，都没有才交给外层 */
  private handleBack(): boolean {
    if (this.showCast) {
      this.setShowCast(false);
      return true;
    }
    if (this.state.playlist !== null) {
      this.vm.closePlaylist();
      return true;
    }
    if (this.state.searchActive) {
      this.vm.exitSearch();
      return true;
    }
    return false;
  }

  private headerTitle(): string {
    return this.state.playlist !== null ? (this.state.playlist as MusicPlaylist).name : '音乐';
  }

  private headerSubtitle(): string {
    if (!this.state.configured) {
      return '尚未接入 Songloft';
    }
    if (this.state.playlist !== null) {
      return `${(this.state.playlist as MusicPlaylist).songCount} 首`;
    }
    if (this.state.stats !== null) {
      const st: MusicLibraryStats = this.state.stats as MusicLibraryStats;
      return `${st.totalSongs} 首 · ${st.artistCount} 位歌手`;
    }
    return this.state.serverLabel.length > 0 ? this.state.serverLabel : 'Songloft';
  }

  build() {
    Stack() {
      Column() {
        // ---------- 顶部 ----------
        Row() {
          if (this.state.playlist !== null) {
            Text('←')
              .fontSize(18)
              .fontColor(this.theme.colors.textPrimary)
              .padding(4)
              .onClick((): void => {
                this.vm.closePlaylist();
              })
            Blank().width(12)
          }
          Column() {
            Text(this.headerTitle())
              .fontSize(this.state.playlist !== null ? this.theme.fs(20) : this.theme.fs(26))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme.colors.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.headerSubtitle())
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          if (this.state.configured) {
            Text(this.state.searchActive ? '✕' : '🔍')
              .fontSize(18)
              .padding(4)
              .onClick((): void => {
                if (this.state.searchActive) {
                  this.searchDraft = '';
                  this.vm.exitSearch();
                } else {
                  this.vm.startSearch();
                }
              })
            Blank().width(14)
            Text('⟳')
              .fontSize(18)
              .padding(4)
              .onClick((): void => {
                this.vm.refresh();
              })
            Blank().width(14)
            Text('📡')
              .fontSize(18)
              .fontColor(Palette.pink)
              .padding(4)
              .onClick((): void => {
                // T07 接入 DLNA 投送面板
                this.setShowCast(true);
              })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 10 })
        .alignItems(VerticalAlign.Center)

        // 搜索栏（即时搜索：停止输入 0.4 秒后自动出结果）
        if (this.state.configured && this.state.searchActive) {
          Row() {
            Row() {
              Text('🔍')
                .fontSize(13)
                .fontColor(this.theme.colors.textSecondary)
              Blank().width(7)
              TextInput({ text: this.searchDraft, placeholder: '搜歌曲 / 歌手 / 专辑' })
                .fontSize(this.theme.fs(14))
                .fontColor(this.theme.colors.textPrimary)
                .placeholderColor(this.theme.colors.textSecondary)
                .backgroundColor(Color.Transparent)
                .padding(0)
                .layoutWeight(1)
                .enterKeyType(EnterKeyType.Search)
                .onChange((v: string): void => {
                  this.searchDraft = v;
                  this.scheduleSearch();
                })
                .onSubmit((): void => {
                  this.vm.search(this.searchDraft);
                })
              if (this.searchDraft.length > 0) {
                Text('✕')
                  .fontSize(12)
                  .fontColor(this.theme.colors.textSecondary)
                  .padding(4)
                  .onClick((): void => {
                    this.searchDraft = '';
                  })
              }
            }
            .layoutWeight(1)
            .borderRadius(10)
            .backgroundColor(withAlpha(this.theme.colors.separator, 0x59))
            .border({ width: 1, color: withAlpha(this.theme.colors.accent, 0x73) })
            .padding({ left: 11, right: 11, top: 9, bottom: 9 })
            .alignItems(VerticalAlign.Center)

            Blank().width(10)
            Text('✕')
              .fontSize(16)
              .fontColor(this.theme.colors.textSecondary)
              .padding(4)
              .onClick((): void => {
                this.searchDraft = '';
                this.vm.exitSearch();
              })
          }
          .width('100%')
          .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 4, bottom: 6 })
          .alignItems(VerticalAlign.Center)
        }

        // ---------- 主体 ----------
        if (!this.state.configured) {
          this.ConnectHint()
        } else if (this.state.loading && this.state.visibleSongs().length === 0) {
          Column() {
            LoadingProgress().width(24).height(24).color(Palette.pink)
          }
          .width('100%')
          .padding({ top: 60 })
          .alignItems(HorizontalAlign.Center)
        } else if (this.state.error.length > 0 && this.state.visibleSongs().length === 0) {
          this.ErrorHint()
        } else {
          this.SongList()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.colors.background)

      // 投送面板：搜索 DLNA 设备、点歌投送、调音箱音量
      if (this.showCast) {
        CastSheet({
          currentTitle: this.playback.current !== null ? (this.playback.current as MusicSong).title : '',
          onCast: (device: DlnaDevice): void => {
            this.vm.castCurrent(device);
          },
          onDismiss: (): void => {
            this.setShowCast(false);
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Bottom)
  }

  // ---------- 歌曲列表 ----------

  @Builder
  SongList() {
    List() {
      // 歌单区（只在根视图展示）
      if (this.state.playlist === null && !this.state.searchActive) {
        if (this.state.playlists.length > 0) {
          ListItem() {
            Column() {
              SectionHeader({ title: '歌单' })
              Blank().height(8)
              Scroll() {
                Row() {
                  ForEach(this.state.playlists, (pl: MusicPlaylist): void => {
                    PlaylistCard({
                      playlist: pl,
                      onTap: (): void => {
                        this.vm.openPlaylist(pl);
                      }
                    })
                    Blank().width(10)
                  }, (pl: MusicPlaylist): string => String(pl.id))
                }
                .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .margin({ bottom: 18 })
        }

        // 全部歌曲标题 + 播放全部
        ListItem() {
          Row() {
            SectionHeader({ title: this.state.query.length === 0 ? '全部歌曲' : '搜索结果' })
            Blank()
            if (this.state.visibleSongs().length > 0) {
              Row() {
                Text('▶').fontSize(11).fontColor(Palette.pink)
                Blank().width(3)
                Text('播放全部')
                  .fontSize(this.theme.fs(11))
                  .fontColor(Palette.pink)
              }
              .alignItems(VerticalAlign.Center)
              .backgroundColor(withAlpha(Palette.pink, 0x1F))
              .borderRadius(9)
              .padding({ left: 9, right: 9, top: 5, bottom: 5 })
              .onClick((): void => {
                this.vm.playAll();
              })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .margin({ bottom: 8 })
      }

      // 空态
      if (this.state.visibleSongs().length === 0) {
        ListItem() {
          EmptyHint({
            text: this.state.playlist !== null
              ? '这个歌单还没有歌曲'
              : (this.state.query.length === 0 ? '音乐库里还没有歌曲' : '没搜到相关歌曲')
          })
        }
      }

      // 歌曲列表
      ForEach(this.state.visibleSongs(), (song: MusicSong, index: number): void => {
        ListItem() {
          Column() {
            SongRow({
              song: song,
              playing: this.playback.current !== null &&
                (this.playback.current as MusicSong).id === song.id,
              favorite: this.state.favoriteIds.has(song.id),
              onPlay: (): void => {
                this.vm.playSong(song);
              },
              onToggleFavorite: (): void => {
                this.vm.toggleFavorite(song);
              }
            })
            if (index !== this.state.visibleSongs().length - 1) {
              DividerLine()
            }
          }
          .width('100%')
        }
      }, (song: MusicSong): string => String(song.id))

      // 分页状态
      if (this.state.loadingMore) {
        ListItem() {
          Column() {
            LoadingProgress().width(18).height(18).color(Palette.pink)
          }
          .width('100%')
          .padding({ top: 14, bottom: 14 })
          .alignItems(HorizontalAlign.Center)
        }
      } else if (this.state.visibleSongs().length > 0 &&
        this.state.visibleSongs().length >= this.state.total && this.state.playlist === null) {
        ListItem() {
          Column() {
            Text(`已经到底了 · 共 ${this.state.visibleSongs().length} 首`)
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
          }
          .width('100%')
          .padding({ top: 14, bottom: 14 })
          .alignItems(HorizontalAlign.Center)
        }
      }

      // 底部占位项：列表尾部不用 `.padding({ bottom })`。
      // List 的 padding 会裁剪滚动内容 —— 歌曲行在底栏上沿被硬切、玻璃后面透不出东西；
      // 末尾占位项则让内容一路铺到屏幕底，从底栏下面滚过去。
      ListItem() {
        Column()
          .width('100%')
          .height(this.bottomInset + 8)
      }
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onReachEnd((): void => {
      // 滑到底前就预取下一页
      if (!this.state.loadingMore && this.state.visibleSongs().length < this.state.total) {
        this.vm.loadMore();
      }
    })
  }

  // ---------- 未接入引导 ----------

  @Builder
  ConnectHint() {
    Column() {
      OiiCard({ paddingVp: 14 }) {
        Row() {
          Stack() {
            Column()
              .width(34)
              .height(34)
              .borderRadius(9)
              .backgroundColor(withAlpha(Palette.pink, 0x24))
            Text('🎵').fontSize(16)
          }
          .width(34)
          .height(34)
          Blank().width(11)
          Column() {
            Text('接入 Songloft 音乐库')
              .fontSize(this.theme.fs(15))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.colors.textPrimary)
            Blank().height(2)
            Text('设置 → 音乐服务，填 Songloft 地址和账号，这里就能浏览歌曲、歌单并在手机上播放。')
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
              .lineHeight(this.theme.fs(16))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text('去设置')
            .fontSize(this.theme.fs(13))
            .fontColor(Palette.pink)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          // 「去设置」要打开「设置 → 音乐服务」，不是下载器服务器列表。
          // 通过全局信号让 Index 切到设置 Tab，Settings 收到后自动弹出音乐服务弹窗。
          AppStorage.setOrCreate('openMusicSettings', true);
        })
      }
    }
    .width('100%')
    .padding(Metrics.pagePadding)
  }

  // ---------- 错误提示 ----------

  @Builder
  ErrorHint() {
    Column() {
      OiiCard({ paddingVp: 14 }) {
        Column() {
          Text('连不上音乐服务')
            .fontSize(this.theme.fs(14))
            .fontColor(Palette.red)
          Blank().height(4)
          Text(this.state.error)
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
            .lineHeight(this.theme.fs(16))
          Blank().height(10)
          Text('重试')
            .fontSize(this.theme.fs(13))
            .fontColor(Palette.pink)
            .borderRadius(9)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .onClick((): void => {
              this.vm.refresh();
            })
        }
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .padding(Metrics.pagePadding)
  }

  /** 即时搜索防抖：停止输入 0.4 秒后自动出结果 */
  private scheduleSearch(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
    }
    const draft: string = this.searchDraft;
    if (draft.trim().length === 0) {
      return;
    }
    this.searchTimer = setTimeout((): void => {
      this.searchTimer = -1;
      if (this.searchDraft === draft) {
        this.vm.search(draft);
      }
    }, 400);
  }

  private searchTimer: number = -1;
}
