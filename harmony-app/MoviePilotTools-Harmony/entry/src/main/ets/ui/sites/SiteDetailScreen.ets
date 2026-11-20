import { AppTheme, Palette, Metrics, withAlpha } from '../../common/Theme';
import { MpResource } from '../../model/MpModels';
import { MpSite, MpSiteCategory, SiteSort, siteSortLabel } from '../../model/MpSiteModels';
import { MpSiteState, MpViewModel } from '../../vm/MpViewModel';
import { EmptyHint } from '../components/Common';
import { PosterImage } from '../components/PosterImage';
import { formatStorageSize, formatRelativeTime } from '../../common/Format';
import { SiteAvatar } from './SiteScreen';
import { SiteDownloadSheet } from './SiteDownloadSheet';

/**
 * 站点详情 = 该站种子浏览（对应安卓 ui/sites/SiteDetailScreen.kt）。
 *
 * 关键取舍：
 *  - 分类**单选**（点同一个=取消）。MP 的站点索引器基本只认单值 cat，
 *    多值逗号拼接更容易被整个忽略；
 *  - 排序是**客户端**排序（浏览接口没有 sort 参数），只对已翻下来的几页生效；
 *  - 站点忽略 cat 时如实提示「该站点没有按分类过滤」，不假装成功；
 *  - 浏览是同步阻塞接口，等待时给骨架屏 + 计时，避免用户以为卡死。
 */

/** 保存路径的三档在 SiteDownloadSheet 内部管理，本页只负责开关面板 */

/** 卡片上的小徽标（促销 / 字幕 / 分辨率 / 来源），与安卓 TinyPill 同一套配色 */
class TorrentBadge {
  text: string;
  tint: number;

  constructor(text: string, tint: number) {
    this.text = text;
    this.tint = tint;
  }
}

@Component
export struct SiteDetailPage {
  @Consume('oiiTheme') theme: AppTheme;
  @Consume('navStack') navStack: NavPathStack;
  private vm: MpViewModel = MpViewModel.getInstance();
  @State state: MpSiteState = new MpSiteState();
  @State site: MpSite | null = null;

  // 投递面板
  @State sheetVisible: boolean = false;
  @State sheetResource: MpResource | null = null;
  @State showSortMenu: boolean = false;

  private listener: () => void = (): void => {
    this.state = this.vm.state.site;
  };

  aboutToAppear(): void {
    this.vm.subscribe(this.listener);
    this.state = this.vm.state.site;
  }

  aboutToDisappear(): void {
    this.vm.unsubscribe(this.listener);
  }

  /** NavDestination onReady：拿到站点参数后开始浏览 */
  loadParam(param: Object): void {
    if (param instanceof MpSite) {
      const site: MpSite = param as MpSite;
      this.site = site;
      this.vm.openSite(site);
      this.vm.loadDownloadOptions();
    }
  }

  private siteName(): string {
    return this.site !== null ? this.site.name : '站点';
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          this.Header()
          this.SearchRow()
          if (this.state.categories.length > 0) {
            this.CategoryRow()
          }
          this.SortRow()
          if (this.state.catIgnored) {
            Text('该站点没有按分类过滤，下面仍是全部种子（MP 只对部分站点转发 cat 参数）')
              .fontSize(this.theme.fs(11))
              .fontColor(Palette.orange)
              .width('100%')
              .padding({
                left: Metrics.pagePadding,
                right: Metrics.pagePadding,
                top: 2,
                bottom: 6
              })
          }
          this.Body()
        }
        .width('100%')
        .height('100%')

