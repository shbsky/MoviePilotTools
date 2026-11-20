import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { Configuration } from '@ohos.app.ability.Configuration';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppTheme, themeColors, Palette, Metrics, withAlpha } from '../common/Theme';
import { STORE_THEME_MODE, STORE_FONT_SCALE, STORE_SYSTEM_DARK, AppEnv, logInfo, logWarn } from '../common/AppConstants';
import { BackStack } from '../common/BackStack';
import { AppViewModel } from '../vm/AppViewModel';
import { MpViewModel } from '../vm/MpViewModel';
import { MusicViewModel } from '../vm/MusicViewModel';
import { ToastHost } from '../ui/components/Common';
import { DashboardPage } from '../ui/dashboard/Dashboard';
import { TransfersPage } from '../ui/transfers/Transfers';
import { SiteScreen } from '../ui/sites/SiteScreen';
import { SiteDetailPage } from '../ui/sites/SiteDetailScreen';
import { SiteTorrentDetailPage } from '../ui/sites/SiteTorrentDetailScreen';
import { MusicPage } from '../ui/music/Music';
import { MoviePilotPage } from '../ui/moviepilot/MoviePilot';
import { SettingsPage } from '../ui/settings/Settings';
import { ServerListPage } from '../ui/settings/ServerScreens';
import { TermsScreen } from '../ui/settings/TermsScreen';
import { MpServerListPage } from '../ui/moviepilot/MpServerScreens';
import { MediaDetailPage } from '../ui/moviepilot/MediaDetail';
import { MiniPlayerBar, NowPlayingPage } from '../ui/music/PlayerBars';
import { PlaybackState } from '../model/MusicModels';

/**
 * 根页面（对应安卓 MainActivity.kt）：
 * Navigation 壳（隐藏标题栏）→ 首页 5 Tab + 悬浮胶囊底栏 →
 * 全局 Toast；NavDestination 覆盖层路由（任务详情 / 服务器列表 / 服务器编辑）。
 */

class TabItem {
  readonly label: string;
  readonly icon: string;

  constructor(label: string, icon: string) {
    this.label = label;
    this.icon = icon;
  }
}

const TABS: TabItem[] = [
  new TabItem('仪表盘', '📊'),
  // 第 2 个 Tab 与安卓 v1.0.8 一致：「任务」换成「站点」，
  // 下载器页改为从仪表盘卡片进入的覆盖层（下载器页有完整侧边栏，不适合塞在 Tab 里）
  new TabItem('站点', '🌐'),
  new TabItem('音乐', '🎵'),
  new TabItem('MoviePilot', '🎬'),
  new TabItem('设置', '⚙️')
];

@Entry
@Component
struct Index {
  @StorageLink(STORE_THEME_MODE) @Watch('onThemeSettingChanged') themeMode: string = 'system';
  @StorageLink(STORE_FONT_SCALE) @Watch('onThemeSettingChanged') fontScale: number = 1.0;
  /**
   * 系统当前是否深色（EntryAbility 在启动 / 系统主题切换时写入）。
   * 这是「跟随系统」能实时生效的关键：以前只在页面出现时读一次 Ability config，
   * 系统切了深浅色页面不会重绘，必须等别的状态变化（比如点字体大小）才顺带刷新。
   */
  @StorageLink(STORE_SYSTEM_DARK) @Watch('onSystemColorModeChanged') systemDark: boolean = false;
  @Provide('oiiTheme') theme: AppTheme = new AppTheme(themeColors(false), 1.0);
  @State currentTab: number = 0;
  @Provide('navStack') navStack: NavPathStack = new NavPathStack();
  private mvm: MusicViewModel = MusicViewModel.getInstance();
  @State @Watch('syncBottomInset') playback: PlaybackState = new PlaybackState();
  @StorageLink('openNowPlaying') @Watch('onOpenNowPlaying') openNowPlaying: boolean = false;
  /**
   * 音乐页「投送到音箱」面板是否打开（由 MusicPage 写入）。
   *
   * 弹窗挂在各 Tab 页自己的 Stack 里，而胶囊底栏 / 迷你播放条是本页 Tabs 之后的
   * 兄弟节点，z 序永远在最上面 —— 面板一打开，底部那块就被胶囊压住看不见了。
   * 所以在面板打开期间把这两个元素隐藏，让投送面板真正铺到底（安卓端是 Dialog，
   * 本来就不受底栏影响）。
   */
  @StorageLink('castSheetOpen') castSheetOpen: boolean = false;
  /** 全屏播放页激活中：Navigation 避让 padding 归零（深色背景铺满系统栏区域） */
  @StorageLink('nowPlayingActive') @Watch('onNowPlayingActive') nowPlayingActive: boolean = false;
  /** 沉浸式安全区高度（vp）：顶部状态栏 / 底部小白条导航指示器 */
  @State topSafeVp: number = 0;
  @State @Watch('syncBottomInset') bottomSafeVp: number = 0;
  /** 当前是否深色主题（applySystemBar 用：播放页全屏态下图标强制转白） */
  private isDark: boolean = false;

