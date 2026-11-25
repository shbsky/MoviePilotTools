import { AppTheme, Palette, Metrics, withAlpha, glassCard, ghostFill, GLASS_MASK } from '../../common/Theme';
import { MpMedia, MpServer, MpSubscribe, MpDiscoverChannel, MP_CHANNELS } from '../../model/MpModels';
import { MpSite } from '../../model/MpSiteModels';
import { SubscribeOption, SubscribeOptions } from '../../data/SubscribeOptions';
import { MpViewModel, MpState, SubscribePanel } from '../../vm/MpViewModel';
import { BackStack } from '../../common/BackStack';
import { OiiCard, TinyPill, SelectablePill, EmptyHint, ThinProgress } from '../components/Common';
import { PosterImage } from '../components/PosterImage';

/**
 * MoviePilot 主页（对应安卓 ui/moviepilot/MoviePilotScreen.kt）：
 * 频道胶囊 → 3 列海报瀑布（分页加载）；搜索 / 订阅列表为本页覆盖层，
 * 详情与服务器管理走 NavDestination 路由。
 */

// 海报渐变兜底（对应安卓 posterFallback）
const FALLBACK_A: number[] = [0xFF2F6FED, 0xFF0EA5A4, 0xFFF97316, 0xFF6D28D9, 0xFF059669];
const FALLBACK_B: number[] = [0xFF7B4BF5, 0xFF2F6FED, 0xFFDB2777, 0xFF1D4ED8, 0xFF0891B2];

/** 选择器列表的最大高度（约 6 行半）：选项少时弹窗按内容收缩，选项多才滚动 */
const PICKER_LIST_MAX_HEIGHT: number = 264;

function hashOf(seed: string): number {
  let h: number = 0;
  for (let i = 0; i < seed.length; i++) {
    h = (h * 31 + seed.charCodeAt(i)) | 0;
  }
  return Math.abs(h);
}

function posterFallbackA(seed: string): number {
  return FALLBACK_A[hashOf(seed) % FALLBACK_A.length];
}

function posterFallbackB(seed: string): number {
  return FALLBACK_B[hashOf(seed) % FALLBACK_B.length];
}

/** 评分文本：一位小数 */
function voteText(vote: number): string {
  return vote.toFixed(1);
}

/** 海报卡（带渐变兜底 / 评分角标 / 季角标 / 订阅角标） */
@Component
export struct PosterCard {
  @Consume('oiiTheme') theme: AppTheme;
  title: string = '';
  posterUrl: string = '';
  vote: number = 0;
  season: number = -1;
  isTV: boolean = false;
  subscribed: boolean = false;
  canSubscribe: boolean = true;
  onOpen: () => void = (): void => {
  };
  onSubscribe: () => void = (): void => {
  };
  @State posterFailed: boolean = false;
  /** 订阅角标点击后吞掉冒泡到卡片的打开详情 */
  private swallowOpen: boolean = false;

  build() {
    Column() {
      Stack() {
        // 渐变兜底始终垫底
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 135,
            colors: [[posterFallbackA(this.title), 0.0], [posterFallbackB(this.title), 1.0]]
          })

        if (this.posterUrl.length > 0 && !this.posterFailed) {
          PosterImage({
            url: this.posterUrl,
            onFailed: (): void => {
              this.posterFailed = true;
            }
          })
        }
        if (this.posterUrl.length === 0 || this.posterFailed) {
          Text(this.title)
            .fontSize(11)
            .fontColor(0xE6FFFFFF)
            .textAlign(TextAlign.Center)
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding(6)
        }
        if (this.vote > 0) {
          Text(voteText(this.vote))
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(0xFFFFD60A)
            .backgroundColor(0xCC000000)
            .borderRadius(6)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .margin(5)
        }
        if (this.isTV && this.season > 0) {
          Text(`S${this.season}`)
            .fontSize(9)
            .fontColor(0xFFFFFFFF)
            .backgroundColor(0xCC000000)
            .borderRadius(6)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .margin(5)
        }
        if (this.canSubscribe) {
          Text(this.subscribed ? '已订阅' : '+ 订阅')
            .fontSize(9)
            .fontWeight(FontWeight.Medium)
            .fontColor(0xFFFFFFFF)
            .backgroundColor(this.subscribed ? 0xE634C759 : 0xE6000000)
            .borderRadius(7)
            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            .margin(5)
            .onClick((): void => {
              if (!this.subscribed) {
                this.swallowOpen = true;
                this.onSubscribe();
              }
            })
        }
      }
      .width('100%')
      .aspectRatio(0.68)
      .borderRadius(10)
      .clip(true)
      .alignContent(this.vote > 0 ? Alignment.TopStart : Alignment.TopStart)

      Blank().height(5)
      Text(this.title)
        .fontSize(11)
        .fontColor(this.theme.colors.textPrimary)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(15)
    }
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      if (this.swallowOpen) {
        this.swallowOpen = false;
        return;
      }
      this.onOpen();
    })
  }
}

/**
 * 订阅编辑页的只读选择框。
 * 必须是 @Component + @Prop：原来用 @Builder 按值传参，选完下载器/保存路径后 value
 * 不随 @State 刷新，要切一次「基础/进阶」强制重建子树才显示新值（与之前修站点回显同一个坑）。
 */
@Component
struct EditPickerRowCell {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop value: string = '';
  onTap: () => void = (): void => {
  };

  build() {
    Row() {
      Text(this.value)
        .fontSize(this.theme.fs(13))
        .fontColor(this.value.length > 0 && this.value !== 'null' ? this.theme.colors.textPrimary
          : this.theme.colors.textSecondary)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('⌄')
        .fontSize(this.theme.fs(14))
        .fontColor(this.theme.colors.textSecondary)
    }
    .width('100%')
    .height(40)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.theme.colors.card)
    .borderRadius(9)
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.onTap();
    })
  }
}

/** 订阅编辑页的开关行：on 必须 @Prop，否则从别处改状态时开关不刷新。 */
@Component
struct EditSwitchCell {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop title: string = '';
  @Prop hint: string = '';
  @Prop on: boolean = false;
  onChange: (v: boolean) => void = (v: boolean): void => {
  };

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(this.theme.fs(13))
          .fontColor(this.theme.colors.textPrimary)
        Text(this.hint)
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.on })
        .onChange((isOn: boolean): void => {
          this.onChange(isOn);
        })
    }
    .width('100%')
    .margin({ top: 9 })
    .alignItems(VerticalAlign.Center)
  }
}

