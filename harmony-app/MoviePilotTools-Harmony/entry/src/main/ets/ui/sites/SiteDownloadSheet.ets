import { AppTheme, Palette, withAlpha } from '../../common/Theme';
import { MpResource, MpDownloader, MpSavePath } from '../../model/MpModels';
import { MpViewModel } from '../../vm/MpViewModel';
import { DialogHost, SelectChip } from '../components/Common';
import { ToastHub } from '../../vm/StoreBase';

/**
 * 投递到下载器（对应安卓 ui/sites/SiteDownloadSheet.kt）。
 *
 * v1.0.11：底部半屏面板 → 居中弹窗（统一走 DialogHost，样式与「音乐服务 / 添加下载器」一致）。
 * 以前从种子详情点「下载」会从底下抽出一个整宽面板，遮住半屏、顶部还留一块灰；
 * 现在改成毛玻璃居中卡片，高度按内容收缩，选项多时内容区自己滚。
 *
 * 上一次修的两个「点了没反应」：
 *  1. 下载器胶囊的 ForEach key 里没有选中态，ArkUI 认为项没变就不重建 → 底色不变。key 已带上选中态。
 *  2. 手选「手动」没填路径时点确认被静默拦掉 → 现在给明确 toast（并由 confirmDisabled 直接置灰）。
 */

enum SavePathMode {
  AUTO,
  PRESET,
  MANUAL
}

@Component
export struct SiteDownloadSheet {
  @Consume('oiiTheme') theme: AppTheme;
  @Link @Watch('onVisibleChanged') visible: boolean;
  @Link resource: MpResource | null;
  private vm: MpViewModel = MpViewModel.getInstance();

  @State downloaderIndex: number = 0;
  @State pathMode: SavePathMode = SavePathMode.AUTO;
  @State presetIndex: number = 0;
  @State manualPath: string = '';
  @State submitting: boolean = false;
  @State submitError: string = '';
  @State doneTaskId: string = '';

  aboutToAppear(): void {
    this.resetForm();
  }

  onVisibleChanged(): void {
    if (!this.visible) {
      return;
    }
    this.resetForm();
  }

  private resetForm(): void {
    this.downloaderIndex = 0;
    this.pathMode = SavePathMode.AUTO;
    this.presetIndex = 0;
    this.manualPath = '';
    this.submitError = '';
    this.doneTaskId = '';
    this.submitting = false;
    if (this.vm.state.savePaths.length === 0 || this.vm.state.downloaders.length === 0) {
      this.vm.loadDownloadOptions();
    }
  }

  private downloaderLabel(idx: number): string {
    if (idx === 0) {
      return '默认';
    }
    const list: MpDownloader[] = this.vm.state.downloaders;
    const i: number = idx - 1;
    return i >= 0 && i < list.length ? list[i].name : '默认';
  }

  private chosenDownloader(): string {
    return this.downloaderIndex === 0 ? '' : this.downloaderLabel(this.downloaderIndex);
  }

  private chosenSavePath(): string {
    if (this.pathMode === SavePathMode.PRESET) {
      const list: MpSavePath[] = this.vm.state.savePaths;
      if (this.presetIndex >= 0 && this.presetIndex < list.length) {
        return list[this.presetIndex].savePath;
      }
      return '';
    }
    if (this.pathMode === SavePathMode.MANUAL) {
      return this.manualPath.trim();
    }
    return '';
  }

  private canSubmit(): boolean {
    if (this.submitting) {
      return false;
    }
    if (this.pathMode === SavePathMode.MANUAL) {
      return this.manualPath.trim().length > 0;
    }
    return true;
  }

  /** 确认键文案跟着状态走：已推送 → 完成；失败 → 重试；提交中 → 转圈由 DialogHost 的 busy 处理 */
  private confirmLabel(): string {
    if (this.doneTaskId.length > 0) {
      return '完成';
    }
    if (this.submitting) {
      return '正在投递…';
    }
    return this.submitError.length > 0 ? '重试' : '确认投递';
  }

  private close(): void {
    this.visible = false;
    this.submitting = false;
    this.submitError = '';
    this.doneTaskId = '';
  }

  private onConfirmTap(): void {
    if (this.doneTaskId.length > 0) {
      this.close();
      return;
    }
    this.submit();
  }

  private submit(): void {
    const res: MpResource | null = this.resource;
    if (res === null) {
      ToastHub.getInstance().show('没有可投递的种子');
      return;
    }
    if (this.submitting) {
      return;
    }
    if (this.pathMode === SavePathMode.MANUAL && this.manualPath.trim().length === 0) {
      ToastHub.getInstance().show('先把保存路径填上，或选「自动」');
      return;
    }
    this.submitting = true;
    this.submitError = '';
    this.vm.submitDownload(res, this.chosenDownloader(), this.chosenSavePath())
      .then((id: string): void => {
        this.submitting = false;
        this.doneTaskId = id;
      })
      .catch((e: Error): void => {
        this.submitting = false;
        this.submitError = this.humanize(e);
      });
  }