  private mvmListener: () => void = (): void => {
    this.playback = this.mvm.playback();
  };

  aboutToAppear(): void {
    this.rebuildTheme();
    this.computeSafeArea();
    this.syncBottomInset();
    AppEnv.attach(getContext(this) as common.UIAbilityContext);
    AppViewModel.getInstance().bootstrap();
    MpViewModel.getInstance().bootstrap();
    this.mvm.subscribe(this.mvmListener);
    this.mvm.bootstrap();
    logInfo('Index', '根页面就绪');
  }

  /**
   * 把「悬浮栏 + 迷你条 + 安全区」的避让高度广播给五个 Tab 页。
   *
   * v1.0.12：以前这个高度是加在 Tabs 上的 padding —— 页面因此比屏幕矮一截，
   * 弹窗的遮罩只能盖到页面底部，底部那条（悬浮栏所在区域）不会变暗，
   * 看着像「弹窗一出来下面就白了」。现在页面铺满整屏，避让改由各页自己的
   * 滚动内容加底部内边距，遮罩就能盖满整个屏幕。
   */
  private syncBottomInset(): void {
    const next: number = this.bottomInsetVp();
    const cur: number | undefined = AppStorage.get<number>('bottomInsetVp');
    // 值没变就别写：playback 每秒都可能刷新一次，重复写 AppStorage 会让五个 Tab 页白白重绘
    if (cur === undefined || Math.abs(cur - next) > 0.01) {
      AppStorage.setOrCreate('bottomInsetVp', next);
    }
  }

  /** 迷你条点击 → 打开全屏播放页 */
  onOpenNowPlaying(): void {
    if (this.openNowPlaying) {
      AppStorage.setOrCreate('openNowPlaying', false);
      this.navStack.pushPathByName('nowPlaying', '');
    }
  }

  onThemeSettingChanged(): void {
    this.rebuildTheme();
  }

  /** 系统深浅色变化：只有「跟随系统」时才需要跟着变，显式选了浅/深色时用户意志优先 */
  onSystemColorModeChanged(): void {
    if (this.themeMode === 'system') {
      this.rebuildTheme();
    }
  }

  /** 页面重新显示（从后台回来 / 从其它页返回）：系统主题可能在后台期间已变，补一次判定 */
  onPageShow(): void {
    this.rebuildTheme();
  }

  /** 仪表盘服务器卡片下钻：改为打开下载器覆盖层（见 Dashboard.openServer） */

  private systemIsDark(): boolean {
    // 优先用 EntryAbility 维护的系统状态：系统切换深浅色时会实时写入 AppStorage
    const cached: boolean | undefined = AppStorage.get<boolean>(STORE_SYSTEM_DARK);
    if (cached !== undefined) {
      return cached;
    }
    // 兜底：直接读 Ability 配置（AppStorage 尚未初始化时）
    try {
      const ctx: common.Context = getContext(this);
      const cfg: Configuration = (ctx as common.UIAbilityContext).config;
      if (cfg !== undefined && cfg.colorMode !== undefined) {
        return cfg.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      }
    } catch (err) {
      // 忽略，回退浅色
    }
    return false;
  }

