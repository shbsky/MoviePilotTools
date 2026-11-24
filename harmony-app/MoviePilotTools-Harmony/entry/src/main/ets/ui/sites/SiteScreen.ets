import { image } from '@kit.ImageKit';
import { AppTheme, Palette, Metrics, withAlpha, ghostFill } from '../../common/Theme';
import { MpSite, MpSiteUserData } from '../../model/MpSiteModels';
import { MpSiteState, MpViewModel } from '../../vm/MpViewModel';
import { SiteIcon, SiteIconStore } from '../../net/SiteIconStore';
import { EmptyHint, DialogHost } from '../components/Common';
import { AppViewModel } from '../../vm/AppViewModel';
import { appSettingsCopy } from '../settings/Settings';
import { formatStorageSize } from '../../common/Format';

/**
 * 站点列表页（对应安卓 ui/sites/SiteScreen.kt）。
 *
 * 数据全部来自 MoviePilot，App 里只读：站点增删改一律去 MP 后台。
 * 卡片上的等级/流量/魔力来自 MP 定时抓取的缓存，所以会标出「更新 MM-DD」，
 * 超过 3 天标黄 —— 那种数字可能已经是几天前的了。
 */

const AVATAR_COLORS: number[] = [
  0xFF0A84FF, 0xFF5E5CE6, 0xFFAF52DE, 0xFFFF2D55,
  0xFFFF9500, 0xFF34C759, 0xFF00C7BE, 0xFF5856D6
];

function avatarColorOf(seed: string): number {
  let h: number = 0;
  for (let i = 0; i < seed.length; i++) {
    h = ((h << 5) - h + seed.charCodeAt(i)) | 0;
  }
  const idx: number = Math.abs(h) % AVATAR_COLORS.length;
  return AVATAR_COLORS[idx];
}

/** 站点图标：真图标优先（base64 自解码 / 地址直连），失败降级首字色块 */
@Component
export struct SiteAvatar {
  @Consume('oiiTheme') theme: AppTheme;
  siteId: number = 0;
  name: string = '';
  sizeVp: number = 46;
  corner: number = 12;
  @State pixel: image.PixelMap | null = null;
  @State iconUrl: string = '';
  @State failed: boolean = false;
  private seq: number = 0;

  aboutToAppear(): void {
    this.loadIcon();
  }

  private loadIcon(): void {
    const cached: SiteIcon | null = SiteIconStore.cached(this.siteId);
    if (cached !== null) {
      this.applyIcon(cached);
      return;
    }
    if (SiteIconStore.isMissing(this.siteId)) {
      this.failed = true;
      return;
    }
    this.seq++;
    const seq: number = this.seq;
    MpViewModel.getInstance().loadSiteIcon(this.siteId).then((icon: SiteIcon | null): void => {
      // 组件可能已经换了站点（列表复用），过期结果直接丢
      if (seq !== this.seq) {
        return;
      }
      if (icon === null) {
        this.failed = true;
        return;
      }
      this.applyIcon(icon);
    }).catch((): void => {
      this.failed = true;
    });
  }

  private applyIcon(icon: SiteIcon): void {
    this.iconUrl = icon.url;
    this.pixel = icon.pixel;
    if (icon.isEmpty()) {
      this.failed = true;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.pixel !== null) {
        Image(this.pixel)
          .width(this.sizeVp)
          .height(this.sizeVp)
          .objectFit(ImageFit.Cover)
          .draggable(false)
      } else if (this.iconUrl.length > 0 && !this.failed) {
        Image(this.iconUrl)
          .width(this.sizeVp)
          .height(this.sizeVp)
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .onError((): void => {
            // 站点防盗链会 403，必须兜底
            this.failed = true;
          })
      } else {
        Text(this.name.trim().length > 0 ? this.name.trim().substring(0, 1).toUpperCase() : '#')
          .fontSize(this.sizeVp * 0.4)
          .fontWeight(FontWeight.Bold)
          .fontColor(0xFFFFFFFF)
      }
    }
    .width(this.sizeVp)
    .height(this.sizeVp)
    .borderRadius(this.corner)
    .clip(true)
    .backgroundColor(avatarColorOf(this.name))
  }
}

@Component
export struct SiteScreen {
  @Consume('oiiTheme') theme: AppTheme;
  @Consume('navStack') navStack: NavPathStack;
  private vm: MpViewModel = MpViewModel.getInstance();
  @State state: MpSiteState = new MpSiteState();
  /** 底部悬浮栏避让（Index 统一广播） */
  @StorageLink('bottomInsetVp') bottomInset: number = 72;

