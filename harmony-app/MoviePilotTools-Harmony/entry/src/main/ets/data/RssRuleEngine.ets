import { RssItemRecord, RssSource } from '../model/RssModels';
import { formatBytes } from '../common/Format';

/**
 * RSS 规则引擎（对应安卓 data/RssRuleEngine.kt，逐条对齐 iOS 原版 RSSRuleEngine.swift）：
 * 1) 包含关键词必须全部命中；2) 排除关键词任一命中即淘汰；
 * 3) 体积区间（RSS 未给体积时跳过，minSizeGB/maxSizeGB 为 -1 表示未设置）；
 * 4) 集数过滤（支持范围、空格分隔、分号「或」）。
 *
 * 用户决策 b：RSS 模型+引擎只做代码级入库，无页面入口、无后台轮询。
 */

/** 集数定位：season = -1 表示标题里没带季号 */
class EpisodeMarker {
  season: number = -1;
  episode: number = 0;
}

/** 集数规则：0 = 单集，1 = 区间 */
class EpisodeRule {
  kind: number = 0;
  start: EpisodeMarker = new EpisodeMarker();
  end: EpisodeMarker = new EpisodeMarker();
}

export class RssRuleEngine {

  static matches(item: RssItemRecord, source: RssSource): boolean {
    const title: string = item.title.toLowerCase();

    if (source.includeKeywords.length > 0) {
      for (const keyword of source.includeKeywords) {
        const k: string = keyword.trim().toLowerCase();
        if (k.length === 0) {
          continue;
        }
        if (!title.includes(k)) {
          return false;
        }
      }
    }

    if (source.excludeKeywords.length > 0) {
      for (const keyword of source.excludeKeywords) {
        const k: string = keyword.trim().toLowerCase();
        if (k.length === 0) {
          continue;
        }
        if (title.includes(k)) {
          return false;
        }
      }
    }

    if (item.sizeBytes > 0) {
      const gb: number = item.sizeBytes / 1024 / 1024 / 1024;
      if (source.minSizeGB >= 0 && gb < source.minSizeGB) {
        return false;
      }
      if (source.maxSizeGB >= 0 && gb > source.maxSizeGB) {
        return false;
      }
    }

    const filter: string = source.episodeFilter.trim();
    if (filter.length > 0 && !RssRuleEngine.matchesEpisodeFilter(item.title, filter)) {
      return false;
    }

    return true;
  }

  /** 命中原因，给「规则预览」用 */
  static explain(item: RssItemRecord, source: RssSource): string | null {
    if (!RssRuleEngine.matches(item, source)) {
      return null;
    }
    const parts: string[] = [];
    if (source.includeKeywords.length > 0) {
      parts.push('关键词命中');
    }
    if (item.sizeBytes > 0) {
      parts.push(formatBytes(item.sizeBytes));
    }
    if (source.episodeFilter.trim().length > 0) {
      parts.push('集数命中');
    }
    const joined: string = parts.join(' · ');
    return joined.length > 0 ? joined : '全部满足';
  }

  // ---------- 集数 ----------

  private static matchesEpisodeFilter(title: string, rawFilter: string): boolean {
    // "or" 当成"或"的分隔符（对齐安卓/iOS 行为）
    const normalized: string = rawFilter.replace(/\bor\b/gi, ';').trim();
    const rules: EpisodeRule[] = [];

    const segments: string[] = normalized.split(';');
    for (const part of segments) {
      const text: string = part.trim();
      if (text.length === 0) {
        continue;
      }
      // 含 "-" 的整体当作区间候选，否则按空格拆成多个单集候选
      const candidates: string[] =
        text.includes('-') ? [text] : text.split(/\s+/);
      for (const candidate of candidates) {
        const rule: EpisodeRule | null = RssRuleEngine.parseEpisodeRule(candidate);
        if (rule !== null) {
          rules.push(rule);
        }
      }
    }

    if (rules.length === 0) {
      return true; // 规则写错时不改变原有行为
    }

    const marker: EpisodeMarker | null = RssRuleEngine.extractEpisodeMarker(title);
    if (marker === null) {
      return false;
    }
    for (const rule of rules) {
      if (RssRuleEngine.matchesRule(rule, marker)) {
        return true;
      }
    }
    return false;
  }

