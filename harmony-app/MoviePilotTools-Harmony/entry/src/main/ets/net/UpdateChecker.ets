import { get, TimeoutTier, Reply } from './HttpClient';
import { parseJsonObject, jStr, jNum } from '../common/AppConstants';

/**
 * 鸿蒙端版本更新检查（对应安卓 net/UpdateChecker.kt）。
 *
 * 关键点：两端共用同一个 GitHub Release（tag 是统一的），
 * 但鸿蒙只认 Release 资产里的 .hap / .app 安装包——
 * 没有 hap 资产时，即使 tag 更新也只提示「暂无鸿蒙包」，不再把用户导向 apk 网页。
 */

const LATEST_API: string = 'https://api.github.com/repos/shbsky/MoviePilotTools/releases/latest';
const RELEASES_URL: string = 'https://github.com/shbsky/MoviePilotTools/releases';

/** 一次检查的结果 */
export class UpdateInfo {
  /** Release tag，如 1.0.9 */
  tag: string = '';
  /** Release 网页地址 */
  page: string = '';
  /** tag 版本比本地新 */
  hasUpdate: boolean = false;
  /** 该 Release 是否含鸿蒙安装包（.hap / .app） */
  hasHap: boolean = false;
  /** hap 资产直链 */
  hapUrl: string = '';
  /** hap 资产文件名 */
  hapName: string = '';
  /** hap 大小（字节） */
  hapSize: number = 0;
}

/** 候选 hap 资产 */
class HapAsset {
  name: string = '';
  url: string = '';
  size: number = 0;

  constructor(name: string, url: string, size: number) {
    this.name = name;
    this.url = url;
    this.size = size;
  }
}

/** 归一化版本：去 v 前缀、去 +构建号、去 -后缀 */
function normalize(v: string): string {
  return v.trim().replace(/^[vV]/, '').split('+')[0].split('-')[0].trim();
}

/** latest 是否比 current 新（逐段比较，缺段按 0） */
export function newer(latest: string, current: string): boolean {
  const a: string[] = normalize(latest).split('.');
  const b: string[] = normalize(current).split('.');
  const n: number = Math.max(a.length, b.length);
  for (let i: number = 0; i < n; i++) {
    const x: number = i < a.length ? parseInt(a[i]) : 0;
    const y: number = i < b.length ? parseInt(b[i]) : 0;
    const nx: number = isNaN(x) ? 0 : x;
    const ny: number = isNaN(y) ? 0 : y;
    if (nx !== ny) {
      return nx > ny;
    }
  }
  return false;
}

/** 从 Release assets 里挑鸿蒙安装包，跳过 debug / unsigned */
function findHapAsset(obj: Record<string, Object>): HapAsset | null {
  const raw: Object | undefined = obj['assets'];
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return null;
  }
  const arr: Array<Object> = raw as Array<Object>;
  const candidates: HapAsset[] = [];
  for (const item of arr) {
    if (item === null || item === undefined || typeof item !== 'object') {
      continue;
    }
    const a: Record<string, Object> = item as Record<string, Object>;
    const name: string = jStr(a, ['name']);
    const url: string = jStr(a, ['browser_download_url']);
    const low: string = name.toLowerCase();
    if (url.length === 0) {
      continue;
    }
    if (!low.endsWith('.hap') && !low.endsWith('.app')) {
      continue;
    }
    candidates.push(new HapAsset(name, url, jNum(a, ['size'])));
  }
  if (candidates.length === 0) {
    return null;
  }
  const formal: HapAsset[] = candidates.filter((c: HapAsset): boolean => {
    const low: string = c.name.toLowerCase();
    return !low.includes('debug') && !low.includes('unsigned');
  });
  return formal.length > 0 ? formal[0] : candidates[0];
}

/** 请求 GitHub 最新 Release 并检查鸿蒙包；网络/格式异常会抛错，由调用方 catch */
export async function checkUpdate(current: string): Promise<UpdateInfo> {
  const reply: Reply = await get(LATEST_API, {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'MPtools-Harmony'
  }, TimeoutTier.SLOW);
  if (!reply.isSuccessful()) {
    const msg: string = reply.code === 404 ? '仓库还没有发布任何 Release'
      : (reply.code === 403 ? 'GitHub 限流了，过几分钟再试'
        : `检查更新失败（HTTP ${reply.code}）`);
    throw new Error(msg);
  }
  const obj: Record<string, Object> | null = parseJsonObject(reply.body);
  if (obj === null) {
    throw new Error('检查失败（返回格式异常）');
  }
  const tag: string = jStr(obj, ['tag_name', 'name']);
  if (tag.length === 0) {
    throw new Error('检查失败（没有发布记录）');
  }
  const out: UpdateInfo = new UpdateInfo();
  out.tag = tag;
  out.page = jStr(obj, ['html_url'], RELEASES_URL);
  out.hasUpdate = newer(tag, current);
  const hap: HapAsset | null = findHapAsset(obj);
  if (hap !== null) {
    out.hasHap = true;
    out.hapUrl = hap.url;
    out.hapName = hap.name;
    out.hapSize = hap.size;
  }
  return out;
}
