import { AppTheme, Palette, Metrics, withAlpha } from '../../common/Theme';
import { formatBytes, formatStorageSize } from '../../common/Format';
import { ServerConfig, ServerSnapshot } from '../../model/Models';
import { MpStatistic, MpStorage, MpMedia, MpServer, MP_CHANNELS, MpMemoryInfo,
  MpSystemInfo, MpDownloaderInfo } from '../../model/MpModels';
import { AppViewModel, AppState } from '../../vm/AppViewModel';
import { MpViewModel, DashboardLiveState } from '../../vm/MpViewModel';
import { MoviePilotClient } from '../../net/MoviePilotClient';
import { ElevatedCard, SectionHeader, StatTile, ServerBadge, Dot, IconValue } from '../components/Common';
import { MultiLineChart } from '../components/LineChart';
import { HeroCarousel } from './HeroCarousel';

/**
 * 仪表盘（对应安卓 ui/dashboard/DashboardScreen.kt）：
 * Hero 海报轮播（MP 推荐 + 本地缓存）→ 流量监控 → 媒体库（T04 接 MP）→
 * 数据聚合 → 服务器状态卡（点卡钻入任务页）。
 */

@Component
export struct DashboardPage {
  @Consume('oiiTheme') theme: AppTheme;
  @Consume('navStack') navStack: NavPathStack;
  private vm: AppViewModel = AppViewModel.getInstance();
  private mpvm: MpViewModel = MpViewModel.getInstance();
  @State state: AppState = new AppState();
  /** 仪表盘媒体库统计（来自 MoviePilot） */
  @State mpStats: MpStatistic | null = null;
  @State mpConfigured: boolean = false;
  /** MoviePilot 报的挂载盘容量（剩余空间优先用它） */
  @State mpStorage: MpStorage | null = null;
  /** MP 仪表盘实时速率 / CPU / 内存 / 系统信息（App 本地轮询采样） */
  @State mpLive: DashboardLiveState = new DashboardLiveState();
  /** 「系统信息」是否展开（默认展开，用户可手动收起） */
  @State systemExpanded: boolean = true;
  /** Hero 海报轮播（MP 推荐 + 本地缓存；状态隔离，不碰 MP 发现页分页） */
  @State heroPosters: MpMedia[] = [];
  @State heroError: string = '';
  /** 已为哪台 MP server 载入过海报，避免重复请求 */
  private heroLoadedKey: string = '';
  /** 底部悬浮栏避让高度（Index 统一写入：胶囊栏 + 迷你播放条 + 安全区） */
  @StorageLink('bottomInsetVp') bottomInset: number = 72;

  private listener: () => void = (): void => {
    this.state = this.vm.state;
  };

  private mpListener: () => void = (): void => {
    this.mpStats = this.mpvm.state.stats;
    this.mpConfigured = this.mpvm.state.server() !== null;
    this.mpStorage = this.mpvm.state.storage;
    this.mpLive = this.mpvm.state.live;
    this.maybeLoadHero();
  };

  aboutToAppear(): void {
    this.vm.subscribe(this.listener);
    this.state = this.vm.state;
    this.mpvm.subscribe(this.mpListener);
    this.mpListener();
    // 仪表盘自己不刷新（任务页在 aboutToAppear 里 refreshNow），一旦 bootstrap 的自动轮询
    // 没起来（配置读取失败 / 首帧早于 bootstrap），这张卡就会一直是空 state 里的 0。
    // refresh 内部有 servers 为空 + refreshing 双重守卫，这里补一次是幂等的。
    this.vm.refreshNow();
  }

  aboutToDisappear(): void {
    this.vm.unsubscribe(this.listener);
    this.mpvm.unsubscribe(this.mpListener);
  }

  /** 从持久化缓存还原 Hero 海报（开 App 首帧即有图，弱网/离线不空） */
  private restoreHeroFromCache(): void {
    const cache = this.mpvm.state.heroCache;
    if (cache === null || cache.items.length === 0) {
      return;
    }
    const list: MpMedia[] = [];
    for (const it of cache.items) {
      const m: MpMedia = new MpMedia();
      m.mediaId = it.mediaId;
      m.title = it.title;
      m.year = it.year;
      m.type = it.type;
      m.overview = it.overview;
      m.posterUrl = it.posterUrl;
      m.backdropUrl = it.backdropUrl;
      m.vote = it.vote;
      m.genres = it.genres;
      list.push(m);
    }
    this.heroPosters = list;
  }

  /** server 就绪/切换时：先还原缓存，再联网刷新（每台 server 只拉一次） */
  private maybeLoadHero(): void {
    const server: MpServer | null = this.mpvm.state.server();
    // 缓存只还原一次首帧（避免每次 listener 都覆盖刚联网拿到的新图）
    if (this.heroPosters.length === 0) {
      this.restoreHeroFromCache();
    }
    if (server === null) {
      return;
    }
    const key: string = server.id;
    if (key === this.heroLoadedKey) {
      return;
    }
    // 缓存若已经是这台 server 的，先记 key 避免重复拉；仍会拉一次做后台刷新
    this.heroLoadedKey = key;
    this.loadHeroPosters(server);
  }

  /** 直接调 client.recommend，不碰 mpvm.state.items/channel/page */
  private loadHeroPosters(server: MpServer): void {
    if (!server.isValid()) {
      return;
    }
    this.heroError = '';
    const client: MoviePilotClient = new MoviePilotClient(server);
    // 多取一些以便过滤掉没有 backdrop 的条目后还能补满 8 张
    client.recommend(MP_CHANNELS[0], 1, 20).then((list: MpMedia[]): void => {
      const wide: MpMedia[] = list.filter((m: MpMedia): boolean => m.backdropUrl.length > 0);
      const picked: MpMedia[] = (wide.length > 0 ? wide : list).slice(0, 8);
      if (picked.length === 0) {
        // 空结果不覆盖已有缓存图
        if (this.heroPosters.length === 0) {
          this.heroError = '暂无推荐海报';
        }
        return;
      }
      this.heroPosters = picked;
      this.mpvm.saveHeroCache(server.id, picked); // 落盘，下次开 App 直接命中
    }).catch((e: Error): void => {
      // 失败保留旧图（stale-on-error），只在不提示会误导时给提示
      if (this.heroPosters.length === 0) {
        this.heroError = e.message.length > 0 ? e.message : '推荐加载失败';
      }
    });
  }

