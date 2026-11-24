import { AppTheme, Palette, Metrics, withAlpha } from '../../common/Theme';
import { formatBytes, formatRelativeTime } from '../../common/Format';
import { MpMedia, MpServer, MpResource, ResourceFilter, ResourceSortField, resourceSortFieldLabel } from '../../model/MpModels';
import { MpViewModel, MpState } from '../../vm/MpViewModel';
import { OiiCard, ElevatedCard, TinyPill, SelectablePill, EmptyHint } from '../components/Common';
import { PosterImage } from '../components/PosterImage';

/**
 * 媒体详情页（对应安卓 ui/moviepilot/MediaDetailScreen.kt）：
 * 海报+信息+订阅/搜资源 → 简介 → 演职员 → 候选资源（排序菜单 + 筛选底部面板 + 投递底部面板）。
 * NavDestination：参数为 MpMedia，进入时调 vm.openDetail。
 */

function posterFallbackA(seed: string): number {
  const palettesA: number[] = [0xFF2F6FED, 0xFF0EA5A4, 0xFFF97316, 0xFF6D28D9, 0xFF059669];
  let h: number = 0;
  for (let i = 0; i < seed.length; i++) {
    h = (h * 31 + seed.charCodeAt(i)) | 0;
  }
  return palettesA[Math.abs(h) % palettesA.length];
}

function posterFallbackB(seed: string): number {
  const palettesB: number[] = [0xFF7B4BF5, 0xFF2F6FED, 0xFFDB2777, 0xFF1D4ED8, 0xFF0891B2];
  let h: number = 0;
  for (let i = 0; i < seed.length; i++) {
    h = (h * 31 + seed.charCodeAt(i)) | 0;
  }
  return palettesB[Math.abs(h) % palettesB.length];
}

@Component
export struct MediaDetailPage {
  @Consume('oiiTheme') theme: AppTheme;
  @Consume('navStack') navStack: NavPathStack;
  private vm: MpViewModel = MpViewModel.getInstance();
  @State state: MpState = new MpState();
  @State expandOverview: boolean = true;
  @State posterFailed: boolean = false;
  @State showFilter: boolean = false;
  @State downloadTarget: MpResource | null = null;

  // 筛选面板（多选，空数组 = 全部）；点一下即生效，无需“应用”
  @State draftSite: string[] = [];
  @State draftResolution: string[] = [];
  @State draftQuality: string[] = [];
  @State draftCodec: string[] = [];
  @State draftSubtitle: string[] = [];
  @State draftGroup: string[] = [];
  @State draftPromotion: string[] = [];
  @State draftPromotionOnly: boolean = false;
  @State draftHideHitAndRun: boolean = false;

  /** 系统导航条高度（Index 广播）：筛选面板底部要让开小白条 */
  @StorageProp('sysBottomSafeVp') bottomSafeVp: number = 0;
  /** 屏幕高度（vp）：算筛选面板滚动区最多能有多高 */
  @StorageProp('sysScreenHeightVp') screenHeightVp: number = 800;

  // 投递面板选择
  @State pickDownloader: string = '';
  @State pickSavePath: string = '';

  private listener: () => void = (): void => {
    this.state = this.vm.state;
  };

  aboutToAppear(): void {
    this.vm.subscribe(this.listener);
    this.state = this.vm.state;
  }

  aboutToDisappear(): void {
    this.vm.unsubscribe(this.listener);
  }

  private detail(): MpMedia | null {
    return this.state.detail;
  }

  private subscribed(): boolean {
    return this.state.isSubscribed(this.state.detail);
  }

  /** 排序菜单项（ResourceSortField 枚举值列表） */
  private sortFields(): ResourceSortField[] {
    return [
      ResourceSortField.RELEVANCE, ResourceSortField.SEEDERS, ResourceSortField.PUBLISH_TIME,
      ResourceSortField.SIZE, ResourceSortField.SITE
    ];
  }

  private pickSort(field: ResourceSortField): void {
    const f: ResourceFilter = this.copyFilter();
    const same: boolean = f.sortField === field;
    f.sortField = field;
    f.descending = same ? !f.descending : true;
    this.vm.updateFilter(f);
  }

  private copyFilter(): ResourceFilter {
    const src: ResourceFilter = this.state.filter;
    const f: ResourceFilter = new ResourceFilter();
    f.site = src.site.slice(0);
    f.resolution = src.resolution.slice(0);
    f.quality = src.quality.slice(0);
    f.codec = src.codec.slice(0);
    f.subtitle = src.subtitle.slice(0);
    f.group = src.group.slice(0);
    f.promotion = src.promotion.slice(0);
    f.promotionOnly = src.promotionOnly;
    f.hideHitAndRun = src.hideHitAndRun;
    f.sortField = src.sortField;
    f.descending = src.descending;
    return f;
  }

