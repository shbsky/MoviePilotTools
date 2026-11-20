import { http } from '@kit.NetworkKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { common, Want, wantConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { logDebug, logWarn } from '../common/AppConstants';

/**
 * 鸿蒙端应用内更新（对应安卓 net/ApkUpdater.kt）。
 *
 * 流程：把 GitHub Release 里的 .hap 下到应用沙箱 update 目录 →
 * 用 startAbility(viewData + 文件 URI) 交给系统匹配的应用打开，
 * 系统会拉起安装界面（仍需用户在系统弹窗点一次「安装」——鸿蒙不允许三方静默安装）。
 * 国内直连 GitHub 失败时按顺序换镜像；拉起失败由调用方降级到浏览器打开 Release 页。
 */

/** 单次下载最长等待（毫秒） */
const READ_TIMEOUT_MS: number = 120000;

/** 国内直连 objects.githubusercontent.com 常常失败，按顺序换镜像 */
const MIRRORS: string[] = [
  '',
  'https://ghfast.top/',
  'https://gh-proxy.com/'
];

/** 下载进度：0f..1f，总长未知时为 -1 */
export class HapProgress {
  downloaded: number = 0;
  total: number = 0;
  fraction: number = -1;
}

/** 下载目录：应用沙箱 filesDir/update，无需存储权限 */
function downloadDir(ctx: common.UIAbilityContext): string {
  const dir: string = ctx.filesDir + '/update';
  try {
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
  } catch (err) {
    // 已存在或不可建，交给后续 openSync 报错
  }
  return dir;
}

/** 清掉上次下载的残包 */
export function cleanup(ctx: common.UIAbilityContext): void {
  try {
    const dir: string = downloadDir(ctx);
    const names: string[] = fs.listFileSync(dir);
    for (const n of names) {
      try {
        fs.unlinkSync(dir + '/' + n);
      } catch (err) {
        // 忽略单个文件删除失败
      }
    }
  } catch (err) {
    // 目录不存在
  }
}

/** 单个源下载到 dest，成功返回，失败抛错 */
async function fetchOne(url: string, dest: string,
  onProgress: (p: HapProgress) => void): Promise<void> {
  const req: http.HttpRequest = http.createHttp();
  let file: fs.File | null = null;
  let settled: boolean = false;
  try {
    const part: string = dest + '.part';
    // 先删残包再新建，避免旧内容残留（fileIo 无 TRUNCATE 模式）
    if (fs.accessSync(part)) {
      fs.unlinkSync(part);
    }
    file = fs.openSync(part, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    const headers: Record<string, string> = {
      'User-Agent': 'MPtools-Harmony',
      'Accept': 'application/octet-stream'
    };
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: 15000,
      readTimeout: READ_TIMEOUT_MS,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    };

    await new Promise<void>((resolve: () => void, reject: (e: Error) => void): void => {
      let downloaded: number = 0;
      let lastCode: number = 0;
      let lastEmit: number = 0;
      const finishOk: () => void = (): void => {
        if (!settled) {
          settled = true;
          resolve();
        }
      };
      const finishErr: (e: Error) => void = (e: Error): void => {
        if (!settled) {
          settled = true;
          reject(e);
        }
      };
      try {
        req.on('dataReceive', (chunk: ArrayBuffer): void => {
          try {
            if (file !== null) {
              fs.writeSync(file.fd, chunk);
            }
          } catch (err) {
            finishErr(new Error('写入安装包失败'));
            return;
          }
          downloaded += chunk.byteLength;
          const now: number = Date.now();
          if (now - lastEmit >= 120) {
            lastEmit = now;
            const p: HapProgress = new HapProgress();
            p.downloaded = downloaded;
            p.total = 0;
            p.fraction = -1;
            onProgress(p);
          }
        });
        req.on('dataEnd', (): void => {
          finishOk();
        });
        req.requestInStream(url, opts).then((code: number): void => {
          lastCode = code;
          if (code >= 400) {
            finishErr(new Error(`下载失败（HTTP ${code}）`));
          }
        }).catch((err: BusinessError): void => {
          finishErr(new Error(err.message));
        });
      } catch (err) {
        const e: BusinessError = err as BusinessError;
        finishErr(new Error(e.message));
      }
    });

    if (file !== null) {
      fs.closeSync(file);
      file = null;
    }
    const size: number = fs.statSync(part).size;
    if (size < 512 * 1024) {
      throw new Error('下载到的文件不完整');
    }
    if (fs.accessSync(dest)) {
      fs.unlinkSync(dest);
    }
    fs.renameSync(part, dest);
    const done: HapProgress = new HapProgress();
    done.downloaded = size;
    done.total = size;
    done.fraction = 1;
    onProgress(done);
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (err) {
        // 忽略
      }
    }
    req.destroy();
  }
}

/**
 * 下载 hap 到沙箱，返回本地路径。国内直连失败自动换镜像。
 * onProgress 在网络回调线程触发，UI 侧自行切换。
 */
export async function download(ctx: common.UIAbilityContext, url: string,
  fileName: string, onProgress: (p: HapProgress) => void): Promise<string> {
  const dir: string = downloadDir(ctx);
  const safeName: string = fileName.length > 0 ? fileName.replace(/[^\w.\-]/g, '_') : 'update.hap';
  const dest: string = dir + '/' + safeName;
  let lastError: Error = new Error('下载失败，请稍后重试');

  for (const mirror of MIRRORS) {
    // 镜像只对 GitHub 域名有意义，其它源原样请求
    if (mirror.length > 0 && !url.startsWith('https://github.com/')) {
      break;
    }
    try {
      await fetchOne(mirror + url, dest, onProgress);
      return dest;
    } catch (err) {
      lastError = err as Error;
      logWarn('HapUpdater', `mirror=${mirror} 失败：${lastError.message}`);
      try {
        const part: string = dest + '.part';
        if (fs.accessSync(part)) {
          fs.unlinkSync(part);
        }
        if (fs.accessSync(dest)) {
          fs.unlinkSync(dest);
        }
      } catch (e) {
        // 忽略清理失败
      }
    }
  }
  throw lastError;
}

/**
 * 用系统能力打开本地 hap，匹配到的应用（文件管理/包安装器）会拉起安装界面。
 * 返回是否成功拉起；失败时调用方应降级到浏览器打开 Release 页。
 */
export async function install(ctx: common.UIAbilityContext, path: string): Promise<boolean> {
  try {
    const uri: string = fileUri.getUriFromPath(path);
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: uri,
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    };
    await ctx.startAbility(want);
    logDebug('HapUpdater', `已拉起安装：${path}`);
    return true;
  } catch (err) {
    const e: BusinessError = err as BusinessError;
    logWarn('HapUpdater', `拉起安装失败：${e.message}`);
    return false;
  }
}
