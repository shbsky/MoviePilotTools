import { AppTheme, Palette, Metrics, withAlpha } from '../../common/Theme';
import {
  formatBytes, formatStorageSize, formatPercent, formatDurationCN, humanEta,
  formatRatio
} from '../../common/Format';
import {
  TorrentStatus, TorrentTask, torrentStatusLabel, ServerType, ServerConfig, ServerSnapshot
} from '../../model/Models';
import {
  AppViewModel, AppState, StatusFilter, statusFilterLabel, matchesStatusFilter, TorrentAction
} from '../../vm/AppViewModel';
import { EmptyHint, ThinProgress, DialogHost } from '../components/Common';
import { TaskEditDialog, TaskEditMode } from './TaskEditScreen';
import { TorrentDetailPage } from './TorrentDetail';
import { TrackerListDialog } from './TrackerList';
import { AddTorrentDialog } from './AddTorrentScreen';
import { ToastHub } from '../../vm/StoreBase';

/**
 * 下载器页面（对应安卓 ui/transfers/TransfersScreen.kt，重做版）
 *
 * 布局对齐 Transmission Remote / qBittorrent 官方客户端：
 *   顶栏（☰ 侧边栏 / 标题+在线点 / ⇄ 切换下载器 / 批量 / 备用限速 / 退出）
 * 顶栏四个操作按钮与安卓逐一对齐：图标用系统矢量符号（SymbolGlyph），不用 emoji。
 *   速度汇总行 → 任务卡片列表 → 右下「＋ 新增」与「⇅ 排序」两个圆钮
 * 状态筛选挪进侧边栏，避免和排序按钮重复（这正是 被吐槽的点）。
 * 所有操作都走 tr/qb 原生 RPC，不经 MoviePilot。
 */

export enum TaskSort {
  ADDED,
  NAME,
  SIZE,
  PROGRESS,
  DL_SPEED,
  UL_SPEED,
  RATIO
}

export function taskSortLabel(s: TaskSort): string {
  switch (s) {
    case TaskSort.ADDED:
      return '添加时间';
    case TaskSort.NAME:
      return '种子名称';
    case TaskSort.SIZE:
      return '文件大小';
    case TaskSort.PROGRESS:
      return '完成进度';
    case TaskSort.DL_SPEED:
      return '下载速度';
    case TaskSort.UL_SPEED:
      return '上传速度';
    case TaskSort.RATIO:
      return '分享比率';
    default:
      return '添加时间';
  }
}

/*
 * 种子操作整页的版式常量（集中一处好统一调）：
 * 卡片圆角 18、卡片间距 8（与安卓一致）、行高 52（图标块 38 + 上下各 7），
 * 参照用户给的设计稿 —— 每行之间加一条分隔线做区分；
 * 2026-11-23 用户反馈「行间距有点大，不好看」：padding 9→7，卡片间距 12→8。
 */
const CARD_RADIUS: number = 18;
const CARD_GAP: number = 8;
const ROW_ICON_SIZE: number = 38;
const ROW_VPAD: number = 7;

@Component
export struct TransfersPage {
  @Consume('oiiTheme') theme: AppTheme;
  @Consume('navStack') navStack: NavPathStack;
  private vm: AppViewModel = AppViewModel.getInstance();
  @State state: AppState = new AppState();
  @State focusServerId: string = '';
  @State drawerOpen: boolean = false;
  @State statusFilter: StatusFilter = StatusFilter.ALL;
  @State sortMode: TaskSort = TaskSort.ADDED;
  @State sortAsc: boolean = false;
  /** 备用限速是否开启（决定顶栏限速图标是橙色还是常规色，同安卓） */
  @State altSpeedOn: boolean = false;
  /** false = 本地乐观值还没被服务端快照确认，此时不让刷新把颜色刷回去 */
  @State altSpeedSynced: boolean = true;
  /** 切换请求在飞时忽略再次点击（连点会切过去又切回来） */
  @State altSpeedBusy: boolean = false;
  /** 点击备用限速的时刻：只有「这之后完成的刷新」才有资格否定乐观值 */
  private altSpeedClickAt: number = 0;

  // 批量操作面板
  @State batchOpen: boolean = false;
  @State batchDeleteMode: boolean = false;
  @State batchDeleteFiles: boolean = false;
  @State batchLocationMode: boolean = false;
  // 批量删除弹窗里勾选的任务（默认全选，对应安卓 BatchDeleteDialog）
  @State deleteChecked: string[] = [];
  @State movePathInput: string = '';
  @State busy: boolean = false;

  // 单任务面板
  @State actionTask: TorrentTask | null = null;
  // 单任务编辑弹窗（原来是全屏页，改成弹窗）
  @State editTask: TorrentTask | null = null;
  @State editMode: TaskEditMode = TaskEditMode.RENAME;
  // 任务详情弹窗（叠在单任务面板之上；关掉后回到面板，不掉回列表）
  @State detailTask: TorrentTask | null = null;
  /** Tracker 列表弹窗（与详情/编辑同级，打开时把操作弹窗藏起来） */
  @State trackerTask: TorrentTask | null = null;
  // 新增下载弹窗（原来是整页 NavDestination）
  @State addOpen: boolean = false;

  // 列表与统计缓存：build 里只读这些字段，避免每帧重复遍历/排序（几百个种子时会卡）
  @State taskList: TorrentTask[] = [];
  /** 当前下载器的任务总数（顶栏副标题用；以前错用了「所有服务器任务总和」） */
  @State serverTaskCount: number = 0;
  @State filterCounts: number[] = [];
  @State downSpeed: number = 0;
  @State upSpeed: number = 0;
  @State seedingCount: number = 0;
  @State downloadingCount: number = 0;
  /** 做种体积（侧边栏第二行用） */
  @State seedingBytes: number = 0;
  /** 侧边栏「总体积」= 当前下载器**全部**任务体积（安卓 DrawerPanel 口径，不受筛选影响） */
  @State serverTotalBytes: number = 0;
  @State totalRatio: number = 0;

  private listener: () => void = (): void => {
    this.rebuild();
  };

  aboutToAppear(): void {
    this.vm.subscribe(this.listener);
    this.rebuild();
    const focus: string = AppStorage.get<string>('downloadersFocusServer') ?? '';
    if (focus.length > 0) {
      this.focusServerId = focus;
      AppStorage.setOrCreate('downloadersFocusServer', '');
    } else if (this.state.activeServerId !== null) {
      this.focusServerId = this.state.activeServerId;
    }
    this.rebuild();
    this.vm.refreshNow();
  }

  aboutToDisappear(): void {
    this.vm.unsubscribe(this.listener);
  }

  /** 状态变了 / 筛选或排序变了才重算，build 里不再反复遍历 */
  private rebuild(): void {
    this.state = this.vm.state;
    this.taskList = this.tasks();
    this.recomputeStats();
    this.syncAltSpeed();
  }

  /**
   * 备用限速的真实状态来自服务器快照（每次刷新都会读一次）。
   * 点击后的乐观值先霸住颜色，**只有快照确认一致才交还**，否则等这一轮刷新落地后以服务器为准 ——
   * 之前是「点击成功就交还」，结果刷新还没回来就被上一轮的旧快照刷回去，颜色一会又变了。
   */
  private syncAltSpeed(): void {
    if (this.focusServerId.length === 0) {
      return;
    }
    const snap: ServerSnapshot | null = this.state.snapshotOf(this.focusServerId);
    if (snap === null) {
      return;
    }
    if (!snap.altSpeedKnown) {
      // 这一轮没读到（超时 / 接口报错）→ 保持现状，绝不当成「已关闭」去改颜色
      return;
    }
    if (this.altSpeedSynced) {
      this.altSpeedOn = snap.altSpeedEnabled;
      return;
    }
    if (snap.altSpeedEnabled === this.altSpeedOn) {
      // 服务器已确认，交还给快照
      this.altSpeedSynced = true;
      return;
    }
    if (this.state.lastRefreshStartedAt > this.altSpeedClickAt) {
      // 点击**之后才开始抓**的刷新仍然对不上（切换失败或被别处改回去），以服务器为准。
      // 用「开抓时间」而不是「落地时间」，才能排除「点击前就在跑、点击后才返回」的旧数据。
      this.altSpeedOn = snap.altSpeedEnabled;
      this.altSpeedSynced = true;
    }
  }