  private openFilterSheet(): void {
    this.draftSite = this.state.filter.site.slice(0);
    this.draftResolution = this.state.filter.resolution.slice(0);
    this.draftQuality = this.state.filter.quality.slice(0);
    this.draftCodec = this.state.filter.codec.slice(0);
    this.draftSubtitle = this.state.filter.subtitle.slice(0);
    this.draftGroup = this.state.filter.group.slice(0);
    this.draftPromotion = this.state.filter.promotion.slice(0);
    this.draftPromotionOnly = this.state.filter.promotionOnly;
    this.draftHideHitAndRun = this.state.filter.hideHitAndRun;
    this.showFilter = true;
  }

  /** 把面板里的选择立刻写回筛选条件（实时生效，列表在面板后方同步变化） */
  private applyLive(): void {
    this.vm.updateFilter(this.buildFilter());
  }

  private buildFilter(): ResourceFilter {
    const f: ResourceFilter = new ResourceFilter();
    f.site = this.draftSite.slice(0);
    f.resolution = this.draftResolution.slice(0);
    f.quality = this.draftQuality.slice(0);
    f.codec = this.draftCodec.slice(0);
    f.subtitle = this.draftSubtitle.slice(0);
    f.group = this.draftGroup.slice(0);
    f.promotion = this.draftPromotion.slice(0);
    f.promotionOnly = this.draftPromotionOnly;
    f.hideHitAndRun = this.draftHideHitAndRun;
    f.sortField = this.state.filter.sortField;
    f.descending = this.state.filter.descending;
    return f;
  }