  // ---- 站点筛选----
  // 站点一多，列表翻半天；这里的白名单只管「显示哪些站」，
  // 想真减少 MP 的站点压力还是要去 MP 后台停用（索引器压根不请求）。
  private appvm: AppViewModel = AppViewModel.getInstance();
  @State showSiteFilter: boolean = false;
  /** 弹窗里的临时选择：空 = 全部 */
  @State draftFilter: string[] = [];

  private listener: () => void = (): void => {
    this.state = this.vm.state.site;
  };

  aboutToAppear(): void {
    this.vm.subscribe(this.listener);
    this.state = this.vm.state.site;
    this.vm.loadSites(false);
  }

  aboutToDisappear(): void {
    this.vm.unsubscribe(this.listener);
  }

  private totalSeeding(): number {
    let n: number = 0;
    this.state.userData.forEach((d: MpSiteUserData): void => {
      n += d.seeding;
    });
    return n;
  }

  /** 白名单（空 = 全部） */
  private whitelist(): string[] {
    return this.appvm.state.settings.mpSiteFilter;
  }

  private filterActive(): boolean {
    return this.whitelist().length > 0;
  }

  /** 列表实际渲染的站点（按白名单过滤，顺序保持 MP 的优先级） */
  private visibleSites(): MpSite[] {
    const wl: string[] = this.whitelist();
    if (wl.length === 0) {
      return this.state.sites;
    }
    const out: MpSite[] = [];
    for (const site of this.state.sites) {
      if (wl.indexOf(site.name) >= 0) {
        out.push(site);
      }
    }
    return out;
  }

  private toggleDraft(name: string): void {
    const next: string[] = this.draftFilter.slice(0);
    const i: number = next.indexOf(name);
    if (i >= 0) {
      next.splice(i, 1);
    } else {
      next.push(name);
    }
    this.draftFilter = next;
  }

  private saveFilter(): void {
    const next = appSettingsCopy(this.appvm.state.settings);
    next.mpSiteFilter = this.draftFilter.slice(0);
    this.appvm.updateSettings(next);
    this.showSiteFilter = false;
  }

