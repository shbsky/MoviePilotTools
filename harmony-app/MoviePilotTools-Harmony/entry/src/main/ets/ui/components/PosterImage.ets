import { image } from '@kit.ImageKit';
import { DoubanImageProvider } from '../../net/DoubanImageProvider';

/**
 * 海报图片组件（T08 #39 Referer 兜底）：
 * 豆瓣图床（*.doubanio.com）必须带防盗链请求头，Image 组件带不了，
 * 这里先手动拉字节解码成 PixelMap 再显示；其它图床直接走 Image 网络加载。
 * 加载失败时回调 onFailed，由父级切到渐变 + 标题兜底。
 */
@Component
export struct PosterImage {
  @Prop @Watch('onUrlChanged') url: string = '';
  onFailed: () => void = (): void => {
  };
  @State pixel: image.PixelMap | null = null;
  @State isDoubanUrl: boolean = false;
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.onUrlChanged();
  }

  onUrlChanged(): void {
    this.loadSeq++;
    const seq: number = this.loadSeq;
    this.pixel = null;
    this.isDoubanUrl = DoubanImageProvider.isDoubanHost(this.url);
    if (this.url.length === 0) {
      this.onFailed();
      return;
    }
    if (!this.isDoubanUrl) {
      // 普通图床交给 Image 组件直连，失败由 onError 上报
      return;
    }
    DoubanImageProvider.fetchPixelMap(this.url).then((pm: image.PixelMap | null): void => {
      if (seq !== this.loadSeq) {
        return; // url 已经又变了，丢弃过期结果
      }
      if (pm === null) {
        this.onFailed();
      } else {
        this.pixel = pm;
      }
    });
  }

  build() {
    if (this.pixel !== null) {
      Image(this.pixel)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .draggable(false)
    } else if (!this.isDoubanUrl) {
      Image(this.url)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .draggable(false)
        .onError((): void => {
          // 失败交给父级切渐变兜底（父级会置 posterFailed 并移除本组件）
          this.onFailed();
        })
    }
  }
}