  /** 右上按钮：打开当前海报详情（MediaDetail.onReady 内会调 openDetail） */
  private openHeroDetail(media: MpMedia): void {
    this.navStack.pushPathByName('mpDetail', media);
  }

  /** "1.23 GB" → 数字部分（瓦片用大字号）/ 单位部分（小字号） */
  private bytesValue(bytes: number): string {
    const text: string = formatBytes(bytes);
    const space: number = text.indexOf(' ');
    return space > 0 ? text.substring(0, space) : text;
  }

  private bytesUnit(bytes: number): string {
    const text: string = formatBytes(bytes);
    const space: number = text.indexOf(' ');
    return space > 0 ? text.substring(space + 1) : '';
  }

  /** 速率单位（MB / KB / B）：拼接「MB/s」用，取不到时兜底成 B，绝不出现只有斜杠的情况 */
  private bytesUnitSuffix(bytes: number): string {
    const u: string = this.bytesUnit(bytes);
    return u.length > 0 ? u : 'B';
  }

  /**
   * 剩余空间取值优先级：
   * 1) MoviePilot 的挂载盘统计（用户实测最准，按媒体库实际目录算）；
   * 2) 拿不到时退回下载器 RPC 的 free_space（同主机去重后求和）。
   */
  private freeSpaceBytes(): number {
    const st: MpStorage | null = this.mpStorage;
    if (st !== null && st.isValid() && st.freeBytes() > 0) {
      return st.freeBytes();
    }
    // mpStorage 拿到对象但剩余为 0（MP 只统计配置了下载目录的盘）时也要继续往下退，
    // 否则会停在 0 B 不再用下载器的 free_space。
    return this.effectiveState().totalFreeSpace();
  }

  private freeSpaceCaption(): string {
    const st: MpStorage | null = this.mpStorage;
    return st !== null && st.isValid() ? '剩余空间 · 挂载盘' : '剩余空间';
  }

  /** MP 挂载盘总容量（0 = 没拿到，退回下载器口径时没有总容量） */
  private storageTotal(): number {
    const st: MpStorage | null = this.mpStorage;
    return st !== null && st.isValid() ? st.totalBytes : 0;
  }

  private storageUsed(): number {
    const st: MpStorage | null = this.mpStorage;
    if (st !== null && st.isValid() && st.usedBytes > 0) {
      return st.usedBytes;
    }
    return 0;
  }

  /** 已使用百分比（0~100，保留一位小数） */
  private storageUsedPercent(): number {
    const total: number = this.storageTotal();
    if (total <= 0) {
      return 0;
    }
    const pct: number = this.storageUsed() / total * 100;
    return pct > 100 ? 100 : pct;
  }

  private storagePercentText(): string {
    const pct: number = this.storageUsedPercent();
    return (Math.round(pct * 10) / 10).toFixed(1);
  }

