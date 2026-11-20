import { AppTheme, Palette, withAlpha, glassCard, GLASS_MASK } from '../../common/Theme';
import { DlnaDevice } from '../../net/DlnaClient';
import { CastController, CastState } from '../../player/CastController';

/**
 * 投送弹窗（对应安卓 ui/music/CastSheet.kt）：
 * 搜索局域网里的 DLNA 设备、把歌推过去，并且能调音箱音量、切上一首/下一首。
 *
 * 一旦这里选定过设备，回到列表点歌就会直接投给音箱（不用再点这个按钮）。
 */

/** 单台设备行 */
@Component
struct DeviceRow {
  @Consume('oiiTheme') theme: AppTheme;
  device: DlnaDevice = new DlnaDevice();
  selected: boolean = false;
  busy: boolean = false;
  onPick: () => void = (): void => {
  };

  build() {
    Row() {
      Stack() {
        Text(this.selected ? '📡' : '🔈').fontSize(15)
      }
      .width(30)
      .height(30)
      .borderRadius(9)
      .backgroundColor(withAlpha(Palette.blue, 0x1F))

      Blank().width(10)
      Column() {
        Text(this.device.name)
          .fontSize(this.theme.fs(13))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.colors.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.device.model.length > 0 && this.device.model !== this.device.name) {
          Text(this.device.model)
            .fontSize(this.theme.fs(10))
            .fontColor(this.theme.colors.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.selected ? '投送中' : (this.busy ? '请稍候' : '投送'))
        .fontSize(this.theme.fs(12))
        .fontColor(this.selected ? Palette.green : (this.busy ? this.theme.colors.textSecondary : Palette.blue))
    }
    .width('100%')
    .borderRadius(11)
    .backgroundColor(this.selected ? withAlpha(Palette.blue, 0x1F) : this.theme.colors.background)
    .padding({ left: 11, right: 11, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      if (!this.busy) {
        this.onPick();
      }
    })
  }
}

/** 正在投送：设备 / 曲目 / 上一首-暂停-下一首 / 音箱音量 */
@Component
struct CastingPanel {
  @Consume('oiiTheme') theme: AppTheme;
  cs: CastState = new CastState();
  @State volumeDraft: number = 0;

  aboutToAppear(): void {
    this.volumeDraft = this.cs.volume >= 0 ? this.cs.volume : 30;
  }

