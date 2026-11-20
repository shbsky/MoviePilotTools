import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppTheme, Palette } from '../../common/Theme';
import { ServerType, ServerConfig, AddTorrentOptions } from '../../model/Models';
import { AppState, AppViewModel } from '../../vm/AppViewModel';
import { ToastHub } from '../../vm/StoreBase';
import { DialogHost, SelectChip } from '../components/Common';

/**
 * 新增下载（对应安卓 ui/transfers/TorrentAddScreen.kt）。
 *
 * v1.0.11 改版：NavDestination 整页 → 居中弹窗（同「设置 → 音乐服务」那套 DialogHost）。
 * 之前整页时表单下部一大片空白，提交键孤零零吊在右上角；现在高度按内容收缩、按钮行固定在底部。
 *
 * 两种来源：URL/磁力 ↔ 本地 .torrent（读文件后校验 bencode 首字节 'd'，10MB 上限）。
 * qB 额外支持重命名、分类、自动种子管理、跳过哈希校验；TR 只认保存位置。
 * Cookie 只对 http 直链有意义：tr/qb 的 RPC 都没有单任务 Cookie 字段，
 * 带 Cookie 的直链由 App 自己先抓 .torrent 再交给下载器。
 */

enum SourceKind {
  URL,
  FILE
}

const MAX_TORRENT_BYTES: number = 10 * 1024 * 1024;

@Component
export struct AddTorrentDialog {
  @Consume('oiiTheme') theme: AppTheme;
  /** 由父组件传入的默认下载器（当前正在看的这台） */
  initialServerId: string = '';
  onClose: () => void = (): void => {
  };
  private vm: AppViewModel = AppViewModel.getInstance();
  @State state: AppState = new AppState();

  @State serverId: string = '';
  @State kind: SourceKind = SourceKind.URL;
  @State urlText: string = '';
  @State fileName: string = '';
  @State fileBytes: ArrayBuffer | null = null;
  @State savePath: string = '';
  @State cookie: string = '';
  @State rename: string = '';
  @State categoryIndex: number = 0;
  @State categories: string[] = [];
  @State autoTMM: boolean = false;
  @State skipChecking: boolean = false;
  @State submitting: boolean = false;
  @State error: string = '';

  private listener: () => void = (): void => {
    this.state = this.vm.state;
  };

  aboutToAppear(): void {
    this.vm.subscribe(this.listener);
    this.state = this.vm.state;
    if (this.initialServerId.length > 0) {
      this.serverId = this.initialServerId;
    } else if (this.state.activeServerId !== null) {
      this.serverId = this.state.activeServerId;
    } else if (this.state.servers.length > 0) {
      this.serverId = this.state.servers[0].id;
    }
    this.savePath = this.state.lastSavePath;
    this.loadCategories();
  }

  aboutToDisappear(): void {
    this.vm.unsubscribe(this.listener);
  }

  private server(): ServerConfig | null {
    return this.state.serverById(this.serverId);
  }

  private isQb(): boolean {
    const s: ServerConfig | null = this.server();
    return s !== null && s.type === ServerType.QBITTORRENT;
  }

  private loadCategories(): void {
    if (!this.isQb() || this.serverId.length === 0) {
      return;
    }
    this.vm.listCategories(this.serverId).then((list: string[]): void => {
      this.categories = list;
    }).catch((): void => {
      this.categories = [];
    });
  }

  private pickFile(): void {
    try {
      const ctx: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.torrent'];
      documentPicker.select(options).then((uris: Array<string>): void => {
        if (uris.length === 0) {
          return;
        }
        this.readTorrent(uris[0]);
      }).catch((err: BusinessError): void => {
        // 用户取消不算错误
        if (err.code !== 13900042) {
          this.error = `选择文件失败：${err.message}`;
        }
      });
    } catch (err) {
      this.error = '打开文件选择器失败';
    }
  }

  private readTorrent(uri: string): void {
    try {
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const info = fs.statSync(file.fd);
      if (info.size <= 0) {
        fs.closeSync(file);
        this.error = '文件是空的';
        return;
      }
      if (info.size > MAX_TORRENT_BYTES) {
        fs.closeSync(file);
        this.error = '文件超过 10MB，确认选的是 .torrent 吗？';
        return;
      }
      const buffer: ArrayBuffer = new ArrayBuffer(info.size);
      const read: number = fs.readSync(file.fd, buffer);
      fs.closeSync(file);
      if (read <= 0) {
        this.error = '读取文件失败';
        return;
      }
      const bytes: Uint8Array = new Uint8Array(buffer);
      // bencode 字典一定以 'd' 开头：用它挡掉选错文件
      if (bytes[0] !== 0x64) {
        this.error = '这不是合法的 .torrent 文件（bencode 头不对）';
        return;
      }
      this.fileBytes = buffer;
      const slash: number = uri.lastIndexOf('/');
      this.fileName = slash >= 0 ? uri.substring(slash + 1) : uri;
      this.error = '';
    } catch (err) {
      this.error = '读取文件失败';
    }
  }