  /**
   * 一次遍历算完速度、做种数、总体积、分享率，外加各筛选项计数。
   * 口径对齐安卓：汇总/计数一律取「当前下载器全部任务」，不受状态筛选影响；
   * 只有顶栏的命中数取筛选后的 taskList（之前这里错用了命中数当总数）。
   */
  private recomputeStats(): void {
    const all: TorrentTask[] = this.serverTasks();
    this.serverTaskCount = all.length;
    let down: number = 0;
    let up: number = 0;
    let seeding: number = 0;
    let downloading: number = 0;
    let seedBytes: number = 0;
    let totalBytes: number = 0;
    let totalUp: number = 0;
    let totalDown: number = 0;
    for (const t of all) {
      down += t.downloadSpeed;
      up += t.uploadSpeed;
      totalUp += t.uploaded;
      totalDown += t.downloaded;
      totalBytes += t.size;
      if (t.status === TorrentStatus.SEEDING) {
        seeding++;
        seedBytes += t.size;
      } else if (t.status === TorrentStatus.DOWNLOADING || t.status === TorrentStatus.QUEUED) {
        downloading++;
      }
    }
    this.downSpeed = down;
    this.upSpeed = up;
    this.seedingCount = seeding;
    this.downloadingCount = downloading;
    this.seedingBytes = seedBytes;
    this.serverTotalBytes = totalBytes;
    this.totalRatio = totalDown > 0 ? totalUp / totalDown : 0;

    // 筛选项计数按「当前下载器」全量算，不受当前筛选影响
    const counts: number[] = [];
    for (const f of this.filterOptions()) {
      let n: number = 0;
      for (const t of all) {
        if (matchesStatusFilter(t, f)) {
          n++;
        }
      }
      counts.push(n);
    }
    this.filterCounts = counts;
  }

  private server(): ServerConfig | null {
    if (this.focusServerId.length > 0) {
      return this.state.serverById(this.focusServerId);
    }
    return null;
  }

  private isQb(): boolean {
    const s: ServerConfig | null = this.server();
    return s !== null && s.type === ServerType.QBITTORRENT;
  }

  private online(): boolean {
    const s: ServerConfig | null = this.server();
    if (s === null) {
      return false;
    }
    const snap = this.state.snapshotOf(s.id);
    return snap !== null && snap.online;
  }

  private title(): string {
    const s: ServerConfig | null = this.server();
    return s !== null ? s.displayName() : '全部下载器';
  }

  /** 本页只显示当前下载器的任务（下载器页是「某一台」的状态页） */
  private tasks(): TorrentTask[] {
    const out: TorrentTask[] = [];
    for (const t of this.state.tasks) {
      if (this.focusServerId.length > 0 && t.serverId !== this.focusServerId) {
        continue;
      }
      if (!matchesStatusFilter(t, this.statusFilter)) {
        continue;
      }
      out.push(t);
    }
    out.sort((a: TorrentTask, b: TorrentTask): number => {
      let cmp: number = 0;
      if (this.sortMode === TaskSort.NAME) {
        const an: string = a.name.toLowerCase();
        const bn: string = b.name.toLowerCase();
        cmp = an < bn ? -1 : (an > bn ? 1 : 0);
      } else if (this.sortMode === TaskSort.SIZE) {
        cmp = a.size - b.size;
      } else if (this.sortMode === TaskSort.PROGRESS) {
        cmp = a.progress - b.progress;
      } else if (this.sortMode === TaskSort.DL_SPEED) {
        cmp = a.downloadSpeed - b.downloadSpeed;
      } else if (this.sortMode === TaskSort.UL_SPEED) {
        cmp = a.uploadSpeed - b.uploadSpeed;
      } else if (this.sortMode === TaskSort.RATIO) {
        cmp = a.ratio - b.ratio;
      } else {
        cmp = a.addedAt - b.addedAt;
      }
      return this.sortAsc ? cmp : -cmp;
    });
    return out;
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.TopBar()
          this.SpeedRow()
          if (this.taskList.length === 0) {
            Column() {
              EmptyHint({
                text: this.state.servers.length === 0 ? '还没有添加下载器'
                  : (this.statusFilter === StatusFilter.ALL ? '暂无任务' : '没有符合筛选条件的任务')
              })
            }
            .layoutWeight(1)
          } else {
            List() {
              ForEach(this.taskList, (task: TorrentTask): void => {
                ListItem() {
                  this.TaskCard(task)
                }
                .margin({ bottom: 10 })
              }, (task: TorrentTask): string => task.id())
              ListItem() {
                Column() {
                  Blank().height(96)
                }
                .width('100%')
              }
            }
            .layoutWeight(1)
            .width('100%')
            .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
          }
        }
        .width('100%')
        .height('100%')

