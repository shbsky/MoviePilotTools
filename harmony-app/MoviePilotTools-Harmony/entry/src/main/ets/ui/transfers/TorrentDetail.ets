import { AppTheme, Metrics, Palette, withAlpha } from '../../common/Theme';
import {
  formatBytes, formatStorageSize, formatPercent, formatDurationCN, formatDateTime,
  extractResolutionBadge, formatRatio
} from '../../common/Format';
import { TorrentStatus, TorrentTask, torrentStatusLabel } from '../../model/Models';
import { AppViewModel, TorrentAction } from '../../vm/AppViewModel';
import { MpViewModel } from '../../vm/MpViewModel';
import { PosterImage } from '../components/PosterImage';
import { DividerLine, TinyPill, DialogHost } from '../components/Common';

/**
 * 任务详情（对应安卓 ui/transfers/TorrentDetailScreen.kt）。
 *
 * 弹窗 → 整页。用户要求「只读/浏览类面板改回全屏」，真正改数据的地方
 * （重命名 / 保存位置 / 限速 / 分享率 / Tracker）才继续用 DialogHost 弹窗。
 * 这里是整页：顶栏（返回 + 任务详情 + 下载器名）+ 可滚内容。
 * 删除确认仍是弹窗 —— 那是改动数据的二次确认，弹窗更符合习惯。
 */

@Component
export struct TorrentDetailPage {
  @Consume('oiiTheme') theme: AppTheme;
  /** 由父组件在打开时传入（组件在 if 分支内创建，每次打开都是新实例） */
  task: TorrentTask = new TorrentTask();
  onClose: () => void = (): void => {
  };
  /** 删除成功后回调父级：任务已经没了，上一层操作弹窗也要一起收起 */
  onDeleted: () => void = (): void => {
  };
  private vm: AppViewModel = AppViewModel.getInstance();
  private mpVm: MpViewModel = MpViewModel.getInstance();
  @State serverName: string = '';
  @State confirmDelete: boolean = false;
  @State deleteFiles: boolean = false;
  /** 海报：按种子标题向 MP 识别接口反查，拿不到就用渐变 + 首字兜底 */
  @State poster: string = '';

  aboutToAppear(): void {
    const server = this.vm.state.serverById(this.task.serverId);
    this.serverName = server !== null ? server.displayName() : '';
    this.loadPoster();
  }

  /** 海报反查：MP 服务器没配 / 识别不到都静默失败，其余部分照常显示 */
  private loadPoster(): void {
    const title: string = this.task.name;
    if (title.length === 0) {
      return;
    }
    this.mpVm.posterForTitle(title).then((url: string): void => {
      if (url.length > 0) {
        this.poster = url;
      }
    });
  }

  private posterFallback(): boolean {
    return this.poster.length === 0;
  }

  private badgeText(): string {
    const b = extractResolutionBadge(this.task.name);
    return b !== null ? b.text : '';
  }

  private badgeArgb(): number {
    const b = extractResolutionBadge(this.task.name);
    return b !== null ? b.argb : 0;
  }

