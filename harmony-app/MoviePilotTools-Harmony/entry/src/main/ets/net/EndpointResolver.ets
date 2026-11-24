import { Endpoint, EndpointMode, ServerConfig } from '../model/Models';
import { ApiException } from './HttpClient';
import { logInfo, logWarn } from '../common/AppConstants';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 域名 / IP 自动切换的核心（对应安卓 net/EndpointResolver.kt）。
 *
 * - AUTO：优先内网（连上 WiFi / 有线时先只探内网地址，通了就用），
 *   内网不通再并发探测全部候选，谁先响应用谁；结果缓存 10 分钟。
 *   「家里直连内网 IP、外面走公网域名」不需要手动干预。
 * - MANUAL：固定用用户选的那条。
 * 请求失败时调用 invalidate()，下次重新探测。
 */

const CACHE_TTL_MS: number = 10 * 60 * 1000;
const PROBE_BUDGET_MS: number = 3200;
/** 优先级提升：局域网内的探测预算（内网通常几十毫秒，1.2 秒还不通就是不在了） */
const LAN_PROBE_BUDGET_MS: number = 1200;

class CacheEntry {
  readonly endpoint: Endpoint;
  readonly at: number;

  constructor(endpoint: Endpoint, at: number) {
    this.endpoint = endpoint;
    this.at = at;
  }
}

export type EndpointProbe = (ep: Endpoint) => Promise<boolean>;

export class EndpointResolver {
  private static cache: Map<string, CacheEntry> = new Map();
  /** 最近一次判定的「当前是否在局域网」，3 秒内复用（避免每个请求都查一次系统能力） */
  private static lanCached: boolean = true;
  private static lanCheckedAt: number = 0;
  private static watching: boolean = false;
  /** 网络监听实例（必须常驻，否则监听会被回收） */
  private static netWatcher: connection.NetConnection | null = null;