  private canSubmit(): boolean {
    if (this.submitting || this.serverId.length === 0) {
      return false;
    }
    if (this.kind === SourceKind.URL) {
      return this.urlText.trim().length > 0;
    }
    return this.fileBytes !== null;
  }

  private submit(): void {
    if (!this.canSubmit()) {
      return;
    }
    const opts: AddTorrentOptions = new AddTorrentOptions();
    opts.savePath = this.savePath.trim();
    opts.paused = false;
    opts.autoTMM = this.autoTMM;
    opts.skipChecking = this.skipChecking;
    if (this.isQb()) {
      opts.rename = this.rename.trim();
      if (this.categoryIndex > 0 && this.categoryIndex <= this.categories.length) {
        opts.category = this.categories[this.categoryIndex - 1];
      }
    }
    this.submitting = true;
    this.error = '';
    let job: Promise<void>;
    if (this.kind === SourceKind.FILE && this.fileBytes !== null) {
      job = this.vm.addTorrentByFile(this.serverId, this.fileBytes, this.fileName, opts);
    } else if (this.cookie.trim().length > 0) {
      job = this.vm.addTorrentWithCookie(this.serverId, this.urlText, this.cookie, opts);
    } else {
      job = this.vm.addTorrentByUrl(this.serverId, this.urlText, opts);
    }
    job.then((): void => {
      this.submitting = false;
      this.vm.refreshNow();
      // 成功不再单开一个「已添加下载」弹窗（还要再点一次关闭），直接关窗 + Toast
      this.onClose();
      ToastHub.getInstance().show('已添加下载，去任务列表看进度');
    }).catch((e: Error): void => {
      this.submitting = false;
      this.error = this.humanize(e);
    });
  }

  private humanize(e: Error): string {
    const msg: string = e.message.length > 0 ? e.message : '添加失败';
    if (msg.indexOf('failed to connect') >= 0) {
      return '连不上下载器，检查地址与网络';
    }
    if (msg.indexOf('timeout') >= 0 || msg.indexOf('超时') >= 0) {
      return '提交超时：下载器可能已收到，去任务列表看看';
    }
    return msg;
  }

  build() {
    DialogHost({
      visible: true,
      title: '新增下载',
      confirmText: this.submitting ? '提交中…' : '提交',
      busy: this.submitting,
      confirmDisabled: !this.canSubmit(),
      contentMaxHeight: 420,
      onCancel: (): void => {
        if (!this.submitting) {
          this.onClose();
        }
      },
      onConfirm: (): void => {
        this.submit();
      }
    }) {
      this.Content()
    }
  }

  @Builder
  Content() {
    Column() {
      // ---- 下载器 ----
      this.Label('下载器')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.state.servers, (s: ServerConfig): void => {
          SelectChip({
            label: s.displayName(),
            active: this.serverId === s.id,
            onTap: (): void => {
              this.serverId = s.id;
              this.categoryIndex = 0;
              this.categories = [];
              this.loadCategories();
            }
          })
        }, (s: ServerConfig): string => `sv-${s.id}-${this.serverId === s.id ? 1 : 0}`)
      }
      .width('100%')

      // ---- 来源 ----
      this.Label('来源')
      Row() {
        SelectChip({
          label: 'URL / 磁力',
          active: this.kind === SourceKind.URL,
          onTap: (): void => {
            this.kind = SourceKind.URL;
          }
        })
        SelectChip({
          label: '本地种子文件',
          active: this.kind === SourceKind.FILE,
          onTap: (): void => {
            this.kind = SourceKind.FILE;
          }
        })
      }
      .width('100%')

