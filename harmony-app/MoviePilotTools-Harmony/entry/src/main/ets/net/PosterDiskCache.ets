import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppEnv, logWarn } from '../common/AppConstants';

/**
 * 海报图片磁盘缓存（首屏 Hero 轮播离线可见）。
 *
 * 把图片字节（ArrayBuffer）以 URL 的hash文件名存到应用沙箱 cacheDir/oiiqt_poster/。
 * 存字节而非 PixelMap：PixelMap 无法直接序列化落盘；读取时再 decode 成 PixelMap。
 * 豆瓣防盗链只需首次联网下载时带 Referer（见 DoubanImageProvider），命中缓存后不再请求。
 *
 * 只读缓存用于离线首屏；联网成功后再异步回写覆盖，达到 stale-while-revalidate。
 */
export class PosterDiskCache {
  private static dirReady: boolean = false;

  /** 缓存目录：应用沙箱，无需存储权限 */
  private static dir(): string {
    const path: string = AppEnv.context().cacheDir + '/oiiqt_poster';
    if (!PosterDiskCache.dirReady) {
      try {
        if (!fs.accessSync(path)) {
          fs.mkdirSync(path, true);
        }
        PosterDiskCache.dirReady = true;
      } catch (err) {
        // 目录不可建时读写会各自失败并被上层吞掉，不影响主流程
      }
    }
    return path;
  }

  /** URL → 安全文件名（纯数字 hash，避免非法文件名字符；不依赖 Math.imul） */
  private static key(url: string): string {
    let h: number = 5381;
    for (let i: number = 0; i < url.length; i++) {
      h = ((h * 33) + url.charCodeAt(i)) >>> 0; // djb2，>>>0 保持 32 位无符号
    }
    const hash: string = h.toString(16);
    // 再拼一个长度尾巴，降低极端碰撞概率
    return `p_${hash}_${url.length}`;
  }

  private static pathOf(url: string): string {
    return PosterDiskCache.dir() + '/' + PosterDiskCache.key(url);
  }

  /** 读缓存字节；无缓存/失败返回 null */
  static get(url: string): ArrayBuffer | null {
    if (url.length === 0) {
      return null;
    }
    const path: string = PosterDiskCache.pathOf(url);
    let file: fs.File | null = null;
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      // 取档案大小用 statSync（传 fd，与 AddTorrentScreen.ets 写法一致）
      const stat: fs.Stat = fs.statSync(file.fd);
      if (stat.size <= 0) {
        return null;
      }
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      return buf;
    } catch (err) {
      return null;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  /** 写缓存字节（同步落盘，量小且无所谓阻塞） */
  static put(url: string, buf: ArrayBuffer): void {
    if (url.length === 0 || buf.byteLength === 0) {
      return;
    }
    const path: string = PosterDiskCache.pathOf(url);
    let file: fs.File | null = null;
    try {
      // 先删残包再新建（fileIo 无 TRUNCATE 模式，沿用 HapUpdater 的做法）
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
      file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
      fs.writeSync(file.fd, buf);
    } catch (err) {
      logWarn('PosterDiskCache', `写缓存失败: ${err}`);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  /** 字节解码成 PixelMap；失败返回 null */
  static toPixelMap(buf: ArrayBuffer): image.PixelMap | null {
    try {
      const source: image.ImageSource = image.createImageSource(buf);
      if (source === null) {
        return null;
      }
      return source.createPixelMapSync();
    } catch (err) {
      return null;
    }
  }

  /** 一次性：读缓存并解码；无缓存/失败返回 null */
  static loadPixelMap(url: string): image.PixelMap | null {
    const buf: ArrayBuffer | null = PosterDiskCache.get(url);
    if (buf === null) {
      return null;
    }
    return PosterDiskCache.toPixelMap(buf);
  }
}
