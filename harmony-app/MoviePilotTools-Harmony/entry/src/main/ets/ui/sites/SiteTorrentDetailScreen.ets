import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppTheme, Palette, Metrics, withAlpha, ghostFill } from '../../common/Theme';
import { MpMedia, MpResource } from '../../model/MpModels';
import { MpViewModel, TorrentMediaInfo } from '../../vm/MpViewModel';
import { PosterImage } from '../components/PosterImage';
import { ElevatedCard } from '../components/Common';
import { ToastHub } from '../../vm/StoreBase';
import { formatStorageSize, formatRelativeTime } from '../../common/Format';
import { SiteDownloadSheet } from './SiteDownloadSheet';

/**
 * 种子详情（对应安卓 ui/sites/SiteTorrentDetailScreen.kt）。
 *
 * 和 MP 搜索结果页统一：站点接口本身只有标题/简介/体积几个文字字段，
 * 所以进页面时用种子标题去 MP 识别一次（`vm.loadTorrentMedia`），
 * 拿到中文标题、类型、评分、简介、演职员，版式与 `MediaDetail.ets` 对齐：
 * 海报 + 信息 → 种子数据 → 简介 → 演职员，卡片全部用悬浮卡。
 */

@Component
export struct SiteTorrentDetailPage {
  @Consume('oiiTheme') theme: AppTheme;
  @Consume('navStack') navStack: NavPathStack;
  private vm: MpViewModel = MpViewModel.getInstance();
  @State item: MpResource | null = null;
  @State poster: string = '';
  /** MP 侧内容（识别 → 详情 → 演职员）；识别不出来就整页退回站点数据 */
  @State info: TorrentMediaInfo = new TorrentMediaInfo();
  @State expandOverview: boolean = true;
  @State sheetVisible: boolean = false;
  @State sheetResource: MpResource | null = null;
  /** 底部小白条高度：Navigation 已改成全屏铺满，底部操作条要自己让开 */
  @StorageLink('sysBottomSafeVp') bottomSafeVp: number = 0;

  private loadParam(param: Object): void {
    if (!(param instanceof MpResource)) {
      return;
    }
    const res: MpResource = param as MpResource;
    this.item = res;
    this.sheetResource = res;
    // 列表里已经识别过就直接用海报缓存，避免详情页再等一次
    const cached: string = this.vm.state.site.posterOf(res);
    if (cached.length > 0) {
      this.poster = cached;
    }
    this.vm.loadTorrentMedia(res.title).then((info: TorrentMediaInfo): void => {
      this.info = info;
      const media: MpMedia | null = info.media;
      if (this.poster.length === 0 && media !== null && media.posterUrl.length > 0) {
        this.poster = media.posterUrl;
      }
    });
  }