  build() {
    // 外层 Stack：DialogHost 需要铺满整屏才能盖住列表（放进 Column 里会撑出布局）
    Stack() {
      Column() {
      // ---- 头部 ----
      Row() {
        Text('站点')
          .fontSize(this.theme.fs(20))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.colors.textPrimary)
        Blank().width(8)
        Text(this.filterActive()
          ? `显示 ${this.visibleSites().length}/${this.state.sites.length} · 做种 ${this.totalSeeding()}`
          : `${this.state.sites.length} 个 · 做种 ${this.totalSeeding()}`)
          .fontSize(this.theme.fs(11))
          .fontColor(this.filterActive() ? Palette.blue : this.theme.colors.textSecondary)
          .maxLines(1)
          .layoutWeight(1)
        if (this.state.loading) {
          LoadingProgress().width(18).height(18).color(Palette.blue)
          Blank().width(6)
        }
        // 站点筛选：站点几十个时列表翻半天，这里只留常用的
        Text('筛选')
          .fontSize(this.theme.fs(12))
          .fontColor(this.filterActive() ? Palette.blue : this.theme.colors.textSecondary)
          .borderRadius(9)
          .backgroundColor(this.filterActive() ? withAlpha(Palette.blue, 0x1C) : Color.Transparent)
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .onClick((): void => {
            this.draftFilter = this.whitelist().slice(0);
            this.showSiteFilter = true;
          })
        Blank().width(2)
        Text('⟳')
          .fontSize(this.theme.fs(19))
          .fontColor(this.theme.colors.textPrimary)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            this.vm.refreshSites();
          })
      }
      .width('100%')
      .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 12, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      // ---- 错误横幅：固定在头部下方，不被列表滚走 ----
      if (this.state.error.length > 0) {
        Row() {
          Text(this.state.error)
            .fontSize(this.theme.fs(12))
            .fontColor(Palette.red)
            .layoutWeight(1)
            .maxLines(3)
          Text(this.state.permissionDenied ? '换 Token' : '重试')
            .fontSize(this.theme.fs(12))
            .fontColor(Palette.blue)
            .padding({ left: 10 })
            .onClick((): void => {
              this.vm.refreshSites();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .borderRadius(10)
        .backgroundColor(0x1AFF3B30)
        .margin({ left: Metrics.pagePadding, right: Metrics.pagePadding, bottom: 8 })
        .alignItems(VerticalAlign.Center)
      }

      if (this.state.sites.length === 0 && !this.state.loading) {
        Column() {
          EmptyHint({
            text: this.state.error.length > 0 ? '站点没加载出来'
              : '还没有站点，先去 MoviePilot 后台「站点」里添加'
          })
        }
        .layoutWeight(1)
      } else if (this.visibleSites().length === 0) {
        // 白名单里选的站点全被删了 / 名字改了，别让用户对着空白列表发呆
        Column() {
          EmptyHint({ text: '筛选后没有站点，点右上「筛选」重新选择' })
        }
        .layoutWeight(1)
      } else {
        List() {
          ForEach(this.visibleSites(), (site: MpSite): void => {
            ListItem() {
              this.SiteCard(site)
            }
            .margin({ bottom: 8 })
          }, (site: MpSite): string => `s${site.id}`)

          // 底部占位项：
          // 底栏避让不能再写成 List 的 `.padding({ bottom })` —— List 的 padding 会裁剪
          // 滚动内容，卡片在底栏上沿被硬切、底栏后面永远透不出列表。
          // 用末尾占位项代替：内容可以铺到屏幕底、从底栏下面滚过去。
          ListItem() {
            Column()
              .width('100%')
              .height(this.bottomInset)
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.colors.background)

      // 站点筛选弹窗：多选，空数组 = 全部
      DialogHost({
        visible: this.showSiteFilter,
        title: '选择要显示的站点',
        subtitle: this.draftFilter.length === 0
          ? `当前显示全部 ${this.state.sites.length} 个站点`
          : `已选 ${this.draftFilter.length} 个站点`,
        confirmText: '完成',
        cancelText: '全部显示',
        contentMaxHeight: 380,
        onCancel: (): void => {
          // 「全部显示」= 清空白名单并关闭
          this.draftFilter = [];
          this.saveFilter();
        },
        onConfirm: (): void => {
          this.saveFilter();
        }
      }) {
        Column() {
          if (this.state.sites.length === 0) {
            Text('还没有站点')
              .fontSize(this.theme.fs(12))
              .fontColor(this.theme.colors.textSecondary)
          }
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.state.sites, (site: MpSite): void => {
              Text(site.name)
                .fontSize(this.theme.fs(12))
                .fontColor(this.draftFilter.indexOf(site.name) >= 0 ? Palette.blue : this.theme.colors.textPrimary)
                .borderRadius(14)
                .backgroundColor(this.draftFilter.indexOf(site.name) >= 0
                  ? withAlpha(Palette.blue, 0x1F) : ghostFill(this.theme.colors.textPrimary))
                .border({
                  width: 0.6,
                  color: this.draftFilter.indexOf(site.name) >= 0
                    ? withAlpha(Palette.blue, 0x66) : Color.Transparent
                })
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .margin({ right: 6, bottom: 8 })
                .onClick((): void => {
                  this.toggleDraft(site.name);
                })
            }, (site: MpSite): string => `flt-${site.id}-${this.draftFilter.indexOf(site.name) >= 0 ? 1 : 0}`)
          }
          .width('100%')
          Blank().height(2)
          Text('只想让列表清爽，就选常用的几个站。若想减少 MoviePilot 的站点压力（搜索时不去请求这些站），请到 MP 后台·站点 里停用 —— 索引器压根不会请求停用的站点。')
            .fontSize(this.theme.fs(10))
            .fontColor(this.theme.colors.textSecondary)
            .lineHeight(this.theme.fs(15))
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SiteCard(site: MpSite) {
    // 外层：实色圆角底承影（gradient 不参与 shadow 轮廓，单层会投出直角）
    Row() {
      Row() {
      SiteAvatar({ siteId: site.id, name: site.name, sizeVp: 44, corner: 11 })
        .opacity(site.isActive ? 1 : 0.45)
      Blank().width(11)
      Column() {
        Row() {
          Text(site.name)
            .fontSize(this.theme.fs(15))
            .fontWeight(FontWeight.Medium)
            .fontColor(site.isActive ? this.theme.colors.textPrimary : this.theme.colors.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (!site.isActive) {
            Text('已停用')
              .fontSize(this.theme.fs(9))
              .fontColor(this.theme.colors.textSecondary)
              .backgroundColor(withAlpha(0xFF8E8E93, 0x22))
              .borderRadius(5)
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .margin({ left: 6 })
          } else if (this.levelOf(site).length > 0) {
            Text(this.levelOf(site))
              .fontSize(this.theme.fs(9))
              .fontColor(Palette.blue)
              .backgroundColor(0x1F0A84FF)
              .borderRadius(5)
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .margin({ left: 6 })
              .maxLines(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(site.displayDomain().length > 0 ? site.displayDomain() : site.note)
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })

        this.StatsLine(site)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(this.theme.fs(15))
        .fontColor(this.theme.colors.textSecondary)
        .padding({ left: 6 })
    }
    .width('100%')
    .padding(12)
    .borderRadius(14)
    // 弱悬浮（仪表盘的一半）：站点是长列表，阴影太重会显得整屏脏
    .linearGradient({
      angle: 180,
      colors: this.theme.colors.isDark
        ? [[withAlpha(0x2B2B32, 0xF7), 0.0], [withAlpha(0x202026, 0xF0), 1.0]]
        : [[withAlpha(0xFCFDFF, 0xFA), 0.0], [withAlpha(0xE3EBF8, 0xF5), 1.0]]
    })
    .border({
      width: 0.8,
      color: withAlpha(0xFFFFFF, this.theme.colors.isDark ? 0x30 : 0xF5),
      radius: 14
    })
    .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .borderRadius(14)
      .backgroundColor(this.theme.colors.isDark ? 0x2B2B32 : 0xFCFDFF)
      .shadow({
        radius: 22,
        color: this.theme.colors.isDark ? 'rgba(0,0,0,0.30)' : 'rgba(59,76,112,0.10)',
        offsetX: 0,
        offsetY: 8,
        fill: true
      })
      .onClick((): void => {
        if (!site.isActive) {
          return;
        }
        this.navStack.pushPathByName('siteDetail', site);
      })
  }

  @Builder
  StatsLine(site: MpSite) {
    if (!this.hasData(site.id)) {
      Text('暂无账号数据（MP 未抓取或 Cookie 失效）')
        .fontSize(this.theme.fs(10))
        .fontColor(this.theme.colors.textSecondary)
        .margin({ top: 4 })
    } else {
      Row() {
        Text('↑').fontSize(10).fontColor(Palette.arrowUp)
        Text(this.uploadText(site.id))
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
        Blank().width(7)
        Text('↓').fontSize(10).fontColor(Palette.blue)
        Text(this.downloadText(site.id))
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
        Blank().width(7)
        Text(this.seedingText(site.id))
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
      }
      .margin({ top: 4 })
      .alignItems(VerticalAlign.Center)

      Row() {
        if (this.hasError(site.id)) {
          Text('抓取失败：Cookie / 登录可能已失效')
            .fontSize(this.theme.fs(10))
            .fontColor(Palette.red)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Text(`魔力 ${this.bonusText(site.id)}`)
            .fontSize(this.theme.fs(10))
            .fontColor(this.theme.colors.textSecondary)
          Blank().width(7)
          Text(`分享率 ${this.ratioText(site.id)}`)
            .fontSize(this.theme.fs(10))
            .fontColor(this.theme.colors.textSecondary)
        }
        Blank()
        Text(this.updatedText(site.id))
          .fontSize(this.theme.fs(10))
          .fontColor(this.isStale(site.id) ? Palette.orange : this.theme.colors.textSecondary)
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)
    }
  }

  private userDataOf(siteId: number): MpSiteUserData | null {
    return this.state.userDataOf(siteId);
  }

  private hasData(siteId: number): boolean {
    return this.state.userDataOf(siteId) !== null;
  }

  private hasError(siteId: number): boolean {
    const d: MpSiteUserData | null = this.state.userDataOf(siteId);
    return d !== null && d.hasError();
  }

  private isStale(siteId: number): boolean {
    const d: MpSiteUserData | null = this.state.userDataOf(siteId);
    return d !== null && d.isStale();
  }

  private uploadText(siteId: number): string {
    const d: MpSiteUserData | null = this.state.userDataOf(siteId);
    return d === null ? '--' : formatStorageSize(d.upload);
  }

  private downloadText(siteId: number): string {
    const d: MpSiteUserData | null = this.state.userDataOf(siteId);
    return d === null ? '--' : formatStorageSize(d.download);
  }

  private seedingText(siteId: number): string {
    const d: MpSiteUserData | null = this.state.userDataOf(siteId);
    return d === null ? '做种 --' : `做种 ${d.seeding}`;
  }

  private ratioText(siteId: number): string {
    const d: MpSiteUserData | null = this.state.userDataOf(siteId);
    return d === null ? '--' : d.ratioText();
  }

  private updatedText(siteId: number): string {
    const d: MpSiteUserData | null = this.state.userDataOf(siteId);
    return d === null ? '' : d.updatedText();
  }

  private levelOf(site: MpSite): string {
    const d: MpSiteUserData | null = this.state.userDataOf(site.id);
    return d === null ? '' : d.userLevel.trim();
  }

  private bonusText(siteId: number): string {
    const d: MpSiteUserData | null = this.state.userDataOf(siteId);
    if (d === null) {
      return '0';
    }
    const v: number = d.bonus;
    if (v >= 10000) {
      return `${(v / 10000).toFixed(1)} 万`;
    }
    return `${Math.round(v)}`;
  }
}
