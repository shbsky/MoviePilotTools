/**
 * 零依赖多序列折线图（ArkUI Canvas）。
 *
 * MP 没有 CPU / 内存历史序列接口，曲线由 App 本地轮询采样后画出来。
 * 画法对齐 MoviePilot 网页仪表盘：左侧 Y 轴刻度 + 虚线网格 + 2vp 折线 + 可选面积填充。
 *
 * 注意：旧版只在 onReady 里画一次，数据来了不会重绘；这里用 @Watch + onAreaChange
 * 双通道触发，保证采样增长时曲线跟着走。
 */
@Component
export struct MultiLineChart {
  @Prop @Watch('redraw') series: number[][] = [];
  @Prop @Watch('redraw') colors: number[] = [];
  @Prop @Watch('redraw') yMax: number = 100;
  @Prop @Watch('redraw') yLabels: string[] = [];
  @Prop gridColor: number = 0x22000000;
  @Prop labelColor: number = 0x99000000;
  /** 需要铺面积渐变的序列下标；-1 = 不填充 */
  @Prop filledIndex: number = -1;
  @Prop chartHeight: number = 78;
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D();

  /** 数据变了排一次重绘：属性赋值时 canvas 尺寸可能还没算好，延到下一帧 */
  private redraw(): void {
    setTimeout((): void => {
      this.draw();
    }, 0);
  }

  /** 半透明色：0xFFRRGGBB + alpha（0~1）→ 0xAARRGGBB */
  private translucent(color: number, alpha: number): number {
    const a: number = Math.round(alpha * 255) & 0xFF;
    const rgb: number = color & 0x00FFFFFF;
    return ((a << 24) | rgb) >>> 0;
  }

  private draw(): void {
    const ctx: CanvasRenderingContext2D = this.context;
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);

    const hasLabels: boolean = this.yLabels.length > 0;
    const left: number = hasLabels ? 26 : 0;
    const right: number = w;
    const top: number = 8;
    const bottom: number = h - 6;
    const plotHeight: number = Math.max(1, bottom - top);
    const plotWidth: number = Math.max(1, right - left);
    const max: number = Math.max(1, this.yMax);
    const gridLines: number = 2;

    // ---- 虚线网格 + 左侧刻度 ----
    ctx.lineWidth = 1;
    ctx.strokeStyle = this.gridColor;
    ctx.setLineDash([4, 4]);
    for (let i: number = 0; i <= gridLines; i++) {
      const y: number = top + plotHeight * i / gridLines;
      ctx.beginPath();
      ctx.moveTo(left, y);
      ctx.lineTo(right, y);
      ctx.stroke();
    }
    ctx.setLineDash([]);

    if (hasLabels) {
      ctx.font = '10px sans-serif';
      ctx.textAlign = 'right';
      ctx.fillStyle = this.labelColor;
      for (let i: number = 0; i <= gridLines; i++) {
        if (i >= this.yLabels.length) {
          break;
        }
        const y: number = top + plotHeight * i / gridLines;
        ctx.fillText(this.yLabels[i], left - 5, y + 3);
      }
      ctx.textAlign = 'left';
    }

    let maxPoints: number = 0;
    for (const points of this.series) {
      if (points.length > maxPoints) {
        maxPoints = points.length;
      }
    }
    if (maxPoints < 2) {
      return;
    }

    const xOf = (index: number): number => left + index * plotWidth / (maxPoints - 1);
    const yOf = (value: number): number =>
      bottom - (Math.min(max, Math.max(0, value)) / max) * plotHeight;

    // ---- 面积填充（只给 filledIndex 那条）----
    if (this.filledIndex >= 0 && this.filledIndex < this.series.length) {
      const fill: number[] = this.series[this.filledIndex];
      if (fill.length >= 2) {
        const fillColor: number = this.filledIndex < this.colors.length
          ? this.colors[this.filledIndex] : 0xFF0A84FF;
        ctx.fillStyle = this.translucent(fillColor, 0.18);
        ctx.beginPath();
        ctx.moveTo(xOf(0), bottom);
        for (let i: number = 0; i < fill.length; i++) {
          ctx.lineTo(xOf(i), yOf(fill[i]));
        }
        ctx.lineTo(xOf(fill.length - 1), bottom);
        ctx.closePath();
        ctx.fill();
      }
    }

    // ---- 折线 ----
    ctx.lineWidth = 2;
    for (let s: number = 0; s < this.series.length; s++) {
      const points: number[] = this.series[s];
      if (points.length < 2) {
        continue;
      }
      ctx.strokeStyle = s < this.colors.length ? this.colors[s] : 0xFF0A84FF;
      ctx.beginPath();
      for (let i: number = 0; i < points.length; i++) {
        if (i === 0) {
          ctx.moveTo(xOf(i), yOf(points[i]));
        } else {
          ctx.lineTo(xOf(i), yOf(points[i]));
        }
      }
      ctx.stroke();
    }
  }

  build() {
    Canvas(this.context)
      .width('100%')
      .height(this.chartHeight)
      .onReady(() => {
        this.draw();
      })
      .onAreaChange(() => {
        this.draw();
      })
  }
}
