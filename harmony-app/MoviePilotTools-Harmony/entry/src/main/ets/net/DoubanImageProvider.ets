import { image } from '@kit.ImageKit';
import { getBinary } from './HttpClient';
import { PosterUrl } from './PosterUrl';
import { logDebug, logWarn } from '../common/AppConstants';

/**
 * 豆瓣图床加载器（对应安卓 DoubanImageHeaderInterceptor + Coil 的组合）。
 *
 * 实测（2026-11）：
 *  - 不带 Referer：HTTP 418，响应体 0 字节
 *  - 带 `Referer: https://movie.douban.com/`：HTTP 200，正常返回图片
 *
 * 安卓用 OkHttp 拦截器全局补头；鸿蒙的 Image 组件带不了请求头，
 * 所以豆瓣图走「手动 getBinary → ImageSource → PixelMap」，
 * 非豆瓣图仍由 Image 组件直接加载（不耗内存转码）。
 */
export class DoubanImageProvider {

  private static readonly DOUBAN_UA: string =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) ' +
    'Chrome/124.0.0.0 Mobile Safari/537.36';

  static isDoubanHost(url: string): boolean {
    return url.toLowerCase().includes('doubanio.com');
  }

  /** 请求头补齐规则（与安卓拦截器逐项一致），导出给其他需要直接拉豆瓣图的调用方 */
  static doubanHeaders(): Record<string, string> {
    const headers: Record<string, string> = {
      'Referer': PosterUrl.DOUBAN_REFERER,
      'User-Agent': DoubanImageProvider.DOUBAN_UA,
      // 不放 avif：老设备解码不了，webp 已经够用
      'Accept': 'image/webp,image/apng,image/*,*/*;q=0.8'
    };
    return headers;
  }

  /** 拉豆瓣图并解码成 PixelMap；失败返回 null（调用方走渐变兜底） */
  static async fetchPixelMap(url: string): Promise<image.PixelMap | null> {
    try {
      logDebug('DoubanImage', `fetch ${url}`);
      const buf: ArrayBuffer = await getBinary(url, DoubanImageProvider.doubanHeaders(), 20000);
      const source: image.ImageSource = image.createImageSource(buf);
      if (source === null) {
        return null;
      }
      const pixelMap: image.PixelMap = await source.createPixelMap();
      return pixelMap;
    } catch (err) {
      const e: Error = err as Error;
      logWarn('DoubanImage', `加载失败: ${e.message}`);
      return null;
    }
  }
}
