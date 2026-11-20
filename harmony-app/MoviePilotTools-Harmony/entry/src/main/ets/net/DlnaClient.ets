import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { get, post, Reply, TimeoutTier } from './HttpClient';
import { logInfo, logWarn } from '../common/AppConstants';

/**
 * 极简 DLNA/UPnP 投送客户端（对应安卓 net/dlna/DlnaClient.kt，只做 MediaRenderer 需要的那几个动作）。
 *
 * 流程：SSDP M-SEARCH 发现设备 → 拉设备描述 XML 找 AVTransport 的 controlURL
 *      → SOAP 调 SetAVTransportURI + Play 把音频地址推过去（音箱自己去拉流）。
 *
 * 鸿蒙侧说明：SSDP 的 M-SEARCH 应答是单播回源端口，所以普通 UDPSocket 就够用，
 * 不需要像安卓那样申请组播锁（组播锁只是为了让系统不过滤组播包）。
 */

const TAG: string = 'DLNA';

const SSDP_ADDR: string = '239.255.255.250';
const SSDP_PORT: number = 1900;
const MEDIA_RENDERER: string = 'urn:schemas-upnp-org:device:MediaRenderer:1';
const AV_TRANSPORT: string = 'urn:schemas-upnp-org:service:AVTransport:1';
const RENDERING_CONTROL: string = 'urn:schemas-upnp-org:service:RenderingControl:1';
const SOAP_ENV: string = 'http://schemas.xmlsoap.org/soap/envelope/';

/** UPnP 的错误应答里带的说明（701 = 转场不可用，714 = 非法实例） */
export class DlnaException extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DlnaException';
  }
}

/** 发现到的投送目标 */
export class DlnaDevice {
  name: string = '';
  model: string = '';
  location: string = '';
  controlUrl: string = '';
  /** RenderingControl 的 controlURL：有它才能调音箱音量，没有就只能靠音箱自己的旋钮 */
  volumeUrl: string = '';

  id(): string {
    return this.controlUrl;
  }

  volumeSupported(): boolean {
    return this.volumeUrl.length > 0;
  }
}

/** 播放状态快照（用来判断一首放完了没有，好接着推下一首） */
export class DlnaTransport {
  state: string = '';
  positionMs: number = 0;
  durationMs: number = 0;
}

export class DlnaClient {

  // ---------------------------------------------------------------- 发现

  /**
   * 广播搜索 MediaRenderer：发 3 次 M-SEARCH（UDP 会丢包），在 timeoutMs 内收应答。
   * 应答是 HTTP 报文样式的文本，从 Location 头取设备描述 XML 的地址。
   */
  static async discover(timeoutMs: number = 4000): Promise<DlnaDevice[]> {
    const udp: socket.UDPSocket = socket.constructUDPSocketInstance();
    const locations: Set<string> = new Set<string>();
    try {
      // port 0 = 系统随机分配一个空闲端口；应答会单播回这个端口
      await udp.bind({ address: '0.0.0.0', port: 0, family: 1 } as socket.NetAddress);
      try {
        const extra: socket.UDPExtraOptions = { broadcast: true };
        await udp.setExtraOptions(extra);
      } catch (err) {
        // 部分机型可能拒绝 broadcast 选项，不影响组播发送
        logWarn(TAG, `setExtraOptions(broadcast) 忽略: ${err}`);
      }
      udp.on('message', (info: socket.SocketMessageInfo): void => {
        const text: string = DlnaClient.decodeText(info.message);
        const loc: string | null = DlnaClient.headerValue(text, 'location');
        if (loc !== null && loc.toLowerCase().startsWith('http')) {
          locations.add(loc);
        }
      });

      const message: string = 'M-SEARCH * HTTP/1.1\r\n' +
        `HOST: ${SSDP_ADDR}:${SSDP_PORT}\r\n` +
        'MAN: "ssdp:discover"\r\n' +
        'MX: 2\r\n' +
        `ST: ${MEDIA_RENDERER}\r\n` +
        'USER-AGENT: OiiQT/Harmony UPnP/1.1\r\n' +
        '\r\n';
      const target: socket.NetAddress =
        { address: SSDP_ADDR, port: SSDP_PORT, family: 1 } as socket.NetAddress;
      for (let i = 0; i < 3; i++) {
        try {
          await udp.send({ data: message, address: target } as socket.UDPSendOptions);
        } catch (err) {
          logWarn(TAG, `M-SEARCH 发送失败(第${i + 1}次): ${err}`);
        }
      }

      const deadline: number = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        await DlnaClient.sleep(150);
      }
      try {
        udp.off('message');
        await udp.close();
      } catch (err) {
        // close 失败不影响结果
      }
    } catch (err) {
      const e: Error = err as Error;
      logWarn(TAG, `SSDP 发现失败: ${e.message}`);
      try {
        await udp.close();
      } catch (closeErr) {
        // 忽略
      }
    }

