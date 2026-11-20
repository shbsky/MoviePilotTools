/**
 * 主题色板与度量，与安卓 ui/theme/Theme.kt 完全对齐（架构 §9）。
 */

export class Palette {
  static readonly bgLight: number = 0xFFF2F2F7;
  static readonly cardLight: number = 0xFFFFFFFF;
  static readonly bgDark: number = 0xFF101014;
  static readonly cardDark: number = 0xFF1C1C1E;

  static readonly blue: number = 0xFF0A84FF;
  static readonly green: number = 0xFF34C759;
  static readonly orange: number = 0xFFFF9500;
  static readonly red: number = 0xFFFF3B30;
  static readonly purple: number = 0xFFAF52DE;
  static readonly indigo: number = 0xFF5E5CE6;
  static readonly mint: number = 0xFF00C7BE;
  static readonly pink: number = 0xFFFF2D55;
  static readonly gray: number = 0xFF8E8E93;

  static readonly textLight: number = 0xFF1C1C1E;
  static readonly secondaryLight: number = 0xFF8A8A8E;
  static readonly separatorLight: number = 0xFFE6E6EB;

  static readonly textDark: number = 0xFFF2F2F7;
  static readonly secondaryDark: number = 0xFF9A9AA0;
  static readonly separatorDark: number = 0xFF2C2C30;

  static readonly arrowDown: number = 0xFF0A84FF;
  static readonly arrowUp: number = 0xFF34C759;
}

/** 明暗两套成组取用 */
export class OiiColors {
  readonly background: number;
  readonly card: number;
  readonly textPrimary: number;
  readonly textSecondary: number;
  readonly separator: number;
  readonly accent: number;
  readonly isDark: boolean;

  constructor(background: number, card: number, textPrimary: number, textSecondary: number,
    separator: number, accent: number, isDark: boolean) {
    this.background = background;
    this.card = card;
    this.textPrimary = textPrimary;
    this.textSecondary = textSecondary;
    this.separator = separator;
    this.accent = accent;
    this.isDark = isDark;
  }
}

export function themeColors(isDark: boolean): OiiColors {
  if (isDark) {
    return new OiiColors(Palette.bgDark, Palette.cardDark, Palette.textDark,
      Palette.secondaryDark, Palette.separatorDark, Palette.blue, true);
  }
  return new OiiColors(Palette.bgLight, Palette.cardLight, Palette.textLight,
    Palette.secondaryLight, Palette.separatorLight, Palette.blue, false);
}

/** 给 ARGB 颜色换 alpha（alphaHex: 0x00~0xFF） */
export function withAlpha(color: number, alphaHex: number): number {
  return ((alphaHex << 24) | (color & 0x00FFFFFF)) >>> 0;
}

/**
 * 毛玻璃弹窗统一材质（v1.0.11 起所有弹窗共用）。
 *
 * 注：**不用 backgroundBlurStyle**。真机上给自绘 overlay 加背景虚化会直接闪退
 * （组件在 Stack 里尺寸不受限，虚化层拿不到有效绘制区域，走 native 崩溃，JS 层抓不到）。
 * 现在的「玻璃」靠三件事做出来，视觉接近毛玻璃且零崩溃风险：
 *   1. 近乎实心的卡片色 + 一丝透明（底下页面只留一点影子，不再透字）
 *   2. 0.5vp 高光描边（勾出玻璃边缘）
 *   3. 大半径柔和投影（卡片浮起来，和背景分层）
 * 遮罩 0.46：卡片不透明了，遮罩可以压深一点，弹窗和背景分得更开。
 */
export const GLASS_MASK: string = 'rgba(0,0,0,0.46)';

/**
 * 玻璃卡片底色：卡片色 ~98% 不透明度。
 * 演进：88% → 95% → 98%。前三版都还嫌透（下载器任务列表背景上全是绿色进度条和大字，
 * 透上来跟弹窗自己的文字打架，用户反馈「都能看到底部文字了」）。
 * 现在基本是实心卡片，只留一丝丝通透感；「毛玻璃」的观感靠 0.5vp 高光描边 + 柔和投影
 * 和更深的遮罩来做，不再指望卡片本身半透明。
 */
export function glassCard(card: number): number {
  return withAlpha(card, 0xFA);
}

/** 次要按钮（取消/关闭）：淡灰填充。绝不能用白色——白卡上的白按钮等于没有边界 */
export function ghostFill(textPrimary: number): number {
  return withAlpha(textPrimary, 0x14);
}

/** 圆角 / 间距度量（vp） */
export class Metrics {
  static readonly cardRadius: number = 18;
  static readonly tileRadius: number = 16;
  static readonly pagePadding: number = 16;
  static readonly cardGap: number = 12;
  static readonly bottomBarRadius: number = 24;
  static readonly bottomReserve: number = 110;
  /**
   * 底部悬浮胶囊 TabBar 避让高度（BUG-4）：
   * 栏实际高 ~52vp（padding 7×2 + icon 21 + gap 3 + label ~14），加 16vp 间距留白。
   * 五个 Tab 页滚动内容的底部统一避让（Index 在 Tabs 容器统一加 padding）。
   */
  static readonly bottomBarInset: number = 68;
  /**
   * 迷你播放条存在时的额外避让高度（BUG-4）：
   * 迷你条高 ~52vp（进度条 2 + 行 padding 7×2 + 封面 36），在 Stack 内 margin-bottom 76，
   * 顶缘距 Stack 底 ~128vp；扣除 TabBar 本身占位 52vp 后额外需要 76vp（含 12vp 呼吸空隙）。
   * 注意：系统导航条（小白条）高度已由 Index 的 Navigation padding(bottomSafeVp) 计入，
   * 此处不可重复累加。
   */
  static readonly miniPlayerInset: number = 76;
}

/**
 * 五个 Tab 页滚动内容的底部避让高度（BUG-4）：
 * 悬浮胶囊 TabBar（~52vp+16 空隙），迷你播放条存在时叠加 miniPlayerInset。
 * 系统导航条（小白条）高度已由 Index 的 Navigation bottomSafeVp padding 计入，此处不重复累加。
 */
export function contentBottomInset(hasMiniBar: boolean): number {
  return hasMiniBar ? Metrics.bottomBarInset + Metrics.miniPlayerInset : Metrics.bottomBarInset;
}

/**
 * 主题状态对象：Index 以 @Provide 下发（含字体缩放），
 * 组件用 @Consume 拿到后 colors / fs() 一起响应变化。
 */
export class AppTheme {
  readonly colors: OiiColors;
  readonly fontScale: number;

  constructor(colors: OiiColors, fontScale: number) {
    this.colors = colors;
    this.fontScale = fontScale;
  }

  /** 字体缩放：90%~120% 经 AppStorage.fontScale 乘算 */
  fs(base: number): number {
    const v: number = base * this.fontScale;
    return Math.round(v * 10) / 10;
  }
}
