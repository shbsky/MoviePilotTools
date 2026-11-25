import { AppTheme, Palette, Metrics, withAlpha } from '../../common/Theme';
import { AppSettings } from '../../model/Settings';
import { parseEndpoints, summarizeEndpoints } from '../../model/Models';
import { AppViewModel, AppState } from '../../vm/AppViewModel';
import { MpViewModel } from '../../vm/MpViewModel';
import { MpServer } from '../../model/MpModels';
import { get, TimeoutTier, Reply } from '../../net/HttpClient';
import { STORE_THEME_MODE, STORE_FONT_SCALE, REFRESH_OPTIONS, logInfo, logError } from '../../common/AppConstants';
import { BackStack } from '../../common/BackStack';
import { MusicViewModel } from '../../vm/MusicViewModel';
import { ToastHub } from '../../vm/StoreBase';
import { SongloftClient, SongloftSession } from '../../net/SongloftClient';
import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BackupManager } from '../../data/BackupManager';
import { ConfigStore } from '../../data/ConfigStore';
import { checkUpdate as checkMpUpdate, UpdateInfo } from '../../net/UpdateChecker';
import { download as downloadHap, install as installHap, HapProgress } from '../../net/HapUpdater';
import { BasicField, BasicFieldMulti, FieldLabel, DividerLine, DialogHost, OptionRow, ElevatedCard } from '../components/Common';

/**
 * 设置页（对应安卓 ui/settings/SettingsScreen.kt）：
 * 状态卡、资源管理组、外观、仪表盘定制、关于弹窗、音乐服务配置弹窗。
 * MP 服务器行在 T04 接入 MpViewModel 后显示真实数量。
 */

const APP_VERSION: string = '1.0.1';
/** 项目仓库（关于页「项目地址」+ 更新检查） */
const REPO_URL: string = 'https://github.com/shbsky/MoviePilotTools';
const REPO_DISPLAY: string = 'github.com/shbsky/MoviePilotTools';
const RELEASES_URL: string = 'https://github.com/shbsky/MoviePilotTools/releases';

class ProbeCheck {
  display: string = '';
  ok: boolean = false;

  constructor(display: string, ok: boolean) {
    this.display = display;
    this.ok = ok;
  }
}

function compareVersion(a: string, b: string): number {
  const clean = (s: string): string => s.trim().replace(/^v/i, '').split('-')[0];
  const pa: string[] = clean(a).split('.');
  const pb: string[] = clean(b).split('.');
  const n: number = Math.max(pa.length, pb.length);
  for (let i = 0; i < n; i++) {
    const va: number = i < pa.length ? parseInt(pa[i]) : 0;
    const vb: number = i < pb.length ? parseInt(pb[i]) : 0;
    const na: number = isNaN(va) ? 0 : va;
    const nb: number = isNaN(vb) ? 0 : vb;
    if (na !== nb) {
      return na - nb;
    }
  }
  return 0;
}

/** 逐个探测地址（只探 TCP/HTTP 可达，不校验账号） */
async function probeAddresses(text: string, path: string): Promise<ProbeCheck[]> {
  const out: ProbeCheck[] = [];
  for (const endpoint of parseEndpoints(text)) {
    let ok: boolean = false;
    try {
      const res: Reply = await get(endpoint.url(path), {}, TimeoutTier.PROBE);
      ok = res.code >= 200 && res.code < 500;
    } catch (err) {
      ok = false;
    }
    const display: string = endpoint.display();
    const proto: number = display.indexOf('://');
    out.push(new ProbeCheck(proto >= 0 ? display.substring(proto + 3) : display, ok));
  }
  return out;
}

/** AppSettings 值拷贝（ArkTS 无 data class copy） */
export function appSettingsCopy(s: AppSettings): AppSettings {
  const n: AppSettings = new AppSettings();
  n.refreshSeconds = s.refreshSeconds;
  n.rssRefreshMinutes = s.rssRefreshMinutes;
  n.theme = s.theme;
  n.fontScale = s.fontScale;
  n.dashboardOrder = s.dashboardOrder.slice(0);
  n.hiddenModules = s.hiddenModules.slice(0);
  n.hideTracker = s.hideTracker;
  n.moviePilotRefreshMinutes = s.moviePilotRefreshMinutes;
  n.showModuleTraffic = s.showModuleTraffic;
  n.showModuleAssets = s.showModuleAssets;
  n.showModuleServers = s.showModuleServers;
  n.rssBackground = s.rssBackground;
  n.rssWifiOnly = s.rssWifiOnly;
  n.rssChargingOnly = s.rssChargingOnly;
  n.rssNotify = s.rssNotify;
  n.mpDefaultDownloader = s.mpDefaultDownloader;
  n.mpDefaultSavePath = s.mpDefaultSavePath;
  n.showModuleMedia = s.showModuleMedia;
  n.musicUrl = s.musicUrl;
  n.musicUser = s.musicUser;
  n.musicPass = s.musicPass;
  n.mpSiteFilter = s.mpSiteFilter.slice(0);
  return n;
}

