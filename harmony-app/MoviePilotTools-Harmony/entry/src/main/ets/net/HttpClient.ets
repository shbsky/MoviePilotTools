import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import {
  CONNECT_NORMAL_MS, READ_NORMAL_MS, READ_SLOW_MS, CONNECT_PROBE_MS, READ_PROBE_MS,
  logWarn, logDebug
} from '../common/AppConstants';

/**
 * HTTP 封装单例（对应安卓 net/Net.kt + OkHttp）：
 * - 内存 CookieJar：qBittorrent 登录后的 SID 需要跨请求保持；
 * - 三档超时：普通（连接 6s/读 30s）、慢速（读 130s，MP 资源搜索）、探测（2.5s）；
 * - 统一 ApiException。
 */

export class ApiException extends Error {
  readonly code: number;

  constructor(message: string, code: number = 0) {
    super(message);
    this.name = 'ApiException';
    this.code = code;
  }
}

export class Reply {
  code: number = 0;
  body: string = '';
  headers: Record<string, string> = {};

  isSuccessful(): boolean {
    return this.code >= 200 && this.code < 300;
  }
}

/** 内存 Cookie：按 host 存「name=value; name2=value2」串 */
const COOKIE_STORE: Map<string, Map<string, string>> = new Map();

export function hostOf(url: string): string {
  let s: string = url;
  const proto: number = s.indexOf('://');
  if (proto >= 0) {
    s = s.substring(proto + 3);
  }
  const slash: number = s.indexOf('/');
  const hostPart: string = slash >= 0 ? s.substring(0, slash) : s;
  const at: number = hostPart.lastIndexOf('@');
  return (at >= 0 ? hostPart.substring(at + 1) : hostPart).toLowerCase();
}

export function clearCookies(): void {
  COOKIE_STORE.clear();
}

function mergeSetCookies(host: string, setCookieValue: string): void {
  if (setCookieValue.trim().length === 0) {
    return;
  }
  let bucket: Map<string, string> | undefined = COOKIE_STORE.get(host);
  if (bucket === undefined) {
    bucket = new Map<string, string>();
    COOKIE_STORE.set(host, bucket);
  }
  // set-cookie 可能多段；Expires 里的逗号会影响简单 split，
  // 用正则逐段取第一对 name=value 即可（我们只关心 SID 这类短名值对）
  const pairRegex: RegExp = /([a-zA-Z0-9_\-\.]+)=([^;]*)/g;
  let m: RegExpExecArray | null = pairRegex.exec(setCookieValue);
  while (m !== null) {
    if (m.length >= 3 && m[1].length > 0) {
      bucket.set(m[1], m[2]);
    }
    m = pairRegex.exec(setCookieValue);
  }
}

function cookieHeaderFor(host: string): string {
  const bucket: Map<string, string> | undefined = COOKIE_STORE.get(host);
  if (bucket === undefined || bucket.size === 0) {
    return '';
  }
  const parts: string[] = [];
  bucket.forEach((v: string, k: string): void => {
    parts.push(`${k}=${v}`);
  });
  return parts.join('; ');
}

export class TimeoutTier {
  static readonly NORMAL: number = 0;
  static readonly SLOW: number = 1;
  static readonly PROBE: number = 2;
}

function tierTimeouts(tier: number): number[] {
  if (tier === TimeoutTier.SLOW) {
    return [CONNECT_NORMAL_MS, READ_SLOW_MS];
  }
  if (tier === TimeoutTier.PROBE) {
    return [CONNECT_PROBE_MS, READ_PROBE_MS];
  }
  return [CONNECT_NORMAL_MS, READ_NORMAL_MS];
}

function flattenHeaders(raw: Object | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (raw === undefined || raw === null) {
    return out;
  }
  const h: Record<string, Object> = raw as Record<string, Object>;
  const keys: string[] = Object.keys(h);
  for (const k of keys) {
    const v: Object | undefined = h[k];
    if (typeof v === 'string') {
      out[k.toLowerCase()] = v as string;
    } else if (Array.isArray(v)) {
      const parts: string[] = [];
      const arr: Array<Object> = v as Array<Object>;
      for (const item of arr) {
        if (typeof item === 'string') {
          parts.push(item as string);
        }
      }
      out[k.toLowerCase()] = parts.join('\n');
    }
  }
  return out;
}