  /** 从标题提取 S01E02 / E02 / " - 02" 形式的集数定位 */
  private static extractEpisodeMarker(title: string): EpisodeMarker | null {
    let m: RegExpExecArray | null = /\bS(\d{1,2})[ ._-]?E(\d{1,3})\b/i.exec(title);
    if (m !== null) {
      const season: number = parseInt(m[1], 10);
      const episode: number = parseInt(m[2], 10);
      if (!isNaN(season) && !isNaN(episode)) {
        const marker: EpisodeMarker = new EpisodeMarker();
        marker.season = season;
        marker.episode = episode;
        return marker;
      }
    }
    m = /\bE(?:P)?[ ._-]?(\d{1,3})\b/i.exec(title);
    if (m !== null) {
      const episode: number = parseInt(m[1], 10);
      if (!isNaN(episode)) {
        const marker: EpisodeMarker = new EpisodeMarker();
        marker.season = -1;
        marker.episode = episode;
        return marker;
      }
    }
    m = /(?:\s-\s|\s)(\d{1,3})(?=\s*[\(\[]|$)/i.exec(title);
    if (m !== null) {
      const episode: number = parseInt(m[1], 10);
      if (!isNaN(episode)) {
        const marker: EpisodeMarker = new EpisodeMarker();
        marker.season = -1;
        marker.episode = episode;
        return marker;
      }
    }
    return null;
  }

  private static parseEpisodeRule(text: string): EpisodeRule | null {
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      return null;
    }
    if (trimmed.includes('-')) {
      // 只在第一个 "-" 处切开：S01E01-E10 / 01-12
      const idx: number = trimmed.indexOf('-');
      const start: EpisodeMarker | null =
        RssRuleEngine.parseMarker(trimmed.substring(0, idx), -1);
      const end: EpisodeMarker | null = start === null
        ? null
        : RssRuleEngine.parseMarker(trimmed.substring(idx + 1), start.season);
      if (start !== null && end !== null) {
        const rule: EpisodeRule = new EpisodeRule();
        rule.kind = 1;
        rule.start = start;
        rule.end = end;
        return rule;
      }
    }
    const marker: EpisodeMarker | null = RssRuleEngine.parseMarker(trimmed, -1);
    if (marker === null) {
      return null;
    }
    const rule: EpisodeRule = new EpisodeRule();
    rule.kind = 0;
    rule.start = marker;
    return rule;
  }

  private static parseMarker(text: string, inheritedSeason: number): EpisodeMarker | null {
    const normalized: string = text.trim().toUpperCase();
    if (normalized.length === 0) {
      return null;
    }
    let m: RegExpExecArray | null = /^S(\d{1,2})E(\d{1,3})$/.exec(normalized);
    if (m !== null) {
      const season: number = parseInt(m[1], 10);
      const episode: number = parseInt(m[2], 10);
      if (!isNaN(season) && !isNaN(episode)) {
        const marker: EpisodeMarker = new EpisodeMarker();
        marker.season = season;
        marker.episode = episode;
        return marker;
      }
    }
    m = /^E?(\d{1,3})$/.exec(normalized);
    if (m !== null) {
      const episode: number = parseInt(m[1], 10);
      if (!isNaN(episode)) {
        const marker: EpisodeMarker = new EpisodeMarker();
        marker.season = inheritedSeason;
        marker.episode = episode;
        return marker;
      }
    }
    return null;
  }

  private static matchesRule(rule: EpisodeRule, item: EpisodeMarker): boolean {
    if (rule.kind === 0) {
      const season: number = rule.start.season;
      return (season < 0 || item.season === season) && item.episode === rule.start.episode;
    }
    const start: EpisodeMarker = rule.start;
    const end: EpisodeMarker = rule.end;
    const rangeSeason: number = start.season >= 0 ? start.season : end.season;
    if (rangeSeason >= 0 && item.season !== rangeSeason) {
      return false;
    }
    if (start.season >= 0 && end.season >= 0 && start.season !== end.season) {
      return false; // 暂不支持跨季区间
    }
    const lower: number = Math.min(start.episode, end.episode);
    const upper: number = Math.max(start.episode, end.episode);
    return item.episode >= lower && item.episode <= upper;
  }
}