  private rebuildTheme(): void {
    let dark: boolean = false;
    if (this.themeMode === 'dark') {
      dark = true;
    } else if (this.themeMode === 'light') {
      dark = false;
    } else {
      dark = this.systemIsDark();
    }
    this.theme = new AppTheme(themeColors(dark), this.fontScale);
    this.isDark = dark;
    // 运行时主题切换：同步状态栏/导航条图标颜色（浅色主题深色图标，反之白色）
    this.applySystemBar();
  }

  /**
   * 计算状态栏/导航指示器（小白条）安全区高度（px→vp）。
   * setWindowLayoutFullScreen(true) 后系统不再自动避让，由 Navigation padding 统一处理。
   * API（已对 SDK d.ts 核对）：Window.getWindowAvoidArea(AvoidAreaType): AvoidArea。
   */
  private computeSafeArea(): void {
    window.getLastWindow(getContext(this) as common.UIAbilityContext)
      .then((win: window.Window): void => {
        const statusArea: window.AvoidArea =
          win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const navArea: window.AvoidArea =
          win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        this.topSafeVp = px2vp(statusArea.topRect.height);
        this.bottomSafeVp = px2vp(navArea.bottomRect.height);
        // 发布给全屏播放页（NowPlaying 自行铺满系统栏区域后内容再避让）
        AppStorage.setOrCreate('sysTopSafeVp', this.topSafeVp);
        AppStorage.setOrCreate('sysBottomSafeVp', this.bottomSafeVp);
        // 屏幕高度（vp）：弹窗内容区用它算「最多能有多高」，内容多的弹窗（任务详情）才能一次显示完
        const rect: window.Rect = win.getWindowProperties().windowRect;
        AppStorage.setOrCreate('sysScreenHeightVp', px2vp(rect.height));
        logInfo('Index',
          `安全区: top=${this.topSafeVp}vp bottom=${this.bottomSafeVp}vp 屏高=${px2vp(rect.height)}vp`);
      })
      .catch((err: BusinessError): void => {
        logWarn('Index', `获取安全区失败: ${err.code}`);
      });
  }

  /** 全屏播放页进出：系统栏图标颜色跟随（深色页面配白色图标） */
  onNowPlayingActive(): void {
    this.applySystemBar();
  }

