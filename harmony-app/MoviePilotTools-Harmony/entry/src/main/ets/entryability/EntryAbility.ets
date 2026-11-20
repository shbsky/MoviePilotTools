import { AbilityConstant, UIAbility, Want, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Configuration } from '@ohos.app.ability.Configuration';
import EnvironmentCallback from '@ohos.app.ability.EnvironmentCallback';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppEnv, STORE_THEME_MODE, STORE_FONT_SCALE, STORE_SYSTEM_DARK, attachDebugLog, logInfo, logWarn
} from '../common/AppConstants';
import { AppViewModel } from '../vm/AppViewModel';
import { MpViewModel } from '../vm/MpViewModel';
import { BackgroundAudioManager } from '../player/BackgroundAudioManager';

/**
 * 入口 Ability（对应安卓 MainActivity.kt + OiiQTApplication.kt）：
 * - onCreate：attach 上下文、初始化 AppStorage 默认值、注册系统环境回调（深浅色跟随）；
 * - onWindowStageCreate：加载 Index；开启沉浸式全屏（状态栏/导航条透明，页面延伸到屏幕边缘）；
 * - onConfigurationUpdate：系统深浅色 / 字体等变化时回写 AppStorage，页面据此重绘；
 * - onForeground / onBackground：恢复/暂停下载器轮询（音乐/投送保活在 player 层）。
 */
export default class EntryAbility extends UIAbility {
  /** ApplicationContext.on('environment') 的注册 id，销毁时注销 */
  private envCallbackId: number = -1;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppEnv.attach(this.context);
    attachDebugLog(this.context.filesDir);
    if (AppStorage.get(STORE_THEME_MODE) === undefined) {
      AppStorage.setOrCreate(STORE_THEME_MODE, 'system');
    }
    if (AppStorage.get(STORE_FONT_SCALE) === undefined) {
      AppStorage.setOrCreate(STORE_FONT_SCALE, 1.0);
    }
    // 系统主题初值：必须在这里落一次，否则页面首次渲染前 @StorageLink 拿不到真实值
    AppStorage.setOrCreate(STORE_SYSTEM_DARK, this.configIsDark(this.context.config));
    this.registerEnvironment();
    logInfo('EntryAbility', '应用创建');
  }

  /**
   * 系统环境回调：系统切换深/浅色、改字体、改语言都会走到这里。
   * 只写 AppStorage，重绘交给 Index 的 @StorageLink（避免在 Ability 里直接操作 UI）。
   */
  private registerEnvironment(): void {
    try {
      const appCtx: common.ApplicationContext = this.context.getApplicationContext();
      const callback: EnvironmentCallback = {
        onConfigurationUpdated: (config: Configuration): void => {
          this.syncSystemDark(config);
        },
        onMemoryLevel: (level: AbilityConstant.MemoryLevel): void => {
          // 内存等级变化与主题无关，忽略
        }
      };
      this.envCallbackId = appCtx.on('environment', callback);
      logInfo('EntryAbility', `环境回调已注册 id=${this.envCallbackId}`);
    } catch (err) {
      logWarn('EntryAbility', `环境回调注册失败: ${err}`);
    }
  }

  /** 系统配置变化（切回前台时系统也可能补发一次） */
  onConfigurationUpdate(newConfig: Configuration): void {
    this.syncSystemDark(newConfig);
  }

  private syncSystemDark(config: Configuration | undefined): void {
    const dark: boolean = this.configIsDark(config);
    const prev: boolean | undefined = AppStorage.get<boolean>(STORE_SYSTEM_DARK);
    AppStorage.setOrCreate(STORE_SYSTEM_DARK, dark);
    if (prev !== dark) {
      logInfo('EntryAbility', `系统深浅色变更 -> ${dark ? '深色' : '浅色'}`);
    }
  }

  private configIsDark(config: Configuration | undefined): boolean {
    if (config === undefined || config.colorMode === undefined) {
      return false;
    }
    return config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err): void => {
      if (err.code !== 0) {
        logWarn('EntryAbility', `加载首页失败: ${err.code}`);
        return;
      }
      // 沉浸式：布局延伸到系统栏之下，系统栏本身透明（API 签名已对 SDK d.ts 核对）
      windowStage.getMainWindow().then((win: window.Window): Promise<void> => {
        return win.setWindowLayoutFullScreen(true).then((): Promise<void> => {
          return win.setWindowSystemBarProperties({
            statusBarColor: '#00000000',
            navigationBarColor: '#00000000',
            statusBarContentColor: this.startupIsDark() ? '#FFFFFF' : '#000000',
            navigationBarContentColor: this.startupIsDark() ? '#FFFFFF' : '#000000'
          });
        });
      }).catch((err: BusinessError): void => {
        logWarn('EntryAbility', `沉浸式设置失败: ${err.code} ${err.message}`);
      });
    });
  }

  /** 启动时的深浅色判断：优先用户主题设置，跟随系统时读 Ability config */
  private startupIsDark(): boolean {
    const mode: string = AppStorage.get<string>(STORE_THEME_MODE) ?? 'system';
    if (mode === 'dark') {
      return true;
    }
    if (mode === 'light') {
      return false;
    }
    try {
      const cfg = this.context.config;
      if (cfg !== undefined && cfg.colorMode !== undefined) {
        return cfg.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      }
    } catch (err) {
      // 忽略，回退浅色
    }
    return false;
  }

  onForeground(): void {
    AppEnv.setForeground(true);
    try {
      AppViewModel.getInstance().onForeground();
    } catch (err) {
      // VM 尚未初始化时忽略
    }
    // MP 媒体库统计同理：息屏期间不轮询，解锁回来立刻补一次
    try {
      MpViewModel.getInstance().onForeground();
    } catch (err) {
      // VM 尚未初始化时忽略
    }
  }

  onBackground(): void {
    AppEnv.setForeground(false);
    try {
      AppViewModel.getInstance().onBackground();
    } catch (err) {
      // VM 尚未初始化时忽略
    }
    try {
      MpViewModel.getInstance().onBackground();
    } catch (err) {
      // VM 尚未初始化时忽略
    }
    // 音乐 / 投送进行中：退后台这一刻再确认一次长时任务已生效，
    // 否则息屏后被系统冻结，播一会儿就停（飞牛音乐这种原生播放器不会有这问题）。
    BackgroundAudioManager.ensureAlive().then((): void => {
    }).catch((): void => {
    });
  }

  onDestroy(): void {
    // 注销环境回调，避免 Ability 销毁后仍被 ApplicationContext 持有
    if (this.envCallbackId >= 0) {
      try {
        this.context.getApplicationContext().off('environment', this.envCallbackId).catch((): void => {
        });
      } catch (err) {
        // 忽略
      }
      this.envCallbackId = -1;
    }
    logInfo('EntryAbility', '应用销毁');
    // 进程退出时销毁 AVSession，系统侧媒体卡/会话资源随之回收
    BackgroundAudioManager.destroy();
  }
}
