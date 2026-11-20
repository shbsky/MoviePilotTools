/**
 * 海报地址归一化（对应安卓 net/PosterUrl.kt）。
 *
 * MoviePilot 返回的 poster 字段有三种形态：
 *  1. 完整地址：`https://img9.doubanio.com/view/photo/...`（豆瓣源最常见）
 *  2. 相对路径：`/p2912345.jpg`（TMDB 源的 poster_path）
 *  3. MP 自己的接口：`/api/v1/media/xxx/image`
 *
 * 老逻辑把所有非 http 开头的一律拼成 image.tmdb.org/t/p/w500，
 * 结果豆瓣的 /view/photo/... 被拼成错误地址。这里按来源分别拼装。
 */
export class PosterUrl {
  static readonly TMDB_BASE: string = 'https://image.tmdb.org/t/p/w500';
  static readonly DOUBAN_BASE: string = 'https://img9.doubanio.com';
  /** 豆瓣图床必须带的请求头（T08 DoubanImageProvider 使用） */
  static readonly DOUBAN_REFERER: string = 'https://movie.douban.com/';

  /**
   * @param raw   MP 返回的原始 poster / poster_path / backdrop_path
   * @param source MP 的 media_source：douban / tmdb / bangumi …
   * @param mediaServerBase 当前选中的 MP 地址，用于还原 /api/... 相对路径
   */
  static normalize(raw: string, source: string = '', mediaServerBase: string = ''): string {
    const value: string = raw.trim();
    if (value.length === 0) {
      return '';
    }
    const lower: string = value.toLowerCase();

    // 1) 已是完整地址：只把豆瓣的 http 升级成 https
    if (lower.startsWith('http://')) {
      if (lower.includes('doubanio.com') || lower.includes('douban.com')) {
        return `https://${value.substring(7)}`;
      }
      return value;
    }
    if (lower.startsWith('https://')) {
      return value;
    }

    // 2) 协议相对
    if (value.startsWith('//')) {
      return `https:${value}`;
    }

    // 3) 缺协议的豆瓣绝对地址
    if (lower.includes('doubanio.com')) {
      return `https://${value.replace(/^\/+|\/+$/g, '')}`;
    }

    const path: string = value.startsWith('/') ? value : `/${value}`;
    const normalizedSource: string = source.toLowerCase();

    // 4) MP 自己的接口要走服务器地址，不能塞给 TMDB
    if (path.startsWith('/api/')) {
      const base: string = mediaServerBase.trim().replace(/\/+$/g, '');
      return base.length > 0 ? `${base}${path}` : path;
    }

    // 5) 豆瓣路径：/view/photo/s_ratio_poster/public/p2912xxx.jpg
    if (normalizedSource === 'douban' || lower.includes('douban')) {
      return `${PosterUrl.DOUBAN_BASE}${path}`;
    }

    // 6) TMDB 相对路径 / 7) 来源未知时兜底 TMDB
    return `${PosterUrl.TMDB_BASE}${path}`;
  }

  static isDouban(url: string): boolean {
    const lower: string = url.toLowerCase();
    const proto: number = lower.indexOf('://');
    if (proto < 0) {
      return false;
    }
    const rest: string = lower.substring(proto + 3);
    const slash: number = rest.indexOf('/');
    const host: string = slash >= 0 ? rest.substring(0, slash) : rest;
    return host.includes('doubanio.com');
  }
}
