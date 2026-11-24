import { AppTheme, Palette, Metrics, withAlpha, glassCard, ghostFill, GLASS_MASK } from '../../common/Theme';
import { formatBytes } from '../../common/Format';
import { ServerType, serverTypeShortLabel } from '../../model/Models';
import { ToastHub } from '../../vm/StoreBase';
import { TOAST_SHORT_MS } from '../../common/AppConstants';

/**
 * 通用 UI 组件（对应安卓 ui/components/Components.kt + Fields.kt 首批基础件）。
 * 主题经 @Provide('oiiTheme') 自 Index 下发，组件统一 @Consume。
 */

@Builder
export function emptyBuilder(): void {
}

/**
 * 字符串是否有内容（对 undefined / null 安全）。
 * ArkUI 的 @Prop 字符串在真机某些刷新时序下会拿到 undefined，
 * 直接 `.length` 会让渲染阶段抛 TypeError 把整个进程带走（闪退就是这么来的）。
 */
export function hasText(v: string): boolean {
  if (!v) {
    return false;
  }
  return v.length > 0;
}

/** 圆角卡片 */
@Component
export struct OiiCard {
  @Consume('oiiTheme') theme: AppTheme;
  @BuilderParam content: () => void = emptyBuilder;
  paddingVp: number = 14;
  bgColor: number = -1;

  build() {
    Column() {
      this.content()
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .borderRadius(Metrics.tileRadius)
    .backgroundColor(this.bgColor >= 0 ? this.bgColor : this.theme.colors.card)
    .padding(this.paddingVp)
  }
}

/**
 * 立体悬浮卡片（仪表盘专用）：玻璃渐变底 + 高光描边 + 抬升阴影 + 可选彩色光斑。
 * 不启用 backgroundBlurStyle —— 尺寸不受限的 Stack 上会 native 崩溃，
 * 且卡片背后是纯色页面，真模糊看不出差别。全部静态绘制，滚动不重算。
 */
@Component
export struct ElevatedCard {
  @Consume('oiiTheme') theme: AppTheme;
  @BuilderParam content: () => void = emptyBuilder;
  paddingVp: number = 14;
  /** >=0 时在卡片左上叠一枚同色柔光斑（只给大卡传） */
  accent: number = -1;
  /** true = 弱悬浮（约仪表盘一半），给站点 / 种子这类长列表用，避免整屏阴影太重 */
  subtle: boolean = false;
  /** 圆角（vp）：仪表盘 / MP 用 20，设置页这种紧凑分组用 18 */
  radiusVp: number = 20;

  /**
   * 卡片底色渐变。accent 直接混进渐变起点，**不再额外叠图层**。
   *
   * 踩坑记录：原来用 children 里一个 width('72%') / height('80%') 的 Column 配
   * .position + .blur 画彩色光斑。父 Column 高度是 auto（由内容撑开），
   * ArkUI 里百分比高度会解析成外层约束高度，光斑直接溢出卡片，
   * 真机上变成一条横跨半个屏幕的紫色色块（且 blur 又把边缘糊开，更明显）。
   */
  private gradientColors(): Array<[number, number]> {
    const isDark: boolean = this.theme.colors.isDark;
    if (this.accent >= 0) {
      // 只做「左上角一层很淡的彩雾」——安卓那边是 alpha 0.14 的径向光斑，
      // 之前给到 0x30 直接把整张卡染成紫粉色（真机截图对比过），这里压到 0x18 → 0x05
      return [
        [withAlpha(this.accent, isDark ? 0x1C : 0x18), 0.0],
        [withAlpha(this.accent, isDark ? 0x08 : 0x05), 0.40],
        [withAlpha(isDark ? 0x2B2B32 : 0xFCFDFF, 0xF2), 1.0]
      ];
    }
    if (isDark) {
      return [[withAlpha(0x2B2B32, 0xF7), 0.0], [withAlpha(0x202026, 0xF0), 1.0]];
    }
    // 冷调：上近白、下浅蓝灰，配合蓝灰投影才有「浮起来」的通透感
    return [[withAlpha(0xFCFDFF, 0xFA), 0.0], [withAlpha(0xE3EBF8, 0xF5), 1.0]];
  }