  /** 多选切换：已选则取消，未选则追加；返回新数组以驱动刷新 */
  private toggleValue(list: string[], value: string): string[] {
    const next: string[] = list.slice(0);
    const at: number = next.indexOf(value);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(value);
    }
    return next;
  }

  private openDownloadSheet(target: MpResource): void {
    this.downloadTarget = target;
    this.pickDownloader = this.state.downloaders.length > 0 ? this.state.downloaders[0].name : '';
    this.pickSavePath = this.state.savePaths.length > 0 ? this.state.savePaths[0].savePath : '';
    this.vm.loadDownloadOptions();
  }

  private confirmDownload(): void {
    const target: MpResource | null = this.downloadTarget;
    if (target !== null) {
      this.vm.download(target, this.pickDownloader, this.pickSavePath);
    }
    this.downloadTarget = null;
  }

  private infoLine(media: MpMedia): string {
    const parts: string[] = [];
    if (media.yearLabel().length > 0) {
      parts.push(media.yearLabel());
    }
    parts.push(media.typeLabel());
    return parts.join(' · ');
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          if (this.state.detail === null) {
            EmptyHint({ text: '条目不存在' })
          } else {
            this.DetailBody()
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.theme.colors.background)

        // 筛选底部面板
        if (this.showFilter) {
          this.FilterSheet()
        }

        // 投递底部面板
        if (this.downloadTarget !== null) {
          this.DownloadSheet()
        }
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.Bottom)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext): void => {
      const param: Object | undefined = ctx.pathInfo.param as Object | undefined;
      if (param instanceof MpMedia) {
        this.vm.openDetail(param as MpMedia);
      }
    })
    .onBackPressed((): boolean => {
      if (this.showFilter) {
        this.showFilter = false;
        return true;
      }
      if (this.downloadTarget !== null) {
        this.downloadTarget = null;
        return true;
      }
      return false;
    })
  }

  // ---------- 主体 ----------

  @Builder
  DetailBody() {
    List() {
      // 头部
      ListItem() {
        Row() {
          Text('←')
            .fontSize(20)
            .fontColor(this.theme.colors.textPrimary)
            .padding(4)
            .onClick((): void => {
              this.navStack.pop();
            })
          Blank().width(10)
          Text(this.detail() !== null ? (this.detail() as MpMedia).title : '')
            .fontSize(this.theme.fs(17))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .margin({ bottom: 12 })

      // 海报 + 基本信息
      ListItem() {
        this.PosterInfoSection()
      }
      .margin({ bottom: 12 })

      // 简介
      if (this.detail() !== null && (this.detail() as MpMedia).overview.length > 0) {
        ListItem() {
          ElevatedCard({ paddingVp: 13, subtle: true, radiusVp: 18 }) {
            Column() {
              Text((this.detail() as MpMedia).overview)
                .fontSize(this.theme.fs(12))
                .fontColor(this.theme.colors.textSecondary)
                .lineHeight(this.theme.fs(18))
                .maxLines(this.expandOverview ? 100 : 4)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.expandOverview ? '收起' : '展开')
                .fontSize(this.theme.fs(11))
                .fontColor(Palette.blue)
                .margin({ top: 4 })
                .onClick((): void => {
                  this.expandOverview = !this.expandOverview;
                })
            }
            .alignItems(HorizontalAlign.Start)
          }
        }
        .margin({ bottom: 12 })
      }

      // 演职员
      if (this.hasCredits()) {
        ListItem() {
          ElevatedCard({ paddingVp: 13, subtle: true, radiusVp: 18 }) {
            Column() {
              Text('演职员')
                .fontSize(this.theme.fs(13))
                .fontWeight(FontWeight.Medium)
                .fontColor(this.theme.colors.textPrimary)
              Blank().height(6)
              Text(this.creditsText())
                .fontSize(this.theme.fs(11))
                .fontColor(this.theme.colors.textSecondary)
                .lineHeight(this.theme.fs(17))
            }
            .alignItems(HorizontalAlign.Start)
          }
        }
        .margin({ bottom: 12 })
      }

      // 资源区标题 + 排序/筛选
      ListItem() {
        Row() {
          Text('候选资源')
            .fontSize(this.theme.fs(16))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
          Blank().width(6)
          Text(this.state.resources.length === 0 ? '' :
            `${this.state.filteredResources().length}/${this.state.resources.length}`)
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
          Blank()
          if (this.state.resourceSearched) {
            // 排序按钮（下拉菜单）
            Row() {
              Text(resourceSortFieldLabel(this.state.filter.sortField))
                .fontSize(this.theme.fs(11))
                .fontColor(this.theme.colors.textPrimary)
              Text(this.state.filter.descending ? ' ↓' : ' ↑')
                .fontSize(this.theme.fs(11))
                .fontColor(this.theme.colors.textSecondary)
            }
            .backgroundColor(this.theme.colors.card)
            .borderRadius(10)
            .padding({ left: 9, right: 9, top: 6, bottom: 6 })
            .bindMenu(this.sortMenuItems())

            Blank().width(8)
            // 筛选按钮
            Row() {
              Text('⚙')
                .fontSize(12)
                .fontColor(this.state.filter.activeCount() > 0 ? Palette.blue : this.theme.colors.textSecondary)
              if (this.state.filter.activeCount() > 0) {
                Blank().width(3)
                Text(String(this.state.filter.activeCount()))
                  .fontSize(this.theme.fs(11))
                  .fontColor(Palette.blue)
              }
            }
            .backgroundColor(this.state.filter.activeCount() > 0
              ? withAlpha(Palette.blue, 0x24) : this.theme.colors.card)
            .borderRadius(10)
            .padding({ left: 9, right: 9, top: 6, bottom: 6 })
            .onClick((): void => {
              this.openFilterSheet();
            })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .margin({ bottom: 12 })

      // 搜索进度
      if (this.state.resourcesLoading) {
        ListItem() {
          Column() {
            LoadingProgress().width(28).height(28).color(Palette.blue)
            Blank().height(10)
            Text(this.state.searchStage.length > 0 ? this.state.searchStage : '正在向各站点发起搜索…')
              .fontSize(this.theme.fs(12))
              .fontColor(this.theme.colors.textSecondary)
            if (this.state.resources.length > 0) {
              Blank().height(4)
              Text(`已返回 ${this.state.resources.length} 个`)
                .fontSize(this.theme.fs(11))
                .fontColor(Palette.green)
            }
            Blank().height(6)
            Text('站点多时可能要几十秒，可以边等边看')
              .fontSize(this.theme.fs(10))
              .fontColor(this.theme.colors.textSecondary)
          }
          .width('100%')
          .padding({ top: 24, bottom: 24 })
          .alignItems(HorizontalAlign.Center)
        }
      }

      // 还没搜过时的占位提示
      if (!this.state.resourcesLoading && !this.state.resourceSearched &&
        this.state.resources.length === 0 && this.state.resourceError.length === 0) {
        ListItem() {
          Column() {
            Text('🔎').fontSize(26)
            Blank().height(10)
            Text('还没搜索资源')
              .fontSize(this.theme.fs(13))
              .fontColor(this.theme.colors.textPrimary)
            Blank().height(4)
            Text('想找片源时，点上面的「搜资源」再开始搜索。')
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
          }
          .width('100%')
          .padding({ top: 26, bottom: 26 })
          .alignItems(HorizontalAlign.Center)
        }
      }

      // 错误提示
      if (this.state.resourceError.length > 0) {
        ListItem() {
          OiiCard({ paddingVp: 12 }) {
            Column() {
              Text(this.state.resourceError)
                .fontSize(this.theme.fs(12))
                .fontColor(Palette.red)
                .lineHeight(this.theme.fs(18))
              if (this.state.server() !== null && !(this.state.server() as MpServer).hasLogin()) {
                Blank().height(4)
                Text('提示：MP 只填 API Token 时用的是阻塞式搜索，要等所有站点搜完才出结果；填上 MP 用户名密码可以改成边搜边显示。')
                  .fontSize(this.theme.fs(11))
                  .fontColor(this.theme.colors.textSecondary)
                  .lineHeight(this.theme.fs(17))
              }
            }
            .alignItems(HorizontalAlign.Start)
          }
        }
        .margin({ bottom: 12 })
      }

      // 筛选后为空
      if (!this.state.resourcesLoading && this.state.filteredResources().length === 0 &&
        this.state.resourceError.length === 0 && this.state.resources.length > 0) {
        ListItem() {
          EmptyHint({ text: '当前筛选条件下没有资源，试试放宽条件' })
        }
      }

      // 资源行
      ForEach(this.state.filteredResources(), (resource: MpResource): void => {
        ListItem() {
          this.ResourceRow(resource)
        }
        // 行间距：之前 2 太贴，长列表像一整块（用户反馈「鸿蒙种子列表有点挤」）
        .margin({ bottom: 10 })
      }, (resource: MpResource): string => resource.key)
    }
    .layoutWeight(1)
    .width('100%')
    // 全屏详情页没有迷你条/TabBar 遮挡，底部只留手势条空隙（之前 110 会在列表底部留一大块空白）
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 8, bottom: 24 })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  PosterInfoSection() {
    Row() {
      // 海报
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 135,
            colors: [
              [posterFallbackA(this.detail() !== null ? (this.detail() as MpMedia).title : 'x'), 0.0],
              [posterFallbackB(this.detail() !== null ? (this.detail() as MpMedia).title : 'x'), 1.0]
            ]
          })
        if (this.detail() !== null && (this.detail() as MpMedia).posterUrl.length > 0 && !this.posterFailed) {
          PosterImage({
            url: (this.detail() as MpMedia).posterUrl,
            onFailed: (): void => {
              this.posterFailed = true;
            }
          })
        }
        if (this.detail() !== null && ((this.detail() as MpMedia).posterUrl.length === 0 || this.posterFailed)) {
          Text((this.detail() as MpMedia).title)
            .fontSize(11)
            .fontColor(0xFFFFFFFF)
            .textAlign(TextAlign.Center)
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding(6)
        }
      }
      .width(96)
      .aspectRatio(0.68)
      .borderRadius(10)
      .clip(true)

      Blank().width(12)
      Column() {
        Text(this.detail() !== null ? (this.detail() as MpMedia).title : '')
          .fontSize(this.theme.fs(18))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank().height(4)
        Row() {
          Text(this.detail() !== null ? this.infoLine(this.detail() as MpMedia) : '')
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
          if (this.detail() !== null && (this.detail() as MpMedia).vote > 0) {
            Blank().width(6)
            Text(`★ ${(this.detail() as MpMedia).vote.toFixed(1)}`)
              .fontSize(this.theme.fs(11))
              .fontColor(0xFFFF9500)
          }
        }
        .alignItems(VerticalAlign.Center)
        if (this.detail() !== null && (this.detail() as MpMedia).genres.length > 0) {
          Blank().height(6)
          Text(this.genreText())
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.detail() !== null && (this.detail() as MpMedia).directors.length > 0) {
          Blank().height(4)
          Text(`导演：${(this.detail() as MpMedia).directors.slice(0, 2).join('、')}`)
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.detail() !== null && (this.detail() as MpMedia).cast.length > 0) {
          Blank().height(2)
          Text(`主演：${(this.detail() as MpMedia).cast.slice(0, 3).join('、')}`)
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Blank().height(8)
        Row() {
          Text(this.subscribed() ? '已订阅' : '订阅')
            .fontSize(this.theme.fs(12))
            .fontColor(this.subscribed() ? Palette.green : 0xFFFFFFFF)
            .backgroundColor(this.subscribed() ? withAlpha(Palette.green, 0x24) : Palette.blue)
            .borderRadius(10)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .onClick((): void => {
              if (!this.subscribed() && this.state.detail !== null) {
                this.vm.subscribeMedia(this.state.detail, this.state.detail.season);
              }
            })
          Blank().width(8)
          Row() {
            Text('⟳')
              .fontSize(12)
              .fontColor(Palette.blue)
            Blank().width(4)
            Text(this.resourcesButtonLabel())
              .fontSize(this.theme.fs(12))
              .fontColor(Palette.blue)
          }
          .alignItems(VerticalAlign.Center)
          .backgroundColor(withAlpha(Palette.blue, 0x1F))
          .borderRadius(10)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .onClick((): void => {
            this.vm.searchResources();
          })
        }
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 排序菜单（数组式 bindMenu：点击直接弹出） */
  private sortMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    for (const field of this.sortFields()) {
      const f: ResourceSortField = field;
      items.push({
        value: resourceSortFieldLabel(field),
        action: (): void => {
          this.pickSort(f);
        }
      });
    }
    return items;
  }

  /** 促销文案（免费 / 50% / 2X）判定 */
  private isPromoText(t: string): boolean {
    if (t.indexOf('免费') >= 0 || t.indexOf('%') >= 0) {
      return true;
    }
    return /^[0-9.]+X/.test(t);
  }

  /** 标签底色：促销橙绿、H&R 红、制作组灰、分辨率紫、来源靛、字幕/效果蓝 */
  private pillBg(text: string, r: MpResource): number {
    if (this.isPromoText(text)) {
      return text.indexOf('免费') >= 0 ? withAlpha(Palette.green, 0x26) : withAlpha(Palette.orange, 0x24);
    }
    if (text === 'H&R' || text.indexOf('禁') >= 0) {
      return withAlpha(Palette.red, 0x1F);
    }
    if (text === r.group()) {
      return withAlpha(this.theme.colors.textSecondary, 0x1C);
    }
    if (text === r.resolution()) {
      return withAlpha(Palette.purple, 0x1F);
    }
    if (text === r.quality()) {
      return withAlpha(Palette.indigo, 0x1F);
    }
    return withAlpha(Palette.blue, 0x1A);
  }

  private pillFg(text: string, r: MpResource): number {
    if (this.isPromoText(text)) {
      return text.indexOf('免费') >= 0 ? Palette.green : Palette.orange;
    }
    if (text === 'H&R' || text.indexOf('禁') >= 0) {
      return Palette.red;
    }
    if (text === r.group()) {
      return this.theme.colors.textSecondary;
    }
    if (text === r.resolution()) {
      return Palette.purple;
    }
    if (text === r.quality()) {
      return Palette.indigo;
    }
    return Palette.blue;
  }

  @Builder
  ResourceRow(resource: MpResource) {
    ElevatedCard({ paddingVp: 13, subtle: true, radiusVp: 16 }) {
      Column() {
        Text(resource.title)
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(this.theme.fs(17))
        Blank().height(6)
        // 标签行（对齐 MP 搜索结果）：
        // MP labels（中字/国语/特效…）→ 分辨率 → 来源 → 制作组 → 促销/免费，
        // 顺序和配色都在 MpResource.badges() 里定好，这里只负责画。
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
          justifyContent: FlexAlign.Start }) {
          Row() {
            TinyPill({ text: resource.siteName, bgColor: withAlpha(Palette.blue, 0x1F), fgColor: Palette.blue })
          }
          .margin({ right: 4, bottom: 4 })
          ForEach(resource.badges(), (text: string): void => {
            Row() {
              TinyPill({ text: text, bgColor: this.pillBg(text, resource), fgColor: this.pillFg(text, resource) })
            }
            .margin({ right: 4, bottom: 4 })
          }, (text: string, idx: number): string => `bd-${idx}-${text}`)
        }
        .width('100%')

        // 副标题：站点 description 优先（站点种子页那一行），搜索接口不给时用「小组·来源·编码」兜底
        if (resource.subtitle().length > 0) {
          Text(resource.subtitle())
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(this.theme.fs(15))
            .margin({ top: 4 })
            .width('100%')
        }
        Blank().height(6)
        Row() {
          // 信息组占满剩余宽度并裁切，「下载」按钮永远贴右边
          Row() {
            Text(formatBytes(resource.sizeBytes))
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
              .maxLines(1)
            Text(` · 种 ${resource.seeders}`)
              .fontSize(this.theme.fs(11))
              .fontColor(Palette.green)
              .maxLines(1)
            Text(` · 下 ${resource.peers}`)
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
              .maxLines(1)
            if (resource.pubDateMs > 0) {
              Text(` · ${formatRelativeTime(resource.pubDateMs)}`)
                .fontSize(this.theme.fs(11))
                .fontColor(this.theme.colors.textSecondary)
                .maxLines(1)
            }
          }
          .layoutWeight(1)
          .clip(true)
          .alignItems(VerticalAlign.Center)
          Text('下载')
            .fontSize(this.theme.fs(11))
            .fontColor(0xFFFFFFFF)
            .backgroundColor(Palette.blue)
            .borderRadius(10)
            .padding({ left: 11, right: 11, top: 5, bottom: 5 })
            .margin({ left: 8 })
            .onClick((): void => {
              this.openDownloadSheet(resource);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
    }
  }

  // ---------- 筛选底部面板 ----------

  /**
   * 筛选面板滚动区的最大高度。
   *
   * 之前面板整块是一个普通 Column，站点 30+ / 制作组 20+ 时内容超过一屏，
   * 底部的「只看免费 / 促销」「隐藏 H&R」直接被屏幕边缘（和小白条）切掉。
   * 这里给滚动区限高：内容少时按内容高度自适应、不浪费空白；内容多时滚动。
   */
  private filterScrollMax(): number {
    const h: number = this.screenHeightVp > 0 ? this.screenHeightVp : 800;
    return Math.max(240, h * 0.78 - 44 - this.bottomSafeVp);
  }

  @Builder
  FilterSheet() {
    Column() {
      // 点击遮罩关闭
      Column()
        .width('100%')
        .layoutWeight(1)
        .onClick((): void => {
          this.showFilter = false;
        })

      Column() {
        Row() {
          Text('筛选资源')
            .fontSize(this.theme.fs(17))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
          Blank()
          Text('重置')
            .fontSize(this.theme.fs(13))
            .fontColor(this.theme.colors.textSecondary)
            .padding(6)
            .onClick((): void => {
              this.draftSite = [];
              this.draftResolution = [];
              this.draftQuality = [];
              this.draftCodec = [];
              this.draftSubtitle = [];
              this.draftGroup = [];
              this.draftPromotion = [];
              this.draftPromotionOnly = false;
              this.draftHideHitAndRun = false;
              this.applyLive();
            })
          Text('完成')
            .fontSize(this.theme.fs(13))
            .fontColor(Palette.blue)
            .padding(6)
            .onClick((): void => {
              // 只收起面板，筛选早在点选时就已生效
              this.showFilter = false;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 内容区可滚动：标题行固定，下面的筛选组多了就滚，不再被屏幕切掉
        Scroll() {
          Column() {
            if (this.state.sites().length > 0) {
              FilterChipGroup({
                title: '站点',
                options: this.state.sites(),
                selected: this.draftSite,
                onToggle: (v: string): void => {
                  this.draftSite = this.toggleValue(this.draftSite, v);
                  this.applyLive();
                },
                onClear: (): void => {
                  this.draftSite = [];
                  this.applyLive();
                }
              })
            }
            if (this.state.subtitles().length > 0) {
              FilterChipGroup({
                title: '标签',
                options: this.state.subtitles(),
                selected: this.draftSubtitle,
                onToggle: (v: string): void => {
                  this.draftSubtitle = this.toggleValue(this.draftSubtitle, v);
                  this.applyLive();
                },
                onClear: (): void => {
                  this.draftSubtitle = [];
                  this.applyLive();
                }
              })
            }
            if (this.state.groups().length > 0) {
              FilterChipGroup({
                title: '制作组',
                options: this.state.groups(),
                selected: this.draftGroup,
                onToggle: (v: string): void => {
                  this.draftGroup = this.toggleValue(this.draftGroup, v);
                  this.applyLive();
                },
                onClear: (): void => {
                  this.draftGroup = [];
                  this.applyLive();
                }
              })
            }
            if (this.state.promotions().length > 0) {
              FilterChipGroup({
                title: '促销',
                options: this.state.promotions(),
                selected: this.draftPromotion,
                onToggle: (v: string): void => {
                  this.draftPromotion = this.toggleValue(this.draftPromotion, v);
                  this.applyLive();
                },
                onClear: (): void => {
                  this.draftPromotion = [];
                  this.applyLive();
                }
              })
            }
            if (this.state.resolutions().length > 0) {
              FilterChipGroup({
                title: '分辨率',
                options: this.state.resolutions(),
                selected: this.draftResolution,
                onToggle: (v: string): void => {
                  this.draftResolution = this.toggleValue(this.draftResolution, v);
                  this.applyLive();
                },
                onClear: (): void => {
                  this.draftResolution = [];
                  this.applyLive();
                }
              })
            }
            if (this.state.qualities().length > 0) {
              FilterChipGroup({
                title: '质量',
                options: this.state.qualities(),
                selected: this.draftQuality,
                onToggle: (v: string): void => {
                  this.draftQuality = this.toggleValue(this.draftQuality, v);
                  this.applyLive();
                },
                onClear: (): void => {
                  this.draftQuality = [];
                  this.applyLive();
                }
              })
            }
            if (this.state.codecs().length > 0) {
              FilterChipGroup({
                title: '编码',
                options: this.state.codecs(),
                selected: this.draftCodec,
                onToggle: (v: string): void => {
                  this.draftCodec = this.toggleValue(this.draftCodec, v);
                  this.applyLive();
                },
                onClear: (): void => {
                  this.draftCodec = [];
                  this.applyLive();
                }
              })
            }

            Blank().height(10)
            Row() {
              Text('只看免费 / 促销')
                .fontSize(this.theme.fs(13))
                .fontColor(this.theme.colors.textPrimary)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.draftPromotionOnly })
                .selectedColor(Palette.blue)
                .onChange((on: boolean): void => {
                  this.draftPromotionOnly = on;
                  this.applyLive();
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            Row() {
              Text('隐藏 H&R')
                .fontSize(this.theme.fs(13))
                .fontColor(this.theme.colors.textPrimary)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.draftHideHitAndRun })
                .selectedColor(Palette.blue)
                .onChange((on: boolean): void => {
                  this.draftHideHitAndRun = on;
                  this.applyLive();
                })
            }
            .width('100%')
            .margin({ top: 6 })
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .constraintSize({ maxHeight: this.filterScrollMax() })
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .borderRadius({ topLeft: 20, topRight: 20 })
      .backgroundColor(this.theme.colors.background)
      // bottom 补系统导航条高度：否则最后一行「隐藏 H&R」压在小白条底下点不到
      .padding({ left: 16, right: 16, top: 14, bottom: 14 + this.bottomSafeVp })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }

  // ---------- 投递底部面板 ----------

  @Builder
  DownloadSheet() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .onClick((): void => {
          this.downloadTarget = null;
        })

      Column() {
        Text('投递到下载器')
          .fontSize(this.theme.fs(17))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
        Blank().height(6)
        Text(this.downloadTarget !== null ? (this.downloadTarget as MpResource).title : '')
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank().height(4)
        Text(this.downloadTarget !== null
          ? `${(this.downloadTarget as MpResource).siteName} · ${formatBytes((this.downloadTarget as MpResource).sizeBytes)} · ${(this.downloadTarget as MpResource).seeders} 个做种`
          : '')
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)

        if (this.state.downloaders.length > 0) {
          Text('下载器')
            .fontSize(this.theme.fs(12))
            .fontColor(this.theme.colors.textSecondary)
            .margin({ top: 14 })
          SingleChipRow({
            options: this.downloaderNames(),
            selected: this.pickDownloader,
            onSelect: (v: string): void => {
              this.pickDownloader = v;
            }
          })
        }

        if (this.state.savePaths.length > 0) {
          Text('保存路径')
            .fontSize(this.theme.fs(12))
            .fontColor(this.theme.colors.textSecondary)
            .margin({ top: 12 })
          SingleChipRow({
            options: this.savePathValues(),
            selected: this.pickSavePath,
            onSelect: (v: string): void => {
              this.pickSavePath = v;
            }
          })
        }

        Blank().height(18)
        Text('确认下载')
          .fontSize(this.theme.fs(14))
          .fontWeight(FontWeight.Medium)
          .fontColor(0xFFFFFFFF)
          .textAlign(TextAlign.Center)
          .width('100%')
          .backgroundColor(Palette.blue)
          .borderRadius(13)
          .padding({ top: 13, bottom: 13 })
          .onClick((): void => {
            this.confirmDownload();
          })
        Blank().height(8)
        Text('由 MoviePilot 决定投递方式，会带上站点 cookie 与种子原始信息。')
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
      }
      .width('100%')
      .borderRadius({ topLeft: 20, topRight: 20 })
      .backgroundColor(this.theme.colors.background)
      .padding({ left: 16, right: 16, top: 14, bottom: 30 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }

  // ---------- 辅助 ----------

  /**
   * 演职员名单：MP 的 credits 接口优先；
   * 拿不到（接口失败 / 老版本 MP 没有这个接口）时退回详情自带的导演 + 主演，
   * 保证「演职员」这一块不会整块消失。
   */
  private creditNames(): string[] {
    const names: string[] = [];
    for (const p of this.state.credits) {
      if (p.name && p.name.length > 0 && names.indexOf(p.name) < 0) {
        names.push(p.name);
      }
    }
    if (names.length > 0) {
      return names;
    }
    const d: MpMedia | null = this.detail();
    if (d === null) {
      return names;
    }
    const fallback: string[] = d.directors.concat(d.cast);
    for (const n of fallback) {
      if (n && n.length > 0 && names.indexOf(n) < 0) {
        names.push(n);
      }
    }
    return names;
  }

  private hasCredits(): boolean {
    return this.creditNames().length > 0;
  }

  private creditsText(): string {
    const names: string[] = this.creditNames();
    const out: string[] = [];
    const end: number = Math.min(12, names.length);
    for (let i = 0; i < end; i++) {
      out.push(names[i]);
    }
    return out.join('、');
  }

  private genreText(): string {
    if (this.detail() === null) {
      return '';
    }
    const genres: string[] = (this.detail() as MpMedia).genres.slice(0, 4);
    return genres.join(' / ');
  }

  private resourcesButtonLabel(): string {
    if (this.state.resourcesLoading) {
      return '搜索中';
    }
    return this.state.resourceSearched ? '重新搜索' : '搜资源';
  }

  private downloaderNames(): string[] {
    const out: string[] = [];
    for (const d of this.state.downloaders) {
      out.push(d.name);
    }
    return out;
  }

  private savePathValues(): string[] {
    const out: string[] = [];
    for (const p of this.state.savePaths) {
      out.push(p.savePath);
    }
    return out;
  }
}

/**
 * 筛选分组（多选胶囊）。
 * 用独立 @Component + @Prop 而不是 @Builder：
 * - @Builder 按值传参时，父组件状态变了子 UI 不刷新（点了没反应、颜色不变就是这个原因）；
 * - @Prop 数组在父组件换成新数组时会真正下发到子组件。
 */
@Component
struct FilterChipGroup {
  @Consume('oiiTheme') theme: AppTheme;
  title: string = '';
  options: string[] = [];
  @Prop selected: string[] = [];
  onToggle: (v: string) => void = (v: string): void => {
  };
  onClear: () => void = (): void => {
  };

  build() {
    Column() {
      Text(this.title)
        .fontSize(this.theme.fs(12))
        .fontColor(this.theme.colors.textSecondary)
        .margin({ top: 10 })
      // Flex 换行 + 左对齐（横向 Scroll 在内容不满一屏时会把子节点居中）
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
        justifyContent: FlexAlign.Start }) {
        Row() {
          SelectablePill({
            text: '全部',
            selected: this.selected.length === 0,
            onTap: (): void => {
              this.onClear();
            }
          })
        }
        .margin({ right: 6, bottom: 6 })
        ForEach(this.options, (option: string): void => {
          Row() {
            SelectablePill({
              text: option,
              selected: this.selected.indexOf(option) >= 0,
              onTap: (): void => {
                this.onToggle(option);
              }
            })
          }
          .margin({ right: 6, bottom: 6 })
        }, (option: string): string => `${option}-${this.selected.indexOf(option) >= 0 ? 1 : 0}`)
      }
      .width('100%')
      .padding({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 单选胶囊行（下载器 / 保存路径）：同样用 @Component + @Prop，点选后颜色才会变 */
@Component
struct SingleChipRow {
  @Consume('oiiTheme') theme: AppTheme;
  options: string[] = [];
  @Prop selected: string = '';
  onSelect: (v: string) => void = (v: string): void => {
  };

  build() {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
      justifyContent: FlexAlign.Start }) {
      ForEach(this.options, (option: string): void => {
        Row() {
          SelectablePill({
            text: option,
            selected: this.selected === option,
            onTap: (): void => {
              this.onSelect(option);
            }
          })
        }
        .margin({ right: 6, bottom: 6 })
      }, (option: string): string => `${option}-${this.selected === option ? 1 : 0}`)
    }
    .width('100%')
    .padding({ top: 6 })
  }
}