@Component
export struct SettingsPage {
  @Consume('oiiTheme') theme: AppTheme;
  @Consume('navStack') navStack: NavPathStack;
  private vm: AppViewModel = AppViewModel.getInstance();
  private mpvm: MpViewModel = MpViewModel.getInstance();
  @State state: AppState = new AppState();
  /** MoviePilot 已配置的服务器数（独立订阅，行上显示真实状态而不是写死「未配置」） */
  @State mpCount: number = 0;
  /**
   * MoviePilot 在线台数。状态卡上的「已连接 x/y 台服务器」统计的是 MoviePilot，
   * 不是下载器 —— 下载器有自己的行。−1 表示正在探测，UI 先只显示总数。
   */
  @State mpOnline: number = -1;
  @State dialog: string = '';
  // 本地备份 / 恢复
  @State backupPassword: string = '';
  @State restorePassword: string = '';
  @State backupMessage: string = '';
  @State pendingRestoreText: string = '';
  @State pendingRestoreName: string = '';
  /** 底部悬浮栏避让（Index 统一广播） */
  @StorageLink('bottomInsetVp') bottomInset: number = 72;
  /** 音乐页「去设置」：Index 切到本 Tab 后，这里自动弹出音乐服务弹窗 */
  @StorageLink('openMusicSettings') @Watch('onOpenMusicSettings') openMusicSettings: boolean = false;
  // 音乐服务草稿
  @State musicUrlDraft: string = '';
  @State musicUserDraft: string = '';
  @State musicPassDraft: string = '';
  @State checking: boolean = false;
  @State checks: ProbeCheck[] = [];
  @State musicMessage: string = '';
  @State musicMessageOk: boolean = false;
  /** 删除音乐服务器要连点两次：第一次只上膛，第二次才真删（配置清空不可撤销） */
  @State musicDeleteArmed: boolean = false;
  // 关于 · 版本与更新
  @State appVersion: string = APP_VERSION;
  @State updateChecking: boolean = false;
  @State updateState: string = '';
  @State updateHasNew: boolean = false;
  @State updateUrl: string = RELEASES_URL;
  // 应用内下载安装（仅当 Release 含鸿蒙 hap 资产时可用）
  @State updateDownloading: boolean = false;
  @State updateProgress: string = '';
  @State updateHapUrl: string = '';
  @State updateHapName: string = '';
  /** 新版本是否带鸿蒙 hap（决定点按是应用内下载还是跳网页） */
  @State updateHapAvailable: boolean = false;

  private listener: () => void = (): void => {
    this.state = this.vm.state;
  };

  /** 上一次探测过的服务器集合：同一批服务器不重复打网络 */
  private probedKey: string = '';

  private mpListener: () => void = (): void => {
    const servers: MpServer[] = this.mpvm.state.servers;
    this.mpCount = servers.length;
    if (servers.length === 0) {
      this.mpOnline = 0;
      return;
    }
    let key: string = '';
    for (const s of servers) {
      key = `${key}${s.id},`;
    }
    if (key !== this.probedKey) {
      this.probedKey = key;
      this.checkMpOnline(servers);
    }
  };

  /** 逐台探一次 MoviePilot，用于状态卡的「已连接 x/y」 */
  private async checkMpOnline(servers: MpServer[]): Promise<void> {
    this.mpOnline = -1;
    let ok: number = 0;
    for (const srv of servers) {
      try {
        await this.mpvm.testServer(srv);
        ok++;
      } catch (err) {
        // 连不上不计入在线数，不打扰用户
      }
    }
    this.mpOnline = ok;
  }

  aboutToAppear(): void {
    this.vm.subscribe(this.listener);
    this.state = this.vm.state;
    this.mpvm.subscribe(this.mpListener);
    this.probedKey = '';
    this.mpListener();
    this.loadVersion();
    BackStack.get().push('settings', 4, (): boolean => this.handleBack());
    // 音乐页「去设置」时本 Tab 可能刚实例化，@Watch 不会补触发 → 这里兜底检查一次
    this.onOpenMusicSettings();
  }

  aboutToDisappear(): void {
    this.vm.unsubscribe(this.listener);
    this.mpvm.unsubscribe(this.mpListener);
    BackStack.get().remove('settings');
  }

  /** 返回键先关弹窗，没有弹窗才交给外层 */
  private handleBack(): boolean {
    if (this.dialog.length > 0) {
      this.dialog = '';
      return true;
    }
    return false;
  }