  /** 有彩色光斑时走 135°（左上角起），把彩雾压在左上角，和安卓的径向光斑位置一致 */
  private gradientAngle(): number {
    return this.accent >= 0 ? 135 : 180;
  }

  /**
   * 悬浮阴影参数（对齐安卓那套「12 层叠加柔影」的观感）。
   *
   * ArkUI 只能画一层 shadow，所以不能照抄安卓的 alpha（0.26 会变成一圈生硬的黑边）。
   * 单层要「自然」只能靠：**半径放大 + alpha 压低 + 下移多一点**，
   * 让阴影在卡片下方摊开成一片很淡的蓝灰雾，而不是贴着边缘的深色光晕。
   */
  private shadowRadius(): number {
    return this.subtle ? 22 : 28;
  }

  private shadowColor(): string {
    if (this.theme.colors.isDark) {
      return this.subtle ? 'rgba(0,0,0,0.30)' : 'rgba(0,0,0,0.42)';
    }
    // 偏蓝灰的冷调投影，比纯黑更像参考图里的「环境光」
    return this.subtle ? 'rgba(59,76,112,0.10)' : 'rgba(59,76,112,0.14)';
  }

  private shadowOffsetY(): number {
    return this.subtle ? 8 : 12;
  }

  /**
   * 卡片实底（不透明）：只给外层的 shadow 提供「真实圆角轮廓」。
   *
   * 踩坑：ArkUI 的 shadow 轮廓取自组件的**背景绘制内容**。卡片原来只有
   * `.linearGradient()` 而没有 `backgroundColor`，gradient 是独立绘制层、
   * 不参与轮廓计算，shadow 就退化成按布局矩形（直角）投射 ——
   * 真机上圆角外侧露出一块方形灰角，`fill: true` 也救不回来。
   * 解法是外面再套一层：外层 `backgroundColor + borderRadius` 承影，内层铺渐变。
   */
  private baseColor(): number {
    return this.theme.colors.isDark ? 0x2B2B32 : 0xFCFDFF;
  }

  build() {
    Column() {
      // 内层：玻璃面（渐变 + 高光描边 + 内容）
      Column() {
        this.content()
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .borderRadius(this.radiusVp)
      .linearGradient({ angle: this.gradientAngle(), colors: this.gradientColors() })
      .border({
        width: this.subtle ? 0.5 : 0.8,
        color: withAlpha(0xFFFFFF, this.theme.colors.isDark ? 0x2A : 0xF5),
        radius: this.radiusVp
      })
      .padding(this.paddingVp)
    }
    .width('100%')
    .borderRadius(this.radiusVp)
    .backgroundColor(this.baseColor())
    .shadow({
      radius: this.shadowRadius(),
      color: this.shadowColor(),
      offsetX: 0,
      offsetY: this.shadowOffsetY(),
      fill: true
    })
  }
}

/** 区块标题（右侧可挂控件） */
@Component
export struct SectionHeader {
  @Consume('oiiTheme') theme: AppTheme;
  title: string = '';
  @BuilderParam trailing: () => void = emptyBuilder;

  build() {
    Row() {
      Text(this.title)
        .fontSize(this.theme.fs(17))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.colors.textPrimary)
        .layoutWeight(1)
      this.trailing()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}

/** 分类/标签小胶囊 */
@Component
export struct TagPill {
  @Consume('oiiTheme') theme: AppTheme;
  text: string = '';
  tint: number = -1;
  bgColor: number = -1;
  fontVp: number = 11;

  build() {
    Text(this.text)
      .fontSize(this.theme.fs(this.fontVp))
      .fontColor(this.tint >= 0 ? this.tint : this.theme.colors.textSecondary)
      .backgroundColor(this.bgColor >= 0 ? this.bgColor : this.theme.colors.separator)
      .borderRadius(7)
      .padding({ left: 7, right: 7, top: 3, bottom: 3 })
      .maxLines(1)
  }
}

/** 更小的徽章 */
@Component
export struct TinyPill {
  @Consume('oiiTheme') theme: AppTheme;
  text: string = '';
  bgColor: number = Palette.separatorLight;
  fgColor: number = 0xFFFFFFFF;
  fontVp: number = 10;

