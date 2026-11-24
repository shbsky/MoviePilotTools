import { image } from '@kit.ImageKit';
import { AppTheme } from '../../common/Theme';
import { MpMedia } from '../../model/MpModels';
import { PosterDiskCache } from '../../net/PosterDiskCache';
import { DoubanImageProvider } from '../../net/DoubanImageProvider';
import { getBinary } from '../../net/HttpClient';

/**
 * Hero 海报单张图：磁盘缓存优先 → 命中立即显示（离线/弱网首屏不空），
 * 未命中才联网下载并异步回写缓存。豆瓣图带 Referer，其它图床直连。
 */
@Component
struct HeroPosterImage {
  @Prop url: string = '';
  @State pixel: image.PixelMap | null = null;
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.load();
  }

  private load(): void {
    if (this.url.length === 0) {
      return;
    }
    const seq: number = ++this.loadSeq;
    // 1) 先看磁盘缓存：同步读 + 解码，命中则首帧即有图
    const cached: image.PixelMap | null = PosterDiskCache.loadPixelMap(this.url);
    if (cached !== null) {
      this.pixel = cached;
      return; // 有缓存就不联网，避免每次开 App 都下载（stale-while-revalidate 的“先显示旧图”）
    }
    // 2) 未命中才联网下载
    const headers: Record<string, string> = DoubanImageProvider.isDoubanHost(this.url)
      ? DoubanImageProvider.doubanHeaders() : {};
    getBinary(this.url, headers, 20000).then((buf: ArrayBuffer): void => {
      if (seq !== this.loadSeq) {
        return;
      }
      const pm: image.PixelMap | null = PosterDiskCache.toPixelMap(buf);
      if (pm !== null) {
        this.pixel = pm;
        PosterDiskCache.put(this.url, buf); // 异步回写，下次开 App 直接命中
      }
    }).catch((): void => {
      // 下载失败保留空（父层叠字/渐变遮罩仍在，不会全白）
    });
  }

  build() {
    // 关键：组件自身必须撑满父 Stack，否则内部 Image 的 100% 参照不确定尺寸，
    // 图片只按原图大小渲染成一条，看起来「不居中/上面全黑」。
    Stack() {
      if (this.pixel !== null) {
        // Cover：以卡片宽度为基准放大，居中裁切上下（用户要的「中间放大裁切成卡片宽度」）。
        // 海报铺满整张卡，不再出现中间窄条 + 两边黑边。
        Image(this.pixel)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
      } else {
        // 加载中的兜底底色（深色，避免纯白割裂）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(0xFF14161C)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(0xFF14161C)
  }
}

/**
 * 首屏 Hero 海报轮播：高 190vp / 圆角 22，海报按卡片宽度铺满、居中裁切。
 * 资料由父层传入（来自 MP 推荐 + 本地缓存），本组件不碰任何 MP 分页状态。
 */
@Component
export struct HeroCarousel {
  @Consume('oiiTheme') theme: AppTheme;
  @Prop items: MpMedia[] = [];
  /** 点右上圆形按钮 → 打开当前海报详情（父层负责 openDetail + navStack） */
  onOpenDetail: (media: MpMedia) => void = (): void => {
  };
  @State currentIndex: number = 0;
  /** 卡片高度：190vp，海报按宽度铺满、居中裁切（不缩成窄条） */
  private readonly cardHeight: number = 190;

  private subtitleOf(m: MpMedia): string {
    const year: string = m.yearLabel();
    const genre: string = m.genres.length > 0 ? m.genres[0] : m.typeLabel();
    return year.length > 0 ? `${year} · ${genre}` : genre;
  }

  build() {
    Stack() {
      // ---- 1) Swiper 全幅海报 ----
      Swiper() {
        ForEach(this.items, (media: MpMedia, idx: number): void => {
          this.HeroSlide(media)
        }, (media: MpMedia, idx: number): string => `hero-${media.mediaId}-${idx}`)
      }
      .width('100%')
      .height(this.cardHeight)
      .loop(this.items.length > 1)
      .autoPlay(this.items.length > 1)
      .interval(5000)
      .duration(320)
      .indicator(false)
      .onChange((idx: number): void => {
        this.currentIndex = idx;
      })

      // ---- 2) 底部小横条指示点（固定，不随页滑）----
      Column() {
        Blank()
        Row({ space: 4 }) {
          ForEach(this.items, (media: MpMedia, idx: number): void => {
            Row()
              .width(idx === this.currentIndex ? 14 : 6)
              .height(2)
              .borderRadius(1)
              .backgroundColor(idx === this.currentIndex ? 0xFFFFFFFF : 0x66FFFFFF)
          }, (media: MpMedia, idx: number): string => `dot-${idx}`)
        }
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: 10 })
      .hitTestBehavior(HitTestMode.Transparent)

      // ---- 3) 右上圆形按钮（打开详情）----
      Stack({ alignContent: Alignment.TopEnd }) {
        Stack({ alignContent: Alignment.Center }) {
          Text('›')
            .fontSize(this.theme.fs(22))
            .fontWeight(FontWeight.Medium)
            .fontColor(0xFFFFFFFF)
        }
        .width(30)
        .height(30)
        .borderRadius(15)
        .backgroundColor(0x66000000)
        .margin({ top: 12, right: 12 })
        .onClick((): void => {
          const m: MpMedia | undefined = this.items[this.currentIndex];
          if (m !== undefined) {
            this.onOpenDetail(m);
          }
        })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height(this.cardHeight)
    .borderRadius(22)
    // 实色圆角底：给 shadow 一个真实轮廓。海报被 clip 裁成圆角，但 shadow 取的是
    // 组件的背景绘制轮廓 —— 没有 backgroundColor 时会退化成矩形，四角露直角。
    .backgroundColor(0x101014)
    // 海报卡也浮起来：蓝灰冷调投影（和 ElevatedCard 一致的悬浮语言）
    .shadow({
      radius: 30,
      color: this.theme.colors.isDark ? 'rgba(0,0,0,0.45)' : 'rgba(59,76,112,0.16)',
      offsetX: 0,
      offsetY: 14,
      fill: true
    })
    .clip(true)
  }

  /** 每页：背景海报（缓存） → 左下叠字（不再压黑色渐变遮罩，保留海报原色） */
  @Builder
  HeroSlide(media: MpMedia) {
    // alignContent Bottom：叠字贴底；图片 100% 高不受影响
    Stack({ alignContent: Alignment.Bottom }) {
      HeroPosterImage({ url: media.backdropUrl.length > 0 ? media.backdropUrl : media.posterUrl })

      // 文字直接叠在海报上：靠更实的描边阴影保证可读性，不用整块黑色滤镜盖住画面。
      Column() {
        Column() {
          Text(media.title)
            .fontSize(this.theme.fs(18))
            .fontWeight(FontWeight.Bold)
            .fontColor(0xFFFFFFFF)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textShadow({ radius: 8, color: '#CC000000', offsetX: 0, offsetY: 1 })
          Text(this.subtitleOf(media))
            .fontSize(this.theme.fs(11))
            .fontColor(0xF2FFFFFF)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textShadow({ radius: 6, color: '#CC000000', offsetX: 0, offsetY: 1 })
          Text(media.overview)
            .fontSize(this.theme.fs(10))
            .fontColor(0xE6FFFFFF)
            .lineHeight(this.theme.fs(14))
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textShadow({ radius: 6, color: '#CC000000', offsetX: 0, offsetY: 1 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 18, right: 56 })
      }
      .width('100%')
      .height(120)
      .justifyContent(FlexAlign.End)
      .padding({ bottom: 20 })
    }
    .width('100%')
    .height(this.cardHeight)
  }
}