  private openPage(): void {
    const item: MpResource | null = this.item;
    if (item === null || item.pageUrl.trim().length === 0) {
      ToastHub.getInstance().show('这个种子没有页面地址');
      return;
    }
    try {
      const ctx: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.openLink(item.pageUrl).catch((err: BusinessError): void => {
        ToastHub.getInstance().show(`打不开链接：${err.message}`);
      });
    } catch (err) {
      ToastHub.getInstance().show('打不开链接');
    }
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          // ---- 顶栏（标题居中，和安卓版一致） ----
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
            Column() {
              Text('种子详情')
                .fontSize(this.theme.fs(16))
                .fontWeight(FontWeight.Medium)
                .fontColor(this.theme.colors.textPrimary)
              Text(this.siteText())
                .fontSize(this.theme.fs(11))
                .fontColor(this.theme.colors.textSecondary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Center)
            Column().width(34).height(34)
          }
          .width('100%')
          .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 8, bottom: 8 })
          .alignItems(VerticalAlign.Center)

          Scroll() {
            Column() {
              // ---- 海报 + 信息（对齐 MP 详情页顶部那一段） ----
              Row() {
                Stack({ alignContent: Alignment.Center }) {
                  if (this.posterSrc().length > 0) {
                    // PosterImage 是自定义 struct，尺寸/圆角挂在外层 Stack 上（同 MP 详情页写法）
                    PosterImage({ url: this.posterSrc() })
                  } else {
                    Column()
                      .width(96)
                      .height(141)
                      .borderRadius(10)
                      .linearGradient({
                        angle: 135,
                        colors: [[0xFF2B4C7E, 0.0], [0xFF5E5CE6, 1.0]]
                      })
                    Text(this.initialOf())
                      .fontSize(34)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(0xD9FFFFFF)
                  }
                }
                .width(96)
                .height(141)
                .borderRadius(10)
                .clip(true)

                Blank().width(12)
                Column() {
                  Text(this.displayTitle())
                    .fontSize(this.theme.fs(18))
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.theme.colors.textPrimary)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Blank().height(4)
                  Row() {
                    Text(this.metaLine())
                      .fontSize(this.theme.fs(11))
                      .fontColor(this.theme.colors.textSecondary)
                    if (this.voteText().length > 0) {
                      Blank().width(6)
                      Text(this.voteText())
                        .fontSize(this.theme.fs(11))
                        .fontColor(0xFFFF9500)
                    }
                  }
                  .alignItems(VerticalAlign.Center)
                  if (this.genresText().length > 0) {
                    Blank().height(6)
                    Text(this.genresText())
                      .fontSize(this.theme.fs(11))
                      .fontColor(this.theme.colors.textSecondary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  if (this.directorsText().length > 0) {
                    Blank().height(4)
                    Text(this.directorsText())
                      .fontSize(this.theme.fs(11))
                      .fontColor(this.theme.colors.textSecondary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  if (this.castText().length > 0) {
                    Blank().height(2)
                    Text(this.castText())
                      .fontSize(this.theme.fs(11))
                      .fontColor(this.theme.colors.textSecondary)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  Blank().height(8)
                  // 规格标签：促销 / 分辨率 / 来源 / 制作组 …（和列表卡片同一套 badges）
                  Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
                    justifyContent: FlexAlign.Start }) {
                    ForEach(this.badges(), (text: string): void => {
                      Row() {
                        Text(text)
                          .fontSize(this.theme.fs(9))
                          .fontColor(this.badgeFg(text))
                          .backgroundColor(this.badgeBg(text))
                          .borderRadius(6)
                          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                          .maxLines(1)
                      }
                      .margin({ right: 4, bottom: 4 })
                    }, (text: string, idx: number): string => `tg-${idx}-${text}`)
                  }
                  .width('100%')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)

              // ---- 种子数据（站点页独有） ----
              // 注意：ElevatedCard 是自定义 struct，不能链 .margin()，间距只能用 Blank 占位
              Blank().height(14)
              ElevatedCard({ paddingVp: 14, subtle: true, radiusVp: 18 }) {
                Column() {
                  Row() {
                    this.StatCell('做种', this.seedersText(), Palette.green)
                    this.StatCell('下载中', this.peersText(), this.theme.colors.textPrimary)
                    this.StatCell('完成', this.grabsText(), this.theme.colors.textPrimary)
                  }
                  .width('100%')
                  Blank().height(12)
                  Row()
                    .width('100%')
                    .height(0.5)
                    .backgroundColor(this.theme.colors.separator)
                  Blank().height(10)
                  this.MetaRow('体积', this.sizeText())
                  this.MetaRow('发布', this.pubText())
                  this.MetaRow('站点', this.siteText())
                  this.MetaRow('种子名', this.item !== null ? this.item.title : '')
                }
                .alignItems(HorizontalAlign.Start)
              }

              // ---- 简介 ----
              if (this.overviewText().length > 0) {
                Blank().height(12)
                ElevatedCard({ paddingVp: 13, subtle: true, radiusVp: 18 }) {
                  Column() {
                    Text('简介')
                      .fontSize(this.theme.fs(13))
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.theme.colors.textPrimary)
                    Blank().height(6)
                    Text(this.overviewText())
                      .fontSize(this.theme.fs(12))
                      .fontColor(this.theme.colors.textSecondary)
                      .lineHeight(this.theme.fs(19))
                      .maxLines(this.expandOverview ? 200 : 4)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text(this.expandOverview ? '收起' : '展开')
                      .fontSize(this.theme.fs(11))
                      .fontColor(Palette.blue)
                      .margin({ top: 4 })
                      .onClick((): void => {
                        this.expandOverview = !this.expandOverview;
                      })
                    if (this.overviewFromSite()) {
                      Blank().height(4)
                      Text('MP 未识别到该种子，简介由站点提供。')
                        .fontSize(this.theme.fs(10))
                        .fontColor(withAlpha(this.theme.colors.textSecondary, 0xB3))
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                }
              }

              // ---- 演职员 ----
              if (this.info.creditNames.length > 0) {
                Blank().height(12)
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

              // 底部固定操作条（42 + 上下内边距）压在上面，末尾留出它的高度
              Blank().height(96 + this.bottomSafeVp)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          // 关键：Scroll 的 align 默认是 Center，内容不足一屏时会被垂直居中（上面空一大块）。
          .align(Alignment.Top)
        }
        .width('100%')
        .height('100%')

        // ---- 底部固定操作条 ----
        // 整块白底去掉：白底压在白卡/白页面上就是「白上白」。改成页面背景的渐隐。
        Column() {
          Row() {
            Text('浏览器打开')
              .fontSize(this.theme.fs(14))
              .fontColor(this.theme.colors.textPrimary)
              .layoutWeight(1)
              .height(42)
              .textAlign(TextAlign.Center)
              .borderRadius(11)
              .backgroundColor(ghostFill(this.theme.colors.textPrimary))
              .onClick((): void => {
                this.openPage();
              })
            Blank().width(10)
            Text('下载')
              .fontSize(this.theme.fs(14))
              .fontWeight(FontWeight.Medium)
              .fontColor(0xFFFFFFFF)
              .layoutWeight(1)
              .height(42)
              .textAlign(TextAlign.Center)
              .borderRadius(11)
              .backgroundColor(Palette.blue)
              .onClick((): void => {
                if (this.sheetResource === null) {
                  return;
                }
                if (this.vm.state.savePaths.length === 0) {
                  this.vm.loadDownloadOptions();
                }
                this.sheetVisible = true;
              })
          }
          .width('100%')
          .padding({
            left: Metrics.pagePadding,
            right: Metrics.pagePadding,
            top: 10,
            // 小白条高度并进内边距：全屏后按钮不能压住系统手势条
            bottom: 12 + this.bottomSafeVp
          })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ top: 14 })
        .linearGradient({
          angle: 180,
          colors: [
            [withAlpha(this.theme.colors.background, 0x00), 0],
            [withAlpha(this.theme.colors.background, 0xD9), 0.45],
            [this.theme.colors.background, 1]
          ]
        })

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
      if (this.sheetVisible) {
        this.sheetVisible = false;
        return true;
      }
      return false;
    })
  }

  @Builder
  StatCell(label: string, value: string, valueColor: number) {
    Column() {
      Text(value)
        .fontSize(this.theme.fs(18))
        .fontWeight(FontWeight.Medium)
        .fontColor(valueColor)
        .maxLines(1)
      Text(label)
        .fontSize(this.theme.fs(11))
        .fontColor(this.theme.colors.textSecondary)
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  MetaRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(this.theme.fs(11.5))
        .fontColor(this.theme.colors.textSecondary)
        .width(48)
      Text(value)
        .fontSize(this.theme.fs(11.5))
        .fontColor(this.theme.colors.textPrimary)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 3, bottom: 3 })
    .alignItems(VerticalAlign.Top)
  }

  // ---------- MP 侧内容（识别结果优先，缺失时退回站点数据） ----------

  private mp(): MpMedia | null {
    return this.info.media;
  }

  private displayTitle(): string {
    const m: MpMedia | null = this.mp();
    if (m !== null && m.title.length > 0) {
      return m.title;
    }
    return this.item !== null ? this.item.title : '';
  }

  private posterSrc(): string {
    const m: MpMedia | null = this.mp();
    if (m !== null && m.posterUrl.length > 0) {
      return m.posterUrl;
    }
    return this.poster;
  }

  private metaLine(): string {
    const parts: string[] = [];
    const m: MpMedia | null = this.mp();
    if (m !== null) {
      if (m.yearLabel().length > 0) {
        parts.push(m.yearLabel());
      }
      parts.push(m.typeLabel());
    } else if (this.item !== null && this.item.pubDateText.length >= 4) {
      parts.push(this.item.pubDateText.substring(0, 4));
    }
    return parts.join(' · ');
  }

  private voteText(): string {
    const m: MpMedia | null = this.mp();
    return m !== null && m.vote > 0 ? `★ ${m.vote.toFixed(1)}` : '';
  }

  private genresText(): string {
    const m: MpMedia | null = this.mp();
    return m !== null && m.genres.length > 0 ? m.genres.slice(0, 4).join(' / ') : '';
  }

  private directorsText(): string {
    const m: MpMedia | null = this.mp();
    return m !== null && m.directors.length > 0 ? `导演：${m.directors.slice(0, 2).join('、')}` : '';
  }

  private castText(): string {
    const m: MpMedia | null = this.mp();
    return m !== null && m.cast.length > 0 ? `主演：${m.cast.slice(0, 3).join('、')}` : '';
  }

  private overviewText(): string {
    const m: MpMedia | null = this.mp();
    if (m !== null && m.overview.length > 0) {
      return m.overview;
    }
    return this.descText();
  }

  private overviewFromSite(): boolean {
    const m: MpMedia | null = this.mp();
    return m === null || m.overview.length === 0;
  }

  private creditsText(): string {
    const names: string[] = this.info.creditNames.slice(0, 12);
    return names.join('、');
  }

  private initialOf(): string {
    const t: string = this.displayTitle();
    return t.length > 0 ? t.substring(0, 1).toUpperCase() : '?';
  }

  // ---------- 站点侧数据 ----------

  private badges(): string[] {
    return this.item !== null ? this.item.badges() : [];
  }

  private isPromo(text: string): boolean {
    return text.indexOf('免费') >= 0 || text.indexOf('%') >= 0 || /^[0-9.]+X/.test(text);
  }

  private badgeBg(text: string): number {
    if (text.indexOf('免费') >= 0) {
      return withAlpha(Palette.green, 0x26);
    }
    if (this.isPromo(text)) {
      return withAlpha(Palette.orange, 0x24);
    }
    if (text === 'H&R' || text.indexOf('禁') >= 0) {
      return withAlpha(Palette.red, 0x1F);
    }
    if (this.item !== null && text === this.item.resolution()) {
      return withAlpha(Palette.purple, 0x1F);
    }
    if (this.item !== null && text === this.item.group()) {
      return withAlpha(this.theme.colors.textSecondary, 0x1C);
    }
    return withAlpha(Palette.blue, 0x1A);
  }

  private badgeFg(text: string): number {
    if (text.indexOf('免费') >= 0) {
      return Palette.green;
    }
    if (this.isPromo(text)) {
      return Palette.orange;
    }
    if (text === 'H&R' || text.indexOf('禁') >= 0) {
      return Palette.red;
    }
    if (this.item !== null && text === this.item.resolution()) {
      return Palette.purple;
    }
    if (this.item !== null && text === this.item.group()) {
      return this.theme.colors.textSecondary;
    }
    return Palette.blue;
  }

  private sizeText(): string {
    return this.item !== null ? formatStorageSize(this.item.sizeBytes) : '--';
  }

  private seedersText(): string {
    return this.item !== null ? `${this.item.seeders}` : '--';
  }

  private peersText(): string {
    return this.item !== null ? `${this.item.peers}` : '--';
  }

  private grabsText(): string {
    return this.item !== null ? `${this.item.grabs}` : '--';
  }

  private pubText(): string {
    if (this.item === null) {
      return '--';
    }
    if (this.item.pubDateMs > 0) {
      return formatRelativeTime(this.item.pubDateMs);
    }
    return this.item.pubDateText.length > 0 ? this.item.pubDateText : '--';
  }

  private siteText(): string {
    return this.item !== null && this.item.siteName.length > 0 ? this.item.siteName : '--';
  }

  private descText(): string {
    return this.item !== null ? this.item.description.trim() : '';
  }
}