  build() {
    Text(this.text)
      .fontSize(this.theme.fs(this.fontVp))
      .fontColor(this.fgColor)
      .backgroundColor(this.bgColor)
      .borderRadius(6)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .maxLines(1)
  }
}

/** 可选中胶囊（筛选 Chip） */
@Component
export struct SelectablePill {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop text: string = '';
  /** @Prop：父组件状态变化时能真正刷新（普通成员只在首次创建时取值，之后改了不刷新） */
  @Prop selected: boolean = false;
  onTap: () => void = (): void => {
  };

  build() {
    Text(this.text)
      .fontSize(this.theme.fs(13))
      .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.selected ? 0xFFFFFFFF : this.theme.colors.textSecondary)
      .backgroundColor(this.selected ? this.theme.colors.accent : this.theme.colors.card)
      .borderRadius(18)
      .border({
        width: 0.5,
        color: this.selected ? Color.Transparent : this.theme.colors.separator
      })
      .padding({ left: 15, right: 15, top: 8, bottom: 8 })
      .onClick((): void => {
        this.onTap();
      })
  }
}

/** 状态点 */
@Component
export struct Dot {
  /**
   * 必须是 @Prop：普通成员在 ArkUI 里只在**创建时**赋一次值，父组件重绘时传进来的新颜色
   * 不会被同步。以前这里就是普通成员，导致仪表盘/服务器列表的状态点永远停在首帧颜色
   * ——首帧快照还没回来（null → 橙），后面数据到了、转绿了，圆点却一直是黄的。
   */
  @Prop color: number = Palette.green;
  @Prop sizeVp: number = 8;

  build() {
    Circle()
      .width(this.sizeVp)
      .height(this.sizeVp)
      .fill(this.color)
  }
}

/** 空态提示 */
@Component
export struct EmptyHint {
  @Consume('oiiTheme') theme: AppTheme;
  text: string = '';

  build() {
    Column() {
      Text(this.text)
        .fontSize(this.theme.fs(14))
        .fontColor(this.theme.colors.textSecondary)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 40, bottom: 40 })
  }
}

/** 分隔线 */
@Component
export struct DividerLine {
  @Consume('oiiTheme') theme: AppTheme;

  build() {
    Row()
      .width('100%')
      .height(0.5)
      .backgroundColor(this.theme.colors.separator)
  }
}

/** 细进度条 */
@Component
export struct ThinProgress {
  @Consume('oiiTheme') theme: AppTheme;
  progress: number = 0;
  color: number = Palette.blue;
  heightVp: number = 3;

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row()
        .width('100%')
        .height(this.heightVp)
        .borderRadius(this.heightVp)
        .backgroundColor(this.theme.colors.separator)
      Row()
        .width(`${Math.min(Math.max(this.progress, 0), 1) * 100}%`)
        .height(this.heightVp)
        .borderRadius(this.heightVp)
        .backgroundColor(this.color)
    }
    .width('100%')
  }
}

/** ↓↑ 速度对 */
@Component
export struct SpeedPair {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop download: number = 0;
  @Prop upload: number = 0;
  @Prop divider: boolean = true;

  build() {
    Row() {
      Text('↓')
        .fontSize(this.theme.fs(12))
        .fontColor(Palette.arrowDown)
      Text(` ${formatBytes(this.download)}/s`)
        .fontSize(this.theme.fs(12))
        .fontColor(this.theme.colors.textSecondary)
      if (this.divider) {
        Text('  ')
          .fontSize(this.theme.fs(12))
      }
      Text('↑')
        .fontSize(this.theme.fs(12))
        .fontColor(Palette.arrowUp)
      Text(` ${formatBytes(this.upload)}/s`)
        .fontSize(this.theme.fs(12))
        .fontColor(this.theme.colors.textSecondary)
    }
    .alignItems(VerticalAlign.Center)
  }
}

/** 服务器类型徽章（qb/tr 圆点） */
@Component
export struct ServerBadge {
  type: ServerType = ServerType.QBITTORRENT;
  sizeVp: number = 22;