  build() {
    Stack() {
      // ---- 整页 ----
      Column() {
        this.Header()

        Scroll() {
          Column() {
            this.Content()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, bottom: 24 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        // Scroll 的 align 默认 Center，内容不足一屏时会被垂直居中
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.colors.background)
      .alignItems(HorizontalAlign.Start)

      // 删除二次确认（弹窗：改动数据的地方保持弹窗）
      DialogHost({
        visible: this.confirmDelete,
        title: '删除任务',
        confirmText: '删除',
        destructive: true,
        onCancel: (): void => {
          this.confirmDelete = false;
        },
        onConfirm: (): void => {
          this.confirmDelete = false;
          this.vm.performAction(this.task,
            this.deleteFiles ? TorrentAction.DELETE_WITH_FILES : TorrentAction.DELETE);
          this.onDeleted();
          this.onClose();
        }
      }) {
        this.DeleteConfirmContent()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 整页顶栏：圆形返回钮 + 标题 + 下载器名（与站点详情页同一套尺寸） */
  @Builder
  Header(): void {
    Row() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(18)
          .fontColor([this.theme.colors.textPrimary])
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor(this.theme.colors.card)
      .justifyContent(FlexAlign.Center)
      .onClick((): void => {
        this.onClose();
      })

      Blank().width(10)
      Column() {
        Text('任务详情')
          .fontSize(this.theme.fs(17))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.serverName.length > 0) {
          Text(this.serverName)
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  Content(): void {
    Column() {
      Row() {
        Stack() {
          if (!this.posterFallback()) {
            PosterImage({
              url: this.poster,
              onFailed: (): void => {
                this.poster = '';
              }
            })
          } else {
            Column()
              .width(62)
              .height(86)
              .borderRadius(8)
              .linearGradient({
                angle: 135,
                colors: [[0xFF2B4C7E, 0.0], [0xFF5E5CE6, 1.0]]
              })
            Text(this.task.name.length > 0 ? this.task.name.substring(0, 1).toUpperCase() : '?')
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(0xE6FFFFFF)
          }
          if (this.badgeText() !== '') {
            Text(this.badgeText())
              .fontSize(8)
              .fontWeight(FontWeight.Bold)
              .fontColor(0xFFFFFFFF)
              .backgroundColor(this.badgeArgb())
              .borderRadius(4)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          }
        }
        .width(62)
        .height(86)
        .borderRadius(8)
        .clip(true)
        .alignContent(Alignment.TopStart)

        Blank().width(11)
        Column() {
          Text(this.task.name)
            .fontSize(this.theme.fs(14))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(this.theme.fs(19))
            // 种子名常是「[字幕组] The.Silent.Storm.2026.S01.2160p...」这种无空格长串：
            // 默认 NORMAL 只认空格断行，整串被推到下一行 → 首行只剩两个字符。
            // BREAK_ALL 允许任意字符断行，每行填满、不再出现「[合 / 雨]」式的难看断行。
            .wordBreak(WordBreak.BREAK_ALL)
            .width('100%')
          Blank().height(7)
          Row() {
            TinyPill({
              text: torrentStatusLabel(this.task.status),
              bgColor: withAlpha(this.task.accentColor(), 0x29),
              fgColor: this.task.accentColor()
            })
            Blank().width(5)
            TinyPill({
              text: formatPercent(this.task.progress),
              bgColor: this.theme.colors.background,
              fgColor: this.theme.colors.textSecondary
            })
            if (this.serverName.length > 0) {
              Blank().width(5)
              TinyPill({
                text: this.serverName,
                bgColor: 0x240A84FF,
                fgColor: Palette.blue
              })
            }
          }
          .alignItems(VerticalAlign.Center)
          Blank().height(6)
          Text(this.task.trackerHost.length > 0 ? this.task.trackerHost : '未知 Tracker')
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 操作排放在简报之前：弹窗内容区要滚动，按钮跟内容一起滚下去就找不到了
      Blank().height(10)
      this.ActionRow()
      Blank().height(12)

      Text('数据简报')
        .fontSize(this.theme.fs(12))
        .fontColor(this.theme.colors.textSecondary)
      Blank().height(6)

      // 明细块：整页底色是 background，所以块用 card 色才看得出是一张卡
      Column() {
        if (this.task.taxonomyTags().length > 0 || this.task.category.length > 0) {
          Row() {
            Text('分类 / 标签')
              .fontSize(this.theme.fs(12))
              .fontColor(this.theme.colors.textSecondary)
            Blank().width(10)
            Row() {
              if (this.task.category.length > 0) {
                TinyPill({ text: this.task.category, bgColor: 0x2434C759, fgColor: Palette.green })
              }
              ForEach(this.task.tags.slice(0, 2), (t: string): void => {
                Blank().width(4)
                TinyPill({ text: t, bgColor: 0x24AF52DE, fgColor: Palette.purple })
              }, (t: string): string => t)
            }
            .justifyContent(FlexAlign.End)
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 10, bottom: 10 })
          .alignItems(VerticalAlign.Center)
          DividerLine()
        }

        this.InfoRow('速率',
          `↓ ${formatBytes(this.task.downloadSpeed)}/s   ↑ ${formatBytes(this.task.uploadSpeed)}/s`,
          this.theme.colors.textPrimary)
        DividerLine()
        this.InfoRow('流量',
          `↓${formatStorageSize(this.task.downloaded)}  ↑${formatStorageSize(this.task.uploaded)}`,
          this.theme.colors.textPrimary)
        DividerLine()
        this.InfoRow('分享率', formatRatio(this.task.ratio),
          this.task.ratio < 1.0 ? Palette.red : Palette.green)
        DividerLine()
        this.InfoRow('添加时间', formatDateTime(this.task.addedAt), this.theme.colors.textPrimary)
        DividerLine()
        this.InfoRow('完成时间',
          this.task.completedAt > 0 ? formatDateTime(this.task.completedAt) : '--',
          this.theme.colors.textPrimary)
        DividerLine()
        this.InfoRow('保存路径',
          this.task.savePath.length > 0 ? this.task.savePath : '--',
          this.theme.colors.textPrimary)
        DividerLine()
        this.InfoRow('文件大小', formatStorageSize(this.task.size), this.theme.colors.textPrimary)
        DividerLine()
        this.InfoRow('用户', `${this.task.numSeeds}/${this.task.numPeers}`,
          this.theme.colors.textPrimary)
        if (this.task.seedingSeconds > 0) {
          DividerLine()
          this.InfoRow('做种时长', formatDurationCN(this.task.seedingSeconds),
            this.theme.colors.textPrimary)
        }
        if (this.task.errorMessage.length > 0) {
          DividerLine()
          this.InfoRow('状态信息', this.task.errorMessage, Palette.red)
        }
      }
      .width('100%')
      .borderRadius(12)
      .backgroundColor(this.theme.colors.card)
      .padding({ left: 11, right: 11, top: 2, bottom: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 操作排：暂停/继续、校验、删除 */
  @Builder
  ActionRow(): void {
    Row() {
      this.ActionButton(this.task.status === TorrentStatus.PAUSED ? '继续' : '暂停',
        this.task.status === TorrentStatus.PAUSED ? '▶' : '⏸', Palette.blue, (): void => {
          this.vm.performAction(this.task,
            this.task.status === TorrentStatus.PAUSED ? TorrentAction.RESUME : TorrentAction.PAUSE);
        })
      Blank().width(8)
      this.ActionButton('校验', '⟳', Palette.orange, (): void => {
        this.vm.performAction(this.task, TorrentAction.RECHECK);
      })
      Blank().width(8)
      this.ActionButton('删除', '🗑', Palette.red, (): void => {
        this.confirmDelete = true;
      })
    }
    .width('100%')
    .margin({ top: 14 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  DeleteConfirmContent(): void {
    Column() {
      Text(`确定要删除「${this.task.name.substring(0, 40)}」吗？`)
        .fontSize(this.theme.fs(14))
        .fontColor(this.theme.colors.textPrimary)
      Blank().height(10)
      Row() {
        Column()
          .width(18)
          .height(18)
          .borderRadius(4)
          .borderWidth(1)
          .borderColor(this.theme.colors.separator)
          .backgroundColor(this.deleteFiles ? Palette.red : Color.Transparent)
        Blank().width(8)
        Text('同时删除已下载的文件')
          .fontSize(this.theme.fs(14))
          .fontColor(this.theme.colors.textPrimary)
      }
      .alignItems(VerticalAlign.Center)
      .onClick((): void => {
        this.deleteFiles = !this.deleteFiles;
      })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  InfoRow(label: string, value: string, valueColor: number): void {
    Row() {
      Text(label)
        .fontSize(this.theme.fs(12))
        .fontColor(this.theme.colors.textSecondary)
      Blank().width(12)
      Text(value)
        .fontSize(this.theme.fs(12))
        .fontColor(valueColor)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ActionButton(text: string, icon: string, tint: number, onTap: () => void): void {
    Row() {
      Text(icon).fontSize(13).fontColor(tint)
      Blank().width(4)
      Text(text)
        .fontSize(this.theme.fs(13))
        .fontWeight(FontWeight.Medium)
        .fontColor(tint)
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .borderRadius(10)
    .backgroundColor(withAlpha(tint, 0x1F))
    .padding({ top: 10, bottom: 10 })
    .onClick((): void => {
      onTap();
    })
  }
}
