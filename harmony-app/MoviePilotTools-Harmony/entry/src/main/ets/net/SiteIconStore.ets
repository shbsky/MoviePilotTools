import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { logWarn } from '../common/AppConstants';

/**
 * 站点图标缓存与解码（对应安卓 net/SiteIconStore.kt）。
 *
 * MP 的 `site/icon/{id}` 返回的 icon 字段有两种形态：
 *  - 图片地址（少数站点直接给 favicon 地址）→ 直接交给 Image 组件；
 *  - **纯 base64**（无 `data:` 前缀，可能还带换行）→ 必须自己 Base64 解码再生成 PixelMap。
 *    安卓那边一开始拼成 data URI 交给 Coil 全部失败，只剩地址型的能显示，就是这个原因。
 *
 * 失败语义（决定要不要重试）：
 *  - MP 明确说没有图标（null）→ 记进 missing，不再请求；
 *  - 网络 / 鉴权异常 → 不记 missing，允许下次重试。
 */

export class SiteIcon {
  /** base64 解出来的位图（地址型图标时为 null） */
  pixel: image.PixelMap | null = null;
  /** 地址型图标的 URL（base64 型为空串） */
  url: string = '';

  constructor(pixel: image.PixelMap | null, url: string) {
    this.pixel = pixel;
    this.url = url;
  }

  isEmpty(): boolean {
    return this.pixel === null && this.url.length === 0;
  }
}

const MAX_CACHE: number = 128;
const MAX_CONCURRENCY: number = 4;

export class SiteIconStore {
  private static cache: Map<number, SiteIcon> = new Map();
  /** 插入顺序（用于超上限时淘汰最早的，Map 迭代器在 ArkTS 里取值写法更绕，单独记一份） */
  private static order: number[] = [];
  private static missing: Set<number> = new Set();
  private static inflight: Map<number, Promise<SiteIcon | null>> = new Map();
  private static running: number = 0;
  private static queue: Array<() => void> = [];

  static cached(siteId: number): SiteIcon | null {
    const hit: SiteIcon | undefined = SiteIconStore.cache.get(siteId);
    return hit === undefined ? null : hit;
  }

  static isMissing(siteId: number): boolean {
    return SiteIconStore.missing.has(siteId);
  }

  /** 换 MP 服务器时清空，避免上一台的图标串到下一台 */
  static clear(): void {
    SiteIconStore.cache.forEach((v: SiteIcon): void => {
      if (v.pixel !== null) {
        v.pixel.release();
      }
    });
    SiteIconStore.cache.clear();
    SiteIconStore.order = [];
    SiteIconStore.missing.clear();
    SiteIconStore.inflight.clear();
  }

  /**
   * 取图标：命中缓存直接给，否则拉一次（并发上限 4，多出来的排队）。
   * 同一站点并发调用只会真正请求一次。
   */
  static async load(siteId: number, fetchRaw: () => Promise<string | null>): Promise<SiteIcon | null> {
    const hit: SiteIcon | null = SiteIconStore.cached(siteId);
    if (hit !== null) {
      return hit;
    }
    if (SiteIconStore.missing.has(siteId)) {
      return null;
    }
    const pending: Promise<SiteIcon | null> | undefined = SiteIconStore.inflight.get(siteId);
    if (pending !== undefined) {
      return await pending;
    }
    const task: Promise<SiteIcon | null> = SiteIconStore.runLimited(siteId, fetchRaw);
    SiteIconStore.inflight.set(siteId, task);
    try {
      return await task;
    } finally {
      SiteIconStore.inflight.delete(siteId);
    }
  }

  private static async runLimited(siteId: number, fetchRaw: () => Promise<string | null>): Promise<SiteIcon | null> {
    await SiteIconStore.acquire();
    try {
      let raw: string | null;
      try {
        raw = await fetchRaw();
      } catch (err) {
        // 网络/鉴权失败：不记 missing，下次还能重试
        logWarn('SiteIcon', `站点 ${siteId} 图标请求失败：${(err as Error).message}`);
        return null;
      }
      if (raw === null || raw.trim().length === 0) {
        // MP 明确说没有图标
        SiteIconStore.missing.add(siteId);
        return null;
      }
      const icon: SiteIcon | null = await SiteIconStore.decode(raw);
      if (icon === null) {
        // 拿到了内容但解不出来（站点返回一张坏图），别一直重试
        SiteIconStore.missing.add(siteId);
        return null;
      }
      SiteIconStore.put(siteId, icon);
      return icon;
    } finally {
      SiteIconStore.release();
    }
  }

  private static put(siteId: number, icon: SiteIcon): void {
    if (SiteIconStore.cache.has(siteId)) {
      SiteIconStore.cache.set(siteId, icon);
      return;
    }
    while (SiteIconStore.order.length >= MAX_CACHE) {
      const oldest: number | undefined = SiteIconStore.order.shift();
      if (oldest === undefined) {
        break;
      }
      const old: SiteIcon | undefined = SiteIconStore.cache.get(oldest);
      if (old !== undefined && old.pixel !== null) {
        old.pixel.release();
      }
      SiteIconStore.cache.delete(oldest);
    }
    SiteIconStore.cache.set(siteId, icon);
    SiteIconStore.order.push(siteId);
  }

  private static acquire(): Promise<void> {
    if (SiteIconStore.running < MAX_CONCURRENCY) {
      SiteIconStore.running++;
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void): void => {
      SiteIconStore.queue.push((): void => {
        SiteIconStore.running++;
        resolve();
      });
    });
  }

  private static release(): void {
    SiteIconStore.running--;
    const next: (() => void) | undefined = SiteIconStore.queue.shift();
    if (next !== undefined) {
      next();
    }
  }

  /** 原始字符串 → 可渲染对象：http 地址直接用，base64 自己解码成位图 */
  private static async decode(raw: string): Promise<SiteIcon | null> {
    let text: string = raw.trim();
    if (text.startsWith('http://') || text.startsWith('https://')) {
      return new SiteIcon(null, text);
    }
    // 兼容带 data: 前缀的写法，以及被换行折断的长 base64
    const comma: number = text.indexOf('base64,');
    if (text.startsWith('data:') && comma > 0) {
      text = text.substring(comma + 7);
    }
    text = text.replace(/[\r\n\t\s]/g, '');
    if (text.length === 0) {
      return null;
    }
    try {
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(text);
      if (bytes.length === 0) {
        return null;
      }
      const source: image.ImageSource = image.createImageSource(bytes.buffer as ArrayBuffer);
      if (source === null) {
        return null;
      }
      const pixel: image.PixelMap = await source.createPixelMap();
      source.release();
      return new SiteIcon(pixel, '');
    } catch (err) {
      logWarn('SiteIcon', `图标解码失败：${(err as Error).message}`);
      return null;
    }
  }
}