    const devices: DlnaDevice[] = [];
    const seenUrls: Set<string> = new Set<string>();
    const keys: string[] = Array.from(locations);
    for (const location of keys) {
      const device: DlnaDevice | null = await DlnaClient.describe(location);
      if (device === null) {
        continue;
      }
      if (seenUrls.has(device.controlUrl)) {
        continue;
      }
      seenUrls.add(device.controlUrl);
      devices.push(device);
    }
    logInfo(TAG, `发现 ${devices.length} 台投送设备`);
    return devices;
  }

  /** 拉设备描述，取出友好名 + AVTransport 的 controlURL */
  private static async describe(location: string): Promise<DlnaDevice | null> {
    let xml: string = '';
    try {
      const reply = await get(location, {}, TimeoutTier.PROBE);
      if (!reply.isSuccessful()) {
        return null;
      }
      xml = reply.body;
    } catch (err) {
      return null;
    }
    if (xml.trim().length === 0) {
      return null;
    }

    // 设备描述 XML 用顺序扫描解析（等价于安卓的 XmlPullParser 走法）：
    // 先碰到 serviceType 才认后面的 controlURL，这样能区分 AVTransport / RenderingControl
    let friendlyName: string = '';
    let modelName: string = '';
    let deviceType: string = '';
    let currentService: string = '';
    let avControl: string = '';
    let volumeControl: string = '';
    const tagRegex: RegExp = /<(friendlyName|modelName|deviceType|serviceType|controlURL)[^>]*>([\s\S]*?)<\/\1>/g;
    let m: RegExpExecArray | null = tagRegex.exec(xml);
    while (m !== null) {
      const tag: string = m[1];
      const value: string = m[2].trim();
      if (tag === 'friendlyName') {
        if (friendlyName.length === 0) {
          friendlyName = DlnaClient.unescapeXml(value);
        }
      } else if (tag === 'modelName') {
        if (modelName.length === 0) {
          modelName = DlnaClient.unescapeXml(value);
        }
      } else if (tag === 'deviceType') {
        deviceType = value;
      } else if (tag === 'serviceType') {
        currentService = value;
      } else if (tag === 'controlURL') {
        if (currentService.includes('AVTransport') && avControl.length === 0) {
          avControl = value;
        }
        if (currentService.includes('RenderingControl') && volumeControl.length === 0) {
          volumeControl = value;
        }
      }
      m = tagRegex.exec(xml);
    }

    // 没有 AVTransport 的（比如纯纯的网关/路由器）直接丢掉
    if (avControl.length === 0) {
      return null;
    }
    if (deviceType.length > 0 && !deviceType.includes('MediaRenderer')) {
      return null;
    }

    const device: DlnaDevice = new DlnaDevice();
    device.name = friendlyName.length > 0
      ? friendlyName
      : (modelName.length > 0 ? modelName : '未知设备');
    device.model = modelName;
    device.location = location;
    device.controlUrl = DlnaClient.absolute(location, avControl);
    device.volumeUrl = volumeControl.length > 0 ? DlnaClient.absolute(location, volumeControl) : '';
    return device;
  }

  private static absolute(location: string, path: string): string {
    if (path.toLowerCase().startsWith('http')) {
      return path;
    }
    if (path.startsWith('//')) {
      // 协议相对：沿用 location 的协议
      const schemeEnd: number = location.indexOf('://');
      return schemeEnd >= 0 ? location.substring(0, schemeEnd + 1) + path : path;
    }
    if (path.startsWith('/')) {
      const schemeEnd: number = location.indexOf('://');
      if (schemeEnd >= 0) {
        const after: string = location.substring(schemeEnd + 3);
        const slash: number = after.indexOf('/');
        return schemeEnd >= 0
          ? location.substring(0, schemeEnd + 3) + (slash >= 0 ? after.substring(0, slash) : after) + path
          : location + path;
      }
    }
    // 相对路径：去掉文件名部分再拼
    const slash: number = location.lastIndexOf('/');
    return slash >= 0 ? location.substring(0, slash + 1) + path : location + '/' + path;
  }

  private static headerValue(raw: string, key: string): string | null {
    const lines: string[] = raw.split('\n');
    for (const line of lines) {
      const clean: string = line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
      const idx: number = clean.indexOf(':');
      if (idx > 0 && clean.substring(0, idx).trim().toLowerCase() === key.toLowerCase()) {
        return clean.substring(idx + 1).trim();
      }
    }
    return null;
  }

  private static decodeText(buf: ArrayBuffer): string {
    const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
    return decoder.decodeToString(new Uint8Array(buf));
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: (v: void) => void): void => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }

  // ---------------------------------------------------------------- 控制

  /** 把音频地址推给音箱并开始播放 */
  static async play(device: DlnaDevice, audioUrl: string, title: string,
    mime: string = 'audio/mpeg'): Promise<void> {
    logInfo(TAG, `play() url=${audioUrl}`);
    logInfo(TAG, `play() mime=${mime} title=${title} device=${device.name}`);
    const metadata: string = DlnaClient.didl(title, audioUrl, mime);
    await DlnaClient.soap(device, 'SetAVTransportURI',
      '<InstanceID>0</InstanceID>' +
      `<CurrentURI>${DlnaClient.escape(audioUrl)}</CurrentURI>` +
      `<CurrentURIMetaData>${DlnaClient.escape(metadata)}</CurrentURIMetaData>`);
    await DlnaClient.soap(device, 'Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
    logInfo(TAG, 'play() SetAVTransportURI + Play 都返回 200');
  }

  static async pause(device: DlnaDevice): Promise<void> {
    await DlnaClient.soap(device, 'Pause', '<InstanceID>0</InstanceID>');
  }

  static async stop(device: DlnaDevice): Promise<void> {
    await DlnaClient.soap(device, 'Stop', '<InstanceID>0</InstanceID>');
  }

  /** 拖动进度：AVTransport 的 Seek，Unit=REL_TIME 表示「跳到第几秒」 */
  static async seek(device: DlnaDevice, positionMs: number): Promise<void> {
    await DlnaClient.soap(device, 'Seek',
      '<InstanceID>0</InstanceID><Unit>REL_TIME</Unit>' +
      `<Target>${DlnaClient.msToTime(positionMs)}</Target>`);
  }

  /** 恢复播放（部分音箱没有 Pause，走 Play 也能继续） */
  static async resume(device: DlnaDevice): Promise<void> {
    await DlnaClient.soap(device, 'Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
  }

  // ---------------------------------------------------------------- 状态 / 音量

  /** 读当前播放状态与进度：轮询它就知道这首放完没有，好接着推下一首 */
  static async transport(device: DlnaDevice): Promise<DlnaTransport> {
    const stateXml: string = await DlnaClient.soap(device, 'GetTransportInfo', '<InstanceID>0</InstanceID>');
    let positionXml: string = '';
    try {
      positionXml = await DlnaClient.soap(device, 'GetPositionInfo', '<InstanceID>0</InstanceID>');
    } catch (err) {
      positionXml = '';
    }
    const t: DlnaTransport = new DlnaTransport();
    t.state = DlnaClient.tagValue(stateXml, 'CurrentTransportState');
    t.positionMs = DlnaClient.timeToMs(DlnaClient.tagValue(positionXml, 'RelTime'));
    t.durationMs = DlnaClient.timeToMs(DlnaClient.tagValue(positionXml, 'TrackDuration'));
    return t;
  }

  /**
   * 读音箱当前正在播放的媒体 URI（GetMediaInfo 的 CurrentURI）。
   * 用途：判断音箱现在放的是不是我们推的流 —— 用户可能对小爱音箱语音点歌，
   * 这时不能把状态翻转误判成「我们这首放完了」而自动推下一首去抢播。
   * 返回的是 XML 转义过的原文，调用方自行反转义后再比较。
   */
  static async mediaUri(device: DlnaDevice): Promise<string> {
    const xml: string = await DlnaClient.soap(device, 'GetMediaInfo', '<InstanceID>0</InstanceID>');
    return DlnaClient.tagValue(xml, 'CurrentURI');
  }

  /** 音箱当前音量（0..100）；设备没开 RenderingControl 时返回 -1 */
  static async getVolume(device: DlnaDevice): Promise<number> {
    if (!device.volumeSupported()) {
      return -1;
    }
    try {
      const xml: string = await DlnaClient.soap(device, 'GetVolume',
        '<InstanceID>0</InstanceID><Channel>Master</Channel>',
        RENDERING_CONTROL, device.volumeUrl);
      const raw: string = DlnaClient.tagValue(xml, 'CurrentVolume');
      const v: number = parseInt(raw, 10);
      return isNaN(v) ? -1 : v;
    } catch (err) {
      return -1;
    }
  }

  /** 调音箱音量：投送时手机的实体音量键管不到音箱，只能走这个 */
  static async setVolume(device: DlnaDevice, percent: number): Promise<void> {
    if (!device.volumeSupported()) {
      throw new DlnaException('这台设备不允许 App 调音量');
    }
    const clamped: number = Math.max(0, Math.min(100, Math.trunc(percent)));
    await DlnaClient.soap(device, 'SetVolume',
      '<InstanceID>0</InstanceID><Channel>Master</Channel>' +
      `<DesiredVolume>${clamped}</DesiredVolume>`,
      RENDERING_CONTROL, device.volumeUrl);
  }

  // ---------------------------------------------------------------- 内部

  /** 还原 XML 转义（设备描述友好名 / GetMediaInfo 回来的 CurrentURI 都可能是转义原文） */
  static unescapeXml(s: string): string {
    return s.replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'")
      .replace(/&amp;/g, '&');
  }

  private static tagValue(xml: string, name: string): string {
    const regex: RegExp = new RegExp(`<${name}>([\\s\\S]*?)</${name}>`);
    const m: RegExpExecArray | null = regex.exec(xml);
    return m !== null ? m[1].trim() : '';
  }

  /** 毫秒 → UPnP 的时间格式 H:MM:SS */
  private static msToTime(ms: number): string {
    const total: number = Math.trunc(Math.max(0, ms) / 1000);
    const h: number = Math.trunc(total / 3600);
    const m: number = Math.trunc((total % 3600) / 60);
    const sec: number = total % 60;
    const mm: string = m < 10 ? `0${m}` : String(m);
    const ss: string = sec < 10 ? `0${sec}` : String(sec);
    return `${h}:${mm}:${ss}`;
  }

  /** UPnP 的时长格式是 H:MM:SS(.mmm)，按「从右往左、每段乘 60」解析最省事 */
  private static timeToMs(raw: string): number {
    const value: string = raw.trim();
    if (value.length === 0 || value.startsWith('NOT_IMPLEMENTED')) {
      return 0;
    }
    let seconds: number = 0;
    let weight: number = 1;
    const parts: string[] = value.split(':').reverse();
    for (const part of parts) {
      const n: number = parseFloat(part);
      if (!isNaN(n)) {
        seconds += n * weight;
      }
      weight *= 60;
    }
    return Math.trunc(seconds * 1000);
  }

  private static async soap(device: DlnaDevice, action: string, body: string,
    service: string = AV_TRANSPORT, target: string = device.controlUrl): Promise<string> {
    const envelope: string = '<?xml version="1.0" encoding="utf-8"?>' +
      `<s:Envelope xmlns:s="${SOAP_ENV}" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">` +
      `<s:Body><u:${action} xmlns:u="${service}">${body}</u:${action}></s:Body></s:Envelope>`;
    const headers: Record<string, string> = {
      'SOAPACTION': `"${service}#${action}"`
    };
    let reply: Reply | null = null;
    try {
      reply = await post(target, envelope, 'text/xml; charset="utf-8"', headers, TimeoutTier.NORMAL);
    } catch (err) {
      const e: Error = err as Error;
      throw new DlnaException(e.message.length > 0 ? e.message : '设备没响应');
    }
    const resp: Reply = reply as Reply;
    if (!resp.isSuccessful()) {
      // UPnP 的错误都放在 errorDescription 里
      const reasonRegex: RegExp = /<errorDescription>([\s\S]*?)<\/errorDescription>/;
      const rm: RegExpExecArray | null = reasonRegex.exec(resp.body);
      const reason: string = rm !== null ? rm[1].trim() : '';
      logWarn(TAG, `${action} -> HTTP ${resp.code} reason=${reason}`);
      if (resp.code === 500 && reason.length > 0) {
        throw new DlnaException(`${reason}（HTTP 500）`);
      }
      if (resp.code === 500) {
        throw new DlnaException('设备拒绝了这次投送（HTTP 500）');
      }
      throw new DlnaException(`投送失败（HTTP ${resp.code}）`);
    }
    return resp.body;
  }

  private static didl(title: string, audioUrl: string, mime: string): string {
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" ' +
      'xmlns:dc="http://purl.org/dc/elements/1.1/" ' +
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">' +
      '<item id="1" parentID="0" restricted="1">' +
      `<dc:title>${DlnaClient.escape(title)}</dc:title>` +
      '<upnp:class>object.item.audioItem.musicTrack</upnp:class>' +
      `<res protocolInfo="http-get:*:${mime}:*">${DlnaClient.escape(audioUrl)}</res>` +
      '</item></DIDL-Lite>';
  }

  private static escape(value: string): string {
    return value.replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&apos;');
  }
}