      if (this.kind === SourceKind.URL) {
        TextArea({ text: this.urlText, placeholder: '粘贴磁力链接或 http(s) 直链，可一行一个' })
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.textPrimary)
          .placeholderColor(this.theme.colors.textSecondary)
          .placeholderFont({ size: this.theme.fs(12) })
          .backgroundColor(this.theme.colors.background)
          .borderRadius(10)
          .height(88)
          .margin({ top: 6 })
          .onChange((v: string): void => {
            this.urlText = v;
          })
      } else {
        Row() {
          Text(this.fileBytes !== null ? `📄 ${this.fileName}` : '📄 选择一个 .torrent 文件')
            .fontSize(this.theme.fs(12))
            .fontColor(this.fileBytes !== null ? this.theme.colors.textPrimary
              : this.theme.colors.textSecondary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('选择')
            .fontSize(this.theme.fs(12))
            .fontColor(Palette.blue)
        }
        .width('100%')
        .padding(12)
        .borderRadius(10)
        .backgroundColor(this.theme.colors.background)
        .margin({ top: 6 })
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          this.pickFile();
        })
      }

      // ---- 保存位置 ----
      this.Label('保存位置（留空 = 下载器默认目录）')
      TextInput({ text: this.savePath, placeholder: '例如 /downloads/电影' })
        .fontSize(this.theme.fs(13))
        .fontColor(this.theme.colors.textPrimary)
        .placeholderColor(this.theme.colors.textSecondary)
        .placeholderFont({ size: this.theme.fs(13) })
        .backgroundColor(this.theme.colors.background)
        .borderRadius(10)
        .height(38)
        .onChange((v: string): void => {
          this.savePath = v;
        })

      // ---- Cookie（仅 URL） ----
      if (this.kind === SourceKind.URL) {
        this.Label('Cookie（可选，站点需要登录时才填）')
        TextInput({ text: this.cookie, placeholder: 'uid=xxx; pass=yyy' })
          .fontSize(this.theme.fs(13))
          .fontColor(this.theme.colors.textPrimary)
          .placeholderColor(this.theme.colors.textSecondary)
          .placeholderFont({ size: this.theme.fs(13) })
          .backgroundColor(this.theme.colors.background)
          .borderRadius(10)
          .height(38)
          .onChange((v: string): void => {
            this.cookie = v;
          })
        Text('填了 Cookie 时 App 会先自己把 .torrent 抓下来再交给下载器')
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
          .margin({ top: 5 })
          .width('100%')
      }

      // ---- qB 专属 ----
      if (this.isQb()) {
        this.Label('重命名（可选）')
        TextInput({ text: this.rename, placeholder: '不改就留空' })
          .fontSize(this.theme.fs(13))
          .fontColor(this.theme.colors.textPrimary)
          .placeholderColor(this.theme.colors.textSecondary)
          .placeholderFont({ size: this.theme.fs(13) })
          .backgroundColor(this.theme.colors.background)
          .borderRadius(10)
          .height(38)
          .onChange((v: string): void => {
            this.rename = v;
          })

        this.Label('下载分类')
        Flex({ wrap: FlexWrap.Wrap }) {
          SelectChip({
            label: '不分类',
            active: this.categoryIndex === 0,
            onTap: (): void => {
              this.categoryIndex = 0;
            }
          })
          ForEach(this.categories, (c: string, idx: number): void => {
            SelectChip({
              label: c,
              active: this.categoryIndex === idx + 1,
              onTap: (): void => {
                this.categoryIndex = idx + 1;
              }
            })
          }, (c: string, idx: number): string => `cat-${idx}-${c}-${this.categoryIndex === idx + 1 ? 1 : 0}`)
        }
        .width('100%')

        Row() {
          Column() {
            Text('自动种子管理')
              .fontSize(this.theme.fs(13))
              .fontColor(this.theme.colors.textPrimary)
            Text('交给 qB 按分类规则自动管理路径')
              .fontSize(this.theme.fs(10))
              .fontColor(this.theme.colors.textSecondary)
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.autoTMM })
            .selectedColor(Palette.green)
            .onChange((on: boolean): void => {
              this.autoTMM = on;
            })
        }
        .width('100%')
        .padding({ top: 12, bottom: 2 })
        .alignItems(VerticalAlign.Center)

        Row() {
          Column() {
            Text('跳过哈希校验')
              .fontSize(this.theme.fs(13))
              .fontColor(this.theme.colors.textPrimary)
            Text('种子来自可信来源时可加快入列')
              .fontSize(this.theme.fs(10))
              .fontColor(this.theme.colors.textSecondary)
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.skipChecking })
            .selectedColor(Palette.orange)
            .onChange((on: boolean): void => {
              this.skipChecking = on;
            })
        }
        .width('100%')
        .padding({ top: 10, bottom: 2 })
        .alignItems(VerticalAlign.Center)
      }

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(this.theme.fs(11))
          .fontColor(Palette.red)
          .width('100%')
          .margin({ top: 10 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  Label(text: string) {
    Text(text)
      .fontSize(this.theme.fs(11))
      .fontColor(this.theme.colors.textSecondary)
      .width('100%')
      .margin({ top: 13, bottom: 6 })
  }
}