        if (this.sheetVisible) {
          SiteDownloadSheet({ visible: $sheetVisible, resource: $sheetResource })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.colors.background)
    }
    .hideTitleBar(true)
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.colors.background)
    .onReady((ctx: NavDestinationContext): void => {
      this.loadParam(ctx.pathInfo.param as Object);
    })
    .onBackPressed((): boolean => {
      // 面板开着时，返回键先关面板（符合直觉，也不会误退出页面）
      if (this.sheetVisible) {
        this.sheetVisible = false;
        return true;
      }
      this.vm.closeSite();
      return false;
    })
  }

  @Builder
  Header() {
    Row() {
      Stack() {
        Circle().width(34).height(34).fill(this.theme.colors.card)
        Text('←').fontSize(18).fontColor(this.theme.colors.textPrimary)
      }
      .width(34)
      .height(34)
      .onClick((): void => {
        this.navStack.pop();
      })

      Blank().width(8)
      Row() {
        if (this.site !== null) {
          SiteAvatar({ siteId: this.site.id, name: this.site.name, sizeVp: 28, corner: 8 })
          Blank().width(8)
        }
        Column() {
          Text(this.siteName())
            .fontSize(this.theme.fs(16))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.site !== null && this.site.displayDomain().length > 0) {
            Text(this.site.displayDomain())
              .fontSize(this.theme.fs(10))
              .fontColor(this.theme.colors.textSecondary)
              .maxLines(1)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)

      Text('⟳')
        .fontSize(this.theme.fs(18))
        .fontColor(this.theme.colors.textPrimary)
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .onClick((): void => {
          this.vm.refreshSiteTorrents();
        })
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 8, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SearchRow() {
    Row() {
      Text('🔍').fontSize(14).fontColor(this.theme.colors.textSecondary)
      Blank().width(6)
      TextInput({ text: this.state.searchInput, placeholder: '搜索该站种子…' })
        .fontSize(this.theme.fs(13))
        .fontColor(this.theme.colors.textPrimary)
        .placeholderColor(this.theme.colors.textSecondary)
        .placeholderFont({ size: this.theme.fs(13) })
        .backgroundColor(Color.Transparent)
        .padding(0)
        .layoutWeight(1)
        .enterKeyType(EnterKeyType.Search)
        .onChange((v: string): void => {
          this.vm.updateSiteSearchInput(v);
        })
        .onSubmit((): void => {
          this.vm.submitSiteSearch();
        })
      if (this.state.searchInput.length > 0) {
        Text('✕')
          .fontSize(13)
          .fontColor(this.theme.colors.textSecondary)
          .padding(4)
          .onClick((): void => {
            this.vm.updateSiteSearchInput('');
            this.vm.submitSiteSearch();
          })
      }
    }
    .width('100%')
    .height(36)
    .borderRadius(10)
    .backgroundColor(this.theme.colors.card)
    .padding({ left: 10, right: 10 })
    .margin({ left: Metrics.pagePadding, right: Metrics.pagePadding, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  CategoryRow() {
    Scroll() {
      Row() {
        this.CatChip('全部分类', this.state.selectedCat.length === 0, (): void => {
          this.vm.clearSiteCategories();
        })
        ForEach(this.state.categories, (cat: MpSiteCategory, idx: number): void => {
          this.CatChip(cat.label(), this.state.selectedCat === cat.value(), (): void => {
            this.vm.toggleSiteCategory(cat.value());
          })
        }, (cat: MpSiteCategory, idx: number): string =>
            `cat-${idx}-${cat.value()}-${this.state.selectedCat === cat.value() ? 1 : 0}`)
      }
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
    .margin({ bottom: 6 })
  }

  @Builder
  CatChip(label: string, active: boolean, onTap: () => void) {
    Text(label)
      .fontSize(this.theme.fs(11))
      .fontColor(active ? 0xFFFFFFFF : this.theme.colors.textPrimary)
      .backgroundColor(active ? Palette.blue : this.theme.colors.card)
      .borderRadius(9)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .margin({ right: 6 })
      .maxLines(1)
      .onClick((): void => {
        onTap();
      })
  }

  @Builder
  SortRow() {
    Row() {
      Text(`已加载 ${this.state.torrents.length} 条`)
        .fontSize(this.theme.fs(11))
        .fontColor(this.theme.colors.textSecondary)
      Blank()
      Row() {
        Text('⇅')
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.textSecondary)
        Text(` ${siteSortLabel(this.state.sort)}`)
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.accent)
      }
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .borderRadius(8)
      .backgroundColor(this.theme.colors.card)
      .onClick((): void => {
        this.showSortMenu = !this.showSortMenu;
      })
      .bindMenu(this.sortMenuItems(), {
        onDisappear: (): void => {
          this.showSortMenu = false;
        }
      })
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  private sortMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    const all: SiteSort[] = [SiteSort.LATEST, SiteSort.SIZE, SiteSort.SEEDERS, SiteSort.GRABS];
    for (const s of all) {
      const target: SiteSort = s;
      items.push({
        value: siteSortLabel(s),
        action: (): void => {
          this.vm.setSiteSort(target);
          this.showSortMenu = false;
        }
      });
    }
    return items;
  }

  @Builder
  Body() {
    if (this.state.torrents.length === 0) {
      if (this.state.browsing) {
        this.SkeletonBlock()
      } else if (this.state.browseError.length > 0) {
        Column() {
          Text('⚠️').fontSize(30)
          Blank().height(10)
          Text(this.state.browseError)
            .fontSize(this.theme.fs(12))
            .fontColor(this.theme.colors.textSecondary)
            .textAlign(TextAlign.Center)
            .padding({ left: 30, right: 30 })
          Blank().height(14)
          Text('重试')
            .fontSize(this.theme.fs(13))
            .fontColor(0xFFFFFFFF)
            .backgroundColor(Palette.blue)
            .borderRadius(16)
            .padding({ left: 18, right: 18, top: 7, bottom: 7 })
            .onClick((): void => {
              this.vm.refreshSiteTorrents();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        Column() {
          EmptyHint({ text: '这个站点没有种子（或分类/关键词没有匹配）' })
        }
        .layoutWeight(1)
      }
    } else {
      List() {
        ForEach(this.state.sortedTorrents(), (item: MpResource): void => {
          ListItem() {
            this.TorrentCard(item)
          }
          .margin({ bottom: 8 })
        }, (item: MpResource): string => item.key)

        ListItem() {
          this.Footer()
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onReachEnd((): void => {
        if (this.state.hasMore && !this.state.browsing) {
          this.vm.loadMoreSiteTorrents();
        }
      })
    }
  }

  @Builder
  SkeletonBlock() {
    Column() {
      ForEach([0, 1, 2], (i: number): void => {
        Row() {
          Column()
            .width(52)
            .height(72)
            .borderRadius(7)
            .backgroundColor(withAlpha(0xFF8E8E93, 0x22))
          Blank().width(10)
          Column() {
            Column().width('100%').height(13).borderRadius(4)
              .backgroundColor(withAlpha(0xFF8E8E93, 0x22))
            Blank().height(7)
            Column().width('60%').height(11).borderRadius(4)
              .backgroundColor(withAlpha(0xFF8E8E93, 0x18))
          }
          .layoutWeight(1)
        }
        .width('100%')
        .padding(11)
        .borderRadius(13)
        .backgroundColor(this.theme.colors.card)
        .margin({ bottom: 8 })
      }, (i: number): string => `sk${i}`)
      Blank().height(6)
      Row() {
        LoadingProgress().width(16).height(16).color(Palette.blue)
        Blank().width(8)
        Text(`正在让 MoviePilot 去站点抓列表…已等 ${this.state.elapsedSeconds} 秒`)
          .fontSize(this.theme.fs(11))
          .fontColor(this.state.elapsedSeconds >= 60 ? Palette.orange : this.theme.colors.textSecondary)
        Blank()
        Text('取消')
          .fontSize(this.theme.fs(11))
          .fontColor(Palette.blue)
          .onClick((): void => {
            this.vm.cancelSiteBrowse();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
  }

  @Builder
  Footer() {
    Column() {
      if (this.state.browsing) {
        Row() {
          LoadingProgress().width(16).height(16).color(Palette.blue)
          Blank().width(8)
          Text(`加载下一页…已等 ${this.state.elapsedSeconds} 秒`)
            .fontSize(this.theme.fs(11))
            .fontColor(this.state.elapsedSeconds >= 60 ? Palette.orange : this.theme.colors.textSecondary)
          Blank()
          Text('取消')
            .fontSize(this.theme.fs(11))
            .fontColor(Palette.blue)
            .onClick((): void => {
              this.vm.cancelSiteBrowse();
            })
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
        .alignItems(VerticalAlign.Center)
      } else if (this.state.browseError.length > 0) {
        Row() {
          Text(this.state.browseError)
            .fontSize(this.theme.fs(11))
            .fontColor(Palette.red)
            .layoutWeight(1)
            .maxLines(4)
          Text('重试')
            .fontSize(this.theme.fs(11))
            .fontColor(Palette.blue)
            .padding({ left: 8 })
            .onClick((): void => {
              this.vm.refreshSiteTorrents();
            })
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
        .alignItems(VerticalAlign.Top)
      } else if (!this.state.hasMore) {
        Text(`已到站点最后一页 · 共 ${this.state.torrents.length} 条`)
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 20 })
      } else {
        Blank().height(90)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 徽标：v1.0.15 起直接复用 MpResource.badges()（搜索页与这里同一套顺序），
   * 以前这里只取 labels[0..1] 再 slice(0,4)，所以「中字/国语/特效」永远显示不全。
   */
  private badgeSpecs(item: MpResource): TorrentBadge[] {
    const out: TorrentBadge[] = [];
    for (const text of item.badges()) {
      out.push(new TorrentBadge(text, this.badgeTint(text, item)));
    }
    return out;
  }

  /** 徽标配色：促销橙/免费绿、H&R 红、制作组灰、分辨率薄荷、来源靛、字幕蓝 */
  private badgeTint(text: string, item: MpResource): number {
    if (text.indexOf('免费') >= 0) {
      return Palette.green;
    }
    if (text.indexOf('%') >= 0 || /^[0-9.]+X/.test(text)) {
      return Palette.orange;
    }
    if (text === 'H&R' || text.indexOf('禁') >= 0) {
      return Palette.red;
    }
    if (text === item.group()) {
      return Palette.gray;
    }
    if (text === item.resolution()) {
      return Palette.mint;
    }
    if (text === item.quality()) {
      return Palette.indigo;
    }
    return Palette.blue;
  }

  /** 副标题：description 优先，缺失时由 subtitle() 用「小组·来源·编码」兜底 */
  private descText(item: MpResource): string {
    return item.subtitle();
  }

  @Builder
  TorrentCard(item: MpResource) {
    // 外层：实色圆角底承影（gradient 不参与 shadow 轮廓，单层会投出直角）
    Row() {
      Row() {
      // 海报：站点接口不给图，靠 MP 识别反查；没识别到就用渐变 + 首字
      Stack({ alignContent: Alignment.Center }) {
        if (this.state.posterOf(item).length > 0) {
          PosterImage({ url: this.state.posterOf(item) })
            .width(52)
            .height(72)
            .borderRadius(7)
            .clip(true)
        } else {
          Column()
            .width(52)
            .height(72)
            .borderRadius(7)
            .linearGradient({
              angle: 135,
              colors: [[0xFF2B4C7E, 0.0], [0xFF5E5CE6, 1.0]]
            })
          Text(item.title.length > 0 ? item.title.substring(0, 1).toUpperCase() : '?')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(0xD9FFFFFF)
        }
        // 免费种在封面上打角标，跟安卓一致（列表里一眼看出不计量）
        if (item.isFree()) {
          Text('FREE')
            .fontSize(this.theme.fs(7))
            .fontWeight(FontWeight.Bold)
            .fontColor(0xFFFFFFFF)
            .backgroundColor(Palette.green)
            .borderRadius(3)
            .padding({ left: 3, right: 3, top: 1, bottom: 1 })
            .position({ x: 3, y: 3 })
        }
      }
      .width(52)
      .height(72)

      Blank().width(10)
      Column() {
        Text(item.title)
          .fontSize(this.theme.fs(13))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(this.theme.fs(18))
          .width('100%')

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.badgeSpecs(item), (b: TorrentBadge): void => {
            this.Badge(b.text, b.tint)
          }, (b: TorrentBadge, idx: number): string => `bd-${idx}-${b.text}`)
        }
        .width('100%')
        .margin({ top: 5 })

        // 副标题：站点列表里最关键的一行（字幕组 / 演员 / 集数），安卓有、鸿蒙漏了
        if (this.descText(item).length > 0) {
          Text(this.descText(item))
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(this.theme.fs(15))
            .margin({ top: 4 })
            .width('100%')
        }

        Row() {
          Text(`↑ ${item.seeders}`)
            .fontSize(this.theme.fs(10))
            .fontColor(Palette.green)
          Blank().width(7)
          Text(`↓ ${item.peers}`)
            .fontSize(this.theme.fs(10))
            .fontColor(this.theme.colors.textSecondary)
          Blank().width(9)
          Text(formatStorageSize(item.sizeBytes))
            .fontSize(this.theme.fs(10))
            .fontColor(this.theme.colors.textSecondary)
          Blank()
          Text(item.pubDateMs > 0 ? formatRelativeTime(item.pubDateMs) : '')
            .fontSize(this.theme.fs(10))
            .fontColor(this.theme.colors.textSecondary)
        }
        .width('100%')
        .margin({ top: 5 })
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(10)
    .borderRadius(13)
    // 弱悬浮（仪表盘的一半）：种子列表很长，阴影太重会显得整屏脏
    .linearGradient({
      angle: 180,
      colors: this.theme.colors.isDark
        ? [[withAlpha(0x2B2B32, 0xF7), 0.0], [withAlpha(0x202026, 0xF0), 1.0]]
        : [[withAlpha(0xFCFDFF, 0xFA), 0.0], [withAlpha(0xE3EBF8, 0xF5), 1.0]]
    })
    .border({
      width: 0.8,
      color: withAlpha(0xFFFFFF, this.theme.colors.isDark ? 0x30 : 0xF5),
      radius: 13
    })
    .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .borderRadius(13)
      .backgroundColor(this.theme.colors.isDark ? 0x2B2B32 : 0xFCFDFF)
      .shadow({
        radius: 20,
        color: this.theme.colors.isDark ? 'rgba(0,0,0,0.30)' : 'rgba(59,76,112,0.10)',
        offsetX: 0,
        offsetY: 7,
        fill: true
      })
    .onClick((): void => {
      this.navStack.pushPathByName('siteTorrent', item);
    })
    .gesture(LongPressGesture().onAction((): void => {
      this.openSheet(item);
    }))
  }

  @Builder
  Badge(text: string, tint: number) {
    Text(text)
      .fontSize(this.theme.fs(9))
      .fontColor(tint)
      .backgroundColor(withAlpha(tint, 0x26))
      .borderRadius(4)
      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
      .margin({ right: 4 })
      .maxLines(1)
  }

  /** 长按种子：打开投递面板（面板自身管理下载器/保存路径/提交结果） */
  private openSheet(item: MpResource): void {
    this.sheetResource = item;
    if (this.vm.state.savePaths.length === 0) {
      this.vm.loadDownloadOptions();
    }
    this.sheetVisible = true;
  }
}