  /**
   * 当前网络是不是局域网（WiFi / 有线）。
   *
   * 查询失败一律返回 true：多探一次内网没有任何副作用（不通会自动回退公网），
   * 反过来误判成「不在局域网」就会在自家 WiFi 下去挤公网域名。
   */
  static deviceOnLan(): boolean {
    const now: number = Date.now();
    if (now - EndpointResolver.lanCheckedAt < 3000) {
      return EndpointResolver.lanCached;
    }
    let onLan: boolean = true;
    try {
      const net: connection.NetHandle = connection.getDefaultNetSync();
      if (net === undefined || net.netId === 0) {
        onLan = false;
      } else {
        const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);
        const bears: connection.NetBearType[] = caps.bearerTypes;
        onLan = bears !== undefined &&
          (bears.indexOf(connection.NetBearType.BEARER_WIFI) >= 0 ||
            bears.indexOf(connection.NetBearType.BEARER_ETHERNET) >= 0);
      }
    } catch (err) {
      onLan = true;
    }
    EndpointResolver.lanCached = onLan;
    EndpointResolver.lanCheckedAt = now;
    return onLan;
  }

  /**
   * 监听网络切换：连上 / 断开 WiFi、切蜂窝时清空选路缓存，
   * 下一次请求立刻重新探测（否则最长要等 10 分钟 TTL，会出现「回到家还连着公网域名」）。
   * 只装一次，进程内常驻。
   */
  static installNetworkWatcher(): void {
    if (EndpointResolver.watching) {
      return;
    }
    EndpointResolver.watching = true;
    const onChange = (): void => {
      EndpointResolver.cache.clear();
      EndpointResolver.lanCheckedAt = 0;
      logInfo('EndpointResolver', '网络发生变化，选路缓存已清空');
    };
    try {
      // 事件挂在 NetConnection 实例上（不是 connection 命名空间），且必须先 register 才会回调；
      // 实例要常驻，否则被回收后监听就没了
      const watcher: connection.NetConnection = connection.createNetConnection();
      EndpointResolver.netWatcher = watcher;
      watcher.register((err: BusinessError): void => {
        if (err) {
          logWarn('EndpointResolver', `网络监听注册失败: ${err.code}`);
        }
      });
      watcher.on('netAvailable', (_net: connection.NetHandle): void => {
        onChange();
      });
      watcher.on('netLost', (_net: connection.NetHandle): void => {
        onChange();
      });
      watcher.on('netCapabilitiesChange',
        (_info: connection.NetCapabilityInfo): void => {
          onChange();
        });
    } catch (err) {
      logWarn('EndpointResolver', `网络监听注册异常: ${err}`);
    }
  }

  /** 只探内网这几条，短预算内谁先成功用谁；全不通返回 null（交给公网兜底） */
  private static async probeLanFirst(lanEps: Endpoint[],
    probe: EndpointProbe): Promise<Endpoint | null> {
    let done: boolean = false;
    let settle: ((ep: Endpoint | null) => void) | null = null;
    const winner: Promise<Endpoint | null> =
      new Promise<Endpoint | null>((resolve: (ep: Endpoint | null) => void): void => {
        settle = resolve;
      });
    for (const ep of lanEps) {
      probe(ep).then((ok: boolean): void => {
        if (ok && !done && settle !== null) {
          done = true;
          settle(ep);
        }
      }).catch((err: Error): void => {
        logWarn('EndpointResolver', `内网探测失败 ${ep.display()}: ${err.message}`);
      });
    }
    try {
      return await Promise.race<Endpoint | null>([
        winner,
        new Promise<Endpoint | null>((resolve: (ep: Endpoint | null) => void): void => {
          setTimeout((): void => {
            done = true;
            resolve(null);
          }, LAN_PROBE_BUDGET_MS);
        })
      ]);
    } catch (err) {
      return null;
    }
  }

  static cachedEndpoint(serverId: string): Endpoint | null {
    const hit: CacheEntry | undefined = EndpointResolver.cache.get(serverId);
    if (hit === undefined) {
      return null;
    }
    if (Date.now() - hit.at > CACHE_TTL_MS) {
      EndpointResolver.cache.delete(serverId);
      return null;
    }
    return hit.endpoint;
  }

  static invalidate(serverId: string): void {
    EndpointResolver.cache.delete(serverId);
  }

  static remember(serverId: string, endpoint: Endpoint): void {
    EndpointResolver.cache.set(serverId, new CacheEntry(endpoint, Date.now()));
  }

  /** 按「缓存优先 / 手动固定」给出候选顺序，供需要逐个尝试的调用方（如 MoviePilot）使用 */
  static candidates(serverId: string, endpoints: Endpoint[], mode: EndpointMode,
    pinnedIndex: number): Endpoint[] {
    if (endpoints.length === 0) {
      return [];
    }
    if (mode === EndpointMode.MANUAL) {
      const pinned: Endpoint = pinnedIndex >= 0 && pinnedIndex < endpoints.length
        ? endpoints[pinnedIndex] : endpoints[0];
      const out: Endpoint[] = [pinned];
      for (const ep of endpoints) {
        if (ep.hostKey() !== pinned.hostKey()) {
          out.push(ep);
        }
      }
      return out;
    }
    const cached: Endpoint | null = EndpointResolver.cachedEndpoint(serverId);
    if (cached !== null) {
      let found: boolean = false;
      for (const ep of endpoints) {
        if (ep.hostKey() === cached.hostKey()) {
          found = true;
          break;
        }
      }
      if (found) {
        const out: Endpoint[] = [];
        for (const ep of endpoints) {
          if (ep.hostKey() === cached.hostKey()) {
            out.push(ep);
          }
        }
        for (const ep of endpoints) {
          if (ep.hostKey() !== cached.hostKey()) {
            out.push(ep);
          }
        }
        return out;
      }
    }
    return endpoints;
  }

  /** 解析出一台服务器的可用端点；一个都探不通时抛 ApiException */
  static async resolve(server: ServerConfig, probe: EndpointProbe): Promise<Endpoint> {
    const chosen: Endpoint | null = await EndpointResolver.resolveAny(
      server.id, server.activeEndpoints(), server.endpointMode, server.pinnedEndpointIndex, probe);
    if (chosen === null) {
      throw new ApiException('没有可用的访问地址');
    }
    return chosen;
  }

  /**
   * 与 resolve 同逻辑，但不依赖 ServerConfig —— 流量统计面板、音乐服务这类
   * 「只有一个多行地址输入框」的轻量服务也走同一套自动检测。
   * 返回 null 表示一个地址都探不通。
   */
  static async resolveAny(cacheKey: string, endpoints: Endpoint[], mode: EndpointMode,
    pinnedIndex: number, probe: EndpointProbe): Promise<Endpoint | null> {
    const valid: Endpoint[] = [];
    for (const ep of endpoints) {
      if (ep.enabled && ep.isValid()) {
        valid.push(ep);
      }
    }
    if (valid.length === 0) {
      return null;
    }

    if (mode === EndpointMode.MANUAL) {
      const pinned: Endpoint = pinnedIndex >= 0 && pinnedIndex < valid.length
        ? valid[pinnedIndex] : valid[0];
      // 固定的地址也要探一下：不通就回退到别的地址，别把用户卡在「连不上」
      let pinnedOk: boolean = false;
      try {
        pinnedOk = await probe(pinned);
      } catch (err) {
        pinnedOk = false;
      }
      if (pinnedOk) {
        EndpointResolver.remember(cacheKey, pinned);
        return pinned;
      }
      logWarn('EndpointResolver', `手动固定地址探测失败，回退并发探测: ${pinned.display()}`);
    } else {
      const cached: Endpoint | null = EndpointResolver.cachedEndpoint(cacheKey);
      // 缓存里如果存的是公网地址，而现在又在局域网里，就作废重测（连上 WiFi 优先走内网）
      const mustReprobe: boolean = cached !== null && !cached.isLanHost() &&
        EndpointResolver.deviceOnLan() &&
        valid.some((ep: Endpoint): boolean => ep.isLanHost());
      if (cached !== null && !mustReprobe) {
        for (const ep of valid) {
          if (ep.hostKey() === cached.hostKey()) {
            return ep;
          }
        }
      }
      if (mustReprobe && cached !== null) {
        logInfo('EndpointResolver', `缓存是外网地址(${cached.display()})，当前在局域网内，重新选路`);
      }
    }

    // 把 pinned 排最前，其余保持原顺序
    const ordered: Endpoint[] = valid.slice(0);
    const pinnedKey: string = pinnedIndex >= 0 && pinnedIndex < valid.length
      ? valid[pinnedIndex].hostKey() : '';
    if (pinnedKey.length > 0) {
      ordered.sort((a: Endpoint, b: Endpoint): number => {
        const av: number = a.hostKey() === pinnedKey ? 0 : 1;
        const bv: number = b.hostKey() === pinnedKey ? 0 : 1;
        return av - bv;
      });
    }

    // 局域网内：先只探内网地址，通了就定它（不再让公网域名抢「谁先响应」）
    if (EndpointResolver.deviceOnLan()) {
      const lanEps: Endpoint[] = ordered.filter((ep: Endpoint): boolean => ep.isLanHost());
      if (lanEps.length > 0) {
        const lanWinner: Endpoint | null = await EndpointResolver.probeLanFirst(lanEps, probe);
        if (lanWinner !== null) {
          EndpointResolver.remember(cacheKey, lanWinner);
          logInfo('EndpointResolver', `优先内网命中: ${lanWinner.display()}`);
          return lanWinner;
        }
        logWarn('EndpointResolver', '内网地址都不通，回退并发探测（公网）');
      }
    }

    // 并发探测所有候选，谁先成功用谁；预算 3200ms
    let done: boolean = false;
    let settle: ((ep: Endpoint | null) => void) | null = null;
    const winnerPromise: Promise<Endpoint | null> =
      new Promise<Endpoint | null>((resolve: (ep: Endpoint | null) => void): void => {
        settle = resolve;
      });

    for (const ep of ordered) {
      probe(ep).then((ok: boolean): void => {
        if (ok && !done && settle !== null) {
          done = true;
          settle(ep);
        }
      }).catch((err: Error): void => {
        logWarn('EndpointResolver', `探测失败 ${ep.display()}: ${err.message}`);
      });
    }

    let winner: Endpoint | null = null;
    try {
      winner = await Promise.race<Endpoint | null>([
        winnerPromise,
        new Promise<Endpoint | null>((resolve: (ep: Endpoint | null) => void): void => {
          setTimeout((): void => {
            if (!done) {
              done = true;
              resolve(null);
            } else {
              resolve(null);
            }
          }, PROBE_BUDGET_MS);
        })
      ]);
    } catch (err) {
      winner = null;
    }

    if (winner !== null) {
      EndpointResolver.remember(cacheKey, winner);
      logInfo('EndpointResolver', `选路命中: ${winner.display()}`);
    }
    return winner;
  }
}