  /**
   * MP 同款「实时速率」单卡（对齐安卓 RealtimeSpeedCard）：
   * 下载/上传速率分列 → 总下载 / 总上传 / 剩余空间（卡内不再重复写标题）。
   * 数据优先直读 MP 仪表盘 `dashboard/downloader`；MP 五项全 0（服务端无下载目录 /
   * 下载器采样为空）时整卡退回 App 直连下载器的口径，避免整张卡空白。
   */
  @Builder
  RealtimeSpeedCard() {
    ElevatedCard({ paddingVp: 16 }) {
      Column() {
        // 标题行已删：区块标题「实时速率」就在卡片正上方，卡内再写一遍是重复
        Row() {
          Column() {
            Text('下载速率')
              .fontSize(this.theme.fs(12))
              .fontColor(this.theme.colors.textSecondary)
            Blank().height(3)
            Row() {
              Text(this.bytesValue(this.liveSpeed(false)))
                .fontSize(this.theme.fs(24))
                .fontWeight(FontWeight.Medium)
                .fontColor(Palette.blue)
                .maxLines(1)
                .constraintSize({ maxWidth: 110 })
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${this.bytesUnitSuffix(this.liveSpeed(false))}/s`)
                .fontSize(this.theme.fs(12))
                .fontColor(this.theme.colors.textSecondary)
                .maxLines(1)
            }
            .alignItems(VerticalAlign.Bottom)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Column()
            .width(0.5)
            .height(44)
            .backgroundColor(this.theme.colors.separator)

          Blank().width(14)

          Column() {
            Text('上传速率')
              .fontSize(this.theme.fs(12))
              .fontColor(this.theme.colors.textSecondary)
            Blank().height(3)
            Row() {
              Text(this.bytesValue(this.liveSpeed(true)))
                .fontSize(this.theme.fs(24))
                .fontWeight(FontWeight.Medium)
                .fontColor(Palette.green)
                .maxLines(1)
                .constraintSize({ maxWidth: 110 })
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${this.bytesUnitSuffix(this.liveSpeed(true))}/s`)
                .fontSize(this.theme.fs(12))
                .fontColor(this.theme.colors.textSecondary)
                .maxLines(1)
            }
            .alignItems(VerticalAlign.Bottom)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Blank().height(12)
        Row()
          .width('100%')
          .height(0.5)
          .backgroundColor(this.theme.colors.separator)
        Blank().height(10)

        Row() {
          SpeedTotalCell({ label: '总下载', value: formatBytes(this.cardTotalDownload()) })
          SpeedTotalCell({ label: '总上传', value: formatBytes(this.cardTotalUpload()) })
          SpeedTotalCell({ label: '剩余空间', value: formatBytes(this.cardFreeSpace()) })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        if (this.mpLive.speedError.length > 0) {
          Blank().height(6)
          Text(`速率刷新失败：${this.mpLive.speedError}`)
            .fontSize(this.theme.fs(11))
            .fontColor(Palette.red)
            .maxLines(2)
        }

        // 三格全 0 时补一行诊断（有数时不显示）：一眼区分「MP 没给数据」
        // 「下载器快照没回来」「任务列表为空」三种情况，省掉来回猜。
        if (this.cardTotalDownload() <= 0 && this.cardTotalUpload() <= 0 &&
          this.cardFreeSpace() <= 0) {
          Blank().height(6)
          Text(this.diagnosisText())
            .fontSize(this.theme.fs(10))
            .fontColor(this.theme.colors.textSecondary)
            .maxLines(2)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /**
   * MP 的 `/dashboard/downloader` 是否真的拿到了数据。
   *
   * MP v3.2 的实现里，下载器汇总来自 `DashboardChain().downloader_info()`，
   * 一旦服务端没配「下载目录」或下载器采样为空，五个字段会**一起**返回 0
   * （`sample_downloader()` 直接 `return DownloaderInfo()`）—— 网页那张卡也是 0。
   * 所以只要五项全 0 就判为「MP 没数据」，整卡改用 App 直连下载器的 RPC 口径。
   */
  private mpDownloaderReady(): boolean {
    const d: MpDownloaderInfo = this.mpLive.downloader;
    return !d.isEmpty();
  }

  /**
   * 三格全 0 时的诊断行（有数时不显示）。
   * `MP 空/有值` 区分 MP 服务端有没有给数据；`快照 N 台` 是 App 直连下载器回来的状态数；
   * `任务 N 条` 是当前列表条数。三者一对照就能定位卡在哪一层。
   */
  private diagnosisText(): string {
    const st: AppState = this.effectiveState();
    const d: MpDownloaderInfo = this.mpLive.downloader;
    const mpTotal: number = d.downloadSize + d.uploadSize + d.freeSpace;
    return `诊断 · MP ${mpTotal > 0 ? '有值' : '空'}(${d.downloadSize}/${d.uploadSize}/${d.freeSpace})` +
      ` · 快照 ${st.snapshots.size} 台 · 任务 ${st.tasks.length} 条`;
  }

  /**
   * 逐项取值：某一项 MP 给了正数就用 MP（与网页口径一致），
   * 这一项是 0 就单独退回 App 直连下载器/挂载盘的数。
   *
   * 不能「整卡二选一」——MP 经常回半残数据（速率有值、累计量和剩余空间是 0，
   * 或者反过来），整卡切换会把本来能拿到的字段一起变成 0 B，这正是鸿蒙端
   * 之前「总下载/总上传/剩余空间全 0」的直接原因。
   */
  private pickMp(mp: number, local: () => number): number {
    return mp > 0 ? mp : local();
  }

  /**
   * 取「最新的」下载器状态。
   *
   * 正常情况下 `this.state` 就是 VM 推过来的副本；但它有两个落后窗口：
   * ① 页面首次 mount 时还是 `new AppState()`（快照为空），FM 的首次 refresh 尚未回来；
   * ② @State 赋的是同一个引用时 ArkUI 可能不重绘，UI 停在上一帧。
   * 只要副本里没有快照而单例有，就直接读单例，避免实时速率卡整片 0 B。
   */
  private effectiveState(): AppState {
    if (this.state.snapshots.size === 0 && this.vm.state.snapshots.size > 0) {
      return this.vm.state;
    }
    return this.state;
  }

  /** 下载 / 上传速率（MP 有值用 MP，否则用下载器直连值） */
  private liveSpeed(up: boolean): number {
    const d: MpDownloaderInfo = this.mpLive.downloader;
    const st: AppState = this.effectiveState();
    return this.pickMp(
      up ? d.uploadSpeed : d.downloadSpeed,
      (): number => up ? st.totalUploadSpeed() : st.totalDownloadSpeed()
    );
  }

  /** 总下载量（MP → 快照累计量 → 任务列表求和，三级兜底） */
  private cardTotalDownload(): number {
    const mp: number = this.mpLive.downloader.downloadSize;
    if (mp > 0) {
      return mp;
    }
    const st: AppState = this.effectiveState();
    const snap: number = st.totalDownloaded();
    return snap > 0 ? snap : st.sumTaskDownloaded();
  }

  /** 总上传量（同三级兜底） */
  private cardTotalUpload(): number {
    const mp: number = this.mpLive.downloader.uploadSize;
    if (mp > 0) {
      return mp;
    }
    const st: AppState = this.effectiveState();
    const snap: number = st.totalUploaded();
    return snap > 0 ? snap : st.sumTaskUploaded();
  }

  /** 剩余空间：MP 下载目录口径 → MP 挂载盘 → App 下载器 free_space（按主机去重） */
  private cardFreeSpace(): number {
    return this.pickMp(this.mpLive.downloader.freeSpace, (): number => this.freeSpaceBytes());
  }

  /**
   * 「实时总带宽 / 存储空间」这一排两块瓦片共用的高度。
   * 存储空间那张内容最多（图标行 + 大号数值 + 已使用 + 进度条 + 可用/总容量），是这一排的天花板；
   * 两块给同一个固定高度，就不依赖 Flex stretch（真机上没生效，右边会高出一截）。
   * 78 = 内边距 28 + 图标行 19 + 间距 10+4+6+6 + 进度条 5；三行文字按 1.4 倍行高估，末尾再留 6 的余量。
   */
  private assetTileHeight(): number {
    const text: number = this.theme.fs(22) + this.theme.fs(12) + this.theme.fs(10);
    return Math.round(78 + text * 1.4) + 6;
  }

  @Builder
  BandwidthTile() {
    // 外层：实色圆角底承影（gradient 是独立绘制层、不参与 shadow 轮廓，单层会投出直角）
    Column() {
      Column() {
      Text('⇄')
        .fontSize(this.theme.fs(18))
        .fontColor(Palette.orange)
      Column() {
        Row() {
          Text(this.bytesValue(this.state.totalBandwidth()))
            .fontSize(this.theme.fs(22))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.bytesUnitSuffix(this.state.totalBandwidth())}/s`)
            .fontSize(this.theme.fs(12))
            .fontColor(this.theme.colors.textSecondary)
            .maxLines(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        Blank().height(6)
        Text('实时总带宽')
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
    }
    // 等高：上下两端撑开（图标顶、数值贴底），中间不留一块突兀的空白
    .height(this.assetTileHeight())
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .borderRadius(Metrics.tileRadius)
    // 和「数据聚合」那四块同一套立体语言：冷调渐变 + 高光边 + 蓝灰柔影
    .linearGradient({
      angle: 180,
      colors: this.theme.colors.isDark
        ? [[withAlpha(0x2B2B32, 0xF7), 0.0], [withAlpha(0x202026, 0xF0), 1.0]]
        : [[withAlpha(0xFCFDFF, 0xFA), 0.0], [withAlpha(0xE3EBF8, 0xF5), 1.0]]
    })
    .border({
      width: 0.8,
      color: withAlpha(0xFFFFFF, this.theme.colors.isDark ? 0x2A : 0xF5),
      radius: Metrics.tileRadius
    })
    .padding(14)
      }
      .layoutWeight(1)
      .height(this.assetTileHeight())
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(HorizontalAlign.Start)
      .borderRadius(Metrics.tileRadius)
      .backgroundColor(this.theme.colors.isDark ? 0x2B2B32 : 0xFCFDFF)
      .shadow({
        radius: 26,
        color: this.theme.colors.isDark ? 'rgba(0,0,0,0.42)' : 'rgba(59,76,112,0.14)',
        offsetX: 0,
        offsetY: 11,
        fill: true
      })
      .margin({ right: Metrics.cardGap })
  }

  @Builder
  StorageTile() {
    // 外层：实色圆角底承影，内层铺渐变
    Column() {
      Column() {
      Row() {
        // 安卓版 Icons.Rounded.Storage 同款：三条圆角横杠 + 薄荷绿
        Column({ space: 3 }) {
          Row().width(19).height(4).borderRadius(2).backgroundColor(Palette.mint)
          Row().width(19).height(4).borderRadius(2).backgroundColor(Palette.mint)
          Row().width(19).height(4).borderRadius(2).backgroundColor(Palette.mint)
        }
        .margin({ top: 2 })
        Blank().width(7)
        Text('存储空间')
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.textSecondary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Blank().height(10)
      Text(this.storageTotal() > 0
        ? formatStorageSize(this.storageTotal())
        : (this.freeSpaceBytes() > 0 ? formatStorageSize(this.freeSpaceBytes()) : '—'))
        .fontSize(this.theme.fs(22))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.colors.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.storageTotal() > 0) {
        Blank().height(4)
        Text(`已使用 ${this.storagePercentText()}%`)
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
        Blank().height(6)
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(5)
            .borderRadius(3)
            .backgroundColor(withAlpha(Palette.mint, 0x26))
          Row()
            .width(`${this.storageUsedPercent()}%`)
            .height(5)
            .borderRadius(3)
            .backgroundColor(Palette.mint)
        }
        .width('100%')
        .height(5)
        .alignContent(Alignment.Start)
        Blank().height(6)
        Text(`可用 ${formatStorageSize(this.freeSpaceBytes())} / 总容量 ${formatStorageSize(this.storageTotal())}`)
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        Blank().height(6)
        Text(this.freeSpaceCaption())
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
      }
    }
    .height(this.assetTileHeight())
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .borderRadius(Metrics.tileRadius)
    // 同「实时总带宽」：渐变 + 高光边 + 柔影，两块瓦片观感一致
    .linearGradient({
      angle: 180,
      colors: this.theme.colors.isDark
        ? [[withAlpha(0x2B2B32, 0xF7), 0.0], [withAlpha(0x202026, 0xF0), 1.0]]
        : [[withAlpha(0xFCFDFF, 0xFA), 0.0], [withAlpha(0xE3EBF8, 0xF5), 1.0]]
    })
    .border({
      width: 0.8,
      color: withAlpha(0xFFFFFF, this.theme.colors.isDark ? 0x2A : 0xF5),
      radius: Metrics.tileRadius
    })
    .padding(14)
      }
      .layoutWeight(1)
      .height(this.assetTileHeight())
      .alignItems(HorizontalAlign.Start)
      .borderRadius(Metrics.tileRadius)
      .backgroundColor(this.theme.colors.isDark ? 0x2B2B32 : 0xFCFDFF)
      .shadow({
        radius: 26,
        color: this.theme.colors.isDark ? 'rgba(0,0,0,0.42)' : 'rgba(59,76,112,0.14)',
        offsetX: 0,
        offsetY: 11,
        fill: true
      })
  }

  private openServerTasks(serverId: string): void {
    // 与安卓 v1.0.8 一致：点下载器卡片进入「该下载器」的覆盖层状态页，
    // 不切 Tab、也不改全局 activeServerId（改全局会让别的页面跟着跳）
    AppStorage.setOrCreate('downloadersFocusServer', serverId);
    this.navStack.pushPathByName('downloaders', '');
  }

  // ==================== 系统信息（CPU / 内存 / 系统，各自独立卡片） ====================

  /** 区块标题右侧说明（同时用来判断当前卡片用的是哪套口径） */
  private liveCaption(): string {
    if (!this.mpConfigured) {
      return '未接入 MoviePilot';
    }
    if (this.mpLive.lastSpeedAt <= 0) {
      return this.mpLive.speedError.length > 0 ? '上次刷新失败' : '正在连接…';
    }
    // MP 服务端没配下载目录 / 下载器采样为空时（五项全 0），卡片改用下载器直连数据
    if (this.mpDownloaderReady()) {
      return '来自 MoviePilot';
    }
    // MP 没数据时，只要本地快照/任务里还有值，就说明走的是下载器口径；
    // 连本地都没有值 = 下载器也没读到（离线 / 未配置），这时明确报出来，别再显示「来自下载器」误导。
    const localReady: boolean = this.cardTotalDownload() > 0 || this.cardTotalUpload() > 0 ||
      this.cardFreeSpace() > 0;
    return localReady ? '来自下载器' : '暂无数据 · 检查下载器';
  }

  private isCpuValid(): boolean {
    return !Number.isNaN(this.mpLive.cpu);
  }

  /** CPU 最近 30 个采样点 */
  private cpuPoints(): number[] {
    const samples = this.mpLive.cpuSamples;
    const start: number = Math.max(0, samples.length - 30);
    const points: number[] = [];
    for (let i: number = start; i < samples.length; i++) {
      points.push(samples[i].value);
    }
    return points;
  }

  /** Y 轴按峰值取整档，14% 的曲线才不会贴着 100% 底边变成一条直线 */
  private cpuYMax(): number {
    let peak: number = 0;
    for (const p of this.cpuPoints()) {
      if (p > peak) {
        peak = p;
      }
    }
    return this.percentCeil(peak);
  }

  private cpuTicks(): string[] {
    const max: number = this.cpuYMax();
    return [`${Math.round(max)}%`, `${Math.round(max / 2)}%`, '0%'];
  }

  /** 内存使用率曲线（%）：和 CPU 卡同一套画法 */
  private memoryUsagePoints(): number[] {
    const total: number = this.memTotal() > 0 ? this.memTotal() : 1;
    const out: number[] = [];
    for (const s of this.mpLive.memorySamples) {
      const pct: number = s.used / total * 100;
      out.push(Math.min(100, Math.max(0, pct)));
    }
    return out;
  }

  private memoryPeak(): number {
    let peak: number = 0;
    for (const p of this.memoryUsagePoints()) {
      if (p > peak) {
        peak = p;
      }
    }
    return peak;
  }

  /** 百分比曲线取整档（2/5/10/20/50/100），CPU 与内存共用 */
  private percentCeil(peak: number): number {
    if (peak <= 2) {
      return 2;
    }
    if (peak <= 5) {
      return 5;
    }
    if (peak <= 10) {
      return 10;
    }
    if (peak <= 20) {
      return 20;
    }
    if (peak <= 50) {
      return 50;
    }
    return 100;
  }

  /** 内存是否可用（null 判断收在这里，@Builder 里不直接碰可空属性） */
  private hasMemory(): boolean {
    const m: MpMemoryInfo | null = this.mpLive.memory;
    return m !== null && m.total > 0;
  }

  private memUsage(): number {
    const m: MpMemoryInfo | null = this.mpLive.memory;
    return m === null ? NaN : m.usage;
  }

  private memUsed(): number {
    const m: MpMemoryInfo | null = this.mpLive.memory;
    return m === null ? 0 : m.used;
  }

  private memTotal(): number {
    const m: MpMemoryInfo | null = this.mpLive.memory;
    return m === null ? 0 : m.total;
  }

  private memCached(): number {
    const m: MpMemoryInfo | null = this.mpLive.memory;
    return m === null ? 0 : m.cached;
  }

  private memAvailable(): number {
    const m: MpMemoryInfo | null = this.mpLive.memory;
    return m === null ? 0 : m.available;
  }

  private hasSystem(): boolean {
    const s: MpSystemInfo | null = this.mpLive.system;
    return s !== null && !s.isEmpty();
  }

  private sysField(field: string): string {
    const s: MpSystemInfo | null = this.mpLive.system;
    if (s === null) {
      return '';
    }
    if (field === 'hostname') {
      return s.hostname;
    }
    if (field === 'os') {
      return s.operatingSystem;
    }
    return field === 'runtime' ? s.runtime : s.version;
  }

  private percentText(value: number, digits: number): string {
    return Number.isNaN(value) ? '--' : `${value.toFixed(digits)}%`;
  }

  /** CPU 使用率卡（MP 同款：标题行百分比 → 面积折线 → 1/5/15 分钟均值） */
  @Builder
  CpuCard() {
    ElevatedCard({ paddingVp: 14 }) {
      Column() {
        Row() {
          Text('◔')
            .fontSize(this.theme.fs(16))
            .fontColor(Palette.blue)
          Blank().width(8)
          Text('CPU 使用率')
            .fontSize(this.theme.fs(13))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
          Blank()
          Text(this.percentText(this.mpLive.cpu, 1))
            .fontSize(this.theme.fs(15))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Blank().height(10)

        if (this.cpuPoints().length >= 2) {
          MultiLineChart({
            series: [this.cpuPoints()],
            colors: [Palette.blue],
            yMax: this.cpuYMax(),
            yLabels: this.cpuTicks(),
            filledIndex: 0,
            gridColor: this.theme.colors.separator,
            labelColor: this.theme.colors.textSecondary,
            chartHeight: 78
          })
        } else {
          Text('正在采集曲线…')
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
        }

        Blank().height(10)
        Row() {
          Text('平均使用')
            .fontSize(this.theme.fs(10))
            .fontColor(this.theme.colors.textSecondary)
            .layoutWeight(1)
          this.AvgCell('1 分钟', this.mpLive.cpuAverage(60000))
          this.AvgCell('5 分钟', this.mpLive.cpuAverage(300000))
          this.AvgCell('15 分钟', this.mpLive.cpuAverage(900000))
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  AvgCell(label: string, value: number) {
    Column() {
      Text(this.percentText(value, 1))
        .fontSize(this.theme.fs(13))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.colors.textPrimary)
        .maxLines(1)
      Text(label)
        .fontSize(this.theme.fs(10))
        .fontColor(this.theme.colors.textSecondary)
        .maxLines(1)
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  /** 内存使用卡（MP 同款：百分比 → 已用/总量 → 三序列折线 → 带数值图例） */
  @Builder
  MemoryCard() {
    ElevatedCard({ paddingVp: 14 }) {
      Column() {
        Row() {
          Text('▤')
            .fontSize(this.theme.fs(16))
            .fontColor(Palette.orange)
          Blank().width(8)
          Text('内存使用')
            .fontSize(this.theme.fs(13))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
          Blank()
          Text(this.hasMemory() ? this.percentText(this.memUsage(), 1) : '--')
            .fontSize(this.theme.fs(15))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.hasMemory()) {
          Blank().height(4)
          Row() {
            Text(formatBytes(this.memUsed()))
              .fontSize(this.theme.fs(18))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.colors.textPrimary)
              .maxLines(1)
            Text(` / ${formatBytes(this.memTotal())}`)
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
              .maxLines(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Bottom)

          Blank().height(8)
          if (this.mpLive.memorySamples.length >= 2) {
            // 与 CPU 卡同一套画法：画「使用率 %」的面积曲线。
            // 之前画绝对字节（已使用 0.5G / 已缓存 10G，量程 15G），蓝线贴底、另两条压成直线。
            MultiLineChart({
              series: [this.memoryUsagePoints()],
              colors: [Palette.blue],
              yMax: this.percentCeil(this.memoryPeak()),
              yLabels: [
                `${Math.round(this.percentCeil(this.memoryPeak()))}%`,
                `${Math.round(this.percentCeil(this.memoryPeak()) / 2)}%`,
                '0%'
              ],
              filledIndex: 0,
              gridColor: this.theme.colors.separator,
              labelColor: this.theme.colors.textSecondary,
              chartHeight: 78
            })
          } else {
            Text('正在采集曲线…')
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
          }

          Blank().height(8)
          Row() {
            this.LegendCell('已使用', formatBytes(this.memUsed()), Palette.blue)
            this.LegendCell('已缓存', formatBytes(this.memCached()), Palette.purple)
            this.LegendCell('可用', formatBytes(this.memAvailable()), Palette.green)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else {
          Blank().height(8)
          Text('正在读取…')
            .fontSize(this.theme.fs(12))
            .fontColor(this.theme.colors.textSecondary)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  LegendCell(label: string, value: string, color: number) {
    Column() {
      Row() {
        Circle()
          .width(6)
          .height(6)
          .fill(color)
        Blank().width(4)
        Text(label)
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
      }
      .alignItems(VerticalAlign.Center)

      Blank().height(2)
      Text(value)
        .fontSize(this.theme.fs(11))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.colors.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  /** 系统详情卡（仅管理员 JWT 可读；API Token 模式给出说明） */
  @Builder
  SystemCard() {
    ElevatedCard({ paddingVp: 14 }) {
      Column() {
        Row() {
          Text('ⓘ')
            .fontSize(this.theme.fs(16))
            .fontColor(Palette.purple)
          Blank().width(8)
          Text('系统')
            .fontSize(this.theme.fs(13))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Blank().height(8)
        if (this.hasSystem()) {
          this.SysRow('主机名', this.sysField('hostname'))
          this.SysRow('操作系统', this.sysField('os'))
          this.SysRow('运行环境', this.sysField('runtime'))
          this.SysRow('版本', this.sysField('version'))
        } else if (this.mpLive.systemDenied) {
          Text('系统信息需要管理员账号登录（仅 API Token 无权读取）。CPU / 内存不受影响。')
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
            .lineHeight(this.theme.fs(16))
        } else if (this.mpLive.systemError.length > 0) {
          Text(`系统信息读取失败：${this.mpLive.systemError}`)
            .fontSize(this.theme.fs(11))
            .fontColor(Palette.red)
            .lineHeight(this.theme.fs(16))
        } else {
          Text('正在读取…')
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  SysRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(this.theme.fs(11))
        .fontColor(this.theme.colors.textSecondary)
        .width(64)
      Text(value.length > 0 ? value : '--')
        .fontSize(this.theme.fs(11))
        .fontColor(this.theme.colors.textPrimary)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 2, bottom: 2 })
  }

  build() {
    List() {
      // ---- Hero 卡：MP 推荐海报轮播（加高到 190vp，接近 16:9 让海报完整）----
      ListItem() {
        if (this.heroPosters.length > 0) {
          HeroCarousel({
            items: this.heroPosters,
            onOpenDetail: (media: MpMedia): void => { this.openHeroDetail(media); }
          })
        } else {
          // 降级：保留原渐变卡，不展示空白；联上网后自动换成海报
          // 高度与 HeroCarousel 的 cardHeight(190) 保持一致，切换时不跳动
          Stack() {
            Column()
              .width('100%')
              .height(190)
              .borderRadius(22)
              .linearGradient({
                angle: 120,
                colors: [[0xFF1B3A6B, 0.0], [0xFF0A84FF, 0.55], [0xFF5E5CE6, 1.0]]
              })
            Column() {
              Text('MoviePilotTools')
                .fontSize(this.theme.fs(19))
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFFFFFFFF)
                .maxLines(1)
              Blank()
              Text(!this.mpConfigured
                ? '连接 MoviePilot 后展示精选海报'
                : (this.heroError.length > 0 ? `${this.heroError} · 点击重试` : '正在加载推荐影片…'))
                .fontSize(this.theme.fs(11))
                .fontColor(0xD9FFFFFF)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .height('100%')
            .padding(18)
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .height(190)
          .borderRadius(22)
          // 实色圆角底：shadow 取的是背景绘制轮廓，只有 gradient 时会退化成矩形投出直角
          .backgroundColor(0xFF1B3A6B)
          // 抬升阴影让降级 Hero 卡也浮起来（海报轮播卡自带阴影，不用重复加）
          .shadow({
            radius: 18,
            color: this.theme.colors.isDark ? 'rgba(0,0,0,0.50)' : 'rgba(0,0,0,0.22)',
            offsetX: 0,
            offsetY: 8,
            fill: true
          })
          .onClick((): void => {
            const s: MpServer | null = this.mpvm.state.server();
            if (s !== null) {
              this.heroLoadedKey = ''; // 允许重试
              this.loadHeroPosters(s);
            }
          })
        }
      }
      .margin({ bottom: 14 })

      // ---- 实时速率（下载 / 上传各一张，数据来自 MP 仪表盘）----
      if (this.state.settings.showModuleTraffic) {
        ListItem() {
          SectionHeader({ title: '实时速率' }) {
            Text(this.liveCaption())
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
          }
        }
        .margin({ bottom: 8 })
        ListItem() {
          this.RealtimeSpeedCard()
        }
        .margin({ bottom: 14 })
      }

      // ---- 媒体库 ----
      if (this.state.settings.showModuleMedia) {
        ListItem() {
          SectionHeader({ title: '媒体库' }) {
            Text(this.mpStats !== null ? '来自 MoviePilot' : '未接入 MoviePilot')
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
          }
        }
        .margin({ bottom: 8 })
        ListItem() {
          ElevatedCard({ paddingVp: 14, accent: Palette.purple }) {
            this.MediaLibraryCard()
          }
        }
        .margin({ bottom: 14 })
      }

      // ---- 数据聚合 ----
      if (this.state.settings.showModuleAssets) {
        ListItem() {
          SectionHeader({ title: '数据聚合' })
        }
        .margin({ bottom: 8 })
        ListItem() {
          Row() {
            StatTile({
              iconChar: '✔',
              iconTint: Palette.green,
              value: String(this.state.totalSeeding()),
              unit: '个',
              caption: '做种总数'
            })
              .layoutWeight(1)
              .margin({ right: Metrics.cardGap })
            StatTile({
              iconChar: '↓',
              iconTint: Palette.blue,
              value: String(this.state.totalDownloading()),
              unit: '个',
              caption: '正在下载'
            })
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .margin({ bottom: Metrics.cardGap })
        ListItem() {
          // 两块瓦片用同一个固定高度（assetTileHeight）：以前靠 Flex + ItemAlign.Stretch 等高，
          // 真机上没生效，右边「存储空间」比左边「实时总带宽」高一截
          Row() {
            this.BandwidthTile()
            this.StorageTile()
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .margin({ bottom: 14 })
      }

      // ---- 服务器状态 ----
      if (this.state.settings.showModuleServers) {
        ListItem() {
          SectionHeader({ title: '下载服务器状态' })
        }
        .margin({ bottom: 8 })
        if (this.state.servers.length === 0) {
          ListItem() {
            ElevatedCard({ paddingVp: 18 }) {
              Column() {
                Text('还没有添加下载器')
                  .fontSize(this.theme.fs(15))
                  .fontColor(this.theme.colors.textSecondary)
                Blank().height(8)
                Text('点这里添加 qBittorrent 或 Transmission')
                  .fontSize(this.theme.fs(14))
                  .fontColor(this.theme.colors.accent)
                  .onClick((): void => {
                    this.navStack.pushPathByName('serverList', '');
                  })
              }
              .alignItems(HorizontalAlign.Start)
            }
          }
        } else {
          ForEach(this.state.servers, (server: ServerConfig): void => {
            // 一台服务器占一整行（之前半宽卡片又短又挤）
            ListItem() {
              Column() {
                this.ServerStatusTile(server)
              }
              .width('100%')
            }
            .margin({ bottom: Metrics.cardGap })
          }, (server: ServerConfig): string => server.id)
        }
      }

      // ---- 系统信息（默认折叠：折叠时只有一行标题；展开后是 CPU / 内存 / 系统三张独立卡）----
      // 由「设置 → 仪表盘定制 → 服务器状态」开关控制（原来只判 mpConfigured，开关拨了没反应）
      if (this.mpConfigured && this.state.settings.showModuleServers) {
        ListItem() {
          Row() {
            Text('ⓘ')
              .fontSize(this.theme.fs(16))
              .fontColor(Palette.purple)
            Blank().width(8)
            Text('系统信息')
              .fontSize(this.theme.fs(17))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.colors.textPrimary)
            Blank()
            Text(this.systemExpanded ? '收起' : '展开')
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
            Text(this.systemExpanded ? '⌃' : '⌄')
              .fontSize(this.theme.fs(14))
              .fontColor(this.theme.colors.textSecondary)
              .margin({ left: 4 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            this.systemExpanded = !this.systemExpanded;
          })
        }
        .margin({ bottom: 8 })

        if (this.systemExpanded) {
          ListItem() {
            this.CpuCard()
          }
          .margin({ bottom: Metrics.cardGap })

          ListItem() {
            this.MemoryCard()
          }
          .margin({ bottom: Metrics.cardGap })

          ListItem() {
            this.SystemCard()
          }
        }
      }

      // 底部占位项（v1.0.14）：
      // 底栏避让原来加在 List 的 `.padding({ bottom })` 上 —— List 的 padding 会**裁剪**
      // 滚动内容，内容永远进不了底栏那块区域，卡片就在底栏上沿被整齐切断（截图里红箭头
      // 指的那条「硬切边」），底栏自然也透不出任何东西。
      // 换成末尾一个透明占位项：内容能一直铺到屏幕底、从底栏玻璃下面滚过去，
      // 滚到底时又刚好停在胶囊上沿。
      ListItem() {
        Column()
          .width('100%')
          .height(this.bottomInset + 8)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 8 })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .backgroundColor(this.theme.colors.background)
  }

  /**
   * 媒体统计卡：2×2 网格，样式对齐 MoviePilot 里的那张
   * （彩色图标 + 分类名 + 数量 + 本月新增），数据全取 MP 的 dashboard/statistic。
   */
  @Builder
  MediaLibraryCard(): void {
    if (this.mpConfigured && this.mpStats !== null && !this.mpStats.isEmpty()) {
      Column() {
        Row() {
          this.MediaStatCell('电影', this.mpStats.movies, this.mpStats.moviesThisMonth,
            Palette.purple, '🎬')
          this.CellDividerV()
          this.MediaStatCell('电视剧', this.mpStats.tvs, this.mpStats.tvsThisMonth,
            Palette.green, '📺')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row()
          .width('100%')
          .height(0.5)
          .backgroundColor(this.theme.colors.separator)
          .margin({ top: 2, bottom: 2 })

        Row() {
          this.MediaStatCell('剧集', this.mpStats.episodes, this.mpStats.episodesThisMonth,
            Palette.orange, '🎞')
          this.CellDividerV()
          this.MediaStatCell('音乐', this.mpStats.music, this.mpStats.musicThisMonth,
            Palette.blue, '🎵')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
    } else if (this.mpConfigured) {
      Column() {
        Text(this.mpStatsLoadingText())
          .fontSize(this.theme.fs(14))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
        Blank().height(6)
        Text('数据取自 MoviePilot 仪表盘统计。')
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)
          .lineHeight(this.theme.fs(16))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else {
      Column() {
        Text('还没接入 MoviePilot')
          .fontSize(this.theme.fs(14))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
        Blank().height(6)
        Text('添加 MoviePilot 服务器后，这里会显示电影 / 电视剧 / 剧集 / 音乐数量和本月新增。')
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)
          .lineHeight(this.theme.fs(16))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 2×2 网格里的一格：彩色圆徽标 + 分类 / 数量 / 本月新增 */
  @Builder
  MediaStatCell(label: string, count: number, added: number, color: number, glyph: string): void {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        Circle().width(38).height(38).fill(color)
        Text(glyph).fontSize(this.theme.fs(17))
      }
      .width(38)
      .height(38)
      Blank().width(10)
      Column() {
        Text(label)
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
        Text(String(count))
          .fontSize(this.theme.fs(17))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.colors.textPrimary)
          .maxLines(1)
        Text(`+${added} 本月新增`)
          .fontSize(this.theme.fs(10))
          .fontColor(Palette.green)
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8, left: 2, right: 6 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  CellDividerV(): void {
    Divider()
      .vertical(true)
      .height(40)
      .strokeWidth(0.5)
      .color(this.theme.colors.separator)
  }

  private mpStatsLoadingText(): string {
    if (this.mpvm.state.statsLoading) {
      return '正在读取媒体库…';
    }
    if (this.mpvm.state.statsError.length > 0) {
      return `媒体库统计失败：${this.mpvm.state.statsError}`;
    }
    return '媒体库';
  }

  @Builder
  ServerStatusTile(server: ServerConfig): void {
    Column() {
      ElevatedCard({ paddingVp: 13 }) {
        this.ServerStatusTileContent(server)
      }
    }
    .onClick((): void => {
      this.openServerTasks(server.id);
    })
  }

  @Builder
  ServerStatusTileContent(server: ServerConfig): void {
    Column() {
      Row() {
        ServerBadge({ type: server.type, sizeVp: 20 })
        Blank().width(7)
        Text(server.displayName())
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Blank().width(6)
        Dot({ color: this.statusDotColor(server.id), sizeVp: 8 })
        Blank().width(3)
        Text('›')
          .fontSize(13)
          .fontColor(this.theme.colors.textSecondary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Blank().height(10)
      Row() {
        IconValue({ iconChar: '↑', value: `${formatBytes(this.upSpeedOf(server.id))}/s`, tint: Palette.arrowUp })
          .layoutWeight(1)
        IconValue({ iconChar: '↓', value: `${formatBytes(this.downSpeedOf(server.id))}/s`, tint: Palette.blue })
          .layoutWeight(1)
      }
      .width('100%')
      Blank().height(8)
      Row() {
        IconValue({ iconChar: '💾', value: formatStorageSize(this.seedingSizeOf(server.id)),
          tint: this.theme.colors.textSecondary })
          .layoutWeight(1)
        IconValue({ iconChar: '📈', value: this.ratioTextOf(server.id),
          tint: this.theme.colors.textSecondary })
          .layoutWeight(1)
      }
      .width('100%')

      if (this.errorTextOf(server.id).length > 0) {
        Blank().height(8)
        Text(this.errorTextOf(server.id))
          .fontSize(this.theme.fs(11))
          .fontColor(Palette.red)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else if (this.freeSpaceOf(server.id) > 0) {
        Blank().height(8)
        Text(`剩余 ${formatStorageSize(this.freeSpaceOf(server.id))}`)
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private snapshotOf(serverId: string): ServerSnapshot | null {
    return this.state.snapshotOf(serverId);
  }

  private statusDotColor(serverId: string): number {
    const snap: ServerSnapshot | null = this.snapshotOf(serverId);
    if (snap === null) {
      return Palette.orange;
    }
    return snap.online ? Palette.green : Palette.red;
  }

  private upSpeedOf(serverId: string): number {
    const snap: ServerSnapshot | null = this.snapshotOf(serverId);
    return snap !== null ? snap.uploadSpeed : 0;
  }

  private downSpeedOf(serverId: string): number {
    const snap: ServerSnapshot | null = this.snapshotOf(serverId);
    return snap !== null ? snap.downloadSpeed : 0;
  }

  private seedingSizeOf(serverId: string): number {
    const snap: ServerSnapshot | null = this.snapshotOf(serverId);
    return snap !== null ? snap.seedingSize : 0;
  }

  private ratioTextOf(serverId: string): string {
    const snap: ServerSnapshot | null = this.snapshotOf(serverId);
    return (snap !== null ? snap.ratio() : 0).toFixed(2);
  }

  private freeSpaceOf(serverId: string): number {
    const snap: ServerSnapshot | null = this.snapshotOf(serverId);
    return snap !== null && snap.online ? snap.freeSpace : 0;
  }

  private errorTextOf(serverId: string): string {
    const snap: ServerSnapshot | null = this.snapshotOf(serverId);
    if (snap === null || snap.online) {
      return '';
    }
    return snap.error;
  }
}

/**
 * 「总下载 / 总上传 / 剩余空间」这一排的单元格。
 *
 * 必须做成独立 @Component，不能写成带参数的 @Builder：
 * @Builder 的参数是**按值传递**，父组件状态更新后它内部的 `Text(value)` 不会重绘，
 * 卡片会永远停在首帧算出来的 “0 B”（速率那一行因为是 `Text(this.xxx())` 直接求值，
 * 所以能刷新，只剩下面三格不动 —— 这正是「上面有数、下面全 0」的成因）。
 * 换成 @Prop 才能收到父组件传来的新字符串并重绘。
 */
@Component
struct SpeedTotalCell {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Column() {
      Text(this.label)
        .fontSize(this.theme.fs(11))
        .fontColor(this.theme.colors.textSecondary)
        .maxLines(1)
      Blank().height(2)
      Text(this.value)
        .fontSize(this.theme.fs(14))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.colors.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }
}