  build() {
    Column() {
      Row() {
        Text('📡').fontSize(15)
        Blank().width(9)
        Column() {
          Row() {
            Text(this.cs.active !== null ? (this.cs.active as DlnaDevice).name : '设备')
              .fontSize(this.theme.fs(13))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.colors.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.cs.progressText().length > 0) {
              Blank().width(6)
              Text(this.cs.progressText())
                .fontSize(this.theme.fs(10))
                .fontColor(this.theme.colors.textSecondary)
            }
          }
          .alignItems(VerticalAlign.Center)
          Text(this.cs.title.length > 0 ? this.cs.title : '正在投送')
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text('停止')
          .fontSize(this.theme.fs(12))
          .fontColor(Palette.red)
          .borderRadius(8)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick((): void => {
            CastController.getInstance().stopCasting();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Blank().height(10)
      Row() {
        Text('⏮')
          .fontSize(18)
          .fontColor(this.cs.hasPrevious() ? this.theme.colors.textPrimary : this.theme.colors.textSecondary)
          .padding(6)
          .onClick((): void => {
            if (this.cs.hasPrevious()) {
              CastController.getInstance().previous();
            }
          })
        Blank().width(16)
        Stack() {
          Text(this.cs.playing ? '⏸' : '▶️').fontSize(17).fontColor(Color.White)
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(Palette.blue)
        .onClick((): void => {
          CastController.getInstance().togglePause();
        })
        Blank().width(16)
        Text('⏭')
          .fontSize(18)
          .fontColor(this.cs.hasNext() ? this.theme.colors.textPrimary : this.theme.colors.textSecondary)
          .padding(6)
          .onClick((): void => {
            if (this.cs.hasNext()) {
              CastController.getInstance().next();
            }
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Blank().height(6)
      if (this.cs.volumeSupported && this.cs.volume >= 0) {
        Row() {
          Text('🔊').fontSize(13).fontColor(this.theme.colors.textSecondary)
          Slider({
            value: this.volumeDraft,
            min: 0,
            max: 100,
            step: 1,
            style: SliderStyle.OutSet
          })
            .layoutWeight(1)
            .padding({ left: 6, right: 6 })
            .selectedColor(Palette.blue)
            .trackColor(this.theme.colors.separator)
            .onChange((value: number, mode: SliderChangeMode): void => {
              if (mode === SliderChangeMode.End) {
                CastController.getInstance().setVolume(Math.round(value));
              }
              this.volumeDraft = Math.round(value);
            })
          Text(`${Math.round(this.volumeDraft)}`)
            .fontSize(this.theme.fs(11))
            .fontColor(this.theme.colors.textSecondary)
            .width(22)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else {
        Row() {
          Text('🔊').fontSize(12).fontColor(this.theme.colors.textSecondary)
          Blank().width(6)
          Text('这台设备不支持 App 调音量，用音箱自己的旋钮或遥控器')
            .fontSize(this.theme.fs(10))
            .fontColor(this.theme.colors.textSecondary)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(withAlpha(Palette.blue, 0x17))
    .padding(11)
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct CastSheet {
  @Consume('oiiTheme') theme: AppTheme;
  /** 屏幕高度（vp，Index 算安全区时写入）：给内容区高度加一道「不超过屏幕」的兜底 */
  @StorageProp('sysScreenHeightVp') screenHeightVp: number = 0;
  currentTitle: string = '';
  /** 点设备行：交给 MusicViewModel.castCurrent 组队列并投送 */
  onCast: (device: DlnaDevice) => void = (_device: DlnaDevice): void => {
  };
  onDismiss: () => void = (): void => {
  };
  private cast: CastController = CastController.getInstance();
  @State cs: CastState = new CastState();
  private listener: () => void = (): void => {
    this.cs = this.cast.state;
  };

  aboutToAppear(): void {
    this.cast.subscribe(this.listener);
    this.listener();
    if (!this.cs.scanned && !this.cs.scanning) {
      this.cast.scan();
    }
    if (this.cs.casting()) {
      this.cast.refreshVolume();
    }
  }

  aboutToDisappear(): void {
    this.cast.unsubscribe(this.listener);
  }

  /**
   * 内容区最大高度：默认 400，屏幕装不下时按屏高收（卡片除内容外还要放
   * 标题 24 + 间距 16 + 按钮 36 + 上下内边距 30 ≈ 106，再留上下呼吸空间）。
   */
  private listMaxVp(): number {
    let h: number = 400;
    const cap: number = this.screenHeightVp > 0 ? this.screenHeightVp - 240 : 0;
    if (cap > 220 && cap < h) {
      h = cap;
    }
    return h;
  }

  build() {
    // 对齐安卓 OiiAlertDialog：**居中卡片**（不是底部面板），标题在上、内容居中、按钮在右下
    Stack() {
      // 半透明遮罩：点空白处关闭（对齐安卓 Dialog 的 dim 层，底下的列表会虚化）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(GLASS_MASK)
        .onClick((): void => {
          this.onDismiss();
        })

      Column() {
        // ---------- 标题 ----------
        Row() {
          Text('📡').fontSize(17)
          Blank().width(8)
          Text('投送到音箱')
            .fontSize(this.theme.fs(17))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.colors.textPrimary)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Blank().height(12)
        Scroll() {
          Column() {
            Text('音箱会自己从 Songloft 拉流播放。选定一次设备后，回列表点歌就自动投给它，整张列表会连播。')
              .fontSize(this.theme.fs(11))
              .fontColor(this.theme.colors.textSecondary)
              .lineHeight(this.theme.fs(16))

            if (this.cs.casting()) {
              Blank().height(12)
              CastingPanel({ cs: this.cs })
            }

            Blank().height(14)

            if (this.cs.scanning) {
              Row() {
                LoadingProgress().width(16).height(16).color(Palette.blue)
                Blank().width(10)
                Text('正在搜索局域网设备…')
                  .fontSize(this.theme.fs(12))
                  .fontColor(this.theme.colors.textSecondary)
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 18, bottom: 18 })
              .alignItems(VerticalAlign.Center)
            } else if (this.cs.devices.length === 0) {
              Text(this.cs.message !== null ? (this.cs.message as string) : '没找到设备，点下面「重新搜索」再试一次。')
                .fontSize(this.theme.fs(11))
                .fontColor(this.cs.message !== null ? Palette.red : this.theme.colors.textSecondary)
                .lineHeight(this.theme.fs(16))
            } else {
              Column() {
                Text(`找到 ${this.cs.devices.length} 台设备，点一台开始投送` +
                  (this.currentTitle.length > 0 ? `「${this.currentTitle}」` : ''))
                  .fontSize(this.theme.fs(11))
                  .fontColor(this.theme.colors.textSecondary)
                Blank().height(8)
                ForEach(this.cs.devices, (device: DlnaDevice): void => {
                  DeviceRow({
                    device: device,
                    selected: this.cs.active !== null &&
                      (this.cs.active as DlnaDevice).id() === device.id(),
                    busy: this.cs.busy,
                    onPick: (): void => {
                      this.onCast(device);
                    }
                  })
                  Blank().height(6)
                }, (device: DlnaDevice): string =>
                  `${device.id()}-${this.cs.active !== null && (this.cs.active as DlnaDevice).id() === device.id() ? 1 : 0}`)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }

            // 消息提示（有设备列表时才显示，空列表时消息已经在上面展示）
            if (this.cs.message !== null && this.cs.devices.length > 0) {
              Blank().height(8)
              Text(this.cs.message as string)
                .fontSize(this.theme.fs(11))
                .fontColor(this.cs.casting() ? Palette.green : Palette.red)
                .lineHeight(this.theme.fs(16))
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          // 右边补 8：卡片右内边距只有 12（要让按钮贴边），正文按 20 对齐
          .padding({ right: 8, bottom: 6 })
        }
        .scrollBar(BarState.Off)
        .constraintSize({ maxHeight: this.listMaxVp() })
        .width('100%')
        .align(Alignment.TopStart)

        Blank().height(4)
        // ---------- 按钮：右下角两个文字按钮（关闭 | 重新搜索），与安卓一致 ----------
        Row() {
          Text('关闭')
            .fontSize(this.theme.fs(14))
            .fontColor(Palette.blue)
            .borderRadius(8)
            .padding({ left: 12, right: 12, top: 9, bottom: 9 })
            .onClick((): void => {
              this.onDismiss();
            })
          Text(this.cs.scanning ? '搜索中…' : '重新搜索')
            .fontSize(this.theme.fs(14))
            .fontColor(this.cs.scanning ? this.theme.colors.textSecondary : Palette.blue)
            .borderRadius(8)
            .padding({ left: 12, right: 12, top: 9, bottom: 9 })
            .onClick((): void => {
              if (!this.cs.scanning) {
                this.cast.scan();
              }
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(VerticalAlign.Center)
      }
      // 宽 80%（安卓 AlertDialog 实机观感），窄屏兜个 340 上限
      .width('80%')
      .constraintSize({ maxWidth: 340 })
      .borderRadius(20)
      // 毛玻璃：与其它弹窗同一套材质
      .backgroundColor(glassCard(this.theme.colors.card))
      .border({ width: 0.5, color: withAlpha(this.theme.colors.textPrimary, 0x14) })
      .shadow({ radius: 26, color: 'rgba(0,0,0,0.22)', offsetX: 0, offsetY: 10 })
      .padding({ left: 20, right: 12, top: 20, bottom: 10 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
