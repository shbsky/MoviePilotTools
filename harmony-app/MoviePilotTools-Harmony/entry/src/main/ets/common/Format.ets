import { TorrentStatus } from '../model/Models';

/**
 * 速度/体积/时间/相对时间格式化，1:1 移植安卓 data/Format.kt。
 */

const UNITS: string[] = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

function pad2(n: number): string {
  return n < 10 ? '0' + String(n) : String(n);
}

/** 1024 进制，和 iOS 版 ByteCountFormatter(countStyle = .binary) 对齐 */
export function formatBytes(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  let value: number = bytes;
  let unit: number = 0;
  while (value >= 1024.0 && unit < UNITS.length - 1) {
    value = value / 1024.0;
    unit++;
  }
  if (unit === 0) {
    return `${Math.trunc(value)} B`;
  }
  return `${value.toFixed(2)} ${UNITS[unit]}`;
}

/** 存储容量：>=100 不保留小数，>=10 留 1 位，其余 2 位（照抄原版 formatStorageSize） */
export function formatStorageSize(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  const gb: number = 1024.0 * 1024 * 1024;
  const tb: number = gb * 1024;
  const pb: number = tb * 1024;
  const value: number = bytes;
  if (value >= pb) {
    return fixedByMagnitude(value / pb, 'PB');
  }
  if (value >= tb) {
    return fixedByMagnitude(value / tb, 'TB');
  }
  return formatBytes(bytes);
}

function fixedByMagnitude(value: number, unit: string): string {
  let decimals: number = 2;
  if (value >= 100) {
    decimals = 0;
  } else if (value >= 10) {
    decimals = 1;
  }
  return `${value.toFixed(decimals)} ${unit}`;
}

export function formatSpeed(bytesPerSecond: number): string {
  return `${formatBytes(bytesPerSecond)}/s`;
}

export function formatRatio(ratio: number): string {
  return ratio.toFixed(2);
}

export function formatPercent(progress: number): string {
  return `${Math.trunc(progress * 100)}%`;
}

/** 20天21小时1分 这种中文时长 */
export function formatDurationCN(seconds: number): string {
  if (seconds <= 0) {
    return '0分';
  }
  const totalMinutes: number = Math.floor(seconds / 60);
  const days: number = Math.floor(totalMinutes / (24 * 60));
  const hours: number = Math.floor((totalMinutes % (24 * 60)) / 60);
  const minutes: number = totalMinutes % 60;
  let out: string = '';
  if (days > 0) {
    out += `${days}天`;
  }
  if (hours > 0) {
    out += `${hours}小时`;
  }
  out += `${minutes}分`;
  return out;
}

export function formatDateTime(epochMillis: number): string {
  if (epochMillis <= 0) {
    return '--';
  }
  const d: Date = new Date(epochMillis);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ` +
    `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

/** 解析标题里的分辨率徽章 */
export class ResolutionBadge {
  readonly text: string;
  readonly argb: number;

  constructor(text: string, argb: number) {
    this.text = text;
    this.argb = argb;
  }
}

export function extractResolutionBadge(title: string): ResolutionBadge | null {
  const upper: string = title.toUpperCase();
  if (/\b(4320P|8K)\b/.test(upper)) {
    return new ResolutionBadge('8K', 0xFFAF52DE);
  }
  if (/\b(2160P|4K|UHD)\b/.test(upper)) {
    return new ResolutionBadge('4K', 0xFFAF52DE);
  }
  if (/\b1440P\b/.test(upper)) {
    return new ResolutionBadge('1440p', 0xFF5856D6);
  }
  if (/\b1080P\b/.test(upper)) {
    return new ResolutionBadge('1080p', 0xFF0A84FF);
  }
  if (/\b720P\b/.test(upper)) {
    return new ResolutionBadge('720p', 0xFF34C759);
  }
  if (/\b576P\b/.test(upper)) {
    return new ResolutionBadge('576p', 0xFF8E8E93);
  }
  if (/\b480P\b/.test(upper)) {
    return new ResolutionBadge('480p', 0xFF8E8E93);
  }
  return null;
}

/** tracker 地址只留域名 */
export function trackerHostOf(raw: string): string {
  if (raw.trim().length === 0) {
    return '';
  }
  let s: string = raw;
  const proto: number = s.indexOf('://');
  s = proto >= 0 ? s.substring(proto + 3) : s;
  const slash: number = s.indexOf('/');
  s = slash >= 0 ? s.substring(0, slash) : s;
  const q: number = s.indexOf('?');
  s = q >= 0 ? s.substring(0, q) : s;
  const at: number = s.lastIndexOf('@');
  s = at >= 0 ? s.substring(at + 1) : s;
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

export function percentColor(progress: number, status: TorrentStatus): number {
  if (status === TorrentStatus.ERROR) {
    return 0xFFFF3B30;
  }
  if (progress >= 0.9999) {
    return 0xFF34C759;
  }
  return 0xFF0A84FF;
}

export function humanEta(seconds: number): string {
  if (seconds <= 0 || seconds >= 8640000) {
    return '∞';
  }
  const h: number = Math.floor(seconds / 3600);
  const m: number = Math.floor((seconds % 3600) / 60);
  const s: number = Math.abs(Math.floor(seconds % 60));
  if (h > 0) {
    return `${h}h ${m}m`;
  }
  if (m > 0) {
    return `${m}m ${s}s`;
  }
  return `${s}s`;
}

/** 相对时间：刚刚 / 12 分钟前 / 3 小时前 / 2 天前 / 日期（PRD #46） */
export function formatRelativeTime(epochMillis: number): string {
  if (epochMillis <= 0) {
    return '--';
  }
  const diff: number = Date.now() - epochMillis;
  if (diff < 0) {
    return formatDateTime(epochMillis).substring(0, 16);
  }
  const minutes: number = Math.floor(diff / 60000);
  if (minutes < 1) {
    return '刚刚';
  }
  if (minutes < 60) {
    return `${minutes} 分钟前`;
  }
  if (minutes < 60 * 24) {
    return `${Math.floor(minutes / 60)} 小时前`;
  }
  if (minutes < 60 * 24 * 7) {
    return `${Math.floor(minutes / (60 * 24))} 天前`;
  }
  const d: Date = new Date(epochMillis);
  return `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

// ---------- 音乐时长（原 MusicModels.kt） ----------

export function formatDuration(seconds: number): string {
  if (seconds <= 0) {
    return '--:--';
  }
  const m: number = Math.floor(seconds / 60);
  const s: number = seconds % 60;
  return `${m}:${pad2(s)}`;
}

export function formatDurationMs(ms: number): string {
  return formatDuration(Math.floor(ms / 1000));
}