        // ---- 右下两个圆钮：新增 / 排序（整层透明，不挡列表滚动） ----
        Column() {
          Blank()
          Row() {
            // 注意：不要用 Circle()+shadow —— 阴影按正方形轮廓绘制，圆钮外面会多出一块方块
            Row() {
              SymbolGlyph($r('sys.symbol.plus'))
                .fontSize(22)
                .fontColor([Palette.blue])
            }
            .width(48)
            .height(48)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(this.theme.colors.card)
            .borderRadius(24)
            // 深色主题下「卡片色圆钮」压在卡片上几乎看不见（用户反馈）：加描边 + 更实的投影
            .border({ width: 1, color: this.fabBorder() })
            .shadow({ radius: 14, color: this.fabShadow(), offsetX: 0, offsetY: 4 })
            .onClick((): void => {
              this.addOpen = true;
            })

            Blank().width(12)

            Row() {
              SymbolGlyph($r('sys.symbol.sort'))
                .fontSize(19)
                .fontColor([this.theme.colors.textPrimary])
            }
            .width(48)
            .height(48)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(this.theme.colors.card)
            .borderRadius(24)
            .border({ width: 1, color: this.fabBorder() })
            .shadow({ radius: 14, color: this.fabShadow(), offsetX: 0, offsetY: 4 })
            .bindMenu(this.sortMenuItems())
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
          .padding({ right: 18, bottom: 26 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)

        // ---- 侧边栏 ----
        if (this.drawerOpen) {
          Row() {
            this.Drawer()
            Column()
              .layoutWeight(1)
              .height('100%')
              .backgroundColor(0x55000000)
              .onClick((): void => {
                this.drawerOpen = false;
              })
          }
          .width('100%')
          .height('100%')
        }

        // ---- 批量操作弹窗（含批量删除 / 更改保存位置两个子态） ----
        if (this.batchOpen) {
          this.BatchDialog()
        }

        // ---- 单任务操作页 ----
        // 只有「任务详情」是整页，打开时要把操作页藏掉（两个整页不能叠）。
        // 其余二级（重命名 / 保存位置 / 限速 / 分享率 / 分类 / 标签 / Tracker / 删除确认）
        // 都是 DialogHost 居中弹窗，**必须让操作页继续在下面当背景** —— 以前这里一起藏掉了，
        // 弹窗背后就露出种子列表（用户反馈：点更改保存位置背景跳回种子列表）。
        if (this.actionTask !== null && this.detailTask === null) {
          this.TaskActionPage(this.actionTaskValue())
        }

        // ---- Tracker 列表弹窗（叠在操作弹窗之上，关掉自然回到操作弹窗） ----
        if (this.trackerTask !== null) {
          TrackerListDialog({
            task: this.trackerTaskValue(),
            onClose: (): void => {
              this.trackerTask = null;
            }
          })
        }

        // ---- 任务详情弹窗（叠在操作弹窗之上，关掉自然回到操作弹窗） ----
        if (this.detailTask !== null) {
          TorrentDetailPage({
            task: this.detailTaskValue(),
            onDeleted: (): void => {
              // 任务已删除，上一层操作弹窗不能再留着
              this.actionTask = null;
            },
            onClose: (): void => {
              this.detailTask = null;
            }
          })
        }

        // ---- 单任务编辑弹窗（重命名 / 分类 / 标签 / 限速 / 分享率 / 保存位置） ----
        if (this.editTask !== null) {
          TaskEditDialog({
            task: this.editTaskValue(),
            mode: this.editMode,
            onSaved: (): void => {
              // 保存后立刻把 actionTask / detailTask 换成 state.tasks 里的最新对象，
              // 否则这两种弹窗持有的是旧快照，保存位置要退出重进才刷新。
              // refresh(false) 已在 ViewModel 的 afterEdit 里跑完，这里直接取最新值。
              const saved: TorrentTask | null = this.editTask;
              if (saved !== null) {
                const fresh: TorrentTask | undefined =
                  this.vm.state.tasks.find((t: TorrentTask): boolean => t.id() === saved.id());
                if (fresh !== undefined) {
                  this.actionTask = fresh;
                  if (this.detailTask !== null && this.detailTask.id() === fresh.id()) {
                    this.detailTask = fresh;
                  }
                }
              }
              // 注意：不清 actionTask，弹窗一关仍留在「种子操作」整页
            },
            onClose: (): void => {
              this.editTask = null;
            }
          })
        }

        // ---- 新增下载弹窗 ----
        if (this.addOpen) {
          AddTorrentDialog({
            initialServerId: this.focusServerId,
            onClose: (): void => {
              this.addOpen = false;
            }
          })
        }

      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.colors.background)
    }
    .hideTitleBar(true)
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.colors.background)
    // 返回键逐层关：设置 → 新增 → 详情 → 编辑 → 操作面板 → 批量子态 → 批量 → 侧边栏，最后才退出本页
    .onBackPressed((): boolean => {
      if (this.addOpen) {
        this.addOpen = false;
        return true;
      }
      if (this.detailTask !== null) {
        this.detailTask = null;
        return true;
      }
      if (this.editTask !== null) {
        this.editTask = null;
        return true;
      }
      if (this.trackerTask !== null) {
        this.trackerTask = null;
        return true;
      }
      if (this.actionTask !== null) {
        this.actionTask = null;
        return true;
      }
      if (this.batchDeleteMode) {
        this.batchDeleteMode = false;
        this.deleteChecked = [];
        return true;
      }
      if (this.batchLocationMode) {
        this.batchLocationMode = false;
        return true;
      }
      if (this.batchOpen) {
        this.batchOpen = false;
        return true;
      }
      if (this.drawerOpen) {
        this.drawerOpen = false;
        return true;
      }
      return false;
    })
  }

  /** 顶栏图标：系统矢量符号（对应安卓 Material 圆角图标），34×34 点击区 */
  @Builder
  TopIcon(sym: Resource, sizeVp: number, tint: number, onTap: () => void) {
    Row() {
      SymbolGlyph(sym)
        .fontSize(sizeVp)
        .fontColor([tint])
    }
    .width(34)
    .height(34)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      onTap();
    })
  }

  @Builder
  TopBar() {
    Row() {
      // ☰ 菜单（侧边栏）
      this.TopIcon($r('sys.symbol.line_3_horizontal'), 21, this.theme.colors.textPrimary, (): void => {
        this.drawerOpen = true;
      })

      Blank().width(4)
      Column() {
        Row() {
          Text(this.title())
            .fontSize(this.theme.fs(16))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Blank().width(6)
          Circle()
            .width(7)
            .height(7)
            .fill(this.online() ? Palette.green : Palette.red)
        }
        .alignItems(VerticalAlign.Center)
        Text(`${this.serverTaskCount} 个任务 · ${this.state.isRefreshing ? '刷新中…' : '已连接'}`)
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 切换下载器（多台时才出现，和安卓一致）
      if (this.state.servers.length > 1) {
        Stack() {
          SymbolGlyph($r('sys.symbol.arrow_left_arrow_right'))
            .fontSize(21)
            .fontColor([this.theme.colors.textPrimary])
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .bindMenu(this.switchServerMenuItems())
      }

      // 批量操作
      this.TopIcon($r('sys.symbol.list_checkmark'), 21, this.theme.colors.textPrimary, (): void => {
        this.batchOpen = true;
        this.batchDeleteMode = false;
        this.batchLocationMode = false;
        this.deleteChecked = [];
      })

      // 备用限速：**橙色 = 已开启备用限速**；常规色 = 已关闭（正常速度）。
      // 这里刻意不用 TopIcon：@Builder 的参数是值传递，状态变了颜色不会刷新，看起来像「点了没反应」
      Row() {
        SymbolGlyph($r('sys.symbol.gauge_with_dots_needle_33percent'))
          .fontSize(21)
          .fontColor([this.altSpeedOn ? Palette.orange : this.theme.colors.textPrimary])
      }
      .width(34)
      .height(34)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick((): void => {
        this.toggleAltSpeed();
      })

      // 退出（回仪表盘）
      this.TopIcon($r('sys.symbol.xmark'), 19,
        this.theme.colors.textPrimary, (): void => {
          this.navStack.pop();
        })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  /** 「切换下载器」下拉：名称 · QB/TR，当前那台打勾（同安卓） */
  private switchServerMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    for (const s of this.state.servers) {
      const id: string = s.id;
      const active: boolean = id === this.focusServerId;
      const short: string = s.type === ServerType.QBITTORRENT ? 'QB' : 'TR';
      items.push({
        value: `${active ? '✓ ' : ''}${s.displayName()} · ${short}`,
        action: (): void => {
          if (active) {
            return;
          }
          this.focusServerId = id;
          this.statusFilter = StatusFilter.ALL;
          // 换了下载器就丢掉上一台未确认的限速乐观值，直接用新机器的快照
          this.altSpeedSynced = true;
          this.rebuild();
          this.vm.refreshNow();
        }
      });
    }
    return items;
  }

  @Builder
  SpeedRow() {
    Row() {
      Text('↓').fontSize(12).fontColor(Palette.blue)
      Text(` ${formatBytes(this.downSpeed)}/s`)
        .fontSize(this.theme.fs(12))
        .fontColor(this.theme.colors.textSecondary)
      Blank().width(12)
      Text('↑').fontSize(12).fontColor(Palette.arrowUp)
      Text(` ${formatBytes(this.upSpeed)}/s`)
        .fontSize(this.theme.fs(12))
        .fontColor(this.theme.colors.textSecondary)
      Blank()
      // 与安卓一致：当前筛选命中数 / 当前下载器任务总数（筛选中时数字会比 全 少）
      Text(`${this.taskList.length} / ${this.serverTaskCount} 个任务`)
        .fontSize(this.theme.fs(11))
        .fontColor(this.statusFilter === StatusFilter.ALL ? this.theme.colors.textSecondary
          : Palette.blue)
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 2, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  private toggleAltSpeed(): void {
    if (this.focusServerId.length === 0) {
      ToastHub.getInstance().show('先选一台下载器');
      return;
    }
    // 连点会连发两次 toggle（切过去又切回来），还会撞上「服务器状态没变」的判定，直接忽略
    if (this.altSpeedBusy) {
      return;
    }
    this.altSpeedBusy = true;
    // 先乐观着色，请求回来再以服务端状态为准，避免「点了没反应」的观感
    const optimistic: boolean = !this.altSpeedOn;
    this.altSpeedClickAt = Date.now();
    this.altSpeedOn = optimistic;
    this.altSpeedSynced = false;
    this.vm.toggleAltSpeed(this.focusServerId).then((on: boolean): void => {
      this.altSpeedBusy = false;
      this.altSpeedOn = on;
      // 这里**不要**直接置 synced=true：此时快照还是上一轮的旧数据，会被刷回去
      ToastHub.getInstance().show(on ? '已开启备用限速' : '已关闭备用限速');
      this.vm.refreshNow();
    }).catch((e: Error): void => {
      this.altSpeedBusy = false;
      this.altSpeedOn = !optimistic;
      this.altSpeedSynced = true;
      ToastHub.getInstance().show(e.message.length > 0 ? e.message : '切换失败');
    });
  }

  private sortMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    const all: TaskSort[] = [TaskSort.ADDED, TaskSort.NAME, TaskSort.SIZE, TaskSort.PROGRESS,
      TaskSort.DL_SPEED, TaskSort.UL_SPEED, TaskSort.RATIO];
    for (const s of all) {
      const target: TaskSort = s;
      const desc: string = this.sortMode === s ? (this.sortAsc ? '（升序 ↑）' : '（降序 ↓）') : '';
      items.push({
        value: `${taskSortLabel(s)}${desc}`,
        action: (): void => {
          if (this.sortMode === target) {
            this.sortAsc = !this.sortAsc;
          } else {
            this.sortMode = target;
            this.sortAsc = false;
          }
          this.rebuild();
        }
      });
    }
    return items;
  }

  @Builder
  TaskCard(task: TorrentTask) {
    Column() {
      Row() {
        Text(this.statusGlyph(task.status))
          .fontSize(12)
          .fontColor(this.statusColor(task.status))
        Blank().width(4)
        Text(torrentStatusLabel(task.status))
          .fontSize(this.theme.fs(11))
          .fontColor(this.statusColor(task.status))
        if (task.trackerHost.length > 0) {
          Blank().width(6)
          Text(task.trackerHost.substring(0, 14))
            .fontSize(this.theme.fs(9))
            .fontColor(Palette.blue)
            .backgroundColor(0x1F0A84FF)
            .borderRadius(4)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .maxLines(1)
        }
        Blank()
        Text(formatPercent(task.progress))
          .fontSize(this.theme.fs(11))
          .fontColor(this.statusColor(task.status))
        if (task.status === TorrentStatus.DOWNLOADING || task.status === TorrentStatus.QUEUED) {
          Text(task.etaSeconds > 0 ? ` · ${humanEta(task.etaSeconds)}` : '')
            .fontSize(this.theme.fs(10))
            .fontColor(this.theme.colors.textSecondary)
        } else if (task.status === TorrentStatus.SEEDING) {
          Text(` · ${formatDurationCN(task.seedingSeconds)}`)
            .fontSize(this.theme.fs(10))
            .fontColor(this.theme.colors.textSecondary)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(task.name)
        .fontSize(this.theme.fs(13))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.colors.textPrimary)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(this.theme.fs(18))
        // 种子名是「中文名.Let's.Go.2026.S01.2160p...」这种无空格长串：
        // 默认 NORMAL 按词断行会把整串推到第二行，第一行只剩中文名几个字 → 用 BREAK_ALL 逐字符填满再折行（与详情标题一致）。
        .wordBreak(WordBreak.BREAK_ALL)
        .width('100%')
        .margin({ top: 5 })

      if (task.errorMessage.length > 0) {
        Text(task.errorMessage)
          .fontSize(this.theme.fs(10))
          .fontColor(Palette.red)
          .maxLines(2)
          .width('100%')
          .margin({ top: 3 })
      }

      ThinProgress({ progress: task.progress, color: this.statusColor(task.status) })
        .margin({ top: 7 })

      Row() {
        Text('↓').fontSize(10).fontColor(Palette.blue)
        Text(`${formatBytes(task.downloadSpeed)}/s`)
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
        Blank().width(6)
        Text('↑').fontSize(10).fontColor(Palette.arrowUp)
        Text(`${formatBytes(task.uploadSpeed)}/s`)
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
        Blank().width(8)
        Text(`⇅ ${task.numPeers}/${task.totalSeeds}`)
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
        Blank()
        Text(`${formatStorageSize(task.size)} · ${formatRatio(task.ratio)}`)
          .fontSize(this.theme.fs(10))
          .fontColor(this.theme.colors.textSecondary)
      }
      .width('100%')
      .margin({ top: 6 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor(this.theme.colors.card)
    .shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetX: 0, offsetY: 2 })
    .border({ width: 0.5, color: withAlpha(this.theme.colors.separator, 0x88) })
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      // 点击与长按都弹操作面板；进详情的入口是面板第一行的种子名
      this.actionTask = task;
    })
    .gesture(LongPressGesture().onAction((): void => {
      this.actionTask = task;
    }))
  }

  private statusGlyph(s: TorrentStatus): string {
    switch (s) {
      case TorrentStatus.DOWNLOADING:
        return '↓';
      case TorrentStatus.QUEUED:
        return '⋯';
      case TorrentStatus.SEEDING:
        return '↑';
      case TorrentStatus.PAUSED:
        return 'Ⅱ';
      case TorrentStatus.CHECKING:
        return '⟳';
      case TorrentStatus.ERROR:
        return '!';
      default:
        return '✓';
    }
  }

  private statusColor(s: TorrentStatus): number {
    switch (s) {
      case TorrentStatus.DOWNLOADING:
        return Palette.blue;
      case TorrentStatus.QUEUED:
        return Palette.indigo;
      case TorrentStatus.SEEDING:
        return Palette.green;
      case TorrentStatus.ERROR:
        return Palette.red;
      case TorrentStatus.CHECKING:
        return Palette.orange;
      default:
        return Palette.gray;
    }
  }

  // ---------------- 侧边栏 ----------------

  /**
   * 侧边栏：整块照安卓 DrawerPanel 重做。
   * 状态项 8 项同顺序（全部/下载/暂停/做种/活动/完成/检查/错误），彩色图标块 + 选中打勾；
   * 不再显示右侧计数（安卓没有），刷新/配置/返回也改成整行菜单。
   */
  @Builder
  Drawer() {
    Column() {
      Column() {
        Row() {
          Text(this.versionBadge())
            .fontSize(this.theme.fs(12))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.accent)
          Blank()
          Text(this.online() ? 'ONLINE' : 'OFFLINE')
            .fontSize(this.theme.fs(10))
            .fontWeight(FontWeight.Medium)
            .fontColor(0xFFFFFFFF)
            .backgroundColor(this.online() ? Palette.green : Palette.red)
            .borderRadius(4)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.serverTypeLabel())
          .fontSize(this.theme.fs(20))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.colors.textPrimary)
          .margin({ top: 3 })
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        DrawerInfoRow({ label: '地址', value: this.endpointLabel() })
        DrawerInfoRow({ label: '用户', value: this.drawerUserLabel() })
        DrawerInfoRow({ label: '总体积', value: formatStorageSize(this.serverTotalBytes) })

        Blank().height(10)
        Row({ space: 16 }) {
          DrawerStatCell({ label: '↓', value: `${formatBytes(this.downSpeed)}/s`, tint: Palette.blue })
          DrawerStatCell({ label: '↑', value: `${formatBytes(this.upSpeed)}/s`, tint: Palette.green })
        }
        Blank().height(6)
        Row({ space: 16 }) {
          DrawerStatCell({ label: '做种', value: `${this.seedingCount}`, tint: Palette.green })
          DrawerStatCell({ label: '下载', value: `${this.downloadingCount}`, tint: Palette.blue })
          DrawerStatCell({ label: '分享率', value: formatRatio(this.totalRatio),
            tint: this.theme.colors.textPrimary })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 18, bottom: 14 })
      .alignItems(HorizontalAlign.Start)

      this.DividerLine()

      // 状态筛选：图标 + 文案 + 选中圆勾（与安卓 DrawerRow 一致）
      List() {
        ForEach(this.filterOptions(), (f: StatusFilter): void => {
          ListItem() {
            Row() {
              Row() {
                SymbolGlyph(this.filterIcon(f))
                  .fontSize(19)
                  .fontColor([this.filterTint(f)])
              }
              .width(38)
              .height(38)
              .borderRadius(12)
              .backgroundColor(withAlpha(this.filterTint(f), 0x1F))
              .justifyContent(FlexAlign.Center)

              Blank().width(13)
              Text(statusFilterLabel(f))
                .fontSize(this.theme.fs(14))
                .fontColor(this.statusFilter === f ? this.theme.colors.accent
                  : this.theme.colors.textPrimary)
                .layoutWeight(1)
              if (this.statusFilter === f) {
                Stack() {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(12)
                    .fontColor([0xFFFFFFFF])
                }
                .width(17)
                .height(17)
                .borderRadius(9)
                .backgroundColor(this.theme.colors.accent)
              }
            }
            .width('100%')
            .padding({ left: 14, right: 16, top: 7, bottom: 7 })
            .backgroundColor(this.statusFilter === f ? withAlpha(this.theme.colors.accent, 0x10)
              : Color.Transparent)
            .alignItems(VerticalAlign.Center)
            .onClick((): void => {
              this.statusFilter = f;
              this.drawerOpen = false;
              this.rebuild();
            })
          }
        }, (f: StatusFilter): string => `f${f}`)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)

      this.DividerLine()
      Column() {
        this.DrawerAction($r('sys.symbol.arrow_clockwise'), '刷新', Palette.blue, false, (): void => {
          this.vm.refreshNow();
          this.drawerOpen = false;
        })
        this.DrawerAction($r('sys.symbol.gearshape'), '配置', Palette.indigo, true, (): void => {
          this.drawerOpen = false;
          // 下载器设置是整页（与 MoviePilot 服务器页统一），只有添加/编辑才弹窗
          this.navStack.pushPathByName('serverList', '');
        })
        this.DrawerAction($r('sys.symbol.chevron_left'), '返回', this.theme.colors.textSecondary,
          false, (): void => {
            this.drawerOpen = false;
          })
      }
      .width('100%')
      .padding({ top: 6, bottom: 18 })
    }
    .width('76%')
    .height('100%')
    .backgroundColor(this.theme.colors.background)
    .shadow({ radius: 18, color: 'rgba(0,0,0,0.25)', offsetX: 4, offsetY: 0 })
  }

  @Builder
  DrawerAction(sym: Resource, label: string, tint: number, chevron: boolean, onTap: () => void) {
    Row() {
      SymbolGlyph(sym)
        .fontSize(15)
        .fontColor([tint])
        .width(18)
      Blank().width(14)
      Text(label)
        .fontSize(this.theme.fs(14))
        .fontColor(tint)
        .layoutWeight(1)
      if (chevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(13)
          .fontColor([this.theme.colors.textSecondary])
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      onTap();
    })
  }

  // 注意：这里原本用 @Builder(label, value) 按值传参，异步刷新后速度会永远停在 0 B/s
  // （和仪表盘 SpeedTotalCell / IconValue 是同一个坑）。已改成文件末尾的 @Component + @Prop。

  @Builder
  DividerLine() {
    Divider()
      .strokeWidth(0.5)
      .color(this.theme.colors.separator)
  }

  /** 与安卓 StatusFilter.entries 完全同序 */
  private filterOptions(): StatusFilter[] {
    return [StatusFilter.ALL, StatusFilter.DOWNLOADING, StatusFilter.PAUSED, StatusFilter.SEEDING,
      StatusFilter.ACTIVE, StatusFilter.COMPLETED, StatusFilter.CHECKING, StatusFilter.ERROR];
  }

  /** 菜单图标只取项目里已验证可用的系统符号，避免新符号名在旧 API 上编译不过 */
  private filterIcon(f: StatusFilter): Resource {
    switch (f) {
      case StatusFilter.ALL:
        return $r('sys.symbol.list_checkmark');
      case StatusFilter.DOWNLOADING:
        return $r('sys.symbol.chevron_down');
      case StatusFilter.PAUSED:
        return $r('sys.symbol.pause_fill');
      case StatusFilter.SEEDING:
        return $r('sys.symbol.arrow_up_right');
      case StatusFilter.ACTIVE:
        return $r('sys.symbol.arrow_left_arrow_right');
      case StatusFilter.COMPLETED:
        return $r('sys.symbol.checkmark_circle_fill');
      case StatusFilter.CHECKING:
        return $r('sys.symbol.checkmark_square');
      case StatusFilter.ERROR:
        return $r('sys.symbol.xmark');
      default:
        return $r('sys.symbol.list_checkmark');
    }
  }

  /** 与安卓 statusTint() 同色 */
  private filterTint(f: StatusFilter): number {
    switch (f) {
      case StatusFilter.ALL:
      case StatusFilter.DOWNLOADING:
        return Palette.blue;
      case StatusFilter.PAUSED:
        return Palette.purple;
      case StatusFilter.SEEDING:
      case StatusFilter.COMPLETED:
        return Palette.green;
      case StatusFilter.ACTIVE:
        return Palette.mint;
      case StatusFilter.CHECKING:
        return Palette.orange;
      case StatusFilter.ERROR:
        return Palette.red;
      default:
        return Palette.blue;
    }
  }

  /** 侧边栏顶部版本徽标（安卓：TR 4.0.4 / QB v4.6.7） */
  private versionBadge(): string {
    const s: ServerConfig | null = this.server();
    if (s === null) {
      return 'TR / QB';
    }
    const snap: ServerSnapshot | null = this.state.snapshotOf(s.id);
    let v: string = snap !== null ? snap.appVersion.trim() : '';
    if (v.length > 0) {
      const space: number = v.indexOf(' ');
      v = space > 0 ? v.substring(0, space) : v;
      v = v.substring(0, 12);
    }
    return `${s.type === ServerType.QBITTORRENT ? 'QB' : 'TR'}${v.length > 0 ? ' ' + v : ''}`;
  }

  private drawerUserLabel(): string {
    const s: ServerConfig | null = this.server();
    if (s === null) {
      return '未设置用户名';
    }
    if (s.useApiKey && s.type === ServerType.QBITTORRENT) {
      return 'API Key';
    }
    return s.username.trim().length > 0 ? s.username : '未设置用户名';
  }

  private serverTypeLabel(): string {
    const s: ServerConfig | null = this.server();
    if (s === null) {
      return '';
    }
    return s.type === ServerType.QBITTORRENT ? 'qBittorrent' : 'Transmission';
  }

  private endpointLabel(): string {
    const s: ServerConfig | null = this.server();
    if (s === null) {
      return '--';
    }
    const snap = this.state.snapshotOf(s.id);
    if (snap !== null && snap.endpointLabel.length > 0) {
      return snap.endpointLabel;
    }
    return s.endpoints.length > 0 ? s.endpoints[0].display() : '--';
  }

  // ---------------- 批量操作面板 ----------------

  @Builder
  BatchDialog() {
    DialogHost({
      visible: true,
      title: this.batchTitle(),
      confirmText: this.batchConfirmText(),
      destructive: this.batchDeleteMode,
      showCancel: true,
      contentMaxHeight: 400,
      onCancel: (): void => {
        this.batchCancel();
      },
      onConfirm: (): void => {
        this.batchConfirm();
      }
    }) {
      Column() {
        if (this.batchDeleteMode) {
          // 删除清单：高度封顶后自己滚，种子多时也不会把弹窗撑出屏幕
          Row() {
            Text(`共 ${this.serverTasks().length} 个任务`)
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
              .layoutWeight(1)
            Text(this.deleteChecked.length === this.serverTasks().length ? '取消全选' : '全选')
              .fontSize(this.theme.fs(12))
              .fontColor(Palette.blue)
              .onClick((): void => {
                this.toggleAllDelete();
              })
          }
          .width('100%')
          .margin({ bottom: 6 })
          .alignItems(VerticalAlign.Center)

          List() {
            ForEach(this.serverTasks(), (t: TorrentTask): void => {
              ListItem() {
                Row() {
                  Checkbox()
                    .select(this.deleteChecked.indexOf(t.hash) >= 0)
                    .selectedColor(Palette.blue)
                  Text(t.name)
                    .fontSize(this.theme.fs(12))
                    .fontColor(this.theme.colors.textPrimary)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ left: 8 })
                }
                .width('100%')
                .height(34)
                .alignItems(VerticalAlign.Center)
                .onClick((): void => {
                  this.toggleDeleteCheck(t.hash);
                })
              }
            }, (t: TorrentTask): string => `del-${t.id()}-${this.deleteChecked.indexOf(t.hash) >= 0 ? 1 : 0}`)
          }
          .width('100%')
          // 高度按条数算（封顶 190）：固定高度在任务少时留一大片空白，不设高度又会把弹窗撑爆
          .height(Math.min(190, this.serverTasks().length * 34 + 4))
          .scrollBar(BarState.Auto)

          Row() {
            Checkbox()
              .select(this.batchDeleteFiles)
              .selectedColor(Palette.red)
              .onChange((v: boolean): void => {
                this.batchDeleteFiles = v;
              })
            Text('同时删除已下载的文件')
              .fontSize(this.theme.fs(12))
              .fontColor(this.batchDeleteFiles ? Palette.red : this.theme.colors.textPrimary)
              .margin({ left: 8 })
              .onClick((): void => {
                this.batchDeleteFiles = !this.batchDeleteFiles;
              })
          }
          .width('100%')
          .margin({ top: 10 })
          .alignItems(VerticalAlign.Center)
        } else if (this.batchLocationMode) {
          Text(`更改 ${this.allHashes().length} 个任务的保存位置`)
            .fontSize(this.theme.fs(14))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
            .width('100%')
          Text('下载器会把这些任务的下载目录移到新路径（文件本身是否搬移取决于客户端）')
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
            .width('100%')
            .margin({ top: 4 })

          TextInput({ text: this.movePathInput, placeholder: '例如 /downloads/movies' })
            .height(40)
            .fontSize(this.theme.fs(13))
            .fontColor(this.theme.colors.textPrimary)
            .placeholderColor(this.theme.colors.textSecondary)
            .placeholderFont({ size: this.theme.fs(13) })
            .backgroundColor(this.theme.colors.background)
            .borderRadius(9)
            .enterKeyType(EnterKeyType.Done)
            .margin({ top: 12 })
            .onChange((v: string): void => {
              this.movePathInput = v;
            })
        } else {
          // 与安卓 BatchSheet 一致：不列种子、不给勾选，作用范围就是本机全部任务
          Row() {
            Text('作用范围')
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
              .layoutWeight(1)
            Text(`全部 ${this.allHashes().length} 个任务`)
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 操作项：与安卓 BatchSheet / 单任务面板一致（图标 + 文字的行式菜单）
          Column() {
            this.SheetRow($r('sys.symbol.play_fill'), '全部继续', Palette.indigo, (): void => {
              this.runBatch(TorrentAction.RESUME);
            })
            this.RowLine()
            this.SheetRow($r('sys.symbol.pause_fill'), '全部暂停', Palette.indigo, (): void => {
              this.runBatch(TorrentAction.PAUSE);
            })
            if (this.isQb()) {
              this.RowLine()
              this.SheetRow($r('sys.symbol.bolt_1'), '全部强制继续', Palette.green, (): void => {
                this.runBatch(TorrentAction.FORCE_RESUME);
              })
            }
          }
          .width('100%')
          .borderRadius(10)
          .backgroundColor(this.theme.colors.background)
          .margin({ top: 8 })

          Column() {
            this.SheetRow($r('sys.symbol.folder'), '更改保存位置', Palette.mint, (): void => {
              if (this.allHashes().length === 0) {
                ToastHub.getInstance().show('当前没有任务');
                return;
              }
              this.batchLocationMode = true;
            })
          }
          .width('100%')
          .borderRadius(10)
          .backgroundColor(this.theme.colors.background)
          .margin({ top: 8 })

          if (this.isQb()) {
            Column() {
              this.SheetRow($r('sys.symbol.arrow_clockwise'), '自动种子管理', Palette.indigo, (): void => {
                this.runBatch(TorrentAction.AUTO_MANAGEMENT_ON);
              })
              this.RowLine()
              this.SheetRow($r('sys.symbol.gauge_with_dots_needle_33percent'), '超级种子模式', Palette.green,
                (): void => {
                  this.runBatch(TorrentAction.SUPER_SEEDING_ON);
                })
            }
            .width('100%')
            .borderRadius(10)
            .backgroundColor(this.theme.colors.background)
            .margin({ top: 8 })
          }

          Column() {
            this.SheetRow($r('sys.symbol.checkmark_square'), '重新校验', Palette.green, (): void => {
              this.runBatch(TorrentAction.RECHECK);
            })
            this.RowLine()
            this.SheetRow($r('sys.symbol.speaker_wave_2'), '重新汇报', Palette.green, (): void => {
              this.runBatch(TorrentAction.REANNOUNCE);
            })
          }
          .width('100%')
          .borderRadius(10)
          .backgroundColor(this.theme.colors.background)
          .margin({ top: 8 })

          // 高危动作永远排最底部（用户要求：凡是高危操作都放最下面）
          Column() {
            this.SheetRow($r('sys.symbol.trash'), '批量删除', Palette.red, (): void => {
              if (this.allHashes().length === 0) {
                ToastHub.getInstance().show('当前没有任务');
                return;
              }
              this.batchDeleteFiles = false;
              this.deleteChecked = this.allHashes();
              this.batchDeleteMode = true;
            }, true)
          }
          .width('100%')
          .borderRadius(10)
          .backgroundColor(this.theme.colors.background)
          .margin({ top: 8 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 批量面板标题（随当前层级变化） */
  private batchTitle(): string {
    if (this.batchDeleteMode) {
      return '批量删除';
    }
    if (this.batchLocationMode) {
      return '更改保存位置';
    }
    return '批量操作';
  }

  /** 批量弹窗确认键文案（随子状态变） */
  private batchConfirmText(): string {
    if (this.batchDeleteMode) {
      return this.batchDeleteFiles ? '删除任务和文件' : '删除任务';
    }
    if (this.batchLocationMode) {
      return '确认移动';
    }
    return '关闭';
  }

  /** 批量弹窗取消：删除 / 改位置先退回动作列表，动作列表再退才关弹窗 */
  private batchCancel(): void {
    if (this.batchDeleteMode) {
      this.batchDeleteMode = false;
      this.deleteChecked = [];
      return;
    }
    if (this.batchLocationMode) {
      this.batchLocationMode = false;
      return;
    }
    this.batchOpen = false;
  }

  /** 批量弹窗确认键：删除 / 改位置执行动作，动作列表层只负责关闭 */
  private batchConfirm(): void {
    if (this.batchDeleteMode) {
      if (this.deleteChecked.length === 0) {
        ToastHub.getInstance().show('先勾选要删除的任务');
        return;
      }
      this.runBatch(this.batchDeleteFiles ? TorrentAction.DELETE_WITH_FILES : TorrentAction.DELETE,
        '', this.deleteChecked.slice(0));
      return;
    }
    if (this.batchLocationMode) {
      const path: string = this.movePathInput.trim();
      if (path.length === 0) {
        ToastHub.getInstance().show('先填目标路径');
        return;
      }
      this.runBatch(TorrentAction.CHANGE_LOCATION, path);
      return;
    }
    this.batchOpen = false;
  }

  /** 当前下载器的全部任务（口径同安卓 source：只按服务器过滤，不受状态筛选影响） */
  private serverTasks(): TorrentTask[] {
    const out: TorrentTask[] = [];
    for (const t of this.state.tasks) {
      if (this.focusServerId.length > 0 && t.serverId !== this.focusServerId) {
        continue;
      }
      out.push(t);
    }
    return out;
  }

  /** 批量操作作用范围：当前下载器的全部任务（口径同安卓 allHashes） */
  private allHashes(): string[] {
    const out: string[] = [];
    for (const t of this.serverTasks()) {
      out.push(t.hash);
    }
    return out;
  }

  /** 批量删除弹窗：单个任务勾选/取消（整体替换数组，保证 UI 刷新） */
  private toggleDeleteCheck(hash: string): void {
    const next: string[] = this.deleteChecked.slice(0);
    const idx: number = next.indexOf(hash);
    if (idx >= 0) {
      next.splice(idx, 1);
    } else {
      next.push(hash);
    }
    this.deleteChecked = next;
  }

  /** 批量删除弹窗：全选 / 取消全选（同安卓按钮文案切换） */
  private toggleAllDelete(): void {
    if (this.deleteChecked.length === this.serverTasks().length) {
      this.deleteChecked = [];
    } else {
      this.deleteChecked = this.allHashes();
    }
  }

  private runBatch(action: TorrentAction, location: string = '', hashes: string[] = []): void {
    const target: string[] = hashes.length > 0 ? hashes : this.allHashes();
    if (target.length === 0) {
      ToastHub.getInstance().show('当前没有任务');
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.vm.batchAction(this.focusServerId, action, target, location).then((): void => {
      this.busy = false;
      this.batchOpen = false;
      this.batchDeleteMode = false;
      this.batchLocationMode = false;
      this.deleteChecked = [];
    }).catch((e: Error): void => {
      this.busy = false;
      ToastHub.getInstance().show(e.message.length > 0 ? e.message : '操作失败');
    });
  }

  // ---------------- 单任务操作面板 ----------------

  /**
   * 种子操作（弹窗 → 整页）。
   *
   * 用户要求「只读/浏览类面板改回全屏」，真正改数据的地方（重命名 / 保存位置 /
   * 限速 / 分享率 / 分类 / 标签 / Tracker）继续用 DialogHost 弹窗。
   */
  @Builder
  TaskActionPage(task: TorrentTask) {
    Column() {
      this.ActionHeader(task)

      Scroll() {
        this.TaskActionList(task)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      // Scroll 默认 align 是 Center，内容不足一屏会被垂直居中
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.colors.background)
    .alignItems(HorizontalAlign.Start)
  }

  /** 整页顶栏：圆形返回钮 + 「种子操作」+ 种子名 */
  @Builder
  ActionHeader(task: TorrentTask) {
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
        this.actionTask = null;
      })

      Blank().width(10)
      Column() {
        Text('种子操作')
          .fontSize(this.theme.fs(17))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(task.name)
          .fontSize(this.theme.fs(11))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  TaskActionList(task: TorrentTask) {
      Column() {
        // 第一行：进任务详情（详情是叠在本面板之上的弹窗，关掉自动回到这里）
        Row() {
          Column() {
            Text('查看任务详情')
              .fontSize(this.theme.fs(14))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.colors.textPrimary)
            Text('速度、流量、保存路径、做种时长')
              .fontSize(this.theme.fs(10))
              .fontColor(this.theme.colors.textSecondary)
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(15)
            .fontColor([this.theme.colors.textSecondary])
        }
        .width('100%')
        .padding(14)
        .borderRadius(CARD_RADIUS)
        .backgroundColor(this.theme.colors.card)
        .shadow({ radius: 14, color: this.softShadow(), offsetY: 3 })
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          this.openDetail(task);
        })

        // 组 1：继续 / 暂停
        Column() {
          if (task.status === TorrentStatus.PAUSED) {
            this.SheetRow($r('sys.symbol.play_fill'), '继续', Palette.blue, (): void => {
              this.runSingle(TorrentAction.RESUME);
            })
          } else {
            this.SheetRow($r('sys.symbol.pause_fill'), '暂停', Palette.blue, (): void => {
              this.runSingle(TorrentAction.PAUSE);
            })
          }
          if (this.isQb()) {
            this.RowLine()
            this.SheetRow($r('sys.symbol.bolt_1'), '强制继续', Palette.green, (): void => {
              this.runSingleForceStart();
            })
          }
        }
        .width('100%')
        .borderRadius(CARD_RADIUS)
        .backgroundColor(this.theme.colors.card)
        .shadow({ radius: 14, color: this.softShadow(), offsetY: 3 })
        .margin({ top: CARD_GAP })

        // 组 2：重命名（单独一张卡，和安卓一致）
        Column() {
          this.SheetRow($r('sys.symbol.square_and_pencil'), '重命名', Palette.blue, (): void => {
            this.openEdit(TaskEditMode.RENAME);
          })
        }
        .width('100%')
        .borderRadius(CARD_RADIUS)
        .backgroundColor(this.theme.colors.card)
        .shadow({ radius: 14, color: this.softShadow(), offsetY: 3 })
        .margin({ top: CARD_GAP })

        // 组 2b：更改保存位置（+ qb 的分类 / 标签）
        Column() {
          this.SheetRow($r('sys.symbol.folder'), '更改保存位置', Palette.mint, (): void => {
            this.openEdit(TaskEditMode.LOCATION);
          })
          if (this.isQb()) {
            this.RowLine()
            this.SheetRow($r('sys.symbol.square_grid_2x2'), '分类', Palette.purple, (): void => {
              this.openEdit(TaskEditMode.CATEGORY);
            })
            this.RowLine()
            this.SheetRow($r('sys.symbol.label'), '标签', Palette.orange, (): void => {
              this.openEdit(TaskEditMode.TAGS);
            })
          }
        }
        .width('100%')
        .borderRadius(CARD_RADIUS)
        .backgroundColor(this.theme.colors.card)
        .shadow({ radius: 14, color: this.softShadow(), offsetY: 3 })
        .margin({ top: CARD_GAP })

        // 组 3：限速 / 分享率
        Column() {
          this.SheetRow($r('sys.symbol.gauge_with_dots_needle_33percent'), '限速设置', Palette.blue, (): void => {
            this.openEdit(TaskEditMode.LIMITS);
          })
          this.RowLine()
          this.SheetRow($r('sys.symbol.arrow_up_right'), '分享率设置', Palette.orange, (): void => {
            this.openEdit(TaskEditMode.RATIO);
          })
          this.RowLine()
          this.SheetRow($r('sys.symbol.repeat'), 'Tracker 列表', Palette.mint, (): void => {
            this.openTrackers();
          })
          if (this.isQb()) {
            this.RowLine()
            this.SheetRow($r('sys.symbol.arrow_clockwise'), '自动种子管理', Palette.indigo, (): void => {
              this.runAutoManagement();
            })
          }
        }
        .width('100%')
        .borderRadius(CARD_RADIUS)
        .backgroundColor(this.theme.colors.card)
        .shadow({ radius: 14, color: this.softShadow(), offsetY: 3 })
        .margin({ top: CARD_GAP })

        // 组 4：校验 / 汇报
        Column() {
          this.SheetRow($r('sys.symbol.checkmark_square'), '重新校验', Palette.green, (): void => {
            this.runSingle(TorrentAction.RECHECK);
          })
          this.RowLine()
          this.SheetRow($r('sys.symbol.speaker_wave_2'), '重新汇报', Palette.green, (): void => {
            this.runSingle(TorrentAction.REANNOUNCE);
          })
        }
        .width('100%')
        .borderRadius(CARD_RADIUS)
        .backgroundColor(this.theme.colors.card)
        .shadow({ radius: 14, color: this.softShadow(), offsetY: 3 })
        .margin({ top: CARD_GAP })

        // 组 5：删除
        Column() {
          this.SheetRow($r('sys.symbol.trash'), '删除种子', Palette.red, (): void => {
            this.runSingle(TorrentAction.DELETE);
          }, true)
          this.RowLine()
          this.SheetRow($r('sys.symbol.trash'), '删除种子和文件', Palette.red, (): void => {
            this.runSingle(TorrentAction.DELETE_WITH_FILES);
          }, true)
        }
        .width('100%')
        .borderRadius(CARD_RADIUS)
        // 高危组整卡淡红底 + 左侧红条（设计稿样式）：和白底的功能组一眼分开
        .backgroundColor(withAlpha(Palette.red, 0x14))
        .border({ width: { left: 3 }, color: withAlpha(Palette.red, 0xC0) })
        .shadow({ radius: 14, color: this.softShadow(), offsetY: 3 })
        .margin({ top: CARD_GAP })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, bottom: 24 })
  }
  /**
   * 行与行之间的分隔线（菜单元件 SheetRow 专用）。
   *
   * 注意：这里**不能**叫 `Line` —— ArkUI 自带同名绘图组件 `Line`（形状组件），
   * 裸写 `Line()` 会优先解析成内置组件，画出来是个 0 尺寸的空图形，
   * 结果就是「代码里有线、界面上一条都看不到」（2026-11-23 用户反馈截图）。
   * 所以统一叫 RowLine，并且一律用 this.RowLine() 调用。
   */
  @Builder
  RowLine() {
    Divider()
      .strokeWidth(1)
      // 用户反馈「每行加条线看下效果」：原来 0.5 + 极淡的 separator 基本看不见，
      // 这里换成 1px + textSecondary 的 27% 透明度，浅色/深色主题下都清晰又不刺眼。
      .color(withAlpha(this.theme.colors.textSecondary, 0x45))
      // 缩进到文字起点（13 内边距 + 38 图标块 + 13 间距）
      .margin({ left: 13 + ROW_ICON_SIZE + 13, right: 16 })
  }

  /** 整页分组卡的柔影：浅色用冷调蓝灰（比纯黑更像环境光），深色压黑 */
  private softShadow(): string {
    return this.theme.colors.isDark ? 'rgba(0,0,0,0.30)' : 'rgba(59,76,112,0.08)';
  }

  /**
   * 右下两个悬浮圆钮的描边：深色主题下圆钮是 card 色、压在同样是 card 色的卡片上，
   * 只剩一圈轮廓能分辨，不描边就糊成一片（用户反馈「黑色主题看不清楚」）。
   */
  private fabBorder(): number {
    return this.theme.colors.isDark
      ? withAlpha(this.theme.colors.textSecondary, 0x59)
      : withAlpha(this.theme.colors.separator, 0xFF);
  }

  /** 悬浮圆钮的投影：深色主题要更实，否则看不出「浮」在列表之上 */
  private fabShadow(): string {
    return this.theme.colors.isDark ? 'rgba(0,0,0,0.55)' : 'rgba(59,76,112,0.18)';
  }

  /**
   * 菜单行：图标带浅色圆角底（tint 的 15% 透明度）+ 文案 + 可选箭头。
   *
   * 原来是「裸图标 + 文字」，整页看着空，给图标垫一块同色浅底做视觉锚点。
   * 图标块 30→38 后行高一度到 56，用户又反馈「行间距有点大」→ 上下 padding 收到 7（行高 52）。
   */
  @Builder
  SheetRow(sym: Resource, label: string, tint: number, onTap: () => void, danger: boolean = false) {
    Row() {
      Row() {
        SymbolGlyph(sym)
          .fontSize(19)
          .fontColor([tint])
      }
      .width(ROW_ICON_SIZE)
      .height(ROW_ICON_SIZE)
      .borderRadius(12)
      .backgroundColor(withAlpha(tint, 0x26))
      .justifyContent(FlexAlign.Center)

      Blank().width(13)
      Text(label)
        .fontSize(this.theme.fs(15))
        .fontColor(danger ? Palette.red : this.theme.colors.textPrimary)
        .layoutWeight(1)
      Blank().width(8)
    }
    .width('100%')
    // 行高 = 图标块 38 + 上下各 7 = 52（ROW_VPAD 可统一调）
    .padding({ left: 13, right: 16, top: ROW_VPAD, bottom: ROW_VPAD })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      onTap();
    })
  }

  /** 编辑弹窗要的任务对象（避免在 @State 可空字段上做类型收窄） */
  private editTaskValue(): TorrentTask {
    const t: TorrentTask | null = this.editTask;
    return t !== null ? t : new TorrentTask();
  }

  /** 操作弹窗要的任务对象（同上） */
  private actionTaskValue(): TorrentTask {
    const t: TorrentTask | null = this.actionTask;
    return t !== null ? t : new TorrentTask();
  }

  /** Tracker 弹窗要的任务对象（同上） */
  private trackerTaskValue(): TorrentTask {
    const t: TorrentTask | null = this.trackerTask;
    return t !== null ? t : new TorrentTask();
  }

  /** 打开 Tracker 列表：保留 actionTask，关掉后回操作弹窗 */
  private openTrackers(): void {
    const task: TorrentTask | null = this.actionTask;
    if (task === null) {
      return;
    }
    this.trackerTask = task;
  }

  /** 详情弹窗要的任务对象（同上） */
  private detailTaskValue(): TorrentTask {
    const t: TorrentTask | null = this.detailTask;
    return t !== null ? t : new TorrentTask();
  }

  /** 打开任务详情：**不清 actionTask**，详情关掉后操作弹窗自动回到原位 */
  private openDetail(task: TorrentTask): void {
    this.detailTask = task;
  }

  private openEdit(mode: TaskEditMode): void {
    const task: TorrentTask | null = this.actionTask;
    if (task === null) {
      return;
    }
    // 同样保留 actionTask：编辑弹窗叠在操作弹窗之上，关掉后回到上一级而不是掉回列表
    this.editMode = mode;
    this.editTask = task;
  }

  private runSingle(action: TorrentAction): void {
    const task: TorrentTask | null = this.actionTask;
    if (task === null) {
      return;
    }
    this.actionTask = null;
    this.vm.performAction(task, action);
  }

  private runSingleForceStart(): void {
    const task: TorrentTask | null = this.actionTask;
    if (task === null) {
      return;
    }
    this.actionTask = null;
    this.vm.forceStartTask(task).catch((e: Error): void => {
      ToastHub.getInstance().show(e.message.length > 0 ? e.message : '操作失败');
    });
  }

  private runAutoManagement(): void {
    const task: TorrentTask | null = this.actionTask;
    if (task === null) {
      return;
    }
    this.actionTask = null;
    // 面板里没有回显开关状态（torrents/info 没解析 auto_tmm），所以这里只做「开启」
    this.vm.setAutoManagement(task, true).catch((e: Error): void => {
      ToastHub.getInstance().show(e.message.length > 0 ? e.message : '操作失败');
    });
  }
}

/**
 * 侧边栏信息行 / 统计小格。
 * 必须用 @Component + @Prop：普通字段和 @Builder 的按值参数只在首次创建时取值，
 * 轮询回来的速度/数量不会重绘（现象就是「明明有上传，卡片一直 0 B/s」）。
 */
@Component
struct DrawerInfoRow {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(this.theme.fs(11))
        .fontColor(this.theme.colors.textSecondary)
        .width(72)
      Text(this.value)
        .fontSize(this.theme.fs(11))
        .fontColor(this.theme.colors.textPrimary)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ top: 8 })
    .alignItems(VerticalAlign.Center)
  }
}

@Component
struct DrawerStatCell {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop tint: number = Palette.blue;

  build() {
    Row() {
      Text(this.label)
        .fontSize(this.theme.fs(12))
        .fontColor(this.tint)
      Text(this.value)
        .fontSize(this.theme.fs(12))
        .fontColor(this.tint)
    }
    .alignItems(VerticalAlign.Center)
  }
}
