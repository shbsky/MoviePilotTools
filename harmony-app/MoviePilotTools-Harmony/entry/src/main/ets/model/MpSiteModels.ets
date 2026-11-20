import { jStr, jNum, jBool } from '../common/AppConstants';

/**
 * MoviePilot 站点模型，移植安卓 data/MpSiteModels.kt。
 *
 * App 里对站点**只读**：登录、Cookie、分类映射、限流全在 MP 服务端，
 * 增删改一律去 MP 后台做，这里不提供写入入口。
 */

export class MpSite {
  id: number = 0;
  name: string = '';
  domain: string = '';
  url: string = '';
  /** 优先级，MP 里越小越先搜 */
  pri: number = 0;
  isActive: boolean = true;
  /** 该站绑定的下载器，空表示用默认 */
  downloader: string = '';
  note: string = '';

  /** 展示用域名：优先 domain，空则从 url 里抠 */
  displayDomain(): string {
    if (this.domain.trim().length > 0) {
      return this.domain.trim();
    }
    const raw: string = this.url.trim();
    if (raw.length === 0) {
      return '';
    }
    const sep: number = raw.indexOf('://');
    let rest: string = sep >= 0 ? raw.substring(sep + 3) : raw;
    const slash: number = rest.indexOf('/');
    if (slash >= 0) {
      rest = rest.substring(0, slash);
    }
    const q: number = rest.indexOf('?');
    if (q >= 0) {
      rest = rest.substring(0, q);
    }
    return rest;
  }

  initial(): string {
    const t: string = this.name.trim();
    return t.length > 0 ? t.substring(0, 1).toUpperCase() : '#';
  }

  /**
   * 与 MpSiteUserData.domain 做匹配用的键。
   * MP 里两边基本一致，但可能一边带 www、一边大小写不同，统一抹平后再比；
   * 匹配不上只会让卡片少显示个人数据，不会出错。
   */
  matchKeys(): string[] {
    const raw: string[] = [this.domain, this.displayDomain()];
    if (this.url.trim().length > 0) {
      raw.push(this.url);
    }
    const out: string[] = [];
    for (const item of raw) {
      let k: string = item.trim().toLowerCase();
      if (k.startsWith('https://')) {
        k = k.substring(8);
      } else if (k.startsWith('http://')) {
        k = k.substring(7);
      }
      if (k.startsWith('www.')) {
        k = k.substring(4);
      }
      while (k.endsWith('/')) {
        k = k.substring(0, k.length - 1);
      }
      if (k.length > 0 && out.indexOf(k) < 0) {
        out.push(k);
      }
    }
    return out;
  }
}

export function mpSiteFromJson(o: Record<string, Object>): MpSite | null {
  const site: MpSite = new MpSite();
  site.id = Math.trunc(jNum(o, ['id'], 0));
  site.name = jStr(o, ['name']).trim();
  if (site.id <= 0 || site.name.length === 0) {
    return null;
  }
  site.domain = jStr(o, ['domain']);
  site.url = jStr(o, ['url']);
  site.pri = Math.trunc(jNum(o, ['pri'], 0));
  // 字段缺失按「启用」处理：MP 里 is_active 恒有值，缺失说明版本差异，
  // 宁可显示出来也别把用户所有站点都置灰
  site.isActive = jBool(o, ['is_active'], true);
  site.downloader = jStr(o, ['downloader']);
  site.note = jStr(o, ['note']);
  return site;
}

/**
 * 站点个人数据（`GET api/v1/site/userdata/latest`）。
 * 这是 MP 服务端定期去站点抓的数据（不是实时），所以带 updated_*，
 * 太久没更新时要提示用户 —— 数字可能已经是几天前的了。
 */
export class MpSiteUserData {
  domain: string = '';
  /** MP 侧的站点名称，域名对不上时拿它做兜底匹配 */
  name: string = '';
  username: string = '';
  userLevel: string = '';
  joinAt: string = '';
  /** 魔力值 / 积分 */
  bonus: number = 0;
  upload: number = 0;
  download: number = 0;
  ratio: number = 0;
  seeding: number = 0;
  leeching: number = 0;
  seedingSize: number = 0;
  leechingSize: number = 0;
  messageUnread: number = 0;
  messageTotal: number = 0;
  /** 站点抓取失败时 MP 会把原因写在这里（登录失效最常见） */
  errMsg: string = '';
  updatedDay: string = '';
  updatedTime: string = '';

  hasError(): boolean {
    return this.errMsg.trim().length > 0;
  }

  ratioText(): string {
    return this.ratio.toFixed(2);
  }

  private stamp(): string {
    const t: string = this.updatedTime.trim();
    return t.length > 0 ? t : this.updatedDay.trim();
  }

  /** 「更新 11-16」；拿不到日期返回空串，卡片上不占位 */
  updatedText(): string {
    const raw: string = this.stamp();
    if (raw.length === 0) {
      return '';
    }
    const text: string = raw.replace(/T/g, ' ');
    const m: RegExpMatchArray | null = text.match(/(\d{4})-(\d{2})-(\d{2})/);
    if (m !== null) {
      return `更新 ${m[2]}-${m[3]}`;
    }
    return `更新 ${text.substring(0, 10)}`;
  }