  build() {
    Stack() {
      Circle()
        .width(this.sizeVp)
        .height(this.sizeVp)
        .fill(this.type === ServerType.QBITTORRENT ? 0xFF2F6FED : 0xFF8E44AD)
      Text(serverTypeShortLabel(this.type))
        .fontSize(this.sizeVp * 0.42)
        .fontWeight(FontWeight.Bold)
        .fontColor(0xFFFFFFFF)
    }
    .width(this.sizeVp)
    .height(this.sizeVp)
  }
}

/** 仪表盘统计瓦片 */
@Component
export struct StatTile {
  @Consume('oiiTheme') theme: AppTheme;
  // 全部走 @Prop：普通成员只在创建时取一次值，异步数据回填后不会刷新
  // （仪表盘四块统计一直显示 0 就是这个坑）
  @Prop iconChar: string = '';
  @Prop iconTint: number = Palette.blue;
  @Prop value: string = '';
  @Prop unit: string = '';
  @Prop caption: string = '';

  build() {
    // 外层：实色圆角底，专供 shadow 取轮廓。gradient 是独立绘制层，不参与轮廓计算，
    // 单层用 gradient 做底时 shadow 会退化成按矩形（直角）投射。
    Column() {
      // 内层：玻璃面（渐变 + 高光描边 + 内容）
      Column() {
      Text(this.iconChar)
        .fontSize(this.theme.fs(18))
        .fontColor(this.iconTint)
      Blank().height(10)
      Row() {
        Text(this.value)
          .fontSize(this.theme.fs(22))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (hasText(this.unit)) {
          Blank().width(3)
          Text(this.unit)
            .fontSize(this.theme.fs(12))
            .fontColor(this.theme.colors.textSecondary)
        }
      }
      .alignItems(VerticalAlign.Bottom)
      if (hasText(this.caption)) {
        Blank().height(6)
        Text(this.caption)
          .fontSize(this.theme.fs(12))
          .fontColor(this.theme.colors.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .borderRadius(Metrics.tileRadius)
    // 和 ElevatedCard 同一套立体语言：冷调渐变 + 高光边 + 蓝灰柔光投影。
    // 「数据聚合」那四块统计卡原来只是平底色，和旁边的大卡不像一套东西。
    .linearGradient({
      angle: 180,
      colors: this.theme.colors.isDark
        ? [[withAlpha(0x2B2B32, 0xF7), 0.0], [withAlpha(0x202026, 0xF0), 1.0]]
        : [[withAlpha(0xFCFDFF, 0xFA), 0.0], [withAlpha(0xE3EBF8, 0xF5), 1.0]]
    })
    .border({
      width: 0.8,
      color: withAlpha(0xFFFFFF, this.theme.colors.isDark ? 0x2A : 0xF5),
      radius: Metrics.tileRadius
    })
    .padding(14)
      }
      .width('100%')
      .borderRadius(Metrics.tileRadius)
      .backgroundColor(this.theme.colors.isDark ? 0x2B2B32 : 0xFCFDFF)
      .shadow({
        radius: 26,
        color: this.theme.colors.isDark ? 'rgba(0,0,0,0.42)' : 'rgba(59,76,112,0.14)',
        offsetX: 0,
        offsetY: 11,
        fill: true
      })
  }
}

/** Tab 占位页（T01 过渡用） */
@Component
export struct PlaceholderPage {
  @Consume('oiiTheme') theme: AppTheme;
  title: string = '';
  subtitle: string = '';
  iconChar: string = '⏳';

  build() {
    Column() {
      Stack() {
        Circle()
          .width(64)
          .height(64)
          .fill(Palette.blue)
          .opacity(0.12)
        Text(this.iconChar)
          .fontSize(30)
      }
      .width(64)
      .height(64)

      Blank().height(16)
      Text(this.title)
        .fontSize(this.theme.fs(20))
        .fontColor(this.theme.colors.textPrimary)
      Blank().height(8)
      Text(this.subtitle)
        .fontSize(this.theme.fs(13))
        .fontColor(this.theme.colors.textSecondary)
        .textAlign(TextAlign.Center)
        .lineHeight(this.theme.fs(20))
      Blank().height(24)
      Text('当前版本：阶段一')
        .fontSize(this.theme.fs(12))
        .fontColor(this.theme.colors.textSecondary)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }
}

/** 全局 Toast（底部居中深色圆角条，2.2~2.4s 自动消失，PRD #41） */
@Component
export struct ToastHost {
  @State message: string = '';
  private hideTimer: number = -1;
  private toastListener: () => void = (): void => {
    const hub: ToastHub = ToastHub.getInstance();
    this.message = hub.message;
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
    }
    this.hideTimer = setTimeout((): void => {
      this.message = '';
    }, hub.durationMs > 0 ? hub.durationMs : TOAST_SHORT_MS);
  };

  aboutToAppear(): void {
    ToastHub.getInstance().subscribe(this.toastListener);
  }

  aboutToDisappear(): void {
    ToastHub.getInstance().unsubscribe(this.toastListener);
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
    }
  }

  build() {
    if (this.message.length > 0) {
      Column() {
        Text(this.message)
          .fontSize(13)
          .fontColor(0xFFFFFFFF)
          .textAlign(TextAlign.Center)
      }
      .constraintSize({ maxWidth: '82%' })
      .borderRadius(12)
      .backgroundColor(0xEE1C1C1E)
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .justifyContent(FlexAlign.Center)
    }
  }
}

/** 图标+文本信息行（服务器状态卡用） */
@Component
export struct IconValue {
  @Consume('oiiTheme') theme: AppTheme;
  // 必须 @Prop：普通字段只在组件创建时取一次值，下载器速度/体积/分享率会永远冻在首帧的 0
  // （和 StatTile / SpeedTotalCell 是同一个坑）。
  @Prop iconChar: string = '';
  @Prop value: string = '';
  @Prop tint: number = Palette.blue;
  @Prop fontVp: number = 12;

  build() {
    Row() {
      Text(this.iconChar)
        .fontSize(this.theme.fs(this.fontVp))
        .fontColor(this.tint)
      Text(` ${this.value}`)
        .fontSize(this.theme.fs(this.fontVp))
        .fontColor(this.theme.colors.textSecondary)
        .maxLines(1)
    }
    .alignItems(VerticalAlign.Center)
  }
}

/**
 * 通用确认/选择对话框宿主：半透明遮罩 + 居中卡片（卡片宽 92%，对齐安卓 OiiDialog）。
 * 替代安卓 AlertDialog（ArkTS 用 @State 控制即可，无需 CustomDialog）。
 */
@Component
export struct DialogHost {
  @Consume('oiiTheme') theme: AppTheme;
  /** 弹窗可见性由父组件状态控制（父→子单向）；子组件不回写，关闭走 onCancel/onConfirm 回调 */
  @Prop visible: boolean = false;
  /** @Prop：批量弹窗的标题/按钮文案随子状态变（批量操作 → 批量删除 / 更改保存位置） */
  @Prop title: string = '';
  /** 标题下的一行说明（任务名 / 种子名），留空则不占位 */
  @Prop subtitle: string = '';
  @BuilderParam content: () => void = emptyBuilder;
  @Prop confirmText: string = '确定';
  @Prop cancelText: string = '取消';
  /** 危险操作：确认按钮红色 */
  @Prop destructive: boolean = false;
  /** 只有关闭按钮（选择类弹窗） */
  @Prop showCancel: boolean = true;
  /** 提交中：确认按钮转圈且不可再点 */
  @Prop busy: boolean = false;
  /** 确认按钮置灰（必填项未填写等） */
  @Prop confirmDisabled: boolean = false;
  /** 内容区最大高度（vp），超出后内容区自己滚动；高度不足时卡片按内容收缩 */
  @Prop contentMaxHeight: number = 420;
  /**
   * 屏幕高度（vp），Index 算安全区时写进 AppStorage。
   * 用来给内容区高度加一道「不超过屏幕」的兜底：内容多的弹窗（任务详情）能一次显示完，
   * 但小屏上也不会把卡片顶到状态栏外被裁切。0 = 还没取到，走 contentMaxHeight。
   */
  @StorageLink('sysScreenHeightVp') screenHeightVp: number = 0;
  onConfirm: () => void = (): void => {
  };
  /** 遮罩点击/取消按钮触发，父组件负责关闭弹窗（置空状态源） */
  onCancel: () => void = (): void => {
  };

  /**
   * 文本兜底（崩溃止血）。
   *
   * 线上崩溃：`TypeError: Cannot read property length of undefined` at Common.ets:508
   *  —— @Prop 的字符串在真机某种时序下会拿到 undefined（父级表达式为 undefined、
   *  或数据对象缺字段，如 task.name），直接读 `.length` 会在 build 阶段抛异常，
   *  整个 App 被 ArkTS 运行时杀掉（连 try/catch 都来不及）。
   *  所以渲染前一律过一遍兜底，宁可显示默认文案，也不能让弹窗把进程带走。
   */
  private safeText(v: string, fallback: string): string {
    if (!v) {
      return fallback;
    }
    return v;
  }

  private hasSubtitle(): boolean {
    return this.safeText(this.subtitle, '').length > 0;
  }

  /** 内容区最大高度兜底：@Prop 拿到 undefined 时给 420，避免约束失效把卡片撑满屏 */
  private maxHeightVp(): number {
    let h: number = this.contentMaxHeight;
    if (!h || h <= 0) {
      h = 420;
    }
    // 自适应上限：卡片除内容外还要放标题（~24）+ 间距（28）+ 按钮（40）+ 上下内边距（36）≈ 128，
    // 再给屏幕上下各留一点呼吸空间（合计约 72）。
    // 超过屏幕会上下同时被裁（卡片居中溢出），所以宁可让内容区自己滚。
    const cap: number = this.screenHeightVp > 0 ? this.screenHeightVp - 200 : 0;
    if (cap > 240 && h > cap) {
      return cap;
    }
    return h;
  }

  /**
   * 取消键是否显示。
   * 除了 showCancel（true/false）之外，还要求 cancelText 非空——双保险：
   * 「关于」这类只有一个按钮的弹窗如果哪天 showCancel 没生效（或文案被传成 undefined），
   * 就会出现「取消 + 关闭」两个按钮并排的重复感，这里直接把空文案当成「不要取消键」。
   */
  private cancelVisible(): boolean {
    if (this.showCancel === false) {
      return false;
    }
    return this.safeText(this.cancelText, '').length > 0;
  }

  build() {
    if (this.visible) {
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(GLASS_MASK)
          .onClick((): void => {
            if (!this.busy) {
              this.onCancel();
            }
          })

        Column() {
          Text(this.safeText(this.title, ''))
            .fontSize(this.theme.fs(17))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
          if (this.hasSubtitle()) {
            Text(this.safeText(this.subtitle, ''))
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .lineHeight(this.theme.fs(16))
              .margin({ top: 4 })
              .width('100%')
          }
          Blank().height(12)
          Scroll() {
            Column() {
              this.content()
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
          .constraintSize({ maxHeight: this.maxHeightVp() })
          .scrollBar(BarState.Off)

          Blank().height(16)
          Row() {
            if (this.cancelVisible()) {
              Text(this.safeText(this.cancelText, '取消'))
                .fontSize(this.theme.fs(14))
                .fontColor(this.theme.colors.textPrimary)
                .layoutWeight(1)
                .height(40)
                .textAlign(TextAlign.Center)
                .borderRadius(10)
                .backgroundColor(ghostFill(this.theme.colors.textPrimary))
                .onClick((): void => {
                  if (!this.busy) {
                    this.onCancel();
                  }
                })
              Blank().width(8)
            }
            Row() {
              if (this.busy) {
                LoadingProgress()
                  .width(15)
                  .height(15)
                  .color(0xFFFFFFFF)
                Blank().width(6)
              }
              // 文案缺失时兜底「关闭」：① 空串以前会渲染成一条没字的色条（像进度条）
              // ② undefined 直接读 .length 会 TypeError 让整个 App 闪退（本次崩溃点）
              Text(this.safeText(this.confirmText, '关闭'))
                .fontSize(this.theme.fs(14))
                .fontWeight(FontWeight.Medium)
                // 置灰时用灰字（白字 + 低透明度会糊成一片，看不出是「不可点」）
                .fontColor(this.confirmDisabled ? this.theme.colors.textSecondary : 0xFFFFFFFF)
            }
            .layoutWeight(1)
            .height(40)
            .justifyContent(FlexAlign.Center)
            .borderRadius(10)
            // 主按钮统一「实心主色 + 白字」，不再用 12% 淡蓝：淡蓝在白卡上边界糊、字也容易看不清
            // 不可点时不靠整体降透明度（那会让白字跟着变淡、看着像渲染错误），改成淡灰底 + 灰字
            .backgroundColor(this.confirmDisabled
              ? ghostFill(this.theme.colors.textPrimary)
              : (this.destructive ? Palette.red : this.theme.colors.accent))
            .onClick((): void => {
              if (!this.busy && !this.confirmDisabled) {
                this.onConfirm();
              }
            })
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('92%')
        .borderRadius(20)
        // 毛玻璃：半透明卡片 + 背景虚化 + 细描边勾出玻璃边缘
        .backgroundColor(glassCard(this.theme.colors.card))
        .border({ width: 0.5, color: withAlpha(this.theme.colors.textPrimary, 0x14) })
        .shadow({ radius: 26, color: 'rgba(0,0,0,0.22)', offsetX: 0, offsetY: 10 })
        .padding(18)
      }
      .width('100%')
      .height('100%')
    }
  }
}

/** 可选胶囊（分类 / 标签 / 下载器 / 保存路径） */
@Component
export struct SelectChip {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop label: string = '';
  @Prop active: boolean = false;
  onTap: () => void = (): void => {
  };

  build() {
    Text(this.label)
      .fontSize(this.theme.fs(12))
      .fontColor(this.active ? 0xFFFFFFFF : this.theme.colors.textPrimary)
      .backgroundColor(this.active ? Palette.blue : this.theme.colors.background)
      .borderRadius(9)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .margin({ right: 6, bottom: 6 })
      .maxLines(1)
      .onClick((): void => {
        this.onTap();
      })
  }
}

/** 单选弹窗行 */
@Component
export struct OptionRow {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop label: string = '';
  @Prop selected: boolean = false;
  onPick: () => void = (): void => {
  };

  build() {
    Row() {
      Text(this.label)
        .fontSize(this.theme.fs(15))
        .fontColor(this.selected ? this.theme.colors.accent : this.theme.colors.textPrimary)
        .layoutWeight(1)
      if (this.selected) {
        Circle()
          .width(7)
          .height(7)
          .fill(this.theme.colors.accent)
      }
    }
    .width('100%')
    .borderRadius(9)
    .padding({ top: 11, bottom: 11, left: 8, right: 8 })
    .onClick((): void => {
      this.onPick();
    })
  }
}

/** 筛选下拉按钮（带 ▾） */
@Component
export struct FilterButton {
  @Consume('oiiTheme') theme: AppTheme;
  text: string = '';
  active: boolean = false;
  menuOpen: boolean = false;
  onTap: () => void = (): void => {
  };

  @Builder
  emptyMenu(): void {
  }

  build() {
    Row() {
      Text(this.text)
        .fontSize(this.theme.fs(12))
        .fontColor(this.active ? this.theme.colors.accent : this.theme.colors.textSecondary)
        .maxLines(1)
      Text('▾')
        .fontSize(this.theme.fs(11))
        .fontColor(this.active ? this.theme.colors.accent : this.theme.colors.textSecondary)
    }
    .alignItems(VerticalAlign.Center)
    .borderRadius(9)
    .backgroundColor(this.active ? withAlpha(this.theme.colors.accent, 0x1F) : this.theme.colors.card)
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .onClick((): void => {
      this.onTap();
    })
  }
}

// ---------- 输入框（对应安卓 ui/components/Fields.kt） ----------

@Component
export struct FieldLabel {
  @Consume('oiiTheme') theme: AppTheme;
  text: string = '';
  @BuilderParam trailing: () => void = emptyBuilder;

  build() {
    Row() {
      Text(this.text)
        .fontSize(this.theme.fs(12))
        .fontColor(this.theme.colors.textSecondary)
      if (this.trailing !== undefined) {
        Blank()
        this.trailing()
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}

@Component
export struct BasicField {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop value: string = '';
  placeholder: string = '';
  /** 密码类字段：默认打码，右侧带「眼睛」可临时查看 */
  secret: boolean = false;
  onValueChanged: (v: string) => void = (v: string): void => {
  };
  /** 用户按下键盘动作键（完成/搜索）时回调 */
  onImeAction: () => void = (): void => {
  };
  @State revealed: boolean = false;

  build() {
    Row() {
      TextInput({ text: this.value, placeholder: this.placeholder })
        .fontSize(this.theme.fs(14))
        .fontColor(this.theme.colors.textPrimary)
        .placeholderColor(this.theme.colors.textSecondary)
        .placeholderFont({ size: this.theme.fs(14) })
        .backgroundColor(Color.Transparent)
        // 内部 padding 不能为 0：置 0 时部分系统版本文字会贴边被裁（用户反馈首字符被遮）
        .padding({ left: 4, right: 4, top: 4, bottom: 4 })
        .type(this.secret && !this.revealed ? InputType.Password : InputType.Normal)
        // 系统 InputType.Password 自带一颗眼睛图标，下面又自绘了一颗 → 两个图标。
        // 关掉系统那颗，只留下面可控的（点击切换明文/密文）。
        .showPasswordIcon(false)
        .enterKeyType(EnterKeyType.Done)
        .onChange((v: string): void => {
          this.onValueChanged(v);
        })
        .onSubmit((): void => {
          this.onImeAction();
        })
        .layoutWeight(1)
      if (this.secret) {
        Text(this.revealed ? '🙈' : '👁')
          .fontSize(this.theme.fs(17))
          .fontColor(this.theme.colors.textSecondary)
          .padding(4)
          .onClick((): void => {
            this.revealed = !this.revealed;
          })
      }
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .height(40)
    .borderRadius(10)
    // 底色用「主色半透明叠加」：无论放在白卡片还是直接铺在页面底色上都可见
    // （之前用 colors.background，铺在页面上时框和页面同色 → 用户名/密码框「隐形」）
    .backgroundColor(withAlpha(this.theme.colors.textPrimary, 0x0F))
    .border({
      width: 1,
      color: withAlpha(this.theme.colors.textPrimary, 0x1F)
    })
    // 左 12 + 内部 4 = 文字距圆角 16（「空两格」），圆角曲线够不到文字
    .padding({ left: 12, right: 12 })
  }
}

/** 多行输入框：一个框里填多个地址（内网 IP + 公网域名，一行一个） */
@Component
export struct BasicFieldMulti {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop value: string = '';
  placeholder: string = '';
  onValueChanged: (v: string) => void = (v: string): void => {
  };

  build() {
    Column() {
      if (!hasText(this.value)) {
        Text(this.placeholder)
          .fontSize(this.theme.fs(13))
          .fontColor(this.theme.colors.textSecondary)
          .lineHeight(this.theme.fs(18))
      }
      TextArea({ text: this.value, placeholder: '' })
        .fontSize(this.theme.fs(13))
        .fontColor(this.theme.colors.textPrimary)
        .lineHeight(this.theme.fs(18))
        .backgroundColor(Color.Transparent)
        // 内部 padding 不能为 0（同 BasicField，置 0 会文字贴边被裁）
        .padding({ left: 4, right: 4, top: 2, bottom: 2 })
        .constraintSize({ minHeight: 40 })
        .onChange((v: string): void => {
          this.onValueChanged(v);
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .constraintSize({ minHeight: 58 })
    .borderRadius(10)
    // 与 BasicField 同款：主色半透明叠加 + 描边，铺在页面底色上也可见
    .backgroundColor(withAlpha(this.theme.colors.textPrimary, 0x0F))
    .border({
      width: 1,
      color: withAlpha(this.theme.colors.textPrimary, 0x1F)
    })
    // 左 12 + 内部 4 = 文字距圆角 16
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
  }
}