  /** 版本号取真实安装信息（AppScope/app.json5 里的 versionName），拿不到才用兜底常量 */
  private loadVersion(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName !== undefined && info.versionName.length > 0) {
        this.appVersion = info.versionName;
      }
    } catch (err) {
      // 取不到就用常量
    }
  }

  /** 用系统能力打开外部链接（GitHub 仓库 / Releases） */
  private openUrl(url: string): void {
    try {
      const ctx: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.openLink(url).catch((err: BusinessError): void => {
        ToastHub.getInstance().show(`打不开链接：${err.message}`);
      });
    } catch (err) {
      ToastHub.getInstance().show('打不开链接');
    }
  }

  /** 选备份文件并读入内存，接着弹密码框 */
  private async pickRestoreFile(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pickerInstance = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = [`.${BackupManager.FILE_EXTENSION}`];
      const uris: string[] = await pickerInstance.select(options);
      if (uris.length === 0) {
        return;
      }
      const file = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(file.fd);
        const buf: ArrayBuffer = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buf);
        this.pendingRestoreText = this.decodeUtf8(new Uint8Array(buf));
        this.pendingRestoreName = uris[0].split('/').pop() ?? '备份文件';
        this.restorePassword = '';
        this.dialog = 'restore';
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      const e = err as BusinessError;
      this.backupMessage = `读取备份失败：${e.message ?? '未知错误'}`;
    }
  }

  /** 把配置写成备份文件（系统文件选择器让用户选保存位置） */
  private async doBackup(): Promise<void> {
    const password = this.backupPassword;
    this.dialog = '';
    try {
      const store = ConfigStore.getInstance();
      const text = BackupManager.wrap(store.toJson(store.load()), password);
      const ctx: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pickerInstance = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSaveOptions();
      const d = new Date();
      const stamp = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}-${String(d.getHours()).padStart(2, '0')}${String(d.getMinutes()).padStart(2, '0')}`;
      options.newFileNames = [`MoviePilotTools-backup-${stamp}.${BackupManager.FILE_EXTENSION}`];
      options.fileSuffixChoices = [`备份文件|.${BackupManager.FILE_EXTENSION}`];
      const uris: string[] = await pickerInstance.save(options);
      if (uris.length === 0) {
        return;
      }
      const file = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
      } finally {
        fs.closeSync(file);
      }
      this.backupMessage = '备份完成，文件已保存';
    } catch (err) {
      const e = err as BusinessError;
      this.backupMessage = `备份失败：${e.message ?? '未知错误'}`;
    }
  }

  /** 执行恢复：解密 → 写盘 → 通知两个 VM 重载 */
  private doRestore(): void {
    try {
      const plain = BackupManager.unwrap(this.pendingRestoreText, this.restorePassword);
      const store = ConfigStore.getInstance();
      if (!store.restoreFromJson(plain)) {
        this.backupMessage = '恢复失败：备份内容格式不正确';
        this.dialog = '';
        return;
      }
      this.vm.reloadFromStore();
      this.mpvm.bootstrap();
      // 音乐配置也在整包里，恢复后必须通知音乐 VM，否则音乐页仍用旧地址/账号
      const restoredSettings: AppSettings = store.load().settings;
      MusicViewModel.getInstance().configure(
        restoredSettings.musicUrl, restoredSettings.musicUser, restoredSettings.musicPass
      );
      this.pendingRestoreText = '';
      this.restorePassword = '';
      this.dialog = '';
      this.backupMessage = '恢复成功，配置已更新';
    } catch (err) {
      const e = err as Error;
      this.backupMessage = e.message ?? '恢复失败';
      this.dialog = '';
    }
  }

  private decodeUtf8(bytes: Uint8Array): string {
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeWithStream(bytes);
  }

  /** 检查 GitHub 最新 Release；鸿蒙只认带 hap 资产的版本，按钮变成「下载更新」 */
  private checkUpdate(): void {
    if (this.updateChecking || this.updateDownloading) {
      return;
    }
    this.updateChecking = true;
    this.updateHasNew = false;
    this.updateHapAvailable = false;
    this.updateState = '检查中…';
    checkMpUpdate(this.appVersion).then((info: UpdateInfo): void => {
      this.updateChecking = false;
      this.updateUrl = info.page.length > 0 ? info.page : RELEASES_URL;
      if (!info.hasUpdate) {
        this.updateState = `已是最新（${info.tag}）`;
        return;
      }
      this.updateHasNew = true;
      if (info.hasHap) {
        // Release 带鸿蒙包：应用内下载 → 拉起系统安装
        this.updateHapAvailable = true;
        this.updateHapUrl = info.hapUrl;
        this.updateHapName = info.hapName;
        this.updateState = `有新版本 ${info.tag}（点此更新）`;
      } else {
        // 只有安卓 apk：不把 apk 当鸿蒙更新，只能开网页说明
        this.updateState = `有新版本 ${info.tag}（暂无鸿蒙包）`;
      }
    }).catch((e: Error): void => {
      this.updateChecking = false;
      this.updateState = `检查失败：${e.message}`;
      logInfo('Settings', `checkUpdate: ${e.message}`);
    });
  }

  /**
   * 应用内下载并安装：下载 hap 到沙箱 → 交给系统拉起安装界面。
   * 拉不起来（系统没有能打开 hap 的应用）时降级到浏览器打开 Release 页。
   */
  private startUpdate(): void {
    if (this.updateHapUrl.length === 0 || this.updateDownloading) {
      return;
    }
    this.updateDownloading = true;
    this.updateProgress = '准备下载…';
    this.updateState = '下载中…';
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    downloadHap(ctx, this.updateHapUrl, this.updateHapName, (p: HapProgress): void => {
      if (p.fraction >= 0) {
        this.updateProgress = `下载中 ${Math.round(p.fraction * 100)}%`;
      } else {
        this.updateProgress = `下载中 ${(p.downloaded / 1024 / 1024).toFixed(1)} MB`;
      }
    }).then(async (path: string): Promise<void> => {
      this.updateProgress = '准备安装…';
      this.updateState = '准备安装…';
      const launched: boolean = await installHap(ctx, path);
      this.updateDownloading = false;
      if (launched) {
        this.updateState = '请在系统弹窗点「安装」';
        ToastHub.getInstance().show('请在系统弹窗中确认安装');
      } else {
        // 系统拉不起安装界面：降级到浏览器，让用户手动下载安装
        this.updateState = '无法自动安装，已打开下载页';
        this.openUrl(this.updateUrl);
      }
    }).catch((e: Error): void => {
      this.updateDownloading = false;
      this.updateState = `下载失败：${e.message}`;
      ToastHub.getInstance().show(`下载失败：${e.message}`);
      logInfo('Settings', `startUpdate: ${e.message}`);
    });
  }

  private updateSettings(next: AppSettings): void {
    this.vm.updateSettings(next);
    AppStorage.setOrCreate(STORE_THEME_MODE, next.theme);
    AppStorage.setOrCreate(STORE_FONT_SCALE, next.fontScale);
  }

  private themeLabel(): string {
    const t: string = this.state.settings.theme;
    if (t === 'light') {
      return '浅色';
    }
    if (t === 'dark') {
      return '深色';
    }
    return '跟随系统';
  }

  private musicValue(): string {
    const u: string = this.state.settings.musicUrl;
    if (u.trim().length === 0) {
      return '未接入 Songloft';
    }
    return summarizeEndpoints(u);
  }

  /** 音乐页「去设置」信号 → 弹出音乐服务弹窗并清掉信号，避免下次进设置又弹 */
  onOpenMusicSettings(): void {
    if (this.openMusicSettings) {
      this.openMusicDialog();
      AppStorage.setOrCreate('openMusicSettings', false);
    }
  }

  private openMusicDialog(): void {
    this.musicUrlDraft = this.state.settings.musicUrl;
    this.musicUserDraft = this.state.settings.musicUser;
    this.musicPassDraft = this.state.settings.musicPass;
    this.checks = [];
    this.musicMessage = '';
    this.dialog = 'music';
  }

  private parsedAddressCount(): number {
    return parseEndpoints(this.musicUrlDraft).length;
  }

  private checkAddresses(): void {
    this.checking = true;
    this.checks = [];
    probeAddresses(this.musicUrlDraft, '/api/v1/songs?limit=1').then((list: ProbeCheck[]): void => {
      this.checking = false;
      this.checks = list;
    }).catch((err: Error): void => {
      this.checking = false;
      logInfo('Settings', `地址检测失败: ${err.message}`);
    });
  }

  /** T05 接入 SongloftClient 后补真正登录测试；当前先做地址可达性检测 */
  private testMusic(): void {
    this.musicMessageOk = false;
    this.musicMessage = '正在登录…';
    this.checkAddresses();
    probeAddresses(this.musicUrlDraft, '/api/v1/songs?limit=1').then((list: ProbeCheck[]): void => {
      let anyOk: boolean = false;
      for (const c of list) {
        if (c.ok) {
          anyOk = true;
          break;
        }
      }
      if (!anyOk) {
        this.musicMessage = '没有可用地址：请检查地址是否填对、服务是否启动';
      } else {
        this.musicMessage = '地址可达。保存后音乐页会自动登录。';
        this.musicMessageOk = true;
      }
    }).catch((err: Error): void => {
      this.musicMessage = err.message.length > 0 ? err.message : '连接失败';
    });
  }

  private saveMusic(): void {
    const next: AppSettings = appSettingsCopy(this.state.settings);
    next.musicUrl = this.musicUrlDraft.trim();
    next.musicUser = this.musicUserDraft;
    next.musicPass = this.musicPassDraft;
    this.updateSettings(next);
    this.dialog = '';
    this.musicDeleteArmed = false;
    // 立即按新配置接入（同配置内部会跳过），并做一次登录测试
    const mvm: MusicViewModel = MusicViewModel.getInstance();
    mvm.configure(next.musicUrl, next.musicUser, next.musicPass);
    if (next.musicUrl.trim().length > 0 && next.musicUser.trim().length > 0) {
      const tester: SongloftClient =
        new SongloftClient(next.musicUrl, next.musicUser, next.musicPass);
      tester.test().then((msg: string): void => {
        ToastHub.getInstance().show(msg);
      }).catch((e: Error): void => {
        ToastHub.getInstance().show(e.message.length > 0 ? e.message : '音乐服务测试失败');
      });
    }
  }

  /**
   * 删除已保存的音乐服务器：清空地址 / 账号 / 密码，并把音乐页回落成「未接入」。
   * 用户反馈：填完想换一个服务器，弹窗里只有「保存」，没有删除入口。
   */
  private deleteMusic(): void {
    const next: AppSettings = appSettingsCopy(this.state.settings);
    next.musicUrl = '';
    next.musicUser = '';
    next.musicPass = '';
    this.updateSettings(next);
    this.musicUrlDraft = '';
    this.musicUserDraft = '';
    this.musicPassDraft = '';
    this.checks = [];
    this.musicMessage = '';
    this.musicMessageOk = false;
    this.musicDeleteArmed = false;
    this.dialog = '';
    MusicViewModel.getInstance().configure('', '', '');
    ToastHub.getInstance().show('已删除音乐服务器');
  }

  build() {
    Stack() {
      Scroll() {
        Column() {
          Blank().height(14)
          Text('设置')
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.colors.textPrimary)
            .width('100%')
          Blank().height(16)

          // ---- 状态卡（从平铺实色改成和仪表盘同一套玻璃悬浮卡）----
          ElevatedCard({ paddingVp: 14, radiusVp: 18 }) {
          Row() {
            Stack() {
              Circle().width(34).height(34).fill(withAlpha(Palette.green, 0x24))
              Text('🖧').fontSize(17).fontColor(Palette.green)
            }
            .width(34)
            .height(34)
            Blank().width(11)
            Column() {
              Text('MoviePilotTools')
                .fontSize(this.theme.fs(15))
                .fontWeight(FontWeight.Medium)
                .fontColor(this.theme.colors.textPrimary)
              Text(this.mpCount === 0
                ? '尚未配置服务器'
                : (this.mpOnline < 0
                  ? `${this.mpCount} 台服务器`
                  : `已连接 ${this.mpOnline}/${this.mpCount} 台服务器`))
                .fontSize(this.theme.fs(12))
                .fontColor(this.theme.colors.textSecondary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text('运行中')
              .fontSize(10)
              .fontColor(Palette.green)
              .borderRadius(8)
              .backgroundColor(withAlpha(Palette.green, 0x1F))
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            this.dialog = 'about';
          })
          }

          Blank().height(20)
          this.GroupLabel('资源管理')
          // 分组改成玻璃悬浮卡（外层承影 + 内层渐变），与仪表盘同一套语言
          ElevatedCard({ paddingVp: 0, radiusVp: 18 }) {
          Column() {
            SettingsRowItem({
              icon: '🖧', tint: Palette.purple, title: '下载器设置',
              value: `${this.state.servers.length} 台`,
              onTap: (): void => {
                this.navStack.pushPathByName('serverList', '');
              }
            })
            DividerLine()
            SettingsRowItem({
              icon: '🎬', tint: Palette.blue, title: 'MoviePilot',
              value: this.mpCount > 0 ? `${this.mpCount} 台` : '未配置',
              onTap: (): void => {
                this.navStack.pushPathByName('mpServerList', '');
              }
            })
            DividerLine()
            SettingsRowItem({
              icon: '🎵', tint: Palette.pink, title: '音乐服务（Songloft）',
              value: this.musicValue(),
              onTap: (): void => {
                this.openMusicDialog();
              }
            })
            DividerLine()
            SettingsRowItem({
              icon: '⟳', tint: Palette.blue, title: '下载器刷新频率',
              value: `${this.state.settings.refreshSeconds}秒`,
              onTap: (): void => {
                this.dialog = 'refresh';
              }
            })
            DividerLine()
            SettingsRowItem({
              icon: '⬆', tint: Palette.green, title: '本地备份',
              value: '导出全部配置',
              onTap: (): void => {
                this.backupPassword = '';
                this.dialog = 'backup';
              }
            })
            DividerLine()
            SettingsRowItem({
              icon: '⬇', tint: Palette.orange, title: '从备份恢复',
              value: '覆盖当前配置',
              onTap: (): void => {
                this.pickRestoreFile();
              }
            })
          }
          .width('100%')
          }
          Blank().height(20)
          this.GroupLabel('应用设置')
          // 分组改成玻璃悬浮卡（外层承影 + 内层渐变），与仪表盘同一套语言
          ElevatedCard({ paddingVp: 0, radiusVp: 18 }) {
          Column() {
            SettingsRowItem({
              icon: '🎨', tint: Palette.indigo, title: '外观主题',
              value: this.themeLabel(),
              onTap: (): void => {
                this.dialog = 'theme';
              }
            })
            DividerLine()
            SettingsRowItem({
              icon: '🔤', tint: Palette.blue, title: '字体大小',
              value: `${Math.round(this.state.settings.fontScale * 100)}%`,
              onTap: (): void => {
                this.dialog = 'font';
              }
            })
          }
          .width('100%')
          }
          Blank().height(20)
          this.GroupLabel('仪表盘定制')
          // 分组改成玻璃悬浮卡（外层承影 + 内层渐变），与仪表盘同一套语言
          ElevatedCard({ paddingVp: 0, radiusVp: 18 }) {
          Column() {
            ToggleRowItem({
              icon: '📈', tint: Palette.blue, title: '流量监控',
              checked: this.state.settings.showModuleTraffic,
              onChange: (v: boolean): void => {
                const next: AppSettings = appSettingsCopy(this.state.settings);
                next.showModuleTraffic = v;
                this.updateSettings(next);
              }
            })
            DividerLine()
            ToggleRowItem({
              icon: '🎬', tint: Palette.purple, title: '媒体库',
              checked: this.state.settings.showModuleMedia,
              onChange: (v: boolean): void => {
                const next: AppSettings = appSettingsCopy(this.state.settings);
                next.showModuleMedia = v;
                this.updateSettings(next);
              }
            })
            DividerLine()
            ToggleRowItem({
              icon: '🧮', tint: Palette.orange, title: '数据聚合',
              checked: this.state.settings.showModuleAssets,
              onChange: (v: boolean): void => {
                const next: AppSettings = appSettingsCopy(this.state.settings);
                next.showModuleAssets = v;
                this.updateSettings(next);
              }
            })
            DividerLine()
            ToggleRowItem({
              icon: '🖧', tint: Palette.green, title: '服务器状态',
              checked: this.state.settings.showModuleServers,
              onChange: (v: boolean): void => {
                const next: AppSettings = appSettingsCopy(this.state.settings);
                next.showModuleServers = v;
                this.updateSettings(next);
              }
            })
          }
          .width('100%')
          }
          Blank().height(20)
          this.GroupLabel('关于')
          // 分组改成玻璃悬浮卡（外层承影 + 内层渐变），与仪表盘同一套语言
          ElevatedCard({ paddingVp: 0, radiusVp: 18 }) {
          Column() {
            Row() {
              Text('版本')
                .fontSize(this.theme.fs(15))
                .fontColor(this.theme.colors.textPrimary)
                .layoutWeight(1)
              Text(this.appVersion)
                .fontSize(this.theme.fs(13))
                .fontColor(this.theme.colors.textSecondary)
            }
            .width('100%')
            .padding(14)
            .alignItems(VerticalAlign.Center)
            DividerLine()
            // 应用更新：点一下查 GitHub 最新 Release；查到新版再点直接开下载页
            Row() {
              Text('应用更新')
                .fontSize(this.theme.fs(15))
                .fontColor(this.theme.colors.textPrimary)
                .layoutWeight(1)
              if (this.updateChecking || this.updateDownloading) {
                LoadingProgress()
                  .width(14)
                  .height(14)
                  .color(Palette.blue)
                Blank().width(6)
              }
              Text(this.updateDownloading ? this.updateProgress
                : (this.updateState.length > 0 ? this.updateState : '检查更新'))
                .fontSize(this.theme.fs(13))
                .fontColor(this.updateHasNew ? Palette.blue : this.theme.colors.textSecondary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 170 })
              Text('›')
                .fontSize(this.theme.fs(14))
                .fontColor(this.theme.colors.textSecondary)
                .padding({ left: 4 })
            }
            .width('100%')
            .padding(14)
            .alignItems(VerticalAlign.Center)
            .onClick((): void => {
              if (this.updateDownloading) {
                return;
              }
              if (this.updateHasNew && this.updateHapAvailable) {
                // 带鸿蒙包：弹窗确认后应用内下载安装
                this.dialog = 'update';
              } else if (this.updateHasNew && this.updateUrl.length > 0) {
                // 只有 apk：开网页说明
                this.openUrl(this.updateUrl);
              } else {
                this.checkUpdate();
              }
            })
            DividerLine()
            Row() {
              Text('项目地址')
                .fontSize(this.theme.fs(15))
                .fontColor(this.theme.colors.textPrimary)
                .layoutWeight(1)
              Text(REPO_DISPLAY)
                .fontSize(this.theme.fs(13))
                .fontColor(this.theme.colors.textSecondary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 190 })
              Text('›')
                .fontSize(this.theme.fs(14))
                .fontColor(this.theme.colors.textSecondary)
                .padding({ left: 4 })
            }
            .width('100%')
            .padding(14)
            .alignItems(VerticalAlign.Center)
            .onClick((): void => {
              this.openUrl(REPO_URL);
            })
            DividerLine()
            // 用户协议：与仓库 TERMS.md 同文，HarmonyOS 提审要求应用内可见免责声明
            Row() {
              Text('用户协议')
                .fontSize(this.theme.fs(15))
                .fontColor(this.theme.colors.textPrimary)
                .layoutWeight(1)
              Text('免责声明')
                .fontSize(this.theme.fs(13))
                .fontColor(this.theme.colors.textSecondary)
              Text('›')
                .fontSize(this.theme.fs(14))
                .fontColor(this.theme.colors.textSecondary)
                .padding({ left: 4 })
            }
            .width('100%')
            .padding(14)
            .alignItems(VerticalAlign.Center)
            .onClick((): void => {
              this.navStack.pushPathByName('terms', '');
            })
          }
          .width('100%')
          }
          // 底部留白分两段：padding bottom(bottomInsetVp) 负责让开胶囊，
          // 这里的 Blank 负责「最后一张卡和胶囊之间留多少呼吸」。
          // 曾收到 6vp，真机上滚到底「用户协议」贴着胶囊太近 → 改 20vp，
          // 比仪表盘（底部占位 bottomInset + 8）略松一点，和安卓的 88dp 观感对齐。
          Blank().height(20)
        }
        .width('100%')
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, bottom: this.bottomInset })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      // ================= 弹窗层 =================

      // 关于（只有一个「关闭」：不传 cancelText，配合 showCancel:false 保证不会出现两个按钮）
      DialogHost({
        visible: this.dialog === 'about',
        title: 'MoviePilotTools',
        confirmText: '关闭',
        cancelText: '',
        showCancel: false,
        onCancel: (): void => {
          this.dialog = '';
        },
        onConfirm: (): void => {
          this.dialog = '';
        }
        }) {
          this.AboutContent()
        }

      // 应用更新确认
      DialogHost({
        visible: this.dialog === 'update',
        title: '应用更新',
        confirmText: '下载安装',
        cancelText: '取消',
        onCancel: (): void => {
          this.dialog = '';
        },
        onConfirm: (): void => {
          this.dialog = '';
          this.startUpdate();
        }
        }) {
          this.UpdateContent()
        }

      // 刷新频率
      DialogHost({
        visible: this.dialog === 'refresh',
        title: '下载器刷新频率',
        confirmText: '关闭',
        showCancel: false,
        onCancel: (): void => {
          this.dialog = '';
        },
        onConfirm: (): void => {
          this.dialog = '';
        }
        }) {
          ForEach(REFRESH_OPTIONS, (sec: number): void => {
            OptionRow({
              label: `${sec} 秒`,
              selected: this.state.settings.refreshSeconds === sec,
              onPick: (): void => {
                const next: AppSettings = appSettingsCopy(this.state.settings);
                next.refreshSeconds = sec;
                this.updateSettings(next);
                this.dialog = '';
              }
            })
          }, (sec: number): string => `r${sec}`)
        }

      // 主题
      DialogHost({
        visible: this.dialog === 'theme',
        title: '外观主题',
        confirmText: '关闭',
        showCancel: false,
        onCancel: (): void => {
          this.dialog = '';
        },
        onConfirm: (): void => {
          this.dialog = '';
        }
        }) {
          ForEach(['system', 'light', 'dark'], (mode: string): void => {
            OptionRow({
              label: mode === 'light' ? '浅色' : (mode === 'dark' ? '深色' : '跟随系统'),
              selected: this.state.settings.theme === mode,
              onPick: (): void => {
                const next: AppSettings = appSettingsCopy(this.state.settings);
                next.theme = mode;
                this.updateSettings(next);
                this.dialog = '';
              }
            })
          }, (mode: string): string => mode)
        }

      // 字体
      DialogHost({
        visible: this.dialog === 'font',
        title: '字体大小',
        confirmText: '关闭',
        showCancel: false,
        onCancel: (): void => {
          this.dialog = '';
        },
        onConfirm: (): void => {
          this.dialog = '';
        }
        }) {
          ForEach([0.9, 1.0, 1.1, 1.2], (scale: number): void => {
            OptionRow({
              label: `${Math.round(scale * 100)}%`,
              selected: Math.abs(this.state.settings.fontScale - scale) < 0.001,
              onPick: (): void => {
                const next: AppSettings = appSettingsCopy(this.state.settings);
                next.fontScale = scale;
                this.updateSettings(next);
                this.dialog = '';
              }
            })
          }, (scale: number): string => `f${scale}`)
        }

      // 音乐服务
      DialogHost({
        visible: this.dialog === 'music',
        title: '音乐服务 (Songloft)',
        confirmText: '保存',
        onCancel: (): void => {
          this.dialog = '';
        },
        onConfirm: (): void => {
          this.saveMusic();
        }
        }) {
          this.MusicContent()
        }

      // 本地备份 · 密码输入
      DialogHost({
        visible: this.dialog === 'backup',
        title: '本地备份',
        confirmText: '导出',
        onCancel: (): void => {
          this.dialog = '';
        },
        onConfirm: (): void => {
          this.doBackup();
        }
        }) {
          Column() {
            Text('设置备份密码以保护下载器地址、账号、API Key 等敏感信息。留空 = 不加密，文件里能直接看到这些配置。密码忘记后无法找回。')
              .fontSize(this.theme.fs(12))
              .fontColor(this.theme.colors.textSecondary)
            Blank().height(10)
            FieldLabel({ text: '备份密码（可留空）' })
            BasicField({
              value: this.backupPassword,
              placeholder: '留空则不加密',
              secret: true,
              onValueChanged: (v: string): void => { this.backupPassword = v; }
            })
          }
          .width('100%')
        }

      // 从备份恢复 · 密码输入
      DialogHost({
        visible: this.dialog === 'restore',
        title: '恢复备份',
        confirmText: '恢复',
        destructive: true,
        onCancel: (): void => {
          this.dialog = '';
          this.pendingRestoreText = '';
        },
        onConfirm: (): void => {
          this.doRestore();
        }
        }) {
          Column() {
            Text(`文件：${this.pendingRestoreName}`)
              .fontSize(this.theme.fs(12))
              .fontColor(this.theme.colors.textSecondary)
            Blank().height(6)
            Text('恢复会覆盖当前全部配置（下载器 / MoviePilot / RSS / 音乐 / 外观）。若备份时设了密码，请输入；没设就留空。')
              .fontSize(this.theme.fs(12))
              .fontColor(this.theme.colors.textSecondary)
            Blank().height(10)
            FieldLabel({ text: '备份密码（可留空）' })
            BasicField({
              value: this.restorePassword,
              placeholder: '留空则不解密',
              secret: true,
              onValueChanged: (v: string): void => { this.restorePassword = v; }
            })
          }
          .width('100%')
        }

      // 备份 / 恢复结果
      DialogHost({
        visible: this.backupMessage.length > 0,
        title: '备份与恢复',
        confirmText: '知道了',
        showCancel: false,
        onCancel: (): void => {
          this.backupMessage = '';
        },
        onConfirm: (): void => {
          this.backupMessage = '';
        }
        }) {
          Text(this.backupMessage)
            .fontSize(this.theme.fs(13))
            .fontColor(this.theme.colors.textPrimary)
        }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.colors.background)
  }

  @Builder
  UpdateContent(): void {
    Column() {
      Text(`发现新版本 ${this.updateState.replace('（点此更新）', '')}`)
        .fontSize(this.theme.fs(14))
        .fontColor(this.theme.colors.textPrimary)
      Blank().height(8)
      Text(`安装包：${this.updateHapName}`)
        .fontSize(this.theme.fs(10))
        .fontColor(this.theme.colors.textSecondary)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  AboutContent(): void {
    Column() {
      Text(`版本 ${this.appVersion}`)
        .fontSize(this.theme.fs(12))
        .fontColor(this.theme.colors.textPrimary)
      Blank().height(4)
      Text('ArkTS · ArkUI · AVPlayer（HarmonyOS NEXT）')
        .fontSize(this.theme.fs(11))
        .fontColor(this.theme.colors.textSecondary)
      Blank().height(14)
      this.AboutRow('下载器',
        `${this.state.onlineCount()}/${this.state.servers.length} 台在线`)
      this.AboutRow('流量统计', '取自下载器累计计数器')
      this.AboutRow('音乐', 'Songloft · 支持 DLNA 投送')
      Blank().height(12)
      Text('数据全部留在本机，只有连你的下载器和服务器时才走网络。')
        .fontSize(this.theme.fs(10))
        .fontColor(this.theme.colors.textSecondary)
        .lineHeight(this.theme.fs(15))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  AboutRow(label: string, value: string): void {
    Row() {
      Text(label)
        .fontSize(this.theme.fs(12))
        .fontColor(this.theme.colors.textSecondary)
        .layoutWeight(1)
      Text(value)
        .fontSize(this.theme.fs(12))
        .fontColor(this.theme.colors.textPrimary)
    }
    .width('100%')
    .padding({ top: 3, bottom: 3 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  MusicContent(): void {
    Column() {
      Text('填 Songloft 的地址和登录账号，音乐标签页就能浏览歌曲、歌单并在手机上播放。地址可以填多行（内网 IP + 公网域名），自动挑能通的。')
        .fontSize(this.theme.fs(11))
        .fontColor(this.theme.colors.textSecondary)
        .lineHeight(this.theme.fs(16))
      Blank().height(12)
      FieldLabel({ text: '服务地址（一行一个，可填多条）' })
      Blank().height(6)
      BasicFieldMulti({
        value: this.musicUrlDraft,
        placeholder: '192.168.1.10:58091\nmusic.example.com',
        onValueChanged: (v: string): void => {
          this.musicUrlDraft = v;
        }
      })
      Blank().height(5)
      Text(this.parsedAddressCount() === 0
        ? '第一行填内网地址，第二行填公网域名（在外面自动走域名）'
        : `已填 ${this.parsedAddressCount()} 个地址，连之前会自动选能通的那个`)
        .fontSize(this.theme.fs(10))
        .fontColor(this.parsedAddressCount() > 1 ? Palette.green : this.theme.colors.textSecondary)
        .lineHeight(this.theme.fs(15))
      Blank().height(12)
      FieldLabel({ text: '登录账号' })
      Blank().height(6)
      BasicField({
        value: this.musicUserDraft,
        placeholder: '账号',
        onValueChanged: (v: string): void => {
          this.musicUserDraft = v.trim();
        }
      })
      Blank().height(12)
      FieldLabel({ text: '登录密码' })
      Blank().height(6)
      BasicField({
        value: this.musicPassDraft,
        placeholder: '密码',
        secret: true,
        onValueChanged: (v: string): void => {
          this.musicPassDraft = v;
        }
      })
      Blank().height(10)
      Row() {
        Text(this.checking ? '检测中…' : '检测地址')
          .fontSize(this.theme.fs(12))
          .fontColor(Palette.blue)
          .borderRadius(8)
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .onClick((): void => {
            if (!this.checking && this.musicUrlDraft.trim().length > 0) {
              this.checkAddresses();
            }
          })
        Blank().width(6)
        Text('地址不写 http:// 也行，默认按 http 走')
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.checks.length > 0) {
        Column() {
          ForEach(this.checks, (c: ProbeCheck): void => {
            Row() {
              Text(c.ok ? '✓' : '✕')
                .fontSize(this.theme.fs(11))
                .fontColor(c.ok ? Palette.green : Palette.red)
              Blank().width(6)
              Text(c.display)
                .fontSize(this.theme.fs(11))
                .fontColor(c.ok ? this.theme.colors.textPrimary : this.theme.colors.textSecondary)
              Blank().width(6)
              Text(c.ok ? '可用' : '连不上')
                .fontSize(this.theme.fs(10))
                .fontColor(c.ok ? Palette.green : this.theme.colors.textSecondary)
            }
            .width('100%')
            .padding({ top: 1, bottom: 1 })
            .alignItems(VerticalAlign.Center)
          }, (c: ProbeCheck): string => `${c.display}-${c.ok ? 1 : 0}`)
        }
        .width('100%')
        .padding({ top: 8 })
        .alignItems(HorizontalAlign.Start)
      }

      if (this.musicMessage.length > 0) {
        Blank().height(8)
        Text(this.musicMessage)
          .fontSize(this.theme.fs(11))
          .fontColor(this.musicMessageOk ? Palette.green : Palette.red)
          .lineHeight(this.theme.fs(16))
      }

      // 删除入口只在「已经配了服务器」时出现，没配的时候不摆一个灰按钮占位
      if (this.state.settings.musicUrl.trim().length > 0) {
        Blank().height(14)
        Divider()
          .strokeWidth(0.5)
          .color(this.theme.colors.separator)
        Blank().height(4)
        Text(this.musicDeleteArmed ? '再点一次确认删除' : '删除服务器')
          .fontSize(this.theme.fs(12))
          .fontColor(Palette.red)
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .borderRadius(8)
          .onClick((): void => {
            if (this.musicDeleteArmed) {
              this.deleteMusic();
            } else {
              this.musicDeleteArmed = true;
            }
          })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  GroupLabel(text: string): void {
    Text(text)
      .fontSize(this.theme.fs(12))
      .fontColor(this.theme.colors.textSecondary)
      .width('100%')
      .padding({ left: 4, bottom: 8 })
  }
}

/**
 * 设置行（独立 @Component）：
 * 之前是 @Builder 按值传参——按值参数不随状态刷新，出现「已连接 2/2 但下面写 0 台」的冻结；
 * @Component + @Prop 由父组件同步，状态变化后行值会跟着更新。
 */
@Component
struct SettingsRowItem {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop icon: string = '';
  @Prop tint: number = 0;
  @Prop title: string = '';
  @Prop value: string = '';
  onTap: () => void = (): void => {
  };

  build() {
    Row() {
      Text(this.icon)
        .fontSize(13)
        .width(24)
        .height(24)
        .textAlign(TextAlign.Center)
        .borderRadius(6)
        .backgroundColor(withAlpha(this.tint, 0x24))
      Blank().width(10)
      Text(this.title)
        .fontSize(this.theme.fs(15))
        .fontColor(this.theme.colors.textPrimary)
        .layoutWeight(1)
      Text(this.value)
        .fontSize(this.theme.fs(13))
        .fontColor(this.theme.colors.textSecondary)
      Blank().width(4)
      Text('›')
        .fontSize(15)
        .fontColor(this.theme.colors.textSecondary)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.onTap();
    })
  }
}

@Component
struct ToggleRowItem {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop icon: string = '';
  @Prop tint: number = 0;
  @Prop title: string = '';
  @Prop checked: boolean = false;
  onChange: (v: boolean) => void = (v: boolean): void => {
  };

  build() {
    Row() {
      Text(this.icon)
        .fontSize(13)
        .width(24)
        .height(24)
        .textAlign(TextAlign.Center)
        .borderRadius(6)
        .backgroundColor(withAlpha(this.tint, 0x24))
      Blank().width(10)
      Text(this.title)
        .fontSize(this.theme.fs(15))
        .fontColor(this.theme.colors.textPrimary)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.checked })
        .selectedColor(this.theme.colors.accent)
        .onChange((v: boolean): void => {
          this.onChange(v);
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }
}