  /** 系统栏透明背景 + 图标颜色：播放页全屏态强制白色，否则随主题 */
  private applySystemBar(): void {
    const contentLight: boolean = this.nowPlayingActive || this.isDark;
    window.getLastWindow(getContext(this) as common.UIAbilityContext)
      .then((win: window.Window): void => {
        win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: contentLight ? '#FFFFFF' : '#000000',
          navigationBarContentColor: contentLight ? '#FFFFFF' : '#000000'
        });
      })
      .catch((err: BusinessError): void => {
        logWarn('Index', `系统栏颜色设置失败: ${err.code}`);
      });
  }

  private tabIconColor(index: number): number {
    return this.currentTab === index ? Palette.blue : this.theme.colors.textSecondary;
  }

  /** 选中项胶囊的「浮起」阴影；未选中给 0 阴影（清透，不影响玻璃通透感） */
  private tabItemShadow(index: number): ShadowOptions {
    if (this.currentTab === index) {
      return {
        radius: 12,
        color: 'rgba(10,132,255,0.40)',
        offsetX: 0,
        offsetY: 4
      };
    }
    return { radius: 0, color: 'rgba(0,0,0,0)', offsetX: 0, offsetY: 0 };
  }

  /**
   * 底栏玻璃面的纵向渐变（酷安同款）。
   *
   * **目标效果（用户定的，别再改方向）**：就是截图里那张「彩色磨砂玻璃」——
   * 海报能透过底栏看到，但被糊成一片柔和的彩色雾；图标浮在这层雾上面。
   * 这需要 `backdropBlur` + 低 alpha 填充**两者同时存在**，缺一个就变味：
   *   · 只有低 alpha 没 blur → 背后海报/文字清清楚楚穿过底栏，跟图标打架（v1.0.22 被否）；
   *   · 只有 blur 没有低 alpha（或 alpha 太高）→ 变成浅色实板，海报被冲成一片白（v1.0.23 被否）。
   *
   * 三段式的用意（酷安那个胶囊最抓眼的就是这条顶缘亮边）：
   *  0%   一条较实的亮边 → 玻璃的「厚度」高光
   *  8%   落回很淡的雾面
   *  100% 更透 → 下半部分越来越通透，像一块斜切玻璃
   *
   * 要微调只改这三个 alpha，布局不用动。
   */
  private barGlassColors(): Array<[number, number]> {
    if (this.theme.colors.isDark) {
      return [
        [withAlpha(0xFFFFFF, 0x24), 0.0],
        [withAlpha(0x1C1C22, 0x80), 0.08],
        [withAlpha(0x14141A, 0x52), 1.0]
      ];
    }
    return [
      [withAlpha(0xFFFFFF, 0x9E), 0.0],
      [withAlpha(0xF7FAFF, 0x3D), 0.08],
      [withAlpha(0xE9EFFA, 0x16), 1.0]
    ];
  }

  /**
   * 底栏底衬色。
   *
   * 只加**极淡**一层（浅色 7% 白 / 深色 13% 黑），作用是给 `shadow(fill:true)` 一个
   * 「真实圆角轮廓」：ArkUI 的阴影轮廓取自组件的背景绘制内容，纯 linearGradient
   * 不参与轮廓计算，圆角外侧会露出方形灰角（Common.ets 里好卡也踩过这个坑）。
   * 透明度必须压到很低，否则就又变成挡住内容的实心板了。
   */
  private barBaseColor(): number {
    return this.theme.colors.isDark ? withAlpha(0x000000, 0x22) : withAlpha(0xFFFFFF, 0x12);
  }

  /** 底栏玻璃高光描边：深色主题压低亮度，避免泛白 */
  private barRimColor(): number {
    return withAlpha(0xFFFFFF, this.theme.colors.isDark ? 0x33 : 0xF2);
  }

  /** 系统返回键：先让 Tab 页内部的覆盖层逐层关闭，再弹 NavDestination，最后回首页 Tab */
  onBackPress(): boolean {
    // Tab 页内部的覆盖层（订阅列表 / 编辑订阅 / 选择器 / 面板 / 批量操作…）不在 NavPathStack 里，
    // 由各页在 aboutToAppear 注册到 BackStack，这里优先询问，避免直接跳回仪表盘。
    if (BackStack.get().dispatch(this.currentTab)) {
      return true;
    }
    if (this.navStack.size() > 0) {
      this.navStack.pop();
      return true;
    }
    if (this.currentTab !== 0) {
      this.currentTab = 0;
      return true;
    }
    return false;
  }

  /**
   * 五个 Tab 页滚动内容的底部避让高度（BUG-4）：
   * 悬浮胶囊 TabBar + 迷你播放条（正在播放时）叠加高度 + 底部安全区。
   * v1.0.12：Navigation 不再统一留底部 padding（改全屏沉浸），安全区高度改由这里补，
   * 否则列表最后一屏会被小白条区域盖住。
   *
   * v1.0.13：从 +76 收到 +64 —— 76 是按「胶囊 52 + 空隙 24」估的，实际滚到底时
   * 最后一项离胶囊顶边还有一大截空白，看着像「内容落不到底栏」。现在
   * 64 = 胶囊 52 + 12vp 呼吸空隙，最后一项刚好停在胶囊上沿，视觉上贴住底栏。
   */
  private bottomInsetVp(): number {
    const bar: number = this.barBottomVp() + 64;
    return this.playback.current !== null ? bar + Metrics.miniPlayerInset : bar;
  }

  /**
   * 胶囊底栏距屏幕物理底边的距离（vp）。
   * 以前是「内容区底部留出整个安全区高度」，胶囊等于坐在安全区上沿、圆角还被切掉，
   * 底边露出一条空白 → 看着像 App 没铺满屏。现在整屏铺满，胶囊只让开小白条一点点。
   */
  private barBottomVp(): number {
    const safe: number = this.bottomSafeVp;
    return safe > 16 ? safe - 16 : 6;
  }

  /** 播放页占位（T05-T07 接入真实页面后替换） */
  @Builder
  MpPlaceholderPage(title: string) {
    NavDestination() {
      Column() {
        Text(title)
          .fontSize(this.theme.fs(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
        Blank().height(10)
        Text('该页面将在后续版本开放')
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.textSecondary)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(this.theme.colors.background)
    }
    .hideTitleBar(true)
    .width('100%')
    .height('100%')
  }

  /** NavDestination 路由表 */
  @Builder
  PagesMap(name: string) {
    if (name === 'serverList') {
      // 仅作「设置 / 仪表盘 / 音乐」里下载器设置的兼容壳，内容仍是弹窗
      ServerListPage()
    } else if (name === 'mpServerList') {
      MpServerListPage()
    } else if (name === 'mpDetail') {
      MediaDetailPage()
    } else if (name === 'nowPlaying') {
      NowPlayingPage()
    } else if (name === 'terms') {
      TermsScreen()
    } else if (name === 'downloaders') {
      TransfersPage()
    } else if (name === 'siteDetail') {
      SiteDetailPage()
    } else if (name === 'siteTorrent') {
      SiteTorrentDetailPage()
    }
  }

  build() {
    // 最外层 Stack：Toast 必须挂在 Navigation **外面**。
    // NavDestination（下载器 / 设置 / 种子详情等二级页）会整层盖住 Navigation 内部，
    // 以前 Toast 放在里面，导致这些页面上的提示（备用限速、已保存、删除成功…）一个都看不见。
    Stack({ alignContent: Alignment.Bottom }) {
      Navigation(this.navStack) {
      Stack() {
        Tabs({ index: this.currentTab, barPosition: BarPosition.End }) {
          TabContent() {
            DashboardPage()
          }
          TabContent() {
            SiteScreen()
          }
          TabContent() {
            MusicPage()
          }
          TabContent() {
            MoviePilotPage()
          }
          TabContent() {
            SettingsPage()
          }
        }
        .barHeight(0)
        .scrollable(false)
        .edgeEffect(EdgeEffect.None)
        // 页面铺满整屏（不再在这里留底部 padding）：
        // 底部避让由各 Tab 页读 AppStorage('bottomInsetVp') 加在滚动内容上，
        // 这样弹窗遮罩能盖住整屏，底部不会留一条没变暗的白边
        .layoutWeight(1)

        // 底部悬浮胶囊 TabBar：系统级背景模糊 + 高光描边 + 柔影，
        // 选中项是一枚带高光边的淡蓝「凸起」胶囊。
        Column() {
          Row() {
            // 注意：这里**不能**再放任何「绝对定位装饰层」（光斑、薄涂）。
            // ArkUI 的 position 组件仍会参与 Row 的布局测量，装饰层会吃掉宽度，
            // 导致 5 个 layoutWeight(1) 的 Tab 分到不等宽 —— 真机上表现就是
            // 选中胶囊偏大、后面的图标整体往左漂。玻璃的色调交给底层的实底 + 淡渐变。
            ForEach(TABS, (item: TabItem, idx: number): void => {
              Column() {
                Text(item.icon)
                  .fontSize(21)
                  .fontColor(this.tabIconColor(idx))
                Blank().height(3)
                Text(item.label)
                  .fontSize(10)
                  .fontWeight(this.currentTab === idx ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(this.tabIconColor(idx))
                  .maxLines(1)
              }
              // 用等分宽度而不是 layoutWeight：Row 里只要有任何额外子节点参与测量，
              // layoutWeight 就会把余量分配得不等，选中胶囊看着就偏了
              .width(`${100 / TABS.length}%`)
              .borderRadius(16)
              .padding({ top: 6, bottom: 6 })
              .backgroundColor(this.currentTab === idx ? withAlpha(Palette.blue, 0x24) : Color.Transparent)
              .border({
                width: this.currentTab === idx ? 0.6 : 0,
                color: withAlpha(0xFFFFFF, this.theme.colors.isDark ? 0x33 : 0xD9)
              })
              .shadow(this.tabItemShadow(idx))
              .onClick((): void => {
                this.currentTab = idx;
              })
            }, (item: TabItem, idx: number): string => `${item.label}-${this.currentTab === idx ? 1 : 0}`)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          // ---- 玻璃面 ----
          // 定稿效果 = 截图里那张「彩色磨砂玻璃」：backdropBlur 采样 + 低 alpha 填充。
          //
          // 试错史（四个方向都被否，别再走回头路）：
          // ① backgroundBlurStyle(COMPONENT_THIN) → 系统材质自带近白底，List 页糊成白板、Grid 页全透明。
          // ② 只删材质留 backdropBlur(20) + 低 alpha → ✅ 就是这个效果（用户最终确认要的）。
          // ③ 删 backdropBlur 只留低 alpha → 海报/文字清晰穿过底栏，和图标打架。
          // ④ 高 alpha（91%~97%）→ 浅色实板，海报被冲成一片白，玻璃感消失。
          //
          // 注意：底衬 barBaseColor 的 alpha 必须压得很低，否则会把 blur 结果整体提亮成白板。
          .backgroundColor(this.barBaseColor())
          .backdropBlur(20)
          .linearGradient({
            angle: 180,
            colors: this.barGlassColors()
          })
          .border({ width: 0.6, color: this.barRimColor() })
          .borderRadius(Metrics.bottomBarRadius)
          .shadow({
            // 和卡片同一套柔影语言：半径大、alpha 低、下移多，摊成一片淡蓝灰雾，不贴黑边
            radius: 26,
            color: this.theme.colors.isDark ? 'rgba(0,0,0,0.42)' : 'rgba(59,76,112,0.16)',
            offsetX: 0,
            offsetY: 12,
            fill: true   // 跟随胶囊圆角，否则下方露出方形阴影
          })
          .padding({ left: 6, right: 6, top: 7, bottom: 7 })
        }
        .width('calc(100% - 32vp)')
        .margin({ left: 16, right: 16 })
        // 整屏铺到物理底边，胶囊只让开小白条：底边不再露出一条空白
        .padding({ bottom: this.barBottomVp() })
        .alignItems(HorizontalAlign.Center)
        // 投送面板打开时整条胶囊让位（隐藏期间不占位、不吃点击）
        .visibility(this.castSheetOpen ? Visibility.None : Visibility.Visible)

        // 迷你播放条（正在播放时常驻，位于底栏上方）；投送面板打开时一并让位
        if (this.playback.current !== null && !this.castSheetOpen) {
          Column() {
            MiniPlayerBar({ playback: this.playback })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          // 76 = 迷你条自身高度 + 与胶囊之间的呼吸空隙，再补上胶囊抬高量
          .margin({ bottom: 76 + this.barBottomVp() })
        }
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.Bottom)
      .backgroundColor(this.theme.colors.background)
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.PagesMap)
    // 沉浸式避让：顶部留出状态栏，**底部不再留**（v1.0.12 改全屏铺满）。
    // 以前底部留 bottomSafeVp，导致底栏坐在安全区上沿、圆角被切、下面露一条空白，
    // 看着像 App 没铺满屏。现在由各页面自己的底部元素用 sysBottomSafeVp 让开小白条。
    // 全屏播放页（nowPlaying）激活时顶部也归零——该页深色背景自行铺满系统栏区域。
    .padding(this.nowPlayingActive ? { top: 0 } : { top: this.topSafeVp })
    .backgroundColor(this.theme.colors.background)
    .width('100%')
    .height('100%')

      // 全局 Toast 浮层（最上层，任何二级页都能看见；透明不挡点击）
      Column() {
        ToastHost()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ bottom: this.toastBottomVp() })
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.colors.background)
  }

  /** Toast 距屏幕底：跟原来在 Navigation 内缩区里视觉位置一致（补回小白条高度） */
  private toastBottomVp(): number {
    const base: number = this.playback.current !== null ? 140 : Metrics.bottomReserve;
    return base + this.bottomSafeVp;
  }
}
