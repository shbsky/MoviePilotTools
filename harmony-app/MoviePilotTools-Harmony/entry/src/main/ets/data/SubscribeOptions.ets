/**
 * 订阅设置里的固定选项表，取值与 MoviePilot 前端 `api/constants.ts` 一致。
 *
 * MP 存的是**正则字符串**（例如质量「蓝光原盘」），界面上只显示中文名，
 * 提交时把值原样带回去，两边数据完全通用。
 */

export class SubscribeOption {
  label: string = '';
  value: string = '';

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

export class SubscribeOptions {
  static quality(): SubscribeOption[] {
    return [
      new SubscribeOption('全部', ''),
      new SubscribeOption('蓝光原盘', 'Blu-?Ray.+VC-?1|Blu-?Ray.+AVC|UHD.+blu-?ray.+HEVC|MiniBD'),
      new SubscribeOption('Remux', 'Remux'),
      new SubscribeOption('BluRay', 'Blu-?Ray'),
      new SubscribeOption('UHD', 'UHD|UltraHD'),
      new SubscribeOption('WEB-DL', 'WEB-?DL|WEB-?RIP'),
      new SubscribeOption('HDTV', 'HDTV'),
      new SubscribeOption('H265', '[Hx].?265|HEVC'),
      new SubscribeOption('H264', '[Hx].?264|AVC')
    ];
  }

  static resolution(): SubscribeOption[] {
    return [
      new SubscribeOption('全部', ''),
      new SubscribeOption('4k', '4K|2160p|x2160'),
      new SubscribeOption('1080p', '1080[pi]|x1080'),
      new SubscribeOption('720p', '720[pi]|x720')
    ];
  }

  static effect(): SubscribeOption[] {
    return [
      new SubscribeOption('全部', ''),
      new SubscribeOption('杜比视界', 'Dolby[\\s.]+Vision|DOVI|[\\s.]+DV[\\s.]+'),
      new SubscribeOption('杜比全景声', 'Dolby[\\s.]*\\+?Atmos|Atmos'),
      new SubscribeOption('HDR', '[\\s.]+HDR[\\s.]+|HDR10|HDR10\\+'),
      new SubscribeOption('SDR', '[\\s.]+SDR[\\s.]+')
    ];
  }

  /** 界面显示名：认不出的自定义值原样显示（MP 网页里手填过的老数据） */
  static labelOf(options: SubscribeOption[], value: string): string {
    for (const opt of options) {
      if (opt.value === value) {
        return opt.label;
      }
    }
    return value.length > 0 ? value : '全部';
  }
}
