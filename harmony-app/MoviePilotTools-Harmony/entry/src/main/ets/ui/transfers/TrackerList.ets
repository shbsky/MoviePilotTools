import { AppTheme, Palette } from '../../common/Theme';
import { TorrentTask, TrackerEntry } from '../../model/Models';
import { AppViewModel } from '../../vm/AppViewModel';
import { BasicFieldMulti, DialogHost, FieldLabel } from '../components/Common';

/**
 * 种子操作弹窗的第二级：Tracker 列表（对应安卓 ui/transfers/TrackerDialog.kt）。
 *
 * 一条一条列出来，点某条进编辑（URL 可改 / 可删），底部可以「添加 Tracker」。
 * qB 的 DHT / PEX / LSD 伪 Tracker 也列出来，但标灰、不可点 —— 它们不是真 Tracker，
 * 改了也没用，不给点比点了没反应好。
 */
@Component
export struct TrackerListDialog {
  @Consume('oiiTheme') theme: AppTheme;
  /** 由调用方传入；组件在 if 分支内创建，每次打开都是新实例 */
  task: TorrentTask = new TorrentTask();
  onClose: () => void = (): void => {
  };

  private vm: AppViewModel = AppViewModel.getInstance();

  @State items: TrackerEntry[] = [];
  @State loading: boolean = true;
  @State error: string = '';
  /** 正在提交改 / 增 / 删 */
  @State busy: boolean = false;
  /** 正在编辑的条目；null 表示当前是列表态 */
  @State editing: TrackerEntry | null = null;
  /** 新增态（此时 editing 仍是 null，靠这个标记区分） */
  @State adding: boolean = false;
  @State input: string = '';

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.loading = true;
    this.error = '';
    this.vm.loadTrackers(this.task).then((list: TrackerEntry[]): void => {
      this.items = list;
      this.loading = false;
    }).catch((e: Error): void => {
      this.loading = false;
      this.error = e.message.length > 0 ? e.message : '读取 Tracker 失败';
    });
  }

  private realCount(): number {
    let n: number = 0;
    for (const e of this.items) {
      if (!e.special()) {
        n += 1;
      }
    }
    return n;
  }

  /** 状态色：工作中绿、更新中蓝、不工作红、已停用灰、未联系/未知橙 */
  private statusColor(status: number): number {
    switch (status) {
      case 2:
        return Palette.green;
      case 3:
        return Palette.blue;
      case 4:
        return Palette.red;
      case 0:
        return Palette.gray;
      default:
        return Palette.orange;
    }
  }

  private beginEdit(entry: TrackerEntry): void {
    this.error = '';
    this.input = entry.url;
    this.editing = entry;
    this.adding = false;
  }

  private beginAdd(): void {
    this.error = '';
    this.input = '';
    this.editing = null;
    this.adding = true;
  }

  private cancelEdit(): void {
    this.error = '';
    this.input = '';
    this.editing = null;
    this.adding = false;
  }

  private submit(): void {
    if (this.busy) {
      return;
    }
    const url: string = this.input.trim();
    if (url.length === 0) {
      this.error = 'Tracker 地址不能为空';
      return;
    }
    const entry: TrackerEntry | null = this.editing;
    this.error = '';
    this.busy = true;
    const job: Promise<void> = entry !== null
      ? this.vm.editTrackerEntry(this.task, entry, url)
      : this.vm.addTrackerEntry(this.task, url);
    job.then((): void => {
      this.busy = false;
      this.cancelEdit();
      this.reload();
    }).catch((e: Error): void => {
      this.busy = false;
      this.error = e.message.length > 0 ? e.message : '操作失败';
    });
  }

  private remove(): void {
    const entry: TrackerEntry | null = this.editing;
    if (entry === null || this.busy) {
      return;
    }
    this.error = '';
    this.busy = true;
    this.vm.removeTrackerEntry(this.task, entry).then((): void => {
      this.busy = false;
      this.cancelEdit();
      this.reload();
    }).catch((e: Error): void => {
      this.busy = false;
      this.error = e.message.length > 0 ? e.message : '操作失败';
    });
  }

  build() {
    Stack() {
      if (this.editing !== null || this.adding) {
        this.EditDialog()
      } else {
        this.ListDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  ListDialog() {
    DialogHost({
      visible: true,
      title: 'Tracker 列表',
      subtitle: this.task.name,
      confirmText: '关闭',
      showCancel: false,
      contentMaxHeight: 400,
      onCancel: (): void => {
        this.onClose();
      },
      onConfirm: (): void => {
        this.onClose();
      }
    }) {
      this.ListContent()
    }
  }

  @Builder
  ListContent() {
    Column() {
      // 概览行：条数 + 刷新
      Row() {
        Text(this.loading ? '正在读取…' : `共 ${this.realCount()} 条 Tracker`)
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)
          .layoutWeight(1)
        Text('刷新')
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.accent)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .onClick((): void => {
            if (!this.busy) {
              this.reload();
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.error.length > 0) {
        Blank().height(8)
        Text(this.error)
          .fontSize(this.theme.fs(11))
          .fontColor(Palette.red)
          .lineHeight(this.theme.fs(16))
      }

      if (this.items.length === 0 && !this.loading) {
        Blank().height(12)
        Text('这个种子还没有 Tracker。可以点下面「添加 Tracker」手动补一条。')
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.textSecondary)
          .lineHeight(this.theme.fs(17))
      }

      if (this.items.length > 0) {
        Blank().height(10)
        Column() {
          ForEach(this.items, (entry: TrackerEntry, index: number) => {
            if (index > 0) {
              Divider()
                .strokeWidth(0.5)
                .color(this.theme.colors.separator)
                .margin({ left: 34 })
            }
            this.TrackerRow(entry)
          }, (entry: TrackerEntry) => entry.url)
        }
        .width('100%')
        .borderRadius(10)
        .backgroundColor(this.theme.colors.background)
        .clip(true)
      }

      Blank().height(10)
      Row() {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(16)
          .fontColor([Palette.blue])
          .width(20)
        Blank().width(12)
        Text('添加 Tracker')
          .fontSize(this.theme.fs(14))
          .fontColor(this.theme.colors.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 13, bottom: 13 })
      .borderRadius(10)
      .backgroundColor(this.theme.colors.background)
      .alignItems(VerticalAlign.Center)
      .onClick((): void => {
        if (!this.busy) {
          this.beginAdd();
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  TrackerRow(entry: TrackerEntry) {
    Row() {
      Circle()
        .width(8)
        .height(8)
        .fill(entry.special() ? this.theme.colors.textSecondary : this.statusColor(entry.status))
        .opacity(entry.special() ? 0.4 : 1)
      Blank().width(12)
      Column() {
        Row() {
          Text(entry.host())
            .fontSize(this.theme.fs(13))
            .fontWeight(FontWeight.Medium)
            .fontColor(entry.special() ? this.theme.colors.textSecondary : this.theme.colors.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (!entry.special()) {
            Blank().width(6)
            Text(entry.statusText())
              .fontSize(this.theme.fs(10))
              .fontColor(this.statusColor(entry.status))
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(entry.url)
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })

        if (!entry.special() && (entry.seeds > 0 || entry.leeches > 0 || entry.peers > 0)) {
          Text(`种子 ${entry.seeds} · 用户 ${entry.leeches}${entry.peers > 0 ? ` · 已连 ${entry.peers}` : ''}`)
            .fontSize(this.theme.fs(10))
            .fontColor(this.theme.colors.textSecondary)
            .margin({ top: 2 })
        }
        if (!entry.special() && entry.message.length > 0) {
          Text(entry.message)
            .fontSize(this.theme.fs(10))
            .fontColor(Palette.red)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (!entry.special()) {
        Blank().width(8)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([this.theme.colors.textSecondary])
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 11, bottom: 11 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      if (!entry.special() && !this.busy) {
        this.beginEdit(entry);
      }
    })
  }

  @Builder
  EditDialog() {
    DialogHost({
      visible: true,
      title: this.adding ? '添加 Tracker' : '编辑 Tracker',
      subtitle: this.task.name,
      confirmText: '保存',
      // 编辑态给「取消」：改了一半想退出去，点遮罩不算明显
      cancelText: '取消',
      showCancel: true,
      busy: this.busy,
      confirmDisabled: this.input.trim().length === 0,
      contentMaxHeight: 300,
      onCancel: (): void => {
        if (!this.busy) {
          this.cancelEdit();
        }
      },
      onConfirm: (): void => {
        this.submit();
      }
    }) {
      this.EditContent()
    }
  }

  @Builder
  EditContent() {
    Column() {
      FieldLabel({ text: 'Tracker URL' })
      Blank().height(6)
      BasicFieldMulti({
        value: this.input,
        placeholder: 'https://…/announce.php?passkey=…',
        onValueChanged: (v: string): void => {
          this.input = v;
        }
      })
      Blank().height(6)
      Text('改完保存会立刻向新地址汇报；地址写错这条 Tracker 就会变成「不工作」。')
        .fontSize(this.theme.fs(10))
        .fontColor(this.theme.colors.textSecondary)
        .lineHeight(this.theme.fs(15))

      if (this.error.length > 0) {
        Blank().height(8)
        Text(this.error)
          .fontSize(this.theme.fs(11))
          .fontColor(Palette.red)
          .lineHeight(this.theme.fs(16))
      }

      if (this.editing !== null) {
        Blank().height(14)
        Row() {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(16)
            .fontColor([Palette.red])
            .width(20)
          Blank().width(10)
          Text('删除这条 Tracker')
            .fontSize(this.theme.fs(13))
            .fontColor(Palette.red)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 12, bottom: 12 })
        .borderRadius(10)
        .backgroundColor(this.theme.colors.background)
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          this.remove();
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