  private humanize(e: Error): string {
    const msg: string = e.message.length > 0 ? e.message : '提交失败';
    if (msg.indexOf('timeout') >= 0 || msg.indexOf('超时') >= 0) {
      return '提交超时：下载器可能没响应，去下载器页面看看是否已入列';
    }
    if (msg.indexOf('failed to connect') >= 0) {
      return '连不上 MoviePilot，检查手机与服务器是否在同一网络';
    }
    return msg;
  }

  build() {
    DialogHost({
      visible: this.visible,
      title: '投递到下载器',
      subtitle: this.resource !== null ? this.resource.title : '',
      confirmText: this.confirmLabel(),
      cancelText: '取消',
      showCancel: this.doneTaskId.length === 0,
      busy: this.submitting,
      confirmDisabled: this.doneTaskId.length === 0 && !this.canSubmit(),
      contentMaxHeight: 320,
      onCancel: (): void => {
        this.close();
      },
      onConfirm: (): void => {
        this.onConfirmTap();
      }
    }) {
      this.Content()
    }
  }

  @Builder
  Content() {
    Column() {
      if (this.doneTaskId.length > 0) {
        Text('✓ 已推送到 MoviePilot，下载器开始下载')
          .fontSize(this.theme.fs(13))
          .fontColor(Palette.green)
          .width('100%')
        Text(`任务 ID：${this.doneTaskId}`)
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)
          .width('100%')
          .margin({ top: 6 })
      } else {
        this.SheetLabel('下载器')
        Flex({ wrap: FlexWrap.Wrap }) {
          SelectChip({
            label: '默认',
            active: this.downloaderIndex === 0,
            onTap: (): void => {
              this.downloaderIndex = 0;
            }
          })
          ForEach(this.vm.state.downloaders, (d: MpDownloader, idx: number): void => {
            SelectChip({
              label: d.name,
              active: this.downloaderIndex === idx + 1,
              onTap: (): void => {
                this.downloaderIndex = idx + 1;
              }
            })
            // key 带上选中态：否则 ForEach 认为项没变，不重建 → 点击后底色不变（看着像没反应）
          }, (d: MpDownloader, idx: number): string =>
            `dl-${idx}-${d.name}-${this.downloaderIndex === idx + 1 ? 1 : 0}`)
        }
        .width('100%')
        .margin({ top: 6 })

        this.SheetLabel('保存路径')
        Flex({ wrap: FlexWrap.Wrap }) {
          SelectChip({
            label: '自动',
            active: this.pathMode === SavePathMode.AUTO,
            onTap: (): void => {
              this.pathMode = SavePathMode.AUTO;
            }
          })
          ForEach(this.vm.state.savePaths, (p: MpSavePath, idx: number): void => {
            SelectChip({
              label: p.name,
              active: this.pathMode === SavePathMode.PRESET && this.presetIndex === idx,
              onTap: (): void => {
                this.pathMode = SavePathMode.PRESET;
                this.presetIndex = idx;
              }
            })
          }, (p: MpSavePath, idx: number): string =>
            `sp-${idx}-${p.savePath}-${this.pathMode === SavePathMode.PRESET && this.presetIndex === idx ? 1 : 0}`)
          SelectChip({
            label: '手动',
            active: this.pathMode === SavePathMode.MANUAL,
            onTap: (): void => {
              this.pathMode = SavePathMode.MANUAL;
            }
          })
        }
        .width('100%')
        .margin({ top: 6 })

        if (this.pathMode === SavePathMode.MANUAL) {
          TextInput({ text: this.manualPath, placeholder: '例如 /downloads 或 rclone:gd/影视' })
            .fontSize(this.theme.fs(12))
            .fontColor(this.theme.colors.textPrimary)
            .placeholderColor(this.theme.colors.textSecondary)
            .placeholderFont({ size: this.theme.fs(12) })
            .backgroundColor(withAlpha(this.theme.colors.textPrimary, 0x0F))
            .borderRadius(9)
            .height(38)
            .margin({ top: 4 })
            .onChange((v: string): void => {
              this.manualPath = v;
            })
        }

        if (this.submitError.length > 0) {
          Text(this.submitError)
            .fontSize(this.theme.fs(11))
            .fontColor(Palette.red)
            .lineHeight(this.theme.fs(16))
            .width('100%')
            .margin({ top: 10 })
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  SheetLabel(text: string) {
    Text(text)
      .fontSize(this.theme.fs(11))
      .fontColor(this.theme.colors.textSecondary)
      .width('100%')
      .margin({ top: 12 })
  }
}