@Component
export struct MoviePilotPage {
  @Consume('oiiTheme') theme: AppTheme;
  @Consume('navStack') navStack: NavPathStack;
  private vm: MpViewModel = MpViewModel.getInstance();
  @State state: MpState = new MpState();
  @State showSubscribes: boolean = false;
  /** 底部悬浮栏避让（Index 统一广播） */
  @StorageLink('bottomInsetVp') bottomInset: number = 72;

  // ---- 订阅设置（全屏页） ----
  @State editingSub: MpSubscribe | null = null;
  @State editTab: number = 0;
  // 文本输入框用普通字段，不要 @State：受控绑定会让每次按键触发整页重建、
  // 输入法焦点丢失，表现为「要点好几次才能填进去」。内容由 TextInput 自己维护，
  // onChange 同步到这里；打开/切换订阅时用 editingSub、editTab 触发重建带出初值。
  private eKeyword: string = '';
  @State eQuality: string = '';
  @State eResolution: string = '';
  @State eEffect: string = '';
  @State eSites: number[] = [];
  @State eCustomInterval: boolean = false;
  private eIntervalHours: string = '';
  @State eDownloader: string = '';
  @State eSavePath: string = '';
  @State eBestVersion: boolean = false;
  @State eImdb: boolean = false;
  private eInclude: string = '';
  private eExclude: string = '';
  @State eRuleGroups: string[] = [];
  private eMediaCategory: string = '';
  private eCustomWords: string = '';
  @State eSaving: boolean = false;

  // ---- 通用选择器 ----
  @State pickerOpen: boolean = false;
  @State pickerTitle: string = '';
  @State pickerTarget: string = '';
  @State pickerMulti: boolean = false;
  @State pickerSearchable: boolean = false;
  @State pickerLabels: string[] = [];
  @State pickerValues: string[] = [];
  @State pickerPicked: string[] = [];
  @State pickerQuery: string = '';

  // ---- 二次确认 ----
  @State confirmDeleteSub: MpSubscribe | null = null;
  @State confirmResetSub: MpSubscribe | null = null;

  private listener: () => void = (): void => {
    this.state = this.vm.state;
  };

  aboutToAppear(): void {
    this.vm.subscribe(this.listener);
    this.state = this.vm.state;
    BackStack.get().push('moviepilot', 3, (): boolean => this.handleBack());
  }

  aboutToDisappear(): void {
    this.vm.unsubscribe(this.listener);
    BackStack.get().remove('moviepilot');
  }

  /**
   * 页面内部层级的返回：按渲染优先级从最上层往下关，
   * 关掉一层就 return true（这次返回键算消费掉），全关完 return false 交给外层。
   * 渲染顺序：搜索 → 订阅列表 → 编辑订阅 → 选择器 → 订阅面板 → 二次确认，
   * 所以返回顺序要倒过来：确认 → 面板 → 选择器 → 编辑 → 订阅 → 搜索。
   */
  private handleBack(): boolean {
    if (this.confirmResetSub !== null) {
      this.confirmResetSub = null;
      return true;
    }
    if (this.confirmDeleteSub !== null) {
      this.confirmDeleteSub = null;
      return true;
    }
    if (this.state.subscribePanel !== null) {
      this.vm.closeSubscribePanel();
      return true;
    }
    if (this.pickerOpen) {
      this.pickerOpen = false;
      return true;
    }
    if (this.editingSub !== null) {
      this.closeEdit();
      return true;
    }
    if (this.showSubscribes) {
      this.showSubscribes = false;
      return true;
    }
    if (this.state.searchActive) {
      this.vm.exitSearch();
      return true;
    }
    return false;
  }

  private openDetail(media: MpMedia): void {
    this.vm.openDetail(media);
    this.navStack.pushPathByName('mpDetail', media);
  }