export function formEncode(form: Record<string, string>): string {
  const parts: string[] = [];
  const keys: string[] = Object.keys(form);
  for (const k of keys) {
    parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(form[k])}`);
  }
  return parts.join('&');
}

export function basicAuth(user: string, pass: string): string {
  const encoder: util.TextEncoder = new util.TextEncoder();
  const bytes: Uint8Array = encoder.encodeInto(`${user}:${pass}`);
  const b64: string = new util.Base64Helper().encodeToStringSync(bytes);
  return `Basic ${b64}`;
}

async function doRequest(url: string, method: http.RequestMethod, body: string,
  headers: Record<string, string>, tier: number): Promise<Reply> {
  const req: http.HttpRequest = http.createHttp();
  try {
    const host: string = hostOf(url);
    const finalHeaders: Record<string, string> = {};
    const keys: string[] = Object.keys(headers);
    for (const k of keys) {
      finalHeaders[k] = headers[k];
    }
    if (finalHeaders['Cookie'] === undefined) {
      const cookie: string = cookieHeaderFor(host);
      if (cookie.length > 0) {
        finalHeaders['Cookie'] = cookie;
      }
    }

    const tt: number[] = tierTimeouts(tier);
    const opts: http.HttpRequestOptions = {
      method: method,
      header: finalHeaders,
      connectTimeout: tt[0],
      readTimeout: tt[1],
      // 这些请求全是 NAS 上的实时状态/操作，任何一层缓存都可能让「刚点完还是旧值」
      usingCache: false,
      expectDataType: http.HttpDataType.STRING
    };
    if (body.length > 0) {
      opts.extraData = body;
    }

    const res: http.HttpResponse = await req.request(url, opts);
    const resHeaders: Record<string, string> = flattenHeaders(res.header as Object);
    const setCookie: string =
      resHeaders['set-cookie'] !== undefined ? resHeaders['set-cookie'] : '';
    if (setCookie.length > 0) {
      mergeSetCookies(host, setCookie);
      logDebug('Http', `host=${host} 收到 Set-Cookie`);
    }
    const reply: Reply = new Reply();
    reply.code = res.responseCode;
    reply.body = String(res.result ?? '');
    reply.headers = resHeaders;
    return reply;
  } finally {
    req.destroy();
  }
}

export async function get(url: string, headers: Record<string, string> = {},
  tier: number = TimeoutTier.NORMAL): Promise<Reply> {
  return await doRequest(url, http.RequestMethod.GET, '', headers, tier);
}

export async function post(url: string, body: string, contentType: string,
  headers: Record<string, string> = {}, tier: number = TimeoutTier.NORMAL): Promise<Reply> {
  const finalHeaders: Record<string, string> = { 'Content-Type': contentType };
  const keys: string[] = Object.keys(headers);
  for (const k of keys) {
    finalHeaders[k] = headers[k];
  }
  return await doRequest(url, http.RequestMethod.POST, body, finalHeaders, tier);
}

export async function postForm(url: string, form: Record<string, string>,
  headers: Record<string, string> = {}, tier: number = TimeoutTier.NORMAL): Promise<Reply> {
  return await post(url, formEncode(form), 'application/x-www-form-urlencoded', headers, tier);
}

export async function postJson(url: string, body: string,
  headers: Record<string, string> = {}, tier: number = TimeoutTier.NORMAL): Promise<Reply> {
  return await post(url, body, 'application/json', headers, tier);
}

export async function putJson(url: string, body: string,
  headers: Record<string, string> = {}, tier: number = TimeoutTier.NORMAL): Promise<Reply> {
  return await doRequest(url, http.RequestMethod.PUT, body, headers, tier);
}

export async function del(url: string,
  headers: Record<string, string> = {}, tier: number = TimeoutTier.NORMAL): Promise<Reply> {
  return await doRequest(url, http.RequestMethod.DELETE, '', headers, tier);
}

/** 二进制 GET（豆瓣图片 / 封面 / Range 探流），超时毫秒 */
export async function getBinary(url: string, headers: Record<string, string> = {},
  timeoutMs: number = 25000): Promise<ArrayBuffer> {
  const req: http.HttpRequest = http.createHttp();
  try {
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: CONNECT_NORMAL_MS,
      readTimeout: timeoutMs,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    };
    const res: http.HttpResponse = await req.request(url, opts);
    if (res.responseCode < 200 || res.responseCode >= 300) {
      throw new ApiException(`HTTP ${res.responseCode}`, res.responseCode);
    }
    return res.result as ArrayBuffer;
  } finally {
    req.destroy();
  }
}

/** 流式 GET：onChunk 增量回调（MP 跨站资源搜索「边收边显示」），返回状态码 */
export function requestStream(url: string, headers: Record<string, string>,
  onChunk: (chunk: ArrayBuffer) => void, timeoutMs: number = 180000): Promise<number> {
  return new Promise<number>((resolve: (v: number) => void, reject: (e: Error) => void) => {
    const req: http.HttpRequest = http.createHttp();
    let settled: boolean = false;
    let lastCode: number = 0;

    // Cookie 必须一起带：MP 的 /search/media/{id}/stream 走的是 Query/Cookie 里的
    // resource_token（登录时由 MP 写进 Set-Cookie），缺了它服务端直接 422「请求参数不正确」
    const finalHeaders: Record<string, string> = {};
    const keys: string[] = Object.keys(headers);
    for (const k of keys) {
      finalHeaders[k] = headers[k];
    }
    if (finalHeaders['Cookie'] === undefined) {
      const cookie: string = cookieHeaderFor(hostOf(url));
      if (cookie.length > 0) {
        finalHeaders['Cookie'] = cookie;
      }
    }

    const finishOk: (code: number) => void = (code: number): void => {
      if (!settled) {
        settled = true;
        try {
          req.off('dataReceive');
          req.off('dataEnd');
        } catch (err) {
          // 忽略 off 异常
        }
        req.destroy();
        resolve(code);
      }
    };
    const finishErr: (e: Error) => void = (e: Error): void => {
      if (!settled) {
        settled = true;
        try {
          req.off('dataReceive');
          req.off('dataEnd');
        } catch (err) {
          // 忽略 off 异常
        }
        req.destroy();
        reject(e);
      }
    };

    try {
      req.on('dataReceive', (chunk: ArrayBuffer): void => {
        onChunk(chunk);
      });
      req.on('dataEnd', (): void => {
        logDebug('Http', `流式接收结束 code=${lastCode}`);
        finishOk(lastCode);
      });
      const tt: number[] = [CONNECT_NORMAL_MS, timeoutMs];
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: finalHeaders,
        connectTimeout: tt[0],
        readTimeout: tt[1],
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      };
      req.requestInStream(url, opts).then((code: number): void => {
        lastCode = code;
        if (code >= 400) {
          finishOk(code);
        }
      }).catch((err: Error): void => {
        finishErr(err);
      });
    } catch (err) {
      finishErr(err as Error);
    }
  });
}

/** 二进制 POST（multipart 上传 .torrent 用）：body 已是完整字节流 */
export async function postBytes(url: string, body: ArrayBuffer, contentType: string,
  headers: Record<string, string> = {}, tier: number = TimeoutTier.NORMAL): Promise<Reply> {
  const req: http.HttpRequest = http.createHttp();
  try {
    const host: string = hostOf(url);
    const finalHeaders: Record<string, string> = { 'Content-Type': contentType };
    const keys: string[] = Object.keys(headers);
    for (const k of keys) {
      finalHeaders[k] = headers[k];
    }
    if (finalHeaders['Cookie'] === undefined) {
      const cookie: string = cookieHeaderFor(host);
      if (cookie.length > 0) {
        finalHeaders['Cookie'] = cookie;
      }
    }
    const tt: number[] = tierTimeouts(tier);
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: finalHeaders,
      connectTimeout: tt[0],
      readTimeout: tt[1],
      expectDataType: http.HttpDataType.STRING,
      extraData: body
    };
    const res: http.HttpResponse = await req.request(url, opts);
    const reply: Reply = new Reply();
    reply.code = res.responseCode;
    reply.body = String(res.result ?? '');
    reply.headers = flattenHeaders(res.header as Object);
    return reply;
  } finally {
    req.destroy();
  }
}

/** 拼 multipart/form-data 字节流（仅支持文本字段 + 一个文件字段） */
export function buildMultipart(boundary: string, fields: Record<string, string>,
  fileFieldName: string, fileName: string, fileBytes: ArrayBuffer): ArrayBuffer {
  const encoder: util.TextEncoder = new util.TextEncoder();
  const chunks: Uint8Array[] = [];
  const fieldKeys: string[] = Object.keys(fields);
  for (const k of fieldKeys) {
    const head: string = `--${boundary}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${fields[k]}\r\n`;
    chunks.push(encoder.encodeInto(head));
  }
  const fileHead: string = `--${boundary}\r\nContent-Disposition: form-data; name="${fileFieldName}"; ` +
    `filename="${fileName}"\r\nContent-Type: application/x-bittorrent\r\n\r\n`;
  chunks.push(encoder.encodeInto(fileHead));
  chunks.push(new Uint8Array(fileBytes));
  chunks.push(encoder.encodeInto(`\r\n--${boundary}--\r\n`));

  let total: number = 0;
  for (const c of chunks) {
    total += c.length;
  }
  const out: Uint8Array = new Uint8Array(total);
  let offset: number = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.length;
  }
  return out.buffer as ArrayBuffer;
}

export function orMessage(e: Error): string {
  if (e instanceof ApiException) {
    return e.message;
  }
  return e.message.length > 0 ? e.message : '未知错误';
}