  /** 距今天数；解析不出来返回 -1（当作「不知道」，不标黄） */
  staleDays(): number {
    const raw: string = this.stamp();
    if (raw.length === 0) {
      return -1;
    }
    const ms: number = MpSiteUserData.parseStamp(raw);
    if (ms <= 0) {
      return -1;
    }
    const diff: number = Date.now() - ms;
    const days: number = Math.trunc(diff / 86400000);
    return days > 0 ? days : 0;
  }

  isStale(): boolean {
    return this.staleDays() > 3;
  }

  /** 「2026-11-16 12:34:56」「2026-11-16T12:34:56」「2026-11-16」统一解析成毫秒 */
  private static parseStamp(raw: string): number {
    const text: string = raw.replace(/T/g, ' ');
    const m: RegExpMatchArray | null =
      text.match(/(\d{4})-(\d{2})-(\d{2})(?:\s+(\d{2}):(\d{2})(?::(\d{2}))?)?/);
    if (m === null) {
      return -1;
    }
    const year: number = parseInt(m[1], 10);
    const month: number = parseInt(m[2], 10) - 1;
    const day: number = parseInt(m[3], 10);
    const hour: number = m[4] !== undefined ? parseInt(m[4], 10) : 0;
    const minute: number = m[5] !== undefined ? parseInt(m[5], 10) : 0;
    const second: number = m[6] !== undefined ? parseInt(m[6], 10) : 0;
    return new Date(year, month, day, hour, minute, second).getTime();
  }
}

export function mpSiteUserDataFromJson(o: Record<string, Object>): MpSiteUserData {
  const d: MpSiteUserData = new MpSiteUserData();
  d.domain = jStr(o, ['domain']);
  d.name = jStr(o, ['name']);
  d.username = jStr(o, ['username']);
  d.userLevel = jStr(o, ['user_level']);
  if (d.userLevel.length === 0) {
    d.userLevel = jStr(o, ['user_level_name']);
  }
  d.joinAt = jStr(o, ['join_at']);
  d.bonus = jNum(o, ['bonus'], 0);
  d.upload = Math.trunc(jNum(o, ['upload'], 0));
  d.download = Math.trunc(jNum(o, ['download'], 0));
  d.ratio = jNum(o, ['ratio'], 0);
  d.seeding = Math.trunc(jNum(o, ['seeding'], 0));
  d.leeching = Math.trunc(jNum(o, ['leeching'], 0));
  d.seedingSize = Math.trunc(jNum(o, ['seeding_size'], 0));
  d.leechingSize = Math.trunc(jNum(o, ['leeching_size'], 0));
  d.messageUnread = Math.trunc(jNum(o, ['message_unread'], 0));
  d.messageTotal = Math.trunc(jNum(o, ['message_total'], 0));
  d.errMsg = jStr(o, ['err_msg']);
  d.updatedDay = jStr(o, ['updated_day']);
  d.updatedTime = jStr(o, ['updated_time']);
  return d;
}

/** 站点分类（`GET api/v1/site/category/{id}`）。各站分类完全不同，全部由接口驱动。 */
export class MpSiteCategory {
  /**
   * MP 里的分类标识（数字或文本，比如 m-team 的 `419`）。
   * **请求 cat= 参数传的必须是它**（不是 cat 组名），否则站点不认、永远「这个分类下没有种子」。
   */
  id: string = '';
  /** 分类组名，只用来展示 */
  cat: string = '';
  /** 完整分类名，只用来展示 */
  desc: string = '';

  constructor(id: string = '', cat: string = '', desc: string = '') {
    this.id = id;
    this.cat = cat;
    this.desc = desc;
  }

  /** 发给 MP 的值 */
  value(): string {
    if (this.id.trim().length > 0) {
      return this.id.trim();
    }
    return this.cat.trim().length > 0 ? this.cat.trim() : this.desc.trim();
  }

  /** 给用户看：desc 最具体（`Movie(電影)/SD`），其次 cat */
  label(): string {
    if (this.desc.trim().length > 0) {
      return this.desc.trim();
    }
    return this.cat.trim().length > 0 ? this.cat.trim() : this.id.trim();
  }
}

/**
 * 站点种子列表的排序方式 —— 对齐 MoviePilot 网页版「浏览」弹窗右侧那四个选项。
 * MP 的 `site/resource/{id}` 没有 sort 参数，所以全部是客户端排序。
 */
export enum SiteSort {
  LATEST,
  SIZE,
  SEEDERS,
  GRABS
}

export function siteSortLabel(s: SiteSort): string {
  switch (s) {
    case SiteSort.LATEST:
      return '最新发布';
    case SiteSort.SIZE:
      return '资源大小';
    case SiteSort.SEEDERS:
      return '做种最多';
    case SiteSort.GRABS:
      return '下载最多';
    default:
      return '最新发布';
  }
}

/** 把站点列表按优先级+名字排好：停用的沉底，同优先级按名字 */
export function sortSitesForDisplay(list: MpSite[]): MpSite[] {
  const out: MpSite[] = list.slice(0);
  out.sort((a: MpSite, b: MpSite): number => {
    if (a.isActive !== b.isActive) {
      return a.isActive ? -1 : 1;
    }
    if (a.pri !== b.pri) {
      return a.pri - b.pri;
    }
    const an: string = a.name.toLowerCase();
    const bn: string = b.name.toLowerCase();
    return an < bn ? -1 : (an > bn ? 1 : 0);
  });
  return out;
}