  build() {
    Stack() {
      // ---- 主内容 ----
      Column() {
        // 头部
        Row() {
          Column() {
            Text('MoviePilot')
              .fontSize(this.theme.fs(26))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme.colors.textPrimary)
            Row() {
              Text(this.state.server() !== null ? this.serverName() : '未配置服务器')
                .fontSize(this.theme.fs(11))
                .fontColor(this.state.server() !== null
                  ? this.theme.colors.textSecondary : this.theme.colors.accent)
              Text(' ›')
                .fontSize(this.theme.fs(11))
                .fontColor(this.theme.colors.textSecondary)
            }
            .borderRadius(6)
            .padding({ right: 4 })
            .onClick((): void => {
              this.navStack.pushPathByName('mpServerList', '');
            })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('🔍')
            .fontSize(19)
            .padding(4)
            .onClick((): void => {
              this.vm.startSearch();
            })
          Blank().width(14)
          Text('📑')
            .fontSize(19)
            .padding(4)
            .onClick((): void => {
              this.showSubscribes = true;
              this.vm.loadSubscribes(false);
            })
        }
        .width('100%')
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 4 })
        .alignItems(VerticalAlign.Center)

        if (this.state.servers.length === 0) {
          // 未配置引导
          Column() {
            Stack() {
              Circle().width(64).height(64).fill(withAlpha(Palette.blue, 0x1F))
              Text('🖧').fontSize(28)
            }
            .width(64)
            .height(64)
            Blank().height(16)
            Text('还没有配置 MoviePilot')
              .fontSize(this.theme.fs(17))
              .fontColor(this.theme.colors.textPrimary)
            Blank().height(6)
            Text('填上 MP 的访问地址和 API Token，就能在这里浏览豆瓣/TMDB 榜单、\n跨站点搜资源、一键投递和订阅。')
              .fontSize(this.theme.fs(12))
              .fontColor(this.theme.colors.textSecondary)
              .textAlign(TextAlign.Center)
              .lineHeight(this.theme.fs(19))
            Blank().height(18)
            Text('添加 MoviePilot')
              .fontSize(this.theme.fs(13))
              .fontColor(0xFFFFFFFF)
              .backgroundColor(Palette.blue)
              .borderRadius(18)
              .padding({ left: 18, right: 18, top: 9, bottom: 9 })
              .onClick((): void => {
                this.navStack.pushPathByName('mpServerList', '');
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .padding({ left: 34, right: 34 })
        } else {
          // 频道胶囊
          Scroll() {
            Row() {
              ForEach(MP_CHANNELS, (channel: MpDiscoverChannel): void => {
                SelectablePill({
                  text: channel.title,
                  selected: this.state.channel.key === channel.key,
                  onTap: (): void => {
                    this.vm.selectChannel(channel);
                  }
                })
              }, (channel: MpDiscoverChannel): string => `${channel.key}-${this.state.channel.key === channel.key ? 1 : 0}`)
            }
            .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .padding({ top: 6, bottom: 6 })

          if (this.state.loading) {
            Column() {
              LoadingProgress().width(34).height(34).color(Palette.blue)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else if (this.state.error.length > 0 && this.state.items.length === 0) {
            Column() {
              Text(this.state.error)
                .fontSize(this.theme.fs(13))
                .fontColor(Palette.red)
                .textAlign(TextAlign.Center)
              Blank().height(10)
              Text('重试')
                .fontSize(this.theme.fs(12))
                .fontColor(Palette.blue)
                .backgroundColor(ghostFill(this.theme.colors.textPrimary))
                .borderRadius(14)
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .onClick((): void => {
                  this.vm.loadDiscover(true);
                })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else {
            Grid() {
              ForEach(this.state.items, (media: MpMedia): void => {
                GridItem() {
                  PosterCard({
                    title: media.title,
                    posterUrl: media.posterUrl,
                    vote: media.vote,
                    season: media.season,
                    isTV: media.isTV(),
                    subscribed: this.state.isSubscribed(media),
                    onOpen: (): void => {
                      this.openDetail(media);
                    },
                    onSubscribe: (): void => {
                      this.vm.subscribeMedia(media, media.season);
                    }
                  })
                }
              }, (media: MpMedia): string => `${media.mediaId}:${media.season}`)

              if (this.state.hasMore && this.state.items.length > 0) {
                GridItem() {
                  Column() {
                    if (this.state.loadingMore) {
                      LoadingProgress().width(16).height(16).color(Palette.blue)
                    }
                  }
                  .width('100%')
                  .height(40)
                  .justifyContent(FlexAlign.Center)
                }
              }
            }
            .columnsTemplate('1fr 1fr 1fr')
            .columnsGap(10)
            .rowsGap(14)
            .layoutWeight(1)
            .width('100%')
            .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 4, bottom: 8 + this.bottomInset })
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .onReachEnd((): void => {
              if (this.state.hasMore && !this.state.loadingMore && this.state.items.length > 0) {
                this.vm.loadDiscover(false);
              }
            })
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.colors.background)

      // ---- 搜索覆盖层 ----
      if (this.state.searchActive) {
        this.SearchOverlay()
      }

      // ---- 订阅列表覆盖层 ----
      if (this.showSubscribes) {
        this.SubscribeOverlay()
      }

      // ---- 订阅设置（整页，盖住列表） ----
      if (this.editingSub !== null) {
        this.SubscribeEditPage(this.editingSub)
      }

      // ---- 选择器 / 面板 / 二次确认 ----
      if (this.pickerOpen) {
        this.PickerOverlay()
      }
      // 选择器叠上来时先收起订阅面板，不做「面板当背景」的层级
      if (this.state.subscribePanel !== null && !this.pickerOpen) {
        this.SubscribePanelOverlay(this.state.subscribePanel)
      }
      if (this.confirmDeleteSub !== null) {
        this.ConfirmOverlay('取消订阅',
          `从 MoviePilot 里删除《${this.confirmDeleteSub.name}》这条订阅？已下载的文件不受影响。`,
          '确认取消', (): void => {
            const target: MpSubscribe | null = this.confirmDeleteSub;
            this.confirmDeleteSub = null;
            if (target !== null) {
              this.vm.deleteSubscribe(target.id);
            }
          })
      }
      if (this.confirmResetSub !== null) {
        this.ConfirmOverlay('重置订阅',
          `清空《${this.confirmResetSub.name}》已完成的集数，重新按缺失集数搜索？`,
          '确认重置', (): void => {
            const target: MpSubscribe | null = this.confirmResetSub;
            this.confirmResetSub = null;
            if (target !== null) {
              this.vm.resetSubscribe(target);
            }
          })
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Top)
  }

  private serverName(): string {
    const s: MpServer | null = this.state.server();
    return s !== null ? s.displayName() : 'MoviePilot';
  }

  // ---------- 搜索覆盖层 ----------

  @Builder
  SearchOverlay() {
    Column() {
      Row() {
        Text('←')
          .fontSize(20)
          .fontColor(this.theme.colors.textPrimary)
          .padding(4)
          .onClick((): void => {
            this.vm.exitSearch();
          })
        Blank().width(10)
        Column() {
          TextInput({ text: this.state.searchQuery, placeholder: '搜索电影、剧集名称' })
            .fontSize(this.theme.fs(14))
            .fontColor(this.theme.colors.textPrimary)
            .placeholderColor(this.theme.colors.textSecondary)
            .backgroundColor(this.theme.colors.card)
            .borderRadius(9)
            .height(38)
            .enterKeyType(EnterKeyType.Search)
            .onChange((v: string): void => {
              this.vm.updateSearchQuery(v);
            })
            .onSubmit((): void => {
              this.vm.search();
            })
        }
        .layoutWeight(1)
        Blank().width(8)
        Text('搜索')
          .fontSize(this.theme.fs(12))
          .fontColor(0xFFFFFFFF)
          .backgroundColor(Palette.blue)
          .borderRadius(10)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .onClick((): void => {
            this.vm.search();
          })
      }
      .width('100%')
      .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.state.searching) {
        Column() {
          LoadingProgress().width(34).height(34).color(Palette.blue)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.state.searchResults.length === 0) {
        EmptyHint({ text: '输入片名后点搜索' })
      } else {
        Grid() {
          ForEach(this.state.searchResults, (media: MpMedia): void => {
            GridItem() {
              PosterCard({
                title: media.title,
                posterUrl: media.posterUrl,
                vote: media.vote,
                season: media.season,
                isTV: media.isTV(),
                subscribed: this.state.isSubscribed(media),
                onOpen: (): void => {
                  this.openDetail(media);
                },
                onSubscribe: (): void => {
                  this.vm.subscribeMedia(media, media.season);
                }
              })
            }
          }, (media: MpMedia): string => media.mediaId)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(10)
        .rowsGap(14)
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, bottom: 8 + this.bottomInset })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.colors.background)
  }

  // ---------- 订阅列表覆盖层 ----------

  @Builder
  SubscribeOverlay() {
    Column() {
      Row() {
        Text('←')
          .fontSize(20)
          .fontColor(this.theme.colors.textPrimary)
          .padding(4)
          .onClick((): void => {
            this.showSubscribes = false;
          })
        Blank().width(10)
        Text('订阅（与 MP 网页同一份数据）')
          .fontSize(this.theme.fs(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
      }
      .width('100%')
      .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.state.subscribes.length === 0) {
        EmptyHint({ text: this.state.subscribesLoading ? '加载中…' : '还没有订阅，在详情页点「订阅」即可' })
      } else {
        List() {
          ForEach(this.state.subscribes, (sub: MpSubscribe): void => {
            ListItem() {
              this.SubscribeCard(sub)
            }
            .margin({ bottom: 9 })
          }, (sub: MpSubscribe): string =>
          // key 里必须带上会变的字段：ArkUI 的 ForEach 在 key 不变时**不重建子项**，
          // 只用 id 做 key 的话，从 MP 网页改过的订阅（进度/状态/关键词…）刷新回来也不重绘，
          // 表现就是「必须退出 App 再进才同步」（用户反馈）。
          `${sub.id}-${sub.state}-${sub.completedEpisode}-${sub.totalEpisode}-${sub.keyword}-${sub.sites.length}`)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 2, bottom: 8 + this.bottomInset })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.colors.background)
  }

  @Builder
  SubscribeCard(sub: MpSubscribe) {
    OiiCard({ paddingVp: 11 }) {
      Row() {
        // 小海报（渐变兜底）
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 135,
              colors: [[posterFallbackA(sub.name), 0.0], [posterFallbackB(sub.name), 1.0]]
            })
          if (sub.posterUrl.length > 0) {
            Image(sub.posterUrl)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .draggable(false)
          }
        }
        .width(46)
        .height(66)
        .borderRadius(7)
        .clip(true)

        Blank().width(10)
        Column() {
          Text(`${sub.name}${sub.season > 0 ? ` S${sub.season}` : ''}`)
            .fontSize(this.theme.fs(13))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Blank().height(3)
          Row() {
            TinyPill({
              text: sub.stateLabel(),
              bgColor: sub.state.toUpperCase() === 'R'
                ? withAlpha(Palette.green, 0x26) : withAlpha(Palette.orange, 0x26),
              fgColor: sub.state.toUpperCase() === 'R' ? Palette.green : Palette.orange
            })
            Blank().width(5)
            Text(sub.progressText())
              .fontSize(this.theme.fs(10))
              .fontColor(this.theme.colors.textSecondary)
            if (sub.bestVersion) {
              Blank().width(5)
              TinyPill({
                text: '洗版',
                bgColor: withAlpha(Palette.purple, 0x26),
                fgColor: Palette.purple
              })
            }
          }
          .alignItems(VerticalAlign.Center)
          if (sub.type === '电视剧' && sub.totalEpisode > 0) {
            Blank().height(5)
            ThinProgress({ progress: sub.progress(), color: Palette.green })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Blank().width(6)
        // 卡片操作收进「⋯」菜单，和 MP 网页那 8 项对齐
        Text('⋮')
          .fontSize(this.theme.fs(18))
          .fontColor(this.theme.colors.textSecondary)
          .padding({ left: 6, right: 2, top: 2, bottom: 2 })
          .bindMenu(this.subMenuItems(sub))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // 点整张卡直接进编辑（用户要求：不用每次去点「⋮」）；「⋮」是独立菜单，点它不会走到这里
      .onClick((): void => {
        this.beginEdit(sub);
      })
    }
  }

  // ---------- 订阅卡片菜单 ----------

  private subMenuItems(sub: MpSubscribe): MenuElement[] {
    return [
      {
        value: '编辑',
        action: (): void => {
          this.beginEdit(sub);
        }
      },
      {
        value: '立即搜索',
        action: (): void => {
          this.vm.searchSubscribeNow(sub);
        }
      },
      {
        value: sub.state.toUpperCase() === 'R' ? '暂停' : '恢复',
        action: (): void => {
          this.vm.toggleSubscribeState(sub);
        }
      },
      {
        value: '重置',
        action: (): void => {
          this.confirmResetSub = sub;
        }
      },
      {
        value: '订阅活动',
        action: (): void => {
          this.vm.openSubscribeActivity(sub);
        }
      },
      {
        value: '媒体详情',
        action: (): void => {
          this.vm.openSubscribeMedia(sub);
        }
      },
      {
        value: '文件统计',
        action: (): void => {
          this.vm.openSubscribeFiles(sub);
        }
      },
      {
        value: '取消订阅',
        action: (): void => {
          this.confirmDeleteSub = sub;
        }
      }
    ];
  }

  // ---------- 订阅设置：数据准备 ----------

  private beginEdit(sub: MpSubscribe): void {
    this.vm.loadSubscribeOptions();
    // 按 id 从当前列表取一份**最新**的对象：ArkUI 的 ForEach 在 key 不变时不会重建子项，
    // 列表项闭包里可能还攥着保存前的旧对象，直接用它填表单会让人以为「保存没生效」。
    const latest: MpSubscribe = this.state.subscribes.find((s: MpSubscribe): boolean => s.id === sub.id)
      ?? sub;
    this.editingSub = latest;
    this.editTab = 0;
    this.eKeyword = latest.keyword;
    this.eQuality = latest.quality;
    this.eResolution = latest.resolution;
    this.eEffect = latest.effect;
    this.eSites = latest.sites.slice();
    this.eCustomInterval = latest.searchInterval > 0;
    this.eIntervalHours = latest.searchInterval > 0 ? String(latest.searchInterval) : '24';
    this.eDownloader = latest.downloader;
    this.eSavePath = latest.savePath;
    this.eBestVersion = latest.bestVersion;
    this.eImdb = latest.searchImdbId;
    this.eInclude = latest.include;
    this.eExclude = latest.exclude;
    this.eRuleGroups = latest.filterGroups.slice();
    this.eMediaCategory = latest.mediaCategory;
    this.eCustomWords = latest.customWords;
    this.eSaving = false;
  }

  private closeEdit(): void {
    this.editingSub = null;
    this.pickerOpen = false;
  }

  /**
   * 订阅站点只能挑 MP「系统设置 → 订阅 → 订阅站点」勾过的；
   * 这条订阅已选中的老站点也留着，否则一保存就被清掉。
   */
  private editableSites(): MpSite[] {
    const all: MpSite[] = this.state.site.sites;
    const allowed: number[] | null = this.state.rssSiteIds;
    if (allowed === null) {
      return all;
    }
    const out: MpSite[] = [];
    for (const site of all) {
      if (allowed.indexOf(site.id) >= 0 || this.eSites.indexOf(site.id) >= 0) {
        out.push(site);
      }
    }
    return out;
  }

  private saveEdit(): void {
    const base: MpSubscribe | null = this.editingSub;
    if (base === null || this.eSaving) {
      return;
    }
    this.eSaving = true;
    const sub: MpSubscribe = new MpSubscribe();
    sub.id = base.id;
    sub.name = base.name;
    sub.year = base.year;
    sub.type = base.type;
    sub.season = base.season;
    sub.posterUrl = base.posterUrl;
    sub.vote = base.vote;
    sub.totalEpisode = base.totalEpisode;
    sub.lackEpisode = base.lackEpisode;
    sub.completedEpisode = base.completedEpisode;
    sub.state = base.state;
    sub.lastUpdate = base.lastUpdate;
    sub.tmdbId = base.tmdbId;
    sub.doubanId = base.doubanId;
    sub.bangumiId = base.bangumiId;
    sub.posterRaw = base.posterRaw;
    sub.mediaSource = base.mediaSource;
    sub.mediaIdRaw = base.mediaIdRaw;

    sub.keyword = this.eKeyword.trim();
    sub.quality = this.eQuality;
    sub.resolution = this.eResolution;
    sub.effect = this.eEffect;
    sub.sites = this.eSites.slice();
    const hours: number = parseInt(this.eIntervalHours, 10);
    sub.searchInterval = this.eCustomInterval && !isNaN(hours) && hours > 0 ? hours : -1;
    sub.downloader = this.eDownloader;
    sub.savePath = this.eSavePath;
    sub.bestVersion = this.eBestVersion;
    sub.searchImdbId = this.eImdb;
    sub.include = this.eInclude.trim();
    sub.exclude = this.eExclude.trim();
    sub.filterGroups = this.eRuleGroups.slice();
    sub.mediaCategory = this.eMediaCategory.trim();
    sub.customWords = this.eCustomWords.trim();

    this.vm.saveSubscribe(sub, (ok: boolean): void => {
      this.eSaving = false;
      if (!ok) {
        return;
      }
      // 用户要求：保存成功后**停留在此页**，不再自动返回上一层。
      // 同时把刚保存的值就地写回列表（loadSubscribes 是异步的，
      // 回来慢的时候列表还是旧值，用户会以为「没保存成功」）。
      this.vm.applySavedSubscribe(sub);
    });
  }

  // ---------- 选择器 ----------

  private openPicker(target: string, title: string, options: SubscribeOption[],
    picked: string[], multi: boolean, searchable: boolean): void {
    const labels: string[] = [];
    const values: string[] = [];
    for (const opt of options) {
      labels.push(opt.label);
      values.push(opt.value);
    }
    this.pickerTarget = target;
    this.pickerTitle = title;
    this.pickerLabels = labels;
    this.pickerValues = values;
    this.pickerPicked = picked.slice();
    this.pickerMulti = multi;
    this.pickerSearchable = searchable;
    this.pickerQuery = '';
    this.pickerOpen = true;
  }

  private pickerLabelOf(value: string): string {
    const idx: number = this.pickerValues.indexOf(value);
    if (idx >= 0 && idx < this.pickerLabels.length) {
      return this.pickerLabels[idx];
    }
    return '全部';
  }

  private confirmPicker(): void {
    const picked: string[] = this.pickerPicked.slice();
    const single: string = picked.length > 0 ? picked[0] : '';
    const target: string = this.pickerTarget;
    this.pickerOpen = false;
    if (target === 'quality') {
      this.eQuality = single;
    } else if (target === 'resolution') {
      this.eResolution = single;
    } else if (target === 'effect') {
      this.eEffect = single;
    } else if (target === 'sites') {
      const ids: number[] = [];
      for (const v of picked) {
        const n: number = parseInt(v, 10);
        if (!isNaN(n)) {
          ids.push(n);
        }
      }
      this.eSites = ids;
    } else if (target === 'downloader') {
      this.eDownloader = single;
    } else if (target === 'savepath') {
      this.eSavePath = single;
    } else if (target === 'interval') {
      this.eCustomInterval = single === 'custom';
    } else if (target === 'rules') {
      this.eRuleGroups = picked;
    }
  }
  // ---------- 订阅设置：界面 ----------

  @Builder
  EditLabel(text: string) {
    Text(text)
      .fontSize(this.theme.fs(12))
      .fontColor(this.theme.colors.textSecondary)
      .width('100%')
      .margin({ bottom: 6 })
  }

  @Builder
  EditHint(text: string) {
    Text(text)
      .fontSize(this.theme.fs(10))
      .fontColor(this.theme.colors.textSecondary)
      .width('100%')
      .margin({ top: 5 })
  }

  @Builder
  EditTabItem(text: string, index: number) {
    Text(text)
      .fontSize(this.theme.fs(13))
      .fontColor(this.editTab === index ? Palette.purple : this.theme.colors.textSecondary)
      .fontWeight(this.editTab === index ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 16, right: 16, top: 7, bottom: 7 })
      .backgroundColor(this.editTab === index ? withAlpha(Palette.purple, 0x26) : this.theme.colors.card)
      .borderRadius(9)
      .onClick((): void => {
        this.editTab = index;
      })
  }

  @Builder
  SubscribeEditPage(sub: MpSubscribe) {
    Column() {
      // 顶栏：返回 + 标题（只认这里的返回和系统返回手势，没有下滑关闭）
      Row() {
        Text('←')
          .fontSize(this.theme.fs(20))
          .fontColor(this.theme.colors.textPrimary)
          .padding(6)
          .onClick((): void => {
            this.closeEdit();
          })
        Blank().width(6)
        Column() {
          Text('编辑订阅')
            .fontSize(this.theme.fs(17))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
          Text(`${sub.name}${sub.season > 0 ? ` S${sub.season}` : ''}`)
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 1 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 8, bottom: 6 })
      .alignItems(VerticalAlign.Center)

      // 分页
      Row() {
        this.EditTabItem('基础', 0)
        Blank().width(8)
        this.EditTabItem('进阶', 1)
      }
      .width('100%')
      .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
      .margin({ top: 6, bottom: 4 })

      // 字段
      Scroll() {
        Column() {
          // 用 ForEach + key 强制「切分页时整块重建」：ArkUI 在 if/else 分支之间切换时会复用节点，
          // 曾导致「进阶」页顶部残留一块 ~25dp 的空隙、内容不往上顶（用户截图反馈）。
          // key 里带上 tab 号，切页就换 key → 旧子树销毁、新子树重建。
          ForEach([this.editTab], (tab: number): void => {
            if (tab === 0) {
            Column() {
              this.EditLabel('搜索关键词')
              TextInput({ text: this.eKeyword, placeholder: '留空用订阅名称搜索' })
                .height(40)
                .fontSize(this.theme.fs(13))
                .backgroundColor(this.theme.colors.card)
                .borderRadius(9)
                .onChange((v: string): void => {
                  this.eKeyword = v;
                })
              this.EditHint('指定搜索站点时使用的关键词')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 9 })

            Row() {
              Column() {
                this.EditLabel('质量')
                EditPickerRowCell({
                  value: SubscribeOptions.labelOf(SubscribeOptions.quality(), this.eQuality),
                  onTap: (): void => {
                    this.openPicker('quality', '质量', SubscribeOptions.quality(), [this.eQuality], false, false);
                  }
                })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Blank().width(10)

              Column() {
                this.EditLabel('分辨率')
                EditPickerRowCell({
                  value: SubscribeOptions.labelOf(SubscribeOptions.resolution(), this.eResolution),
                  onTap: (): void => {
                    this.openPicker('resolution', '分辨率', SubscribeOptions.resolution(),
                      [this.eResolution], false, false);
                  }
                })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .margin({ top: 9 })
            .alignItems(VerticalAlign.Top)

            Column() {
              this.EditLabel('特效')
              EditPickerRowCell({
                value: SubscribeOptions.labelOf(SubscribeOptions.effect(), this.eEffect),
                onTap: (): void => {
                  this.openPicker('effect', '特效', SubscribeOptions.effect(), [this.eEffect], false, false);
                }
              })
              this.EditHint('不选表示不限')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 9 })

            Column() {
              this.EditLabel('订阅站点')
              // 站点回显这里**不用 EditPickerRow**：@Builder 的按值参数在 ArkUI 里不随状态刷新，
              // 多选完只显示一个站点就是它导致的（安卓没这问题）。内联写，Text 直接读 eSites。
              Row() {
                Text(this.eSiteSummary())
                  .fontSize(this.theme.fs(13))
                  .fontColor(this.eSites.length > 0 ? this.theme.colors.textPrimary
                    : this.theme.colors.textSecondary)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text('⌄')
                  .fontSize(this.theme.fs(14))
                  .fontColor(this.theme.colors.textSecondary)
              }
              .width('100%')
              .height(40)
              .padding({ left: 12, right: 12 })
              .backgroundColor(this.theme.colors.card)
              .borderRadius(9)
              .alignItems(VerticalAlign.Center)
              .onClick((): void => {
                this.openSitePicker();
              })
              this.EditHint(this.editableSites().length === 0
                ? '先去 MoviePilot 网页「系统设置 → 订阅 → 订阅站点」勾选站点'
                : '只列出系统设置里勾选的订阅站点')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 9 })

            Column() {
              this.EditLabel('搜索周期')
              EditPickerRowCell({
                value: this.eCustomInterval ? '自定义' : '跟随系统',
                onTap: (): void => {
                  this.openPicker('interval', '搜索周期', [
                    new SubscribeOption('跟随系统', 'system'),
                    new SubscribeOption('自定义', 'custom')
                  ], [this.eCustomInterval ? 'custom' : 'system'], false, false);
                }
              })
              if (this.eCustomInterval) {
                TextInput({ text: this.eIntervalHours, placeholder: '每隔多少小时搜索一次' })
                  .type(InputType.Number)
                  .height(40)
                  .fontSize(this.theme.fs(13))
                  .backgroundColor(this.theme.colors.card)
                  .borderRadius(9)
                  .margin({ top: 8 })
                  .onChange((v: string): void => {
                    this.eIntervalHours = v;
                  })
              }
              this.EditHint('仅在开启定时搜索时生效，手动搜索和 RSS 刷新不受影响')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 9 })

            Column() {
              this.EditLabel('下载器 / 保存路径')
              Row() {
                Column() {
                  EditPickerRowCell({
                    value: this.eDownloader.length === 0 ? '自动' : this.eDownloader,
                    onTap: (): void => {
                      const opts: SubscribeOption[] = [new SubscribeOption('自动（用系统设置）', '')];
                      for (const d of this.state.downloaders) {
                        opts.push(new SubscribeOption(d.name, d.name));
                      }
                      this.openPicker('downloader', '下载器', opts, [this.eDownloader], false, false);
                    }
                  })
                }
                .layoutWeight(1)

                Blank().width(10)

                Column() {
                  EditPickerRowCell({
                    value: this.eSavePath.length === 0 ? '自动' : this.eSavePath,
                    onTap: (): void => {
                      const opts: SubscribeOption[] = [new SubscribeOption('自动（用系统设置）', '')];
                      for (const p of this.state.savePaths) {
                        opts.push(new SubscribeOption(p.savePath, p.savePath));
                      }
                      this.openPicker('savepath', '保存路径', opts, [this.eSavePath], false, false);
                    }
                  })
                }
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 9 })

            EditSwitchCell({
              title: '洗版',
              hint: '按洗版优先级进行过滤订阅',
              on: this.eBestVersion,
              onChange: (v: boolean): void => {
                this.eBestVersion = v;
              }
            })
            EditSwitchCell({
              title: '使用 IMDbID 搜索',
              hint: '开启后引用 IMDbID 精确搜索资源',
              on: this.eImdb,
              onChange: (v: boolean): void => {
                this.eImdb = v;
              }
            })
          } else {
            // 进阶页直接以「包含」开头：上面已经有「基础 / 进阶」分页，
            // 再加一段「进阶过滤」标题 + 说明就是重复（用户已明确要求去掉，与安卓保持一致）。
            Column() {
              this.EditLabel('包含')
              TextInput({ text: this.eInclude, placeholder: '关键字或正则，命中才下载' })
                .height(40)
                .fontSize(this.theme.fs(13))
                .backgroundColor(this.theme.colors.card)
                .borderRadius(9)
                .onChange((v: string): void => {
                  this.eInclude = v;
                })
              this.EditHint('多个关键字用 | 分隔，支持正则表达式')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 9 })

            Column() {
              this.EditLabel('排除')
              TextInput({ text: this.eExclude, placeholder: '关键字或正则，命中就跳过' })
                .height(40)
                .fontSize(this.theme.fs(13))
                .backgroundColor(this.theme.colors.card)
                .borderRadius(9)
                .onChange((v: string): void => {
                  this.eExclude = v;
                })
              this.EditHint('多个关键字用 | 分隔，支持正则表达式')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 9 })

            Column() {
              this.EditLabel('优先级规则组')
              EditPickerRowCell({
                value: this.eRuleGroups.length === 0
                  ? (this.state.subscribeRuleGroups.length === 0 ? '未配置规则组' : '不选使用系统设置')
                  : this.eRuleGroups.join('、'),
                onTap: (): void => {
                  if (this.state.subscribeRuleGroups.length === 0) {
                    return;
                  }
                  const opts: SubscribeOption[] = [];
                  for (const g of this.state.subscribeRuleGroups) {
                    opts.push(new SubscribeOption(g, g));
                  }
                  this.openPicker('rules', '优先级规则组', opts, this.eRuleGroups, true, false);
                }
              })
              this.EditHint('按选定的过滤规则组对订阅进行过滤')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 9 })

            Column() {
              this.EditLabel('自定义类别')
              TextInput({ text: this.eMediaCategory, placeholder: '留空自动识别' })
                .height(40)
                .fontSize(this.theme.fs(13))
                .backgroundColor(this.theme.colors.card)
                .borderRadius(9)
                .onChange((v: string): void => {
                  this.eMediaCategory = v;
                })
              this.EditHint('指定类别名称，留空自动识别')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 9 })

            Column() {
              this.EditLabel('自定义识别词')
              TextArea({ text: this.eCustomWords, placeholder: '只对这条订阅生效的识别词' })
                .height(84)
                .fontSize(this.theme.fs(13))
                .backgroundColor(this.theme.colors.card)
                .borderRadius(9)
                .onChange((v: string): void => {
                  this.eCustomWords = v;
                })
              this.EditHint('替换词：前置词 <=> 替换词；被替换词 <=> 替换词 & 前定位词 <=> 后定位词 & 集数偏移（EP）。替换词支持 {imdbid/doubanid/bangumiid/animelistid=xxx&type=movie/tv&g=xxxxx&e=xxxxx} 直接指定媒体数据源 ID，其中 g 为剧集组编号，s、e 为季数和集数（均可选）。只对这条订阅生效。')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 9 })
            }
          }, (tab: number): string => `edit-tab-${tab}`)
          Blank().height(10)
        }
        .width('100%')
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)

      // 底部操作：不跟着内容滚；bottom 必须加 bottomInset 避让底部悬浮 TabBar，
      // 否则按钮会被 TabBar 完全盖住看不到（曾因此被报「按钮不见了」）
      Row() {
        Text('取消订阅')
          .fontSize(this.theme.fs(13))
          .fontColor(Palette.red)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(withAlpha(Palette.red, 0x1F))
          .borderRadius(13)
          .onClick((): void => {
            this.confirmDeleteSub = sub;
          })
        Blank().width(10)
        Text(this.eSaving ? '保存中…' : '保存')
          .fontSize(this.theme.fs(14))
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(this.eSaving ? withAlpha(Palette.blue, 0x80) : Palette.blue)
          .borderRadius(13)
          .onClick((): void => {
            this.saveEdit();
          })
      }
      .width('100%')
      .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 18 + this.bottomInset })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.colors.background)
  }

  /**
   * 站点回显：`已选 4 个：憨憨、馒头、听听歌、高清杜比`。
   *
   * 带个数是为了「一眼确认多选真的生效」——之前多选完只显示一个站点，
   * 用户根本判断不出是没存上还是只选中了一个。
   */
  private eSiteSummary(): string {
    const n: number = this.eSites.length;
    if (n === 0) {
      return '不选使用系统设置';
    }
    const names: string[] = [];
    for (const id of this.eSites) {
      let hit: string = '';
      for (const site of this.state.site.sites) {
        if (site.id === id) {
          hit = site.name.length > 0 ? site.name : site.domain;
          break;
        }
      }
      // 站点列表还没加载完 / 站点已被删：给出可辨认的兜底，不要静默丢名字
      names.push(hit.length > 0 ? hit : `站点${id}`);
    }
    return `已选 ${n} 个：${names.join('、')}`;
  }

  private openSitePicker(): void {
    const opts: SubscribeOption[] = [];
    for (const site of this.editableSites()) {
      opts.push(new SubscribeOption(site.name, String(site.id)));
    }
    const picked: string[] = [];
    for (const id of this.eSites) {
      picked.push(String(id));
    }
    this.openPicker('sites', '订阅站点', opts, picked, true, true);
  }

  private pickerVisibleIndexes(): number[] {
    const out: number[] = [];
    const q: string = this.pickerQuery.trim().toLowerCase();
    for (let i = 0; i < this.pickerLabels.length; i++) {
      if (q.length === 0 || this.pickerLabels[i].toLowerCase().indexOf(q) >= 0) {
        out.push(i);
      }
    }
    return out;
  }

  @Builder
  PickerOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(GLASS_MASK)
        .onClick((): void => {
          this.pickerOpen = false;
        })

      Column() {
        Text(this.pickerTitle)
          .fontSize(this.theme.fs(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
          .width('100%')

        if (this.pickerSearchable) {
          TextInput({ text: this.pickerQuery, placeholder: '搜索…' })
            .height(38)
            .fontSize(this.theme.fs(13))
            .backgroundColor(this.theme.colors.background)
            .borderRadius(9)
            .margin({ top: 10 })
            .onChange((v: string): void => {
              this.pickerQuery = v;
            })
        }

        /*
         * 用 Scroll + Column 而不是 List + layoutWeight：
         * layoutWeight 会把列表撑满卡片剩余高度，选项只有三五个时弹窗下半截全是空白。
         * 现在列表按内容高度收缩，超过上限才滚。
         */
        Scroll() {
          Column() {
            ForEach(this.pickerVisibleIndexes(), (index: number): void => {
              Row() {
                Text(this.pickerLabels[index])
                  .fontSize(this.theme.fs(13))
                  .fontColor(this.theme.colors.textPrimary)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.pickerPicked.indexOf(this.pickerValues[index]) >= 0) {
                  Text('✓')
                    .fontSize(this.theme.fs(14))
                    .fontColor(Palette.purple)
                    .fontWeight(FontWeight.Bold)
                }
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 11, bottom: 11 })
              .borderRadius(9)
              .onClick((): void => {
                const v: string = this.pickerValues[index];
                const has: boolean = this.pickerPicked.indexOf(v) >= 0;
                if (this.pickerMulti) {
                  const next: string[] = [];
                  for (const p of this.pickerPicked) {
                    if (p !== v) {
                      next.push(p);
                    }
                  }
                  if (!has) {
                    next.push(v);
                  }
                  this.pickerPicked = next;
                } else {
                  this.pickerPicked = [v];
                }
              })
            }, (index: number): string =>
            `${index}-${this.pickerPicked.indexOf(this.pickerValues[index]) >= 0 ? 1 : 0}`)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .constraintSize({ maxHeight: PICKER_LIST_MAX_HEIGHT })
        .margin({ top: 8 })
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)

        // 操作区统一靠右下：次操作（取消/关闭）在左，主操作（确定）在右，符合 App 内其余弹窗
        Row() {
          if (this.pickerMulti && this.pickerPicked.length > 0) {
            Text('清空选择')
              .fontSize(this.theme.fs(12))
              .fontColor(Palette.red)
              .onClick((): void => {
                this.pickerPicked = [];
              })
          }
          Blank()
          Text(this.pickerMulti ? '取消' : '关闭')
            .fontSize(this.theme.fs(14))
            .fontColor(this.theme.colors.textPrimary)
            .textAlign(TextAlign.Center)
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .borderRadius(9)
            .backgroundColor(ghostFill(this.theme.colors.textPrimary))
            .onClick((): void => {
              this.pickerOpen = false;
            })
          Text('确定')
            .fontSize(this.theme.fs(14))
            .fontWeight(FontWeight.Medium)
            .fontColor(0xFFFFFFFF)
            .textAlign(TextAlign.Center)
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            .borderRadius(9)
            .backgroundColor(Palette.blue)
            .margin({ left: 8 })
            .onClick((): void => {
              this.confirmPicker();
            })
        }
        .width('100%')
        .margin({ top: 12 })
        .alignItems(VerticalAlign.Center)
      }
      .width('86%')
      .constraintSize({ maxHeight: '68%' })
      .padding(18)
      // 毛玻璃：与 DialogHost 同一套材质（半透明 + 背景虚化 + 细描边）
      .backgroundColor(glassCard(this.theme.colors.card))
      .border({ width: 0.5, color: withAlpha(this.theme.colors.textPrimary, 0x14) })
      .shadow({ radius: 26, color: 'rgba(0,0,0,0.22)', offsetX: 0, offsetY: 10 })
      .borderRadius(20)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SubscribePanelOverlay(panel: SubscribePanel) {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(GLASS_MASK)
        .onClick((): void => {
          this.vm.closeSubscribePanel();
        })

      Column() {
        Text(panel.title)
          .fontSize(this.theme.fs(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
          .width('100%')

        if (panel.loading) {
          Text('加载中…')
            .fontSize(this.theme.fs(12))
            .fontColor(this.theme.colors.textSecondary)
            .margin({ top: 14 })
        } else if (panel.error.length > 0) {
          Text(panel.error)
            .fontSize(this.theme.fs(12))
            .fontColor(Palette.red)
            .margin({ top: 14 })
        } else {
          Scroll() {
            Column() {
              ForEach(panel.lines, (line: string): void => {
                Text(line)
                  .fontSize(this.theme.fs(12))
                  .fontColor(this.theme.colors.textPrimary)
                  .width('100%')
                  .margin({ bottom: 6 })
              }, (line: string, index: number): string => `${index}-${line}`)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .constraintSize({ maxHeight: 420 })
          .margin({ top: 12 })
          .align(Alignment.TopStart)
          .scrollBar(BarState.Off)
        }

        Text('关闭')
          .fontSize(this.theme.fs(14))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
          .textAlign(TextAlign.Center)
          .alignSelf(ItemAlign.End)
          .padding({ left: 22, right: 22, top: 10, bottom: 10 })
          .borderRadius(9)
          .backgroundColor(ghostFill(this.theme.colors.textPrimary))
          .margin({ top: 12 })
          .onClick((): void => {
            this.vm.closeSubscribePanel();
          })
      }
      .width('86%')
      .constraintSize({ maxHeight: '68%' })
      .padding(18)
      // 毛玻璃：与 DialogHost 同一套材质（半透明 + 背景虚化 + 细描边）
      .backgroundColor(glassCard(this.theme.colors.card))
      .border({ width: 0.5, color: withAlpha(this.theme.colors.textPrimary, 0x14) })
      .shadow({ radius: 26, color: 'rgba(0,0,0,0.22)', offsetX: 0, offsetY: 10 })
      .borderRadius(20)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  ConfirmOverlay(title: string, message: string, confirmText: string, onConfirm: () => void) {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(GLASS_MASK)
        .onClick((): void => {
          this.confirmDeleteSub = null;
          this.confirmResetSub = null;
        })

      Column() {
        Text(title)
          .fontSize(this.theme.fs(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
          .width('100%')
        Text(message)
          .fontSize(this.theme.fs(13))
          .fontColor(this.theme.colors.textPrimary)
          .width('100%')
          .margin({ top: 10 })
          .lineHeight(this.theme.fs(20))

        Row() {
          Blank()
          Text('再想想')
            .fontSize(this.theme.fs(14))
            .fontColor(this.theme.colors.textPrimary)
            .textAlign(TextAlign.Center)
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .borderRadius(9)
            .backgroundColor(ghostFill(this.theme.colors.textPrimary))
            .onClick((): void => {
              this.confirmDeleteSub = null;
              this.confirmResetSub = null;
            })
          Text(confirmText)
            .fontSize(this.theme.fs(14))
            .fontWeight(FontWeight.Medium)
            .fontColor(0xFFFFFFFF)
            .textAlign(TextAlign.Center)
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            .borderRadius(9)
            .backgroundColor(Palette.red)
            .margin({ left: 8 })
            .onClick((): void => {
              onConfirm();
            })
        }
        .width('100%')
        .margin({ top: 12 })
        .alignItems(VerticalAlign.Center)
      }
      .width('82%')
      .padding(18)
      .backgroundColor(glassCard(this.theme.colors.card))
      .border({ width: 0.5, color: withAlpha(this.theme.colors.textPrimary, 0x14) })
      .shadow({ radius: 26, color: 'rgba(0,0,0,0.22)', offsetX: 0, offsetY: 10 })
      .borderRadius(20)
    }
    .width('100%')
    .height('100%')
  }
}
